`include "defines.svh"

// =============================================================================
// 同步 PRF 返回对齐与操作数选择级
// =============================================================================
// IQ/issue1 在握手拍向 PRF 发出读地址，本模块同时锁存 issue 元数据；PRF
// 在该上升沿更新读数据，因此随后的整个周期内，meta_reg 与 prf_src* 正好
// 对齐。广播旁路命中时优先使用 issue 包内锁存的数据，PRF 本身不做前递。
//
// 本级是一个 1-entry elastic stage：下游可每拍消费并由新指令替换；下游
// 阻塞时 in_ready 拉低，PRF 对应端口不再产生有效请求并保持上次读值，因而
// out_bus 在整个反压期间稳定。
// =============================================================================
module operand_read_stage (
    input  logic                                      clk,
    input  logic                                      rst_n,
    input  wire core_port_pkg::recover_event_t        recover,

    input  logic                                      in_valid,
    input  wire core_port_pkg::issue1_slot_t          in_bus,
    output logic                                      in_ready,

    input  logic [core_port_pkg::XLEN-1:0]            prf_src1,
    input  logic [core_port_pkg::XLEN-1:0]            prf_src2,

    output logic                                      out_valid,
    output      core_port_pkg::execute_operand_t      out_bus,
    input  logic                                      out_ready
);
    import core_port_pkg::*;

    logic         meta_valid;
    issue1_slot_t meta_reg;
    logic [XLEN-1:0] rs1_value;
    logic [XLEN-1:0] rs2_value;

    always_comb begin
        in_ready = !meta_valid || out_ready;
        out_valid = meta_valid;

        rs1_value = '0;
        if (meta_reg.uop.dec.use_rs1)
            rs1_value = meta_reg.src1_bypass_valid
                      ? meta_reg.src1_bypass_data : prf_src1;

        rs2_value = '0;
        if (meta_reg.uop.dec.use_rs2 || meta_reg.read_store_data)
            rs2_value = meta_reg.src2_bypass_valid
                      ? meta_reg.src2_bypass_data : prf_src2;

        out_bus = '0;
        out_bus.issue     = meta_reg;
        out_bus.rs1_value = rs1_value;
        out_bus.rs2_value = rs2_value;
        out_bus.operand1  = meta_reg.uop.dec.src1_is_pc
                          ? meta_reg.uop.dec.pc : rs1_value;
        out_bus.operand2  = meta_reg.uop.dec.src2_is_imm
                          ? meta_reg.uop.dec.imm : rs2_value;
    end

    always_ff @(posedge clk) begin
        if (!rst_n || recover.valid) begin
            meta_valid <= 1'b0;
            meta_reg   <= '0;
        end else if (in_ready) begin
            meta_valid <= in_valid;
            if (in_valid)
                meta_reg <= in_bus;
        end
    end

`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
        if (rst_n && !recover.valid && out_valid && !out_ready)
            assert (!in_ready)
                else $error("operand_read_stage: accepted input while stalled");
    end
`endif

endmodule
