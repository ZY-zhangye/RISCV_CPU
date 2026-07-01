`timescale 1ns/1ps
`include "defines.svh"

module tb_core_subword_memory;
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

    function automatic logic [31:0] encode_load(
        input logic [2:0] funct3, input logic [4:0] rd,
        input logic [4:0] rs1, input integer offset
    );
        encode_load = {offset[11:0], rs1, funct3, rd, 7'b0000011};
    endfunction

    function automatic logic [31:0] encode_store(
        input logic [2:0] funct3, input logic [4:0] rs1,
        input logic [4:0] rs2, input integer offset
    );
        logic [11:0] imm12;
        begin
            imm12 = offset[11:0];
            encode_store = {imm12[11:5], rs2, rs1, funct3,
                            imm12[4:0], 7'b0100011};
        end
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
            while (!seen && (cycles < 180)) begin
                @(negedge clk);
                seen = (commit_fire[0] && (commit_bus.lane0.pc == pc))
                    || (commit_fire[1] && (commit_bus.lane1.pc == pc));
                cycles = cycles + 1;
            end
            if (seen) tick();
            assert (seen) else $fatal(1, "%s commit timeout", name);
        end
    endtask

    task automatic run_load(
        input string name, input logic [2:0] funct3,
        input integer offset, input logic [31:0] expected
    );
        begin
            prepare_case();
            u_memory.write_word(32'h0, encode_addi(5'd1, 5'd0, 32'h400));
            u_memory.write_word(32'h4, encode_load(funct3, 5'd3, 5'd1, offset));
            u_memory.write_word(32'h400, 32'h80ff_7f01);
            start_case();
            wait_commit(32'h4, name);
            assert (committed_x3() == expected)
                else $fatal(1, "%s mismatch: expected=%08h actual=%08h",
                            name, expected, committed_x3());
        end
    endtask

    task automatic run_store(
        input string name, input logic [2:0] funct3,
        input integer value, input integer offset,
        input logic [31:0] expected_word
    );
        integer wait_cycles;
        begin
            prepare_case();
            u_memory.write_word(32'h0, encode_addi(5'd1, 5'd0, 32'h400));
            u_memory.write_word(32'h4, encode_addi(5'd2, 5'd0, value));
            u_memory.write_word(32'h8, encode_store(funct3, 5'd1, 5'd2, offset));
            u_memory.write_word(32'h400, 32'h1122_3344);
            start_case();
            wait_commit(32'h8, name);
            wait_cycles = 0;
            while ((u_memory.mem[256] != expected_word) && (wait_cycles < 60)) begin
                tick();
                wait_cycles = wait_cycles + 1;
            end
            assert (u_memory.mem[256] == expected_word)
                else $fatal(1, "%s write mask mismatch: expected=%08h actual=%08h",
                            name, expected_word, u_memory.mem[256]);
        end
    endtask

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;

        run_load("LB",  3'b000, 2, 32'hffff_ffff);
        run_load("LBU", 3'b100, 2, 32'h0000_00ff);
        run_load("LH",  3'b001, 2, 32'hffff_80ff);
        run_load("LHU", 3'b101, 2, 32'h0000_80ff);

        run_store("SB", 3'b000, 32'h7a, 1, 32'h1122_7a44);
        run_store("SH", 3'b001, 32'h7bc, 2, 32'h07bc_3344);

        $display("PASS: core LB/LBU/LH/LHU/SB/SH subword memory instructions");
        $finish;
    end

endmodule
