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

## 8. 断言

- complete 只能写 valid entry，且 rob_id generation/epoch 匹配。
- bank1 valid 蕴含 bank0 valid。
- occupancy 在 0 至 32。
- retire 只清连续、有效、满足提交条件的 head。
- 恢复后不存在年龄晚于恢复 tail 的 valid entry。
