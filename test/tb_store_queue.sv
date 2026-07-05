`timescale 1ns/1ps

import core_types_pkg::*;

module tb_store_queue;
  logic clk_i = 1'b0;
  logic rst_i = 1'b1;

  logic [1:0] alloc_valid_i = '0;
  logic [1:0][SQ_ID_W-1:0] alloc_sq_id_i = '0;
  logic [1:0][ROB_ID_W-1:0] alloc_rob_id_i = '0;
  logic [1:0][CHECKPOINTS-1:0] alloc_branch_mask_i = '0;

  logic execute_valid_i = 1'b0;
  logic execute_ready_o;
  logic [SQ_ID_W-1:0] execute_sq_id_i = '0;
  logic [XLEN-1:0] execute_address_i = '0;
  logic [XLEN-1:0] execute_data_i = '0;
  logic [3:0] execute_byte_enable_i = '0;
  logic execute_exception_valid_i = 1'b0;
  logic [3:0] execute_exception_cause_i = '0;
  logic [XLEN-1:0] execute_exception_tval_i = '0;

  logic commit_valid_i = 1'b0;
  logic [SQ_ID_W-1:0] commit_sq_id_i = '0;
  logic commit_ready_o;
  logic commit_done_o;

  store_mem_req_t mem_req_o;
  logic mem_req_ready_i = 1'b0;

  logic sq_release_valid_o;
  logic [SQ_ID_W-1:0] sq_release_id_o;

  logic checkpoint_clear_i = 1'b0;
  logic [CP_W-1:0] checkpoint_clear_id_i = '0;
  recovery_t recovery_i = '0;

  store_queue_entry_t entries_o [0:SQ_ENTRIES-1];
  logic [3:0] occupancy_o;

  store_queue dut (.*);

  always #5 clk_i = ~clk_i;

  task automatic clear_controls;
    begin
      alloc_valid_i = '0;
      alloc_sq_id_i = '0;
      alloc_rob_id_i = '0;
      alloc_branch_mask_i = '0;
      execute_valid_i = 1'b0;
      execute_sq_id_i = '0;
      execute_address_i = '0;
      execute_data_i = '0;
      execute_byte_enable_i = '0;
      execute_exception_valid_i = 1'b0;
      execute_exception_cause_i = '0;
      execute_exception_tval_i = '0;
      commit_valid_i = 1'b0;
      commit_sq_id_i = '0;
      mem_req_ready_i = 1'b0;
      checkpoint_clear_i = 1'b0;
      checkpoint_clear_id_i = '0;
      recovery_i = '0;
    end
  endtask

  task automatic execute_store(
      input logic [SQ_ID_W-1:0] sq_id,
      input logic [XLEN-1:0] address,
      input logic [XLEN-1:0] data,
      input logic [3:0] byte_enable,
      input logic exception_valid
  );
    begin
      @(negedge clk_i);
      execute_valid_i = 1'b1;
      execute_sq_id_i = sq_id;
      execute_address_i = address;
      execute_data_i = data;
      execute_byte_enable_i = byte_enable;
      execute_exception_valid_i = exception_valid;
      execute_exception_cause_i = exception_valid ? 4'd6 : '0;
      execute_exception_tval_i = exception_valid ? address : '0;
      #1;
      if (!execute_ready_o)
        $fatal(1, "store execute not ready for sq%0d", sq_id);
      @(posedge clk_i);
      #1;
      execute_valid_i = 1'b0;
    end
  endtask

  initial begin
    store_mem_req_t held_req;

    clear_controls();
    repeat (2) @(posedge clk_i);
    @(negedge clk_i);
    rst_i = 1'b0;
    @(posedge clk_i);
    #1;
    if (occupancy_o != 0 || mem_req_o.valid || commit_done_o ||
        sq_release_valid_o)
      $fatal(1, "reset state mismatch");

    // Allocate two Store entries with different speculation masks.
    @(negedge clk_i);
    alloc_valid_i = 2'b11;
    alloc_sq_id_i[0] = 3'd0;
    alloc_sq_id_i[1] = 3'd1;
    alloc_rob_id_i[0] = 5'd4;
    alloc_rob_id_i[1] = 5'd5;
    alloc_branch_mask_i[0] = 4'b0000;
    alloc_branch_mask_i[1] = 4'b0100;
    @(posedge clk_i);
    #1;
    alloc_valid_i = '0;
    if (occupancy_o != 2 || !entries_o[0].valid || !entries_o[1].valid ||
        entries_o[0].rob_id != 5'd4 || entries_o[1].rob_id != 5'd5)
      $fatal(1, "Store allocation mismatch");

    // Execute Store 0. A speculative executed Store must not write memory.
    execute_store(3'd0, 32'h8000_0100, 32'h1122_3344, 4'b1111, 1'b0);
    if (!entries_o[0].address_valid || !entries_o[0].data_valid ||
        entries_o[0].address != 32'h8000_0100 ||
        entries_o[0].data != 32'h1122_3344 ||
        entries_o[0].byte_enable != 4'b1111 || mem_req_o.valid)
      $fatal(1, "Store execute update mismatch");

    // ROB-head commit captures Store 0 into the one-entry commit buffer.
    @(negedge clk_i);
    commit_valid_i = 1'b1;
    commit_sq_id_i = 3'd0;
    #1;
    if (!commit_ready_o)
      $fatal(1, "ready Store was not commit-ready");
    @(posedge clk_i);
    #1;
    commit_valid_i = 1'b0;
    if (!mem_req_o.valid || mem_req_o.sq_id != 3'd0 ||
        mem_req_o.address != 32'h8000_0100 ||
        mem_req_o.data != 32'h1122_3344 ||
        mem_req_o.byte_enable != 4'b1111)
      $fatal(1, "commit buffer payload mismatch");

    // Commit buffer must hold under Data RAM backpressure.
    held_req = mem_req_o;
    repeat (2) begin
      @(posedge clk_i);
      #1;
      if (mem_req_o !== held_req || commit_done_o || sq_release_valid_o)
        $fatal(1, "commit buffer did not hold under backpressure");
    end

    // Branch recovery kills younger Store 1 but not the committed Store buffer.
    @(negedge clk_i);
    recovery_i.valid = 1'b1;
    recovery_i.cause = REC_BRANCH;
    recovery_i.checkpoint_id = 2'd2;
    @(posedge clk_i);
    #1;
    recovery_i = '0;
    if (entries_o[1].valid || !mem_req_o.valid || mem_req_o !== held_req)
      $fatal(1, "branch recovery Store handling mismatch");

    // Data RAM accepts committed Store: completion and allocator release pulse.
    @(negedge clk_i);
    mem_req_ready_i = 1'b1;
    @(posedge clk_i);
    #1;
    mem_req_ready_i = 1'b0;
    if (!commit_done_o || !sq_release_valid_o || sq_release_id_o != 3'd0 ||
        mem_req_o.valid || occupancy_o != 0)
      $fatal(1, "Store commit fire/release mismatch");
    @(posedge clk_i);
    #1;
    if (commit_done_o || sq_release_valid_o)
      $fatal(1, "commit/release pulse lasted more than one cycle");

    // Exception Store records metadata but can never enter commit buffer.
    @(negedge clk_i);
    alloc_valid_i = 2'b01;
    alloc_sq_id_i[0] = 3'd2;
    alloc_rob_id_i[0] = 5'd6;
    alloc_branch_mask_i[0] = 4'b0010;
    @(posedge clk_i);
    #1;
    alloc_valid_i = '0;
    execute_store(3'd2, 32'h8000_0102, 32'haabb_ccdd, 4'b1100, 1'b1);
    if (!entries_o[2].exception_valid ||
        entries_o[2].exception_cause != 4'd6 ||
        entries_o[2].exception_tval != 32'h8000_0102)
      $fatal(1, "Store exception metadata mismatch");
    @(negedge clk_i);
    commit_valid_i = 1'b1;
    commit_sq_id_i = 3'd2;
    #1;
    if (commit_ready_o)
      $fatal(1, "exception Store became commit-ready");
    @(posedge clk_i);
    #1;
    commit_valid_i = 1'b0;
    if (mem_req_o.valid)
      $fatal(1, "exception Store entered commit buffer");

    // Correct branch clear updates surviving entry mask.
    @(negedge clk_i);
    checkpoint_clear_i = 1'b1;
    checkpoint_clear_id_i = 2'd1;
    @(posedge clk_i);
    #1;
    checkpoint_clear_i = 1'b0;
    if (entries_o[2].branch_mask != 4'b0000)
      $fatal(1, "checkpoint clear did not update Store mask");

    // Exception recovery clears all uncommitted SQ entries.
    @(negedge clk_i);
    recovery_i.valid = 1'b1;
    recovery_i.cause = REC_EXCEPT;
    @(posedge clk_i);
    #1;
    recovery_i = '0;
    if (occupancy_o != 0 || mem_req_o.valid)
      $fatal(1, "exception recovery did not clear Store Queue");

    $display("PASS: store_queue directed tests");
    $finish;
  end

  initial begin
    #30000;
    $fatal(1, "timeout");
  end
endmodule
