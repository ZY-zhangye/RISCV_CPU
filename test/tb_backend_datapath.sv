`timescale 1ns/1ps
`include "defines.svh"

module tb_backend_datapath;
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
    logic div_dvd_valid, div_dvs_valid, div_result_valid, div_result_ready;
    logic signed [32:0] div_dvd, div_dvs, div_q, div_r;
    recover_event_t recover;
    branch_update_t branch_update;
    logic fence_i;
    rob_commit_bundle_t commit_bus;
    logic [1:0] commit_fire;
    logic backend_idle;
    integer div_count;
    integer cycles;
    logic younger_completed_first;
    logic saw_div_complete;
    logic saw_store_request;
    logic saw_load_42;

    backend_top dut (
        .clk(clk), .rst_n(rst_n), .ds_to_rn_valid(ds_valid),
        .ds_to_rn_bus(ds_bus), .rn_allowin(rn_allowin),
        .mem_request_valid(mem_valid), .mem_request(mem_req),
        .mem_request_ready(mem_ready), .mem_response(mem_rsp),
        .irq_software_i(1'b0), .irq_timer_i(1'b0), .irq_external_i(1'b0),
        .mul_request_valid(mul_valid),
        .mul_operand_a(mul_a), .mul_operand_b(mul_b), .mul_product(mul_product),
        .div_dividend_valid(div_dvd_valid), .div_dividend_ready(1'b1),
        .div_dividend_data(div_dvd), .div_divisor_valid(div_dvs_valid),
        .div_divisor_ready(1'b1), .div_divisor_data(div_dvs),
        .div_result_valid(div_result_valid), .div_result_ready(div_result_ready),
        .div_quotient(div_q), .div_remainder(div_r), .recover_o(recover),
        .branch_update_o(branch_update), .fence_i_commit_o(fence_i),
        .commit_bus_o(commit_bus), .commit_fire_o(commit_fire),
        .backend_idle_o(backend_idle)
    );

    always #5 clk = ~clk;
    assign mul_product = mul_a * mul_b;

    function automatic ds_rn_slot_t decode_at(
        input logic [31:0] pc, input logic [31:0] inst
    );
        fs_ds_slot_t slot;
        begin
            slot = '{inst:inst, pc:pc, pred_taken:1'b0, pred_target:'0};
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
            @(negedge clk);
            ds_bus = '0;
            ds_bus.lane0 = decode_at(pc0, inst0);
            ds_bus.lane1 = decode_at(pc1, inst1);
            ds_valid = 1'b1;
            tick();
            ds_valid = 1'b0;
            ds_bus = '0;
        end
    endtask

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            div_count <= 0;
            div_result_valid <= 1'b0;
            div_q <= '0;
            div_r <= '0;
        end else begin
            if (div_result_valid && div_result_ready)
                div_result_valid <= 1'b0;
            if (div_count != 0) begin
                div_count <= div_count - 1;
                if (div_count == 1)
                    div_result_valid <= 1'b1;
            end
            if (div_dvd_valid && div_dvs_valid) begin
                div_q <= $signed(div_dvd) / $signed(div_dvs);
                div_r <= $signed(div_dvd) % $signed(div_dvs);
                div_count <= 8;
            end
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            younger_completed_first <= 1'b0;
            saw_div_complete <= 1'b0;
            saw_store_request <= 1'b0;
            saw_load_42 <= 1'b0;
        end else begin
            // 第三条 DIV tag=2，第四条年轻 ADDI tag=3。
            if ((dut.rob_complete.lane0.valid && dut.rob_complete.lane0.tag == 6'd2)
                || (dut.rob_complete.lane1.valid && dut.rob_complete.lane1.tag == 6'd2))
                saw_div_complete <= 1'b1;
            if ((dut.rob_complete.lane0.valid && dut.rob_complete.lane0.tag == 6'd3)
                || (dut.rob_complete.lane1.valid && dut.rob_complete.lane1.tag == 6'd3))
                younger_completed_first <= !saw_div_complete;
            if (mem_valid && mem_ready && mem_req.is_store) begin
                saw_store_request <= 1'b1;
                assert (mem_req.write_data == 32'd42)
                    else $fatal(1, "store data did not cross PRF/LSQ path");
            end
            if (commit_fire[0] && commit_bus.lane0.rd == 5'd3
                && dut.u_prf.registers[commit_bus.lane0.pdst] == 32'd42)
                saw_load_42 <= 1'b1;
            if (commit_fire[1] && commit_bus.lane1.rd == 5'd3
                && dut.u_prf.registers[commit_bus.lane1.pdst] == 32'd42)
                saw_load_42 <= 1'b1;
        end
    end

    initial begin
        clk = 0; rst_n = 0; ds_valid = 0; ds_bus = '0;
        mem_ready = 1; mem_rsp = '0; cycles = 0;
        repeat (3) tick(); rst_n = 1; tick();

        // x1=5, x2=x1+3：同束 RAW；随后 DIV 与年轻 ADDI 验证越序完成。
        send2(32'h1000, 32'h00500093, 32'h1004, 32'h00308113);
        send2(32'h1008, 32'h021141b3, 32'h100c, 32'h00900213);

        while (backend_idle && cycles < 20) begin tick(); cycles++; end
        while (!backend_idle && cycles < 200) begin tick(); cycles++; end
        assert (cycles < 200) else $fatal(1, "backend did not drain DIV sequence");
        assert (younger_completed_first)
            else $fatal(1, "younger ALU did not complete ahead of long DIV");

        // x1=16, x2=42；Store 后的 Load 必须可由老 Store 全覆盖转发。
        send2(32'h1100, 32'h01000093, 32'h1104, 32'h02a00113);
        send2(32'h1108, 32'h0020a023, 32'h110c, 32'h0000a183);
        cycles = 0;
        while (backend_idle && cycles < 20) begin tick(); cycles++; end
        while (!backend_idle && cycles < 200) begin tick(); cycles++; end
        assert (cycles < 200) else $fatal(1, "backend did not drain LSQ sequence");
        assert (saw_store_request) else $fatal(1, "committed store was not drained");
        assert (saw_load_42) else $fatal(1, "load did not receive forwarded store data");
        $display("PASS: backend RAW/WAW + OoO DIV + LSQ forwarding/drain integration");
        $finish;
    end
endmodule
