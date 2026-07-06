`timescale 1ns/1ps

import core_types_pkg::*;

module tb_backend_int_cluster;
  logic clk_i = 1'b0;
  logic rst_i = 1'b1;
  logic [1:0] dec_valid_i = '0;
  logic dec_ready_o;
  decoded_uop_t dec_uop0_i = '0;
  decoded_uop_t dec_uop1_i = '0;
  recovery_t recovery_o;
  logic checkpoint_clear_valid_o;
  logic [CP_W-1:0] checkpoint_clear_id_o;
  logic redirect_valid_o;
  logic [XLEN-1:0] redirect_pc_o;
  logic store_commit_valid_o;
  logic [SQ_ID_W-1:0] store_commit_sq_id_o;
  logic store_commit_ready_i = 1'b0;
  logic store_commit_done_i = 1'b0;
  logic [1:0] retire_count_o;
  logic [5:0] rob_occupancy_o;
  logic rob_empty_o;
  logic rob_full_o;
  logic [6:0] free_prd_count_o;
  logic [3:0] free_lq_count_o;
  logic [3:0] free_sq_count_o;
  logic [$clog2(CHECKPOINTS+1)-1:0] active_checkpoint_count_o;
  logic recovery_busy_o;
  logic busy_o;
  logic [2:0] dispatch_buffer_occupancy_o;
  logic [$clog2(IQ_INT_ENTRIES+1)-1:0] int_issue_occupancy_o;
  logic [PHYS_REGS-1:0] prf_ready_bits_o;
  logic [XLEN-1:0] mstatus_o;
  logic [XLEN-1:0] mtvec_o;
  logic [XLEN-1:0] mepc_o;
  logic [XLEN-1:0] mcause_o;
  logic [XLEN-1:0] mtval_o;

  backend_int_cluster dut (.*);

  always #5 clk_i = ~clk_i;

  function automatic decoded_uop_t make_int(
      input logic [31:0] pc,
      input logic [4:0] rd,
      input alu_op_t alu_op,
      input logic [31:0] imm
  );
    decoded_uop_t uop;
    begin
      uop = '0;
      uop.pc = pc;
      uop.inst = 32'h0000_0013;
      uop.rd = rd;
      uop.write_rd = (rd != 0);
      uop.imm = imm;
      uop.fu_type = FU_INT;
      uop.alu_op = alu_op;
      uop.need_rs1 = 1'b0;
      uop.need_rs2 = 1'b0;
      make_int = uop;
    end
  endfunction

  function automatic decoded_uop_t make_branch(
      input logic [31:0] pc,
      input logic [31:0] imm,
      input logic pred_taken,
      input logic [31:0] pred_target
  );
    decoded_uop_t uop;
    begin
      uop = '0;
      uop.pc = pc;
      uop.inst = 32'h0000_0063;
      uop.fu_type = FU_BRANCH;
      uop.branch_op = BR_JAL;
      uop.imm = imm;
      uop.pred_taken = pred_taken;
      uop.pred_target = pred_target;
      uop.need_rs1 = 1'b0;
      uop.need_rs2 = 1'b0;
      make_branch = uop;
    end
  endfunction

  function automatic decoded_uop_t make_csr(
      input logic [31:0] pc,
      input logic [4:0] rd,
      input logic [11:0] csr_addr,
      input logic [31:0] zimm
  );
    decoded_uop_t uop;
    begin
      uop = '0;
      uop.pc = pc;
      uop.inst = 32'h3000_1073;
      uop.rd = rd;
      uop.write_rd = (rd != 0);
      uop.fu_type = FU_CSR;
      uop.alu_op = ALU_PASS1;
      uop.csr_op = CSR_RWI;
      uop.csr_addr = csr_addr;
      uop.csr_zimm = zimm[4:0];
      uop.serializing = 1'b1;
      uop.need_rs1 = 1'b0;
      uop.need_rs2 = 1'b0;
      make_csr = uop;
    end
  endfunction

  task automatic send_decode(
      input logic [1:0] valid,
      input decoded_uop_t uop0,
      input decoded_uop_t uop1
  );
    integer cycles;
    begin
      cycles = 0;
      while (!dec_ready_o) begin
        @(negedge clk_i);
        cycles = cycles + 1;
        if (cycles > 80)
          $fatal(1, "backend decode ready timeout");
      end
      @(negedge clk_i);
      dec_valid_i = valid;
      dec_uop0_i = uop0;
      dec_uop1_i = uop1;
      @(posedge clk_i); #1;
      dec_valid_i = '0;
      dec_uop0_i = '0;
      dec_uop1_i = '0;
    end
  endtask

  task automatic wait_backend_idle;
    integer cycles;
    begin
      cycles = 0;
      while (!rob_empty_o || busy_o || (dispatch_buffer_occupancy_o != 0) ||
             (int_issue_occupancy_o != 0)) begin
        @(posedge clk_i); #1;
        cycles = cycles + 1;
        if (cycles > 240) begin
          $display("idle timeout: rob_empty=%0b busy=%0b rob_occ=%0d db_occ=%0d iq_occ=%0d retire=%0d rec_busy=%0b redir=%0b",
                   rob_empty_o, busy_o, rob_occupancy_o,
                   dispatch_buffer_occupancy_o, int_issue_occupancy_o,
                   retire_count_o, recovery_busy_o, redirect_valid_o);
          $display("  prf_ready[32]=%0b prf_ready[33]=%0b prf_ready[34]=%0b",
                   prf_ready_bits_o[32], prf_ready_bits_o[33],
                   prf_ready_bits_o[34]);
          $display("  int0_valid=%0b int0_ready=%0b int1_valid=%0b int1_ready=%0b wb=%b complete0=%0b complete1=%0b",
                   dut.int0_result_valid, dut.int0_result_ready,
                   dut.int1_result_valid, dut.int1_result_ready,
                   dut.wb_valid, dut.rob_complete[0].valid,
                   dut.rob_complete[1].valid);
          $display("  rob_head_valid=%b head0 valid/complete=%0b/%0b head1 valid/complete=%0b/%0b",
                   dut.u_commit_recovery.rob_head_valid,
                   dut.u_commit_recovery.rob_head0.valid,
                   dut.u_commit_recovery.rob_head0.complete,
                   dut.u_commit_recovery.rob_head1.valid,
                   dut.u_commit_recovery.rob_head1.complete);
          $fatal(1, "backend did not become idle");
        end
      end
    end
  endtask

  task automatic wait_backend_activity;
    integer cycles;
    begin
      cycles = 0;
      while ((rob_occupancy_o == 0) && (dispatch_buffer_occupancy_o == 0) &&
             (int_issue_occupancy_o == 0) && !busy_o &&
             (retire_count_o == 0) && (dut.dispatch_valid == 2'b00) &&
             (dut.int0_result_valid == 1'b0) &&
             (dut.int1_result_valid == 1'b0) &&
             (dut.wb_valid == 2'b00)) begin
        @(posedge clk_i); #1;
        cycles = cycles + 1;
        if (cycles > 80)
          $fatal(1, "backend did not observe decode activity");
      end
    end
  endtask

  task automatic wait_redirect(input logic [31:0] expected_pc);
    integer cycles;
    begin
      cycles = 0;
      while (!redirect_valid_o) begin
        @(posedge clk_i); #1;
        cycles = cycles + 1;
        if (cycles > 160)
          $fatal(1, "backend redirect timeout");
      end
      if (redirect_pc_o != expected_pc)
        $fatal(1, "backend redirect pc mismatch got=%h exp=%h",
               redirect_pc_o, expected_pc);
      @(posedge clk_i); #1;
    end
  endtask

  initial begin
    repeat (2) @(posedge clk_i);
    @(negedge clk_i);
    rst_i = 1'b0;
    @(posedge clk_i); #1;
    if (!rob_empty_o || free_prd_count_o != 32 || recovery_busy_o)
      $fatal(1, "backend reset state mismatch");

    send_decode(2'b11,
                make_int(32'h8000_0000, 5'd5, ALU_AUIPC, 32'h100),
                make_int(32'h8000_0004, 5'd6, ALU_LUI, 32'h200));
    wait_backend_activity();
    wait_backend_idle();
    if (!prf_ready_bits_o[32] || !prf_ready_bits_o[33] ||
        free_prd_count_o != 32)
      $fatal(1, "integer writeback/commit loop mismatch");

    send_decode(2'b01,
                make_branch(32'h8000_0100, 32'h40, 1'b0, 32'h8000_0104),
                '0);
    wait_redirect(32'h8000_0140);
    wait_backend_idle();
    if (active_checkpoint_count_o != 0)
      $fatal(1, "branch recovery did not release checkpoint");

    send_decode(2'b01,
                make_csr(32'h8000_0200, 5'd7, 12'h300, 32'h8),
                '0);
    wait_backend_activity();
    wait_backend_idle();
    if (!mstatus_o[3] || !prf_ready_bits_o[34])
      $fatal(1, "CSR prepare/commit loop mismatch");

    $display("PASS: backend_int_cluster directed tests");
    $finish;
  end

  initial begin
    #1000000;
    $fatal(1, "timeout");
  end
endmodule
