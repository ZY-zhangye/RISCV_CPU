`timescale 1ns/1ps

import core_types_pkg::*;

// commit_unit.sv
// Conservative in-order commit controller for the registered ROB head row.
//
// V1 handles normal dual retire, one-lane serializing retire, precise
// exception request generation and two-phase Store commit authorization.
// CSR instruction side effects are intentionally left for the next integration
// step; csr_file exception entry is driven here.

module commit_unit (
    input  logic        clk_i,
    input  logic        rst_i,

    input  logic [1:0]  rob_head_valid_i,
    input  rob_entry_t  rob_head0_i,
    input  rob_entry_t  rob_head1_i,
    output logic [1:0]  retire_count_o,

    output commit_map_t commit_map0_o,
    output commit_map_t commit_map1_o,

    output logic [1:0]              reclaim_valid_o,
    output logic [1:0][PRD_W-1:0]   reclaim_prd_o,
    input  logic                    reclaim_ready_i,

    output logic                    store_commit_valid_o,
    output logic [SQ_ID_W-1:0]      store_commit_sq_id_o,
    input  logic                    store_commit_ready_i,
    input  logic                    store_commit_done_i,

    output logic                    csr_exception_valid_o,
    output logic [XLEN-1:0]         csr_exception_pc_o,
    output logic [3:0]              csr_exception_cause_o,
    output logic [XLEN-1:0]         csr_exception_tval_o,
    input  logic [XLEN-1:0]         csr_exception_vector_i,

    output recovery_t               recovery_o,
    output logic [1:0]              instret_count_o,
    output logic                    store_pending_o
);

  logic store_pending_q;

  logic lane0_ready;
  logic lane1_ready;
  logic lane0_exception;
  logic lane0_store;
  logic lane0_serializing;
  logic lane0_can_retire;
  logic lane1_can_retire;
  logic normal_retire_fire;
  logic [1:0] normal_reclaim_valid;
  logic store_capture;
  logic store_done_retire;

  assign lane0_ready = rob_head_valid_i[0] && rob_head0_i.valid &&
                       rob_head0_i.complete;
  assign lane1_ready = rob_head_valid_i[1] && rob_head1_i.valid &&
                       rob_head1_i.complete;

  assign lane0_exception = lane0_ready && rob_head0_i.entry.exception_valid;
  assign lane0_store = lane0_ready && rob_head0_i.entry.is_store;
  assign lane0_serializing = lane0_ready && rob_head0_i.entry.serializing;

  assign store_commit_valid_o = !store_pending_q && lane0_store &&
                                !lane0_exception;
  assign store_commit_sq_id_o = rob_head0_i.entry.sq_id;
  assign store_capture = store_commit_valid_o && store_commit_ready_i;
  assign store_done_retire = store_pending_q && store_commit_done_i;

  assign lane0_can_retire = !store_pending_q && lane0_ready &&
                            !lane0_exception && !lane0_store;
  assign lane1_can_retire = lane0_can_retire && !lane0_serializing &&
                            lane1_ready &&
                            !rob_head1_i.entry.exception_valid &&
                            !rob_head1_i.entry.is_store &&
                            !rob_head1_i.entry.serializing;
  assign normal_reclaim_valid[0] = lane0_can_retire &&
      rob_head0_i.entry.write_rd && (rob_head0_i.entry.arch_rd != 5'd0);
  assign normal_reclaim_valid[1] = lane1_can_retire &&
      rob_head1_i.entry.write_rd && (rob_head1_i.entry.arch_rd != 5'd0);
  assign normal_retire_fire = lane0_can_retire &&
      ((normal_reclaim_valid == 2'b00) || reclaim_ready_i);

  always_comb begin : commit_outputs
    commit_map0_o = '0;
    commit_map1_o = '0;
    reclaim_valid_o = '0;
    reclaim_prd_o = '0;
    retire_count_o = 2'd0;
    instret_count_o = 2'd0;

    csr_exception_valid_o = lane0_exception && !store_pending_q;
    csr_exception_pc_o = rob_head0_i.entry.pc;
    csr_exception_cause_o = rob_head0_i.entry.exception_cause;
    csr_exception_tval_o = rob_head0_i.entry.exception_tval;

    recovery_o = '0;
    if (csr_exception_valid_o) begin
      recovery_o.valid = 1'b1;
      recovery_o.cause = REC_EXCEPT;
      recovery_o.redirect_pc = csr_exception_vector_i;
    end

    if (store_done_retire) begin
      retire_count_o = 2'd1;
      instret_count_o = 2'd1;
    end else if (lane0_can_retire) begin
      reclaim_valid_o = normal_reclaim_valid;
      reclaim_prd_o[0] = rob_head0_i.entry.old_prd;
      reclaim_prd_o[1] = rob_head1_i.entry.old_prd;

      if (normal_retire_fire) begin
      retire_count_o = lane1_can_retire ? 2'd2 : 2'd1;
      instret_count_o = retire_count_o;

      if (rob_head0_i.entry.write_rd && (rob_head0_i.entry.arch_rd != 5'd0)) begin
        commit_map0_o.valid = 1'b1;
        commit_map0_o.arch_rd = rob_head0_i.entry.arch_rd;
        commit_map0_o.prd = rob_head0_i.entry.new_prd;
      end

      if (lane1_can_retire && rob_head1_i.entry.write_rd &&
          (rob_head1_i.entry.arch_rd != 5'd0)) begin
        commit_map1_o.valid = 1'b1;
        commit_map1_o.arch_rd = rob_head1_i.entry.arch_rd;
        commit_map1_o.prd = rob_head1_i.entry.new_prd;
      end
      end
    end
  end

  assign store_pending_o = store_pending_q;

  always_ff @(posedge clk_i) begin : store_commit_tracking
    if (rst_i) begin
      store_pending_q <= 1'b0;
    end else begin
      if (store_done_retire)
        store_pending_q <= 1'b0;
      else if (store_capture)
        store_pending_q <= 1'b1;
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk_i) begin : commit_unit_assertions
    if (!rst_i) begin
      if (retire_count_o == 2'd2) begin
        assert (lane0_can_retire && lane1_can_retire)
          else $error("commit_unit emitted invalid dual retire");
      end

      if ((reclaim_valid_o != 2'b00) && !reclaim_ready_i)
        assert ((retire_count_o == 0) && !commit_map0_o.valid &&
                !commit_map1_o.valid)
          else $error("commit_unit retired while reclaim was backpressured");

      if (csr_exception_valid_o) begin
        assert (retire_count_o == 2'd0)
          else $error("exception retired as normal instruction");
      end

      if (store_pending_q) begin
        assert (!store_commit_valid_o)
          else $error("commit_unit resent Store while waiting for done");
      end
    end
  end
`endif

endmodule
