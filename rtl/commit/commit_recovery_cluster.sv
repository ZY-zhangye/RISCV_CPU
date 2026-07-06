`timescale 1ns/1ps

import core_types_pkg::*;

// Full retirement and recovery integration boundary. It closes ROB head
// commit, AMT/reclaim feedback, CSR-to-PRF commit write, branch/exception
// recovery broadcast, sticky Rename/ROB acknowledgements, and final redirect.
module commit_recovery_cluster #(
    parameter logic [XLEN-1:0] HART_ID = '0,
    parameter logic [XLEN-1:0] RESET_MTVEC = RESET_PC
) (
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

    input  completion_t                  complete0_i,
    input  completion_t                  complete1_i,
    input  logic [1:0]                   lq_release_valid_i,
    input  logic [1:0][LQ_ID_W-1:0]      lq_release_id_i,
    input  logic [1:0]                   sq_release_valid_i,
    input  logic [1:0][SQ_ID_W-1:0]      sq_release_id_i,

    input  branch_resolve_t              branch_i,
    output recovery_t                    recovery_o,
    output logic                         checkpoint_clear_valid_o,
    output logic [CP_W-1:0]              checkpoint_clear_id_o,
    output logic                         redirect_valid_o,
    output logic [XLEN-1:0]              redirect_pc_o,

    input  logic [5:0]                   prf_read_valid_i,
    input  logic [5:0][PRD_W-1:0]        prf_read_prd_i,
    output logic [5:0][XLEN-1:0]         prf_read_data_o,
    input  logic [1:0]                   wb_valid_i,
    input  logic [1:0][PRD_W-1:0]        wb_prd_i,
    input  logic [1:0][XLEN-1:0]         wb_data_i,
    output logic [PHYS_REGS-1:0]         prf_ready_bits_o,

    output logic                         store_commit_valid_o,
    output logic [SQ_ID_W-1:0]           store_commit_sq_id_o,
    input  logic                         store_commit_ready_i,
    input  logic                         store_commit_done_i,

    output logic [1:0]                   retire_count_o,
    output logic [5:0]                   rob_occupancy_o,
    output logic                         rob_empty_o,
    output logic                         rob_full_o,
    output logic [6:0]                   free_prd_count_o,
    output logic [3:0]                   free_lq_count_o,
    output logic [3:0]                   free_sq_count_o,
    output logic [$clog2(CHECKPOINTS+1)-1:0]
                                             active_checkpoint_count_o,
    output logic                         recovery_busy_o,
    output logic                         busy_o,
    output logic [XLEN-1:0]              mstatus_o,
    output logic [XLEN-1:0]              mtvec_o,
    output logic [XLEN-1:0]              mepc_o,
    output logic [XLEN-1:0]              mcause_o,
    output logic [XLEN-1:0]              mtval_o
);

  commit_map_t commit_map0_raw;
  commit_map_t commit_map1_raw;
  commit_map_t commit_map0_q;
  commit_map_t commit_map1_q;
  commit_map_t commit_map0_commit;
  commit_map_t commit_map1_commit;
  logic [1:0] reclaim_valid_raw;
  logic [1:0] reclaim_valid_q;
  logic [1:0] reclaim_valid_offer;
  logic [1:0][PRD_W-1:0] reclaim_prd_raw;
  logic [1:0][PRD_W-1:0] reclaim_prd_q;
  logic [1:0][PRD_W-1:0] reclaim_prd_commit;
  logic reclaim_ready;
  logic [1:0] rob_head_valid;
  rob_entry_t rob_head0;
  rob_entry_t rob_head1;
  logic [3:0] rename_recovery_done;
  logic rename_busy;
  logic rob_branch_clear_done;
  recovery_t commit_recovery;
  recovery_t commit_recovery_q;
  logic [1:0] instret_count;
  logic store_pending;
  logic [1:0] retire_count_raw;
  logic [1:0] retire_count_q;
  logic commit_txn_pending_q;
  logic commit_txn_fire;
  logic reclaim_drain_pending_q;
  logic csr_wb_pending;
  logic commit_hold;
  logic [1:0] alloc_clear_valid;
  logic [1:0][PRD_W-1:0] alloc_clear_prd;
  recovery_cause_t active_recovery_cause_q;
  logic branch_recovery_complete;

  assign alloc_clear_valid[0] = dispatch_fire_o && dispatch_valid_o[0] &&
      dispatch_uop0_o.dec.write_rd && (dispatch_uop0_o.prd != '0);
  assign alloc_clear_valid[1] = dispatch_fire_o && dispatch_valid_o[1] &&
      dispatch_uop1_o.dec.write_rd && (dispatch_uop1_o.prd != '0);
  assign alloc_clear_prd[0] = dispatch_uop0_o.prd;
  assign alloc_clear_prd[1] = dispatch_uop1_o.prd;

  assign branch_recovery_complete = redirect_valid_o &&
      (active_recovery_cause_q == REC_BRANCH);
  assign commit_txn_fire = commit_txn_pending_q &&
      ((reclaim_valid_q == 2'b00) || reclaim_ready);
  assign retire_count_o = commit_txn_fire ? retire_count_q : 2'd0;
  assign commit_map0_commit = commit_txn_fire ? commit_map0_q : '0;
  assign commit_map1_commit = commit_txn_fire ? commit_map1_q : '0;
  assign reclaim_valid_offer = commit_txn_pending_q ? reclaim_valid_q : '0;
  assign reclaim_prd_commit = reclaim_prd_q;
  assign commit_hold = recovery_busy_o || commit_txn_pending_q ||
                       commit_recovery_q.valid || csr_wb_pending;
  assign busy_o = rename_busy || recovery_busy_o || commit_txn_pending_q ||
                  reclaim_drain_pending_q ||
                  commit_recovery_q.valid || csr_wb_pending ||
                  store_pending;

  // Commit decisions are captured first; the registered transaction updates
  // AMT/reclaim and advances ROB together on the following cycle.
  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      retire_count_q <= '0;
      commit_map0_q <= '0;
      commit_map1_q <= '0;
      reclaim_valid_q <= '0;
      reclaim_prd_q <= '0;
      commit_txn_pending_q <= 1'b0;
      reclaim_drain_pending_q <= 1'b0;
    end else begin
      reclaim_drain_pending_q <= 1'b0;
      if (commit_txn_pending_q) begin
        if (commit_txn_fire) begin
          reclaim_drain_pending_q <= (reclaim_valid_q != 2'b00);
          retire_count_q <= '0;
          commit_map0_q <= '0;
          commit_map1_q <= '0;
          reclaim_valid_q <= '0;
          reclaim_prd_q <= '0;
          commit_txn_pending_q <= 1'b0;
        end
      end else if (retire_count_raw != 0) begin
        retire_count_q <= retire_count_raw;
        commit_map0_q <= commit_map0_raw;
        commit_map1_q <= commit_map1_raw;
        reclaim_valid_q <= reclaim_valid_raw;
        reclaim_prd_q <= reclaim_prd_raw;
        commit_txn_pending_q <= 1'b1;
      end
    end
  end

  // Commit recovery requests are registered before they enter the global
  // broadcaster. This removes the same-cycle path from ROB head metadata
  // through trap/redirect selection back into ROB and PRF recovery state.
  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      commit_recovery_q <= '0;
    end else begin
      if (commit_recovery_q.valid && !recovery_busy_o)
        commit_recovery_q <= '0;
      else if (!commit_recovery_q.valid && commit_recovery.valid)
        commit_recovery_q <= commit_recovery;
    end
  end

  always_ff @(posedge clk_i) begin
    if (rst_i)
      active_recovery_cause_q <= REC_NONE;
    else if (recovery_o.valid)
      active_recovery_cause_q <= recovery_o.cause;
    else if (redirect_valid_o)
      active_recovery_cause_q <= REC_NONE;
  end

  rename_rob_cluster u_rename_rob (
      .clk_i,
      .rst_i,
      .dec_valid_i,
      .dec_ready_o,
      .dec_uop0_i,
      .dec_uop1_i,
      .dispatch_valid_o,
      .dispatch_ready_i,
      .dispatch_uop0_o,
      .dispatch_uop1_o,
      .dispatch_fire_o,
      .commit_map0_i(commit_map0_commit),
      .commit_map1_i(commit_map1_commit),
      .reclaim_valid_i(reclaim_valid_offer),
      .reclaim_prd0_i(reclaim_prd_commit[0]),
      .reclaim_prd1_i(reclaim_prd_commit[1]),
      .reclaim_ready_o(reclaim_ready),
      .wb_ready_valid_i(wb_valid_i),
      .wb_ready_prd0_i(wb_prd_i[0]),
      .wb_ready_prd1_i(wb_prd_i[1]),
      .complete0_i,
      .complete1_i,
      .lq_release_valid_i,
      .lq_release_id_i,
      .sq_release_valid_i,
      .sq_release_id_i,
      .rob_head_valid_o(rob_head_valid),
      .rob_head0_o(rob_head0),
      .rob_head1_o(rob_head1),
      .retire_count_i(retire_count_o),
      .checkpoint_clear_i(checkpoint_clear_valid_o),
      .checkpoint_clear_id_i(checkpoint_clear_id_o),
      .rob_branch_clear_done_o(rob_branch_clear_done),
      .recovery_i(recovery_o),
      .branch_recovery_complete_i(branch_recovery_complete),
      .recovery_done_o(rename_recovery_done),
      .rob_occupancy_o,
      .rob_empty_o,
      .rob_full_o,
      .free_prd_count_o,
      .free_lq_count_o,
      .free_sq_count_o,
      .active_checkpoint_count_o,
      .busy_o(rename_busy)
  );

  commit_csr_prf_cluster #(
      .HART_ID(HART_ID),
      .RESET_MTVEC(RESET_MTVEC)
  ) u_commit_prf (
      .clk_i,
      .rst_i,
      .rob_head_valid_i(rob_head_valid),
      .rob_head0_i(rob_head0),
      .rob_head1_i(rob_head1),
      .retire_count_o(retire_count_raw),
      .commit_map0_o(commit_map0_raw),
      .commit_map1_o(commit_map1_raw),
      .reclaim_valid_o(reclaim_valid_raw),
      .reclaim_prd_o(reclaim_prd_raw),
      .reclaim_ready_i(reclaim_ready),
      .store_commit_valid_o,
      .store_commit_sq_id_o,
      .store_commit_ready_i,
      .store_commit_done_i,
      .prf_read_valid_i,
      .prf_read_prd_i,
      .prf_read_data_o,
      .wb_valid_i,
      .wb_prd_i,
      .wb_data_i,
      .alloc_clear_valid_i(alloc_clear_valid),
      .alloc_clear_prd_i(alloc_clear_prd),
      .prf_ready_bits_o,
      .recovery_o(commit_recovery),
      .instret_count_o(instret_count),
      .store_pending_o(store_pending),
      .csr_wb_pending_o(csr_wb_pending),
      .mstatus_o,
      .mtvec_o,
      .mepc_o,
      .mcause_o,
      .mtval_o,
      .recovery_busy_i(commit_hold)
  );

  recovery_controller #(.ACKS(4)) u_recovery_controller (
      .clk_i,
      .rst_i,
      .branch_i,
      .commit_recovery_i(commit_recovery_q),
      .recovery_done_i(rename_recovery_done),
      .recovery_o,
      .redirect_valid_o,
      .redirect_pc_o,
      .checkpoint_clear_valid_o,
      .checkpoint_clear_id_o,
      .busy_o(recovery_busy_o)
  );

`ifndef SYNTHESIS
  always_ff @(posedge clk_i) begin
    if (!rst_i) begin
      if (redirect_valid_o)
        assert (rename_recovery_done == 4'b1111)
          else $error("redirect issued before Rename/ROB recovery completed");
      if ((reclaim_valid_offer != 2'b00) && !reclaim_ready)
        assert (retire_count_o == 0)
          else $error("ROB retired while Free List reclaim was blocked");
    end
  end
`endif

endmodule
