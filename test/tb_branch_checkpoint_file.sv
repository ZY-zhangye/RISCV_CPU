`timescale 1ns/1ps

import core_types_pkg::*;

module tb_branch_checkpoint_file;
  logic clk_i = 1'b0;
  logic rst_i = 1'b1;

  logic alloc_req_i = 1'b0;
  logic alloc_valid_o;
  logic [CP_W-1:0] alloc_checkpoint_id_o;
  logic alloc_fire_i = 1'b0;
  logic alloc_cancel_i = 1'b0;
  logic [ROB_ID_W-1:0] save_rob_tail_i = '0;
  logic [CHECKPOINTS-1:0] save_parent_mask_i = '0;
  logic checkpoint_clear_i = 1'b0;
  logic [CP_W-1:0] checkpoint_clear_id_i = '0;
  recovery_t recovery_i = '0;
  logic branch_restore_valid_o;
  logic [ROB_ID_W-1:0] branch_restore_rob_tail_o;
  logic branch_recovery_complete_i = 1'b0;
  logic exception_flush_i = 1'b0;
  logic busy_o;
  logic full_o;
  logic [$clog2(CHECKPOINTS+1)-1:0] active_count_o;

  branch_checkpoint_file dut (.*);

  always #5 clk_i = ~clk_i;

  task automatic reserve_checkpoint(
      output logic [CP_W-1:0] checkpoint_id
  );
    begin
      @(negedge clk_i);
      alloc_req_i = 1'b1;
      while (!alloc_valid_o)
        @(negedge clk_i);
      checkpoint_id = alloc_checkpoint_id_o;
      alloc_req_i = 1'b0;
    end
  endtask

  task automatic commit_checkpoint(
      input logic [ROB_ID_W-1:0] rob_tail,
      input logic [CHECKPOINTS-1:0] parent_mask
  );
    begin
      save_rob_tail_i = rob_tail;
      save_parent_mask_i = parent_mask;
      alloc_fire_i = 1'b1;
      @(posedge clk_i); #1;
      alloc_fire_i = 1'b0;
      save_parent_mask_i = '0;
    end
  endtask

  task automatic allocate_checkpoint(
      input logic [ROB_ID_W-1:0] rob_tail,
      input logic [CHECKPOINTS-1:0] parent_mask,
      output logic [CP_W-1:0] checkpoint_id
  );
    begin
      reserve_checkpoint(checkpoint_id);
      commit_checkpoint(rob_tail, parent_mask);
    end
  endtask

  initial begin
    logic [CP_W-1:0] cp0;
    logic [CP_W-1:0] cp1;
    logic [CP_W-1:0] cp2;
    logic [CP_W-1:0] cp3;

    repeat (2) @(posedge clk_i);
    @(negedge clk_i);
    rst_i = 1'b0;

    // A cancelled reservation is reusable and never becomes active.
    reserve_checkpoint(cp0);
    if (cp0 != 2'd0)
      $fatal(1, "first checkpoint ID mismatch");
    alloc_cancel_i = 1'b1;
    @(posedge clk_i); #1;
    alloc_cancel_i = 1'b0;
    if (active_count_o != 0)
      $fatal(1, "cancelled checkpoint became active");

    allocate_checkpoint(5'd7, 4'b0000, cp0);
    allocate_checkpoint(5'd12, 4'b0001, cp1);
    if (cp0 != 2'd0 || cp1 != 2'd1 || active_count_o != 2)
      $fatal(1, "nested checkpoint allocation mismatch");

    // Correctly resolving cp0 releases it and removes cp0 from cp1's ancestry.
    @(negedge clk_i);
    checkpoint_clear_i = 1'b1;
    checkpoint_clear_id_i = cp0;
    @(posedge clk_i); #1;
    checkpoint_clear_i = 1'b0;
    if (active_count_o != 1)
      $fatal(1, "correct checkpoint clear count mismatch");

    // Reuse cp0 as a child of cp1.
    allocate_checkpoint(5'd18, 4'b0010, cp2);
    if (cp2 != cp0 || active_count_o != 2)
      $fatal(1, "released checkpoint ID was not reused");

    // Mispredict cp1 exposes its ROB tail and holds both cp1 and child cp2
    // until the recovery controller reports all acknowledgements complete.
    @(negedge clk_i);
    recovery_i.valid = 1'b1;
    recovery_i.cause = REC_BRANCH;
    recovery_i.checkpoint_id = cp1;
    recovery_i.redirect_pc = 32'h8000_0200;
    #1;
    if (!branch_restore_valid_o || branch_restore_rob_tail_o != 5'd12)
      $fatal(1, "branch restore lookup mismatch");
    @(posedge clk_i); #1;
    recovery_i = '0;
    if (!busy_o || active_count_o != 2)
      $fatal(1, "checkpoint recovery did not hold active state");

    @(negedge clk_i);
    alloc_req_i = 1'b1;
    repeat (2) @(posedge clk_i);
    #1;
    if (alloc_valid_o)
      $fatal(1, "allocator responded during pending recovery");
    @(negedge clk_i);
    alloc_req_i = 1'b0;
    branch_recovery_complete_i = 1'b1;
    @(posedge clk_i); #1;
    branch_recovery_complete_i = 1'b0;
    if (busy_o || active_count_o != 0)
      $fatal(1, "mispredict did not release branch and descendants");

    // Fill all four entries and verify backpressure.
    allocate_checkpoint(5'd1, 4'b0000, cp0);
    allocate_checkpoint(5'd2, 4'b0001, cp1);
    allocate_checkpoint(5'd3, 4'b0011, cp2);
    allocate_checkpoint(5'd4, 4'b0111, cp3);
    if (!full_o || active_count_o != 4)
      $fatal(1, "checkpoint full indication mismatch");
    @(negedge clk_i);
    alloc_req_i = 1'b1;
    repeat (2) @(posedge clk_i);
    #1;
    if (alloc_valid_o)
      $fatal(1, "allocator overcommitted full checkpoint file");
    alloc_req_i = 1'b0;

    // Exception recovery discards every speculative checkpoint.
    @(negedge clk_i);
    exception_flush_i = 1'b1;
    @(posedge clk_i); #1;
    exception_flush_i = 1'b0;
    if (active_count_o != 0 || full_o || busy_o)
      $fatal(1, "exception flush did not reset checkpoint state");

    $display("PASS: branch_checkpoint_file directed tests");
    $finish;
  end

  initial begin
    #200000;
    $fatal(1, "timeout");
  end
endmodule
