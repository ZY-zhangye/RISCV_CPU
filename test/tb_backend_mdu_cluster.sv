import core_types_pkg::*;

module tb_backend_mdu_cluster;
  timeunit 1ns;
  timeprecision 1ps;

  logic clk_i = 1'b0;
  logic rst_i = 1'b1;
  logic [1:0] dec_valid_i = '0;
  logic dec_ready_o;
  decoded_uop_t dec_uop0_i = '0;
  decoded_uop_t dec_uop1_i = '0;
  load_mem_req_t load_mem_req_o;
  logic load_mem_req_ready_i = 1'b0;
  load_mem_resp_t load_mem_resp_i = '0;
  logic load_mem_resp_ready_o;
  store_mem_req_t store_mem_req_o;
  logic store_mem_req_ready_i = 1'b0;
  recovery_t recovery_o;
  logic checkpoint_clear_valid_o;
  logic [CP_W-1:0] checkpoint_clear_id_o;
  logic redirect_valid_o;
  logic [XLEN-1:0] redirect_pc_o;
  logic branch_update_valid_o;
  branch_update_t branch_update_o;
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
  logic [$clog2(IQ_MEM_ENTRIES+1)-1:0] mem_issue_occupancy_o;
  logic [$clog2(IQ_MDU_ENTRIES+1)-1:0] mdu_issue_occupancy_o;
  logic [3:0] lq_occupancy_o;
  logic [3:0] sq_occupancy_o;
  logic [PHYS_REGS-1:0] prf_ready_bits_o;
  logic [PRD_W-1:0] int1_prd;
  logic [PRD_W-1:0] int2_prd;
  logic [PRD_W-1:0] mul_prd;
  logic [PRD_W-1:0] div_prd;
  logic [XLEN-1:0] mstatus_o;
  logic [XLEN-1:0] mtvec_o;
  logic [XLEN-1:0] mepc_o;
  logic [XLEN-1:0] mcause_o;
  logic [XLEN-1:0] mtval_o;

  backend_mdu_cluster dut (.*);

  always #5 clk_i = ~clk_i;

  function automatic decoded_uop_t make_int_imm(
      input logic [31:0] pc,
      input logic [4:0] rd,
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
      uop.alu_op = ALU_ADD;
      uop.need_rs1 = 1'b0;
      uop.need_rs2 = 1'b0;
      make_int_imm = uop;
    end
  endfunction

  function automatic decoded_uop_t make_mul(
      input logic [31:0] pc,
      input logic [4:0] rd,
      input logic [4:0] rs1,
      input logic [4:0] rs2,
      input mul_op_t mul_op
  );
    decoded_uop_t uop;
    begin
      uop = '0;
      uop.pc = pc;
      uop.inst = 32'h0200_0033;
      uop.rd = rd;
      uop.rs1 = rs1;
      uop.rs2 = rs2;
      uop.write_rd = (rd != 0);
      uop.fu_type = FU_MUL;
      uop.mul_op = mul_op;
      uop.need_rs1 = 1'b1;
      uop.need_rs2 = 1'b1;
      make_mul = uop;
    end
  endfunction

  function automatic decoded_uop_t make_div(
      input logic [31:0] pc,
      input logic [4:0] rd,
      input logic [4:0] rs1,
      input logic [4:0] rs2,
      input div_op_t div_op
  );
    decoded_uop_t uop;
    begin
      uop = '0;
      uop.pc = pc;
      uop.inst = 32'h0200_4033;
      uop.rd = rd;
      uop.rs1 = rs1;
      uop.rs2 = rs2;
      uop.write_rd = (rd != 0);
      uop.fu_type = FU_DIV;
      uop.div_op = div_op;
      uop.need_rs1 = 1'b1;
      uop.need_rs2 = 1'b1;
      make_div = uop;
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
        if (cycles > 100)
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

  task automatic wait_prf_write_data(
      input logic [XLEN-1:0] expected_data,
      input producer_t expected_producer,
      output logic [PRD_W-1:0] observed_prd
  );
    integer cycles;
    logic seen;
    begin
      cycles = 0;
      seen = 1'b0;
      observed_prd = '0;
      while (!seen) begin
        @(posedge clk_i); #1;
        if (dut.wb_valid[0] &&
            dut.wb_completion[0].valid &&
            dut.wb_completion[0].write_prf &&
            (dut.wb_completion[0].data == expected_data) &&
            (dut.wb_completion[0].producer == expected_producer)) begin
          observed_prd = dut.wb_completion[0].prd;
          seen = 1'b1;
        end
        if (dut.wb_valid[1] &&
            dut.wb_completion[1].valid &&
            dut.wb_completion[1].write_prf &&
            (dut.wb_completion[1].data == expected_data) &&
            (dut.wb_completion[1].producer == expected_producer)) begin
          observed_prd = dut.wb_completion[1].prd;
          seen = 1'b1;
        end
        cycles = cycles + 1;
        if (cycles > 260)
          $fatal(1, "timeout waiting for PRF write data=%h producer=%0d",
                 expected_data, expected_producer);
      end
    end
  endtask

  task automatic wait_backend_idle;
    integer cycles;
    begin
      cycles = 0;
      while (!rob_empty_o || busy_o || (dispatch_buffer_occupancy_o != 0) ||
             (int_issue_occupancy_o != 0) ||
             (mem_issue_occupancy_o != 0) ||
             (mdu_issue_occupancy_o != 0) ||
             (lq_occupancy_o != 0) || (sq_occupancy_o != 0) ||
             load_mem_req_o.valid || store_mem_req_o.valid ||
             (dut.mdu_fifo_count_q != 0) ||
             dut.mdu_ex_valid || dut.mul_result_valid ||
             dut.div_result_valid) begin
        @(posedge clk_i); #1;
        cycles = cycles + 1;
        if (cycles > 420) begin
          $display("idle timeout: rob_empty=%0b busy=%0b rob_occ=%0d db=%0d intiq=%0d memiq=%0d mduiq=%0d",
                   rob_empty_o, busy_o, rob_occupancy_o,
                   dispatch_buffer_occupancy_o, int_issue_occupancy_o,
                   mem_issue_occupancy_o, mdu_issue_occupancy_o);
          $display("  mdu_ex=%0b/%0b mdu_fifo=%0d mul=%0b/%0b div=%0b/%0b retire=%0d",
                   dut.mdu_ex_valid, dut.mdu_ex_ready,
                   dut.mdu_fifo_count_q,
                   dut.mul_result_valid, dut.mul_result_ready,
                   dut.div_result_valid, dut.div_result_ready,
                   retire_count_o);
          $fatal(1, "backend_mdu_cluster did not become idle");
        end
      end
    end
  endtask

  initial begin
    repeat (2) @(posedge clk_i);
    @(negedge clk_i);
    rst_i = 1'b0;
    @(posedge clk_i); #1;
    if (!rob_empty_o || free_prd_count_o != 32 ||
        free_lq_count_o != 8 || free_sq_count_o != 8)
      $fatal(1, "backend_mdu reset state mismatch");

    send_decode(2'b01,
                make_int_imm(32'h8000_2000, 5'd1, 32'd6),
                '0);
    wait_prf_write_data(32'd6, PROD_INT0, int1_prd);
    wait_backend_idle();

    send_decode(2'b01,
                make_int_imm(32'h8000_2004, 5'd2, 32'd7),
                '0);
    wait_prf_write_data(32'd7, PROD_INT0, int2_prd);
    wait_backend_idle();

    send_decode(2'b01,
                make_mul(32'h8000_2010, 5'd3, 5'd1, 5'd2, MUL_MUL),
                '0);
    wait_prf_write_data(32'd42, PROD_MUL, mul_prd);
    wait_backend_idle();
    if (!prf_ready_bits_o[mul_prd] || free_prd_count_o != 32)
      $fatal(1, "backend MUL writeback/retire mismatch");

    send_decode(2'b01,
                make_div(32'h8000_2020, 5'd4, 5'd3, 5'd2, DIV_DIVU),
                '0);
    wait_prf_write_data(32'd6, PROD_DIV, div_prd);
    wait_backend_idle();
    if (!prf_ready_bits_o[div_prd] || free_prd_count_o != 32)
      $fatal(1, "backend DIV writeback/retire mismatch");

    $display("PASS: backend_mdu_cluster directed tests");
    $finish;
  end

  initial begin
    #1000000;
    $fatal(1, "timeout");
  end
endmodule
