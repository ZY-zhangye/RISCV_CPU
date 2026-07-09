// Simple SoC data RAM wrapper.
//
// V1 stores bytes in 32-bit word banks and accepts LSU memory requests after
// address routing. Loads return the 4-byte window starting at the byte address.
// Stores update absolute byte addresses selected by byte_enable, so byte/half/
// word accesses may cross an aligned word boundary.
import core_types_pkg::*;

module soc_data_ram #(
    parameter logic [XLEN-1:0] BASE_ADDR = 32'h8010_0000,
    parameter int unsigned     MEM_BYTES = 262144,
    parameter string           INIT_FILE = "",
    parameter bit              TRUST_ROUTED_ADDR = 1'b0
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
  logic [1:0] load_pipe_lane_q;
  logic load_pipe_error_q;

  logic [7:0] read_data_b0_q;
  logic [7:0] read_data_b1_q;
  logic [7:0] read_data_b2_q;
  logic [7:0] read_data_b3_q;

  logic load_hit;
  logic store_hit;
  logic store_write_ok;
  logic init_hit;
  logic load_fire;
  logic store_fire;
  logic init_fire;
  logic ram_read_fire;

  logic [WORD_INDEX_W-1:0] load_base_index;
  logic [WORD_INDEX_W-1:0] store_base_index;
  logic [WORD_INDEX_W-1:0] init_base_index;
  logic [WORD_INDEX_W-1:0] load_read_index_b0;
  logic [WORD_INDEX_W-1:0] load_read_index_b1;
  logic [WORD_INDEX_W-1:0] load_read_index_b2;
  logic [WORD_INDEX_W-1:0] load_read_index_b3;
  logic [1:0] load_base_lane;
  logic [1:0] store_base_lane;

  logic write_en_b0;
  logic write_en_b1;
  logic write_en_b2;
  logic write_en_b3;
  logic [WORD_INDEX_W-1:0] write_index_b0;
  logic [WORD_INDEX_W-1:0] write_index_b1;
  logic [WORD_INDEX_W-1:0] write_index_b2;
  logic [WORD_INDEX_W-1:0] write_index_b3;
  logic [7:0] write_data_b0;
  logic [7:0] write_data_b1;
  logic [7:0] write_data_b2;
  logic [7:0] write_data_b3;

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

  function automatic logic [WORD_INDEX_W-1:0] routed_word_index(
      input logic [XLEN-1:0] addr
  );
    begin
      if (TRUST_ROUTED_ADDR)
        routed_word_index = addr[WORD_INDEX_W+1:2];
      else
        routed_word_index = word_index(addr);
    end
  endfunction

  function automatic logic [1:0] routed_byte_lane(
      input logic [XLEN-1:0] addr
  );
    begin
      if (TRUST_ROUTED_ADDR)
        routed_byte_lane = addr[1:0];
      else
        routed_byte_lane = byte_lane(addr);
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

  assign load_hit = TRUST_ROUTED_ADDR ?
                    load_req_i.valid :
                    (load_req_i.valid &&
                     byte_window_in_range(load_req_i.address, 4'b1111));
  assign store_hit = store_req_i.valid &&
                     byte_window_in_range(store_req_i.address,
                                          store_req_i.byte_enable);
  assign store_write_ok = TRUST_ROUTED_ADDR ? store_req_i.valid : store_hit;
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
  // Keep BRAM read enable independent of the address range comparator.
  assign ram_read_fire = load_fire;

  assign load_base_index = routed_word_index(load_req_i.address);
  assign store_base_index = routed_word_index(store_req_i.address);
  assign init_base_index = word_index(init_write_addr_i);
  assign load_base_lane = routed_byte_lane(load_req_i.address);
  assign store_base_lane = routed_byte_lane(store_req_i.address);
`ifdef SYNTHESIS
  assign load_read_index_b0 = load_base_index + WORD_INDEX_W'(load_base_lane > 2'd0);
  assign load_read_index_b1 = load_base_index + WORD_INDEX_W'(load_base_lane > 2'd1);
  assign load_read_index_b2 = load_base_index + WORD_INDEX_W'(load_base_lane > 2'd2);
  assign load_read_index_b3 = load_base_index;
`else
  assign load_read_index_b0 = load_hit ?
                              (load_base_index + WORD_INDEX_W'(load_base_lane > 2'd0)) :
                              '0;
  assign load_read_index_b1 = load_hit ?
                              (load_base_index + WORD_INDEX_W'(load_base_lane > 2'd1)) :
                              '0;
  assign load_read_index_b2 = load_hit ?
                              (load_base_index + WORD_INDEX_W'(load_base_lane > 2'd2)) :
                              '0;
  assign load_read_index_b3 = load_hit ? load_base_index : '0;
