# ROB/Commit/Rename 时序优化方案

日期：2026-07-03
基线提交：`d82ff3b Pipeline LSQ age and forwarding logic`
参考交接：`fpga_handoff_20260703_lsq_rob_timing/`
目标：在不降低当前 RTL 功能门禁的前提下，按开源高性能乱序核的结构思路，切断当前 ROB/commit/free-list release 长组合路径，并为后续 200 MHz FPGA 收敛建立分阶段路线。

## 1. 当前问题

LSQ 已完成本地年龄矩阵、Load 的 older-store mask、Store drain 独立流水和 Load forwarding 分级后，quick place 的主瓶颈已经从旧的 LSQ memory select 路径转移到提交/恢复/Free List release 簇。

`fpga_handoff_20260703_lsq_rob_timing/reports/top_worst_paths_quick.rpt` 中当前最差路径为：

- Source：`u_fpga_core/u_core/u_backend/u_rob/head_ptr_reg[0]_rep__20/C`
- Destination：`u_fpga_core/u_core/u_backend/u_rename/u_free_list/free_bitmap_reg[41]/D`
- Slack：`-11.666 ns`
- Data path delay：`16.295 ns`
- Route delay：`14.827 ns`，约 `90.991%`
- Logic levels：`22`

报告中的路径实际跨越：

```text
ROB head/entry commit candidate
  -> LSQ store_commit_ready / CSR / FENCE commit gating
  -> commit_controller commit_ready/recover
  -> ROB commit_fire / commit_map
  -> RAT/RRAT rrat_next / recover_used_mask
  -> Free List free_mask / recover free_bitmap write
```

另一个高优先级簇来自 `u_lsq/entries_reg[*][valid]` 到 Rename FIFO `CE`，说明 dispatch capacity/ROB allow/LSQ capacity 仍能反向影响 Rename FIFO 写使能，属于资源 ready 控制的跨模块扇出问题。

## 2. 开源高性能核可借鉴原则

### 2.1 BOOM

BOOM ROB 文档给出的关键做法：

- ROB 是循环队列，commit head 指向最老指令，tail 指向最新指令。
- 超标量提交在 ROB row 内贪婪提交，不跨多个 row 做过宽组合搜索。
- Store 提交后，ROB 通知 LSU 有多少 Store 可以标记为 committed；Store 之后由 LSU 按程序序排到内存，而不是让提交路径直接形成 Store drain 的宽组合选择。
- 写寄存器指令提交时，stale physical destination 返回 Free List。
- flush/exception 可选择通过 committed map table 单周期恢复，或者逐行 rollback。

BOOM Rename 文档还明确：

- explicit renaming 使用 physical register file，Map Table 保存推测映射。
- 可选 Committed Map Table 保存已提交架构状态，flush/exception 时可以用它单周期恢复。
- Free List 是 bit-vector，多发射通过级联 priority decoder 分配。
- stale pdst 在指令提交后返回 Free List。
- 分支恢复中使用 Allocation List 回收分支之后分配的物理寄存器，避免简单 Free List 快照造成寄存器泄漏。

对本项目的含义：

1. Commit 的架构状态更新与 Free List 回收可以是明确的本地顺序事件，但不应把完整 commit gating、RRAT 更新、recover used-mask 和 free_bitmap D 端合成同一拍大网络。
2. 已提交 Store 的排空控制应保留在 LSQ 本地，本项目当前已基本符合。
3. 如果继续坚持 RRAT committed map table 单周期恢复，需要把“恢复控制”和“普通提交回收”拆成不同路径，避免每个普通提交都驱动恢复重建网络。

### 2.2 XiangShan

XiangShan ROB 源码显示其 ROB 使用多 bank 组织，bank 读地址本身寄存，commit 读取通过当前行/下一行缓存组织，而不是每拍从大表组合读出全部提交信息。

XiangShan StoreQueue forwarding 源码体现了更直接的时序原则：

- S0 根据 `deqPtr` 与 Load 的 `sqIdx` 生成环形年龄 mask。
- S0 到 S1 用 `RegEnable` 寄存 Load 范围、StoreSet 命中、Load sqIdx、age mask 等信息。
- S1 到 S2 再寄存选中 Store entry、数据无效/地址无效信息、forward one-hot、Load mask、Load 地址等。
- S2 才生成最终 forward data、mask、invalid/replay 响应。

对本项目的含义：

