`timescale 1ns/1ps

import core_types_pkg::*;

// csr_file.sv
// Minimal machine-mode CSR state for commit-time CSR execution, precise
// exception entry and MRET return.  Reads are combinational; writes commit on
// the rising edge so commit_unit can use csr_rdata_o as the old architectural
// value to write back to rd.

module csr_file #(
    parameter logic [XLEN-1:0] HART_ID = 32'b0,
    parameter logic [XLEN-1:0] RESET_MTVEC = RESET_PC
) (
    input  logic              clk_i,
    input  logic              rst_i,

    input  logic              csr_valid_i,
    input  logic              csr_commit_i,
    output logic              csr_ready_o,
    input  csr_op_t           csr_op_i,
    input  logic [11:0]       csr_addr_i,
    input  logic [XLEN-1:0]   csr_rs1_value_i,
    input  logic [4:0]        csr_zimm_i,
    output logic              csr_result_valid_o,
    output logic [XLEN-1:0]   csr_rdata_o,
    output logic              csr_illegal_o,

    input  logic              exception_valid_i,
    input  logic [XLEN-1:0]   exception_pc_i,
    input  logic [3:0]        exception_cause_i,
    input  logic [XLEN-1:0]   exception_tval_i,
    output logic [XLEN-1:0]   exception_vector_o,

    input  logic              mret_valid_i,
    output logic [XLEN-1:0]   mret_vector_o,

    input  logic              retire_valid_i,
    input  logic [1:0]        retire_count_i,

    output logic [XLEN-1:0]   mstatus_o,
    output logic [XLEN-1:0]   mie_o,
    output logic [XLEN-1:0]   mtvec_o,
    output logic [XLEN-1:0]   mepc_o,
    output logic [XLEN-1:0]   mcause_o,
    output logic [XLEN-1:0]   mtval_o
);

  localparam logic [11:0] CSR_MSTATUS  = 12'h300;
  localparam logic [11:0] CSR_MIE      = 12'h304;
  localparam logic [11:0] CSR_MTVEC    = 12'h305;
  localparam logic [11:0] CSR_MSCRATCH = 12'h340;
  localparam logic [11:0] CSR_MEPC     = 12'h341;
  localparam logic [11:0] CSR_MCAUSE   = 12'h342;
  localparam logic [11:0] CSR_MTVAL    = 12'h343;
  localparam logic [11:0] CSR_MIP      = 12'h344;
  localparam logic [11:0] CSR_MCYCLE   = 12'hb00;
  localparam logic [11:0] CSR_MINSTRET = 12'hb02;
  localparam logic [11:0] CSR_MHARTID  = 12'hf14;

  localparam int MSTATUS_MIE  = 3;
  localparam int MSTATUS_MPIE = 7;
  localparam int MSTATUS_MPP_LSB = 11;

  logic [XLEN-1:0] mstatus_q;
  logic [XLEN-1:0] mie_q;
  logic [XLEN-1:0] mtvec_q;
  logic [XLEN-1:0] mscratch_q;
  logic [XLEN-1:0] mepc_q;
  logic [XLEN-1:0] mcause_q;
  logic [XLEN-1:0] mtval_q;
  logic [XLEN-1:0] mip_q;
  logic [XLEN-1:0] mcycle_q;
  logic [XLEN-1:0] minstret_q;

  logic csr_known;
  logic csr_read_only;
  logic csr_write_intent;
  logic csr_write_enable;
  logic [XLEN-1:0] csr_operand;
  logic [XLEN-1:0] csr_new_value;

  function automatic logic [XLEN-1:0] mask_mstatus(
      input logic [XLEN-1:0] value
  );
    begin
      mask_mstatus = '0;
      mask_mstatus[MSTATUS_MIE] = value[MSTATUS_MIE];
      mask_mstatus[MSTATUS_MPIE] = value[MSTATUS_MPIE];
      mask_mstatus[MSTATUS_MPP_LSB +: 2] = value[MSTATUS_MPP_LSB +: 2];
    end
  endfunction

  function automatic logic is_known_csr(input logic [11:0] addr);
    begin
      unique case (addr)
        CSR_MSTATUS, CSR_MIE, CSR_MTVEC, CSR_MSCRATCH,
        CSR_MEPC, CSR_MCAUSE, CSR_MTVAL, CSR_MIP,
        CSR_MCYCLE, CSR_MINSTRET, CSR_MHARTID: is_known_csr = 1'b1;
        default: is_known_csr = 1'b0;
      endcase
    end
  endfunction

  function automatic logic is_read_only_csr(input logic [11:0] addr);
    begin
      is_read_only_csr = (addr == CSR_MHARTID);
    end
  endfunction

  function automatic logic [XLEN-1:0] read_csr(input logic [11:0] addr);
    begin
      unique case (addr)
        CSR_MSTATUS:  read_csr = mstatus_q;
        CSR_MIE:      read_csr = mie_q;
        CSR_MTVEC:    read_csr = mtvec_q;
        CSR_MSCRATCH: read_csr = mscratch_q;
        CSR_MEPC:     read_csr = mepc_q;
        CSR_MCAUSE:   read_csr = mcause_q;
        CSR_MTVAL:    read_csr = mtval_q;
        CSR_MIP:      read_csr = mip_q;
        CSR_MCYCLE:   read_csr = mcycle_q;
        CSR_MINSTRET: read_csr = minstret_q;
        CSR_MHARTID:  read_csr = HART_ID;
        default:      read_csr = '0;
      endcase
    end
  endfunction

  assign csr_ready_o = 1'b1;
  assign csr_known = is_known_csr(csr_addr_i);
  assign csr_read_only = is_read_only_csr(csr_addr_i);
  assign csr_operand = ((csr_op_i == CSR_RWI) ||
                        (csr_op_i == CSR_RSI) ||
                        (csr_op_i == CSR_RCI)) ?
                       {{(XLEN-5){1'b0}}, csr_zimm_i} : csr_rs1_value_i;

  always_comb begin : csr_alu
    unique case (csr_op_i)
      CSR_RW, CSR_RWI: csr_new_value = csr_operand;
      CSR_RS, CSR_RSI: csr_new_value = csr_rdata_o | csr_operand;
      CSR_RC, CSR_RCI: csr_new_value = csr_rdata_o & ~csr_operand;
      default:         csr_new_value = csr_rdata_o;
    endcase
  end

  assign csr_write_intent =
      ((csr_op_i == CSR_RW) || (csr_op_i == CSR_RWI) || (csr_operand != '0));
  assign csr_write_enable = csr_valid_i && csr_commit_i && csr_known &&
                            !csr_read_only && csr_write_intent;
  assign csr_rdata_o = read_csr(csr_addr_i);
  assign csr_illegal_o =
      csr_valid_i && (!csr_known || (csr_read_only && csr_write_intent));
  assign csr_result_valid_o = csr_valid_i && csr_ready_o;

  assign exception_vector_o = {mtvec_q[XLEN-1:2], 2'b00};
  assign mret_vector_o = mepc_q;

  assign mstatus_o = mstatus_q;
  assign mie_o = mie_q;
  assign mtvec_o = mtvec_q;
  assign mepc_o = mepc_q;
  assign mcause_o = mcause_q;
  assign mtval_o = mtval_q;

  always_ff @(posedge clk_i) begin : csr_registers
    logic [XLEN-1:0] mstatus_next;

    if (rst_i) begin
      mstatus_q <= '0;
      mie_q <= '0;
      mtvec_q <= RESET_MTVEC;
      mscratch_q <= '0;
      mepc_q <= '0;
      mcause_q <= '0;
      mtval_q <= '0;
      mip_q <= '0;
      mcycle_q <= '0;
      minstret_q <= '0;
    end else begin
      mcycle_q <= mcycle_q + 32'd1;
      if (retire_valid_i)
        minstret_q <= minstret_q + {{(XLEN-2){1'b0}}, retire_count_i};

      if (exception_valid_i) begin
        mstatus_next = mstatus_q;
        mstatus_next[MSTATUS_MPIE] = mstatus_q[MSTATUS_MIE];
        mstatus_next[MSTATUS_MIE] = 1'b0;
        mstatus_next[MSTATUS_MPP_LSB +: 2] = 2'b11;
        mstatus_q <= mask_mstatus(mstatus_next);
        mepc_q <= exception_pc_i;
        mcause_q <= {{(XLEN-4){1'b0}}, exception_cause_i};
        mtval_q <= exception_tval_i;
      end else if (mret_valid_i) begin
        mstatus_next = mstatus_q;
        mstatus_next[MSTATUS_MIE] = mstatus_q[MSTATUS_MPIE];
        mstatus_next[MSTATUS_MPIE] = 1'b1;
        mstatus_next[MSTATUS_MPP_LSB +: 2] = 2'b00;
        mstatus_q <= mask_mstatus(mstatus_next);
      end else if (csr_write_enable && !csr_illegal_o) begin
        unique case (csr_addr_i)
          CSR_MSTATUS:  mstatus_q <= mask_mstatus(csr_new_value);
          CSR_MIE:      mie_q <= csr_new_value;
          CSR_MTVEC:    mtvec_q <= {csr_new_value[XLEN-1:2], 2'b00};
          CSR_MSCRATCH: mscratch_q <= csr_new_value;
          CSR_MEPC:     mepc_q <= {csr_new_value[XLEN-1:1], 1'b0};
          CSR_MCAUSE:   mcause_q <= csr_new_value;
          CSR_MTVAL:    mtval_q <= csr_new_value;
          CSR_MIP:      mip_q <= csr_new_value;
          CSR_MCYCLE:   mcycle_q <= csr_new_value;
          CSR_MINSTRET: minstret_q <= csr_new_value;
          default: begin
          end
        endcase
      end
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk_i) begin : csr_file_assertions
    if (!rst_i) begin
      if (exception_valid_i && mret_valid_i)
        assert (exception_valid_i)
          else $error("unreachable");

      if (csr_valid_i && csr_read_only && csr_write_intent)
        assert (csr_illegal_o)
          else $error("read-only CSR write was not illegal");
    end
  end
`endif

endmodule
