`timescale 1ns/1ps

import core_types_pkg::*;

// store_queue.sv
// Eight-entry direct-indexed Store Queue with a one-entry commit buffer.
//
// Allocation supplies the SQ IDs reserved by lsq_allocator. Store execution
// writes address/data/byte-enable directly by sq_id. Only an ROB-head commit
// request may move a ready entry into the commit buffer; no speculative Store
// can produce a memory write.

module store_queue (
    input  logic                         clk_i,
    input  logic                         rst_i,

    input  logic [1:0]                   alloc_valid_i,
    input  logic [1:0][SQ_ID_W-1:0]      alloc_sq_id_i,
    input  logic [1:0][ROB_ID_W-1:0]     alloc_rob_id_i,
    input  logic [1:0][CHECKPOINTS-1:0]  alloc_branch_mask_i,

    input  logic                         execute_valid_i,
    output logic                         execute_ready_o,
    input  logic [SQ_ID_W-1:0]           execute_sq_id_i,
    input  logic [XLEN-1:0]              execute_address_i,
    input  logic [XLEN-1:0]              execute_data_i,
    input  logic [3:0]                   execute_byte_enable_i,
    input  logic                         execute_exception_valid_i,
    input  logic [3:0]                   execute_exception_cause_i,
    input  logic [XLEN-1:0]              execute_exception_tval_i,

    input  logic                         commit_valid_i,
    input  logic [SQ_ID_W-1:0]           commit_sq_id_i,
    output logic                         commit_ready_o,
    output logic                         commit_done_o,

    output store_mem_req_t               mem_req_o,
    input  logic                         mem_req_ready_i,

    output logic                         sq_release_valid_o,
    output logic [SQ_ID_W-1:0]           sq_release_id_o,

    input  logic                         checkpoint_clear_i,
    input  logic [CP_W-1:0]              checkpoint_clear_id_i,
    input  recovery_t                    recovery_i,

    output store_queue_entry_t           entries_o [0:SQ_ENTRIES-1],
    output logic [3:0]                   occupancy_o
);

  store_queue_entry_t entry_q [0:SQ_ENTRIES-1];

  logic commit_buffer_valid_q;
  store_mem_req_t commit_buffer_q;
  logic commit_done_q;
  logic sq_release_valid_q;
  logic [SQ_ID_W-1:0] sq_release_id_q;
  logic commit_capture;
  logic mem_fire;
  store_mem_req_t mem_req_masked;

  task automatic invalidate_entry(input int idx);
    begin
      entry_q[idx].valid <= 1'b0;
      entry_q[idx].address_valid <= 1'b0;
      entry_q[idx].data_valid <= 1'b0;
      entry_q[idx].exception_valid <= 1'b0;
      entry_q[idx].branch_mask <= '0;
    end
  endtask

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
      for (idx = 0; idx < SQ_ENTRIES; idx = idx + 1)
        count_valid = count_valid + entry_q[idx].valid;
    end
  endfunction

  genvar entry_index;
  generate
    for (entry_index = 0; entry_index < SQ_ENTRIES; entry_index = entry_index + 1) begin : expose_entries
      assign entries_o[entry_index] = entry_q[entry_index];
    end
  endgenerate

  assign occupancy_o = count_valid();

  assign execute_ready_o = !recovery_i.valid &&
                           entry_q[execute_sq_id_i].valid;

  assign commit_ready_o = !recovery_i.valid && !commit_buffer_valid_q &&
                          entry_q[commit_sq_id_i].valid &&
                          entry_q[commit_sq_id_i].address_valid &&
                          entry_q[commit_sq_id_i].data_valid &&
                          !entry_q[commit_sq_id_i].exception_valid;
  assign commit_capture = commit_valid_i && commit_ready_o;

  always_comb begin
    mem_req_masked = commit_buffer_q;
    mem_req_masked.valid = commit_buffer_valid_q && !recovery_i.valid;
  end

  assign mem_req_o = mem_req_masked;
  assign mem_fire = !recovery_i.valid && commit_buffer_valid_q &&
                    mem_req_ready_i;

  assign commit_done_o = commit_done_q;
  assign sq_release_valid_o = sq_release_valid_q;
  assign sq_release_id_o = sq_release_id_q;

  always_ff @(posedge clk_i) begin : store_queue_state
    integer idx;
    if (rst_i) begin
      for (idx = 0; idx < SQ_ENTRIES; idx = idx + 1)
        entry_q[idx] <= '0;
      commit_buffer_valid_q <= 1'b0;
      commit_buffer_q <= '0;
      commit_done_q <= 1'b0;
      sq_release_valid_q <= 1'b0;
      sq_release_id_q <= '0;
    end else begin
      commit_done_q <= 1'b0;
      sq_release_valid_q <= 1'b0;

      // The commit buffer contains an already-authorized ROB-head Store and is
      // therefore not killed by younger branch recovery.
      if (mem_fire) begin
        commit_buffer_valid_q <= 1'b0;
        commit_done_q <= 1'b1;
        sq_release_valid_q <= 1'b1;
        sq_release_id_q <= commit_buffer_q.sq_id;
        invalidate_entry(commit_buffer_q.sq_id);
      end

      if (recovery_i.valid) begin
        if (recovery_i.cause == REC_EXCEPT) begin
          for (idx = 0; idx < SQ_ENTRIES; idx = idx + 1)
            invalidate_entry(idx);
        end else if (recovery_i.cause == REC_BRANCH) begin
          for (idx = 0; idx < SQ_ENTRIES; idx = idx + 1) begin
            if (entry_q[idx].valid &&
                entry_q[idx].branch_mask[recovery_i.checkpoint_id]) begin
              invalidate_entry(idx);
            end else if (entry_q[idx].valid) begin
              entry_q[idx].branch_mask <= clear_checkpoint(
                  entry_q[idx].branch_mask,
                  recovery_i.checkpoint_id);
            end
          end
        end
      end else begin
        if (checkpoint_clear_i) begin
          for (idx = 0; idx < SQ_ENTRIES; idx = idx + 1) begin
            if (entry_q[idx].valid)
              entry_q[idx].branch_mask <= clear_checkpoint(
                  entry_q[idx].branch_mask,
                  checkpoint_clear_id_i);
          end
        end

        if (execute_valid_i && execute_ready_o) begin
          entry_q[execute_sq_id_i].address_valid <= 1'b1;
          entry_q[execute_sq_id_i].address <= execute_address_i;
          entry_q[execute_sq_id_i].data_valid <= 1'b1;
          entry_q[execute_sq_id_i].data <= execute_data_i;
          entry_q[execute_sq_id_i].byte_enable <= execute_byte_enable_i;
          entry_q[execute_sq_id_i].exception_valid <=
              execute_exception_valid_i;
          entry_q[execute_sq_id_i].exception_cause <=
              execute_exception_cause_i;
          entry_q[execute_sq_id_i].exception_tval <=
              execute_exception_tval_i;
        end

        if (alloc_valid_i[0]) begin
          entry_q[alloc_sq_id_i[0]].valid <= 1'b1;
          entry_q[alloc_sq_id_i[0]].rob_id <= alloc_rob_id_i[0];
          entry_q[alloc_sq_id_i[0]].address_valid <= 1'b0;
          entry_q[alloc_sq_id_i[0]].data_valid <= 1'b0;
          entry_q[alloc_sq_id_i[0]].exception_valid <= 1'b0;
          entry_q[alloc_sq_id_i[0]].branch_mask <= alloc_branch_mask_i[0];
        end
        if (alloc_valid_i[1]) begin
          entry_q[alloc_sq_id_i[1]].valid <= 1'b1;
          entry_q[alloc_sq_id_i[1]].rob_id <= alloc_rob_id_i[1];
          entry_q[alloc_sq_id_i[1]].address_valid <= 1'b0;
          entry_q[alloc_sq_id_i[1]].data_valid <= 1'b0;
          entry_q[alloc_sq_id_i[1]].exception_valid <= 1'b0;
          entry_q[alloc_sq_id_i[1]].branch_mask <= alloc_branch_mask_i[1];
        end

        if (commit_capture) begin
          commit_buffer_valid_q <= 1'b1;
          commit_buffer_q.valid <= 1'b1;
          commit_buffer_q.sq_id <= commit_sq_id_i;
          commit_buffer_q.address <= entry_q[commit_sq_id_i].address;
          commit_buffer_q.data <= entry_q[commit_sq_id_i].data;
          commit_buffer_q.byte_enable <=
              entry_q[commit_sq_id_i].byte_enable;
        end
      end
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk_i) begin : store_queue_assertions
    if (!rst_i) begin
      assert (!(alloc_valid_i[0] && alloc_valid_i[1] &&
                (alloc_sq_id_i[0] == alloc_sq_id_i[1])))
        else $error("store_queue allocated the same SQ ID twice");

      if (execute_valid_i)
        assert (entry_q[execute_sq_id_i].valid)
          else $error("store_queue execute targeted an invalid SQ entry");

      if (mem_req_o.valid) begin
        assert (commit_buffer_valid_q)
          else $error("speculative Store generated a memory request");
        assert (mem_req_o.byte_enable != 4'b0000)
          else $error("Store memory request has empty byte enable");
      end

      if (commit_valid_i && entry_q[commit_sq_id_i].exception_valid)
        assert (!commit_ready_o)
          else $error("exception Store entered commit buffer");
    end
  end
`endif

endmodule