1. 大范围队列读取和选择结果应先寄存 index/one-hot，再用下一拍组装宽数据。
2. 全局指针和队列状态不要直接穿透到远端位图寄存器 D/CE。
3. 控制路径也应像数据 forwarding 一样建立“候选选择 -> 事件包寄存 -> 本地状态更新”的边界。

### 2.3 当前已采用、无需重复的部分

`rtl/core/lsq.sv` 已经吸收了 BOOM/XiangShan 的 LSQ 思路：

- 用 `age_older[DEPTH][DEPTH]` 替代 ROB head 减法。
- 用每个 Load 的 `older_store_mask` 表达 Store 依赖集合。
- Store drain 基于本地 `store_seq == store_drain_head`。
- Load forwarding 分成 `load_s0`、`load_s1` 和最终请求/转发生成。
- Completion 先寄存 select idx/tag，再组装 writeback bus。

下一阶段不应优先继续拆旧的 Load forwarding，而应先处理 commit/release 控制簇。

## 3. 推荐总体方向

当前最差路径的本质是“提交是否发生”这个组合结果同时驱动太多远端状态：

- ROB 自身 head/entry valid；
- RRAT 更新；
- Free List stale pdst 回收；
- recover_used_mask 重建；
- Rename FIFO/Dispatch 资源 ready；
- CSR/LSQ/FENCE 提交门控。

建议把提交拆成两个层次：

1. **Commit decision 层**：只决定 ROB 本拍是否提交、触发 trap/recover、更新 ROB head。
2. **Retirement side-effect 层**：把已提交的架构映射、stale pdst、CSR side effect、Free List release 作为寄存事件，在后一级本地消费。

这样普通提交回收允许晚一拍进入 Free List。当前设计已经规定本拍回收标签下一拍才参与分配，因此再增加一拍 release pipeline 对正确性影响小，主要影响极端满 PRF 时的短暂吞吐。

## 4. 分阶段实现方案

### 阶段 A：寄存 commit_map / free release 事件

优先级：最高。

新增一组 retirement pipeline 寄存器，建议位置在 `backend_top` 或 `rename_stage` 输入边界：

```systemverilog
commit_map_bundle_t commit_map_q;
phys_reg_event_bundle_t free_event_q;
```

基本规则：

- `rob.sv` 继续组合产生 `commit_map`，用于本拍 ROB/commit 语义。
- `rename_stage` 不再直接用组合 `commit_map` 驱动 `free_list.free_event`。
- `commit_map_q <= commit_map` 后，下一拍再送入 `rat_rrat.commit_map` 和 `free_list.free_event`。
- `free_list.free_bitmap_next` 只依赖本地 `free_bitmap`、`alloc_mask` 和寄存后的 `free_event_q`。

预期收益：

- 切断 `ROB head/store_commit_ready -> free_bitmap_reg[*]/D`。
- Free List 的 D 端不再看到提交控制大锥。
- `commit_map[lane*]` 高扇出从组合远端控制变成局部寄存输出。

正确性注意：

- RRAT 更新晚一拍后，recover 不能简单继续使用原组合 `recover.valid` 与未更新 RRAT。
- 需要保证 recovery 恢复到“已经提交且架构可见”的状态。建议阶段 A 同时引入阶段 B 的 recover 对齐。

### 阶段 B：恢复事件与 retirement side-effect 对齐

优先级：最高，必须与阶段 A 一起设计。

当前 `writeback_commit_stage` 已经把 `recover_next` 寄存成 `recover_reg`，下游实际看到的 `recover_o.valid` 已晚于 `controller_recover` 一拍。这给对齐提供了空间。

建议语义：

```text
Cycle N:
  ROB commit_fire 发生，commit_map 组合形成
  controller_recover/fence_i_recover 组合形成 recover_next

Cycle N+1:
  commit_map_q 更新 RRAT
  recover_reg 对外有效
  rat_rrat 在 recover.valid 下使用含 commit_map_q 的 rrat_next 恢复 RAT
  free_list 使用含 commit_map_q 的 recover_used_mask 重建 free_bitmap
```

实现要点：

- `rat_rrat.commit_map` 改接 `commit_map_q`。
- `free_list.free_event` 改接从 `commit_map_q.stale_pdst` 派生的事件。
- `recover` 保持现有寄存后一拍广播。
- 对异常指令：`commit_map_q.valid` 仍由 ROB 过滤 `!exception_valid`，异常指令自身不提交目标映射。
- 对误预测分支自身写 rd 的情况：如果该分支有 `pdst_valid` 且非 exception，`commit_map_q` 会在 recover 同拍更新 RRAT，满足“分支自身映射提交后恢复”的原约束。

