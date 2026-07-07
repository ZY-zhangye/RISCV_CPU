// Minimal SoC peripheral decode.
//
// V1 implements a memory-mapped LED register and forwards all other MMIO
// accesses to the external peripheral expansion bus.
import core_types_pkg::*;

module soc_periph_decode #(
    parameter logic [XLEN-1:0] MMIO_BASE = 32'h1000_0000,
    parameter logic [XLEN-1:0] LED_OFFSET = 32'h0000_0000,
    parameter int unsigned     LED_WIDTH = 8
) (
    input  logic                         clk_i,
    input  logic                         rst_i,

    input  logic                         req_valid_i,
    output logic                         req_ready_o,
    input  logic                         req_write_i,
    input  logic [XLEN-1:0]              req_addr_i,
    input  logic [XLEN-1:0]              req_wdata_i,
    input  logic [3:0]                   req_wstrb_i,
    output logic                         resp_valid_o,
    output logic [XLEN-1:0]              resp_rdata_o,
    output logic                         resp_error_o,

    output logic                         ext_req_valid_o,
    input  logic                         ext_req_ready_i,
    output logic                         ext_req_write_o,
    output logic [XLEN-1:0]              ext_req_addr_o,
    output logic [XLEN-1:0]              ext_req_wdata_o,
    output logic [3:0]                   ext_req_wstrb_o,
    input  logic                         ext_resp_valid_i,
    input  logic [XLEN-1:0]              ext_resp_rdata_i,
    input  logic                         ext_resp_error_i,

    output logic [LED_WIDTH-1:0]         led_o
);

  logic [XLEN-1:0] led_q;
  logic led_selected;
  logic led_resp_valid_q;
  logic [XLEN-1:0] led_resp_rdata_q;
  logic led_resp_error_q;

  function automatic logic is_led_addr(input logic [XLEN-1:0] addr);
    logic [XLEN-1:0] offset;
    begin
      offset = addr - (MMIO_BASE + LED_OFFSET);
      is_led_addr = (addr >= (MMIO_BASE + LED_OFFSET)) &&
                    (offset < 4);
    end
  endfunction

  assign led_selected = req_valid_i && is_led_addr(req_addr_i);

  assign req_ready_o = led_selected ? !led_resp_valid_q : ext_req_ready_i;
  assign resp_valid_o = led_resp_valid_q || ext_resp_valid_i;
  assign resp_rdata_o = led_resp_valid_q ? led_resp_rdata_q : ext_resp_rdata_i;
  assign resp_error_o = led_resp_valid_q ? led_resp_error_q : ext_resp_error_i;

  assign ext_req_valid_o = req_valid_i && !led_selected;
  assign ext_req_write_o = req_write_i;
  assign ext_req_addr_o = req_addr_i;
  assign ext_req_wdata_o = req_wdata_i;
  assign ext_req_wstrb_o = req_wstrb_i;
  assign led_o = led_q[LED_WIDTH-1:0];

  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      led_q <= '0;
      led_resp_valid_q <= 1'b0;
      led_resp_rdata_q <= '0;
      led_resp_error_q <= 1'b0;
    end else begin
      led_resp_valid_q <= 1'b0;
      led_resp_rdata_q <= '0;
      led_resp_error_q <= 1'b0;

      if (led_selected && req_ready_o) begin
        if (req_write_i) begin
          if (req_wstrb_i[0])
            led_q[7:0] <= req_wdata_i[7:0];
          if (req_wstrb_i[1])
            led_q[15:8] <= req_wdata_i[15:8];
          if (req_wstrb_i[2])
            led_q[23:16] <= req_wdata_i[23:16];
          if (req_wstrb_i[3])
            led_q[31:24] <= req_wdata_i[31:24];
          led_resp_valid_q <= 1'b1;
        end else begin
          led_resp_valid_q <= 1'b1;
          led_resp_rdata_q <= led_q;
        end
      end
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk_i) begin
    if (!rst_i) begin
      if (resp_valid_o && led_resp_valid_q)
        assert (!ext_resp_valid_i)
          else $error("soc_periph_decode saw overlapping LED and external responses");

    end
  end
`endif

endmodule
