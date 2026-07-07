import core_types_pkg::*;

module tb_soc_official_hex;
  timeunit 1ns;
  timeprecision 1ps;

  localparam logic [XLEN-1:0] IMAGE_BASE = 32'h8000_0000;
  // riscv-tests signals completion by storing gp to tohost. In the linked
  // rv32ui images this is the store at 0x80000040; later instructions just
  // maintain the host communication loop.
  localparam logic [XLEN-1:0] END_PC = 32'h8000_0040;
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
          $display("TRACE COMMIT cycle=%0d raw_count=%0d retire=%0d txn[p=%0b f=%0b] pc0=%08h pc1=%08h head_valid=%b c=%b/%b st=%b/%b sq=%0d/%0d sqc[v=%0b r=%0b d=%0b id=%0d] reclaim[v=%b r=%0b] occ=%0d rec_busy=%b",
                   cycles,
                   dut.u_core.u_core_cluster.u_backend.u_commit_recovery.retire_count_raw,
                   retire_count_o,
                   dut.u_core.u_core_cluster.u_backend.u_commit_recovery
                       .commit_txn_pending_q,
                   dut.u_core.u_core_cluster.u_backend.u_commit_recovery
                       .commit_txn_fire,
                   dut.u_core.u_core_cluster.u_backend.u_commit_recovery.rob_head0.entry.pc,
                   dut.u_core.u_core_cluster.u_backend.u_commit_recovery.rob_head1.entry.pc,
                   dut.u_core.u_core_cluster.u_backend.u_commit_recovery.rob_head_valid,
                   dut.u_core.u_core_cluster.u_backend.u_commit_recovery.rob_head0.complete,
                   dut.u_core.u_core_cluster.u_backend.u_commit_recovery.rob_head1.complete,
                   dut.u_core.u_core_cluster.u_backend.u_commit_recovery.rob_head0.entry.is_store,
                   dut.u_core.u_core_cluster.u_backend.u_commit_recovery.rob_head1.entry.is_store,
                   dut.u_core.u_core_cluster.u_backend.u_commit_recovery.rob_head0.entry.sq_id,
                   dut.u_core.u_core_cluster.u_backend.u_commit_recovery.rob_head1.entry.sq_id,
                   dut.u_core.u_core_cluster.u_backend.sq_commit_valid,
                   dut.u_core.u_core_cluster.u_backend.sq_commit_ready,
                   dut.u_core.u_core_cluster.u_backend.sq_commit_done,
                   dut.u_core.u_core_cluster.u_backend.sq_commit_id,
                   dut.u_core.u_core_cluster.u_backend.u_commit_recovery.reclaim_valid_offer,
                   dut.u_core.u_core_cluster.u_backend.u_commit_recovery.reclaim_ready,
                   rob_occupancy_o,
                   recovery_busy_o);
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

      if (trace_enabled &&
          (dut.u_core.u_core_cluster.u_backend.sq_commit_valid ||
           dut.u_core.u_core_cluster.u_backend.sq_commit_ready ||
           dut.u_core.u_core_cluster.u_backend.sq_commit_done ||
           dut.u_core.u_core_cluster.u_backend.u_commit_recovery.commit_txn_pending_q ||
           dut.u_core.u_core_cluster.u_backend.u_commit_recovery.commit_txn_fire)) begin
        $display("TRACE_STORE_COMMIT cycle=%0d raw=%0d retire=%0d txn[p=%0b f=%0b] head0[pc=%08h v=%0b c=%0b st=%0b sq=%0d] head1[pc=%08h v=%0b c=%0b st=%0b sq=%0d] sqc[v=%0b r=%0b d=%0b id=%0d] sq0[v=%0b av=%0b dv=%0b be=%b mask=%b] sq1[v=%0b av=%0b dv=%0b be=%b mask=%b] sq4[v=%0b av=%0b dv=%0b be=%b mask=%b] sq5[v=%0b av=%0b dv=%0b be=%b mask=%b] stmem[core_v=%0b core_r=%0b ram_v=%0b ram_r=%0b addr=%08h be=%b]",
                 cycles,
                 dut.u_core.u_core_cluster.u_backend.u_commit_recovery.retire_count_raw,
                 retire_count_o,
                 dut.u_core.u_core_cluster.u_backend.u_commit_recovery
                     .commit_txn_pending_q,
                 dut.u_core.u_core_cluster.u_backend.u_commit_recovery
                     .commit_txn_fire,
                 dut.u_core.u_core_cluster.u_backend.u_commit_recovery.rob_head0.entry.pc,
                 dut.u_core.u_core_cluster.u_backend.u_commit_recovery.rob_head0.valid,
                 dut.u_core.u_core_cluster.u_backend.u_commit_recovery.rob_head0.complete,
                 dut.u_core.u_core_cluster.u_backend.u_commit_recovery.rob_head0.entry.is_store,
                 dut.u_core.u_core_cluster.u_backend.u_commit_recovery.rob_head0.entry.sq_id,
                 dut.u_core.u_core_cluster.u_backend.u_commit_recovery.rob_head1.entry.pc,
                 dut.u_core.u_core_cluster.u_backend.u_commit_recovery.rob_head1.valid,
                 dut.u_core.u_core_cluster.u_backend.u_commit_recovery.rob_head1.complete,
                 dut.u_core.u_core_cluster.u_backend.u_commit_recovery.rob_head1.entry.is_store,
                 dut.u_core.u_core_cluster.u_backend.u_commit_recovery.rob_head1.entry.sq_id,
                 dut.u_core.u_core_cluster.u_backend.sq_commit_valid,
                 dut.u_core.u_core_cluster.u_backend.sq_commit_ready,
                 dut.u_core.u_core_cluster.u_backend.sq_commit_done,
                 dut.u_core.u_core_cluster.u_backend.sq_commit_id,
                 dut.u_core.u_core_cluster.u_backend.sq_entries[0].valid,
                 dut.u_core.u_core_cluster.u_backend.sq_entries[0].address_valid,
                 dut.u_core.u_core_cluster.u_backend.sq_entries[0].data_valid,
                 dut.u_core.u_core_cluster.u_backend.sq_entries[0].byte_enable,
                 dut.u_core.u_core_cluster.u_backend.sq_entries[0].branch_mask,
                 dut.u_core.u_core_cluster.u_backend.sq_entries[1].valid,
                 dut.u_core.u_core_cluster.u_backend.sq_entries[1].address_valid,
                 dut.u_core.u_core_cluster.u_backend.sq_entries[1].data_valid,
                 dut.u_core.u_core_cluster.u_backend.sq_entries[1].byte_enable,
                 dut.u_core.u_core_cluster.u_backend.sq_entries[1].branch_mask,
                 dut.u_core.u_core_cluster.u_backend.sq_entries[4].valid,
                 dut.u_core.u_core_cluster.u_backend.sq_entries[4].address_valid,
                 dut.u_core.u_core_cluster.u_backend.sq_entries[4].data_valid,
                 dut.u_core.u_core_cluster.u_backend.sq_entries[4].byte_enable,
                 dut.u_core.u_core_cluster.u_backend.sq_entries[4].branch_mask,
                 dut.u_core.u_core_cluster.u_backend.sq_entries[5].valid,
                 dut.u_core.u_core_cluster.u_backend.sq_entries[5].address_valid,
                 dut.u_core.u_core_cluster.u_backend.sq_entries[5].data_valid,
                 dut.u_core.u_core_cluster.u_backend.sq_entries[5].byte_enable,
                 dut.u_core.u_core_cluster.u_backend.sq_entries[5].branch_mask,
                 dut.core_store_req.valid,
                 dut.core_store_req_ready,
                 dut.ram_store_req.valid,
                 dut.ram_store_req_ready,
                 dut.ram_store_req.address,
                 dut.ram_store_req.byte_enable);
      end

      if (trace_enabled && redirect_valid_o)
        $display("TRACE REDIRECT cycle=%0d pc=%08h cause=%0d",
                 cycles, redirect_pc_o, recovery_o.cause);

      if (trace_enabled &&
          dut.u_core.u_core_cluster.u_backend.u_commit_recovery.u_rename_rob
              .u_allocation_cluster.branch_checkpoint_save) begin
        $display("TRACE CP_SAVE cycle=%0d id=%0d lane1=%b tail=%0d rob0=%0d rob1=%0d pc0=%08h pc1=%08h uop_rob0=%0d uop_rob1=%0d mask0=%b mask1=%b",
                 cycles,
                 dut.u_core.u_core_cluster.u_backend.u_commit_recovery.u_rename_rob
                     .u_allocation_cluster.branch_checkpoint_id,
                 dut.u_core.u_core_cluster.u_backend.u_commit_recovery.u_rename_rob
                     .u_allocation_cluster.branch_is_lane1,
                 dut.u_core.u_core_cluster.u_backend.u_commit_recovery.u_rename_rob
                     .u_allocation_cluster.branch_rob_tail,
                 dut.u_core.u_core_cluster.u_backend.u_commit_recovery.u_rename_rob
                     .rob_alloc_id0,
                 dut.u_core.u_core_cluster.u_backend.u_commit_recovery.u_rename_rob
                     .rob_alloc_id1,
                 dut.u_core.u_core_cluster.u_backend.u_commit_recovery.u_rename_rob
                     .dispatch_uop0_o.dec.pc,
                 dut.u_core.u_core_cluster.u_backend.u_commit_recovery.u_rename_rob
                     .dispatch_uop1_o.dec.pc,
                 dut.u_core.u_core_cluster.u_backend.u_commit_recovery.u_rename_rob
                     .dispatch_uop0_o.rob_id,
                 dut.u_core.u_core_cluster.u_backend.u_commit_recovery.u_rename_rob
                     .dispatch_uop1_o.rob_id,
                 dut.u_core.u_core_cluster.u_backend.u_commit_recovery.u_rename_rob
                     .dispatch_uop0_o.branch_mask,
                 dut.u_core.u_core_cluster.u_backend.u_commit_recovery.u_rename_rob
                     .dispatch_uop1_o.branch_mask);
      end

      if (trace_enabled && recovery_o.valid) begin
        $display("TRACE RECOVERY cycle=%0d cause=%0d cp=%0d redirect=%08h restore_valid=%b restore_tail=%0d rob_head_valid=%b occ=%0d",
                 cycles,
                 recovery_o.cause,
                 recovery_o.checkpoint_id,
                 recovery_o.redirect_pc,
                 dut.u_core.u_core_cluster.u_backend.u_commit_recovery.u_rename_rob
                     .branch_restore_valid,
                 dut.u_core.u_core_cluster.u_backend.u_commit_recovery.u_rename_rob
                     .branch_restore_tail,
                 dut.u_core.u_core_cluster.u_backend.u_commit_recovery.rob_head_valid,
                 rob_occupancy_o);
      end

      if (trace_enabled &&
          (dut.u_core.u_core_cluster.u_backend.branch_event_raw.valid ||
           dut.u_core.u_core_cluster.u_backend.branch_event_pending_q ||
           dut.u_core.u_core_cluster.u_backend.branch_event_fire ||
           dut.u_core.u_core_cluster.u_backend.branch_event_to_commit_q.valid)) begin
        $display("TRACE_BRANCH cycle=%0d raw[v=%0b id=%0d cp=%0d mis=%0b pc=%08h redir=%08h] pend=%0b q[id=%0d cp=%0d mis=%0b pc=%08h redir=%08h] fire=%0b out=%0b comp0[v=%0b id=%0d] comp1[v=%0b id=%0d]",
                 cycles,
                 dut.u_core.u_core_cluster.u_backend.branch_event_raw.valid,
                 dut.u_core.u_core_cluster.u_backend.branch_event_raw.rob_id,
                 dut.u_core.u_core_cluster.u_backend.branch_event_raw.checkpoint_id,
                 dut.u_core.u_core_cluster.u_backend.branch_event_raw.mispredict,
                 dut.u_core.u_core_cluster.u_backend.branch_event_raw.update.pc,
                 dut.u_core.u_core_cluster.u_backend.branch_event_raw.redirect_pc,
                 dut.u_core.u_core_cluster.u_backend.branch_event_pending_q,
                 dut.u_core.u_core_cluster.u_backend.branch_event_q.rob_id,
                 dut.u_core.u_core_cluster.u_backend.branch_event_q.checkpoint_id,
                 dut.u_core.u_core_cluster.u_backend.branch_event_q.mispredict,
                 dut.u_core.u_core_cluster.u_backend.branch_event_q.update.pc,
                 dut.u_core.u_core_cluster.u_backend.branch_event_q.redirect_pc,
                 dut.u_core.u_core_cluster.u_backend.branch_event_fire,
                 dut.u_core.u_core_cluster.u_backend.branch_event_to_commit_q.valid,
                 dut.u_core.u_core_cluster.u_backend.rob_complete[0].valid,
                 dut.u_core.u_core_cluster.u_backend.rob_complete[0].rob_id,
                 dut.u_core.u_core_cluster.u_backend.rob_complete[1].valid,
                 dut.u_core.u_core_cluster.u_backend.rob_complete[1].rob_id);
      end

      if (trace_enabled &&
          ((dut.u_core.u_core_cluster.u_backend.issue_valid != 3'b000) ||
           dut.u_core.u_core_cluster.u_backend.int0_ex_valid ||
           dut.u_core.u_core_cluster.u_backend.int1_ex_valid ||
           dut.u_core.u_core_cluster.u_backend.wb_valid != 2'b00 ||
           dut.u_core.u_core_cluster.u_backend.u_commit_recovery.rob_head0.entry.is_csr)) begin
        $display("TRACE_PIPE cycle=%0d issue=%b p=%0d/%0d/%0d pc=%08h/%08h/%08h int0[v=%0b r=%0b pc=%08h id=%0d fu=%0d src1=%08h] int1[v=%0b r=%0b pc=%08h id=%0d br=%0d] wb=%b wb0[id=%0d pc=%08h data=%08h wr=%0b] wb1[id=%0d pc=%08h data=%08h wr=%0b] csrhead[v=%0b c=%0b pc=%08h addr=%03h op=%0d operand=%08h]",
                 cycles,
                 dut.u_core.u_core_cluster.u_backend.issue_valid,
                 dut.u_core.u_core_cluster.u_backend.issue_port0,
                 dut.u_core.u_core_cluster.u_backend.issue_port1,
                 dut.u_core.u_core_cluster.u_backend.issue_port2,
                 dut.u_core.u_core_cluster.u_backend.issue_uop0.pc,
                 dut.u_core.u_core_cluster.u_backend.issue_uop1.pc,
                 dut.u_core.u_core_cluster.u_backend.issue_uop2.pc,
                 dut.u_core.u_core_cluster.u_backend.int0_ex_valid,
                 dut.u_core.u_core_cluster.u_backend.int0_ex_ready,
                 dut.u_core.u_core_cluster.u_backend.int0_ex_uop.pc,
                 dut.u_core.u_core_cluster.u_backend.int0_ex_uop.rob_id,
                 dut.u_core.u_core_cluster.u_backend.int0_ex_uop.fu_type,
                 dut.u_core.u_core_cluster.u_backend.int0_ex_uop.src1,
                 dut.u_core.u_core_cluster.u_backend.int1_ex_valid,
                 dut.u_core.u_core_cluster.u_backend.int1_ex_ready,
                 dut.u_core.u_core_cluster.u_backend.int1_ex_uop.pc,
                 dut.u_core.u_core_cluster.u_backend.int1_ex_uop.rob_id,
                 dut.u_core.u_core_cluster.u_backend.int1_ex_uop.fu_type,
                 dut.u_core.u_core_cluster.u_backend.wb_valid,
                 dut.u_core.u_core_cluster.u_backend.wb_completion[0].rob_id,
                 dut.u_core.u_core_cluster.u_backend.u_commit_recovery.u_rename_rob.u_reorder_buffer.entry_q[dut.u_core.u_core_cluster.u_backend.wb_completion[0].rob_id].pc,
                 dut.u_core.u_core_cluster.u_backend.wb_completion[0].data,
                 dut.u_core.u_core_cluster.u_backend.wb_completion[0].write_prf,
                 dut.u_core.u_core_cluster.u_backend.wb_completion[1].rob_id,
                 dut.u_core.u_core_cluster.u_backend.u_commit_recovery.u_rename_rob.u_reorder_buffer.entry_q[dut.u_core.u_core_cluster.u_backend.wb_completion[1].rob_id].pc,
                 dut.u_core.u_core_cluster.u_backend.wb_completion[1].data,
                 dut.u_core.u_core_cluster.u_backend.wb_completion[1].write_prf,
                 dut.u_core.u_core_cluster.u_backend.u_commit_recovery.rob_head0.valid,
                 dut.u_core.u_core_cluster.u_backend.u_commit_recovery.rob_head0.complete,
                 dut.u_core.u_core_cluster.u_backend.u_commit_recovery.rob_head0.entry.pc,
                 dut.u_core.u_core_cluster.u_backend.u_commit_recovery.rob_head0.entry.csr_addr,
                 dut.u_core.u_core_cluster.u_backend.u_commit_recovery.rob_head0.entry.csr_op,
                 dut.u_core.u_core_cluster.u_backend.u_commit_recovery.rob_head0.entry.csr_operand);
      end

      if (trace_enabled &&
          ((dut.u_core.u_core_cluster.u_backend.mem_candidate_valid != 2'b00) ||
           (dut.u_core.u_core_cluster.u_backend.mem_issue_grant != 2'b00) ||
           dut.u_core.u_core_cluster.u_backend.lsu_ex_valid ||
           (dut.u_core.u_core_cluster.u_backend.u_lsu.state_q != 0) ||
           dut.u_core.u_core_cluster.u_backend.u_lsu.result_valid_o ||
           dut.u_core.u_core_cluster.u_backend.u_lsu.mem_req_o.valid ||
           dut.u_core.u_core_cluster.u_backend.u_lsu.mem_resp_i.valid)) begin
        $display("TRACE_LSU cycle=%0d cand=%b grant=%b ex[v=%0b r=%0b pc=%08h id=%0d lq=%0d sq=%0d addr=%08h op=%0d] state=%0d reqpc=%08h reqid=%0d addr=%08h lqaddr[v=%0b r=%0b sent=%0b id=%0d] memreq[v=%0b r=%0b id=%0d addr=%08h] memresp[v=%0b r=%0b id=%0d data=%08h err=%0b] res[v=%0b r=%0b id=%0d data=%08h wr=%0b] lqcomp[v=%0b id=%0d fwd=%0b]",
                 cycles,
                 dut.u_core.u_core_cluster.u_backend.mem_candidate_valid,
                 dut.u_core.u_core_cluster.u_backend.mem_issue_grant,
                 dut.u_core.u_core_cluster.u_backend.lsu_ex_valid,
                 dut.u_core.u_core_cluster.u_backend.lsu_ex_ready,
                 dut.u_core.u_core_cluster.u_backend.lsu_ex_uop.pc,
                 dut.u_core.u_core_cluster.u_backend.lsu_ex_uop.rob_id,
                 dut.u_core.u_core_cluster.u_backend.lsu_ex_uop.lq_id,
                 dut.u_core.u_core_cluster.u_backend.lsu_ex_uop.sq_id,
                 dut.u_core.u_core_cluster.u_backend.lsu_ex_uop.src1 +
                     dut.u_core.u_core_cluster.u_backend.lsu_ex_uop.imm,
                 dut.u_core.u_core_cluster.u_backend.lsu_ex_uop.mem_op,
                 dut.u_core.u_core_cluster.u_backend.u_lsu.state_q,
                 dut.u_core.u_core_cluster.u_backend.u_lsu.req_uop_q.pc,
                 dut.u_core.u_core_cluster.u_backend.u_lsu.req_uop_q.rob_id,
                 dut.u_core.u_core_cluster.u_backend.u_lsu.req_address_q,
                 dut.u_core.u_core_cluster.u_backend.u_lsu.lq_address_valid_o,
                 dut.u_core.u_core_cluster.u_backend.u_lsu.lq_address_ready_i,
                 dut.u_core.u_core_cluster.u_backend.u_lsu.lq_address_sent_q,
                 dut.u_core.u_core_cluster.u_backend.u_lsu.lq_address_id_o,
                 dut.u_core.u_core_cluster.u_backend.u_lsu.mem_req_o.valid,
                 dut.u_core.u_core_cluster.u_backend.u_lsu.mem_req_ready_i,
                 dut.u_core.u_core_cluster.u_backend.u_lsu.mem_req_o.lq_id,
                 dut.u_core.u_core_cluster.u_backend.u_lsu.mem_req_o.address,
                 dut.u_core.u_core_cluster.u_backend.u_lsu.mem_resp_i.valid,
                 dut.u_core.u_core_cluster.u_backend.u_lsu.mem_resp_ready_o,
                 dut.u_core.u_core_cluster.u_backend.u_lsu.mem_resp_i.lq_id,
                 dut.u_core.u_core_cluster.u_backend.u_lsu.mem_resp_i.data,
                 dut.u_core.u_core_cluster.u_backend.u_lsu.mem_resp_i.error,
                 dut.u_core.u_core_cluster.u_backend.u_lsu.result_valid_o,
                 dut.u_core.u_core_cluster.u_backend.u_lsu.result_ready_i,
                 dut.u_core.u_core_cluster.u_backend.u_lsu.result_o.rob_id,
                 dut.u_core.u_core_cluster.u_backend.u_lsu.result_o.data,
                 dut.u_core.u_core_cluster.u_backend.u_lsu.result_o.write_prf,
                 dut.u_core.u_core_cluster.u_backend.u_lsu.lq_complete_valid_o,
                 dut.u_core.u_core_cluster.u_backend.u_lsu.lq_complete_id_o,
                 dut.u_core.u_core_cluster.u_backend.u_lsu.lq_complete_forwarded_o);
      end

      if (trace_enabled &&
          ((dut.u_core.u_core_cluster.u_backend.int_issue_grant != 3'b000) ||
           (dut.u_core.u_core_cluster.u_backend.int_candidate_uop0.pc == 32'h800001c4) ||
           (dut.u_core.u_core_cluster.u_backend.int_candidate_uop1.pc == 32'h800001c4) ||
           (dut.u_core.u_core_cluster.u_backend.int_candidate_uop2.pc == 32'h800001c4))) begin
        $display("TRACE_IQ cycle=%0d db_rn=%b db_ready=%0b db_head=%0d db_tail=%0d db_count=%0d db_disp=%0d rawv=%b rawpc=%08h/%08h rawid=%0d/%0d qv=%b qpc=%08h/%08h qid=%0d/%0d pop=%0b candv=%b grant=%b slot=%0d/%0d/%0d candpc=%08h/%08h/%08h candid=%0d/%0d/%0d clear=%b clearslot=%0d/%0d/%0d valid=%b count=%0d",
                 cycles,
                 dut.u_core.u_core_cluster.u_backend.u_dispatch_buffer.rn_valid_i,
                 dut.u_core.u_core_cluster.u_backend.u_dispatch_buffer.rn_ready_o,
                 dut.u_core.u_core_cluster.u_backend.u_dispatch_buffer.head_q,
                 dut.u_core.u_core_cluster.u_backend.u_dispatch_buffer.tail_q,
                 dut.u_core.u_core_cluster.u_backend.u_dispatch_buffer.count_q,
                 dut.u_core.u_core_cluster.u_backend.u_dispatch_buffer.dispatch_count,
                 dut.u_core.u_core_cluster.u_backend.int_push_valid_raw,
                 dut.u_core.u_core_cluster.u_backend.int_push_uop0_raw.pc,
                 dut.u_core.u_core_cluster.u_backend.int_push_uop1_raw.pc,
                 dut.u_core.u_core_cluster.u_backend.int_push_uop0_raw.rob_id,
                 dut.u_core.u_core_cluster.u_backend.int_push_uop1_raw.rob_id,
                 dut.u_core.u_core_cluster.u_backend.int_push_valid_q,
                 dut.u_core.u_core_cluster.u_backend.int_push_uop0_q.pc,
                 dut.u_core.u_core_cluster.u_backend.int_push_uop1_q.pc,
                 dut.u_core.u_core_cluster.u_backend.int_push_uop0_q.rob_id,
                 dut.u_core.u_core_cluster.u_backend.int_push_uop1_q.rob_id,
                 dut.u_core.u_core_cluster.u_backend.int_push_stage_pop,
                 dut.u_core.u_core_cluster.u_backend.int_candidate_valid,
                 dut.u_core.u_core_cluster.u_backend.int_issue_grant,
                 dut.u_core.u_core_cluster.u_backend.unused_int_slot0,
                 dut.u_core.u_core_cluster.u_backend.unused_int_slot1,
                 dut.u_core.u_core_cluster.u_backend.unused_int_slot2,
                 dut.u_core.u_core_cluster.u_backend.int_candidate_uop0.pc,
                 dut.u_core.u_core_cluster.u_backend.int_candidate_uop1.pc,
                 dut.u_core.u_core_cluster.u_backend.int_candidate_uop2.pc,
                 dut.u_core.u_core_cluster.u_backend.int_candidate_uop0.rob_id,
                 dut.u_core.u_core_cluster.u_backend.int_candidate_uop1.rob_id,
                 dut.u_core.u_core_cluster.u_backend.int_candidate_uop2.rob_id,
                 dut.u_core.u_core_cluster.u_backend.u_int_issue_queue.clear_valid_q,
                 dut.u_core.u_core_cluster.u_backend.u_int_issue_queue.clear_slot_q[0],
                 dut.u_core.u_core_cluster.u_backend.u_int_issue_queue.clear_slot_q[1],
                 dut.u_core.u_core_cluster.u_backend.u_int_issue_queue.clear_slot_q[2],
                 dut.u_core.u_core_cluster.u_backend.u_int_issue_queue.valid_q,
                 dut.u_core.u_core_cluster.u_backend.u_int_issue_queue.count_q);
      end

      if (trace_enabled &&
          dut.u_core.u_core_cluster.u_backend.u_commit_recovery.u_rename_rob
              .u_reorder_buffer.restore_done_q) begin
        $display("TRACE ROB_RESTORE_DONE cycle=%0d tail=%0d old_tail_row=%0d occ=%0d head_valid=%b head_pc0=%08h head_pc1=%08h",
                 cycles,
                 dut.u_core.u_core_cluster.u_backend.u_commit_recovery.u_rename_rob
                     .u_reorder_buffer.scan_restore_tail_q,
                 dut.u_core.u_core_cluster.u_backend.u_commit_recovery.u_rename_rob
                     .u_reorder_buffer.scan_old_tail_row_q,
                 rob_occupancy_o,
                 dut.u_core.u_core_cluster.u_backend.u_commit_recovery.rob_head_valid,
                 dut.u_core.u_core_cluster.u_backend.u_commit_recovery.rob_head0.entry.pc,
                 dut.u_core.u_core_cluster.u_backend.u_commit_recovery.rob_head1.entry.pc);
      end

      if (trace_enabled &&
          (dut.u_core.u_core_cluster.u_backend.dispatch_fire ||
           (dut.u_core.u_core_cluster.u_backend.sq_alloc_valid != 2'b00) ||
           dut.u_core.u_core_cluster.u_backend.sq_release_valid ||
           dut.u_core.u_core_cluster.u_backend.u_commit_recovery.u_rename_rob
               .u_allocation_cluster.u_lsq_allocator.alloc_fire_i ||
           dut.u_core.u_core_cluster.u_backend.u_commit_recovery.u_rename_rob
               .u_allocation_cluster.u_lsq_allocator.alloc_cancel_i ||
           dut.u_core.u_core_cluster.u_backend.u_commit_recovery.u_rename_rob
               .u_allocation_cluster.u_lsq_allocator.checkpoint_save_i ||
           dut.u_core.u_core_cluster.u_backend.u_commit_recovery.u_rename_rob
               .u_allocation_cluster.u_lsq_allocator.branch_restore_i ||
           dut.u_core.u_core_cluster.u_backend.u_commit_recovery.u_rename_rob
               .u_allocation_cluster.u_lsq_allocator.rollback_busy_q ||
           dut.u_core.u_core_cluster.u_backend.u_commit_recovery.u_rename_rob
               .u_allocation_cluster.u_lsq_allocator.branch_restore_done_q)) begin
        $display("TRACE_LSQ_ALLOC cycle=%0d disp[f=%0b v=%b pc=%08h/%08h rob=%0d/%0d sq=%0d/%0d st=%0b/%0b sqav=%b] alloc[req_lq=%0d req_sq=%0d valid=%0b fire=%0b cancel=%0b res=%0b lqc=%0d sqc=%0d lqid=%0d/%0d sqid=%0d/%0d free_lq=%b free_sq=%b tail_lq=%0d tail_sq=%0d] rel[lqv=%b lqid=%0d/%0d sqv=%b sqid=%0d/%0d] cp[save=%0b id=%0d keep_lq=%0d keep_sq=%0d valid=%b tails_lq=%0d/%0d/%0d/%0d tails_sq=%0d/%0d/%0d/%0d clear=%0b/%0d restore=%0b/%0d rb=%0b tgt=%0d/%0d done=%0b]",
                 cycles,
                 dut.u_core.u_core_cluster.u_backend.dispatch_fire,
                 dut.u_core.u_core_cluster.u_backend.dispatch_valid,
                 dut.u_core.u_core_cluster.u_backend.dispatch_uop0.dec.pc,
                 dut.u_core.u_core_cluster.u_backend.dispatch_uop1.dec.pc,
                 dut.u_core.u_core_cluster.u_backend.dispatch_uop0.rob_id,
                 dut.u_core.u_core_cluster.u_backend.dispatch_uop1.rob_id,
                 dut.u_core.u_core_cluster.u_backend.dispatch_uop0.sq_id,
                 dut.u_core.u_core_cluster.u_backend.dispatch_uop1.sq_id,
                 dut.u_core.u_core_cluster.u_backend.sq_alloc_valid[0],
                 dut.u_core.u_core_cluster.u_backend.sq_alloc_valid[1],
                 dut.u_core.u_core_cluster.u_backend.sq_alloc_valid,
                 dut.u_core.u_core_cluster.u_backend.u_commit_recovery.u_rename_rob
                     .u_allocation_cluster.u_lsq_allocator.alloc_lq_count_i,
                 dut.u_core.u_core_cluster.u_backend.u_commit_recovery.u_rename_rob
                     .u_allocation_cluster.u_lsq_allocator.alloc_sq_count_i,
                 dut.u_core.u_core_cluster.u_backend.u_commit_recovery.u_rename_rob
                     .u_allocation_cluster.u_lsq_allocator.alloc_valid_o,
                 dut.u_core.u_core_cluster.u_backend.u_commit_recovery.u_rename_rob
                     .u_allocation_cluster.u_lsq_allocator.alloc_fire_i,
                 dut.u_core.u_core_cluster.u_backend.u_commit_recovery.u_rename_rob
                     .u_allocation_cluster.u_lsq_allocator.alloc_cancel_i,
                 dut.u_core.u_core_cluster.u_backend.u_commit_recovery.u_rename_rob
                     .u_allocation_cluster.u_lsq_allocator.reservation_valid_q,
                 dut.u_core.u_core_cluster.u_backend.u_commit_recovery.u_rename_rob
                     .u_allocation_cluster.u_lsq_allocator.reservation_lq_count_q,
                 dut.u_core.u_core_cluster.u_backend.u_commit_recovery.u_rename_rob
                     .u_allocation_cluster.u_lsq_allocator.reservation_sq_count_q,
                 dut.u_core.u_core_cluster.u_backend.u_commit_recovery.u_rename_rob
                     .u_allocation_cluster.u_lsq_allocator.reservation_lq_id_q[0],
                 dut.u_core.u_core_cluster.u_backend.u_commit_recovery.u_rename_rob
                     .u_allocation_cluster.u_lsq_allocator.reservation_lq_id_q[1],
                 dut.u_core.u_core_cluster.u_backend.u_commit_recovery.u_rename_rob
                     .u_allocation_cluster.u_lsq_allocator.reservation_sq_id_q[0],
                 dut.u_core.u_core_cluster.u_backend.u_commit_recovery.u_rename_rob
                     .u_allocation_cluster.u_lsq_allocator.reservation_sq_id_q[1],
                 dut.u_core.u_core_cluster.u_backend.u_commit_recovery.u_rename_rob
                     .u_allocation_cluster.u_lsq_allocator.lq_free_bitmap_q,
                 dut.u_core.u_core_cluster.u_backend.u_commit_recovery.u_rename_rob
                     .u_allocation_cluster.u_lsq_allocator.sq_free_bitmap_q,
                 dut.u_core.u_core_cluster.u_backend.u_commit_recovery.u_rename_rob
                     .u_allocation_cluster.u_lsq_allocator.lq_log_tail_q,
                 dut.u_core.u_core_cluster.u_backend.u_commit_recovery.u_rename_rob
                     .u_allocation_cluster.u_lsq_allocator.sq_log_tail_q,
                 dut.u_core.u_core_cluster.u_backend.u_commit_recovery.u_rename_rob
                     .u_allocation_cluster.u_lsq_allocator.lq_release_valid_i,
                 dut.u_core.u_core_cluster.u_backend.u_commit_recovery.u_rename_rob
                     .u_allocation_cluster.u_lsq_allocator.lq_release_id_i[0],
                 dut.u_core.u_core_cluster.u_backend.u_commit_recovery.u_rename_rob
                     .u_allocation_cluster.u_lsq_allocator.lq_release_id_i[1],
                 dut.u_core.u_core_cluster.u_backend.u_commit_recovery.u_rename_rob
                     .u_allocation_cluster.u_lsq_allocator.sq_release_valid_i,
                 dut.u_core.u_core_cluster.u_backend.u_commit_recovery.u_rename_rob
                     .u_allocation_cluster.u_lsq_allocator.sq_release_id_i[0],
                 dut.u_core.u_core_cluster.u_backend.u_commit_recovery.u_rename_rob
                     .u_allocation_cluster.u_lsq_allocator.sq_release_id_i[1],
                 dut.u_core.u_core_cluster.u_backend.u_commit_recovery.u_rename_rob
                     .u_allocation_cluster.u_lsq_allocator.checkpoint_save_i,
                 dut.u_core.u_core_cluster.u_backend.u_commit_recovery.u_rename_rob
                     .u_allocation_cluster.u_lsq_allocator.checkpoint_id_i,
                 dut.u_core.u_core_cluster.u_backend.u_commit_recovery.u_rename_rob
                     .u_allocation_cluster.u_lsq_allocator.checkpoint_keep_lq_count_i,
                 dut.u_core.u_core_cluster.u_backend.u_commit_recovery.u_rename_rob
                     .u_allocation_cluster.u_lsq_allocator.checkpoint_keep_sq_count_i,
                 dut.u_core.u_core_cluster.u_backend.u_commit_recovery.u_rename_rob
                     .u_allocation_cluster.u_lsq_allocator.checkpoint_valid_q,
                 dut.u_core.u_core_cluster.u_backend.u_commit_recovery.u_rename_rob
                     .u_allocation_cluster.u_lsq_allocator.checkpoint_lq_tail_q[0],
                 dut.u_core.u_core_cluster.u_backend.u_commit_recovery.u_rename_rob
                     .u_allocation_cluster.u_lsq_allocator.checkpoint_lq_tail_q[1],
                 dut.u_core.u_core_cluster.u_backend.u_commit_recovery.u_rename_rob
                     .u_allocation_cluster.u_lsq_allocator.checkpoint_lq_tail_q[2],
                 dut.u_core.u_core_cluster.u_backend.u_commit_recovery.u_rename_rob
                     .u_allocation_cluster.u_lsq_allocator.checkpoint_lq_tail_q[3],
                 dut.u_core.u_core_cluster.u_backend.u_commit_recovery.u_rename_rob
                     .u_allocation_cluster.u_lsq_allocator.checkpoint_sq_tail_q[0],
                 dut.u_core.u_core_cluster.u_backend.u_commit_recovery.u_rename_rob
                     .u_allocation_cluster.u_lsq_allocator.checkpoint_sq_tail_q[1],
                 dut.u_core.u_core_cluster.u_backend.u_commit_recovery.u_rename_rob
                     .u_allocation_cluster.u_lsq_allocator.checkpoint_sq_tail_q[2],
                 dut.u_core.u_core_cluster.u_backend.u_commit_recovery.u_rename_rob
                     .u_allocation_cluster.u_lsq_allocator.checkpoint_sq_tail_q[3],
                 dut.u_core.u_core_cluster.u_backend.u_commit_recovery.u_rename_rob
                     .u_allocation_cluster.u_lsq_allocator.checkpoint_clear_i,
                 dut.u_core.u_core_cluster.u_backend.u_commit_recovery.u_rename_rob
                     .u_allocation_cluster.u_lsq_allocator.checkpoint_clear_id_i,
                 dut.u_core.u_core_cluster.u_backend.u_commit_recovery.u_rename_rob
                     .u_allocation_cluster.u_lsq_allocator.branch_restore_i,
                 dut.u_core.u_core_cluster.u_backend.u_commit_recovery.u_rename_rob
                     .u_allocation_cluster.u_lsq_allocator.branch_restore_id_i,
                 dut.u_core.u_core_cluster.u_backend.u_commit_recovery.u_rename_rob
                     .u_allocation_cluster.u_lsq_allocator.rollback_busy_q,
                 dut.u_core.u_core_cluster.u_backend.u_commit_recovery.u_rename_rob
                     .u_allocation_cluster.u_lsq_allocator.rollback_lq_target_q,
                 dut.u_core.u_core_cluster.u_backend.u_commit_recovery.u_rename_rob
                     .u_allocation_cluster.u_lsq_allocator.rollback_sq_target_q,
                 dut.u_core.u_core_cluster.u_backend.u_commit_recovery.u_rename_rob
                     .u_allocation_cluster.u_lsq_allocator.branch_restore_done_q);
      end

      if (cycles >= max_cycles) begin
        $display("REGRESSION_RESULT TIMEOUT test=%s cycles=%0d last_pc=%08h gp=%08h",
                 test_name, cycles, last_commit_pc, committed_x3());
        $fatal(1, "official test timed out");
      end
    end
  end
endmodule
