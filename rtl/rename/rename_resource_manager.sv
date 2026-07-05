`timescale 1ns/1ps

import core_types_pkg::*;

// Atomic reservation coordinator between Rename and the independently
// registered Free List, LSQ, checkpoint, and ROB allocators.
module rename_resource_manager (
    input  logic                         clk_i,
    input  logic                         rst_i,

    input  alloc_req_t                   alloc_req_i,
    output alloc_resp_t                  alloc_resp_o,
    output logic                         alloc_commit_ready_o,
    input  logic                         alloc_fire_i,
    input  logic                         alloc_cancel_i,

    output logic [1:0]                   free_alloc_count_o,
    input  logic                         free_alloc_valid_i,
    input  logic [PRD_W-1:0]             free_alloc_prd0_i,
    input  logic [PRD_W-1:0]             free_alloc_prd1_i,
    output logic                         free_alloc_fire_o,
    output logic                         free_alloc_cancel_o,

    output logic [1:0]                   lsq_alloc_lq_count_o,
    output logic [1:0]                   lsq_alloc_sq_count_o,
    input  logic                         lsq_alloc_valid_i,
    input  logic [1:0][LQ_ID_W-1:0]      lsq_alloc_lq_id_i,
    input  logic [1:0][SQ_ID_W-1:0]      lsq_alloc_sq_id_i,
    output logic                         lsq_alloc_fire_o,
    output logic                         lsq_alloc_cancel_o,

    output logic                         checkpoint_alloc_req_o,
    input  logic                         checkpoint_alloc_valid_i,
    input  logic [CP_W-1:0]              checkpoint_alloc_id_i,
    output logic                         checkpoint_alloc_fire_o,
    output logic                         checkpoint_alloc_cancel_o,

    input  logic                         rob_alloc_ready_i,
    input  logic [ROB_ID_W-1:0]          rob_alloc_id0_i,
    input  logic [ROB_ID_W-1:0]          rob_alloc_id1_i,
    output logic [1:0]                   rob_alloc_valid_o,

    output logic                         busy_o
);

  typedef enum logic [1:0] {
    ST_IDLE,
    ST_RESERVE,
    ST_WAIT_FIRE
  } manager_state_t;

  manager_state_t state_q;
  alloc_req_t request_q;

  logic [1:0] prd_count;
  logic [1:0] lq_count;
  logic [1:0] sq_count;
  logic checkpoint_needed;
  logic free_ready;
  logic lsq_ready;
  logic checkpoint_ready;
  logic all_resources_ready;
  logic reserve_cancel;
  logic transaction_fire;
  logic transaction_cancel;

  function automatic logic [1:0] count_mask(input logic [1:0] mask);
    count_mask = {1'b0, mask[0]} + {1'b0, mask[1]};
  endfunction

  assign prd_count = count_mask(request_q.need_prd);
  assign lq_count = count_mask(request_q.need_lq);
  assign sq_count = count_mask(request_q.need_sq);
  assign checkpoint_needed = |request_q.need_checkpoint;

  assign free_ready = (prd_count == 2'd0) || free_alloc_valid_i;
  assign lsq_ready = ((lq_count == 2'd0) && (sq_count == 2'd0)) ||
                     lsq_alloc_valid_i;
  assign checkpoint_ready = !checkpoint_needed || checkpoint_alloc_valid_i;
  assign all_resources_ready = free_ready && lsq_ready &&
                               checkpoint_ready && rob_alloc_ready_i;

  assign busy_o = (state_q != ST_IDLE);
  assign reserve_cancel = (state_q == ST_RESERVE) &&
                          (!alloc_req_i.valid || alloc_cancel_i);
  assign alloc_commit_ready_o = (state_q == ST_WAIT_FIRE) &&
                                all_resources_ready;
  assign transaction_fire = alloc_commit_ready_o && alloc_fire_i &&
                            !alloc_cancel_i;
  assign transaction_cancel = reserve_cancel ||
                              ((state_q == ST_WAIT_FIRE) && alloc_cancel_i);

  assign free_alloc_count_o = (state_q == ST_IDLE) ? 2'd0 : prd_count;
  assign lsq_alloc_lq_count_o = (state_q == ST_IDLE) ? 2'd0 : lq_count;
  assign lsq_alloc_sq_count_o = (state_q == ST_IDLE) ? 2'd0 : sq_count;
  assign checkpoint_alloc_req_o = (state_q == ST_RESERVE) &&
                                  checkpoint_needed;

  assign free_alloc_fire_o = transaction_fire && (prd_count != 2'd0);
  assign lsq_alloc_fire_o = transaction_fire &&
                            ((lq_count != 2'd0) || (sq_count != 2'd0));
  assign checkpoint_alloc_fire_o = transaction_fire && checkpoint_needed;
  assign rob_alloc_valid_o = transaction_fire ? request_q.lane_valid : 2'b00;

  assign free_alloc_cancel_o = transaction_cancel && (prd_count != 2'd0);
  assign lsq_alloc_cancel_o = transaction_cancel &&
                              ((lq_count != 2'd0) || (sq_count != 2'd0));
  assign checkpoint_alloc_cancel_o = transaction_cancel && checkpoint_needed;

  always_comb begin : response_build
    logic [1:0] compact_index;

    alloc_resp_o = '0;
    alloc_resp_o.valid = (state_q == ST_RESERVE) && alloc_req_i.valid &&
                         all_resources_ready;
    alloc_resp_o.lane_valid = request_q.lane_valid;
    alloc_resp_o.rob_id[0] = rob_alloc_id0_i;
    alloc_resp_o.rob_id[1] = rob_alloc_id1_i;
    alloc_resp_o.checkpoint_id = checkpoint_alloc_id_i;

    compact_index = '0;
    for (int lane = 0; lane < 2; lane = lane + 1) begin
      if (request_q.need_prd[lane]) begin
        alloc_resp_o.prd[lane] = (compact_index == 2'd0) ?
                                 free_alloc_prd0_i : free_alloc_prd1_i;
        compact_index = compact_index + 1'b1;
      end
    end

    compact_index = '0;
    for (int lane = 0; lane < 2; lane = lane + 1) begin
      if (request_q.need_lq[lane]) begin
        alloc_resp_o.lq_id[lane] = lsq_alloc_lq_id_i[compact_index];
        compact_index = compact_index + 1'b1;
      end
    end

    compact_index = '0;
    for (int lane = 0; lane < 2; lane = lane + 1) begin
      if (request_q.need_sq[lane]) begin
        alloc_resp_o.sq_id[lane] = lsq_alloc_sq_id_i[compact_index];
        compact_index = compact_index + 1'b1;
      end
    end

    alloc_resp_o.bank_same = (prd_count == 2'd2) &&
                             (free_alloc_prd0_i[0] == free_alloc_prd1_i[0]);
  end

  always_ff @(posedge clk_i) begin : manager_state
    if (rst_i) begin
      state_q <= ST_IDLE;
      request_q <= '0;
    end else begin
      unique case (state_q)
        ST_IDLE: begin
          if (alloc_req_i.valid) begin
            request_q <= alloc_req_i;
            state_q <= ST_RESERVE;
          end
        end

        ST_RESERVE: begin
          if (reserve_cancel) begin
            request_q <= '0;
            state_q <= ST_IDLE;
          end else if (all_resources_ready && alloc_req_i.valid) begin
            state_q <= ST_WAIT_FIRE;
          end
        end

        ST_WAIT_FIRE: begin
          if (alloc_cancel_i || transaction_fire) begin
            request_q <= '0;
            state_q <= ST_IDLE;
          end
        end

        default: begin
          request_q <= '0;
          state_q <= ST_IDLE;
        end
      endcase
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk_i) begin : manager_assertions
    if (!rst_i) begin
      assert (!(alloc_fire_i && alloc_cancel_i))
        else $error("resource manager fire and cancel overlap");

      if (alloc_fire_i)
        assert (alloc_commit_ready_o)
          else $error("resource manager fire while commit was not ready");

      if (alloc_cancel_i)
        assert (state_q != ST_IDLE)
          else $error("resource manager cancel while idle");

      assert (request_q.need_checkpoint != 2'b11)
        else $error("resource manager received two checkpoint requests");

      if (alloc_resp_o.valid)
        assert (all_resources_ready && (state_q == ST_RESERVE))
          else $error("resource manager emitted incomplete response");
    end
  end
`endif

endmodule
