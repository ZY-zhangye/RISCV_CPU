# Free List 设计

建议模块名：free_list。

## 1. 端口

| 方向 | 端口 | 位宽 | 说明 |
|---|---|---:|---|
| input | alloc_count_i | 2 | 请求 0/1/2 个 PRD |
| output | alloc_valid_o | 1 | 可满足完整请求 |
| output | alloc_prd0_o、alloc_prd1_o | 6 | 选择结果 |
| input | alloc_fire_i | 1 | 真正消耗结果 |
| input | alloc_cancel_i | 1 | 取消尚未消耗的 reservation |
| input | reclaim_valid_i | 2 | Commit 延迟回收 |
| input | reclaim_prd_i | 2×6 | old PRD |
| output | reclaim_ready_o | 1 | Reclaim Buffer 可原子接受整个前缀有效 bundle |
| input | checkpoint_save_i | 1 | 保存恢复信息 |
| input | checkpoint_id_i | 2 | checkpoint 槽 |
| input | checkpoint_keep_count_i | 2 | 当前分配 bundle 中位于分支及其之前的 PRD 数 |
| input | checkpoint_clear_i / checkpoint_clear_id_i | 1 / 2 | 正确预测后释放 checkpoint |
| input | branch_restore_i | 1 | 分支恢复 |
| input | branch_restore_id_i | 2 | 待恢复 checkpoint 槽 |
| output | branch_restore_done_o | 1 | allocation log 回滚完成脉冲 |
| input | rebuild_start_i | 1 | 异常后重建 |
| input | amt_map_i | 32×6 | 已提交映射扫描源 |
| output | busy_o | 1 | rollback/rebuild 期间禁止新分配 |
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
bank_same 性能事件。选择结果必须先写入 allocator reservation/response 寄存器，再供
Rename R1 使用；禁止 `alloc_req → bitmap priority encode → alloc_resp` 同周期组合返回。
reservation 在 `alloc_fire` 前保持且不清 bitmap，flush/cancel 时无副作用释放。

V1 使用 S0/S1 两拍选择和单个 reservation 寄存器：S0 只选择第一个 PRD 并寄存，S1
基于已寄存的第一个 PRD 选择第二个 PRD，禁止两套组/组内优先编码器组合串联。
reservation 被 fire/cancel 清除后的下一周期才重新开始选择，不建立
`alloc_fire → bitmap update → next selection` 的同周期穿越路径。吞吐优化应通过后续增加
第二个预选槽完成，而不是放宽该时序边界。

## 4. 更新规则

alloc_fire 时清除所选 bit。reclaim 被吸收时置位对应 bit。若同周期同一 PRD 被错误地
同时分配和回收，应触发断言；正常设计不会出现这种情况。

Reclaim Buffer 满时 Commit 必须局部停顿，不允许把压力组合传到 Rename。

## 5. 分支恢复

推荐 checkpoint 保存 allocation log tail，而非复制完整 64-bit bitmap。每次分配把
PRD 写入 64 项 allocation log；误预测按 checkpoint tail 回滚年轻分配，并将这些 PRD
逐周期归还。恢复期间暂停 Rename，允许用数周期换取较短关键路径。ROB 深度为 32，必须
保证任一活动 checkpoint 后的未决 PRD 分配数小于 allocation log 容量。

checkpoint 与 `alloc_fire` 同周期保存。`checkpoint_keep_count_i` 指明当前 bundle 中应保留
在 checkpoint 之前的 PRD 数：lane0 分支时不得错误保留 lane1 的年轻 PRD；lane1 分支时
可包含 lane0 和 lane1 自身的目的 PRD。checkpoint clear 只释放日志位置标记，不改 bitmap。

allocation log 动态读取必须先进入 `rollback_prd` 寄存器，下一拍才写 free bitmap，禁止
`64:1 log read mux → bitmap write decoder` 同周期级联。

若最终选择 bitmap snapshot，必须将 snapshot 寄存分布实现，恢复也在本地时序完成。

## 6. 异常重建

rebuild_start 后：

1. 将临时 used bitmap 清零并标记 p0。
2. 每周期扫描 2 至 4 个 AMT 项，标记其 PRD 已使用。
3. 扫描完毕后 free_bitmap = ~used_bitmap，并强制清 p0。
4. 更新 group_nonempty，拉高 rebuild_done。

AMT 的动态双项读取与 used-bitmap 标记必须由寄存器隔开；恢复多一个启动周期可以接受，
不得形成 `32:1 AMT mux → 64-bit used decoder/update` 的单周期路径。

## 7. 断言

- 已分配 PRD 在分配前必为空闲。
- reclaim PRD 不为 p0，且不会重复置位。
- 双分配结果不同。
- free_count 等于 bitmap popcount。
- 重建结束后 AMT 中所有 PRD 均非空闲。

## 8. 200 MHz OOC 问题记录与整改约束

2026-07-04 的真实 5.000 ns OOC 综合报告显示：WNS=-1.413 ns、TNS=-10.926 ns，16 个
失败端点。最差路径为 `selection_prd0_q_reg[1] → reservation_prd1_q_reg[1]`，数据路径
6.387 ns，共 17 级逻辑，其中包含 6 个 CARRY4；报告状态为 synthesized/unplaced。

整改要求：

- `pick_group` 不得使用 `integer` 循环加法计算旋转 group index，改为显式四路固定顺序。
- S0 寄存 PRD0 时同时寄存 one-hot exclude mask，S1 不再动态解码 PRD0 清除 bitmap bit。
- 偶/奇候选尽量并行生成，不把 parity fallback、group select 和 bit select 串成一条长链。
- 若结构重写后 5 ns WNS 小于 +1.0 ns，继续增加 S1 内部寄存边界；吞吐/延迟让位于时序。
- 整改后必须重新保存 5.000 ns 与 4.000 ns OOC timing summary。5 ns 目标 WNS≥+1.0 ns，
  4 ns 目标 WNS≥0，且关键选择路径不再包含旋转索引产生的 CARRY4。

该问题关闭前，Free List 的功能测试通过不代表模块达到完成定义。
