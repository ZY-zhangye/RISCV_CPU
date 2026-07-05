`timescale 1ns/1ps

import core_types_pkg::*;

// mul_pipeline.sv
// Four-stage RV32M multiply pipeline with a two-entry completion FIFO.
//
// The operands are normalized to signed 33-bit values.  The product is split
// into four independent 17/16-bit partial products so Vivado cannot build a
// same-cycle cascade between multiple DSP48 blocks.  Two registered adder
// levels reconstruct the 66-bit result without changing the four-cycle
// interface latency or requiring a vendor simulation model.

module mul_pipeline (
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

  typedef struct packed {
    logic [ROB_ID_W-1:0]     rob_id;
    logic [PRD_W-1:0]        prd;
    mul_op_t                 mul_op;
    logic [CHECKPOINTS-1:0]  branch_mask;
    logic                    write_rd;
  } mul_meta_t;

  logic s0_valid_q;
  logic signed [32:0] s0_lhs_q;
  logic signed [32:0] s0_rhs_q;
  mul_meta_t s0_meta_q;

  logic s1_valid_q;
  (* use_dsp = "yes" *) logic        [33:0] s1_ll_q;
  (* use_dsp = "yes" *) logic signed [33:0] s1_lh_q;
  (* use_dsp = "yes" *) logic signed [33:0] s1_hl_q;
  (* use_dsp = "yes" *) logic signed [31:0] s1_hh_q;
  mul_meta_t s1_meta_q;

  logic s2_valid_q;
  logic signed [65:0] s2_sum_lo_q;
  logic signed [65:0] s2_sum_hi_q;
  mul_meta_t s2_meta_q;

  logic s3_valid_q;
  completion_t s3_completion_q;
  logic [CHECKPOINTS-1:0] s3_branch_mask_q;

  completion_t fifo_completion_q [0:1];
  logic [CHECKPOINTS-1:0] fifo_branch_mask_q [0:1];
  logic [1:0] fifo_count_q;

  logic accept_fire;
  logic fifo_head_killed;
  logic fifo_pop;
  logic fifo_push;
  logic fifo_can_push;
  logic pipe_advance;

  function automatic logic signed [32:0] normalize_lhs(
      input execute_uop_t uop
  );
    begin
      if (uop.mul_op == MUL_MULHU)
        normalize_lhs = $signed({1'b0, uop.src1});
      else
        normalize_lhs = $signed({uop.src1[31], uop.src1});
    end
  endfunction

  function automatic logic signed [32:0] normalize_rhs(
      input execute_uop_t uop
  );
    begin
      if ((uop.mul_op == MUL_MULHSU) ||
          (uop.mul_op == MUL_MULHU))
        normalize_rhs = $signed({1'b0, uop.src2});
      else
        normalize_rhs = $signed({uop.src2[31], uop.src2});
    end
  endfunction

  function automatic mul_meta_t make_meta(input execute_uop_t uop);
    mul_meta_t meta;
    begin
      meta = '0;
      meta.rob_id = uop.rob_id;
      meta.prd = uop.prd;
      meta.mul_op = uop.mul_op;
      meta.branch_mask = uop.branch_mask;
      meta.write_rd = uop.write_rd;
      make_meta = meta;
    end
  endfunction

  function automatic completion_t make_completion(
      input mul_meta_t meta,
      input logic signed [65:0] product
  );
    completion_t completion;
    begin
      completion = '0;
      completion.valid = 1'b1;
      completion.prd = meta.prd;
      completion.rob_id = meta.rob_id;
      completion.data = (meta.mul_op == MUL_MUL) ?
                        product[31:0] : product[63:32];
      completion.producer = PROD_MUL;
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

  assign fifo_head_killed = recovery_i.valid &&
      ((recovery_i.cause == REC_EXCEPT) ||
       ((recovery_i.cause == REC_BRANCH) && (fifo_count_q != 0) &&
        fifo_branch_mask_q[0][recovery_i.checkpoint_id]));

  assign result_valid_o = (fifo_count_q != 0) && !fifo_head_killed;
  assign result_o = result_valid_o ? fifo_completion_q[0] : '0;

  assign fifo_pop = !recovery_i.valid && result_valid_o && result_ready_i;
  assign fifo_can_push = (fifo_count_q != 2) || fifo_pop;
  assign pipe_advance = !s3_valid_q || fifo_can_push;
  assign fifo_push = !recovery_i.valid && pipe_advance && s3_valid_q;

  assign req_ready_o = !recovery_i.valid && pipe_advance;
  assign accept_fire = req_valid_i && req_ready_o && req_uop_i.valid;

  // --------------------------------------------------------------------------
  // Four-stage DSP pipeline.  When the completion FIFO cannot accept the tail,
  // every stage holds so products and metadata remain aligned.
  // --------------------------------------------------------------------------
  always_ff @(posedge clk_i) begin : multiply_pipeline
    if (rst_i) begin
      s0_valid_q <= 1'b0;
      s0_lhs_q <= '0;
      s0_rhs_q <= '0;
      s0_meta_q <= '0;
      s1_valid_q <= 1'b0;
      s1_ll_q <= '0;
      s1_lh_q <= '0;
      s1_hl_q <= '0;
      s1_hh_q <= '0;
      s1_meta_q <= '0;
      s2_valid_q <= 1'b0;
      s2_sum_lo_q <= '0;
      s2_sum_hi_q <= '0;
      s2_meta_q <= '0;
      s3_valid_q <= 1'b0;
      s3_completion_q <= '0;
      s3_branch_mask_q <= '0;
    end else if (recovery_i.valid) begin
      if (recovery_i.cause == REC_EXCEPT) begin
        s0_valid_q <= 1'b0;
        s1_valid_q <= 1'b0;
        s2_valid_q <= 1'b0;
        s3_valid_q <= 1'b0;
      end else begin
        if (s0_valid_q) begin
          if (s0_meta_q.branch_mask[recovery_i.checkpoint_id])
            s0_valid_q <= 1'b0;
          else
            s0_meta_q.branch_mask <= clear_checkpoint(
                s0_meta_q.branch_mask, recovery_i.checkpoint_id);
        end
        if (s1_valid_q) begin
          if (s1_meta_q.branch_mask[recovery_i.checkpoint_id])
            s1_valid_q <= 1'b0;
          else
            s1_meta_q.branch_mask <= clear_checkpoint(
                s1_meta_q.branch_mask, recovery_i.checkpoint_id);
        end
        if (s2_valid_q) begin
          if (s2_meta_q.branch_mask[recovery_i.checkpoint_id])
            s2_valid_q <= 1'b0;
          else
            s2_meta_q.branch_mask <= clear_checkpoint(
                s2_meta_q.branch_mask, recovery_i.checkpoint_id);
        end
        if (s3_valid_q) begin
          if (s3_branch_mask_q[recovery_i.checkpoint_id])
            s3_valid_q <= 1'b0;
          else
            s3_branch_mask_q <= clear_checkpoint(
                s3_branch_mask_q, recovery_i.checkpoint_id);
        end
      end
    end else if (pipe_advance) begin
      s3_valid_q <= s2_valid_q;
      if (s2_valid_q) begin
        s3_completion_q <= make_completion(
            s2_meta_q, s2_sum_lo_q + s2_sum_hi_q);
        s3_branch_mask_q <= s2_meta_q.branch_mask;
      end

      s2_valid_q <= s1_valid_q;
      if (s1_valid_q) begin
        s2_sum_lo_q <=
            $signed({32'b0, s1_ll_q}) +
            ($signed({{32{s1_lh_q[33]}}, s1_lh_q}) <<< 17);
        s2_sum_hi_q <=
            ($signed({{32{s1_hl_q[33]}}, s1_hl_q}) <<< 17) +
            ($signed({{34{s1_hh_q[31]}}, s1_hh_q}) <<< 34);
        s2_meta_q <= s1_meta_q;
      end

      s1_valid_q <= s0_valid_q;
      if (s0_valid_q) begin
        s1_ll_q <= $unsigned(s0_lhs_q[16:0]) *
                   $unsigned(s0_rhs_q[16:0]);
        s1_lh_q <= $signed({1'b0, s0_lhs_q[16:0]}) *
                   $signed(s0_rhs_q[32:17]);
        s1_hl_q <= $signed(s0_lhs_q[32:17]) *
                   $signed({1'b0, s0_rhs_q[16:0]});
        s1_hh_q <= $signed(s0_lhs_q[32:17]) *
                   $signed(s0_rhs_q[32:17]);
        s1_meta_q <= s0_meta_q;
      end

      s0_valid_q <= accept_fire;
      if (accept_fire) begin
        s0_lhs_q <= normalize_lhs(req_uop_i);
        s0_rhs_q <= normalize_rhs(req_uop_i);
        s0_meta_q <= make_meta(req_uop_i);
      end
    end
  end

  // --------------------------------------------------------------------------
  // Two-entry completion FIFO.  Branch recovery compacts surviving entries so
  // a killed head can never block an older correct-path completion behind it.
  // --------------------------------------------------------------------------
  always_ff @(posedge clk_i) begin : completion_fifo
    logic kill0;
    logic kill1;

    if (rst_i) begin
      fifo_completion_q[0] <= '0;
      fifo_completion_q[1] <= '0;
      fifo_branch_mask_q[0] <= '0;
      fifo_branch_mask_q[1] <= '0;
      fifo_count_q <= '0;
    end else if (recovery_i.valid) begin
      if (recovery_i.cause == REC_EXCEPT) begin
        fifo_count_q <= '0;
      end else begin
        kill0 = (fifo_count_q >= 1) &&
                fifo_branch_mask_q[0][recovery_i.checkpoint_id];
        kill1 = (fifo_count_q == 2) &&
                fifo_branch_mask_q[1][recovery_i.checkpoint_id];

        unique case (fifo_count_q)
          2'd1: begin
            if (kill0) begin
              fifo_count_q <= '0;
            end else begin
              fifo_branch_mask_q[0] <= clear_checkpoint(
                  fifo_branch_mask_q[0], recovery_i.checkpoint_id);
            end
          end
          2'd2: begin
            unique case ({kill1, kill0})
              2'b00: begin
                fifo_branch_mask_q[0] <= clear_checkpoint(
                    fifo_branch_mask_q[0], recovery_i.checkpoint_id);
                fifo_branch_mask_q[1] <= clear_checkpoint(
                    fifo_branch_mask_q[1], recovery_i.checkpoint_id);
              end
              2'b01: begin
                fifo_completion_q[0] <= fifo_completion_q[1];
                fifo_branch_mask_q[0] <= clear_checkpoint(
                    fifo_branch_mask_q[1], recovery_i.checkpoint_id);
                fifo_count_q <= 2'd1;
              end
              2'b10: begin
                fifo_branch_mask_q[0] <= clear_checkpoint(
                    fifo_branch_mask_q[0], recovery_i.checkpoint_id);
                fifo_count_q <= 2'd1;
              end
              default: fifo_count_q <= '0;
            endcase
          end
          default: begin
          end
        endcase
      end
    end else begin
      unique case ({fifo_push, fifo_pop})
        2'b10: begin
          if (fifo_count_q == 0) begin
            fifo_completion_q[0] <= s3_completion_q;
            fifo_branch_mask_q[0] <= s3_branch_mask_q;
          end else begin
            fifo_completion_q[1] <= s3_completion_q;
            fifo_branch_mask_q[1] <= s3_branch_mask_q;
          end
          fifo_count_q <= fifo_count_q + 1'b1;
        end
        2'b01: begin
          if (fifo_count_q == 2) begin
            fifo_completion_q[0] <= fifo_completion_q[1];
            fifo_branch_mask_q[0] <= fifo_branch_mask_q[1];
          end
          fifo_count_q <= fifo_count_q - 1'b1;
        end
        2'b11: begin
          if (fifo_count_q == 1) begin
            fifo_completion_q[0] <= s3_completion_q;
            fifo_branch_mask_q[0] <= s3_branch_mask_q;
          end else begin
            fifo_completion_q[0] <= fifo_completion_q[1];
            fifo_branch_mask_q[0] <= fifo_branch_mask_q[1];
            fifo_completion_q[1] <= s3_completion_q;
            fifo_branch_mask_q[1] <= s3_branch_mask_q;
          end
        end
        default: begin
        end
      endcase
    end
  end

`ifndef SYNTHESIS
  property result_hold_stable;
    @(posedge clk_i) disable iff (rst_i || recovery_i.valid)
      result_valid_o && !result_ready_i |=> result_valid_o && $stable(result_o);
  endproperty
  assert property (result_hold_stable);

  always_ff @(posedge clk_i) begin : mul_contract_assertions
    if (!rst_i) begin
      assert (fifo_count_q <= 2)
        else $error("mul_pipeline completion FIFO overflow");

      if (req_valid_i && req_ready_o) begin
        assert (req_uop_i.valid)
          else $error("mul_pipeline accepted an invalid execute uop");
        assert (req_uop_i.fu_type == FU_MUL)
          else $error("mul_pipeline accepted a non-MUL uop");
      end

      if (result_valid_o) begin
        assert (result_o.valid && (result_o.producer == PROD_MUL))
          else $error("mul_pipeline emitted malformed completion");
      end
    end
  end
`endif

endmodule
