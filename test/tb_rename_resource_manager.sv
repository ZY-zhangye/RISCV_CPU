`timescale 1ns/1ps

import core_types_pkg::*;

module tb_rename_resource_manager;
  logic clk_i = 1'b0;
  logic rst_i = 1'b1;

  alloc_req_t alloc_req_i = '0;
  alloc_resp_t alloc_resp_o;
  logic alloc_commit_ready_o;
  logic alloc_fire_i = 1'b0;
  logic alloc_cancel_i = 1'b0;

  logic [1:0] free_alloc_count_o;
  logic free_alloc_valid_i = 1'b0;
  logic [PRD_W-1:0] free_alloc_prd0_i = 6'd40;
  logic [PRD_W-1:0] free_alloc_prd1_i = 6'd42;
  logic free_alloc_fire_o;
  logic free_alloc_cancel_o;

  logic [1:0] lsq_alloc_lq_count_o;
  logic [1:0] lsq_alloc_sq_count_o;
  logic lsq_alloc_valid_i = 1'b0;
  logic [1:0][LQ_ID_W-1:0] lsq_alloc_lq_id_i = '{3'd2, 3'd1};
  logic [1:0][SQ_ID_W-1:0] lsq_alloc_sq_id_i = '{3'd4, 3'd3};
  logic lsq_alloc_fire_o;
  logic lsq_alloc_cancel_o;

  logic checkpoint_alloc_req_o;
  logic checkpoint_alloc_valid_i = 1'b0;
  logic [CP_W-1:0] checkpoint_alloc_id_i = 2'd2;
  logic checkpoint_alloc_fire_o;
  logic checkpoint_alloc_cancel_o;

  logic rob_alloc_ready_i = 1'b0;
  logic [ROB_ID_W-1:0] rob_alloc_id0_i = 5'd8;
  logic [ROB_ID_W-1:0] rob_alloc_id1_i = 5'd9;
  logic [1:0] rob_alloc_valid_o;
  logic busy_o;

  rename_resource_manager dut (.*);

  always #5 clk_i = ~clk_i;

  task automatic clear_inputs;
    begin
      alloc_req_i = '0;
      alloc_fire_i = 1'b0;
      alloc_cancel_i = 1'b0;
      free_alloc_valid_i = 1'b0;
      lsq_alloc_valid_i = 1'b0;
      checkpoint_alloc_valid_i = 1'b0;
      rob_alloc_ready_i = 1'b0;
    end
  endtask

  task automatic start_request(input alloc_req_t request);
    begin
      @(negedge clk_i);
      alloc_req_i = request;
      @(posedge clk_i); #1;
      if (!busy_o)
        $fatal(1, "resource request was not captured");
    end
  endtask

  initial begin
    alloc_req_t request;

    clear_inputs();
    repeat (2) @(posedge clk_i);
    @(negedge clk_i);
    rst_i = 1'b0;

    // Dual request: lane0 needs PRD+LQ, lane1 needs PRD+SQ+checkpoint.
    request = '0;
    request.valid = 1'b1;
    request.lane_valid = 2'b11;
    request.need_prd = 2'b11;
    request.need_lq = 2'b01;
    request.need_sq = 2'b10;
    request.need_checkpoint = 2'b10;
    start_request(request);

    if (free_alloc_count_o != 2 || lsq_alloc_lq_count_o != 1 ||
        lsq_alloc_sq_count_o != 1 || !checkpoint_alloc_req_o)
      $fatal(1, "suballocator request counts mismatch");

    // Reservations arrive on different cycles; no partial response is legal.
    @(negedge clk_i);
    free_alloc_valid_i = 1'b1;
    rob_alloc_ready_i = 1'b1;
    #1;
    if (alloc_resp_o.valid)
      $fatal(1, "response escaped before LSQ/checkpoint reservation");

    @(negedge clk_i);
    lsq_alloc_valid_i = 1'b1;
    checkpoint_alloc_valid_i = 1'b1;
    #1;
    if (!alloc_resp_o.valid || alloc_resp_o.lane_valid != 2'b11 ||
        alloc_resp_o.prd[0] != 6'd40 || alloc_resp_o.prd[1] != 6'd42 ||
        alloc_resp_o.lq_id[0] != 3'd1 || alloc_resp_o.sq_id[1] != 3'd3 ||
        alloc_resp_o.rob_id[0] != 5'd8 || alloc_resp_o.rob_id[1] != 5'd9 ||
        alloc_resp_o.checkpoint_id != 2'd2 || !alloc_resp_o.bank_same)
      $fatal(1, "atomic allocation response mismatch");

    @(posedge clk_i); #1;
    alloc_req_i = '0;
    if (alloc_resp_o.valid || !busy_o || !alloc_commit_ready_o)
      $fatal(1, "manager did not hold accepted response until fire");

    // A temporary ROB scan stalls final fire without losing reservations.
    rob_alloc_ready_i = 1'b0;
    #1;
    if (alloc_commit_ready_o || free_alloc_fire_o || lsq_alloc_fire_o ||
        checkpoint_alloc_fire_o || rob_alloc_valid_o != 0)
      $fatal(1, "ROB busy did not block final allocation commit");
    rob_alloc_ready_i = 1'b1;
    #1;
    if (!alloc_commit_ready_o)
      $fatal(1, "allocation commit did not resume with ROB ready");

    @(negedge clk_i);
    alloc_fire_i = 1'b1;
    #1;
    if (!free_alloc_fire_o || !lsq_alloc_fire_o ||
        !checkpoint_alloc_fire_o || rob_alloc_valid_o != 2'b11)
      $fatal(1, "atomic resource fire mismatch");
    @(posedge clk_i); #1;
    alloc_fire_i = 1'b0;
    if (busy_o)
      $fatal(1, "manager did not return idle after fire");

    // Compact PRD IDs scatter to lane1 when lane0 has no destination.
    request = '0;
    request.valid = 1'b1;
    request.lane_valid = 2'b11;
    request.need_prd = 2'b10;
    start_request(request);
    free_alloc_valid_i = 1'b1;
    rob_alloc_ready_i = 1'b1;
    #1;
    if (!alloc_resp_o.valid || alloc_resp_o.prd[0] != 0 ||
        alloc_resp_o.prd[1] != 6'd40 || free_alloc_count_o != 1)
      $fatal(1, "compact PRD scatter mismatch");
    @(posedge clk_i); #1;
    alloc_req_i = '0;
    if (!alloc_commit_ready_o)
      $fatal(1, "compact allocation was not ready to commit");
    @(negedge clk_i);
    alloc_cancel_i = 1'b1;
    #1;
    if (!free_alloc_cancel_o || lsq_alloc_cancel_o ||
        checkpoint_alloc_cancel_o || rob_alloc_valid_o != 0)
      $fatal(1, "accepted transaction cancel mismatch");
    @(posedge clk_i); #1;
    alloc_cancel_i = 1'b0;

    // A flush before reservations complete cancels participating allocators.
    free_alloc_valid_i = 1'b0;
    rob_alloc_ready_i = 1'b0;
    request = '0;
    request.valid = 1'b1;
    request.lane_valid = 2'b01;
    request.need_lq = 2'b01;
    start_request(request);
    @(negedge clk_i);
    alloc_req_i = '0;
    #1;
    if (!lsq_alloc_cancel_o || free_alloc_cancel_o ||
        checkpoint_alloc_cancel_o)
      $fatal(1, "reservation-stage cancel mismatch");
    @(posedge clk_i); #1;
    if (busy_o)
      $fatal(1, "manager did not return idle after reservation cancel");

    // A ROB-only instruction does not wait for unused suballocators.
    request = '0;
    request.valid = 1'b1;
    request.lane_valid = 2'b01;
    start_request(request);
    rob_alloc_ready_i = 1'b1;
    #1;
    if (!alloc_resp_o.valid || free_alloc_count_o != 0 ||
        lsq_alloc_lq_count_o != 0 || lsq_alloc_sq_count_o != 0 ||
        checkpoint_alloc_req_o)
      $fatal(1, "ROB-only allocation response mismatch");
    @(posedge clk_i); #1;
    alloc_req_i = '0;
    if (!alloc_commit_ready_o)
      $fatal(1, "ROB-only allocation was not ready to commit");
    @(negedge clk_i);
    alloc_fire_i = 1'b1;
    #1;
    if (rob_alloc_valid_o != 2'b01 || free_alloc_fire_o ||
        lsq_alloc_fire_o || checkpoint_alloc_fire_o)
      $fatal(1, "ROB-only fire mismatch");
    @(posedge clk_i); #1;
    alloc_fire_i = 1'b0;

    $display("PASS: rename_resource_manager directed tests");
    $finish;
  end

  initial begin
    #200000;
    $fatal(1, "timeout");
  end
endmodule
