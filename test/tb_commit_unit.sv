`timescale 1ns/1ps

import core_types_pkg::*;

module tb_commit_unit;
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

  logic csr_exception_valid_o;
  logic [XLEN-1:0] csr_exception_pc_o;
  logic [3:0] csr_exception_cause_o;
  logic [XLEN-1:0] csr_exception_tval_o;
  logic [XLEN-1:0] csr_exception_vector_i = 32'h8000_0100;

  recovery_t recovery_o;
  logic [1:0] instret_count_o;
  logic store_pending_o;

  commit_unit dut (.*);

  always #5 clk_i = ~clk_i;

  function automatic rob_entry_t make_entry(
      input logic valid,
      input logic complete,
      input logic [4:0] arch_rd,
      input logic [PRD_W-1:0] new_prd,
      input logic [PRD_W-1:0] old_prd
  );
    rob_entry_t entry;
    begin
      entry = '0;
      entry.valid = valid;
      entry.complete = complete;
      entry.entry.arch_rd = arch_rd;
      entry.entry.new_prd = new_prd;
      entry.entry.old_prd = old_prd;
      entry.entry.write_rd = (arch_rd != 0);
      entry.entry.pc = 32'h8000_0000 + {27'b0, arch_rd};
      make_entry = entry;
    end
  endfunction

  task automatic clear_inputs;
    begin
      rob_head_valid_i = '0;
      rob_head0_i = '0;
      rob_head1_i = '0;
      store_commit_ready_i = 1'b0;
      store_commit_done_i = 1'b0;
      csr_exception_vector_i = 32'h8000_0100;
      reclaim_ready_i = 1'b1;
    end
  endtask

  task automatic expect_no_side_effects;
    begin
      if (commit_map0_o.valid || commit_map1_o.valid ||
          reclaim_valid_o != 2'b00 || instret_count_o != 2'd0)
        $fatal(1, "unexpected commit side effects");
    end
  endtask

  initial begin
    clear_inputs();
    repeat (2) @(posedge clk_i);
    @(negedge clk_i);
    rst_i = 1'b0;
    @(posedge clk_i); #1;
    if (retire_count_o != 0 || store_pending_o)
      $fatal(1, "commit_unit reset mismatch");

    // Two ordinary complete instructions retire together.
    @(negedge clk_i);
    rob_head_valid_i = 2'b11;
    rob_head0_i = make_entry(1'b1, 1'b1, 5'd5, 6'd20, 6'd10);
    rob_head1_i = make_entry(1'b1, 1'b1, 5'd6, 6'd21, 6'd11);
    #1;
    if (retire_count_o != 2'd2 || instret_count_o != 2'd2)
      $fatal(1, "dual retire count mismatch");
    if (!commit_map0_o.valid || commit_map0_o.arch_rd != 5'd5 ||
        commit_map0_o.prd != 6'd20 || !commit_map1_o.valid ||
        commit_map1_o.arch_rd != 5'd6 || commit_map1_o.prd != 6'd21 ||
        reclaim_valid_o != 2'b11 || reclaim_prd_o[0] != 6'd10 ||
        reclaim_prd_o[1] != 6'd11)
      $fatal(1, "dual retire map/reclaim mismatch");

    // Reclaim request remains visible, but architectural commit waits for ready.
    reclaim_ready_i = 1'b0;
    #1;
    if (retire_count_o != 0 || commit_map0_o.valid || commit_map1_o.valid ||
        reclaim_valid_o != 2'b11)
      $fatal(1, "reclaim backpressure did not hold dual retirement");
    reclaim_ready_i = 1'b1;

    // Serializing lane0 retires alone even when lane1 is ready.
    rob_head0_i.entry.serializing = 1'b1;
    #1;
    if (retire_count_o != 2'd1 || commit_map1_o.valid || reclaim_valid_o[1])
      $fatal(1, "serializing lane0 did not retire alone");

    // Incomplete lane0 blocks all retirement.
    rob_head0_i = make_entry(1'b1, 1'b0, 5'd7, 6'd22, 6'd12);
    rob_head1_i = make_entry(1'b1, 1'b1, 5'd8, 6'd23, 6'd13);
    #1;
    if (retire_count_o != 0)
      $fatal(1, "incomplete lane0 retired");

    // Lane1 exception is not retired in the same cycle as lane0.
    rob_head0_i = make_entry(1'b1, 1'b1, 5'd9, 6'd24, 6'd14);
    rob_head1_i = make_entry(1'b1, 1'b1, 5'd10, 6'd25, 6'd15);
    rob_head1_i.entry.exception_valid = 1'b1;
    #1;
    if (retire_count_o != 2'd1 || commit_map1_o.valid)
      $fatal(1, "lane1 exception retired with lane0");

    // Lane0 exception produces CSR exception inputs and recovery, no retire.
    rob_head0_i = make_entry(1'b1, 1'b1, 5'd11, 6'd26, 6'd16);
    rob_head0_i.entry.exception_valid = 1'b1;
    rob_head0_i.entry.exception_cause = 4'd2;
    rob_head0_i.entry.exception_tval = 32'hdeed_0002;
    rob_head0_i.entry.pc = 32'h8000_0200;
    rob_head1_i = make_entry(1'b1, 1'b1, 5'd12, 6'd27, 6'd17);
    #1;
    if (retire_count_o != 0 || !csr_exception_valid_o ||
        csr_exception_pc_o != 32'h8000_0200 ||
        csr_exception_cause_o != 4'd2 ||
        csr_exception_tval_o != 32'hdeed_0002 ||
        !recovery_o.valid || recovery_o.cause != REC_EXCEPT ||
        recovery_o.redirect_pc != 32'h8000_0100)
      $fatal(1, "exception recovery output mismatch");
    expect_no_side_effects();

    // Store commit uses two-phase authorization and retires only on done.
    rob_head_valid_i = 2'b01;
    rob_head0_i = make_entry(1'b1, 1'b1, 5'd0, 6'd0, 6'd0);
    rob_head0_i.entry.is_store = 1'b1;
    rob_head0_i.entry.sq_id = 3'd5;
    store_commit_ready_i = 1'b0;
    #1;
    if (!store_commit_valid_o || store_commit_sq_id_o != 3'd5 ||
        retire_count_o != 0 || store_pending_o)
      $fatal(1, "store commit request mismatch before ready");

    store_commit_ready_i = 1'b1;
    @(posedge clk_i); #1;
    store_commit_ready_i = 1'b0;
    if (!store_pending_o || store_commit_valid_o || retire_count_o != 0)
      $fatal(1, "store pending state mismatch after capture");

    @(negedge clk_i);
    store_commit_done_i = 1'b1;
    #1;
    if (retire_count_o != 2'd1 || instret_count_o != 2'd1)
      $fatal(1, "store did not retire on commit done");
    @(posedge clk_i); #1;
    store_commit_done_i = 1'b0;
    if (store_pending_o)
      $fatal(1, "store pending did not clear");

    $display("PASS: commit_unit directed tests");
    $finish;
  end

  initial begin
    #200000;
    $fatal(1, "timeout");
  end
endmodule
