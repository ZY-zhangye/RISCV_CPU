`timescale 1ns/1ps

import core_types_pkg::*;

// recovery_controller.sv
// Priority recovery broadcaster with explicit ack wait and redirect pulse.
//
// REC_BRANCH is reserved for mispredict kill. Correct branch resolution emits
// a separate checkpoint-clear pulse so surviving speculative work is not
// accidentally killed by modules that interpret REC_BRANCH as kill-if-masked.

module recovery_controller #(
    parameter int ACKS = 6
) (
    input  logic                    clk_i,
    input  logic                    rst_i,

    input  branch_resolve_t         branch_i,
    input  recovery_t               commit_recovery_i,

    input  logic [ACKS-1:0]         recovery_done_i,

    output recovery_t               recovery_o,
    output logic                    redirect_valid_o,
    output logic [XLEN-1:0]         redirect_pc_o,

    output logic                    checkpoint_clear_valid_o,
    output logic [CP_W-1:0]         checkpoint_clear_id_o,

    output logic                    busy_o
);

  typedef enum logic [1:0] {
    ST_IDLE,
    ST_BROADCAST,
    ST_WAIT_ACK,
    ST_REDIRECT
  } recovery_state_t;

  recovery_state_t state_q;
  recovery_t latched_recovery_q;
  logic checkpoint_clear_valid_q;
  logic [CP_W-1:0] checkpoint_clear_id_q;

  logic request_valid;
  recovery_t request_recovery;
  logic all_done;

  assign all_done = &recovery_done_i;
  assign busy_o = (state_q != ST_IDLE);

  always_comb begin : request_select
    request_recovery = '0;
    request_valid = 1'b0;

    if (commit_recovery_i.valid) begin
      request_valid = 1'b1;
      request_recovery = commit_recovery_i;
    end else if (branch_i.valid && branch_i.mispredict) begin
      request_valid = 1'b1;
      request_recovery.valid = 1'b1;
      request_recovery.cause = REC_BRANCH;
      request_recovery.checkpoint_id = branch_i.checkpoint_id;
      request_recovery.redirect_pc = branch_i.redirect_pc;
    end
  end

  assign recovery_o = (state_q == ST_BROADCAST) ? latched_recovery_q : '0;
  assign redirect_valid_o = (state_q == ST_REDIRECT);
  assign redirect_pc_o = latched_recovery_q.redirect_pc;

  assign checkpoint_clear_valid_o = checkpoint_clear_valid_q;
  assign checkpoint_clear_id_o = checkpoint_clear_id_q;

  always_ff @(posedge clk_i) begin : recovery_fsm
    if (rst_i) begin
      state_q <= ST_IDLE;
      latched_recovery_q <= '0;
      checkpoint_clear_valid_q <= 1'b0;
      checkpoint_clear_id_q <= '0;
    end else begin
      checkpoint_clear_valid_q <= 1'b0;

      unique case (state_q)
        ST_IDLE: begin
          if (request_valid) begin
            latched_recovery_q <= request_recovery;
            state_q <= ST_BROADCAST;
          end else if (branch_i.valid && !branch_i.mispredict) begin
            checkpoint_clear_valid_q <= 1'b1;
            checkpoint_clear_id_q <= branch_i.checkpoint_id;
          end
        end

        ST_BROADCAST: begin
          state_q <= ST_WAIT_ACK;
        end

        ST_WAIT_ACK: begin
          if (all_done)
            state_q <= ST_REDIRECT;
        end

        ST_REDIRECT: begin
          latched_recovery_q <= '0;
          state_q <= ST_IDLE;
        end

        default: begin
          latched_recovery_q <= '0;
          state_q <= ST_IDLE;
        end
      endcase
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk_i) begin : recovery_controller_assertions
    if (!rst_i) begin
      if (recovery_o.valid)
        assert (busy_o)
          else $error("recovery broadcast while controller was idle");

      if (checkpoint_clear_valid_o)
        assert (!recovery_o.valid && !busy_o)
          else $error("checkpoint clear overlapped recovery flow");
    end
  end
`endif

endmodule
