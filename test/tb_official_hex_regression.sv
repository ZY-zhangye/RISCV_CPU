`timescale 1ns/1ps
`include "defines.svh"

// Core 级官方 HEX 回归平台。通过 +HEX=<path> 载入镜像，使用
// +MAX_CYCLES=<n> 调整超时，+TRACE 打印提交/恢复/访存轨迹。
module tb_official_hex_regression;
    import core_port_pkg::*;

    localparam int          MUL_LATENCY = 3;
    localparam int          DIV_LATENCY = 8;
    localparam logic [31:0] RESET_PC    = 32'h8000_0000;
    localparam logic [31:0] END_PC      = 32'h8000_0044;
    localparam int          MEMORY_WORDS = 4096;

    logic clk;
    logic rst_n;
    logic [31:0] imem_addr;
    logic imem_ren;
    logic [63:0] imem_rdata;
    logic dmem_request_valid;
    logic dmem_request_ready;
    lsq_mem_request_t dmem_request;
    lsq_mem_response_t dmem_response;
    recover_event_t recover;
    branch_update_t branch_update;
    rob_commit_bundle_t commit_bus;
    logic [1:0] commit_fire;
    logic fence_i_commit;
    logic core_idle;

    logic mul_request_valid;
    logic signed [32:0] mul_operand_a;
    logic signed [32:0] mul_operand_b;
    logic signed [65:0] mul_product;

    logic div_dividend_valid;
    logic div_dividend_ready;
    logic signed [32:0] div_dividend_data;
    logic div_divisor_valid;
    logic div_divisor_ready;
    logic signed [32:0] div_divisor_data;
    logic div_result_valid;
    logic div_result_ready;
    logic signed [32:0] div_quotient;
    logic signed [32:0] div_remainder;
    logic div_have_dividend;
    logic div_have_divisor;
    logic div_busy;
    logic signed [32:0] div_dividend_reg;
    logic signed [32:0] div_divisor_reg;
    integer div_count;

    integer cycles;
    integer max_cycles;
    logic trace_enabled;
    string hex_file;
    string test_name;
    logic [31:0] last_commit_pc;

    core_top #(
        .MUL_LATENCY(MUL_LATENCY),
        .RESET_PC(RESET_PC)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .imem_addr_o(imem_addr),
        .imem_ren_o(imem_ren),
        .imem_rdata_i(imem_rdata),
        .dmem_request_valid_o(dmem_request_valid),
        .dmem_request_o(dmem_request),
        .dmem_request_ready_i(dmem_request_ready),
        .dmem_response_i(dmem_response),
        .irq_software_i(1'b0),
        .irq_timer_i(1'b0),
        .irq_external_i(1'b0),
        .mul_request_valid_o(mul_request_valid),
        .mul_operand_a_o(mul_operand_a),
        .mul_operand_b_o(mul_operand_b),
        .mul_product_i(mul_product),
        .div_dividend_valid_o(div_dividend_valid),
        .div_dividend_ready_i(div_dividend_ready),
        .div_dividend_data_o(div_dividend_data),
        .div_divisor_valid_o(div_divisor_valid),
        .div_divisor_ready_i(div_divisor_ready),
        .div_divisor_data_o(div_divisor_data),
        .div_result_valid_i(div_result_valid),
        .div_result_ready_o(div_result_ready),
        .div_quotient_i(div_quotient),
        .div_remainder_i(div_remainder),
        .recover_o(recover),
        .branch_update_o(branch_update),
        .fence_i_commit_o(fence_i_commit),
        .commit_bus_o(commit_bus),
        .commit_fire_o(commit_fire),
        .core_idle_o(core_idle)
    );

    unified_memory_model #(
        .BASE_ADDR(RESET_PC),
        .WORD_COUNT(MEMORY_WORDS)
    ) u_memory (
        .clk(clk),
        .rst_n(rst_n),
        .imem_addr(imem_addr),
        .imem_ren(imem_ren),
        .imem_rdata(imem_rdata),
        .dmem_request_valid(dmem_request_valid),
        .dmem_request(dmem_request),
        .dmem_request_ready(dmem_request_ready),
        .dmem_response(dmem_response),
        .dmem_stage_valid_o()
    );

    always #5 clk = ~clk;

    // 固定延迟乘法器模型。MLU 在 MUL_LATENCY 到期时采样该结果。
    always_ff @(posedge clk) begin
        if (!rst_n)
            mul_product <= '0;
        else if (mul_request_valid)
            mul_product <= mul_operand_a * mul_operand_b;
    end

    // 双输入 ready/valid Divider Generator 行为模型。
    assign div_dividend_ready = !div_busy && !div_result_valid
                              && !div_have_dividend;
    assign div_divisor_ready  = !div_busy && !div_result_valid
                              && !div_have_divisor;

    always_ff @(posedge clk) begin : divider_model
        logic dividend_fire;
        logic divisor_fire;
        logic signed [32:0] dividend_now;
        logic signed [32:0] divisor_now;

        if (!rst_n) begin
            div_have_dividend <= 1'b0;
            div_have_divisor  <= 1'b0;
            div_busy          <= 1'b0;
            div_dividend_reg  <= '0;
            div_divisor_reg   <= '0;
            div_count         <= 0;
            div_result_valid  <= 1'b0;
            div_quotient      <= '0;
            div_remainder     <= '0;
        end else begin
            dividend_fire = div_dividend_valid && div_dividend_ready;
            divisor_fire  = div_divisor_valid && div_divisor_ready;
            dividend_now  = dividend_fire ? div_dividend_data
                                          : div_dividend_reg;
            divisor_now   = divisor_fire ? div_divisor_data
                                         : div_divisor_reg;

            if (div_result_valid && div_result_ready)
                div_result_valid <= 1'b0;

            if (dividend_fire) begin
                div_dividend_reg  <= div_dividend_data;
                div_have_dividend <= 1'b1;
            end
            if (divisor_fire) begin
                div_divisor_reg  <= div_divisor_data;
                div_have_divisor <= 1'b1;
            end

            if (!div_busy && !div_result_valid
                && (div_have_dividend || dividend_fire)
                && (div_have_divisor || divisor_fire)) begin
                // 除零和 signed overflow 应由 MLU 本地快速路径处理；保护
                // 分支只用于在 RTL 出错时避免行为模型制造额外 X。
                if (divisor_now == 0) begin
                    div_quotient  <= -33'sd1;
                    div_remainder <= dividend_now;
                end else if ((dividend_now == -33'sd2147483648)
                             && (divisor_now == -33'sd1)) begin
                    div_quotient  <= dividend_now;
                    div_remainder <= '0;
                end else begin
                    div_quotient  <= dividend_now / divisor_now;
                    div_remainder <= dividend_now % divisor_now;
                end
                div_have_dividend <= 1'b0;
                div_have_divisor  <= 1'b0;
                div_busy          <= 1'b1;
                div_count         <= DIV_LATENCY;
            end else if (div_busy) begin
                if (div_count > 1)
                    div_count <= div_count - 1;
                else begin
                    div_count        <= 0;
                    div_busy         <= 1'b0;
                    div_result_valid <= 1'b1;
                end
            end
        end
    end

    function automatic logic [31:0] committed_gp;
        logic [PHYS_REG_IDX_WIDTH-1:0] preg;
        begin
            preg = dut.u_backend.u_rename.u_rat_rrat.rrat[3];
            committed_gp = dut.u_backend.u_prf.registers[preg];
        end
    endfunction

    task automatic fail_unknown(input string signal_name);
        begin
            $display("REGRESSION_RESULT FAIL test=%s cycle=%0d reason=unknown_%s last_pc=%08h",
                     test_name, cycles, signal_name, last_commit_pc);
            $fatal(1, "Unknown value observed on %s", signal_name);
        end
    endtask

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        cycles = 0;
        max_cycles = 100000;
        trace_enabled = $test$plusargs("TRACE");
        last_commit_pc = RESET_PC;
        if (!$value$plusargs("HEX=%s", hex_file))
            $fatal(1, "tb_official_hex_regression requires +HEX=<path>");
        if (!$value$plusargs("TEST=%s", test_name))
            test_name = hex_file;
        void'($value$plusargs("MAX_CYCLES=%d", max_cycles));

        $display("REGRESSION_START test=%s hex=%s max_cycles=%0d",
                 test_name, hex_file, max_cycles);
        repeat (5) @(posedge clk);
        @(negedge clk);
        rst_n = 1'b1;

        forever begin
            @(posedge clk);
            #1;
            cycles = cycles + 1;

            if ($isunknown(commit_fire))
                fail_unknown("commit_fire");
            if (imem_ren && $isunknown(imem_addr))
                fail_unknown("imem_addr");
            if ($isunknown(dmem_request_valid))
                fail_unknown("dmem_request_valid");
            if (dmem_request_valid && $isunknown(dmem_request))
                fail_unknown("dmem_request");
            if ($isunknown(dmem_response.valid))
                fail_unknown("dmem_response_valid");

            if (commit_fire[0]) begin
                last_commit_pc = commit_bus.lane0.pc;
                if (trace_enabled)
                    $display("TRACE COMMIT cycle=%0d lane=0 pc=%08h pdst=%0d",
                             cycles, commit_bus.lane0.pc,
                             commit_bus.lane0.pdst);
            end
            if (commit_fire[1]) begin
                last_commit_pc = commit_bus.lane1.pc;
                if (trace_enabled)
                    $display("TRACE COMMIT cycle=%0d lane=1 pc=%08h pdst=%0d",
                             cycles, commit_bus.lane1.pc,
                             commit_bus.lane1.pdst);
            end
            if (trace_enabled && recover.valid)
                $display("TRACE RECOVER cycle=%0d reason=%0d target=%08h",
                         cycles, recover.reason, recover.target);
            if (trace_enabled && dmem_request_valid && dmem_request_ready)
                $display("TRACE DMEM cycle=%0d store=%0b addr=%08h data=%08h strb=%b",
                         cycles, dmem_request.is_store, dmem_request.address,
                         dmem_request.write_data, dmem_request.write_strobe);

            if ((commit_fire[0] && (commit_bus.lane0.pc == END_PC))
                || (commit_fire[1] && (commit_bus.lane1.pc == END_PC))) begin
                if ($isunknown(committed_gp()))
                    fail_unknown("committed_gp");
                if (committed_gp() == 32'd1) begin
                    $display("REGRESSION_RESULT PASS test=%s cycles=%0d gp=%08h",
                             test_name, cycles, committed_gp());
                    $finish;
                end else begin
                    $display("REGRESSION_RESULT FAIL test=%s cycles=%0d gp=%08h last_pc=%08h",
                             test_name, cycles, committed_gp(), last_commit_pc);
                    $fatal(1, "Official test failed: committed gp must equal 1");
                end
            end

            if (cycles >= max_cycles) begin
                $display("REGRESSION_RESULT TIMEOUT test=%s cycles=%0d last_pc=%08h",
                         test_name, cycles, last_commit_pc);
                $fatal(1, "Official test timed out");
            end
        end
    end

endmodule
