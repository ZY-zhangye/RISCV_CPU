# Commit、CSR 与 Recovery 设计

建议模块：commit_unit、csr_file、branch_checkpoint_file、recovery_controller。

## 1. Commit 端口

| 方向 | 端口 | 类型 | 说明 |
|---|---|---|---|
| input | rob_head_valid_i | 2-bit | ROB head row |
| input | rob_head_i | 2×rob_entry_t | 两条最老指令 |
| output | retire_count_o | 2-bit | 0/1/2 |
| output | amt_update_o | 2×typed | new_prd 提交映射 |
| output | reclaim_o | 2×typed | old_prd 写 Reclaim Buffer |
| output | store_commit_o | typed | head Store 请求 |
| input | store_commit_done_i | 1 | Store 副作用已接受 |
| output | recovery_req_o | recovery_req_t | 异常/MRET/中断 |
| output | commit_trace_o | 2×typed | 调试和 instret |

## 2. 双提交条件

lane0 可提交条件：valid、complete、无待处理序列化动作，若为 Store 则
store_commit_done。lane1 只有 lane0 同周期提交、lane1 complete 且 lane0 不触发
异常/恢复时才可提交。

异常、MRET、ECALL、EBREAK、序列化 CSR 在 head 独占处理，本周期 retire_count 至多 1。

### 2.1 Commit Unit V1 实现状态（2026-07-05）

`rtl/commit/commit_unit.sv` 已实现保守按序提交控制：

- 从 ROB head row 的两路寄存输出生成 `retire_count_o`。
- 普通 complete 指令支持双提交；lane0 serializing 时只提交 lane0。
- 生成 `commit_map_t` AMT 更新和 old PRD reclaim 输出。
- reclaim 使用 valid/ready：请求可在 Free List 反压时保持，但 ROB retire、AMT 更新和
  instret 必须等 reclaim ready 后同拍发生。
- Store 使用两阶段协议：先向 Store Queue 发 `store_commit_valid_o/sq_id`，
  capture 后进入 pending，直到 `store_commit_done_i` 才退休 ROB head。
- lane0 exception 不正常 retire，输出 CSR exception 写入端口和 `REC_EXCEPT` recovery。
- V1 暂不执行 CSR/MRET 指令副作用；相关集成留给后续 commit/CSR glue。

## 3. CSR 端口与状态

csr_file 至少实现 mstatus、mie、mtvec、mscratch、mepc、mcause、mtval、mip、
mcycle、minstret、mhartid。CSR 指令到达 ROB head 后读取、计算旧值返回 PRD，并在
提交点原子更新 CSR。

CSR 执行期间暂停年轻提交和新序列化操作，但不需要全核组合停顿；前端停止通过
recovery/serialize 状态逐级生效。

### 3.1 CSR File V1 实现状态（2026-07-05）

`rtl/commit/csr_file.sv` 已实现 commit-time machine-mode CSR 状态文件：

- 支持 `mstatus/mie/mtvec/mscratch/mepc/mcause/mtval/mip/mcycle/minstret/mhartid`。
- CSR 指令组合读旧值，时钟沿按 `CSR_RW/RS/RC/RWI/RSI/RCI` 原子更新。
- CSR 组合检查与 `csr_commit_i` 副作用使能分离，等待 PRF/reclaim 时不会提前改状态。
- `CSRRS/CSRRC/CSRRSI/CSRRCI` 在 operand/zimm 为 0 时不写 CSR。
- `mhartid` 只读，未知地址或只读写入产生 `csr_illegal_o`。
- 异常入口写 `mepc/mcause/mtval`，并执行 machine-mode `mstatus` 栈切换；
  `exception_vector_o` 输出对齐后的 `mtvec`。
- `mret_valid_i` 恢复 `MIE/MPIE/MPP` 并输出 `mepc` 作为返回 PC。
- `mcycle` 每周期递增，`minstret` 按 retire_count 累加；CSR 写计数器时写入优先。

### 3.2 Commit + CSR Cluster（2026-07-06）

