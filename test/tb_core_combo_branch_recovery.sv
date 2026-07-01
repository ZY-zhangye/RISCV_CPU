`timescale 1ns/1ps
`include "defines.svh"

module tb_core_combo_branch_recovery;
    import core_port_pkg::*;

    logic clk, rst_n;
    logic [31:0] imem_addr;
    logic imem_ren;
    logic [63:0] imem_rdata;
    logic dmem_request_valid, dmem_request_ready;
    lsq_mem_request_t dmem_request;
    lsq_mem_response_t dmem_response;
    recover_event_t recover;
    branch_update_t branch_update;
    rob_commit_bundle_t commit_bus;
    logic [1:0] commit_fire;
    logic signed [32:0] mul_operand_a, mul_operand_b;
    logic signed [65:0] mul_product;

    integer branch_update_count;
    integer loop_update_count;
    integer branch_recover_count;
    integer recover_to_08, recover_to_10, recover_to_20, recover_to_28;
    logic prediction_sequence_error;
    logic wrong_path_commit;
    logic wrong1c_pdst_valid, wrong24_pdst_valid;
    phys_reg_idx_t wrong1c_pdst, wrong24_pdst;
    logic wrong1c_wrote_back, wrong24_wrote_back;

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
        .recover_o(recover), .branch_update_o(branch_update),
        .fence_i_commit_o(), .commit_bus_o(commit_bus),
        .commit_fire_o(commit_fire), .core_idle_o()
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

    function automatic logic [31:0] encode_branch(
        input logic [2:0] funct3,
        input logic [4:0] rs1,
        input logic [4:0] rs2,
        input integer imm
    );
        logic [12:0] branch_imm;
        begin
            branch_imm = imm[12:0];
            encode_branch = {branch_imm[12], branch_imm[10:5], rs2, rs1,
                             funct3, branch_imm[4:1], branch_imm[11],
                             7'b1100011};
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

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            branch_update_count      <= 0;
            loop_update_count        <= 0;
            branch_recover_count     <= 0;
            recover_to_08            <= 0;
            recover_to_10            <= 0;
            recover_to_20            <= 0;
            recover_to_28            <= 0;
            prediction_sequence_error <= 1'b0;
            wrong_path_commit        <= 1'b0;
            wrong1c_pdst_valid       <= 1'b0;
            wrong24_pdst_valid       <= 1'b0;
            wrong1c_pdst             <= '0;
            wrong24_pdst             <= '0;
            wrong1c_wrote_back       <= 1'b0;
            wrong24_wrote_back       <= 1'b0;
        end else begin
            if (branch_update.valid) begin
                branch_update_count <= branch_update_count + 1;
                if (branch_update.pc == 32'h0c) begin
                    // BLT 的实际方向必须是 taken, taken, not-taken；中间
                    // 一次已经被首次训练为 taken，因此不得请求 redirect。
                    unique case (loop_update_count)
                        0: if (!branch_update.taken
                               || !dut.u_backend.bru_wb.redirect_valid)
                               prediction_sequence_error <= 1'b1;
                        1: if (!branch_update.taken
                               || dut.u_backend.bru_wb.redirect_valid)
                               prediction_sequence_error <= 1'b1;
                        2: if (branch_update.taken
                               || !dut.u_backend.bru_wb.redirect_valid)
                               prediction_sequence_error <= 1'b1;
                        default: prediction_sequence_error <= 1'b1;
                    endcase
                    loop_update_count <= loop_update_count + 1;
                end
            end

            if (recover.valid && (recover.reason == RECOVER_BRANCH)) begin
                branch_recover_count <= branch_recover_count + 1;
                unique case (recover.target)
                    32'h08: recover_to_08 <= recover_to_08 + 1;
                    32'h10: recover_to_10 <= recover_to_10 + 1;
                    32'h20: recover_to_20 <= recover_to_20 + 1;
                    32'h28: recover_to_28 <= recover_to_28 + 1;
                    default: prediction_sequence_error <= 1'b1;
                endcase
            end

            // 两条首次 taken BEQ 的 fall-through 指令会与分支一同进入
            // 后端。记录其 pdst，要求实际观察到写回但永不允许提交。
            if (dut.u_backend.rob_alloc_valid[0]
                && (dut.u_backend.rob_alloc_bus.lane0.pc == 32'h1c)) begin
                wrong1c_pdst <= dut.u_backend.rob_alloc_bus.lane0.pdst;
                wrong1c_pdst_valid <= 1'b1;
            end
            if (dut.u_backend.rob_alloc_valid[1]
                && (dut.u_backend.rob_alloc_bus.lane1.pc == 32'h1c)) begin
                wrong1c_pdst <= dut.u_backend.rob_alloc_bus.lane1.pdst;
                wrong1c_pdst_valid <= 1'b1;
            end
            if (dut.u_backend.rob_alloc_valid[0]
                && (dut.u_backend.rob_alloc_bus.lane0.pc == 32'h24)) begin
                wrong24_pdst <= dut.u_backend.rob_alloc_bus.lane0.pdst;
                wrong24_pdst_valid <= 1'b1;
            end
            if (dut.u_backend.rob_alloc_valid[1]
                && (dut.u_backend.rob_alloc_bus.lane1.pc == 32'h24)) begin
                wrong24_pdst <= dut.u_backend.rob_alloc_bus.lane1.pdst;
                wrong24_pdst_valid <= 1'b1;
            end

            if (wrong1c_pdst_valid && (recover_to_20 == 0)
                && ((dut.u_backend.wakeup_bus.lane0.valid
                     && (dut.u_backend.wakeup_bus.lane0.preg == wrong1c_pdst))
                    || (dut.u_backend.wakeup_bus.lane1.valid
                        && (dut.u_backend.wakeup_bus.lane1.preg == wrong1c_pdst))))
                wrong1c_wrote_back <= 1'b1;
            if (wrong24_pdst_valid && (recover_to_28 == 0)
                && ((dut.u_backend.wakeup_bus.lane0.valid
                     && (dut.u_backend.wakeup_bus.lane0.preg == wrong24_pdst))
                    || (dut.u_backend.wakeup_bus.lane1.valid
                        && (dut.u_backend.wakeup_bus.lane1.preg == wrong24_pdst))))
                wrong24_wrote_back <= 1'b1;

            if ((commit_fire[0]
                 && ((commit_bus.lane0.pc == 32'h1c)
                     || (commit_bus.lane0.pc == 32'h24)))
                || (commit_fire[1]
                    && ((commit_bus.lane1.pc == 32'h1c)
                        || (commit_bus.lane1.pc == 32'h24))))
                wrong_path_commit <= 1'b1;
        end
    end

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        u_memory.clear_words(`NOP_INST);

        u_memory.write_word(32'h00, encode_addi(5'd2, 5'd0, 3));
        u_memory.write_word(32'h04, encode_addi(5'd1, 5'd0, 0));
        u_memory.write_word(32'h08, encode_addi(5'd1, 5'd1, 1));
        u_memory.write_word(32'h0c,
            encode_branch(3'b100, 5'd1, 5'd2, -4)); // blt x1,x2,0x08

        // FENCE 阻止循环错误 fall-through 提前训练后续分支。
        u_memory.write_word(32'h10, 32'h0000_000f);
        u_memory.write_word(32'h14, encode_addi(5'd3, 5'd0, 55));
        u_memory.write_word(32'h18,
            encode_branch(3'b000, 5'd0, 5'd0, 8));  // beq -> 0x20
        u_memory.write_word(32'h1c, encode_addi(5'd3, 5'd0, 99));
        u_memory.write_word(32'h20,
            encode_branch(3'b000, 5'd0, 5'd0, 8));  // beq -> 0x28
        u_memory.write_word(32'h24, encode_addi(5'd3, 5'd0, 88));
        u_memory.write_word(32'h28, encode_addi(5'd4, 5'd3, 1));

        repeat (3) tick();
        rst_n = 1'b1;
        tick();
        wait_commit(32'h28, "post-recovery architectural instruction");
        repeat (6) tick();

        assert (!prediction_sequence_error
                && (branch_update_count == 5)
                && (loop_update_count == 3))
            else $fatal(1,
                "predictor update sequence failed updates=%0d loop=%0d",
                branch_update_count, loop_update_count);
        assert ((branch_recover_count == 4)
                && (recover_to_08 == 1) && (recover_to_10 == 1)
                && (recover_to_20 == 1) && (recover_to_28 == 1))
            else $fatal(1,
                "branch recovery sequence failed total=%0d targets=%0d/%0d/%0d/%0d",
                branch_recover_count, recover_to_08, recover_to_10,
                recover_to_20, recover_to_28);
        assert (wrong1c_pdst_valid && wrong24_pdst_valid
                && (wrong1c_wrote_back || wrong24_wrote_back)
                && !wrong_path_commit)
            else $fatal(1,
                "wrong-path isolation failed alloc=%0b/%0b wb=%0b/%0b commit=%0b",
                wrong1c_pdst_valid, wrong24_pdst_valid,
                wrong1c_wrote_back, wrong24_wrote_back, wrong_path_commit);
        assert ((committed_reg(5'd1) == 32'd3)
                && (committed_reg(5'd3) == 32'd55)
                && (committed_reg(5'd4) == 32'd56))
            else $fatal(1,
                "post-recovery state mismatch x1=%0d x3=%0d x4=%0d",
                committed_reg(5'd1), committed_reg(5'd3), committed_reg(5'd4));
        assert ((dut.u_backend.u_rename.u_rat_rrat.rat[1]
                 == dut.u_backend.u_rename.u_rat_rrat.rrat[1])
                && (dut.u_backend.u_rename.u_rat_rrat.rat[3]
                    == dut.u_backend.u_rename.u_rat_rrat.rrat[3])
                && (dut.u_backend.u_rename.u_rat_rrat.rat[4]
                    == dut.u_backend.u_rename.u_rat_rrat.rrat[4]))
            else $fatal(1, "RAT/RRAT mismatch after consecutive recoveries");

        $display("PASS: predictor training + consecutive recovery + wrong-path isolation");
        $finish;
    end

endmodule
