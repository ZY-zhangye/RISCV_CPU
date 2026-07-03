`timescale 1ns/1ps

import core_types_pkg::*;

module tb_fetch_pipeline;
  logic clk_i = 1'b0;
  logic rst_i = 1'b1;
  logic redirect_valid_i = 1'b0;
  logic [31:0] redirect_target_i = '0;
  logic ibuf_ready_i = 1'b0;
  logic fetch_valid_o;
  fetch_packet_t fetch_packet_o;
  logic bp_query_valid_o;
  bp_query_t bp_query_o;
  bp_pred_t bp_result_i = '0;
  logic imem_req_valid_o;
  logic [31:0] imem_req_addr_o;
  logic imem_resp_valid_i = 1'b0;
  logic [127:0] imem_resp_data_i = '0;

  fetch_pipeline dut (.*);

  always #5 clk_i = ~clk_i;

  task automatic send_response(
      input logic [127:0] data,
      input bp_pred_t pred
  );
    // First let the request be sampled on a rising edge, then return it on a
    // later rising edge as a synchronous memory would.
    @(posedge clk_i);
    @(negedge clk_i);
    imem_resp_data_i  = data;
    imem_resp_valid_i = 1'b1;
    bp_result_i       = pred;
    @(negedge clk_i);
    imem_resp_valid_i = 1'b0;
    bp_result_i       = '0;
  endtask

  task automatic expect_request(input logic [31:0] addr);
    wait (imem_req_valid_o === 1'b1);
    if (imem_req_addr_o !== addr)
      $fatal(1, "request address: got %h expected %h", imem_req_addr_o, addr);
    if (bp_query_o.pc !== addr)
      $fatal(1, "BP query address: got %h expected %h", bp_query_o.pc, addr);
  endtask

  initial begin
    bp_pred_t pred;
    fetch_packet_t stalled_packet;

    repeat (2) @(posedge clk_i);
    @(negedge clk_i);
    rst_i = 1'b0;

    // Reset PC, little-endian slot extraction, and F2 hold under backpressure.
    expect_request(32'h8000_0000);
    pred = '0;
    send_response(128'h4444_4444_3333_3333_2222_2222_1111_1111, pred);
    wait (fetch_valid_o === 1'b1);
    #1;
    if (fetch_packet_o.block_pc !== 32'h8000_0000 ||
        fetch_packet_o.slot_valid !== 4'b1111 ||
        fetch_packet_o.inst[0] !== 32'h1111_1111 ||
        fetch_packet_o.inst[3] !== 32'h4444_4444)
      $fatal(1, "bad first fetch packet");
    stalled_packet = fetch_packet_o;
    repeat (2) begin
      @(posedge clk_i);
      #1;
      if (!fetch_valid_o || fetch_packet_o !== stalled_packet)
        $fatal(1, "F2 payload changed while stalled");
    end

    @(negedge clk_i);
    ibuf_ready_i = 1'b1;
    @(posedge clk_i);
    #1;
    if (fetch_valid_o)
      $fatal(1, "accepted F2 packet did not retire");

    // A predicted branch in slot 1 keeps slots 0..1 and redirects next PC.
    expect_request(32'h8000_0010);
    pred = '0;
    pred.valid      = 1'b1;
    pred.btb_hit    = 4'b0010;
    pred.bht_taken  = 4'b0010;
    pred.btb_slot   = 2'd1;
    pred.btb_target = 32'h8000_0040;
    send_response(128'hdddd_dddd_cccc_cccc_bbbb_bbbb_aaaa_aaaa, pred);
    wait (fetch_valid_o === 1'b1);
    #1;
    if (!fetch_packet_o.pred_taken ||
        fetch_packet_o.pred_slot !== 2'd1 ||
        fetch_packet_o.pred_target !== 32'h8000_0040 ||
        fetch_packet_o.slot_valid !== 4'b0011)
      $fatal(1, "bad predicted-taken packet");
    @(posedge clk_i);
    #1;
    expect_request(32'h8000_0040);

    // Redirect while the 0x40 request is pending.  Its late response must be
    // drained, and the misaligned redirect becomes a synthetic exception.
    @(negedge clk_i);
    redirect_target_i = 32'h8000_0082;
    redirect_valid_i  = 1'b1;
    @(negedge clk_i);
    redirect_valid_i  = 1'b0;
    send_response(128'hffff_ffff_eeee_eeee_dddd_dddd_cccc_cccc, '0);

    wait (fetch_valid_o === 1'b1);
    #1;
    if (!fetch_packet_o.exception_valid ||
        fetch_packet_o.exception_cause !== 4'd0 ||
        fetch_packet_o.exception_tval !== 32'h8000_0082 ||
        fetch_packet_o.slot_valid !== 4'b0001)
      $fatal(1, "bad misaligned fetch exception packet");

    $display("PASS: fetch_pipeline directed tests");
    $finish;
  end

  initial begin
    #2000;
    $fatal(1, "timeout");
  end
endmodule
