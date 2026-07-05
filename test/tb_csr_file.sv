`timescale 1ns/1ps

import core_types_pkg::*;

module tb_csr_file;
  localparam logic [31:0] HART_ID_VALUE = 32'h0000_0123;
  localparam logic [31:0] RESET_MTVEC_VALUE = 32'h8000_0100;

  localparam logic [11:0] CSR_MSTATUS  = 12'h300;
  localparam logic [11:0] CSR_MIE      = 12'h304;
  localparam logic [11:0] CSR_MTVEC    = 12'h305;
  localparam logic [11:0] CSR_MSCRATCH = 12'h340;
  localparam logic [11:0] CSR_MEPC     = 12'h341;
  localparam logic [11:0] CSR_MCAUSE   = 12'h342;
  localparam logic [11:0] CSR_MTVAL    = 12'h343;
  localparam logic [11:0] CSR_MCYCLE   = 12'hb00;
  localparam logic [11:0] CSR_MINSTRET = 12'hb02;
  localparam logic [11:0] CSR_MHARTID  = 12'hf14;

  logic clk_i = 1'b0;
  logic rst_i = 1'b1;

  logic csr_valid_i = 1'b0;
  logic csr_ready_o;
  csr_op_t csr_op_i = CSR_RW;
  logic [11:0] csr_addr_i = '0;
  logic [XLEN-1:0] csr_rs1_value_i = '0;
  logic [4:0] csr_zimm_i = '0;
  logic csr_result_valid_o;
  logic [XLEN-1:0] csr_rdata_o;
  logic csr_illegal_o;

  logic exception_valid_i = 1'b0;
  logic [XLEN-1:0] exception_pc_i = '0;
  logic [3:0] exception_cause_i = '0;
  logic [XLEN-1:0] exception_tval_i = '0;
  logic [XLEN-1:0] exception_vector_o;

  logic mret_valid_i = 1'b0;
  logic [XLEN-1:0] mret_vector_o;

  logic retire_valid_i = 1'b0;
  logic [1:0] retire_count_i = '0;

  logic [XLEN-1:0] mstatus_o;
  logic [XLEN-1:0] mie_o;
  logic [XLEN-1:0] mtvec_o;
  logic [XLEN-1:0] mepc_o;
  logic [XLEN-1:0] mcause_o;
  logic [XLEN-1:0] mtval_o;

  csr_file #(
      .HART_ID(HART_ID_VALUE),
      .RESET_MTVEC(RESET_MTVEC_VALUE)
  ) dut (.*);

  always #5 clk_i = ~clk_i;

  function automatic logic [31:0] mstatus_value(
      input logic mie,
      input logic mpie,
      input logic [1:0] mpp
  );
    begin
      mstatus_value = '0;
      mstatus_value[3] = mie;
      mstatus_value[7] = mpie;
      mstatus_value[12:11] = mpp;
    end
  endfunction

  task automatic clear_inputs;
    begin
      csr_valid_i = 1'b0;
      csr_op_i = CSR_RW;
      csr_addr_i = '0;
      csr_rs1_value_i = '0;
      csr_zimm_i = '0;
      exception_valid_i = 1'b0;
      exception_pc_i = '0;
      exception_cause_i = '0;
      exception_tval_i = '0;
      mret_valid_i = 1'b0;
      retire_valid_i = 1'b0;
      retire_count_i = '0;
    end
  endtask

  task automatic csr_cycle(
      input csr_op_t op,
      input logic [11:0] addr,
      input logic [XLEN-1:0] rs1_value,
      input logic [4:0] zimm,
      input logic [XLEN-1:0] expected_old,
      input logic expected_illegal
  );
    begin
      @(negedge clk_i);
      csr_valid_i = 1'b1;
      csr_op_i = op;
      csr_addr_i = addr;
      csr_rs1_value_i = rs1_value;
      csr_zimm_i = zimm;
      #1;
      if (!csr_ready_o || !csr_result_valid_o ||
          csr_rdata_o !== expected_old || csr_illegal_o !== expected_illegal)
        $fatal(1, "CSR cycle mismatch addr=%h old=%h exp=%h illegal=%0d exp=%0d",
               addr, csr_rdata_o, expected_old, csr_illegal_o, expected_illegal);
      @(posedge clk_i); #1;
      csr_valid_i = 1'b0;
      csr_addr_i = '0;
      csr_rs1_value_i = '0;
      csr_zimm_i = '0;
    end
  endtask

  task automatic idle_cycle;
    begin
      @(posedge clk_i); #1;
    end
  endtask

  initial begin
    logic [31:0] old_cycle;

    clear_inputs();
    repeat (2) @(posedge clk_i);
    @(negedge clk_i);
    rst_i = 1'b0;
    @(posedge clk_i); #1;

    if (mtvec_o !== RESET_MTVEC_VALUE || mstatus_o !== 32'b0 ||
        exception_vector_o !== RESET_MTVEC_VALUE)
      $fatal(1, "CSR reset state mismatch");

    csr_cycle(CSR_RW, CSR_MTVEC, 32'h8000_0123, '0, RESET_MTVEC_VALUE, 1'b0);
    if (mtvec_o !== 32'h8000_0120)
      $fatal(1, "mtvec alignment/write failed");

    csr_cycle(CSR_RS, CSR_MTVEC, 32'b0, '0, 32'h8000_0120, 1'b0);
    if (mtvec_o !== 32'h8000_0120)
      $fatal(1, "CSRRS zero incorrectly wrote mtvec");

    csr_cycle(CSR_RW, CSR_MSTATUS, 32'hffff_ffff, '0, 32'b0, 1'b0);
    if (mstatus_o !== mstatus_value(1'b1, 1'b1, 2'b11))
      $fatal(1, "mstatus mask failed: %h", mstatus_o);

    csr_cycle(CSR_RC, CSR_MSTATUS, 32'h0000_0008, '0,
              mstatus_value(1'b1, 1'b1, 2'b11), 1'b0);
    if (mstatus_o !== mstatus_value(1'b0, 1'b1, 2'b11))
      $fatal(1, "mstatus clear failed: %h", mstatus_o);

    csr_cycle(CSR_RWI, CSR_MSCRATCH, '0, 5'd5, 32'b0, 1'b0);
    csr_cycle(CSR_RSI, CSR_MSCRATCH, '0, 5'd2, 32'd5, 1'b0);
    csr_cycle(CSR_RS, CSR_MSCRATCH, 32'b0, '0, 32'd7, 1'b0);

    csr_cycle(CSR_RS, CSR_MHARTID, 32'b0, '0, HART_ID_VALUE, 1'b0);
    csr_cycle(CSR_RW, CSR_MHARTID, 32'hdead_beef, '0, HART_ID_VALUE, 1'b1);
    csr_cycle(CSR_RW, 12'h7c0, 32'h1, '0, 32'b0, 1'b1);

    csr_cycle(CSR_RW, CSR_MINSTRET, 32'd10, '0, 32'b0, 1'b0);
    @(negedge clk_i);
    retire_valid_i = 1'b1;
    retire_count_i = 2'd2;
    @(posedge clk_i); #1;
    retire_valid_i = 1'b0;
    retire_count_i = '0;
    csr_cycle(CSR_RS, CSR_MINSTRET, 32'b0, '0, 32'd12, 1'b0);

    @(negedge clk_i);
    csr_valid_i = 1'b1;
    csr_op_i = CSR_RS;
    csr_addr_i = CSR_MCYCLE;
    csr_rs1_value_i = '0;
    #1;
    if (csr_illegal_o)
      $fatal(1, "mcycle read unexpectedly illegal");
    old_cycle = csr_rdata_o;
    @(posedge clk_i); #1;
    csr_valid_i = 1'b0;
    csr_addr_i = '0;
    idle_cycle();
    @(negedge clk_i);
    csr_valid_i = 1'b1;
    csr_op_i = CSR_RS;
    csr_addr_i = CSR_MCYCLE;
    csr_rs1_value_i = '0;
    #1;
    if (csr_rdata_o === old_cycle)
      $fatal(1, "mcycle did not advance");
    @(posedge clk_i); #1;
    csr_valid_i = 1'b0;
    csr_addr_i = '0;

    csr_cycle(CSR_RW, CSR_MSTATUS, 32'h0000_0008, '0, mstatus_o, 1'b0);
    @(negedge clk_i);
    exception_valid_i = 1'b1;
    exception_pc_i = 32'h8000_0204;
    exception_cause_i = 4'd11;
    exception_tval_i = 32'hbad0_1234;
    @(posedge clk_i); #1;
    exception_valid_i = 1'b0;
    if (mepc_o !== 32'h8000_0204 || mcause_o !== 32'd11 ||
        mtval_o !== 32'hbad0_1234 || exception_vector_o !== 32'h8000_0120)
      $fatal(1, "exception CSR update failed");
    if (mstatus_o !== mstatus_value(1'b0, 1'b1, 2'b11))
      $fatal(1, "exception mstatus update failed: %h", mstatus_o);

    @(negedge clk_i);
    mret_valid_i = 1'b1;
    @(posedge clk_i); #1;
    mret_valid_i = 1'b0;
    if (mret_vector_o !== 32'h8000_0204 ||
        mstatus_o !== mstatus_value(1'b1, 1'b1, 2'b00))
      $fatal(1, "mret CSR update failed: vector=%h mstatus=%h",
             mret_vector_o, mstatus_o);

    $display("PASS: csr_file directed tests");
    $finish;
  end

  initial begin
    #200000;
    $fatal(1, "timeout");
  end
endmodule
