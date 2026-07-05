`timescale 1ns/1ps

import core_types_pkg::*;

module tb_int_pipeline0;
  logic clk_i = 1'b0;
  logic rst_i = 1'b1;

  logic ex_valid_i = 1'b0;
  logic ex_ready_o;
  execute_uop_t ex_uop_i = '0;

  logic result_valid_o;
  logic result_ready_i = 1'b0;
  completion_t result_o;

  recovery_t recovery_i = '0;

  int_pipeline0 dut (.*);

  always #5 clk_i = ~clk_i;

  function automatic execute_uop_t make_uop(
      input logic [ROB_ID_W-1:0] rob_id,
      input logic [PRD_W-1:0] prd,
      input alu_op_t alu_op,
      input logic [XLEN-1:0] src1,
      input logic [XLEN-1:0] src2,
      input logic [XLEN-1:0] imm,
      input logic need_rs1,
      input logic need_rs2,
      input logic write_rd,
      input logic [CHECKPOINTS-1:0] branch_mask
  );
    execute_uop_t uop;
    begin
      uop = '0;
      uop.valid = 1'b1;
      uop.rob_id = rob_id;
      uop.prd = prd;
      uop.src1 = src1;
      uop.src2 = src2;
      uop.imm = imm;
      uop.pc = 32'h8000_1000;
      uop.fu_type = FU_INT;
      uop.alu_op = alu_op;
      uop.branch_mask = branch_mask;
      uop.write_rd = write_rd;
      uop.need_rs1 = need_rs1;
      uop.need_rs2 = need_rs2;
      make_uop = uop;
    end
  endfunction

  task automatic clear_inputs;
    begin
      ex_valid_i = 1'b0;
      ex_uop_i = '0;
      result_ready_i = 1'b0;
      recovery_i = '0;
    end
  endtask

  task automatic issue_one(input execute_uop_t uop);
    begin
      @(negedge clk_i);
      if (!ex_ready_o)
        $fatal(1, "int_pipeline0 unexpectedly not ready");
      ex_valid_i = 1'b1;
      ex_uop_i = uop;
      @(posedge clk_i);
      #1;
      ex_valid_i = 1'b0;
      ex_uop_i = '0;
    end
  endtask

  task automatic expect_result(
      input logic [ROB_ID_W-1:0] rob_id,
      input logic [PRD_W-1:0] prd,
      input logic [XLEN-1:0] data,
      input logic write_prf
  );
    begin
      if (!result_valid_o)
        $fatal(1, "missing completion result");
      if (!result_o.valid || result_o.rob_id !== rob_id || result_o.prd !== prd ||
          result_o.data !== data || result_o.producer !== PROD_INT0 ||
          result_o.write_prf !== write_prf || result_o.is_store ||
          result_o.exception_valid)
        $fatal(1, "completion mismatch rob=%0d prd=%0d data=%h write=%b",
               result_o.rob_id, result_o.prd, result_o.data, result_o.write_prf);
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
        $fatal(1, "completion did not drain");
    end
  endtask

  task automatic run_op(
      input alu_op_t alu_op,
      input logic [XLEN-1:0] src1,
      input logic [XLEN-1:0] src2,
      input logic [XLEN-1:0] imm,
      input logic need_rs1,
      input logic need_rs2,
      input logic [XLEN-1:0] expected
  );
    execute_uop_t uop;
    begin
      uop = make_uop(5'd3, 6'd12, alu_op, src1, src2, imm,
                     need_rs1, need_rs2, 1'b1, '0);
      issue_one(uop);
      expect_result(5'd3, 6'd12, expected, 1'b1);
      drain_result();
    end
  endtask

  initial begin
    execute_uop_t uop_a;
    execute_uop_t uop_b;
    completion_t held_result;

    repeat (2) @(posedge clk_i);
    @(negedge clk_i);
    rst_i = 1'b0;
    clear_inputs();
    @(posedge clk_i);
    #1;
    if (!ex_ready_o || result_valid_o)
      $fatal(1, "reset/idle state mismatch");

    // Register and immediate ALU operations.
    run_op(ALU_ADD, 32'd7, 32'd5, 32'd0, 1'b1, 1'b1, 32'd12);
    run_op(ALU_ADD, 32'd7, 32'd0, 32'd9, 1'b1, 1'b0, 32'd16);
    run_op(ALU_SUB, 32'd7, 32'd9, 32'd0, 1'b1, 1'b1, 32'hffff_fffe);
    run_op(ALU_AND, 32'hf0f0_aa55, 32'h0ff0_0f0f, 32'd0,
           1'b1, 1'b1, 32'h00f0_0a05);
    run_op(ALU_OR, 32'hf0f0_0000, 32'h0000_0f0f, 32'd0,
           1'b1, 1'b1, 32'hf0f0_0f0f);
    run_op(ALU_XOR, 32'ha5a5_ffff, 32'hffff_0000, 32'd0,
           1'b1, 1'b1, 32'h5a5a_ffff);
    run_op(ALU_SLT, 32'hffff_fffb, 32'd3, 32'd0, 1'b1, 1'b1, 32'd1);
    run_op(ALU_SLTU, 32'hffff_fffb, 32'd3, 32'd0, 1'b1, 1'b1, 32'd0);

    // Shift operations use src2 for register form and imm for immediate form.
    run_op(ALU_SLL, 32'h0000_0003, 32'd4, 32'd0, 1'b1, 1'b1, 32'h0000_0030);
    run_op(ALU_SRL, 32'h8000_0000, 32'd4, 32'd0, 1'b1, 1'b1, 32'h0800_0000);
    run_op(ALU_SRA, 32'h8000_0000, 32'd4, 32'd0, 1'b1, 1'b1, 32'hf800_0000);
    run_op(ALU_SLL, 32'h0000_0003, 32'd0, 32'd5, 1'b1, 1'b0, 32'h0000_0060);

    // LUI/AUIPC ignore source register readiness and use imm/pc+imm.
    run_op(ALU_LUI, 32'hdead_beef, 32'h1234_5678, 32'h1234_5000,
           1'b0, 1'b0, 32'h1234_5000);
    uop_a = make_uop(5'd4, 6'd13, ALU_AUIPC, '0, '0, 32'h40,
                     1'b0, 1'b0, 1'b1, '0);
    uop_a.pc = 32'h8000_2000;
    issue_one(uop_a);
    expect_result(5'd4, 6'd13, 32'h8000_2040, 1'b1);
    drain_result();

    // A non-writing integer uop still completes ROB but does not write PRF.
    uop_a = make_uop(5'd5, 6'd0, ALU_PASS1, 32'hcafe_babe, '0, '0,
                     1'b1, 1'b0, 1'b0, '0);
    issue_one(uop_a);
    expect_result(5'd5, 6'd0, 32'hcafe_babe, 1'b0);

    // Completion buffer holds payload stable under backpressure.
    held_result = result_o;
    repeat (3) begin
      @(posedge clk_i);
      #1;
      if (!result_valid_o || result_o !== held_result || ex_ready_o)
        $fatal(1, "result hold/backpressure mismatch");
    end

    // Full buffer can drain and accept a new uop in the same cycle.
    @(negedge clk_i);
    result_ready_i = 1'b1;
    uop_b = make_uop(5'd6, 6'd14, ALU_XOR, 32'haaaa_0000, 32'h0000_5555,
                     '0, 1'b1, 1'b1, 1'b1, '0);
    ex_valid_i = 1'b1;
    ex_uop_i = uop_b;
    #1;
    if (!ex_ready_o)
      $fatal(1, "ready not asserted for drain+accept");
    @(posedge clk_i);
    #1;
    result_ready_i = 1'b0;
    ex_valid_i = 1'b0;
    ex_uop_i = '0;
    expect_result(5'd6, 6'd14, 32'haaaa_5555, 1'b1);
    drain_result();

    // Branch recovery kills buffered younger results.
    uop_a = make_uop(5'd7, 6'd15, ALU_ADD, 32'd1, 32'd2, '0,
                     1'b1, 1'b1, 1'b1, 4'b0100);
    issue_one(uop_a);
    expect_result(5'd7, 6'd15, 32'd3, 1'b1);
    @(negedge clk_i);
    recovery_i.valid = 1'b1;
    recovery_i.cause = REC_BRANCH;
    recovery_i.checkpoint_id = 2'd2;
    #1;
    if (result_valid_o)
      $fatal(1, "killed result remained visible during recovery");
    @(posedge clk_i);
    #1;
    if (result_valid_o)
      $fatal(1, "branch recovery did not clear killed result");
    recovery_i = '0;
    #1;
    if (!ex_ready_o)
      $fatal(1, "int_pipeline0 did not become ready after recovery");

    // Unrelated branch recovery preserves the result.
    uop_a = make_uop(5'd8, 6'd16, ALU_ADD, 32'd10, 32'd20, '0,
                     1'b1, 1'b1, 1'b1, 4'b0010);
    issue_one(uop_a);
    @(negedge clk_i);
    recovery_i.valid = 1'b1;
    recovery_i.cause = REC_BRANCH;
    recovery_i.checkpoint_id = 2'd0;
    @(posedge clk_i);
    #1;
    expect_result(5'd8, 6'd16, 32'd30, 1'b1);
    recovery_i = '0;
    drain_result();

    // Exception recovery clears any buffered result.
    uop_a = make_uop(5'd9, 6'd17, ALU_ADD, 32'd11, 32'd22, '0,
                     1'b1, 1'b1, 1'b1, '0);
    issue_one(uop_a);
    @(negedge clk_i);
    recovery_i.valid = 1'b1;
    recovery_i.cause = REC_EXCEPT;
    @(posedge clk_i);
    #1;
    if (result_valid_o)
      $fatal(1, "exception recovery did not clear result");
    recovery_i = '0;

    $display("PASS: int_pipeline0 directed tests");
    $finish;
  end

  initial begin
    #30000;
    $fatal(1, "timeout");
  end
endmodule
