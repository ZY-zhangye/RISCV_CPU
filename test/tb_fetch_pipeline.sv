`timescale 1ns/1ps

import core_types_pkg::*;

module tb_fetch_pipeline;
  logic clk_i = 1'b0;
  logic rst_i = 1'b1;
  logic redirect_valid_i = 1'b0;
  logic [31:0] redirect_target_i = '0;
  logic ibuf_ready_i = 1'b1;
  logic fetch_valid_o;
  fetch_packet_t fetch_packet_o;
  logic bp_query_valid_o;
  bp_query_t bp_query_o;
  bp_pred_t bp_result_i = '0;
  logic imem_req_valid_o;
  logic [31:0] imem_req_addr_o;
  logic imem_resp_valid_i = 1'b0;
  logic [127:0] imem_resp_data_i = '0;

  logic branch_enable = 1'b0;
  integer cycle_count = 0;

  fetch_pipeline dut (.*);

  always #5 clk_i = ~clk_i;

  function automatic logic [127:0] memory_block(input logic [31:0] addr);
    memory_block = {addr + 32'd12, addr + 32'd8,
                    addr + 32'd4, addr};
  endfunction

  function automatic bp_pred_t prediction_for(input logic [31:0] addr);
    bp_pred_t prediction;
    prediction = '0;
    if (branch_enable && (addr == 32'h8000_0040)) begin
      prediction.valid      = 1'b1;
      prediction.btb_hit    = 4'b0010;
      prediction.bht_taken  = 4'b0010;
      prediction.btb_slot   = 2'd1;
      prediction.btb_target = 32'h8000_0100;
    end
    return prediction;
  endfunction

  // One-cycle, ordered synchronous IROM and predictor model.
  always_ff @(posedge clk_i) begin
    cycle_count <= cycle_count + 1;
    if (rst_i) begin
      imem_resp_valid_i <= 1'b0;
      imem_resp_data_i  <= '0;
      bp_result_i       <= '0;
    end else begin
      imem_resp_valid_i <= imem_req_valid_o;
      if (imem_req_valid_o)
        imem_resp_data_i <= memory_block(imem_req_addr_o);
      if (bp_query_valid_o)
        bp_result_i <= prediction_for(bp_query_o.pc);
      else
        bp_result_i <= '0;
    end
  end

  task automatic pulse_redirect(input logic [31:0] target);
    @(negedge clk_i);
    redirect_target_i = target;
    redirect_valid_i  = 1'b1;
    @(negedge clk_i);
    redirect_valid_i  = 1'b0;
  endtask

  task automatic wait_packet(input logic [31:0] expected_block);
    while (!fetch_valid_o)
      @(negedge clk_i);
    if (fetch_packet_o.block_pc !== expected_block)
      $fatal(1, "packet block: got %h expected %h",
             fetch_packet_o.block_pc, expected_block);
  endtask

  initial begin
    integer request_number;
    integer previous_request_cycle;
    logic [31:0] expected_address;
    fetch_packet_t stalled_packet;

    repeat (2) @(posedge clk_i);
    @(negedge clk_i);
    rst_i = 1'b0;

    // Once started, an unstalled one-cycle IROM must accept a new sequential
    // block every cycle rather than waiting for the previous F2 packet.
    request_number = 0;
    previous_request_cycle = -1;
    while (request_number < 6) begin
      @(posedge clk_i);
      if (imem_req_valid_o) begin
        expected_address = 32'h8000_0000 + request_number * 16;
        if (imem_req_addr_o !== expected_address)
          $fatal(1, "request %0d: got %h expected %h", request_number,
                 imem_req_addr_o, expected_address);
        if ((previous_request_cycle >= 0) &&
            (cycle_count != previous_request_cycle + 1))
          $fatal(1, "sequential requests were not issued in adjacent cycles");
        previous_request_cycle = cycle_count;
        request_number = request_number + 1;
      end
    end
    // Verify packet contents and then apply backpressure.  The F2 payload must
    // remain stable, and request issue must stop after the reserved response is
    // absorbed by the skid entry.
    wait_packet(32'h8000_0020);
    if (fetch_packet_o.inst[0] !== 32'h8000_0020 ||
        fetch_packet_o.inst[3] !== 32'h8000_002c ||
        fetch_packet_o.slot_valid !== 4'b1111)
      $fatal(1, "bad sequential fetch packet");

    @(negedge clk_i);
    ibuf_ready_i = 1'b0;
    stalled_packet = fetch_packet_o;
    repeat (4) begin
      @(negedge clk_i);
      if (!fetch_valid_o || fetch_packet_o !== stalled_packet)
        $fatal(1, "F2 payload changed while stalled");
    end
    if (imem_req_valid_o)
      $fatal(1, "request issue did not stop after frontend credits filled");
    ibuf_ready_i = 1'b1;
    repeat (2) @(posedge clk_i);

    // Redirect to a block with a predicted-taken branch in slot 1.  Sequential
    // younger requests may have reached IROM, but none may escape to the IBUF.
    branch_enable = 1'b1;
    pulse_redirect(32'h8000_0040);
    wait_packet(32'h8000_0040);
    if (!fetch_packet_o.pred_taken ||
        fetch_packet_o.pred_slot !== 2'd1 ||
        fetch_packet_o.pred_target !== 32'h8000_0100 ||
        fetch_packet_o.slot_valid !== 4'b0011)
      $fatal(1, "bad predicted-taken packet");

    @(posedge clk_i);
    @(negedge clk_i);
    wait_packet(32'h8000_0100);

    // Misaligned redirects create one synthetic exception packet without an
    // IROM access for the bad address.
    branch_enable = 1'b0;
    pulse_redirect(32'h8000_0182);
    wait_packet(32'h8000_0180);
    if (!fetch_packet_o.exception_valid ||
        fetch_packet_o.exception_cause !== 4'd0 ||
        fetch_packet_o.exception_tval !== 32'h8000_0182 ||
        fetch_packet_o.slot_valid !== 4'b0001)
      $fatal(1, "bad misaligned fetch exception packet");

    $display("PASS: elastic fetch_pipeline directed tests");
    $finish;
  end

  initial begin
    #4000;
    $fatal(1, "timeout");
  end
endmodule
