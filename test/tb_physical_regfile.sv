`timescale 1ns/1ps

import core_types_pkg::*;

module tb_physical_regfile;
  logic clk_i = 1'b0;
  logic rst_i = 1'b1;
  logic [5:0] read_valid_i = '0;
  logic [5:0][PRD_W-1:0] read_prd_i = '0;
  logic [5:0][XLEN-1:0] read_data_o;
  logic [1:0] wb_valid_i = '0;
  logic [1:0][PRD_W-1:0] wb_prd_i = '0;
  logic [1:0][XLEN-1:0] wb_data_i = '0;
  logic commit_valid_i = 1'b0;
  logic [PRD_W-1:0] commit_prd_i = '0;
  logic [XLEN-1:0] commit_data_i = '0;
  logic commit_ready_o;
  logic [1:0] alloc_clear_valid_i = '0;
  logic [1:0][PRD_W-1:0] alloc_clear_prd_i = '0;
  logic [PHYS_REGS-1:0] ready_bits_o;

  physical_regfile dut (.*);

  always #5 clk_i = ~clk_i;

  task automatic clear_controls;
    begin
      read_valid_i = '0;
      read_prd_i = '0;
      wb_valid_i = '0;
      wb_prd_i = '0;
      wb_data_i = '0;
      commit_valid_i = 1'b0;
      commit_prd_i = '0;
      commit_data_i = '0;
      alloc_clear_valid_i = '0;
      alloc_clear_prd_i = '0;
    end
  endtask

  task automatic write_two(
      input logic [PRD_W-1:0] prd0,
      input logic [XLEN-1:0] data0,
      input logic [PRD_W-1:0] prd1,
      input logic [XLEN-1:0] data1
  );
    begin
      @(negedge clk_i);
      wb_valid_i = 2'b11;
      wb_prd_i[0] = prd0;
      wb_prd_i[1] = prd1;
      wb_data_i[0] = data0;
      wb_data_i[1] = data1;
      @(posedge clk_i);
      #1;
      wb_valid_i = '0;
      wb_prd_i = '0;
      wb_data_i = '0;
    end
  endtask

  initial begin
    integer lane;

    repeat (2) @(posedge clk_i);
    @(negedge clk_i);
    rst_i = 1'b0;
    #1;
    if (ready_bits_o !== {PHYS_REGS{1'b1}})
      $fatal(1, "PRF ready reset state mismatch");
    if (read_data_o !== '0)
      $fatal(1, "PRF read output reset state mismatch");

    // Allocation clears two newly assigned physical destinations.
    alloc_clear_valid_i = 2'b11;
    alloc_clear_prd_i[0] = 6'd10;
    alloc_clear_prd_i[1] = 6'd11;
    @(posedge clk_i);
    #1;
    if (ready_bits_o[10] || ready_bits_o[11] || !ready_bits_o[0])
      $fatal(1, "allocation ready clear mismatch");
    @(negedge clk_i);
    alloc_clear_valid_i = '0;
    alloc_clear_prd_i = '0;

    // Opposite-Bank dual writeback updates data and ready state together.
    write_two(6'd10, 32'h1111_aaaa, 6'd11, 32'h2222_bbbb);
    if (!ready_bits_o[10] || !ready_bits_o[11])
      $fatal(1, "dual writeback did not set ready bits");

    // Three requests per Bank exercise all six physical read copies.
    @(negedge clk_i);
    read_valid_i = 6'b11_1111;
    read_prd_i[0] = 6'd10;
    read_prd_i[1] = 6'd10;
    read_prd_i[2] = 6'd10;
    read_prd_i[3] = 6'd11;
    read_prd_i[4] = 6'd11;
    read_prd_i[5] = 6'd11;
    @(posedge clk_i);
    #1;
    for (lane = 0; lane < 3; lane = lane + 1)
      if (read_data_o[lane] !== 32'h1111_aaaa)
        $fatal(1, "even-Bank copy %0d read mismatch", lane);
    for (lane = 3; lane < 6; lane = lane + 1)
      if (read_data_o[lane] !== 32'h2222_bbbb)
        $fatal(1, "odd-Bank copy %0d read mismatch", lane - 3);

    // Interleaved lane order must still allocate each Bank's copies correctly.
    write_two(6'd20, 32'h3333_cccc, 6'd21, 32'h4444_dddd);
    @(negedge clk_i);
    read_valid_i = 6'b11_1111;
    read_prd_i[0] = 6'd20;
    read_prd_i[1] = 6'd21;
    read_prd_i[2] = 6'd20;
    read_prd_i[3] = 6'd21;
    read_prd_i[4] = 6'd20;
    read_prd_i[5] = 6'd21;
    @(posedge clk_i);
    #1;
    for (lane = 0; lane < 6; lane = lane + 1) begin
      if (!lane[0] && (read_data_o[lane] !== 32'h3333_cccc))
        $fatal(1, "interleaved even read lane %0d mismatch", lane);
      if (lane[0] && (read_data_o[lane] !== 32'h4444_dddd))
        $fatal(1, "interleaved odd read lane %0d mismatch", lane);
    end

    // Invalid lanes and p0 return zero without consuming a physical copy.
    @(negedge clk_i);
    read_valid_i = 6'b00_0111;
    read_prd_i = '0;
    read_prd_i[0] = 6'd0;
    read_prd_i[1] = 6'd20;
    read_prd_i[2] = 6'd21;
    @(posedge clk_i);
    #1;
    if (read_data_o[0] !== 32'd0 ||
        read_data_o[1] !== 32'h3333_cccc ||
        read_data_o[2] !== 32'h4444_dddd ||
        read_data_o[3] !== 32'd0 || read_data_o[4] !== 32'd0 ||
        read_data_o[5] !== 32'd0)
      $fatal(1, "p0/invalid read behavior mismatch");

    // A write and allocation clear for the same PRD writes the data but leaves
    // the destination not-ready; allocation clear has ready-bit priority.
    @(negedge clk_i);
    read_valid_i = '0;
    wb_valid_i = 2'b01;
    wb_prd_i[0] = 6'd12;
    wb_data_i[0] = 32'h5555_eeee;
    alloc_clear_valid_i = 2'b01;
    alloc_clear_prd_i[0] = 6'd12;
    @(posedge clk_i);
    #1;
    if (ready_bits_o[12])
      $fatal(1, "allocation clear did not override WB ready set");
    @(negedge clk_i);
    wb_valid_i = '0;
    alloc_clear_valid_i = '0;
    read_valid_i = 6'b00_0001;
    read_prd_i[0] = 6'd12;
    @(posedge clk_i);
    #1;
    if (read_data_o[0] !== 32'h5555_eeee)
      $fatal(1, "same-cycle WB/alloc data write was lost");

    // A lane-1-only even write verifies the per-Bank lane fallback mux.
    @(negedge clk_i);
    read_valid_i = '0;
    wb_valid_i = 2'b10;
    wb_prd_i[1] = 6'd22;
    wb_data_i[1] = 32'h6666_f00d;
    @(posedge clk_i);
    #1;
    if (!ready_bits_o[22])
      $fatal(1, "lane-1-only write did not set ready");
    @(negedge clk_i);
    clear_controls();
    read_valid_i = 6'b00_0001;
    read_prd_i[0] = 6'd22;
    @(posedge clk_i);
    #1;
    if (read_data_o[0] !== 32'h6666_f00d)
      $fatal(1, "lane-1-only even write data mismatch");

    @(negedge clk_i);
    clear_controls();
    @(posedge clk_i);
    #1;
    if (read_data_o !== '0 || !ready_bits_o[0])
      $fatal(1, "final PRF idle/p0 state mismatch");

    // CSR commit has a dedicated handshake and updates data/ready atomically.
    @(negedge clk_i);
    commit_valid_i = 1'b1;
    commit_prd_i = 6'd24;
    commit_data_i = 32'hc001_c0de;
    if (!commit_ready_o)
      $fatal(1, "idle PRF did not accept CSR commit write");
    @(posedge clk_i); #1;
    commit_valid_i = 1'b0;
    if (!ready_bits_o[24])
      $fatal(1, "CSR commit write did not set ready");
    @(negedge clk_i);
    read_valid_i = 6'b00_0001;
    read_prd_i[0] = 6'd24;
    @(posedge clk_i); #1;
    if (read_data_o[0] !== 32'hc001_c0de)
      $fatal(1, "CSR commit write data mismatch");

    // Any normal WB reserves the shared physical write resources.
    @(negedge clk_i);
    clear_controls();
    wb_valid_i = 2'b01;
    wb_prd_i[0] = 6'd26;
    wb_data_i[0] = 32'h1234_5678;
    #1;
    if (commit_ready_o)
      $fatal(1, "CSR commit ready ignored active normal WB");
    @(posedge clk_i); #1;
    clear_controls();

    $display("PASS: physical_regfile directed tests");
    $finish;
  end

  initial begin
    #30000;
    $fatal(1, "timeout");
  end
endmodule
