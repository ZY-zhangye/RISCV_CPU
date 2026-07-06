// Simple SoC data RAM wrapper.
//
// V1 stores 32-bit words and accepts typed LSU memory requests after address
// routing. Loads produce a one-cycle registered response when the response slot
// is free. Stores are committed side effects and update bytes selected by
// byte_enable.
import core_types_pkg::*;

module soc_data_ram #(
    parameter logic [XLEN-1:0] BASE_ADDR = 32'h8000_0000,
    parameter int unsigned     MEM_BYTES = 262144,
    parameter string           INIT_FILE = ""
) (
    input  logic                         clk_i,
    input  logic                         rst_i,

    input  load_mem_req_t                load_req_i,
    output logic                         load_req_ready_o,
    output load_mem_resp_t               load_resp_o,
    input  logic                         load_resp_ready_i,

    input  store_mem_req_t               store_req_i,
    output logic                         store_req_ready_o,

    input  logic                         init_write_valid_i,
    input  logic [XLEN-1:0]              init_write_addr_i,
    input  logic [XLEN-1:0]              init_write_data_i,
    input  logic [3:0]                   init_write_wstrb_i,
    output logic                         init_write_ready_o,
    output logic                         init_write_error_o
);

  localparam int unsigned WORD_BYTES = 4;
  localparam int unsigned WORD_COUNT = MEM_BYTES / WORD_BYTES;
  localparam int unsigned WORD_INDEX_W =
      (WORD_COUNT <= 1) ? 1 : $clog2(WORD_COUNT);

  (* ram_style = "block" *) logic [XLEN-1:0] mem_q [0:WORD_COUNT-1];

  load_mem_resp_t load_resp_q;
  logic load_pipe_valid_q;
  logic [LQ_ID_W-1:0] load_pipe_lq_id_q;
  logic [WORD_INDEX_W-1:0] load_pipe_index_q;
  logic load_pipe_error_q;

  logic load_hit;
  logic store_hit;
  logic init_hit;
  logic [WORD_INDEX_W-1:0] load_index;
  logic [WORD_INDEX_W-1:0] store_index;
  logic [WORD_INDEX_W-1:0] init_index;
  logic load_fire;
  logic store_fire;
  logic init_fire;

  function automatic logic in_range(input logic [XLEN-1:0] addr);
    logic [XLEN-1:0] offset;
    begin
      offset = addr - BASE_ADDR;
      in_range = (addr >= BASE_ADDR) && (offset < MEM_BYTES);
    end
  endfunction

  function automatic logic [WORD_INDEX_W-1:0] word_index(
      input logic [XLEN-1:0] addr
  );
    logic [XLEN-1:0] offset;
    begin
      offset = addr - BASE_ADDR;
      word_index = offset[WORD_INDEX_W+1:2];
    end
  endfunction

  assign load_hit = load_req_i.valid && in_range(load_req_i.address);
  assign store_hit = store_req_i.valid && in_range(store_req_i.address);
  assign init_hit = init_write_valid_i && in_range(init_write_addr_i);
  assign load_index = word_index(load_req_i.address);
  assign store_index = word_index(store_req_i.address);
  assign init_index = word_index(init_write_addr_i);

  assign load_req_ready_o = !load_pipe_valid_q && !load_resp_q.valid;
  assign store_req_ready_o = !init_write_valid_i;
  assign init_write_ready_o = 1'b1;
  assign init_write_error_o = init_write_valid_i && !init_hit;
  assign load_resp_o = load_resp_q;

  assign load_fire = load_req_i.valid && load_req_ready_o;
  assign store_fire = store_req_i.valid && store_req_ready_o;
  assign init_fire = init_write_valid_i && init_hit;

  initial begin
    if (INIT_FILE != "")
      $readmemh(INIT_FILE, mem_q);
  end

  always_ff @(posedge clk_i) begin
    if (init_fire) begin
      if (init_write_wstrb_i[0])
        mem_q[init_index][7:0] <= init_write_data_i[7:0];
      if (init_write_wstrb_i[1])
        mem_q[init_index][15:8] <= init_write_data_i[15:8];
      if (init_write_wstrb_i[2])
        mem_q[init_index][23:16] <= init_write_data_i[23:16];
      if (init_write_wstrb_i[3])
        mem_q[init_index][31:24] <= init_write_data_i[31:24];
    end else if (store_fire && store_hit) begin
      if (store_req_i.byte_enable[0])
        mem_q[store_index][7:0] <= store_req_i.data[7:0];
      if (store_req_i.byte_enable[1])
        mem_q[store_index][15:8] <= store_req_i.data[15:8];
      if (store_req_i.byte_enable[2])
        mem_q[store_index][23:16] <= store_req_i.data[23:16];
      if (store_req_i.byte_enable[3])
        mem_q[store_index][31:24] <= store_req_i.data[31:24];
    end

    if (rst_i) begin
      load_resp_q <= '0;
      load_pipe_valid_q <= 1'b0;
      load_pipe_lq_id_q <= '0;
      load_pipe_index_q <= '0;
      load_pipe_error_q <= 1'b0;
    end else begin
      if (load_resp_q.valid && load_resp_ready_i)
        load_resp_q <= '0;

      if (load_fire) begin
        load_pipe_valid_q <= 1'b1;
        load_pipe_lq_id_q <= load_req_i.lq_id;
        load_pipe_index_q <= load_index;
        load_pipe_error_q <= !load_hit;
      end

      if (load_pipe_valid_q) begin
        load_pipe_valid_q <= 1'b0;
        load_resp_q.valid <= 1'b1;
        load_resp_q.lq_id <= load_pipe_lq_id_q;
        load_resp_q.error <= load_pipe_error_q;
        if (load_pipe_error_q)
          load_resp_q.data <= '0;
        else
          load_resp_q.data <= mem_q[load_pipe_index_q];
      end
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk_i) begin
    if (!rst_i) begin
      if (load_req_i.valid)
        assert (load_req_i.address[1:0] == 2'b00)
          else $error("soc_data_ram load address is not word aligned");

      if (store_req_i.valid) begin
        assert (store_req_i.address[1:0] == 2'b00)
          else $error("soc_data_ram store address is not word aligned");
        assert (store_req_i.byte_enable != 4'b0000)
          else $error("soc_data_ram store byte_enable is zero");
      end

      if (init_write_valid_i)
        assert (init_write_addr_i[1:0] == 2'b00)
          else $error("soc_data_ram init write address is not word aligned");
    end
  end
`endif

endmodule
