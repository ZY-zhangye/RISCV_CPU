`timescale 1ns/1ps

import core_types_pkg::*;

// lsu_pipeline.sv
// Conservative single-request LSU pipeline.
//
// Load path:
//   L0 capture/AGU -> L1 parallel SQ candidates -> L2 balanced reduction
//   -> L3 registered nearest-store decision -> forwarding or Data RAM
//   request/response -> local completion buffer.
//
// Store path:
//   L0 capture/AGU -> direct SQ update + Store completion.

module lsu_pipeline (
    input  logic                       clk_i,
    input  logic                       rst_i,

    input  logic                       issue_valid_i,
    output logic                       issue_ready_o,
    input  execute_uop_t               issue_uop_i,

    input  store_queue_entry_t         sq_entries_i [0:SQ_ENTRIES-1],

    output logic                       lq_address_valid_o,
    input  logic                       lq_address_ready_i,
    output logic [LQ_ID_W-1:0]         lq_address_id_o,
    output logic [XLEN-1:0]            lq_address_o,
    output logic                       lq_address_exception_valid_o,
    output logic [3:0]                 lq_address_exception_cause_o,
    output logic [XLEN-1:0]            lq_address_exception_tval_o,

    output logic                       lq_complete_valid_o,
    output logic [LQ_ID_W-1:0]         lq_complete_id_o,
    output logic                       lq_complete_forwarded_o,

    output logic                       sq_update_valid_o,
    input  logic                       sq_update_ready_i,
    output logic [SQ_ID_W-1:0]         sq_update_id_o,
    output logic [XLEN-1:0]            sq_update_address_o,
    output logic [XLEN-1:0]            sq_update_data_o,
    output logic [3:0]                 sq_update_byte_enable_o,
    output logic                       sq_update_exception_valid_o,
    output logic [3:0]                 sq_update_exception_cause_o,
    output logic [XLEN-1:0]            sq_update_exception_tval_o,

    output load_mem_req_t              mem_req_o,
    input  logic                       mem_req_ready_i,
    input  load_mem_resp_t             mem_resp_i,
    output logic                       mem_resp_ready_o,

    output logic                       result_valid_o,
    input  logic                       result_ready_i,
    output completion_t                result_o,

    input  recovery_t                  recovery_i
);

  typedef enum logic [2:0] {
    LSU_IDLE,
    LSU_STORE_EXEC,
    LSU_LOAD_COMPARE,
    LSU_LOAD_REDUCE,
    LSU_LOAD_DECIDE,
    LSU_LOAD_MEM_REQ,
    LSU_LOAD_MEM_WAIT
  } lsu_state_t;

  typedef struct packed {
    logic                      valid;
    logic [ROB_ID_W-1:0]       distance;
    logic                      data_valid;
    logic [3:0]                byte_enable;
    logic [XLEN-1:0]           data;
  } forward_candidate_t;

  lsu_state_t state_q;
  execute_uop_t req_uop_q;
  logic [XLEN-1:0] req_address_q;
  logic req_exception_valid_q;
  logic [3:0] req_exception_cause_q;
  logic [XLEN-1:0] req_exception_tval_q;
  logic lq_address_sent_q;

  logic sq_older_unknown_q;
  forward_candidate_t sq_candidate_q [0:SQ_ENTRIES-1];
  forward_candidate_t reduce_pair [0:3];
  forward_candidate_t reduce_half [0:1];
  forward_candidate_t reduce_winner;
  forward_candidate_t selected_candidate_q;

  completion_t completion_q;
  logic completion_valid_q;
  logic [CHECKPOINTS-1:0] completion_branch_mask_q;
  logic completion_slot_ready;
  logic completion_killed;

  logic lq_complete_valid_q;
  logic [LQ_ID_W-1:0] lq_complete_id_q;
  logic lq_complete_forwarded_q;

  logic issue_fire;
  logic [XLEN-1:0] issue_address;
  logic issue_misaligned;

  function automatic logic is_load_op(input mem_op_t mem_op);
    is_load_op = (mem_op <= MEM_LHU);
  endfunction

  function automatic logic is_store_op(input mem_op_t mem_op);
    is_store_op = (mem_op >= MEM_SB);
  endfunction

  function automatic logic access_misaligned(
      input mem_op_t mem_op,
      input logic [XLEN-1:0] address
  );
    begin
      unique case (mem_op)
        MEM_LH, MEM_LHU, MEM_SH: access_misaligned = address[0];
        MEM_LW, MEM_SW:          access_misaligned = |address[1:0];
        default:                 access_misaligned = 1'b0;
      endcase
    end
  endfunction

  function automatic logic [3:0] load_byte_mask(
      input mem_op_t mem_op,
      input logic [1:0] offset
  );
    begin
      unique case (mem_op)
        MEM_LB, MEM_LBU: load_byte_mask = 4'b0001 << offset;
        MEM_LH, MEM_LHU: load_byte_mask = 4'b0011 << offset;
        default:         load_byte_mask = 4'b1111;
      endcase
    end
  endfunction

  function automatic logic [3:0] store_byte_enable(
      input mem_op_t mem_op,
      input logic [1:0] offset
  );
    begin
      unique case (mem_op)
        MEM_SB:  store_byte_enable = 4'b0001 << offset;
        MEM_SH:  store_byte_enable = 4'b0011 << offset;
        default: store_byte_enable = 4'b1111;
      endcase
    end
  endfunction

  function automatic logic [XLEN-1:0] align_store_data(
      input mem_op_t mem_op,
      input logic [XLEN-1:0] data,
      input logic [1:0] offset
  );
    begin
      unique case (mem_op)
        MEM_SB:  align_store_data = {24'd0, data[7:0]} << (offset * 8);
        MEM_SH:  align_store_data = {16'd0, data[15:0]} << (offset * 8);
        default: align_store_data = data;
      endcase
    end
  endfunction

  function automatic logic [XLEN-1:0] extract_load_data(
      input mem_op_t mem_op,
      input logic [XLEN-1:0] word,
      input logic [1:0] offset
  );
    logic [XLEN-1:0] shifted;
    begin
      shifted = word >> (offset * 8);
      unique case (mem_op)
        MEM_LB:  extract_load_data = {{24{shifted[7]}}, shifted[7:0]};
        MEM_LBU: extract_load_data = {24'd0, shifted[7:0]};
        MEM_LH:  extract_load_data = {{16{shifted[15]}}, shifted[15:0]};
        MEM_LHU: extract_load_data = {16'd0, shifted[15:0]};
        default: extract_load_data = shifted;
      endcase
    end
  endfunction

  function automatic logic [ROB_ID_W-1:0] rob_distance(
      input logic [ROB_ID_W-1:0] older,
      input logic [ROB_ID_W-1:0] younger
  );
    rob_distance = younger - older;
  endfunction

  function automatic logic rob_is_older(
      input logic [ROB_ID_W-1:0] candidate,
      input logic [ROB_ID_W-1:0] reference
  );
    logic [ROB_ID_W-1:0] distance;
    begin
      distance = rob_distance(candidate, reference);
      rob_is_older = (distance != '0) && !distance[ROB_ID_W-1];
    end
  endfunction

  function automatic forward_candidate_t nearer_candidate(
      input forward_candidate_t left,
      input forward_candidate_t right
  );
    begin
      if (!left.valid)
        nearer_candidate = right;
      else if (!right.valid)
        nearer_candidate = left;
      else if (right.distance < left.distance)
        nearer_candidate = right;
      else
        nearer_candidate = left;
    end
  endfunction

  // A balanced 8-to-1 reduction keeps the nearest-Store selection at three
  // comparator levels.  The previous procedural accumulator synthesized as
  // an eight-entry serial priority chain and dominated the 200 MHz path.
  always_comb begin
    reduce_pair[0] = nearer_candidate(sq_candidate_q[0], sq_candidate_q[1]);
    reduce_pair[1] = nearer_candidate(sq_candidate_q[2], sq_candidate_q[3]);
    reduce_pair[2] = nearer_candidate(sq_candidate_q[4], sq_candidate_q[5]);
    reduce_pair[3] = nearer_candidate(sq_candidate_q[6], sq_candidate_q[7]);
    reduce_half[0] = nearer_candidate(reduce_pair[0], reduce_pair[1]);
    reduce_half[1] = nearer_candidate(reduce_pair[2], reduce_pair[3]);
    reduce_winner = nearer_candidate(reduce_half[0], reduce_half[1]);
  end

  function automatic completion_t make_completion(
      input execute_uop_t uop,
      input logic [XLEN-1:0] data,
      input logic exception_valid,
      input logic [3:0] exception_cause,
      input logic [XLEN-1:0] exception_tval
  );
    completion_t completion;
    begin
      completion = '0;
      completion.valid = 1'b1;
      completion.prd = uop.prd;
      completion.rob_id = uop.rob_id;
      completion.data = data;
      completion.exception_valid = exception_valid;
      completion.exception_cause = exception_cause;
      completion.exception_tval = exception_tval;
      completion.producer = PROD_LSU;
      completion.write_prf = uop.is_load && uop.write_rd && !exception_valid;
      completion.is_store = uop.is_store;
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

  assign issue_address = issue_uop_i.src1 + issue_uop_i.imm;
  assign issue_misaligned = access_misaligned(issue_uop_i.mem_op,
                                              issue_address);
  assign issue_ready_o = (state_q == LSU_IDLE) && !recovery_i.valid;
  assign issue_fire = issue_valid_i && issue_ready_o && issue_uop_i.valid;

  assign completion_slot_ready = !completion_valid_q || result_ready_i;
  assign completion_killed = recovery_i.valid &&
      ((recovery_i.cause == REC_EXCEPT) ||
       ((recovery_i.cause == REC_BRANCH) &&
        completion_branch_mask_q[recovery_i.checkpoint_id]));

  assign result_valid_o = completion_valid_q && !completion_killed;
  assign result_o = result_valid_o ? completion_q : '0;

  assign lq_address_valid_o = !recovery_i.valid &&
                              (state_q == LSU_LOAD_COMPARE) &&
                              !lq_address_sent_q;
  assign lq_address_id_o = req_uop_q.lq_id;
  assign lq_address_o = req_address_q;
  assign lq_address_exception_valid_o = req_exception_valid_q;
  assign lq_address_exception_cause_o = req_exception_cause_q;
  assign lq_address_exception_tval_o = req_exception_tval_q;

  assign lq_complete_valid_o = lq_complete_valid_q;
  assign lq_complete_id_o = lq_complete_id_q;
  assign lq_complete_forwarded_o = lq_complete_forwarded_q;

  assign sq_update_valid_o = !recovery_i.valid &&
                             (state_q == LSU_STORE_EXEC) &&
                             completion_slot_ready;
  assign sq_update_id_o = req_uop_q.sq_id;
  assign sq_update_address_o = req_address_q;
  assign sq_update_data_o = align_store_data(req_uop_q.mem_op,
                                             req_uop_q.store_data,
                                             req_address_q[1:0]);
  assign sq_update_byte_enable_o = store_byte_enable(req_uop_q.mem_op,
                                                     req_address_q[1:0]);
  assign sq_update_exception_valid_o = req_exception_valid_q;
  assign sq_update_exception_cause_o = req_exception_cause_q;
  assign sq_update_exception_tval_o = req_exception_tval_q;

  always_comb begin
    mem_req_o = '0;
    if (!recovery_i.valid && (state_q == LSU_LOAD_MEM_REQ)) begin
      mem_req_o.valid = 1'b1;
      mem_req_o.lq_id = req_uop_q.lq_id;
      mem_req_o.address = {req_address_q[XLEN-1:2], 2'b00};
    end
  end
  assign mem_resp_ready_o = !recovery_i.valid &&
                            (state_q == LSU_LOAD_MEM_WAIT) &&
                            completion_slot_ready &&
                            (mem_resp_i.lq_id == req_uop_q.lq_id);

  always_ff @(posedge clk_i) begin : lsu_state
    integer idx;
    logic older_unknown;
    logic [3:0] required_mask;
    logic full_cover;
    logic [XLEN-1:0] loaded_data;

    if (rst_i) begin
      state_q <= LSU_IDLE;
      req_uop_q <= '0;
      req_address_q <= '0;
      req_exception_valid_q <= 1'b0;
      req_exception_cause_q <= '0;
      req_exception_tval_q <= '0;
      lq_address_sent_q <= 1'b0;
      sq_older_unknown_q <= 1'b0;
      for (idx = 0; idx < SQ_ENTRIES; idx = idx + 1)
        sq_candidate_q[idx] <= '0;
      selected_candidate_q <= '0;
      completion_q <= '0;
      completion_valid_q <= 1'b0;
      completion_branch_mask_q <= '0;
      lq_complete_valid_q <= 1'b0;
      lq_complete_id_q <= '0;
      lq_complete_forwarded_q <= 1'b0;
    end else begin
      lq_complete_valid_q <= 1'b0;

      if (completion_valid_q && result_ready_i) begin
        completion_valid_q <= 1'b0;
      end

      if (recovery_i.valid) begin
        if (completion_killed) begin
          completion_valid_q <= 1'b0;
        end else if (completion_valid_q &&
                     (recovery_i.cause == REC_BRANCH)) begin
          completion_branch_mask_q <= clear_checkpoint(
              completion_branch_mask_q,
              recovery_i.checkpoint_id);
        end

        if ((recovery_i.cause == REC_EXCEPT) ||
            ((state_q != LSU_IDLE) &&
             req_uop_q.branch_mask[recovery_i.checkpoint_id])) begin
          state_q <= LSU_IDLE;
          lq_address_sent_q <= 1'b0;
        end else if (state_q != LSU_IDLE) begin
          req_uop_q.branch_mask <= clear_checkpoint(
              req_uop_q.branch_mask,
              recovery_i.checkpoint_id);
          if ((state_q == LSU_LOAD_REDUCE) ||
              (state_q == LSU_LOAD_DECIDE))
            state_q <= LSU_LOAD_COMPARE;
        end
      end else begin
        if (issue_fire) begin
          req_uop_q <= issue_uop_i;
          req_address_q <= issue_address;
          req_exception_valid_q <= issue_misaligned;
          req_exception_cause_q <= is_store_op(issue_uop_i.mem_op) ?
                                   4'd6 : 4'd4;
          req_exception_tval_q <= issue_address;
          lq_address_sent_q <= 1'b0;
          state_q <= issue_uop_i.is_store ?
                     LSU_STORE_EXEC : LSU_LOAD_COMPARE;
        end

        if ((state_q == LSU_STORE_EXEC) && sq_update_valid_o &&
            sq_update_ready_i) begin
          completion_q <= make_completion(req_uop_q,
                                          '0,
                                          req_exception_valid_q,
                                          req_exception_cause_q,
                                          req_exception_tval_q);
          completion_valid_q <= 1'b1;
          completion_branch_mask_q <= req_uop_q.branch_mask;
          state_q <= LSU_IDLE;
        end

        if (state_q == LSU_LOAD_COMPARE) begin
          if (lq_address_valid_o && lq_address_ready_i)
            lq_address_sent_q <= 1'b1;

          if (lq_address_sent_q ||
              (lq_address_valid_o && lq_address_ready_i)) begin
            if (req_exception_valid_q) begin
              if (completion_slot_ready) begin
                completion_q <= make_completion(req_uop_q,
                                                '0,
                                                1'b1,
                                                req_exception_cause_q,
                                                req_exception_tval_q);
                completion_valid_q <= 1'b1;
                completion_branch_mask_q <= req_uop_q.branch_mask;
                lq_complete_valid_q <= 1'b1;
                lq_complete_id_q <= req_uop_q.lq_id;
                lq_complete_forwarded_q <= 1'b0;
                state_q <= LSU_IDLE;
              end
            end else begin
              older_unknown = 1'b0;
              required_mask = load_byte_mask(req_uop_q.mem_op,
                                             req_address_q[1:0]);
              for (idx = 0; idx < SQ_ENTRIES; idx = idx + 1) begin
                sq_candidate_q[idx].valid <=
                    sq_entries_i[idx].valid &&
                    rob_is_older(sq_entries_i[idx].rob_id,
                                 req_uop_q.rob_id) &&
                    sq_entries_i[idx].address_valid &&
                    (sq_entries_i[idx].address[XLEN-1:2] ==
                     req_address_q[XLEN-1:2]) &&
                    (|(sq_entries_i[idx].byte_enable & required_mask));
                sq_candidate_q[idx].distance <= rob_distance(
                    sq_entries_i[idx].rob_id,
                    req_uop_q.rob_id);
                sq_candidate_q[idx].data_valid <=
                    sq_entries_i[idx].data_valid;
                sq_candidate_q[idx].byte_enable <=
                    sq_entries_i[idx].byte_enable;
                sq_candidate_q[idx].data <= sq_entries_i[idx].data;
                if (sq_entries_i[idx].valid &&
                    rob_is_older(sq_entries_i[idx].rob_id,
                                 req_uop_q.rob_id)) begin
                  if (!sq_entries_i[idx].address_valid)
                    older_unknown = 1'b1;
                end
              end
              sq_older_unknown_q <= older_unknown;
              state_q <= LSU_LOAD_REDUCE;
            end
          end
        end

        if (state_q == LSU_LOAD_REDUCE) begin
          if (sq_older_unknown_q) begin
            state_q <= LSU_LOAD_COMPARE;
          end else begin
            selected_candidate_q <= reduce_winner;
            state_q <= LSU_LOAD_DECIDE;
          end
        end

        if (state_q == LSU_LOAD_DECIDE) begin
            if (selected_candidate_q.valid) begin
              required_mask = load_byte_mask(req_uop_q.mem_op,
                                             req_address_q[1:0]);
              full_cover = ((selected_candidate_q.byte_enable &
                             required_mask) == required_mask);
              if (full_cover && selected_candidate_q.data_valid) begin
                if (completion_slot_ready) begin
                  loaded_data = extract_load_data(
                      req_uop_q.mem_op,
                      selected_candidate_q.data,
                      req_address_q[1:0]);
                  completion_q <= make_completion(req_uop_q,
                                                  loaded_data,
                                                  1'b0,
                                                  '0,
                                                  '0);
                  completion_valid_q <= 1'b1;
                  completion_branch_mask_q <= req_uop_q.branch_mask;
                  lq_complete_valid_q <= 1'b1;
                  lq_complete_id_q <= req_uop_q.lq_id;
                  lq_complete_forwarded_q <= 1'b1;
                  state_q <= LSU_IDLE;
                end
              end else begin
                state_q <= LSU_LOAD_COMPARE;
              end
            end else begin
              state_q <= LSU_LOAD_MEM_REQ;
            end
        end

        if ((state_q == LSU_LOAD_MEM_REQ) && mem_req_ready_i)
          state_q <= LSU_LOAD_MEM_WAIT;

        if ((state_q == LSU_LOAD_MEM_WAIT) && mem_resp_i.valid &&
            mem_resp_ready_o) begin
          loaded_data = extract_load_data(req_uop_q.mem_op,
                                          mem_resp_i.data,
                                          req_address_q[1:0]);
          completion_q <= make_completion(req_uop_q,
                                          loaded_data,
                                          mem_resp_i.error,
                                          mem_resp_i.error ? 4'd5 : '0,
                                          mem_resp_i.error ?
                                              req_address_q : '0);
          completion_valid_q <= 1'b1;
          completion_branch_mask_q <= req_uop_q.branch_mask;
          lq_complete_valid_q <= 1'b1;
          lq_complete_id_q <= req_uop_q.lq_id;
          lq_complete_forwarded_q <= 1'b0;
          state_q <= LSU_IDLE;
        end
      end
    end
  end

`ifndef SYNTHESIS
  property result_hold_stable;
    @(posedge clk_i) disable iff (rst_i || recovery_i.valid)
      result_valid_o && !result_ready_i |=> result_valid_o && $stable(result_o);
  endproperty
  assert property (result_hold_stable);

  always_ff @(posedge clk_i) begin : lsu_assertions
    if (!rst_i) begin
      if (issue_valid_i && issue_ready_o) begin
        assert (issue_uop_i.fu_type == FU_LSU)
          else $error("lsu_pipeline accepted non-LSU uop");
        assert (issue_uop_i.is_load ^ issue_uop_i.is_store)
          else $error("lsu_pipeline uop must be exactly one of Load/Store");
      end

      if (mem_req_o.valid)
        assert (req_uop_q.is_load && !req_exception_valid_q)
          else $error("invalid or Store request entered load memory port");

      if (sq_update_valid_o)
        assert (req_uop_q.is_store)
          else $error("Load attempted to update Store Queue");
    end
  end
`endif

endmodule
