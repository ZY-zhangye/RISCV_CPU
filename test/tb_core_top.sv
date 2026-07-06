import core_types_pkg::*;

module tb_core_top;
  timeunit 1ns;
  timeprecision 1ps;

  logic clk_i = 1'b0;
  logic rst_i = 1'b1;

  logic ext_irq_i = 1'b0;
  logic timer_irq_i = 1'b0;
  logic software_irq_i = 1'b0;

  logic imem_req_valid_o;
  logic [31:0] imem_req_addr_o;
  logic imem_resp_valid_i = 1'b0;
  logic [127:0] imem_resp_data_i = '0;

  load_mem_req_t load_mem_req_o;
  logic load_mem_req_ready_i = 1'b0;
  load_mem_resp_t load_mem_resp_i = '0;
  logic load_mem_resp_ready_o;
  store_mem_req_t store_mem_req_o;
  logic store_mem_req_ready_i = 1'b0;
  logic interrupt_pending_o;
  recovery_t recovery_o;
  logic checkpoint_clear_valid_o;
  logic [CP_W-1:0] checkpoint_clear_id_o;
  logic redirect_valid_o;
  logic [XLEN-1:0] redirect_pc_o;
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
  logic [3:0] ibuf_occupancy_o;
  logic [2:0] dispatch_buffer_occupancy_o;
  logic [$clog2(IQ_INT_ENTRIES+1)-1:0] int_issue_occupancy_o;
  logic [$clog2(IQ_MEM_ENTRIES+1)-1:0] mem_issue_occupancy_o;
  logic [$clog2(IQ_MDU_ENTRIES+1)-1:0] mdu_issue_occupancy_o;
  logic [3:0] lq_occupancy_o;
  logic [3:0] sq_occupancy_o;
  logic [PHYS_REGS-1:0] prf_ready_bits_o;
  logic [XLEN-1:0] mstatus_o;
  logic [XLEN-1:0] mtvec_o;
  logic [XLEN-1:0] mepc_o;
  logic [XLEN-1:0] mcause_o;
  logic [XLEN-1:0] mtval_o;

  core_top dut (.*);

  always #5 clk_i = ~clk_i;

  function automatic logic [31:0] enc_i(
      input logic [11:0] imm,
      input logic [4:0] rs1,
      input logic [2:0] funct3,
      input logic [4:0] rd,
      input logic [6:0] opcode
  );
    enc_i = {imm, rs1, funct3, rd, opcode};
  endfunction

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

  function automatic logic [31:0] addi(
      input logic [4:0] rd,
      input logic [4:0] rs1,
      input logic [11:0] imm
  );
    addi = enc_i(imm, rs1, 3'b000, rd, 7'b0010011);
  endfunction

  function automatic logic [31:0] mul(
      input logic [4:0] rd,
      input logic [4:0] rs1,
      input logic [4:0] rs2
  );
    mul = enc_r(7'b0000001, rs2, rs1, 3'b000, rd, 7'b0110011);
  endfunction

  function automatic logic [31:0] divu(
      input logic [4:0] rd,
      input logic [4:0] rs1,
      input logic [4:0] rs2
  );
    divu = enc_r(7'b0000001, rs2, rs1, 3'b101, rd, 7'b0110011);
  endfunction

  function automatic logic [127:0] imem_block(input logic [31:0] addr);
    logic [31:0] inst0;
    logic [31:0] inst1;
    logic [31:0] inst2;
    logic [31:0] inst3;
    begin
      inst0 = 32'h0000_0013;
      inst1 = 32'h0000_0013;
      inst2 = 32'h0000_0013;
      inst3 = 32'h0000_0013;
      unique case (addr)
        32'h8000_0000: begin
          inst0 = addi(5'd1, 5'd0, 12'd6);
          inst1 = addi(5'd2, 5'd0, 12'd7);
          inst2 = mul(5'd3, 5'd1, 5'd2);
          inst3 = divu(5'd4, 5'd3, 5'd2);
        end
        default: begin
          inst0 = 32'h0000_0013;
          inst1 = 32'h0000_0013;
          inst2 = 32'h0000_0013;
          inst3 = 32'h0000_0013;
        end
      endcase
      imem_block = {inst3, inst2, inst1, inst0};
    end
  endfunction

  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      imem_resp_valid_i <= 1'b0;
      imem_resp_data_i <= '0;
    end else begin
      imem_resp_valid_i <= imem_req_valid_o;
      if (imem_req_valid_o)
        imem_resp_data_i <= imem_block(imem_req_addr_o);
    end
  end

  task automatic wait_prf_write_data(
      input logic [XLEN-1:0] expected_data,
      input producer_t expected_producer
  );
    integer cycles;
    logic seen;
    begin
      cycles = 0;
      seen = 1'b0;
      while (!seen) begin
        @(posedge clk_i); #1;
        if (dut.u_core_cluster.u_backend.wb_valid[0] &&
            dut.u_core_cluster.u_backend.wb_completion[0].valid &&
            dut.u_core_cluster.u_backend.wb_completion[0].write_prf &&
            (dut.u_core_cluster.u_backend.wb_completion[0].data == expected_data) &&
            (dut.u_core_cluster.u_backend.wb_completion[0].producer == expected_producer)) begin
          seen = 1'b1;
        end
        if (dut.u_core_cluster.u_backend.wb_valid[1] &&
            dut.u_core_cluster.u_backend.wb_completion[1].valid &&
            dut.u_core_cluster.u_backend.wb_completion[1].write_prf &&
            (dut.u_core_cluster.u_backend.wb_completion[1].data == expected_data) &&
            (dut.u_core_cluster.u_backend.wb_completion[1].producer == expected_producer)) begin
          seen = 1'b1;
        end
        cycles = cycles + 1;
        if (cycles > 360)
          $fatal(1, "timeout waiting for data=%h producer=%0d",
                 expected_data, expected_producer);
      end
    end
  endtask

  initial begin
    repeat (2) @(posedge clk_i);
    @(negedge clk_i);
    rst_i = 1'b0;

    ext_irq_i = 1'b1;
    #1;
    if (!interrupt_pending_o)
      $fatal(1, "interrupt_pending_o did not reflect ext_irq_i");
    ext_irq_i = 1'b0;

    timer_irq_i = 1'b1;
    software_irq_i = 1'b1;
    #1;
    if (!interrupt_pending_o)
      $fatal(1, "interrupt_pending_o did not reflect timer/software irq");
    timer_irq_i = 1'b0;
    software_irq_i = 1'b0;

    wait_prf_write_data(32'd6, PROD_INT0);
    wait_prf_write_data(32'd7, PROD_INT0);
    wait_prf_write_data(32'd42, PROD_MUL);
    wait_prf_write_data(32'd6, PROD_DIV);
    repeat (8) @(posedge clk_i); #1;

    if (free_lq_count_o != 8 || free_sq_count_o != 8)
      $fatal(1, "core_top memory resources did not drain");

    $display("PASS: core_top directed tests");
    $finish;
  end

  initial begin
    #2000000;
    $fatal(1, "timeout");
  end
endmodule
