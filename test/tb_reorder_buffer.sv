import core_types_pkg::*;

module tb_reorder_buffer;
  logic clk_i = 1'b0;
  logic rst_i = 1'b1;

  logic [1:0] alloc_valid_i = 2'b00;
  logic alloc_ready_o;
  logic [ROB_ID_W-1:0] alloc_rob_id0_o;
  logic [ROB_ID_W-1:0] alloc_rob_id1_o;
  rob_alloc_t alloc_entry0_i = '0;
  rob_alloc_t alloc_entry1_i = '0;

  completion_t complete0_i = '0;
  completion_t complete1_i = '0;

  logic [1:0] head_valid_o;
  rob_entry_t head_entry0_o;
  rob_entry_t head_entry1_o;
  logic [1:0] retire_count_i = 2'd0;

  logic exception_flush_i = 1'b0;
  logic exception_flush_done_o;

  logic branch_clear_valid_i = 1'b0;
  logic [CP_W-1:0] branch_clear_id_i = '0;
  logic branch_clear_done_o;

  logic restore_valid_i = 1'b0;
  logic [ROB_ID_W-1:0] restore_tail_i = '0;
  logic restore_done_o;

  logic busy_o;
  logic empty_o;
  logic full_o;
  logic [5:0] occupancy_o;

  reorder_buffer dut (.*);

  always #5 clk_i = ~clk_i;

  function automatic rob_alloc_t make_entry(
      input logic [31:0] pc,
      input logic [4:0] arch_rd,
      input logic [PRD_W-1:0] new_prd,
      input logic [PRD_W-1:0] old_prd,
      input logic [CHECKPOINTS-1:0] branch_mask
  );
    rob_alloc_t entry;
    entry = '0;
    entry.pc = pc;
    entry.arch_rd = arch_rd;
    entry.new_prd = new_prd;
    entry.old_prd = old_prd;
    entry.write_rd = (arch_rd != 0);
    entry.branch_mask = branch_mask;
    return entry;
  endfunction

  function automatic completion_t make_completion(
      input logic [ROB_ID_W-1:0] rob_id,
      input logic exception_valid
  );
    completion_t completion;
    completion = '0;
    completion.valid = 1'b1;
    completion.rob_id = rob_id;
    completion.exception_valid = exception_valid;
    completion.exception_cause = 4'hd;
    completion.exception_tval = 32'hbad0_0000 | rob_id;
    completion.write_prf = !exception_valid;
    return completion;
  endfunction

  task automatic allocate_bundle(
      input logic [1:0] valid,
      input rob_alloc_t entry0,
      input rob_alloc_t entry1,
      output logic [ROB_ID_W-1:0] id0,
      output logic [ROB_ID_W-1:0] id1
  );
    @(negedge clk_i);
    alloc_valid_i = valid;
    alloc_entry0_i = entry0;
    alloc_entry1_i = entry1;
    if (!alloc_ready_o)
      $fatal(1, "ROB rejected allocation valid=%b", valid);
    id0 = alloc_rob_id0_o;
    id1 = alloc_rob_id1_o;
    @(negedge clk_i);
    alloc_valid_i = 2'b00;
    alloc_entry0_i = '0;
    alloc_entry1_i = '0;
  endtask

  task automatic complete_pair(
      input logic [ROB_ID_W-1:0] id0,
      input logic [ROB_ID_W-1:0] id1
  );
    @(negedge clk_i);
    complete0_i = make_completion(id0, 1'b0);
    complete1_i = make_completion(id1, 1'b0);
    @(negedge clk_i);
    complete0_i = '0;
    complete1_i = '0;
  endtask

  task automatic retire_row(input logic [1:0] count);
    @(negedge clk_i);
    retire_count_i = count;
    @(negedge clk_i);
    retire_count_i = 2'd0;
  endtask

  initial begin
    logic [ROB_ID_W-1:0] id0;
    logic [ROB_ID_W-1:0] id1;
    logic [ROB_ID_W-1:0] id2;
    logic [ROB_ID_W-1:0] id3;
    logic [ROB_ID_W-1:0] id4;
    logic [ROB_ID_W-1:0] id5;
    integer idx;

    repeat (2) @(posedge clk_i);
    @(negedge clk_i);
    rst_i = 1'b0;

    if (!empty_o || occupancy_o != 0)
      $fatal(1, "ROB reset state mismatch");

    allocate_bundle(2'b11,
                    make_entry(32'h1000, 5'd1, 6'd33, 6'd1, 4'b0010),
                    make_entry(32'h1004, 5'd2, 6'd34, 6'd2, 4'b0010),
                    id0, id1);

    if (id0 != 5'd0 || id1 != 5'd1 || occupancy_o != 6'd2 ||
        head_valid_o != 2'b11)
      $fatal(1, "initial dual allocation mismatch id=%0d/%0d occ=%0d head=%b",
             id0, id1, occupancy_o, head_valid_o);

    complete_pair(id0, id1);
    if (!head_entry0_o.complete || !head_entry1_o.complete)
      $fatal(1, "head completion not reflected");

    retire_row(2'd2);
    if (!empty_o || occupancy_o != 6'd0 || head_valid_o != 2'b00)
      $fatal(1, "dual retire mismatch occ=%0d head=%b", occupancy_o,
             head_valid_o);

    allocate_bundle(2'b01,
                    make_entry(32'h2000, 5'd3, 6'd35, 6'd3, 4'b0100),
                    '0, id2, id3);
    if (id2 != 5'd2 || id3 != 5'd3 || occupancy_o != 6'd1 ||
        head_valid_o != 2'b01)
      $fatal(1, "single allocation did not consume a new row");

    @(negedge clk_i);
    complete0_i = make_completion(id2, 1'b1);
    @(negedge clk_i);
    complete0_i = '0;
    if (!head_entry0_o.complete || !head_entry0_o.entry.exception_valid ||
        head_entry0_o.entry.exception_cause != 4'hd)
      $fatal(1, "exception completion not captured");

    retire_row(2'd1);
    if (!empty_o || occupancy_o != 6'd0)
      $fatal(1, "single retire mismatch occ=%0d", occupancy_o);

    allocate_bundle(2'b11,
                    make_entry(32'h3000, 5'd4, 6'd36, 6'd4, 4'b0011),
                    make_entry(32'h3004, 5'd5, 6'd37, 6'd5, 4'b0011),
                    id4, id5);
    @(negedge clk_i);
    branch_clear_valid_i = 1'b1;
    branch_clear_id_i = 2'd0;
    @(negedge clk_i);
    branch_clear_valid_i = 1'b0;
    while (!branch_clear_done_o) begin
      if (!busy_o)
        $fatal(1, "branch clear dropped busy");
      @(negedge clk_i);
    end
    if (head_entry0_o.entry.branch_mask[0] ||
        head_entry1_o.entry.branch_mask[0] ||
        !head_entry0_o.entry.branch_mask[1] ||
        !head_entry1_o.entry.branch_mask[1])
      $fatal(1, "branch clear mask result mismatch");

    allocate_bundle(2'b11,
                    make_entry(32'h4000, 5'd6, 6'd38, 6'd6, 4'b0000),
                    make_entry(32'h4004, 5'd7, 6'd39, 6'd7, 4'b0000),
                    id0, id1);
    allocate_bundle(2'b01,
                    make_entry(32'h5000, 5'd8, 6'd40, 6'd8, 4'b0000),
                    '0, id2, id3);
    if (occupancy_o != 6'd5)
      $fatal(1, "restore setup occupancy mismatch: %0d", occupancy_o);

    @(negedge clk_i);
    restore_valid_i = 1'b1;
    restore_tail_i = id5 + 1'b1; // checkpoint tail after the branch row
    @(negedge clk_i);
    restore_valid_i = 1'b0;
    while (!restore_done_o) begin
      if (!busy_o)
        $fatal(1, "restore dropped busy");
      @(negedge clk_i);
    end

    if (occupancy_o != 6'd2 || head_valid_o != 2'b11 ||
        head_entry0_o.entry.pc != 32'h3000 ||
        head_entry1_o.entry.pc != 32'h3004)
      $fatal(1, "restore did not keep only the checkpoint row occ=%0d head=%b",
             occupancy_o, head_valid_o);

    // Exception flush preempts an active branch-clear scan and resets all ROB
    // pointers/counters without requiring payload-array clearing.
    @(negedge clk_i);
    branch_clear_valid_i = 1'b1;
    branch_clear_id_i = 2'd1;
    @(posedge clk_i); #1;
    branch_clear_valid_i = 1'b0;
    if (!busy_o)
      $fatal(1, "exception preemption setup did not start branch scan");
    @(negedge clk_i);
    exception_flush_i = 1'b1;
    @(posedge clk_i); #1;
    exception_flush_i = 1'b0;
    if (!exception_flush_done_o || busy_o || !empty_o ||
        occupancy_o != 0 || head_valid_o != 2'b00)
      $fatal(1, "exception flush did not reset ROB state");
    if (alloc_rob_id0_o != 0 || alloc_rob_id1_o != 1)
      $fatal(1, "exception flush did not reset ROB tail IDs");

    for (idx = 0; idx < 16; idx = idx + 1) begin
      allocate_bundle(2'b01,
                      make_entry(32'h6000 + idx * 4, 5'd9, 6'd41, 6'd9, 4'b0),
                      '0, id0, id1);
    end
    if (!full_o)
      $fatal(1, "ROB did not report full after filling rows");
    @(negedge clk_i);
    alloc_valid_i = 2'b01;
    alloc_entry0_i = make_entry(32'h7000, 5'd10, 6'd42, 6'd10, 4'b0);
    if (alloc_ready_o)
      $fatal(1, "full ROB accepted allocation");
    @(negedge clk_i);
    alloc_valid_i = 2'b00;
    alloc_entry0_i = '0;

    $display("PASS: reorder_buffer directed tests");
    $finish;
  end

  initial begin
    #20000;
    $fatal(1, "timeout");
  end
endmodule
