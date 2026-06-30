`timescale 1ns/1ps
`include "defines.svh"

module tb_execute_stage;
    import core_port_pkg::*;

    localparam int MUL_LATENCY = 3;

    logic clk;
    logic rst_n;
    recover_event_t recover;
    logic issue0_valid;
    iq_issue_slot_t issue0_bus;
    logic issue0_ready;
    logic issue1_valid;
    issue1_slot_t issue1_bus;
    logic issue1_ready;
    phys_reg_read_data_bundle_t prf_read_data;
    logic alu0_available, mlu_available, alu1_available;
    logic bru_available, csr_available, lsu_available;
    logic alu0_wb_valid, mlu_wb_valid, alu1_wb_valid;
    logic bru_wb_valid, csr_wb_valid;
    execute_writeback_t alu0_wb, mlu_wb, alu1_wb, bru_wb, csr_wb;
    csr_execute_update_t csr_update;
    lsq_agu_result_t lsu_agu_result;
    csr_read_request_t csr_read_request;
    csr_read_response_t csr_read_response;
    logic mul_request_valid;
    logic signed [32:0] mul_operand_a, mul_operand_b;
    logic signed [65:0] mul_product;
    logic div_dividend_valid, div_dividend_ready;
    logic signed [32:0] div_dividend_data;
    logic div_divisor_valid, div_divisor_ready;
    logic signed [32:0] div_divisor_data;
    logic div_result_valid, div_result_ready;
    logic signed [32:0] div_quotient, div_remainder;
    integer wait_cycles;

    execute_stage #(.MUL_LATENCY(MUL_LATENCY)) dut (
        .clk(clk), .rst_n(rst_n), .recover(recover),
        .issue0_valid(issue0_valid), .issue0_bus(issue0_bus),
        .issue0_ready(issue0_ready),
        .issue1_valid(issue1_valid), .issue1_bus(issue1_bus),
        .issue1_ready(issue1_ready), .prf_read_data(prf_read_data),
        .alu0_available(alu0_available), .mlu_available(mlu_available),
        .alu1_available(alu1_available), .bru_available(bru_available),
        .csr_available(csr_available), .lsu_available(lsu_available),
        .alu0_wb_valid(alu0_wb_valid), .alu0_wb(alu0_wb),
        .alu0_wb_ready(1'b1),
        .mlu_wb_valid(mlu_wb_valid), .mlu_wb(mlu_wb),
        .mlu_wb_ready(1'b1),
        .alu1_wb_valid(alu1_wb_valid), .alu1_wb(alu1_wb),
        .alu1_wb_ready(1'b1),
        .bru_wb_valid(bru_wb_valid), .bru_wb(bru_wb),
        .bru_wb_ready(1'b1),
        .csr_wb_valid(csr_wb_valid), .csr_wb(csr_wb),
        .csr_update(csr_update), .csr_wb_ready(1'b1),
        .lsu_agu_result(lsu_agu_result),
        .csr_commit_available(1'b1),
        .csr_read_request(csr_read_request),
        .csr_read_response(csr_read_response),
        .mul_request_valid(mul_request_valid),
        .mul_operand_a(mul_operand_a), .mul_operand_b(mul_operand_b),
        .mul_product(mul_product),
        .div_dividend_valid(div_dividend_valid),
        .div_dividend_ready(div_dividend_ready),
        .div_dividend_data(div_dividend_data),
        .div_divisor_valid(div_divisor_valid),
        .div_divisor_ready(div_divisor_ready),
        .div_divisor_data(div_divisor_data),
        .div_result_valid(div_result_valid),
        .div_result_ready(div_result_ready),
        .div_quotient(div_quotient), .div_remainder(div_remainder)
    );

    always #5 clk = ~clk;
    always_comb mul_product = mul_operand_a * mul_operand_b;

    // CSR 文件一拍时序读模型。
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            csr_read_response <= '0;
        end else begin
            csr_read_response.valid <= csr_read_request.valid;
            if (csr_read_request.valid) begin
                csr_read_response.data <= (csr_read_request.addr == 12'h301)
                                        ? 32'h4000_1100 : 32'h0000_0010;
                csr_read_response.implemented <= (csr_read_request.addr != 12'h7ff);
                csr_read_response.writable <= (csr_read_request.addr != 12'h301)
                                           && (csr_read_request.addr != 12'h7ff);
            end
        end
    end

    task automatic cycle;
        @(posedge clk);
        #1;
    endtask

    task automatic clear_issue;
        issue0_valid = 1'b0;
        issue1_valid = 1'b0;
        issue0_bus   = '0;
        issue1_bus   = '0;
    endtask

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        recover = '0;
        clear_issue();
        prf_read_data = '0;
        div_dividend_ready = 1'b1;
        div_divisor_ready  = 1'b1;
        div_result_valid = 1'b0;
        div_quotient = '0;
        div_remainder = '0;

        repeat (2) cycle();
        rst_n = 1'b1;

        // ALU0：同步 PRF 读值对齐。
        issue0_bus = '0;
        issue0_bus.rob_tag = rob_tag_t'(1);
        issue0_bus.uop.dec.fu_type = FU_ALU;
        issue0_bus.uop.dec.alu_op = ALU_ADD;
        issue0_bus.uop.dec.use_rs1 = 1'b1;
        issue0_bus.uop.dec.use_rs2 = 1'b1;
        issue0_bus.uop.pdst_valid = 1'b1;
        issue0_bus.uop.pdst = phys_reg_idx_t'(7);
        prf_read_data.port0 = 32'd10;
        prf_read_data.port1 = 32'd20;
        issue0_valid = 1'b1;
        cycle();
        issue0_valid = 1'b0;
        cycle();
        assert (alu0_wb_valid && (alu0_wb.data == 32'd30)
                && (alu0_wb.pdst == phys_reg_idx_t'(7)))
            else $fatal(1, "ALU0 add/operand alignment failed");
        cycle();

        // 广播旁路必须优先于 PRF 旧值。
        issue0_bus = '0;
        issue0_bus.rob_tag = rob_tag_t'(2);
        issue0_bus.uop.dec.fu_type = FU_ALU;
        issue0_bus.uop.dec.alu_op = ALU_XOR;
        issue0_bus.uop.dec.use_rs1 = 1'b1;
        issue0_bus.uop.dec.src2_is_imm = 1'b1;
        issue0_bus.uop.dec.imm = 32'h00ff_00ff;
        issue0_bus.src1_bypass_valid = 1'b1;
        issue0_bus.src1_bypass_data = 32'h1234_5678;
        prf_read_data.port0 = 32'hdead_beef;
        issue0_valid = 1'b1;
        cycle();
        issue0_valid = 1'b0;
        cycle();
        assert (alu0_wb_valid
                && (alu0_wb.data == (32'h1234_5678 ^ 32'h00ff_00ff)))
            else $fatal(1, "operand bypass priority failed");
        cycle();

        // BRU：taken BEQ 的预测失误和真实目标。
        issue1_bus = '0;
        issue1_bus.rob_tag = rob_tag_t'(3);
        issue1_bus.uop.dec.fu_type = FU_BRU;
        issue1_bus.uop.dec.branch_op = BR_BEQ;
        issue1_bus.uop.dec.pc = 32'h0000_0100;
        issue1_bus.uop.dec.imm = 32'd16;
        issue1_bus.uop.dec.use_rs1 = 1'b1;
        issue1_bus.uop.dec.use_rs2 = 1'b1;
        issue1_bus.uop.dec.pred_taken = 1'b0;
        prf_read_data.port2 = 32'h55aa_55aa;
        prf_read_data.port3 = 32'h55aa_55aa;
        issue1_valid = 1'b1;
        cycle();
        issue1_valid = 1'b0;
        cycle();
        assert (bru_wb_valid && bru_wb.redirect_valid
                && (bru_wb.redirect_target == 32'h0000_0110)
                && (bru_wb.data == 32'h0000_0104))
            else $fatal(1, "BRU redirect/link result failed");
        cycle();

        // CSRRSI：rd 取得旧值，新值只作为精确提交更新包输出。
        issue1_bus = '0;
        issue1_bus.rob_tag = rob_tag_t'(4);
        issue1_bus.uop.dec.fu_type = FU_CSR;
        issue1_bus.uop.dec.csr_op = CSR_SET;
        issue1_bus.uop.dec.csr_use_imm = 1'b1;
        issue1_bus.uop.dec.csr_addr = 12'h300;
        issue1_bus.uop.dec.imm = 32'h3;
        issue1_bus.uop.pdst_valid = 1'b1;
        issue1_bus.uop.pdst = phys_reg_idx_t'(9);
        issue1_valid = 1'b1;
        cycle();
        issue1_valid = 1'b0;
        cycle();
        cycle();
        assert (csr_wb_valid && (csr_wb.data == 32'h10)
                && csr_update.valid && csr_update.write_enable
                && (csr_update.addr == 12'h300)
                && (csr_update.write_data == 32'h13))
            else $fatal(1, "CSR execute/update calculation failed");
        cycle();

        // CSRRW 尝试写只读 misa 必须成为精确 illegal instruction，不能
        // 写 rd，也不能进入 CSR 提交缓存。
        issue1_bus = '0;
        issue1_bus.rob_tag = rob_tag_t'(14);
        issue1_bus.uop.dec.fu_type = FU_CSR;
        issue1_bus.uop.dec.csr_op = CSR_WRITE;
        issue1_bus.uop.dec.csr_addr = 12'h301;
        issue1_bus.uop.dec.inst = 32'h3010_9073;
        issue1_bus.uop.dec.use_rs1 = 1'b1;
        issue1_bus.uop.pdst_valid = 1'b1;
        issue1_bus.uop.pdst = phys_reg_idx_t'(11);
        prf_read_data.port2 = 32'hffff_ffff;
        issue1_valid = 1'b1;
        cycle();
        issue1_valid = 1'b0;
        cycle();
        cycle();
        assert (csr_wb_valid && csr_wb.exception_valid
                && (csr_wb.exc_code == `EXC_ILLEGAL_INST)
                && !csr_wb.pdst_valid && !csr_update.valid)
            else $fatal(1, "read-only CSR write was not trapped precisely");
        cycle();

        // LSU：AGU 组合返回，Store data 与地址一同送回 LSQ。
        issue1_bus = '0;
        issue1_bus.from_lsq = 1'b1;
        issue1_bus.lsq_tag = lsq_tag_t'(5);
        issue1_bus.rob_tag = rob_tag_t'(5);
        issue1_bus.read_store_data = 1'b1;
        issue1_bus.uop.dec.fu_type = FU_LSU;
        issue1_bus.uop.dec.mem_write = 1'b1;
        issue1_bus.uop.dec.use_rs1 = 1'b1;
        issue1_bus.uop.dec.use_rs2 = 1'b1;
        issue1_bus.uop.dec.imm = 32'h20;
        prf_read_data.port2 = 32'h0000_1000;
        prf_read_data.port3 = 32'hcafe_babe;
        issue1_valid = 1'b1;
        cycle();
        issue1_valid = 1'b0;
        assert (lsu_agu_result.valid
                && (lsu_agu_result.lsq_tag == lsq_tag_t'(5))
                && (lsu_agu_result.address == 32'h0000_1020)
                && lsu_agu_result.store_data_valid
                && (lsu_agu_result.store_data == 32'hcafe_babe))
            else $fatal(1, "LSU AGU/store data result failed");
        cycle();

        // MLU fixed-latency multiplier：-2 * 3 的高 32 位应为全 1。
        issue0_bus = '0;
        issue0_bus.rob_tag = rob_tag_t'(6);
        issue0_bus.uop.dec.fu_type = FU_MLU;
        issue0_bus.uop.dec.mlu_op = MLU_MULH;
        issue0_bus.uop.dec.use_rs1 = 1'b1;
        issue0_bus.uop.dec.use_rs2 = 1'b1;
        issue0_bus.uop.pdst_valid = 1'b1;
        issue0_bus.uop.pdst = phys_reg_idx_t'(10);
        prf_read_data.port0 = 32'hffff_fffe;
        prf_read_data.port1 = 32'd3;
        issue0_valid = 1'b1;
        cycle();
        issue0_valid = 1'b0;
        cycle();
        assert (mul_request_valid == 1'b0)
            else $fatal(1, "multiplier request must be a one-cycle pulse");
        wait_cycles = 0;
        while (!mlu_wb_valid && (wait_cycles < 8)) begin
            cycle();
            wait_cycles = wait_cycles + 1;
        end
        assert (mlu_wb_valid && (mlu_wb.data == 32'hffff_ffff))
            else $fatal(1, "fixed-latency MULH result failed");
        cycle();

        // Divider 双输入独立握手：先接 divisor，后接 dividend。
        issue0_bus = '0;
        issue0_bus.rob_tag = rob_tag_t'(7);
        issue0_bus.uop.dec.fu_type = FU_MLU;
        issue0_bus.uop.dec.mlu_op = MLU_DIV;
        issue0_bus.uop.dec.use_rs1 = 1'b1;
        issue0_bus.uop.dec.use_rs2 = 1'b1;
        prf_read_data.port0 = 32'd20;
        prf_read_data.port1 = 32'd3;
        div_dividend_ready = 1'b0;
        div_divisor_ready  = 1'b1;
        issue0_valid = 1'b1;
        cycle();
        issue0_valid = 1'b0;
        cycle();
        assert (div_dividend_valid && div_divisor_valid)
            else $fatal(1, "divider input valids not asserted");
        cycle();
        assert (div_dividend_valid && !div_divisor_valid)
            else $fatal(1, "divider independent input handshake failed");
        div_dividend_ready = 1'b1;
        cycle();
        assert (div_result_ready)
            else $fatal(1, "divider did not enter result wait state");
        div_quotient = 33'sd6;
        div_remainder = 33'sd2;
        div_result_valid = 1'b1;
        cycle();
        div_result_valid = 1'b0;
        assert (mlu_wb_valid && (mlu_wb.data == 32'd6))
            else $fatal(1, "divider result handshake failed");
        cycle();

        // RISC-V 除零语义由本地快速路径完成。
        issue0_bus = '0;
        issue0_bus.rob_tag = rob_tag_t'(8);
        issue0_bus.uop.dec.fu_type = FU_MLU;
        issue0_bus.uop.dec.mlu_op = MLU_DIVU;
        issue0_bus.uop.dec.use_rs1 = 1'b1;
        issue0_bus.uop.dec.use_rs2 = 1'b1;
        prf_read_data.port0 = 32'h1234_5678;
        prf_read_data.port1 = '0;
        issue0_valid = 1'b1;
        cycle();
        issue0_valid = 1'b0;
        cycle();
        assert (mlu_wb_valid && (mlu_wb.data == 32'hffff_ffff))
            else $fatal(1, "RISC-V divide-by-zero result failed");
        cycle();

        // recovery 发生在 Divider 只接收 divisor 后：MLU 必须继续发送
        // dividend 并排空旧结果，期间不能把旧结果写回或接收新操作。
        issue0_bus = '0;
        issue0_bus.rob_tag = rob_tag_t'(9);
        issue0_bus.uop.dec.fu_type = FU_MLU;
        issue0_bus.uop.dec.mlu_op = MLU_REMU;
        issue0_bus.uop.dec.use_rs1 = 1'b1;
        issue0_bus.uop.dec.use_rs2 = 1'b1;
        prf_read_data.port0 = 32'd21;
        prf_read_data.port1 = 32'd4;
        div_dividend_ready = 1'b0;
        div_divisor_ready  = 1'b1;
        issue0_valid = 1'b1;
        cycle();
        issue0_valid = 1'b0;
        cycle();
        cycle();
        assert (div_dividend_valid && !div_divisor_valid)
            else $fatal(1, "recovery test did not reach half-sent divide");
        recover.valid  = 1'b1;
        recover.reason = RECOVER_BRANCH;
        cycle();
        recover = '0;
        assert (!mlu_available && div_dividend_valid)
            else $fatal(1, "killed divide was not retained for safe drain");
        div_dividend_ready = 1'b1;
        cycle();
        div_quotient = 33'sd5;
        div_remainder = 33'sd1;
        div_result_valid = 1'b1;
        cycle();
        div_result_valid = 1'b0;
        assert (!mlu_wb_valid && mlu_available)
            else $fatal(1, "killed divider result was not discarded safely");

        $display("PASS: operand select + ALU/MLU/BRU/LSU/CSR execute stage");
        $finish;
    end

endmodule
