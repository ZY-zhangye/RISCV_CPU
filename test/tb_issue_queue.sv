import core_types_pkg::*;

module tb_issue_queue;
  localparam int ENTRIES = 12;
  localparam int GROUPS = 3;
  localparam int SLOT_W = $clog2(ENTRIES);

  logic clk_i = 1'b0;
  logic rst_i = 1'b1;

  logic [1:0] push_valid_i = 2'b00;
  logic push_ready_o;
  issue_uop_t push_uop0_i = '0;
  issue_uop_t push_uop1_i = '0;

  logic [1:0] wb_valid_i = 2'b00;
  logic [1:0][PRD_W-1:0] wb_prd_i = '0;

  logic [GROUPS-1:0] candidate_valid_o;
  issue_uop_t candidate_uop0_o;
  issue_uop_t candidate_uop1_o;
  issue_uop_t candidate_uop2_o;
  logic [SLOT_W-1:0] candidate_slot0_o;
  logic [SLOT_W-1:0] candidate_slot1_o;
  logic [SLOT_W-1:0] candidate_slot2_o;
  logic [GROUPS-1:0] issue_grant_i = '0;

  recovery_t recovery_i = '0;
  logic empty_o;
  logic full_o;
  logic [$clog2(ENTRIES+1)-1:0] occupancy_o;

  issue_queue #(
      .ENTRIES(ENTRIES),
      .GROUPS(GROUPS)
  ) dut (.*);

  always #5 clk_i = ~clk_i;

  function automatic issue_uop_t make_uop(
      input logic [ROB_ID_W-1:0] rob_id,
      input logic [PRD_W-1:0] prs1,
      input logic [PRD_W-1:0] prs2,
      input logic src1_ready,
      input logic src2_ready,
      input logic [CHECKPOINTS-1:0] branch_mask
  );
    issue_uop_t uop;
    uop = '0;
    uop.rob_id = rob_id;
    uop.prd = 6'd40 + {1'b0, rob_id};
    uop.prs1 = prs1;
    uop.prs2 = prs2;
    uop.need_rs1 = 1'b1;
    uop.need_rs2 = 1'b1;
    uop.src1_ready = src1_ready;
    uop.src2_ready = src2_ready;
    uop.fu_type = FU_INT;
    uop.branch_mask = branch_mask;
    return uop;
  endfunction

  task automatic push_one(input issue_uop_t uop);
    @(negedge clk_i);
    push_valid_i = 2'b01;
    push_uop0_i = uop;
    if (!push_ready_o)
      $fatal(1, "issue queue rejected single push");
    @(negedge clk_i);
    push_valid_i = 2'b00;
    push_uop0_i = '0;
  endtask

  task automatic push_two(input issue_uop_t uop0, input issue_uop_t uop1);
    @(negedge clk_i);
    push_valid_i = 2'b11;
    push_uop0_i = uop0;
    push_uop1_i = uop1;
    if (!push_ready_o)
      $fatal(1, "issue queue rejected dual push");
    @(negedge clk_i);
    push_valid_i = 2'b00;
    push_uop0_i = '0;
    push_uop1_i = '0;
  endtask

  initial begin
    integer idx;

    repeat (2) @(posedge clk_i);
    @(negedge clk_i);
    rst_i = 1'b0;

    if (!empty_o || occupancy_o != 0)
      $fatal(1, "reset state mismatch");

    // Not-ready entry must not become a candidate until wakeup has registered.
    push_one(make_uop(5'd4, 6'd10, 6'd11, 1'b1, 1'b0, 4'b0001));
    if (candidate_valid_o != 3'b000)
      $fatal(1, "not-ready entry became candidate");
    @(negedge clk_i);
    wb_valid_i = 2'b01;
    wb_prd_i[0] = 6'd11;
    @(negedge clk_i);
    wb_valid_i = 2'b00;
    wb_prd_i = '0;
    repeat (2) @(negedge clk_i);
    if (!candidate_valid_o[0] || candidate_uop0_o.rob_id != 5'd4)
      $fatal(1, "wakeup did not produce candidate");

    // Grant clears the registered candidate slot once.
    @(negedge clk_i);
    issue_grant_i = 3'b001;
    @(negedge clk_i);
    issue_grant_i = 3'b000;
    @(negedge clk_i);
    if (!empty_o || occupancy_o != 0)
      $fatal(1, "grant did not remove issued entry");

    // Dual push fills deterministic free slots; oldest ready in group wins.
    push_two(make_uop(5'd8, 6'd1, 6'd2, 1'b1, 1'b1, 4'b0010),
             make_uop(5'd7, 6'd3, 6'd4, 1'b1, 1'b1, 4'b0010));
    repeat (2) @(negedge clk_i);
    if (!candidate_valid_o[0] || candidate_uop0_o.rob_id != 5'd7)
      $fatal(1, "oldest ready candidate selection mismatch valid=%b rob=%0d occ=%0d",
             candidate_valid_o, candidate_uop0_o.rob_id, occupancy_o);

    // A visible candidate is a held valid/ready handshake item.  A newly
    // selected older entry must not replace it before the arbiter grants it;
    // this permits a pipelined global arbitration stage.
    push_one(make_uop(5'd6, 6'd9, 6'd10, 1'b1, 1'b1, 4'b0010));
    repeat (2) @(negedge clk_i);
    if (!candidate_valid_o[0] || candidate_uop0_o.rob_id != 5'd7)
      $fatal(1, "ungranted candidate was not held stable");

    // Branch recovery kills entries that depend on the resolved checkpoint.
    @(negedge clk_i);
    recovery_i.valid = 1'b1;
    recovery_i.cause = REC_BRANCH;
    recovery_i.checkpoint_id = 2'd1;
    @(negedge clk_i);
    recovery_i = '0;
    @(negedge clk_i);
    if (!empty_o || candidate_valid_o != 3'b000)
      $fatal(1, "branch kill recovery mismatch occ=%0d valid=%b rob=%0d mask=%b",
             occupancy_o, candidate_valid_o, candidate_uop0_o.rob_id,
             candidate_uop0_o.branch_mask);

    // Fill the queue and verify ready deasserts.
    for (idx = 0; idx < 6; idx = idx + 1) begin
      push_two(make_uop(ROB_ID_W'(idx), 6'd5, 6'd6, 1'b0, 1'b0, 4'b0000),
               make_uop(ROB_ID_W'(idx + 6), 6'd7, 6'd8, 1'b0, 1'b0, 4'b0000));
    end
    if (!full_o || occupancy_o != ENTRIES[$clog2(ENTRIES+1)-1:0])
      $fatal(1, "full state mismatch occ=%0d", occupancy_o);
    @(negedge clk_i);
    push_valid_i = 2'b01;
    push_uop0_i = make_uop(5'd20, 6'd9, 6'd10, 1'b1, 1'b1, 4'b0000);
    #1;
    if (push_ready_o)
      $fatal(1, "full issue queue accepted push");
    push_valid_i = 2'b00;
    push_uop0_i = '0;

    // Exception recovery flushes all entries.
    @(negedge clk_i);
    recovery_i.valid = 1'b1;
    recovery_i.cause = REC_EXCEPT;
    @(negedge clk_i);
    recovery_i = '0;
    if (!empty_o || occupancy_o != 0)
      $fatal(1, "exception recovery did not flush IQ");

    $display("PASS: issue_queue directed tests");
    $finish;
  end

  initial begin
    #20000;
    $fatal(1, "timeout");
  end
endmodule
