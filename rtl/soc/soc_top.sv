// Minimal SoC integration top.
//
// V1 wires core_top to instruction memory, data RAM and the simple address
// router. Peripheral MMIO first hits a small internal decode block for simple
// board I/O, then falls through to the external expansion bus.
import core_types_pkg::*;

module soc_top #(
    parameter logic [XLEN-1:0] HART_ID = '0,
    parameter logic [XLEN-1:0] RESET_MTVEC = RESET_PC,
    parameter logic [XLEN-1:0] RAM_BASE = 32'h8000_0000,
    parameter int unsigned     RAM_BYTES = 262144,
    parameter logic [XLEN-1:0] MMIO_BASE = 32'h1000_0000,
    parameter int unsigned     MMIO_BYTES = 16384,
    parameter int unsigned     LED_WIDTH = 8,
    parameter int unsigned     POWER_ON_RESET_CYCLES = 64,
    parameter string           IMEM_INIT_FILE = "",
    parameter string           DMEM_INIT_FILE = ""
) (
    input  logic                         clk_i,
    input  logic                         rst_i,

    input  logic                         ext_irq_i,
    input  logic                         timer_irq_i,
    input  logic                         software_irq_i,

    output logic                         periph_req_valid_o,
    input  logic                         periph_req_ready_i,
    output logic                         periph_req_write_o,
    output logic [XLEN-1:0]              periph_req_addr_o,
    output logic [XLEN-1:0]              periph_req_wdata_o,
    output logic [3:0]                   periph_req_wstrb_o,
    input  logic                         periph_resp_valid_i,
    input  logic [XLEN-1:0]              periph_resp_rdata_i,
    input  logic                         periph_resp_error_i,

    output logic [LED_WIDTH-1:0]         led_o,

    input  logic                         imem_init_write_valid_i,
    input  logic [XLEN-1:0]              imem_init_write_addr_i,
    input  logic [127:0]                 imem_init_write_data_i,
    output logic                         imem_init_write_ready_o,
    output logic                         imem_init_write_error_o,

    input  logic                         dmem_init_write_valid_i,
    input  logic [XLEN-1:0]              dmem_init_write_addr_i,
    input  logic [XLEN-1:0]              dmem_init_write_data_i,
    input  logic [3:0]                   dmem_init_write_wstrb_i,
    output logic                         dmem_init_write_ready_o,
    output logic                         dmem_init_write_error_o,

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
    output logic [XLEN-1:0]              mtval_o,

    output logic                         imem_resp_error_o,
    output logic                         data_store_error_o,
    output logic                         mmio_busy_o
);

  localparam int unsigned POR_COUNT_W =
      (POWER_ON_RESET_CYCLES <= 1) ? 1 : $clog2(POWER_ON_RESET_CYCLES);

  logic [POR_COUNT_W-1:0] power_on_reset_count_q = '0;
  logic power_on_reset_done_q = 1'b0;
  logic soc_rst;

  logic imem_req_valid;
  logic [XLEN-1:0] imem_req_addr;
  logic imem_resp_valid;
  logic [127:0] imem_resp_data;

  load_mem_req_t core_load_req;
  logic core_load_req_ready;
  load_mem_resp_t core_load_resp;
  logic core_load_resp_ready;
  store_mem_req_t core_store_req;
  logic core_store_req_ready;

  load_mem_req_t ram_load_req;
  logic ram_load_req_ready;
  load_mem_resp_t ram_load_resp;
  logic ram_load_resp_ready;
  store_mem_req_t ram_store_req;
  logic ram_store_req_ready;

  logic router_periph_req_valid;
  logic router_periph_req_ready;
  logic router_periph_req_write;
  logic [XLEN-1:0] router_periph_req_addr;
  logic [XLEN-1:0] router_periph_req_wdata;
  logic [3:0] router_periph_req_wstrb;
  logic router_periph_resp_valid;
  logic [XLEN-1:0] router_periph_resp_rdata;
  logic router_periph_resp_error;

  assign soc_rst = rst_i || !power_on_reset_done_q;

  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      power_on_reset_count_q <= '0;
      power_on_reset_done_q <= (POWER_ON_RESET_CYCLES == 0);
    end else if (!power_on_reset_done_q) begin
      if ((POWER_ON_RESET_CYCLES <= 1) ||
          (power_on_reset_count_q == POWER_ON_RESET_CYCLES[POR_COUNT_W-1:0] - 1'b1)) begin
        power_on_reset_done_q <= 1'b1;
      end else begin
        power_on_reset_count_q <= power_on_reset_count_q + 1'b1;
      end
    end
  end

  core_top #(
      .HART_ID(HART_ID),
      .RESET_MTVEC(RESET_MTVEC)
  ) u_core (
      .clk_i,
      .rst_i(soc_rst),
      .ext_irq_i,
      .timer_irq_i,
      .software_irq_i,
      .imem_req_valid_o(imem_req_valid),
      .imem_req_addr_o(imem_req_addr),
      .imem_resp_valid_i(imem_resp_valid),
      .imem_resp_data_i(imem_resp_data),
      .load_mem_req_o(core_load_req),
      .load_mem_req_ready_i(core_load_req_ready),
      .load_mem_resp_i(core_load_resp),
      .load_mem_resp_ready_o(core_load_resp_ready),
      .store_mem_req_o(core_store_req),
      .store_mem_req_ready_i(core_store_req_ready),
      .interrupt_pending_o,
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

  soc_imem #(
      .BASE_ADDR(RAM_BASE),
      .MEM_BYTES(RAM_BYTES),
      .INIT_FILE(IMEM_INIT_FILE)
  ) u_imem (
      .clk_i,
      .rst_i(soc_rst),
      .imem_req_valid_i(imem_req_valid),
      .imem_req_addr_i(imem_req_addr),
      .imem_resp_valid_o(imem_resp_valid),
      .imem_resp_data_o(imem_resp_data),
      .imem_resp_error_o,
      .init_write_valid_i(imem_init_write_valid_i),
      .init_write_addr_i(imem_init_write_addr_i),
      .init_write_data_i(imem_init_write_data_i),
      .init_write_ready_o(imem_init_write_ready_o),
      .init_write_error_o(imem_init_write_error_o)
  );

  soc_addr_router #(
      .RAM_BASE(RAM_BASE),
      .RAM_SIZE(RAM_BYTES[XLEN-1:0]),
      .MMIO_BASE(MMIO_BASE),
      .MMIO_SIZE(MMIO_BYTES[XLEN-1:0])
  ) u_addr_router (
      .clk_i,
      .rst_i(soc_rst),
      .core_load_req_i(core_load_req),
      .core_load_req_ready_o(core_load_req_ready),
      .core_load_resp_o(core_load_resp),
      .core_load_resp_ready_i(core_load_resp_ready),
      .core_store_req_i(core_store_req),
      .core_store_req_ready_o(core_store_req_ready),
      .ram_load_req_o(ram_load_req),
      .ram_load_req_ready_i(ram_load_req_ready),
      .ram_load_resp_i(ram_load_resp),
      .ram_load_resp_ready_o(ram_load_resp_ready),
      .ram_store_req_o(ram_store_req),
      .ram_store_req_ready_i(ram_store_req_ready),
      .periph_req_valid_o(router_periph_req_valid),
      .periph_req_ready_i(router_periph_req_ready),
      .periph_req_write_o(router_periph_req_write),
      .periph_req_addr_o(router_periph_req_addr),
      .periph_req_wdata_o(router_periph_req_wdata),
      .periph_req_wstrb_o(router_periph_req_wstrb),
      .periph_resp_valid_i(router_periph_resp_valid),
      .periph_resp_rdata_i(router_periph_resp_rdata),
      .periph_resp_error_i(router_periph_resp_error),
      .sticky_store_error_o(data_store_error_o),
      .mmio_busy_o
  );

  soc_periph_decode #(
      .MMIO_BASE(MMIO_BASE),
      .LED_OFFSET(32'h0000_0000),
      .LED_WIDTH(LED_WIDTH)
  ) u_periph_decode (
      .clk_i,
      .rst_i(soc_rst),
      .req_valid_i(router_periph_req_valid),
      .req_ready_o(router_periph_req_ready),
      .req_write_i(router_periph_req_write),
      .req_addr_i(router_periph_req_addr),
      .req_wdata_i(router_periph_req_wdata),
      .req_wstrb_i(router_periph_req_wstrb),
      .resp_valid_o(router_periph_resp_valid),
      .resp_rdata_o(router_periph_resp_rdata),
      .resp_error_o(router_periph_resp_error),
      .ext_req_valid_o(periph_req_valid_o),
      .ext_req_ready_i(periph_req_ready_i),
      .ext_req_write_o(periph_req_write_o),
      .ext_req_addr_o(periph_req_addr_o),
      .ext_req_wdata_o(periph_req_wdata_o),
      .ext_req_wstrb_o(periph_req_wstrb_o),
      .ext_resp_valid_i(periph_resp_valid_i),
      .ext_resp_rdata_i(periph_resp_rdata_i),
      .ext_resp_error_i(periph_resp_error_i),
      .led_o
  );

  soc_data_ram #(
      .BASE_ADDR(RAM_BASE),
      .MEM_BYTES(RAM_BYTES),
      .INIT_FILE(DMEM_INIT_FILE)
  ) u_data_ram (
      .clk_i,
      .rst_i(soc_rst),
      .load_req_i(ram_load_req),
      .load_req_ready_o(ram_load_req_ready),
      .load_resp_o(ram_load_resp),
      .load_resp_ready_i(ram_load_resp_ready),
      .store_req_i(ram_store_req),
      .store_req_ready_o(ram_store_req_ready),
      .init_write_valid_i(dmem_init_write_valid_i),
      .init_write_addr_i(dmem_init_write_addr_i),
      .init_write_data_i(dmem_init_write_data_i),
      .init_write_wstrb_i(dmem_init_write_wstrb_i),
      .init_write_ready_o(dmem_init_write_ready_o),
      .init_write_error_o(dmem_init_write_error_o)
  );

`ifndef SYNTHESIS
  always_ff @(posedge clk_i) begin
    if (!soc_rst) begin
      if (imem_req_valid)
        assert (imem_req_addr[3:0] == 4'b0000)
          else $error("soc_top saw unaligned imem request");
    end
  end
`endif

endmodule
