import core_types_pkg::*;

module tb_soc_data_ram;
  timeunit 1ns;
  timeprecision 1ps;

  logic clk_i = 1'b0;
  logic rst_i = 1'b1;

  load_mem_req_t load_req_i = '0;
  logic load_req_ready_o;
  load_mem_resp_t load_resp_o;
  logic load_resp_ready_i = 1'b0;

  store_mem_req_t store_req_i = '0;
  logic store_req_ready_o;

  logic init_write_valid_i = 1'b0;
  logic [XLEN-1:0] init_write_addr_i = '0;
  logic [XLEN-1:0] init_write_data_i = '0;
  logic [3:0] init_write_wstrb_i = '0;
  logic init_write_ready_o;
  logic init_write_error_o;

  soc_data_ram #(
      .BASE_ADDR(32'h8010_0000),
      .MEM_BYTES(256)
  ) dut (.*);

  always #5 clk_i = ~clk_i;

  task automatic init_write(
      input logic [XLEN-1:0] addr,
      input logic [XLEN-1:0] data,
      input logic [3:0] wstrb
  );
    begin
      @(negedge clk_i);
      init_write_valid_i = 1'b1;
      init_write_addr_i = addr;
      init_write_data_i = data;
      init_write_wstrb_i = wstrb;
      #1;
      if (!init_write_ready_o || init_write_error_o)
        $fatal(1, "init write was not accepted addr=%h", addr);
      @(posedge clk_i); #1;
      init_write_valid_i = 1'b0;
      init_write_addr_i = '0;
      init_write_data_i = '0;
      init_write_wstrb_i = '0;
    end
  endtask

  task automatic load_word(
      input logic [LQ_ID_W-1:0] lq_id,
      input logic [XLEN-1:0] addr
  );
    begin
      @(negedge clk_i);
      load_req_i.valid = 1'b1;
      load_req_i.lq_id = lq_id;
      load_req_i.address = addr;
      #1;
      if (!load_req_ready_o)
        $fatal(1, "load request was not ready addr=%h", addr);
      @(posedge clk_i); #1;
      load_req_i = '0;
    end
  endtask

  task automatic store_word(
      input logic [SQ_ID_W-1:0] sq_id,
      input logic [XLEN-1:0] addr,
      input logic [XLEN-1:0] data,
      input logic [3:0] wstrb
  );
    begin
      @(negedge clk_i);
      store_req_i.valid = 1'b1;
      store_req_i.sq_id = sq_id;
      store_req_i.address = addr;
      store_req_i.data = data;
      store_req_i.byte_enable = wstrb;
      #1;
      if (!store_req_ready_o)
        $fatal(1, "store request was not ready addr=%h", addr);
      @(posedge clk_i); #1;
      store_req_i = '0;
    end
  endtask

  task automatic expect_resp(
      input logic [LQ_ID_W-1:0] lq_id,
      input logic [XLEN-1:0] data,
      input logic error
  );
    begin
      @(posedge clk_i); #1;
      if (!load_resp_o.valid ||
          load_resp_o.lq_id != lq_id ||
          load_resp_o.data !== data ||
          load_resp_o.error !== error)
        $fatal(1, "load response mismatch id=%0d data=%h err=%0b expected id=%0d data=%h err=%0b",
               load_resp_o.lq_id, load_resp_o.data, load_resp_o.error,
               lq_id, data, error);
    end
  endtask

  task automatic drain_resp;
    begin
      @(negedge clk_i);
      load_resp_ready_i = 1'b1;
      @(posedge clk_i); #1;
      load_resp_ready_i = 1'b0;
    end
  endtask

  initial begin
    repeat (2) @(posedge clk_i);
    @(negedge clk_i);
    rst_i = 1'b0;
    @(posedge clk_i); #1;
    if (!load_req_ready_o || !store_req_ready_o || load_resp_o.valid)
      $fatal(1, "reset state mismatch");

    init_write(32'h8010_0000, 32'h1122_3344, 4'b1111);
    init_write(32'h8010_0004, 32'haabb_ccdd, 4'b1111);

    load_word(3'd1, 32'h8010_0000);
    expect_resp(3'd1, 32'h1122_3344, 1'b0);

    // Response must hold under core/router backpressure, and new loads must
    // not be accepted until the held response drains.
    repeat (2) begin
      @(posedge clk_i); #1;
      if (!load_resp_o.valid ||
          load_resp_o.lq_id != 3'd1 ||
          load_resp_o.data != 32'h1122_3344 ||
          load_req_ready_o)
        $fatal(1, "held response/backpressure mismatch");
    end
    drain_resp();
    if (!load_req_ready_o)
      $fatal(1, "load request did not reopen after response drain");

    // Byte store updates only selected lanes.
    store_word(3'd2, 32'h8010_0000, 32'h0000_aa00, 4'b0010);
    load_word(3'd2, 32'h8010_0000);
    expect_resp(3'd2, 32'h1122_aa44, 1'b0);
    drain_resp();

    // Load and Store can be accepted in the same cycle for independent words.
    @(negedge clk_i);
    load_req_i.valid = 1'b1;
    load_req_i.lq_id = 3'd3;
    load_req_i.address = 32'h8010_0004;
    store_req_i.valid = 1'b1;
    store_req_i.sq_id = 3'd3;
    store_req_i.address = 32'h8010_0008;
    store_req_i.data = 32'h5566_7788;
    store_req_i.byte_enable = 4'b1111;
    #1;
    if (!load_req_ready_o || !store_req_ready_o)
      $fatal(1, "parallel load/store was not accepted");
    @(posedge clk_i); #1;
    load_req_i = '0;
    store_req_i = '0;
    expect_resp(3'd3, 32'haabb_ccdd, 1'b0);
    drain_resp();
    load_word(3'd4, 32'h8010_0008);
    expect_resp(3'd4, 32'h5566_7788, 1'b0);
    drain_resp();

    load_word(3'd5, 32'h8010_0100);
    expect_resp(3'd5, 32'h0000_0000, 1'b1);
    drain_resp();

    @(negedge clk_i);
    init_write_valid_i = 1'b1;
    init_write_addr_i = 32'h8010_0100;
    init_write_data_i = 32'hdead_beef;
    init_write_wstrb_i = 4'b1111;
    #1;
    if (!init_write_error_o || store_req_ready_o)
      $fatal(1, "out-of-range init write/error or store arbitration mismatch");
    @(posedge clk_i); #1;
    init_write_valid_i = 1'b0;
    init_write_addr_i = '0;
    init_write_data_i = '0;
    init_write_wstrb_i = '0;

    $display("PASS: soc_data_ram directed tests");
    $finish;
  end

  initial begin
    #200000;
    $fatal(1, "timeout");
  end
endmodule
