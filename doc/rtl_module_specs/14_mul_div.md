# Multiply/Divide Unit 设计

建议模块：mul_pipeline、div_unit、muldiv_frontend。

## 1. 公共端口

| 方向 | 端口 | 类型 | 说明 |
|---|---|---|---|
| input | req_valid_i | 1 | MDU IQ 请求 |
| output | req_ready_o | 1 | 对应单元可接受 |
| input | req_uop_i | execute_uop_t | 操作数、op、ID、mask |
| output | result_valid_o | 1 | 结果有效 |
| input | result_ready_i | 1 | Completion Buffer 接收 |
| output | result_o | completion_t | 最终 32-bit 结果 |
| input | recovery_i | recovery_t | 标记/取消错误路径 |

## 2. 乘法器

使用 DSP48 映射的有符号乘法流水，固定 3 至 4 周期，吞吐率 1/cycle。输入规范化为
33×33 signed，以统一 MUL、MULH、MULHSU、MULHU。每级同时流水 rob_id、prd、op、
branch_mask 和 valid。

输出根据 op 选择低 32 位或高 32 位，先进入深度 2 的 Mul Completion FIFO，再参与
全局 WB。

## 3. 除法器

Radix-4 迭代，单在途，目标 16 至 18 周期。状态机：

    IDLE -> PREPARE -> ITERATE -> SIGN_FIX -> OUTPUT

DIV/DIVU/REM/REMU 共用 datapath。必须显式处理：

- 除数为 0：quotient 全 1，remainder=dividend。
- signed 最小负数除以 -1：quotient=最小负数，remainder=0。

OUTPUT 保持 result_valid，直到 Completion Buffer 接收。

## 4. Recovery

乘法流水中的错误路径项不能简单停整条流水；每级按 branch_mask kill valid。除法器若
当前项被 kill，可立即回到 IDLE。正确分支解析清 mask 位。

## 5. 时序约束

乘法器每级 DSP 之间必须有寄存器；不允许组合符号修正跨越多个 DSP 级。除法器每轮
仅完成固定 radix-4 步骤，余数比较/选择必须独立达到 225 MHz 以上。

## 6. 断言

- 乘法输出延迟固定且 tag 不乱序。
- 除法器 busy 时不接受第二项。
- 被 kill 的 MDU 项不进入 Completion Buffer。
- 所有特殊除法结果符合 RISC-V 规范。
