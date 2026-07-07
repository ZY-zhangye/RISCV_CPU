import core_types_pkg::*;

module tb_dispatch_buffer;
  logic clk_i = 1'b0;
  logic rst_i = 1'b1;

  logic [1:0] rn_valid_i = 2'b00;
  logic rn_ready_o;
  renamed_uop_t rn_uop0_i = '0;
  renamed_uop_t rn_uop1_i = '0;

  logic [1:0] int_push_valid_o;
  logic [1:0] int_push_ready_i = 2'b11;
  issue_uop_t int_push_uop0_o;
  issue_uop_t int_push_uop1_o;

  logic [1:0] mem_push_valid_o;
  logic [1:0] mem_push_ready_i = 2'b11;
  issue_uop_t mem_push_uop0_o;
  issue_uop_t mem_push_uop1_o;

  logic [1:0] mdu_push_valid_o;
  logic [1:0] mdu_push_ready_i = 2'b11;
  issue_uop_t mdu_push_uop0_o;
  issue_uop_t mdu_push_uop1_o;

  logic [1:0] wb_valid_i = 2'b00;
  logic [1:0][PRD_W-1:0] wb_prd_i = '0;

  logic checkpoint_clear_i = 1'b0;
  logic [CP_W-1:0] checkpoint_clear_id_i = '0;
  recovery_t recovery_i = '0;
  logic empty_o;
  logic full_o;
  logic [2:0] occupancy_o;

  dispatch_buffer dut (.*);

  always #5 clk_i = ~clk_i;

  function automatic renamed_uop_t make_uop(
      input fu_t fu,
      input logic [ROB_ID_W-1:0] rob_id,
      input logic [PRD_W-1:0] prd,
      input logic [CHECKPOINTS-1:0] branch_mask
  );
    renamed_uop_t uop;
    uop = '0;
    uop.dec.fu_type = fu;
    uop.dec.write_rd = 1'b1;
    uop.dec.need_rs1 = 1'b1;
    uop.dec.need_rs2 = 1'b1;
    uop.dec.imm = 32'h1000 + rob_id;
    uop.dec.pc = 32'h8000_0000 + {25'd0, rob_id, 2'b00};
    uop.dec.pred_taken = (fu == FU_BRANCH);
    uop.dec.pred_target = uop.dec.pc + 32'h40;
    uop.dec.mem_op = (fu == FU_LSU) ? MEM_LW : MEM_LB;
    uop.prd = prd;
    uop.prs1 = prd + 6'd1;
    uop.prs2 = prd + 6'd2;
    uop.old_prd = prd + 6'd3;
    uop.rob_id = rob_id;
    uop.lq_id = rob_id[LQ_ID_W-1:0];
    uop.sq_id = rob_id[SQ_ID_W-1:0];
    uop.checkpoint_id = rob_id[CP_W-1:0];
    uop.branch_mask = branch_mask;
    uop.src1_ready = 1'b1;
    uop.src2_ready = 1'b0;
    return uop;
  endfunction

  task automatic push_bundle(
      input logic [1:0] valid,
      input renamed_uop_t uop0,
      input renamed_uop_t uop1
  );
    @(negedge clk_i);
    rn_valid_i = valid;
    rn_uop0_i = uop0;
    rn_uop1_i = uop1;
    if (!rn_ready_o)
      $fatal(1, "dispatch buffer rejected rename bundle valid=%b", valid);
    @(negedge clk_i);
    rn_valid_i = 2'b00;
    rn_uop0_i = '0;
    rn_uop1_i = '0;
  endtask

  task automatic expect_idle;
    if (int_push_valid_o != 2'b00 || mem_push_valid_o != 2'b00 ||
        mdu_push_valid_o != 2'b00)
      $fatal(1, "unexpected dispatch valid int/mem/mdu=%b/%b/%b",
             int_push_valid_o, mem_push_valid_o, mdu_push_valid_o);
  endtask

  initial begin
    integer idx;

    repeat (2) @(posedge clk_i);
    @(negedge clk_i);
    rst_i = 1'b0;

    if (!empty_o || occupancy_o != 0)
      $fatal(1, "reset state mismatch");

    push_bundle(2'b11,
                make_uop(FU_INT, 5'd0, 6'd10, 4'b0001),
                make_uop(FU_BRANCH, 5'd1, 6'd11, 4'b0001));
    if (occupancy_o != 3'd2)
      $fatal(1, "occupancy after push mismatch: %0d", occupancy_o);
    if (int_push_valid_o != 2'b11 ||
        int_push_uop0_o.rob_id != 5'd0 ||
        int_push_uop1_o.rob_id != 5'd1 ||
        int_push_uop1_o.pc != 32'h8000_0004 ||
        !int_push_uop1_o.pred_taken ||
        int_push_uop1_o.pred_target != 32'h8000_0044 ||
        int_push_uop1_o.checkpoint_id != 2'd1)
      $fatal(1, "integer dispatch mismatch");
    @(negedge clk_i);
    if (occupancy_o != 3'd0 || !empty_o)
      $fatal(1, "integer dispatch did not dequeue both");

    push_bundle(2'b11,
                make_uop(FU_LSU, 5'd2, 6'd12, 4'b0010),
                make_uop(FU_MUL, 5'd3, 6'd13, 4'b0010));
    if (mem_push_valid_o != 2'b01 || mdu_push_valid_o != 2'b01 ||
        mem_push_uop0_o.rob_id != 5'd2 ||
        mdu_push_uop0_o.rob_id != 5'd3)
      $fatal(1, "mixed-class dispatch mismatch");
    @(negedge clk_i);

    mem_push_ready_i = 2'b00;
    int_push_ready_i = 2'b11;
    push_bundle(2'b11,
                make_uop(FU_LSU, 5'd4, 6'd14, 4'b0000),
                make_uop(FU_INT, 5'd5, 6'd15, 4'b0000));
    expect_idle();
    if (occupancy_o != 3'd2)
      $fatal(1, "blocked head occupancy mismatch: %0d", occupancy_o);
    mem_push_ready_i = 2'b11;
    #1;
    if (mem_push_valid_o != 2'b01 || int_push_valid_o != 2'b01 ||
        mem_push_uop0_o.rob_id != 5'd4 ||
        int_push_uop0_o.rob_id != 5'd5)
      $fatal(1, "unblocked mixed dispatch mismatch int=%b mem=%b mdu=%b int_id=%0d mem_id=%0d occ=%0d",
             int_push_valid_o, mem_push_valid_o, mdu_push_valid_o,
             int_push_uop0_o.rob_id, mem_push_uop0_o.rob_id, occupancy_o);
    @(negedge clk_i);

    int_push_ready_i = 2'b00;
    mem_push_ready_i = 2'b00;
    mdu_push_ready_i = 2'b00;
    for (idx = 0; idx < 3; idx = idx + 1) begin
      push_bundle(2'b11,
                  make_uop(FU_INT, 5'd6 + idx * 2, 6'd20, 4'b0000),
                  make_uop(FU_INT, 5'd7 + idx * 2, 6'd21, 4'b0000));
    end
    if (!full_o || occupancy_o != 3'd6)
      $fatal(1, "full state mismatch occ=%0d", occupancy_o);
    @(negedge clk_i);
    rn_valid_i = 2'b01;
    rn_uop0_i = make_uop(FU_INT, 5'd20, 6'd22, 4'b0000);
    #1;
    if (rn_ready_o)
      $fatal(1, "full dispatch buffer accepted rename");
    rn_valid_i = 2'b00;
    rn_uop0_i = '0;

    @(negedge clk_i);
    recovery_i.valid = 1'b1;
    recovery_i.cause = REC_BRANCH;
    recovery_i.checkpoint_id = 2'd0;
    @(negedge clk_i);
    recovery_i = '0;
    if (!empty_o || occupancy_o != 3'd0)
      $fatal(1, "recovery did not flush dispatch buffer");

    $display("PASS: dispatch_buffer directed tests");
    $finish;
  end

  initial begin
    #10000;
    $fatal(1, "timeout");
  end
endmodule
