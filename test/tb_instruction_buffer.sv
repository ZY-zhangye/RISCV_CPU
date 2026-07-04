`timescale 1ns/1ps

import core_types_pkg::*;

module tb_instruction_buffer;
  logic clk_i = 1'b0;
  logic rst_i = 1'b1;
  logic fetch_valid_i = 1'b0;
  logic fetch_ready_o;
  fetch_packet_t fetch_packet_i = '0;
  logic [1:0] decode_valid_o;
  logic decode_ready_i = 1'b0;
  fetch_slot_t decode_slot0_o;
  fetch_slot_t decode_slot1_o;
  logic flush_i = 1'b0;
  logic [3:0] occupancy_o;

  instruction_buffer dut (.*);

  always #5 clk_i = ~clk_i;

  function automatic fetch_packet_t make_packet(
      input logic [31:0] block_pc,
      input logic [3:0]  slot_valid,
      input logic [7:0]  fetch_id
  );
    fetch_packet_t packet;
    packet = '0;
    packet.block_pc = block_pc;
    packet.inst[0] = block_pc;
    packet.inst[1] = block_pc + 32'd4;
    packet.inst[2] = block_pc + 32'd8;
    packet.inst[3] = block_pc + 32'd12;
    packet.slot_valid = slot_valid;
    packet.fetch_id = fetch_id;
    return packet;
  endfunction

  task automatic enqueue_packet(input fetch_packet_t packet);
    @(negedge clk_i);
    fetch_packet_i = packet;
    fetch_valid_i  = 1'b1;
    if (!fetch_ready_o)
      $fatal(1, "buffer unexpectedly rejected packet with mask %b",
             packet.slot_valid);
    @(negedge clk_i);
    fetch_valid_i  = 1'b0;
    fetch_packet_i = '0;
  endtask

  task automatic consume_pair(
      input logic [31:0] expected_pc0,
      input logic [31:0] expected_pc1
  );
    while (decode_valid_o != 2'b11)
      @(negedge clk_i);
    if ((decode_slot0_o.pc !== expected_pc0) ||
        (decode_slot1_o.pc !== expected_pc1))
      $fatal(1, "decode pair: got %h/%h expected %h/%h",
             decode_slot0_o.pc, decode_slot1_o.pc,
             expected_pc0, expected_pc1);
    decode_ready_i = 1'b1;
    @(posedge clk_i);
    @(negedge clk_i);
    decode_ready_i = 1'b0;
  endtask

  initial begin
    fetch_packet_t packet;
    logic [1:0] stalled_valid;
    fetch_slot_t stalled_slot0;
    fetch_slot_t stalled_slot1;

    repeat (2) @(posedge clk_i);
    @(negedge clk_i);
    rst_i = 1'b0;

    // Fill all eight entries while Decode is stalled.
    enqueue_packet(make_packet(32'h8000_0000, 4'b1111, 8'h10));
    while (decode_valid_o != 2'b11)
      @(negedge clk_i);
    stalled_valid = decode_valid_o;
    stalled_slot0 = decode_slot0_o;
    stalled_slot1 = decode_slot1_o;

    enqueue_packet(make_packet(32'h8000_0010, 4'b1111, 8'h11));
    if (occupancy_o !== 4'd8)
      $fatal(1, "full occupancy: got %0d", occupancy_o);
    if (decode_valid_o !== stalled_valid ||
        decode_slot0_o !== stalled_slot0 ||
        decode_slot1_o !== stalled_slot1)
      $fatal(1, "decode bundle changed while stalled");

    packet = make_packet(32'h8000_0020, 4'b0001, 8'h12);
    fetch_packet_i = packet;
    fetch_valid_i = 1'b1;
    #1;
    if (fetch_ready_o)
      $fatal(1, "full buffer asserted fetch_ready");
    fetch_valid_i = 1'b0;
    fetch_packet_i = '0;

    // Drain in program order.  This also wraps both ring pointers to zero.
    consume_pair(32'h8000_0000, 32'h8000_0004);
    consume_pair(32'h8000_0008, 32'h8000_000c);
    consume_pair(32'h8000_0010, 32'h8000_0014);
    consume_pair(32'h8000_0018, 32'h8000_001c);
    if (occupancy_o !== 4'd0 || decode_valid_o !== 2'b00)
      $fatal(1, "buffer did not drain to empty");

    // Sparse input slots are compacted while retaining their exact PCs.
    packet = make_packet(32'h8000_0100, 4'b1100, 8'h20);
    packet.pred_taken  = 1'b1;
    packet.pred_slot   = 2'd2;
    packet.pred_target = 32'h8000_0200;
    enqueue_packet(packet);
    while (decode_valid_o != 2'b11)
      @(negedge clk_i);
    if (decode_slot0_o.pc !== 32'h8000_0108 ||
        decode_slot1_o.pc !== 32'h8000_010c ||
        !decode_slot0_o.pred_taken ||
        decode_slot0_o.pred_target !== 32'h8000_0200 ||
        decode_slot1_o.pred_taken)
      $fatal(1, "sparse compaction or prediction metadata failed");
    consume_pair(32'h8000_0108, 32'h8000_010c);

    // Fetch exception metadata follows the sole valid instruction slot.
    packet = make_packet(32'h8000_0180, 4'b0010, 8'h21);
    packet.exception_valid = 1'b1;
    packet.exception_cause = 4'd0;
    packet.exception_tval  = 32'h8000_0182;
    enqueue_packet(packet);
    while (decode_valid_o != 2'b01)
      @(negedge clk_i);
    if (decode_slot0_o.pc !== 32'h8000_0184 ||
        !decode_slot0_o.exception_valid ||
        decode_slot0_o.exception_cause !== 4'd0 ||
        decode_slot0_o.exception_tval !== 32'h8000_0182)
      $fatal(1, "fetch exception metadata failed");

    // Flush dominates a simultaneous enqueue and clears any held output.
    @(negedge clk_i);
    flush_i = 1'b1;
    fetch_valid_i = 1'b1;
    fetch_packet_i = make_packet(32'h8000_0300, 4'b1111, 8'h30);
    #1;
    if (fetch_ready_o)
      $fatal(1, "fetch_ready asserted during flush");
    @(negedge clk_i);
    flush_i = 1'b0;
    fetch_valid_i = 1'b0;
    fetch_packet_i = '0;
    if (occupancy_o !== 4'd0 || decode_valid_o !== 2'b00)
      $fatal(1, "flush did not empty instruction buffer");

    $display("PASS: instruction_buffer directed tests");
    $finish;
  end

  initial begin
    #3000;
    $fatal(1, "timeout");
  end
endmodule
