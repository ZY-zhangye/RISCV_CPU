`timescale 1ns/1ps

import core_types_pkg::*;

// div_unit.sv
// Single-inflight RV32M divide/remainder unit.
//
// The datapath uses unsigned radix-4 long division after signed operand
// normalization.  Each ITERATE cycle consumes two dividend bits, so a normal
// 32-bit operation completes in 16 divide iterations plus PREPARE/SIGN_FIX.
// Divide-by-zero and signed overflow follow the RISC-V architectural rules and
// bypass the iterative datapath.

module div_unit (
    input  logic         clk_i,
    input  logic         rst_i,

    input  logic         req_valid_i,
    output logic         req_ready_o,
    input  execute_uop_t req_uop_i,

    output logic         result_valid_o,
    input  logic         result_ready_i,
    output completion_t  result_o,

    input  recovery_t    recovery_i
);

  typedef enum logic [2:0] {
    ST_IDLE,
    ST_PREPARE,
    ST_ITERATE,
    ST_SIGN_FIX,
    ST_OUTPUT
  } div_state_t;

  typedef struct packed {
    logic [ROB_ID_W-1:0]     rob_id;
    logic [PRD_W-1:0]        prd;
    div_op_t                 div_op;
    logic [CHECKPOINTS-1:0]  branch_mask;
    logic                    write_rd;
  } div_meta_t;

  localparam logic [31:0] INT_MIN = 32'h8000_0000;
  localparam logic [31:0] NEG_ONE = 32'hffff_ffff;

  div_state_t state_q;
  div_meta_t  meta_q;

  logic [31:0] lhs_q;
  logic [31:0] rhs_q;
  logic [31:0] dividend_shift_q;
  logic [31:0] quotient_q;
  logic [33:0] remainder_q;
  logic [33:0] divisor1_q;
  logic [33:0] divisor2_q;
  logic [33:0] divisor3_q;
  logic [4:0]  iter_q;
  logic        quotient_neg_q;
  logic        remainder_neg_q;

  completion_t completion_q;

  logic accept_fire;
  logic output_killed;

  logic        prepare_signed_op;
  logic        prepare_rem_op;
  logic        prepare_lhs_neg;
  logic        prepare_rhs_neg;
  logic        prepare_div_by_zero;
  logic        prepare_signed_overflow;
  logic [31:0] prepare_lhs_mag;
  logic [31:0] prepare_rhs_mag;

  logic [33:0] iter_trial_remainder;
  logic [33:0] iter_minus1;
  logic [33:0] iter_minus2;
  logic [33:0] iter_minus3;
  logic [1:0]  iter_qdigit;
  logic [33:0] iter_remainder_next;
  logic [31:0] iter_quotient_next;
  logic [31:0] iter_dividend_shift_next;
  logic        iter_ge1;
  logic        iter_ge2;
  logic        iter_ge3;

  logic [31:0] fixed_quotient;
  logic [31:0] fixed_remainder;
  logic [31:0] fixed_result_data;

  function automatic logic is_signed_op(input div_op_t div_op);
    begin
      is_signed_op = (div_op == DIV_DIV) || (div_op == DIV_REM);
    end
  endfunction

  function automatic logic is_remainder_op(input div_op_t div_op);
    begin
      is_remainder_op = (div_op == DIV_REM) || (div_op == DIV_REMU);
    end
  endfunction

  function automatic logic [31:0] negate32(input logic [31:0] value);
    begin
      negate32 = ~value + 32'd1;
    end
  endfunction

  function automatic div_meta_t make_meta(input execute_uop_t uop);
    div_meta_t meta;
    begin
      meta = '0;
      meta.rob_id = uop.rob_id;
      meta.prd = uop.prd;
      meta.div_op = uop.div_op;
      meta.branch_mask = uop.branch_mask;
      meta.write_rd = uop.write_rd;
      make_meta = meta;
    end
  endfunction

  function automatic completion_t make_completion(
      input div_meta_t meta,
      input logic [31:0] data
  );
    completion_t completion;
    begin
      completion = '0;
      completion.valid = 1'b1;
      completion.prd = meta.prd;
      completion.rob_id = meta.rob_id;
      completion.data = data;
      completion.producer = PROD_DIV;
      completion.write_prf = meta.write_rd;
      completion.is_store = 1'b0;
      make_completion = completion;
    end
  endfunction

  function automatic logic [CHECKPOINTS-1:0] clear_checkpoint(
      input logic [CHECKPOINTS-1:0] mask,
      input logic [CP_W-1:0] checkpoint_id
  );
    logic [CHECKPOINTS-1:0] one_hot;
    begin
      one_hot = '0;
      one_hot[checkpoint_id] = 1'b1;
      clear_checkpoint = mask & ~one_hot;
    end
  endfunction

  assign accept_fire = req_valid_i && req_ready_o && req_uop_i.valid;
  assign req_ready_o = (state_q == ST_IDLE) && !recovery_i.valid;

  assign output_killed = recovery_i.valid && (state_q == ST_OUTPUT) &&
      ((recovery_i.cause == REC_EXCEPT) ||
       ((recovery_i.cause == REC_BRANCH) &&
        meta_q.branch_mask[recovery_i.checkpoint_id]));

  assign result_valid_o = (state_q == ST_OUTPUT) && !output_killed;
  assign result_o = result_valid_o ? completion_q : '0;

  assign prepare_signed_op = is_signed_op(meta_q.div_op);
  assign prepare_rem_op = is_remainder_op(meta_q.div_op);
  assign prepare_lhs_neg = prepare_signed_op && lhs_q[31];
  assign prepare_rhs_neg = prepare_signed_op && rhs_q[31];
  assign prepare_div_by_zero = (rhs_q == 32'b0);
  assign prepare_signed_overflow =
      prepare_signed_op && (lhs_q == INT_MIN) && (rhs_q == NEG_ONE);
  assign prepare_lhs_mag = prepare_lhs_neg ? negate32(lhs_q) : lhs_q;
  assign prepare_rhs_mag = prepare_rhs_neg ? negate32(rhs_q) : rhs_q;

  always_comb begin : radix4_step
    iter_trial_remainder = {remainder_q[31:0], dividend_shift_q[31:30]};
    iter_minus1 = iter_trial_remainder - divisor1_q;
    iter_minus2 = iter_trial_remainder - divisor2_q;
    iter_minus3 = iter_trial_remainder - divisor3_q;
    iter_ge1 = (iter_trial_remainder >= divisor1_q);
    iter_ge2 = (iter_trial_remainder >= divisor2_q);
    iter_ge3 = (iter_trial_remainder >= divisor3_q);

    iter_qdigit = 2'd0;
    iter_remainder_next = iter_trial_remainder;

    if (iter_ge3) begin
      iter_qdigit = 2'd3;
      iter_remainder_next = iter_minus3;
    end else if (iter_ge2) begin
      iter_qdigit = 2'd2;
      iter_remainder_next = iter_minus2;
    end else if (iter_ge1) begin
      iter_qdigit = 2'd1;
      iter_remainder_next = iter_minus1;
    end

    iter_quotient_next = {quotient_q[29:0], iter_qdigit};
    iter_dividend_shift_next = {dividend_shift_q[29:0], 2'b00};
  end

  assign fixed_quotient =
      quotient_neg_q ? negate32(quotient_q) : quotient_q;
  assign fixed_remainder =
      remainder_neg_q ? negate32(remainder_q[31:0]) : remainder_q[31:0];
  assign fixed_result_data =
      prepare_rem_op ? fixed_remainder : fixed_quotient;

  always_ff @(posedge clk_i) begin : div_sequencer
    if (rst_i) begin
      state_q <= ST_IDLE;
      meta_q <= '0;
      lhs_q <= '0;
      rhs_q <= '0;
      dividend_shift_q <= '0;
      quotient_q <= '0;
      remainder_q <= '0;
      divisor1_q <= '0;
      divisor2_q <= '0;
      divisor3_q <= '0;
      iter_q <= '0;
      quotient_neg_q <= 1'b0;
      remainder_neg_q <= 1'b0;
      completion_q <= '0;
    end else if (recovery_i.valid && (state_q != ST_IDLE)) begin
      if ((recovery_i.cause == REC_EXCEPT) ||
          ((recovery_i.cause == REC_BRANCH) &&
           meta_q.branch_mask[recovery_i.checkpoint_id])) begin
        state_q <= ST_IDLE;
        meta_q <= '0;
        completion_q <= '0;
      end else if (recovery_i.cause == REC_BRANCH) begin
        meta_q.branch_mask <= clear_checkpoint(meta_q.branch_mask,
                                               recovery_i.checkpoint_id);
      end
    end else begin
      unique case (state_q)
        ST_IDLE: begin
          if (accept_fire) begin
            state_q <= ST_PREPARE;
            meta_q <= make_meta(req_uop_i);
            lhs_q <= req_uop_i.src1;
            rhs_q <= req_uop_i.src2;
          end
        end

        ST_PREPARE: begin
          dividend_shift_q <= prepare_lhs_mag;
          divisor1_q <= {2'b00, prepare_rhs_mag};
          divisor2_q <= {1'b0, prepare_rhs_mag, 1'b0};
          divisor3_q <= {2'b00, prepare_rhs_mag} +
                        {1'b0, prepare_rhs_mag, 1'b0};
          iter_q <= '0;

          if (prepare_div_by_zero) begin
            quotient_q <= 32'hffff_ffff;
            remainder_q <= {2'b00, lhs_q};
            quotient_neg_q <= 1'b0;
            remainder_neg_q <= 1'b0;
            state_q <= ST_SIGN_FIX;
          end else if (prepare_signed_overflow) begin
            quotient_q <= INT_MIN;
            remainder_q <= '0;
            quotient_neg_q <= 1'b0;
            remainder_neg_q <= 1'b0;
            state_q <= ST_SIGN_FIX;
          end else begin
            quotient_q <= '0;
            remainder_q <= '0;
            quotient_neg_q <= prepare_signed_op && (lhs_q[31] ^ rhs_q[31]);
            remainder_neg_q <= prepare_signed_op && lhs_q[31];
            state_q <= ST_ITERATE;
          end
        end

        ST_ITERATE: begin
          remainder_q <= iter_remainder_next;
          quotient_q <= iter_quotient_next;
          dividend_shift_q <= iter_dividend_shift_next;

          if (iter_q == 5'd15) begin
            state_q <= ST_SIGN_FIX;
          end else begin
            iter_q <= iter_q + 5'd1;
          end
        end

        ST_SIGN_FIX: begin
          completion_q <= make_completion(meta_q, fixed_result_data);
          state_q <= ST_OUTPUT;
        end

        ST_OUTPUT: begin
          if (result_valid_o && result_ready_i) begin
            state_q <= ST_IDLE;
            completion_q <= '0;
            meta_q <= '0;
          end
        end

        default: state_q <= ST_IDLE;
      endcase
    end
  end

`ifndef SYNTHESIS
  property result_hold_stable;
    @(posedge clk_i) disable iff (rst_i || recovery_i.valid)
      result_valid_o && !result_ready_i |=> result_valid_o && $stable(result_o);
  endproperty
  assert property (result_hold_stable);

  always_ff @(posedge clk_i) begin : div_contract_assertions
    if (!rst_i) begin
      if (req_valid_i && req_ready_o) begin
        assert (req_uop_i.valid)
          else $error("div_unit accepted an invalid execute uop");
        assert (req_uop_i.fu_type == FU_DIV)
          else $error("div_unit accepted a non-DIV uop");
      end

      if (result_valid_o) begin
        assert (result_o.valid && (result_o.producer == PROD_DIV))
          else $error("div_unit emitted malformed completion");
      end
    end
  end
`endif

endmodule
