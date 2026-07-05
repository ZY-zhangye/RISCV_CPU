# Completion Buffer 与 Writeback 设计

建议模块：各执行端 completion_buffer、writeback_arbiter。

## 1. Producer 接口

Producer 包括 INT0、INT1、LSU、MUL、DIV。每个 producer 使用 valid-ready 和
completion_t。建议深度：INT0 1、INT1 1、LSU 2、MUL 2、DIV 1。

Completion Buffer 负责吸收固定延迟碰撞，不允许通过全局 stall 让所有执行端同时停住。

## 2. Writeback 输出

| 方向 | 端口 | 类型 | 说明 |
|---|---|---|---|
| output | wb_valid_o | 2-bit | 最多两个最终写回 |
| output | wb_o | 2×completion_t | 结果 |
| input | recovery_i | recovery_t | kill 过滤 |
| output | prf_write_o | 2×typed | 实际 PRF 写 |
| output | rob_complete_o | 2×typed | ROB 直接索引完成 |
| output | wakeup_tag_o | 2×PRD | IQ 下一拍 wakeup |

## 3. 仲裁

第一层在 producer 间选最多两个候选；第二层检查 PRF Bank：

- 两个普通结果写不同 Bank：双写。
- 两个结果写同 Bank：只发优先级较高者，另一项留在原 buffer。
- 不写 PRF 的异常/Store/纯 Branch completion 可占 ROB complete 通路，但不占 PRF Bank。

建议动态公平仲裁，静态紧急度 Load > INT/Branch > MUL > DIV 只用于 buffer 即将满时。

## 4. 原子副作用

一个普通 completion 被仲裁接受的同一时钟沿完成：

1. 写 PRF。
2. PRF ready 置位。
3. ROB complete 置位。
4. 产生 wakeup tag。
5. producer buffer 出队。

异常 completion 只写 ROB exception/complete，不写 PRF 和 wakeup。

## 5. 时序

Producer 候选先寄存，Bank 检查和二选仲裁在 WB 周期完成，输出再作为时序写使能。
不得把执行单元原始结果绕过 buffer 直接接 PRF。

## 6. Recovery

仲裁前按 branch_mask 和 rob generation 过滤失效结果。recovery 与 WB 同周期时，只有
不被恢复杀死的更老结果可写；简单实现可以让 recovery 周期全部 WB 暂停一拍。

## 7. 断言

- 每 Bank 每周期最多一次 PRF write。
- 同一 rob_id 不重复完成。
- 异常 completion 不产生 wakeup。
- buffer 满时 producer ready 为 0 且数据不丢失。
- 仲裁长期公平，无持续有请求 producer 永久饥饿。

## 8. 当前实现状态（2026-07-05）

`rtl/writeback/writeback_arbiter.sv` 已实现时序化 5 producer / 2 lane 写回仲裁：

- Producer 顺序：INT0、INT1/Branch、LSU、MUL、DIV。
- 每个 producer 前置 2-entry skid buffer，`ready_o` 只由本地 occupancy 产生，输出
  WB/ROB/PRF/wakeup 全部来自寄存输出。
- 稳态每周期最多输出 2 个 `completion_t`。
- 普通 `write_prf` completion 检查 PRF bank；同 bank 只接受其中一个，另一个 producer 保持。
- 异常、Store、非 PRF completion 只占 ROB complete lane，不占 PRF bank，不产生 wakeup。
- 输出同时拆分为 `wb_o`、`prf_write_*`、`rob_complete_*`、`wakeup_*`。
- `recovery_i.valid` 周期暂停所有 writeback，producer ready 全部为 0，已缓冲 payload 保留。
- V1 使用固定优先级以切断原 rotating priority 的深组合反馈路径；若系统级测试暴露饥饿，再引入小型寄存 age 机制。

`test/tb_writeback_arbiter.sv` 已覆盖双写、同 bank 冲突、异常/Store 不占 PRF、
recovery pause、输入缓冲与注册输出延迟。QuestaSim 单测通过，`Errors: 0, Warnings: 0`。
用户 OOC：200 MHz / 5.000 ns 下 WNS = +0.287 ns。最差路径为 producer buffer
count 到另一 producer buffer data CE，route 占比约 86%；该模块暂时冻结，后续在
成组/实现布线暴露真实问题时再考虑增加选择结果流水级。
