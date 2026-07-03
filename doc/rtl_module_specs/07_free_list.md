# Free List 设计

建议模块名：free_list。

## 1. 端口

| 方向 | 端口 | 位宽 | 说明 |
|---|---|---:|---|
| input | alloc_count_i | 2 | 请求 0/1/2 个 PRD |
| output | alloc_valid_o | 1 | 可满足完整请求 |
| output | alloc_prd0_o、alloc_prd1_o | 6 | 选择结果 |
| input | alloc_fire_i | 1 | 真正消耗结果 |
| input | reclaim_valid_i | 2 | Commit 延迟回收 |
| input | reclaim_prd_i | 2×6 | old PRD |
| input | checkpoint_save_i | 1 | 保存恢复信息 |
| input | checkpoint_id_i | 2 | checkpoint 槽 |
| input | branch_restore_i | 1 | 分支恢复 |
| input | rebuild_start_i | 1 | 异常后重建 |
| input | amt_map_i | 32×6 | 已提交映射扫描源 |
| output | rebuild_done_o | 1 | 重建完成 |
| output | free_count_o | 7 | 空闲数 |

## 2. 数据结构

主空闲表为 4 组×16-bit bitmap。p0 至 p31 初始被占用，p32 至 p63 初始空闲。
另维护 group_nonempty[3:0] 和旋转起始组，避免固定低编号热点。

Commit 不直接写主 bitmap，而是先写 2-entry Reclaim Buffer。下一周期或后续周期由
Free List 本地吸收，切断 Commit 到 Rename 的组合闭环。

## 3. 双分配

选择分两级：

1. 从 group_nonempty 选择最多两个候选组。
2. 每组做 16-bit first-one/second-one。

优先尝试一个偶数 PRD 和一个奇数 PRD。无法跨 Bank 时仍可分配同 Bank，但设置
bank_same 性能事件。选择结果在 allocator response 寄存后供 Rename R1 使用。

## 4. 更新规则

alloc_fire 时清除所选 bit。reclaim 被吸收时置位对应 bit。若同周期同一 PRD 被错误地
同时分配和回收，应触发断言；正常设计不会出现这种情况。

Reclaim Buffer 满时 Commit 必须局部停顿，不允许把压力组合传到 Rename。

## 5. 分支恢复

推荐 checkpoint 保存 allocation log tail，而非复制完整 64-bit bitmap。每次分配把
PRD 写入小型 allocation log；误预测按 checkpoint tail 回滚年轻分配，并将这些 PRD
逐周期归还。恢复期间暂停 Rename，允许用数周期换取较短关键路径。

若最终选择 bitmap snapshot，必须将 snapshot 寄存分布实现，恢复也在本地时序完成。

## 6. 异常重建

rebuild_start 后：

1. 将临时 used bitmap 清零并标记 p0。
2. 每周期扫描 2 至 4 个 AMT 项，标记其 PRD 已使用。
3. 扫描完毕后 free_bitmap = ~used_bitmap，并强制清 p0。
4. 更新 group_nonempty，拉高 rebuild_done。

## 7. 断言

- 已分配 PRD 在分配前必为空闲。
- reclaim PRD 不为 p0，且不会重复置位。
- 双分配结果不同。
- free_count 等于 bitmap popcount。
- 重建结束后 AMT 中所有 PRD 均非空闲。