`rtl/commit/commit_csr_cluster.sv` 在 ROB head 执行序列化系统指令：

- 普通双提交、Store 两阶段提交和已有异常继续复用 `commit_unit`。
- 合法 CSR 在提交点原子更新 CSR，旧值通过独立 `csr_wb_valid/prd/data` 写入目标 PRD，
  同周期更新 AMT 并回收 old PRD。
- 未知/只读非法 CSR 转 illegal-instruction 精确异常，`mtval` 保存原始指令。
- MRET 单独退休、恢复 mstatus 并向 recovery 输出 mepc；ECALL/EBREAK 不退休并进入异常。
- FENCE 作为无 CSR 副作用的单独序列化指令退休。

ROB entry 已扩展保存 CSR op/address/zimm、prepared operand、原始指令和特殊系统指令标志。
CSR operand prepare 已接入：Issue Arbiter 固定路由到 INT0，INT0 completion 仅携带 rs1
且不写 PRF，ROB 保存并前递 `csr_operand`。`commit_csr_cluster` 增加 PRF ready 门控，
保证普通 WB 活跃时 CSR 不退休；合法 CSR 在提交点更新 CSR、ROB retire 与 AMT/reclaim，
旧 CSR 值进入 `commit_csr_prf_cluster` 的一项 PRF 写缓冲，下一拍写入 PRF ready/data。

`rtl/commit/commit_csr_prf_cluster.sv` 已将 Commit/CSR 与 PRF commit write/ready 闭合，
作为本轮 5 ns OOC top。普通 WB 活跃时 CSR retire 保持为 0，WB 清空后自动继续；
CSR 写缓冲 pending 时对外置 busy/hold，避免后续提交越过尚未落入 PRF 的 CSR 结果。

`test/tb_commit_csr_cluster.sv` 覆盖普通双提交、合法 CSRRW 旧值写回与 AMT/reclaim、
非法 CSR 精确异常、MRET、ECALL、FENCE 和 PRF 反压。新增
`test/tb_commit_csr_prf_cluster.sv` 覆盖 CSR 提交、一拍 PRF 缓冲写和普通 WB 冲突保持。
QuestaSim 2024.1 当前 31 项回归均通过。原 Commit+CSR top 的用户 5.000 ns OOC WNS
为 +1.202 ns；`commit_csr_prf_cluster` 5.000 ns OOC WNS 为 +1.013 ns，时序健康，
当前冻结并进入完整 Commit/Recovery 集群。

### 3.3 完整 Commit/Recovery Cluster（2026-07-06）

`rtl/commit/commit_recovery_cluster.sv` 已闭合 Rename/ROB、Commit/CSR/PRF 与
Recovery Controller：

- ROB head 自动驱动双提交，commit map/reclaim 反馈 RAT/AMT 与 Free List。
- Dispatch fire 产生的目的 PRD 自动清除 PRF ready，普通 WB 同时更新 PRF 和 RAT ready。
- Commit 异常和 Branch mispredict 统一进入 recovery controller；单拍 broadcast 后等待
  Rename、Free List、LSQ、ROB 四路 sticky ack，再产生单拍 redirect。
- Branch redirect 同拍释放 checkpoint recovery pending；正确预测只发 checkpoint clear，
  不触发全局恢复。
- recovery busy 抑制重复 Commit 异常请求，CSR 异常入口只产生一次架构状态更新。
- Commit recovery 请求在进入 `recovery_controller` 前打一拍，避免 ROB head 系统指令
  分类同拍回灌 checkpoint clear/recovery 控制；CSR commit write 通过一项缓冲写 PRF，
  pending 期间纳入集群 busy/hold。

`test/tb_commit_recovery_cluster.sv` 覆盖误预测保留 checkpoint row、四路 ack 后 redirect、
正确预测局部 clear、幸存指令退休，以及 decode-time 精确异常的资源重建和 mtvec redirect。
QuestaSim 2024.1 当前 32 项回归全部 PASS；仿真 `Errors: 0`，保留默认
`-svinputport=relaxed` 端口 kind 警告。
下一步对 `commit_recovery_cluster` 执行 5.000 ns OOC。

