`timescale 1ns/1ps

import core_types_pkg::*;

// Registered allocator and lifetime tracker for speculative branch checkpoints.
//
// The RAT, Free List, and LSQ keep their own checkpoint payloads indexed by the
// ID allocated here. This module owns the common lifetime and the ROB restore
// tail needed when a branch mispredict is broadcast.
module branch_checkpoint_file (
    input  logic                         clk_i,
    input  logic                         rst_i,

    input  logic                         alloc_req_i,
    output logic                         alloc_valid_o,
    output logic [CP_W-1:0]              alloc_checkpoint_id_o,
    input  logic                         alloc_fire_i,
    input  logic                         alloc_cancel_i,
    input  logic [ROB_ID_W-1:0]          save_rob_tail_i,
    input  logic [CHECKPOINTS-1:0]       save_parent_mask_i,

    input  logic                         checkpoint_clear_i,
    input  logic [CP_W-1:0]              checkpoint_clear_id_i,

    input  recovery_t                    recovery_i,
    output logic                         branch_restore_valid_o,
    output logic [ROB_ID_W-1:0]          branch_restore_rob_tail_o,
    input  logic                         branch_recovery_complete_i,

    input  logic                         exception_flush_i,

    output logic                         busy_o,
    output logic                         full_o,
    output logic [$clog2(CHECKPOINTS+1)-1:0] active_count_o
);

  localparam int COUNT_W = $clog2(CHECKPOINTS + 1);

  logic [CHECKPOINTS-1:0] active_q;
  logic [CHECKPOINTS-1:0] parent_mask_q [0:CHECKPOINTS-1];
  logic [ROB_ID_W-1:0] rob_tail_q [0:CHECKPOINTS-1];

  logic reservation_valid_q;
  logic [CP_W-1:0] reservation_id_q;

  logic recovery_pending_q;
  logic [CP_W-1:0] recovery_id_q;
  logic [CHECKPOINTS-1:0] recovery_release_mask_q;
  logic save_pending_q;
  logic [CP_W-1:0] save_id_q;
  logic [ROB_ID_W-1:0] save_rob_tail_q;
  logic [CHECKPOINTS-1:0] save_parent_mask_q;

  logic candidate_valid;
  logic [CP_W-1:0] candidate_id;
  logic [CHECKPOINTS-1:0] unavailable_mask;

  always_comb begin : candidate_select
    candidate_valid = 1'b0;
    candidate_id = '0;
    unavailable_mask = active_q;
    if (reservation_valid_q)
      unavailable_mask[reservation_id_q] = 1'b1;
    if (save_pending_q)
      unavailable_mask[save_id_q] = 1'b1;

    for (int idx = 0; idx < CHECKPOINTS; idx = idx + 1) begin
      if (!candidate_valid && !unavailable_mask[idx]) begin
        candidate_valid = 1'b1;
        candidate_id = CP_W'(idx);
      end
    end
  end

  always_comb begin : active_counter
    active_count_o = '0;
    for (int idx = 0; idx < CHECKPOINTS; idx = idx + 1)
      active_count_o = active_count_o + COUNT_W'(active_q[idx]);
  end

  assign alloc_valid_o = reservation_valid_q && !recovery_pending_q;
  assign alloc_checkpoint_id_o = reservation_id_q;
  assign busy_o = recovery_pending_q;
  assign full_o = &unavailable_mask;

  assign branch_restore_valid_o = recovery_i.valid &&
      (recovery_i.cause == REC_BRANCH) &&
      active_q[recovery_i.checkpoint_id] && !recovery_pending_q;
  assign branch_restore_rob_tail_o =
      rob_tail_q[recovery_i.checkpoint_id];

  always_ff @(posedge clk_i) begin : checkpoint_state
    integer idx;
    logic [CHECKPOINTS-1:0] release_mask;

    if (rst_i) begin
      active_q <= '0;
      reservation_valid_q <= 1'b0;
      reservation_id_q <= '0;
      recovery_pending_q <= 1'b0;
      recovery_id_q <= '0;
      recovery_release_mask_q <= '0;
      save_pending_q <= 1'b0;
      save_id_q <= '0;
      save_rob_tail_q <= '0;
      save_parent_mask_q <= '0;
      for (idx = 0; idx < CHECKPOINTS; idx = idx + 1) begin
        parent_mask_q[idx] <= '0;
        rob_tail_q[idx] <= '0;
      end
    end else if (exception_flush_i) begin
      active_q <= '0;
      reservation_valid_q <= 1'b0;
      recovery_pending_q <= 1'b0;
      recovery_release_mask_q <= '0;
      save_pending_q <= 1'b0;
      for (idx = 0; idx < CHECKPOINTS; idx = idx + 1)
        parent_mask_q[idx] <= '0;
    end else begin
      if (save_pending_q && !recovery_i.valid) begin
        active_q[save_id_q] <= 1'b1;
        parent_mask_q[save_id_q] <= save_parent_mask_q;
        rob_tail_q[save_id_q] <= save_rob_tail_q;
        save_pending_q <= 1'b0;
      end

      if (branch_recovery_complete_i && recovery_pending_q) begin
        active_q <= active_q & ~recovery_release_mask_q;
        recovery_pending_q <= 1'b0;
        recovery_release_mask_q <= '0;
        for (idx = 0; idx < CHECKPOINTS; idx = idx + 1) begin
          if (recovery_release_mask_q[idx])
            parent_mask_q[idx] <= '0;
        end
      end else if (branch_restore_valid_o) begin
        release_mask = '0;
        save_pending_q <= 1'b0;
        for (idx = 0; idx < CHECKPOINTS; idx = idx + 1) begin
          if (active_q[idx] &&
              ((CP_W'(idx) == recovery_i.checkpoint_id) ||
               parent_mask_q[idx][recovery_i.checkpoint_id]))
            release_mask[idx] = 1'b1;
        end
        recovery_pending_q <= 1'b1;
        recovery_id_q <= recovery_i.checkpoint_id;
        recovery_release_mask_q <= release_mask;
        reservation_valid_q <= 1'b0;
      end else if (checkpoint_clear_i && active_q[checkpoint_clear_id_i]) begin
        active_q[checkpoint_clear_id_i] <= 1'b0;
        parent_mask_q[checkpoint_clear_id_i] <= '0;
        for (idx = 0; idx < CHECKPOINTS; idx = idx + 1)
          parent_mask_q[idx][checkpoint_clear_id_i] <= 1'b0;
      end

      if (!recovery_pending_q && !branch_restore_valid_o) begin
        if (alloc_cancel_i) begin
          reservation_valid_q <= 1'b0;
        end else if (alloc_fire_i && reservation_valid_q) begin
          save_pending_q <= 1'b1;
          save_id_q <= reservation_id_q;
          save_rob_tail_q <= save_rob_tail_i;
          save_parent_mask_q <= save_parent_mask_i;
          if (checkpoint_clear_i)
            save_parent_mask_q[checkpoint_clear_id_i] <= 1'b0;
          reservation_valid_q <= 1'b0;
        end else if (!reservation_valid_q && alloc_req_i && candidate_valid) begin
          reservation_valid_q <= 1'b1;
          reservation_id_q <= candidate_id;
        end
      end
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk_i) begin : checkpoint_assertions
    if (!rst_i) begin
      assert (!(alloc_fire_i && alloc_cancel_i))
        else $error("checkpoint allocation fire and cancel overlap");

      if (alloc_fire_i)
        assert (reservation_valid_q)
          else $error("checkpoint allocation fired without a reservation");

      if (branch_recovery_complete_i)
        assert (recovery_pending_q)
          else $error("checkpoint recovery completed without pending recovery");

      if (branch_restore_valid_o)
        assert (!parent_mask_q[recovery_i.checkpoint_id]
                              [recovery_i.checkpoint_id])
          else $error("checkpoint cannot be its own parent");

      if (recovery_pending_q)
        assert (recovery_release_mask_q[recovery_id_q])
          else $error("pending recovery does not release its source checkpoint");
    end
  end
`endif

endmodule
