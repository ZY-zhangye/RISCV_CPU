import core_types_pkg::*;

module tb_soc_withmext_coe;
  timeunit 1ns;
  timeprecision 1ps;

  localparam string IROM_INIT = "hex/withmext/irom-v2.mem";
  localparam string DMEM_INIT = "hex/withmext/dram.mem";
  localparam int unsigned RUN_CYCLES = 20000;

  logic clk_i = 1'b0;
  logic clk_cnt_i = 1'b0;
  logic rst_i = 1'b1;

  logic ext_irq_i = 1'b0;
  logic timer_irq_i = 1'b0;
  logic software_irq_i = 1'b0;

  logic periph_req_valid_o;
  logic periph_req_ready_i = 1'b1;
  logic periph_req_write_o;
  logic [XLEN-1:0] periph_req_addr_o;
  logic [XLEN-1:0] periph_req_wdata_o;
  logic [3:0] periph_req_wstrb_o;
  logic periph_resp_valid_i = 1'b0;
  logic [XLEN-1:0] periph_resp_rdata_i = '0;
  logic periph_resp_error_i = 1'b1;

  logic [63:0] sw_i = 64'h0000_0000_0000_0000;
  logic [7:0] key_i = 8'h00;
  logic [31:0] led_o;
  logic [39:0] seg_o;

  logic imem_init_write_valid_i = 1'b0;
  logic [XLEN-1:0] imem_init_write_addr_i = '0;
  logic [127:0] imem_init_write_data_i = '0;
  logic imem_init_write_ready_o;
  logic imem_init_write_error_o;

  logic dmem_init_write_valid_i = 1'b0;
  logic [XLEN-1:0] dmem_init_write_addr_i = '0;
  logic [XLEN-1:0] dmem_init_write_data_i = '0;
  logic [3:0] dmem_init_write_wstrb_i = '0;
  logic dmem_init_write_ready_o;
  logic dmem_init_write_error_o;

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
  logic imem_resp_error_o;
  logic data_store_error_o;
  logic mmio_busy_o;

  // Waveform monitor window for board outputs.
  (* keep = "true" *) logic [31:0] led_monitor;
  (* keep = "true" *) logic [39:0] seg_monitor;
  (* keep = "true" *) logic [1:0] wb_monitor_valid;
  (* keep = "true" *) logic [1:0][XLEN-1:0] wb_monitor_pc;
  (* keep = "true" *) logic [1:0][4:0] wb_monitor_rd;
  (* keep = "true" *) logic [1:0][XLEN-1:0] wb_monitor_data;
  logic [31:0] led_prev_q;
  logic [39:0] seg_prev_q;
  int unsigned cycle_count;

  assign led_monitor = led_o;
  assign seg_monitor = seg_o;

  soc_top #(
      .IMEM_INIT_FILE(IROM_INIT),
      .DMEM_INIT_FILE(DMEM_INIT),
      .POWER_ON_RESET_CYCLES(8)
  ) dut (.*);

  function automatic logic [XLEN-1:0] read_prf_data(
      input logic [PRD_W-1:0] prd
  );
    logic [PRD_W-2:0] bank_index;
    begin
      bank_index = prd[PRD_W-1:1];
      if (prd == '0) begin
        read_prf_data = '0;
      end else if (prd[0]) begin
        read_prf_data =
            dut.u_core.u_core_cluster.u_backend.u_commit_recovery
               .u_commit_prf.u_prf.bank1_copy0[bank_index];
      end else begin
        read_prf_data =
            dut.u_core.u_core_cluster.u_backend.u_commit_recovery
               .u_commit_prf.u_prf.bank0_copy0[bank_index];
      end
    end
  endfunction

  function automatic logic [XLEN-1:0] retire_wb_data(
      input rob_entry_t entry
  );
    begin
      if (entry.entry.is_csr) begin
        retire_wb_data =
            dut.u_core.u_core_cluster.u_backend.u_commit_recovery
               .u_commit_prf.u_commit_csr.csr_rdata;
      end else begin
        retire_wb_data = read_prf_data(entry.entry.new_prd);
      end
    end
  endfunction

  always_comb begin
    wb_monitor_valid = '0;
    wb_monitor_pc = '0;
    wb_monitor_rd = '0;
    wb_monitor_data = '0;

    if (retire_count_o != 2'd0) begin
      wb_monitor_pc[0] =
          dut.u_core.u_core_cluster.u_backend.u_commit_recovery
             .rob_head0.entry.pc;
      wb_monitor_rd[0] =
          dut.u_core.u_core_cluster.u_backend.u_commit_recovery
             .rob_head0.entry.arch_rd;
      wb_monitor_data[0] = retire_wb_data(
          dut.u_core.u_core_cluster.u_backend.u_commit_recovery.rob_head0);
      wb_monitor_valid[0] =
          dut.u_core.u_core_cluster.u_backend.u_commit_recovery
             .rob_head0.entry.write_rd &&
          (dut.u_core.u_core_cluster.u_backend.u_commit_recovery
             .rob_head0.entry.arch_rd != 5'd0);
    end

    if (retire_count_o == 2'd2) begin
      wb_monitor_pc[1] =
          dut.u_core.u_core_cluster.u_backend.u_commit_recovery
             .rob_head1.entry.pc;
      wb_monitor_rd[1] =
          dut.u_core.u_core_cluster.u_backend.u_commit_recovery
             .rob_head1.entry.arch_rd;
      wb_monitor_data[1] = retire_wb_data(
          dut.u_core.u_core_cluster.u_backend.u_commit_recovery.rob_head1);
      wb_monitor_valid[1] =
          dut.u_core.u_core_cluster.u_backend.u_commit_recovery
             .rob_head1.entry.write_rd &&
          (dut.u_core.u_core_cluster.u_backend.u_commit_recovery
             .rob_head1.entry.arch_rd != 5'd0);
    end
  end

  always #5 clk_i = ~clk_i;
  always #10 clk_cnt_i = ~clk_cnt_i;

  // External expansion accesses are outside this board-level COE smoke test.
  // Return an error response one cycle after accepting such a request.
  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      periph_resp_valid_i <= 1'b0;
      periph_resp_rdata_i <= '0;
      periph_resp_error_i <= 1'b1;
    end else begin
      periph_resp_valid_i <= periph_req_valid_o;
      periph_resp_rdata_i <= '0;
      periph_resp_error_i <= 1'b1;
    end
  end

  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      led_prev_q <= '0;
      seg_prev_q <= '0;
      cycle_count <= 0;
    end else begin
      cycle_count <= cycle_count + 1;
      if (led_monitor !== led_prev_q) begin
        $display("MONITOR_LED cycle=%0d led=%08h", cycle_count, led_monitor);
        led_prev_q <= led_monitor;
      end
      if (seg_monitor !== seg_prev_q) begin
        $display("MONITOR_SEG cycle=%0d seg=%010h", cycle_count, seg_monitor);
        seg_prev_q <= seg_monitor;
      end
      for (int lane = 0; lane < 2; lane = lane + 1) begin
        if (wb_monitor_valid[lane]) begin
          $display("MONITOR_WB cycle=%0d lane=%0d pc=%08h rd=x%0d data=%08h",
                   cycle_count, lane, wb_monitor_pc[lane],
                   wb_monitor_rd[lane], wb_monitor_data[lane]);
        end
      end
    end
  end

  always_ff @(posedge clk_i) begin
    if (!rst_i && $test$plusargs("CSR_TRACE")) begin
      automatic rob_entry_t trace_head0 =
          dut.u_core.u_core_cluster.u_backend.u_commit_recovery.rob_head0;
      automatic rob_entry_t trace_head1 =
          dut.u_core.u_core_cluster.u_backend.u_commit_recovery.rob_head1;

      if (dut.u_core.u_core_cluster.u_backend.int0_ex_valid &&
          dut.u_core.u_core_cluster.u_backend.int0_ex_ready &&
          (dut.u_core.u_core_cluster.u_backend.int0_ex_uop.fu_type == FU_CSR)) begin
        $display("TRACE_CSR_EX cycle=%0d pc=%08h rob=%0d csr=%03h op=%0d src1=%08h zimm=%0d rd_prd=%0d",
                 cycle_count,
                 dut.u_core.u_core_cluster.u_backend.int0_ex_uop.pc,
                 dut.u_core.u_core_cluster.u_backend.int0_ex_uop.rob_id,
                 dut.u_core.u_core_cluster.u_backend.int0_ex_uop.csr_addr,
                 dut.u_core.u_core_cluster.u_backend.int0_ex_uop.csr_op,
                 dut.u_core.u_core_cluster.u_backend.int0_ex_uop.src1,
                 dut.u_core.u_core_cluster.u_backend.int0_ex_uop.csr_zimm,
                 dut.u_core.u_core_cluster.u_backend.int0_ex_uop.prd);
      end

      if (dut.u_core.u_core_cluster.u_backend.int0_result_valid &&
          dut.u_core.u_core_cluster.u_backend.int0_result.valid &&
          (dut.u_core.u_core_cluster.u_backend.int0_result.write_prf == 1'b0)) begin
        $display("TRACE_INT0_COMPLETE cycle=%0d rob=%0d data=%08h branch_mask=%b",
                 cycle_count,
                 dut.u_core.u_core_cluster.u_backend.int0_result.rob_id,
                 dut.u_core.u_core_cluster.u_backend.int0_result.data,
                 dut.u_core.u_core_cluster.u_backend.int0_result.branch_mask);
      end

      if ((retire_count_o != 2'd0) &&
          (((trace_head0.entry.pc >= 32'h8000_020c) &&
            (trace_head0.entry.pc <= 32'h8000_0490)) ||
           ((trace_head0.entry.pc >= 32'h8000_2170) &&
            (trace_head0.entry.pc <= 32'h8000_22a0)) ||
           ((trace_head0.entry.pc >= 32'h8000_0140) &&
            (trace_head0.entry.pc <= 32'h8000_0160)))) begin
        $display("TRACE_RET cycle=%0d retire=%0d h0[v=%0b c=%0b pc=%08h csr=%0b addr=%03h op=%0d operand=%08h rd=x%0d prd=%0d] h1[v=%0b c=%0b pc=%08h]",
                 cycle_count, retire_count_o,
                 trace_head0.valid, trace_head0.complete,
                 trace_head0.entry.pc, trace_head0.entry.is_csr,
                 trace_head0.entry.csr_addr, trace_head0.entry.csr_op,
                 trace_head0.entry.csr_operand,
                 trace_head0.entry.arch_rd, trace_head0.entry.new_prd,
                 trace_head1.valid, trace_head1.complete,
                 trace_head1.entry.pc);
      end

      if (dut.u_core.u_core_cluster.u_backend.u_commit_recovery
              .u_commit_prf.u_commit_csr.csr_command ||
          dut.u_core.u_core_cluster.u_backend.u_commit_recovery
              .u_commit_prf.u_commit_csr.special_exception ||
          dut.u_core.u_core_cluster.u_backend.u_commit_recovery
              .u_commit_prf.u_commit_csr.mret_command) begin
        $display("TRACE_CSR_COMMIT cycle=%0d pc=%08h csr_cmd=%0b addr=%03h op=%0d operand=%08h rdata=%08h illegal=%0b retire_raw=%0d recovery=%0b redirect=%08h mtvec=%08h mscratch=%08h mepc=%08h mcause=%08h",
                 cycle_count, trace_head0.entry.pc,
                 dut.u_core.u_core_cluster.u_backend.u_commit_recovery
                    .u_commit_prf.u_commit_csr.csr_command,
                 trace_head0.entry.csr_addr, trace_head0.entry.csr_op,
                 trace_head0.entry.csr_operand,
                 dut.u_core.u_core_cluster.u_backend.u_commit_recovery
                    .u_commit_prf.u_commit_csr.csr_rdata,
                 dut.u_core.u_core_cluster.u_backend.u_commit_recovery
                    .u_commit_prf.u_commit_csr.csr_illegal,
                 dut.u_core.u_core_cluster.u_backend.u_commit_recovery
                    .retire_count_raw,
                 dut.u_core.u_core_cluster.u_backend.u_commit_recovery
                    .u_commit_prf.u_commit_csr.recovery_o.valid,
                 dut.u_core.u_core_cluster.u_backend.u_commit_recovery
                    .u_commit_prf.u_commit_csr.recovery_o.redirect_pc,
                 mtvec_o,
                 dut.u_core.u_core_cluster.u_backend.u_commit_recovery
                    .u_commit_prf.u_commit_csr.u_csr_file.mscratch_q,
                 mepc_o, mcause_o);
      end

      if (recovery_o.valid || redirect_valid_o) begin
        $display("TRACE_REC cycle=%0d recovery=%0b cause=%0d redirect_req=%08h redirect_valid=%0b redirect_pc=%08h mtvec=%08h mepc=%08h mcause=%08h",
                 cycle_count, recovery_o.valid, recovery_o.cause,
                 recovery_o.redirect_pc, redirect_valid_o, redirect_pc_o,
                 mtvec_o, mepc_o, mcause_o);
      end
    end
  end

  initial begin
    #1;
    if (dut.u_imem.mem_b0_q[0] !== 32'h0012_1117 ||
        dut.u_imem.mem_b1_q[0] !== 32'h0501_0113 ||
        dut.u_imem.mem_b2_q[0] !== 32'h7710_00ef ||
        dut.u_imem.mem_b3_q[0] !== 32'h4ed0_10ef)
      $fatal(1, "IROM COE conversion/init mismatch");

    if ({dut.u_data_ram.mem_b3_q[3], dut.u_data_ram.mem_b2_q[3],
         dut.u_data_ram.mem_b1_q[3], dut.u_data_ram.mem_b0_q[3]} !== 32'h1234_abcd)
      $fatal(1, "DRAM COE conversion/init mismatch at word 3");
    if ({dut.u_data_ram.mem_b3_q[4], dut.u_data_ram.mem_b2_q[4],
         dut.u_data_ram.mem_b1_q[4], dut.u_data_ram.mem_b0_q[4]} !== 32'h5566_7788)
      $fatal(1, "DRAM COE conversion/init mismatch at word 4");

    repeat (5) @(posedge clk_i);
    @(negedge clk_i);
    rst_i = 1'b0;

    repeat (RUN_CYCLES) begin
      @(posedge clk_i);
      #1;
      if ($isunknown(led_monitor))
        $fatal(1, "LED monitor became X");
      if ($isunknown(seg_monitor))
        $fatal(1, "SEG monitor became X");
      if (imem_resp_error_o)
        $fatal(1, "instruction memory error");
    end

    $display("PASS: withmext COE boot smoke cycles=%0d led=%08h seg=%010h",
             cycle_count, led_monitor, seg_monitor);
    $finish;
  end

  initial begin
    #(RUN_CYCLES * 20ns);
    $fatal(1, "timeout");
  end
endmodule
