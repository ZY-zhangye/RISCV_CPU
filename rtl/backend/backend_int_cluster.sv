`timescale 1ns/1ps

import core_types_pkg::*;

// First backend integration boundary for the integer/branch/CSR loop.
// LSU and MDU dispatch paths are intentionally backpressured in this stage;
// they will be opened by later integration clusters.
module backend_int_cluster #(
    parameter logic [XLEN-1:0] HART_ID = '0,
    parameter logic [XLEN-1:0] RESET_MTVEC = RESET_PC
) (
    input  logic                         clk_i,
    input  logic                         rst_i,

    input  logic [1:0]                   dec_valid_i,
    output logic                         dec_ready_o,
    input  decoded_uop_t                 dec_uop0_i,
    input  decoded_uop_t                 dec_uop1_i,

    output recovery_t                    recovery_o,
    output logic                         checkpoint_clear_valid_o,
    output logic [CP_W-1:0]              checkpoint_clear_id_o,
    output logic                         redirect_valid_o,
    output logic [XLEN-1:0]              redirect_pc_o,

    output logic                         store_commit_valid_o,
    output logic [SQ_ID_W-1:0]           store_commit_sq_id_o,
    input  logic                         store_commit_ready_i,
    input  logic                         store_commit_done_i,

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

  logic [1:0] int_push_valid;
  logic [1:0] int_push_ready;
  issue_uop_t int_push_uop0;
  issue_uop_t int_push_uop1;
  logic int_iq_push_ready;
  logic int_iq_empty;
  logic int_iq_full;
  logic [$clog2(IQ_INT_ENTRIES+1)-1:0] int_iq_occupancy;

  logic [2:0] int_candidate_valid;
  issue_uop_t int_candidate_uop0;
  issue_uop_t int_candidate_uop1;
  issue_uop_t int_candidate_uop2;
  logic [$clog2(IQ_INT_ENTRIES)-1:0] unused_int_slot0;
  logic [$clog2(IQ_INT_ENTRIES)-1:0] unused_int_slot1;
  logic [$clog2(IQ_INT_ENTRIES)-1:0] unused_int_slot2;
  logic [2:0] int_issue_grant;

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
  logic int0_ex_valid;
  logic int0_ex_ready;
  execute_uop_t int0_ex_uop;
  logic int1_ex_valid;
  logic int1_ex_ready;
  execute_uop_t int1_ex_uop;

  logic int0_result_valid;
  logic int0_result_ready;
  completion_t int0_result;
  logic int1_result_valid;
  logic int1_result_ready;
  completion_t int1_result;
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

  assign dispatch_buffer_occupancy_o = db_occupancy;
  assign int_issue_occupancy_o = int_iq_occupancy;

  assign branch_event_complete_match =
      ((rob_complete[0].valid &&
        (rob_complete[0].rob_id == branch_event_q.rob_id)) ||
       (rob_complete[1].valid &&
        (rob_complete[1].rob_id == branch_event_q.rob_id)));
  assign branch_event_fire = branch_event_pending_q &&
                             branch_event_complete_match;

  // Dispatch Buffer expects independent first/second-slot capacity. Derive it
  // from registered IQ occupancy to avoid a push_valid -> push_ready loop.
  assign int_push_ready[0] = !int_iq_full &&
      (int_iq_occupancy < IQ_INT_ENTRIES[$bits(int_iq_occupancy)-1:0]);
  assign int_push_ready[1] =
      (int_iq_occupancy <= (IQ_INT_ENTRIES - 2));

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
      .dispatch_alloc_valid_o(),
      .dispatch_alloc_uop0_o(),
      .dispatch_alloc_uop1_o(),
      .dispatch_alloc_fire_o(),
      .complete0_i(rob_complete[0]),
      .complete1_i(rob_complete[1]),
      .lq_release_valid_i(2'b00),
      .lq_release_id_i('0),
      .sq_release_valid_i(2'b00),
      .sq_release_id_i('0),
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
      .store_commit_valid_o,
      .store_commit_sq_id_o,
      .store_commit_ready_i,
      .store_commit_done_i,
      .lq_retire_valid_o(),
      .lq_retire_id_o(),
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
      .int_push_valid_o(int_push_valid),
      .int_push_ready_i(int_push_ready),
      .int_push_uop0_o(int_push_uop0),
      .int_push_uop1_o(int_push_uop1),
      .mem_push_valid_o(),
      .mem_push_ready_i(2'b00),
      .mem_push_uop0_o(),
      .mem_push_uop1_o(),
      .mdu_push_valid_o(),
      .mdu_push_ready_i(2'b00),
      .mdu_push_uop0_o(),
      .mdu_push_uop1_o(),
      .wb_valid_i(wakeup_valid),
      .wb_prd_i(wakeup_prd),
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
      .push_valid_i(int_push_valid),
      .push_ready_o(int_iq_push_ready),
      .push_uop0_i(int_push_uop0),
      .push_uop1_i(int_push_uop1),
      .wb_valid_i(wakeup_valid),
      .wb_prd_i(wakeup_prd),
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

  issue_arbiter u_issue_arbiter (
      .clk_i,
      .rst_i,
      .int_candidate_valid_i(int_candidate_valid),
      .int_candidate_uop0_i(int_candidate_uop0),
      .int_candidate_uop1_i(int_candidate_uop1),
      .int_candidate_uop2_i(int_candidate_uop2),
      .mem_candidate_valid_i(2'b00),
      .mem_candidate_uop0_i('0),
      .mem_candidate_uop1_i('0),
      .mem_issue_allowed_i(2'b00),
      .mdu_candidate_valid_i(1'b0),
      .mdu_candidate_uop_i('0),
      .mdu_accept_i(1'b0),
      .int0_ready_i(int0_issue_ready),
      .int1_ready_i(int1_issue_ready),
      .lsu_ready_i(1'b0),
      .mdu_ready_i(1'b0),
      .issue_block_i(branch_event_to_commit_q.valid &&
                     branch_event_to_commit_q.mispredict),
      .recovery_i(recovery_o),
      .int_issue_grant_o(int_issue_grant),
      .mem_issue_grant_o(),
      .mdu_issue_grant_o(),
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
      .lsu_issue_ready_o(),
      .mdu_issue_ready_o(),
      .int0_valid_o(int0_ex_valid),
      .int0_ready_i(int0_ex_ready),
      .int0_uop_o(int0_ex_uop),
      .int1_valid_o(int1_ex_valid),
      .int1_ready_i(int1_ex_ready),
      .int1_uop_o(int1_ex_uop),
      .lsu_valid_o(),
      .lsu_ready_i(1'b0),
      .lsu_uop_o(),
      .mdu_valid_o(),
      .mdu_ready_i(1'b0),
      .mdu_uop_o(),
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

  writeback_arbiter u_writeback (
      .clk_i,
      .rst_i,
      .int0_valid_i(int0_result_valid),
      .int0_ready_o(int0_result_ready),
      .int0_i(int0_result),
      .int1_valid_i(int1_result_valid),
      .int1_ready_o(int1_result_ready),
      .int1_i(int1_result),
      .lsu_valid_i(1'b0),
      .lsu_ready_o(),
      .lsu_i('0),
      .mul_valid_i(1'b0),
      .mul_ready_o(),
      .mul_i('0),
      .div_valid_i(1'b0),
      .div_ready_o(),
      .div_i('0),
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

  // The branch pipe resolves before the timing-pipelined writeback arbiter has
  // marked the branch complete in the ROB. Hold the resolve event until the
  // matching ROB completion is visible, then emit it one cycle later so the ROB
  // samples the completion before checkpoint clear/recovery can start scanning.
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
          // Hold pending event.
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
      assert (!int_push_valid[0] || int_iq_push_ready)
        else $error("backend_int_cluster pushed INT IQ while not ready");
      assert (rob_complete_valid == wb_valid)
        else $error("writeback valid and ROB completion valid diverged");
      if (branch_event_raw.valid)
        assert (!branch_event_pending_q || branch_event_fire)
          else $error("backend_int_cluster branch resolve queue overflow");
    end
  end
`endif

endmodule
