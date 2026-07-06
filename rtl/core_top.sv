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

    input  logic                         ext_irq_i,
    input  logic                         timer_irq_i,
    input  logic                         software_irq_i,

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

    output logic                         interrupt_pending_o,
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

  assign interrupt_pending_o = ext_irq_i | timer_irq_i | software_irq_i;

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
      .recovery_o,
      .checkpoint_clear_valid_o,
      .checkpoint_clear_id_o,
      .redirect_valid_o,
      .redirect_pc_o,
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
      .ibuf_occupancy_o,
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
          else $error("core_top saw misaligned redirect");
    end
  end
`endif

endmodule
