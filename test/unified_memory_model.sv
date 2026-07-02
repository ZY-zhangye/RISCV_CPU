`timescale 1ns/1ps
`include "defines.svh"

// =============================================================================
// Core 级统一行为内存
// =============================================================================
// IMEM：固定一周期 64-bit 同步读。
// DMEM：Core 请求先进入本模块的一项外部寄存器，再访问统一 word array；
//       Load 在寄存级之后返回响应，明确切断 Core→存储器→Core 的组合路径。
// =============================================================================
module unified_memory_model #(
    parameter logic [31:0] BASE_ADDR = 32'h0000_0000,
    parameter int          WORD_COUNT = 4096
) (
    input  logic                                      clk,
    input  logic                                      rst_n,

    input  logic [`ADDR_WIDTH-1:0]                    imem_addr,
    input  logic                                      imem_ren,
    output logic [`DATA_WIDTH-1:0]                    imem_rdata,

    input  logic                                      dmem_request_valid,
    input  wire core_port_pkg::lsq_mem_request_t      dmem_request,
    output logic                                      dmem_request_ready,
    output      core_port_pkg::lsq_mem_response_t     dmem_response,

    output logic                                      dmem_stage_valid_o
);
    import core_port_pkg::*;

    logic [31:0] mem [0:WORD_COUNT-1];
    logic dmem_stage_valid;
    lsq_mem_request_t dmem_stage_request;
    lsq_mem_response_t dmem_response_reg;
    integer imem_word_index;
    integer dmem_word_index;
    integer byte_idx;
    integer init_idx;
    string hex_file;

    task automatic clear_words(input logic [31:0] value);
        integer clear_idx;
        begin
            for (clear_idx = 0; clear_idx < WORD_COUNT; clear_idx = clear_idx + 1)
                mem[clear_idx] = value;
        end
    endtask

    task automatic write_word(
        input logic [31:0] address,
        input logic [31:0] value
    );
        integer write_index;
        begin
            write_index = (address - BASE_ADDR) >> 2;
            if ((address >= BASE_ADDR) && (write_index >= 0)
                && (write_index < WORD_COUNT))
                mem[write_index] = value;
        end
    endtask

    assign dmem_request_ready = !dmem_stage_valid;
    assign dmem_response = dmem_response_reg;
    assign dmem_stage_valid_o = dmem_stage_valid;

    initial begin
        // 未被 HEX 覆盖的地址保持为确定的 NOP，避免短镜像之后的预取把
        // 未初始化 X 带入前端。镜像本身仍由 $readmemh 原样覆盖，不改写。
        for (init_idx = 0; init_idx < WORD_COUNT; init_idx = init_idx + 1)
            mem[init_idx] = `NOP_INST;
        if ($value$plusargs("HEX=%s", hex_file))
            $readmemh(hex_file, mem);
    end

    // 同步 IMEM：地址在本拍提出，64-bit 数据在下一拍寄存输出。
    always @(posedge clk) begin
        if (!rst_n) begin
            imem_rdata <= {`NOP_INST, `NOP_INST};
        end else if (imem_ren) begin
            imem_word_index = (imem_addr - BASE_ADDR) >> 2;
            if ((imem_addr >= BASE_ADDR)
                && (imem_word_index >= 0)
                && ((imem_word_index + 1) < WORD_COUNT))
                imem_rdata <= {mem[imem_word_index + 1], mem[imem_word_index]};
            else
                imem_rdata <= {`NOP_INST, `NOP_INST};
        end
    end

    // Core 外部 DMEM 寄存级。stage 非空时不接收新请求；Load 响应和
    // Store 写入均在请求完成寄存之后发生。
    always @(posedge clk) begin
        if (!rst_n) begin
            dmem_stage_valid   <= 1'b0;
            dmem_stage_request <= '0;
            dmem_response_reg  <= '0;
        end else begin
            dmem_response_reg <= '0;

            if (dmem_stage_valid) begin
                dmem_word_index = (dmem_stage_request.address - BASE_ADDR) >> 2;
                if (dmem_stage_request.is_store) begin
                    if ((dmem_stage_request.address >= BASE_ADDR)
                        && (dmem_word_index >= 0)
                        && (dmem_word_index < WORD_COUNT)) begin
                        for (byte_idx = 0; byte_idx < 4; byte_idx = byte_idx + 1)
                            if (dmem_stage_request.write_strobe[byte_idx])
                                mem[dmem_word_index][byte_idx*8 +: 8]
                                    <= dmem_stage_request.write_data[byte_idx*8 +: 8];
                    end
                end else begin
                    dmem_response_reg.valid   <= 1'b1;
                    dmem_response_reg.lsq_tag <= dmem_stage_request.lsq_tag;
                    if ((dmem_stage_request.address >= BASE_ADDR)
                        && (dmem_word_index >= 0)
                        && (dmem_word_index < WORD_COUNT)) begin
                        dmem_response_reg.read_data <= mem[dmem_word_index];
                    end else begin
                        dmem_response_reg.exception_valid <= 1'b1;
                        dmem_response_reg.exc_code <= `EXC_LOAD_ACCESS;
                        dmem_response_reg.exc_tval <= dmem_stage_request.address;
                    end
                end
                dmem_stage_valid <= 1'b0;
            end

            if (dmem_request_valid && dmem_request_ready) begin
                dmem_stage_valid   <= 1'b1;
                dmem_stage_request <= dmem_request;
            end
        end
    end

`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
        if (rst_n && dmem_response_reg.valid)
            assert (!dmem_stage_request.is_store)
                else $error("unified_memory_model: Store generated a response");
    end
`endif

endmodule
