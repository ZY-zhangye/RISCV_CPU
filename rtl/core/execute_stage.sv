`include "defines.svh"

// =============================================================================
// 双发射执行簇（不含最终 WB0/WB1 仲裁）
// =============================================================================
// lane0：ALU0 / MLU
// lane1：ALU1 / BRU / CSR / LSQ-AGU
//
// 两路都先经过独立 operand_read_stage，与同步 PRF 返回对齐并完成广播旁路
// 选择。之后按 FU 类型路由到独立执行单元。各结果端口保留 valid/ready，
// 供下一阶段实现 WB0(ALU0/MLU) 与 WB1(ALU1/BRU/LSU) 仲裁；CSR 结果保留
// 独立端口，提交侧可将其作为串行操作处理。
// =============================================================================
module execute_stage #(
    parameter int MUL_LATENCY = 3
) (
    input  logic                                      clk,
    input  logic                                      rst_n,
    input  wire core_port_pkg::recover_event_t        recover,

    // issue0：来自 IQ0。
    input  logic                                      issue0_valid,
    input  wire core_port_pkg::iq_issue_slot_t        issue0_bus,
    output logic                                      issue0_ready,

    // issue1：来自 IQ1/LSQ 年龄仲裁器。
    input  logic                                      issue1_valid,
    input  wire core_port_pkg::issue1_slot_t          issue1_bus,
    output logic                                      issue1_ready,

    // PRF 同步读数据：port0/1 对应 issue0，port2/3 对应 issue1。
    input  wire core_port_pkg::phys_reg_read_data_bundle_t prf_read_data,

    // 返回 IQ/LSQ 的功能单元可用性。
    output logic                                      alu0_available,
    output logic                                      mlu_available,
    output logic                                      alu1_available,
    output logic                                      bru_available,
    output logic                                      csr_available,
    output logic                                      lsu_available,

    // 独立执行结果，等待后续写回仲裁。
    output logic                                      alu0_wb_valid,
    output      core_port_pkg::execute_writeback_t    alu0_wb,
    input  logic                                      alu0_wb_ready,
    output logic                                      mlu_wb_valid,
    output      core_port_pkg::execute_writeback_t    mlu_wb,
    input  logic                                      mlu_wb_ready,
    output logic                                      alu1_wb_valid,
    output      core_port_pkg::execute_writeback_t    alu1_wb,
    input  logic                                      alu1_wb_ready,
    output logic                                      bru_wb_valid,
    output      core_port_pkg::execute_writeback_t    bru_wb,
    input  logic                                      bru_wb_ready,
    output logic                                      csr_wb_valid,
    output      core_port_pkg::execute_writeback_t    csr_wb,
    output      core_port_pkg::csr_execute_update_t   csr_update,
    input  logic                                      csr_wb_ready,

    // LSU AGU 结果直接回到 LSQ；LSQ 内的 memory_request_reg 是 DMEM 前
    // 的外置寄存级。
    output      core_port_pkg::lsq_agu_result_t       lsu_agu_result,

    // CSR 文件一拍时序读口；提交缓存非空时禁止新的 CSR 离开 IQ/operand。
    input  logic                                      csr_commit_available,
    output      core_port_pkg::csr_read_request_t     csr_read_request,
    input  wire core_port_pkg::csr_read_response_t    csr_read_response,

    // Vivado Multiplier / Divider Generator 接口。
    output logic                                      mul_request_valid,
    output logic signed [32:0]                        mul_operand_a,
    output logic signed [32:0]                        mul_operand_b,
    input  logic signed [65:0]                        mul_product,
    output logic                                      div_dividend_valid,
    input  logic                                      div_dividend_ready,
    output logic signed [32:0]                        div_dividend_data,
    output logic                                      div_divisor_valid,
    input  logic                                      div_divisor_ready,
    output logic signed [32:0]                        div_divisor_data,
    input  logic                                      div_result_valid,
    output logic                                      div_result_ready,
    input  logic signed [32:0]                        div_quotient,
    input  logic signed [32:0]                        div_remainder
);
    import core_port_pkg::*;

    issue1_slot_t issue0_common;
    execute_operand_t operand0_bus;
    execute_operand_t operand1_bus;
    logic operand0_valid;
    logic operand0_ready;
    logic operand1_valid;
    logic operand1_ready;
    logic alu0_in_ready;
    logic mlu_in_ready;
    logic alu1_in_ready;
    logic bru_in_ready;
    logic csr_in_ready;
    logic lsu_in_ready;

    always_comb begin
        issue0_common = '0;
        issue0_common.rob_tag           = issue0_bus.rob_tag;
        issue0_common.uop               = issue0_bus.uop;
        issue0_common.src1_bypass_valid = issue0_bus.src1_bypass_valid;
        issue0_common.src1_bypass_data  = issue0_bus.src1_bypass_data;
        issue0_common.src2_bypass_valid = issue0_bus.src2_bypass_valid;
        issue0_common.src2_bypass_data  = issue0_bus.src2_bypass_data;

        unique case (operand0_bus.issue.uop.dec.fu_type)
            FU_ALU: operand0_ready = alu0_in_ready;
            FU_MLU: operand0_ready = mlu_in_ready;
            default: operand0_ready = 1'b0;
        endcase

        if (operand1_bus.issue.from_lsq)
            operand1_ready = lsu_in_ready;
        else begin
            unique case (operand1_bus.issue.uop.dec.fu_type)
                FU_ALU: operand1_ready = alu1_in_ready;
                FU_BRU: operand1_ready = bru_in_ready;
                FU_CSR: operand1_ready = csr_in_ready && csr_commit_available;
                default: operand1_ready = 1'b0;
            endcase
        end

        alu0_available = alu0_in_ready;
        mlu_available  = mlu_in_ready;
        alu1_available = alu1_in_ready;
        bru_available  = bru_in_ready;
        csr_available  = csr_in_ready && csr_commit_available;
        lsu_available  = lsu_in_ready;
    end

    operand_read_stage u_operand0 (
        .clk      (clk),
        .rst_n    (rst_n),
        .recover  (recover),
        .in_valid (issue0_valid),
        .in_bus   (issue0_common),
        .in_ready (issue0_ready),
        .prf_src1 (prf_read_data.port0),
        .prf_src2 (prf_read_data.port1),
        .out_valid(operand0_valid),
        .out_bus  (operand0_bus),
        .out_ready(operand0_ready)
    );

    operand_read_stage u_operand1 (
        .clk      (clk),
        .rst_n    (rst_n),
        .recover  (recover),
        .in_valid (issue1_valid),
        .in_bus   (issue1_bus),
        .in_ready (issue1_ready),
        .prf_src1 (prf_read_data.port2),
        .prf_src2 (prf_read_data.port3),
        .out_valid(operand1_valid),
        .out_bus  (operand1_bus),
        .out_ready(operand1_ready)
    );

    alu_unit u_alu0 (
        .clk(clk), .rst_n(rst_n), .recover(recover),
        .in_valid(operand0_valid
                  && (operand0_bus.issue.uop.dec.fu_type == FU_ALU)),
        .in_bus(operand0_bus), .in_ready(alu0_in_ready),
        .out_valid(alu0_wb_valid), .out_bus(alu0_wb),
        .out_ready(alu0_wb_ready)
    );

    mlu_unit #(.MUL_LATENCY(MUL_LATENCY)) u_mlu (
        .clk(clk), .rst_n(rst_n), .recover(recover),
        .in_valid(operand0_valid
                  && (operand0_bus.issue.uop.dec.fu_type == FU_MLU)),
        .in_bus(operand0_bus), .in_ready(mlu_in_ready),
        .out_valid(mlu_wb_valid), .out_bus(mlu_wb),
        .out_ready(mlu_wb_ready),
        .mul_request_valid(mul_request_valid),
        .mul_operand_a(mul_operand_a), .mul_operand_b(mul_operand_b),
        .mul_product(mul_product),
        .div_dividend_valid(div_dividend_valid),
        .div_dividend_ready(div_dividend_ready),
        .div_dividend_data(div_dividend_data),
        .div_divisor_valid(div_divisor_valid),
        .div_divisor_ready(div_divisor_ready),
        .div_divisor_data(div_divisor_data),
        .div_result_valid(div_result_valid),
        .div_result_ready(div_result_ready),
        .div_quotient(div_quotient), .div_remainder(div_remainder)
    );

    alu_unit u_alu1 (
        .clk(clk), .rst_n(rst_n), .recover(recover),
        .in_valid(operand1_valid && !operand1_bus.issue.from_lsq
                  && (operand1_bus.issue.uop.dec.fu_type == FU_ALU)),
        .in_bus(operand1_bus), .in_ready(alu1_in_ready),
        .out_valid(alu1_wb_valid), .out_bus(alu1_wb),
        .out_ready(alu1_wb_ready)
    );

    bru_unit u_bru (
        .clk(clk), .rst_n(rst_n), .recover(recover),
        .in_valid(operand1_valid && !operand1_bus.issue.from_lsq
                  && (operand1_bus.issue.uop.dec.fu_type == FU_BRU)),
        .in_bus(operand1_bus), .in_ready(bru_in_ready),
        .out_valid(bru_wb_valid), .out_bus(bru_wb),
        .out_ready(bru_wb_ready)
    );

    csr_unit u_csr (
        .clk(clk), .rst_n(rst_n), .recover(recover),
        .in_valid(operand1_valid && !operand1_bus.issue.from_lsq
                  && (operand1_bus.issue.uop.dec.fu_type == FU_CSR)
                  && csr_commit_available),
        .in_bus(operand1_bus), .in_ready(csr_in_ready),
        .csr_read_request(csr_read_request),
        .csr_read_response(csr_read_response),
        .out_valid(csr_wb_valid), .out_bus(csr_wb),
        .csr_update(csr_update), .out_ready(csr_wb_ready)
    );

    lsu_unit u_lsu (
        .recover_valid(recover.valid),
        .in_valid(operand1_valid && operand1_bus.issue.from_lsq),
        .in_bus(operand1_bus), .in_ready(lsu_in_ready),
        .agu_result(lsu_agu_result)
    );

`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
        if (rst_n && !recover.valid && operand0_valid)
            assert ((operand0_bus.issue.uop.dec.fu_type == FU_ALU)
                    || (operand0_bus.issue.uop.dec.fu_type == FU_MLU))
                else $error("execute_stage: unsupported FU on issue0");
        if (rst_n && !recover.valid && operand1_valid)
            assert (operand1_bus.issue.from_lsq
                    || (operand1_bus.issue.uop.dec.fu_type == FU_ALU)
                    || (operand1_bus.issue.uop.dec.fu_type == FU_BRU)
                    || (operand1_bus.issue.uop.dec.fu_type == FU_CSR))
                else $error("execute_stage: unsupported FU on issue1");
    end
`endif

endmodule
