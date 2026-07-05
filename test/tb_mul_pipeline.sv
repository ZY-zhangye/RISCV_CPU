`timescale 1ns/1ps

import core_types_pkg::*;

module tb_mul_pipeline;
  logic clk_i = 1'b0;
  logic rst_i = 1'b1;

  logic req_valid_i = 1'b0;
  logic req_ready_o;
  execute_uop_t req_uop_i = '0;

  logic result_valid_o;
  logic result_ready_i = 1'b0;
  completion_t result_o;

  recovery_t recovery_i = '0;

  mul_pipeline dut (.*);

  always #5 clk_i = ~clk_i;

  function automatic execute_uop_t make_mul(
      input logic [ROB_ID_W-1:0] rob_id,
      input logic [PRD_W-1:0] prd,
      input mul_op_t mul_op,
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
      uop.fu_type = FU_MUL;
      uop.mul_op = mul_op;
      uop.branch_mask = branch_mask;
      uop.write_rd = 1'b1;
      uop.need_rs1 = 1'b1;
      uop.need_rs2 = 1'b1;
      make_mul = uop;
    end
  endfunction

  function automatic logic [XLEN-1:0] reference_mul(
      input mul_op_t mul_op,
      input logic [XLEN-1:0] lhs,
      input logic [XLEN-1:0] rhs
  );
    logic signed [32:0] norm_lhs;
    logic signed [32:0] norm_rhs;
    logic signed [65:0] product;
    begin
      norm_lhs = (mul_op == MUL_MULHU) ?
                 $signed({1'b0, lhs}) : $signed({lhs[31], lhs});
      norm_rhs = ((mul_op == MUL_MULHSU) || (mul_op == MUL_MULHU)) ?
                 $signed({1'b0, rhs}) : $signed({rhs[31], rhs});
      product = norm_lhs * norm_rhs;
      reference_mul = (mul_op == MUL_MUL) ?
                      product[31:0] : product[63:32];
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
        $fatal(1, "mul_pipeline unexpectedly not ready");
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
        if (cycles > 20)
          $fatal(1, "timeout waiting for multiply completion");
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
          result_o.data !== data || result_o.producer !== PROD_MUL ||
          !result_o.write_prf || result_o.is_store ||
          result_o.exception_valid)
        $fatal(1, "multiply completion mismatch rob=%0d prd=%0d data=%h",
               result_o.rob_id, result_o.prd, result_o.data);
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
        $fatal(1, "multiply completion did not drain");
    end
  endtask

  task automatic run_op(
      input mul_op_t mul_op,
      input logic [XLEN-1:0] lhs,
      input logic [XLEN-1:0] rhs,
      input logic [XLEN-1:0] expected
  );
    integer cycles;
    begin
      issue_one(make_mul(5'd3, 6'd20, mul_op, lhs, rhs, '0));
      wait_result(cycles);
      expect_result(5'd3, 6'd20, expected);
      drain_result();
    end
  endtask

  initial begin
    execute_uop_t uop;
    completion_t held_result;
    integer cycles;
    integer output_index;
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
      $fatal(1, "mul_pipeline reset/idle state mismatch");

    // Fixed no-stall latency is four cycles from input acceptance to result.
    issue_one(make_mul(5'd1, 6'd10, MUL_MUL,
                       32'hffff_fffe, 32'd3, '0));
    wait_result(cycles);
    if (cycles != 4)
      $fatal(1, "multiply latency mismatch: expected 4, got %0d", cycles);
    expect_result(5'd1, 6'd10, 32'hffff_fffa);
    drain_result();

    // All four RV32M multiply signedness/result selections.
    run_op(MUL_MUL,    32'h8000_0001, 32'd3, 32'h8000_0003);
    run_op(MUL_MULH,   32'hffff_fffe, 32'd3, 32'hffff_ffff);
    run_op(MUL_MULHSU, 32'hffff_fffe, 32'hffff_ffff, 32'hffff_fffe);
    run_op(MUL_MULHU,  32'hffff_ffff, 32'hffff_fffe, 32'hffff_fffd);

    // Compare the explicit four-part DSP decomposition against a behavioral
    // 33x33 reference over random operands and every RV32M multiply opcode.
    for (sample = 0; sample < 24; sample = sample + 1) begin
      random_lhs = $urandom;
      random_rhs = $urandom;
      run_op(MUL_MUL, random_lhs, random_rhs,
             reference_mul(MUL_MUL, random_lhs, random_rhs));
      run_op(MUL_MULH, random_lhs, random_rhs,
             reference_mul(MUL_MULH, random_lhs, random_rhs));
      run_op(MUL_MULHSU, random_lhs, random_rhs,
             reference_mul(MUL_MULHSU, random_lhs, random_rhs));
      run_op(MUL_MULHU, random_lhs, random_rhs,
             reference_mul(MUL_MULHU, random_lhs, random_rhs));
    end

    // Four consecutive requests must emerge in order at one result per cycle.
    result_ready_i = 1'b1;
    @(negedge clk_i);
    req_valid_i = 1'b1;
    req_uop_i = make_mul(5'd4, 6'd24, MUL_MUL, 32'd2, 32'd7, '0);
    @(posedge clk_i); #1;
    @(negedge clk_i);
    if (!req_ready_o) $fatal(1, "pipeline lost unit throughput at request 1");
    req_uop_i = make_mul(5'd5, 6'd25, MUL_MUL, 32'd3, 32'd7, '0);
    @(posedge clk_i); #1;
    @(negedge clk_i);
    if (!req_ready_o) $fatal(1, "pipeline lost unit throughput at request 2");
    req_uop_i = make_mul(5'd6, 6'd26, MUL_MUL, 32'd4, 32'd7, '0);
    @(posedge clk_i); #1;
    @(negedge clk_i);
    if (!req_ready_o) $fatal(1, "pipeline lost unit throughput at request 3");
    req_uop_i = make_mul(5'd7, 6'd27, MUL_MUL, 32'd5, 32'd7, '0);
    @(posedge clk_i); #1;
    req_valid_i = 1'b0;
    req_uop_i = '0;

    output_index = 0;
    cycles = 0;
    while (output_index < 4) begin
      @(posedge clk_i);
      #1;
      cycles = cycles + 1;
      if (result_valid_o) begin
        unique case (output_index)
          0: expect_result(5'd4, 6'd24, 32'd14);
          1: expect_result(5'd5, 6'd25, 32'd21);
          2: expect_result(5'd6, 6'd26, 32'd28);
          3: expect_result(5'd7, 6'd27, 32'd35);
        endcase
        output_index = output_index + 1;
      end
      if (cycles > 12)
        $fatal(1, "timeout in throughput test");
    end
    // The fourth result was observed after the edge; keep ready asserted
    // through the following edge so that its handshake actually completes.
    @(posedge clk_i);
    #1;
    result_ready_i = 1'b0;
    if (result_valid_o)
      $fatal(1, "throughput test left an undrained result");

    // Result payload remains stable while the consumer is stalled.
    issue_one(make_mul(5'd8, 6'd28, MUL_MUL,
                       32'h1234_5678, 32'd2, '0));
    wait_result(cycles);
    held_result = result_o;
    repeat (3) begin
      @(posedge clk_i);
      #1;
      if (!result_valid_o || (result_o !== held_result))
        $fatal(1, "multiply result changed under backpressure");
    end
    drain_result();

    // Kill an in-flight multiply before it reaches the completion FIFO.
    issue_one(make_mul(5'd9, 6'd29, MUL_MUL,
                       32'd9, 32'd9, 4'b0010));
    repeat (2) @(posedge clk_i);
    @(negedge clk_i);
    recovery_i.valid = 1'b1;
    recovery_i.cause = REC_BRANCH;
    recovery_i.checkpoint_id = 2'd1;
    #1;
    if (result_valid_o || req_ready_o)
      $fatal(1, "recovery did not suppress killed multiply");
    @(posedge clk_i); #1;
    recovery_i = '0;
    repeat (7) begin
      @(posedge clk_i); #1;
      if (result_valid_o)
        $fatal(1, "killed in-flight multiply reached completion");
    end

    // An unrelated branch recovery preserves the operation and clears its bit.
    issue_one(make_mul(5'd10, 6'd30, MUL_MUL,
                       32'd11, 32'd12, 4'b0010));
    @(posedge clk_i);
    @(negedge clk_i);
    recovery_i.valid = 1'b1;
    recovery_i.cause = REC_BRANCH;
    recovery_i.checkpoint_id = 2'd0;
    @(posedge clk_i); #1;
    recovery_i = '0;
    wait_result(cycles);
    expect_result(5'd10, 6'd30, 32'd132);
    drain_result();

    // FIFO recovery compacts a surviving second result behind a killed head.
    issue_one(make_mul(5'd11, 6'd31, MUL_MUL,
                       32'd13, 32'd2, 4'b0100));
    issue_one(make_mul(5'd12, 6'd32, MUL_MUL,
                       32'd17, 32'd2, 4'b0010));
    wait_result(cycles);
    expect_result(5'd11, 6'd31, 32'd26);
    @(posedge clk_i); #1; // Allow the second result to enter FIFO slot 1.
    @(negedge clk_i);
    recovery_i.valid = 1'b1;
    recovery_i.cause = REC_BRANCH;
    recovery_i.checkpoint_id = 2'd2;
    #1;
    if (result_valid_o)
      $fatal(1, "killed FIFO head remained visible during recovery");
    @(posedge clk_i); #1;
    recovery_i = '0;
    #1;
    expect_result(5'd12, 6'd32, 32'd34);
    drain_result();

    // Exception recovery flushes every pipeline/FIFO entry.
    uop = make_mul(5'd13, 6'd33, MUL_MUL, 32'd19, 32'd3, '0);
    issue_one(uop);
    @(negedge clk_i);
    recovery_i.valid = 1'b1;
    recovery_i.cause = REC_EXCEPT;
    @(posedge clk_i); #1;
    recovery_i = '0;
    repeat (7) begin
      @(posedge clk_i); #1;
      if (result_valid_o)
        $fatal(1, "exception recovery did not flush multiply pipeline");
    end

    $display("PASS: mul_pipeline directed tests");
    $finish;
  end

  initial begin
    #50000;
    $fatal(1, "timeout");
  end
endmodule
