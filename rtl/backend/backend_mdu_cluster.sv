import core_types_pkg::*;

// Backend integration boundary with INT/Branch/CSR, LSU, and MDU.
// This keeps the LSU cluster timing cuts and opens the MDU IQ plus local
// mul/div frontend.  MDU subunit backpressure is absorbed by Operand Read.
module backend_mdu_cluster #(
    parameter logic [XLEN-1:0] HART_ID = '0,
    parameter logic [XLEN-1:0] RESET_MTVEC = RESET_PC
) (
    input  logic                         clk_i,
    input  logic                         rst_i,

    input  logic [1:0]                   dec_valid_i,
    output logic                         dec_ready_o,
    input  decoded_uop_t                 dec_uop0_i,
    input  decoded_uop_t                 dec_uop1_i,

    output load_mem_req_t                load_mem_req_o,
    input  logic                         load_mem_req_ready_i,
    input  load_mem_resp_t               load_mem_resp_i,
    output logic                         load_mem_resp_ready_o,

    output store_mem_req_t               store_mem_req_o,
    input  logic                         store_mem_req_ready_i,

    output recovery_t                    recovery_o,
    output logic                         checkpoint_clear_valid_o,
    output logic [CP_W-1:0]              checkpoint_clear_id_o,
    output logic                         redirect_valid_o,
    output logic [XLEN-1:0]              redirect_pc_o,
    output logic                         branch_update_valid_o,
    output branch_update_t               branch_update_o,

    output logic [1:0]                   retire_count_o,
    output logic [5:0]                   rob_occupancy_o,
    output logic                         rob_empty_o,
    output logic                         rob_full_o,
    output logic [6:0]                   free_prd_count_o,
    output logic [3:0]                   free_lq_count_o,
    output logic [3:0]                   free_sq_count_o,
    output logic [$clog2(CHECKPOINTS+1)-1:0]
                                             active_checkpoint_count_o,
    output logic                         recovery_busy_o,
    output logic                         busy_o,
    output logic [2:0]                   dispatch_buffer_occupancy_o,
    output logic [$clog2(IQ_INT_ENTRIES+1)-1:0]
                                             int_issue_occupancy_o,
    output logic [$clog2(IQ_MEM_ENTRIES+1)-1:0]
                                             mem_issue_occupancy_o,
    output logic [$clog2(IQ_MDU_ENTRIES+1)-1:0]
                                             mdu_issue_occupancy_o,
    output logic [3:0]                   lq_occupancy_o,
    output logic [3:0]                   sq_occupancy_o,
    output logic [PHYS_REGS-1:0]         prf_ready_bits_o,
    output logic [XLEN-1:0]              mstatus_o,
    output logic [XLEN-1:0]              mtvec_o,
    output logic [XLEN-1:0]              mepc_o,
    output logic [XLEN-1:0]              mcause_o,
    output logic [XLEN-1:0]              mtval_o
);

  logic [1:0] dispatch_valid;
  logic dispatch_ready;
  renamed_uop_t dispatch_uop0;
  renamed_uop_t dispatch_uop1;
  logic dispatch_fire;

  logic [1:0] int_push_valid_raw;
  logic [1:0] int_push_ready;
  issue_uop_t int_push_uop0_raw;
  issue_uop_t int_push_uop1_raw;
  logic [1:0] int_push_valid_q;
  issue_uop_t int_push_uop0_q;
  issue_uop_t int_push_uop1_q;
  logic int_push_stage_accept;
  logic int_push_stage_pop;
  logic int_iq_push_ready;
  logic int_iq_empty;
  logic int_iq_full;
  logic [$clog2(IQ_INT_ENTRIES+1)-1:0] int_iq_occupancy;

  logic [1:0] mem_push_valid_raw;
  logic [1:0] mem_push_ready;
  issue_uop_t mem_push_uop0_raw;
  issue_uop_t mem_push_uop1_raw;
  logic [1:0] mem_push_valid_q;
  issue_uop_t mem_push_uop0_q;
  issue_uop_t mem_push_uop1_q;
  logic mem_push_stage_accept;
  logic mem_push_stage_pop;
  logic mem_iq_push_ready;
  logic mem_iq_empty;
  logic mem_iq_full;
  logic [$clog2(IQ_MEM_ENTRIES+1)-1:0] mem_iq_occupancy;

  logic [1:0] mdu_push_valid_raw;
  logic [1:0] mdu_push_ready;
  issue_uop_t mdu_push_uop0_raw;
  issue_uop_t mdu_push_uop1_raw;
  logic [1:0] mdu_push_valid_q;
  issue_uop_t mdu_push_uop0_q;
  issue_uop_t mdu_push_uop1_q;
  logic mdu_push_stage_accept;
  logic mdu_push_stage_pop;
  logic mdu_iq_push_ready;
  logic mdu_iq_empty;
  logic mdu_iq_full;
  logic [$clog2(IQ_MDU_ENTRIES+1)-1:0] mdu_iq_occupancy;

  logic [2:0] int_candidate_valid;
  issue_uop_t int_candidate_uop0;
  issue_uop_t int_candidate_uop1;
  issue_uop_t int_candidate_uop2;
  logic [$clog2(IQ_INT_ENTRIES)-1:0] unused_int_slot0;
  logic [$clog2(IQ_INT_ENTRIES)-1:0] unused_int_slot1;
  logic [$clog2(IQ_INT_ENTRIES)-1:0] unused_int_slot2;
  logic [2:0] int_issue_grant;

  logic [1:0] mem_candidate_valid;
  issue_uop_t mem_candidate_uop0;
  issue_uop_t mem_candidate_uop1;
  logic [$clog2(IQ_MEM_ENTRIES)-1:0] unused_mem_slot0;
  logic [$clog2(IQ_MEM_ENTRIES)-1:0] unused_mem_slot1;
  logic [1:0] mem_issue_grant;
  logic [1:0] mem_issue_allowed;

  logic mdu_candidate_valid;
  issue_uop_t mdu_candidate_uop;
  logic [$clog2(IQ_MDU_ENTRIES)-1:0] unused_mdu_slot0;
  logic mdu_issue_grant;

  logic [2:0] issue_valid;
  issue_port_t issue_port0;
  issue_port_t issue_port1;
  issue_port_t issue_port2;
  issue_uop_t issue_uop0;
  issue_uop_t issue_uop1;
  issue_uop_t issue_uop2;

  logic [5:0] prf_read_valid;
  logic [5:0][PRD_W-1:0] prf_read_prd;
  logic [5:0][XLEN-1:0] prf_read_data;

  logic int0_issue_ready;
  logic int1_issue_ready;
  logic lsu_issue_ready;
  logic mdu_issue_ready;
  logic int0_ex_valid;
  logic int0_ex_ready;
  execute_uop_t int0_ex_uop;
  logic int1_ex_valid;
  logic int1_ex_ready;
  execute_uop_t int1_ex_uop;
  logic lsu_ex_valid;
  logic lsu_ex_ready;
  execute_uop_t lsu_ex_uop;
  logic mdu_ex_valid;
  logic mdu_ex_ready;
  execute_uop_t mdu_ex_uop;
  logic mdu_frontend_ready;
  execute_uop_t mdu_fifo_uop_q [0:1];
  logic [1:0] mdu_fifo_count_q;
  logic mdu_fifo_fire_in;
  logic mdu_fifo_fire_out;

  logic int0_result_valid;
  logic int0_result_ready;
  completion_t int0_result;
  logic int1_result_valid;
  logic int1_result_ready;
  completion_t int1_result;
  logic lsu_result_valid;
  logic lsu_result_ready;
  completion_t lsu_result;
  logic mul_result_valid;
  logic mul_result_ready;
  completion_t mul_result;
  logic div_result_valid;
  logic div_result_ready;
  completion_t div_result;
  logic lq_address_valid;
  logic [LQ_ID_W-1:0] lq_address_id;
  logic [XLEN-1:0] lq_address;
  logic lq_address_exception_valid;
  logic [3:0] lq_address_exception_cause;
  logic [XLEN-1:0] lq_address_exception_tval;
  logic lq_complete_valid;
  logic [LQ_ID_W-1:0] lq_complete_id;
  logic lq_complete_forwarded;
  logic sq_update_valid;
  logic [SQ_ID_W-1:0] sq_update_id;
  logic [XLEN-1:0] sq_update_address;
  logic [XLEN-1:0] sq_update_data;
  logic [3:0] sq_update_byte_enable;
  logic sq_update_exception_valid;
  logic [3:0] sq_update_exception_cause;
  logic [XLEN-1:0] sq_update_exception_tval;
  branch_resolve_t branch_event_raw;
  branch_resolve_t branch_event_q;
  branch_resolve_t branch_event_to_commit_q;
  logic branch_event_pending_q;
  logic branch_event_complete_match;
  logic branch_event_fire;

  logic [1:0] wb_valid;
  completion_t wb_completion [0:1];
  logic [1:0] prf_write_valid;
  logic [1:0][PRD_W-1:0] prf_write_prd;
  logic [1:0][XLEN-1:0] prf_write_data;
  logic [1:0] wakeup_valid;
  logic [1:0][PRD_W-1:0] wakeup_prd;
  logic [1:0] ready_wakeup_valid;
  logic [1:0][PRD_W-1:0] ready_wakeup_prd;
  logic [1:0] rob_complete_valid;
  completion_t rob_complete [0:1];

  logic [2:0] db_occupancy;
  logic db_empty;
  logic db_full;

  load_queue_entry_t lq_entries [0:LQ_ENTRIES-1];
  store_queue_entry_t sq_entries [0:SQ_ENTRIES-1];

  logic [1:0] lq_alloc_valid;
  logic [1:0][LQ_ID_W-1:0] lq_alloc_id;
  logic [1:0][ROB_ID_W-1:0] lq_alloc_rob_id;
  logic [1:0][PRD_W-1:0] lq_alloc_prd;
  mem_op_t lq_alloc_mem_op [0:1];
  logic [1:0][CHECKPOINTS-1:0] lq_alloc_branch_mask;
  logic [1:0] lq_retire_valid;
  logic [1:0][LQ_ID_W-1:0] lq_retire_id;
  logic [1:0] lq_release_valid;
  logic [1:0][LQ_ID_W-1:0] lq_release_id;
  logic lq_address_ready;
  logic lq_complete_ready;

  logic [1:0] sq_alloc_valid;
  logic [1:0][SQ_ID_W-1:0] sq_alloc_id;
  logic [1:0][ROB_ID_W-1:0] sq_alloc_rob_id;
  logic [1:0][CHECKPOINTS-1:0] sq_alloc_branch_mask;
  logic sq_update_ready;
  logic sq_commit_valid;
  logic [SQ_ID_W-1:0] sq_commit_id;
  logic sq_commit_ready;
  logic sq_commit_done;
  logic sq_release_valid;
  logic [SQ_ID_W-1:0] sq_release_id;
  logic commit_busy;

  assign dispatch_buffer_occupancy_o = db_occupancy;
  assign int_issue_occupancy_o = int_iq_occupancy;
  assign mem_issue_occupancy_o = mem_iq_occupancy;
  assign mdu_issue_occupancy_o = mdu_iq_occupancy;
  assign busy_o = commit_busy || (mdu_fifo_count_q != 2'd0);

  assign branch_event_complete_match =
      ((rob_complete[0].valid &&
        (rob_complete[0].rob_id == branch_event_q.rob_id)) ||
       (rob_complete[1].valid &&
        (rob_complete[1].rob_id == branch_event_q.rob_id)));
  assign branch_event_fire = branch_event_pending_q &&
                             branch_event_complete_match;
  assign branch_update_valid_o = branch_event_fire;
  assign branch_update_o = branch_event_fire ? branch_event_q.update : '0;

  assign int_push_stage_pop = (int_push_valid_q != 2'b00) &&
                              int_iq_push_ready;
  assign mem_push_stage_pop = (mem_push_valid_q != 2'b00) &&
                              mem_iq_push_ready;
  assign mdu_push_stage_pop = (mdu_push_valid_q != 2'b00) &&
                              mdu_iq_push_ready;
  assign int_push_stage_accept = (int_push_valid_q == 2'b00) ||
                                 int_push_stage_pop;
  assign mem_push_stage_accept = (mem_push_valid_q == 2'b00) ||
                                 mem_push_stage_pop;
  assign mdu_push_stage_accept = (mdu_push_valid_q == 2'b00) ||
                                 mdu_push_stage_pop;
  assign int_push_ready = {2{int_push_stage_accept}};
  assign mem_push_ready = {2{mem_push_stage_accept}};
  assign mdu_push_ready = {2{mdu_push_stage_accept}};
  assign mdu_ex_ready = (mdu_fifo_count_q != 2'd2);
  assign mdu_fifo_fire_in = mdu_ex_valid && mdu_ex_ready && !recovery_o.valid;
  assign mdu_fifo_fire_out = (mdu_fifo_count_q != 2'd0) &&
                             mdu_frontend_ready && !recovery_o.valid;

  // Register the Dispatch Buffer -> IQ push boundary.  The backend LSU OOC
  // critical path was dominated by dispatch payload/classification wires
  // driving IQ enqueue CE fanout.  This one-bundle skid keeps dispatch
  // backpressure precise while making IQ enqueue local to the stage register.
  always_ff @(posedge clk_i) begin
    if (rst_i || recovery_o.valid) begin
      int_push_valid_q <= '0;
      int_push_uop0_q <= '0;
      int_push_uop1_q <= '0;
      mem_push_valid_q <= '0;
      mem_push_uop0_q <= '0;
      mem_push_uop1_q <= '0;
      mdu_push_valid_q <= '0;
      mdu_push_uop0_q <= '0;
      mdu_push_uop1_q <= '0;
    end else begin
      if (int_push_stage_pop)
        int_push_valid_q <= '0;
      if (int_push_stage_accept && (int_push_valid_raw != 2'b00)) begin
        int_push_valid_q <= int_push_valid_raw;
        int_push_uop0_q <= int_push_uop0_raw;
        int_push_uop1_q <= int_push_uop1_raw;
      end

      if (mem_push_stage_pop)
        mem_push_valid_q <= '0;
      if (mem_push_stage_accept && (mem_push_valid_raw != 2'b00)) begin
        mem_push_valid_q <= mem_push_valid_raw;
        mem_push_uop0_q <= mem_push_uop0_raw;
        mem_push_uop1_q <= mem_push_uop1_raw;
      end

      if (mdu_push_stage_pop)
        mdu_push_valid_q <= '0;
      if (mdu_push_stage_accept && (mdu_push_valid_raw != 2'b00)) begin
        mdu_push_valid_q <= mdu_push_valid_raw;
        mdu_push_uop0_q <= mdu_push_uop0_raw;
        mdu_push_uop1_q <= mdu_push_uop1_raw;
      end

      if (checkpoint_clear_valid_o) begin
        int_push_uop0_q.branch_mask[checkpoint_clear_id_o] <= 1'b0;
        int_push_uop1_q.branch_mask[checkpoint_clear_id_o] <= 1'b0;
        mem_push_uop0_q.branch_mask[checkpoint_clear_id_o] <= 1'b0;
        mem_push_uop1_q.branch_mask[checkpoint_clear_id_o] <= 1'b0;
        mdu_push_uop0_q.branch_mask[checkpoint_clear_id_o] <= 1'b0;
        mdu_push_uop1_q.branch_mask[checkpoint_clear_id_o] <= 1'b0;
      end
    end
  end

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

  // Decouple the global issue/operand-read ready path from MUL/DIV subunit
  // ready.  The frontend raw ready depends on recovery, MUL FIFO pressure and
  // DIV busy state; a two-entry local FIFO keeps throughput for back-to-back
  // MULs while preventing that raw ready from feeding Issue Arbiter P2.
  always_ff @(posedge clk_i) begin
    execute_uop_t survivor0;
    execute_uop_t survivor1;
    logic [1:0] survivor_count;
    if (rst_i) begin
      mdu_fifo_count_q <= '0;
      mdu_fifo_uop_q[0] <= '0;
      mdu_fifo_uop_q[1] <= '0;
    end else if (recovery_o.valid) begin
      survivor0 = '0;
      survivor1 = '0;
      survivor_count = '0;

      if (recovery_o.cause != REC_EXCEPT) begin
        if ((mdu_fifo_count_q != 2'd0) &&
            !mdu_fifo_uop_q[0].branch_mask[recovery_o.checkpoint_id]) begin
          survivor0 = mdu_fifo_uop_q[0];
          survivor0.branch_mask = clear_checkpoint(
              mdu_fifo_uop_q[0].branch_mask,
              recovery_o.checkpoint_id);
          survivor_count = 2'd1;
        end

        if ((mdu_fifo_count_q == 2'd2) &&
            !mdu_fifo_uop_q[1].branch_mask[recovery_o.checkpoint_id]) begin
          if (survivor_count == 2'd0) begin
            survivor0 = mdu_fifo_uop_q[1];
            survivor0.branch_mask = clear_checkpoint(
                mdu_fifo_uop_q[1].branch_mask,
                recovery_o.checkpoint_id);
          end else begin
            survivor1 = mdu_fifo_uop_q[1];
            survivor1.branch_mask = clear_checkpoint(
                mdu_fifo_uop_q[1].branch_mask,
                recovery_o.checkpoint_id);
          end
          survivor_count = survivor_count + 2'd1;
        end
      end

      mdu_fifo_count_q <= survivor_count;
      mdu_fifo_uop_q[0] <= survivor0;
      mdu_fifo_uop_q[1] <= survivor1;
    end else begin
      unique case ({mdu_fifo_fire_in, mdu_fifo_fire_out})
        2'b01: begin
          if (mdu_fifo_count_q == 2'd2) begin
            mdu_fifo_count_q <= 2'd1;
            mdu_fifo_uop_q[0] <= mdu_fifo_uop_q[1];
            mdu_fifo_uop_q[1] <= '0;
          end else begin
            mdu_fifo_count_q <= '0;
            mdu_fifo_uop_q[0] <= '0;
            mdu_fifo_uop_q[1] <= '0;
          end
        end

        2'b10: begin
          if (mdu_fifo_count_q == 2'd0) begin
            mdu_fifo_count_q <= 2'd1;
            mdu_fifo_uop_q[0] <= mdu_ex_uop;
          end else begin
            mdu_fifo_count_q <= 2'd2;
            mdu_fifo_uop_q[1] <= mdu_ex_uop;
          end
        end

        2'b11: begin
          if (mdu_fifo_count_q == 2'd1) begin
            mdu_fifo_count_q <= 2'd1;
            mdu_fifo_uop_q[0] <= mdu_ex_uop;
            mdu_fifo_uop_q[1] <= '0;
          end else begin
            mdu_fifo_count_q <= 2'd2;
            mdu_fifo_uop_q[0] <= mdu_fifo_uop_q[1];
            mdu_fifo_uop_q[1] <= mdu_ex_uop;
          end
        end

        default: begin
          mdu_fifo_count_q <= mdu_fifo_count_q;
        end
      endcase

      if (checkpoint_clear_valid_o) begin
        if (mdu_fifo_count_q != 2'd0)
          mdu_fifo_uop_q[0].branch_mask[checkpoint_clear_id_o] <= 1'b0;
        if (mdu_fifo_count_q == 2'd2)
          mdu_fifo_uop_q[1].branch_mask[checkpoint_clear_id_o] <= 1'b0;
      end
    end
  end

  function automatic logic is_load_renamed(input renamed_uop_t uop);
    is_load_renamed = (uop.dec.fu_type == FU_LSU) &&
                      (uop.dec.mem_op <= MEM_LHU);
  endfunction

  function automatic logic is_store_renamed(input renamed_uop_t uop);
    is_store_renamed = (uop.dec.fu_type == FU_LSU) &&
                       (uop.dec.mem_op >= MEM_SB);
  endfunction

  function automatic logic rob_id_is_older(
      input logic [ROB_ID_W-1:0] candidate,
      input logic [ROB_ID_W-1:0] reference
  );
    logic [ROB_ID_W-1:0] distance;
    begin
      distance = reference - candidate;
      rob_id_is_older = (distance != '0) && !distance[ROB_ID_W-1];
    end
  endfunction

  function automatic logic load_waits_for_older_store(input issue_uop_t uop);
    integer sq_idx;
    begin
      load_waits_for_older_store = 1'b0;
      if (uop.is_load) begin
        for (sq_idx = 0; sq_idx < SQ_ENTRIES; sq_idx = sq_idx + 1) begin
          if (sq_entries[sq_idx].valid &&
              rob_id_is_older(sq_entries[sq_idx].rob_id, uop.rob_id) &&
              !sq_entries[sq_idx].address_valid)
            load_waits_for_older_store = 1'b1;
        end
      end
    end
  endfunction

  always_comb begin
    mem_issue_allowed = 2'b11;
    if (mem_candidate_valid[0] &&
        load_waits_for_older_store(mem_candidate_uop0))
      mem_issue_allowed[0] = 1'b0;
    if (mem_candidate_valid[1] &&
        load_waits_for_older_store(mem_candidate_uop1))
      mem_issue_allowed[1] = 1'b0;
  end

  always_comb begin
    lq_alloc_valid = '0;
    lq_alloc_id = '0;
    lq_alloc_rob_id = '0;
    lq_alloc_prd = '0;
    lq_alloc_mem_op[0] = MEM_LB;
    lq_alloc_mem_op[1] = MEM_LB;
    lq_alloc_branch_mask = '0;
    sq_alloc_valid = '0;
    sq_alloc_id = '0;
    sq_alloc_rob_id = '0;
    sq_alloc_branch_mask = '0;

    if (dispatch_fire && dispatch_valid[0]) begin
      if (is_load_renamed(dispatch_uop0)) begin
        lq_alloc_valid[0] = 1'b1;
        lq_alloc_id[0] = dispatch_uop0.lq_id;
        lq_alloc_rob_id[0] = dispatch_uop0.rob_id;
        lq_alloc_prd[0] = dispatch_uop0.prd;
        lq_alloc_mem_op[0] = dispatch_uop0.dec.mem_op;
        lq_alloc_branch_mask[0] = dispatch_uop0.branch_mask;
      end
      if (is_store_renamed(dispatch_uop0)) begin
        sq_alloc_valid[0] = 1'b1;
        sq_alloc_id[0] = dispatch_uop0.sq_id;
        sq_alloc_rob_id[0] = dispatch_uop0.rob_id;
        sq_alloc_branch_mask[0] = dispatch_uop0.branch_mask;
      end
    end

    if (dispatch_fire && dispatch_valid[1]) begin
      if (is_load_renamed(dispatch_uop1)) begin
        lq_alloc_valid[1] = 1'b1;
        lq_alloc_id[1] = dispatch_uop1.lq_id;
        lq_alloc_rob_id[1] = dispatch_uop1.rob_id;
        lq_alloc_prd[1] = dispatch_uop1.prd;
        lq_alloc_mem_op[1] = dispatch_uop1.dec.mem_op;
        lq_alloc_branch_mask[1] = dispatch_uop1.branch_mask;
      end
      if (is_store_renamed(dispatch_uop1)) begin
        sq_alloc_valid[1] = 1'b1;
        sq_alloc_id[1] = dispatch_uop1.sq_id;
        sq_alloc_rob_id[1] = dispatch_uop1.rob_id;
        sq_alloc_branch_mask[1] = dispatch_uop1.branch_mask;
      end
    end
  end

  commit_recovery_cluster #(
      .HART_ID(HART_ID),
      .RESET_MTVEC(RESET_MTVEC)
  ) u_commit_recovery (
      .clk_i,
      .rst_i,
      .dec_valid_i,
      .dec_ready_o,
      .dec_uop0_i,
      .dec_uop1_i,
      .dispatch_valid_o(dispatch_valid),
      .dispatch_ready_i(dispatch_ready),
      .dispatch_uop0_o(dispatch_uop0),
      .dispatch_uop1_o(dispatch_uop1),
      .dispatch_fire_o(dispatch_fire),
      .complete0_i(rob_complete[0]),
      .complete1_i(rob_complete[1]),
      .lq_release_valid_i(lq_release_valid),
      .lq_release_id_i(lq_release_id),
      .sq_release_valid_i({1'b0, sq_release_valid}),
      .sq_release_id_i({{SQ_ID_W{1'b0}}, sq_release_id}),
      .branch_i(branch_event_to_commit_q),
      .recovery_o,
      .checkpoint_clear_valid_o,
      .checkpoint_clear_id_o,
      .redirect_valid_o,
      .redirect_pc_o,
      .prf_read_valid_i(prf_read_valid),
      .prf_read_prd_i(prf_read_prd),
      .prf_read_data_o(prf_read_data),
      .wb_valid_i(prf_write_valid),
      .wb_prd_i(prf_write_prd),
      .wb_data_i(prf_write_data),
      .prf_ready_bits_o,
      .wakeup_valid_o(ready_wakeup_valid),
      .wakeup_prd_o(ready_wakeup_prd),
      .store_commit_valid_o(sq_commit_valid),
      .store_commit_sq_id_o(sq_commit_id),
      .store_commit_ready_i(sq_commit_ready),
      .store_commit_done_i(sq_commit_done),
      .lq_retire_valid_o(lq_retire_valid),
      .lq_retire_id_o(lq_retire_id),
      .retire_count_o,
      .rob_occupancy_o,
      .rob_empty_o,
      .rob_full_o,
      .free_prd_count_o,
      .free_lq_count_o,
      .free_sq_count_o,
      .active_checkpoint_count_o,
      .recovery_busy_o,
      .busy_o(commit_busy),
      .mstatus_o,
      .mtvec_o,
      .mepc_o,
      .mcause_o,
      .mtval_o
  );

  dispatch_buffer u_dispatch_buffer (
      .clk_i,
      .rst_i,
      .rn_valid_i(dispatch_valid),
      .rn_ready_o(dispatch_ready),
      .rn_uop0_i(dispatch_uop0),
      .rn_uop1_i(dispatch_uop1),
      .int_push_valid_o(int_push_valid_raw),
      .int_push_ready_i(int_push_ready),
      .int_push_uop0_o(int_push_uop0_raw),
      .int_push_uop1_o(int_push_uop1_raw),
      .mem_push_valid_o(mem_push_valid_raw),
      .mem_push_ready_i(mem_push_ready),
      .mem_push_uop0_o(mem_push_uop0_raw),
      .mem_push_uop1_o(mem_push_uop1_raw),
      .mdu_push_valid_o(mdu_push_valid_raw),
      .mdu_push_ready_i(mdu_push_ready),
      .mdu_push_uop0_o(mdu_push_uop0_raw),
      .mdu_push_uop1_o(mdu_push_uop1_raw),
      .wb_valid_i(ready_wakeup_valid),
      .wb_prd_i(ready_wakeup_prd),
      .checkpoint_clear_i(checkpoint_clear_valid_o),
      .checkpoint_clear_id_i(checkpoint_clear_id_o),
      .recovery_i(recovery_o),
      .empty_o(db_empty),
      .full_o(db_full),
      .occupancy_o(db_occupancy)
  );

  issue_queue #(
      .ENTRIES(IQ_INT_ENTRIES),
      .GROUPS(3)
  ) u_int_issue_queue (
      .clk_i,
      .rst_i,
      .push_valid_i(int_push_valid_q),
      .push_ready_o(int_iq_push_ready),
      .push_uop0_i(int_push_uop0_q),
      .push_uop1_i(int_push_uop1_q),
      .wb_valid_i(ready_wakeup_valid),
      .wb_prd_i(ready_wakeup_prd),
      .prf_ready_bits_i(prf_ready_bits_o),
      .candidate_valid_o(int_candidate_valid),
      .candidate_uop0_o(int_candidate_uop0),
      .candidate_uop1_o(int_candidate_uop1),
      .candidate_uop2_o(int_candidate_uop2),
      .candidate_slot0_o(unused_int_slot0),
      .candidate_slot1_o(unused_int_slot1),
      .candidate_slot2_o(unused_int_slot2),
      .issue_grant_i(int_issue_grant),
      .candidate_reselect_i(3'b000),
      .checkpoint_clear_i(checkpoint_clear_valid_o),
      .checkpoint_clear_id_i(checkpoint_clear_id_o),
      .recovery_i(recovery_o),
      .empty_o(int_iq_empty),
      .full_o(int_iq_full),
      .occupancy_o(int_iq_occupancy)
  );

  issue_queue #(
      .ENTRIES(IQ_MEM_ENTRIES),
      .GROUPS(2)
  ) u_mem_issue_queue (
      .clk_i,
      .rst_i,
      .push_valid_i(mem_push_valid_q),
      .push_ready_o(mem_iq_push_ready),
      .push_uop0_i(mem_push_uop0_q),
      .push_uop1_i(mem_push_uop1_q),
      .wb_valid_i(ready_wakeup_valid),
      .wb_prd_i(ready_wakeup_prd),
      .prf_ready_bits_i(prf_ready_bits_o),
      .candidate_valid_o(mem_candidate_valid),
      .candidate_uop0_o(mem_candidate_uop0),
      .candidate_uop1_o(mem_candidate_uop1),
      .candidate_uop2_o(),
      .candidate_slot0_o(unused_mem_slot0),
      .candidate_slot1_o(unused_mem_slot1),
      .candidate_slot2_o(),
      .issue_grant_i(mem_issue_grant),
      .candidate_reselect_i(mem_candidate_valid & ~mem_issue_allowed),
      .checkpoint_clear_i(checkpoint_clear_valid_o),
      .checkpoint_clear_id_i(checkpoint_clear_id_o),
      .recovery_i(recovery_o),
      .empty_o(mem_iq_empty),
      .full_o(mem_iq_full),
      .occupancy_o(mem_iq_occupancy)
  );

  issue_queue #(
      .ENTRIES(IQ_MDU_ENTRIES),
      .GROUPS(1)
  ) u_mdu_issue_queue (
      .clk_i,
      .rst_i,
      .push_valid_i(mdu_push_valid_q),
      .push_ready_o(mdu_iq_push_ready),
      .push_uop0_i(mdu_push_uop0_q),
      .push_uop1_i(mdu_push_uop1_q),
      .wb_valid_i(ready_wakeup_valid),
      .wb_prd_i(ready_wakeup_prd),
      .prf_ready_bits_i(prf_ready_bits_o),
      .candidate_valid_o(mdu_candidate_valid),
      .candidate_uop0_o(mdu_candidate_uop),
      .candidate_uop1_o(),
      .candidate_uop2_o(),
      .candidate_slot0_o(unused_mdu_slot0),
      .candidate_slot1_o(),
      .candidate_slot2_o(),
      .issue_grant_i(mdu_issue_grant),
      .candidate_reselect_i(1'b0),
      .checkpoint_clear_i(checkpoint_clear_valid_o),
      .checkpoint_clear_id_i(checkpoint_clear_id_o),
      .recovery_i(recovery_o),
      .empty_o(mdu_iq_empty),
      .full_o(mdu_iq_full),
      .occupancy_o(mdu_iq_occupancy)
  );

  issue_arbiter u_issue_arbiter (
      .clk_i,
      .rst_i,
      .int_candidate_valid_i(int_candidate_valid),
      .int_candidate_uop0_i(int_candidate_uop0),
      .int_candidate_uop1_i(int_candidate_uop1),
      .int_candidate_uop2_i(int_candidate_uop2),
      .mem_candidate_valid_i(mem_candidate_valid),
      .mem_candidate_uop0_i(mem_candidate_uop0),
      .mem_candidate_uop1_i(mem_candidate_uop1),
      .mem_issue_allowed_i(mem_issue_allowed),
      .mdu_candidate_valid_i(mdu_candidate_valid),
      .mdu_candidate_uop_i(mdu_candidate_uop),
      .mdu_accept_i(1'b1),
      .int0_ready_i(int0_issue_ready),
      .int1_ready_i(int1_issue_ready),
      .lsu_ready_i(lsu_issue_ready),
      .mdu_ready_i(mdu_issue_ready),
      .recovery_i(recovery_o),
      .int_issue_grant_o(int_issue_grant),
      .mem_issue_grant_o(mem_issue_grant),
      .mdu_issue_grant_o(mdu_issue_grant),
      .issue_valid_o(issue_valid),
      .issue_port0_o(issue_port0),
      .issue_port1_o(issue_port1),
      .issue_port2_o(issue_port2),
      .issue_uop0_o(issue_uop0),
      .issue_uop1_o(issue_uop1),
      .issue_uop2_o(issue_uop2)
  );

  operand_read_stage u_operand_read (
      .clk_i,
      .rst_i,
      .issue_valid_i(issue_valid),
      .issue_port0_i(issue_port0),
      .issue_port1_i(issue_port1),
      .issue_port2_i(issue_port2),
      .issue_uop0_i(issue_uop0),
      .issue_uop1_i(issue_uop1),
      .issue_uop2_i(issue_uop2),
      .prf_read_valid_o(prf_read_valid),
      .prf_read_prd_o(prf_read_prd),
      .prf_read_data_i(prf_read_data),
      .wb_valid_i(prf_write_valid),
      .wb_prd_i(prf_write_prd),
      .wb_data_i(prf_write_data),
      .int0_issue_ready_o(int0_issue_ready),
      .int1_issue_ready_o(int1_issue_ready),
      .lsu_issue_ready_o(lsu_issue_ready),
      .mdu_issue_ready_o(mdu_issue_ready),
      .int0_valid_o(int0_ex_valid),
      .int0_ready_i(int0_ex_ready),
      .int0_uop_o(int0_ex_uop),
      .int1_valid_o(int1_ex_valid),
      .int1_ready_i(int1_ex_ready),
      .int1_uop_o(int1_ex_uop),
      .lsu_valid_o(lsu_ex_valid),
      .lsu_ready_i(lsu_ex_ready),
      .lsu_uop_o(lsu_ex_uop),
      .mdu_valid_o(mdu_ex_valid),
      .mdu_ready_i(mdu_ex_ready),
      .mdu_uop_o(mdu_ex_uop),
      .checkpoint_clear_i(checkpoint_clear_valid_o),
      .checkpoint_clear_id_i(checkpoint_clear_id_o),
      .recovery_i(recovery_o)
  );

  int_pipeline0 u_int0 (
      .clk_i,
      .rst_i,
      .ex_valid_i(int0_ex_valid),
      .ex_ready_o(int0_ex_ready),
      .ex_uop_i(int0_ex_uop),
      .result_valid_o(int0_result_valid),
      .result_ready_i(int0_result_ready),
      .result_o(int0_result),
      .checkpoint_clear_i(checkpoint_clear_valid_o),
      .checkpoint_clear_id_i(checkpoint_clear_id_o),
      .recovery_i(recovery_o)
  );

  int_branch_pipeline1 u_int1 (
      .clk_i,
      .rst_i,
      .ex_valid_i(int1_ex_valid),
      .ex_ready_o(int1_ex_ready),
      .ex_uop_i(int1_ex_uop),
      .result_valid_o(int1_result_valid),
      .result_ready_i(int1_result_ready),
      .result_o(int1_result),
      .branch_event_o(branch_event_raw),
      .checkpoint_clear_i(checkpoint_clear_valid_o),
      .checkpoint_clear_id_i(checkpoint_clear_id_o),
      .recovery_i(recovery_o)
  );

  lsu_pipeline u_lsu (
      .clk_i,
      .rst_i,
      .issue_valid_i(lsu_ex_valid),
      .issue_ready_o(lsu_ex_ready),
      .issue_uop_i(lsu_ex_uop),
      .sq_entries_i(sq_entries),
      .lq_address_valid_o(lq_address_valid),
      .lq_address_ready_i(lq_address_ready),
      .lq_address_id_o(lq_address_id),
      .lq_address_o(lq_address),
      .lq_address_exception_valid_o(lq_address_exception_valid),
      .lq_address_exception_cause_o(lq_address_exception_cause),
      .lq_address_exception_tval_o(lq_address_exception_tval),
      .lq_complete_valid_o(lq_complete_valid),
      .lq_complete_id_o(lq_complete_id),
      .lq_complete_forwarded_o(lq_complete_forwarded),
      .sq_update_valid_o(sq_update_valid),
      .sq_update_ready_i(sq_update_ready),
      .sq_update_id_o(sq_update_id),
      .sq_update_address_o(sq_update_address),
      .sq_update_data_o(sq_update_data),
      .sq_update_byte_enable_o(sq_update_byte_enable),
      .sq_update_exception_valid_o(sq_update_exception_valid),
      .sq_update_exception_cause_o(sq_update_exception_cause),
      .sq_update_exception_tval_o(sq_update_exception_tval),
      .mem_req_o(load_mem_req_o),
      .mem_req_ready_i(load_mem_req_ready_i),
      .mem_resp_i(load_mem_resp_i),
      .mem_resp_ready_o(load_mem_resp_ready_o),
      .result_valid_o(lsu_result_valid),
      .result_ready_i(lsu_result_ready),
      .result_o(lsu_result),
      .recovery_i(recovery_o)
  );

  muldiv_frontend u_muldiv (
      .clk_i,
      .rst_i,
      .mdu_valid_i(mdu_fifo_count_q != 2'd0),
      .mdu_ready_o(mdu_frontend_ready),
      .mdu_uop_i(mdu_fifo_uop_q[0]),
      .mul_valid_o(mul_result_valid),
      .mul_ready_i(mul_result_ready),
      .mul_o(mul_result),
      .div_valid_o(div_result_valid),
      .div_ready_i(div_result_ready),
      .div_o(div_result),
      .recovery_i(recovery_o)
  );

  load_queue u_load_queue (
      .clk_i,
      .rst_i,
      .alloc_valid_i(lq_alloc_valid),
      .alloc_lq_id_i(lq_alloc_id),
      .alloc_rob_id_i(lq_alloc_rob_id),
      .alloc_prd_i(lq_alloc_prd),
      .alloc_mem_op_i(lq_alloc_mem_op),
      .alloc_branch_mask_i(lq_alloc_branch_mask),
      .address_valid_i(lq_address_valid),
      .address_ready_o(lq_address_ready),
      .address_lq_id_i(lq_address_id),
      .address_i(lq_address),
      .address_exception_valid_i(lq_address_exception_valid),
      .address_exception_cause_i(lq_address_exception_cause),
      .address_exception_tval_i(lq_address_exception_tval),
      .complete_valid_i(lq_complete_valid),
      .complete_ready_o(lq_complete_ready),
      .complete_lq_id_i(lq_complete_id),
      .complete_forwarded_i(lq_complete_forwarded),
      .retire_valid_i(lq_retire_valid),
      .retire_lq_id_i(lq_retire_id),
      .lq_release_valid_o(lq_release_valid),
      .lq_release_id_o(lq_release_id),
      .checkpoint_clear_i(checkpoint_clear_valid_o),
      .checkpoint_clear_id_i(checkpoint_clear_id_o),
      .recovery_i(recovery_o),
      .entries_o(lq_entries),
      .occupancy_o(lq_occupancy_o)
  );

  store_queue u_store_queue (
      .clk_i,
      .rst_i,
      .alloc_valid_i(sq_alloc_valid),
      .alloc_sq_id_i(sq_alloc_id),
      .alloc_rob_id_i(sq_alloc_rob_id),
      .alloc_branch_mask_i(sq_alloc_branch_mask),
      .execute_valid_i(sq_update_valid),
      .execute_ready_o(sq_update_ready),
      .execute_sq_id_i(sq_update_id),
      .execute_address_i(sq_update_address),
      .execute_data_i(sq_update_data),
      .execute_byte_enable_i(sq_update_byte_enable),
      .execute_exception_valid_i(sq_update_exception_valid),
      .execute_exception_cause_i(sq_update_exception_cause),
      .execute_exception_tval_i(sq_update_exception_tval),
      .commit_valid_i(sq_commit_valid),
      .commit_sq_id_i(sq_commit_id),
      .commit_ready_o(sq_commit_ready),
      .commit_done_o(sq_commit_done),
      .mem_req_o(store_mem_req_o),
      .mem_req_ready_i(store_mem_req_ready_i),
      .sq_release_valid_o(sq_release_valid),
      .sq_release_id_o(sq_release_id),
      .checkpoint_clear_i(checkpoint_clear_valid_o),
      .checkpoint_clear_id_i(checkpoint_clear_id_o),
      .recovery_i(recovery_o),
      .entries_o(sq_entries),
      .occupancy_o(sq_occupancy_o)
  );

  writeback_arbiter u_writeback (
      .clk_i,
      .rst_i,
      .int0_valid_i(int0_result_valid),
      .int0_ready_o(int0_result_ready),
      .int0_i(int0_result),
      .int1_valid_i(int1_result_valid),
      .int1_ready_o(int1_result_ready),
      .int1_i(int1_result),
      .lsu_valid_i(lsu_result_valid),
      .lsu_ready_o(lsu_result_ready),
      .lsu_i(lsu_result),
      .mul_valid_i(mul_result_valid),
      .mul_ready_o(mul_result_ready),
      .mul_i(mul_result),
      .div_valid_i(div_result_valid),
      .div_ready_o(div_result_ready),
      .div_i(div_result),
      .recovery_i(recovery_o),
      .wb_valid_o(wb_valid),
      .wb_o(wb_completion),
      .prf_write_valid_o(prf_write_valid),
      .prf_write_prd_o(prf_write_prd),
      .prf_write_data_o(prf_write_data),
      .rob_complete_valid_o(rob_complete_valid),
      .rob_complete_o(rob_complete),
      .wakeup_valid_o(wakeup_valid),
      .wakeup_prd_o(wakeup_prd)
  );

  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      branch_event_pending_q <= 1'b0;
      branch_event_q <= '0;
      branch_event_to_commit_q <= '0;
    end else if (recovery_o.valid) begin
      branch_event_pending_q <= 1'b0;
      branch_event_q <= '0;
      branch_event_to_commit_q <= '0;
    end else begin
      branch_event_to_commit_q <= '0;
      if (branch_event_fire)
        branch_event_to_commit_q <= branch_event_q;

      unique case ({branch_event_fire, branch_event_raw.valid})
        2'b00: begin
        end
        2'b01,
        2'b11: begin
          branch_event_pending_q <= 1'b1;
          branch_event_q <= branch_event_raw;
        end
        default: begin
          branch_event_pending_q <= 1'b0;
          branch_event_q <= '0;
        end
      endcase
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk_i) begin
    if (!rst_i) begin
      assert (rob_complete_valid == wb_valid)
        else $error("writeback valid and ROB completion valid diverged");
      if (branch_event_raw.valid)
        assert (!branch_event_pending_q || branch_event_fire)
          else $error("backend_mdu_cluster branch resolve queue overflow");
    end
  end
`endif

endmodule