需要增加断言：

- `recover.valid` 同拍，`rat_rrat` 使用的是寄存提交包对应的 `rrat_next`。
- `commit_map_q` 不得在 `recover.valid` 被错误清零，否则会丢失恢复边界那条已提交映射。
- `free_event_q` 中两个 stale pdst 不得为同一非零物理寄存器，除非上游 commit_map valid 已过滤。

### 阶段 C：拆分 commit_ready 与 resource_ready 高扇出

优先级：高。

`commit_controller` 目前组合读 `store_commit_ready`、`csr_commit_ready`、`fence_commit_ready`，再驱动 ROB `commit_ready`，进而影响 `commit_fire` 和全局 side effect。

建议：

1. 在 `backend_top` 增加局部寄存：

```systemverilog
logic [1:0] store_commit_ready_q;
logic [1:0] csr_commit_ready_q;
logic       fence_commit_ready_q;
```

2. 第一版只在无 recovery 时更新这些 ready 快照，commit_controller 使用快照。
3. Store commit ready 晚一拍会让 Store commit 最多多等一拍；CSR/FENCE ready 晚一拍同理，但能显著降低 LSQ/CSR 到 ROB head/free-list 的组合穿透。

风险：

- 如果 `store_commit_ready_q` 为 1 后对应 LSQ 条目被 recovery 清掉，必须由 `recover.valid` 清快照或让 commit_controller 在 recover 同拍禁止 commit。
- 对 FENCE.I，必须保持 `fence_commit_ready` 对 Core 外 Store 请求寄存级可见性的原约束，宁可多等一拍，不能提前。

### 阶段 D：ROB commit bus 本地寄存化

优先级：中高。

XiangShan 的 ROB bank 读地址寄存给出一个方向：commit 信息读取可以先形成本地 head row 缓存，再由 commit_controller 消费，而不是每拍让 `head_ptr` 通过 ROB entries 直接驱动远端控制。

本项目可保守实现：

- 在 `rob.sv` 内增加 `commit_bus_q`，缓存 head/head+1 的可提交候选。
- `commit_ready` 消费 `commit_bus_q`。
- `commit_fire` 对 `commit_bus_q` 生效，ROB head 下一拍推进。

这会让提交决策增加一拍，但能把 `head_ptr -> entries mux -> commit_controller` 与远端 release 分开。建议在阶段 A/B/C 后根据新 timing report 决定是否实施。

### 阶段 E：Rename/Dispatch resource ready 局部化

优先级：中。

quick report 中的第二类路径是 `LSQ entries.valid -> Rename FIFO CE`。当前资源容量大致路径为：

```text
LSQ entries.valid -> lsq_capacity
  -> dispatch dp_ready
  -> rename FIFO dequeue/free space
  -> rename_fire / renamed_fifo CE
```

建议：

- 给 `iq0_capacity/iq1_capacity/lsq_capacity/rob_allowin` 增加 Dispatch 边界寄存快照。
- Dispatch 使用上一拍容量，资源实际入队仍由目标队列 `enq_fire`/断言保护。
- 或者在 Rename 输出 FIFO 和 Dispatch 之间增加一项 dispatch issue buffer，让 Rename FIFO CE 不直接依赖 LSQ/IQ 当前容量。

这属于吞吐和时序权衡：容量晚一拍会增加偶发气泡，但对 FPGA 200 MHz 更友好。

## 5. 建议实施顺序

### 里程碑 1：Commit map pipeline

范围：

- `backend_top.sv` 或 `rename_stage.sv` 增加 `commit_map_q`。
- `rat_rrat.commit_map` 和 `free_list.free_event` 改用寄存提交包。
- recovery 与 `commit_map_q` 对齐。

验收：

- `tb_rename_state`
- `tb_rename_stage`
- `tb_rob`
- `tb_backend_control`
- `tb_core_combo_branch_recovery`
- `tb_core_combo_trap_interrupt`
- `tb_core_combo_fence_i_smc`
- `scripts/run-regression.ps1 -Mode unit`
- `scripts/run-regression.ps1 -Mode all`

Timing 验收：

- quick report 不再出现 `u_rob/head_ptr* -> u_rename/u_free_list/free_bitmap_reg[*]/D` 作为 top path。
- `commit_map` 或 `recover_used_mask` 不再是跨大范围 route 的 top fanout。

### 里程碑 2：Commit resource ready snapshots

范围：

- 寄存 `store_commit_ready`、`csr_commit_ready`、`fence_commit_ready`。
- commit_controller 使用局部 ready 快照。
- recovery 清空或屏蔽 ready 快照。

