# Rename、RAT 与 AMT 设计

建议模块名：rename_stage、rat_amt。Rename 的关键组合逻辑分为 R0 Map Read 和 R1
Ready/Allocate；入口 elastic register 不计入逻辑级命名。

## 1. 端口

| 方向 | 端口 | 类型 | 说明 |
|---|---|---|---|
| input | dec_valid_i | 2-bit | 双路前缀有效 |
| output | dec_ready_o | 1 | R0 输入寄存器可接收 |
| input | dec_uop0_i / dec_uop1_i | 2×decoded_uop_t | 译码微操作 |
| output | rn_valid_o | 2-bit | 已重命名 bundle |
| input | rn_ready_i | 1 | Dispatch Buffer 可接收 |
| output | rn_uop0_o / rn_uop1_o | 2×renamed_uop_t | 物理寄存器和各类 ID |
| input | commit_map0_i / commit_map1_i | 2×commit_map_t | AMT 更新事件 |
| input | wb_ready_set_i | 2×PRD | 写回 ready 更新 |
| input | recovery_i | recovery_t | 分支或异常恢复 |
| output | alloc_req_o | alloc_req_t | Free List/ROB/LSQ/Checkpoint 需求 |
| input | alloc_resp_i | alloc_resp_t | R1 使用的已寄存分配结果 |
| output | alloc_fire_o / alloc_cancel_o | 1 / 1 | 原子消耗或恢复取消保留资源 |

## 2. RAT/AMT

RAT 和 AMT 均为 32×6-bit 寄存器阵列。x0 始终映射 p0。

- RAT 是推测映射，由 Rename R1 更新。
- AMT 是已提交映射，由 Commit 更新。
- 分支恢复从 checkpoint 恢复 RAT。
- 精确异常恢复把 RAT 逐项或双项复制为 AMT，不走单周期 32 项大多路器。

## 3. R0 时序

R0 组合读取最多四个源映射和两个旧目的映射。周期末锁存：

- lane0 的 prs1/prs2/old_prd。
- lane1 的基础 RAT 结果。
- 两 lane 资源需求。
- lane 内 RAW/WAW 比较所需的架构寄存器信息。

R0 不查询 PRD ready table，不执行 Free List 优先编码，也不写 RAT。禁止形成
`RAT map mux → PRD ready mux` 的同周期级联路径。

## 4. R1 时序

R1 使用 R0 已寄存的 PRD 编号查询 ready table，并在该侧执行最多两路 WB tag bypass。
R1 从已寄存并保持的 allocator response 获得最多两个 PRD、ROB ID、LQ/SQ ID 和最多一个
checkpoint。发生 rn_fire 时原子执行：

1. 生成 lane0/lane1 最终 prs、prd、old_prd。
2. 更新 RAT，WAW 时 lane1 最终覆盖 lane0。
3. 清新 PRD ready。
4. 向 ROB 和相应队列发送分配写入。
5. 将 renamed_uop 写入 Dispatch Buffer。

所有资源必须同时可用才允许该 lane 接受。双路不能出现部分写 ROB、未写 IQ 的状态。
alloc_req/alloc_resp 使用前缀 `lane_valid`，并分 lane 表达 PRD/LQ/SQ/Checkpoint 需求。
allocator 的 response 在 `alloc_fire_o` 前只保留不消耗；恢复冲刷 R1 时由
`alloc_cancel_o` 释放保留。

`alloc_req_o` 到 `alloc_resp_i` 不允许存在同周期组合返回路径。Free List 的选择结果必须
先进入 reservation/response 寄存器；response 到达前请求 payload 必须保持稳定。

## 5. Lane 内依赖

RAW：lane1 的源寄存器命中 lane0.rd 时，使用 lane0.new_prd，ready=0。

WAW：lane1.rd 等于 lane0.rd 时，lane1.old_prd=lane0.new_prd，最终 RAT 指向
lane1.new_prd。lane0 的 old_prd 仍在 lane0 提交时回收。

x0 不分配新 PRD，不产生 WAW/RAW 物理依赖。

## 6. 接受宽度

lane0 若资源不足则两 lane 均停。lane0 可接受但 lane1 资源不足时，允许单收 lane0，
lane1 必须由 Decode/R0 弹性寄存器保持并在下一次成为 lane0。序列化指令后不得同周期
分配更年轻 lane。

## 7. 恢复

分支误预测时：

- 恢复 checkpoint RAT snapshot。
- 清空 R0/R1 中所有错误路径 uop。
- allocator 使用 checkpoint 保存的 tail/bitmap 恢复。

