// Simple SoC instruction memory wrapper.
//
// The fetch pipeline issues 16-byte aligned block reads and expects an ordered
// fixed-latency response. V1 implements a 128-bit wide synchronous memory with
// an optional block write port for test/program loading.
import core_types_pkg::*;

module soc_imem #(
    parameter logic [XLEN-1:0] BASE_ADDR = 32'h8000_0000,
    parameter int unsigned     MEM_BYTES = 16384,
    parameter string           INIT_FILE = ""
) (
    input  logic                         clk_i,
    input  logic                         rst_i,

    input  logic                         imem_req_valid_i,
    input  logic [XLEN-1:0]              imem_req_addr_i,
    output logic                         imem_resp_valid_o,
    output logic [127:0]                 imem_resp_data_o,
    output logic                         imem_resp_error_o,

    input  logic                         init_write_valid_i,
    input  logic [XLEN-1:0]              init_write_addr_i,
    input  logic [127:0]                 init_write_data_i,
    output logic                         init_write_ready_o,
    output logic                         init_write_error_o
);

  localparam int unsigned BLOCK_BYTES = 16;
  localparam int unsigned BLOCK_COUNT = MEM_BYTES / BLOCK_BYTES;
  localparam int unsigned BLOCK_INDEX_W =
      (BLOCK_COUNT <= 1) ? 1 : $clog2(BLOCK_COUNT);
  localparam logic [127:0] NOP_BLOCK = {4{32'h0000_0013}};
  localparam string XPM_INIT_FILE = (INIT_FILE == "") ? "none" : INIT_FILE;
  localparam int unsigned XPM_USE_MEM_INIT = (INIT_FILE == "") ? 0 : 1;

`ifndef SYNTHESIS
  (* ram_style = "block" *) logic [31:0] mem_b0_q [0:BLOCK_COUNT-1];
  (* ram_style = "block" *) logic [31:0] mem_b1_q [0:BLOCK_COUNT-1];
  (* ram_style = "block" *) logic [31:0] mem_b2_q [0:BLOCK_COUNT-1];
  (* ram_style = "block" *) logic [31:0] mem_b3_q [0:BLOCK_COUNT-1];
`endif

  logic resp_valid_q;
`ifndef SYNTHESIS
  logic [127:0] resp_data_q;
`endif
  logic resp_error_q;
`ifdef SYNTHESIS
  logic [127:0] xpm_read_data;
  logic xpm_read_enable;
  logic [0:0] xpm_write_enable;
`endif

  logic req_hit;
  logic init_hit;
  logic [BLOCK_INDEX_W-1:0] req_index;
  logic [BLOCK_INDEX_W-1:0] init_index;

  function automatic logic in_range(input logic [XLEN-1:0] addr);
    logic [XLEN-1:0] offset;
    begin
      offset = addr - BASE_ADDR;
      in_range = (addr >= BASE_ADDR) && (offset < MEM_BYTES);
    end
  endfunction

  function automatic logic [BLOCK_INDEX_W-1:0] block_index(
      input logic [XLEN-1:0] addr
  );
    logic [XLEN-1:0] offset;
    begin
      offset = addr - BASE_ADDR;
      block_index = offset[BLOCK_INDEX_W+3:4];
    end
  endfunction

  assign req_hit = imem_req_valid_i && in_range(imem_req_addr_i);
  assign init_hit = init_write_valid_i && in_range(init_write_addr_i);
  assign req_index = block_index(imem_req_addr_i);
  assign init_index = block_index(init_write_addr_i);
  assign init_write_ready_o = 1'b1;
  assign init_write_error_o = init_write_valid_i && !init_hit;
  assign imem_resp_valid_o = resp_valid_q;
  assign imem_resp_error_o = resp_error_q;
`ifdef SYNTHESIS
  assign imem_resp_data_o = resp_error_q ? NOP_BLOCK : xpm_read_data;
  assign xpm_read_enable = req_hit;
  assign xpm_write_enable[0] = init_write_valid_i && init_hit;
`else
  assign imem_resp_data_o = resp_data_q;
`endif

`ifndef SYNTHESIS
  logic [127:0] init_mem [0:BLOCK_COUNT-1];

  initial begin
    if (INIT_FILE != "") begin
      $readmemh(INIT_FILE, init_mem);
      for (int idx = 0; idx < BLOCK_COUNT; idx = idx + 1) begin
        mem_b0_q[idx] = init_mem[idx][31:0];
        mem_b1_q[idx] = init_mem[idx][63:32];
        mem_b2_q[idx] = init_mem[idx][95:64];
        mem_b3_q[idx] = init_mem[idx][127:96];
      end
    end
  end
`endif

`ifdef SYNTHESIS
  xpm_memory_sdpram #(
      .ADDR_WIDTH_A(BLOCK_INDEX_W),
      .ADDR_WIDTH_B(BLOCK_INDEX_W),
      .AUTO_SLEEP_TIME(0),
      .BYTE_WRITE_WIDTH_A(128),
      .CASCADE_HEIGHT(0),
      .CLOCKING_MODE("common_clock"),
      .ECC_MODE("no_ecc"),
      .MEMORY_INIT_FILE(XPM_INIT_FILE),
      .MEMORY_INIT_PARAM("0"),
      .MEMORY_OPTIMIZATION("true"),
      .MEMORY_PRIMITIVE("block"),
      .MEMORY_SIZE(BLOCK_COUNT * 128),
      .MESSAGE_CONTROL(0),
      .READ_DATA_WIDTH_B(128),
      .READ_LATENCY_B(1),
      .READ_RESET_VALUE_B("0"),
      .RST_MODE_A("SYNC"),
      .RST_MODE_B("SYNC"),
      .SIM_ASSERT_CHK(0),
      .USE_EMBEDDED_CONSTRAINT(0),
      .USE_MEM_INIT(XPM_USE_MEM_INIT),
      .WAKEUP_TIME("disable_sleep"),
      .WRITE_DATA_WIDTH_A(128),
      .WRITE_MODE_B("read_first")
  ) u_imem_xpm (
      .clka(clk_i),
      .clkb(clk_i),
      .ena(xpm_write_enable[0]),
      .enb(xpm_read_enable),
      .wea(xpm_write_enable),
      .addra(init_index),
      .addrb(req_index),
      .dina(init_write_data_i),
      .doutb(xpm_read_data),
      .injectdbiterra(1'b0),
      .injectsbiterra(1'b0),
      .regceb(1'b1),
      .rstb(rst_i),
      .sleep(1'b0),
      .dbiterrb(),
      .sbiterrb()
  );

  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      resp_valid_q <= 1'b0;
      resp_error_q <= 1'b0;
    end else begin
      resp_valid_q <= imem_req_valid_i;
      resp_error_q <= imem_req_valid_i && !req_hit;
    end
  end
`else
  always @(posedge clk_i) begin
    if (init_write_valid_i && init_hit) begin
      mem_b0_q[init_index] <= init_write_data_i[31:0];
      mem_b1_q[init_index] <= init_write_data_i[63:32];
      mem_b2_q[init_index] <= init_write_data_i[95:64];
      mem_b3_q[init_index] <= init_write_data_i[127:96];
    end

    if (rst_i) begin
      resp_valid_q <= 1'b0;
      resp_data_q <= '0;
      resp_error_q <= 1'b0;
    end else begin
      resp_valid_q <= imem_req_valid_i;
      resp_error_q <= imem_req_valid_i && !req_hit;
      if (req_hit) begin
        resp_data_q[31:0] <= mem_b0_q[req_index];
        resp_data_q[63:32] <= mem_b1_q[req_index];
        resp_data_q[95:64] <= mem_b2_q[req_index];
        resp_data_q[127:96] <= mem_b3_q[req_index];
      end else begin
        resp_data_q <= NOP_BLOCK;
      end
    end
  end
`endif

`ifndef SYNTHESIS
  always_ff @(posedge clk_i) begin
    if (!rst_i) begin
      if (imem_req_valid_i)
        assert (imem_req_addr_i[3:0] == 4'b0000)
          else $error("soc_imem received unaligned instruction block address");

      if (init_write_valid_i)
        assert (init_write_addr_i[3:0] == 4'b0000)
          else $error("soc_imem init write address is not block aligned");
    end
  end
`endif

endmodule
