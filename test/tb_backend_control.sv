`timescale 1ns/1ps
`include "defines.svh"

module tb_backend_control;
    import core_port_pkg::*;
    import id_decode_pkg::*;

    logic clk, rst_n, ds_valid, rn_allowin;
    ds_rn_bundle_t ds_bus;
    logic mem_valid, mem_ready;
    lsq_mem_request_t mem_req;
    lsq_mem_response_t mem_rsp;
    logic mul_valid;
    logic signed [32:0] mul_a, mul_b;
    logic signed [65:0] mul_product;
    logic div_result_ready;
    recover_event_t recover;
    branch_update_t branch_update;
    logic fence_i;
    rob_commit_bundle_t commit_bus;
    logic [1:0] commit_fire;
    logic backend_idle;
    integer csr_commits;
    integer branch_updates, branch_recovers;
    logic saw_branch_update, saw_branch_recover, saw_fence_i;
    logic saw_exception, saw_mret;

    backend_top #(.MTVEC_RESET(32'h0000_0100)) dut (
        .clk(clk), .rst_n(rst_n), .ds_to_rn_valid(ds_valid),
        .ds_to_rn_bus(ds_bus), .rn_allowin(rn_allowin),
        .mem_request_valid(mem_valid), .mem_request(mem_req),
        .mem_request_ready(mem_ready), .mem_response(mem_rsp),
        .irq_software_i(1'b0), .irq_timer_i(1'b0), .irq_external_i(1'b0),
        .mul_request_valid(mul_valid),
        .mul_operand_a(mul_a), .mul_operand_b(mul_b), .mul_product(mul_product),
        .div_dividend_valid(), .div_dividend_ready(1'b1), .div_dividend_data(),
        .div_divisor_valid(), .div_divisor_ready(1'b1), .div_divisor_data(),
        .div_result_valid(1'b0), .div_result_ready(div_result_ready),
        .div_quotient('0), .div_remainder('0), .recover_o(recover),
        .branch_update_o(branch_update), .fence_i_commit_o(fence_i),
        .commit_bus_o(commit_bus), .commit_fire_o(commit_fire),
        .backend_idle_o(backend_idle)
    );

    always #5 clk = ~clk;
    assign mul_product = mul_a * mul_b;

    function automatic ds_rn_slot_t decode_at(
        input logic [31:0] pc, input logic [31:0] inst,
        input logic pred_taken, input logic [31:0] pred_target
    );
        fs_ds_slot_t slot;
        begin
            slot = '{inst:inst, pc:pc, pred_taken:pred_taken,
                     pred_target:pred_target};
            decode_at = decode_instruction(slot, `EXC_NONE, '0);
        end
    endfunction

    task automatic tick;
        @(posedge clk); #1;
    endtask

    task automatic send2(
        input logic [31:0] pc0, input logic [31:0] inst0,
        input logic [31:0] pc1, input logic [31:0] inst1
    );
        begin
            while (!rn_allowin) tick();
            @(negedge clk); ds_bus = '0;
            ds_bus.lane0 = decode_at(pc0, inst0, 1'b0, '0);
            ds_bus.lane1 = decode_at(pc1, inst1, 1'b0, '0);
            ds_valid = 1'b1; tick(); ds_valid = 1'b0; ds_bus = '0;
        end
    endtask

    task automatic send1_pred(
        input logic [31:0] pc, input logic [31:0] inst,
        input logic pred_taken, input logic [31:0] pred_target
    );
        begin
            while (!rn_allowin) tick();
            @(negedge clk); ds_bus = '0;
            ds_bus.lane0 = decode_at(pc, inst, pred_taken, pred_target);
            ds_valid = 1'b1; tick(); ds_valid = 1'b0; ds_bus = '0;
        end
    endtask

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            csr_commits <= 0;
            branch_updates <= 0;
            branch_recovers <= 0;
            saw_branch_update <= 0;
            saw_branch_recover <= 0;
            saw_fence_i <= 0;
            saw_exception <= 0;
            saw_mret <= 0;
        end else begin
            if (branch_update.valid) begin
                saw_branch_update <= 1;
                branch_updates <= branch_updates + 1;
            end
            if (fence_i) saw_fence_i <= 1;
            if (commit_fire[0] && commit_bus.lane0.is_csr) csr_commits <= csr_commits + 1;
            if (commit_fire[1] && commit_bus.lane1.is_csr) csr_commits <= csr_commits + 1;
            if (recover.valid && recover.reason == RECOVER_BRANCH) begin
                branch_recovers <= branch_recovers + 1;
                if (recover.target == 32'h0000_2008)
                    saw_branch_recover <= 1;
            end
            if (recover.valid && recover.reason == RECOVER_EXCEPTION
                && recover.target == 32'h0000_0100)
                saw_exception <= 1;
            if (recover.valid && recover.reason == RECOVER_BRANCH
                && recover.target == 32'h0000_2300)
                saw_mret <= 1;
        end
    end

    initial begin
        integer n;
        clk = 0; rst_n = 0; ds_valid = 0; ds_bus = '0;
        mem_ready = 1; mem_rsp = '0;
        repeat (3) tick(); rst_n = 1; tick();

        // BEQ x0,x0,+8，故意预测 not-taken：训练在 WB1，恢复在 ROB 头。
        send1_pred(32'h2000, 32'h00000463, 1'b0, '0);
        n = 0; while (!saw_branch_recover && n < 80) begin tick(); n++; end
        assert (saw_branch_update && saw_branch_recover)
            else $fatal(1, "branch update/recovery integration failed");

        // 同一分支预测 taken 且目标正确：仍训练，但不得产生 recovery。
        send1_pred(32'h2010, 32'h00000463, 1'b1, 32'h2018);
        n = 0; while (branch_updates < 2 && n < 80) begin tick(); n++; end
        repeat (8) tick();
        assert ((branch_updates == 2) && (branch_recovers == 1))
            else $fatal(1, "correctly predicted branch update/recovery behavior failed");

        // Store 与 FENCE.I 同束；阻塞 DMEM 时 FENCE.I 不得提交。
        mem_ready = 0;
        send2(32'h2100, 32'h00002023, 32'h2104, 32'h0000100f);
        n = 0; while (!mem_valid && n < 80) begin tick(); n++; end
        assert (mem_valid) else $fatal(1, "committed store did not reach DMEM");
        repeat (8) tick();
        assert (!saw_fence_i) else $fatal(1, "FENCE.I committed with nonempty LSQ");
        mem_ready = 1;
        n = 0; while (!saw_fence_i && n < 40) begin tick(); n++; end
        assert (saw_fence_i) else $fatal(1, "FENCE.I pulse missing after LSQ drain");

        // 连续 CSR 可进入 Rename 缓冲，但 Dispatch 后端严格保持单项串行。
        send1_pred(32'h2200, 32'h340010f3, 1'b0, '0);
        send1_pred(32'h2204, 32'h34002173, 1'b0, '0);
        n = 0; while (csr_commits < 2 && n < 120) begin tick(); n++; end
        assert (csr_commits == 2) else $fatal(1, "serialized CSR sequence deadlocked");

        // 未实现 CSR 形成精确非法指令异常；随后 MRET 必须返回 mepc。
        send1_pred(32'h2300, 32'hfff01073, 1'b0, '0);
        n = 0; while (!saw_exception && n < 80) begin tick(); n++; end
        assert (saw_exception) else $fatal(1, "illegal CSR trap missing");
        send1_pred(32'h2400, 32'h30200073, 1'b0, '0);
        n = 0; while (!saw_mret && n < 80) begin tick(); n++; end
        assert (saw_mret) else $fatal(1, "MRET did not use trapped mepc");

        $display("PASS: branch training/recovery + serialized CSR/FENCE.I/trap/MRET");
        $finish;
    end
endmodule
