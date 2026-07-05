`timescale 1ns/1ps

import core_types_pkg::*;

// load_queue.sv
// Eight-entry direct-indexed Load Queue metadata array.
//
// This module owns the Load entry lifecycle only. Address generation, SQ
// comparison, forwarding and Data RAM access are implemented in lsu_pipeline.

module load_queue (
    input  logic                         clk_i,
    input  logic                         rst_i,

    input  logic [1:0]                   alloc_valid_i,
    input  logic [1:0][LQ_ID_W-1:0]      alloc_lq_id_i,
    input  logic [1:0][ROB_ID_W-1:0]     alloc_rob_id_i,
    input  logic [1:0][PRD_W-1:0]        alloc_prd_i,
    input  mem_op_t                      alloc_mem_op_i [0:1],
    input  logic [1:0][CHECKPOINTS-1:0]  alloc_branch_mask_i,

    input  logic                         address_valid_i,
    output logic                         address_ready_o,
    input  logic [LQ_ID_W-1:0]           address_lq_id_i,
    input  logic [XLEN-1:0]              address_i,
    input  logic                         address_exception_valid_i,
    input  logic [3:0]                   address_exception_cause_i,
    input  logic [XLEN-1:0]              address_exception_tval_i,

    input  logic                         complete_valid_i,
    output logic                         complete_ready_o,
    input  logic [LQ_ID_W-1:0]           complete_lq_id_i,
    input  logic                         complete_forwarded_i,

    input  logic [1:0]                   retire_valid_i,
    input  logic [1:0][LQ_ID_W-1:0]      retire_lq_id_i,
    output logic [1:0]                   lq_release_valid_o,
    output logic [1:0][LQ_ID_W-1:0]      lq_release_id_o,

    input  logic                         checkpoint_clear_i,
    input  logic [CP_W-1:0]              checkpoint_clear_id_i,
    input  recovery_t                    recovery_i,

    output load_queue_entry_t            entries_o [0:LQ_ENTRIES-1],
    output logic [3:0]                   occupancy_o
);

  load_queue_entry_t entry_q [0:LQ_ENTRIES-1];
  logic [1:0] lq_release_valid_q;
  logic [1:0][LQ_ID_W-1:0] lq_release_id_q;

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

  function automatic logic [3:0] count_valid;
    integer idx;
    begin
      count_valid = '0;
      for (idx = 0; idx < LQ_ENTRIES; idx = idx + 1)
        count_valid = count_valid + entry_q[idx].valid;
    end
  endfunction

  genvar entry_index;
  generate
    for (entry_index = 0; entry_index < LQ_ENTRIES; entry_index = entry_index + 1) begin : expose_entries
      assign entries_o[entry_index] = entry_q[entry_index];
    end
  endgenerate

  assign occupancy_o = count_valid();

  assign address_ready_o = !recovery_i.valid &&
                           entry_q[address_lq_id_i].valid &&
                           !entry_q[address_lq_id_i].address_valid &&
                           !entry_q[address_lq_id_i].completed;

  assign complete_ready_o = !recovery_i.valid &&
                            entry_q[complete_lq_id_i].valid &&
                            entry_q[complete_lq_id_i].address_valid &&
                            !entry_q[complete_lq_id_i].completed;

  assign lq_release_valid_o = lq_release_valid_q;
  assign lq_release_id_o = lq_release_id_q;

  always_ff @(posedge clk_i) begin : load_queue_state
    integer idx;
    if (rst_i) begin
      for (idx = 0; idx < LQ_ENTRIES; idx = idx + 1)
        entry_q[idx] <= '0;
      lq_release_valid_q <= '0;
      lq_release_id_q <= '0;
    end else begin
      lq_release_valid_q <= '0;

      if (recovery_i.valid) begin
        if (recovery_i.cause == REC_EXCEPT) begin
          for (idx = 0; idx < LQ_ENTRIES; idx = idx + 1)
            entry_q[idx] <= '0;
        end else if (recovery_i.cause == REC_BRANCH) begin
          for (idx = 0; idx < LQ_ENTRIES; idx = idx + 1) begin
            if (entry_q[idx].valid &&
                entry_q[idx].branch_mask[recovery_i.checkpoint_id]) begin
              entry_q[idx] <= '0;
            end else if (entry_q[idx].valid) begin
              entry_q[idx].branch_mask <= clear_checkpoint(
                  entry_q[idx].branch_mask,
                  recovery_i.checkpoint_id);
            end
          end
        end
      end else begin
        if (checkpoint_clear_i) begin
          for (idx = 0; idx < LQ_ENTRIES; idx = idx + 1) begin
            if (entry_q[idx].valid)
              entry_q[idx].branch_mask <= clear_checkpoint(
                  entry_q[idx].branch_mask,
                  checkpoint_clear_id_i);
          end
        end

        if (address_valid_i && address_ready_o) begin
          entry_q[address_lq_id_i].address_valid <= 1'b1;
          entry_q[address_lq_id_i].address <= address_i;
          entry_q[address_lq_id_i].exception_valid <=
              address_exception_valid_i;
          entry_q[address_lq_id_i].exception_cause <=
              address_exception_cause_i;
          entry_q[address_lq_id_i].exception_tval <=
              address_exception_tval_i;
        end

        if (complete_valid_i && complete_ready_o) begin
          entry_q[complete_lq_id_i].completed <= 1'b1;
          entry_q[complete_lq_id_i].forwarded <= complete_forwarded_i;
        end

        if (retire_valid_i[0] && entry_q[retire_lq_id_i[0]].valid) begin
          entry_q[retire_lq_id_i[0]] <= '0;
          lq_release_valid_q[0] <= 1'b1;
          lq_release_id_q[0] <= retire_lq_id_i[0];
        end
        if (retire_valid_i[1] && entry_q[retire_lq_id_i[1]].valid) begin
          entry_q[retire_lq_id_i[1]] <= '0;
          lq_release_valid_q[1] <= 1'b1;
          lq_release_id_q[1] <= retire_lq_id_i[1];
        end

        if (alloc_valid_i[0]) begin
          entry_q[alloc_lq_id_i[0]] <= '0;
          entry_q[alloc_lq_id_i[0]].valid <= 1'b1;
          entry_q[alloc_lq_id_i[0]].rob_id <= alloc_rob_id_i[0];
          entry_q[alloc_lq_id_i[0]].prd <= alloc_prd_i[0];
          entry_q[alloc_lq_id_i[0]].mem_op <= alloc_mem_op_i[0];
          entry_q[alloc_lq_id_i[0]].branch_mask <= alloc_branch_mask_i[0];
        end
        if (alloc_valid_i[1]) begin
          entry_q[alloc_lq_id_i[1]] <= '0;
          entry_q[alloc_lq_id_i[1]].valid <= 1'b1;
          entry_q[alloc_lq_id_i[1]].rob_id <= alloc_rob_id_i[1];
          entry_q[alloc_lq_id_i[1]].prd <= alloc_prd_i[1];
          entry_q[alloc_lq_id_i[1]].mem_op <= alloc_mem_op_i[1];
          entry_q[alloc_lq_id_i[1]].branch_mask <= alloc_branch_mask_i[1];
        end
      end
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk_i) begin : load_queue_assertions
    if (!rst_i) begin
      assert (!(alloc_valid_i[0] && alloc_valid_i[1] &&
                (alloc_lq_id_i[0] == alloc_lq_id_i[1])))
        else $error("load_queue allocated the same LQ ID twice");

      if (address_valid_i)
        assert (entry_q[address_lq_id_i].valid)
          else $error("load_queue address update targeted invalid entry");

      if (complete_valid_i)
        assert (entry_q[complete_lq_id_i].valid)
          else $error("load_queue completion targeted invalid entry");

      assert (!(retire_valid_i[0] && retire_valid_i[1] &&
                (retire_lq_id_i[0] == retire_lq_id_i[1])))
        else $error("load_queue retired the same LQ ID twice");
    end
  end
`endif

endmodule
