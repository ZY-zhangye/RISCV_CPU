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
