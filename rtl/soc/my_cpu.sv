// JYD2025 Vivado-facing CPU wrapper.
//
// This module keeps the board project's expected port names while reusing the
// local SoC integration top and address map.
import core_types_pkg::*;

module my_cpu (
    input  logic        clk,
    input  logic        clk_cnt,
    input  logic        rst_n,
    output logic [31:0] led,
    input  logic [7:0]  key,
    input  logic [63:0] sw,
    output logic [39:0] seg
);

  logic periph_req_valid;
  logic periph_req_write;
  logic [XLEN-1:0] periph_req_addr;
  logic [XLEN-1:0] periph_req_wdata;
  logic [3:0] periph_req_wstrb;
  logic periph_error_resp_q;

  recovery_t unused_recovery;
  logic unused_interrupt_pending;
  logic unused_checkpoint_clear_valid;
  logic [CP_W-1:0] unused_checkpoint_clear_id;
  logic unused_redirect_valid;
  logic [XLEN-1:0] unused_redirect_pc;
  logic [1:0] unused_retire_count;
  logic [5:0] unused_rob_occupancy;
  logic unused_rob_empty;
  logic unused_rob_full;
  logic [6:0] unused_free_prd_count;
  logic [3:0] unused_free_lq_count;
  logic [3:0] unused_free_sq_count;
  logic [$clog2(CHECKPOINTS+1)-1:0] unused_active_checkpoint_count;
  logic unused_recovery_busy;
  logic unused_busy;
  logic [3:0] unused_ibuf_occupancy;
  logic [2:0] unused_dispatch_buffer_occupancy;
  logic [$clog2(IQ_INT_ENTRIES+1)-1:0] unused_int_issue_occupancy;
  logic [$clog2(IQ_MEM_ENTRIES+1)-1:0] unused_mem_issue_occupancy;
  logic [$clog2(IQ_MDU_ENTRIES+1)-1:0] unused_mdu_issue_occupancy;
  logic [3:0] unused_lq_occupancy;
  logic [3:0] unused_sq_occupancy;
  logic [PHYS_REGS-1:0] unused_prf_ready_bits;
  logic [XLEN-1:0] unused_mstatus;
  logic [XLEN-1:0] unused_mtvec;
  logic [XLEN-1:0] unused_mepc;
  logic [XLEN-1:0] unused_mcause;
  logic [XLEN-1:0] unused_mtval;
  logic unused_imem_resp_error;
  logic unused_data_store_error;
  logic unused_mmio_busy;

  always_ff @(posedge clk) begin
    if (!rst_n)
      periph_error_resp_q <= 1'b0;
    else
      periph_error_resp_q <= periph_req_valid;
  end

  soc_top u_soc (
      .clk_i(clk),
      .clk_cnt_i(clk_cnt),
      .rst_i(!rst_n),
      .ext_irq_i(1'b0),
      .timer_irq_i(1'b0),
      .software_irq_i(1'b0),
      .periph_req_valid_o(periph_req_valid),
      .periph_req_ready_i(1'b1),
      .periph_req_write_o(periph_req_write),
      .periph_req_addr_o(periph_req_addr),
      .periph_req_wdata_o(periph_req_wdata),
      .periph_req_wstrb_o(periph_req_wstrb),
      .periph_resp_valid_i(periph_error_resp_q),
      .periph_resp_rdata_i('0),
      .periph_resp_error_i(1'b1),
      .sw_i(sw),
      .key_i(key),
      .led_o(led),
      .seg_o(seg),
      .imem_init_write_valid_i(1'b0),
      .imem_init_write_addr_i('0),
      .imem_init_write_data_i('0),
      .imem_init_write_ready_o(),
      .imem_init_write_error_o(),
      .dmem_init_write_valid_i(1'b0),
      .dmem_init_write_addr_i('0),
      .dmem_init_write_data_i('0),
      .dmem_init_write_wstrb_i('0),
      .dmem_init_write_ready_o(),
      .dmem_init_write_error_o(),
      .interrupt_pending_o(unused_interrupt_pending),
      .recovery_o(unused_recovery),
      .checkpoint_clear_valid_o(unused_checkpoint_clear_valid),
      .checkpoint_clear_id_o(unused_checkpoint_clear_id),
      .redirect_valid_o(unused_redirect_valid),
      .redirect_pc_o(unused_redirect_pc),
      .retire_count_o(unused_retire_count),
      .rob_occupancy_o(unused_rob_occupancy),
      .rob_empty_o(unused_rob_empty),
      .rob_full_o(unused_rob_full),
      .free_prd_count_o(unused_free_prd_count),
      .free_lq_count_o(unused_free_lq_count),
      .free_sq_count_o(unused_free_sq_count),
      .active_checkpoint_count_o(unused_active_checkpoint_count),
      .recovery_busy_o(unused_recovery_busy),
      .busy_o(unused_busy),
      .ibuf_occupancy_o(unused_ibuf_occupancy),
      .dispatch_buffer_occupancy_o(unused_dispatch_buffer_occupancy),
      .int_issue_occupancy_o(unused_int_issue_occupancy),
      .mem_issue_occupancy_o(unused_mem_issue_occupancy),
      .mdu_issue_occupancy_o(unused_mdu_issue_occupancy),
      .lq_occupancy_o(unused_lq_occupancy),
      .sq_occupancy_o(unused_sq_occupancy),
      .prf_ready_bits_o(unused_prf_ready_bits),
      .mstatus_o(unused_mstatus),
      .mtvec_o(unused_mtvec),
      .mepc_o(unused_mepc),
      .mcause_o(unused_mcause),
      .mtval_o(unused_mtval),
      .imem_resp_error_o(unused_imem_resp_error),
      .data_store_error_o(unused_data_store_error),
      .mmio_busy_o(unused_mmio_busy)
  );

endmodule
