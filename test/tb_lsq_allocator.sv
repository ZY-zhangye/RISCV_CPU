`timescale 1ns/1ps

import core_types_pkg::*;

module tb_lsq_allocator;
  logic clk_i = 1'b0;
  logic rst_i = 1'b1;

  logic [1:0] alloc_lq_count_i = '0;
  logic [1:0] alloc_sq_count_i = '0;
  logic alloc_valid_o;
  logic [1:0][LQ_ID_W-1:0] alloc_lq_id_o;
  logic [1:0][SQ_ID_W-1:0] alloc_sq_id_o;
  logic alloc_fire_i = 1'b0;
  logic alloc_cancel_i = 1'b0;

  logic [1:0] lq_release_valid_i = '0;
  logic [1:0][LQ_ID_W-1:0] lq_release_id_i = '0;
  logic [1:0] sq_release_valid_i = '0;
  logic [1:0][SQ_ID_W-1:0] sq_release_id_i = '0;

  logic checkpoint_save_i = 1'b0;
  logic [CP_W-1:0] checkpoint_id_i = '0;
  logic [1:0] checkpoint_keep_lq_count_i = '0;
  logic [1:0] checkpoint_keep_sq_count_i = '0;
  logic checkpoint_clear_i = 1'b0;
  logic [CP_W-1:0] checkpoint_clear_id_i = '0;

  logic branch_restore_i = 1'b0;
  logic [CP_W-1:0] branch_restore_id_i = '0;
  logic branch_restore_done_o;

  logic exception_flush_i = 1'b0;
  logic exception_flush_done_o;

  logic busy_o;
  logic [3:0] lq_free_count_o;
  logic [3:0] sq_free_count_o;

  lsq_allocator dut (.*);

  always #5 clk_i = ~clk_i;

  task automatic clear_controls;
    begin
      alloc_lq_count_i = '0;
      alloc_sq_count_i = '0;
      alloc_fire_i = 1'b0;
      alloc_cancel_i = 1'b0;
      lq_release_valid_i = '0;
      lq_release_id_i = '0;
      sq_release_valid_i = '0;
      sq_release_id_i = '0;
      checkpoint_save_i = 1'b0;
      checkpoint_id_i = '0;
      checkpoint_keep_lq_count_i = '0;
      checkpoint_keep_sq_count_i = '0;
      checkpoint_clear_i = 1'b0;
      checkpoint_clear_id_i = '0;
      branch_restore_i = 1'b0;
      branch_restore_id_i = '0;
      exception_flush_i = 1'b0;
    end
  endtask

  task automatic request_reservation(
      input logic [1:0] lq_count,
      input logic [1:0] sq_count
  );
    begin
      @(negedge clk_i);
      alloc_lq_count_i = lq_count;
      alloc_sq_count_i = sq_count;
      @(posedge clk_i);
      #1;
      if (!alloc_valid_o)
        $fatal(1, "missing LSQ reservation lq=%0d sq=%0d", lq_count, sq_count);
    end
  endtask

  task automatic fire_reservation(
      input logic save_checkpoint,
      input logic [CP_W-1:0] checkpoint_id,
      input logic [1:0] keep_lq,
      input logic [1:0] keep_sq
  );
    begin
      @(negedge clk_i);
      alloc_lq_count_i = '0;
      alloc_sq_count_i = '0;
      alloc_fire_i = 1'b1;
      checkpoint_save_i = save_checkpoint;
      checkpoint_id_i = checkpoint_id;
      checkpoint_keep_lq_count_i = keep_lq;
      checkpoint_keep_sq_count_i = keep_sq;
      @(posedge clk_i);
      #1;
      alloc_fire_i = 1'b0;
      checkpoint_save_i = 1'b0;
      if (alloc_valid_o)
        $fatal(1, "reservation did not clear after fire");
    end
  endtask

  initial begin
    logic [1:0][LQ_ID_W-1:0] held_lq_ids;
    logic [1:0][SQ_ID_W-1:0] held_sq_ids;
    logic [LQ_ID_W-1:0] kept_lq_id;
    integer cycles;

    clear_controls();
    repeat (2) @(posedge clk_i);
    @(negedge clk_i);
    rst_i = 1'b0;
    @(posedge clk_i);
    #1;
    if (lq_free_count_o != 4'd8 || sq_free_count_o != 4'd8 ||
        alloc_valid_o || busy_o)
      $fatal(1, "reset state mismatch");

    // Reserve two LQ IDs and one SQ ID. Reservation must remain stable until fire.
    request_reservation(2'd2, 2'd1);
    if (alloc_lq_id_o[0] !== 3'd0 || alloc_lq_id_o[1] !== 3'd1 ||
        alloc_sq_id_o[0] !== 3'd0)
      $fatal(1, "initial reservation IDs mismatch");
    held_lq_ids = alloc_lq_id_o;
    held_sq_ids = alloc_sq_id_o;
    kept_lq_id = alloc_lq_id_o[0];

    @(negedge clk_i);
    alloc_lq_count_i = 2'd1;
    alloc_sq_count_i = 2'd2;
    @(posedge clk_i);
    #1;
    if (!alloc_valid_o || alloc_lq_id_o !== held_lq_ids ||
        alloc_sq_id_o !== held_sq_ids)
      $fatal(1, "reservation payload did not hold stable");

    // Save checkpoint after keeping only the first LQ allocation. The second
    // LQ and the SQ allocation are younger than the branch.
    fire_reservation(1'b1, 2'd0, 2'd1, 2'd0);
    if (lq_free_count_o != 4'd6 || sq_free_count_o != 4'd7)
      $fatal(1, "first allocation counts mismatch");

    // Allocate younger entries after the checkpoint.
    request_reservation(2'd1, 2'd2);
    if (alloc_lq_id_o[0] !== 3'd2 ||
        alloc_sq_id_o[0] !== 3'd1 || alloc_sq_id_o[1] !== 3'd2)
      $fatal(1, "younger reservation IDs mismatch");
    fire_reservation(1'b0, '0, '0, '0);
    if (lq_free_count_o != 4'd5 || sq_free_count_o != 4'd5)
      $fatal(1, "younger allocation counts mismatch");

    // Restore checkpoint 0. LQ rolls back two IDs; SQ rolls back three IDs.
    @(negedge clk_i);
    branch_restore_i = 1'b1;
    branch_restore_id_i = 2'd0;
    @(posedge clk_i);
    #1;
    branch_restore_i = 1'b0;
    cycles = 0;
    while (!branch_restore_done_o) begin
      if (!busy_o)
        $fatal(1, "rollback lost busy before done");
      @(posedge clk_i);
      #1;
      cycles = cycles + 1;
      if (cycles > 8)
        $fatal(1, "rollback timeout");
    end
    if (lq_free_count_o != 4'd7 || sq_free_count_o != 4'd8)
      $fatal(1, "checkpoint rollback count mismatch lq=%0d sq=%0d",
             lq_free_count_o, sq_free_count_o);

    // A cancelled reservation must consume no entries.
    request_reservation(2'd1, 2'd1);
    if (alloc_lq_id_o[0] !== 3'd1 || alloc_sq_id_o[0] !== 3'd0)
      $fatal(1, "post-rollback IDs were not released");
    @(negedge clk_i);
    alloc_lq_count_i = '0;
    alloc_sq_count_i = '0;
    alloc_cancel_i = 1'b1;
    @(posedge clk_i);
    #1;
    alloc_cancel_i = 1'b0;
    if (alloc_valid_o || lq_free_count_o != 4'd7 || sq_free_count_o != 4'd8)
      $fatal(1, "cancel consumed reserved entries");

    // Release the one checkpoint-kept LQ entry.
    @(negedge clk_i);
    lq_release_valid_i = 2'b01;
    lq_release_id_i[0] = kept_lq_id;
    @(posedge clk_i);
    #1;
    lq_release_valid_i = '0;
    if (lq_free_count_o != 4'd8)
      $fatal(1, "LQ release failed");

    // Allocate entries, then exception flush must free all state immediately.
    request_reservation(2'd2, 2'd2);
    fire_reservation(1'b0, '0, '0, '0);
    if (lq_free_count_o != 4'd6 || sq_free_count_o != 4'd6)
      $fatal(1, "pre-flush allocation mismatch");
    @(negedge clk_i);
    exception_flush_i = 1'b1;
    @(posedge clk_i);
    #1;
    exception_flush_i = 1'b0;
    if (!exception_flush_done_o || lq_free_count_o != 4'd8 ||
        sq_free_count_o != 4'd8 || busy_o || alloc_valid_o)
      $fatal(1, "exception flush failed");

    // Clearing a checkpoint makes a later restore a no-op completion.
    @(negedge clk_i);
    checkpoint_clear_i = 1'b1;
    checkpoint_clear_id_i = 2'd0;
    @(posedge clk_i);
    #1;
    checkpoint_clear_i = 1'b0;
    @(negedge clk_i);
    branch_restore_i = 1'b1;
    branch_restore_id_i = 2'd0;
    @(posedge clk_i);
    #1;
    branch_restore_i = 1'b0;
    if (!branch_restore_done_o || busy_o)
      $fatal(1, "invalid checkpoint restore did not complete as no-op");

    $display("PASS: lsq_allocator directed tests");
    $finish;
  end

  initial begin
    #30000;
    $fatal(1, "timeout");
  end
endmodule
