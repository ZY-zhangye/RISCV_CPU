`timescale 1ns/1ps

import core_types_pkg::*;

module tb_int_branch_pipeline1;
  logic clk_i = 1'b0;
  logic rst_i = 1'b1;

  logic ex_valid_i = 1'b0;
  logic ex_ready_o;
  execute_uop_t ex_uop_i = '0;

  logic result_valid_o;
  logic result_ready_i = 1'b0;
  completion_t result_o;

  branch_resolve_t branch_event_o;
  recovery_t recovery_i = '0;

  int_branch_pipeline1 dut (.*);

  always #5 clk_i = ~clk_i;

  function automatic execute_uop_t make_int_uop(
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
      uop.write_rd = write_rd;
      uop.need_rs1 = need_rs1;
      uop.need_rs2 = need_rs2;
      uop.branch_mask = branch_mask;
      make_int_uop = uop;
    end
  endfunction

  function automatic execute_uop_t make_branch_uop(
      input logic [ROB_ID_W-1:0] rob_id,
      input logic [PRD_W-1:0] prd,
      input branch_op_t branch_op,
      input logic [XLEN-1:0] pc,
      input logic [XLEN-1:0] src1,
      input logic [XLEN-1:0] src2,
      input logic [XLEN-1:0] imm,
      input logic pred_taken,
      input logic [XLEN-1:0] pred_target,
      input logic write_rd,
      input logic [CP_W-1:0] checkpoint_id,
      input logic [CHECKPOINTS-1:0] branch_mask
  );
    execute_uop_t uop;
    begin
      uop = '0;
      uop.valid = 1'b1;
      uop.rob_id = rob_id;
      uop.prd = prd;
      uop.pc = pc;
      uop.src1 = src1;
      uop.src2 = src2;
      uop.imm = imm;
      uop.fu_type = FU_BRANCH;
      uop.branch_op = branch_op;
      uop.pred_taken = pred_taken;
      uop.pred_target = pred_target;
      uop.write_rd = write_rd;
      uop.need_rs1 = (branch_op != BR_JAL);
      uop.need_rs2 = (branch_op != BR_JAL) && (branch_op != BR_JALR);
      uop.checkpoint_id = checkpoint_id;
      uop.branch_mask = branch_mask;
      make_branch_uop = uop;
    end
  endfunction

  task automatic issue_one(input execute_uop_t uop);
    begin
      @(negedge clk_i);
      if (!ex_ready_o)
        $fatal(1, "int_branch_pipeline1 unexpectedly not ready");
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
      input logic write_prf,
      input logic exception_valid,
      input logic [XLEN-1:0] exception_tval
  );
    begin
      if (!result_valid_o || !result_o.valid)
        $fatal(1, "missing completion");
      if (result_o.rob_id !== rob_id || result_o.prd !== prd ||
          result_o.data !== data || result_o.producer !== PROD_INT1 ||
          result_o.write_prf !== write_prf ||
          result_o.exception_valid !== exception_valid ||
          result_o.exception_tval !== exception_tval)
        $fatal(1, "completion mismatch rob=%0d prd=%0d data=%h write=%b exc=%b tval=%h",
               result_o.rob_id, result_o.prd, result_o.data, result_o.write_prf,
               result_o.exception_valid, result_o.exception_tval);
    end
  endtask

  task automatic expect_no_branch_event;
    begin
      if (branch_event_o.valid)
        $fatal(1, "unexpected branch event");
    end
  endtask

  task automatic expect_branch_event(
      input logic [ROB_ID_W-1:0] rob_id,
      input logic [CP_W-1:0] checkpoint_id,
      input logic actual_taken,
      input logic [XLEN-1:0] actual_target,
      input logic mispredict,
      input logic is_branch,
      input logic is_jal,
      input logic is_jalr
  );
    begin
      if (!branch_event_o.valid)
        $fatal(1, "missing branch event");
      if (branch_event_o.rob_id !== rob_id ||
          branch_event_o.checkpoint_id !== checkpoint_id ||
          branch_event_o.actual_taken !== actual_taken ||
          branch_event_o.actual_target !== actual_target ||
          branch_event_o.redirect_pc !== actual_target ||
          branch_event_o.mispredict !== mispredict ||
          branch_event_o.update.taken !== actual_taken ||
          branch_event_o.update.is_branch !== is_branch ||
          branch_event_o.update.is_jal !== is_jal ||
          branch_event_o.update.is_jalr !== is_jalr)
        $fatal(1, "branch event mismatch rob=%0d taken=%b target=%h mis=%b type=%b%b%b",
               branch_event_o.rob_id, branch_event_o.actual_taken,
               branch_event_o.actual_target, branch_event_o.mispredict,
               branch_event_o.update.is_branch, branch_event_o.update.is_jal,
               branch_event_o.update.is_jalr);
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

  initial begin
    execute_uop_t uop;
    completion_t held_result;

    repeat (2) @(posedge clk_i);
    @(negedge clk_i);
    rst_i = 1'b0;
    recovery_i = '0;
    result_ready_i = 1'b0;
    @(posedge clk_i);
    #1;
    if (!ex_ready_o || result_valid_o || branch_event_o.valid)
      $fatal(1, "reset/idle state mismatch");

    // Simple INT1 ALU operations and immediate operand selection.
    uop = make_int_uop(5'd1, 6'd10, ALU_ADD, 32'd4, 32'd5, '0,
                       1'b1, 1'b1, 1'b1, '0);
    issue_one(uop);
    expect_result(5'd1, 6'd10, 32'd9, 1'b1, 1'b0, '0);
    expect_no_branch_event();
    drain_result();

    uop = make_int_uop(5'd2, 6'd11, ALU_OR, 32'h1000_0000, '0, 32'h0000_00ff,
                       1'b1, 1'b0, 1'b1, '0);
    issue_one(uop);
    expect_result(5'd2, 6'd11, 32'h1000_00ff, 1'b1, 1'b0, '0);
    expect_no_branch_event();
    drain_result();

    uop = make_int_uop(5'd3, 6'd12, ALU_SLT, 32'hffff_fffe, 32'd1, '0,
                       1'b1, 1'b1, 1'b1, '0);
    issue_one(uop);
    expect_result(5'd3, 6'd12, 32'd1, 1'b1, 1'b0, '0);
    drain_result();

    // Conditional branch predicted correctly not-taken.
    uop = make_branch_uop(5'd4, 6'd0, BR_EQ, 32'h8000_2000,
                          32'd1, 32'd2, 32'h20,
                          1'b0, 32'h0, 1'b0, 2'd1, '0);
    issue_one(uop);
    expect_result(5'd4, 6'd0, 32'd0, 1'b0, 1'b0, '0);
    expect_branch_event(5'd4, 2'd1, 1'b0, 32'h8000_2004, 1'b0,
                        1'b1, 1'b0, 1'b0);
    if (branch_event_o.update.target !== 32'h8000_2020)
      $fatal(1, "branch predictor update target mismatch");
    drain_result();

    // Direction mispredict: BNE is actually taken.
    uop = make_branch_uop(5'd5, 6'd0, BR_NE, 32'h8000_3000,
                          32'd1, 32'd2, 32'h30,
                          1'b0, 32'h0, 1'b0, 2'd2, '0);
    issue_one(uop);
    expect_branch_event(5'd5, 2'd2, 1'b1, 32'h8000_3030, 1'b1,
                        1'b1, 1'b0, 1'b0);
    drain_result();

    // Target mispredict: predicted taken but to the wrong target.
    uop = make_branch_uop(5'd6, 6'd0, BR_GEU, 32'h8000_4000,
                          32'd7, 32'd7, 32'h40,
                          1'b1, 32'h8000_4999, 1'b0, 2'd3, '0);
    issue_one(uop);
    expect_branch_event(5'd6, 2'd3, 1'b1, 32'h8000_4040, 1'b1,
                        1'b1, 1'b0, 1'b0);
    drain_result();

    // JAL writes link pc+4 and emits JAL predictor update.
    uop = make_branch_uop(5'd7, 6'd20, BR_JAL, 32'h8000_5000,
                          '0, '0, 32'h100,
                          1'b1, 32'h8000_5100, 1'b1, 2'd0, '0);
    issue_one(uop);
    expect_result(5'd7, 6'd20, 32'h8000_5004, 1'b1, 1'b0, '0);
    expect_branch_event(5'd7, 2'd0, 1'b1, 32'h8000_5100, 1'b0,
                        1'b0, 1'b1, 1'b0);
    drain_result();

    // JALR clears bit 0 in the target.
    uop = make_branch_uop(5'd8, 6'd21, BR_JALR, 32'h8000_6000,
                          32'h0000_1005, '0, 32'h3,
                          1'b1, 32'h0000_1008, 1'b1, 2'd1, '0);
    issue_one(uop);
    expect_result(5'd8, 6'd21, 32'h8000_6004, 1'b1, 1'b0, '0);
    expect_branch_event(5'd8, 2'd1, 1'b1, 32'h0000_1008, 1'b0,
                        1'b0, 1'b0, 1'b1);
    drain_result();

    // JALR target remains 2-byte aligned after bit0 clear: raise instruction-address-misaligned.
    uop = make_branch_uop(5'd9, 6'd22, BR_JALR, 32'h8000_7000,
                          32'h0000_1001, '0, 32'h2,
                          1'b1, 32'h0000_1002, 1'b1, 2'd2, '0);
    issue_one(uop);
    expect_result(5'd9, 6'd22, 32'h8000_7004, 1'b0, 1'b1, 32'h0000_1002);
    expect_branch_event(5'd9, 2'd2, 1'b1, 32'h0000_1002, 1'b0,
                        1'b0, 1'b0, 1'b1);
    drain_result();

    // Result backpressure holds completion, but branch event is a single-cycle pulse.
    uop = make_branch_uop(5'd10, 6'd0, BR_LT, 32'h8000_8000,
                          32'hffff_ffff, 32'd1, 32'h10,
                          1'b0, 32'h0, 1'b0, 2'd3, '0);
    issue_one(uop);
    expect_branch_event(5'd10, 2'd3, 1'b1, 32'h8000_8010, 1'b1,
                        1'b1, 1'b0, 1'b0);
    held_result = result_o;
    @(posedge clk_i);
    #1;
    if (!result_valid_o || result_o !== held_result || branch_event_o.valid || ex_ready_o)
      $fatal(1, "branch pulse/backpressure behavior mismatch");
    drain_result();

    // Branch recovery kills buffered younger completion.
    uop = make_int_uop(5'd11, 6'd23, ALU_ADD, 32'd1, 32'd2, '0,
                       1'b1, 1'b1, 1'b1, 4'b0010);
    issue_one(uop);
    expect_result(5'd11, 6'd23, 32'd3, 1'b1, 1'b0, '0);
    @(negedge clk_i);
    recovery_i.valid = 1'b1;
    recovery_i.cause = REC_BRANCH;
    recovery_i.checkpoint_id = 2'd1;
    #1;
    if (result_valid_o)
      $fatal(1, "killed completion visible during recovery");
    @(posedge clk_i);
    #1;
    if (result_valid_o)
      $fatal(1, "branch recovery did not clear completion");
    recovery_i = '0;
    #1;
    if (!ex_ready_o)
      $fatal(1, "not ready after recovery");

    $display("PASS: int_branch_pipeline1 directed tests");
    $finish;
  end

  initial begin
    #30000;
    $fatal(1, "timeout");
  end
endmodule
