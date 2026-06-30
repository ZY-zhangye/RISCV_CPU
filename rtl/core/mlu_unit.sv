`include "defines.svh"

// =============================================================================
// RV32M MLU —— Vivado Multiplier / Divider Generator 适配层
// =============================================================================
// 乘法：
//   - 使用 33x33 signed IP。带符号操作数符号扩展，无符号操作数零扩展，
//     因而一个 signed IP 可覆盖 MUL/MULH/MULHSU/MULHU。
//   - mul_request_valid 仅脉冲一拍；MUL_LATENCY 必须与 Vivado IP 配置一致，
//     到期后采样 66-bit mul_product。
//
// 除法：
//   - dividend/divisor 输入是彼此独立的类 AXI ready/valid 通道；本模块会
//     分别保持 valid，直到两个输入都完成握手。
//   - result 也使用 ready/valid。建议 Divider Generator 配置 33-bit signed，
//     quotient/remainder 分别接到本模块的 33-bit 输入。
//   - 除零和 signed overflow 依 RISC-V 规范在本地完成，不占用除法 IP。
//
// 当前采用单在途策略，优先保证固定延迟 IP 在任意 WB 反压下不会溢出。
// recovery 对已进入 IP 的操作只标记 killed：乘法等待固定延迟结束后丢弃，
// 除法继续补齐可能尚未握手的输入并消费旧结果，避免 AXI IP 被半包卡死或
// 将旧结果误配给恢复后的新指令；排空期间 MLU 保持 unavailable。
// =============================================================================
module mlu_unit #(
    parameter int MUL_LATENCY = 3
) (
    input  logic                                      clk,
    input  logic                                      rst_n,
    input  wire core_port_pkg::recover_event_t        recover,

    input  logic                                      in_valid,
    input  wire core_port_pkg::execute_operand_t      in_bus,
    output logic                                      in_ready,

    output logic                                      out_valid,
    output      core_port_pkg::execute_writeback_t    out_bus,
    input  logic                                      out_ready,

    // Vivado Multiplier IP：固定延迟，无反压。
    output logic                                      mul_request_valid,
    output logic signed [32:0]                        mul_operand_a,
    output logic signed [32:0]                        mul_operand_b,
    input  logic signed [65:0]                        mul_product,

    // Vivado Divider Generator：AXI-stream 风格双输入与结果通道。
    output logic                                      div_dividend_valid,
    input  logic                                      div_dividend_ready,
    output logic signed [32:0]                        div_dividend_data,
    output logic                                      div_divisor_valid,
    input  logic                                      div_divisor_ready,
    output logic signed [32:0]                        div_divisor_data,
    input  logic                                      div_result_valid,
    output logic                                      div_result_ready,
    input  logic signed [32:0]                        div_quotient,
    input  logic signed [32:0]                        div_remainder
);
    import core_port_pkg::*;

    localparam int MUL_COUNT_WIDTH = (MUL_LATENCY <= 1)
                                   ? 1 : $clog2(MUL_LATENCY + 1);

    typedef enum logic [2:0] {
        MLU_IDLE,
        MLU_MUL_WAIT,
        MLU_DIV_SEND,
        MLU_DIV_WAIT,
        MLU_RESULT
    } mlu_state_e;

    mlu_state_e state;
    execute_operand_t pending_bus;
    execute_writeback_t result_reg;
    logic [MUL_COUNT_WIDTH-1:0] mul_count;
    logic signed [32:0] operand_a_reg;
    logic signed [32:0] operand_b_reg;
    logic dividend_sent;
    logic divisor_sent;
    logic operation_killed;
    logic dividend_done_now;
    logic divisor_done_now;
    logic input_is_multiply;
    logic input_is_divide;
    logic input_signed_divide;
    logic input_divide_by_zero;
    logic input_signed_overflow;
    logic input_a_signed;
    logic input_b_signed;
    logic signed [32:0] extended_input_a;
    logic signed [32:0] extended_input_b;
    logic [XLEN-1:0] immediate_div_result;

    function automatic logic is_multiply_op(input mlu_op_e op);
        is_multiply_op = (op == MLU_MUL) || (op == MLU_MULH)
                      || (op == MLU_MULHSU) || (op == MLU_MULHU);
    endfunction

    function automatic logic is_divide_op(input mlu_op_e op);
        is_divide_op = (op == MLU_DIV) || (op == MLU_DIVU)
                    || (op == MLU_REM) || (op == MLU_REMU);
    endfunction

    always_comb begin
        input_is_multiply = is_multiply_op(in_bus.issue.uop.dec.mlu_op);
        input_is_divide   = is_divide_op(in_bus.issue.uop.dec.mlu_op);
        input_signed_divide = (in_bus.issue.uop.dec.mlu_op == MLU_DIV)
                           || (in_bus.issue.uop.dec.mlu_op == MLU_REM);

        input_a_signed = (in_bus.issue.uop.dec.mlu_op != MLU_MULHU)
                      && (in_bus.issue.uop.dec.mlu_op != MLU_DIVU)
                      && (in_bus.issue.uop.dec.mlu_op != MLU_REMU);
        input_b_signed = (in_bus.issue.uop.dec.mlu_op == MLU_MUL)
                      || (in_bus.issue.uop.dec.mlu_op == MLU_MULH)
                      || input_signed_divide;
        extended_input_a = $signed({input_a_signed && in_bus.rs1_value[31],
                                    in_bus.rs1_value});
        extended_input_b = $signed({input_b_signed && in_bus.rs2_value[31],
                                    in_bus.rs2_value});

        input_divide_by_zero = (in_bus.rs2_value == '0);
        input_signed_overflow = input_signed_divide
                              && (in_bus.rs1_value == 32'h8000_0000)
                              && (in_bus.rs2_value == 32'hffff_ffff);
        immediate_div_result = '0;
        if (input_divide_by_zero) begin
            if ((in_bus.issue.uop.dec.mlu_op == MLU_DIV)
                || (in_bus.issue.uop.dec.mlu_op == MLU_DIVU))
                immediate_div_result = 32'hffff_ffff;
            else
                immediate_div_result = in_bus.rs1_value;
        end else if (input_signed_overflow) begin
            if (in_bus.issue.uop.dec.mlu_op == MLU_DIV)
                immediate_div_result = 32'h8000_0000;
            else
                immediate_div_result = '0;
        end

        in_ready = (state == MLU_IDLE);
        out_valid = (state == MLU_RESULT);
        out_bus   = result_reg;

        mul_request_valid = in_valid && in_ready && input_is_multiply
                          && !recover.valid;
        mul_operand_a = extended_input_a;
        mul_operand_b = extended_input_b;

        div_dividend_valid = (state == MLU_DIV_SEND) && !dividend_sent;
        div_divisor_valid  = (state == MLU_DIV_SEND) && !divisor_sent;
        div_dividend_data  = operand_a_reg;
        div_divisor_data   = operand_b_reg;
        div_result_ready   = (state == MLU_DIV_WAIT);
        dividend_done_now  = dividend_sent
                           || (div_dividend_valid && div_dividend_ready);
        divisor_done_now   = divisor_sent
                           || (div_divisor_valid && div_divisor_ready);
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state          <= MLU_IDLE;
            pending_bus    <= '0;
            result_reg     <= '0;
            mul_count      <= '0;
            operand_a_reg  <= '0;
            operand_b_reg  <= '0;
            dividend_sent  <= 1'b0;
            divisor_sent   <= 1'b0;
            operation_killed <= 1'b0;
        end else begin
            // 已送入不可取消 IP 的事务在恢复时必须继续排空。
            if (recover.valid) begin
                result_reg <= '0;
                if ((state == MLU_MUL_WAIT)
                    || (state == MLU_DIV_SEND)
                    || (state == MLU_DIV_WAIT)) begin
                    operation_killed <= 1'b1;
                end else begin
                    state <= MLU_IDLE;
                    operation_killed <= 1'b0;
                end
            end
            unique case (state)
                MLU_IDLE: begin
                    if (in_valid && !recover.valid) begin
                        pending_bus   <= in_bus;
                        operand_a_reg <= extended_input_a;
                        operand_b_reg <= extended_input_b;
                        result_reg    <= '0;
                        result_reg.rob_tag    <= in_bus.issue.rob_tag;
                        result_reg.pdst_valid <= in_bus.issue.uop.pdst_valid;
                        result_reg.pdst       <= in_bus.issue.uop.pdst;
                        operation_killed <= 1'b0;

                        if (input_is_multiply) begin
                            mul_count <= MUL_COUNT_WIDTH'(MUL_LATENCY);
                            state     <= MLU_MUL_WAIT;
                        end else if (input_is_divide
                                     && (input_divide_by_zero
                                         || input_signed_overflow)) begin
                            result_reg.data <= immediate_div_result;
                            state <= MLU_RESULT;
                        end else if (input_is_divide) begin
                            dividend_sent <= 1'b0;
                            divisor_sent  <= 1'b0;
                            state <= MLU_DIV_SEND;
                        end else begin
                            result_reg.data <= '0;
                            state <= MLU_RESULT;
                        end
                    end
                end

                MLU_MUL_WAIT: begin
                    if (mul_count > MUL_COUNT_WIDTH'(1)) begin
                        mul_count <= mul_count - 1'b1;
                    end else begin
                        mul_count <= '0;
                        if (operation_killed || recover.valid) begin
                            operation_killed <= 1'b0;
                            state <= MLU_IDLE;
                        end else begin
                            if (pending_bus.issue.uop.dec.mlu_op == MLU_MUL)
                                result_reg.data <= mul_product[31:0];
                            else
                                result_reg.data <= mul_product[63:32];
                            state <= MLU_RESULT;
                        end
                    end
                end

                MLU_DIV_SEND: begin
                    if (div_dividend_valid && div_dividend_ready)
                        dividend_sent <= 1'b1;
                    if (div_divisor_valid && div_divisor_ready)
                        divisor_sent <= 1'b1;
                    if (dividend_done_now && divisor_done_now)
                        state <= MLU_DIV_WAIT;
                end

                MLU_DIV_WAIT: begin
                    if (div_result_valid) begin
                        if (operation_killed || recover.valid) begin
                            operation_killed <= 1'b0;
                            state <= MLU_IDLE;
                        end else begin
                            if ((pending_bus.issue.uop.dec.mlu_op == MLU_DIV)
                                || (pending_bus.issue.uop.dec.mlu_op == MLU_DIVU))
                                result_reg.data <= div_quotient[31:0];
                            else
                                result_reg.data <= div_remainder[31:0];
                            state <= MLU_RESULT;
                        end
                    end
                end

                MLU_RESULT: begin
                    if (out_ready)
                        state <= MLU_IDLE;
                end

                default: state <= MLU_IDLE;
            endcase
        end
    end

`ifndef SYNTHESIS
    initial begin
        assert (MUL_LATENCY >= 1)
            else $fatal(1, "mlu_unit: MUL_LATENCY must be >= 1");
    end
`endif

endmodule
