`timescale 1ns/1ps

import core_types_pkg::*;

module tb_commit_csr_prf_cluster;
  logic clk_i = 1'b0;
  logic rst_i = 1'b1;
  logic [1:0] rob_head_valid_i = '0;
  rob_entry_t rob_head0_i = '0;
  rob_entry_t rob_head1_i = '0;
  logic [1:0] retire_count_o;
  commit_map_t commit_map0_o;
  commit_map_t commit_map1_o;
  logic [1:0] reclaim_valid_o;
  logic [1:0][PRD_W-1:0] reclaim_prd_o;
  logic reclaim_ready_i = 1'b1;
  logic store_commit_valid_o;
  logic [SQ_ID_W-1:0] store_commit_sq_id_o;
  logic store_commit_ready_i = 1'b0;
  logic store_commit_done_i = 1'b0;
  logic [5:0] prf_read_valid_i = '0;
  logic [5:0][PRD_W-1:0] prf_read_prd_i = '0;
  logic [5:0][XLEN-1:0] prf_read_data_o;
  logic [1:0] wb_valid_i = '0;
  logic [1:0][PRD_W-1:0] wb_prd_i = '0;
  logic [1:0][XLEN-1:0] wb_data_i = '0;
  logic [1:0] alloc_clear_valid_i = '0;
  logic [1:0][PRD_W-1:0] alloc_clear_prd_i = '0;
  logic [PHYS_REGS-1:0] prf_ready_bits_o;
  recovery_t recovery_o;
  logic [1:0] instret_count_o;
  logic store_pending_o;
  logic csr_wb_pending_o;
  logic csr_commit_wakeup_valid_o;
  logic [PRD_W-1:0] csr_commit_wakeup_prd_o;
  logic [XLEN-1:0] mstatus_o;
  logic [XLEN-1:0] mtvec_o;
  logic [XLEN-1:0] mepc_o;
  logic [XLEN-1:0] mcause_o;
  logic [XLEN-1:0] mtval_o;
  logic recovery_busy_i = 1'b0;

  commit_csr_prf_cluster dut (.*);

  always #5 clk_i = ~clk_i;

  function automatic rob_entry_t make_csr(
      input logic [PRD_W-1:0] prd,
      input logic [31:0] operand
  );
    rob_entry_t entry;
    begin
      entry = '0;
      entry.valid = 1'b1;
      entry.complete = 1'b1;
      entry.entry.arch_rd = 5'd5;
      entry.entry.new_prd = prd;
      entry.entry.old_prd = 6'd5;
      entry.entry.write_rd = 1'b1;
      entry.entry.serializing = 1'b1;
      entry.entry.is_csr = 1'b1;
      entry.entry.csr_op = CSR_RW;
      entry.entry.csr_addr = 12'h300;
      entry.entry.csr_operand = operand;
      entry.entry.pc = 32'h8000_1000;
      make_csr = entry;
    end
  endfunction

  task automatic clear_inputs;
    begin
      rob_head_valid_i = '0;
      rob_head0_i = '0;
      wb_valid_i = '0;
      wb_prd_i = '0;
      wb_data_i = '0;
      alloc_clear_valid_i = '0;
      alloc_clear_prd_i = '0;
      prf_read_valid_i = '0;
      prf_read_prd_i = '0;
    end
  endtask

  initial begin
    repeat (2) @(posedge clk_i);
    @(negedge clk_i);
    rst_i = 1'b0;

    // Mark both CSR destinations not-ready before their commit writes.
    alloc_clear_valid_i = 2'b11;
    alloc_clear_prd_i[0] = 6'd40;
    alloc_clear_prd_i[1] = 6'd41;
    @(posedge clk_i); #1;
    alloc_clear_valid_i = '0;

    // CSR state commits on the retirement edge; the PRF write is buffered and
    // lands one cycle later to keep ROB head decode off the PRF ready path.
    @(negedge clk_i);
    rob_head_valid_i = 2'b01;
    rob_head0_i = make_csr(6'd40, 32'h0000_0008);
    #1;
    if (retire_count_o != 1 || !commit_map0_o.valid)
      $fatal(1, "idle PRF did not allow CSR retirement");
    @(posedge clk_i); #1;
    clear_inputs();
    if (prf_ready_bits_o[40] || !mstatus_o[3] || !csr_wb_pending_o)
      $fatal(1, "CSR retire did not enter buffered PRF write state");
    @(posedge clk_i); #1;
    if (!prf_ready_bits_o[40] || csr_wb_pending_o)
      $fatal(1, "buffered CSR write did not update PRF");
    @(negedge clk_i);
    prf_read_valid_i[0] = 1'b1;
    prf_read_prd_i[0] = 6'd40;
    @(posedge clk_i); #1;
    if (prf_read_data_o[0] != 0)
      $fatal(1, "first CSR old value was not written to PRF");

    // A normal WB stalls CSR retirement for one cycle, then the CSR write is
    // buffered and preserved after the normal WB.
    @(negedge clk_i);
    clear_inputs();
    wb_valid_i = 2'b01;
    wb_prd_i[0] = 6'd42;
    wb_data_i[0] = 32'hfeed_0042;
    rob_head_valid_i = 2'b01;
    rob_head0_i = make_csr(6'd41, 32'h0000_0000);
    #1;
    if (retire_count_o != 0 || prf_ready_bits_o[41])
      $fatal(1, "normal WB did not backpressure CSR retirement");
    @(posedge clk_i); #1;
    wb_valid_i = '0;
    #1;
    if (retire_count_o != 1)
      $fatal(1, "CSR retirement did not resume after normal WB");
    @(posedge clk_i); #1;
    clear_inputs();
    if (prf_ready_bits_o[41] || !prf_ready_bits_o[42] ||
        mstatus_o[3] || !csr_wb_pending_o)
      $fatal(1, "resumed CSR did not buffer after normal WB");
    @(posedge clk_i); #1;
    if (!prf_ready_bits_o[41] || csr_wb_pending_o)
      $fatal(1, "buffered CSR write after normal WB was lost");
    @(negedge clk_i);
    prf_read_valid_i = 6'b00_0011;
    prf_read_prd_i[0] = 6'd41;
    prf_read_prd_i[1] = 6'd42;
    @(posedge clk_i); #1;
    if (prf_read_data_o[0] != 32'h0000_0008 ||
        prf_read_data_o[1] != 32'hfeed_0042)
      $fatal(1, "integrated CSR/normal PRF write data mismatch");

    $display("PASS: commit_csr_prf_cluster directed tests");
    $finish;
  end

  initial begin
    #100000;
    $fatal(1, "timeout");
  end
endmodule
