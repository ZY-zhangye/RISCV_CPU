// Board peripheral decode for the contest memory map.
//
// MMIO window:
// - 0x8020_0000: SW[31:0]  read-only
// - 0x8020_0004: SW[63:32] read-only
// - 0x8020_0010: KEY[7:0]  read-only
// - 0x8020_0020: SEG data  read/write
// - 0x8020_0040: LED data  write-only
// - 0x8020_0050: counter   read/write start/stop command
//
// Local accesses are acknowledged deterministically. Unsupported reads return
// zero and unsupported writes have no side effects.
import core_types_pkg::*;

module soc_periph_decode #(
    parameter logic [XLEN-1:0] MMIO_BASE = 32'h8020_0000,
    parameter logic [XLEN-1:0] MMIO_SIZE = 32'h0000_0100,
    parameter int unsigned     CNT_TICKS_PER_COUNT = 50000
) (
    input  logic                         clk_i,
    input  logic                         clk_cnt_i,
    input  logic                         rst_i,

    input  logic                         req_valid_i,
    output logic                         req_ready_o,
    input  logic                         req_write_i,
    input  logic [XLEN-1:0]              req_addr_i,
    input  logic [XLEN-1:0]              req_wdata_i,
    input  logic [3:0]                   req_wstrb_i,
    output logic                         resp_valid_o,
    output logic [XLEN-1:0]              resp_rdata_o,

    output logic                         ext_req_valid_o,
    input  logic                         ext_req_ready_i,
    output logic                         ext_req_write_o,
    output logic [XLEN-1:0]              ext_req_addr_o,
    output logic [XLEN-1:0]              ext_req_wdata_o,
    output logic [3:0]                   ext_req_wstrb_o,
    input  logic                         ext_resp_valid_i,
    input  logic [XLEN-1:0]              ext_resp_rdata_i,

    input  logic [63:0]                  sw_i,
    input  logic [7:0]                   key_i,
    output logic [31:0]                  led_o,
    output logic [39:0]                  seg_o
);

  localparam logic [XLEN-1:0] SW_LOW_ADDR  = MMIO_BASE + 32'h0000_0000;
  localparam logic [XLEN-1:0] SW_HIGH_ADDR = MMIO_BASE + 32'h0000_0004;
  localparam logic [XLEN-1:0] KEY_ADDR     = MMIO_BASE + 32'h0000_0010;
  localparam logic [XLEN-1:0] SEG_ADDR     = MMIO_BASE + 32'h0000_0020;
  localparam logic [XLEN-1:0] LED_ADDR     = MMIO_BASE + 32'h0000_0040;
  localparam logic [XLEN-1:0] CNT_ADDR     = MMIO_BASE + 32'h0000_0050;
  localparam logic [XLEN-1:0] CNT_START    = 32'h8000_0000;
  localparam logic [XLEN-1:0] CNT_STOP     = 32'hffff_ffff;

  logic [XLEN-1:0] led_q;
  logic [XLEN-1:0] seg_data_q;
  logic [XLEN-1:0] cnt_value;
  logic cnt_enable_q;

  logic local_selected;
  logic local_fire;
  logic full_word_write;
  logic [XLEN-1:0] read_data;

  logic resp_valid_q;
  logic [XLEN-1:0] resp_rdata_q;

  function automatic logic in_mmio(input logic [XLEN-1:0] addr);
    logic [XLEN-1:0] offset;
    begin
      offset = addr - MMIO_BASE;
      in_mmio = (addr >= MMIO_BASE) && (offset < MMIO_SIZE);
    end
  endfunction

  assign local_selected = req_valid_i && in_mmio(req_addr_i);
  assign local_fire = local_selected && req_ready_o;
  assign full_word_write = (req_wstrb_i == 4'b1111);

  always_comb begin
    read_data = '0;
    unique case (req_addr_i)
      SW_LOW_ADDR:  read_data = sw_i[31:0];
      SW_HIGH_ADDR: read_data = sw_i[63:32];
      KEY_ADDR:     read_data = {24'b0, key_i};
      SEG_ADDR:     read_data = seg_data_q;
      CNT_ADDR:     read_data = cnt_value;
      default:      read_data = '0;
    endcase
  end

  assign req_ready_o = local_selected ? !resp_valid_q : ext_req_ready_i;
  assign resp_valid_o = resp_valid_q || ext_resp_valid_i;
  assign resp_rdata_o = resp_valid_q ? resp_rdata_q : ext_resp_rdata_i;

  assign ext_req_valid_o = req_valid_i && !local_selected;
  assign ext_req_write_o = req_write_i;
  assign ext_req_addr_o = req_addr_i;
  assign ext_req_wdata_o = req_wdata_i;
  assign ext_req_wstrb_o = req_wstrb_i;
  assign led_o = led_q;

  soc_counter #(
      .TICKS_PER_COUNT(CNT_TICKS_PER_COUNT)
  ) u_counter (
      .cpu_clk_i(clk_i),
      .cnt_clk_i(clk_cnt_i),
      .rst_i,
      .enable_i(cnt_enable_q),
      .count_o(cnt_value)
  );

  soc_display_seg u_display_seg (
      .clk_i(clk_cnt_i),
      .rst_i,
      .data_i(seg_data_q),
      .seg_o
  );

  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      led_q <= '0;
      seg_data_q <= '0;
      cnt_enable_q <= 1'b0;
      resp_valid_q <= 1'b0;
      resp_rdata_q <= '0;
    end else begin
      resp_valid_q <= 1'b0;
      resp_rdata_q <= '0;

      if (local_fire) begin
        resp_valid_q <= 1'b1;
        if (!req_write_i)
          resp_rdata_q <= read_data;

        if (req_write_i && full_word_write) begin
          unique case (req_addr_i)
            SEG_ADDR: seg_data_q <= req_wdata_i;
            LED_ADDR: led_q <= req_wdata_i;
            CNT_ADDR: begin
              if (req_wdata_i == CNT_START)
                cnt_enable_q <= 1'b1;
              else if (req_wdata_i == CNT_STOP)
                cnt_enable_q <= 1'b0;
            end
            default: begin
            end
          endcase
        end
      end
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk_i) begin
    if (!rst_i && resp_valid_q)
      assert (!ext_resp_valid_i)
        else $error("soc_periph_decode saw overlapping local and external responses");
  end
