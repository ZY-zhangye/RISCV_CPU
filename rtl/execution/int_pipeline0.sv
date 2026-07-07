`timescale 1ns/1ps

import core_types_pkg::*;

// int_pipeline0.sv
// INT0 single-cycle integer execution pipe.
//
// Contract:
// - Accepts one execute_uop_t from Operand Read through valid-ready.
// - Computes the INT0 ALU result in the EX cycle and stores it in a local
//   1-entry completion buffer.
// - Does not combinationally bypass raw ALU output to global writeback.
// - Recovery pauses new accepts and kills/updates the buffered result locally.
// - Branch resolution is intentionally not implemented here; INT1/Branch gets a
//   separate pipeline.

module int_pipeline0 (
    input  logic        clk_i,
    input  logic        rst_i,

    input  logic        ex_valid_i,
    output logic        ex_ready_o,
    input  execute_uop_t ex_uop_i,

    output logic        result_valid_o,
    input  logic        result_ready_i,
    output completion_t result_o,

    input  logic        checkpoint_clear_i,
    input  logic [CP_W-1:0] checkpoint_clear_id_i,
    input  recovery_t   recovery_i
);

  completion_t completion_q;
  logic [CHECKPOINTS-1:0] completion_branch_mask_q;
  logic completion_valid_q;
  logic completion_killed;
  logic accept_fire;

  // --------------------------------------------------------------------------
  // Operand and ALU helpers
  // --------------------------------------------------------------------------
  function automatic logic [XLEN-1:0] select_operand_a(input execute_uop_t uop);
    begin
      unique case (uop.alu_op)
        ALU_LUI:   select_operand_a = '0;
        ALU_AUIPC: select_operand_a = uop.pc;
        default:   select_operand_a = uop.need_rs1 ? uop.src1 : '0;
      endcase
    end
  endfunction

  function automatic logic [XLEN-1:0] select_operand_b(input execute_uop_t uop);
    begin
      unique case (uop.alu_op)
        ALU_LUI,
        ALU_AUIPC: select_operand_b = uop.imm;
        default:   select_operand_b = uop.need_rs2 ? uop.src2 : uop.imm;
      endcase
    end
  endfunction

  function automatic logic [XLEN-1:0] alu_result(input execute_uop_t uop);
    logic [XLEN-1:0] op_a;
    logic [XLEN-1:0] op_b;
    logic [4:0] shamt;
    begin
      op_a = select_operand_a(uop);
      op_b = select_operand_b(uop);
      shamt = op_b[4:0];

      unique case (uop.alu_op)
        ALU_ADD,
        ALU_LUI,
        ALU_AUIPC: alu_result = op_a + op_b;
        ALU_SUB:   alu_result = op_a - op_b;
        ALU_SLL:   alu_result = op_a << shamt;
        ALU_SRL:   alu_result = op_a >> shamt;
        ALU_SRA:   alu_result = $signed(op_a) >>> shamt;
        ALU_AND:   alu_result = op_a & op_b;
        ALU_OR:    alu_result = op_a | op_b;
        ALU_XOR:   alu_result = op_a ^ op_b;
        ALU_SLT:   alu_result = {{(XLEN-1){1'b0}}, ($signed(op_a) < $signed(op_b))};
        ALU_SLTU:  alu_result = {{(XLEN-1){1'b0}}, (op_a < op_b)};
        ALU_PASS1: alu_result = op_a;
        default:   alu_result = '0;
      endcase
    end
  endfunction

  function automatic completion_t make_completion(input execute_uop_t uop);
    completion_t completion;
    logic [XLEN-1:0] csr_operand;
    begin
      csr_operand = ((uop.csr_op == CSR_RWI) ||
                     (uop.csr_op == CSR_RSI) ||
                     (uop.csr_op == CSR_RCI)) ?
                    {{(XLEN-5){1'b0}}, uop.csr_zimm} : uop.src1;

      completion = '0;
      completion.valid = 1'b1;
      completion.prd = uop.prd;
      completion.rob_id = uop.rob_id;
      completion.data = (uop.fu_type == FU_CSR) ? csr_operand : alu_result(uop);
      completion.exception_valid = 1'b0;
      completion.exception_cause = '0;
      completion.exception_tval = '0;
      completion.producer = PROD_INT0;
      completion.write_prf = uop.write_rd && (uop.fu_type != FU_CSR);
      completion.is_store = 1'b0;
      completion.branch_mask = uop.branch_mask;
      make_completion = completion;
    end
  endfunction

  function automatic logic [CHECKPOINTS-1:0] clear_checkpoint(
      input logic [CHECKPOINTS-1:0] mask,
      input logic [CP_W-1:0] checkpoint_id
  );
    logic [CHECKPOINTS-1:0] one_hot;
    begin
      one_hot = '0;
      one_hot[checkpoint_id] = 1'b1;
      clear_checkpoint = mask & ~one_hot;
    end
  endfunction

  function automatic logic [CHECKPOINTS-1:0] clear_if_checkpoint_clear(
      input logic [CHECKPOINTS-1:0] mask
  );
    begin
      clear_if_checkpoint_clear = checkpoint_clear_i ?
          clear_checkpoint(mask, checkpoint_clear_id_i) : mask;
    end
  endfunction

  assign completion_killed = recovery_i.valid &&
      ((recovery_i.cause == REC_EXCEPT) ||
       ((recovery_i.cause == REC_BRANCH) &&
        completion_branch_mask_q[recovery_i.checkpoint_id]));

  assign result_valid_o = completion_valid_q && !completion_killed;
  assign result_o = result_valid_o ? completion_q : '0;

  assign ex_ready_o = !recovery_i.valid &&
                      (!completion_valid_q || result_ready_i);
  assign accept_fire = ex_valid_i && ex_ready_o && ex_uop_i.valid;

  // --------------------------------------------------------------------------
  // Local completion buffer
  // --------------------------------------------------------------------------
  always_ff @(posedge clk_i) begin : completion_buffer
    if (rst_i) begin
      completion_q <= '0;
      completion_branch_mask_q <= '0;
      completion_valid_q <= 1'b0;
    end else if (recovery_i.valid) begin
      if (completion_killed) begin
        completion_q <= '0;
        completion_branch_mask_q <= '0;
        completion_valid_q <= 1'b0;
      end else if (completion_valid_q && (recovery_i.cause == REC_BRANCH)) begin
        completion_branch_mask_q <= clear_checkpoint(completion_branch_mask_q,
                                                     recovery_i.checkpoint_id);
        completion_q.branch_mask <= clear_checkpoint(completion_branch_mask_q,
                                                     recovery_i.checkpoint_id);
      end
    end else begin
      if (accept_fire) begin
        completion_q <= make_completion(ex_uop_i);
        completion_q.branch_mask <= clear_if_checkpoint_clear(
            ex_uop_i.branch_mask);
        completion_branch_mask_q <= clear_if_checkpoint_clear(
            ex_uop_i.branch_mask);
        completion_valid_q <= 1'b1;
      end else if (result_valid_o && result_ready_i) begin
        completion_q <= '0;
        completion_branch_mask_q <= '0;
        completion_valid_q <= 1'b0;
      end else if (checkpoint_clear_i && completion_valid_q) begin
        completion_branch_mask_q <= clear_checkpoint(completion_branch_mask_q,
                                                     checkpoint_clear_id_i);
        completion_q.branch_mask <= clear_checkpoint(completion_branch_mask_q,
                                                     checkpoint_clear_id_i);
      end
    end
  end

`ifndef SYNTHESIS
  property result_hold_stable;
    @(posedge clk_i) disable iff (rst_i || recovery_i.valid)
      result_valid_o && !result_ready_i |=> result_valid_o && $stable(result_o);
  endproperty

  assert property (result_hold_stable);

  always_ff @(posedge clk_i) begin : int0_contract_assertions
    if (!rst_i && ex_valid_i && ex_ready_o) begin
      assert (ex_uop_i.valid)
        else $error("int_pipeline0 accepted an invalid execute uop");
      assert ((ex_uop_i.fu_type == FU_INT) ||
              (ex_uop_i.fu_type == FU_CSR))
        else $error("int_pipeline0 accepted an unsupported uop pc=%08h fu=%0d alu=%0d rob=%0d prd=%0d mask=%b",
                    ex_uop_i.pc, ex_uop_i.fu_type, ex_uop_i.alu_op,
                    ex_uop_i.rob_id, ex_uop_i.prd, ex_uop_i.branch_mask);
      assert (ex_uop_i.alu_op != ALU_SLL ||
              ex_uop_i.need_rs2 || (ex_uop_i.imm[31:5] == '0))
        else $error("int_pipeline0 SLL immediate has non-zero high shamt bits");
    end
  end
`endif

endmodule
