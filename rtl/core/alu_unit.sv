`include "defines.svh"

// =============================================================================
// 单周期整数 ALU
// =============================================================================
// 输入来自操作数选择级；结果进入 1-entry 弹性输出寄存器。该寄存器切断
// ALU 组合路径与后续 WB 仲裁，同时允许“本拍消费旧结果 + 接收新操作”实现
// 每拍一条吞吐。
// =============================================================================
module alu_unit (
    input  logic                                      clk,
    input  logic                                      rst_n,
    input  wire core_port_pkg::recover_event_t        recover,

    input  logic                                      in_valid,
    input  wire core_port_pkg::execute_operand_t      in_bus,
    output logic                                      in_ready,

    output logic                                      out_valid,
    output      core_port_pkg::execute_writeback_t    out_bus,
    input  logic                                      out_ready
);
    import core_port_pkg::*;

    execute_writeback_t result_reg;
    logic result_valid;
    logic [XLEN-1:0] alu_result;

    always_comb begin
        unique case (in_bus.issue.uop.dec.alu_op)
            ALU_ADD:  alu_result = in_bus.operand1 + in_bus.operand2;
            ALU_SUB:  alu_result = in_bus.operand1 - in_bus.operand2;
            ALU_SLL:  alu_result = in_bus.operand1 << in_bus.operand2[4:0];
            ALU_SLT:  alu_result = {{(XLEN-1){1'b0}},
                                   $signed(in_bus.operand1) < $signed(in_bus.operand2)};
            ALU_SLTU: alu_result = {{(XLEN-1){1'b0}},
                                   in_bus.operand1 < in_bus.operand2};
            ALU_XOR:  alu_result = in_bus.operand1 ^ in_bus.operand2;
            ALU_SRL:  alu_result = in_bus.operand1 >> in_bus.operand2[4:0];
            ALU_SRA:  alu_result = $signed(in_bus.operand1) >>> in_bus.operand2[4:0];
            ALU_OR:   alu_result = in_bus.operand1 | in_bus.operand2;
            ALU_AND:  alu_result = in_bus.operand1 & in_bus.operand2;
            default:  alu_result = '0;
        endcase

        in_ready = !result_valid || out_ready;
        out_valid = result_valid;
        out_bus   = result_reg;
    end

    always_ff @(posedge clk) begin
        if (!rst_n || recover.valid) begin
            result_valid <= 1'b0;
            result_reg   <= '0;
        end else if (in_ready) begin
            result_valid <= in_valid;
            if (in_valid) begin
                result_reg <= '0;
                result_reg.rob_tag    <= in_bus.issue.rob_tag;
                result_reg.pdst_valid <= in_bus.issue.uop.pdst_valid;
                result_reg.pdst       <= in_bus.issue.uop.pdst;
                result_reg.data       <= alu_result;
            end
        end
    end

endmodule
