// Minimal SoC integration top.
//
// The default address map matches the JYD2025 Vivado-facing platform:
// - IROM: 0x8000_0000..0x8000_3fff active, 16 KiB, read-only to the core
// - DRAM: 0x8010_0000..0x8013_ffff active, 256 KiB, read/write
// - MMIO: 0x8020_0000..0x8020_00ff local board peripherals
import core_types_pkg::*;

module soc_top #(
    parameter logic [XLEN-1:0] HART_ID = '0,
    parameter logic [XLEN-1:0] RESET_MTVEC = RESET_PC,
    parameter logic [XLEN-1:0] IROM_BASE = 32'h8000_0000,
    parameter int unsigned     IROM_BYTES = 16384,
    parameter logic [XLEN-1:0] RAM_BASE = 32'h8010_0000,
    parameter int unsigned     RAM_BYTES = 262144,
    parameter logic [XLEN-1:0] MMIO_BASE = 32'h8020_0000,
    parameter int unsigned     MMIO_BYTES = 256,
    parameter int unsigned     POWER_ON_RESET_CYCLES = 64,
    parameter string           IMEM_INIT_FILE = "",
    parameter string           DMEM_INIT_FILE = ""
) (
    input  logic                         clk_i,
    input  logic                         clk_cnt_i,
    input  logic                         rst_i,

    output logic                         periph_req_valid_o,
    input  logic                         periph_req_ready_i,
    output logic                         periph_req_write_o,
    output logic [XLEN-1:0]              periph_req_addr_o,
    output logic [XLEN-1:0]              periph_req_wdata_o,
    output logic [3:0]                   periph_req_wstrb_o,
    input  logic                         periph_resp_valid_i,
    input  logic [XLEN-1:0]              periph_resp_rdata_i,

    input  logic [63:0]                  sw_i,
    input  logic [7:0]                   key_i,
    output logic [31:0]                  led_o,
    output logic [39:0]                  seg_o,

    input  logic                         imem_init_write_valid_i,
    input  logic [XLEN-1:0]              imem_init_write_addr_i,
    input  logic [127:0]                 imem_init_write_data_i,
    output logic                         imem_init_write_ready_o,

    input  logic                         dmem_init_write_valid_i,
    input  logic [XLEN-1:0]              dmem_init_write_addr_i,
    input  logic [XLEN-1:0]              dmem_init_write_data_i,
    input  logic [3:0]                   dmem_init_write_wstrb_i,
    output logic                         dmem_init_write_ready_o
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
      .imem_req_valid_o(imem_req_valid),
      .imem_req_addr_o(imem_req_addr),
      .imem_resp_valid_i(imem_resp_valid),
      .imem_resp_data_i(imem_resp_data),
      .load_mem_req_o(core_load_req),
      .load_mem_req_ready_i(core_load_req_ready),
      .load_mem_resp_i(core_load_resp),
      .load_mem_resp_ready_o(core_load_resp_ready),
      .store_mem_req_o(core_store_req),
      .store_mem_req_ready_i(core_store_req_ready)
  );

  soc_imem #(
      .BASE_ADDR(IROM_BASE),
      .MEM_BYTES(IROM_BYTES),
      .INIT_FILE(IMEM_INIT_FILE)
  ) u_imem (
      .clk_i,
      .rst_i(soc_rst),
      .imem_req_valid_i(imem_req_valid),
      .imem_req_addr_i(imem_req_addr),
      .imem_resp_valid_o(imem_resp_valid),
      .imem_resp_data_o(imem_resp_data),
      .init_write_valid_i(imem_init_write_valid_i),
      .init_write_addr_i(imem_init_write_addr_i),
      .init_write_data_i(imem_init_write_data_i),
      .init_write_ready_o(imem_init_write_ready_o)
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
      .mmio_busy_o()
  );

  soc_periph_decode #(
      .MMIO_BASE(MMIO_BASE),
      .MMIO_SIZE(MMIO_BYTES[XLEN-1:0])
  ) u_periph_decode (
      .clk_i,
      .clk_cnt_i,
      .rst_i(soc_rst),
      .req_valid_i(router_periph_req_valid),
      .req_ready_o(router_periph_req_ready),
      .req_write_i(router_periph_req_write),
      .req_addr_i(router_periph_req_addr),
      .req_wdata_i(router_periph_req_wdata),
      .req_wstrb_i(router_periph_req_wstrb),
      .resp_valid_o(router_periph_resp_valid),
      .resp_rdata_o(router_periph_resp_rdata),
      .ext_req_valid_o(periph_req_valid_o),
      .ext_req_ready_i(periph_req_ready_i),
      .ext_req_write_o(periph_req_write_o),
      .ext_req_addr_o(periph_req_addr_o),
      .ext_req_wdata_o(periph_req_wdata_o),
      .ext_req_wstrb_o(periph_req_wstrb_o),
      .ext_resp_valid_i(periph_resp_valid_i),
      .ext_resp_rdata_i(periph_resp_rdata_i),
      .sw_i,
      .key_i,
      .led_o,
      .seg_o
  );

  soc_data_ram #(
      .BASE_ADDR(RAM_BASE),
      .MEM_BYTES(RAM_BYTES),
      .INIT_FILE(DMEM_INIT_FILE),
      .TRUST_ROUTED_ADDR(1'b1)
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
      .init_write_ready_o(dmem_init_write_ready_o)
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
