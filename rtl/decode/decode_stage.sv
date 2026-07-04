`timescale 1ns/1ps

import core_types_pkg::*;
import decode_pkg::*;

// decode_stage.sv
// 2 路超标量译码级流水线 (2-way Superscalar Decode Stage)
// 职责：
// 1. 实现双路并行译码，调用包中的 `decode_slot` 独立解算 lane0 和 lane1；
// 2. 控制双路超标量发射约束：如果在 lane0 遇到了序列化指令 (如 CSR、MRET 等) 或触发了取指异常，
//    则主动抑制/清零 lane1 的有效位，以降低后级 Rename 与发射的控制复杂度。
// 3. 实现与后级 Rename 和前级 Instruction Buffer 之间的握手和流水寄存。

module decode_stage (
    input  logic          clk_i,             // 时钟信号
    input  logic          rst_i,             // 复位信号 (高电平有效)

    // 前级 Instruction Buffer (IBuf) 输入接口
    input  logic [1:0]    in_valid_i,        // 输入有效位 ([0] lane0有效, [1] lane1有效)
    output logic          in_ready_o,        // 译码级就绪，允许接收新包 (反压)
    input  fetch_slot_t   fetch_slot0_i,     // lane0 原始指令槽
    input  fetch_slot_t   fetch_slot1_i,     // lane1 原始指令槽

    // 后级 重命名 (Rename) 输出接口
    output logic [1:0]    out_valid_o,       // 译码输出给下一级的有效指示
    input  logic          out_ready_i,       // 下一级就绪信号 (反压)
    output decoded_uop_t  decoded_uop0_o,    // lane0 译码后微操作 payload
    output decoded_uop_t  decoded_uop1_o,    // lane1 译码后微操作 payload

    // 清空与复位控制
    input  logic          flush_i            // 流水线清空 (冲刷)
);

  // 流水线物理暂存寄存器
  logic [1:0] out_valid_q;
  decoded_uop_t decoded_uop0_q;
  decoded_uop_t decoded_uop1_q;

  // 组合逻辑译码计算连线
  decoded_uop_t decoded_lane0;
  decoded_uop_t decoded_lane1;
  logic [1:0] accepted_valid;

  // 双通道独立组合逻辑译码
  assign decoded_lane0 = decode_pkg::decode_slot(fetch_slot0_i);
  assign decoded_lane1 = decode_pkg::decode_slot(fetch_slot1_i);

  // 双路发射合法性筛选：
  // 1. lane0 只有在前级标记有效时有效。
  // 2. lane1 只有当 lane0 和 lane1 同时有效，且 lane0 **不是**序列化指令（如CSR/MRET），
  //    且 lane0 **没有**携带异常（如地址非对齐、非法指令）时才有效。
  // 这确保了在遇到例外情况或强序列化操作时，Decode 阶段能立刻在 lane1 产生气泡（清零有效信号），
  // 避免它们同时进入后级重命名。
  assign accepted_valid[0] = in_valid_i[0];
  assign accepted_valid[1] = in_valid_i[1] && in_valid_i[0] &&
                             !decoded_lane0.serializing &&
                             !decoded_lane0.exception_valid;

  // 反压就绪计算：没有发生冲刷，且（输出端寄存器为空 或 下一级已被成功接收并腾出空间）
  assign in_ready_o = !flush_i && ((out_valid_q == 2'b00) || out_ready_i);

  // 组合逻辑输出：若发生 flush 冲刷，则强制将输出有效位清零
  assign out_valid_o = flush_i ? 2'b00 : out_valid_q;
  assign decoded_uop0_o = decoded_uop0_q;
  assign decoded_uop1_o = decoded_uop1_q;

  // 流水寄存器更新逻辑
  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      out_valid_q    <= 2'b00;
      decoded_uop0_q <= '0;
      decoded_uop1_q <= '0;
    end else if (flush_i) begin
      out_valid_q <= 2'b00;
    end else if (in_ready_o) begin
      out_valid_q <= accepted_valid;
      if (accepted_valid[0])
        decoded_uop0_q <= decoded_lane0;
      if (accepted_valid[1])
        decoded_uop1_q <= decoded_lane1;
    end
  end

  // ==========================================================================
  // 系统断言 (SystemVerilog Assertions)
  // ==========================================================================
`ifdef DECODE_STAGE_ASSERTIONS
  // 断言 1：输入有效位必须符合前缀有效原则（不能出现 lane1 有效但 lane0 无效的情况，即 2'b10）
  property p_input_prefix;
    @(posedge clk_i) disable iff (rst_i) in_valid_i != 2'b10;
  endproperty
  assert property (p_input_prefix);

  // 断言 2：输出有效位必须符合前缀有效原则（即 2'b10 为非法输出）
  property p_output_prefix;
    @(posedge clk_i) disable iff (rst_i) out_valid_o != 2'b10;
  endproperty
  assert property (p_output_prefix);

  // 断言 3：当后级重命名被反压暂停时，当前译码流水级的输出必须保持绝对稳定
  property p_output_stable;
    @(posedge clk_i) disable iff (rst_i || flush_i)
      (out_valid_o != 2'b00) && !out_ready_i |=>
        $stable(out_valid_o) && $stable(decoded_uop0_o) &&
        $stable(decoded_uop1_o);
  endproperty
  assert property (p_output_stable);
`endif

endmodule