`endif

endmodule

module soc_counter #(
    parameter int unsigned TICKS_PER_COUNT = 50000
) (
    input  logic        cpu_clk_i,
    input  logic        cnt_clk_i,
    input  logic        rst_i,
    input  logic        enable_i,
    output logic [31:0] count_o
);
  logic enable_cnt_meta_q;
  logic enable_cnt_q;
  logic [31:0] count_cnt_q;
  logic [31:0] tick_cnt_q;
  logic [31:0] count_gray_cnt;
  logic [31:0] count_gray_cpu_meta_q;
  logic [31:0] count_gray_cpu_q;
  logic tick_wrap;

  assign tick_wrap = (TICKS_PER_COUNT <= 1) ||
                     (tick_cnt_q == 32'(TICKS_PER_COUNT - 1));

  function automatic logic [31:0] gray_to_bin(input logic [31:0] gray);
    begin
      gray_to_bin[31] = gray[31];
      for (int bit_idx = 30; bit_idx >= 0; bit_idx = bit_idx - 1)
        gray_to_bin[bit_idx] = gray_to_bin[bit_idx + 1] ^ gray[bit_idx];
    end
  endfunction

  always_ff @(posedge cnt_clk_i) begin
    if (rst_i) begin
      enable_cnt_meta_q <= 1'b0;
      enable_cnt_q <= 1'b0;
      count_cnt_q <= '0;
      tick_cnt_q <= '0;
    end else begin
      enable_cnt_meta_q <= enable_i;
      enable_cnt_q <= enable_cnt_meta_q;
      if (enable_cnt_q) begin
        if (tick_wrap) begin
          tick_cnt_q <= '0;
          count_cnt_q <= count_cnt_q + 1'b1;
        end else begin
          tick_cnt_q <= tick_cnt_q + 1'b1;
        end
      end else begin
        tick_cnt_q <= '0;
      end
    end
  end

  assign count_gray_cnt = count_cnt_q ^ (count_cnt_q >> 1);

  always_ff @(posedge cpu_clk_i) begin
    if (rst_i) begin
      count_gray_cpu_meta_q <= '0;
      count_gray_cpu_q <= '0;
    end else begin
      count_gray_cpu_meta_q <= count_gray_cnt;
      count_gray_cpu_q <= count_gray_cpu_meta_q;
    end
  end

  assign count_o = gray_to_bin(count_gray_cpu_q);
endmodule

module soc_display_seg (
    input  logic        clk_i,
    input  logic        rst_i,
    input  logic [31:0] data_i,
    output logic [39:0] seg_o
);
  logic [4:0] scan_count_q;
  logic [3:0] digit0;
  logic [3:0] digit1;
  logic [3:0] digit2;
  logic [3:0] digit3;
  logic [7:0] ans;

  always_ff @(posedge clk_i) begin
    if (rst_i)
      scan_count_q <= '0;
    else
      scan_count_q <= scan_count_q + 1'b1;
  end

  always_comb begin
    if (scan_count_q[4]) begin
      ans = 8'b0101_0101;
      digit0 = data_i[3:0];
      digit1 = data_i[11:8];
      digit2 = data_i[19:16];
      digit3 = data_i[27:24];
    end else begin
      ans = 8'b1010_1010;
      digit0 = data_i[7:4];
      digit1 = data_i[15:12];
      digit2 = data_i[23:20];
      digit3 = data_i[31:28];
    end
  end

  soc_seg7 u_seg0 (.digit_i(digit0), .seg_o(seg_o[6:0]));
  soc_seg7 u_seg1 (.digit_i(digit1), .seg_o(seg_o[16:10]));
  soc_seg7 u_seg2 (.digit_i(digit2), .seg_o(seg_o[26:20]));
  soc_seg7 u_seg3 (.digit_i(digit3), .seg_o(seg_o[36:30]));

  assign seg_o[7] = 1'b0;
  assign seg_o[17] = 1'b0;
  assign seg_o[27] = 1'b0;
  assign seg_o[37] = 1'b0;
  assign {seg_o[39:38], seg_o[29:28], seg_o[19:18], seg_o[9:8]} = ans;
endmodule

module soc_seg7 (
    input  logic [3:0] digit_i,
    output logic [6:0] seg_o
);
  always_comb begin
    unique case (digit_i)
      4'h0: seg_o = 7'b011_1111;
      4'h1: seg_o = 7'b000_0110;
      4'h2: seg_o = 7'b101_1011;
      4'h3: seg_o = 7'h4f;
      4'h4: seg_o = 7'h66;
      4'h5: seg_o = 7'h6d;
      4'h6: seg_o = 7'h7d;
      4'h7: seg_o = 7'h07;
      4'h8: seg_o = 7'h7f;
      4'h9: seg_o = 7'h6f;
      4'ha: seg_o = 7'h77;
      4'hb: seg_o = 7'h7c;
      4'hc: seg_o = 7'h39;
      4'hd: seg_o = 7'h5e;
      4'he: seg_o = 7'h79;
      4'hf: seg_o = 7'h71;
      default: seg_o = 7'h00;
    endcase
  end
endmodule
