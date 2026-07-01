`timescale 1ns/1ps
`include "defines.svh"

module tb_core_combo_trap_interrupt;
    import core_port_pkg::*;

    localparam logic [31:0] TRAP_VECTOR = 32'h0000_0100;
    localparam logic [11:0] CSR_MSTATUS  = 12'h300;
    localparam logic [11:0] CSR_MIE      = 12'h304;
    localparam logic [11:0] CSR_MSCRATCH = 12'h340;
    localparam logic [11:0] CSR_MEPC     = 12'h341;

    logic clk, rst_n;
    logic irq_external;
    logic [31:0] imem_addr;
    logic imem_ren;
    logic [63:0] imem_rdata;
    logic dmem_request_valid, dmem_request_ready;
    lsq_mem_request_t dmem_request;
    lsq_mem_response_t dmem_response;
    recover_event_t recover;
    rob_commit_bundle_t commit_bus;
    logic [1:0] commit_fire;
    logic signed [32:0] mul_operand_a, mul_operand_b;
    logic signed [65:0] mul_product;

    integer case_id;
    integer csr_commit_count;
    integer exception_recover_count;
    integer interrupt_recover_count;
    integer mret_recover_count;
    logic csr_order_error;

    core_top #(
        .RESET_PC(32'h0),
        .MTVEC_RESET(TRAP_VECTOR)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .imem_addr_o(imem_addr), .imem_ren_o(imem_ren),
        .imem_rdata_i(imem_rdata),
        .dmem_request_valid_o(dmem_request_valid),
        .dmem_request_o(dmem_request),
        .dmem_request_ready_i(dmem_request_ready),
        .dmem_response_i(dmem_response),
        .irq_software_i(1'b0), .irq_timer_i(1'b0),
        .irq_external_i(irq_external),
        .mul_request_valid_o(), .mul_operand_a_o(mul_operand_a),
        .mul_operand_b_o(mul_operand_b), .mul_product_i(mul_product),
        .div_dividend_valid_o(), .div_dividend_ready_i(1'b1),
        .div_dividend_data_o(), .div_divisor_valid_o(),
        .div_divisor_ready_i(1'b1), .div_divisor_data_o(),
        .div_result_valid_i(1'b0), .div_result_ready_o(),
        .div_quotient_i('0), .div_remainder_i('0),
        .recover_o(recover), .branch_update_o(), .fence_i_commit_o(),
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

    function automatic logic [31:0] encode_lui(
        input logic [4:0] rd, input logic [19:0] upper
    );
        encode_lui = {upper, rd, 7'b0110111};
    endfunction

    function automatic logic [31:0] encode_addi(
        input logic [4:0] rd, input logic [4:0] rs1, input integer imm
    );
        encode_addi = {imm[11:0], rs1, 3'b000, rd, 7'b0010011};
    endfunction

    function automatic logic [31:0] encode_csr(
        input logic [11:0] csr_addr,
        input logic [4:0] source,
        input logic [2:0] funct3,
        input logic [4:0] rd
    );
        encode_csr = {csr_addr, source, funct3, rd, 7'b1110011};
    endfunction

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

    task automatic prepare_case(input integer selected_case);
        begin
            rst_n = 1'b0;
            irq_external = 1'b0;
            case_id = selected_case;
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

    task automatic wait_commit(input logic [31:0] pc, input string name);
        integer cycles;
        logic seen;
        begin
            cycles = 0;
            seen = 1'b0;
            while (!seen && (cycles < 500)) begin
                @(negedge clk);
                seen = (commit_fire[0] && (commit_bus.lane0.pc == pc))
                    || (commit_fire[1] && (commit_bus.lane1.pc == pc));
                cycles = cycles + 1;
            end
            if (seen) tick();
            assert (seen) else $fatal(1, "%s commit timeout", name);
        end
    endtask

    task automatic wait_recovery(
        input recover_reason_e reason,
        input logic [31:0] target,
        input string name
    );
        integer cycles;
        logic seen;
        begin
            cycles = 0;
            seen = 1'b0;
            while (!seen && (cycles < 500)) begin
                @(negedge clk);
                seen = recover.valid && (recover.reason == reason)
                    && (recover.target == target);
                cycles = cycles + 1;
            end
            if (seen) tick();
            assert (seen) else $fatal(1,
                "%s recovery timeout: csr=%0d exc=%0d irq=%0d mret=%0d mepc=%08h rob_occ=%0d serial=%0b head=%08h/%0b iq=%0d/%0d rat5=%0d busy=%0b issue=%0b/%0b pc=%08h/%08h",
                name, csr_commit_count, exception_recover_count,
                interrupt_recover_count, mret_recover_count,
                dut.u_backend.u_writeback_commit.u_csr_file.mepc,
                dut.u_backend.rob_occupancy,
                dut.u_backend.serializing_pending,
                dut.u_backend.rob_commit_bus.lane0.pc,
                dut.u_backend.rob_commit_bus.lane0.valid,
                dut.u_backend.u_issue_queues.u_iq0.occupancy,
                dut.u_backend.u_issue_queues.u_iq1.occupancy,
                dut.u_backend.u_rename.u_rat_rrat.rat[5],
                dut.u_backend.u_rename.u_busy_table.busy_bitmap[
                    dut.u_backend.u_rename.u_rat_rrat.rat[5]],
                dut.u_backend.issue0_valid,
                dut.u_backend.issue1_valid,
                dut.u_backend.issue0_bus.uop.dec.pc,
                dut.u_backend.issue1_bus.uop.dec.pc);
        end
    endtask

    function automatic logic [31:0] expected_csr_pc(
        input integer selected_case,
        input integer index
    );
        begin
            expected_csr_pc = 32'hffff_ffff;
            if (selected_case == 1) begin
                unique case (index)
                    0: expected_csr_pc = 32'h04;
                    1: expected_csr_pc = 32'h08;
                    2: expected_csr_pc = 32'h0c;
                    3: expected_csr_pc = 32'h100;
                    4: expected_csr_pc = 32'h108;
                    default: ;
                endcase
            end else if (selected_case == 2) begin
                unique case (index)
                    0: expected_csr_pc = 32'h08;
                    1: expected_csr_pc = 32'h10;
                    default: ;
                endcase
            end
        end
    endfunction

    always_ff @(posedge clk) begin
        logic [31:0] committed_csr_pc;
        logic csr_committed;
        if (!rst_n) begin
            csr_commit_count        <= 0;
            exception_recover_count <= 0;
            interrupt_recover_count <= 0;
            mret_recover_count      <= 0;
            csr_order_error         <= 1'b0;
        end else begin
            csr_committed = 1'b0;
            committed_csr_pc = '0;
            if (commit_fire[0] && commit_bus.lane0.is_csr) begin
                csr_committed = 1'b1;
                committed_csr_pc = commit_bus.lane0.pc;
            end
            if (commit_fire[1] && commit_bus.lane1.is_csr) begin
                if (csr_committed)
                    csr_order_error <= 1'b1;
                csr_committed = 1'b1;
                committed_csr_pc = commit_bus.lane1.pc;
            end
            if (csr_committed) begin
                if (committed_csr_pc
                    != expected_csr_pc(case_id, csr_commit_count))
                    csr_order_error <= 1'b1;
                csr_commit_count <= csr_commit_count + 1;
            end

            if (recover.valid) begin
                unique case (recover.reason)
                    RECOVER_EXCEPTION:
                        exception_recover_count <= exception_recover_count + 1;
                    RECOVER_INTERRUPT:
                        interrupt_recover_count <= interrupt_recover_count + 1;
                    RECOVER_BRANCH:
                        mret_recover_count <= mret_recover_count + 1;
                    default: ;
                endcase
            end
        end
    end

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        irq_external = 1'b0;
        case_id = 0;

        // ------------------------------------------------------------------
        // Case 1：连续 CSR 后发生非法指令。handler 读取 mepc、加 4、精确
        // 写回 mepc，再通过 MRET 返回异常指令的下一条。
        // ------------------------------------------------------------------
        prepare_case(1);
        u_memory.write_word(32'h00, encode_addi(5'd1, 5'd0, 17));
        u_memory.write_word(32'h04,
            encode_csr(CSR_MSCRATCH, 5'd1, 3'b001, 5'd0));
        u_memory.write_word(32'h08,
            encode_csr(CSR_MSCRATCH, 5'd2, 3'b110, 5'd2));
        u_memory.write_word(32'h0c,
            encode_csr(CSR_MSCRATCH, 5'd1, 3'b111, 5'd3));
        u_memory.write_word(32'h10, 32'hffff_ffff);
        u_memory.write_word(32'h14, encode_addi(5'd4, 5'd0, 44));
        u_memory.write_word(32'h100,
            encode_csr(CSR_MEPC, 5'd0, 3'b010, 5'd5));
        u_memory.write_word(32'h104, encode_addi(5'd5, 5'd5, 4));
        u_memory.write_word(32'h108,
            encode_csr(CSR_MEPC, 5'd5, 3'b001, 5'd0));
        u_memory.write_word(32'h10c, 32'h3020_0073);
        start_case();
        wait_recovery(RECOVER_EXCEPTION, TRAP_VECTOR, "illegal trap");
        assert ((dut.u_backend.u_writeback_commit.u_csr_file.mepc == 32'h10)
                && (dut.u_backend.u_writeback_commit.u_csr_file.mcause == 32'd2)
                && (dut.u_backend.u_writeback_commit.u_csr_file.mtval
                    == 32'hffff_ffff))
            else $fatal(1, "synchronous trap CSR state mismatch");
        wait_recovery(RECOVER_BRANCH, 32'h14, "exception handler MRET");
        wait_commit(32'h14, "post-exception instruction");
        repeat (5) tick();
        assert (!csr_order_error && (csr_commit_count == 5)
                && (exception_recover_count == 1)
                && (mret_recover_count == 1))
            else $fatal(1, "serialized CSR/exception/MRET sequence failed");
        assert ((committed_reg(5'd2) == 32'h11)
                && (committed_reg(5'd3) == 32'h13)
                && (committed_reg(5'd4) == 32'd44)
                && (dut.u_backend.u_writeback_commit.u_csr_file.mscratch
                    == 32'h12))
            else $fatal(1, "CSR architectural state after exception mismatch");
        assert ((dut.u_backend.u_rename.u_rat_rrat.rat[2]
                 == dut.u_backend.u_rename.u_rat_rrat.rrat[2])
                && (dut.u_backend.u_rename.u_rat_rrat.rat[3]
                    == dut.u_backend.u_rename.u_rat_rrat.rrat[3])
                && (dut.u_backend.u_rename.u_rat_rrat.rat[4]
                    == dut.u_backend.u_rename.u_rat_rrat.rrat[4]))
            else $fatal(1, "Rename state mismatch after synchronous trap/MRET");

        // ------------------------------------------------------------------
        // Case 2：IRQ 在 CSR 串行序列期间已同步，但只有 mie/mstatus 精确
        // 提交后才可见。中断应在空 ROB 边界取走，mepc=下一条 PC=0x14；
        // handler 直接 MRET，随后主程序必须从 0x14 完整执行。
        // ------------------------------------------------------------------
        prepare_case(2);
        u_memory.write_word(32'h00, encode_lui(5'd1, 20'h00001));
        u_memory.write_word(32'h04, encode_addi(5'd1, 5'd1, -2048));
        u_memory.write_word(32'h08,
            encode_csr(CSR_MIE, 5'd1, 3'b001, 5'd0));
        u_memory.write_word(32'h0c, encode_addi(5'd2, 5'd0, 8));
        u_memory.write_word(32'h10,
            encode_csr(CSR_MSTATUS, 5'd2, 3'b001, 5'd0));
        u_memory.write_word(32'h14, encode_addi(5'd6, 5'd0, 6));
        u_memory.write_word(32'h18, 32'h0000_000f);
        u_memory.write_word(32'h1c, encode_addi(5'd7, 5'd0, 7));
        u_memory.write_word(32'h100, 32'h3020_0073);
        irq_external = 1'b1;
        start_case();
        wait_recovery(RECOVER_INTERRUPT, TRAP_VECTOR, "external interrupt");
        irq_external = 1'b0;
        assert ((dut.u_backend.u_writeback_commit.u_csr_file.mepc == 32'h14)
                && (dut.u_backend.u_writeback_commit.u_csr_file.mcause
                    == 32'h8000_000b)
                && (dut.u_backend.u_writeback_commit.u_csr_file.mtval == 0)
                && !dut.u_backend.u_writeback_commit.u_csr_file.mstatus_mie
                && dut.u_backend.u_writeback_commit.u_csr_file.mstatus_mpie)
            else $fatal(1, "external interrupt precise state mismatch");
        wait_recovery(RECOVER_BRANCH, 32'h14, "interrupt handler MRET");
        wait_commit(32'h1c, "post-interrupt instruction stream");
        repeat (8) tick();
        assert (!csr_order_error && (csr_commit_count == 2)
                && (interrupt_recover_count == 1)
                && (mret_recover_count == 1))
            else $fatal(1, "serialized interrupt/MRET sequence failed");
        assert ((committed_reg(5'd6) == 32'd6)
                && (committed_reg(5'd7) == 32'd7)
                && dut.u_backend.u_writeback_commit.u_csr_file.mstatus_mie
                && dut.u_backend.u_writeback_commit.u_csr_file.mstatus_mpie)
            else $fatal(1, "post-interrupt architectural state mismatch");
        assert ((dut.u_backend.u_rename.u_rat_rrat.rat[6]
                 == dut.u_backend.u_rename.u_rat_rrat.rrat[6])
                && (dut.u_backend.u_rename.u_rat_rrat.rat[7]
                    == dut.u_backend.u_rename.u_rat_rrat.rrat[7]))
            else $fatal(1, "Rename state mismatch after interrupt/MRET");

        $display("PASS: serialized CSR + precise exception/interrupt + MRET recovery");
        $finish;
    end

endmodule
