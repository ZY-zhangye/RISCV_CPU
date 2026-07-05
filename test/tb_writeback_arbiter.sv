`timescale 1ns/1ps

import core_types_pkg::*;

module tb_writeback_arbiter;
  logic clk_i = 1'b0;
  logic rst_i = 1'b1;

  logic int0_valid_i = 1'b0;
  logic int0_ready_o;
  completion_t int0_i = '0;

  logic int1_valid_i = 1'b0;
  logic int1_ready_o;
  completion_t int1_i = '0;

  logic lsu_valid_i = 1'b0;
  logic lsu_ready_o;
  completion_t lsu_i = '0;

  logic mul_valid_i = 1'b0;
  logic mul_ready_o;
  completion_t mul_i = '0;

  logic div_valid_i = 1'b0;
  logic div_ready_o;
  completion_t div_i = '0;

  recovery_t recovery_i = '0;

  logic [1:0] wb_valid_o;
  completion_t wb_o [0:1];

  logic [1:0] prf_write_valid_o;
  logic [1:0][PRD_W-1:0] prf_write_prd_o;
  logic [1:0][XLEN-1:0] prf_write_data_o;

  logic [1:0] rob_complete_valid_o;
  completion_t rob_complete_o [0:1];

  logic [1:0] wakeup_valid_o;
  logic [1:0][PRD_W-1:0] wakeup_prd_o;

  writeback_arbiter dut (.*);

  always #5 clk_i = ~clk_i;

  function automatic completion_t make_completion(
      input logic [ROB_ID_W-1:0] rob_id,
      input logic [PRD_W-1:0] prd,
      input logic [XLEN-1:0] data,
      input producer_t producer,
      input logic write_prf,
      input logic exception_valid,
      input logic is_store
  );
    completion_t completion;
    begin
      completion = '0;
      completion.valid = 1'b1;
      completion.rob_id = rob_id;
      completion.prd = prd;
      completion.data = data;
      completion.producer = producer;
      completion.write_prf = write_prf;
      completion.exception_valid = exception_valid;
      completion.exception_cause = exception_valid ? 4'd2 : '0;
      completion.exception_tval = exception_valid ? data : '0;
      completion.is_store = is_store;
      make_completion = completion;
    end
  endfunction

  task automatic clear_inputs;
    begin
      int0_valid_i = 1'b0;
      int1_valid_i = 1'b0;
      lsu_valid_i = 1'b0;
      mul_valid_i = 1'b0;
      div_valid_i = 1'b0;
      int0_i = '0;
      int1_i = '0;
      lsu_i = '0;
      mul_i = '0;
      div_i = '0;
      recovery_i = '0;
    end
  endtask

  task automatic expect_idle;
    begin
      if (wb_valid_o != 2'b00 || rob_complete_valid_o != 2'b00 ||
          prf_write_valid_o != 2'b00 || wakeup_valid_o != 2'b00)
        $fatal(1, "expected idle outputs");
    end
  endtask

  task automatic expect_lane(
      input integer lane,
      input logic [ROB_ID_W-1:0] rob_id,
      input logic [PRD_W-1:0] prd,
      input logic [XLEN-1:0] data,
      input logic prf_write
  );
    begin
      if (!wb_valid_o[lane] || !rob_complete_valid_o[lane])
        $fatal(1, "lane %0d missing writeback", lane);
      if (wb_o[lane].rob_id !== rob_id || wb_o[lane].prd !== prd ||
          wb_o[lane].data !== data || rob_complete_o[lane] !== wb_o[lane])
        $fatal(1, "lane %0d payload mismatch rob=%0d prd=%0d data=%h",
               lane, wb_o[lane].rob_id, wb_o[lane].prd, wb_o[lane].data);
      if (prf_write_valid_o[lane] !== prf_write ||
          wakeup_valid_o[lane] !== prf_write)
        $fatal(1, "lane %0d PRF/wakeup valid mismatch", lane);
      if (prf_write) begin
        if (prf_write_prd_o[lane] !== prd ||
            prf_write_data_o[lane] !== data ||
            wakeup_prd_o[lane] !== prd)
          $fatal(1, "lane %0d PRF/wakeup payload mismatch", lane);
      end
    end
  endtask

  task automatic capture_inputs;
    begin
      @(posedge clk_i);
      #1;
      clear_inputs();
      expect_idle();
    end
  endtask

  task automatic advance_to_output;
    begin
      @(posedge clk_i);
      #1;
    end
  endtask

  task automatic clear_output;
    begin
      @(posedge clk_i);
      #1;
      expect_idle();
    end
  endtask

  initial begin
    repeat (2) @(posedge clk_i);
    @(negedge clk_i);
    rst_i = 1'b0;
    clear_inputs();
    @(posedge clk_i);
    #1;
    expect_idle();
    if (!int0_ready_o || !int1_ready_o || !lsu_ready_o || !mul_ready_o || !div_ready_o)
      $fatal(1, "empty producer buffers should be ready");

    // Two PRF writes to opposite banks can issue together.
    @(negedge clk_i);
    int0_valid_i = 1'b1;
    int0_i = make_completion(5'd1, 6'd10, 32'haaaa_0001, PROD_INT0,
                             1'b1, 1'b0, 1'b0);
    int1_valid_i = 1'b1;
    int1_i = make_completion(5'd2, 6'd11, 32'hbbbb_0002, PROD_INT1,
                             1'b1, 1'b0, 1'b0);
    #1;
    if (!int0_ready_o || !int1_ready_o)
      $fatal(1, "input buffer ready mismatch");
    capture_inputs();
    advance_to_output();
    expect_lane(0, 5'd1, 6'd10, 32'haaaa_0001, 1'b1);
    expect_lane(1, 5'd2, 6'd11, 32'hbbbb_0002, 1'b1);
    clear_output();

    // Same-bank PRF conflict: INT0 wins, INT1 remains buffered, LSU pairs.
    @(negedge clk_i);
    int0_valid_i = 1'b1;
    int0_i = make_completion(5'd3, 6'd20, 32'h0000_0003, PROD_INT0,
                             1'b1, 1'b0, 1'b0);
    int1_valid_i = 1'b1;
    int1_i = make_completion(5'd4, 6'd22, 32'h0000_0004, PROD_INT1,
                             1'b1, 1'b0, 1'b0);
    lsu_valid_i = 1'b1;
    lsu_i = make_completion(5'd5, 6'd21, 32'h0000_0005, PROD_LSU,
                            1'b1, 1'b0, 1'b0);
    capture_inputs();
    advance_to_output();
    expect_lane(0, 5'd3, 6'd20, 32'h0000_0003, 1'b1);
    expect_lane(1, 5'd5, 6'd21, 32'h0000_0005, 1'b1);
    advance_to_output();
    expect_lane(0, 5'd4, 6'd22, 32'h0000_0004, 1'b1);
    if (wb_valid_o[1])
      $fatal(1, "unexpected second lane for leftover completion");
    clear_output();

    // Exception does not consume PRF bank, so same-bank normal completion can pair.
    @(negedge clk_i);
    int0_valid_i = 1'b1;
    int0_i = make_completion(5'd6, 6'd30, 32'hbad0_0006, PROD_INT0,
                             1'b1, 1'b1, 1'b0);
    int1_valid_i = 1'b1;
    int1_i = make_completion(5'd7, 6'd32, 32'h0000_0007, PROD_INT1,
                             1'b1, 1'b0, 1'b0);
    capture_inputs();
    advance_to_output();
    expect_lane(0, 5'd6, 6'd30, 32'hbad0_0006, 1'b0);
    expect_lane(1, 5'd7, 6'd32, 32'h0000_0007, 1'b1);
    clear_output();

    // Store completion updates ROB but does not write PRF or wake up IQ.
    @(negedge clk_i);
    lsu_valid_i = 1'b1;
    lsu_i = make_completion(5'd8, 6'd0, 32'h0000_0008, PROD_LSU,
                            1'b0, 1'b0, 1'b1);
    mul_valid_i = 1'b1;
    mul_i = make_completion(5'd9, 6'd33, 32'h0000_0009, PROD_MUL,
                            1'b1, 1'b0, 1'b0);
    capture_inputs();
    advance_to_output();
    expect_lane(0, 5'd8, 6'd0, 32'h0000_0008, 1'b0);
    expect_lane(1, 5'd9, 6'd33, 32'h0000_0009, 1'b1);
    clear_output();

    // Recovery pauses selection and output while preserving buffered producer data.
    @(negedge clk_i);
    int0_valid_i = 1'b1;
    int0_i = make_completion(5'd10, 6'd40, 32'h0000_0010, PROD_INT0,
                             1'b1, 1'b0, 1'b0);
    capture_inputs();
    @(negedge clk_i);
    recovery_i.valid = 1'b1;
    recovery_i.cause = REC_BRANCH;
    #1;
    if (int0_ready_o || wb_valid_o != 2'b00)
      $fatal(1, "recovery pause should block ready/output");
    @(posedge clk_i);
    #1;
    recovery_i = '0;
    #1;
    if (!int0_ready_o)
      $fatal(1, "buffered producer should become selectable after recovery");
    advance_to_output();
    expect_lane(0, 5'd10, 6'd40, 32'h0000_0010, 1'b1);
    clear_output();

    $display("PASS: writeback_arbiter directed tests");
    $finish;
  end

  initial begin
    #30000;
    $fatal(1, "timeout");
  end
endmodule
