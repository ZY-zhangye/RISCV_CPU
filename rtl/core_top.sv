// CPU core integration top.
//
// This layer keeps RAM/MMIO outside the core.  It wraps the frozen
// frontend_backend_cluster and exposes the typed memory interfaces that the
// SoC-level router will consume.
import core_types_pkg::*;

module core_top #(
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
    input  logic                         store_mem_req_ready_i
);

  frontend_backend_cluster #(
      .HART_ID(HART_ID),
      .RESET_MTVEC(RESET_MTVEC)
  ) u_core_cluster (
      .clk_i,
      .rst_i,
      .imem_req_valid_o,
      .imem_req_addr_o,
      .imem_resp_valid_i,
      .imem_resp_data_i,
      .load_mem_req_o,
      .load_mem_req_ready_i,
      .load_mem_resp_i,
      .load_mem_resp_ready_o,
      .store_mem_req_o,
      .store_mem_req_ready_i,
      .recovery_o(),
      .checkpoint_clear_valid_o(),
      .checkpoint_clear_id_o(),
      .redirect_valid_o(),
      .redirect_pc_o(),
      .retire_count_o(),
      .rob_occupancy_o(),
      .rob_empty_o(),
      .rob_full_o(),
      .free_prd_count_o(),
      .free_lq_count_o(),
      .free_sq_count_o(),
      .active_checkpoint_count_o(),
      .recovery_busy_o(),
      .busy_o(),
      .ibuf_occupancy_o(),
      .dispatch_buffer_occupancy_o(),
      .int_issue_occupancy_o(),
      .mem_issue_occupancy_o(),
      .mdu_issue_occupancy_o(),
      .lq_occupancy_o(),
      .sq_occupancy_o(),
      .prf_ready_bits_o(),
      .mstatus_o(),
      .mtvec_o(),
      .mepc_o(),
      .mcause_o(),
      .mtval_o()
  );

endmodule
