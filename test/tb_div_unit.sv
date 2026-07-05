`timescale 1ns/1ps

import core_types_pkg::*;

module tb_div_unit;
  logic clk_i = 1'b0;
  logic rst_i = 1'b1;

  logic req_valid_i = 1'b0;
  logic req_ready_o;
  execute_uop_t req_uop_i = '0;

  logic result_valid_o;
  logic result_ready_i = 1'b0;
  completion_t result_o;

  recovery_t recovery_i = '0;

  localparam logic [31:0] INT_MIN = 32'h8000_0000;
  localparam logic [31:0] NEG_ONE = 32'hffff_ffff;

  div_unit dut (.*);

  always #5 clk_i = ~clk_i;

  function automatic logic [31:0] negate32(input logic [31:0] value);
    begin
      negate32 = ~value + 32'd1;
    end
  endfunction

  function automatic execute_uop_t make_div(
      input logic [ROB_ID_W-1:0] rob_id,
      input logic [PRD_W-1:0] prd,
      input div_op_t div_op,
      input logic [XLEN-1:0] lhs,
      input logic [XLEN-1:0] rhs,
      input logic [CHECKPOINTS-1:0] branch_mask
  );
    execute_uop_t uop;
    begin
      uop = '0;
      uop.valid = 1'b1;
      uop.rob_id = rob_id;
      uop.prd = prd;
      uop.src1 = lhs;
      uop.src2 = rhs;
      uop.fu_type = FU_DIV;
      uop.div_op = div_op;
      uop.branch_mask = branch_mask;
      uop.write_rd = 1'b1;
      uop.need_rs1 = 1'b1;
      uop.need_rs2 = 1'b1;
      make_div = uop;
    end
  endfunction

  function automatic logic [XLEN-1:0] reference_div(
      input div_op_t div_op,
      input logic [XLEN-1:0] lhs,
      input logic [XLEN-1:0] rhs
  );
    logic signed_op;
    logic rem_op;
    logic lhs_neg;
    logic rhs_neg;
    logic quotient_neg;
    logic remainder_neg;
    logic [31:0] lhs_mag;
    logic [31:0] rhs_mag;
    logic [31:0] quotient;
    logic [31:0] remainder;
    begin
      signed_op = (div_op == DIV_DIV) || (div_op == DIV_REM);
      rem_op = (div_op == DIV_REM) || (div_op == DIV_REMU);

      if (rhs == 32'b0) begin
        reference_div = rem_op ? lhs : 32'hffff_ffff;
      end else if (signed_op && (lhs == INT_MIN) && (rhs == NEG_ONE)) begin
        reference_div = rem_op ? 32'b0 : INT_MIN;
      end else begin
        lhs_neg = signed_op && lhs[31];
        rhs_neg = signed_op && rhs[31];
        lhs_mag = lhs_neg ? negate32(lhs) : lhs;
        rhs_mag = rhs_neg ? negate32(rhs) : rhs;
        quotient = lhs_mag / rhs_mag;
        remainder = lhs_mag % rhs_mag;
        quotient_neg = signed_op && (lhs[31] ^ rhs[31]);
        remainder_neg = signed_op && lhs[31];

        if (quotient_neg)
          quotient = negate32(quotient);
        if (remainder_neg)
          remainder = negate32(remainder);

        reference_div = rem_op ? remainder : quotient;
      end
    end
  endfunction

  task automatic clear_inputs;
    begin
      req_valid_i = 1'b0;
      req_uop_i = '0;
      result_ready_i = 1'b0;
      recovery_i = '0;
    end
  endtask

  task automatic issue_one(input execute_uop_t uop);
    begin
      @(negedge clk_i);
      if (!req_ready_o)
        $fatal(1, "div_unit unexpectedly not ready");
      req_valid_i = 1'b1;
      req_uop_i = uop;
      @(posedge clk_i);
      #1;
      req_valid_i = 1'b0;
      req_uop_i = '0;
    end
  endtask

  task automatic wait_result(output integer cycles);
    begin
      cycles = 0;
      while (!result_valid_o) begin
        @(posedge clk_i);
        #1;
        cycles = cycles + 1;
        if (cycles > 40)
          $fatal(1, "timeout waiting for divide completion");
      end
    end
  endtask

  task automatic expect_result(
      input logic [ROB_ID_W-1:0] rob_id,
      input logic [PRD_W-1:0] prd,
      input logic [XLEN-1:0] data
  );
    begin
      if (!result_valid_o || !result_o.valid ||
          result_o.rob_id !== rob_id || result_o.prd !== prd ||
          result_o.data !== data || result_o.producer !== PROD_DIV ||
          !result_o.write_prf || result_o.is_store ||
          result_o.exception_valid)
        $fatal(1, "divide completion mismatch rob=%0d prd=%0d data=%h expected=%h",
               result_o.rob_id, result_o.prd, result_o.data, data);
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
        $fatal(1, "divide completion did not drain");
    end
  endtask

  task automatic run_op(
      input div_op_t div_op,
      input logic [XLEN-1:0] lhs,
      input logic [XLEN-1:0] rhs,
      input logic [XLEN-1:0] expected
  );
    integer cycles;
    begin
      issue_one(make_div(5'd3, 6'd20, div_op, lhs, rhs, '0));
      wait_result(cycles);
      expect_result(5'd3, 6'd20, expected);
      drain_result();
    end
  endtask

  initial begin
    execute_uop_t uop;
    completion_t held_result;
    integer cycles;
    integer sample;
    logic [XLEN-1:0] random_lhs;
    logic [XLEN-1:0] random_rhs;

    clear_inputs();
    repeat (2) @(posedge clk_i);
    @(negedge clk_i);
    rst_i = 1'b0;
    @(posedge clk_i);
    #1;
    if (!req_ready_o || result_valid_o)
      $fatal(1, "div_unit reset/idle state mismatch");

    // Normal no-stall latency is 18 cycles from input acceptance to result.
    issue_one(make_div(5'd1, 6'd10, DIV_DIVU, 32'd100, 32'd7, '0));
    if (req_ready_o)
      $fatal(1, "div_unit ready while a divide is active");
    wait_result(cycles);
    if (cycles != 18)
      $fatal(1, "divide latency mismatch: expected 18, got %0d", cycles);
    expect_result(5'd1, 6'd10, 32'd14);
    drain_result();

    // Directed signed/unsigned quotient and remainder cases.
    run_op(DIV_DIV,  32'hffff_ffeb, 32'd4, reference_div(DIV_DIV,  32'hffff_ffeb, 32'd4));
    run_op(DIV_DIV,  32'd21, 32'hffff_fffc, reference_div(DIV_DIV,  32'd21, 32'hffff_fffc));
    run_op(DIV_DIVU, 32'hffff_fffe, 32'd2, reference_div(DIV_DIVU, 32'hffff_fffe, 32'd2));
    run_op(DIV_REM,  32'hffff_ffeb, 32'd4, reference_div(DIV_REM,  32'hffff_ffeb, 32'd4));
    run_op(DIV_REMU, 32'hffff_fffe, 32'd7, reference_div(DIV_REMU, 32'hffff_fffe, 32'd7));

    // RISC-V architectural special cases.
    run_op(DIV_DIV,  32'h1234_5678, 32'b0, 32'hffff_ffff);
    run_op(DIV_DIVU, 32'h89ab_cdef, 32'b0, 32'hffff_ffff);
    run_op(DIV_REM,  32'h8000_0001, 32'b0, 32'h8000_0001);
    run_op(DIV_REMU, 32'h7654_3210, 32'b0, 32'h7654_3210);
    run_op(DIV_DIV,  INT_MIN, NEG_ONE, INT_MIN);
    run_op(DIV_REM,  INT_MIN, NEG_ONE, 32'b0);

    // Random cross-checks against an explicit architectural reference model.
    for (sample = 0; sample < 20; sample = sample + 1) begin
      random_lhs = $urandom;
      random_rhs = $urandom;
      run_op(DIV_DIV, random_lhs, random_rhs,
             reference_div(DIV_DIV, random_lhs, random_rhs));
      run_op(DIV_DIVU, random_lhs, random_rhs,
             reference_div(DIV_DIVU, random_lhs, random_rhs));
      run_op(DIV_REM, random_lhs, random_rhs,
             reference_div(DIV_REM, random_lhs, random_rhs));
      run_op(DIV_REMU, random_lhs, random_rhs,
             reference_div(DIV_REMU, random_lhs, random_rhs));
    end

    // The single-inflight unit must deassert ready while busy.
    issue_one(make_div(5'd4, 6'd21, DIV_DIVU, 32'd1000, 32'd13, '0));
    repeat (4) begin
      @(posedge clk_i);
      #1;
      if (req_ready_o)
        $fatal(1, "div_unit accepted overlap while busy");
    end
    wait_result(cycles);
    expect_result(5'd4, 6'd21, reference_div(DIV_DIVU, 32'd1000, 32'd13));
    drain_result();

    // Result payload remains stable while the consumer is stalled.
    issue_one(make_div(5'd5, 6'd22, DIV_REMU,
                       32'h1234_5678, 32'd97, '0));
    wait_result(cycles);
    held_result = result_o;
    repeat (3) begin
      @(posedge clk_i);
      #1;
      if (!result_valid_o || (result_o !== held_result))
        $fatal(1, "divide result changed under backpressure");
    end
    drain_result();

    // Kill an in-flight divide before it reaches OUTPUT.
    issue_one(make_div(5'd6, 6'd23, DIV_DIVU,
                       32'd999, 32'd17, 4'b0010));
    repeat (5) @(posedge clk_i);
    @(negedge clk_i);
    recovery_i.valid = 1'b1;
    recovery_i.cause = REC_BRANCH;
    recovery_i.checkpoint_id = 2'd1;
    #1;
    if (result_valid_o || req_ready_o)
      $fatal(1, "recovery did not suppress killed divide");
    @(posedge clk_i); #1;
    recovery_i = '0;
    #1;
    if (!req_ready_o)
      $fatal(1, "div_unit did not return idle after killed divide");
    repeat (24) begin
      @(posedge clk_i); #1;
      if (result_valid_o)
        $fatal(1, "killed in-flight divide reached completion");
    end

    // An unrelated branch recovery preserves the divide and clears its bit.
    issue_one(make_div(5'd7, 6'd24, DIV_REMU,
                       32'd12345, 32'd101, 4'b0010));
    repeat (3) @(posedge clk_i);
    @(negedge clk_i);
    recovery_i.valid = 1'b1;
    recovery_i.cause = REC_BRANCH;
    recovery_i.checkpoint_id = 2'd0;
    @(posedge clk_i); #1;
    recovery_i = '0;
    wait_result(cycles);
    expect_result(5'd7, 6'd24, reference_div(DIV_REMU, 32'd12345, 32'd101));
    drain_result();

    // Kill a completed but undrained result at OUTPUT.
    issue_one(make_div(5'd8, 6'd25, DIV_DIVU,
                       32'd4096, 32'd64, 4'b0100));
    wait_result(cycles);
    expect_result(5'd8, 6'd25, 32'd64);
    @(negedge clk_i);
    recovery_i.valid = 1'b1;
    recovery_i.cause = REC_BRANCH;
    recovery_i.checkpoint_id = 2'd2;
    #1;
    if (result_valid_o)
      $fatal(1, "killed OUTPUT divide remained visible during recovery");
    @(posedge clk_i); #1;
    recovery_i = '0;
    #1;
    if (!req_ready_o || result_valid_o)
      $fatal(1, "div_unit did not clear killed OUTPUT result");

    // Exception recovery flushes the active divide.
    uop = make_div(5'd9, 6'd26, DIV_DIVU, 32'd777, 32'd19, '0);
    issue_one(uop);
    @(negedge clk_i);
    recovery_i.valid = 1'b1;
    recovery_i.cause = REC_EXCEPT;
    @(posedge clk_i); #1;
    recovery_i = '0;
    repeat (24) begin
      @(posedge clk_i); #1;
      if (result_valid_o)
        $fatal(1, "exception recovery did not flush divide unit");
    end

    $display("PASS: div_unit directed tests");
    $finish;
  end

  initial begin
    #200000;
    $fatal(1, "timeout");
  end
endmodule
