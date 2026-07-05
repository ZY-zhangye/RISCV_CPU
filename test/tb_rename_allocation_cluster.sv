`timescale 1ns/1ps

import core_types_pkg::*;

module tb_rename_allocation_cluster;
  logic clk_i = 1'b0;
  logic rst_i = 1'b1;

  alloc_req_t alloc_req_i = '0;
  alloc_resp_t alloc_resp_o;
  logic alloc_commit_ready_o;
  logic alloc_fire_i = 1'b0;
  logic alloc_cancel_i = 1'b0;
  logic [1:0] rename_valid_i = '0;
  renamed_uop_t rename_uop0_i = '0;
  renamed_uop_t rename_uop1_i = '0;

  logic rob_alloc_ready_i = 1'b1;
  logic [ROB_ID_W-1:0] rob_alloc_id0_i = '0;
  logic [ROB_ID_W-1:0] rob_alloc_id1_i = 1;
  logic [1:0] rob_alloc_valid_o;

  logic [1:0] reclaim_valid_i = '0;
  logic [PRD_W-1:0] reclaim_prd0_i = '0;
  logic [PRD_W-1:0] reclaim_prd1_i = '0;
  logic reclaim_ready_o;
  logic [1:0] lq_release_valid_i = '0;
  logic [1:0][LQ_ID_W-1:0] lq_release_id_i = '0;
  logic [1:0] sq_release_valid_i = '0;
  logic [1:0][SQ_ID_W-1:0] sq_release_id_i = '0;

  logic checkpoint_clear_i = 1'b0;
  logic [CP_W-1:0] checkpoint_clear_id_i = '0;
  recovery_t recovery_i = '0;
  logic branch_recovery_complete_i = 1'b0;
  logic [PRD_W-1:0] amt_map_i [0:ARCH_REGS-1];

  logic branch_restore_valid_o;
  logic [ROB_ID_W-1:0] branch_restore_rob_tail_o;
  logic free_list_branch_done_o;
  logic lsq_branch_done_o;
  logic free_list_rebuild_done_o;
  logic lsq_exception_done_o;
  logic [6:0] free_prd_count_o;
  logic [3:0] free_lq_count_o;
  logic [3:0] free_sq_count_o;
  logic [$clog2(CHECKPOINTS+1)-1:0] active_checkpoint_count_o;
  logic busy_o;

  rename_allocation_cluster dut (.*);

  always #5 clk_i = ~clk_i;

  function automatic renamed_uop_t make_uop(
      input fu_t fu,
      input logic write_rd,
      input mem_op_t mem_op,
      input logic [ROB_ID_W-1:0] rob_id,
      input logic [CP_W-1:0] checkpoint_id,
      input logic [CHECKPOINTS-1:0] branch_mask
  );
    renamed_uop_t uop;
    begin
      uop = '0;
      uop.dec.fu_type = fu;
      uop.dec.write_rd = write_rd;
      uop.dec.mem_op = mem_op;
      uop.rob_id = rob_id;
      uop.checkpoint_id = checkpoint_id;
      uop.branch_mask = branch_mask;
      make_uop = uop;
    end
  endfunction

  task automatic reserve_bundle(
      input alloc_req_t request,
      input logic [ROB_ID_W-1:0] rob0,
      input logic [ROB_ID_W-1:0] rob1,
      output alloc_resp_t response
  );
    integer cycles;
    begin
      @(negedge clk_i);
      rob_alloc_id0_i = rob0;
      rob_alloc_id1_i = rob1;
      alloc_req_i = request;
      cycles = 0;
      while (!alloc_resp_o.valid) begin
        @(posedge clk_i); #1;
        cycles = cycles + 1;
        if (cycles > 12)
          $fatal(1, "allocation cluster response timeout");
      end
      response = alloc_resp_o;
      @(posedge clk_i); #1;
      alloc_req_i = '0;
      if (!alloc_commit_ready_o)
        $fatal(1, "accepted allocation was not ready to commit");
    end
  endtask

  task automatic fire_bundle(
      input logic [1:0] valid,
      input renamed_uop_t uop0,
      input renamed_uop_t uop1
  );
    begin
      @(negedge clk_i);
      rename_valid_i = valid;
      rename_uop0_i = uop0;
      rename_uop1_i = uop1;
      alloc_fire_i = 1'b1;
      #1;
      if (rob_alloc_valid_o != valid)
        $fatal(1, "ROB allocation fire mismatch");
      @(posedge clk_i); #1;
      alloc_fire_i = 1'b0;
      rename_valid_i = '0;
      rename_uop0_i = '0;
      rename_uop1_i = '0;
    end
  endtask

  initial begin
    alloc_req_t request;
    alloc_resp_t response;
    renamed_uop_t uop0;
    renamed_uop_t uop1;
    logic free_done_seen;
    logic lsq_done_seen;
    integer cycles;

    for (int idx = 0; idx < ARCH_REGS; idx = idx + 1)
      amt_map_i[idx] = PRD_W'(idx);

    repeat (2) @(posedge clk_i);
    @(negedge clk_i);
    rst_i = 1'b0;
    @(posedge clk_i); #1;
    if (free_prd_count_o != 7'd32 || free_lq_count_o != 4'd8 ||
        free_sq_count_o != 4'd8 || active_checkpoint_count_o != 0)
      $fatal(1, "allocation cluster reset mismatch");

    // Lane0 writes a PRD; lane1 is an integer branch with no LSQ allocation.
    request = '0;
    request.valid = 1'b1;
    request.lane_valid = 2'b11;
    request.need_prd = 2'b01;
    request.need_checkpoint = 2'b10;
    reserve_bundle(request, 5'd0, 5'd1, response);
    uop0 = make_uop(FU_INT, 1'b1, MEM_LW, response.rob_id[0], '0, '0);
    uop0.prd = response.prd[0];
    uop1 = make_uop(FU_BRANCH, 1'b0, MEM_LW, response.rob_id[1],
                    response.checkpoint_id, '0);
    fire_bundle(2'b11, uop0, uop1);
    if (free_prd_count_o != 7'd31 || free_lq_count_o != 4'd8 ||
        free_sq_count_o != 4'd8 || active_checkpoint_count_o != 1)
      $fatal(1, "branch bundle allocation mismatch");

    // Younger load/store entries must be rolled back to the branch's zero-LSQ
    // checkpoint while the older PRD allocation remains consumed.
    request = '0;
    request.valid = 1'b1;
    request.lane_valid = 2'b11;
    request.need_lq = 2'b01;
    request.need_sq = 2'b10;
    reserve_bundle(request, 5'd2, 5'd3, response);
    uop0 = make_uop(FU_LSU, 1'b0, MEM_LW, response.rob_id[0], '0, 4'b0001);
    uop1 = make_uop(FU_LSU, 1'b0, MEM_SW, response.rob_id[1], '0, 4'b0001);
    fire_bundle(2'b11, uop0, uop1);
    if (free_lq_count_o != 4'd7 || free_sq_count_o != 4'd7)
      $fatal(1, "younger LSQ allocation mismatch");

    @(negedge clk_i);
    recovery_i.valid = 1'b1;
    recovery_i.cause = REC_BRANCH;
    recovery_i.checkpoint_id = 2'd0;
    recovery_i.redirect_pc = 32'h8000_0200;
    #1;
    if (!branch_restore_valid_o || branch_restore_rob_tail_o != 5'd2)
      $fatal(1, "cluster ROB restore tail mismatch");
    @(posedge clk_i); #1;
    recovery_i = '0;
    free_done_seen = free_list_branch_done_o;
    lsq_done_seen = lsq_branch_done_o;
    cycles = 0;
    while (!(free_done_seen && lsq_done_seen)) begin
      @(posedge clk_i); #1;
      free_done_seen |= free_list_branch_done_o;
      lsq_done_seen |= lsq_branch_done_o;
      cycles = cycles + 1;
      if (cycles > 12)
        $fatal(1, "cluster branch rollback timeout");
    end
    if (free_prd_count_o != 7'd31 || free_lq_count_o != 4'd8 ||
        free_sq_count_o != 4'd8 || active_checkpoint_count_o != 1)
      $fatal(1, "cluster branch rollback state mismatch");

    @(negedge clk_i);
    branch_recovery_complete_i = 1'b1;
    @(posedge clk_i); #1;
    branch_recovery_complete_i = 1'b0;
    if (active_checkpoint_count_o != 0 || busy_o)
      $fatal(1, "checkpoint lifetime did not end after recovery acks");

    // Correct resolution releases a checkpoint without a recovery flow.
    request = '0;
    request.valid = 1'b1;
    request.lane_valid = 2'b01;
    request.need_checkpoint = 2'b01;
    reserve_bundle(request, 5'd4, 5'd5, response);
    uop0 = make_uop(FU_BRANCH, 1'b0, MEM_LW, response.rob_id[0],
                    response.checkpoint_id, '0);
    fire_bundle(2'b01, uop0, '0);
    @(negedge clk_i);
    checkpoint_clear_i = 1'b1;
    checkpoint_clear_id_i = response.checkpoint_id;
    @(posedge clk_i); #1;
    checkpoint_clear_i = 1'b0;
    if (active_checkpoint_count_o != 0)
      $fatal(1, "correct branch did not release cluster checkpoint");

    // Exception recovery flushes LSQ/checkpoints and rebuilds the Free List
    // from the committed AMT image.
    request = '0;
    request.valid = 1'b1;
    request.lane_valid = 2'b01;
    request.need_prd = 2'b01;
    request.need_lq = 2'b01;
    reserve_bundle(request, 5'd6, 5'd7, response);
    uop0 = make_uop(FU_LSU, 1'b1, MEM_LW, response.rob_id[0], '0, '0);
    uop0.prd = response.prd[0];
    fire_bundle(2'b01, uop0, '0);
    @(negedge clk_i);
    recovery_i.valid = 1'b1;
    recovery_i.cause = REC_EXCEPT;
    recovery_i.redirect_pc = 32'h8000_0100;
    @(posedge clk_i); #1;
    recovery_i = '0;
    cycles = 0;
    while (!free_list_rebuild_done_o) begin
      @(posedge clk_i); #1;
      cycles = cycles + 1;
      if (cycles > 40)
        $fatal(1, "cluster Free List rebuild timeout");
    end
    if (free_prd_count_o != 7'd32 || free_lq_count_o != 4'd8 ||
        free_sq_count_o != 4'd8 || active_checkpoint_count_o != 0)
      $fatal(1, "cluster exception recovery mismatch");

    $display("PASS: rename_allocation_cluster directed tests");
    $finish;
  end

  initial begin
    #300000;
    $fatal(1, "timeout");
  end
endmodule
