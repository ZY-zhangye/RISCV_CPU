import core_types_pkg::*;

// Frontend + backend integration boundary.
// Opens Fetch, Branch Predictor, Instruction Buffer and Decode in front of the
// frozen backend_mdu_cluster.  IROM and data memory remain external so OOC tests
// can model realistic memory timing without pulling in platform RAM wrappers.
module frontend_backend_cluster #(
    parameter logic [XLEN-1:0] HART_ID = '0,
    parameter logic [XLEN-1:0] RESET_MTVEC = RESET_PC
) (
    input  logic                         clk_i,
    input  logic                         rst_i,

    output logic                         imem_req_valid_o,
    output logic [31:0]                  imem_req_addr_o,
    input  logic                         imem_resp_valid_i,
    input  logic [127:0]                 imem_resp_data_i,

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
    output logic [3:0]                   ibuf_occupancy_o,
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

  logic fetch_valid;
  logic fetch_ready;
  fetch_packet_t fetch_packet;
  bp_query_t bp_query;
  bp_pred_t bp_prediction;
  logic bp_query_valid;
  logic branch_update_valid;
  branch_update_t branch_update;
  logic frontend_flush;

  logic [1:0] ibuf_decode_valid;
  logic ibuf_decode_ready;
  fetch_slot_t decode_slot0;
  fetch_slot_t decode_slot1;

  logic [1:0] dec_valid;
  logic dec_ready;
  decoded_uop_t dec_uop0;
  decoded_uop_t dec_uop1;

  assign frontend_flush = recovery_busy_o || redirect_valid_o;

  fetch_pipeline u_fetch (
      .clk_i,
      .rst_i,
      .redirect_valid_i(redirect_valid_o),
      .redirect_target_i(redirect_pc_o),
      .ibuf_ready_i(fetch_ready),
      .fetch_valid_o(fetch_valid),
      .fetch_packet_o(fetch_packet),
      .bp_query_valid_o(bp_query_valid),
      .bp_query_o(bp_query),
      .bp_result_i(bp_prediction),
      .imem_req_valid_o,
      .imem_req_addr_o,
      .imem_resp_valid_i,
      .imem_resp_data_i
  );

  branch_predictor u_branch_predictor (
      .clk_i,
      .rst_i,
      .query_valid_i(bp_query_valid),
      .query_i(bp_query),
      .pred_o(bp_prediction),
      .update_valid_i(branch_update_valid),
      .update_i(branch_update)
  );

  instruction_buffer u_ibuf (
      .clk_i,
      .rst_i,
      .fetch_valid_i(fetch_valid),
      .fetch_ready_o(fetch_ready),
      .fetch_packet_i(fetch_packet),
      .decode_valid_o(ibuf_decode_valid),
      .decode_ready_i(ibuf_decode_ready),
      .decode_slot0_o(decode_slot0),
      .decode_slot1_o(decode_slot1),
      .flush_i(frontend_flush),
      .occupancy_o(ibuf_occupancy_o)
  );

  decode_stage u_decode (
      .clk_i,
      .rst_i,
      .in_valid_i(ibuf_decode_valid),
      .in_ready_o(ibuf_decode_ready),
      .fetch_slot0_i(decode_slot0),
      .fetch_slot1_i(decode_slot1),
      .out_valid_o(dec_valid),
      .out_ready_i(dec_ready),
      .decoded_uop0_o(dec_uop0),
      .decoded_uop1_o(dec_uop1),
      .flush_i(frontend_flush)
  );

  backend_mdu_cluster #(
      .HART_ID(HART_ID),
      .RESET_MTVEC(RESET_MTVEC)
  ) u_backend (
      .clk_i,
      .rst_i,
      .dec_valid_i(dec_valid),
      .dec_ready_o(dec_ready),
      .dec_uop0_i(dec_uop0),
      .dec_uop1_i(dec_uop1),
      .load_mem_req_o,
      .load_mem_req_ready_i,
      .load_mem_resp_i,
      .load_mem_resp_ready_o,
      .store_mem_req_o,
      .store_mem_req_ready_i,
      .recovery_o,
      .checkpoint_clear_valid_o,
      .checkpoint_clear_id_o,
      .redirect_valid_o,
      .redirect_pc_o,
      .branch_update_valid_o(branch_update_valid),
      .branch_update_o(branch_update),
      .retire_count_o,
      .rob_occupancy_o,
      .rob_empty_o,
      .rob_full_o,
      .free_prd_count_o,
      .free_lq_count_o,
      .free_sq_count_o,
      .active_checkpoint_count_o,
      .recovery_busy_o,
      .busy_o,
      .dispatch_buffer_occupancy_o,
      .int_issue_occupancy_o,
      .mem_issue_occupancy_o,
      .mdu_issue_occupancy_o,
      .lq_occupancy_o,
      .sq_occupancy_o,
      .prf_ready_bits_o,
      .mstatus_o,
      .mtvec_o,
      .mepc_o,
      .mcause_o,
      .mtval_o
  );

`ifndef SYNTHESIS
  always_ff @(posedge clk_i) begin
    if (!rst_i) begin
      if (redirect_valid_o)
        assert (redirect_pc_o[1:0] == 2'b00)
          else $error("frontend_backend_cluster saw misaligned redirect");
    end
  end
`endif

endmodule
