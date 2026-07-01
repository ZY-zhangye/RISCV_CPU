`timescale 1ns/1ps
`include "defines.svh"

module tb_core_branch_instructions;
    import core_port_pkg::*;

    logic clk;
    logic rst_n;
    logic [31:0] imem_addr;
    logic imem_ren;
    logic [63:0] imem_rdata;
    logic dmem_request_valid;
    lsq_mem_request_t dmem_request;
    logic dmem_request_ready;
    lsq_mem_response_t dmem_response;
    recover_event_t recover;
    branch_update_t branch_update;
    rob_commit_bundle_t commit_bus;
    logic [1:0] commit_fire;
    logic signed [32:0] mul_operand_a;
    logic signed [32:0] mul_operand_b;
    logic signed [65:0] mul_product;

    integer branch_update_count;
    integer branch_recover_count;
    integer branch_commit_count;
    branch_update_t last_branch_update;
    recover_event_t last_branch_recover;
    logic [31:0] last_branch_commit_pc;
    logic [31:0] last_branch_commit_next_pc;

    core_top #(
        .RESET_PC(32'h0000_0000),
        .MTVEC_RESET(32'h0000_0100)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .imem_addr_o(imem_addr), .imem_ren_o(imem_ren),
        .imem_rdata_i(imem_rdata),
        .dmem_request_valid_o(dmem_request_valid),
        .dmem_request_o(dmem_request),
        .dmem_request_ready_i(dmem_request_ready),
        .dmem_response_i(dmem_response),
        .irq_software_i(1'b0), .irq_timer_i(1'b0),
        .irq_external_i(1'b0),
        .mul_request_valid_o(), .mul_operand_a_o(mul_operand_a),
        .mul_operand_b_o(mul_operand_b), .mul_product_i(mul_product),
        .div_dividend_valid_o(), .div_dividend_ready_i(1'b1),
        .div_dividend_data_o(), .div_divisor_valid_o(),
        .div_divisor_ready_i(1'b1), .div_divisor_data_o(),
        .div_result_valid_i(1'b0), .div_result_ready_o(),
        .div_quotient_i('0), .div_remainder_i('0),
        .recover_o(recover), .branch_update_o(branch_update),
        .fence_i_commit_o(), .commit_bus_o(commit_bus),
        .commit_fire_o(commit_fire), .core_idle_o()
    );

    unified_memory_model #(
        .BASE_ADDR(32'h0000_0000),
        .WORD_COUNT(1024)
    ) u_memory (
        .clk(clk), .rst_n(rst_n),
        .imem_addr(imem_addr), .imem_ren(imem_ren),
        .imem_rdata(imem_rdata),
        .dmem_request_valid(dmem_request_valid),
        .dmem_request(dmem_request),
        .dmem_request_ready(dmem_request_ready),
        .dmem_response(dmem_response),
        .dmem_stage_valid_o()
    );

    always #5 clk = ~clk;
    assign mul_product = mul_operand_a * mul_operand_b;

    function automatic logic [31:0] encode_addi(
        input logic [4:0] rd,
        input logic [4:0] rs1,
        input integer     imm
    );
        logic [11:0] imm12;
        begin
            imm12 = imm[11:0];
            encode_addi = {imm12, rs1, 3'b000, rd, 7'b0010011};
        end
    endfunction

    function automatic logic [31:0] encode_branch(
        input logic [2:0] funct3,
        input logic [4:0] rs1,
        input logic [4:0] rs2,
        input integer     offset
    );
        logic [12:0] imm13;
        begin
            imm13 = offset[12:0];
            encode_branch = {imm13[12], imm13[10:5], rs2, rs1, funct3,
                             imm13[4:1], imm13[11], 7'b1100011};
        end
    endfunction

    function automatic logic [31:0] encode_jal(
        input logic [4:0] rd,
        input integer     offset
    );
        logic [20:0] imm21;
        begin
            imm21 = offset[20:0];
            encode_jal = {imm21[20], imm21[10:1], imm21[11], imm21[19:12],
                          rd, 7'b1101111};
        end
    endfunction

    function automatic logic [31:0] encode_jalr(
        input logic [4:0] rd,
        input logic [4:0] rs1,
        input integer     imm
    );
        logic [11:0] imm12;
        begin
            imm12 = imm[11:0];
            encode_jalr = {imm12, rs1, 3'b000, rd, 7'b1100111};
        end
    endfunction

    function automatic logic [31:0] committed_reg(input integer arch_idx);
        logic [PHYS_REG_IDX_WIDTH-1:0] preg;
        begin
            preg = dut.u_backend.u_rename.u_rat_rrat.rrat[arch_idx];
            committed_reg = (preg == '0)
                          ? '0 : dut.u_backend.u_prf.registers[preg];
        end
    endfunction

    function automatic logic [PHYS_REG_IDX_WIDTH-1:0] committed_map(
        input integer arch_idx
    );
        committed_map = dut.u_backend.u_rename.u_rat_rrat.rrat[arch_idx];
    endfunction

    task automatic tick;
        @(posedge clk);
        #1;
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

    task automatic wait_for_count(
        input integer selector,
        input integer expected,
        input string  description
    );
        integer wait_cycles;
        integer current_count;
        begin
            wait_cycles = 0;
            current_count = 0;
            while ((current_count < expected) && (wait_cycles < 200)) begin
                tick();
                case (selector)
                    0: current_count = branch_update_count;
                    1: current_count = branch_recover_count;
                    default: current_count = branch_commit_count;
                endcase
                wait_cycles = wait_cycles + 1;
            end
            assert (current_count >= expected)
                else $fatal(1, "timeout waiting for %s", description);
        end
    endtask

    task automatic wait_for_commit_pc(
        input logic [31:0] pc,
        input string description
    );
        integer wait_cycles;
        logic seen;
        begin
            wait_cycles = 0;
            seen = 1'b0;
            while (!seen && (wait_cycles < 200)) begin
                @(negedge clk);
                seen = (commit_fire[0] && (commit_bus.lane0.pc == pc))
                    || (commit_fire[1] && (commit_bus.lane1.pc == pc));
                if (!seen)
                    wait_cycles = wait_cycles + 1;
            end
            if (seen)
                tick();
            assert (seen)
                else $fatal(1, "timeout waiting for %s commit pc=%08h",
                            description, pc);
        end
    endtask

    task automatic run_conditional_branch(
        input string      name,
        input logic [2:0] funct3,
        input integer     lhs,
        input integer     rhs,
        input logic       expected_taken
    );
        begin
            prepare_case();
            u_memory.write_word(32'h0000_0000, encode_addi(5'd1, 5'd0, lhs));
            u_memory.write_word(32'h0000_0004, encode_addi(5'd2, 5'd0, rhs));
            u_memory.write_word(32'h0000_0008,
                                encode_branch(funct3, 5'd1, 5'd2, 24));
            u_memory.write_word(32'h0000_000c,
                                encode_addi(5'd5, 5'd0, 99)); // taken 时错误路径
            u_memory.write_word(32'h0000_0020,
                                encode_addi(5'd3, 5'd0, 1));
            start_case();

            wait_for_count(0, 1, {name, " branch update"});
            assert ((last_branch_update.pc == 32'h0000_0008)
                    && (last_branch_update.taken == expected_taken)
                    && (last_branch_update.target == 32'h0000_0020)
                    && !last_branch_update.is_jalr)
                else $fatal(1, "%s branch update mismatch", name);

            wait_for_count(2, 1, {name, " branch commit"});
            assert (last_branch_commit_pc == 32'h0000_0008)
                else $fatal(1, "%s committed wrong branch PC", name);

            if (expected_taken) begin
                wait_for_count(1, 1, {name, " recovery"});
                assert ((last_branch_recover.reason == RECOVER_BRANCH)
                        && (last_branch_recover.target == 32'h0000_0020))
                    else $fatal(1, "%s recovery target mismatch", name);
                wait_for_commit_pc(32'h0000_0020, {name, " target"});
                assert (committed_reg(3) == 32'd1)
                    else $fatal(1, "%s target instruction did not execute", name);
                assert (committed_map(5) == PHYS_REG_IDX_WIDTH'(5))
                    else $fatal(1, "%s wrong-path instruction committed", name);
                assert (dut.u_backend.retire_next_pc == 32'h0000_0024)
                    else $fatal(1, "%s retire_next_pc mismatch after target", name);
            end else begin
                assert (last_branch_commit_next_pc == 32'h0000_000c)
                    else $fatal(1, "%s not-taken branch next PC mismatch", name);
                repeat (3) tick();
                assert (branch_recover_count == 0)
                    else $fatal(1, "%s unexpectedly recovered", name);
            end
        end
    endtask

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            branch_update_count <= 0;
            branch_recover_count <= 0;
            branch_commit_count <= 0;
            last_branch_update <= '0;
            last_branch_recover <= '0;
            last_branch_commit_pc <= '0;
            last_branch_commit_next_pc <= '0;
        end else begin
            if (branch_update.valid) begin
                branch_update_count <= branch_update_count + 1;
                last_branch_update <= branch_update;
            end
            if (recover.valid && (recover.reason == RECOVER_BRANCH)) begin
                branch_recover_count <= branch_recover_count + 1;
                last_branch_recover <= recover;
            end
            if (commit_fire[0] && commit_bus.lane0.is_branch) begin
                branch_commit_count <= branch_commit_count + 1;
                last_branch_commit_pc <= commit_bus.lane0.pc;
                last_branch_commit_next_pc <= commit_bus.lane0.next_pc;
            end
            if (commit_fire[1] && commit_bus.lane1.is_branch) begin
                branch_commit_count <= branch_commit_count + 1;
                last_branch_commit_pc <= commit_bus.lane1.pc;
                last_branch_commit_next_pc <= commit_bus.lane1.next_pc;
            end
        end
    end

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;

        run_conditional_branch("BEQ taken",  3'b000,  5,  5, 1'b1);
        run_conditional_branch("BNE taken",  3'b001,  5,  6, 1'b1);
        run_conditional_branch("BLT taken",  3'b100, -1,  1, 1'b1);
        run_conditional_branch("BGE taken",  3'b101,  1, -1, 1'b1);
        run_conditional_branch("BLTU taken", 3'b110,  1, -1, 1'b1);
        run_conditional_branch("BGEU taken", 3'b111, -1,  1, 1'b1);
        run_conditional_branch("BEQ not taken", 3'b000, 5, 6, 1'b0);

        // JAL：验证立即数目标、x3 链接值和同 fetch bundle 的错误路径清除。
        prepare_case();
        u_memory.write_word(32'h0000_0000, encode_jal(5'd3, 32));
        u_memory.write_word(32'h0000_0004, encode_addi(5'd5, 5'd0, 99));
        u_memory.write_word(32'h0000_0020, encode_addi(5'd4, 5'd0, 1));
        start_case();
        wait_for_count(0, 1, "JAL update");
        assert (last_branch_update.taken
                && (last_branch_update.pc == 32'h0000_0000)
                && (last_branch_update.target == 32'h0000_0020)
                && !last_branch_update.is_jalr)
            else $fatal(1, "JAL branch update mismatch");
        wait_for_count(1, 1, "JAL recovery");
        assert (last_branch_recover.target == 32'h0000_0020)
            else $fatal(1, "JAL recovery target mismatch");
        wait_for_count(2, 1, "JAL commit");
        assert (last_branch_commit_pc == 32'h0000_0000)
            else $fatal(1, "JAL committed wrong PC");
        assert (committed_reg(3) == 32'h0000_0004)
            else $fatal(1, "JAL link value mismatch");
        wait_for_commit_pc(32'h0000_0020, "JAL target");
        assert (committed_map(5) == PHYS_REG_IDX_WIDTH'(5))
            else $fatal(1, "JAL wrong-path instruction committed");

        // JALR：33 + (-1) = 32，并强制 bit0 清零；链接值为 PC+4=8。
        prepare_case();
        u_memory.write_word(32'h0000_0000, encode_addi(5'd1, 5'd0, 33));
        u_memory.write_word(32'h0000_0004, encode_jalr(5'd3, 5'd1, -1));
        u_memory.write_word(32'h0000_0008, encode_addi(5'd5, 5'd0, 99));
        u_memory.write_word(32'h0000_0020, encode_addi(5'd4, 5'd0, 1));
        start_case();
        wait_for_count(0, 1, "JALR update");
        assert (last_branch_update.taken
                && (last_branch_update.pc == 32'h0000_0004)
                && (last_branch_update.target == 32'h0000_0020)
                && last_branch_update.is_jalr)
            else $fatal(1, "JALR branch update mismatch");
        wait_for_count(1, 1, "JALR recovery");
        assert (last_branch_recover.target == 32'h0000_0020)
            else $fatal(1, "JALR recovery target mismatch");
        wait_for_count(2, 1, "JALR commit");
        assert (last_branch_commit_pc == 32'h0000_0004)
            else $fatal(1, "JALR committed wrong PC");
        assert (committed_reg(3) == 32'h0000_0008)
            else $fatal(1, "JALR link value mismatch");
        wait_for_commit_pc(32'h0000_0020, "JALR target");
        assert (committed_map(5) == PHYS_REG_IDX_WIDTH'(5))
            else $fatal(1, "JALR wrong-path instruction committed");

        $display("PASS: core BEQ/BNE/BLT/BGE/BLTU/BGEU/JAL/JALR");
        $finish;
    end

endmodule
