`timescale 1ns/1ps

import core_types_pkg::*;

module tb_lsu_pipeline;
  logic clk_i = 1'b0;
  logic rst_i = 1'b1;

  logic issue_valid_i = 1'b0;
  logic issue_ready_o;
  execute_uop_t issue_uop_i = '0;

  store_queue_entry_t sq_entries_i [0:SQ_ENTRIES-1];
  logic [ROB_ID_W-1:0] rob_head_id_i = '0;

  logic lq_address_valid_o;
  logic lq_address_ready_i = 1'b1;
  logic [LQ_ID_W-1:0] lq_address_id_o;
  logic [XLEN-1:0] lq_address_o;
  logic lq_address_exception_valid_o;
  logic [3:0] lq_address_exception_cause_o;
  logic [XLEN-1:0] lq_address_exception_tval_o;

  logic lq_complete_valid_o;
  logic [LQ_ID_W-1:0] lq_complete_id_o;
  logic lq_complete_forwarded_o;

  logic sq_update_valid_o;
  logic sq_update_ready_i = 1'b1;
  logic [SQ_ID_W-1:0] sq_update_id_o;
  logic [XLEN-1:0] sq_update_address_o;
  logic [XLEN-1:0] sq_update_data_o;
  logic [3:0] sq_update_byte_enable_o;
  logic sq_update_exception_valid_o;
  logic [3:0] sq_update_exception_cause_o;
  logic [XLEN-1:0] sq_update_exception_tval_o;

  load_mem_req_t mem_req_o;
  logic mem_req_ready_i = 1'b0;
  load_mem_resp_t mem_resp_i = '0;
  logic mem_resp_ready_o;

  logic result_valid_o;
  logic result_ready_i = 1'b0;
  completion_t result_o;

  recovery_t recovery_i = '0;

  lsu_pipeline dut (.*);

  always #5 clk_i = ~clk_i;

  function automatic execute_uop_t make_load(
      input logic [ROB_ID_W-1:0] rob_id,
      input logic [LQ_ID_W-1:0] lq_id,
      input logic [PRD_W-1:0] prd,
      input mem_op_t mem_op,
      input logic [XLEN-1:0] base,
      input logic [XLEN-1:0] imm,
      input logic [CHECKPOINTS-1:0] branch_mask
  );
    execute_uop_t uop;
    begin
      uop = '0;
      uop.valid = 1'b1;
      uop.rob_id = rob_id;
      uop.lq_id = lq_id;
      uop.prd = prd;
      uop.src1 = base;
      uop.imm = imm;
      uop.fu_type = FU_LSU;
      uop.mem_op = mem_op;
      uop.is_load = 1'b1;
      uop.write_rd = 1'b1;
      uop.branch_mask = branch_mask;
      make_load = uop;
    end
  endfunction

  function automatic execute_uop_t make_store(
      input logic [ROB_ID_W-1:0] rob_id,
      input logic [SQ_ID_W-1:0] sq_id,
      input mem_op_t mem_op,
      input logic [XLEN-1:0] base,
      input logic [XLEN-1:0] imm,
      input logic [XLEN-1:0] data,
      input logic [CHECKPOINTS-1:0] branch_mask
  );
    execute_uop_t uop;
    begin
      uop = '0;
      uop.valid = 1'b1;
      uop.rob_id = rob_id;
      uop.sq_id = sq_id;
      uop.src1 = base;
      uop.imm = imm;
      uop.store_data = data;
      uop.fu_type = FU_LSU;
      uop.mem_op = mem_op;
      uop.is_store = 1'b1;
      uop.branch_mask = branch_mask;
      make_store = uop;
    end
  endfunction

  task automatic clear_controls;
    integer idx;
    begin
      issue_valid_i = 1'b0;
      issue_uop_i = '0;
      lq_address_ready_i = 1'b1;
      sq_update_ready_i = 1'b1;
      mem_req_ready_i = 1'b0;
      mem_resp_i = '0;
      result_ready_i = 1'b0;
      recovery_i = '0;
      for (idx = 0; idx < SQ_ENTRIES; idx = idx + 1)
        sq_entries_i[idx] = '0;
    end
  endtask

  task automatic issue_uop(input execute_uop_t uop);
    begin
      @(negedge clk_i);
      if (!issue_ready_o)
        $fatal(1, "LSU unexpectedly not ready");
      issue_valid_i = 1'b1;
      issue_uop_i = uop;
      @(posedge clk_i);
      #1;
      issue_valid_i = 1'b0;
      issue_uop_i = '0;
    end
  endtask

  task automatic drain_result;
    begin
      @(negedge clk_i);
      result_ready_i = 1'b1;
      @(posedge clk_i);
      #1;
      result_ready_i = 1'b0;
      if (result_valid_o)
        $fatal(1, "LSU result did not drain");
    end
  endtask

  task automatic expect_result(
      input logic [ROB_ID_W-1:0] rob_id,
      input logic [PRD_W-1:0] prd,
      input logic [XLEN-1:0] data,
      input logic write_prf,
      input logic is_store,
      input logic exception_valid
  );
    begin
      if (!result_valid_o || !result_o.valid ||
          result_o.rob_id != rob_id || result_o.prd != prd ||
          result_o.data != data || result_o.producer != PROD_LSU ||
          result_o.write_prf != write_prf ||
          result_o.is_store != is_store ||
          result_o.exception_valid != exception_valid)
        $fatal(1, "LSU completion mismatch rob=%0d prd=%0d data=%h write=%b store=%b exc=%b",
               result_o.rob_id, result_o.prd, result_o.data,
               result_o.write_prf, result_o.is_store,
               result_o.exception_valid);
    end
  endtask

  task automatic wait_mem_request(
      input logic [LQ_ID_W-1:0] lq_id,
      input logic [XLEN-1:0] address
  );
    integer cycles;
    begin
      cycles = 0;
      while (!mem_req_o.valid) begin
        @(posedge clk_i);
        #1;
        cycles = cycles + 1;
        if (cycles > 12)
          $fatal(1, "timeout waiting for Load memory request");
      end
      if (mem_req_o.lq_id != lq_id || mem_req_o.address != address)
        $fatal(1, "Load memory request mismatch");
    end
  endtask

  task automatic accept_mem_and_respond(
      input logic [LQ_ID_W-1:0] lq_id,
      input logic [XLEN-1:0] word
  );
    begin
      @(negedge clk_i);
      mem_req_ready_i = 1'b1;
      @(posedge clk_i);
      #1;
      mem_req_ready_i = 1'b0;
      @(negedge clk_i);
      mem_resp_i.valid = 1'b1;
      mem_resp_i.lq_id = lq_id;
      mem_resp_i.data = word;
      #1;
      if (!mem_resp_ready_o)
        $fatal(1, "LSU did not accept matching memory response");
      @(posedge clk_i);
      #1;
      mem_resp_i = '0;
    end
  endtask

  initial begin
    execute_uop_t uop;
    integer cycles;

    clear_controls();
    repeat (2) @(posedge clk_i);
    @(negedge clk_i);
    rst_i = 1'b0;
    @(posedge clk_i);
    #1;
    if (!issue_ready_o || result_valid_o || mem_req_o.valid)
      $fatal(1, "reset state mismatch");

    // Store AGU: byte lane alignment and Store completion.
    uop = make_store(5'd2, 3'd1, MEM_SB,
                     32'h8000_0100, 32'd2, 32'h0000_00aa, '0);
    issue_uop(uop);
    if (!sq_update_valid_o || sq_update_id_o != 3'd1 ||
        sq_update_address_o != 32'h8000_0102 ||
        sq_update_byte_enable_o != 4'b0001 ||
        sq_update_data_o != 32'h0000_00aa ||
        sq_update_exception_valid_o)
      $fatal(1, "Store AGU/update mismatch");
    @(posedge clk_i);
    #1;
    expect_result(5'd2, 6'd0, 32'd0, 1'b0, 1'b1, 1'b0);
    drain_result();

    // Non-conflicting Load issues an aligned word request and extracts LB data.
    uop = make_load(5'd8, 3'd0, 6'd20, MEM_LB,
                    32'h8000_0200, 32'd1, '0);
    issue_uop(uop);
    if (!lq_address_valid_o || lq_address_id_o != 3'd0 ||
        lq_address_o != 32'h8000_0201)
      $fatal(1, "Load address update mismatch");
    wait_mem_request(3'd0, 32'h8000_0201);
    accept_mem_and_respond(3'd0, 32'h0000_0080);
    expect_result(5'd8, 6'd20, 32'hffff_ff80, 1'b1, 1'b0, 1'b0);
    if (!lq_complete_valid_o || lq_complete_id_o != 3'd0 ||
        lq_complete_forwarded_o)
      $fatal(1, "Load completion pulse mismatch");
    drain_result();

    // Nearest older matching Store forwards a byte without a memory request.
    sq_entries_i[0] = '0;
    sq_entries_i[0].valid = 1'b1;
    sq_entries_i[0].rob_id = 5'd9;
    sq_entries_i[0].address_valid = 1'b1;
    sq_entries_i[0].address = 32'h8000_0301;
    sq_entries_i[0].data_valid = 1'b1;
    sq_entries_i[0].data = 32'h0000_0080;
    sq_entries_i[0].byte_enable = 4'b0001;
    // A farther matching Store in the opposite half of the reduction tree
    // must lose to entry 0 (ROB 9 is nearer to the Load at ROB 10).
    sq_entries_i[7] = '0;
    sq_entries_i[7].valid = 1'b1;
    sq_entries_i[7].rob_id = 5'd5;
    sq_entries_i[7].address_valid = 1'b1;
    sq_entries_i[7].address = 32'h8000_0301;
    sq_entries_i[7].data_valid = 1'b1;
    sq_entries_i[7].data = 32'h0000_007f;
    sq_entries_i[7].byte_enable = 4'b0001;
    uop = make_load(5'd10, 3'd1, 6'd21, MEM_LB,
                    32'h8000_0300, 32'd1, '0);
    issue_uop(uop);
    cycles = 0;
    while (!result_valid_o) begin
      @(posedge clk_i);
      #1;
      cycles = cycles + 1;
      if (mem_req_o.valid)
        $fatal(1, "forwarded Load incorrectly accessed memory");
      if (cycles > 8)
        $fatal(1, "timeout waiting for forwarded Load");
    end
    expect_result(5'd10, 6'd21, 32'hffff_ff80, 1'b1, 1'b0, 1'b0);
    if (!lq_complete_valid_o || !lq_complete_forwarded_o)
      $fatal(1, "forwarded Load completion metadata mismatch");
    drain_result();

    // Unknown older Store blocks the Load until its address becomes known.
    sq_entries_i[0] = '0;
    sq_entries_i[7] = '0;
    sq_entries_i[0].valid = 1'b1;
    sq_entries_i[0].rob_id = 5'd11;
    sq_entries_i[0].address_valid = 1'b0;
    uop = make_load(5'd12, 3'd2, 6'd22, MEM_LW,
                    32'h8000_0400, 32'd0, '0);
    issue_uop(uop);
    repeat (4) begin
      @(posedge clk_i);
      #1;
      if (mem_req_o.valid || result_valid_o)
        $fatal(1, "Load bypassed unknown older Store");
    end
    sq_entries_i[0].address_valid = 1'b1;
    sq_entries_i[0].address = 32'h8000_0500;
    sq_entries_i[0].data_valid = 1'b1;
    sq_entries_i[0].byte_enable = 4'b1111;
    wait_mem_request(3'd2, 32'h8000_0400);
    accept_mem_and_respond(3'd2, 32'h1234_5678);
    expect_result(5'd12, 6'd22, 32'h1234_5678, 1'b1, 1'b0, 1'b0);
    drain_result();

    // Byte-addressed Data RAM supports an unaligned halfword window.
    sq_entries_i[0] = '0;
    uop = make_load(5'd13, 3'd3, 6'd23, MEM_LH,
                    32'h8000_0600, 32'd1, '0);
    issue_uop(uop);
    if (!lq_address_valid_o || lq_address_id_o != 3'd3 ||
        lq_address_o != 32'h8000_0601)
      $fatal(1, "Unaligned Load address update mismatch");
    wait_mem_request(3'd3, 32'h8000_0601);
    accept_mem_and_respond(3'd3, 32'h0000_8000);
    expect_result(5'd13, 6'd23, 32'hffff_8000, 1'b1, 1'b0, 1'b0);
    if (!lq_complete_valid_o || lq_complete_id_o != 3'd3 ||
        lq_complete_forwarded_o)
      $fatal(1, "Unaligned Load completion pulse mismatch");
    drain_result();

    // Recovery kills an in-flight speculative Load and suppresses all side effects.
    uop = make_load(5'd14, 3'd4, 6'd24, MEM_LW,
                    32'h8000_0700, 32'd0, 4'b0010);
    issue_uop(uop);
    @(negedge clk_i);
    recovery_i.valid = 1'b1;
    recovery_i.cause = REC_BRANCH;
    recovery_i.checkpoint_id = 2'd1;
    #1;
    if (lq_address_valid_o || mem_req_o.valid || sq_update_valid_o)
      $fatal(1, "recovery did not suppress LSU side effects");
    @(posedge clk_i);
    #1;
    recovery_i = '0;
    #1;
    if (!issue_ready_o || result_valid_o || mem_req_o.valid)
      $fatal(1, "recovery did not return LSU to idle");

    $display("PASS: lsu_pipeline directed tests");
    $finish;
  end

  initial begin
    #50000;
    $fatal(1, "timeout");
  end
endmodule
