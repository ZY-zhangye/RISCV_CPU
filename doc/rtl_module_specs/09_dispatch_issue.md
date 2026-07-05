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

### 4.1 当前 RTL 实现状态

截至 2026-07-04，`rtl/dispatch/dispatch_buffer.sv`、`rtl/issue/issue_queue.sv` 已完成
V1 RTL 与 directed test。

Dispatch Buffer 当前实现为 6 项固定槽环形队列，支持 Rename 双路输入并按顺序向
INT/MEM/MDU 三类 IQ 分发。lane0 阻塞时 lane1 不越过；recovery 周期整 buffer flush，
用于避免固定槽队列产生复杂 head hole 处理路径。

Issue Queue 当前实现为参数化固定槽队列，默认 `ENTRIES=12`、`GROUPS=3`，字段数组存储，
支持双入队、双写回 tag wakeup、分支恢复 kill、延迟清除 issued slot。为满足
XC7K325T-FFG900-2 上 200 MHz 以上时序，select 路径已经拆为两级：

1. S0：每组内每 2-entry pair 先完成 ready/age 选择，并寄存 pair winner。
2. S1：每 group 从 pair winner 中选择最终 candidate 并对外输出。

该结构切断 `valid/src_ready/need_rs/rob_id -> candidate_slot` 的长组合路径。代价是
wakeup 或 push 后 candidate 可见延迟增加约 1 拍；grant 后当前 group 插入 1 拍 bubble，
防止刚授权的旧 candidate 被重新送出。2026-07-04 用户后台单模块综合报告显示
`issue_queue` 在 5.000 ns 约束下 WNS=+1.167 ns，当前不再继续局部优化。

## 5. 全局 Issue Arbiter

输入为各队列候选和执行端 ready，输出最多三条 issue slot。检查：

- 总发射数不超过 3。
- INT0/INT1/LSU/MDU 端口唯一。
- Branch 只去 INT1。
- PRF 每个 Bank 读源数不超过 3。
- MDU 当前操作类型可接受。
- memory candidate 已经通过 LSQ 发射许可。

仲裁结果必须寄存后再驱动 PRF Read。未授权 candidate 保留在 IQ。

### 5.1 当前 RTL 实现状态

截至 2026-07-05，`rtl/issue/issue_arbiter.sv` 与
`test/tb_issue_arbiter.sv` 已完成 V1 RTL 和 directed test。实现时序优先级高于
单周期发射激进度：

- 输入只接收各 IQ 已寄存 candidate，不直接连接 IQ 内部 ready/select 组合逻辑。
- 仲裁输出必须寄存后再进入 PRF Read / operand_read。
- 第一版允许固定优先级加小范围年龄比较，不实现全局完整 oldest 矩阵。
- 如果单模块 5.000 ns WNS 小于 +0.3 ns，则优先把“候选挑选”和“PRF bank 检查”再拆为两拍。

V1 规则：

- 全局总发射数不超过 3。
- INT 最多 2 条，INT0/INT1 各一条；Branch 只能进入 INT1。
- LSU 最多 1 条；MDU 最多 1 条。
- PRF bank 读源计数每 bank 每周期不超过 3，只统计 `need_rs1/need_rs2`。
- 执行端 not ready、LSQ 未许可或 MDU 不可接受时，对应 candidate 不授权。

初版单拍仲裁在补齐 OOC 输入/输出延迟约束后 WNS 为 -5.254 ns，最差路径为
`int_candidate_valid_i[1] -> mdu_issue_grant_o`，包含 18 级 LUT。当前实现据此拆成两级：

1. P0 使用约束优先的固定优先级，先安置只能进入 INT1 的 Branch 和只能进入 INT0 的
   Shift，再填充普通 INT，并各预选一个 LSU、MDU proposal；proposal 及 Bank 读数寄存。
2. P1 只对最多四个已寄存 proposal 执行全局三发射和偶/奇 Bank 读数限制，三个 issue
   slot 及执行端口标签在末级寄存。

Issue Queue 同步改为 valid/ready 保持语义：未获得 grant 的 visible candidate 保持不变，
使多拍仲裁不会清除错误 slot。P1 在产生延迟 grant 前再次检查来源 group valid、执行端
ready 和 LSQ/MDU 许可；recovery 同周期抑制 grant，并清空 proposal 与 issue 输出。

两级版本首次 OOC WNS 为 -3.372 ns；最差路径仍在 P1，报告中出现 4 个 `CARRY4`。
根因是组合循环使用 32-bit `integer` 作为 proposal/issue 计数器，Vivado 将计数、比较和
动态 issue-slot 索引展开成长 carry 链。当前已将 proposal count 收窄为 3 bit、issue
count 收窄为 2 bit。收窄后 OOC WNS 改善到 -1.268 ns，最差路径降为 10 级逻辑，但
P1 的早期 proposal 取舍仍直接影响最终 MDU grant 并扇出到完整 issue payload。

当前进一步加入 selected-mask 寄存层，形成三段式结构：P0 预选 proposal，P1 只计算并
寄存 4-bit Bank/宽度 selected mask，P2 独立复核每个 selected proposal 的 ROB-ID、
source valid、endpoint ready 与 LSQ/MDU 许可，再并行生成 grant 并打包寄存 issue
slot。ROB-ID 身份复核可阻止深流水中的 stale proposal 误 grant 同 group 的新候选。
三段式功能回归通过。最终 5.000 ns OOC WNS 为 +1.821 ns、TNS 为 0，最差数据路径
3.153 ns（7 级逻辑）；资源为 2111 LUT、1371 FF。当前实现冻结，后续仅在集群或完整
核 route 暴露问题时再调整。

实现 Operand Read 前补齐了 `issue_uop_t` 中原先丢失的 `pc`、`pred_taken`、
`pred_target` 和 `checkpoint_id`。字段扩展后重新执行 5.000 ns OOC，最终 WNS 为
+1.031 ns、TNS 为 0；资源为 2897 LUT、2102 FF。时序余量仍超过 +1 ns，继续冻结。

QuestaSim directed test 已覆盖三段寄存边界、Branch/Shift 端口约束、全局三发射上限、
执行端 ready、LSQ/MDU 许可、PRF Bank 限额、未就绪源防御检查、stale proposal
抑制和 recovery 清空。

## 6. Kill 与恢复

误预测时每个 entry 本地计算 branch_mask[checkpoint_id] 并清 valid。正确预测只清该
mask 位。恢复事件优先于 push、wakeup 和 issue。

## 7. 断言

- 同一 IQ slot 不会被同时重复分配。
- issue_grant 只授予 valid 且 ready 的项。
- 发射项在周期末从 IQ 清除一次。
- 每 Bank 源读计数不超 3。
- 被 kill 的项不得出现在下一周期 RR。
