`timescale 1ns/1ps

import core_types_pkg::*;

// P2 integration boundary: Decode -> Rename -> atomic resource allocation ->
// Dispatch, with ROB allocation/completion/retirement and recovery connected.
module rename_rob_cluster (
    input  logic                         clk_i,
    input  logic                         rst_i,

    input  logic [1:0]                   dec_valid_i,
    output logic                         dec_ready_o,
    input  decoded_uop_t                 dec_uop0_i,
    input  decoded_uop_t                 dec_uop1_i,

    output logic [1:0]                   dispatch_valid_o,
    input  logic                         dispatch_ready_i,
    output renamed_uop_t                 dispatch_uop0_o,
    output renamed_uop_t                 dispatch_uop1_o,
    output logic                         dispatch_fire_o,

    input  commit_map_t                  commit_map0_i,
    input  commit_map_t                  commit_map1_i,
    input  logic [1:0]                   reclaim_valid_i,
    input  logic [PRD_W-1:0]             reclaim_prd0_i,
    input  logic [PRD_W-1:0]             reclaim_prd1_i,
    output logic                         reclaim_ready_o,

    input  logic [1:0]                   wb_ready_valid_i,
    input  logic [PRD_W-1:0]             wb_ready_prd0_i,
    input  logic [PRD_W-1:0]             wb_ready_prd1_i,
    input  completion_t                  complete0_i,
    input  completion_t                  complete1_i,

    input  logic [1:0]                   lq_release_valid_i,
    input  logic [1:0][LQ_ID_W-1:0]      lq_release_id_i,
    input  logic [1:0]                   sq_release_valid_i,
    input  logic [1:0][SQ_ID_W-1:0]      sq_release_id_i,

    output logic [1:0]                   rob_head_valid_o,
    output rob_entry_t                   rob_head0_o,
    output rob_entry_t                   rob_head1_o,
    input  logic [1:0]                   retire_count_i,

    input  logic                         checkpoint_clear_i,
    input  logic [CP_W-1:0]              checkpoint_clear_id_i,
    output logic                         rob_branch_clear_done_o,
    input  recovery_t                    recovery_i,
    input  logic                         branch_recovery_complete_i,
    output logic [3:0]                   recovery_done_o,

    output logic [5:0]                   rob_occupancy_o,
    output logic                         rob_empty_o,
    output logic                         rob_full_o,
    output logic [6:0]                   free_prd_count_o,
    output logic [3:0]                   free_lq_count_o,
    output logic [3:0]                   free_sq_count_o,
    output logic [$clog2(CHECKPOINTS+1)-1:0] active_checkpoint_count_o,
    output logic                         busy_o,
    output logic                         rob_busy_o
);

  alloc_req_t alloc_req;
  alloc_resp_t alloc_resp;
  logic alloc_fire;
  logic alloc_cancel;
  logic alloc_commit_ready;
  logic rename_ready;
  logic [1:0] rename_valid;
  renamed_uop_t rename_uop0;
  renamed_uop_t rename_uop1;
  logic rename_recovery_done;
  logic [PRD_W-1:0] amt_map [0:ARCH_REGS-1];

  logic [1:0] rob_alloc_valid;
  logic rob_alloc_ready;
  logic rob_alloc_ready_for_alloc;
  logic [ROB_ID_W-1:0] rob_alloc_id0;
  logic [ROB_ID_W-1:0] rob_alloc_id1;
  rob_alloc_t rob_alloc_entry0;
  rob_alloc_t rob_alloc_entry1;

  logic branch_restore_valid;
  logic [ROB_ID_W-1:0] branch_restore_tail;
  logic rob_restore_valid_q;
  logic [ROB_ID_W-1:0] rob_restore_tail_q;
  logic rob_exception_flush_q;
  logic free_list_branch_done;
  logic lsq_branch_done;
  logic free_list_rebuild_done;
  logic lsq_exception_done;
  logic allocation_busy;
  logic rob_busy;
  logic rob_restore_done;
  logic rob_exception_done;

  recovery_cause_t recovery_cause_q;
  logic [3:0] recovery_ack_q;
  logic [3:0] selected_recovery_done;
  logic exception_recovery;

  function automatic logic is_store(input renamed_uop_t uop);
    is_store = (uop.dec.fu_type == FU_LSU) && (uop.dec.mem_op >= MEM_SB);
  endfunction

  function automatic logic is_load(input renamed_uop_t uop);
    is_load = (uop.dec.fu_type == FU_LSU) && (uop.dec.mem_op <= MEM_LHU);
  endfunction

  function automatic rob_alloc_t make_rob_entry(input renamed_uop_t uop);
    rob_alloc_t entry;
    begin
      entry = '0;
      entry.arch_rd = uop.dec.rd;
      entry.new_prd = uop.prd;
      entry.old_prd = uop.old_prd;
      entry.write_rd = uop.dec.write_rd;
      entry.is_load = is_load(uop);
      entry.lq_id = uop.lq_id;
      entry.is_store = is_store(uop);
      entry.sq_id = uop.sq_id;
      entry.is_branch = (uop.dec.fu_type == FU_BRANCH);
      entry.checkpoint_id = uop.checkpoint_id;
      entry.branch_mask = uop.branch_mask;
      entry.serializing = uop.dec.serializing;
      entry.is_csr = (uop.dec.fu_type == FU_CSR) &&
                     !uop.dec.is_ecall && !uop.dec.is_ebreak &&
                     !uop.dec.is_mret && !uop.dec.is_fence;
      entry.csr_op = uop.dec.csr_op;
      entry.csr_addr = uop.dec.csr_addr;
      entry.csr_zimm = uop.dec.csr_zimm;
      entry.csr_operand = '0;
      entry.is_ecall = uop.dec.is_ecall;
      entry.is_ebreak = uop.dec.is_ebreak;
      entry.is_mret = uop.dec.is_mret;
      entry.is_fence = uop.dec.is_fence;
      entry.inst = uop.dec.inst;
      entry.exception_valid = uop.dec.exception_valid;
      entry.exception_cause = uop.dec.exception_cause;
      entry.exception_tval = uop.dec.exception_tval;
      entry.pc = uop.dec.pc;
      make_rob_entry = entry;
    end
  endfunction

  assign rename_ready = dispatch_ready_i && alloc_commit_ready;
  assign dispatch_valid_o = alloc_commit_ready ? rename_valid : 2'b00;
  assign dispatch_uop0_o = rename_uop0;
  assign dispatch_uop1_o = rename_uop1;
  assign dispatch_fire_o = (rename_valid != 2'b00) && rename_ready;
  assign rob_alloc_entry0 = make_rob_entry(dispatch_uop0_o);
  assign rob_alloc_entry1 = make_rob_entry(dispatch_uop1_o);
  assign exception_recovery = recovery_i.valid &&
                              (recovery_i.cause == REC_EXCEPT);
  assign rob_alloc_ready_for_alloc = rob_alloc_ready && !checkpoint_clear_i;
  assign busy_o = allocation_busy || rob_busy;
  assign rob_busy_o = rob_busy;

  always_comb begin : recovery_done_select
    selected_recovery_done = '0;
    selected_recovery_done[0] = rename_recovery_done;
    if (recovery_cause_q == REC_BRANCH) begin
      selected_recovery_done[1] = free_list_branch_done;
      selected_recovery_done[2] = lsq_branch_done;
      selected_recovery_done[3] = rob_restore_done;
    end else if (recovery_cause_q == REC_EXCEPT) begin
      selected_recovery_done[1] = free_list_rebuild_done;
      selected_recovery_done[2] = lsq_exception_done;
      selected_recovery_done[3] = rob_exception_done;
    end
  end

  assign recovery_done_o = recovery_ack_q | selected_recovery_done;

  always_ff @(posedge clk_i) begin : recovery_ack_state
    if (rst_i) begin
      recovery_cause_q <= REC_NONE;
      recovery_ack_q <= '0;
    end else if (recovery_i.valid) begin
      recovery_cause_q <= recovery_i.cause;
      recovery_ack_q <= '0;
    end else begin
      recovery_ack_q <= recovery_ack_q | selected_recovery_done;
    end
  end

  always_ff @(posedge clk_i) begin : rob_recovery_input_slice
    if (rst_i) begin
      rob_restore_valid_q <= 1'b0;
      rob_restore_tail_q <= '0;
      rob_exception_flush_q <= 1'b0;
    end else begin
      rob_restore_valid_q <= branch_restore_valid;
      rob_exception_flush_q <= exception_recovery;
      if (branch_restore_valid)
        rob_restore_tail_q <= branch_restore_tail;
    end
  end

  rename_stage u_rename_stage (
      .clk_i,
      .rst_i,
      .dec_valid_i,
      .dec_ready_o,
      .dec_uop0_i,
      .dec_uop1_i,
      .rn_valid_o(rename_valid),
      .rn_ready_i(rename_ready),
      .rn_uop0_o(rename_uop0),
      .rn_uop1_o(rename_uop1),
      .alloc_req_o(alloc_req),
      .alloc_resp_i(alloc_resp),
      .alloc_fire_o(alloc_fire),
      .alloc_cancel_o(alloc_cancel),
      .commit_map0_i,
      .commit_map1_i,
      .wb_ready_valid_i,
      .wb_ready_prd0_i,
      .wb_ready_prd1_i,
      .amt_map_o(amt_map),
      .checkpoint_clear_i,
      .checkpoint_clear_id_i,
      .recovery_i,
      .recovery_done_o(rename_recovery_done)
  );

  rename_allocation_cluster u_allocation_cluster (
      .clk_i,
      .rst_i,
      .alloc_req_i(alloc_req),
      .alloc_resp_o(alloc_resp),
      .alloc_commit_ready_o(alloc_commit_ready),
      .alloc_fire_i(alloc_fire),
      .alloc_cancel_i(alloc_cancel),
      .rename_valid_i(dispatch_valid_o),
      .rename_uop0_i(dispatch_uop0_o),
      .rename_uop1_i(dispatch_uop1_o),
      .rob_alloc_ready_i(rob_alloc_ready_for_alloc),
      .rob_alloc_id0_i(rob_alloc_id0),
      .rob_alloc_id1_i(rob_alloc_id1),
      .rob_alloc_valid_o(rob_alloc_valid),
      .reclaim_valid_i,
      .reclaim_prd0_i,
      .reclaim_prd1_i,
      .reclaim_ready_o,
      .lq_release_valid_i,
      .lq_release_id_i,
      .sq_release_valid_i,
      .sq_release_id_i,
      .checkpoint_clear_i,
      .checkpoint_clear_id_i,
      .recovery_i,
      .branch_recovery_complete_i,
      .amt_map_i(amt_map),
      .branch_restore_valid_o(branch_restore_valid),
      .branch_restore_rob_tail_o(branch_restore_tail),
      .free_list_branch_done_o(free_list_branch_done),
      .lsq_branch_done_o(lsq_branch_done),
      .free_list_rebuild_done_o(free_list_rebuild_done),
      .lsq_exception_done_o(lsq_exception_done),
      .free_prd_count_o,
      .free_lq_count_o,
      .free_sq_count_o,
      .active_checkpoint_count_o,
      .busy_o(allocation_busy)
  );

  reorder_buffer u_reorder_buffer (
      .clk_i,
      .rst_i,
      .alloc_valid_i(rob_alloc_valid),
      .alloc_ready_o(rob_alloc_ready),
      .alloc_rob_id0_o(rob_alloc_id0),
      .alloc_rob_id1_o(rob_alloc_id1),
      .alloc_entry0_i(rob_alloc_entry0),
      .alloc_entry1_i(rob_alloc_entry1),
      .complete0_i,
      .complete1_i,
      .head_valid_o(rob_head_valid_o),
      .head_entry0_o(rob_head0_o),
      .head_entry1_o(rob_head1_o),
      .retire_count_i,
      .exception_flush_i(rob_exception_flush_q),
      .exception_flush_done_o(rob_exception_done),
      .branch_clear_valid_i(checkpoint_clear_i),
      .branch_clear_id_i(checkpoint_clear_id_i),
      .branch_clear_done_o(rob_branch_clear_done_o),
      .restore_valid_i(rob_restore_valid_q),
      .restore_tail_i(rob_restore_tail_q),
      .restore_done_o(rob_restore_done),
      .busy_o(rob_busy),
      .empty_o(rob_empty_o),
      .full_o(rob_full_o),
      .occupancy_o(rob_occupancy_o)
  );

`ifndef SYNTHESIS
  always_ff @(posedge clk_i) begin : cluster_assertions
    if (!rst_i) begin
      if (dispatch_fire_o)
        assert (rob_alloc_valid == dispatch_valid_o)
          else $error("Rename/ROB allocation fire lost atomicity");

      if (rob_alloc_valid != 2'b00)
        assert (dispatch_fire_o)
          else $error("ROB allocated without Rename dispatch fire");
    end
  end
`endif

endmodule
