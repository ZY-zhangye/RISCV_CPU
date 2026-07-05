`timescale 1ns/1ps

import core_types_pkg::*;

// muldiv_frontend.sv
// MDU request router and local Mul/Div wrapper.
//
// Operand Read exposes a single MDU valid-ready request channel.  The global
// Writeback Arbiter already has independent MUL and DIV producer inputs, so the
// frontend only dispatches requests by fu_type and keeps the two completion
// streams separate.

module muldiv_frontend (
    input  logic         clk_i,
    input  logic         rst_i,

    input  logic         mdu_valid_i,
    output logic         mdu_ready_o,
    input  execute_uop_t mdu_uop_i,

    output logic         mul_valid_o,
    input  logic         mul_ready_i,
    output completion_t  mul_o,

    output logic         div_valid_o,
    input  logic         div_ready_i,
    output completion_t  div_o,

    input  recovery_t    recovery_i
);

  logic mul_req_valid;
  logic mul_req_ready;
  logic div_req_valid;
  logic div_req_ready;
  logic route_mul;
  logic route_div;

  assign route_mul = mdu_uop_i.valid && (mdu_uop_i.fu_type == FU_MUL);
  assign route_div = mdu_uop_i.valid && (mdu_uop_i.fu_type == FU_DIV);

  assign mul_req_valid = mdu_valid_i && route_mul;
  assign div_req_valid = mdu_valid_i && route_div;

  always_comb begin : ready_mux
    mdu_ready_o = 1'b0;
    if (!recovery_i.valid) begin
      unique case (mdu_uop_i.fu_type)
        FU_MUL: mdu_ready_o = mul_req_ready;
        FU_DIV: mdu_ready_o = div_req_ready;
        default: mdu_ready_o = 1'b0;
      endcase
    end
  end

  mul_pipeline u_mul_pipeline (
      .clk_i(clk_i),
      .rst_i(rst_i),
      .req_valid_i(mul_req_valid),
      .req_ready_o(mul_req_ready),
      .req_uop_i(mdu_uop_i),
      .result_valid_o(mul_valid_o),
      .result_ready_i(mul_ready_i),
      .result_o(mul_o),
      .recovery_i(recovery_i)
  );

  div_unit u_div_unit (
      .clk_i(clk_i),
      .rst_i(rst_i),
      .req_valid_i(div_req_valid),
      .req_ready_o(div_req_ready),
      .req_uop_i(mdu_uop_i),
      .result_valid_o(div_valid_o),
      .result_ready_i(div_ready_i),
      .result_o(div_o),
      .recovery_i(recovery_i)
  );

`ifndef SYNTHESIS
  always_ff @(posedge clk_i) begin : muldiv_frontend_assertions
    if (!rst_i) begin
      if (mdu_valid_i && mdu_ready_o) begin
        assert (mdu_uop_i.valid)
          else $error("muldiv_frontend accepted an invalid uop");
        assert ((mdu_uop_i.fu_type == FU_MUL) ||
                (mdu_uop_i.fu_type == FU_DIV))
          else $error("muldiv_frontend accepted a non-MDU uop");
      end

      assert (!(mul_req_valid && div_req_valid))
        else $error("muldiv_frontend routed one uop to both units");
    end
  end
`endif

endmodule
