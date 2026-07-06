// Simple SoC instruction memory wrapper.
//
// The fetch pipeline issues 16-byte aligned block reads and expects an ordered
// fixed-latency response. V1 implements a 128-bit wide synchronous memory with
// an optional block write port for test/program loading.
import core_types_pkg::*;

module soc_imem #(
    parameter logic [XLEN-1:0] BASE_ADDR = 32'h8000_0000,
    parameter int unsigned     MEM_BYTES = 262144,
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

  logic [127:0] mem_q [0:BLOCK_COUNT-1];

  logic resp_valid_q;
  logic [127:0] resp_data_q;
  logic resp_error_q;

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
  assign imem_resp_data_o = resp_data_q;
  assign imem_resp_error_o = resp_error_q;

  initial begin
    if (INIT_FILE != "")
      $readmemh(INIT_FILE, mem_q);
  end

  always_ff @(posedge clk_i) begin
    if (init_write_valid_i && init_hit)
      mem_q[init_index] <= init_write_data_i;

    if (rst_i) begin
      resp_valid_q <= 1'b0;
      resp_data_q <= '0;
      resp_error_q <= 1'b0;
    end else begin
      resp_valid_q <= imem_req_valid_i;
      resp_error_q <= imem_req_valid_i && !req_hit;
      if (req_hit)
        resp_data_q <= mem_q[req_index];
      else
        resp_data_q <= NOP_BLOCK;
    end
  end

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
