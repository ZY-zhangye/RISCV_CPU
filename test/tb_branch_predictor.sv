`timescale 1ns/1ps

import core_types_pkg::*;

module tb_branch_predictor;
  logic clk_i = 1'b0;
  logic rst_i = 1'b1;
  logic query_valid_i = 1'b0;
  bp_query_t query_i = '0;
  bp_pred_t pred_o;
  logic update_valid_i = 1'b0;
  branch_update_t update_i = '0;

  branch_predictor dut (.*);

  always #5 clk_i = ~clk_i;

  task automatic apply_update(input branch_update_t update);
    @(negedge clk_i);
    update_i       = update;
    update_valid_i = 1'b1;
    @(negedge clk_i);
    update_valid_i = 1'b0;
    update_i       = '0;
    // The update is buffered for one cycle before modifying BTB/BHT state.
    @(posedge clk_i);
    @(negedge clk_i);
  endtask

  task automatic check_prediction(
      input logic [31:0] block_pc,
      input logic        expected_valid,
      input logic [3:0]  expected_hit,
      input logic [3:0]  expected_taken,
      input logic [1:0]  expected_slot,
      input logic [31:0] expected_target
  );
    query_i.pc       = block_pc;
    query_i.fetch_id = 8'h5a;
    query_valid_i    = 1'b1;
    @(posedge clk_i);
    @(negedge clk_i);
    query_valid_i = 1'b0;

    if (pred_o.valid !== expected_valid ||
        pred_o.btb_hit !== expected_hit ||
        pred_o.bht_taken !== expected_taken)
      $fatal(1, "prediction mismatch pc=%h valid/hit/taken=%b/%b/%b",
             block_pc, pred_o.valid, pred_o.btb_hit, pred_o.bht_taken);

    if (expected_valid &&
        ((pred_o.btb_slot !== expected_slot) ||
         (pred_o.btb_target !== expected_target)))
      $fatal(1, "prediction payload mismatch pc=%h slot=%0d target=%h",
             block_pc, pred_o.btb_slot, pred_o.btb_target);
  endtask

  function automatic branch_update_t make_update(
      input logic [31:0] pc,
      input logic [31:0] target,
      input logic taken,
      input logic is_branch,
      input logic is_jal,
      input logic is_jalr
  );
    branch_update_t update;
    update = '0;
    update.pc        = pc;
    update.target    = target;
    update.taken     = taken;
    update.is_branch = is_branch;
    update.is_jal    = is_jal;
    update.is_jalr   = is_jalr;
    return update;
  endfunction

  initial begin
    branch_update_t update;

    repeat (2) @(posedge clk_i);
    @(negedge clk_i);
    rst_i = 1'b0;

    // Cold BTB miss.
    check_prediction(32'h8000_0000, 1'b0, 4'b0000, 4'b0000,
                     2'd0, 32'b0);

    // First taken conditional update initializes its BHT counter to 2'b10.
    update = make_update(32'h8000_0004, 32'h8000_0100,
                         1'b1, 1'b1, 1'b0, 1'b0);
    apply_update(update);
    check_prediction(32'h8000_0000, 1'b1, 4'b0010, 4'b0010,
                     2'd1, 32'h8000_0100);

    // A not-taken result moves 10 -> 01 while preserving the BTB target.
    update.taken = 1'b0;
    apply_update(update);
    check_prediction(32'h8000_0000, 1'b1, 4'b0010, 4'b0000,
                     2'd1, 32'h8000_0100);

    // A later control-flow instruction in the same block cannot displace the
    // earlier slot-1 branch.
    apply_update(make_update(32'h8000_000c, 32'h8000_0200,
                             1'b1, 1'b0, 1'b1, 1'b0));
    check_prediction(32'h8000_0000, 1'b1, 4'b0010, 4'b0000,
                     2'd1, 32'h8000_0100);

    // An earlier JAL does replace it and is always predicted taken.
    apply_update(make_update(32'h8000_0000, 32'h8000_0300,
                             1'b1, 1'b0, 1'b1, 1'b0));
    check_prediction(32'h8000_0000, 1'b1, 4'b0001, 4'b0001,
                     2'd0, 32'h8000_0300);

    // JALR uses the most recently resolved BTB target and is unconditional.
    apply_update(make_update(32'h8000_002c, 32'h8000_1234,
                             1'b1, 1'b0, 1'b0, 1'b1));
    check_prediction(32'h8000_0020, 1'b1, 4'b1000, 4'b1000,
                     2'd3, 32'h8000_1234);

    // Same-index, different-tag update replaces the old direct-mapped entry.
    apply_update(make_update(32'h8000_0820, 32'h8000_2000,
                             1'b1, 1'b0, 1'b1, 1'b0));
    check_prediction(32'h8000_0020, 1'b0, 4'b0000, 4'b0000,
                     2'd0, 32'b0);
    check_prediction(32'h8000_0820, 1'b1, 4'b0001, 4'b0001,
                     2'd0, 32'h8000_2000);

    // Two consecutive updates exercise simultaneous FIFO dequeue/enqueue.
    @(negedge clk_i);
    update_i = make_update(32'h8000_0044, 32'h8000_4000,
                           1'b1, 1'b0, 1'b1, 1'b0);
    update_valid_i = 1'b1;
    @(negedge clk_i);
    update_i = make_update(32'h8000_0068, 32'h8000_6000,
                           1'b1, 1'b0, 1'b0, 1'b1);
    @(negedge clk_i);
    update_valid_i = 1'b0;
    update_i = '0;
    repeat (2) @(posedge clk_i);
    @(negedge clk_i);

    check_prediction(32'h8000_0040, 1'b1, 4'b0010, 4'b0010,
                     2'd1, 32'h8000_4000);
    check_prediction(32'h8000_0060, 1'b1, 4'b0100, 4'b0100,
                     2'd2, 32'h8000_6000);

    $display("PASS: branch_predictor directed tests");
    $finish;
  end

  initial begin
    #3000;
    $fatal(1, "timeout");
  end
endmodule
