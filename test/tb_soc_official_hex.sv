import core_types_pkg::*;

module tb_soc_official_hex;
  timeunit 1ns;
  timeprecision 1ps;

  localparam logic [XLEN-1:0] IMAGE_BASE = 32'h8000_0000;
  localparam logic [XLEN-1:0] END_PC = 32'h8000_0044;
  localparam int unsigned RAM_BYTES = 32768;
  localparam int unsigned MEMORY_WORDS = RAM_BYTES / 4;

  logic clk_i = 1'b0;
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
  logic periph_resp_error_i = 1'b0;
  logic [7:0] led_o;

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

  logic [XLEN-1:0] image_words [0:MEMORY_WORDS-1];
  integer cycles;
  integer max_cycles;
  string hex_file;
  string test_name;
  logic trace_enabled;
  logic end_pc_pending_q;
  logic [XLEN-1:0] last_commit_pc;
  int unsigned loaded_word_count;

  soc_top #(
      .RESET_MTVEC(IMAGE_BASE),
      .RAM_BASE(IMAGE_BASE),
      .RAM_BYTES(RAM_BYTES),
      .POWER_ON_RESET_CYCLES(4)
  ) dut (.*);

  always #5 clk_i = ~clk_i;

  task automatic write_imem_block(
      input logic [XLEN-1:0] addr,
      input logic [127:0] data
  );
    begin
      @(negedge clk_i);
      imem_init_write_valid_i = 1'b1;
      imem_init_write_addr_i = addr;
      imem_init_write_data_i = data;
      #1;
      if (!imem_init_write_ready_o || imem_init_write_error_o)
        $fatal(1, "imem init write failed addr=%08h", addr);
      @(posedge clk_i); #1;
      imem_init_write_valid_i = 1'b0;
      imem_init_write_addr_i = '0;
      imem_init_write_data_i = '0;
    end
  endtask

  task automatic write_dmem_word(
      input logic [XLEN-1:0] addr,
      input logic [XLEN-1:0] data
  );
    begin
      @(negedge clk_i);
      dmem_init_write_valid_i = 1'b1;
      dmem_init_write_addr_i = addr;
      dmem_init_write_data_i = data;
      dmem_init_write_wstrb_i = 4'b1111;
      #1;
      if (!dmem_init_write_ready_o || dmem_init_write_error_o)
        $fatal(1, "dmem init write failed addr=%08h", addr);
      @(posedge clk_i); #1;
      dmem_init_write_valid_i = 1'b0;
      dmem_init_write_addr_i = '0;
      dmem_init_write_data_i = '0;
      dmem_init_write_wstrb_i = '0;
    end
  endtask

  task automatic load_hex_image(output int unsigned word_count);
    integer fd;
    integer code;
    logic [XLEN-1:0] word;
    string ignored_line;
    int unsigned index;
    int unsigned block_index;
    logic [127:0] block_data;
    begin
      for (index = 0; index < MEMORY_WORDS; index = index + 1)
        image_words[index] = '0;

      fd = $fopen(hex_file, "r");
      if (fd == 0)
        $fatal(1, "failed to open HEX file: %s", hex_file);

      word_count = 0;
      while (!$feof(fd)) begin
        code = $fscanf(fd, "%h", word);
        if (code == 1) begin
          if (word_count >= MEMORY_WORDS)
            $fatal(1, "HEX image exceeds test memory words=%0d", MEMORY_WORDS);
          image_words[word_count] = word;
          word_count = word_count + 1;
        end else begin
          void'($fgets(ignored_line, fd));
        end
      end
      $fclose(fd);
      loaded_word_count = word_count;

      for (index = 0; index < word_count; index = index + 1)
        write_dmem_word(IMAGE_BASE + index * 4, image_words[index]);

      for (block_index = 0; block_index < ((word_count + 3) / 4);
           block_index = block_index + 1) begin
        block_data = {word_or_nop(block_index * 4 + 3),
                      word_or_nop(block_index * 4 + 2),
                      word_or_nop(block_index * 4 + 1),
                      word_or_nop(block_index * 4 + 0)};
        write_imem_block(IMAGE_BASE + block_index * 16, block_data);
      end
    end
  endtask

  function automatic logic [XLEN-1:0] word_or_nop(input int unsigned index);
    if (index < loaded_word_count)
      word_or_nop = image_words[index];
    else
      word_or_nop = 32'h0000_0013;
  endfunction

  function automatic logic [XLEN-1:0] committed_x3();
    logic [PRD_W-1:0] prd;
    begin
      prd = dut.u_core.u_core_cluster.u_backend.u_commit_recovery
              .u_rename_rob.u_rename_stage.u_rat_amt.amt_q[3];
      if (prd[0]) begin
        committed_x3 = dut.u_core.u_core_cluster.u_backend.u_commit_recovery
                         .u_commit_prf.u_prf.bank1_copy0[prd[PRD_W-1:1]];
      end else begin
        committed_x3 = dut.u_core.u_core_cluster.u_backend.u_commit_recovery
                         .u_commit_prf.u_prf.bank0_copy0[prd[PRD_W-1:1]];
      end
    end
  endfunction

  function automatic logic raw_retire_end_pc();
    raw_retire_end_pc = 1'b0;
    if (dut.u_core.u_core_cluster.u_backend.u_commit_recovery.retire_count_raw >= 2'd1 &&
        dut.u_core.u_core_cluster.u_backend.u_commit_recovery.rob_head0.entry.pc == END_PC) begin
      raw_retire_end_pc = 1'b1;
      last_commit_pc = END_PC;
    end
    if (dut.u_core.u_core_cluster.u_backend.u_commit_recovery.retire_count_raw >= 2'd2 &&
        dut.u_core.u_core_cluster.u_backend.u_commit_recovery.rob_head1.entry.pc == END_PC) begin
      raw_retire_end_pc = 1'b1;
      last_commit_pc = END_PC;
    end
  endfunction

  task automatic fail_unknown(input string signal_name);
    begin
      $display("REGRESSION_RESULT FAIL test=%s cycle=%0d reason=unknown_%s last_pc=%08h",
               test_name, cycles, signal_name, last_commit_pc);
      $fatal(1, "unknown value observed on %s", signal_name);
    end
  endtask

  task automatic check_result();
    logic [XLEN-1:0] gp;
    begin
      gp = committed_x3();
      if ($isunknown(gp))
        fail_unknown("committed_x3");

      if (gp == 32'd1) begin
        $display("REGRESSION_RESULT PASS test=%s cycles=%0d gp=%08h",
                 test_name, cycles, gp);
        $finish;
      end else begin
        $display("REGRESSION_RESULT FAIL test=%s cycles=%0d gp=%08h last_pc=%08h",
                 test_name, cycles, gp, last_commit_pc);
        $fatal(1, "official test failed: committed x3/gp must equal 1");
      end
    end
  endtask

  initial begin
    int unsigned word_count;

    cycles = 0;
    max_cycles = 100000;
    trace_enabled = $test$plusargs("TRACE");
    end_pc_pending_q = 1'b0;
    last_commit_pc = IMAGE_BASE;

    if (!$value$plusargs("HEX=%s", hex_file))
      $fatal(1, "tb_soc_official_hex requires +HEX=<path>");
    if (!$value$plusargs("TEST=%s", test_name))
      test_name = hex_file;
    void'($value$plusargs("MAX_CYCLES=%d", max_cycles));

    $display("REGRESSION_START test=%s hex=%s max_cycles=%0d",
             test_name, hex_file, max_cycles);
    load_hex_image(word_count);
    $display("REGRESSION_IMAGE test=%s words=%0d base=%08h end_pc=%08h",
             test_name, word_count, IMAGE_BASE, END_PC);

    repeat (2) @(posedge clk_i);
    @(negedge clk_i);
    rst_i = 1'b0;

    forever begin
      @(posedge clk_i);
      #1;
      cycles = cycles + 1;

      if ($isunknown(retire_count_o))
        fail_unknown("retire_count");
      if ($isunknown(redirect_valid_o))
        fail_unknown("redirect_valid");
      if (imem_resp_error_o)
        $fatal(1, "instruction memory error at cycle=%0d", cycles);
      if (data_store_error_o)
        $fatal(1, "data store error at cycle=%0d", cycles);
      if (periph_req_valid_o)
        $fatal(1, "unexpected external MMIO request at cycle=%0d addr=%08h",
               cycles, periph_req_addr_o);

      if (end_pc_pending_q)
        check_result();
      end_pc_pending_q = 1'b0;

      if (dut.u_core.u_core_cluster.u_backend.u_commit_recovery.retire_count_raw != 0) begin
        if (trace_enabled) begin
          $display("TRACE COMMIT cycle=%0d raw_count=%0d pc0=%08h pc1=%08h",
                   cycles,
                   dut.u_core.u_core_cluster.u_backend.u_commit_recovery.retire_count_raw,
                   dut.u_core.u_core_cluster.u_backend.u_commit_recovery.rob_head0.entry.pc,
                   dut.u_core.u_core_cluster.u_backend.u_commit_recovery.rob_head1.entry.pc);
        end

        if (dut.u_core.u_core_cluster.u_backend.u_commit_recovery.retire_count_raw >= 2'd1)
          last_commit_pc =
              dut.u_core.u_core_cluster.u_backend.u_commit_recovery.rob_head0.entry.pc;
        if (dut.u_core.u_core_cluster.u_backend.u_commit_recovery.retire_count_raw >= 2'd2)
          last_commit_pc =
              dut.u_core.u_core_cluster.u_backend.u_commit_recovery.rob_head1.entry.pc;
        if (raw_retire_end_pc())
          end_pc_pending_q = 1'b1;
      end

      if (trace_enabled && redirect_valid_o)
        $display("TRACE REDIRECT cycle=%0d pc=%08h cause=%0d",
                 cycles, redirect_pc_o, recovery_o.cause);

      if (cycles >= max_cycles) begin
        $display("REGRESSION_RESULT TIMEOUT test=%s cycles=%0d last_pc=%08h gp=%08h",
                 test_name, cycles, last_commit_pc, committed_x3());
        $fatal(1, "official test timed out");
      end
    end
  end
endmodule
