`timescale 1ns/1ps

import core_types_pkg::*;

module tb_free_list;
  logic clk_i = 1'b0;
  logic rst_i = 1'b1;
  logic [1:0] alloc_count_i = 2'd0;
  logic alloc_valid_o;
  logic [PRD_W-1:0] alloc_prd0_o;
  logic [PRD_W-1:0] alloc_prd1_o;
  logic alloc_fire_i = 1'b0;
  logic alloc_cancel_i = 1'b0;
  logic [1:0] reclaim_valid_i = 2'b00;
  logic [PRD_W-1:0] reclaim_prd0_i = '0;
  logic [PRD_W-1:0] reclaim_prd1_i = '0;
  logic reclaim_ready_o;
  logic checkpoint_save_i = 1'b0;
  logic [CP_W-1:0] checkpoint_id_i = '0;
  logic [1:0] checkpoint_keep_count_i = 2'd0;
  logic checkpoint_clear_i = 1'b0;
  logic [CP_W-1:0] checkpoint_clear_id_i = '0;
  logic branch_restore_i = 1'b0;
  logic [CP_W-1:0] branch_restore_id_i = '0;
  logic branch_restore_done_o;
  logic rebuild_start_i = 1'b0;
  logic [PRD_W-1:0] amt_map_i [0:ARCH_REGS-1];
  logic busy_o;
  logic rebuild_done_o;
  logic [6:0] free_count_o;

  free_list dut (.*);

  always #5 clk_i = ~clk_i;

  task automatic request_alloc(input logic [1:0] count);
    @(negedge clk_i);
    alloc_count_i = count;
    while (!alloc_valid_o)
      @(negedge clk_i);
  endtask

  task automatic fire_alloc;
    @(negedge clk_i);
    alloc_fire_i = 1'b1;
    @(negedge clk_i);
    alloc_fire_i = 1'b0;
    alloc_count_i = 2'd0;
  endtask

  initial begin
    logic [PRD_W-1:0] first0;
    logic [PRD_W-1:0] first1;
    logic [PRD_W-1:0] held0;
    logic [PRD_W-1:0] branch_prd;
    integer index;

    for (index = 0; index < ARCH_REGS; index = index + 1)
      amt_map_i[index] = index[PRD_W-1:0];

    repeat (2) @(posedge clk_i);
    @(negedge clk_i);
    rst_i = 1'b0;

    if (free_count_o != 7'd32)
      $fatal(1, "reset free count mismatch: %0d", free_count_o);

    // Selection is registered and prefers opposite banks for a dual request.
    request_alloc(2'd2);
    first0 = alloc_prd0_o;
    first1 = alloc_prd1_o;
    if ((first0 < 32) || (first1 < 32) || (first0 == first1) ||
        (first0[0] == first1[0]))
      $fatal(1, "invalid initial dual reservation: p%0d/p%0d", first0, first1);

    // Reservation payload remains stable until fire even if the request changes.
    held0 = alloc_prd0_o;
    @(negedge clk_i);
    alloc_count_i = 2'd1;
    @(negedge clk_i);
    if (!alloc_valid_o || alloc_prd0_o != held0 || free_count_o != 7'd32)
      $fatal(1, "reservation was not held without consuming bitmap");
    alloc_count_i = 2'd2;
    fire_alloc();
    if (free_count_o != 7'd30)
      $fatal(1, "dual allocation count mismatch: %0d", free_count_o);

    // Cancel has no bitmap side effect.
    request_alloc(2'd1);
    held0 = alloc_prd0_o;
    @(negedge clk_i);
    alloc_cancel_i = 1'b1;
    @(negedge clk_i);
    alloc_cancel_i = 1'b0;
    alloc_count_i = 2'd0;
    if (alloc_valid_o || free_count_o != 7'd30)
      $fatal(1, "cancel changed allocation state");

    // Two-entry reclaim buffer accepts a bundle and drains locally one per cycle.
    @(negedge clk_i);
    reclaim_valid_i = 2'b11;
    reclaim_prd0_i = first0;
    reclaim_prd1_i = first1;
    if (!reclaim_ready_o)
      $fatal(1, "reclaim buffer rejected an empty two-entry bundle");
    @(negedge clk_i);
    reclaim_valid_i = 2'b00;
    reclaim_prd0_i = '0;
    reclaim_prd1_i = '0;
    while (free_count_o != 7'd32)
      @(negedge clk_i);

    // Save a checkpoint after the branch's own PRD, then roll back two younger PRDs.
    request_alloc(2'd1);
    branch_prd = alloc_prd0_o;
    @(negedge clk_i);
    alloc_fire_i = 1'b1;
    checkpoint_save_i = 1'b1;
    checkpoint_id_i = 2'd1;
    checkpoint_keep_count_i = 2'd1;
    @(negedge clk_i);
    alloc_fire_i = 1'b0;
    checkpoint_save_i = 1'b0;
    checkpoint_keep_count_i = 2'd0;
    alloc_count_i = 2'd0;

    request_alloc(2'd2);
    fire_alloc();
    if (free_count_o != 7'd29)
      $fatal(1, "checkpoint allocation setup mismatch: %0d", free_count_o);

    @(negedge clk_i);
    branch_restore_i = 1'b1;
    branch_restore_id_i = 2'd1;
    @(negedge clk_i);
    branch_restore_i = 1'b0;
    while (!branch_restore_done_o) begin
      if (!busy_o)
        $fatal(1, "rollback dropped busy before completion");
      @(negedge clk_i);
    end
    if (free_count_o != 7'd31)
      $fatal(1, "rollback did not retain only branch allocation: %0d", free_count_o);

    // The retained branch PRD is still allocated; a fresh reservation must differ.
    request_alloc(2'd1);
    if (alloc_prd0_o == branch_prd)
      $fatal(1, "rollback incorrectly freed branch PRD p%0d", branch_prd);
    @(negedge clk_i);
    alloc_cancel_i = 1'b1;
    @(negedge clk_i);
    alloc_cancel_i = 1'b0;
    alloc_count_i = 2'd0;

    // Exception recovery rebuilds from AMT two mappings per cycle.
    @(negedge clk_i);
    rebuild_start_i = 1'b1;
    @(negedge clk_i);
    rebuild_start_i = 1'b0;
    while (!rebuild_done_o) begin
      if (!busy_o)
        $fatal(1, "rebuild dropped busy before completion");
      @(negedge clk_i);
    end
    if (free_count_o != 7'd32)
      $fatal(1, "AMT rebuild free count mismatch: %0d", free_count_o);

    request_alloc(2'd2);
    if ((alloc_prd0_o < 32) || (alloc_prd1_o < 32))
      $fatal(1, "AMT-used PRD was offered after rebuild");

    $display("PASS: free_list directed tests");
    $finish;
  end

  initial begin
    #10000;
    $fatal(1, "timeout");
  end
endmodule