首次 5.000 ns OOC WNS 为 -2.104 ns、TNS -3198.714 ns，无组合环。最差路径从 ROB
head CSR metadata 经 Commit/reclaim/retire 控制返回 ROB 的下一 head payload 寄存器，
数据延迟 7.078 ns、18 级逻辑，route 占 82.6%。现已在 ROB row 退休边界加入一拍
head refill，切断该跨集群长路径；功能回归保持 32/32 PASS，等待复综合。

首次优化后 WNS 为 -1.516 ns，原 payload D 路径消失；新最差路径为同一 retire 控制链
驱动 ROB head payload 同步复位 `/R`，数据延迟 6.148 ns、13 级逻辑、route 占 86.0%。
第二轮已改为失效时仅清 head `valid/complete`，不清 payload，32 项回归全部通过。

第二次复测 WNS 为 -1.210 ns、TNS -4780.215 ns。最差路径仍由 ROB head CSR metadata
出发，经 Commit/reclaim 组合决策后到 ROB occupancy；同时 `minstret` 暴露 20 级加法
路径。现已建立两阶段提交边界：第一拍完成并锁存已握手的提交事务，pending 屏蔽旧
head，第二拍由寄存 retire_count 推进 ROB；`minstret` 增量也独立寄存一拍。Questa
32 项回归全部通过。

第三次复测 WNS 为 -1.015 ns、TNS -4548.824 ns。最差路径变为 ROB head CSR metadata
经 commit recovery/checkpoint clear 控制返回 ROB tail row 同步复位，次差路径为
CSR writeback valid 组合驱动 PRF ready。现已将 commit recovery 请求寄存到
`commit_recovery_q` 后再送入 `recovery_controller`，并在 `commit_csr_prf_cluster`
内加入 CSR writeback buffer；`commit_hold/busy_o` 同时包含 recovery request pending
和 CSR writeback pending。Questa 32 项回归全部通过。

第四次复测 WNS 为 -0.599 ns、TNS -62.066 ns，失败端点降至 203 个。最差路径为
ROB head CSR metadata 经 CSR/commit/reclaim 组合决策生成 `commit_map0.arch_rd`，
再驱动 RAT/AMT 写使能。现已将 `commit_map0/1`、`reclaim_valid/prd` 与
`retire_count` 合并为注册提交事务：第一拍锁存已握手提交，pending 屏蔽旧 head，
下一拍由寄存事务统一更新 AMT、Free List 和 ROB。Questa 32 项回归全部通过，等待
第五次 OOC。

第五次复测 WNS 为 +0.121 ns、TNS 0，setup timing 已达标；但 `check_timing` 报告
2 个 combinational loops，不能冻结。根因是 pending 提交事务用 `reclaim_ready`
组合门控 `reclaim_valid`，而 Free List 的 `reclaim_ready_o` 会根据
`reclaim_valid_i` 计算本拍输入数量，形成 `valid -> ready -> valid` 回环。现已改为：
pending 事务期间稳定输出 `reclaim_valid_offer`，`retire_count/commit_map` 和
pending 清除只在 `reclaim_ready` 接受拍发生。目标测试与 32 项回归全部通过，等待
第六次 OOC 确认 loops 为 0。

第六次复测 WNS 为 +0.121 ns、TNS 0、失败端点 0，`check_timing` loops 为 0。最慢
路径回到普通 dispatch/ROB allocation 的 `used_rows_q -> rob_alloc_ready -> alloc_fire
-> entry_q CE`，不再经过 commit/recovery 回灌。Commit/Recovery 集群当前时序健康并冻结。

### 3.4 Backend INT Cluster（2026-07-06）

`rtl/backend/backend_int_cluster.sv` 是首个后端整数集成边界，当前串接：

- `commit_recovery_cluster`
- `dispatch_buffer`
- 1 个 INT `issue_queue`
- `issue_arbiter`
- `operand_read_stage`
- `int_pipeline0`
- `int_branch_pipeline1`
- `writeback_arbiter`

