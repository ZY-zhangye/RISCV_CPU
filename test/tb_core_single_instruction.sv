`timescale 1ns/1ps
`include "defines.svh"

module tb_core_single_instruction;
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
    logic dmem_stage_valid;
    recover_event_t recover;
    branch_update_t branch_update;
    logic fence_i_commit;
    rob_commit_bundle_t commit_bus;
    logic [1:0] commit_fire;
    logic core_idle;
    logic mul_request_valid;
    logic signed [32:0] mul_operand_a;
    logic signed [32:0] mul_operand_b;
    logic signed [65:0] mul_product;
    logic div_result_ready;

    logic watch_active;
    logic watch_hit;
    logic [31:0] watch_pc;
    integer cycle_count;
    integer load_request_cycle;
    integer load_response_cycle;
    logic load_request_seen;
    logic load_response_seen;
    logic load_crossed_external_stage;

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
        .mul_request_valid_o(mul_request_valid),
        .mul_operand_a_o(mul_operand_a), .mul_operand_b_o(mul_operand_b),
        .mul_product_i(mul_product),
        .div_dividend_valid_o(), .div_dividend_ready_i(1'b1),
        .div_dividend_data_o(), .div_divisor_valid_o(),
        .div_divisor_ready_i(1'b1), .div_divisor_data_o(),
        .div_result_valid_i(1'b0), .div_result_ready_o(div_result_ready),
        .div_quotient_i('0), .div_remainder_i('0),
        .recover_o(recover), .branch_update_o(branch_update),
        .fence_i_commit_o(fence_i_commit), .commit_bus_o(commit_bus),
        .commit_fire_o(commit_fire), .core_idle_o(core_idle)
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
        .dmem_stage_valid_o(dmem_stage_valid)
    );

    always #5 clk = ~clk;
    assign mul_product = mul_operand_a * mul_operand_b;

    function automatic logic [31:0] committed_gp;
        logic [PHYS_REG_IDX_WIDTH-1:0] gp_preg;
        begin
            gp_preg = dut.u_backend.u_rename.u_rat_rrat.rrat[3];
            committed_gp = (gp_preg == '0)
                         ? '0 : dut.u_backend.u_prf.registers[gp_preg];
        end
    endfunction

    task automatic tick;
        @(posedge clk);
        #1;
    endtask

    task automatic prepare_case;
        begin
            rst_n = 1'b0;
            watch_active = 1'b0;
            watch_pc = '0;
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

    task automatic wait_for_commit(input logic [31:0] pc);
        integer wait_cycles;
        begin
            @(negedge clk);
            watch_pc = pc;
            watch_active = 1'b1;
            wait_cycles = 0;
            while (!watch_hit && (wait_cycles < 200)) begin
                tick();
                wait_cycles = wait_cycles + 1;
            end
            watch_active = 1'b0;
            assert (watch_hit)
                else $fatal(1, "timeout waiting for commit pc=%08h", pc);
        end
    endtask

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            watch_hit <= 1'b0;
            cycle_count <= 0;
            load_request_cycle <= -1;
            load_response_cycle <= -1;
            load_request_seen <= 1'b0;
            load_response_seen <= 1'b0;
            load_crossed_external_stage <= 1'b0;
        end else begin
            cycle_count <= cycle_count + 1;
            if (watch_active
                && ((commit_fire[0] && (commit_bus.lane0.pc == watch_pc))
                    || (commit_fire[1] && (commit_bus.lane1.pc == watch_pc))))
                watch_hit <= 1'b1;

            if (dmem_request_valid && dmem_request_ready
                && !dmem_request.is_store) begin
                load_request_seen  <= 1'b1;
                load_request_cycle <= cycle_count;
                assert (!dmem_response.valid)
                    else $fatal(1, "Load response bypassed external request register");
            end
            if (dmem_stage_valid && !dmem_response.valid)
                load_crossed_external_stage <= 1'b1;
            if (dmem_response.valid) begin
                load_response_seen  <= 1'b1;
                load_response_cycle <= cycle_count;
                assert (load_request_seen && (cycle_count > load_request_cycle))
                    else $fatal(1, "Load response returned without external cycle separation");
            end
        end
    end

    initial begin
        integer store_wait;
        clk = 1'b0;
        rst_n = 1'b0;
        watch_active = 1'b0;
        watch_pc = '0;

        // ADDI：单条目标指令直接写 gp。
        prepare_case();
        u_memory.write_word(32'h0000_0000, 32'h0250_0193); // addi x3,x0,37
        start_case();
        wait_for_commit(32'h0000_0000);
        assert (committed_gp() == 32'd37)
            else $fatal(1, "ADDI result mismatch: %08h", committed_gp());

        // ADD：两条初始化指令后，单独验证寄存器 ADD。
        prepare_case();
        u_memory.write_word(32'h0000_0000, 32'h0050_0093); // addi x1,x0,5
        u_memory.write_word(32'h0000_0004, 32'h0070_0113); // addi x2,x0,7
        u_memory.write_word(32'h0000_0008, 32'h0020_81b3); // add x3,x1,x2
        start_case();
        wait_for_commit(32'h0000_0008);
        assert (committed_gp() == 32'd12)
            else $fatal(1, "ADD result mismatch: %08h", committed_gp());

        // LW：数据预置于 0x400；请求必须先穿过 Core 外寄存级。
        prepare_case();
        u_memory.write_word(32'h0000_0000, 32'h4000_0093); // addi x1,x0,0x400
        u_memory.write_word(32'h0000_0004, 32'h0000_a183); // lw x3,0(x1)
        u_memory.write_word(32'h0000_0400, 32'h0000_002a);
        start_case();
        wait_for_commit(32'h0000_0004);
        assert (committed_gp() == 32'd42)
            else $fatal(1, "LW result mismatch: %08h", committed_gp());
        assert (load_request_seen && load_response_seen
                && load_crossed_external_stage
                && (load_response_cycle > load_request_cycle))
            else $fatal(1, "LW did not traverse the external DMEM register stage");

        // SW：提交后经同一外部寄存级写入统一内存。
        prepare_case();
        u_memory.write_word(32'h0000_0000, 32'h4000_0093); // addi x1,x0,0x400
        u_memory.write_word(32'h0000_0004, 32'h0370_0113); // addi x2,x0,55
        u_memory.write_word(32'h0000_0008, 32'h0020_a223); // sw x2,4(x1)
        start_case();
        wait_for_commit(32'h0000_0008);
        store_wait = 0;
        while ((u_memory.mem[257] != 32'd55) && (store_wait < 50)) begin
            tick();
            store_wait = store_wait + 1;
        end
        assert (u_memory.mem[257] == 32'd55)
            else $fatal(1, "SW data did not drain through external DMEM stage");

        $display("PASS: core single-instruction ADDI/ADD/LW/SW + external DMEM stage");
        $finish;
    end

endmodule
