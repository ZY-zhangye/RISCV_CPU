`timescale 1ns/1ps
`include "defines.svh"

module tb_core_rv32m_instructions;
    import core_port_pkg::*;

    localparam int MUL_LATENCY = 3;
    localparam int DIV_LATENCY = 4;

    logic clk, rst_n;
    logic [31:0] imem_addr;
    logic imem_ren;
    logic [63:0] imem_rdata;
    logic dmem_request_valid, dmem_request_ready;
    lsq_mem_request_t dmem_request;
    lsq_mem_response_t dmem_response;
    rob_commit_bundle_t commit_bus;
    logic [1:0] commit_fire;

    logic mul_request_valid;
    logic signed [32:0] mul_operand_a, mul_operand_b;
    logic signed [65:0] mul_product;

    logic div_dividend_valid, div_dividend_ready;
    logic signed [32:0] div_dividend_data;
    logic div_divisor_valid, div_divisor_ready;
    logic signed [32:0] div_divisor_data;
    logic div_result_valid, div_result_ready;
    logic signed [32:0] div_quotient, div_remainder;
    logic div_have_dividend, div_have_divisor;
    logic div_busy;
    logic signed [32:0] div_dividend_reg, div_divisor_reg;
    integer div_count;
    integer mul_request_count, div_request_count;

    core_top #(
        .MUL_LATENCY(MUL_LATENCY),
        .RESET_PC(32'h0)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .imem_addr_o(imem_addr), .imem_ren_o(imem_ren),
        .imem_rdata_i(imem_rdata),
        .dmem_request_valid_o(dmem_request_valid),
        .dmem_request_o(dmem_request),
        .dmem_request_ready_i(dmem_request_ready),
        .dmem_response_i(dmem_response),
        .irq_software_i(1'b0), .irq_timer_i(1'b0), .irq_external_i(1'b0),
        .mul_request_valid_o(mul_request_valid),
        .mul_operand_a_o(mul_operand_a), .mul_operand_b_o(mul_operand_b),
        .mul_product_i(mul_product),
        .div_dividend_valid_o(div_dividend_valid),
        .div_dividend_ready_i(div_dividend_ready),
        .div_dividend_data_o(div_dividend_data),
        .div_divisor_valid_o(div_divisor_valid),
        .div_divisor_ready_i(div_divisor_ready),
        .div_divisor_data_o(div_divisor_data),
        .div_result_valid_i(div_result_valid),
        .div_result_ready_o(div_result_ready),
        .div_quotient_i(div_quotient), .div_remainder_i(div_remainder),
        .recover_o(), .branch_update_o(), .fence_i_commit_o(),
        .commit_bus_o(commit_bus), .commit_fire_o(commit_fire),
        .core_idle_o()
    );

    unified_memory_model #(.WORD_COUNT(1024)) u_memory (
        .clk(clk), .rst_n(rst_n),
        .imem_addr(imem_addr), .imem_ren(imem_ren), .imem_rdata(imem_rdata),
        .dmem_request_valid(dmem_request_valid), .dmem_request(dmem_request),
        .dmem_request_ready(dmem_request_ready), .dmem_response(dmem_response),
        .dmem_stage_valid_o()
    );

    always #5 clk = ~clk;

    // 固定延迟乘法 IP 行为模型：只在 request 脉冲时锁存输入。结果保持
    // 稳定，供 MLU 在配置的 MUL_LATENCY 到期时采样。
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            mul_product       <= '0;
            mul_request_count <= 0;
        end else if (mul_request_valid) begin
            mul_product <= mul_operand_a * mul_operand_b;
            mul_request_count <= mul_request_count + 1;
        end
    end

    // Divider Generator 行为模型。两个输入通道分别握手，均收到后经过
    // DIV_LATENCY 拍产生结果，并保持 valid 直至 MLU 接收。
    assign div_dividend_ready = !div_busy && !div_result_valid
                              && !div_have_dividend;
    assign div_divisor_ready  = !div_busy && !div_result_valid
                              && !div_have_divisor;

    always_ff @(posedge clk) begin : divider_model
        logic dividend_fire;
        logic divisor_fire;
        logic signed [32:0] dividend_now;
        logic signed [32:0] divisor_now;

        if (!rst_n) begin
            div_have_dividend <= 1'b0;
            div_have_divisor  <= 1'b0;
            div_busy          <= 1'b0;
            div_dividend_reg  <= '0;
            div_divisor_reg   <= '0;
            div_count         <= 0;
            div_result_valid  <= 1'b0;
            div_quotient      <= '0;
            div_remainder     <= '0;
            div_request_count <= 0;
        end else begin
            dividend_fire = div_dividend_valid && div_dividend_ready;
            divisor_fire  = div_divisor_valid && div_divisor_ready;
            dividend_now  = dividend_fire ? div_dividend_data
                                          : div_dividend_reg;
            divisor_now   = divisor_fire ? div_divisor_data
                                         : div_divisor_reg;

            if (div_result_valid && div_result_ready)
                div_result_valid <= 1'b0;

            if (dividend_fire) begin
                div_dividend_reg  <= div_dividend_data;
                div_have_dividend <= 1'b1;
            end
            if (divisor_fire) begin
                div_divisor_reg  <= div_divisor_data;
                div_have_divisor <= 1'b1;
            end

            if (!div_busy && !div_result_valid
                && (div_have_dividend || dividend_fire)
                && (div_have_divisor || divisor_fire)) begin
                div_quotient      <= dividend_now / divisor_now;
                div_remainder     <= dividend_now % divisor_now;
                div_have_dividend <= 1'b0;
                div_have_divisor  <= 1'b0;
                div_busy          <= 1'b1;
                div_count         <= DIV_LATENCY;
                div_request_count <= div_request_count + 1;
            end else if (div_busy) begin
                if (div_count > 1) begin
                    div_count <= div_count - 1;
                end else begin
                    div_count        <= 0;
                    div_busy         <= 1'b0;
                    div_result_valid <= 1'b1;
                end
            end
        end
    end

    function automatic logic [31:0] encode_lui(
        input logic [4:0] rd, input logic [19:0] upper
    );
        encode_lui = {upper, rd, 7'b0110111};
    endfunction

    function automatic logic [31:0] encode_addi(
        input logic [4:0] rd, input logic [4:0] rs1,
        input logic [11:0] immediate
    );
        encode_addi = {immediate, rs1, 3'b000, rd, 7'b0010011};
    endfunction

    function automatic logic [31:0] encode_m(
        input logic [2:0] funct3, input logic [4:0] rd,
        input logic [4:0] rs1, input logic [4:0] rs2
    );
        encode_m = {7'b0000001, rs2, rs1, funct3, rd, 7'b0110011};
    endfunction

    function automatic logic [31:0] committed_x3;
        logic [PHYS_REG_IDX_WIDTH-1:0] preg;
        begin
            preg = dut.u_backend.u_rename.u_rat_rrat.rrat[3];
            committed_x3 = dut.u_backend.u_prf.registers[preg];
        end
    endfunction

    task automatic tick;
        @(posedge clk); #1;
    endtask

    task automatic write_li(
        input logic [31:0] pc, input logic [4:0] rd,
        input logic [31:0] value
    );
        logic [31:0] rounded_value;
        begin
            rounded_value = value + 32'h0000_0800;
            u_memory.write_word(pc, encode_lui(rd, rounded_value[31:12]));
            u_memory.write_word(pc + 4,
                encode_addi(rd, rd, value[11:0]));
        end
    endtask

    task automatic prepare_case;
        begin
            rst_n = 1'b0;
            u_memory.clear_words(`NOP_INST);
            repeat (3) tick();
        end
    endtask

    task automatic wait_commit(input string name);
        integer cycles;
        logic seen;
        begin
            cycles = 0;
            seen = 1'b0;
            while (!seen && (cycles < 240)) begin
                @(negedge clk);
                seen = (commit_fire[0] && (commit_bus.lane0.pc == 32'h10))
                    || (commit_fire[1] && (commit_bus.lane1.pc == 32'h10));
                cycles = cycles + 1;
            end
            if (seen) tick();
            assert (seen) else $fatal(1, "%s commit timeout", name);
        end
    endtask

    task automatic run_m(
        input string name,
        input logic [2:0] funct3,
        input logic [31:0] lhs,
        input logic [31:0] rhs,
        input logic [31:0] expected,
        input integer expected_mul_requests,
        input integer expected_div_requests
    );
        begin
            prepare_case();
            write_li(32'h0, 5'd1, lhs);
            write_li(32'h8, 5'd2, rhs);
            u_memory.write_word(32'h10,
                encode_m(funct3, 5'd3, 5'd1, 5'd2));
            rst_n = 1'b1;
            tick();
            wait_commit(name);
            assert (committed_x3() == expected)
                else $fatal(1, "%s mismatch: expected=%08h actual=%08h",
                            name, expected, committed_x3());
            assert (mul_request_count == expected_mul_requests)
                else $fatal(1, "%s multiplier request count=%0d",
                            name, mul_request_count);
            assert (div_request_count == expected_div_requests)
                else $fatal(1, "%s divider request count=%0d",
                            name, div_request_count);
        end
    endtask

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;

        run_m("MUL",    3'b000, 32'hffff_fffe, 32'd3,
              32'hffff_fffa, 1, 0);
        run_m("MULH",   3'b001, 32'hffff_fffe, 32'd3,
              32'hffff_ffff, 1, 0);
        run_m("MULHSU", 3'b010, 32'hffff_fffe, 32'hffff_ffff,
              32'hffff_fffe, 1, 0);
        run_m("MULHU",  3'b011, 32'hffff_ffff, 32'hffff_fffe,
              32'hffff_fffd, 1, 0);

        run_m("DIV",    3'b100, -32'sd20, 32'd3,
              32'hffff_fffa, 0, 1);
        run_m("DIVU",   3'b101, 32'hffff_fff0, 32'd16,
              32'h0fff_ffff, 0, 1);
        run_m("REM",    3'b110, -32'sd20, 32'd3,
              32'hffff_fffe, 0, 1);
        run_m("REMU",   3'b111, 32'hffff_fff1, 32'd16,
              32'h0000_0001, 0, 1);

        // RISC-V 规定的除零与有符号溢出结果必须走 MLU 本地快速路径，
        // 不应向 Divider Generator 发出事务。
        run_m("DIV by zero",  3'b100, 32'h1234_5678, 32'h0,
              32'hffff_ffff, 0, 0);
        run_m("REM by zero",  3'b110, 32'h1234_5678, 32'h0,
              32'h1234_5678, 0, 0);
        run_m("DIV overflow", 3'b100, 32'h8000_0000, 32'hffff_ffff,
              32'h8000_0000, 0, 0);
        run_m("REM overflow", 3'b110, 32'h8000_0000, 32'hffff_ffff,
              32'h0000_0000, 0, 0);

        $display("PASS: core RV32M multiply/divide/remainder instructions");
        $finish;
    end

endmodule
