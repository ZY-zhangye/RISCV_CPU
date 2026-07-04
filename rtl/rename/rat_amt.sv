`timescale 1ns/1ps

import core_types_pkg::*;

module rat_amt (
    input  logic                         clk_i,
    input  logic                         rst_i,

    input  logic [4:0]                   lane0_rs1_i,
    input  logic [4:0]                   lane0_rs2_i,
    input  logic [4:0]                   lane0_rd_i,
    input  logic [4:0]                   lane1_rs1_i,
    input  logic [4:0]                   lane1_rs2_i,
    input  logic [4:0]                   lane1_rd_i,
    output logic [PRD_W-1:0]             lane0_prs1_o,
    output logic [PRD_W-1:0]             lane0_prs2_o,
    output logic [PRD_W-1:0]             lane0_old_prd_o,
    output logic [PRD_W-1:0]             lane1_prs1_o,
    output logic [PRD_W-1:0]             lane1_prs2_o,
    output logic [PRD_W-1:0]             lane1_old_prd_o,
    output logic                         lane0_src1_ready_o,
    output logic                         lane0_src2_ready_o,
    output logic                         lane1_src1_ready_o,
    output logic                         lane1_src2_ready_o,

    input  logic [1:0]                   spec_write_valid_i,
    input  logic [4:0]                   spec_write_rd0_i,
    input  logic [4:0]                   spec_write_rd1_i,
    input  logic [PRD_W-1:0]             spec_write_prd0_i,
    input  logic [PRD_W-1:0]             spec_write_prd1_i,

    input  commit_map_t                  commit_map0_i,
    input  commit_map_t                  commit_map1_i,
    input  logic [1:0]                   wb_ready_valid_i,
    input  logic [PRD_W-1:0]             wb_ready_prd0_i,
    input  logic [PRD_W-1:0]             wb_ready_prd1_i,

    input  logic                         checkpoint_save_i,
    input  logic [CP_W-1:0]              checkpoint_id_i,
    input  logic                         checkpoint_after_lane1_i,
    input  logic                         checkpoint_clear_i,
    input  logic [CP_W-1:0]              checkpoint_clear_id_i,
    output logic [CHECKPOINTS-1:0]        active_branch_mask_o,

    input  recovery_t                    recovery_i,
    output logic                         restore_busy_o,
    output logic                         recovery_done_o
);

  logic [PRD_W-1:0] rat_q [0:ARCH_REGS-1];
  logic [PRD_W-1:0] amt_q [0:ARCH_REGS-1];
  logic [PHYS_REGS-1:0] prd_ready_q;

  logic [PRD_W-1:0] checkpoint_rat_q [0:CHECKPOINTS-1][0:ARCH_REGS-1];
  logic [CHECKPOINTS-1:0] checkpoint_valid_q;
  logic [CHECKPOINTS-1:0] checkpoint_mask_q [0:CHECKPOINTS-1];
  logic [CHECKPOINTS-1:0] active_branch_mask_q;

  logic restore_busy_q;
  logic [4:0] restore_index_q;
  logic recovery_done_q;

  assign lane0_prs1_o = rat_q[lane0_rs1_i];
  assign lane0_prs2_o = rat_q[lane0_rs2_i];
  assign lane0_old_prd_o = rat_q[lane0_rd_i];
  assign lane1_prs1_o = rat_q[lane1_rs1_i];
  assign lane1_prs2_o = rat_q[lane1_rs2_i];
  assign lane1_old_prd_o = rat_q[lane1_rd_i];

  assign lane0_src1_ready_o = prd_ready_q[lane0_prs1_o];
  assign lane0_src2_ready_o = prd_ready_q[lane0_prs2_o];
  assign lane1_src1_ready_o = prd_ready_q[lane1_prs1_o];
  assign lane1_src2_ready_o = prd_ready_q[lane1_prs2_o];

  assign active_branch_mask_o = active_branch_mask_q;
  assign restore_busy_o = restore_busy_q;
  assign recovery_done_o = recovery_done_q;

  always_ff @(posedge clk_i) begin : rat_state
    integer index;
    integer cp_index;

    if (rst_i) begin
      for (index = 0; index < ARCH_REGS; index = index + 1) begin
        rat_q[index] <= index[PRD_W-1:0];
        amt_q[index] <= index[PRD_W-1:0];
      end
      prd_ready_q <= '1;
      checkpoint_valid_q <= '0;
      active_branch_mask_q <= '0;
      restore_busy_q <= 1'b0;
      restore_index_q <= 5'd0;
      recovery_done_q <= 1'b0;
    end else begin
      recovery_done_q <= 1'b0;

      if (recovery_i.valid && (recovery_i.cause == REC_BRANCH)) begin
        if (checkpoint_valid_q[recovery_i.checkpoint_id]) begin
          for (index = 0; index < ARCH_REGS; index = index + 1)
            rat_q[index] <= checkpoint_rat_q[recovery_i.checkpoint_id][index];
          active_branch_mask_q <= checkpoint_mask_q[recovery_i.checkpoint_id];
          checkpoint_valid_q[recovery_i.checkpoint_id] <= 1'b0;
        end
        restore_busy_q <= 1'b0;
        recovery_done_q <= 1'b1;
      end else if (recovery_i.valid && (recovery_i.cause == REC_EXCEPT)) begin
        restore_busy_q <= 1'b1;
        restore_index_q <= 5'd0;
        active_branch_mask_q <= '0;
        checkpoint_valid_q <= '0;
      end else if (restore_busy_q) begin
        rat_q[restore_index_q] <= amt_q[restore_index_q];
        rat_q[restore_index_q + 1'b1] <= amt_q[restore_index_q + 1'b1];
        if (restore_index_q == 5'd30) begin
          restore_busy_q <= 1'b0;
          restore_index_q <= 5'd0;
          recovery_done_q <= 1'b1;
        end else begin
          restore_index_q <= restore_index_q + 5'd2;
        end
      end else begin
        if (commit_map0_i.valid && (commit_map0_i.arch_rd != 0))
          amt_q[commit_map0_i.arch_rd] <= commit_map0_i.prd;
        if (commit_map1_i.valid && (commit_map1_i.arch_rd != 0))
          amt_q[commit_map1_i.arch_rd] <= commit_map1_i.prd;

        if (wb_ready_valid_i[0] && (wb_ready_prd0_i != 0))
          prd_ready_q[wb_ready_prd0_i] <= 1'b1;
        if (wb_ready_valid_i[1] && (wb_ready_prd1_i != 0))
          prd_ready_q[wb_ready_prd1_i] <= 1'b1;

        if (checkpoint_clear_i) begin
          active_branch_mask_q[checkpoint_clear_id_i] <= 1'b0;
          checkpoint_valid_q[checkpoint_clear_id_i] <= 1'b0;
        end

        if (checkpoint_save_i) begin
          cp_index = checkpoint_id_i;
          checkpoint_valid_q[cp_index] <= 1'b1;
          checkpoint_mask_q[cp_index] <= active_branch_mask_q;
          for (index = 0; index < ARCH_REGS; index = index + 1) begin
            checkpoint_rat_q[cp_index][index] <= rat_q[index];
            if (spec_write_valid_i[0] && (spec_write_rd0_i == index) &&
                (spec_write_rd0_i != 0))
              checkpoint_rat_q[cp_index][index] <= spec_write_prd0_i;
            if (checkpoint_after_lane1_i && spec_write_valid_i[1] &&
                (spec_write_rd1_i == index) && (spec_write_rd1_i != 0))
              checkpoint_rat_q[cp_index][index] <= spec_write_prd1_i;
          end
          active_branch_mask_q[cp_index] <= 1'b1;
        end

        if (spec_write_valid_i[0] && (spec_write_rd0_i != 0)) begin
          rat_q[spec_write_rd0_i] <= spec_write_prd0_i;
          prd_ready_q[spec_write_prd0_i] <= 1'b0;
        end
        if (spec_write_valid_i[1] && (spec_write_rd1_i != 0)) begin
          rat_q[spec_write_rd1_i] <= spec_write_prd1_i;
          prd_ready_q[spec_write_prd1_i] <= 1'b0;
        end
      end

      rat_q[0] <= '0;
      amt_q[0] <= '0;
      prd_ready_q[0] <= 1'b1;
    end
  end

`ifdef RAT_AMT_ASSERTIONS
  property p_zero_mapping;
    @(posedge clk_i) rat_q[0] == 0 && amt_q[0] == 0 && prd_ready_q[0];
  endproperty
  assert property (p_zero_mapping);
`endif

endmodule
