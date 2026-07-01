`timescale 1ns/1ps
`include "defines.svh"

module tb_core_combo_memory;
    import core_port_pkg::*;

    logic clk, rst_n;
    logic [31:0] imem_addr;
    logic imem_ren;
    logic [63:0] imem_rdata;
    logic core_dmem_valid, core_dmem_ready;
    logic memory_dmem_valid, memory_dmem_ready;
    logic dmem_gate;
    logic dmem_stage_valid;
    lsq_mem_request_t dmem_request;
    lsq_mem_response_t dmem_response;
    rob_commit_bundle_t commit_bus;
    logic [1:0] commit_fire;
    logic signed [32:0] mul_operand_a, mul_operand_b;
    logic signed [65:0] mul_product;

    integer store_handshake_count;
    integer load_handshake_count;
    integer external_store_stage_count;
    logic x3_committed, x5_committed;
    logic load_overtook_partial_store;
    logic bad_store_order;

    core_top #(.RESET_PC(32'h0)) dut (
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
        .recover_o(), .branch_update_o(), .fence_i_commit_o(),
        .commit_bus_o(commit_bus), .commit_fire_o(commit_fire),
        .core_idle_o()
    );

    // 同时门控 valid/ready，模拟 Core 外存储器反压而不破坏握手原子性。
    assign memory_dmem_valid = core_dmem_valid && dmem_gate;
    assign core_dmem_ready   = memory_dmem_ready && dmem_gate;

    unified_memory_model #(.WORD_COUNT(1024)) u_memory (
        .clk(clk), .rst_n(rst_n),
        .imem_addr(imem_addr), .imem_ren(imem_ren), .imem_rdata(imem_rdata),
        .dmem_request_valid(memory_dmem_valid), .dmem_request(dmem_request),
        .dmem_request_ready(memory_dmem_ready), .dmem_response(dmem_response),
        .dmem_stage_valid_o(dmem_stage_valid)
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
        input logic [4:0] rs1, input integer imm
    );
        encode_load = {imm[11:0], rs1, funct3, rd, 7'b0000011};
    endfunction

    function automatic logic [31:0] encode_store(
        input logic [2:0] funct3, input logic [4:0] rs1,
        input logic [4:0] rs2, input integer imm
    );
        logic [11:0] store_imm;
        begin
            store_imm = imm[11:0];
            encode_store = {store_imm[11:5], rs2, rs1, funct3,
                            store_imm[4:0], 7'b0100011};
        end
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

    task automatic wait_commit(input logic [31:0] pc, input string name);
        integer cycles;
        logic seen;
        begin
            cycles = 0;
            seen = 1'b0;
            while (!seen && (cycles < 360)) begin
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
            store_handshake_count       <= 0;
            load_handshake_count        <= 0;
            external_store_stage_count  <= 0;
            x3_committed                <= 1'b0;
            x5_committed                <= 1'b0;
            load_overtook_partial_store <= 1'b0;
            bad_store_order             <= 1'b0;
        end else begin
            if (core_dmem_valid && core_dmem_ready) begin
                if (dmem_request.is_store) begin
                    if ((store_handshake_count == 0)
                        && ((dmem_request.address != 32'h400)
                            || (dmem_request.write_data != 32'd42)
                            || (dmem_request.write_strobe != 4'b1111)))
                        bad_store_order <= 1'b1;
                    if ((store_handshake_count == 1)
                        && ((dmem_request.address != 32'h404)
                            || (dmem_request.write_data[15:0] != 16'h0678)
                            || (dmem_request.write_strobe != 4'b0011)))
                        bad_store_order <= 1'b1;
                    store_handshake_count <= store_handshake_count + 1;
                end else begin
                    load_handshake_count <= load_handshake_count + 1;
                    if (store_handshake_count < 2)
                        load_overtook_partial_store <= 1'b1;
                    assert (dmem_request.address == 32'h404)
                        else $fatal(1,
                            "full-covered Load incorrectly reached DMEM: %08h",
                            dmem_request.address);
                end
            end

            // 直接观察统一行为内存的 Core 外请求寄存级。
            if (dmem_stage_valid && u_memory.dmem_stage_request.is_store)
                external_store_stage_count <= external_store_stage_count + 1;

            if ((commit_fire[0] && (commit_bus.lane0.pc == 32'h0c))
                || (commit_fire[1] && (commit_bus.lane1.pc == 32'h0c)))
                x3_committed <= 1'b1;
            if ((commit_fire[0] && (commit_bus.lane0.pc == 32'h18))
                || (commit_fire[1] && (commit_bus.lane1.pc == 32'h18)))
                x5_committed <= 1'b1;
        end
    end

    initial begin
        integer cycles;
        clk = 1'b0;
        rst_n = 1'b0;
        dmem_gate = 1'b0;
        u_memory.clear_words(`NOP_INST);
        u_memory.write_word(32'h404, 32'haabb_ccdd);

        u_memory.write_word(32'h00, encode_addi(5'd1, 5'd0, 12'h400));
        u_memory.write_word(32'h04, encode_addi(5'd2, 5'd0, 42));
        u_memory.write_word(32'h08,
            encode_store(3'b010, 5'd1, 5'd2, 0));       // sw x2,0(x1)
        u_memory.write_word(32'h0c,
            encode_load(3'b010, 5'd3, 5'd1, 0));        // lw x3,0(x1)
        u_memory.write_word(32'h10, encode_addi(5'd4, 5'd0, 12'h678));
        u_memory.write_word(32'h14,
            encode_store(3'b001, 5'd1, 5'd4, 4));       // sh x4,4(x1)
        u_memory.write_word(32'h18,
            encode_load(3'b010, 5'd5, 5'd1, 4));        // lw x5,4(x1)
        u_memory.write_word(32'h1c, 32'h0051_8333);      // add x6,x3,x5

        repeat (3) tick();
        rst_n = 1'b1;
        tick();

        // DMEM 完全反压时，第一条 LW 仍必须由全覆盖老 Store 转发完成。
        wait_commit(32'h0c, "full-cover forwarded LW");
        assert (x3_committed && (committed_reg(5'd3) == 32'd42))
            else $fatal(1, "full-cover Store forwarding result mismatch");
        assert ((store_handshake_count == 0) && (load_handshake_count == 0)
                && core_dmem_valid && dmem_request.is_store)
            else $fatal(1, "forwarded Load unexpectedly accessed external DMEM");

        // SH 只覆盖目标 word 的低半部分，年轻 LW 不得部分转发。
        repeat (10) tick();
        assert (!x5_committed && (load_handshake_count == 0))
            else $fatal(1, "partially-covered LW forwarded or completed early");

        dmem_gate = 1'b1;
        wait_commit(32'h18, "partial-overlap LW after Store drain");
        wait_commit(32'h1c, "mixed-memory dependent ADD");
        cycles = 0;
        while ((external_store_stage_count < 2) && (cycles < 40)) begin
            tick();
            cycles = cycles + 1;
        end

        assert (!bad_store_order && !load_overtook_partial_store)
            else $fatal(1, "Store ordering or partial-overlap blocking failed");
        assert ((store_handshake_count == 2)
                && (external_store_stage_count == 2)
                && (load_handshake_count == 1))
            else $fatal(1,
                "DMEM transaction counts stores=%0d stages=%0d loads=%0d",
                store_handshake_count, external_store_stage_count,
                load_handshake_count);
        assert ((u_memory.mem[32'h400 >> 2] == 32'd42)
                && (u_memory.mem[32'h404 >> 2] == 32'haabb_0678))
            else $fatal(1, "Store drain memory image mismatch");
        assert ((committed_reg(5'd5) == 32'haabb_0678)
                && (committed_reg(5'd6) == 32'haabb_06a2))
            else $fatal(1, "mixed Load/Store architectural result mismatch");

        $display("PASS: Store forwarding + partial-overlap block + external drain");
        $finish;
    end

endmodule
