`timescale 1ns/1ps

import core_types_pkg::*;

module tb_load_queue;
  logic clk_i = 1'b0;
  logic rst_i = 1'b1;

  logic [1:0] alloc_valid_i = '0;
  logic [1:0][LQ_ID_W-1:0] alloc_lq_id_i = '0;
  logic [1:0][ROB_ID_W-1:0] alloc_rob_id_i = '0;
  logic [1:0][PRD_W-1:0] alloc_prd_i = '0;
  mem_op_t alloc_mem_op_i [0:1];
  logic [1:0][CHECKPOINTS-1:0] alloc_branch_mask_i = '0;

  logic address_valid_i = 1'b0;
  logic address_ready_o;
  logic [LQ_ID_W-1:0] address_lq_id_i = '0;
  logic [XLEN-1:0] address_i = '0;
  logic address_exception_valid_i = 1'b0;
  logic [3:0] address_exception_cause_i = '0;
  logic [XLEN-1:0] address_exception_tval_i = '0;

  logic complete_valid_i = 1'b0;
  logic complete_ready_o;
  logic [LQ_ID_W-1:0] complete_lq_id_i = '0;
  logic complete_forwarded_i = 1'b0;

  logic [1:0] retire_valid_i = '0;
  logic [1:0][LQ_ID_W-1:0] retire_lq_id_i = '0;
  logic [1:0] lq_release_valid_o;
  logic [1:0][LQ_ID_W-1:0] lq_release_id_o;

  logic checkpoint_clear_i = 1'b0;
  logic [CP_W-1:0] checkpoint_clear_id_i = '0;
  recovery_t recovery_i = '0;

  load_queue_entry_t entries_o [0:LQ_ENTRIES-1];
  logic [3:0] occupancy_o;

  load_queue dut (.*);

  always #5 clk_i = ~clk_i;

  task automatic clear_controls;
    begin
      alloc_valid_i = '0;
      alloc_lq_id_i = '0;
      alloc_rob_id_i = '0;
      alloc_prd_i = '0;
      alloc_mem_op_i[0] = MEM_LB;
      alloc_mem_op_i[1] = MEM_LB;
      alloc_branch_mask_i = '0;
      address_valid_i = 1'b0;
      address_lq_id_i = '0;
      address_i = '0;
      address_exception_valid_i = 1'b0;
      address_exception_cause_i = '0;
      address_exception_tval_i = '0;
      complete_valid_i = 1'b0;
      complete_lq_id_i = '0;
      complete_forwarded_i = 1'b0;
      retire_valid_i = '0;
      retire_lq_id_i = '0;
      checkpoint_clear_i = 1'b0;
      checkpoint_clear_id_i = '0;
      recovery_i = '0;
    end
  endtask

  task automatic update_address(
      input logic [LQ_ID_W-1:0] lq_id,
      input logic [XLEN-1:0] address,
      input logic exception_valid
  );
    begin
      @(negedge clk_i);
      address_valid_i = 1'b1;
      address_lq_id_i = lq_id;
      address_i = address;
      address_exception_valid_i = exception_valid;
      address_exception_cause_i = exception_valid ? 4'd4 : '0;
      address_exception_tval_i = exception_valid ? address : '0;
      #1;
      if (!address_ready_o)
        $fatal(1, "Load address update not ready for lq%0d", lq_id);
      @(posedge clk_i);
      #1;
      address_valid_i = 1'b0;
    end
  endtask

  task automatic complete_load(
      input logic [LQ_ID_W-1:0] lq_id,
      input logic forwarded
  );
    begin
      @(negedge clk_i);
      complete_valid_i = 1'b1;
      complete_lq_id_i = lq_id;
      complete_forwarded_i = forwarded;
      #1;
      if (!complete_ready_o)
        $fatal(1, "Load completion not ready for lq%0d", lq_id);
      @(posedge clk_i);
      #1;
      complete_valid_i = 1'b0;
    end
  endtask

  initial begin
    clear_controls();
    repeat (2) @(posedge clk_i);
    @(negedge clk_i);
    rst_i = 1'b0;
    @(posedge clk_i);
    #1;
    if (occupancy_o != 0 || lq_release_valid_o != 0)
      $fatal(1, "reset state mismatch");

    // Allocate two Loads with distinct metadata.
    @(negedge clk_i);
    alloc_valid_i = 2'b11;
    alloc_lq_id_i[0] = 3'd0;
    alloc_lq_id_i[1] = 3'd1;
    alloc_rob_id_i[0] = 5'd8;
    alloc_rob_id_i[1] = 5'd9;
    alloc_prd_i[0] = 6'd20;
    alloc_prd_i[1] = 6'd21;
    alloc_mem_op_i[0] = MEM_LB;
    alloc_mem_op_i[1] = MEM_LW;
    alloc_branch_mask_i[0] = 4'b0000;
    alloc_branch_mask_i[1] = 4'b1000;
    @(posedge clk_i);
    #1;
    alloc_valid_i = '0;
    if (occupancy_o != 2 || !entries_o[0].valid || !entries_o[1].valid ||
        entries_o[0].rob_id != 5'd8 || entries_o[1].prd != 6'd21 ||
        entries_o[1].mem_op != MEM_LW)
      $fatal(1, "Load allocation mismatch");

    // Completion is not allowed before the address stage.
    complete_lq_id_i = 3'd0;
    #1;
    if (complete_ready_o)
      $fatal(1, "Load completed before address was valid");

    update_address(3'd0, 32'h8000_0201, 1'b0);
    if (!entries_o[0].address_valid ||
        entries_o[0].address != 32'h8000_0201)
      $fatal(1, "Load address update mismatch");
    #1;
    if (address_ready_o)
      $fatal(1, "Load Queue accepted a duplicate address update");

    complete_load(3'd0, 1'b0);
    if (!entries_o[0].completed || entries_o[0].forwarded)
      $fatal(1, "Load completion state mismatch");

    // Branch recovery kills younger entry 1 and preserves completed entry 0.
    @(negedge clk_i);
    recovery_i.valid = 1'b1;
    recovery_i.cause = REC_BRANCH;
    recovery_i.checkpoint_id = 2'd3;
    @(posedge clk_i);
    #1;
    recovery_i = '0;
    if (entries_o[1].valid || !entries_o[0].valid || occupancy_o != 1)
      $fatal(1, "Load branch recovery mismatch");

    // Retire completed Load 0 and release its allocator ID.
    @(negedge clk_i);
    retire_valid_i = 2'b01;
    retire_lq_id_i[0] = 3'd0;
    @(posedge clk_i);
    #1;
    retire_valid_i = '0;
    if (occupancy_o != 0 || lq_release_valid_o != 2'b01 ||
        lq_release_id_o[0] != 3'd0)
      $fatal(1, "Load retire/release mismatch");
    @(posedge clk_i);
    #1;
    if (lq_release_valid_o != 0)
      $fatal(1, "Load release pulse lasted more than one cycle");

    // Allocate two more Loads. One records an address exception; the other is forwarded.
    @(negedge clk_i);
    alloc_valid_i = 2'b11;
    alloc_lq_id_i[0] = 3'd2;
    alloc_lq_id_i[1] = 3'd3;
    alloc_rob_id_i[0] = 5'd10;
    alloc_rob_id_i[1] = 5'd11;
    alloc_prd_i[0] = 6'd22;
    alloc_prd_i[1] = 6'd23;
    alloc_mem_op_i[0] = MEM_LH;
    alloc_mem_op_i[1] = MEM_LBU;
    alloc_branch_mask_i[0] = 4'b0010;
    alloc_branch_mask_i[1] = 4'b0000;
    @(posedge clk_i);
    #1;
    alloc_valid_i = '0;

    update_address(3'd2, 32'h8000_0201, 1'b1);
    if (!entries_o[2].exception_valid ||
        entries_o[2].exception_cause != 4'd4 ||
        entries_o[2].exception_tval != 32'h8000_0201)
      $fatal(1, "Load exception metadata mismatch");

    @(negedge clk_i);
    checkpoint_clear_i = 1'b1;
    checkpoint_clear_id_i = 2'd1;
    @(posedge clk_i);
    #1;
    checkpoint_clear_i = 1'b0;
    if (entries_o[2].branch_mask != 0)
      $fatal(1, "Load checkpoint clear mismatch");

    update_address(3'd3, 32'h8000_0300, 1'b0);
    complete_load(3'd3, 1'b1);
    if (!entries_o[3].completed || !entries_o[3].forwarded)
      $fatal(1, "forwarded Load state mismatch");

    // Dual retire clears both entries and returns both IDs.
    @(negedge clk_i);
    retire_valid_i = 2'b11;
    retire_lq_id_i[0] = 3'd2;
    retire_lq_id_i[1] = 3'd3;
    @(posedge clk_i);
    #1;
    retire_valid_i = '0;
    if (occupancy_o != 0 || lq_release_valid_o != 2'b11 ||
        lq_release_id_o[0] != 3'd2 || lq_release_id_o[1] != 3'd3)
      $fatal(1, "dual Load retire mismatch");

    // Exception recovery clears all remaining uncommitted Load entries.
    @(negedge clk_i);
    alloc_valid_i = 2'b01;
    alloc_lq_id_i[0] = 3'd4;
    alloc_rob_id_i[0] = 5'd12;
    alloc_prd_i[0] = 6'd24;
    alloc_mem_op_i[0] = MEM_LW;
    alloc_branch_mask_i[0] = 4'b0100;
    @(posedge clk_i);
    #1;
    alloc_valid_i = '0;
    @(negedge clk_i);
    recovery_i.valid = 1'b1;
    recovery_i.cause = REC_EXCEPT;
    @(posedge clk_i);
    #1;
    recovery_i = '0;
    if (occupancy_o != 0)
      $fatal(1, "exception recovery did not clear Load Queue");

    $display("PASS: load_queue directed tests");
    $finish;
  end

  initial begin
    #30000;
    $fatal(1, "timeout");
  end
endmodule
