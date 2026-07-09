import core_types_pkg::*;

module tb_issue_arbiter;
  logic clk_i = 1'b0;
  logic rst_i = 1'b1;

  logic [2:0] int_candidate_valid_i = '0;
  issue_uop_t int_candidate_uop0_i = '0;
  issue_uop_t int_candidate_uop1_i = '0;
  issue_uop_t int_candidate_uop2_i = '0;
  logic [1:0] mem_candidate_valid_i = '0;
  issue_uop_t mem_candidate_uop0_i = '0;
  issue_uop_t mem_candidate_uop1_i = '0;
  logic [1:0] mem_issue_allowed_i = '0;
  logic mdu_candidate_valid_i = 1'b0;
  issue_uop_t mdu_candidate_uop_i = '0;
  logic mdu_accept_i = 1'b0;
  logic int0_ready_i = 1'b1;
  logic int1_ready_i = 1'b1;
  logic lsu_ready_i = 1'b1;
  logic mdu_ready_i = 1'b1;
  logic issue_block_i = 1'b0;
  recovery_t recovery_i = '0;

  logic [2:0] int_issue_grant_o;
  logic [1:0] mem_issue_grant_o;
  logic mdu_issue_grant_o;
  logic [2:0] issue_valid_o;
  issue_port_t issue_port0_o;
  issue_port_t issue_port1_o;
  issue_port_t issue_port2_o;
  issue_uop_t issue_uop0_o;
  issue_uop_t issue_uop1_o;
  issue_uop_t issue_uop2_o;

  issue_arbiter dut (.*);

  always #5 clk_i = ~clk_i;

  function automatic issue_uop_t make_uop(
      input logic [ROB_ID_W-1:0] rob_id,
      input fu_t fu_type,
      input alu_op_t alu_op,
      input logic [PRD_W-1:0] prs1,
      input logic [PRD_W-1:0] prs2,
      input logic need_rs1,
      input logic need_rs2
  );
    issue_uop_t uop;
    begin
      uop = '0;
      uop.rob_id = rob_id;
      uop.fu_type = fu_type;
      uop.alu_op = alu_op;
      uop.prs1 = prs1;
      uop.prs2 = prs2;
      uop.need_rs1 = need_rs1;
      uop.need_rs2 = need_rs2;
      uop.src1_ready = 1'b1;
      uop.src2_ready = 1'b1;
      make_uop = uop;
    end
  endfunction

  task automatic clear_candidates;
    begin
      int_candidate_valid_i = '0;
      int_candidate_uop0_i = '0;
      int_candidate_uop1_i = '0;
      int_candidate_uop2_i = '0;
      mem_candidate_valid_i = '0;
      mem_candidate_uop0_i = '0;
      mem_candidate_uop1_i = '0;
      mem_issue_allowed_i = '0;
      mdu_candidate_valid_i = 1'b0;
      mdu_candidate_uop_i = '0;
      mdu_accept_i = 1'b0;
      int0_ready_i = 1'b1;
      int1_ready_i = 1'b1;
      lsu_ready_i = 1'b1;
      mdu_ready_i = 1'b1;
      issue_block_i = 1'b0;
    end
  endtask

  task automatic check_transaction(
      input logic [2:0] expected_int_grant,
      input logic [1:0] expected_mem_grant,
      input logic expected_mdu_grant,
      input logic [2:0] expected_valid,
      input issue_port_t expected_port0,
      input issue_port_t expected_port1,
      input issue_port_t expected_port2,
      input logic [ROB_ID_W-1:0] expected_rob0,
      input logic [ROB_ID_W-1:0] expected_rob1,
      input logic [ROB_ID_W-1:0] expected_rob2
  );
    begin
      // C0 snapshots candidates.  The proposal stage remains isolated from
      // both grants and externally visible issue slots on this edge.
      #1;
      if (int_issue_grant_o != 3'b000 || mem_issue_grant_o != 2'b00 ||
          mdu_issue_grant_o || issue_valid_o != 3'b000)
        $fatal(1, "candidate snapshot stage was not isolated from outputs");
      @(posedge clk_i);
      #1;
      if (int_issue_grant_o != 3'b000 || mem_issue_grant_o != 2'b00 ||
          mdu_issue_grant_o || issue_valid_o != 3'b000)
        $fatal(1, "candidate snapshot bypassed proposal stage");

      // P0 captures proposals from the snapshot.  The selected-mask stage
      // remains isolated from externally visible grants.
      @(posedge clk_i);
      #1;
      if (int_issue_grant_o != 3'b000 || mem_issue_grant_o != 2'b00 ||
          mdu_issue_grant_o || issue_valid_o != 3'b000)
        $fatal(1, "proposal register bypassed selected-mask stage");

      // P1 registers only the Bank/width decision.  P2 fire is combinational
      // on selected_valid_q, but grant/issue outputs still register one edge
      // later — so this edge must remain externally quiet.
      @(posedge clk_i);
      #1;
      if (int_issue_grant_o != 3'b000 || mem_issue_grant_o != 2'b00 ||
          mdu_issue_grant_o || issue_valid_o != 3'b000)
        $fatal(1, "selected-mask stage leaked grant/issue early");

      // P2 grant is now registered.  Issue payload/valid registers on the
      // same edge as grant in issue_registers, so both become visible here.
      // (Historically the TB expected grant one cycle earlier than the
      // C0/P0/P1/P2 pipeline actually produces; align to the real RTL.)
      @(posedge clk_i);
      #1;
      if (int_issue_grant_o != expected_int_grant ||
          mem_issue_grant_o != expected_mem_grant ||
          mdu_issue_grant_o != expected_mdu_grant)
        $fatal(1, "registered proposal grant mismatch int=%b mem=%b mdu=%b out=%b",
               int_issue_grant_o, mem_issue_grant_o, mdu_issue_grant_o,
               issue_valid_o);
      if (issue_valid_o != expected_valid)
        $fatal(1, "registered issue valid mismatch got=%b expected=%b",
               issue_valid_o, expected_valid);
      if (expected_valid[0] &&
          ((issue_port0_o != expected_port0) ||
           (issue_uop0_o.rob_id != expected_rob0)))
        $fatal(1, "issue slot 0 mismatch");
      if (expected_valid[1] &&
          ((issue_port1_o != expected_port1) ||
           (issue_uop1_o.rob_id != expected_rob1)))
        $fatal(1, "issue slot 1 mismatch");
      if (expected_valid[2] &&
          ((issue_port2_o != expected_port2) ||
           (issue_uop2_o.rob_id != expected_rob2)))
        $fatal(1, "issue slot 2 mismatch");

      // Model the IQ clearing its granted candidate after the registered grant
      // pulse.  fire drops combinationally once the live source disappears, but
      // grant/issue outputs only update on the next clock edge.
      @(negedge clk_i);
      clear_candidates();
      @(posedge clk_i);
      #1;
      if (int_issue_grant_o != 3'b000 || mem_issue_grant_o != 2'b00 ||
          mdu_issue_grant_o)
        $fatal(1, "stale proposal granted after source candidate disappeared");
      if (issue_valid_o != 3'b000)
        $fatal(1, "issue output did not clear after source candidate removal");
    end
  endtask

  initial begin
    repeat (2) @(posedge clk_i);
    @(negedge clk_i);
    rst_i = 1'b0;

    // Branch and shift receive their only legal ports even though a flexible
    // ALU candidate has the first group priority.
    int_candidate_valid_i = 3'b111;
    int_candidate_uop0_i = make_uop(5'd10, FU_INT, ALU_ADD,
                                    6'd1, 6'd2, 1'b1, 1'b1);
    int_candidate_uop1_i = make_uop(5'd11, FU_BRANCH, ALU_ADD,
                                    6'd3, 6'd4, 1'b1, 1'b1);
    int_candidate_uop2_i = make_uop(5'd12, FU_INT, ALU_SLL,
                                    6'd5, 6'd6, 1'b1, 1'b1);
    check_transaction(3'b110, 2'b00, 1'b0, 3'b011,
                      ISSUE_INT1, ISSUE_INT0, ISSUE_INT0,
                      5'd11, 5'd12, '0);

    // CSR operand preparation is pinned to INT0 while an independent branch
    // may use INT1 in the same cycle.
    @(negedge clk_i);
    int_candidate_valid_i = 3'b011;
    int_candidate_uop0_i = make_uop(5'd20, FU_CSR, ALU_PASS1,
                                    6'd9, 6'd0, 1'b1, 1'b0);
    int_candidate_uop1_i = make_uop(5'd21, FU_BRANCH, ALU_ADD,
                                    6'd3, 6'd4, 1'b1, 1'b1);
    check_transaction(3'b011, 2'b00, 1'b0, 3'b011,
                      ISSUE_INT1, ISSUE_INT0, ISSUE_INT0,
                      5'd21, 5'd20, '0);

    // INT + LSU + MDU may fill all three global issue slots.
    @(negedge clk_i);
    int_candidate_valid_i = 3'b001;
    int_candidate_uop0_i = make_uop(5'd1, FU_INT, ALU_ADD,
                                    6'd1, 6'd0, 1'b1, 1'b0);
    mem_candidate_valid_i = 2'b01;
    mem_candidate_uop0_i = make_uop(5'd2, FU_LSU, ALU_ADD,
                                    6'd2, 6'd0, 1'b1, 1'b0);
    mem_issue_allowed_i = 2'b01;
    mdu_candidate_valid_i = 1'b1;
    mdu_candidate_uop_i = make_uop(5'd3, FU_MUL, ALU_ADD,
                                   6'd3, 6'd0, 1'b1, 1'b0);
    mdu_accept_i = 1'b1;
    check_transaction(3'b001, 2'b01, 1'b1, 3'b111,
                      ISSUE_INT0, ISSUE_LSU, ISSUE_MDU,
                      5'd1, 5'd2, 5'd3);

    // Two INT proposals plus LSU consume the global width; MDU remains held.
    @(negedge clk_i);
    int_candidate_valid_i = 3'b011;
    int_candidate_uop0_i = make_uop(5'd4, FU_INT, ALU_ADD,
                                    6'd1, 6'd0, 1'b1, 1'b0);
    int_candidate_uop1_i = make_uop(5'd5, FU_INT, ALU_ADD,
                                    6'd2, 6'd0, 1'b1, 1'b0);
    mem_candidate_valid_i = 2'b01;
    mem_candidate_uop0_i = make_uop(5'd6, FU_LSU, ALU_ADD,
                                    6'd3, 6'd0, 1'b1, 1'b0);
    mem_issue_allowed_i = 2'b01;
    mdu_candidate_valid_i = 1'b1;
    mdu_candidate_uop_i = make_uop(5'd7, FU_DIV, ALU_ADD,
                                   6'd4, 6'd0, 1'b1, 1'b0);
    mdu_accept_i = 1'b1;
    check_transaction(3'b011, 2'b01, 1'b0, 3'b111,
                      ISSUE_INT0, ISSUE_INT1, ISSUE_LSU,
                      5'd4, 5'd5, 5'd6);

    // Two even reads from INT plus two from LSU exceed the per-bank limit;
    // the later odd-bank MDU proposal can still issue.
    @(negedge clk_i);
    int_candidate_valid_i = 3'b001;
    int_candidate_uop0_i = make_uop(5'd8, FU_INT, ALU_ADD,
                                    6'd2, 6'd4, 1'b1, 1'b1);
    mem_candidate_valid_i = 2'b01;
    mem_candidate_uop0_i = make_uop(5'd9, FU_LSU, ALU_ADD,
                                    6'd6, 6'd8, 1'b1, 1'b1);
    mem_issue_allowed_i = 2'b01;
    mdu_candidate_valid_i = 1'b1;
    mdu_candidate_uop_i = make_uop(5'd10, FU_MUL, ALU_ADD,
                                   6'd3, 6'd0, 1'b1, 1'b0);
    mdu_accept_i = 1'b1;
    check_transaction(3'b001, 2'b00, 1'b1, 3'b011,
                      ISSUE_INT0, ISSUE_MDU, ISSUE_INT0,
                      5'd8, 5'd10, '0);

    // Queue-local memory permission skips group 0 and selects group 1.
    @(negedge clk_i);
    mem_candidate_valid_i = 2'b11;
    mem_candidate_uop0_i = make_uop(5'd13, FU_LSU, ALU_ADD,
                                    6'd1, 6'd2, 1'b1, 1'b1);
    mem_candidate_uop1_i = make_uop(5'd14, FU_LSU, ALU_ADD,
                                    6'd3, 6'd4, 1'b1, 1'b1);
    mem_issue_allowed_i = 2'b10;
    check_transaction(3'b000, 2'b10, 1'b0, 3'b001,
                      ISSUE_LSU, ISSUE_INT0, ISSUE_INT0,
                      5'd14, '0, '0);

    // Endpoint readiness, MDU acceptance, and source readiness block P0.
    @(negedge clk_i);
    int_candidate_valid_i = 3'b011;
    int_candidate_uop0_i = make_uop(5'd15, FU_BRANCH, ALU_ADD,
                                    6'd1, 6'd2, 1'b1, 1'b1);
    int_candidate_uop1_i = make_uop(5'd16, FU_INT, ALU_SRA,
                                    6'd3, 6'd4, 1'b1, 1'b1);
    int0_ready_i = 1'b0;
    int1_ready_i = 1'b0;
    mdu_candidate_valid_i = 1'b1;
    mdu_candidate_uop_i = make_uop(5'd17, FU_DIV, ALU_ADD,
                                   6'd5, 6'd6, 1'b1, 1'b1);
    mdu_accept_i = 1'b0;
    check_transaction(3'b000, 2'b00, 1'b0, 3'b000,
                      ISSUE_INT0, ISSUE_INT0, ISSUE_INT0,
                      '0, '0, '0);

    @(negedge clk_i);
    int_candidate_valid_i = 3'b001;
    int_candidate_uop0_i = make_uop(5'd18, FU_INT, ALU_ADD,
                                    6'd1, 6'd2, 1'b1, 1'b1);
    int_candidate_uop0_i.src2_ready = 1'b0;
    check_transaction(3'b000, 2'b00, 1'b0, 3'b000,
                      ISSUE_INT0, ISSUE_INT0, ISSUE_INT0,
                      '0, '0, '0);

    // A pending branch recovery handoff blocks the final grant for one cycle
    // without requiring the IQ to drop or reselect its held candidate.
    // Pipeline: C0 snapshot → P0 proposal → P1 selected mask → P2 reg grant/issue.
    @(negedge clk_i);
    clear_candidates();
    int_candidate_valid_i = 3'b001;
    int_candidate_uop0_i = make_uop(5'd22, FU_INT, ALU_ADD,
                                    6'd1, 6'd2, 1'b1, 1'b1);
    @(posedge clk_i); // C0
    #1;
    if (int_issue_grant_o != 3'b000 || issue_valid_o != 3'b000)
      $fatal(1, "issue block setup bypassed candidate snapshot");
    @(posedge clk_i); // P0
    #1;
    if (int_issue_grant_o != 3'b000 || issue_valid_o != 3'b000)
      $fatal(1, "issue block setup bypassed proposal stage");
    // Assert block before P1 commits selected_valid, so P2 fire stays low.
    @(negedge clk_i);
    issue_block_i = 1'b1;
    @(posedge clk_i); // P1: selected registers, fire blocked
    #1;
    if (int_issue_grant_o != 3'b000 || issue_valid_o != 3'b000)
      $fatal(1, "issue block did not suppress final grant");
    @(posedge clk_i); // would-be P2 output edge; still quiet under block
    #1;
    if (int_issue_grant_o != 3'b000 || issue_valid_o != 3'b000)
      $fatal(1, "issue block leaked registered grant/issue");
    @(negedge clk_i);
    issue_block_i = 1'b0;
    // selected_valid_q is still held; fire rises combinationally, grant next edge.
    @(posedge clk_i);
    #1;
    if (int_issue_grant_o != 3'b001)
      $fatal(1, "held candidate did not grant after issue block dropped");
    if (issue_valid_o != 3'b001 || issue_uop0_o.rob_id != 5'd22)
      $fatal(1, "held candidate did not issue after issue block dropped");
    @(negedge clk_i);
    clear_candidates();
    @(posedge clk_i);
    #1;
    if (int_issue_grant_o != 3'b000 || issue_valid_o != 3'b000)
      $fatal(1, "issue output did not clear after blocked candidate test");

    // Recovery clears registered grant/issue on the next clock edge.
    @(negedge clk_i);
    int_candidate_valid_i = 3'b001;
    int_candidate_uop0_i = make_uop(5'd19, FU_INT, ALU_ADD,
                                    6'd1, 6'd2, 1'b1, 1'b1);
    @(posedge clk_i); // C0
    #1;
    if (int_issue_grant_o != 3'b000)
      $fatal(1, "candidate snapshot bypassed proposal stage before recovery test");
    @(posedge clk_i); // P0
    #1;
    if (int_issue_grant_o != 3'b000)
      $fatal(1, "proposal stage bypassed before recovery test");
    @(posedge clk_i); // P1 selected
    #1;
    if (int_issue_grant_o != 3'b000)
      $fatal(1, "selected-mask stage leaked grant before recovery test");
    @(posedge clk_i); // P2 grant/issue registered
    #1;
    if (int_issue_grant_o != 3'b001)
      $fatal(1, "pre-recovery delayed grant missing");
    @(negedge clk_i);
    recovery_i.valid = 1'b1;
    recovery_i.cause = REC_BRANCH;
    @(posedge clk_i);
    #1;
    if (int_issue_grant_o != 3'b000)
      $fatal(1, "recovery did not clear registered grant");
    if (issue_valid_o != 3'b000)
      $fatal(1, "recovery did not clear registered issue output");

    $display("PASS: issue_arbiter pipelined directed tests");
    $finish;
  end

  initial begin
    #30000;
    $fatal(1, "timeout");
  end
endmodule
