import core_types_pkg::*;

module tb_soc_periph_decode;
  timeunit 1ns;
  timeprecision 1ps;

  logic clk_i = 1'b0;
  logic rst_i = 1'b1;

  logic req_valid_i = 1'b0;
  logic req_ready_o;
  logic req_write_i = 1'b0;
  logic [XLEN-1:0] req_addr_i = '0;
  logic [XLEN-1:0] req_wdata_i = '0;
  logic [3:0] req_wstrb_i = '0;
  logic resp_valid_o;
  logic [XLEN-1:0] resp_rdata_o;
  logic resp_error_o;

  logic ext_req_valid_o;
  logic ext_req_ready_i = 1'b0;
  logic ext_req_write_o;
  logic [XLEN-1:0] ext_req_addr_o;
  logic [XLEN-1:0] ext_req_wdata_o;
  logic [3:0] ext_req_wstrb_o;
  logic ext_resp_valid_i = 1'b0;
  logic [XLEN-1:0] ext_resp_rdata_i = '0;
  logic ext_resp_error_i = 1'b0;

  logic [7:0] led_o;

  soc_periph_decode #(
      .MMIO_BASE(32'h1000_0000),
      .LED_OFFSET(32'h0000_0000),
      .LED_WIDTH(8)
  ) dut (.*);

  always #5 clk_i = ~clk_i;

  task automatic led_write(
      input logic [XLEN-1:0] addr,
      input logic [XLEN-1:0] data,
      input logic [3:0] wstrb
  );
    begin
      @(negedge clk_i);
      req_valid_i = 1'b1;
      req_write_i = 1'b1;
      req_addr_i = addr;
      req_wdata_i = data;
      req_wstrb_i = wstrb;
      #1;
      if (!req_ready_o || ext_req_valid_o)
        $fatal(1, "LED write was not accepted locally");
      @(posedge clk_i); #1;
      req_valid_i = 1'b0;
      req_write_i = 1'b0;
      req_addr_i = '0;
      req_wdata_i = '0;
      req_wstrb_i = '0;
      if (!resp_valid_o || resp_error_o)
        $fatal(1, "LED write response mismatch");
      @(posedge clk_i); #1;
      if (resp_valid_o)
        $fatal(1, "LED write response did not clear");
    end
  endtask

  task automatic led_read(
      input logic [XLEN-1:0] addr,
      input logic [XLEN-1:0] expected
  );
    begin
      @(negedge clk_i);
      req_valid_i = 1'b1;
      req_write_i = 1'b0;
      req_addr_i = addr;
      #1;
      if (!req_ready_o || ext_req_valid_o)
        $fatal(1, "LED read was not accepted locally");
      @(posedge clk_i); #1;
      req_valid_i = 1'b0;
      req_addr_i = '0;
      if (!resp_valid_o || resp_error_o || resp_rdata_o !== expected)
        $fatal(1, "LED read response mismatch data=%h expected=%h",
               resp_rdata_o, expected);
      @(posedge clk_i); #1;
      if (resp_valid_o)
        $fatal(1, "LED read response did not clear");
    end
  endtask

  initial begin
    repeat (2) @(posedge clk_i);
    @(negedge clk_i);
    rst_i = 1'b0;
    @(posedge clk_i); #1;
    if (led_o != 8'h00 || resp_valid_o || ext_req_valid_o)
      $fatal(1, "reset state mismatch");

    led_write(32'h1000_0000, 32'h0000_00a5, 4'b0001);
    if (led_o != 8'ha5)
      $fatal(1, "LED output did not update");
    led_read(32'h1000_0000, 32'h0000_00a5);

    led_write(32'h1000_0001, 32'h0000_ff00, 4'b0010);
    if (led_o != 8'ha5)
      $fatal(1, "upper byte write changed 8-bit LED output");
    led_read(32'h1000_0000, 32'h0000_ffa5);

    @(negedge clk_i);
    req_valid_i = 1'b1;
    req_write_i = 1'b1;
    req_addr_i = 32'h1000_0100;
    req_wdata_i = 32'h1234_5678;
    req_wstrb_i = 4'b1111;
    ext_req_ready_i = 1'b0;
    #1;
    if (req_ready_o || !ext_req_valid_o ||
        !ext_req_write_o ||
        ext_req_addr_o != 32'h1000_0100 ||
        ext_req_wdata_o != 32'h1234_5678 ||
        ext_req_wstrb_o != 4'b1111)
      $fatal(1, "external request backpressure/payload mismatch");
    ext_req_ready_i = 1'b1;
    #1;
    if (!req_ready_o)
      $fatal(1, "external request did not become ready");
    @(posedge clk_i); #1;
    req_valid_i = 1'b0;
    req_write_i = 1'b0;
    req_addr_i = '0;
    req_wdata_i = '0;
    req_wstrb_i = '0;
    ext_req_ready_i = 1'b0;

    @(negedge clk_i);
    ext_resp_valid_i = 1'b1;
    ext_resp_rdata_i = 32'hfeed_cafe;
    ext_resp_error_i = 1'b1;
    #1;
    if (!resp_valid_o || resp_rdata_o != 32'hfeed_cafe || !resp_error_o)
      $fatal(1, "external response passthrough mismatch");
    @(posedge clk_i); #1;
    ext_resp_valid_i = 1'b0;
    ext_resp_rdata_i = '0;
    ext_resp_error_i = 1'b0;

    $display("PASS: soc_periph_decode directed tests");
    $finish;
  end

  initial begin
    #200000;
    $fatal(1, "timeout");
  end
endmodule
