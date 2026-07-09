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
  logic periph_resp_valid_q;

  always_ff @(posedge clk) begin
    if (!rst_n)
      periph_resp_valid_q <= 1'b0;
    else
      periph_resp_valid_q <= periph_req_valid;
  end

  soc_top u_soc (
      .clk_i(clk),
      .clk_cnt_i(clk_cnt),
      .rst_i(!rst_n),
      .periph_req_valid_o(periph_req_valid),
      .periph_req_ready_i(1'b1),
      .periph_req_write_o(),
      .periph_req_addr_o(),
      .periph_req_wdata_o(),
      .periph_req_wstrb_o(),
      .periph_resp_valid_i(periph_resp_valid_q),
      .periph_resp_rdata_i('0),
      .sw_i(sw),
      .key_i(key),
      .led_o(led),
      .seg_o(seg),
      .imem_init_write_valid_i(1'b0),
      .imem_init_write_addr_i('0),
      .imem_init_write_data_i('0),
      .imem_init_write_ready_o(),
      .dmem_init_write_valid_i(1'b0),
      .dmem_init_write_addr_i('0),
      .dmem_init_write_data_i('0),
      .dmem_init_write_wstrb_i('0),
      .dmem_init_write_ready_o()
  );

endmodule