`endif

  always_comb begin
    write_en_b0 = 1'b0;
    write_en_b1 = 1'b0;
    write_en_b2 = 1'b0;
    write_en_b3 = 1'b0;
    write_index_b0 = '0;
    write_index_b1 = '0;
    write_index_b2 = '0;
    write_index_b3 = '0;
    write_data_b0 = '0;
    write_data_b1 = '0;
    write_data_b2 = '0;
    write_data_b3 = '0;

    if (init_fire) begin
      write_en_b0 = init_write_wstrb_i[0];
      write_en_b1 = init_write_wstrb_i[1];
      write_en_b2 = init_write_wstrb_i[2];
      write_en_b3 = init_write_wstrb_i[3];
      write_index_b0 = init_base_index;
      write_index_b1 = init_base_index;
      write_index_b2 = init_base_index;
      write_index_b3 = init_base_index;
      write_data_b0 = init_write_data_i[7:0];
      write_data_b1 = init_write_data_i[15:8];
      write_data_b2 = init_write_data_i[23:16];
      write_data_b3 = init_write_data_i[31:24];
    end else begin
      for (int byte_idx = 0; byte_idx < WORD_BYTES; byte_idx = byte_idx + 1) begin
        logic [2:0] lane_sum;
        logic [1:0] target_lane;
        logic [WORD_INDEX_W-1:0] target_index;

        lane_sum = {1'b0, store_base_lane} + byte_idx[2:0];
        target_lane = lane_sum[1:0];
        target_index = store_base_index + WORD_INDEX_W'(lane_sum[2]);

        if (store_req_i.byte_enable[byte_idx]) begin
          unique case (target_lane)
            2'd0: begin
              write_en_b0 = store_fire && store_write_ok;
              write_index_b0 = target_index;
              write_data_b0 = store_req_i.data[byte_idx * 8 +: 8];
            end
            2'd1: begin
              write_en_b1 = store_fire && store_write_ok;
              write_index_b1 = target_index;
              write_data_b1 = store_req_i.data[byte_idx * 8 +: 8];
            end
            2'd2: begin
              write_en_b2 = store_fire && store_write_ok;
              write_index_b2 = target_index;
              write_data_b2 = store_req_i.data[byte_idx * 8 +: 8];
            end
            default: begin
              write_en_b3 = store_fire && store_write_ok;
              write_index_b3 = target_index;
              write_data_b3 = store_req_i.data[byte_idx * 8 +: 8];
            end
          endcase
        end
      end
    end
  end

  initial begin
    if (INIT_FILE != "") begin
      logic [31:0] init_mem [0:WORD_COUNT-1];
      for (int idx = 0; idx < WORD_COUNT; idx = idx + 1)
        init_mem[idx] = '0;
      $readmemh(INIT_FILE, init_mem);
      for (int idx = 0; idx < WORD_COUNT; idx = idx + 1) begin
        mem_b0_q[idx] = init_mem[idx][7:0];
        mem_b1_q[idx] = init_mem[idx][15:8];
        mem_b2_q[idx] = init_mem[idx][23:16];
        mem_b3_q[idx] = init_mem[idx][31:24];
      end
    end
  end

  always @(posedge clk_i) begin
    if (write_en_b0)
      mem_b0_q[write_index_b0] <= write_data_b0;
    if (write_en_b1)
      mem_b1_q[write_index_b1] <= write_data_b1;
    if (write_en_b2)
      mem_b2_q[write_index_b2] <= write_data_b2;
    if (write_en_b3)
      mem_b3_q[write_index_b3] <= write_data_b3;

    if (ram_read_fire) begin
      read_data_b0_q <= mem_b0_q[load_read_index_b0];
      read_data_b1_q <= mem_b1_q[load_read_index_b1];
      read_data_b2_q <= mem_b2_q[load_read_index_b2];
      read_data_b3_q <= mem_b3_q[load_read_index_b3];
    end

    if (rst_i) begin
      load_resp_q <= '0;
      load_pipe_valid_q <= 1'b0;
      load_pipe_lq_id_q <= '0;
      load_pipe_lane_q <= '0;
      load_pipe_error_q <= 1'b0;
      read_data_b0_q <= '0;
      read_data_b1_q <= '0;
      read_data_b2_q <= '0;
      read_data_b3_q <= '0;
    end else begin
      if (load_resp_q.valid && load_resp_ready_i)
        load_resp_q <= '0;

      if (load_fire) begin
        load_pipe_valid_q <= 1'b1;
        load_pipe_lq_id_q <= load_req_i.lq_id;
        load_pipe_lane_q <= load_base_lane;
        load_pipe_error_q <= !load_hit;
      end

      if (load_pipe_valid_q) begin
        load_pipe_valid_q <= 1'b0;
        load_resp_q.valid <= 1'b1;
        load_resp_q.lq_id <= load_pipe_lq_id_q;
        load_resp_q.error <= load_pipe_error_q;
        if (load_pipe_error_q) begin
          load_resp_q.data <= '0;
        end else begin
          unique case (load_pipe_lane_q)
            2'd0: load_resp_q.data <= {read_data_b3_q, read_data_b2_q,
                                       read_data_b1_q, read_data_b0_q};
            2'd1: load_resp_q.data <= {read_data_b0_q, read_data_b3_q,
                                       read_data_b2_q, read_data_b1_q};
            2'd2: load_resp_q.data <= {read_data_b1_q, read_data_b0_q,
                                       read_data_b3_q, read_data_b2_q};
            default: load_resp_q.data <= {read_data_b2_q, read_data_b1_q,
                                          read_data_b0_q, read_data_b3_q};
          endcase
        end
      end
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk_i) begin
    if (!rst_i) begin
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
