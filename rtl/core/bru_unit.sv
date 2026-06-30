`include "defines.svh"

// =============================================================================
// 分支执行单元
// =============================================================================
// 计算条件、真实下一 PC 与 JAL/JALR 链接值。只有预测方向错误，或预测为
// taken 但目标错误时，才在完成包中置 redirect_valid；恢复动作仍由 ROB 头
// 的统一 recovery/flush 通路产生。
// =============================================================================
module bru_unit (
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
    logic actual_taken;
    logic [`ADDR_WIDTH-1:0] branch_target;
    logic [`ADDR_WIDTH-1:0] actual_next_pc;
    logic redirect_needed;

    always_comb begin
        actual_taken = 1'b0;
        unique case (in_bus.issue.uop.dec.branch_op)
            BR_BEQ:  actual_taken = (in_bus.rs1_value == in_bus.rs2_value);
            BR_BNE:  actual_taken = (in_bus.rs1_value != in_bus.rs2_value);
            BR_BLT:  actual_taken = ($signed(in_bus.rs1_value)
                                  < $signed(in_bus.rs2_value));
            BR_BGE:  actual_taken = ($signed(in_bus.rs1_value)
                                  >= $signed(in_bus.rs2_value));
            BR_BLTU: actual_taken = (in_bus.rs1_value < in_bus.rs2_value);
            BR_BGEU: actual_taken = (in_bus.rs1_value >= in_bus.rs2_value);
            BR_JUMP: actual_taken = 1'b1;
            default: actual_taken = 1'b0;
        endcase

        if ((in_bus.issue.uop.dec.branch_op == BR_JUMP)
            && in_bus.issue.uop.dec.use_rs1)
            branch_target = (in_bus.rs1_value + in_bus.issue.uop.dec.imm)
                          & 32'hffff_fffe;
        else
            branch_target = in_bus.issue.uop.dec.pc + in_bus.issue.uop.dec.imm;

        actual_next_pc = actual_taken
                       ? branch_target : (in_bus.issue.uop.dec.pc + 32'd4);
        redirect_needed = (actual_taken != in_bus.issue.uop.dec.pred_taken)
                       || (actual_taken
                           && (branch_target
                               != in_bus.issue.uop.dec.pred_target));

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
                result_reg.rob_tag         <= in_bus.issue.rob_tag;
                result_reg.pdst_valid      <= in_bus.issue.uop.pdst_valid;
                result_reg.pdst            <= in_bus.issue.uop.pdst;
                result_reg.data            <= in_bus.issue.uop.dec.pc + 32'd4;
                result_reg.redirect_valid  <= redirect_needed;
                result_reg.redirect_target <= actual_next_pc;
            end
        end
    end

endmodule