当前阶段只开放 INT/Branch/CSR loop；LSU/MDU dispatch ready 固定反压，后续集成再打开。
为避免 ready/valid 组合环，Dispatch Buffer 的 INT ready 由已寄存 IQ occupancy 推导，不直接
使用 `issue_queue.push_ready_o`。

分支解析事件在 INT1 EX 侧早于 timing-pipelined writeback/ROB completion。backend 边界
增加一项 `branch_event_q`，只有匹配 ROB completion 已经从 writeback arbiter 出现在 ROB
completion 通道时，才向 `commit_recovery_cluster` 发送 branch event。这样可避免
`REC_BRANCH` 广播和该分支 completion 同拍到达 ROB 时，恢复扫描优先级抢占 normal
completion，导致分支自身残留 incomplete。

`test/tb_backend_int_cluster.sv` 覆盖：

- 双整数 ALU 通过 Rename/Dispatch/Issue/RR/EX/WB/Commit 闭环并回收 PRD。
- JAL 误预测触发 redirect，恢复完成后 checkpoint 释放且 ROB 清空。
- CSR immediate prepare 经 INT0 capture zimm，Commit 端更新 mstatus，并通过 PRF commit
  write 置位目标 PRD ready。

QuestaSim 2024.1 当前全量 33 项 directed regression 全部 PASS。`backend_int_cluster`
5.000 ns OOC 最终 WNS 为 +0.110 ns、TNS 为 0，失败端点 0，`check_timing`
loops 为 0；最慢路径从 issue feedback 转移到 recovery/PRF read-data 边界。该集群
当前时序健康并冻结。

## 4. 精确异常

head 异常处理顺序：

1. 停止正常 retire。
2. 写 mepc、mcause、mtval 和 mstatus。
3. 发出 exception recovery。
4. RAT 从 AMT 恢复，ROB/IQ/LSQ 清年轻项。
5. Free List 多周期重建。
6. 所有恢复完成后 redirect 到 mtvec。

异常指令本身不更新 AMT、不回收 old_prd、不增加 instret。

## 5. MRET 和中断

MRET 在 head 更新 mstatus，并 redirect 到 mepc。中断仅在指令边界且无更高优先级同步
异常时接受；mepc 写入下一条应执行 PC。中断复用异常恢复流程。

## 6. Branch Checkpoint

checkpoint_file 每项保存 RAT snapshot 或恢复句柄、Free List log tail、ROB tail、
LQ tail、SQ tail。分配最多每周期一个。正确分支解析释放 checkpoint 并清 mask；
误预测先广播恢复信息，等各模块 ack 后再释放槽。

### 6.1 Branch Checkpoint File V1 实现状态（2026-07-05）

`rtl/commit/branch_checkpoint_file.sv` 已实现统一 checkpoint ID 生命周期管理：

- 4 槽低位优先注册式 reservation，ID 保持到 Rename `alloc_fire/alloc_cancel`。
- `alloc_fire` 保存 ROB 恢复 tail 与父分支 mask；RAT、Free List、LSQ 继续按同一 ID
  本地保存各自恢复载荷，避免集中式大扇出快照。
- 正确分支解析立即释放对应 ID，并清除所有年轻 checkpoint 对该父分支的依赖位。
- 误预测广播时输出对应 ROB tail，锁住分配器；全局 recovery ack 完成后，原子释放
  误预测分支及所有依赖它的年轻 checkpoint。
- 精确异常 flush 清空 reservation、活动槽和待恢复状态。

## 7. Recovery Controller FSM

建议状态：

    IDLE
    BRANCH_BROADCAST
    BRANCH_WAIT_ACK
    EXCEPTION_DRAIN
    RAT_RESTORE
    FREELIST_REBUILD
    REDIRECT

分支恢复目标在数周期内完成即可，异常允许更长。控制器收集 frontend、rename、ROB、
IQ、LSQ、MDU 的 done/ack，避免假定所有模块一拍完成。

