`timescale 1ns/1ps

import core_types_pkg::*;

// writeback_arbiter.sv
// Timing-pipelined five-producer, two-lane completion/writeback arbiter.
//
// Structure:
//   P0: per-producer 2-entry skid buffers.
//   P1: fixed-priority two-lane select from registered producer buffers.
//   P2: registered WB/ROB/PRF/wakeup outputs.
//
// This intentionally avoids a round-robin feedback loop in the timing-critical
// select path. Static priority is acceptable for V1 because each producer has a
// local completion buffer upstream; fairness can be reintroduced later with a
// small registered age scheme if system-level tests show starvation.

module writeback_arbiter (
    input  logic        clk_i,
    input  logic        rst_i,

    input  logic        int0_valid_i,
    output logic        int0_ready_o,
    input  completion_t int0_i,

    input  logic        int1_valid_i,
    output logic        int1_ready_o,
    input  completion_t int1_i,

    input  logic        lsu_valid_i,
    output logic        lsu_ready_o,
    input  completion_t lsu_i,

    input  logic        mul_valid_i,
    output logic        mul_ready_o,
    input  completion_t mul_i,

    input  logic        div_valid_i,
    output logic        div_ready_o,
    input  completion_t div_i,

    input  recovery_t   recovery_i,

    output logic [1:0]  wb_valid_o,
    output completion_t wb_o [0:1],

    output logic [1:0]              prf_write_valid_o,
    output logic [1:0][PRD_W-1:0]   prf_write_prd_o,
    output logic [1:0][XLEN-1:0]    prf_write_data_o,

    output logic [1:0]              rob_complete_valid_o,
    output completion_t             rob_complete_o [0:1],

    output logic [1:0]              wakeup_valid_o,
    output logic [1:0][PRD_W-1:0]   wakeup_prd_o
);

  localparam int PRODUCERS = 5;
  localparam int P_INT0 = 0;
  localparam int P_INT1 = 1;
  localparam int P_LSU  = 2;
  localparam int P_MUL  = 3;
  localparam int P_DIV  = 4;

  logic [PRODUCERS-1:0] in_valid;
  completion_t in_payload [0:PRODUCERS-1];

  logic [1:0] buf_count_q [0:PRODUCERS-1];
  completion_t buf_head_q [0:PRODUCERS-1];
  completion_t buf_tail_q [0:PRODUCERS-1];

  logic [PRODUCERS-1:0] select_fire;
  logic lane_valid_d [0:1];
  completion_t lane_payload_d [0:1];

  logic [1:0] wb_valid_q;
  completion_t wb_q [0:1];

  // --------------------------------------------------------------------------
  // Input vector packing
  // --------------------------------------------------------------------------
  assign in_valid[P_INT0] = int0_valid_i && int0_i.valid;
  assign in_valid[P_INT1] = int1_valid_i && int1_i.valid;
  assign in_valid[P_LSU]  = lsu_valid_i  && lsu_i.valid;
  assign in_valid[P_MUL]  = mul_valid_i  && mul_i.valid;
  assign in_valid[P_DIV]  = div_valid_i  && div_i.valid;

  assign in_payload[P_INT0] = int0_i;
  assign in_payload[P_INT1] = int1_i;
  assign in_payload[P_LSU]  = lsu_i;
  assign in_payload[P_MUL]  = mul_i;
  assign in_payload[P_DIV]  = div_i;

  assign int0_ready_o = !recovery_i.valid && (buf_count_q[P_INT0] != 2'd2);
  assign int1_ready_o = !recovery_i.valid && (buf_count_q[P_INT1] != 2'd2);
  assign lsu_ready_o  = !recovery_i.valid && (buf_count_q[P_LSU]  != 2'd2);
  assign mul_ready_o  = !recovery_i.valid && (buf_count_q[P_MUL]  != 2'd2);
  assign div_ready_o  = !recovery_i.valid && (buf_count_q[P_DIV]  != 2'd2);

  // --------------------------------------------------------------------------
  // Selection helpers
  // --------------------------------------------------------------------------
  function automatic logic consumes_prf_bank(input completion_t completion);
    begin
      consumes_prf_bank = completion.valid && completion.write_prf &&
                          !completion.exception_valid && !completion.is_store &&
                          (completion.prd != '0);
    end
  endfunction

  function automatic logic pair_allowed(
      input completion_t first,
      input completion_t second
  );
    begin
      pair_allowed = 1'b1;
      if (consumes_prf_bank(first) && consumes_prf_bank(second) &&
          (first.prd[0] == second.prd[0]))
        pair_allowed = 1'b0;
    end
  endfunction

  // Fixed-priority select from registered buffers. The second lane scans for
  // the first candidate that does not violate PRF bank constraints.
  always_comb begin : select_from_buffers
    integer idx;
    select_fire = '0;
    for (idx = 0; idx < 2; idx = idx + 1) begin
      lane_valid_d[idx] = 1'b0;
      lane_payload_d[idx] = '0;
    end

    if (!recovery_i.valid) begin
      for (idx = 0; idx < PRODUCERS; idx = idx + 1) begin
        if (!lane_valid_d[0] && (buf_count_q[idx] != 2'd0)) begin
          lane_valid_d[0] = 1'b1;
          lane_payload_d[0] = buf_head_q[idx];
          select_fire[idx] = 1'b1;
        end
      end

      if (lane_valid_d[0]) begin
        for (idx = 0; idx < PRODUCERS; idx = idx + 1) begin
          if (!select_fire[idx] && !lane_valid_d[1] &&
              (buf_count_q[idx] != 2'd0) &&
              pair_allowed(lane_payload_d[0], buf_head_q[idx])) begin
            lane_valid_d[1] = 1'b1;
            lane_payload_d[1] = buf_head_q[idx];
            select_fire[idx] = 1'b1;
          end
        end
      end
    end
  end

  // --------------------------------------------------------------------------
  // Input buffers and registered output lanes
  // --------------------------------------------------------------------------
  always_ff @(posedge clk_i) begin : pipeline_state
    integer idx;
    if (rst_i) begin
      wb_valid_q <= '0;
      for (idx = 0; idx < PRODUCERS; idx = idx + 1) begin
        buf_count_q[idx] <= '0;
        buf_head_q[idx] <= '0;
        buf_tail_q[idx] <= '0;
      end
      for (idx = 0; idx < 2; idx = idx + 1)
        wb_q[idx] <= '0;
    end else if (recovery_i.valid) begin
      wb_valid_q <= '0;
    end else begin
      wb_valid_q[0] <= lane_valid_d[0];
      wb_valid_q[1] <= lane_valid_d[1];
      if (lane_valid_d[0])
        wb_q[0] <= lane_payload_d[0];
      if (lane_valid_d[1])
        wb_q[1] <= lane_payload_d[1];

      for (idx = 0; idx < PRODUCERS; idx = idx + 1) begin
        unique case ({select_fire[idx], in_valid[idx] && (buf_count_q[idx] != 2'd2)})
          2'b00: begin
            // Hold buffered payloads.
          end
          2'b01: begin
            if (buf_count_q[idx] == 2'd0) begin
              buf_head_q[idx] <= in_payload[idx];
              buf_count_q[idx] <= 2'd1;
            end else begin
              buf_tail_q[idx] <= in_payload[idx];
              buf_count_q[idx] <= 2'd2;
            end
          end
          2'b10: begin
            if (buf_count_q[idx] == 2'd2) begin
              buf_head_q[idx] <= buf_tail_q[idx];
              buf_tail_q[idx] <= '0;
              buf_count_q[idx] <= 2'd1;
            end else begin
              buf_head_q[idx] <= '0;
              buf_tail_q[idx] <= '0;
              buf_count_q[idx] <= 2'd0;
            end
          end
          default: begin // pop one head and push one new payload
            if (buf_count_q[idx] == 2'd2) begin
              // This branch is normally unreachable because ready is low when
              // count==2, but keep safe behavior if an invalid upstream ignores ready.
              buf_head_q[idx] <= buf_tail_q[idx];
              buf_tail_q[idx] <= '0;
              buf_count_q[idx] <= 2'd1;
            end else begin
              buf_head_q[idx] <= in_payload[idx];
              buf_tail_q[idx] <= '0;
              buf_count_q[idx] <= 2'd1;
            end
          end
        endcase
      end
    end
  end

  // --------------------------------------------------------------------------
  // Registered output decode
  // --------------------------------------------------------------------------
  always_comb begin : drive_outputs
    integer lane;
    wb_valid_o = recovery_i.valid ? 2'b00 : wb_valid_q;
    prf_write_valid_o = '0;
    prf_write_prd_o = '0;
    prf_write_data_o = '0;
    rob_complete_valid_o = '0;
    wakeup_valid_o = '0;
    wakeup_prd_o = '0;

    for (lane = 0; lane < 2; lane = lane + 1) begin
      wb_o[lane] = '0;
      rob_complete_o[lane] = '0;

      if (wb_valid_o[lane]) begin
        wb_o[lane] = wb_q[lane];
        rob_complete_valid_o[lane] = 1'b1;
        rob_complete_o[lane] = wb_q[lane];

        if (consumes_prf_bank(wb_q[lane])) begin
          prf_write_valid_o[lane] = 1'b1;
          prf_write_prd_o[lane] = wb_q[lane].prd;
          prf_write_data_o[lane] = wb_q[lane].data;
          wakeup_valid_o[lane] = 1'b1;
          wakeup_prd_o[lane] = wb_q[lane].prd;
        end
      end
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk_i) begin : writeback_assertions
    if (!rst_i) begin
      assert (!(prf_write_valid_o[0] && prf_write_valid_o[1] &&
                (prf_write_prd_o[0][0] == prf_write_prd_o[1][0])))
        else $error("writeback_arbiter issued two PRF writes to the same bank");

      assert (!(rob_complete_valid_o[0] && rob_complete_valid_o[1] &&
                (rob_complete_o[0].rob_id == rob_complete_o[1].rob_id)))
        else $error("writeback_arbiter completed the same ROB ID twice");

      if (recovery_i.valid) begin
        assert (wb_valid_o == 2'b00)
          else $error("writeback_arbiter produced output during recovery pause");
      end

      for (int lane = 0; lane < 2; lane = lane + 1) begin
        if (rob_complete_valid_o[lane] &&
            (rob_complete_o[lane].exception_valid || rob_complete_o[lane].is_store)) begin
          assert (!wakeup_valid_o[lane] && !prf_write_valid_o[lane])
            else $error("exception/store completion generated PRF write or wakeup");
        end
      end
    end
  end
`endif

endmodule
