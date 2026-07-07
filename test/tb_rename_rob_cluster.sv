`timescale 1ns/1ps

import core_types_pkg::*;

module tb_rename_rob_cluster;
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

  commit_map_t commit_map0_i = '0;
  commit_map_t commit_map1_i = '0;
  logic [1:0] reclaim_valid_i = '0;
  logic [PRD_W-1:0] reclaim_prd0_i = '0;
  logic [PRD_W-1:0] reclaim_prd1_i = '0;
  logic reclaim_ready_o;
  logic [1:0] wb_ready_valid_i = '0;
  logic [PRD_W-1:0] wb_ready_prd0_i = '0;
  logic [PRD_W-1:0] wb_ready_prd1_i = '0;
  completion_t complete0_i = '0;
  completion_t complete1_i = '0;
  logic [1:0] lq_release_valid_i = '0;
  logic [1:0][LQ_ID_W-1:0] lq_release_id_i = '0;
  logic [1:0] sq_release_valid_i = '0;
  logic [1:0][SQ_ID_W-1:0] sq_release_id_i = '0;

  logic [1:0] rob_head_valid_o;
  rob_entry_t rob_head0_o;
  rob_entry_t rob_head1_o;
  logic [1:0] retire_count_i = '0;
  logic checkpoint_clear_i = 1'b0;
  logic [CP_W-1:0] checkpoint_clear_id_i = '0;
  logic rob_branch_clear_done_o;
  recovery_t recovery_i = '0;
  logic branch_recovery_complete_i = 1'b0;
  logic [3:0] recovery_done_o;

  logic [5:0] rob_occupancy_o;
  logic rob_empty_o;
  logic rob_full_o;
  logic [6:0] free_prd_count_o;
  logic [3:0] free_lq_count_o;
  logic [3:0] free_sq_count_o;
  logic [$clog2(CHECKPOINTS+1)-1:0] active_checkpoint_count_o;
  logic busy_o;
  logic rob_busy_o;

  rename_rob_cluster dut (.*);

  always #5 clk_i = ~clk_i;

  function automatic decoded_uop_t make_uop(
      input logic [31:0] pc,
      input fu_t fu,
      input logic [4:0] rd,
      input logic serializing
  );
    decoded_uop_t uop;
    begin
      uop = '0;
      uop.pc = pc;
      uop.fu_type = fu;
      uop.rd = rd;
      uop.write_rd = (rd != 0);
      uop.serializing = serializing;
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
        if (cycles > 20)
          $fatal(1, "rename/ROB dispatch timeout");
      end
      uop0 = dispatch_uop0_o;
      uop1 = dispatch_uop1_o;
      @(posedge clk_i); #1;
    end
  endtask

  task automatic wait_recovery_done;
    integer cycles;
    begin
      cycles = 0;
      while (recovery_done_o != 4'b1111) begin
        @(posedge clk_i); #1;
        cycles = cycles + 1;
        if (cycles > 48)
          $fatal(1, "rename/ROB recovery ack timeout: %b", recovery_done_o);
      end
    end
  endtask

  initial begin
    renamed_uop_t first0;
    renamed_uop_t first1;
    renamed_uop_t branch0;
    renamed_uop_t branch1;
    renamed_uop_t younger0;
    renamed_uop_t younger1;
    logic [CP_W-1:0] branch_checkpoint;

    repeat (2) @(posedge clk_i);
    @(negedge clk_i);
    rst_i = 1'b0;
    @(posedge clk_i); #1;
    if (!rob_empty_o || rob_occupancy_o != 0 || free_prd_count_o != 32)
      $fatal(1, "rename/ROB cluster reset mismatch");

    // Decode through Rename and atomically allocate PRDs plus one ROB row.
    send_decode(2'b11,
                make_uop(32'h8000_0000, FU_INT, 5'd5, 1'b0),
                make_uop(32'h8000_0004, FU_INT, 5'd6, 1'b0));
    wait_dispatch(first0, first1);
    if (first0.rob_id != 0 || first1.rob_id != 1 ||
        first0.prd == 0 || first1.prd == 0 || first0.prd == first1.prd ||
        rob_occupancy_o != 2)
      $fatal(1, "initial Rename/ROB allocation mismatch");
    @(posedge clk_i); #1;
    if (rob_head_valid_o != 2'b11)
      $fatal(1, "ROB head refill after initial allocation mismatch");
    if (rob_head0_o.entry.pc != 32'h8000_0000 ||
        rob_head1_o.entry.pc != 32'h8000_0004 ||
        rob_head0_o.entry.new_prd != first0.prd ||
        rob_head1_o.entry.new_prd != first1.prd)
      $fatal(1, "ROB entry builder mismatch");

    @(negedge clk_i);
    complete0_i = make_completion(first0.rob_id);
    complete1_i = make_completion(first1.rob_id);
    @(posedge clk_i); #1;
    complete0_i = '0;
    complete1_i = '0;
    if (!rob_head0_o.complete || !rob_head1_o.complete)
      $fatal(1, "ROB completion path mismatch");
    @(negedge clk_i);
    retire_count_i = 2'd2;
    @(posedge clk_i); #1;
    retire_count_i = '0;
    if (!rob_empty_o || rob_occupancy_o != 0)
      $fatal(1, "ROB retirement path mismatch");

    // Lane1 branch creates a checkpoint; a younger row is then rolled back.
    send_decode(2'b11,
                make_uop(32'h8000_0010, FU_INT, 5'd0, 1'b0),
                make_uop(32'h8000_0014, FU_BRANCH, 5'd0, 1'b0));
    wait_dispatch(branch0, branch1);
    branch_checkpoint = branch1.checkpoint_id;
    if (active_checkpoint_count_o != 1 || rob_occupancy_o != 2)
      $fatal(1, "branch checkpoint allocation mismatch");

    send_decode(2'b11,
                make_uop(32'h8000_0020, FU_INT, 5'd0, 1'b0),
                make_uop(32'h8000_0024, FU_INT, 5'd0, 1'b0));
    wait_dispatch(younger0, younger1);
    if (rob_occupancy_o != 4)
      $fatal(1, "younger ROB allocation mismatch");

    @(negedge clk_i);
    recovery_i.valid = 1'b1;
    recovery_i.cause = REC_BRANCH;
    recovery_i.checkpoint_id = branch_checkpoint;
    recovery_i.redirect_pc = 32'h8000_0100;
    @(posedge clk_i); #1;
    recovery_i = '0;
    wait_recovery_done();
    if (rob_occupancy_o != 2 || rob_head0_o.entry.pc != 32'h8000_0010 ||
        rob_head1_o.entry.pc != 32'h8000_0014)
      $fatal(1, "branch recovery did not retain checkpoint row");

    @(negedge clk_i);
    branch_recovery_complete_i = 1'b1;
    @(posedge clk_i); #1;
    branch_recovery_complete_i = 1'b0;
    if (active_checkpoint_count_o != 0)
      $fatal(1, "checkpoint did not release after recovery completion");

    // Exception recovery aggregates immediate ROB/LSQ done with the 16-cycle
    // RAT and Free List rebuild pulses into one sticky done vector.
    @(negedge clk_i);
    recovery_i.valid = 1'b1;
    recovery_i.cause = REC_EXCEPT;
    recovery_i.redirect_pc = 32'h8000_0200;
    @(posedge clk_i); #1;
    recovery_i = '0;
    wait_recovery_done();
    if (!rob_empty_o || rob_occupancy_o != 0 || free_prd_count_o != 32 ||
        free_lq_count_o != 8 || free_sq_count_o != 8)
      $fatal(1, "exception recovery cluster state mismatch");

    $display("PASS: rename_rob_cluster directed tests");
    $finish;
  end

  initial begin
    #500000;
    $fatal(1, "timeout");
  end
endmodule