### 7.1 Recovery Controller V1 实现状态（2026-07-05）

`rtl/commit/recovery_controller.sv` 已实现恢复请求仲裁与广播 FSM：

- commit recovery 优先于 branch mispredict。
- branch mispredict 转换为 `REC_BRANCH` kill broadcast，携带 checkpoint 和 redirect PC。
- 正确分支不走 `REC_BRANCH`，只输出 `checkpoint_clear_valid_o/id`，避免误杀正确路径。
- FSM 顺序为 `IDLE -> BROADCAST -> WAIT_ACK -> REDIRECT`。
- `BROADCAST` 单拍输出 `recovery_t`；`WAIT_ACK` 等待参数化 done 向量全 1；
  `REDIRECT` 单拍输出 redirect valid/PC。
- busy 期间忽略新的年轻恢复请求，避免覆盖已锁存的更老恢复目标。

## 8. 优先级

同步异常 > MRET > 已接受中断 > branch mispredict > 正确分支解析。更老 ROB 事件优先于
更年轻事件。恢复进行时新的年轻事件忽略；更老异常若理论上可能出现，必须按 ROB 年龄
重新仲裁。

## 9. 断言

- Commit 严格按 ROB 顺序。
- 异常指令和所有年轻指令无架构副作用。
- AMT 只在 commit fire 更新。
- Store 只在 head 且无异常时写 Memory。
- recovery 完成前 Fetch 不从新目标继续提交包。

## 10. 当前验证状态

- `test/tb_csr_file.sv` 覆盖 CSR 读改写、只读/未知地址非法、`mcycle/minstret`、
  异常入口和 MRET 状态恢复。QuestaSim 最小测试和 23 项当前回归均通过，
  `Errors: 0, Warnings: 0`。Vivado 5 ns OOC 时序验证待运行后补充最终 WNS/资源。
- `test/tb_commit_unit.sv` 覆盖普通双提交、serializing 单提交、incomplete lane0 阻塞、
  lane1 exception 阻止同周期双提交、lane0 exception recovery，以及 Store 两阶段提交。
  QuestaSim 最小测试和 24 项当前回归均通过，`Errors: 0, Warnings: 0`。Vivado 5 ns OOC 时序验证待运行后补充最终 WNS/资源。
- `test/tb_recovery_controller.sv` 覆盖正确分支 checkpoint clear、branch mispredict broadcast、
  ack wait、redirect pulse、commit recovery 优先级，以及 busy 期间忽略新请求。
  QuestaSim 最小测试和 25 项当前回归均通过，`Errors: 0, Warnings: 0`。Vivado 5 ns OOC
  WNS 为 +3.112 ns，时序健康。
- `test/tb_branch_checkpoint_file.sv` 覆盖 reservation cancel/reuse、嵌套 checkpoint、
  正确解析释放、误预测 ROB tail 查询、恢复期间锁定、后代槽延迟释放、满槽反压和异常
  flush。QuestaSim 2024.1 最小测试和 26 项当前回归均通过，`Errors: 0, Warnings: 0`。
  Vivado 5 ns OOC WNS 为 +2.600 ns，当前冻结。

### 10.1 Backend INT 集成修订（2026-07-06）

Backend INT timing cut 后，两条同一 ROB row 的指令可能分拍完成并分拍提交。为保持
`commit_unit` 支持 serializing lane0 单提交、lane1 exception 阻止双提交等语义，ROB
新增 `head_bank_q` 半行 head 状态：当 bank0 单独退休且 bank1 仍有效时，只清 bank0，
下一拍把 bank1 暴露为 head lane0，直到其完成并提交后再推进 row。

`commit_recovery_cluster` 的普通 reclaim 事务在 fire 后额外保持一拍 busy，覆盖 Free List
reclaim FIFO 逐周期 drain 导致的 free_count 可见延迟，避免 backend idle 早于 reclaim
计数更新。修订后 `tb_reorder_buffer`、`tb_commit_unit`、`tb_commit_recovery_cluster` 和
全量 33 项 Questa regression 通过。
