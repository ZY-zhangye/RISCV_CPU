`timescale 1ns/1ps

import core_types_pkg::*;

module tb_commit_csr_cluster;
  localparam logic [31:0] RESET_MTVEC_VALUE = 32'h8000_0100;

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
  logic store_commit_valid_o;
  logic [SQ_ID_W-1:0] store_commit_sq_id_o;
  logic store_commit_ready_i = 1'b0;
  logic store_commit_done_i = 1'b0;
  logic csr_wb_valid_o;
  logic [PRD_W-1:0] csr_wb_prd_o;
  logic [XLEN-1:0] csr_wb_data_o;
  recovery_t recovery_o;
  logic [1:0] instret_count_o;
  logic store_pending_o;
  logic [XLEN-1:0] mstatus_o;
  logic [XLEN-1:0] mtvec_o;
  logic [XLEN-1:0] mepc_o;
  logic [XLEN-1:0] mcause_o;
  logic [XLEN-1:0] mtval_o;

  commit_csr_cluster #(
      .RESET_MTVEC(RESET_MTVEC_VALUE)
  ) dut (.*);

  always #5 clk_i = ~clk_i;

  function automatic rob_entry_t make_normal(
      input logic [4:0] rd,
      input logic [PRD_W-1:0] new_prd,
      input logic [PRD_W-1:0] old_prd,
      input logic [31:0] pc
  );
    rob_entry_t entry;
    begin
      entry = '0;
      entry.valid = 1'b1;
      entry.complete = 1'b1;
      entry.entry.arch_rd = rd;
      entry.entry.new_prd = new_prd;
      entry.entry.old_prd = old_prd;
      entry.entry.write_rd = (rd != 0);
      entry.entry.pc = pc;
      make_normal = entry;
    end
  endfunction

  function automatic rob_entry_t make_csr(
      input csr_op_t op,
      input logic [11:0] addr,
      input logic [31:0] operand,
      input logic [4:0] rd,
      input logic [31:0] pc,
      input logic [31:0] inst
  );
    rob_entry_t entry;
    begin
      entry = make_normal(rd, 6'd40, 6'd5, pc);
      entry.entry.serializing = 1'b1;
      entry.entry.is_csr = 1'b1;
      entry.entry.csr_op = op;
      entry.entry.csr_addr = addr;
      entry.entry.csr_operand = operand;
      entry.entry.inst = inst;
      make_csr = entry;
    end
  endfunction

  task automatic clear_heads;
    begin
      rob_head_valid_i = '0;
      rob_head0_i = '0;
      rob_head1_i = '0;
    end
  endtask

  initial begin
    rob_entry_t special;

    repeat (2) @(posedge clk_i);
    @(negedge clk_i);
    rst_i = 1'b0;
    @(posedge clk_i); #1;
    if (mtvec_o != RESET_MTVEC_VALUE || retire_count_o != 0)
      $fatal(1, "commit CSR cluster reset mismatch");

    // Ordinary instructions retain the existing dual-retire path.
    @(negedge clk_i);
    rob_head_valid_i = 2'b11;
    rob_head0_i = make_normal(5'd1, 6'd32, 6'd1, 32'h8000_0000);
    rob_head1_i = make_normal(5'd2, 6'd33, 6'd2, 32'h8000_0004);
    #1;
    if (retire_count_o != 2 || !commit_map0_o.valid ||
        !commit_map1_o.valid || reclaim_valid_o != 2'b11)
      $fatal(1, "ordinary dual commit path changed");
    @(posedge clk_i); #1;
    clear_heads();

    // CSRRW commits atomically, writes old CSR value to PRD, and updates AMT.
    @(negedge clk_i);
    rob_head_valid_i = 2'b01;
    rob_head0_i = make_csr(CSR_RW, 12'h300, 32'h0000_0008, 5'd5,
                           32'h8000_0100, 32'h3002_9073);
    #1;
    if (retire_count_o != 1 || !csr_wb_valid_o ||
        csr_wb_prd_o != 6'd40 || csr_wb_data_o != 0 ||
        !commit_map0_o.valid || commit_map0_o.arch_rd != 5'd5 ||
        reclaim_valid_o != 2'b01 || recovery_o.valid)
      $fatal(1, "legal CSR commit mismatch");
    @(posedge clk_i); #1;
    clear_heads();
    if (!mstatus_o[3])
      $fatal(1, "legal CSR did not update mstatus");

    // Unknown CSR becomes a precise illegal-instruction exception.
    @(negedge clk_i);
    rob_head_valid_i = 2'b01;
    rob_head0_i = make_csr(CSR_RW, 12'h7c0, 32'h1, 5'd6,
                           32'h8000_0200, 32'h7c00_9173);
    #1;
    if (retire_count_o != 0 || csr_wb_valid_o ||
        !recovery_o.valid || recovery_o.cause != REC_EXCEPT ||
        recovery_o.redirect_pc != RESET_MTVEC_VALUE)
      $fatal(1, "illegal CSR recovery mismatch");
    @(posedge clk_i); #1;
    clear_heads();
    if (mepc_o != 32'h8000_0200 || mcause_o != 32'd2 ||
        mtval_o != 32'h7c00_9173)
      $fatal(1, "illegal CSR exception state mismatch");

    // MRET retires alone, restores mstatus, and redirects to mepc.
    @(negedge clk_i);
    special = make_normal(0, 0, 0, 32'h8000_0300);
    special.entry.serializing = 1'b1;
    special.entry.is_mret = 1'b1;
    rob_head_valid_i = 2'b01;
    rob_head0_i = special;
    #1;
    if (retire_count_o != 1 || !recovery_o.valid ||
        recovery_o.redirect_pc != 32'h8000_0200)
      $fatal(1, "MRET commit mismatch");
    @(posedge clk_i); #1;
    clear_heads();
    if (!mstatus_o[3])
      $fatal(1, "MRET did not restore MIE");

    // ECALL traps without retiring.
    @(negedge clk_i);
    special = make_normal(0, 0, 0, 32'h8000_0400);
    special.entry.serializing = 1'b1;
    special.entry.is_ecall = 1'b1;
    rob_head_valid_i = 2'b01;
    rob_head0_i = special;
    #1;
    if (retire_count_o != 0 || !recovery_o.valid || csr_wb_valid_o)
      $fatal(1, "ECALL commit mismatch");
    @(posedge clk_i); #1;
    clear_heads();
    if (mepc_o != 32'h8000_0400 || mcause_o != 32'd11 || mtval_o != 0)
      $fatal(1, "ECALL exception state mismatch");

    // FENCE is serializing but retires without CSR or recovery side effects.
    @(negedge clk_i);
    special = make_normal(0, 0, 0, 32'h8000_0500);
    special.entry.serializing = 1'b1;
    special.entry.is_fence = 1'b1;
    rob_head_valid_i = 2'b01;
    rob_head0_i = special;
    #1;
    if (retire_count_o != 1 || recovery_o.valid || csr_wb_valid_o)
      $fatal(1, "FENCE commit mismatch");
    @(posedge clk_i); #1;
    clear_heads();

    $display("PASS: commit_csr_cluster directed tests");
    $finish;
  end

  initial begin
    #200000;
    $fatal(1, "timeout");
  end
endmodule
