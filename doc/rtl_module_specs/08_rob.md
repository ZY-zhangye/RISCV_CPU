# Reorder Buffer 设计

建议模块名：reorder_buffer，32 项，组织为 16 row×2 bank。

## 1. 端口

| 方向 | 端口 | 类型 | 说明 |
|---|---|---|---|
| input | alloc_valid_i | 2-bit | 双路分配 |
| output | alloc_ready_o | 1 | 完整请求可接受 |
| output | alloc_rob_id_o | 2×5-bit | 直接索引 ID |
| input | alloc_entry_i | 2×rob_alloc_t | 分配字段 |
| input | complete_i | 2×completion_t | 双 WB 完成 |
| output | head_valid_o | 2-bit | head row 有效情况 |
| output | head_entry_o | 2×rob_entry_t | Commit 观察 |
| input | retire_count_i | 2-bit | 提交 0/1/2 项 |
| input/output | exception_flush_i / exception_flush_done_o | 1 | 精确异常清空与完成脉冲 |
| input | branch_resolve_i | typed | 分支正确解析/误预测 |
| input | restore_tail_i | typed | checkpoint tail 恢复 |
| output | empty_o、full_o | 1 | 状态 |

## 2. Entry 字段

每项保存 valid、complete、arch_rd、new_prd、old_prd、write_rd、
exception_valid/cause/tval、is_store、sq_id、is_branch、checkpoint_id、
branch_mask、serializing、pc 和必要的预测信息。普通执行结果不保存在 ROB。

## 3. 指针与容量

head 和 tail 使用 row 指针、bank 状态和 wrap bit。初版分配固定：

- 第一条进入 tail_row.bank0。
- 第二条进入同 row.bank1。
- 允许 bank1 空，不允许 bank0 空而 bank1 有效。

如果上一周期只分配 bank0，下一次分配从新 row 的 bank0 开始，牺牲少量容量以简化
提交和直接索引。

## 4. 分配时序

alloc_ready 只由本地 occupancy/free rows 产生。alloc_fire 周期写 entry 并返回已预先
计算和寄存的 ROB ID。Rename/ROB/LSQ 分配必须使用同一 bundle fire。

`alloc_ready_o` 不得依赖 `alloc_valid_i`。非前缀 `2'b10` 由 fire 条件和断言拒绝，避免
与上游 Resource Manager 的 ready→valid 逻辑形成组合环。

## 5. 完成写入

WB 使用 rob_id 直接索引 entry。若 completion 带异常：

- 写 exception 字段。
- complete 置位。
- 不把异常结果标为 PRF ready。

被 branch recovery 杀死的 completion 必须在进入 ROB 前被过滤。

## 6. Head 与提交

head_entry_o 来自 head row 的输出寄存器。Commit 条件由 commit_unit 决定，ROB 只按
retire_count 移动 head 和清 valid。双提交必须先提交 bank0，bank1 只能随 bank0 或在
bank0 已于更早周期退休后成为新的规范 head；V1 用整 row 退休规则简化实现。

## 7. 分支恢复

checkpoint 保存 ROB tail。误预测后恢复 tail，并以多周期或 row mask 方式清除年轻
valid。恢复完成前暂停分配。正确预测仅清 surviving entry 的 branch_mask bit，可分组
完成，避免一拍扇出到 32 项。

精确异常 flush 优先于分支 clear/restore 扫描，同步清空 valid/complete、head/tail、
occupancy 和扫描状态，并输出单拍 done。ROB entry payload 不逐项复位；全清 valid 后旧
payload 不可见，可避免为宽数据阵列引入额外复位扇出。

## 8. 断言

- complete 只能写 valid entry，且 rob_id generation/epoch 匹配。
- bank1 valid 蕴含 bank0 valid。
- occupancy 在 0 至 32。
- retire 只清连续、有效、满足提交条件的 head。
- 恢复后不存在年龄晚于恢复 tail 的 valid entry。

## 9. 当前验证状态（2026-07-06）

`test/tb_reorder_buffer.sv` 已覆盖双/单分配、完成与异常完成、整 row 退休、branch mask
clear、tail restore、满容量，以及精确异常在 branch scan 中途抢占并清空全部 ROB 状态。
CSR completion 还会按 rob_id 保存 `completion.data` 为 `csr_operand`，并对当前 head
执行同拍前递，使提交端无需额外等待一拍。QuestaSim 2024.1 最小测试和当前 31 项回归
均通过，`Errors: 0, Warnings: 0`。
新增 exception flush 后用户 5 ns OOC WNS 为 +0.903 ns，当前冻结。
Rename+ROB 初次成组 OOC WNS 为 -0.281 ns，并报告 2 个组合环；已移除 ROB
`alloc_ready_o -> alloc_valid_i -> alloc_ready_o` 反馈。去环后 Questa 29 项回归通过，
OOC 复测 WNS 为 +0.559 ns、TNS 为 0，combinational loops 为 0，当前冻结。

完整 Commit/Recovery 首次 OOC 暴露 `head payload -> commit/reclaim -> retire_count ->
next head payload mux` 的跨模块长路径，WNS -2.104 ns，18 级逻辑且 82.6% 为布线。
ROB 已改为退休拍推进 head 并清空可见 head，下一拍按已寄存的新 `head_row_q` refill
payload。该一拍 row 切换气泡切断 retire_count 到宽 payload mux 的组合反馈；Questa
32 项回归通过，等待集群 OOC 复测。

第一次复测 WNS 改善到 -1.516 ns、TNS -2089.456 ns，原 D 路径已消失；新最差路径
落在 head payload 的同步复位脚 `/R`，13 级逻辑且 route 占 86.0%。进一步取消退休/
空 ROB 时对 payload 的清零，只清 `valid/complete`，失效 payload 保持不可见，从而移除
高扇出 payload reset 网络。Questa 32 项回归继续通过，等待第二次复测。

第二次复测 WNS 为 -1.210 ns，路径终点转移到 `occupancy_q`，证明局部 head mux/reset
虽已移除，但组合 Commit 决策仍直接返回 ROB counter。完整集群现加入两阶段提交：副作用
握手成功时锁存退休事务，下一拍仅用寄存后的 retire_count 推进 ROB，从结构上切断
head metadata 经 Commit/reclaim 返回 ROB 状态的路径。
