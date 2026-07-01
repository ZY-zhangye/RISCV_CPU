`timescale 1ns/1ps
`include "defines.svh"

module tb_core_combo_dual_issue;
    import core_port_pkg::*;

    logic clk, rst_n;
    logic [31:0] imem_addr;
    logic imem_ren;
    logic [63:0] imem_rdata;
    logic dmem_request_valid, dmem_request_ready;
    lsq_mem_request_t dmem_request;
    lsq_mem_response_t dmem_response;
    rob_commit_bundle_t commit_bus;
    logic [1:0] commit_fire;
    logic signed [32:0] mul_operand_a, mul_operand_b;
    logic signed [65:0] mul_product;

    logic saw_pair0_dual_allocate;
    logic saw_raw_pair_dual_allocate;
    logic saw_pair0_dual_issue;
    logic saw_dual_writeback;
    logic saw_pair0_dual_commit;
    logic saw_inflight_waw;
    logic old_x1_committed;
    phys_reg_idx_t old_x1_pdst;
    phys_reg_idx_t young_x1_pdst;

    core_top #(.RESET_PC(32'h0)) dut (
        .clk(clk), .rst_n(rst_n),
        .imem_addr_o(imem_addr), .imem_ren_o(imem_ren),
        .imem_rdata_i(imem_rdata),
        .dmem_request_valid_o(dmem_request_valid),
        .dmem_request_o(dmem_request),
        .dmem_request_ready_i(dmem_request_ready),
        .dmem_response_i(dmem_response),
        .irq_software_i(1'b0), .irq_timer_i(1'b0), .irq_external_i(1'b0),
        .mul_request_valid_o(), .mul_operand_a_o(mul_operand_a),
        .mul_operand_b_o(mul_operand_b), .mul_product_i(mul_product),
        .div_dividend_valid_o(), .div_dividend_ready_i(1'b1),
        .div_dividend_data_o(), .div_divisor_valid_o(),
        .div_divisor_ready_i(1'b1), .div_divisor_data_o(),
        .div_result_valid_i(1'b0), .div_result_ready_o(),
        .div_quotient_i('0), .div_remainder_i('0),
        .recover_o(), .branch_update_o(), .fence_i_commit_o(),
        .commit_bus_o(commit_bus), .commit_fire_o(commit_fire),
        .core_idle_o()
    );

    unified_memory_model #(.WORD_COUNT(1024)) u_memory (
        .clk(clk), .rst_n(rst_n),
        .imem_addr(imem_addr), .imem_ren(imem_ren), .imem_rdata(imem_rdata),
        .dmem_request_valid(dmem_request_valid), .dmem_request(dmem_request),
        .dmem_request_ready(dmem_request_ready), .dmem_response(dmem_response),
        .dmem_stage_valid_o()
    );

    always #5 clk = ~clk;
    assign mul_product = mul_operand_a * mul_operand_b;

    function automatic logic [31:0] committed_reg(input logic [4:0] arch_reg);
        logic [PHYS_REG_IDX_WIDTH-1:0] preg;
        begin
            preg = dut.u_backend.u_rename.u_rat_rrat.rrat[arch_reg];
            committed_reg = (preg == '0) ? '0
                          : dut.u_backend.u_prf.registers[preg];
        end
    endfunction

    task automatic tick;
        @(posedge clk); #1;
    endtask

    task automatic wait_commit(
        input logic [31:0] pc, input string name
    );
        integer cycles;
        logic seen;
        begin
            cycles = 0;
            seen = 1'b0;
            while (!seen && (cycles < 240)) begin
                @(negedge clk);
                seen = (commit_fire[0] && (commit_bus.lane0.pc == pc))
                    || (commit_fire[1] && (commit_bus.lane1.pc == pc));
                cycles = cycles + 1;
            end
            if (seen) tick();
            assert (seen) else $fatal(1, "%s commit timeout", name);
        end
    endtask

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            saw_pair0_dual_allocate   <= 1'b0;
            saw_raw_pair_dual_allocate <= 1'b0;
            saw_pair0_dual_issue      <= 1'b0;
            saw_dual_writeback        <= 1'b0;
            saw_pair0_dual_commit     <= 1'b0;
            saw_inflight_waw          <= 1'b0;
            old_x1_committed          <= 1'b0;
            old_x1_pdst               <= '0;
            young_x1_pdst             <= '0;
        end else begin
            if (&dut.u_backend.rob_alloc_valid) begin
                if ((dut.u_backend.rob_alloc_bus.lane0.pc == 32'h0)
                    && (dut.u_backend.rob_alloc_bus.lane1.pc == 32'h4))
                    saw_pair0_dual_allocate <= 1'b1;
                if ((dut.u_backend.rob_alloc_bus.lane0.pc == 32'h8)
                    && (dut.u_backend.rob_alloc_bus.lane1.pc == 32'hc)) begin
                    saw_raw_pair_dual_allocate <= 1'b1;
                    old_x1_pdst <= dut.u_backend.rob_alloc_bus.lane0.pdst;
                end
            end

            if (dut.u_backend.rob_alloc_valid[0]
                && (dut.u_backend.rob_alloc_bus.lane0.pc == 32'h10)) begin
                young_x1_pdst <= dut.u_backend.rob_alloc_bus.lane0.pdst;
                saw_inflight_waw <= !old_x1_committed;
            end
            if (dut.u_backend.rob_alloc_valid[1]
                && (dut.u_backend.rob_alloc_bus.lane1.pc == 32'h10)) begin
                young_x1_pdst <= dut.u_backend.rob_alloc_bus.lane1.pdst;
                saw_inflight_waw <= !old_x1_committed;
            end

            if (dut.u_backend.issue0_fire && dut.u_backend.issue1_fire
                && (((dut.u_backend.issue0_bus.uop.dec.pc == 32'h0)
                     && (dut.u_backend.issue1_bus.uop.dec.pc == 32'h4))
                    || ((dut.u_backend.issue0_bus.uop.dec.pc == 32'h4)
                        && (dut.u_backend.issue1_bus.uop.dec.pc == 32'h0))))
                saw_pair0_dual_issue <= 1'b1;

            if (dut.u_backend.wakeup_bus.lane0.valid
                && dut.u_backend.wakeup_bus.lane1.valid)
                saw_dual_writeback <= 1'b1;

            if (commit_fire[0] && (commit_bus.lane0.pc == 32'h8))
                old_x1_committed <= 1'b1;
            if (commit_fire[1] && (commit_bus.lane1.pc == 32'h8))
                old_x1_committed <= 1'b1;

            if (&commit_fire
                && (commit_bus.lane0.pc == 32'h0)
                && (commit_bus.lane1.pc == 32'h4))
                saw_pair0_dual_commit <= 1'b1;
        end
    end

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        u_memory.clear_words(`NOP_INST);

        // 第一束两条独立 ALU 应分流到 IQ0/IQ1，并行发射、双写回、双提交。
        u_memory.write_word(32'h00, 32'h00a0_0213); // addi x4,x0,10
        u_memory.write_word(32'h04, 32'h0140_0293); // addi x5,x0,20

        // 第二束 lane1 依赖 lane0，验证同束 RAW 与跨 IQ 广播唤醒。
        u_memory.write_word(32'h08, 32'h0050_0093); // addi x1,x0,5
        u_memory.write_word(32'h0c, 32'h0030_8113); // addi x2,x1,3

        // x1 在旧映射尚未提交时再次重命名，随后同束 lane1 读取新 x1。
        u_memory.write_word(32'h10, 32'h0041_0093); // addi x1,x2,4
        u_memory.write_word(32'h14, 32'h0010_8193); // addi x3,x1,1

        repeat (3) tick();
        rst_n = 1'b1;
        tick();
        wait_commit(32'h14, "final RAW consumer");

        assert (saw_pair0_dual_allocate)
            else $fatal(1, "front-end pair was not allocated atomically");
        assert (saw_raw_pair_dual_allocate)
            else $fatal(1, "same-bundle RAW pair was not dual-dispatched");
        assert (saw_pair0_dual_issue)
            else $fatal(1, "independent ALUs did not issue in parallel");
        assert (saw_dual_writeback)
            else $fatal(1, "two writeback ports were not active together");
        assert (saw_pair0_dual_commit)
            else $fatal(1, "ROB did not dual-commit the independent pair");
        assert (saw_inflight_waw && (old_x1_pdst != young_x1_pdst))
            else $fatal(1, "in-flight WAW did not allocate a distinct pdst");

        assert ((committed_reg(5'd1) == 32'd12)
                && (committed_reg(5'd2) == 32'd8)
                && (committed_reg(5'd3) == 32'd13)
                && (committed_reg(5'd4) == 32'd10)
                && (committed_reg(5'd5) == 32'd20))
            else $fatal(1,
                "architectural result mismatch x1=%0d x2=%0d x3=%0d x4=%0d x5=%0d",
                committed_reg(5'd1), committed_reg(5'd2), committed_reg(5'd3),
                committed_reg(5'd4), committed_reg(5'd5));
        assert (dut.u_backend.u_rename.u_rat_rrat.rrat[1] == young_x1_pdst)
            else $fatal(1, "RRAT did not retain the youngest WAW mapping");

        $display("PASS: core dual issue + same-bundle RAW + in-flight WAW + dual commit");
        $finish;
    end

endmodule
