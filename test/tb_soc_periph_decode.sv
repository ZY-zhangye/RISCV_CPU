import core_types_pkg::*;

module tb_soc_periph_decode;
  timeunit 1ns;
  timeprecision 1ps;

  logic clk_i = 1'b0;
  logic clk_cnt_i = 1'b0;
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

  logic [63:0] sw_i = 64'hfedc_ba98_7654_3210;
  logic [7:0] key_i = 8'ha6;
  logic [31:0] led_o;
  logic [39:0] seg_o;
  logic [XLEN-1:0] last_read_data;

  soc_periph_decode #(
      .MMIO_BASE(32'h8020_0000),
      .MMIO_SIZE(32'h0000_0100),
      .CNT_TICKS_PER_COUNT(4)
  ) dut (.*);

  always #5 clk_i = ~clk_i;
  always #2 clk_cnt_i = ~clk_cnt_i;

  task automatic local_read(
      input logic [XLEN-1:0] addr,
      input logic [XLEN-1:0] expected,
      input logic expect_error
  );
    begin
      @(negedge clk_i);
      req_valid_i = 1'b1;
      req_write_i = 1'b0;
      req_addr_i = addr;
      req_wdata_i = '0;
      req_wstrb_i = '0;
      #1;
      if (!req_ready_o || ext_req_valid_o)
        $fatal(1, "local read was not accepted addr=%h", addr);
      @(posedge clk_i); #1;
      req_valid_i = 1'b0;
      req_addr_i = '0;
      if (!resp_valid_o || resp_error_o !== expect_error)
        $fatal(1, "local read response status mismatch addr=%h err=%0b expected=%0b",
               addr, resp_error_o, expect_error);
      if (!expect_error && !$isunknown(expected) && (resp_rdata_o !== expected))
        $fatal(1, "local read data mismatch addr=%h data=%h expected=%h",
               addr, resp_rdata_o, expected);
      last_read_data = resp_rdata_o;
      @(posedge clk_i); #1;
      if (resp_valid_o)
        $fatal(1, "local read response did not clear");
    end
  endtask

  task automatic local_write(
      input logic [XLEN-1:0] addr,
      input logic [XLEN-1:0] data,
      input logic [3:0] wstrb,
      input logic expect_error
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
        $fatal(1, "local write was not accepted addr=%h", addr);
      @(posedge clk_i); #1;
      req_valid_i = 1'b0;
      req_write_i = 1'b0;
      req_addr_i = '0;
      req_wdata_i = '0;
      req_wstrb_i = '0;
      if (!resp_valid_o || resp_error_o !== expect_error)
        $fatal(1, "local write response mismatch addr=%h err=%0b expected=%0b",
               addr, resp_error_o, expect_error);
      @(posedge clk_i); #1;
      if (resp_valid_o)
        $fatal(1, "local write response did not clear");
    end
  endtask

  initial begin
    repeat (2) @(posedge clk_i);
    @(negedge clk_i);
    rst_i = 1'b0;
    @(posedge clk_i); #1;
    if (led_o != 32'h0000_0000 || resp_valid_o || ext_req_valid_o)
      $fatal(1, "reset state mismatch");

    local_read(32'h8020_0000, 32'h7654_3210, 1'b0);
    local_read(32'h8020_0004, 32'hfedc_ba98, 1'b0);
    local_read(32'h8020_0010, 32'h0000_00a6, 1'b0);
    local_write(32'h8020_0000, 32'h1111_2222, 4'b1111, 1'b1);

    local_write(32'h8020_0020, 32'h1234_abcd, 4'b1111, 1'b0);
    local_read(32'h8020_0020, 32'h1234_abcd, 1'b0);
    local_write(32'h8020_0020, 32'hffff_ffff, 4'b0011, 1'b1);
    local_read(32'h8020_0020, 32'h1234_abcd, 1'b0);

    local_write(32'h8020_0040, 32'ha5a5_5a5a, 4'b1111, 1'b0);
    if (led_o != 32'ha5a5_5a5a)
      $fatal(1, "LED output did not update");
    local_read(32'h8020_0040, '0, 1'b1);

    local_read(32'h8020_0002, '0, 1'b1);
    local_read(32'h8020_0008, '0, 1'b1);

    local_read(32'h8020_0050, 32'h0000_0000, 1'b0);
    local_write(32'h8020_0050, 32'h8000_0000, 4'b1111, 1'b0);
    repeat (20) @(posedge clk_i);
    local_read(32'h8020_0050, 32'hxxxx_xxxx, 1'b0);
    if (last_read_data === 32'h0000_0000)
      $fatal(1, "counter did not advance after start");
    local_write(32'h8020_0050, 32'hffff_ffff, 4'b1111, 1'b0);
    begin
      logic [XLEN-1:0] stopped_count;
      repeat (20) @(posedge clk_i);
      local_read(32'h8020_0050, 32'hxxxx_xxxx, 1'b0);
      stopped_count = last_read_data;
      repeat (20) @(posedge clk_i);
      local_read(32'h8020_0050, 32'hxxxx_xxxx, 1'b0);
      if (last_read_data !== stopped_count)
        $fatal(1, "counter changed after stop count=%h stopped=%h",
               last_read_data, stopped_count);
    end

    @(negedge clk_i);
    req_valid_i = 1'b1;
    req_write_i = 1'b1;
    req_addr_i = 32'h8020_0100;
    req_wdata_i = 32'h1234_5678;
    req_wstrb_i = 4'b1111;
    ext_req_ready_i = 1'b0;
    #1;
    if (req_ready_o || !ext_req_valid_o ||
        !ext_req_write_o ||
        ext_req_addr_o != 32'h8020_0100 ||
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
