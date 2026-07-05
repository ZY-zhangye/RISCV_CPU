`timescale 1ns/1ps

import core_types_pkg::*;

// int_branch_pipeline1.sv
// INT1 simple integer and branch execution pipe.
//
// Contract:
// - Accepts one execute_uop_t from Operand Read through valid-ready.
// - Computes simple INT1 ALU or branch/JAL/JALR result in one EX cycle.
// - Stores completion in a local 1-entry buffer before global writeback.
// - Emits branch_resolve_t as a one-cycle registered pulse; recovery_controller
//   consumes the pulse and owns all global flush/redirect side effects.
// - INT1 intentionally excludes the full barrel shifter. issue_arbiter should
//   route shift operations to INT0.

module int_branch_pipeline1 (
    input  logic          clk_i,
    input  logic          rst_i,

    input  logic          ex_valid_i,
    output logic          ex_ready_o,
    input  execute_uop_t  ex_uop_i,

    output logic          result_valid_o,
    input  logic          result_ready_i,
    output completion_t   result_o,

    output branch_resolve_t branch_event_o,

    input  recovery_t     recovery_i
);

  completion_t completion_q;
  logic [CHECKPOINTS-1:0] completion_branch_mask_q;
  logic completion_valid_q;
  logic completion_killed;

  branch_resolve_t branch_event_q;
  logic [CHECKPOINTS-1:0] branch_event_mask_q;
  logic branch_event_killed;

  logic accept_fire;

  // --------------------------------------------------------------------------
  // Common helpers
  // --------------------------------------------------------------------------
  function automatic logic [XLEN-1:0] operand_a(input execute_uop_t uop);
    begin
      unique case (uop.alu_op)
        ALU_LUI:   operand_a = '0;
        ALU_AUIPC: operand_a = uop.pc;
        default:   operand_a = uop.need_rs1 ? uop.src1 : '0;
      endcase
    end
  endfunction

  function automatic logic [XLEN-1:0] operand_b(input execute_uop_t uop);
    begin
      unique case (uop.alu_op)
        ALU_LUI,
        ALU_AUIPC: operand_b = uop.imm;
        default:   operand_b = uop.need_rs2 ? uop.src2 : uop.imm;
      endcase
    end
  endfunction

  function automatic logic [XLEN-1:0] simple_alu_result(input execute_uop_t uop);
    logic [XLEN-1:0] op_a;
    logic [XLEN-1:0] op_b;
    begin
      op_a = operand_a(uop);
      op_b = operand_b(uop);
      unique case (uop.alu_op)
        ALU_ADD,
        ALU_LUI,
        ALU_AUIPC: simple_alu_result = op_a + op_b;
        ALU_SUB:   simple_alu_result = op_a - op_b;
        ALU_AND:   simple_alu_result = op_a & op_b;
        ALU_OR:    simple_alu_result = op_a | op_b;
        ALU_XOR:   simple_alu_result = op_a ^ op_b;
        ALU_SLT:   simple_alu_result = {{(XLEN-1){1'b0}}, ($signed(op_a) < $signed(op_b))};
        ALU_SLTU:  simple_alu_result = {{(XLEN-1){1'b0}}, (op_a < op_b)};
        ALU_PASS1: simple_alu_result = op_a;
        default:   simple_alu_result = '0;
      endcase
    end
  endfunction

  function automatic logic branch_taken(input execute_uop_t uop);
    begin
      unique case (uop.branch_op)
        BR_EQ:   branch_taken = (uop.src1 == uop.src2);
        BR_NE:   branch_taken = (uop.src1 != uop.src2);
        BR_LT:   branch_taken = ($signed(uop.src1) < $signed(uop.src2));
        BR_GE:   branch_taken = ($signed(uop.src1) >= $signed(uop.src2));
        BR_LTU:  branch_taken = (uop.src1 < uop.src2);
        BR_GEU:  branch_taken = (uop.src1 >= uop.src2);
        BR_JAL,
        BR_JALR: branch_taken = 1'b1;
        default: branch_taken = 1'b0;
      endcase
    end
  endfunction

  function automatic logic is_jump(input execute_uop_t uop);
    begin
      is_jump = (uop.branch_op == BR_JAL) || (uop.branch_op == BR_JALR);
    end
  endfunction

  function automatic logic [XLEN-1:0] branch_target(input execute_uop_t uop);
    logic [XLEN-1:0] raw_target;
    begin
      unique case (uop.branch_op)
        BR_JALR: begin
          raw_target = uop.src1 + uop.imm;
          branch_target = {raw_target[XLEN-1:1], 1'b0};
        end
        default: branch_target = uop.pc + uop.imm;
      endcase
    end
  endfunction

  function automatic logic branch_misaligned(input execute_uop_t uop);
    logic taken;
    logic [XLEN-1:0] target;
    begin
      taken = branch_taken(uop);
      target = branch_target(uop);
      branch_misaligned = (uop.fu_type == FU_BRANCH) && taken &&
                          (target[1:0] != 2'b00);
    end
  endfunction

  function automatic branch_resolve_t make_branch_event(input execute_uop_t uop);
    branch_resolve_t branch_resolve;
    logic actual_taken;
    logic [XLEN-1:0] taken_target;
    logic [XLEN-1:0] redirect_pc;
    begin
      actual_taken = branch_taken(uop);
      taken_target = branch_target(uop);
      redirect_pc = actual_taken ? taken_target : (uop.pc + 32'd4);

      branch_resolve = '0;
      branch_resolve.valid = (uop.fu_type == FU_BRANCH);
      branch_resolve.rob_id = uop.rob_id;
      branch_resolve.checkpoint_id = uop.checkpoint_id;
      branch_resolve.actual_taken = actual_taken;
      branch_resolve.actual_target = redirect_pc;
      branch_resolve.mispredict = (uop.pred_taken != actual_taken) ||
                                  (actual_taken && (uop.pred_target != taken_target));
      branch_resolve.redirect_pc = redirect_pc;
      branch_resolve.update.pc = uop.pc;
      branch_resolve.update.target = taken_target;
      branch_resolve.update.taken = actual_taken;
      branch_resolve.update.is_branch = !is_jump(uop);
      branch_resolve.update.is_jal = (uop.branch_op == BR_JAL);
      branch_resolve.update.is_jalr = (uop.branch_op == BR_JALR);
      make_branch_event = branch_resolve;
    end
  endfunction

  function automatic completion_t make_completion(input execute_uop_t uop);
    completion_t completion;
    logic is_branch_uop;
    logic is_exception;
    begin
      is_branch_uop = (uop.fu_type == FU_BRANCH);
      is_exception = branch_misaligned(uop);

      completion = '0;
      completion.valid = 1'b1;
      completion.prd = uop.prd;
      completion.rob_id = uop.rob_id;
      if (is_branch_uop && is_jump(uop))
        completion.data = uop.pc + 32'd4;
      else if (is_branch_uop)
        completion.data = '0;
      else
        completion.data = simple_alu_result(uop);
      completion.exception_valid = is_exception;
      completion.exception_cause = is_exception ? 4'd0 : '0; // instruction-address-misaligned
      completion.exception_tval = is_exception ? branch_target(uop) : '0;
      completion.producer = PROD_INT1;
      completion.write_prf = uop.write_rd && !is_exception;
      completion.is_store = 1'b0;
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

  assign completion_killed = recovery_i.valid &&
      ((recovery_i.cause == REC_EXCEPT) ||
       ((recovery_i.cause == REC_BRANCH) &&
        completion_branch_mask_q[recovery_i.checkpoint_id]));

  assign branch_event_killed = recovery_i.valid &&
      ((recovery_i.cause == REC_EXCEPT) ||
       ((recovery_i.cause == REC_BRANCH) &&
        branch_event_mask_q[recovery_i.checkpoint_id]));

  assign result_valid_o = completion_valid_q && !completion_killed;
  assign result_o = result_valid_o ? completion_q : '0;

  assign branch_event_o = (!branch_event_killed && branch_event_q.valid) ?
                          branch_event_q : '0;

  assign ex_ready_o = !recovery_i.valid &&
                      (!completion_valid_q || result_ready_i);
  assign accept_fire = ex_valid_i && ex_ready_o && ex_uop_i.valid;

  // --------------------------------------------------------------------------
  // Local completion buffer and branch event pulse
  // --------------------------------------------------------------------------
  always_ff @(posedge clk_i) begin : pipeline_state
    if (rst_i) begin
      completion_q <= '0;
      completion_branch_mask_q <= '0;
      completion_valid_q <= 1'b0;
      branch_event_q <= '0;
      branch_event_mask_q <= '0;
    end else if (recovery_i.valid) begin
      branch_event_q <= '0;
      branch_event_mask_q <= '0;

      if (completion_killed) begin
        completion_q <= '0;
        completion_branch_mask_q <= '0;
        completion_valid_q <= 1'b0;
      end else if (completion_valid_q && (recovery_i.cause == REC_BRANCH)) begin
        completion_branch_mask_q <= clear_checkpoint(completion_branch_mask_q,
                                                     recovery_i.checkpoint_id);
      end
    end else begin
      branch_event_q <= '0;
      branch_event_mask_q <= '0;

      if (accept_fire) begin
        completion_q <= make_completion(ex_uop_i);
        completion_branch_mask_q <= ex_uop_i.branch_mask;
        completion_valid_q <= 1'b1;

        branch_event_q <= make_branch_event(ex_uop_i);
        branch_event_mask_q <= ex_uop_i.branch_mask;
      end else if (result_valid_o && result_ready_i) begin
        completion_q <= '0;
        completion_branch_mask_q <= '0;
        completion_valid_q <= 1'b0;
      end
    end
  end

`ifndef SYNTHESIS
  property result_hold_stable;
    @(posedge clk_i) disable iff (rst_i || recovery_i.valid)
      result_valid_o && !result_ready_i |=> result_valid_o && $stable(result_o);
  endproperty

  assert property (result_hold_stable);

  always_ff @(posedge clk_i) begin : int1_contract_assertions
    if (!rst_i && ex_valid_i && ex_ready_o) begin
      assert (ex_uop_i.valid)
        else $error("int_branch_pipeline1 accepted an invalid execute uop");
      assert ((ex_uop_i.fu_type == FU_INT) || (ex_uop_i.fu_type == FU_BRANCH))
        else $error("int_branch_pipeline1 accepted unsupported FU");
      assert ((ex_uop_i.alu_op != ALU_SLL) &&
              (ex_uop_i.alu_op != ALU_SRL) &&
              (ex_uop_i.alu_op != ALU_SRA))
        else $error("int_branch_pipeline1 received a shift uop");
    end

    if (!rst_i && branch_event_o.valid) begin
      assert (branch_event_o.update.is_branch ^
              branch_event_o.update.is_jal ^
              branch_event_o.update.is_jalr)
        else $error("branch update type must be one-hot");
    end
  end
`endif

endmodule
