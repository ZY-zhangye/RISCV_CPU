`timescale 1ns/1ps
`include "defines.svh"

module tb_core_alu_instructions;
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

    function automatic logic [31:0] encode_addi(
        input logic [4:0] rd, input logic [4:0] rs1, input integer imm
    );
        encode_addi = {imm[11:0], rs1, 3'b000, rd, 7'b0010011};
    endfunction

    function automatic logic [31:0] encode_r(
        input logic [6:0] funct7, input logic [2:0] funct3,
        input logic [4:0] rd, input logic [4:0] rs1, input logic [4:0] rs2
    );
        encode_r = {funct7, rs2, rs1, funct3, rd, 7'b0110011};
    endfunction

    function automatic logic [31:0] encode_i(
        input logic [2:0] funct3, input logic [4:0] rd,
        input logic [4:0] rs1, input integer imm
    );
        encode_i = {imm[11:0], rs1, funct3, rd, 7'b0010011};
    endfunction

    function automatic logic [31:0] encode_shift_i(
        input logic [6:0] funct7, input logic [2:0] funct3,
        input logic [4:0] rd, input logic [4:0] rs1, input logic [4:0] shamt
    );
        encode_shift_i = {funct7, shamt, rs1, funct3, rd, 7'b0010011};
    endfunction

    function automatic logic [31:0] encode_u(
        input logic [6:0] opcode, input logic [4:0] rd,
        input logic [19:0] upper
    );
        encode_u = {upper, rd, opcode};
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

    task automatic wait_commit(input logic [31:0] pc, input string name);
        integer cycles;
        logic seen;
        begin
            cycles = 0;
            seen = 1'b0;
            while (!seen && (cycles < 160)) begin
                @(negedge clk);
                seen = (commit_fire[0] && (commit_bus.lane0.pc == pc))
                    || (commit_fire[1] && (commit_bus.lane1.pc == pc));
                cycles = cycles + 1;
            end
            if (seen) tick();
            assert (seen) else $fatal(1, "%s commit timeout", name);
        end
    endtask

    task automatic check_x3(input string name, input logic [31:0] expected);
        assert (committed_x3() == expected)
            else $fatal(1, "%s mismatch: expected=%08h actual=%08h",
                        name, expected, committed_x3());
    endtask

    task automatic run_r(
        input string name, input integer lhs, input integer rhs,
        input logic [6:0] funct7, input logic [2:0] funct3,
        input logic [31:0] expected
    );
        begin
            prepare_case();
            u_memory.write_word(32'h0, encode_addi(5'd1, 5'd0, lhs));
            u_memory.write_word(32'h4, encode_addi(5'd2, 5'd0, rhs));
            u_memory.write_word(32'h8, encode_r(funct7, funct3, 5'd3, 5'd1, 5'd2));
            start_case();
            wait_commit(32'h8, name);
            check_x3(name, expected);
        end
    endtask

    task automatic run_i(
        input string name, input integer lhs, input integer imm,
        input logic [2:0] funct3, input logic [31:0] expected
    );
        begin
            prepare_case();
            u_memory.write_word(32'h0, encode_addi(5'd1, 5'd0, lhs));
            u_memory.write_word(32'h4, encode_i(funct3, 5'd3, 5'd1, imm));
            start_case();
            wait_commit(32'h4, name);
            check_x3(name, expected);
        end
    endtask

    task automatic run_shift_i(
        input string name, input integer lhs, input logic [4:0] shamt,
        input logic [6:0] funct7, input logic [2:0] funct3,
        input logic [31:0] expected
    );
        begin
            prepare_case();
            u_memory.write_word(32'h0, encode_addi(5'd1, 5'd0, lhs));
            u_memory.write_word(32'h4,
                encode_shift_i(funct7, funct3, 5'd3, 5'd1, shamt));
            start_case();
            wait_commit(32'h4, name);
            check_x3(name, expected);
        end
    endtask

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;

        run_r("SUB", 9, 4, 7'b0100000, 3'b000, 32'd5);
        run_r("AND", 32'h5a, 32'h3c, 7'b0000000, 3'b111, 32'h18);
        run_r("OR",  32'h5a, 32'h3c, 7'b0000000, 3'b110, 32'h7e);
        run_r("XOR", 32'h5a, 32'h3c, 7'b0000000, 3'b100, 32'h66);
        run_r("SLL", 1, 5, 7'b0000000, 3'b001, 32'd32);
        run_r("SRL", 32'h400, 3, 7'b0000000, 3'b101, 32'h80);
        run_r("SRA", -16, 2, 7'b0100000, 3'b101, 32'hffff_fffc);
        run_r("SLT", -1, 1, 7'b0000000, 3'b010, 32'd1);
        run_r("SLTU", -1, 1, 7'b0000000, 3'b011, 32'd0);

        run_i("ANDI", 32'h5a, 32'h0f, 3'b111, 32'h0a);
        run_i("ORI",  32'h50, 32'h0f, 3'b110, 32'h5f);
        run_i("XORI", 32'h55, 32'h0f, 3'b100, 32'h5a);
        run_i("SLTI", -1, 0, 3'b010, 32'd1);
        run_i("SLTIU", -1, 1, 3'b011, 32'd0);
        run_shift_i("SLLI", 3, 4, 7'b0000000, 3'b001, 32'd48);
        run_shift_i("SRLI", 32'h400, 3, 7'b0000000, 3'b101, 32'h80);
        run_shift_i("SRAI", -32, 3, 7'b0100000, 3'b101, 32'hffff_fffc);

        prepare_case();
        u_memory.write_word(32'h0, encode_u(7'b0110111, 5'd3, 20'h12345));
        start_case();
        wait_commit(32'h0, "LUI");
        check_x3("LUI", 32'h1234_5000);

        prepare_case();
        u_memory.write_word(32'h0, encode_u(7'b0010111, 5'd3, 20'h00001));
        start_case();
        wait_commit(32'h0, "AUIPC");
        check_x3("AUIPC", 32'h0000_1000);

        $display("PASS: core RV32I ALU/shift/compare/LUI/AUIPC instructions");
        $finish;
    end

endmodule
