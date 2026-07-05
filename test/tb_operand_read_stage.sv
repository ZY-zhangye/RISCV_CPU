`timescale 1ns/1ps

import core_types_pkg::*;

module tb_operand_read_stage;
  logic clk_i = 1'b0;
  logic rst_i = 1'b1;

  logic [2:0] issue_valid_i = '0;
  issue_port_t issue_port0_i = ISSUE_INT0;
  issue_port_t issue_port1_i = ISSUE_INT0;
  issue_port_t issue_port2_i = ISSUE_INT0;
  issue_uop_t issue_uop0_i = '0;
  issue_uop_t issue_uop1_i = '0;
  issue_uop_t issue_uop2_i = '0;

  logic [5:0] prf_read_valid;
  logic [5:0][PRD_W-1:0] prf_read_prd;
  logic [5:0][XLEN-1:0] prf_read_data;
  logic [1:0] wb_valid_i = '0;
  logic [1:0][PRD_W-1:0] wb_prd_i = '0;
  logic [1:0][XLEN-1:0] wb_data_i = '0;
  logic [1:0] alloc_clear_valid = '0;
  logic [1:0][PRD_W-1:0] alloc_clear_prd = '0;
  logic [PHYS_REGS-1:0] ready_bits;

  logic int0_issue_ready_o;
  logic int1_issue_ready_o;
  logic lsu_issue_ready_o;
  logic mdu_issue_ready_o;
  logic int0_valid_o;
  logic int0_ready_i = 1'b0;
  execute_uop_t int0_uop_o;
  logic int1_valid_o;
  logic int1_ready_i = 1'b0;
  execute_uop_t int1_uop_o;
  logic lsu_valid_o;
  logic lsu_ready_i = 1'b0;
  execute_uop_t lsu_uop_o;
  logic mdu_valid_o;
  logic mdu_ready_i = 1'b0;
  execute_uop_t mdu_uop_o;
  recovery_t recovery_i = '0;

  physical_regfile prf (
      .clk_i,
      .rst_i,
      .read_valid_i(prf_read_valid),
      .read_prd_i(prf_read_prd),
      .read_data_o(prf_read_data),
      .wb_valid_i,
      .wb_prd_i,
      .wb_data_i,
      .alloc_clear_valid_i(alloc_clear_valid),
      .alloc_clear_prd_i(alloc_clear_prd),
      .ready_bits_o(ready_bits)
  );

  operand_read_stage dut (
      .clk_i,
      .rst_i,
      .issue_valid_i,
      .issue_port0_i,
      .issue_port1_i,
      .issue_port2_i,
      .issue_uop0_i,
      .issue_uop1_i,
      .issue_uop2_i,
      .prf_read_valid_o(prf_read_valid),
      .prf_read_prd_o(prf_read_prd),
      .prf_read_data_i(prf_read_data),
      .wb_valid_i,
      .wb_prd_i,
      .wb_data_i,
      .int0_issue_ready_o,
      .int1_issue_ready_o,
      .lsu_issue_ready_o,
      .mdu_issue_ready_o,
      .int0_valid_o,
      .int0_ready_i,
      .int0_uop_o,
      .int1_valid_o,
      .int1_ready_i,
      .int1_uop_o,
      .lsu_valid_o,
      .lsu_ready_i,
      .lsu_uop_o,
      .mdu_valid_o,
      .mdu_ready_i,
      .mdu_uop_o,
      .recovery_i
  );

  always #5 clk_i = ~clk_i;

  function automatic issue_uop_t make_uop(
      input logic [ROB_ID_W-1:0] rob_id,
      input fu_t fu_type,
      input logic [PRD_W-1:0] prs1,
      input logic [PRD_W-1:0] prs2,
      input logic need_rs1,
      input logic need_rs2,
      input logic [CHECKPOINTS-1:0] branch_mask
  );
    issue_uop_t uop;
    begin
      uop = '0;
      uop.rob_id = rob_id;
      uop.prd = 6'd32 + rob_id;
      uop.fu_type = fu_type;
      uop.alu_op = ALU_ADD;
      uop.mem_op = MEM_SW;
      uop.prs1 = prs1;
      uop.prs2 = prs2;
      uop.need_rs1 = need_rs1;
      uop.need_rs2 = need_rs2;
      uop.src1_ready = !need_rs1 || 1'b1;
      uop.src2_ready = !need_rs2 || 1'b1;
      uop.imm = 32'h0000_0040 + rob_id;
      uop.pc = 32'h8000_0000 + {25'd0, rob_id, 2'b00};
      uop.pred_taken = (fu_type == FU_BRANCH);
      uop.pred_target = uop.pc + 32'h40;
      uop.checkpoint_id = rob_id[CP_W-1:0];
      uop.branch_mask = branch_mask;
      uop.write_rd = (fu_type != FU_LSU);
      uop.is_store = (fu_type == FU_LSU);
      uop.sq_id = rob_id[SQ_ID_W-1:0];
      make_uop = uop;
    end
  endfunction

  task automatic clear_issue;
    begin
      issue_valid_i = '0;
      issue_port0_i = ISSUE_INT0;
      issue_port1_i = ISSUE_INT0;
      issue_port2_i = ISSUE_INT0;
      issue_uop0_i = '0;
      issue_uop1_i = '0;
      issue_uop2_i = '0;
    end
  endtask

  task automatic write_pair(
      input logic [PRD_W-1:0] prd0,
      input logic [XLEN-1:0] data0,
      input logic [PRD_W-1:0] prd1,
      input logic [XLEN-1:0] data1
  );
    begin
      @(negedge clk_i);
      wb_valid_i = 2'b11;
      wb_prd_i[0] = prd0;
      wb_prd_i[1] = prd1;
      wb_data_i[0] = data0;
      wb_data_i[1] = data1;
      @(posedge clk_i);
      #1;
      wb_valid_i = '0;
      wb_prd_i = '0;
      wb_data_i = '0;
    end
  endtask

  initial begin
    execute_uop_t held_lsu;
    execute_uop_t held_mdu;

    repeat (2) @(posedge clk_i);
    @(negedge clk_i);
    rst_i = 1'b0;
    #1;
    if (!int0_issue_ready_o || !int1_issue_ready_o ||
        !lsu_issue_ready_o || !mdu_issue_ready_o)
      $fatal(1, "operand read ports not ready after reset");

    // Seed three even/odd source pairs in the real banked PRF.
    write_pair(6'd2, 32'h0000_1002, 6'd3, 32'h0000_1003);
    write_pair(6'd4, 32'h0000_1004, 6'd5, 32'h0000_1005);
    write_pair(6'd6, 32'h0000_1006, 6'd7, 32'h0000_1007);

    // Three-way issue exercises all six PRF reads and three execution ports.
    @(negedge clk_i);
    if (!int0_issue_ready_o || !lsu_issue_ready_o || !mdu_issue_ready_o)
      $fatal(1, "ports not ready for initial three-way issue");
    issue_valid_i = 3'b111;
    issue_port0_i = ISSUE_INT0;
    issue_port1_i = ISSUE_LSU;
    issue_port2_i = ISSUE_MDU;
    issue_uop0_i = make_uop(5'd1, FU_INT, 6'd2, 6'd3, 1'b1, 1'b1,
                            4'b0001);
    issue_uop1_i = make_uop(5'd2, FU_LSU, 6'd4, 6'd5, 1'b1, 1'b1,
                            4'b0010);
    issue_uop2_i = make_uop(5'd3, FU_MUL, 6'd6, 6'd7, 1'b1, 1'b1,
                            4'b0100);
    @(posedge clk_i);
    #1;
    if (prf_read_valid !== 6'b11_1111)
      $fatal(1, "six-read request did not reach PRF");
    @(negedge clk_i);
    clear_issue();
    @(posedge clk_i);
    #1;
    if (!int0_valid_o || int0_uop_o.src1 != 32'h0000_1002 ||
        int0_uop_o.src2 != 32'h0000_1003 ||
        int0_uop_o.pc != 32'h8000_0004)
      $fatal(1, "INT0 operand/metadata alignment mismatch");
    if (!lsu_valid_o || lsu_uop_o.src1 != 32'h0000_1004 ||
        lsu_uop_o.src2 != 32'h0000_1005 ||
        lsu_uop_o.store_data != 32'h0000_1005 || !lsu_uop_o.is_store)
      $fatal(1, "LSU operand/store-data alignment mismatch");
    if (!mdu_valid_o || mdu_uop_o.src1 != 32'h0000_1006 ||
        mdu_uop_o.src2 != 32'h0000_1007)
      $fatal(1, "MDU operand alignment mismatch");
    held_lsu = lsu_uop_o;
    held_mdu = mdu_uop_o;

    // Consume INT0 while LSU and MDU remain stalled.  They must stay stable,
    // and the now-independent INT0 path must accept a refill.
    @(negedge clk_i);
    int0_ready_i = 1'b1;
    @(posedge clk_i);
    #1;
    if (int0_valid_o || !lsu_valid_o || !mdu_valid_o ||
        lsu_uop_o !== held_lsu || mdu_uop_o !== held_mdu)
      $fatal(1, "independent execution-port consume/stall mismatch");
    @(negedge clk_i);
    int0_ready_i = 1'b0;
    if (!int0_issue_ready_o)
      $fatal(1, "INT0 did not become independently issue-ready");
    issue_valid_i = 3'b001;
    issue_port0_i = ISSUE_INT0;
    issue_uop0_i = make_uop(5'd4, FU_INT, 6'd0, 6'd0, 1'b0, 1'b0,
                            4'b0000);
    @(posedge clk_i);
    @(negedge clk_i);
    clear_issue();
    @(posedge clk_i);
    #1;
    if (!int0_valid_o || int0_uop_o.src1 != 0 || int0_uop_o.src2 != 0 ||
        int0_uop_o.imm != 32'h0000_0044 ||
        lsu_uop_o !== held_lsu || mdu_uop_o !== held_mdu)
      $fatal(1, "INT0 refill or independent stalled payload mismatch");

    // Drain all three held endpoint entries.
    @(negedge clk_i);
    int0_ready_i = 1'b1;
    lsu_ready_i = 1'b1;
    mdu_ready_i = 1'b1;
    @(posedge clk_i);
    #1;
    if (int0_valid_o || lsu_valid_o || mdu_valid_o)
      $fatal(1, "endpoint holding registers did not drain");
    @(negedge clk_i);
    int0_ready_i = 1'b0;
    lsu_ready_i = 1'b0;
    mdu_ready_i = 1'b0;

    // Seed old values, then present final WB during the PRF response cycle.
    write_pair(6'd8, 32'h0000_2008, 6'd9, 32'h0000_2009);
    @(negedge clk_i);
    if (!int1_issue_ready_o)
      $fatal(1, "INT1 not ready for bypass test");
    issue_valid_i = 3'b001;
    issue_port0_i = ISSUE_INT1;
    issue_uop0_i = make_uop(5'd5, FU_BRANCH, 6'd8, 6'd9, 1'b1, 1'b1,
                            4'b0000);
    @(posedge clk_i);
    @(negedge clk_i);
    clear_issue();
    wb_valid_i = 2'b11;
    wb_prd_i[0] = 6'd8;
    wb_prd_i[1] = 6'd9;
    wb_data_i[0] = 32'haaaa_0008;
    wb_data_i[1] = 32'hbbbb_0009;
    @(posedge clk_i);
    #1;
    if (!int1_valid_o || int1_uop_o.src1 != 32'haaaa_0008 ||
        int1_uop_o.src2 != 32'hbbbb_0009 ||
        !int1_uop_o.pred_taken ||
        int1_uop_o.pred_target != 32'h8000_0054 ||
        int1_uop_o.checkpoint_id != 2'd1)
      $fatal(1, "final-WB bypass or Branch metadata mismatch");
    @(negedge clk_i);
    wb_valid_i = '0;
    wb_prd_i = '0;
    wb_data_i = '0;

    // A mispredict recovery kills a held dependent uop.
    begin : response_kill_check
      // Refill INT1 with a branch-dependent item after consuming the bypass uop.
      int1_ready_i = 1'b1;
      @(posedge clk_i);
      @(negedge clk_i);
      int1_ready_i = 1'b0;
      issue_valid_i = 3'b001;
      issue_port0_i = ISSUE_INT1;
      issue_uop0_i = make_uop(5'd6, FU_INT, 6'd2, 6'd3, 1'b1, 1'b1,
                              4'b0010);
      @(posedge clk_i);
      @(negedge clk_i);
      clear_issue();
      @(posedge clk_i);
      #1;
      if (!int1_valid_o)
        $fatal(1, "INT1 recovery-test response missing");
      @(negedge clk_i);
      recovery_i.valid = 1'b1;
      recovery_i.cause = REC_BRANCH;
      recovery_i.checkpoint_id = 2'd1;
      @(posedge clk_i);
      #1;
      if (int1_valid_o)
        $fatal(1, "branch recovery did not kill held response");
      @(negedge clk_i);
      recovery_i = '0;
    end

    // Recovery also kills metadata while its PRF response is in flight.
    @(negedge clk_i);
    issue_valid_i = 3'b001;
    issue_port0_i = ISSUE_INT0;
    issue_uop0_i = make_uop(5'd7, FU_INT, 6'd2, 6'd3, 1'b1, 1'b1,
                            4'b0100);
    @(posedge clk_i);
    @(negedge clk_i);
    clear_issue();
    recovery_i.valid = 1'b1;
    recovery_i.cause = REC_BRANCH;
    recovery_i.checkpoint_id = 2'd2;
    @(posedge clk_i);
    #1;
    if (int0_valid_o)
      $fatal(1, "branch recovery did not kill in-flight metadata");
    @(negedge clk_i);
    recovery_i = '0;

    // Exception recovery flushes all endpoint state.
    recovery_i.valid = 1'b1;
    recovery_i.cause = REC_EXCEPT;
    @(posedge clk_i);
    #1;
    if (int0_valid_o || int1_valid_o || lsu_valid_o || mdu_valid_o)
      $fatal(1, "exception recovery did not flush operand read stage");

    $display("PASS: operand_read_stage directed tests");
    $finish;
  end

  initial begin
    #50000;
    $fatal(1, "timeout");
  end
endmodule