验收：

- Store/FENCE/CSR 相关定向测试必须重点跑。
- `tb_core_exception_fence` 和 `tb_core_combo_fence_i_smc` 不得回退。
- quick report 中 LSQ/CSR 到 ROB/FreeList 的组合穿透应消失或显著下降。

### 里程碑 3：ROB commit candidate register

范围：

- 在 ROB 内缓存 head/head+1 commit candidate。
- 让 commit_controller 消费已寄存 candidate。
- 保持 commit_fire 前缀语义。

验收：

- 全量回归。
- 检查提交追踪 PC 顺序、异常精确性、中断 `mepc`。
- 关注吞吐下降是否可接受。

### 里程碑 4：Dispatch capacity snapshots

范围：

- `lsq_capacity/iq_capacity/rob_allowin` 局部寄存或通过 dispatch buffer 解耦。
- Rename FIFO CE 不再直接依赖 LSQ entries valid。

验收：

- dispatch、backend datapath/control、全部 core combo。
- quick report 中 `u_lsq/entries_reg[*][valid] -> u_rename/renamed_fifo_reg[*]/CE` 不再是 top path。

## 6. 必须补充的验证点

1. 同拍双提交写同一架构寄存器，RRAT 最终仍为 lane1 pdst，两个 stale pdst 回收顺序正确。
2. 分支误预测指令自身写 rd，提交后 recovery，RAT/Free List 与 RRAT 一致。
3. 异常指令到达 ROB head，异常指令自身的推测 pdst 不进入 RRAT，不释放错误 stale pdst。
4. `recover.valid` 与 `commit_map_q` 同拍时，Free List 重建使用含已提交映射的 used mask。
5. Free List 只因寄存 release 包回收 stale pdst，不能受组合 `commit_fire` 直接影响。
6. Store commit ready 快照导致 Store 多等一拍时，不影响 ROB 顺序提交和 LSQ store drain。
7. FENCE/FENCE.I 在 capacity/ready 寄存化后仍等待 LSQ 和 Core 外 DMEM 请求寄存级完全排空。
8. 机器中断在空 ROB 或安全边界采样时，`mepc` 仍等于 `retire_next_pc` 或 lane0 PC。

## 7. 不建议的做法

- 不建议只加 `(* max_fanout *)`、`dont_touch` 或手工复制 `head_ptr` 来掩盖问题。当前路径 route 占比超过 90%，说明物理跨度和控制穿透才是主因。
- 不建议把 Free List 恢复从 `recover_used_mask` 改成简单 Free List snapshot。BOOM 文档明确指出简单快照会在“分配、释放、再分配”序列中泄漏物理寄存器。
- 不建议让 Store drain 再回到 ROB head 全局年龄比较。LSQ 已经完成本地化，回退会重建旧瓶颈。
- 不建议为了快速 timing 而放宽 FENCE.I 的 LSQ empty + extra empty cycle 约束；该约束修复过自修改代码旧指令采样问题。

## 8. 参考资料

- BOOM ROB and Dispatch documentation: https://docs.boom-core.org/en/latest/sections/reorder-buffer.html
- BOOM Rename Stage documentation: https://docs.boom-core.org/en/latest/sections/rename-stage.html
- BOOM LSU documentation: https://docs.boom-core.org/en/latest/sections/load-store-unit.html
- BOOM LSU source: https://github.com/riscv-boom/riscv-boom/blob/master/src/main/scala/v4/lsu/lsu.scala
- XiangShan ROB source: https://github.com/OpenXiangShan/XiangShan/blob/kunminghu-v3/src/main/scala/xiangshan/backend/rob/Rob.scala
- XiangShan StoreQueue source: https://github.com/OpenXiangShan/XiangShan/blob/kunminghu-v3/src/main/scala/xiangshan/mem/lsqueue/NewStoreQueue.scala

## 9. 最终判断

当前最差路径已经不是 LSQ 转发算法本身，而是提交事件穿透多个后端子系统后直接写 Rename/Free List 状态。高性能开源核的共同原则是：全局顺序边界由 ROB 维护，但宽状态更新、Store drain、Free List release 和 forwarding 都应通过本地事件包、局部指针或寄存化选择分阶段完成。

建议下一次 RTL 修改从“commit_map/free_event 寄存化 + recover 对齐”开始。该改动范围小、语义清楚、直接命中最差路径终点；完成回归和 quick timing 后，再决定是否继续寄存 commit resource ready 与 ROB commit candidate。
