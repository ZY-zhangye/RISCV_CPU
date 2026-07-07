`timescale 1ns/1ps

import core_types_pkg::*;

module tb_commit_recovery_cluster;
  logic clk_i = 1'b0;
  logic rst_i = 1'b1;
  logic [1:0] dec_valid_i = '0;
  logic dec_ready_o;
  decoded_uop_t dec_uop0_i = '0;
  decoded_uop_t dec_uop1_i = '0;
  logic [1:0] dispatch_valid_o;
  logic dispatch_ready_i = 1'b1;
  renamed_uop_t dispatch_uop0_o;
  renamed_uop_t dispatch_uop1_o;
  logic dispatch_fire_o;
  completion_t complete0_i = '0;
  completion_t complete1_i = '0;
  logic [1:0] lq_release_valid_i = '0;
  logic [1:0][LQ_ID_W-1:0] lq_release_id_i = '0;
  logic [1:0] sq_release_valid_i = '0;
  logic [1:0][SQ_ID_W-1:0] sq_release_id_i = '0;
  branch_resolve_t branch_i = '0;
  recovery_t recovery_o;
  logic checkpoint_clear_valid_o;
  logic [CP_W-1:0] checkpoint_clear_id_o;
  logic redirect_valid_o;
  logic [XLEN-1:0] redirect_pc_o;
  logic [5:0] prf_read_valid_i = '0;
  logic [5:0][PRD_W-1:0] prf_read_prd_i = '0;
  logic [5:0][XLEN-1:0] prf_read_data_o;
  logic [1:0] wb_valid_i = '0;
  logic [1:0][PRD_W-1:0] wb_prd_i = '0;
  logic [1:0][XLEN-1:0] wb_data_i = '0;
  logic [PHYS_REGS-1:0] prf_ready_bits_o;
  logic [1:0] wakeup_valid_o;
  logic [1:0][PRD_W-1:0] wakeup_prd_o;
  logic store_commit_valid_o;
  logic [SQ_ID_W-1:0] store_commit_sq_id_o;
  logic store_commit_ready_i = 1'b0;
  logic store_commit_done_i = 1'b0;
  logic [1:0] lq_retire_valid_o;
  logic [1:0][LQ_ID_W-1:0] lq_retire_id_o;
  logic [1:0] retire_count_o;
  logic [5:0] rob_occupancy_o;
  logic rob_empty_o;
  logic rob_full_o;
  logic [6:0] free_prd_count_o;
  logic [3:0] free_lq_count_o;
  logic [3:0] free_sq_count_o;
  logic [$clog2(CHECKPOINTS+1)-1:0] active_checkpoint_count_o;
  logic recovery_busy_o;
  logic busy_o;
  logic [XLEN-1:0] mstatus_o;
  logic [XLEN-1:0] mtvec_o;
  logic [XLEN-1:0] mepc_o;
  logic [XLEN-1:0] mcause_o;
  logic [XLEN-1:0] mtval_o;

  commit_recovery_cluster dut (.*);

  always #5 clk_i = ~clk_i;

  function automatic decoded_uop_t make_uop(
      input logic [31:0] pc,
      input fu_t fu,
      input logic [4:0] rd
  );
    decoded_uop_t uop;
    begin
      uop = '0;
      uop.pc = pc;
      uop.inst = 32'h0000_0013;
      uop.fu_type = fu;
      uop.rd = rd;
      uop.write_rd = (rd != 0);
      make_uop = uop;
    end
  endfunction

  function automatic completion_t make_completion(
      input logic [ROB_ID_W-1:0] rob_id
  );
    completion_t completion;
    begin
      completion = '0;
      completion.valid = 1'b1;
      completion.rob_id = rob_id;
      make_completion = completion;
    end
  endfunction

  task automatic send_decode(
      input logic [1:0] valid,
      input decoded_uop_t uop0,
      input decoded_uop_t uop1
  );
    begin
      while (!dec_ready_o)
        @(negedge clk_i);
      @(negedge clk_i);
      dec_valid_i = valid;
      dec_uop0_i = uop0;
      dec_uop1_i = uop1;
      @(posedge clk_i); #1;
      dec_valid_i = '0;
      dec_uop0_i = '0;
      dec_uop1_i = '0;
    end
  endtask

  task automatic wait_dispatch(
      output renamed_uop_t uop0,
      output renamed_uop_t uop1
  );
    integer cycles;
    begin
      cycles = 0;
      while (!dispatch_fire_o) begin
        @(negedge clk_i); #1;
        cycles = cycles + 1;
        if (cycles > 24)
          $fatal(1, "commit/recovery dispatch timeout");
      end
      uop0 = dispatch_uop0_o;
      uop1 = dispatch_uop1_o;
      @(posedge clk_i); #1;
    end
  endtask

  task automatic pulse_branch(
      input logic [ROB_ID_W-1:0] rob_id,
      input logic [CP_W-1:0] checkpoint_id,
      input logic mispredict,
      input logic [31:0] redirect_pc
  );
    begin
      @(negedge clk_i);
      branch_i = '0;
      branch_i.valid = 1'b1;
      branch_i.rob_id = rob_id;
      branch_i.checkpoint_id = checkpoint_id;
      branch_i.mispredict = mispredict;
      branch_i.redirect_pc = redirect_pc;
      @(posedge clk_i); #1;
      branch_i = '0;
    end
  endtask

  task automatic wait_redirect(input logic [31:0] expected_pc);
    integer cycles;
    integer broadcasts;
    begin
      cycles = 0;
      broadcasts = recovery_o.valid ? 1 : 0;
      while (!redirect_valid_o) begin
        @(posedge clk_i); #1;
        if (recovery_o.valid)
          broadcasts = broadcasts + 1;
        cycles = cycles + 1;
        if (cycles > 80)
          $fatal(1, "commit/recovery redirect timeout");
      end
      if (redirect_pc_o != expected_pc || broadcasts != 1)
        $fatal(1, "redirect mismatch pc=%h broadcasts=%0d",
               redirect_pc_o, broadcasts);
      @(posedge clk_i); #1;
      if (redirect_valid_o || recovery_busy_o)
        $fatal(1, "redirect/recovery busy did not clear");
    end
  endtask

  task automatic complete_pair(
      input logic [ROB_ID_W-1:0] id0,
      input logic [ROB_ID_W-1:0] id1
  );
    begin
      @(negedge clk_i);
      complete0_i = make_completion(id0);
      complete1_i = make_completion(id1);
      @(posedge clk_i); #1;
      complete0_i = '0;
      complete1_i = '0;
    end
  endtask

  initial begin
    renamed_uop_t branch0;
    renamed_uop_t branch1;
    renamed_uop_t younger0;
    renamed_uop_t younger1;
    renamed_uop_t correct0;
    renamed_uop_t unused1;
    renamed_uop_t except0;
    decoded_uop_t exception_uop;

    repeat (2) @(posedge clk_i);
    @(negedge clk_i);
    rst_i = 1'b0;
    @(posedge clk_i); #1;
    if (!rob_empty_o || free_prd_count_o != 32 || recovery_busy_o)
      $fatal(1, "commit/recovery reset mismatch");

    // Lane1 branch owns a checkpoint and two younger entries are allocated.
    send_decode(2'b11,
                make_uop(32'h8000_0000, FU_INT, 0),
                make_uop(32'h8000_0004, FU_BRANCH, 0));
    wait_dispatch(branch0, branch1);
    send_decode(2'b11,
                make_uop(32'h8000_0010, FU_INT, 0),
                make_uop(32'h8000_0014, FU_INT, 0));
    wait_dispatch(younger0, younger1);
    if (rob_occupancy_o != 4 || active_checkpoint_count_o != 1)
      $fatal(1, "branch recovery setup mismatch");

    pulse_branch(branch1.rob_id, branch1.checkpoint_id, 1'b1,
                 32'h8000_0100);
    wait_redirect(32'h8000_0100);
    if (rob_occupancy_o != 2 || active_checkpoint_count_o != 0)
      $fatal(1, "mispredict recovery state mismatch");

    // Surviving row may complete and retire after recovery is fully released.
    complete_pair(branch0.rob_id, branch1.rob_id);
    repeat (2) @(posedge clk_i);
    #1;
    if (!rob_empty_o)
      $fatal(1, "surviving branch row did not retire");

    // Correct resolution clears the checkpoint without a global recovery.
    send_decode(2'b01, make_uop(32'h8000_0200, FU_BRANCH, 0), '0);
    wait_dispatch(correct0, unused1);
    pulse_branch(correct0.rob_id, correct0.checkpoint_id, 1'b0,
                 32'h8000_0204);
    if (recovery_busy_o || redirect_valid_o)
      $fatal(1, "correct branch started global recovery");
    repeat (20) begin
      @(posedge clk_i); #1;
      if (active_checkpoint_count_o == 0)
        break;
    end
    if (active_checkpoint_count_o != 0)
      $fatal(1, "correct branch checkpoint did not clear");
    while (busy_o)
      @(posedge clk_i);
    @(negedge clk_i);
    complete0_i = make_completion(correct0.rob_id);
    @(posedge clk_i); #1;
    complete0_i = '0;
    repeat (2) @(posedge clk_i);
    #1;
    if (!rob_empty_o)
      $fatal(1, "correctly resolved branch did not retire");

    // A decode-time exception is complete on allocation and triggers one
    // precise exception broadcast, full resource rebuild, then mtvec redirect.
    exception_uop = make_uop(32'h8000_0300, FU_NONE, 0);
    exception_uop.exception_valid = 1'b1;
    exception_uop.exception_cause = 4'd2;
    exception_uop.exception_tval = 32'hffff_ffff;
    exception_uop.inst = 32'hffff_ffff;
    send_decode(2'b01, exception_uop, '0);
    wait_dispatch(except0, unused1);
    wait_redirect(RESET_PC);
    if (!rob_empty_o || rob_occupancy_o != 0 ||
        mepc_o != 32'h8000_0300 || mcause_o != 32'd2 ||
        mtval_o != 32'hffff_ffff || free_prd_count_o != 32)
      $fatal(1, "precise exception recovery state mismatch");

    $display("PASS: commit_recovery_cluster directed tests");
    $finish;
  end

  initial begin
    #1000000;
    $fatal(1, "timeout");
  end
endmodule
