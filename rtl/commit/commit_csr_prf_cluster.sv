`timescale 1ns/1ps

import core_types_pkg::*;

// Commit/CSR plus physical-register-file integration boundary. CSR results are
// written only when the PRF commit port accepts them; ordinary WB owns the PRF
// write Banks while active and therefore backpressures CSR retirement.
module commit_csr_prf_cluster #(
    parameter logic [XLEN-1:0] HART_ID = '0,
    parameter logic [XLEN-1:0] RESET_MTVEC = RESET_PC
) (
    input  logic                         clk_i,
    input  logic                         rst_i,

    input  logic [1:0]                   rob_head_valid_i,
    input  rob_entry_t                   rob_head0_i,
    input  rob_entry_t                   rob_head1_i,
    output logic [1:0]                   retire_count_o,
    output commit_map_t                  commit_map0_o,
    output commit_map_t                  commit_map1_o,
    output logic [1:0]                   reclaim_valid_o,
    output logic [1:0][PRD_W-1:0]        reclaim_prd_o,
    input  logic                         reclaim_ready_i,

    output logic                         store_commit_valid_o,
    output logic [SQ_ID_W-1:0]           store_commit_sq_id_o,
    input  logic                         store_commit_ready_i,
    input  logic                         store_commit_done_i,

    input  logic [5:0]                   prf_read_valid_i,
    input  logic [5:0][PRD_W-1:0]        prf_read_prd_i,
    output logic [5:0][XLEN-1:0]         prf_read_data_o,
    input  logic [1:0]                   wb_valid_i,
    input  logic [1:0][PRD_W-1:0]        wb_prd_i,
    input  logic [1:0][XLEN-1:0]         wb_data_i,
    input  logic [1:0]                   alloc_clear_valid_i,
    input  logic [1:0][PRD_W-1:0]        alloc_clear_prd_i,
    output logic [PHYS_REGS-1:0]         prf_ready_bits_o,

    output recovery_t                    recovery_o,
    output logic [1:0]                   instret_count_o,
    output logic                         store_pending_o,
    output logic                         csr_wb_pending_o,
    output logic                         csr_commit_wakeup_valid_o,
    output logic [PRD_W-1:0]             csr_commit_wakeup_prd_o,
    output logic [XLEN-1:0]              mstatus_o,
    output logic [XLEN-1:0]              mtvec_o,
    output logic [XLEN-1:0]              mepc_o,
    output logic [XLEN-1:0]              mcause_o,
    output logic [XLEN-1:0]              mtval_o,
    input  logic                         recovery_busy_i
);

  logic csr_wb_raw_valid;
  logic [PRD_W-1:0] csr_wb_raw_prd;
  logic [XLEN-1:0] csr_wb_raw_data;
  logic csr_wb_pending_q;
  logic [PRD_W-1:0] csr_wb_prd_q;
  logic [XLEN-1:0] csr_wb_data_q;
  logic csr_wb_buffer_ready;
  logic prf_commit_ready;
  logic prf_commit_fire;

  assign csr_wb_pending_o = csr_wb_pending_q;
  assign csr_wb_buffer_ready = !csr_wb_pending_q && prf_commit_ready;
  assign prf_commit_fire = csr_wb_pending_q && prf_commit_ready;
  assign csr_commit_wakeup_valid_o = prf_commit_fire;
  assign csr_commit_wakeup_prd_o = csr_wb_prd_q;

  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      csr_wb_pending_q <= 1'b0;
      csr_wb_prd_q <= '0;
      csr_wb_data_q <= '0;
    end else begin
      if (prf_commit_fire)
        csr_wb_pending_q <= 1'b0;
      if (csr_wb_raw_valid && csr_wb_buffer_ready) begin
        csr_wb_pending_q <= 1'b1;
        csr_wb_prd_q <= csr_wb_raw_prd;
        csr_wb_data_q <= csr_wb_raw_data;
      end
    end
  end

  commit_csr_cluster #(
      .HART_ID(HART_ID),
      .RESET_MTVEC(RESET_MTVEC)
  ) u_commit_csr (
      .clk_i,
      .rst_i,
      .rob_head_valid_i,
      .rob_head0_i,
      .rob_head1_i,
      .retire_count_o,
      .commit_map0_o,
      .commit_map1_o,
      .reclaim_valid_o,
      .reclaim_prd_o,
      .reclaim_ready_i,
      .store_commit_valid_o,
      .store_commit_sq_id_o,
      .store_commit_ready_i,
      .store_commit_done_i,
      .csr_wb_valid_o(csr_wb_raw_valid),
      .csr_wb_prd_o(csr_wb_raw_prd),
      .csr_wb_data_o(csr_wb_raw_data),
      .csr_wb_ready_i(csr_wb_buffer_ready),
      .recovery_busy_i,
      .recovery_o,
      .instret_count_o,
      .store_pending_o,
      .mstatus_o,
      .mtvec_o,
      .mepc_o,
      .mcause_o,
      .mtval_o
  );

  physical_regfile u_prf (
      .clk_i,
      .rst_i,
      .read_valid_i(prf_read_valid_i),
      .read_prd_i(prf_read_prd_i),
      .read_data_o(prf_read_data_o),
      .wb_valid_i,
      .wb_prd_i,
      .wb_data_i,
      .commit_valid_i(prf_commit_fire),
      .commit_prd_i(csr_wb_prd_q),
      .commit_data_i(csr_wb_data_q),
      .commit_ready_o(prf_commit_ready),
      .alloc_clear_valid_i,
      .alloc_clear_prd_i,
      .ready_bits_o(prf_ready_bits_o)
  );

endmodule
