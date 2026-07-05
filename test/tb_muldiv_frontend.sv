`timescale 1ns/1ps

import core_types_pkg::*;

module tb_muldiv_frontend;
  logic clk_i = 1'b0;
  logic rst_i = 1'b1;

  logic mdu_valid_i = 1'b0;
  logic mdu_ready_o;
  execute_uop_t mdu_uop_i = '0;

  logic mul_valid_o;
  logic mul_ready_i = 1'b0;
  completion_t mul_o;

  logic div_valid_o;
  logic div_ready_i = 1'b0;
  completion_t div_o;

  recovery_t recovery_i = '0;

  localparam logic [31:0] INT_MIN = 32'h8000_0000;
  localparam logic [31:0] NEG_ONE = 32'hffff_ffff;

  muldiv_frontend dut (.*);

  always #5 clk_i = ~clk_i;

  function automatic logic [31:0] negate32(input logic [31:0] value);
    begin
      negate32 = ~value + 32'd1;
    end
  endfunction

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
      reference_mul = (mul_op == MUL_MUL) ? product[31:0] : product[63:32];
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
        if (quotient_neg) quotient = negate32(quotient);
        if (remainder_neg) remainder = negate32(remainder);
        reference_div = rem_op ? remainder : quotient;
      end
    end
  endfunction

  task automatic clear_inputs;
    begin
      mdu_valid_i = 1'b0;
      mdu_uop_i = '0;
      mul_ready_i = 1'b0;
      div_ready_i = 1'b0;
      recovery_i = '0;
    end
  endtask

  task automatic issue_one(input execute_uop_t uop);
    begin
      @(negedge clk_i);
      mdu_uop_i = uop;
      mdu_valid_i = 1'b1;
      #1;
      if (!mdu_ready_o)
        $fatal(1, "muldiv_frontend unexpectedly not ready for fu=%0d", uop.fu_type);
      @(posedge clk_i);
      #1;
      mdu_valid_i = 1'b0;
      mdu_uop_i = '0;
    end
  endtask

  task automatic wait_mul(output integer cycles);
    begin
      cycles = 0;
      while (!mul_valid_o) begin
        @(posedge clk_i); #1;
        cycles = cycles + 1;
        if (cycles > 30) $fatal(1, "timeout waiting for MUL result");
      end
    end
  endtask

  task automatic wait_div(output integer cycles);
    begin
      cycles = 0;
      while (!div_valid_o) begin
        @(posedge clk_i); #1;
        cycles = cycles + 1;
        if (cycles > 45) $fatal(1, "timeout waiting for DIV result");
      end
    end
  endtask

  task automatic expect_mul(
      input logic [ROB_ID_W-1:0] rob_id,
      input logic [PRD_W-1:0] prd,
      input logic [XLEN-1:0] data
  );
    begin
      if (!mul_valid_o || !mul_o.valid || mul_o.rob_id !== rob_id ||
          mul_o.prd !== prd || mul_o.data !== data ||
          mul_o.producer !== PROD_MUL || !mul_o.write_prf)
        $fatal(1, "MUL completion mismatch data=%h expected=%h", mul_o.data, data);
    end
  endtask

  task automatic expect_div(
      input logic [ROB_ID_W-1:0] rob_id,
      input logic [PRD_W-1:0] prd,
      input logic [XLEN-1:0] data
  );
    begin
      if (!div_valid_o || !div_o.valid || div_o.rob_id !== rob_id ||
          div_o.prd !== prd || div_o.data !== data ||
          div_o.producer !== PROD_DIV || !div_o.write_prf)
        $fatal(1, "DIV completion mismatch data=%h expected=%h", div_o.data, data);
    end
  endtask

  task automatic drain_mul;
    begin
      @(negedge clk_i);
      mul_ready_i = 1'b1;
      @(posedge clk_i); #1;
      mul_ready_i = 1'b0;
      if (mul_valid_o) $fatal(1, "MUL result did not drain");
    end
  endtask

  task automatic drain_div;
    begin
      @(negedge clk_i);
      div_ready_i = 1'b1;
      @(posedge clk_i); #1;
      div_ready_i = 1'b0;
      if (div_valid_o) $fatal(1, "DIV result did not drain");
    end
  endtask

  initial begin
    integer cycles;

    clear_inputs();
    repeat (2) @(posedge clk_i);
    @(negedge clk_i);
    rst_i = 1'b0;
    @(posedge clk_i); #1;
    if (mul_valid_o || div_valid_o)
      $fatal(1, "muldiv_frontend reset output mismatch");

    issue_one(make_mul(5'd1, 6'd10, MUL_MUL, 32'd6, 32'd7, '0));
    wait_mul(cycles);
    expect_mul(5'd1, 6'd10, 32'd42);
    drain_mul();

    issue_one(make_div(5'd2, 6'd11, DIV_DIVU, 32'd100, 32'd7, '0));
    wait_div(cycles);
    expect_div(5'd2, 6'd11, 32'd14);
    drain_div();

    issue_one(make_mul(5'd3, 6'd12, MUL_MULHU,
                       32'hffff_ffff, 32'hffff_fffe, '0));
    wait_mul(cycles);
    expect_mul(5'd3, 6'd12, reference_mul(MUL_MULHU,
                                           32'hffff_ffff, 32'hffff_fffe));
    drain_mul();

    issue_one(make_div(5'd4, 6'd13, DIV_REM,
                       32'hffff_ffeb, 32'd4, '0));
    wait_div(cycles);
    expect_div(5'd4, 6'd13, reference_div(DIV_REM,
                                          32'hffff_ffeb, 32'd4));
    drain_div();

    // A busy DIV must not block a new MUL request.
    issue_one(make_div(5'd5, 6'd14, DIV_DIVU, 32'd1000, 32'd13, '0));
    issue_one(make_mul(5'd6, 6'd15, MUL_MUL, 32'd9, 32'd5, '0));
    wait_mul(cycles);
    expect_mul(5'd6, 6'd15, 32'd45);
    drain_mul();
    wait_div(cycles);
    expect_div(5'd5, 6'd14, reference_div(DIV_DIVU, 32'd1000, 32'd13));
    drain_div();

    // A busy DIV must reject a second DIV request.
    issue_one(make_div(5'd7, 6'd16, DIV_DIVU, 32'd777, 32'd19, '0));
    @(negedge clk_i);
    mdu_uop_i = make_div(5'd8, 6'd17, DIV_DIVU, 32'd123, 32'd5, '0);
    mdu_valid_i = 1'b1;
    #1;
    if (mdu_ready_o)
      $fatal(1, "muldiv_frontend accepted a second DIV while DIV unit was busy");
    mdu_valid_i = 1'b0;
    mdu_uop_i = '0;
    wait_div(cycles);
    expect_div(5'd7, 6'd16, reference_div(DIV_DIVU, 32'd777, 32'd19));
    drain_div();

    // Recovery is forwarded to the MUL pipeline.
    issue_one(make_mul(5'd9, 6'd18, MUL_MUL, 32'd11, 32'd11, 4'b0010));
    @(negedge clk_i);
    recovery_i.valid = 1'b1;
    recovery_i.cause = REC_BRANCH;
    recovery_i.checkpoint_id = 2'd1;
    @(posedge clk_i); #1;
    recovery_i = '0;
    repeat (8) begin
      @(posedge clk_i); #1;
      if (mul_valid_o) $fatal(1, "killed MUL reached frontend output");
    end

    // Recovery is forwarded to the DIV unit.
    issue_one(make_div(5'd10, 6'd19, DIV_DIVU, 32'd555, 32'd11, 4'b0100));
    repeat (4) @(posedge clk_i);
    @(negedge clk_i);
    recovery_i.valid = 1'b1;
    recovery_i.cause = REC_BRANCH;
    recovery_i.checkpoint_id = 2'd2;
    @(posedge clk_i); #1;
    recovery_i = '0;
    repeat (24) begin
      @(posedge clk_i); #1;
      if (div_valid_o) $fatal(1, "killed DIV reached frontend output");
    end

    $display("PASS: muldiv_frontend directed tests");
    $finish;
  end

  initial begin
    #200000;
    $fatal(1, "timeout");
  end
endmodule
