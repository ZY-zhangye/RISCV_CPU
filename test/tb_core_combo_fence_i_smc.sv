`timescale 1ns/1ps
`include "defines.svh"

module tb_core_combo_fence_i_smc;
    import core_port_pkg::*;

    localparam logic [31:0] OLD_INST = 32'h00b0_0193; // addi x3,x0,11
    localparam logic [31:0] NEW_INST = 32'h04d0_0193; // addi x3,x0,77

    logic clk, rst_n;
    logic [31:0] imem_addr;
    logic imem_ren;
    logic [63:0] imem_rdata;
    logic dmem_request_valid, dmem_request_ready;
    logic dmem_stage_valid;
    lsq_mem_request_t dmem_request;
    lsq_mem_response_t dmem_response;
    recover_event_t recover;
    logic fence_i_commit;
    rob_commit_bundle_t commit_bus;
    logic [1:0] commit_fire;
    logic signed [32:0] mul_operand_a, mul_operand_b;
    logic signed [65:0] mul_product;
    fs_ds_bundle_t fetch_bundle;

    logic saw_old_prefetch;
    logic saw_store_handshake;
    logic saw_store_external_stage;
    logic fence_before_store_visible;
    integer fence_i_pulse_count;
    integer fence_i_recover_count;
    integer target_commit_count;

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
        .recover_o(recover), .branch_update_o(),
        .fence_i_commit_o(fence_i_commit),
        .commit_bus_o(commit_bus), .commit_fire_o(commit_fire),
        .core_idle_o()
    );

    unified_memory_model #(.WORD_COUNT(1024)) u_memory (
        .clk(clk), .rst_n(rst_n),
        .imem_addr(imem_addr), .imem_ren(imem_ren), .imem_rdata(imem_rdata),
        .dmem_request_valid(dmem_request_valid), .dmem_request(dmem_request),
        .dmem_request_ready(dmem_request_ready), .dmem_response(dmem_response),
        .dmem_stage_valid_o(dmem_stage_valid)
    );

    always #5 clk = ~clk;
    assign mul_product = mul_operand_a * mul_operand_b;
    always_comb fetch_bundle = fs_ds_bundle_t'(dut.fs_to_ds_bus);

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

    function automatic logic [31:0] encode_store(
        input logic [4:0] rs1, input logic [4:0] rs2, input integer imm
    );
        logic [11:0] store_imm;
        begin
            store_imm = imm[11:0];
            encode_store = {store_imm[11:5], rs2, rs1, 3'b010,
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
            saw_old_prefetch           <= 1'b0;
            saw_store_handshake        <= 1'b0;
            saw_store_external_stage   <= 1'b0;
            fence_before_store_visible <= 1'b0;
            fence_i_pulse_count        <= 0;
            fence_i_recover_count      <= 0;
            target_commit_count        <= 0;
        end else begin
            if (dut.fs_to_ds_valid
                && (((fetch_bundle.lane0.pc == 32'h14)
                     && (fetch_bundle.lane0.inst == OLD_INST))
                    || ((fetch_bundle.lane1.pc == 32'h14)
                        && (fetch_bundle.lane1.inst == OLD_INST))))
                saw_old_prefetch <= 1'b1;

            if (dmem_request_valid && dmem_request_ready
                && dmem_request.is_store) begin
                saw_store_handshake <= 1'b1;
                assert ((dmem_request.address == 32'h14)
                        && (dmem_request.write_data == NEW_INST)
                        && (dmem_request.write_strobe == 4'b1111))
                    else $fatal(1, "self-modifying Store request mismatch");
            end
            if (dmem_stage_valid && u_memory.dmem_stage_request.is_store)
                saw_store_external_stage <= 1'b1;

            if (fence_i_commit) begin
                fence_i_pulse_count <= fence_i_pulse_count + 1;
                if (u_memory.mem[32'h14 >> 2] != NEW_INST)
                    fence_before_store_visible <= 1'b1;
            end
            if (recover.valid && (recover.reason == RECOVER_FENCE_I)) begin
                fence_i_recover_count <= fence_i_recover_count + 1;
                assert (recover.target == 32'h14)
                    else $fatal(1, "FENCE.I recovery target mismatch");
            end
            if ((commit_fire[0] && (commit_bus.lane0.pc == 32'h14))
                || (commit_fire[1] && (commit_bus.lane1.pc == 32'h14)))
                target_commit_count <= target_commit_count + 1;
        end
    end

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        u_memory.clear_words(`NOP_INST);

        u_memory.write_word(32'h00, encode_addi(5'd1, 5'd0, 32'h14));
        u_memory.write_word(32'h04, encode_lui(5'd2, NEW_INST[31:12]));
        u_memory.write_word(32'h08,
            encode_addi(5'd2, 5'd2, NEW_INST[11:0]));
        u_memory.write_word(32'h0c, encode_store(5'd1, 5'd2, 0));
        u_memory.write_word(32'h10, 32'h0000_100f); // fence.i
        u_memory.write_word(32'h14, OLD_INST);
        u_memory.write_word(32'h18, encode_addi(5'd4, 5'd3, 1));

        repeat (3) tick();
        rst_n = 1'b1;
        tick();
        wait_commit(32'h18, "instruction after self-modifying FENCE.I");
        repeat (8) tick();

        assert (saw_old_prefetch)
            else $fatal(1, "old target instruction was not prefetched");
        assert (saw_store_handshake && saw_store_external_stage)
            else $fatal(1, "self-modifying Store did not cross external stage");
        assert (!fence_before_store_visible)
            else $fatal(1, "FENCE.I committed before Store became visible");
        assert ((fence_i_pulse_count == 1) && (fence_i_recover_count == 1))
            else $fatal(1, "FENCE.I pulse/recovery count mismatch");
        assert (target_commit_count == 1)
            else $fatal(1, "stale/refetched target commit count=%0d",
                        target_commit_count);
        assert ((u_memory.mem[32'h14 >> 2] == NEW_INST)
                && (committed_reg(5'd3) == 32'd77)
                && (committed_reg(5'd4) == 32'd78))
            else $fatal(1,
                "self-modifying execution mismatch mem=%08h x3=%0d x4=%0d",
                u_memory.mem[32'h14 >> 2], committed_reg(5'd3),
                committed_reg(5'd4));
        assert ((dut.u_backend.u_rename.u_rat_rrat.rat[3]
                 == dut.u_backend.u_rename.u_rat_rrat.rrat[3])
                && (dut.u_backend.u_rename.u_rat_rrat.rat[4]
                    == dut.u_backend.u_rename.u_rat_rrat.rrat[4]))
            else $fatal(1, "Rename state mismatch after FENCE.I recovery");

        $display("PASS: self-modifying code + external Store stage + FENCE.I refetch");
        $finish;
    end

endmodule
