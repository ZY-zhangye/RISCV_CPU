import core_types_pkg::*;

module tb_backend_lsu_cluster;
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
  logic [3:0] lq_occupancy_o;
  logic [3:0] sq_occupancy_o;
  logic [PHYS_REGS-1:0] prf_ready_bits_o;
  logic [XLEN-1:0] mstatus_o;
  logic [XLEN-1:0] mtvec_o;
  logic [XLEN-1:0] mepc_o;
  logic [XLEN-1:0] mcause_o;
  logic [XLEN-1:0] mtval_o;

  backend_lsu_cluster dut (.*);

  always #5 clk_i = ~clk_i;

  function automatic decoded_uop_t make_load(
      input logic [31:0] pc,
      input logic [4:0] rd,
      input mem_op_t mem_op,
      input logic [31:0] address
  );
    decoded_uop_t uop;
    begin
      uop = '0;
      uop.pc = pc;
      uop.inst = 32'h0000_0003;
      uop.rd = rd;
      uop.write_rd = (rd != 0);
      uop.imm = address;
      uop.fu_type = FU_LSU;
      uop.mem_op = mem_op;
      uop.need_rs1 = 1'b0;
      uop.need_rs2 = 1'b0;
      make_load = uop;
    end
  endfunction

  function automatic decoded_uop_t make_store(
      input logic [31:0] pc,
      input mem_op_t mem_op,
      input logic [31:0] address
  );
    decoded_uop_t uop;
    begin
      uop = '0;
      uop.pc = pc;
      uop.inst = 32'h0000_0023;
      uop.imm = address;
      uop.fu_type = FU_LSU;
      uop.mem_op = mem_op;
      uop.need_rs1 = 1'b0;
      uop.need_rs2 = 1'b0;
      make_store = uop;
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

  task automatic wait_load_request(
      input logic [LQ_ID_W-1:0] lq_id,
      input logic [XLEN-1:0] address
  );
    integer cycles;
    begin
      cycles = 0;
      while (!load_mem_req_o.valid) begin
        @(posedge clk_i); #1;
        cycles = cycles + 1;
        if (cycles > 180)
          $fatal(1, "timeout waiting for backend load request");
      end
      if (load_mem_req_o.lq_id != lq_id || load_mem_req_o.address != address)
        $fatal(1, "backend load request mismatch got id=%0d addr=%h",
               load_mem_req_o.lq_id, load_mem_req_o.address);
    end
  endtask

  task automatic accept_load_response(
      input logic [LQ_ID_W-1:0] lq_id,
      input logic [XLEN-1:0] data
  );
    begin
      @(negedge clk_i);
      load_mem_req_ready_i = 1'b1;
      @(posedge clk_i); #1;
      load_mem_req_ready_i = 1'b0;
      @(negedge clk_i);
      load_mem_resp_i.valid = 1'b1;
      load_mem_resp_i.lq_id = lq_id;
      load_mem_resp_i.data = data;
      #1;
      if (!load_mem_resp_ready_o)
        $fatal(1, "backend did not accept load response");
      @(posedge clk_i); #1;
      load_mem_resp_i = '0;
    end
  endtask

  task automatic wait_store_request(
      input logic [SQ_ID_W-1:0] sq_id,
      input logic [XLEN-1:0] address,
      input logic [XLEN-1:0] data,
      input logic [3:0] byte_enable
  );
    integer cycles;
    begin
      cycles = 0;
      while (!store_mem_req_o.valid) begin
        @(posedge clk_i); #1;
        cycles = cycles + 1;
        if (cycles > 220)
          $fatal(1, "timeout waiting for backend store request");
      end
      if (store_mem_req_o.sq_id != sq_id ||
          store_mem_req_o.address != address ||
          store_mem_req_o.data != data ||
          store_mem_req_o.byte_enable != byte_enable)
        $fatal(1, "backend store request mismatch");
    end
  endtask

  task automatic accept_store_request;
    begin
      @(negedge clk_i);
      store_mem_req_ready_i = 1'b1;
      @(posedge clk_i); #1;
      store_mem_req_ready_i = 1'b0;
    end
  endtask

  task automatic wait_backend_idle;
    integer cycles;
    begin
      cycles = 0;
      while (!rob_empty_o || busy_o || (dispatch_buffer_occupancy_o != 0) ||
             (int_issue_occupancy_o != 0) ||
             (mem_issue_occupancy_o != 0) ||
             (lq_occupancy_o != 0) || (sq_occupancy_o != 0) ||
             load_mem_req_o.valid || store_mem_req_o.valid) begin
        @(posedge clk_i); #1;
        cycles = cycles + 1;
        if (cycles > 320) begin
          $display("idle timeout: rob_empty=%0b busy=%0b rob_occ=%0d db=%0d intiq=%0d memiq=%0d lq=%0d sq=%0d retire=%0d",
                   rob_empty_o, busy_o, rob_occupancy_o,
                   dispatch_buffer_occupancy_o, int_issue_occupancy_o,
                   mem_issue_occupancy_o, lq_occupancy_o, sq_occupancy_o,
                   retire_count_o);
          $display("  load_req=%0b store_req=%0b free_lq=%0d free_sq=%0d lsu_valid=%0b lsu_ready=%0b lsu_result=%0b",
                   load_mem_req_o.valid, store_mem_req_o.valid,
                   free_lq_count_o, free_sq_count_o,
                   dut.lsu_ex_valid, dut.lsu_ex_ready,
                   dut.lsu_result_valid);
          $fatal(1, "backend_lsu_cluster did not become idle");
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
      $fatal(1, "backend_lsu reset state mismatch");

    send_decode(2'b01,
                make_load(32'h8000_1000, 5'd5, MEM_LW, 32'h0000_0100),
                '0);
    wait_load_request(3'd0, 32'h0000_0100);
    accept_load_response(3'd0, 32'h1234_5678);
    wait_backend_idle();
    if (!prf_ready_bits_o[32] || free_prd_count_o != 32 ||
        free_lq_count_o != 8 || lq_occupancy_o != 0)
      $fatal(1, "backend load writeback/retire/release mismatch");

    send_decode(2'b01,
                make_store(32'h8000_1100, MEM_SW, 32'h0000_0200),
                '0);
    wait_store_request(3'd0, 32'h0000_0200, 32'h0000_0000, 4'b1111);
    if (free_sq_count_o != 7 || sq_occupancy_o == 0)
      $fatal(1, "backend store did not allocate SQ before commit");
    repeat (2) begin
      @(posedge clk_i); #1;
      if (!store_mem_req_o.valid)
        $fatal(1, "store request did not hold under memory backpressure");
    end
    accept_store_request();
    wait_backend_idle();
    if (free_sq_count_o != 8 || sq_occupancy_o != 0)
      $fatal(1, "backend store commit/release mismatch");

    $display("PASS: backend_lsu_cluster directed tests");
    $finish;
  end

  initial begin
    #1000000;
    $fatal(1, "timeout");
  end
endmodule
