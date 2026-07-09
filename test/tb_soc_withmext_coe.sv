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
