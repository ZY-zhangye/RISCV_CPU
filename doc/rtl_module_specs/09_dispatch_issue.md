# Dispatch Buffer、Issue Queue 与全局发射设计

建议模块：dispatch_buffer、integer_iq、memory_iq、muldiv_iq、issue_arbiter。

## 1. Dispatch Buffer 端口

| 方向 | 端口 | 类型 | 说明 |
|---|---|---|---|
| input | rn_valid_i | 2-bit | 已重命名 uop |
| output | rn_ready_o | 1 | 可完整接收 |
| input | rn_uop_i | 2×renamed_uop_t | 输入 |
| output | iq_push_valid_o | 2-bit | 最多分发两条 |
| input | iq_push_ready_i | per class | 各分类队列容量 |
| output | iq_push_uop_o | 2×issue_uop_t | 分类输出 |
| input | recovery_i | recovery_t | 本地 kill |

Dispatch Buffer 建议 6 项固定槽环形队列，不整体移动。它按程序顺序检查前两项并路由
到 Integer、Memory 或 MDU IQ。只有目标 IQ 接收时才出队；允许 lane0 出队而 lane1
保留，但不允许 lane1 越过被阻塞的 lane0，以保持分发简单。

## 2. IQ 公共端口

| 方向 | 端口 | 说明 |
|---|---|---|
| input | push_valid_i[1:0] | 最多两项写入空槽 |
| output | push_ready_o | 本地 free_count 足够 |
| input | wb_tag_i[1:0] | 两个写回 PRD tag |
| output | candidate_o | 分组选择候选 |
| input | issue_grant_i | 全局仲裁授权 |
| input | branch_event_i | 清 mask 位或 kill |

IQ entry 保存 valid、rob_id、prd、prs1/prs2、ready bits、操作字段、branch_mask 和
LSQ ID。写入时选择固定空槽，不做压缩。

## 3. Wakeup 周期

周期 N 的 WB tag 与每个 entry 的源 tag 比较，在周期末只更新 ready bit。新 ready 的
entry 最早在周期 N+1 参与 Select。禁止同周期 wakeup-select。

Dispatch 入队时可旁路同周期 WB tag 计算初始 ready，但结果也只在下一周期选择。

## 4. 分组 Select

Integer IQ 12 项分 3 组，每组 4 项：

1. 每组本地选一个 ready 且最老的候选。
2. 候选寄存。
3. 全局 issue_arbiter 从三个候选中最多选两个。

Memory IQ 8 项可分 2 组；MDU IQ 4 项单组。年龄使用 ROB 环形年龄函数，不使用完整年龄
矩阵。候选只携带 RR 所需字段。

## 5. 全局 Issue Arbiter

输入为各队列候选和执行端 ready，输出最多三条 issue slot。检查：

- 总发射数不超过 3。
- INT0/INT1/LSU/MDU 端口唯一。
- Branch 只去 INT1。
- PRF 每个 Bank 读源数不超过 3。
- MDU 当前操作类型可接受。
- memory candidate 已经通过 LSQ 发射许可。

仲裁结果必须寄存后再驱动 PRF Read。未授权 candidate 保留在 IQ。

## 6. Kill 与恢复

误预测时每个 entry 本地计算 branch_mask[checkpoint_id] 并清 valid。正确预测只清该
mask 位。恢复事件优先于 push、wakeup 和 issue。

## 7. 断言

- 同一 IQ slot 不会被同时重复分配。
- issue_grant 只授予 valid 且 ready 的项。
- 发射项在周期末从 IQ 清除一次。
- 每 Bank 源读计数不超 3。
- 被 kill 的项不得出现在下一周期 RR。
