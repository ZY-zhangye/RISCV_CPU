import core_types_pkg::*;

module tb_soc_custom_instr;
  timeunit 1ns;
  timeprecision 1ps;

  localparam logic [XLEN-1:0] IMAGE_BASE = 32'h8000_0000;
  localparam int unsigned RAM_BYTES = 32768;
  localparam int unsigned INIT_BLOCKS = 64;
  localparam int unsigned MAX_PROG_WORDS = 64;
  localparam int unsigned WB_HISTORY_ENTRIES = 256;
  localparam logic [31:0] NOP = 32'h0000_0013;

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

  logic [31:0] prog_mem [0:MAX_PROG_WORDS-1];
  int unsigned program_len;
  string case_name;
  string selected_case;
  bit has_case_select;
  bit trace_enabled;
  bit allow_redirect;
  bit expect_redirect;
  bit seen_redirect;
  logic [XLEN-1:0] expected_redirect_pc;
  string wait_reason;
  bit commit_seen [0:MAX_PROG_WORDS-1];
  bit wb_seen_valid [0:WB_HISTORY_ENTRIES-1];
  logic [4:0] wb_seen_rd [0:WB_HISTORY_ENTRIES-1];
  logic [XLEN-1:0] wb_seen_data [0:WB_HISTORY_ENTRIES-1];
  int unsigned wb_seen_count;
  int cycles;
  int passed_cases;

  soc_top #(
      .RESET_MTVEC(IMAGE_BASE),
      .RAM_BASE(IMAGE_BASE),
      .RAM_BYTES(RAM_BYTES),
      .MMIO_BYTES(4096),
      .POWER_ON_RESET_CYCLES(2)
  ) dut (.*);

  always #5 clk_i = ~clk_i;

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

  function automatic logic [31:0] enc_i(
      input logic [31:0] imm,
      input logic [4:0] rs1,
      input logic [2:0] funct3,
      input logic [4:0] rd,
      input logic [6:0] opcode
  );
    enc_i = {imm[11:0], rs1, funct3, rd, opcode};
  endfunction

  function automatic logic [31:0] enc_s(
      input logic [31:0] imm,
      input logic [4:0] rs2,
      input logic [4:0] rs1,
      input logic [2:0] funct3
  );
    enc_s = {imm[11:5], rs2, rs1, funct3, imm[4:0], 7'b0100011};
  endfunction

  function automatic logic [31:0] enc_b(
      input logic signed [31:0] imm,
      input logic [4:0] rs2,
      input logic [4:0] rs1,
      input logic [2:0] funct3
  );
    logic [12:0] bits;
    begin
      bits = imm[12:0];
      enc_b = {bits[12], bits[10:5], rs2, rs1, funct3, bits[4:1],
               bits[11], 7'b1100011};
    end
  endfunction

  function automatic logic [31:0] enc_u(
      input logic [19:0] imm20,
      input logic [4:0] rd,
      input logic [6:0] opcode
  );
    enc_u = {imm20, rd, opcode};
  endfunction

  function automatic logic [31:0] enc_j(
      input logic signed [31:0] imm,
      input logic [4:0] rd
  );
    logic [20:0] bits;
    begin
      bits = imm[20:0];
      enc_j = {bits[20], bits[10:1], bits[11], bits[19:12], rd, 7'b1101111};
    end
  endfunction

  function automatic logic [31:0] enc_csr(
      input logic [11:0] csr,
      input logic [4:0] rs1_or_zimm,
      input logic [2:0] funct3,
      input logic [4:0] rd
  );
    enc_csr = {csr, rs1_or_zimm, funct3, rd, 7'b1110011};
  endfunction

  function automatic logic [31:0] addi(input logic [4:0] rd,
                                       input logic [4:0] rs1,
                                       input logic [31:0] imm);
    addi = enc_i(imm, rs1, 3'b000, rd, 7'b0010011);
  endfunction

  function automatic logic [31:0] lui(input logic [4:0] rd,
                                      input logic [19:0] imm20);
    lui = enc_u(imm20, rd, 7'b0110111);
  endfunction

  function automatic logic [31:0] auipc(input logic [4:0] rd,
                                        input logic [19:0] imm20);
    auipc = enc_u(imm20, rd, 7'b0010111);
  endfunction

  function automatic logic [31:0] alu_r(input logic [4:0] rd,
                                        input logic [4:0] rs1,
                                        input logic [4:0] rs2,
                                        input logic [2:0] funct3,
                                        input logic [6:0] funct7);
    alu_r = enc_r(funct7, rs2, rs1, funct3, rd, 7'b0110011);
  endfunction

  function automatic logic [31:0] alu_i(input logic [4:0] rd,
                                        input logic [4:0] rs1,
                                        input logic [2:0] funct3,
                                        input logic [31:0] imm);
    alu_i = enc_i(imm, rs1, funct3, rd, 7'b0010011);
  endfunction

  function automatic logic [31:0] load_i(input logic [4:0] rd,
                                         input logic [4:0] rs1,
                                         input logic [2:0] funct3,
                                         input logic [31:0] imm);
    load_i = enc_i(imm, rs1, funct3, rd, 7'b0000011);
  endfunction

  function automatic logic [31:0] store_s(input logic [4:0] rs2,
                                          input logic [4:0] rs1,
                                          input logic [2:0] funct3,
                                          input logic [31:0] imm);
    store_s = enc_s(imm, rs2, rs1, funct3);
  endfunction

  function automatic logic [31:0] branch_b(input logic [4:0] rs1,
                                           input logic [4:0] rs2,
                                           input logic [2:0] funct3,
                                           input logic signed [31:0] imm);
    branch_b = enc_b(imm, rs2, rs1, funct3);
  endfunction

  function automatic logic [31:0] jal(input logic [4:0] rd,
                                      input logic signed [31:0] imm);
    jal = enc_j(imm, rd);
  endfunction

  function automatic logic [31:0] jalr(input logic [4:0] rd,
                                       input logic [4:0] rs1,
                                       input logic [31:0] imm);
    jalr = enc_i(imm, rs1, 3'b000, rd, 7'b1100111);
  endfunction

  function automatic logic [31:0] m_op(input logic [4:0] rd,
                                       input logic [4:0] rs1,
                                       input logic [4:0] rs2,
                                       input logic [2:0] funct3);
    m_op = enc_r(7'b0000001, rs2, rs1, funct3, rd, 7'b0110011);
  endfunction

  function automatic logic [127:0] inst_block(
      input logic [31:0] inst0,
      input logic [31:0] inst1,
      input logic [31:0] inst2,
      input logic [31:0] inst3
  );
    inst_block = {inst3, inst2, inst1, inst0};
  endfunction

  task automatic add_inst(input logic [31:0] inst);
    begin
      if (program_len >= MAX_PROG_WORDS)
        fail("program_too_long");
      prog_mem[program_len] = inst;
      program_len++;
    end
  endtask

  task automatic clear_program();
    int idx;
    begin
      for (idx = 0; idx < MAX_PROG_WORDS; idx++)
        prog_mem[idx] = NOP;
      program_len = 0;
    end
  endtask

  task automatic write_imem_block(input logic [XLEN-1:0] addr,
                                  input logic [127:0] data);
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

  task automatic write_dmem_word(input logic [XLEN-1:0] addr,
                                 input logic [XLEN-1:0] data);
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

  task automatic load_program();
    int unsigned block_idx;
    int unsigned word_idx;
    logic [31:0] i0;
    logic [31:0] i1;
    logic [31:0] i2;
    logic [31:0] i3;
    begin
      for (block_idx = 0; block_idx < INIT_BLOCKS; block_idx++)
        write_imem_block(IMAGE_BASE + block_idx * 16, inst_block(NOP, NOP, NOP, NOP));

      for (block_idx = 0; block_idx < ((program_len + 3) / 4); block_idx++) begin
        word_idx = block_idx * 4;
        i0 = (word_idx + 0 < program_len) ? prog_mem[word_idx + 0] : NOP;
        i1 = (word_idx + 1 < program_len) ? prog_mem[word_idx + 1] : NOP;
        i2 = (word_idx + 2 < program_len) ? prog_mem[word_idx + 2] : NOP;
        i3 = (word_idx + 3 < program_len) ? prog_mem[word_idx + 3] : NOP;
        write_imem_block(IMAGE_BASE + block_idx * 16, inst_block(i0, i1, i2, i3));
      end
    end
  endtask

  function automatic logic [PRD_W-1:0] committed_prd(input logic [4:0] rd);
    committed_prd = dut.u_core.u_core_cluster.u_backend.u_commit_recovery
        .u_rename_rob.u_rename_stage.u_rat_amt.amt_q[rd];
  endfunction

  function automatic logic [XLEN-1:0] prf_value(input logic [PRD_W-1:0] prd);
    begin
      if (prd == '0) begin
        prf_value = '0;
      end else if (prd[0]) begin
        prf_value = dut.u_core.u_core_cluster.u_backend.u_commit_recovery
            .u_commit_prf.u_prf.bank1_copy0[prd[PRD_W-1:1]];
      end else begin
        prf_value = dut.u_core.u_core_cluster.u_backend.u_commit_recovery
            .u_commit_prf.u_prf.bank0_copy0[prd[PRD_W-1:1]];
      end
    end
  endfunction

  function automatic logic [XLEN-1:0] committed_reg(input logic [4:0] rd);
    committed_reg = prf_value(committed_prd(rd));
  endfunction

  function automatic logic [XLEN-1:0] dmem_word(input logic [XLEN-1:0] addr);
    int unsigned idx;
    begin
      idx = (addr - IMAGE_BASE) >> 2;
      dmem_word = {
        dut.u_data_ram.mem_b3_q[idx],
        dut.u_data_ram.mem_b2_q[idx],
        dut.u_data_ram.mem_b1_q[idx],
        dut.u_data_ram.mem_b0_q[idx]
      };
    end
  endfunction

  function automatic logic completion_matches_rd(
      input completion_t completion,
      input logic [4:0] rd,
      input logic [XLEN-1:0] expected
  );
    rob_alloc_t entry;
    begin
      entry = dut.u_core.u_core_cluster.u_backend.u_commit_recovery
          .u_rename_rob.u_reorder_buffer.entry_q[completion.rob_id];
      completion_matches_rd =
          completion.valid && completion.write_prf &&
          (entry.arch_rd == rd) &&
          (entry.new_prd == completion.prd) &&
          (completion.data === expected);
    end
  endfunction

  function automatic logic raw_retire_pc(input logic [XLEN-1:0] pc);
    begin
      raw_retire_pc = 1'b0;
      if (dut.u_core.u_core_cluster.u_backend.u_commit_recovery.retire_count_raw >= 2'd1 &&
          dut.u_core.u_core_cluster.u_backend.u_commit_recovery.rob_head0.entry.pc == pc)
        raw_retire_pc = 1'b1;
      if (dut.u_core.u_core_cluster.u_backend.u_commit_recovery.retire_count_raw >= 2'd2 &&
          dut.u_core.u_core_cluster.u_backend.u_commit_recovery.rob_head1.entry.pc == pc)
        raw_retire_pc = 1'b1;
    end
  endfunction

  function automatic int pc_word_index(input logic [XLEN-1:0] pc);
    pc_word_index = (pc - IMAGE_BASE) >> 2;
  endfunction

  function automatic logic wb_history_matches(input logic [4:0] rd,
                                              input logic [XLEN-1:0] expected);
    begin
      wb_history_matches = 1'b0;
      for (int idx = 0; idx < WB_HISTORY_ENTRIES; idx++) begin
        if (wb_seen_valid[idx] &&
            (wb_seen_rd[idx] == rd) &&
            (wb_seen_data[idx] === expected))
          wb_history_matches = 1'b1;
      end
    end
  endfunction

  task automatic record_wb_lane(input completion_t completion);
    rob_alloc_t entry;
    begin
      if (completion.valid && completion.write_prf) begin
        entry = dut.u_core.u_core_cluster.u_backend.u_commit_recovery
            .u_rename_rob.u_reorder_buffer.entry_q[completion.rob_id];
        if (entry.new_prd == completion.prd) begin
          if (wb_seen_count >= WB_HISTORY_ENTRIES)
            fail("wb_history_overflow");
          wb_seen_valid[wb_seen_count] = 1'b1;
          wb_seen_rd[wb_seen_count] = entry.arch_rd;
          wb_seen_data[wb_seen_count] = completion.data;
          wb_seen_count++;
        end
      end
    end
  endtask

  task automatic record_wb_history();
    begin
      if (dut.u_core.u_core_cluster.u_backend.wb_valid[0])
        record_wb_lane(dut.u_core.u_core_cluster.u_backend.wb_completion[0]);
      if (dut.u_core.u_core_cluster.u_backend.wb_valid[1])
        record_wb_lane(dut.u_core.u_core_cluster.u_backend.wb_completion[1]);
    end
  endtask

  task automatic record_commit_history();
    int idx;
    begin
      if (dut.u_core.u_core_cluster.u_backend.u_commit_recovery.retire_count_raw >= 2'd1) begin
        idx = pc_word_index(
            dut.u_core.u_core_cluster.u_backend.u_commit_recovery.rob_head0.entry.pc);
        if ((idx >= 0) && (idx < MAX_PROG_WORDS))
          commit_seen[idx] = 1'b1;
      end
      if (dut.u_core.u_core_cluster.u_backend.u_commit_recovery.retire_count_raw >= 2'd2) begin
        idx = pc_word_index(
            dut.u_core.u_core_cluster.u_backend.u_commit_recovery.rob_head1.entry.pc);
        if ((idx >= 0) && (idx < MAX_PROG_WORDS))
          commit_seen[idx] = 1'b1;
      end
    end
  endtask

  task automatic fail(input string reason);
    begin
      $display("CUSTOM_TEST FAIL name=%s reason=%s cycle=%0d", case_name, reason, cycles);
      $fatal(1, "CUSTOM_TEST failed");
    end
  endtask

  task automatic trace_cycle();
    begin
      if (trace_enabled &&
          ((cycles < 80) ||
           (dut.u_core.u_core_cluster.u_backend.u_commit_recovery.retire_count_raw != 0) ||
           redirect_valid_o ||
           recovery_o.valid ||
           dut.u_core.u_core_cluster.u_backend.u_commit_recovery.checkpoint_clear_valid_o ||
           dut.u_core.u_core_cluster.u_backend.u_commit_recovery.rob_branch_clear_done ||
           dut.u_core.u_core_cluster.u_backend.u_commit_recovery.branch_i.valid ||
           (dut.u_core.u_core_cluster.u_backend.wb_valid != 2'b00) ||
           ((cycles < 160) &&
            ((dut.u_core.u_core_cluster.u_backend.mem_candidate_valid != 2'b00) ||
             (dut.u_core.u_core_cluster.u_backend.mem_issue_grant != 2'b00) ||
             dut.u_core.u_core_cluster.u_backend.lsu_ex_valid ||
             (dut.u_core.u_core_cluster.u_backend.u_lsu.state_q != 0) ||
             dut.u_core.u_core_cluster.u_backend.sq_update_valid ||
             dut.u_core.u_core_cluster.u_backend.lq_address_valid ||
             dut.u_core.u_core_cluster.u_backend.load_mem_req_o.valid ||
             dut.u_core.u_core_cluster.u_backend.load_mem_resp_i.valid ||
             dut.u_core.u_core_cluster.u_backend.store_mem_req_o.valid)) ||
           ((cycles % 100) == 0))) begin
        $display(
            "TRACE cycle=%0d ret=%0d h0[v=%0b c=%0b pc=%08h br=%0b cp=%0d bm=%b] h1[v=%0b c=%0b pc=%08h br=%0b cp=%0d bm=%b] wb=%b rc0[v=%0b id=%0d] rc1[v=%0b id=%0d] be[p=%0b fire=%0b raw=%0b out=%0b] br[v=%0b mis=%0b cp=%0d pc=%08h] clr=%0b/%0d robclr=%0b rec[v=%0b cause=%0d cp=%0d pc=%08h] redir=%0b/%08h busy=%0b occ=%0d",
            cycles,
            dut.u_core.u_core_cluster.u_backend.u_commit_recovery.retire_count_raw,
            dut.u_core.u_core_cluster.u_backend.u_commit_recovery.rob_head0.valid,
            dut.u_core.u_core_cluster.u_backend.u_commit_recovery.rob_head0.complete,
            dut.u_core.u_core_cluster.u_backend.u_commit_recovery.rob_head0.entry.pc,
            dut.u_core.u_core_cluster.u_backend.u_commit_recovery.rob_head0.entry.is_branch,
            dut.u_core.u_core_cluster.u_backend.u_commit_recovery.rob_head0.entry.checkpoint_id,
            dut.u_core.u_core_cluster.u_backend.u_commit_recovery.rob_head0.entry.branch_mask,
            dut.u_core.u_core_cluster.u_backend.u_commit_recovery.rob_head1.valid,
            dut.u_core.u_core_cluster.u_backend.u_commit_recovery.rob_head1.complete,
            dut.u_core.u_core_cluster.u_backend.u_commit_recovery.rob_head1.entry.pc,
            dut.u_core.u_core_cluster.u_backend.u_commit_recovery.rob_head1.entry.is_branch,
            dut.u_core.u_core_cluster.u_backend.u_commit_recovery.rob_head1.entry.checkpoint_id,
            dut.u_core.u_core_cluster.u_backend.u_commit_recovery.rob_head1.entry.branch_mask,
            dut.u_core.u_core_cluster.u_backend.wb_valid,
            dut.u_core.u_core_cluster.u_backend.rob_complete[0].valid,
            dut.u_core.u_core_cluster.u_backend.rob_complete[0].rob_id,
            dut.u_core.u_core_cluster.u_backend.rob_complete[1].valid,
            dut.u_core.u_core_cluster.u_backend.rob_complete[1].rob_id,
            dut.u_core.u_core_cluster.u_backend.branch_event_pending_q,
            dut.u_core.u_core_cluster.u_backend.branch_event_fire,
            dut.u_core.u_core_cluster.u_backend.branch_event_raw.valid,
            dut.u_core.u_core_cluster.u_backend.branch_event_to_commit_q.valid,
            dut.u_core.u_core_cluster.u_backend.u_commit_recovery.branch_i.valid,
            dut.u_core.u_core_cluster.u_backend.u_commit_recovery.branch_i.mispredict,
            dut.u_core.u_core_cluster.u_backend.u_commit_recovery.branch_i.checkpoint_id,
            dut.u_core.u_core_cluster.u_backend.u_commit_recovery.branch_i.redirect_pc,
            dut.u_core.u_core_cluster.u_backend.u_commit_recovery.checkpoint_clear_valid_o,
            dut.u_core.u_core_cluster.u_backend.u_commit_recovery.checkpoint_clear_id_o,
            dut.u_core.u_core_cluster.u_backend.u_commit_recovery.rob_branch_clear_done,
            recovery_o.valid,
            recovery_o.cause,
            recovery_o.checkpoint_id,
            recovery_o.redirect_pc,
            redirect_valid_o,
            redirect_pc_o,
            recovery_busy_o,
            dut.u_core.u_core_cluster.u_backend.u_commit_recovery.rob_occupancy_o);
        if (dut.u_core.u_core_cluster.u_backend.wb_valid[0]) begin
          $display(
              "TRACE_WB cycle=%0d lane=0 id=%0d pc=%08h rd=%0d prd=%0d data=%08h wr=%0b store=%0b ex=%0b prod=%0d",
              cycles,
              dut.u_core.u_core_cluster.u_backend.wb_completion[0].rob_id,
              dut.u_core.u_core_cluster.u_backend.u_commit_recovery.u_rename_rob.u_reorder_buffer.entry_q[dut.u_core.u_core_cluster.u_backend.wb_completion[0].rob_id].pc,
              dut.u_core.u_core_cluster.u_backend.u_commit_recovery.u_rename_rob.u_reorder_buffer.entry_q[dut.u_core.u_core_cluster.u_backend.wb_completion[0].rob_id].arch_rd,
              dut.u_core.u_core_cluster.u_backend.wb_completion[0].prd,
              dut.u_core.u_core_cluster.u_backend.wb_completion[0].data,
              dut.u_core.u_core_cluster.u_backend.wb_completion[0].write_prf,
              dut.u_core.u_core_cluster.u_backend.wb_completion[0].is_store,
              dut.u_core.u_core_cluster.u_backend.wb_completion[0].exception_valid,
              dut.u_core.u_core_cluster.u_backend.wb_completion[0].producer);
        end
        if (dut.u_core.u_core_cluster.u_backend.wb_valid[1]) begin
          $display(
              "TRACE_WB cycle=%0d lane=1 id=%0d pc=%08h rd=%0d prd=%0d data=%08h wr=%0b store=%0b ex=%0b prod=%0d",
              cycles,
              dut.u_core.u_core_cluster.u_backend.wb_completion[1].rob_id,
              dut.u_core.u_core_cluster.u_backend.u_commit_recovery.u_rename_rob.u_reorder_buffer.entry_q[dut.u_core.u_core_cluster.u_backend.wb_completion[1].rob_id].pc,
              dut.u_core.u_core_cluster.u_backend.u_commit_recovery.u_rename_rob.u_reorder_buffer.entry_q[dut.u_core.u_core_cluster.u_backend.wb_completion[1].rob_id].arch_rd,
              dut.u_core.u_core_cluster.u_backend.wb_completion[1].prd,
              dut.u_core.u_core_cluster.u_backend.wb_completion[1].data,
              dut.u_core.u_core_cluster.u_backend.wb_completion[1].write_prf,
              dut.u_core.u_core_cluster.u_backend.wb_completion[1].is_store,
              dut.u_core.u_core_cluster.u_backend.wb_completion[1].exception_valid,
              dut.u_core.u_core_cluster.u_backend.wb_completion[1].producer);
        end
        $display(
            "TRACE_LSU cycle=%0d miq[occ=%0d cand=%b grant=%b allow=%b c0{id=%0d pc=%08h s1=%0b s2=%0b ld=%0b st=%0b} c1{id=%0d pc=%08h s1=%0b s2=%0b ld=%0b st=%0b}] issue[v=%b p0=%0d p1=%0d p2=%0d] lsu_ex[v=%0b r=%0b id=%0d pc=%08h ld=%0b st=%0b addr=%08h data=%08h] lsu[state=%0d res=%0b/%0b sq=%0b/%0b lqaddr=%0b/%0b lqcomp=%0b/%0b] mem[ldreq=%0b/%0b addr=%08h resp=%0b/%0b data=%08h err=%0b streq=%0b/%0b addr=%08h data=%08h be=%b] q[lq=%0d sq=%0d sqcommit=%0b/%0b done=%0b busy=%0b]",
            cycles,
            dut.u_core.u_core_cluster.u_backend.mem_iq_occupancy,
            dut.u_core.u_core_cluster.u_backend.mem_candidate_valid,
            dut.u_core.u_core_cluster.u_backend.mem_issue_grant,
            dut.u_core.u_core_cluster.u_backend.mem_issue_allowed,
            dut.u_core.u_core_cluster.u_backend.mem_candidate_uop0.rob_id,
            dut.u_core.u_core_cluster.u_backend.mem_candidate_uop0.pc,
            dut.u_core.u_core_cluster.u_backend.mem_candidate_uop0.src1_ready,
            dut.u_core.u_core_cluster.u_backend.mem_candidate_uop0.src2_ready,
            dut.u_core.u_core_cluster.u_backend.mem_candidate_uop0.is_load,
            dut.u_core.u_core_cluster.u_backend.mem_candidate_uop0.is_store,
            dut.u_core.u_core_cluster.u_backend.mem_candidate_uop1.rob_id,
            dut.u_core.u_core_cluster.u_backend.mem_candidate_uop1.pc,
            dut.u_core.u_core_cluster.u_backend.mem_candidate_uop1.src1_ready,
            dut.u_core.u_core_cluster.u_backend.mem_candidate_uop1.src2_ready,
            dut.u_core.u_core_cluster.u_backend.mem_candidate_uop1.is_load,
            dut.u_core.u_core_cluster.u_backend.mem_candidate_uop1.is_store,
            dut.u_core.u_core_cluster.u_backend.issue_valid,
            dut.u_core.u_core_cluster.u_backend.issue_port0,
            dut.u_core.u_core_cluster.u_backend.issue_port1,
            dut.u_core.u_core_cluster.u_backend.issue_port2,
            dut.u_core.u_core_cluster.u_backend.lsu_ex_valid,
            dut.u_core.u_core_cluster.u_backend.lsu_ex_ready,
            dut.u_core.u_core_cluster.u_backend.lsu_ex_uop.rob_id,
            dut.u_core.u_core_cluster.u_backend.lsu_ex_uop.pc,
            dut.u_core.u_core_cluster.u_backend.lsu_ex_uop.is_load,
            dut.u_core.u_core_cluster.u_backend.lsu_ex_uop.is_store,
            dut.u_core.u_core_cluster.u_backend.u_lsu.issue_address,
            dut.u_core.u_core_cluster.u_backend.lsu_ex_uop.store_data,
            dut.u_core.u_core_cluster.u_backend.u_lsu.state_q,
            dut.u_core.u_core_cluster.u_backend.lsu_result_valid,
            dut.u_core.u_core_cluster.u_backend.lsu_result_ready,
            dut.u_core.u_core_cluster.u_backend.sq_update_valid,
            dut.u_core.u_core_cluster.u_backend.sq_update_ready,
            dut.u_core.u_core_cluster.u_backend.lq_address_valid,
            dut.u_core.u_core_cluster.u_backend.lq_address_ready,
            dut.u_core.u_core_cluster.u_backend.lq_complete_valid,
            dut.u_core.u_core_cluster.u_backend.lq_complete_ready,
            dut.u_core.u_core_cluster.u_backend.load_mem_req_o.valid,
            dut.u_core.u_core_cluster.u_backend.load_mem_req_ready_i,
            dut.u_core.u_core_cluster.u_backend.load_mem_req_o.address,
            dut.u_core.u_core_cluster.u_backend.load_mem_resp_i.valid,
            dut.u_core.u_core_cluster.u_backend.load_mem_resp_ready_o,
            dut.u_core.u_core_cluster.u_backend.load_mem_resp_i.data,
            dut.u_core.u_core_cluster.u_backend.load_mem_resp_i.error,
            dut.u_core.u_core_cluster.u_backend.store_mem_req_o.valid,
            dut.u_core.u_core_cluster.u_backend.store_mem_req_ready_i,
            dut.u_core.u_core_cluster.u_backend.store_mem_req_o.address,
            dut.u_core.u_core_cluster.u_backend.store_mem_req_o.data,
            dut.u_core.u_core_cluster.u_backend.store_mem_req_o.byte_enable,
            dut.u_core.u_core_cluster.u_backend.lq_occupancy_o,
            dut.u_core.u_core_cluster.u_backend.sq_occupancy_o,
            dut.u_core.u_core_cluster.u_backend.sq_commit_valid,
            dut.u_core.u_core_cluster.u_backend.sq_commit_ready,
            dut.u_core.u_core_cluster.u_backend.sq_commit_done,
            dut.u_core.u_core_cluster.u_backend.commit_busy);
        $display(
            "TRACE_MIQ_STATE cycle=%0d valid=%b s1=%b s2=%b need1=%b need2=%b candv=%b cslot0=%0d cslot1=%0d pairv=%b pairslot0=%0d pairslot1=%0d pairslot2=%0d pairslot3=%0d",
            cycles,
            dut.u_core.u_core_cluster.u_backend.u_mem_issue_queue.valid_q,
            dut.u_core.u_core_cluster.u_backend.u_mem_issue_queue.src1_ready_q,
            dut.u_core.u_core_cluster.u_backend.u_mem_issue_queue.src2_ready_q,
            dut.u_core.u_core_cluster.u_backend.u_mem_issue_queue.need_rs1_q,
            dut.u_core.u_core_cluster.u_backend.u_mem_issue_queue.need_rs2_q,
            dut.u_core.u_core_cluster.u_backend.u_mem_issue_queue.candidate_valid_q,
            dut.u_core.u_core_cluster.u_backend.u_mem_issue_queue.candidate_slot_q[0],
            dut.u_core.u_core_cluster.u_backend.u_mem_issue_queue.candidate_slot_q[1],
            dut.u_core.u_core_cluster.u_backend.u_mem_issue_queue.pair_valid_q,
            dut.u_core.u_core_cluster.u_backend.u_mem_issue_queue.pair_slot_q[0],
            dut.u_core.u_core_cluster.u_backend.u_mem_issue_queue.pair_slot_q[1],
            dut.u_core.u_core_cluster.u_backend.u_mem_issue_queue.pair_slot_q[2],
            dut.u_core.u_core_cluster.u_backend.u_mem_issue_queue.pair_slot_q[3]);
        for (int dbg_miq_slot = 0; dbg_miq_slot < IQ_MEM_ENTRIES; dbg_miq_slot++) begin
          if (dut.u_core.u_core_cluster.u_backend.u_mem_issue_queue.valid_q[dbg_miq_slot]) begin
            $display(
                "TRACE_MIQ_SLOT cycle=%0d slot=%0d pc=%08h id=%0d prd=%0d prs1=%0d prs2=%0d s1=%0b s2=%0b need1=%0b need2=%0b ld=%0b st=%0b memop=%0d imm=%08h",
                cycles,
                dbg_miq_slot,
                dut.u_core.u_core_cluster.u_backend.u_mem_issue_queue.payload_q[dbg_miq_slot].pc,
                dut.u_core.u_core_cluster.u_backend.u_mem_issue_queue.rob_id_q[dbg_miq_slot],
                dut.u_core.u_core_cluster.u_backend.u_mem_issue_queue.payload_q[dbg_miq_slot].prd,
                dut.u_core.u_core_cluster.u_backend.u_mem_issue_queue.prs1_q[dbg_miq_slot],
                dut.u_core.u_core_cluster.u_backend.u_mem_issue_queue.prs2_q[dbg_miq_slot],
                dut.u_core.u_core_cluster.u_backend.u_mem_issue_queue.src1_ready_q[dbg_miq_slot],
                dut.u_core.u_core_cluster.u_backend.u_mem_issue_queue.src2_ready_q[dbg_miq_slot],
                dut.u_core.u_core_cluster.u_backend.u_mem_issue_queue.need_rs1_q[dbg_miq_slot],
                dut.u_core.u_core_cluster.u_backend.u_mem_issue_queue.need_rs2_q[dbg_miq_slot],
                dut.u_core.u_core_cluster.u_backend.u_mem_issue_queue.payload_q[dbg_miq_slot].is_load,
                dut.u_core.u_core_cluster.u_backend.u_mem_issue_queue.payload_q[dbg_miq_slot].is_store,
                dut.u_core.u_core_cluster.u_backend.u_mem_issue_queue.payload_q[dbg_miq_slot].mem_op,
                dut.u_core.u_core_cluster.u_backend.u_mem_issue_queue.payload_q[dbg_miq_slot].imm);
          end
        end
      end
    end
  endtask

  task automatic tick();
    begin
      @(posedge clk_i); #1;
      cycles++;
      record_commit_history();
      record_wb_history();
      trace_cycle();
      if ($isunknown(retire_count_o))
        fail("unknown_retire_count");
      if ($isunknown(redirect_valid_o))
        fail("unknown_redirect_valid");
      if (imem_resp_error_o)
        fail("instruction_memory_error");
      if (data_store_error_o)
        fail("data_store_error");
      if (periph_req_valid_o)
        fail("unexpected_mmio");
      if (mmio_busy_o)
        fail("unexpected_mmio_busy");
      if (redirect_valid_o) begin
        if (!allow_redirect)
          fail("unexpected_redirect");
        if (expect_redirect && (redirect_pc_o !== expected_redirect_pc))
          fail("redirect_pc_mismatch");
        seen_redirect = 1'b1;
      end
      if (cycles > 2000)
        fail(wait_reason);
    end
  endtask

  task automatic start_case(input string name,
                            input bit redirects_ok = 1'b0,
                            input bit redirect_required = 1'b0,
                            input logic [XLEN-1:0] redirect_pc = '0);
    begin
      case_name = name;
      cycles = 0;
      allow_redirect = redirects_ok;
      expect_redirect = redirect_required;
      expected_redirect_pc = redirect_pc;
      seen_redirect = 1'b0;
      wait_reason = "timeout";
      wb_seen_count = 0;
      for (int idx = 0; idx < MAX_PROG_WORDS; idx++)
        commit_seen[idx] = 1'b0;
      for (int idx = 0; idx < WB_HISTORY_ENTRIES; idx++) begin
        wb_seen_valid[idx] = 1'b0;
        wb_seen_rd[idx] = '0;
        wb_seen_data[idx] = '0;
      end

      @(negedge clk_i);
      rst_i = 1'b1;
      repeat (4) @(posedge clk_i);
      load_program();
      repeat (2) @(posedge clk_i);
      @(negedge clk_i);
      rst_i = 1'b0;
      repeat (5) tick();
    end
  endtask

  task automatic finish_case();
    begin
      repeat (2) tick();
      if (expect_redirect && !seen_redirect)
        fail("missing_redirect");
      if (led_o != 8'h00)
        fail("unexpected_led_state");
      passed_cases++;
      $display("CUSTOM_TEST PASS name=%s cycles=%0d", case_name, cycles);
    end
  endtask

  task automatic expect_wb(input logic [4:0] rd,
                           input logic [XLEN-1:0] expected);
    bit seen;
    begin
      seen = 1'b0;
      wait_reason = $sformatf("timeout_wait_wb_x%0d_%08h", rd, expected);
      while (!seen) begin
        if (wb_history_matches(rd, expected))
          seen = 1'b1;
        if (seen)
          break;
        tick();
        if (dut.u_core.u_core_cluster.u_backend.wb_valid[0] &&
            completion_matches_rd(
                dut.u_core.u_core_cluster.u_backend.wb_completion[0],
                rd, expected))
          seen = 1'b1;
        if (dut.u_core.u_core_cluster.u_backend.wb_valid[1] &&
            completion_matches_rd(
                dut.u_core.u_core_cluster.u_backend.wb_completion[1],
                rd, expected))
          seen = 1'b1;
      end
    end
  endtask

  task automatic expect_commit_pc(input logic [XLEN-1:0] pc);
    int idx;
    begin
      wait_reason = $sformatf("timeout_wait_commit_pc_%08h", pc);
      idx = pc_word_index(pc);
      while (!(((idx >= 0) && (idx < MAX_PROG_WORDS) && commit_seen[idx]) ||
               raw_retire_pc(pc)))
        tick();
      tick();
    end
  endtask

  task automatic expect_committed(input logic [4:0] rd,
                                  input logic [XLEN-1:0] expected);
    logic [XLEN-1:0] actual;
    int wait_count;
    begin
      wait_count = 0;
      wait_reason = $sformatf("timeout_wait_committed_x%0d_%08h", rd, expected);
      actual = committed_reg(rd);
      while ((actual !== expected) && (wait_count < 100)) begin
        tick();
        wait_count++;
        actual = committed_reg(rd);
      end
      if ($isunknown(actual))
        fail("unknown_committed_reg");
      if (actual !== expected)
        fail("committed_reg_mismatch");
    end
  endtask

  task automatic expect_mem_word(input logic [XLEN-1:0] addr,
                                 input logic [XLEN-1:0] expected);
    logic [XLEN-1:0] actual;
    begin
      actual = dmem_word(addr);
      wait_reason = $sformatf("timeout_wait_dmem_%08h_%08h", addr, expected);
      if ($isunknown(actual))
        fail("unknown_dmem_word");
      if (actual !== expected)
        fail("dmem_word_mismatch");
    end
  endtask

  task automatic build_binary_reg(input logic [31:0] inst,
                                  input logic [31:0] expected);
    begin
      clear_program();
      add_inst(addi(5'd1, 5'd0, 32'd9));
      add_inst(addi(5'd2, 5'd0, 32'd4));
      add_inst(inst);
      start_case(case_name);
      expect_wb(5'd3, expected);
      expect_commit_pc(IMAGE_BASE + 32'd8);
      expect_committed(5'd3, expected);
      finish_case();
    end
  endtask

  task automatic run_addi_chain();
    begin
      clear_program();
      add_inst(addi(5'd1, 5'd0, 32'd1));
      add_inst(addi(5'd2, 5'd1, 32'd2));
      start_case("phase1_addi_chain");
      expect_wb(5'd1, 32'd1);
      expect_wb(5'd2, 32'd3);
      expect_commit_pc(IMAGE_BASE + 32'd4);
      expect_committed(5'd1, 32'd1);
      expect_committed(5'd2, 32'd3);
      finish_case();
    end
  endtask

  task automatic run_lui_auipc();
    begin
      clear_program();
      add_inst(lui(5'd3, 20'h12345));
      add_inst(auipc(5'd4, 20'h00001));
      start_case("phase1_lui_auipc");
      expect_wb(5'd3, 32'h1234_5000);
      expect_wb(5'd4, 32'h8000_1004);
      expect_commit_pc(IMAGE_BASE + 32'd4);
      expect_committed(5'd3, 32'h1234_5000);
      expect_committed(5'd4, 32'h8000_1004);
      finish_case();
    end
  endtask

  task automatic run_simple_alu(input string name,
                                input logic [31:0] inst,
                                input logic [31:0] expected);
    begin
      case_name = name;
      build_binary_reg(inst, expected);
    end
  endtask

  task automatic run_shifti(input string name,
                            input logic [31:0] inst,
                            input logic [31:0] expected);
    begin
      case_name = name;
      clear_program();
      add_inst(addi(5'd1, 5'd0, 32'hffff_fff0));
      add_inst(inst);
      start_case(case_name);
      expect_wb(5'd3, expected);
      expect_commit_pc(IMAGE_BASE + 32'd4);
      expect_committed(5'd3, expected);
      finish_case();
    end
  endtask

  task automatic run_branch(input string name,
                            input logic [31:0] branch_inst,
                            input logic [31:0] expected_x3,
                            input bit taken,
                            input logic [31:0] x1_value = 32'd5,
                            input logic [31:0] x2_value = 32'd5);
    begin
      clear_program();
      add_inst(addi(5'd1, 5'd0, x1_value));
      add_inst(addi(5'd2, 5'd0, x2_value));
      add_inst(branch_inst);
      add_inst(addi(5'd3, 5'd0, 32'd1));
      add_inst(taken ? addi(5'd3, 5'd0, 32'd2) : NOP);
      start_case(name, taken, taken, IMAGE_BASE + 32'd16);
      expect_wb(5'd3, expected_x3);
      expect_commit_pc(IMAGE_BASE + (taken ? 32'd16 : 32'd12));
      expect_committed(5'd3, expected_x3);
      finish_case();
    end
  endtask

  task automatic run_jal();
    begin
      clear_program();
      add_inst(jal(5'd1, 32'd8));
      add_inst(addi(5'd2, 5'd0, 32'd1));
      add_inst(addi(5'd3, 5'd0, 32'd3));
      start_case("phase3_jal", 1'b1, 1'b1, IMAGE_BASE + 32'd8);
      expect_wb(5'd1, IMAGE_BASE + 32'd4);
      expect_wb(5'd3, 32'd3);
      expect_commit_pc(IMAGE_BASE + 32'd8);
      expect_committed(5'd1, IMAGE_BASE + 32'd4);
      expect_committed(5'd3, 32'd3);
      finish_case();
    end
  endtask

  task automatic run_jalr();
    begin
      clear_program();
      add_inst(lui(5'd5, 20'h80000));
      add_inst(addi(5'd5, 5'd5, 32'd17));
      add_inst(jalr(5'd1, 5'd5, 32'hfff));
      add_inst(addi(5'd2, 5'd0, 32'd1));
      add_inst(addi(5'd3, 5'd0, 32'd3));
      start_case("phase3_jalr_lowbit_clear", 1'b1, 1'b1, IMAGE_BASE + 32'd16);
      expect_wb(5'd1, IMAGE_BASE + 32'd12);
      expect_wb(5'd3, 32'd3);
      expect_commit_pc(IMAGE_BASE + 32'd16);
      expect_committed(5'd1, IMAGE_BASE + 32'd12);
      expect_committed(5'd3, 32'd3);
      finish_case();
    end
  endtask

  task automatic run_sw_lw();
    begin
      clear_program();
      add_inst(lui(5'd1, 20'h80000));
      add_inst(addi(5'd2, 5'd0, 32'h07b));
      add_inst(store_s(5'd2, 5'd1, 3'b010, 32'd32));
      add_inst(load_i(5'd3, 5'd1, 3'b010, 32'd32));
      write_dmem_word(IMAGE_BASE + 32'd32, 32'h0000_0000);
      start_case("phase4_sw_lw");
      expect_wb(5'd3, 32'h0000_007b);
      expect_commit_pc(IMAGE_BASE + 32'd12);
      expect_mem_word(IMAGE_BASE + 32'd32, 32'h0000_007b);
      expect_committed(5'd3, 32'h0000_007b);
      finish_case();
    end
  endtask

  task automatic run_byte_half_load_store();
    begin
      clear_program();
      add_inst(lui(5'd1, 20'h80000));
      add_inst(addi(5'd2, 5'd0, 32'h0aa));
      add_inst(store_s(5'd2, 5'd1, 3'b000, 32'd33));
      add_inst(addi(5'd2, 5'd0, 32'h7ff));
      add_inst(store_s(5'd2, 5'd1, 3'b001, 32'd34));
      add_inst(load_i(5'd3, 5'd1, 3'b000, 32'd33));
      add_inst(load_i(5'd4, 5'd1, 3'b100, 32'd33));
      add_inst(load_i(5'd5, 5'd1, 3'b001, 32'd34));
      add_inst(load_i(5'd6, 5'd1, 3'b101, 32'd34));
      write_dmem_word(IMAGE_BASE + 32'd32, 32'h1122_3344);
      start_case("phase4_byte_half_merge_loads");
      expect_wb(5'd3, 32'hffff_ffaa);
      expect_wb(5'd4, 32'h0000_00aa);
      expect_wb(5'd5, 32'h0000_07ff);
      expect_wb(5'd6, 32'h0000_07ff);
      expect_commit_pc(IMAGE_BASE + 32'd32);
      expect_mem_word(IMAGE_BASE + 32'd32, 32'h07ff_aa44);
      expect_committed(5'd3, 32'hffff_ffaa);
      expect_committed(5'd4, 32'h0000_00aa);
      expect_committed(5'd5, 32'h0000_07ff);
      expect_committed(5'd6, 32'h0000_07ff);
      finish_case();
    end
  endtask

  task automatic run_load_use();
    begin
      clear_program();
      add_inst(lui(5'd1, 20'h80000));
      add_inst(load_i(5'd2, 5'd1, 3'b010, 32'd48));
      add_inst(addi(5'd3, 5'd2, 32'd1));
      write_dmem_word(IMAGE_BASE + 32'd48, 32'h0000_0041);
      start_case("phase4_load_use");
      expect_wb(5'd2, 32'h0000_0041);
      expect_wb(5'd3, 32'h0000_0042);
      expect_commit_pc(IMAGE_BASE + 32'd8);
      expect_committed(5'd3, 32'h0000_0042);
      finish_case();
    end
  endtask

  task automatic run_m_case(input string name,
                            input logic [31:0] setup0,
                            input logic [31:0] setup1,
                            input logic [31:0] inst,
                            input logic [31:0] expected);
    begin
      clear_program();
      add_inst(setup0);
      add_inst(setup1);
      add_inst(inst);
      start_case(name);
      expect_wb(5'd3, expected);
      expect_commit_pc(IMAGE_BASE + 32'd8);
      expect_committed(5'd3, expected);
      finish_case();
    end
  endtask

  task automatic run_csrrw_mtvec();
    begin
      clear_program();
      add_inst(lui(5'd1, 20'h80001));
      add_inst(enc_csr(12'h305, 5'd1, 3'b001, 5'd2));
      start_case("phase6_csrrw_mtvec");
      expect_commit_pc(IMAGE_BASE + 32'd4);
      expect_committed(5'd2, IMAGE_BASE);
      if (mtvec_o !== 32'h8000_1000)
        fail("mtvec_mismatch");
      finish_case();
    end
  endtask

  task automatic run_csrrwi_mepc();
    begin
      clear_program();
      add_inst(enc_csr(12'h341, 5'd3, 3'b101, 5'd5));
      start_case("phase6_csrrwi_mepc");
      expect_commit_pc(IMAGE_BASE);
      expect_committed(5'd5, 32'h0000_0000);
      if (mepc_o !== 32'h0000_0002)
        fail("mepc_mismatch");
      finish_case();
    end
  endtask

  task automatic run_fence_commit();
    begin
      clear_program();
      add_inst(32'h0000_000f);
      add_inst(32'h0000_100f);
      start_case("phase6_fence_commit");
      expect_commit_pc(IMAGE_BASE + 32'd4);
      finish_case();
    end
  endtask

  task automatic maybe_run(input string name);
    begin
      if (has_case_select && (selected_case != name)) begin
        // Intentionally empty; cases with arguments are selected at call sites.
      end
    end
  endtask

  initial begin
    passed_cases = 0;
    has_case_select = $value$plusargs("CASE=%s", selected_case);
    trace_enabled = $test$plusargs("TRACE");

    if (!has_case_select || selected_case == "phase1_addi_chain")
      run_addi_chain();
    if (!has_case_select || selected_case == "phase1_lui_auipc")
      run_lui_auipc();

    if (!has_case_select || selected_case == "phase2_add")
      run_simple_alu("phase2_add", alu_r(5'd3, 5'd1, 5'd2, 3'b000, 7'b0000000), 32'd13);
    if (!has_case_select || selected_case == "phase2_sub")
      run_simple_alu("phase2_sub", alu_r(5'd3, 5'd1, 5'd2, 3'b000, 7'b0100000), 32'd5);
    if (!has_case_select || selected_case == "phase2_and")
      run_simple_alu("phase2_and", alu_r(5'd3, 5'd1, 5'd2, 3'b111, 7'b0000000), 32'd0);
    if (!has_case_select || selected_case == "phase2_or")
      run_simple_alu("phase2_or", alu_r(5'd3, 5'd1, 5'd2, 3'b110, 7'b0000000), 32'd13);
    if (!has_case_select || selected_case == "phase2_xor")
      run_simple_alu("phase2_xor", alu_r(5'd3, 5'd1, 5'd2, 3'b100, 7'b0000000), 32'd13);
    if (!has_case_select || selected_case == "phase2_slt")
      run_simple_alu("phase2_slt", alu_r(5'd3, 5'd2, 5'd1, 3'b010, 7'b0000000), 32'd1);
    if (!has_case_select || selected_case == "phase2_sltu")
      run_simple_alu("phase2_sltu", alu_r(5'd3, 5'd2, 5'd1, 3'b011, 7'b0000000), 32'd1);
    if (!has_case_select || selected_case == "phase2_sll")
      run_simple_alu("phase2_sll", alu_r(5'd3, 5'd1, 5'd2, 3'b001, 7'b0000000), 32'd144);
    if (!has_case_select || selected_case == "phase2_srl")
      run_simple_alu("phase2_srl", alu_r(5'd3, 5'd1, 5'd2, 3'b101, 7'b0000000), 32'd0);
    if (!has_case_select || selected_case == "phase2_sra")
      run_simple_alu("phase2_sra", alu_r(5'd3, 5'd1, 5'd2, 3'b101, 7'b0100000), 32'd0);
    if (!has_case_select || selected_case == "phase2_slli")
      run_shifti("phase2_slli", alu_i(5'd3, 5'd1, 3'b001, 32'd2), 32'hffff_ffc0);
    if (!has_case_select || selected_case == "phase2_srli")
      run_shifti("phase2_srli", alu_i(5'd3, 5'd1, 3'b101, 32'd2), 32'h3fff_fffc);
    if (!has_case_select || selected_case == "phase2_srai")
      run_shifti("phase2_srai", alu_i(5'd3, 5'd1, 3'b101, 32'h402), 32'hffff_fffc);

    if (!has_case_select || selected_case == "phase3_beq_taken")
      run_branch("phase3_beq_taken", branch_b(5'd1, 5'd2, 3'b000, 32'd8), 32'd2, 1'b1);
    if (!has_case_select || selected_case == "phase3_bne_not_taken")
      run_branch("phase3_bne_not_taken", branch_b(5'd1, 5'd2, 3'b001, 32'd8), 32'd1, 1'b0);
    if (!has_case_select || selected_case == "phase3_blt_taken")
      run_branch("phase3_blt_taken", branch_b(5'd2, 5'd1, 3'b100, 32'd8), 32'd2, 1'b1,
                 32'd5, 32'd4);
    if (!has_case_select || selected_case == "phase3_bge_not_taken")
      run_branch("phase3_bge_not_taken", branch_b(5'd2, 5'd1, 3'b101, 32'd8), 32'd1, 1'b0,
                 32'd5, 32'd4);
    if (!has_case_select || selected_case == "phase3_bltu_taken")
      run_branch("phase3_bltu_taken", branch_b(5'd2, 5'd1, 3'b110, 32'd8), 32'd2, 1'b1,
                 32'd5, 32'd4);
    if (!has_case_select || selected_case == "phase3_bgeu_not_taken")
      run_branch("phase3_bgeu_not_taken", branch_b(5'd2, 5'd1, 3'b111, 32'd8), 32'd1, 1'b0,
                 32'd5, 32'd4);
    if (!has_case_select || selected_case == "phase3_jal")
      run_jal();
    if (!has_case_select || selected_case == "phase3_jalr_lowbit_clear")
      run_jalr();

    if (!has_case_select || selected_case == "phase4_sw_lw")
      run_sw_lw();
    if (!has_case_select || selected_case == "phase4_byte_half_merge_loads")
      run_byte_half_load_store();
    if (!has_case_select || selected_case == "phase4_load_use")
      run_load_use();

    if (!has_case_select || selected_case == "phase5_mul")
      run_m_case("phase5_mul", addi(5'd1, 5'd0, 32'hffd), addi(5'd2, 5'd0, 32'd7),
                 m_op(5'd3, 5'd1, 5'd2, 3'b000), 32'hffff_ffeb);
    if (!has_case_select || selected_case == "phase5_mulh")
      run_m_case("phase5_mulh", addi(5'd1, 5'd0, 32'hffd), addi(5'd2, 5'd0, 32'd7),
                 m_op(5'd3, 5'd1, 5'd2, 3'b001), 32'hffff_ffff);
    if (!has_case_select || selected_case == "phase5_mulhsu")
      run_m_case("phase5_mulhsu", addi(5'd1, 5'd0, 32'hffd), addi(5'd2, 5'd0, 32'd7),
                 m_op(5'd3, 5'd1, 5'd2, 3'b010), 32'hffff_ffff);
    if (!has_case_select || selected_case == "phase5_mulhu")
      run_m_case("phase5_mulhu", addi(5'd1, 5'd0, 32'hfff), addi(5'd2, 5'd0, 32'd2),
                 m_op(5'd3, 5'd1, 5'd2, 3'b011), 32'h0000_0001);
    if (!has_case_select || selected_case == "phase5_div")
      run_m_case("phase5_div", addi(5'd1, 5'd0, 32'hfeb), addi(5'd2, 5'd0, 32'd5),
                 m_op(5'd3, 5'd1, 5'd2, 3'b100), 32'hffff_fffc);
    if (!has_case_select || selected_case == "phase5_divu")
      run_m_case("phase5_divu", addi(5'd1, 5'd0, 32'hfff), addi(5'd2, 5'd0, 32'd2),
                 m_op(5'd3, 5'd1, 5'd2, 3'b101), 32'h7fff_ffff);
    if (!has_case_select || selected_case == "phase5_rem")
      run_m_case("phase5_rem", addi(5'd1, 5'd0, 32'hfeb), addi(5'd2, 5'd0, 32'd5),
                 m_op(5'd3, 5'd1, 5'd2, 3'b110), 32'hffff_ffff);
    if (!has_case_select || selected_case == "phase5_remu")
      run_m_case("phase5_remu", addi(5'd1, 5'd0, 32'hfff), addi(5'd2, 5'd0, 32'd2),
                 m_op(5'd3, 5'd1, 5'd2, 3'b111), 32'h0000_0001);
    if (!has_case_select || selected_case == "phase5_div_by_zero")
      run_m_case("phase5_div_by_zero", addi(5'd1, 5'd0, 32'd123), addi(5'd2, 5'd0, 32'd0),
                 m_op(5'd3, 5'd1, 5'd2, 3'b100), 32'hffff_ffff);
    if (!has_case_select || selected_case == "phase5_div_overflow")
      run_m_case("phase5_div_overflow", lui(5'd1, 20'h80000), addi(5'd2, 5'd0, 32'hfff),
                 m_op(5'd3, 5'd1, 5'd2, 3'b100), 32'h8000_0000);

    if (!has_case_select || selected_case == "phase6_csrrw_mtvec")
      run_csrrw_mtvec();
    if (!has_case_select || selected_case == "phase6_csrrwi_mepc")
      run_csrrwi_mepc();
    if (!has_case_select || selected_case == "phase6_fence_commit")
      run_fence_commit();

    if (has_case_select && (passed_cases == 0))
      $fatal(1, "unknown +CASE=%s", selected_case);

    $display("CUSTOM_TEST SUMMARY pass_count=%0d", passed_cases);
    $finish;
  end

  initial begin
    #50000000;
    $fatal(1, "global timeout");
  end
endmodule
