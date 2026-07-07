`timescale 1ns/1ps

import core_types_pkg::*;

module tb_decode_stage;
  logic clk_i = 1'b0;
  logic rst_i = 1'b1;
  logic [1:0] in_valid_i = 2'b00;
  logic in_ready_o;
  fetch_slot_t fetch_slot0_i = '0;
  fetch_slot_t fetch_slot1_i = '0;
  logic [1:0] out_valid_o;
  logic out_ready_i = 1'b0;
  decoded_uop_t decoded_uop0_o;
  decoded_uop_t decoded_uop1_o;
  logic flush_i = 1'b0;

  decode_stage dut (.*);

  always #5 clk_i = ~clk_i;

  function automatic logic [31:0] enc_r(
      input logic [6:0] funct7,
      input logic [4:0] rs2,
      input logic [4:0] rs1,
      input logic [2:0] funct3,
      input logic [4:0] rd,
      input logic [6:0] opcode
  );
    enc_r = {funct7, rs2, rs1, funct3, rd, opcode};
  endfunction

  function automatic logic [31:0] enc_i(
      input logic [11:0] imm,
      input logic [4:0]  rs1,
      input logic [2:0]  funct3,
      input logic [4:0]  rd,
      input logic [6:0]  opcode
  );
    enc_i = {imm, rs1, funct3, rd, opcode};
  endfunction

  function automatic logic [31:0] enc_s(
      input logic [11:0] imm,
      input logic [4:0]  rs2,
      input logic [4:0]  rs1,
      input logic [2:0]  funct3
  );
    enc_s = {imm[11:5], rs2, rs1, funct3, imm[4:0], 7'b0100011};
  endfunction

  function automatic fetch_slot_t make_slot(input logic [31:0] inst);
    fetch_slot_t slot;
    slot = '0;
    slot.pc = 32'h8000_0100;
    slot.inst = inst;
    slot.pred_taken = 1'b1;
    slot.pred_target = 32'h8000_1000;
    slot.fetch_id = 8'h5a;
    return slot;
  endfunction

  task automatic send_bundle(
      input logic [1:0] valid,
      input fetch_slot_t slot0,
      input fetch_slot_t slot1
  );
    while (!in_ready_o)
      @(negedge clk_i);
    @(negedge clk_i);
    in_valid_i = valid;
    fetch_slot0_i = slot0;
    fetch_slot1_i = slot1;
    @(negedge clk_i);
    in_valid_i = 2'b00;
    fetch_slot0_i = '0;
    fetch_slot1_i = '0;
  endtask

  task automatic consume_output;
    @(negedge clk_i);
    out_ready_i = 1'b1;
    @(negedge clk_i);
    out_ready_i = 1'b0;
  endtask

  initial begin
    decoded_uop_t uop;
    fetch_slot_t slot;
    decoded_uop_t held0;
    decoded_uop_t held1;
    integer funct;

    // Base register ALU and reserved funct7 handling.
    uop = decode_pkg::decode_slot(make_slot(
        enc_r(7'b0000000, 5'd2, 5'd1, 3'b000, 5'd3, 7'b0110011)));
    if (uop.fu_type != FU_INT || uop.alu_op != ALU_ADD ||
        !uop.need_rs1 || !uop.need_rs2 || !uop.write_rd ||
        uop.rs1 != 1 || uop.rs2 != 2 || uop.rd != 3)
      $fatal(1, "ADD decode failed");

    uop = decode_pkg::decode_slot(make_slot(
        enc_r(7'b0100000, 5'd2, 5'd1, 3'b101, 5'd3, 7'b0110011)));
    if (uop.alu_op != ALU_SRA)
      $fatal(1, "SRA decode failed");

    uop = decode_pkg::decode_slot(make_slot(
        enc_r(7'b0100000, 5'd2, 5'd1, 3'b111, 5'd3, 7'b0110011)));
    if (!uop.exception_valid || uop.exception_cause != 4'd2 || uop.write_rd)
      $fatal(1, "reserved OP encoding was not illegal");

    // All eight RV32M funct3 encodings.
    for (funct = 0; funct < 8; funct = funct + 1) begin
      uop = decode_pkg::decode_slot(make_slot(
          enc_r(7'b0000001, 5'd2, 5'd1, funct[2:0], 5'd3,
                7'b0110011)));
      if (funct < 4) begin
        if (uop.fu_type != FU_MUL || uop.mul_op != funct[1:0])
          $fatal(1, "MUL decode failed funct3=%0d", funct);
      end else begin
        if (uop.fu_type != FU_DIV || uop.div_op != (funct - 4))
          $fatal(1, "DIV decode failed funct3=%0d", funct);
      end
    end

    // Immediate ALU, including legal and illegal shifts.
    uop = decode_pkg::decode_slot(make_slot(
        enc_i(12'hfff, 5'd6, 3'b000, 5'd5, 7'b0010011)));
    if (uop.alu_op != ALU_ADD || uop.imm != 32'hffff_ffff)
      $fatal(1, "ADDI sign extension failed");

    uop = decode_pkg::decode_slot(make_slot(
        enc_i({7'b0100000, 5'd7}, 5'd6, 3'b101, 5'd5, 7'b0010011)));
    if (uop.alu_op != ALU_SRA || uop.imm != 7)
      $fatal(1, "SRAI decode failed");

    uop = decode_pkg::decode_slot(make_slot(
        enc_i({7'b0010000, 5'd7}, 5'd6, 3'b101, 5'd5, 7'b0010011)));
    if (!uop.exception_valid || uop.write_rd)
      $fatal(1, "illegal shift-immediate side effects not cleared");

    // Load/store operation classes and sign-extended offsets.
    uop = decode_pkg::decode_slot(make_slot(
        enc_i(12'hffc, 5'd4, 3'b010, 5'd7, 7'b0000011)));
    if (uop.fu_type != FU_LSU || uop.mem_op != MEM_LW ||
        uop.imm != 32'hffff_fffc || !uop.write_rd)
      $fatal(1, "LW decode failed");

    uop = decode_pkg::decode_slot(make_slot(
        enc_s(12'hff8, 5'd7, 5'd4, 3'b010)));
    if (uop.fu_type != FU_LSU || uop.mem_op != MEM_SW ||
        uop.imm != 32'hffff_fff8 || !uop.need_rs2 || uop.write_rd)
      $fatal(1, "SW decode failed");

    // U/J/branch classes.
    uop = decode_pkg::decode_slot(make_slot(32'h1234_52b7)); // LUI x5,0x12345
    if (uop.alu_op != ALU_LUI || uop.imm != 32'h1234_5000)
      $fatal(1, "LUI decode failed");

    uop = decode_pkg::decode_slot(make_slot(32'h0000_00ef)); // JAL x1,0
    if (uop.fu_type != FU_BRANCH || uop.branch_op != BR_JAL ||
        !uop.write_rd)
      $fatal(1, "JAL decode failed");

    uop = decode_pkg::decode_slot(make_slot(32'h0020_8063)); // BEQ x1,x2,0
    if (uop.branch_op != BR_EQ || !uop.need_rs1 || !uop.need_rs2)
      $fatal(1, "BEQ decode failed");

    // Six Zicsr forms preserve CSR address and zimm.
    for (funct = 1; funct <= 7; funct = funct + 1) begin
      if (funct != 4) begin
        uop = decode_pkg::decode_slot(make_slot(
            enc_i(12'h305, 5'd9, funct[2:0], 5'd10, 7'b1110011)));
        if (uop.fu_type != FU_CSR || !uop.serializing ||
            uop.csr_addr != 12'h305 || uop.csr_zimm != 5'd9)
          $fatal(1, "CSR decode failed funct3=%0d", funct);
        if ((funct < 4) != uop.need_rs1)
          $fatal(1, "CSR source mode failed funct3=%0d", funct);
      end
    end

    uop = decode_pkg::decode_slot(make_slot(32'h0000_0073));
    if (!uop.is_ecall || !uop.serializing)
      $fatal(1, "ECALL decode failed");
    uop = decode_pkg::decode_slot(make_slot(32'h0010_0073));
    if (!uop.is_ebreak || !uop.serializing)
      $fatal(1, "EBREAK decode failed");
    uop = decode_pkg::decode_slot(make_slot(32'h3020_0073));
    if (!uop.is_mret || !uop.serializing)
      $fatal(1, "MRET decode failed");
    uop = decode_pkg::decode_slot(make_slot(32'h0000_100f));
    if (!uop.is_fence || !uop.serializing)
      $fatal(1, "FENCE.I decode failed");

    // Fetch exception wins over an otherwise legal instruction.
    slot = make_slot(enc_r(7'b0000000, 5'd2, 5'd1, 3'b000, 5'd3,
                           7'b0110011));
    slot.exception_valid = 1'b1;
    slot.exception_cause = 4'd0;
    slot.exception_tval = 32'h8000_0102;
    uop = decode_pkg::decode_slot(slot);
    if (!uop.exception_valid || uop.exception_cause != 0 ||
        uop.exception_tval != 32'h8000_0102 || uop.write_rd ||
        uop.fu_type != FU_NONE)
      $fatal(1, "fetch exception priority failed");

    // Stage-level dual-lane, stall, and serializing-lane behavior.
    repeat (2) @(posedge clk_i);
    @(negedge clk_i);
    rst_i = 1'b0;

    send_bundle(2'b11,
      make_slot(enc_r(7'b0000000, 5'd2, 5'd1, 3'b000, 5'd3,
                      7'b0110011)),
      make_slot(enc_r(7'b0000001, 5'd2, 5'd1, 3'b000, 5'd4,
                      7'b0110011)));
    if (out_valid_o != 2'b11 || decoded_uop0_o.alu_op != ALU_ADD ||
        decoded_uop1_o.fu_type != FU_MUL)
      $fatal(1, "dual-lane stage output failed valid=%b alu=%0d fu1=%0d",
             out_valid_o, decoded_uop0_o.alu_op, decoded_uop1_o.fu_type);

    held0 = decoded_uop0_o;
    held1 = decoded_uop1_o;
    repeat (2) begin
      @(posedge clk_i);
      #1;
      if (out_valid_o != 2'b11 || decoded_uop0_o !== held0 ||
          decoded_uop1_o !== held1 || in_ready_o)
        $fatal(1, "decode output changed while stalled");
    end
    consume_output();

    send_bundle(2'b11, make_slot(32'h3020_0073),
                make_slot(32'h0020_81b3));
    if (out_valid_o != 2'b11 || !decoded_uop0_o.is_mret ||
        decoded_uop1_o.alu_op != ALU_ADD)
      $fatal(1, "serializing lane0 bundle decode failed");

    @(negedge clk_i);
    flush_i = 1'b1;
    #1;
    if (out_valid_o != 2'b00 || in_ready_o)
      $fatal(1, "flush did not suppress decode interface");
    @(negedge clk_i);
    flush_i = 1'b0;

    $display("PASS: decode_stage directed tests");
    $finish;
  end

  initial begin
    #5000;
    $fatal(1, "timeout");
  end
endmodule
