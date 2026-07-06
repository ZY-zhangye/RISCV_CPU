`timescale 1ns/1ps

import core_types_pkg::*;

module tb_rename_stage;
  logic clk_i = 1'b0;
  logic rst_i = 1'b1;
  logic [1:0] dec_valid_i = 2'b00;
  logic dec_ready_o;
  decoded_uop_t dec_uop0_i = '0;
  decoded_uop_t dec_uop1_i = '0;
  logic [1:0] rn_valid_o;
  logic rn_ready_i = 1'b0;
  renamed_uop_t rn_uop0_o;
  renamed_uop_t rn_uop1_o;
  alloc_req_t alloc_req_o;
  alloc_resp_t alloc_resp_i = '0;
  logic alloc_fire_o;
  logic alloc_cancel_o;
  commit_map_t commit_map0_i = '0;
  commit_map_t commit_map1_i = '0;
  logic [1:0] wb_ready_valid_i = 2'b00;
  logic [PRD_W-1:0] wb_ready_prd0_i = '0;
  logic [PRD_W-1:0] wb_ready_prd1_i = '0;
  logic [PRD_W-1:0] amt_map_o [0:ARCH_REGS-1];
  logic checkpoint_clear_i = 1'b0;
  logic [CP_W-1:0] checkpoint_clear_id_i = '0;
  recovery_t recovery_i = '0;
  logic recovery_done_o;

  rename_stage dut (.*);

  always #5 clk_i = ~clk_i;

  function automatic decoded_uop_t make_int(
      input logic [4:0] rs1,
      input logic [4:0] rs2,
      input logic [4:0] rd
  );
    decoded_uop_t uop;
    uop = '0;
    uop.pc = 32'h8000_0000;
    uop.fu_type = FU_INT;
    uop.rs1 = rs1;
    uop.rs2 = rs2;
    uop.rd = rd;
    uop.need_rs1 = 1'b1;
    uop.need_rs2 = 1'b1;
    uop.write_rd = (rd != 0);
    return uop;
  endfunction

  function automatic decoded_uop_t make_branch(input logic [4:0] rd);
    decoded_uop_t uop;
    uop = '0;
    uop.pc = 32'h8000_0100;
    uop.fu_type = FU_BRANCH;
    uop.branch_op = BR_JAL;
    uop.rd = rd;
    uop.write_rd = (rd != 0);
    return uop;
  endfunction

  task automatic send_decode(
      input logic [1:0] valid,
      input decoded_uop_t uop0,
      input decoded_uop_t uop1
  );
    while (!dec_ready_o)
      @(negedge clk_i);
    @(negedge clk_i);
    dec_valid_i = valid;
    dec_uop0_i = uop0;
    dec_uop1_i = uop1;
    @(negedge clk_i);
    dec_valid_i = 2'b00;
    dec_uop0_i = '0;
    dec_uop1_i = '0;
  endtask

  task automatic grant_with_wb(
      input logic [1:0] lanes,
      input logic [5:0] prd0,
      input logic [5:0] wb_prd
  );
    while (!alloc_req_o.valid)
      @(negedge clk_i);
    @(negedge clk_i);
    alloc_resp_i = '0;
    alloc_resp_i.valid = 1'b1;
    alloc_resp_i.lane_valid = lanes;
    alloc_resp_i.prd[0] = prd0;
    alloc_resp_i.rob_id[0] = 5'd6;
    wb_ready_valid_i = 2'b01;
    wb_ready_prd0_i = wb_prd;
    @(negedge clk_i);
    alloc_resp_i = '0;
    wb_ready_valid_i = 2'b00;
  endtask

  task automatic grant(
      input logic [1:0] lanes,
      input logic [5:0] prd0,
      input logic [5:0] prd1,
      input logic [1:0] checkpoint_id
  );
    while (!alloc_req_o.valid)
      @(negedge clk_i);
    @(negedge clk_i);
    alloc_resp_i = '0;
    alloc_resp_i.valid = 1'b1;
    alloc_resp_i.lane_valid = lanes;
    alloc_resp_i.prd[0] = prd0;
    alloc_resp_i.prd[1] = prd1;
    alloc_resp_i.rob_id[0] = 5'd4;
    alloc_resp_i.rob_id[1] = 5'd5;
    alloc_resp_i.lq_id[0] = 3'd1;
    alloc_resp_i.lq_id[1] = 3'd2;
    alloc_resp_i.sq_id[0] = 3'd3;
    alloc_resp_i.sq_id[1] = 3'd4;
    alloc_resp_i.checkpoint_id = checkpoint_id;
    @(negedge clk_i);
    alloc_resp_i = '0;
  endtask

  task automatic consume_rename;
    @(negedge clk_i);
    rn_ready_i = 1'b1;
    #1;
    if (!alloc_fire_o)
      $fatal(1, "rename fire did not atomically consume allocator response");
    @(posedge clk_i);
    @(negedge clk_i);
    rn_ready_i = 1'b0;
  endtask

  task automatic pulse_wb(input logic [5:0] prd);
    @(negedge clk_i);
    wb_ready_valid_i = 2'b01;
    wb_ready_prd0_i = prd;
    @(negedge clk_i);
    wb_ready_valid_i = 2'b00;
  endtask

  task automatic pulse_recovery(
      input recovery_cause_t cause,
      input logic [1:0] checkpoint_id
  );
    @(negedge clk_i);
    recovery_i.valid = 1'b1;
    recovery_i.cause = cause;
    recovery_i.checkpoint_id = checkpoint_id;
    @(negedge clk_i);
    recovery_i = '0;
  endtask

  initial begin
    decoded_uop_t lane0;
    decoded_uop_t lane1;

    repeat (2) @(posedge clk_i);
    @(negedge clk_i);
    rst_i = 1'b0;

    // Dual rename with lane1 RAW and WAW against lane0.
    lane0 = make_int(5'd1, 5'd2, 5'd5);
    lane1 = make_int(5'd5, 5'd3, 5'd5);
    send_decode(2'b11, lane0, lane1);
    if (alloc_req_o.lane_valid != 2'b11 || alloc_req_o.need_prd != 2'b11)
      $fatal(1, "dual allocation request failed");
    grant(2'b11, 6'd32, 6'd33, 2'd0);
    if (rn_valid_o != 2'b11 ||
        rn_uop0_o.prs1 != 6'd1 || rn_uop0_o.old_prd != 6'd5 ||
        rn_uop0_o.prd != 6'd32 ||
        rn_uop1_o.prs1 != 6'd32 || rn_uop1_o.src1_ready ||
        rn_uop1_o.old_prd != 6'd32 || rn_uop1_o.prd != 6'd33)
      $fatal(1, "lane RAW/WAW rename failed");
    consume_rename();

    // WB readiness is observed by the next map read.
    pulse_wb(6'd33);
    lane0 = make_int(5'd5, 5'd0, 5'd6);
    send_decode(2'b01, lane0, '0);
    grant(2'b01, 6'd34, 6'd0, 2'd0);
    if (rn_uop0_o.prs1 != 6'd33 || !rn_uop0_o.src1_ready)
      $fatal(1, "RAT mapping or PRD ready update failed");
    consume_rename();

    // A partial allocator grant consumes lane0 and replays lane1 as lane0.
    lane0 = make_int(5'd1, 5'd2, 5'd7);
    lane1 = make_int(5'd7, 5'd3, 5'd8);
    send_decode(2'b11, lane0, lane1);
    grant(2'b01, 6'd35, 6'd0, 2'd0);
    if (rn_valid_o != 2'b01 || rn_uop0_o.prd != 6'd35)
      $fatal(1, "partial lane0 grant failed");
    consume_rename();
    if (alloc_req_o.lane_valid != 2'b01)
      $fatal(1, "lane1 was not replayed as lane0");
    grant_with_wb(2'b01, 6'd36, 6'd35);
    if (rn_uop0_o.dec.rd != 5'd8 || rn_uop0_o.prs1 != 6'd35 ||
        !rn_uop0_o.src1_ready)
      $fatal(1, "replayed lane mapping or same-cycle WB bypass failed");
    consume_rename();

    // Checkpoint snapshot includes the branch's own destination mapping but
    // excludes younger speculative writes.
    send_decode(2'b01, make_branch(5'd1), '0);
    grant(2'b01, 6'd37, 6'd0, 2'd2);
    if (rn_uop0_o.branch_mask != 0 || rn_uop0_o.checkpoint_id != 2'd2)
      $fatal(1, "branch checkpoint metadata failed");
    consume_rename();

    send_decode(2'b01, make_int(5'd1, 5'd0, 5'd9), '0);
    grant(2'b01, 6'd38, 6'd0, 2'd0);
    if (!rn_uop0_o.branch_mask[2] || rn_uop0_o.prs1 != 6'd37)
      $fatal(1, "younger branch mask failed");
    consume_rename();

    pulse_recovery(REC_BRANCH, 2'd2);
    lane0 = make_int(5'd1, 5'd9, 5'd11);
    send_decode(2'b01, lane0, '0);
    grant(2'b01, 6'd39, 6'd0, 2'd0);
    if (rn_uop0_o.prs1 != 6'd37 || rn_uop0_o.prs2 != 6'd9 ||
        rn_uop0_o.branch_mask != 0)
      $fatal(1, "branch RAT snapshot recovery failed");
    consume_rename();

    // Correct resolution clears a mask bit even while R1 is stalled.
    send_decode(2'b01, make_branch(5'd0), '0);
    grant(2'b01, 6'd0, 6'd0, 2'd1);
    consume_rename();
    send_decode(2'b01, make_int(5'd1, 5'd2, 5'd13), '0);
    grant(2'b01, 6'd43, 6'd0, 2'd0);
    if (!rn_uop0_o.branch_mask[1])
      $fatal(1, "active branch mask was not attached");
    @(negedge clk_i);
    checkpoint_clear_i = 1'b1;
    checkpoint_clear_id_i = 2'd1;
    @(negedge clk_i);
    checkpoint_clear_i = 1'b0;
    if (rn_uop0_o.branch_mask[1])
      $fatal(1, "held R1 branch mask was not cleared");
    consume_rename();

    // AMT mapping survives exception recovery while speculative RAT state is
    // discarded over the 16-cycle two-entry-per-cycle restore.
    @(negedge clk_i);
    commit_map0_i.valid = 1'b1;
    commit_map0_i.arch_rd = 5'd10;
    commit_map0_i.prd = 6'd40;
    @(negedge clk_i);
    commit_map0_i = '0;

    send_decode(2'b01, make_int(5'd1, 5'd2, 5'd10), '0);
    grant(2'b01, 6'd41, 6'd0, 2'd0);
    consume_rename();
    pulse_recovery(REC_EXCEPT, 2'd0);
    while (!recovery_done_o) begin
      if (dec_ready_o)
        $fatal(1, "Decode accepted input during RAT restore");
      @(negedge clk_i);
    end

    send_decode(2'b01, make_int(5'd10, 5'd0, 5'd12), '0);
    grant(2'b01, 6'd42, 6'd0, 2'd0);
    if (rn_uop0_o.prs1 != 6'd40)
      $fatal(1, "exception AMT restore failed");
    consume_rename();

    $display("PASS: rename_stage directed tests");
    $finish;
  end

  initial begin
    #10000;
    $fatal(1, "timeout");
  end
endmodule
