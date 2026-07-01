`timescale 1ns/1ps
`include "defines.svh"

module tb_core_combo_long_div;
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
    logic div_dividend_valid, div_dividend_ready;
    logic signed [32:0] div_dividend_data;
    logic div_divisor_valid, div_divisor_ready;
    logic signed [32:0] div_divisor_data;
    logic div_result_valid, div_result_ready;
    logic signed [32:0] div_quotient, div_remainder;

    logic have_dividend, have_divisor, div_pending;
    logic signed [32:0] dividend_reg, divisor_reg;
    logic collision_trigger;
    logic div_completed, div_committed;
    logic saw_early_alu_before_div;
    logic saw_branch_before_div;
    logic saw_wb0_conflict;
    logic saw_wb0_loser_held;
    logic younger_commit_violation;
    logic div_tag_valid, early_alu_tag_valid, branch_tag_valid;
    logic conflict_loser_pending, conflict_loser_is_alu;
    rob_tag_t div_tag, early_alu_tag, branch_tag, conflict_loser_tag;

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
        .div_dividend_valid_o(div_dividend_valid),
        .div_dividend_ready_i(div_dividend_ready),
        .div_dividend_data_o(div_dividend_data),
        .div_divisor_valid_o(div_divisor_valid),
        .div_divisor_ready_i(div_divisor_ready),
        .div_divisor_data_o(div_divisor_data),
        .div_result_valid_i(div_result_valid),
        .div_result_ready_o(div_result_ready),
        .div_quotient_i(div_quotient), .div_remainder_i(div_remainder),
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
    assign div_dividend_ready = !have_dividend && !div_pending;
    assign div_divisor_ready  = !have_divisor && !div_pending;

    // 等待第二批年轻 ALU 真正进入 ALU0 的输入寄存边界，再返回 DIV。
    // 该上升沿 ALU0 与 MLU 会同时生成结果，从而确定性制造 WB0 冲突。
    assign collision_trigger = div_pending
        && dut.u_backend.u_execute.operand0_valid
        && (dut.u_backend.u_execute.operand0_bus.issue.uop.dec.fu_type == FU_ALU)
        && (dut.u_backend.u_execute.operand0_bus.issue.uop.dec.pc >= 32'h18)
        && (dut.u_backend.u_execute.operand0_bus.issue.uop.dec.pc <= 32'h1c);
    assign div_result_valid = collision_trigger;

    always_ff @(posedge clk) begin : divider_model
        logic dividend_fire;
        logic divisor_fire;
        logic signed [32:0] dividend_now;
        logic signed [32:0] divisor_now;
        if (!rst_n) begin
            have_dividend <= 1'b0;
            have_divisor  <= 1'b0;
            div_pending   <= 1'b0;
            dividend_reg  <= '0;
            divisor_reg   <= '0;
            div_quotient  <= '0;
            div_remainder <= '0;
        end else begin
            dividend_fire = div_dividend_valid && div_dividend_ready;
            divisor_fire  = div_divisor_valid && div_divisor_ready;
            dividend_now  = dividend_fire ? div_dividend_data : dividend_reg;
            divisor_now   = divisor_fire ? div_divisor_data : divisor_reg;

            if (dividend_fire) begin
                dividend_reg  <= div_dividend_data;
                have_dividend <= 1'b1;
            end
            if (divisor_fire) begin
                divisor_reg  <= div_divisor_data;
                have_divisor <= 1'b1;
            end
            if (!div_pending
                && (have_dividend || dividend_fire)
                && (have_divisor || divisor_fire)) begin
                div_quotient  <= dividend_now / divisor_now;
                div_remainder <= dividend_now % divisor_now;
                have_dividend <= 1'b0;
                have_divisor  <= 1'b0;
                div_pending   <= 1'b1;
            end
            if (div_result_valid && div_result_ready)
                div_pending <= 1'b0;
        end
    end

    function automatic logic [31:0] encode_addi(
        input logic [4:0] rd, input logic [4:0] rs1, input integer imm
    );
        encode_addi = {imm[11:0], rs1, 3'b000, rd, 7'b0010011};
    endfunction

    function automatic logic [31:0] encode_div(
        input logic [4:0] rd, input logic [4:0] rs1, input logic [4:0] rs2
    );
        encode_div = {7'b0000001, rs2, rs1, 3'b100, rd, 7'b0110011};
    endfunction

    function automatic logic [31:0] encode_bne(
        input logic [4:0] rs1, input logic [4:0] rs2, input integer imm
    );
        logic [12:0] branch_imm;
        begin
            branch_imm = imm[12:0];
            encode_bne = {branch_imm[12], branch_imm[10:5], rs2, rs1,
                          3'b001, branch_imm[4:1], branch_imm[11],
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

    function automatic logic complete_has_tag(input rob_tag_t tag);
        complete_has_tag = (dut.u_backend.rob_complete.lane0.valid
                            && (dut.u_backend.rob_complete.lane0.tag == tag))
                         || (dut.u_backend.rob_complete.lane1.valid
                             && (dut.u_backend.rob_complete.lane1.tag == tag));
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

    always_ff @(posedge clk) begin
        logic div_commits_now;
        logic younger_commits_now;
        if (!rst_n) begin
            div_tag                  <= '0;
            early_alu_tag            <= '0;
            branch_tag               <= '0;
            conflict_loser_tag       <= '0;
            div_tag_valid            <= 1'b0;
            early_alu_tag_valid      <= 1'b0;
            branch_tag_valid         <= 1'b0;
            conflict_loser_pending   <= 1'b0;
            conflict_loser_is_alu    <= 1'b0;
            div_completed            <= 1'b0;
            div_committed            <= 1'b0;
            saw_early_alu_before_div <= 1'b0;
            saw_branch_before_div    <= 1'b0;
            saw_wb0_conflict         <= 1'b0;
            saw_wb0_loser_held       <= 1'b0;
            younger_commit_violation <= 1'b0;
        end else begin
            if (dut.u_backend.rob_alloc_valid[0]) begin
                unique case (dut.u_backend.rob_alloc_bus.lane0.pc)
                    32'h08: begin
                        div_tag <= dut.u_backend.rob_alloc_tag.lane0;
                        div_tag_valid <= 1'b1;
                    end
                    32'h10: begin
                        early_alu_tag <= dut.u_backend.rob_alloc_tag.lane0;
                        early_alu_tag_valid <= 1'b1;
                    end
                    32'h14: begin
                        branch_tag <= dut.u_backend.rob_alloc_tag.lane0;
                        branch_tag_valid <= 1'b1;
                    end
                    default: ;
                endcase
            end
            if (dut.u_backend.rob_alloc_valid[1]) begin
                unique case (dut.u_backend.rob_alloc_bus.lane1.pc)
                    32'h08: begin
                        div_tag <= dut.u_backend.rob_alloc_tag.lane1;
                        div_tag_valid <= 1'b1;
                    end
                    32'h10: begin
                        early_alu_tag <= dut.u_backend.rob_alloc_tag.lane1;
                        early_alu_tag_valid <= 1'b1;
                    end
                    32'h14: begin
                        branch_tag <= dut.u_backend.rob_alloc_tag.lane1;
                        branch_tag_valid <= 1'b1;
                    end
                    default: ;
                endcase
            end

            if (early_alu_tag_valid && complete_has_tag(early_alu_tag)
                && !div_completed)
                saw_early_alu_before_div <= 1'b1;
            if (branch_tag_valid && complete_has_tag(branch_tag)
                && !div_completed)
                saw_branch_before_div <= 1'b1;
            if (div_tag_valid && complete_has_tag(div_tag))
                div_completed <= 1'b1;

            if (dut.u_backend.alu0_wb_valid && dut.u_backend.mlu_wb_valid) begin
                saw_wb0_conflict <= 1'b1;
                assert (dut.u_backend.alu0_wb_ready
                        ^ dut.u_backend.mlu_wb_ready)
                    else $fatal(1, "WB0 conflict did not select exactly one source");
                conflict_loser_pending <= 1'b1;
                conflict_loser_is_alu <= !dut.u_backend.alu0_wb_ready;
                conflict_loser_tag <= dut.u_backend.alu0_wb_ready
                                    ? dut.u_backend.mlu_wb.rob_tag
                                    : dut.u_backend.alu0_wb.rob_tag;
            end
            if (conflict_loser_pending) begin
                assert (conflict_loser_is_alu ? dut.u_backend.alu0_wb_valid
                                              : dut.u_backend.mlu_wb_valid)
                    else $fatal(1, "WB0 losing source did not hold valid");
                if (complete_has_tag(conflict_loser_tag)) begin
                    saw_wb0_loser_held <= 1'b1;
                    conflict_loser_pending <= 1'b0;
                end
            end

            div_commits_now = (commit_fire[0] && (commit_bus.lane0.pc == 32'h08))
                           || (commit_fire[1] && (commit_bus.lane1.pc == 32'h08));
            younger_commits_now = (commit_fire[0]
                                    && (commit_bus.lane0.pc > 32'h08))
                                 || (commit_fire[1]
                                     && (commit_bus.lane1.pc > 32'h08));
            if (younger_commits_now && !div_committed && !div_commits_now)
                younger_commit_violation <= 1'b1;
            if (div_commits_now)
                div_committed <= 1'b1;
        end
    end

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        u_memory.clear_words(`NOP_INST);

        u_memory.write_word(32'h00, encode_addi(5'd1, 5'd0, 100));
        u_memory.write_word(32'h04, encode_addi(5'd2, 5'd0, 7));
        u_memory.write_word(32'h08, encode_div(5'd3, 5'd1, 5'd2));
        u_memory.write_word(32'h0c, `NOP_INST);
        u_memory.write_word(32'h10, encode_addi(5'd4, 5'd0, 9));
        u_memory.write_word(32'h14, encode_bne(5'd0, 5'd0, 8));
        u_memory.write_word(32'h18, encode_addi(5'd5, 5'd0, 11));
        u_memory.write_word(32'h1c, encode_addi(5'd6, 5'd0, 13));
        u_memory.write_word(32'h20, 32'h0051_83b3); // add x7,x3,x5

        repeat (3) tick();
        rst_n = 1'b1;
        tick();
        wait_commit(32'h20, "post-DIV dependent ADD");

        assert (saw_early_alu_before_div && saw_branch_before_div)
            else $fatal(1,
                "young ALU/branch did not complete before long DIV: alu=%0b bru=%0b",
                saw_early_alu_before_div, saw_branch_before_div);
        assert (saw_wb0_conflict && saw_wb0_loser_held)
            else $fatal(1, "WB0 conflict/held-result path was not observed");
        assert (!younger_commit_violation)
            else $fatal(1, "younger instruction committed before older DIV");
        assert ((committed_reg(5'd3) == 32'd14)
                && (committed_reg(5'd4) == 32'd9)
                && (committed_reg(5'd5) == 32'd11)
                && (committed_reg(5'd6) == 32'd13)
                && (committed_reg(5'd7) == 32'd25))
            else $fatal(1,
                "long-DIV architectural result mismatch x3=%0d x4=%0d x5=%0d x6=%0d x7=%0d",
                committed_reg(5'd3), committed_reg(5'd4), committed_reg(5'd5),
                committed_reg(5'd6), committed_reg(5'd7));

        $display("PASS: long DIV OoO completion + ordered commit + WB0 conflict hold");
        $finish;
    end

endmodule