异常时进入 restore FSM：停止新分配，RAT←AMT，触发 Free List 重建，完成后恢复 ready。

## 8. 关键断言

- 同一周期所有资源分配与 rn_fire 原子一致。
- RAT[x0] 和 AMT[x0] 始终为 p0。
- 任一 active RAT 映射不指向 Free List 中的空闲 PRD。
- lane1 RAW/WAW 结果与顺序执行两个单独 rename 等价。

## 9. 200 MHz OOC 状态与集成风险

2026-07-04 的 5.000 ns synthesized/unplaced OOC 结果：`rename_stage` WNS=+2.468 ns，
`rat_amt` WNS=+2.529 ns。最差内部路径分别只有 3 级和 4 级 LUT，说明 RAT map/PRD ready
分拍有效，当前不需要再次切分正常 Rename 路径。

仍需保留以下风险约束：

- 单模块 OOC 不包含真实 Free List reservation 和 Dispatch Buffer 布线，必须补做
  `rename_stage+free_list+dispatch_buffer` 成组 OOC。
- allocator response 必须来自寄存 reservation；禁止因为 Free List 延迟增加而改回组合返回。
- branch checkpoint snapshot、branch mask clear 和恢复控制在完整核中可能形成高扇出。
  若 route 报告命中，应采用 RAT 分组、控制复制或分组恢复，不增加正常路径全局 bypass。
- `rat_amt` 当前 1960 LUT、1193 FF，`rename_stage` 为 2205 LUT、2260 FF；面积可接受，但
  checkpoint snapshot 的布局应尽量靠近 RAT banks。

## 10. Resource Manager V1 实现状态（2026-07-05）

`rtl/rename/rename_resource_manager.sv` 负责 Rename 与 Free List、LSQ、Branch
Checkpoint File、ROB 之间的原子分配协调：

- 三态 `IDLE/RESERVE/WAIT_FIRE` 保存请求和已返回 response 的生命周期。
- Free List、LSQ 与 Checkpoint 各自完成注册式 reservation 后，管理器才返回完整
  `alloc_resp_t`；ROB ready 与两路 ID 同时纳入授权条件。
- PRD/LQ/SQ 的紧凑分配结果按 `need_*` mask 重新散布到 lane0/lane1。
- Rename 最终 fire 或 recovery cancel 同拍广播给所有参与资源，ROB 仅在 fire 时看到
  lane valid，避免部分资源被单独消耗。
- response 接受后由 `alloc_commit_ready_o` 再次汇总 reservation 与 ROB ready；顶层必须
  用它门控 Rename 到 Dispatch 的最终 ready，避免 ROB 正在 branch-clear 扫描时其他资源
  提前 fire。
- V1 保守等待完整 bundle，不做资源不足时的 lane0 提前授权；资源释放后请求可继续，
  不影响正确性，后续仅在性能测试证明必要时增加 prefix grant。

`test/tb_rename_resource_manager.sv` 覆盖 staggered reservation、完整 bundle 原子响应、
compact ID lane scatter、response 后 fire/cancel、ROB 临时 busy 的最终 fire 门控、
reservation 中途 flush，以及无子资源的 ROB-only 分配。QuestaSim 2024.1 最小测试和
27 项当前回归均通过，
`Errors: 0, Warnings: 0`。

## 11. Rename Allocation Cluster V1（2026-07-05）

`rtl/rename/rename_allocation_cluster.sv` 将 Resource Manager、Free List、LSQ Allocator
和 Branch Checkpoint File 组合为单一原子分配边界，并根据最终 rename uop 生成 PRD/LQ/SQ
checkpoint keep-count、父分支 mask 和 ROB restore tail。分支恢复同时启动 Free List 与
LSQ rollback，精确异常同时启动 AMT-based Free List rebuild、LSQ flush 和 checkpoint flush。

`test/tb_rename_allocation_cluster.sv` 使用真实四模块覆盖 lane1 分支同 bundle PRD 保留、
零访存分配 checkpoint、年轻 Load/Store rollback、ROB restore tail、正确分支释放和异常
重建。QuestaSim 2024.1 最小测试及当前 28 项回归均通过，`Errors: 0, Warnings: 0`。

用户 5.000 ns OOC 综合 WNS 为 +0.846 ns。Free List reclaim FIFO 空位计算中的无尺寸
32-bit 常量已改为显式 2-bit 运算，避免不必要的宽算术路径；修改后需执行最终回归。

当前完成门槛保持不变：成组 OOC 4.000 ns WNS≥0，完整 route 后 5.000 ns WNS/WHS≥0。
