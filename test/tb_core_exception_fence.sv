`timescale 1ns/1ps
`include "defines.svh"

module tb_core_exception_fence;
    import core_port_pkg::*;

    localparam logic [31:0] TRAP_VECTOR = 32'h0000_0100;

    logic clk, rst_n;
    logic [31:0] imem_addr;
    logic imem_ren;
    logic [63:0] imem_rdata;
    logic core_dmem_valid, core_dmem_ready;
    logic memory_dmem_valid, memory_dmem_ready;
    logic dmem_gate;
    lsq_mem_request_t dmem_request;
    lsq_mem_response_t dmem_response;
    recover_event_t recover;
    rob_commit_bundle_t commit_bus;
    logic [1:0] commit_fire;
    logic fence_i_commit;
    logic signed [32:0] mul_operand_a, mul_operand_b;
    logic signed [65:0] mul_product;

    integer dmem_request_count;
    integer fence_commit_count;
    integer fence_i_pulse_count;
    integer exception_recover_count;
    integer fence_i_recover_count;
    integer post_fence_commit_count;
    logic [31:0] last_exception_target;
    logic [31:0] last_fence_i_target;

    core_top #(
        .RESET_PC(32'h0),
        .MTVEC_RESET(TRAP_VECTOR)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .imem_addr_o(imem_addr), .imem_ren_o(imem_ren),
        .imem_rdata_i(imem_rdata),
        .dmem_request_valid_o(core_dmem_valid),
        .dmem_request_o(dmem_request),
        .dmem_request_ready_i(core_dmem_ready),
        .dmem_response_i(dmem_response),
        .irq_software_i(1'b0), .irq_timer_i(1'b0), .irq_external_i(1'b0),
        .mul_request_valid_o(), .mul_operand_a_o(mul_operand_a),
        .mul_operand_b_o(mul_operand_b), .mul_product_i(mul_product),
        .div_dividend_valid_o(), .div_dividend_ready_i(1'b1),
        .div_dividend_data_o(), .div_divisor_valid_o(),
        .div_divisor_ready_i(1'b1), .div_divisor_data_o(),
        .div_result_valid_i(1'b0), .div_result_ready_o(),
        .div_quotient_i('0), .div_remainder_i('0),
        .recover_o(recover), .branch_update_o(),
        .fence_i_commit_o(fence_i_commit),
        .commit_bus_o(commit_bus), .commit_fire_o(commit_fire),
        .core_idle_o()
    );

    // dmem_gate 只用于 FENCE 定向场景：同时门控 valid 和 ready，模拟
    // Core 外部存储器暂不接收请求，不破坏 ready/valid 原子握手。
    assign memory_dmem_valid = core_dmem_valid && dmem_gate;
    assign core_dmem_ready   = memory_dmem_ready && dmem_gate;

    unified_memory_model #(.WORD_COUNT(1024)) u_memory (
        .clk(clk), .rst_n(rst_n),
        .imem_addr(imem_addr), .imem_ren(imem_ren), .imem_rdata(imem_rdata),
        .dmem_request_valid(memory_dmem_valid), .dmem_request(dmem_request),
        .dmem_request_ready(memory_dmem_ready), .dmem_response(dmem_response),
        .dmem_stage_valid_o()
    );

    always #5 clk = ~clk;
    assign mul_product = mul_operand_a * mul_operand_b;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            dmem_request_count      <= 0;
            fence_commit_count      <= 0;
            fence_i_pulse_count     <= 0;
            exception_recover_count <= 0;
            fence_i_recover_count   <= 0;
            post_fence_commit_count <= 0;
            last_exception_target   <= '0;
            last_fence_i_target     <= '0;
        end else begin
            if (core_dmem_valid && core_dmem_ready)
                dmem_request_count <= dmem_request_count + 1;
            if ((commit_fire[0] && commit_bus.lane0.is_fence)
                || (commit_fire[1] && commit_bus.lane1.is_fence))
                fence_commit_count <= fence_commit_count + 1;
            if ((commit_fire[0] && (commit_bus.lane0.pc == 32'h10))
                || (commit_fire[1] && (commit_bus.lane1.pc == 32'h10)))
                post_fence_commit_count <= post_fence_commit_count + 1;
            if (fence_i_commit)
                fence_i_pulse_count <= fence_i_pulse_count + 1;
            if (recover.valid && (recover.reason == RECOVER_EXCEPTION)) begin
                exception_recover_count <= exception_recover_count + 1;
                last_exception_target <= recover.target;
            end
            if (recover.valid && (recover.reason == RECOVER_FENCE_I)) begin
                fence_i_recover_count <= fence_i_recover_count + 1;
                last_fence_i_target <= recover.target;
            end
        end
    end

    function automatic logic [31:0] encode_lui(
        input logic [4:0] rd, input logic [19:0] upper
    );
        encode_lui = {upper, rd, 7'b0110111};
    endfunction

    function automatic logic [31:0] encode_addi(
        input logic [4:0] rd, input logic [4:0] rs1,
        input logic [11:0] immediate
    );
        encode_addi = {immediate, rs1, 3'b000, rd, 7'b0010011};
    endfunction

    function automatic logic [31:0] encode_load(
        input logic [2:0] funct3, input logic [4:0] rd,
        input logic [4:0] rs1, input logic [11:0] immediate
    );
        encode_load = {immediate, rs1, funct3, rd, 7'b0000011};
    endfunction

    function automatic logic [31:0] encode_store(
        input logic [2:0] funct3, input logic [4:0] rs1,
        input logic [4:0] rs2, input logic [11:0] immediate
    );
        encode_store = {immediate[11:5], rs2, rs1, funct3,
                        immediate[4:0], 7'b0100011};
    endfunction

    function automatic logic [31:0] committed_x3;
        logic [PHYS_REG_IDX_WIDTH-1:0] preg;
        begin
            preg = dut.u_backend.u_rename.u_rat_rrat.rrat[3];
            committed_x3 = dut.u_backend.u_prf.registers[preg];
        end
    endfunction

    task automatic tick;
        @(posedge clk); #1;
    endtask

    task automatic write_li(
        input logic [31:0] pc, input logic [4:0] rd,
        input logic [31:0] value
    );
        logic [31:0] rounded_value;
        begin
            rounded_value = value + 32'h0000_0800;
            u_memory.write_word(pc, encode_lui(rd, rounded_value[31:12]));
            u_memory.write_word(pc + 4,
                encode_addi(rd, rd, value[11:0]));
        end
    endtask

    task automatic prepare_case;
        begin
            rst_n = 1'b0;
            dmem_gate = 1'b1;
            u_memory.clear_words(`NOP_INST);
            repeat (3) tick();
        end
    endtask

    task automatic start_case;
        begin
            rst_n = 1'b1;
            tick();
        end
    endtask

    task automatic wait_commit(
        input logic [31:0] pc, input string name
    );
        integer cycles;
        logic seen;
        begin
            cycles = 0;
            seen = 1'b0;
            while (!seen && (cycles < 320)) begin
                @(negedge clk);
                seen = (commit_fire[0] && (commit_bus.lane0.pc == pc))
                    || (commit_fire[1] && (commit_bus.lane1.pc == pc));
                cycles = cycles + 1;
            end
            if (seen) tick();
            assert (seen) else $fatal(1, "%s commit timeout", name);
        end
    endtask

    task automatic wait_exception(input string name);
        integer cycles;
        begin
            cycles = 0;
            while ((exception_recover_count == 0) && (cycles < 320)) begin
                tick();
                cycles = cycles + 1;
            end
            assert (exception_recover_count == 1)
                else $fatal(1, "%s exception recovery timeout", name);
        end
    endtask

    task automatic check_trap_state(
        input string name,
        input logic [31:0] expected_pc,
        input logic [4:0] expected_cause,
        input logic [31:0] expected_tval
    );
        begin
            assert (last_exception_target == TRAP_VECTOR)
                else $fatal(1, "%s trap target mismatch", name);
            assert (dut.u_backend.u_writeback_commit.u_csr_file.mepc
                    == expected_pc)
                else $fatal(1, "%s mepc mismatch: %08h", name,
                    dut.u_backend.u_writeback_commit.u_csr_file.mepc);
            assert (dut.u_backend.u_writeback_commit.u_csr_file.mcause
                    == {1'b0, 26'b0, expected_cause})
                else $fatal(1, "%s mcause mismatch: %08h", name,
                    dut.u_backend.u_writeback_commit.u_csr_file.mcause);
            assert (dut.u_backend.u_writeback_commit.u_csr_file.mtval
                    == expected_tval)
                else $fatal(1, "%s mtval mismatch: %08h", name,
                    dut.u_backend.u_writeback_commit.u_csr_file.mtval);
        end
    endtask

    task automatic run_memory_exception(
        input string name,
        input logic [31:0] address,
        input logic [31:0] instruction,
        input logic [4:0] expected_cause,
        input integer expected_requests
    );
        begin
            prepare_case();
            write_li(32'h0, 5'd1, address);
            u_memory.write_word(32'h8, instruction);
            start_case();
            wait_exception(name);
            check_trap_state(name, 32'h8, expected_cause, address);
            assert (dmem_request_count == expected_requests)
                else $fatal(1, "%s memory request count=%0d",
                            name, dmem_request_count);
        end
    endtask

    initial begin
        integer cycles;
        clk = 1'b0;
        rst_n = 1'b0;
        dmem_gate = 1'b1;

        // 普通非法编码在译码时形成精确异常。
        prepare_case();
        u_memory.write_word(32'h0, 32'hffff_ffff);
        start_case();
        wait_exception("illegal instruction");
        check_trap_state("illegal instruction", 32'h0, 5'd2,
                         32'hffff_ffff);

        // JAL x0,+2 先产生分支恢复，随后 IF 在 PC=2 形成指令地址不对齐。
        prepare_case();
        u_memory.write_word(32'h0, 32'h0020_006f);
        start_case();
        wait_exception("instruction-address-misaligned");
        check_trap_state("instruction-address-misaligned", 32'h0, 5'd0,
                         32'h2);

        run_memory_exception("LH misaligned", 32'h0000_0001,
            encode_load(3'b001, 5'd3, 5'd1, 12'h0), 5'd4, 0);
        run_memory_exception("LW misaligned", 32'h0000_0002,
            encode_load(3'b010, 5'd3, 5'd1, 12'h0), 5'd4, 0);
        run_memory_exception("SH misaligned", 32'h0000_0001,
            encode_store(3'b001, 5'd1, 5'd0, 12'h0), 5'd6, 0);
        run_memory_exception("SW misaligned", 32'h0000_0002,
            encode_store(3'b010, 5'd1, 5'd0, 12'h0), 5'd6, 0);
        run_memory_exception("load access fault", 32'h0000_2000,
            encode_load(3'b010, 5'd3, 5'd1, 12'h0), 5'd5, 1);

        // 已提交 Store 尚未被外部存储器接收时，FENCE 不能提交，年轻
        // ADDI 也不能越过串行边界；请求被接收并排空后两者依次推进。
        prepare_case();
        u_memory.write_word(32'h0,
            encode_addi(5'd1, 5'd0, 12'h200));
        u_memory.write_word(32'h4,
            encode_addi(5'd2, 5'd0, 12'h05a));
        u_memory.write_word(32'h8,
            encode_store(3'b010, 5'd1, 5'd2, 12'h0));
        u_memory.write_word(32'hc, 32'h0000_000f);
        u_memory.write_word(32'h10,
            encode_addi(5'd3, 5'd0, 12'd17));
        dmem_gate = 1'b0;
        start_case();
        cycles = 0;
        while (!core_dmem_valid && (cycles < 200)) begin
            tick();
            cycles = cycles + 1;
        end
        assert (core_dmem_valid)
            else $fatal(1, "FENCE test Store request missing");
        repeat (10) tick();
        assert ((fence_commit_count == 0) && (post_fence_commit_count == 0))
            else $fatal(1,
                "FENCE crossed nonempty LSQ: fence=%0d younger=%0d occupancy=%0d",
                fence_commit_count, post_fence_commit_count,
                dut.u_backend.lsq_occupancy);
        dmem_gate = 1'b1;
        wait_commit(32'hc, "FENCE");
        wait_commit(32'h10, "instruction after FENCE");
        assert ((fence_commit_count == 1) && (fence_i_pulse_count == 0)
                && (fence_i_recover_count == 0))
            else $fatal(1, "plain FENCE generated incorrect side effects");
        assert (committed_x3() == 32'd17)
            else $fatal(1, "instruction after FENCE did not commit");
        assert (u_memory.mem[32'h200 >> 2] == 32'h0000_005a)
            else $fatal(1, "Store before FENCE was not drained");

        // FENCE.I 提交产生一次 pulse 和一次统一恢复，目标必须是 PC+4；
        // 同束年轻指令只能在恢复后重新取指并提交。
        prepare_case();
        u_memory.write_word(32'h0, 32'h0000_100f);
        u_memory.write_word(32'h4,
            encode_addi(5'd3, 5'd0, 12'd55));
        start_case();
        cycles = 0;
        while ((fence_i_recover_count == 0) && (cycles < 200)) begin
            tick();
            cycles = cycles + 1;
        end
        assert ((fence_i_recover_count == 1)
                && (last_fence_i_target == 32'h4)
                && (fence_i_pulse_count == 1))
            else $fatal(1, "FENCE.I pulse/recovery mismatch");
        wait_commit(32'h4, "instruction after FENCE.I");
        assert (committed_x3() == 32'd55)
            else $fatal(1, "FENCE.I PC+4 refetch failed");
        repeat (8) tick();
        assert ((fence_i_recover_count == 1) && (fence_i_pulse_count == 1))
            else $fatal(1, "FENCE.I notification was not a single pulse");

        $display("PASS: core synchronous exceptions + FENCE/FENCE.I");
        $finish;
    end

endmodule
