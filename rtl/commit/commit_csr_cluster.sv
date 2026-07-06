`timescale 1ns/1ps

import core_types_pkg::*;

// Commit-side integration for ordinary retirement, Stores, precise exceptions,
// commit-time CSR read/modify/write, MRET, ECALL/EBREAK, and FENCE.
module commit_csr_cluster #(
    parameter logic [XLEN-1:0] HART_ID = '0,
    parameter logic [XLEN-1:0] RESET_MTVEC = RESET_PC
) (
    input  logic                         clk_i,
    input  logic                         rst_i,

    input  logic [1:0]                   rob_head_valid_i,
    input  rob_entry_t                   rob_head0_i,
    input  rob_entry_t                   rob_head1_i,
    output logic [1:0]                   retire_count_o,

    output commit_map_t                  commit_map0_o,
    output commit_map_t                  commit_map1_o,
    output logic [1:0]                   reclaim_valid_o,
    output logic [1:0][PRD_W-1:0]        reclaim_prd_o,
    input  logic                         reclaim_ready_i,

    output logic                         store_commit_valid_o,
    output logic [SQ_ID_W-1:0]           store_commit_sq_id_o,
    input  logic                         store_commit_ready_i,
    input  logic                         store_commit_done_i,

    output logic                         csr_wb_valid_o,
    output logic [PRD_W-1:0]             csr_wb_prd_o,
    output logic [XLEN-1:0]              csr_wb_data_o,
    input  logic                         csr_wb_ready_i,
    input  logic                         recovery_busy_i,

    output recovery_t                    recovery_o,
    output logic [1:0]                   instret_count_o,
    output logic                         store_pending_o,

    output logic [XLEN-1:0]              mstatus_o,
    output logic [XLEN-1:0]              mtvec_o,
    output logic [XLEN-1:0]              mepc_o,
    output logic [XLEN-1:0]              mcause_o,
    output logic [XLEN-1:0]              mtval_o
);

  localparam logic [3:0] EXC_BREAKPOINT = 4'd3;
  localparam logic [3:0] EXC_ECALL_M = 4'd11;
  localparam logic [3:0] EXC_ILLEGAL = 4'd2;

  logic [1:0] base_head_valid;
  logic [1:0] base_retire_count;
  commit_map_t base_commit_map0;
  commit_map_t base_commit_map1;
  logic [1:0] base_reclaim_valid;
  logic [1:0][PRD_W-1:0] base_reclaim_prd;
  logic base_exception_valid;
  logic [XLEN-1:0] base_exception_pc;
  logic [3:0] base_exception_cause;
  logic [XLEN-1:0] base_exception_tval;
  recovery_t base_recovery;
  logic [1:0] base_instret_count;

  logic head0_ready;
  logic head0_special;
  logic csr_command;
  logic mret_command;
  logic ecall_command;
  logic ebreak_command;
  logic fence_command;
  logic special_retire;
  logic special_reclaim_request;
  logic special_exception;
  logic [3:0] special_exception_cause;
  logic [XLEN-1:0] special_exception_tval;

  logic csr_ready;
  logic csr_result_valid;
  logic [XLEN-1:0] csr_rdata;
  logic csr_illegal;
  logic [XLEN-1:0] exception_vector;
  logic [XLEN-1:0] mret_vector;
  logic csr_exception_valid;
  logic [XLEN-1:0] csr_exception_pc;
  logic [3:0] csr_exception_cause;
  logic [XLEN-1:0] csr_exception_tval;
  logic [XLEN-1:0] unused_mie;
  logic [1:0] retire_count_counter_q;

  always_ff @(posedge clk_i) begin
    if (rst_i)
      retire_count_counter_q <= '0;
    else
      retire_count_counter_q <= retire_count_o;
  end

  assign head0_ready = !recovery_busy_i && rob_head_valid_i[0] &&
                       rob_head0_i.valid &&
                       rob_head0_i.complete;
  assign csr_command = head0_ready && rob_head0_i.entry.is_csr;
  assign mret_command = head0_ready && rob_head0_i.entry.is_mret;
  assign ecall_command = head0_ready && rob_head0_i.entry.is_ecall;
  assign ebreak_command = head0_ready && rob_head0_i.entry.is_ebreak;
  assign fence_command = head0_ready && rob_head0_i.entry.is_fence;
  assign head0_special = csr_command || mret_command || ecall_command ||
                         ebreak_command || fence_command;
  assign base_head_valid = recovery_busy_i ? 2'b00 :
                           (head0_special ? 2'b00 : rob_head_valid_i);

  assign special_exception = (csr_command && csr_illegal) ||
                             ecall_command || ebreak_command;
  assign special_exception_cause = (csr_command && csr_illegal) ? EXC_ILLEGAL :
                                   (ebreak_command ? EXC_BREAKPOINT : EXC_ECALL_M);
  assign special_exception_tval = (csr_command && csr_illegal) ?
                                  rob_head0_i.entry.inst : '0;
  assign special_reclaim_request = csr_command && csr_ready && !csr_illegal &&
      rob_head0_i.entry.write_rd && (rob_head0_i.entry.arch_rd != 0);
  assign special_retire =
                          (csr_command && csr_ready && !csr_illegal &&
                           (!special_reclaim_request ||
                            (csr_wb_ready_i && reclaim_ready_i))) ||
                          mret_command || fence_command;

  assign csr_exception_valid = base_exception_valid || special_exception;
  assign csr_exception_pc = special_exception ? rob_head0_i.entry.pc :
                                               base_exception_pc;
  assign csr_exception_cause = special_exception ? special_exception_cause :
                                                   base_exception_cause;
  assign csr_exception_tval = special_exception ? special_exception_tval :
                                                 base_exception_tval;

  always_comb begin : output_select
    retire_count_o = base_retire_count;
    commit_map0_o = base_commit_map0;
    commit_map1_o = base_commit_map1;
    reclaim_valid_o = base_reclaim_valid;
    reclaim_prd_o = base_reclaim_prd;
    instret_count_o = base_instret_count;
    recovery_o = base_recovery;

    csr_wb_valid_o = 1'b0;
    csr_wb_prd_o = '0;
    csr_wb_data_o = '0;

    if (head0_special) begin
      retire_count_o = special_retire ? 2'd1 : 2'd0;
      instret_count_o = retire_count_o;
      commit_map0_o = '0;
      commit_map1_o = '0;
      reclaim_valid_o = '0;
      reclaim_prd_o = '0;
      recovery_o = '0;

      if (special_reclaim_request) begin
        reclaim_valid_o[0] = 1'b1;
        reclaim_prd_o[0] = rob_head0_i.entry.old_prd;
      end

      if (special_retire && rob_head0_i.entry.write_rd &&
          (rob_head0_i.entry.arch_rd != 0)) begin
        commit_map0_o.valid = 1'b1;
        commit_map0_o.arch_rd = rob_head0_i.entry.arch_rd;
        commit_map0_o.prd = rob_head0_i.entry.new_prd;
      end

      if (csr_command && special_retire && rob_head0_i.entry.write_rd) begin
        csr_wb_valid_o = 1'b1;
        csr_wb_prd_o = rob_head0_i.entry.new_prd;
        csr_wb_data_o = csr_rdata;
      end

      if (special_exception) begin
        recovery_o.valid = 1'b1;
        recovery_o.cause = REC_EXCEPT;
        recovery_o.redirect_pc = exception_vector;
      end else if (mret_command) begin
        recovery_o.valid = 1'b1;
        recovery_o.cause = REC_EXCEPT;
        recovery_o.redirect_pc = mret_vector;
      end
    end
  end

  commit_unit u_commit_unit (
      .clk_i,
      .rst_i,
      .rob_head_valid_i(base_head_valid),
      .rob_head0_i,
      .rob_head1_i,
      .retire_count_o(base_retire_count),
      .commit_map0_o(base_commit_map0),
      .commit_map1_o(base_commit_map1),
      .reclaim_valid_o(base_reclaim_valid),
      .reclaim_prd_o(base_reclaim_prd),
      .reclaim_ready_i,
      .store_commit_valid_o,
      .store_commit_sq_id_o,
      .store_commit_ready_i,
      .store_commit_done_i,
      .csr_exception_valid_o(base_exception_valid),
      .csr_exception_pc_o(base_exception_pc),
      .csr_exception_cause_o(base_exception_cause),
      .csr_exception_tval_o(base_exception_tval),
      .csr_exception_vector_i(exception_vector),
      .recovery_o(base_recovery),
      .instret_count_o(base_instret_count),
      .store_pending_o
  );

  csr_file #(
      .HART_ID(HART_ID),
      .RESET_MTVEC(RESET_MTVEC)
  ) u_csr_file (
      .clk_i,
      .rst_i,
      .csr_valid_i(csr_command),
      .csr_commit_i(csr_command && special_retire),
      .csr_ready_o(csr_ready),
      .csr_op_i(rob_head0_i.entry.csr_op),
      .csr_addr_i(rob_head0_i.entry.csr_addr),
      .csr_rs1_value_i(rob_head0_i.entry.csr_operand),
      .csr_zimm_i(rob_head0_i.entry.csr_zimm),
      .csr_result_valid_o(csr_result_valid),
      .csr_rdata_o(csr_rdata),
      .csr_illegal_o(csr_illegal),
      .exception_valid_i(csr_exception_valid),
      .exception_pc_i(csr_exception_pc),
      .exception_cause_i(csr_exception_cause),
      .exception_tval_i(csr_exception_tval),
      .exception_vector_o(exception_vector),
      .mret_valid_i(mret_command),
      .mret_vector_o(mret_vector),
      .retire_valid_i(retire_count_counter_q != 0),
      .retire_count_i(retire_count_counter_q),
      .mstatus_o,
      .mie_o(unused_mie),
      .mtvec_o,
      .mepc_o,
      .mcause_o,
      .mtval_o
  );

`ifndef SYNTHESIS
  always_ff @(posedge clk_i) begin : cluster_assertions
    if (!rst_i) begin
      if (head0_special)
        assert (retire_count_o <= 1)
          else $error("serializing system instruction retired with lane1");
      if (special_exception)
        assert ((retire_count_o == 0) && !csr_wb_valid_o)
          else $error("faulting system instruction produced retire/writeback");
      if (csr_wb_valid_o)
        assert (csr_result_valid && !csr_illegal)
          else $error("CSR writeback without legal CSR result");
    end
  end
`endif

endmodule
