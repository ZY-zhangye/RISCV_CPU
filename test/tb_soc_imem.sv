import core_types_pkg::*;

module tb_soc_imem;
  timeunit 1ns;
  timeprecision 1ps;

  logic clk_i = 1'b0;
  logic rst_i = 1'b1;

  logic imem_req_valid_i = 1'b0;
  logic [XLEN-1:0] imem_req_addr_i = '0;
  logic imem_resp_valid_o;
  logic [127:0] imem_resp_data_o;
  logic imem_resp_error_o;

  logic init_write_valid_i = 1'b0;
  logic [XLEN-1:0] init_write_addr_i = '0;
  logic [127:0] init_write_data_i = '0;
  logic init_write_ready_o;
  logic init_write_error_o;

  soc_imem #(
      .MEM_BYTES(256)
  ) dut (.*);

  always #5 clk_i = ~clk_i;

  function automatic logic [127:0] block_data(input logic [31:0] seed);
    block_data = {seed + 32'd12, seed + 32'd8, seed + 32'd4, seed};
  endfunction

  task automatic write_block(
      input logic [XLEN-1:0] addr,
      input logic [127:0] data
  );
    begin
      @(negedge clk_i);
      init_write_valid_i = 1'b1;
      init_write_addr_i = addr;
      init_write_data_i = data;
      #1;
      if (!init_write_ready_o || init_write_error_o)
        $fatal(1, "init write was not accepted addr=%h", addr);
      @(posedge clk_i); #1;
      init_write_valid_i = 1'b0;
      init_write_addr_i = '0;
      init_write_data_i = '0;
    end
  endtask

  task automatic request_block(input logic [XLEN-1:0] addr);
    begin
      @(negedge clk_i);
      imem_req_valid_i = 1'b1;
      imem_req_addr_i = addr;
      @(posedge clk_i); #1;
      imem_req_valid_i = 1'b0;
      imem_req_addr_i = '0;
    end
  endtask

  task automatic expect_response(
      input logic [127:0] data,
      input logic error
  );
    begin
      if (!imem_resp_valid_o ||
          imem_resp_error_o !== error ||
          imem_resp_data_o !== data)
        $fatal(1, "response mismatch valid=%0b error=%0b data=%h expected error=%0b data=%h",
               imem_resp_valid_o, imem_resp_error_o, imem_resp_data_o,
               error, data);
    end
  endtask

  initial begin
    repeat (2) @(posedge clk_i);
    @(negedge clk_i);
    rst_i = 1'b0;
    @(posedge clk_i); #1;
    if (imem_resp_valid_o || imem_resp_error_o)
      $fatal(1, "reset response state mismatch");

    write_block(32'h8000_0000, block_data(32'h1111_0000));
    write_block(32'h8000_0010, block_data(32'h2222_0000));
    write_block(32'h8000_00f0, block_data(32'hffff_0000));

    request_block(32'h8000_0000);
    expect_response(block_data(32'h1111_0000), 1'b0);

    // Back-to-back reads must produce ordered one-cycle responses.
    @(negedge clk_i);
    imem_req_valid_i = 1'b1;
    imem_req_addr_i = 32'h8000_0010;
    @(posedge clk_i); #1;
    expect_response(block_data(32'h2222_0000), 1'b0);
    imem_req_addr_i = 32'h8000_00f0;
    @(posedge clk_i); #1;
    expect_response(block_data(32'hffff_0000), 1'b0);
    imem_req_valid_i = 1'b0;
    imem_req_addr_i = '0;
    @(posedge clk_i); #1;
    if (imem_resp_valid_o)
      $fatal(1, "response valid did not clear after request stream ended");

    request_block(32'h8000_0100);
    expect_response({4{32'h0000_0013}}, 1'b1);

    @(negedge clk_i);
    init_write_valid_i = 1'b1;
    init_write_addr_i = 32'h8000_0100;
    init_write_data_i = block_data(32'h3333_0000);
    #1;
    if (!init_write_error_o)
      $fatal(1, "out-of-range init write did not report error");
    @(posedge clk_i); #1;
    init_write_valid_i = 1'b0;

    $display("PASS: soc_imem directed tests");
    $finish;
  end

  initial begin
    #200000;
    $fatal(1, "timeout");
  end
endmodule
