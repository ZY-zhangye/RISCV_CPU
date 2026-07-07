// Simple SoC data RAM wrapper.
//
// V1 stores bytes in 32-bit word banks and accepts LSU memory requests after
// address routing. Loads return the 4-byte window starting at the byte address.
// Stores update absolute byte addresses selected by byte_enable, so byte/half/
// word accesses may cross an aligned word boundary.
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

  (* ram_style = "block" *) logic [7:0] mem_b0_q [0:WORD_COUNT-1];
  (* ram_style = "block" *) logic [7:0] mem_b1_q [0:WORD_COUNT-1];
  (* ram_style = "block" *) logic [7:0] mem_b2_q [0:WORD_COUNT-1];
  (* ram_style = "block" *) logic [7:0] mem_b3_q [0:WORD_COUNT-1];

  load_mem_resp_t load_resp_q;
  logic load_pipe_valid_q;
  logic [LQ_ID_W-1:0] load_pipe_lq_id_q;
  logic [XLEN-1:0] load_pipe_data_q;
  logic load_pipe_error_q;

  logic load_hit;
  logic store_hit;
  logic init_hit;
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

  function automatic logic [1:0] byte_lane(input logic [XLEN-1:0] addr);
    logic [XLEN-1:0] offset;
    begin
      offset = addr - BASE_ADDR;
      byte_lane = offset[1:0];
    end
  endfunction

  function automatic logic byte_window_in_range(
      input logic [XLEN-1:0] address,
      input logic [3:0] mask
  );
    begin
      byte_window_in_range = 1'b1;
      for (int byte_idx = 0; byte_idx < WORD_BYTES; byte_idx = byte_idx + 1) begin
        if (mask[byte_idx] && !in_range(address + byte_idx))
          byte_window_in_range = 1'b0;
      end
    end
  endfunction

  assign load_hit = load_req_i.valid &&
                    byte_window_in_range(load_req_i.address, 4'b1111);
  assign store_hit = store_req_i.valid &&
                     byte_window_in_range(store_req_i.address,
                                          store_req_i.byte_enable);
  assign init_hit = init_write_valid_i &&
                    byte_window_in_range(init_write_addr_i,
                                         init_write_wstrb_i);

  assign load_req_ready_o = !load_pipe_valid_q && !load_resp_q.valid;
  assign store_req_ready_o = !init_write_valid_i;
  assign init_write_ready_o = 1'b1;
  assign init_write_error_o = init_write_valid_i && !init_hit;
  assign load_resp_o = load_resp_q;

  assign load_fire = load_req_i.valid && load_req_ready_o;
  assign store_fire = store_req_i.valid && store_req_ready_o;
  assign init_fire = init_write_valid_i && init_hit;

`ifndef SYNTHESIS
  initial begin
    if (INIT_FILE != "")
      $error("soc_data_ram INIT_FILE is not supported by the byte-lane BRAM implementation; use init_write ports");
  end
`endif

  always_ff @(posedge clk_i) begin
    logic [XLEN-1:0] write_addr;
    logic [XLEN-1:0] load_addr;
    logic [WORD_INDEX_W-1:0] access_index;
    logic [1:0] access_lane;

    if (init_fire) begin
      for (int byte_idx = 0; byte_idx < WORD_BYTES; byte_idx = byte_idx + 1) begin
        if (init_write_wstrb_i[byte_idx]) begin
          write_addr = init_write_addr_i + byte_idx;
          access_index = word_index(write_addr);
          access_lane = byte_lane(write_addr);
          unique case (access_lane)
            2'd0: mem_b0_q[access_index] <= init_write_data_i[byte_idx * 8 +: 8];
            2'd1: mem_b1_q[access_index] <= init_write_data_i[byte_idx * 8 +: 8];
            2'd2: mem_b2_q[access_index] <= init_write_data_i[byte_idx * 8 +: 8];
            default: mem_b3_q[access_index] <= init_write_data_i[byte_idx * 8 +: 8];
          endcase
        end
      end
    end else if (store_fire && store_hit) begin
      for (int byte_idx = 0; byte_idx < WORD_BYTES; byte_idx = byte_idx + 1) begin
        if (store_req_i.byte_enable[byte_idx]) begin
          write_addr = store_req_i.address + byte_idx;
          access_index = word_index(write_addr);
          access_lane = byte_lane(write_addr);
          unique case (access_lane)
            2'd0: mem_b0_q[access_index] <= store_req_i.data[byte_idx * 8 +: 8];
            2'd1: mem_b1_q[access_index] <= store_req_i.data[byte_idx * 8 +: 8];
            2'd2: mem_b2_q[access_index] <= store_req_i.data[byte_idx * 8 +: 8];
            default: mem_b3_q[access_index] <= store_req_i.data[byte_idx * 8 +: 8];
          endcase
        end
      end
    end

    if (rst_i) begin
      load_resp_q <= '0;
      load_pipe_valid_q <= 1'b0;
      load_pipe_lq_id_q <= '0;
      load_pipe_data_q <= '0;
      load_pipe_error_q <= 1'b0;
    end else begin
      if (load_resp_q.valid && load_resp_ready_i)
        load_resp_q <= '0;

      if (load_fire) begin
        load_pipe_valid_q <= 1'b1;
        load_pipe_lq_id_q <= load_req_i.lq_id;
        load_pipe_error_q <= !load_hit;
        load_pipe_data_q <= '0;

        if (load_hit) begin
          for (int byte_idx = 0; byte_idx < WORD_BYTES; byte_idx = byte_idx + 1) begin
            load_addr = load_req_i.address + byte_idx;
            access_index = word_index(load_addr);
            access_lane = byte_lane(load_addr);
            unique case (access_lane)
              2'd0: load_pipe_data_q[byte_idx * 8 +: 8] <= mem_b0_q[access_index];
              2'd1: load_pipe_data_q[byte_idx * 8 +: 8] <= mem_b1_q[access_index];
              2'd2: load_pipe_data_q[byte_idx * 8 +: 8] <= mem_b2_q[access_index];
              default: load_pipe_data_q[byte_idx * 8 +: 8] <= mem_b3_q[access_index];
            endcase
          end
        end
      end

      if (load_pipe_valid_q) begin
        load_pipe_valid_q <= 1'b0;
        load_resp_q.valid <= 1'b1;
        load_resp_q.lq_id <= load_pipe_lq_id_q;
        load_resp_q.error <= load_pipe_error_q;
        load_resp_q.data <= load_pipe_data_q;
      end
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk_i) begin
    if (!rst_i) begin
      if (load_req_i.valid)
        assert (byte_window_in_range(load_req_i.address, 4'b1111))
          else $error("soc_data_ram load address window is out of range");

      if (store_req_i.valid) begin
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
