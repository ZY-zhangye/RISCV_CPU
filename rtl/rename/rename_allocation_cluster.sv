`timescale 1ns/1ps

import core_types_pkg::*;

// Rename-side allocation cluster. All speculative resources share one
// reservation response and one final fire/cancel boundary.
module rename_allocation_cluster (
    input  logic                         clk_i,
    input  logic                         rst_i,

    input  alloc_req_t                   alloc_req_i,
    output alloc_resp_t                  alloc_resp_o,
    output logic                         alloc_commit_ready_o,
    input  logic                         alloc_fire_i,
    input  logic                         alloc_cancel_i,
    input  logic [1:0]                   rename_valid_i,
    input  renamed_uop_t                 rename_uop0_i,
    input  renamed_uop_t                 rename_uop1_i,

    input  logic                         rob_alloc_ready_i,
    input  logic [ROB_ID_W-1:0]          rob_alloc_id0_i,
    input  logic [ROB_ID_W-1:0]          rob_alloc_id1_i,
    output logic [1:0]                   rob_alloc_valid_o,

    input  logic [1:0]                   reclaim_valid_i,
    input  logic [PRD_W-1:0]             reclaim_prd0_i,
    input  logic [PRD_W-1:0]             reclaim_prd1_i,
    output logic                         reclaim_ready_o,

    input  logic [1:0]                   lq_release_valid_i,
    input  logic [1:0][LQ_ID_W-1:0]      lq_release_id_i,
    input  logic [1:0]                   sq_release_valid_i,
    input  logic [1:0][SQ_ID_W-1:0]      sq_release_id_i,

    input  logic                         checkpoint_clear_i,
    input  logic [CP_W-1:0]              checkpoint_clear_id_i,
    input  recovery_t                    recovery_i,
    input  logic                         branch_recovery_complete_i,
    input  logic [PRD_W-1:0]             amt_map_i [0:ARCH_REGS-1],

    output logic                         branch_restore_valid_o,
    output logic [ROB_ID_W-1:0]          branch_restore_rob_tail_o,
    output logic                         free_list_branch_done_o,
    output logic                         lsq_branch_done_o,
    output logic                         free_list_rebuild_done_o,
    output logic                         lsq_exception_done_o,

    output logic [6:0]                   free_prd_count_o,
    output logic [3:0]                   free_lq_count_o,
    output logic [3:0]                   free_sq_count_o,
    output logic [$clog2(CHECKPOINTS+1)-1:0] active_checkpoint_count_o,
    output logic                         busy_o
);

  logic [1:0] free_alloc_count;
  logic free_alloc_valid;
  logic [PRD_W-1:0] free_alloc_prd0;
  logic [PRD_W-1:0] free_alloc_prd1;
  logic free_alloc_fire;
  logic free_alloc_cancel;

  logic [1:0] lsq_alloc_lq_count;
  logic [1:0] lsq_alloc_sq_count;
  logic lsq_alloc_valid;
  logic [1:0][LQ_ID_W-1:0] lsq_alloc_lq_id;
  logic [1:0][SQ_ID_W-1:0] lsq_alloc_sq_id;
  logic lsq_alloc_fire;
  logic lsq_alloc_cancel;

  logic checkpoint_alloc_req;
  logic checkpoint_alloc_valid;
  logic [CP_W-1:0] checkpoint_alloc_id;
  logic checkpoint_alloc_fire;
  logic checkpoint_alloc_cancel;

  logic manager_busy;
  logic free_list_busy;
  logic lsq_busy;
  logic checkpoint_busy;
  logic checkpoint_full;

  logic branch_checkpoint_save;
  logic branch_is_lane1;
  logic [CP_W-1:0] branch_checkpoint_id;
  logic [ROB_ID_W-1:0] branch_rob_tail;
  logic [CHECKPOINTS-1:0] branch_parent_mask;
  logic [1:0] checkpoint_keep_prd_count;
  logic [1:0] checkpoint_keep_lq_count;
  logic [1:0] checkpoint_keep_sq_count;
  logic branch_restore_start;
  logic exception_recovery;
  logic checkpoint_clear_pending_q;
  logic [CP_W-1:0] checkpoint_clear_id_q;
  logic checkpoint_clear_children;
  logic allocation_recovery_busy;

  function automatic logic is_load(input renamed_uop_t uop);
    is_load = (uop.dec.fu_type == FU_LSU) && (uop.dec.mem_op <= MEM_LHU);
  endfunction

  function automatic logic is_store(input renamed_uop_t uop);
    is_store = (uop.dec.fu_type == FU_LSU) && (uop.dec.mem_op >= MEM_SB);
  endfunction

  assign branch_is_lane1 = rename_valid_i[1] &&
                           (rename_uop1_i.dec.fu_type == FU_BRANCH);
  assign branch_checkpoint_save = checkpoint_alloc_fire;
  assign branch_checkpoint_id = checkpoint_alloc_id;
  assign branch_rob_tail = (branch_is_lane1 ? rob_alloc_id1_i :
                                              rob_alloc_id0_i) + 1'b1;
  assign branch_parent_mask =
      (branch_is_lane1 ? rename_uop1_i.branch_mask :
                         rename_uop0_i.branch_mask) &
      ~({{(CHECKPOINTS-1){1'b0}}, 1'b1} << branch_checkpoint_id);

  always_comb begin : checkpoint_keep_counts
    checkpoint_keep_prd_count = '0;
    checkpoint_keep_lq_count = '0;
    checkpoint_keep_sq_count = '0;

    if (rename_valid_i[0]) begin
      checkpoint_keep_prd_count = checkpoint_keep_prd_count +
          {1'b0, rename_uop0_i.dec.write_rd};
      checkpoint_keep_lq_count = checkpoint_keep_lq_count +
          {1'b0, is_load(rename_uop0_i)};
      checkpoint_keep_sq_count = checkpoint_keep_sq_count +
          {1'b0, is_store(rename_uop0_i)};
    end

    if (branch_is_lane1 && rename_valid_i[1]) begin
      checkpoint_keep_prd_count = checkpoint_keep_prd_count +
          {1'b0, rename_uop1_i.dec.write_rd};
      checkpoint_keep_lq_count = checkpoint_keep_lq_count +
          {1'b0, is_load(rename_uop1_i)};
      checkpoint_keep_sq_count = checkpoint_keep_sq_count +
          {1'b0, is_store(rename_uop1_i)};
    end
  end

  assign exception_recovery = recovery_i.valid &&
                              (recovery_i.cause == REC_EXCEPT);
  assign branch_restore_start = branch_restore_valid_o;
  assign busy_o = manager_busy || free_list_busy || lsq_busy || checkpoint_busy;
  assign allocation_recovery_busy = recovery_i.valid || free_list_busy ||
                                    lsq_busy || checkpoint_busy ||
                                    exception_recovery;
  assign checkpoint_clear_children = checkpoint_clear_pending_q &&
                                     !allocation_recovery_busy;

  always_ff @(posedge clk_i) begin
    if (rst_i || exception_recovery) begin
      checkpoint_clear_pending_q <= 1'b0;
      checkpoint_clear_id_q <= '0;
    end else begin
      if (checkpoint_clear_children)
        checkpoint_clear_pending_q <= 1'b0;
      if (checkpoint_clear_i) begin
        checkpoint_clear_pending_q <= 1'b1;
        checkpoint_clear_id_q <= checkpoint_clear_id_i;
      end
    end
  end

  rename_resource_manager u_resource_manager (
      .clk_i,
      .rst_i,
      .alloc_req_i,
      .alloc_resp_o,
      .alloc_commit_ready_o,
      .alloc_fire_i,
      .alloc_cancel_i,
      .free_alloc_count_o(free_alloc_count),
      .free_alloc_valid_i(free_alloc_valid),
      .free_alloc_prd0_i(free_alloc_prd0),
      .free_alloc_prd1_i(free_alloc_prd1),
      .free_alloc_fire_o(free_alloc_fire),
      .free_alloc_cancel_o(free_alloc_cancel),
      .lsq_alloc_lq_count_o(lsq_alloc_lq_count),
      .lsq_alloc_sq_count_o(lsq_alloc_sq_count),
      .lsq_alloc_valid_i(lsq_alloc_valid),
      .lsq_alloc_lq_id_i(lsq_alloc_lq_id),
      .lsq_alloc_sq_id_i(lsq_alloc_sq_id),
      .lsq_alloc_fire_o(lsq_alloc_fire),
      .lsq_alloc_cancel_o(lsq_alloc_cancel),
      .checkpoint_alloc_req_o(checkpoint_alloc_req),
      .checkpoint_alloc_valid_i(checkpoint_alloc_valid),
      .checkpoint_alloc_id_i(checkpoint_alloc_id),
      .checkpoint_alloc_fire_o(checkpoint_alloc_fire),
      .checkpoint_alloc_cancel_o(checkpoint_alloc_cancel),
      .rob_alloc_ready_i,
      .rob_alloc_id0_i,
      .rob_alloc_id1_i,
      .rob_alloc_valid_o,
      .busy_o(manager_busy)
  );

  free_list u_free_list (
      .clk_i,
      .rst_i,
      .alloc_count_i(free_alloc_count),
      .alloc_valid_o(free_alloc_valid),
      .alloc_prd0_o(free_alloc_prd0),
      .alloc_prd1_o(free_alloc_prd1),
      .alloc_fire_i(free_alloc_fire),
      .alloc_cancel_i(free_alloc_cancel),
      .reclaim_valid_i,
      .reclaim_prd0_i,
      .reclaim_prd1_i,
      .reclaim_ready_o,
      .checkpoint_save_i(branch_checkpoint_save),
      .checkpoint_id_i(branch_checkpoint_id),
      .checkpoint_keep_count_i(checkpoint_keep_prd_count),
      .checkpoint_clear_i(checkpoint_clear_children),
      .checkpoint_clear_id_i(checkpoint_clear_id_q),
      .branch_restore_i(branch_restore_start),
      .branch_restore_id_i(recovery_i.checkpoint_id),
      .branch_restore_done_o(free_list_branch_done_o),
      .rebuild_start_i(exception_recovery),
      .amt_map_i,
      .busy_o(free_list_busy),
      .rebuild_done_o(free_list_rebuild_done_o),
      .free_count_o(free_prd_count_o)
  );

  lsq_allocator u_lsq_allocator (
      .clk_i,
      .rst_i,
      .alloc_lq_count_i(lsq_alloc_lq_count),
      .alloc_sq_count_i(lsq_alloc_sq_count),
      .alloc_valid_o(lsq_alloc_valid),
      .alloc_lq_id_o(lsq_alloc_lq_id),
      .alloc_sq_id_o(lsq_alloc_sq_id),
      .alloc_fire_i(lsq_alloc_fire),
      .alloc_cancel_i(lsq_alloc_cancel),
      .lq_release_valid_i,
      .lq_release_id_i,
      .sq_release_valid_i,
      .sq_release_id_i,
      .checkpoint_save_i(branch_checkpoint_save),
      .checkpoint_id_i(branch_checkpoint_id),
      .checkpoint_keep_lq_count_i(checkpoint_keep_lq_count),
      .checkpoint_keep_sq_count_i(checkpoint_keep_sq_count),
      .checkpoint_clear_i(checkpoint_clear_children),
      .checkpoint_clear_id_i(checkpoint_clear_id_q),
      .branch_restore_i(branch_restore_start),
      .branch_restore_id_i(recovery_i.checkpoint_id),
      .branch_restore_done_o(lsq_branch_done_o),
      .exception_flush_i(exception_recovery),
      .exception_flush_done_o(lsq_exception_done_o),
      .busy_o(lsq_busy),
      .lq_free_count_o(free_lq_count_o),
      .sq_free_count_o(free_sq_count_o)
  );

  branch_checkpoint_file u_checkpoint_file (
      .clk_i,
      .rst_i,
      .alloc_req_i(checkpoint_alloc_req),
      .alloc_valid_o(checkpoint_alloc_valid),
      .alloc_checkpoint_id_o(checkpoint_alloc_id),
      .alloc_fire_i(checkpoint_alloc_fire),
      .alloc_cancel_i(checkpoint_alloc_cancel),
      .save_rob_tail_i(branch_rob_tail),
      .save_parent_mask_i(branch_parent_mask),
      .checkpoint_clear_i(checkpoint_clear_children),
      .checkpoint_clear_id_i(checkpoint_clear_id_q),
      .recovery_i,
      .branch_restore_valid_o,
      .branch_restore_rob_tail_o,
      .branch_recovery_complete_i,
      .exception_flush_i(exception_recovery),
      .busy_o(checkpoint_busy),
      .full_o(checkpoint_full),
      .active_count_o(active_checkpoint_count_o)
  );

`ifndef SYNTHESIS
  always_ff @(posedge clk_i) begin : cluster_assertions
    if (!rst_i) begin
      if (branch_checkpoint_save) begin
        assert ((rename_valid_i[0] &&
                 (rename_uop0_i.dec.fu_type == FU_BRANCH)) ||
                (rename_valid_i[1] &&
                 (rename_uop1_i.dec.fu_type == FU_BRANCH)))
          else $error("checkpoint allocated without a branch uop");
        assert (branch_checkpoint_id == checkpoint_alloc_id)
          else $error("branch checkpoint ID differs from reserved ID");
      end

      if (alloc_fire_i)
        assert (alloc_commit_ready_o)
          else $error("allocation cluster fired while resources were not ready");
    end
  end
`endif

endmodule
