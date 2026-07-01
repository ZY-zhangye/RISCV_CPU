`timescale 1ns/1ps
`include "defines.svh"

module tb_core_csr_system_instructions;
    import core_port_pkg::*;

    localparam logic [31:0] TRAP_VECTOR = 32'h0000_0100;
    localparam logic [11:0] CSR_MSTATUS  = 12'h300;
    localparam logic [11:0] CSR_MISA     = 12'h301;
    localparam logic [11:0] CSR_MSCRATCH = 12'h340;
    localparam logic [11:0] CSR_MEPC     = 12'h341;

    logic clk, rst_n;
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
        .irq_software_i(1'b0), .irq_timer_i(1'b0), .irq_external_i(1'b0),
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
        input logic [4:0] rd, input logic [4:0] rs1,
        input logic [11:0] immediate
    );
        encode_addi = {immediate, rs1, 3'b000, rd, 7'b0010011};
    endfunction

    function automatic logic [31:0] encode_csr(
        input logic [11:0] csr_addr,
        input logic [4:0] source,
        input logic [2:0] funct3,
        input logic [4:0] rd
    );
        encode_csr = {csr_addr, source, funct3, rd, 7'b1110011};
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
            while (!seen && (cycles < 300)) begin
                @(negedge clk);
                seen = (commit_fire[0] && (commit_bus.lane0.pc == pc))
                    || (commit_fire[1] && (commit_bus.lane1.pc == pc));
                cycles = cycles + 1;
            end
            if (seen) tick();
            assert (seen) else $fatal(1, "%s commit timeout", name);
        end
    endtask

    task automatic wait_recover(
        input recover_reason_e reason,
        input logic [31:0] target,
        input string name
    );
        integer cycles;
        logic seen;
        begin
            cycles = 0;
            seen = 1'b0;
            while (!seen && (cycles < 300)) begin
                @(negedge clk);
                seen = recover.valid && (recover.reason == reason)
                    && (recover.target == target);
                cycles = cycles + 1;
            end
            if (seen) tick();
            assert (seen)
                else $fatal(1, "%s recovery timeout/target mismatch", name);
        end
    endtask

    task automatic run_csr_modify(
        input string name,
        input logic [2:0] funct3,
        input logic [31:0] source_value,
        input logic [31:0] expected_new_value
    );
        localparam logic [31:0] INITIAL_VALUE = 32'ha5a5_000f;
        logic [4:0] encoded_source;
        begin
            prepare_case();

            // 先通过一条已提交 CSRRW 初始化 mscratch，再执行被测指令。
            // CSR 串行化保证后者读取的是精确提交后的值。
            write_li(32'h00, 5'd1, INITIAL_VALUE);
            u_memory.write_word(32'h08,
                encode_csr(CSR_MSCRATCH, 5'd1, 3'b001, 5'd0));
            write_li(32'h0c, 5'd2, source_value);
            encoded_source = funct3[2] ? source_value[4:0] : 5'd2;
            u_memory.write_word(32'h14,
                encode_csr(CSR_MSCRATCH, encoded_source, funct3, 5'd3));

            start_case();
            wait_commit(32'h14, name);
            assert (committed_x3() == INITIAL_VALUE)
                else $fatal(1, "%s old CSR value mismatch: %08h",
                            name, committed_x3());
            assert (dut.u_backend.u_writeback_commit.u_csr_file.mscratch
                    == expected_new_value)
                else $fatal(1, "%s committed CSR value mismatch: %08h",
                            name,
                            dut.u_backend.u_writeback_commit.u_csr_file.mscratch);
        end
    endtask

    task automatic run_exception(
        input string name,
        input logic [31:0] instruction,
        input logic [4:0] expected_cause,
        input logic [31:0] expected_tval
    );
        begin
            prepare_case();
            u_memory.write_word(32'h0, instruction);
            start_case();
            wait_recover(RECOVER_EXCEPTION, TRAP_VECTOR, name);
            assert (dut.u_backend.u_writeback_commit.u_csr_file.mepc == 32'h0)
                else $fatal(1, "%s mepc mismatch", name);
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

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;

        run_csr_modify("CSRRW",  3'b001, 32'h1234_5678,
                       32'h1234_5678);
        run_csr_modify("CSRRS",  3'b010, 32'hf0f0_0000,
                       32'hf5f5_000f);
        run_csr_modify("CSRRC",  3'b011, 32'h00ff_000f,
                       32'ha500_0000);
        run_csr_modify("CSRRWI", 3'b101, 32'h0000_001b,
                       32'h0000_001b);
        run_csr_modify("CSRRSI", 3'b110, 32'h0000_0010,
                       32'ha5a5_001f);
        run_csr_modify("CSRRCI", 3'b111, 32'h0000_000f,
                       32'ha5a5_0000);

        // CSRRS source=x0 是纯读取，即使目标 CSR 只读也必须合法。
        prepare_case();
        u_memory.write_word(32'h0,
            encode_csr(CSR_MISA, 5'd0, 3'b010, 5'd3));
        start_case();
        wait_commit(32'h0, "CSRRS misa read");
        assert (committed_x3() == 32'h4000_1100)
            else $fatal(1, "read-only misa value mismatch");

        run_exception("ECALL", 32'h0000_0073, 5'd11, 32'h0);
        run_exception("EBREAK", 32'h0010_0073, 5'd3, 32'h0);
        run_exception("unimplemented CSR", 32'hfff0_11f3, 5'd2,
                      32'hfff0_11f3);
        run_exception("write read-only misa", 32'h3010_11f3, 5'd2,
                      32'h3010_11f3);

        // 先提交 mepc 和 mstatus.MPIE，再执行 MRET。除检查恢复目标外，
        // 目标地址上的 ADDI 必须真正取回并提交，且 MIE <- MPIE。
        prepare_case();
        write_li(32'h00, 5'd1, 32'h0000_0080);
        u_memory.write_word(32'h08,
            encode_csr(CSR_MEPC, 5'd1, 3'b001, 5'd0));
        u_memory.write_word(32'h0c,
            encode_addi(5'd2, 5'd0, 12'h080));
        u_memory.write_word(32'h10,
            encode_csr(CSR_MSTATUS, 5'd2, 3'b001, 5'd0));
        u_memory.write_word(32'h14, 32'h3020_0073);
        u_memory.write_word(32'h80,
            encode_addi(5'd3, 5'd0, 12'd42));
        start_case();
        wait_recover(RECOVER_BRANCH, 32'h0000_0080, "MRET");
        wait_commit(32'h80, "MRET target");
        assert (committed_x3() == 32'd42)
            else $fatal(1, "MRET target instruction did not commit");
        assert (dut.u_backend.u_writeback_commit.u_csr_file.mstatus_mie
                && dut.u_backend.u_writeback_commit.u_csr_file.mstatus_mpie)
            else $fatal(1, "MRET mstatus MIE/MPIE update failed");

        $display("PASS: core CSR read/modify/write + ECALL/EBREAK/MRET/system traps");
        $finish;
    end

endmodule
