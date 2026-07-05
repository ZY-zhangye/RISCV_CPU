`timescale 1ns/1ps

import core_types_pkg::*;

// lsq_allocator.sv
// Registered reservation allocator for the 8-entry Load Queue and Store Queue.
//
// The allocator is deliberately separated from LQ/SQ data arrays:
// - Rename requests 0/1/2 LQ and SQ IDs.
// - Selected IDs are registered and held until alloc_fire_i or alloc_cancel_i.
// - Fire atomically consumes the reservation and appends IDs to allocation logs.
// - Branch checkpoints save log tails; mispredict recovery pops younger IDs
//   from both logs, one LQ and one SQ ID per cycle.
// - Exception flush releases all uncommitted entries.

module lsq_allocator (
    input  logic                       clk_i,
    input  logic                       rst_i,

    input  logic [1:0]                 alloc_lq_count_i,
    input  logic [1:0]                 alloc_sq_count_i,
    output logic                       alloc_valid_o,
    output logic [1:0][LQ_ID_W-1:0]    alloc_lq_id_o,
    output logic [1:0][SQ_ID_W-1:0]    alloc_sq_id_o,
    input  logic                       alloc_fire_i,
    input  logic                       alloc_cancel_i,

    input  logic [1:0]                 lq_release_valid_i,
    input  logic [1:0][LQ_ID_W-1:0]    lq_release_id_i,
    input  logic [1:0]                 sq_release_valid_i,
    input  logic [1:0][SQ_ID_W-1:0]    sq_release_id_i,

    input  logic                       checkpoint_save_i,
    input  logic [CP_W-1:0]            checkpoint_id_i,
    input  logic [1:0]                 checkpoint_keep_lq_count_i,
    input  logic [1:0]                 checkpoint_keep_sq_count_i,
    input  logic                       checkpoint_clear_i,
    input  logic [CP_W-1:0]            checkpoint_clear_id_i,

    input  logic                       branch_restore_i,
    input  logic [CP_W-1:0]            branch_restore_id_i,
    output logic                       branch_restore_done_o,

    input  logic                       exception_flush_i,
    output logic                       exception_flush_done_o,

    output logic                       busy_o,
    output logic [3:0]                 lq_free_count_o,
    output logic [3:0]                 sq_free_count_o
);

  localparam int LOG_PTR_W = LQ_ID_W + 1;

  logic [LQ_ENTRIES-1:0] lq_free_bitmap_q;
  logic [SQ_ENTRIES-1:0] sq_free_bitmap_q;

  logic reservation_valid_q;
  logic [1:0] reservation_lq_count_q;
  logic [1:0] reservation_sq_count_q;
  logic [1:0][LQ_ID_W-1:0] reservation_lq_id_q;
  logic [1:0][SQ_ID_W-1:0] reservation_sq_id_q;

  logic [LQ_ID_W-1:0] lq_allocation_log_q [0:LQ_ENTRIES-1];
  logic [SQ_ID_W-1:0] sq_allocation_log_q [0:SQ_ENTRIES-1];
  logic [LOG_PTR_W-1:0] lq_log_tail_q;
  logic [LOG_PTR_W-1:0] sq_log_tail_q;

  logic [LOG_PTR_W-1:0] checkpoint_lq_tail_q [0:CHECKPOINTS-1];
  logic [LOG_PTR_W-1:0] checkpoint_sq_tail_q [0:CHECKPOINTS-1];
  logic [CHECKPOINTS-1:0] checkpoint_valid_q;

  logic rollback_busy_q;
  logic [LOG_PTR_W-1:0] rollback_lq_target_q;
  logic [LOG_PTR_W-1:0] rollback_sq_target_q;
  logic branch_restore_done_q;
  logic exception_flush_done_q;

  logic [3:0] lq_candidate0;
  logic [3:0] lq_candidate1;
  logic [3:0] sq_candidate0;
  logic [3:0] sq_candidate1;
  logic request_available;

  logic [LOG_PTR_W-1:0] lq_rollback_prev;
  logic [LOG_PTR_W-1:0] sq_rollback_prev;
  logic lq_rollback_last;
  logic sq_rollback_last;

  // --------------------------------------------------------------------------
  // Small fixed-size helper functions
  // --------------------------------------------------------------------------
  function automatic logic [3:0] pick_free(
      input logic [7:0] bitmap,
      input logic       exclude_valid,
      input logic [2:0] exclude_id
  );
    integer idx;
    logic found;
    begin
      pick_free = '0;
      found = 1'b0;
      for (idx = 0; idx < 8; idx = idx + 1) begin
        if (!found && bitmap[idx] &&
            !(exclude_valid && (idx[2:0] == exclude_id))) begin
          pick_free = {1'b1, idx[2:0]};
          found = 1'b1;
        end
      end
    end
  endfunction

  function automatic logic [3:0] popcount8(input logic [7:0] bitmap);
    integer idx;
    begin
      popcount8 = '0;
      for (idx = 0; idx < 8; idx = idx + 1)
        popcount8 = popcount8 + bitmap[idx];
    end
  endfunction

  function automatic logic [LQ_ID_W-1:0] log_index(
      input logic [LOG_PTR_W-1:0] pointer
  );
    log_index = pointer[LQ_ID_W-1:0];
  endfunction

  assign lq_candidate0 = pick_free(lq_free_bitmap_q, 1'b0, '0);
  assign lq_candidate1 = pick_free(lq_free_bitmap_q,
                                   lq_candidate0[3],
                                   lq_candidate0[2:0]);
  assign sq_candidate0 = pick_free(sq_free_bitmap_q, 1'b0, '0);
  assign sq_candidate1 = pick_free(sq_free_bitmap_q,
                                   sq_candidate0[3],
                                   sq_candidate0[2:0]);

  assign lq_free_count_o = popcount8(lq_free_bitmap_q);
  assign sq_free_count_o = popcount8(sq_free_bitmap_q);

  assign request_available =
      (alloc_lq_count_i <= lq_free_count_o) &&
      (alloc_sq_count_i <= sq_free_count_o) &&
      ((alloc_lq_count_i != 2'd1) || lq_candidate0[3]) &&
      ((alloc_lq_count_i != 2'd2) || (lq_candidate0[3] && lq_candidate1[3])) &&
      ((alloc_sq_count_i != 2'd1) || sq_candidate0[3]) &&
      ((alloc_sq_count_i != 2'd2) || (sq_candidate0[3] && sq_candidate1[3]));

  assign alloc_valid_o = reservation_valid_q;
  assign alloc_lq_id_o = reservation_lq_id_q;
  assign alloc_sq_id_o = reservation_sq_id_q;
  assign busy_o = rollback_busy_q;
  assign branch_restore_done_o = branch_restore_done_q;
  assign exception_flush_done_o = exception_flush_done_q;

  assign lq_rollback_prev = lq_log_tail_q - 1'b1;
  assign sq_rollback_prev = sq_log_tail_q - 1'b1;
  assign lq_rollback_last = (lq_rollback_prev == rollback_lq_target_q);
  assign sq_rollback_last = (sq_rollback_prev == rollback_sq_target_q);

  // --------------------------------------------------------------------------
  // Reservation, release and recovery state
  // --------------------------------------------------------------------------
  always_ff @(posedge clk_i) begin : allocator_state
    integer idx;
    if (rst_i) begin
      lq_free_bitmap_q <= '1;
      sq_free_bitmap_q <= '1;
      reservation_valid_q <= 1'b0;
      reservation_lq_count_q <= '0;
      reservation_sq_count_q <= '0;
      reservation_lq_id_q <= '0;
      reservation_sq_id_q <= '0;
      lq_log_tail_q <= '0;
      sq_log_tail_q <= '0;
      checkpoint_valid_q <= '0;
      rollback_busy_q <= 1'b0;
      rollback_lq_target_q <= '0;
      rollback_sq_target_q <= '0;
      branch_restore_done_q <= 1'b0;
      exception_flush_done_q <= 1'b0;
      for (idx = 0; idx < LQ_ENTRIES; idx = idx + 1)
        lq_allocation_log_q[idx] <= '0;
      for (idx = 0; idx < SQ_ENTRIES; idx = idx + 1)
        sq_allocation_log_q[idx] <= '0;
      for (idx = 0; idx < CHECKPOINTS; idx = idx + 1) begin
        checkpoint_lq_tail_q[idx] <= '0;
        checkpoint_sq_tail_q[idx] <= '0;
      end
    end else begin
      branch_restore_done_q <= 1'b0;
      exception_flush_done_q <= 1'b0;

      if (exception_flush_i) begin
        lq_free_bitmap_q <= '1;
        sq_free_bitmap_q <= '1;
        reservation_valid_q <= 1'b0;
        reservation_lq_count_q <= '0;
        reservation_sq_count_q <= '0;
        lq_log_tail_q <= '0;
        sq_log_tail_q <= '0;
        checkpoint_valid_q <= '0;
        rollback_busy_q <= 1'b0;
        exception_flush_done_q <= 1'b1;
      end else if (branch_restore_i && !rollback_busy_q) begin
        reservation_valid_q <= 1'b0;
        reservation_lq_count_q <= '0;
        reservation_sq_count_q <= '0;
        checkpoint_valid_q[branch_restore_id_i] <= 1'b0;
        if (checkpoint_valid_q[branch_restore_id_i] &&
            ((lq_log_tail_q != checkpoint_lq_tail_q[branch_restore_id_i]) ||
             (sq_log_tail_q != checkpoint_sq_tail_q[branch_restore_id_i]))) begin
          rollback_busy_q <= 1'b1;
          rollback_lq_target_q <= checkpoint_lq_tail_q[branch_restore_id_i];
          rollback_sq_target_q <= checkpoint_sq_tail_q[branch_restore_id_i];
        end else begin
          rollback_busy_q <= 1'b0;
          branch_restore_done_q <= 1'b1;
        end
      end else if (rollback_busy_q) begin
        if (lq_log_tail_q != rollback_lq_target_q) begin
          lq_free_bitmap_q[
              lq_allocation_log_q[log_index(lq_rollback_prev)]] <= 1'b1;
          lq_log_tail_q <= lq_rollback_prev;
        end
        if (sq_log_tail_q != rollback_sq_target_q) begin
          sq_free_bitmap_q[
              sq_allocation_log_q[log_index(sq_rollback_prev)]] <= 1'b1;
          sq_log_tail_q <= sq_rollback_prev;
        end

        if (((lq_log_tail_q == rollback_lq_target_q) || lq_rollback_last) &&
            ((sq_log_tail_q == rollback_sq_target_q) || sq_rollback_last)) begin
          rollback_busy_q <= 1'b0;
          branch_restore_done_q <= 1'b1;
        end
      end else begin
        // Commit/retire releases are independent for LQ and SQ.
        if (lq_release_valid_i[0])
          lq_free_bitmap_q[lq_release_id_i[0]] <= 1'b1;
        if (lq_release_valid_i[1])
          lq_free_bitmap_q[lq_release_id_i[1]] <= 1'b1;
        if (sq_release_valid_i[0])
          sq_free_bitmap_q[sq_release_id_i[0]] <= 1'b1;
        if (sq_release_valid_i[1])
          sq_free_bitmap_q[sq_release_id_i[1]] <= 1'b1;

        if (checkpoint_clear_i)
          checkpoint_valid_q[checkpoint_clear_id_i] <= 1'b0;

        if (alloc_cancel_i && reservation_valid_q) begin
          reservation_valid_q <= 1'b0;
          reservation_lq_count_q <= '0;
          reservation_sq_count_q <= '0;
        end else if (alloc_fire_i && reservation_valid_q) begin
          reservation_valid_q <= 1'b0;

          if (reservation_lq_count_q >= 2'd1) begin
            lq_free_bitmap_q[reservation_lq_id_q[0]] <= 1'b0;
            lq_allocation_log_q[log_index(lq_log_tail_q)] <=
                reservation_lq_id_q[0];
          end
          if (reservation_lq_count_q == 2'd2) begin
            lq_free_bitmap_q[reservation_lq_id_q[1]] <= 1'b0;
            lq_allocation_log_q[log_index(lq_log_tail_q + 1'b1)] <=
                reservation_lq_id_q[1];
          end
          if (reservation_sq_count_q >= 2'd1) begin
            sq_free_bitmap_q[reservation_sq_id_q[0]] <= 1'b0;
            sq_allocation_log_q[log_index(sq_log_tail_q)] <=
                reservation_sq_id_q[0];
          end
          if (reservation_sq_count_q == 2'd2) begin
            sq_free_bitmap_q[reservation_sq_id_q[1]] <= 1'b0;
            sq_allocation_log_q[log_index(sq_log_tail_q + 1'b1)] <=
                reservation_sq_id_q[1];
          end

          lq_log_tail_q <= lq_log_tail_q + reservation_lq_count_q;
          sq_log_tail_q <= sq_log_tail_q + reservation_sq_count_q;

          if (checkpoint_save_i) begin
            checkpoint_valid_q[checkpoint_id_i] <= 1'b1;
            checkpoint_lq_tail_q[checkpoint_id_i] <=
                lq_log_tail_q + checkpoint_keep_lq_count_i;
            checkpoint_sq_tail_q[checkpoint_id_i] <=
                sq_log_tail_q + checkpoint_keep_sq_count_i;
          end
        end else if (!reservation_valid_q &&
                     ((alloc_lq_count_i != 2'd0) ||
                      (alloc_sq_count_i != 2'd0)) &&
                     request_available) begin
          reservation_valid_q <= 1'b1;
          reservation_lq_count_q <= alloc_lq_count_i;
          reservation_sq_count_q <= alloc_sq_count_i;
          reservation_lq_id_q[0] <= lq_candidate0[2:0];
          reservation_lq_id_q[1] <= lq_candidate1[2:0];
          reservation_sq_id_q[0] <= sq_candidate0[2:0];
          reservation_sq_id_q[1] <= sq_candidate1[2:0];
        end
      end
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk_i) begin : allocator_assertions
    if (!rst_i) begin
      assert (alloc_lq_count_i <= 2 && alloc_sq_count_i <= 2)
        else $error("lsq_allocator request count exceeds dual-width contract");
      assert (!(alloc_fire_i && alloc_cancel_i))
        else $error("lsq_allocator fire and cancel asserted together");

      if (reservation_valid_q) begin
        assert ((reservation_lq_count_q != 2'd2) ||
                (reservation_lq_id_q[0] != reservation_lq_id_q[1]))
          else $error("lsq_allocator duplicated LQ ID");
        assert ((reservation_sq_count_q != 2'd2) ||
                (reservation_sq_id_q[0] != reservation_sq_id_q[1]))
          else $error("lsq_allocator duplicated SQ ID");
      end

      if (checkpoint_save_i && alloc_fire_i && reservation_valid_q) begin
        assert (checkpoint_keep_lq_count_i <= reservation_lq_count_q)
          else $error("checkpoint keeps more LQ allocations than reserved");
        assert (checkpoint_keep_sq_count_i <= reservation_sq_count_q)
          else $error("checkpoint keeps more SQ allocations than reserved");
      end
    end
  end
`endif

endmodule
