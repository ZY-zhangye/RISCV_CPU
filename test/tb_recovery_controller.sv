`timescale 1ns/1ps

import core_types_pkg::*;

module tb_recovery_controller;
  localparam int ACKS = 3;

  logic clk_i = 1'b0;
  logic rst_i = 1'b1;

  branch_resolve_t branch_i = '0;
  recovery_t commit_recovery_i = '0;
  logic [ACKS-1:0] recovery_done_i = '0;

  recovery_t recovery_o;
  logic redirect_valid_o;
  logic [XLEN-1:0] redirect_pc_o;
  logic checkpoint_clear_valid_o;
  logic [CP_W-1:0] checkpoint_clear_id_o;
  logic busy_o;

  recovery_controller #(.ACKS(ACKS)) dut (.*);

  always #5 clk_i = ~clk_i;

  function automatic branch_resolve_t make_branch(
      input logic mispredict,
      input logic [CP_W-1:0] checkpoint_id,
      input logic [XLEN-1:0] redirect_pc
  );
    branch_resolve_t branch;
    begin
      branch = '0;
      branch.valid = 1'b1;
      branch.mispredict = mispredict;
      branch.checkpoint_id = checkpoint_id;
      branch.redirect_pc = redirect_pc;
      make_branch = branch;
    end
  endfunction

  function automatic recovery_t make_commit_recovery(
      input recovery_cause_t cause,
      input logic [CP_W-1:0] checkpoint_id,
      input logic [XLEN-1:0] redirect_pc
  );
    recovery_t recovery;
    begin
      recovery = '0;
      recovery.valid = 1'b1;
      recovery.cause = cause;
      recovery.checkpoint_id = checkpoint_id;
      recovery.redirect_pc = redirect_pc;
      make_commit_recovery = recovery;
    end
  endfunction

  task automatic clear_inputs;
    begin
      branch_i = '0;
      commit_recovery_i = '0;
      recovery_done_i = '0;
    end
  endtask

  task automatic expect_idle;
    begin
      if (busy_o || recovery_o.valid || redirect_valid_o)
        $fatal(1, "controller not idle");
    end
  endtask

  initial begin
    clear_inputs();
    repeat (2) @(posedge clk_i);
    @(negedge clk_i);
    rst_i = 1'b0;
    @(posedge clk_i); #1;
    expect_idle();

    // Correct branch produces only checkpoint clear, no recovery flow.
    @(negedge clk_i);
    branch_i = make_branch(1'b0, 2'd2, 32'h8000_0100);
    #1;
    if (!checkpoint_clear_valid_o || checkpoint_clear_id_o != 2'd2 || busy_o)
      $fatal(1, "correct branch clear mismatch");
    @(posedge clk_i); #1;
    branch_i = '0;
    expect_idle();

    // Mispredict goes broadcast -> wait ack -> redirect.
    @(negedge clk_i);
    branch_i = make_branch(1'b1, 2'd1, 32'h8000_0200);
    @(posedge clk_i); #1;
    branch_i = '0;
    if (!recovery_o.valid || recovery_o.cause != REC_BRANCH ||
        recovery_o.checkpoint_id != 2'd1 ||
        recovery_o.redirect_pc != 32'h8000_0200 || !busy_o)
      $fatal(1, "branch recovery broadcast mismatch");

    @(posedge clk_i); #1;
    if (recovery_o.valid || redirect_valid_o || !busy_o)
      $fatal(1, "wait-ack state mismatch before done");

    @(negedge clk_i);
    recovery_done_i = 3'b101;
    @(posedge clk_i); #1;
    if (redirect_valid_o)
      $fatal(1, "redirect fired before all acks");

    @(negedge clk_i);
    recovery_done_i = 3'b111;
    @(posedge clk_i); #1;
    if (!redirect_valid_o || redirect_pc_o != 32'h8000_0200 || !busy_o)
      $fatal(1, "redirect pulse mismatch");

    @(posedge clk_i); #1;
    recovery_done_i = '0;
    expect_idle();

    // Commit recovery has priority over simultaneous branch mispredict.
    @(negedge clk_i);
    branch_i = make_branch(1'b1, 2'd3, 32'h8000_0300);
    commit_recovery_i = make_commit_recovery(REC_EXCEPT, 2'd0, 32'h8000_1000);
    @(posedge clk_i); #1;
    branch_i = '0;
    commit_recovery_i = '0;
    if (!recovery_o.valid || recovery_o.cause != REC_EXCEPT ||
        recovery_o.redirect_pc != 32'h8000_1000)
      $fatal(1, "commit recovery priority mismatch");

    @(posedge clk_i); #1;
    @(negedge clk_i);
    branch_i = make_branch(1'b1, 2'd1, 32'hdead_beef);
    commit_recovery_i = make_commit_recovery(REC_EXCEPT, 2'd0, 32'hbad0_bad0);
    recovery_done_i = 3'b111;
    @(posedge clk_i); #1;
    branch_i = '0;
    commit_recovery_i = '0;
    if (!redirect_valid_o || redirect_pc_o != 32'h8000_1000)
      $fatal(1, "busy controller accepted younger request");

    @(posedge clk_i); #1;
    recovery_done_i = '0;
    expect_idle();

    $display("PASS: recovery_controller directed tests");
    $finish;
  end

  initial begin
    #200000;
    $fatal(1, "timeout");
  end
endmodule
