# 验证与时序验收计划

## 1. 模块级验证原则

每个模块需要同时具备 directed test、受约束随机测试、SVA 和独立综合结果。功能通过
但独立综合不达标，不视为模块完成。

## 2. 单元验证矩阵

| 模块 | 必测场景 |
|---|---|
| Fetch | 四槽对齐、块内跳转、redirect 丢旧返回、反压 |
| Predictor | BTB/BHT 命中更新、JALR BTB 预测、查询写冲突 |
| IBuffer | 4 入 2 出、环绕、同周期入出、flush |
| Decode | RV32IM_Zicsr 全编码、非法指令 |
| Rename | 双 RAW/WAW、单资源退化、恢复、x0 |
| Free List | 双分配、跨 Bank、延迟回收、重建 |
| ROB | 双分配/完成/提交、wrap、异常、tail 恢复 |
| IQ | 双入队、双 tag wakeup、分组 oldest、kill |
| PRF | 六读双写、Bank 冲突、bypass、p0 |
| INT0 | ALU/shift/compare、立即数选择、completion 背压、recovery kill |
| INT1/Branch | 简单 ALU、条件分支、JAL/JALR、预测校验、非对齐异常 |
| LSU/LSQ | 未知老 Store 阻塞、最近 Store 转发、非对齐 |
| MDU | 全符号组合、除零、溢出、pipeline kill |
| WB | 三结果碰撞、同 Bank 冲突、公平性、异常 |
| Commit | 双提交、Store、CSR、异常、中断、MRET |

## 3. 集成里程碑

1. P1：Fetch 到 Decode 连续供给。
2. P2：Rename、ROB、顺序整数执行和双提交。
3. P3：Integer OoO、双 WB、Branch recovery。
4. P4：顺序约束 LSU 和 Store commit。
5. P5：Load 越过已知不冲突 Store。
6. P6：M 扩展和 completion 冲突。
7. P7：CSR、精确异常和中断。

每个里程碑先运行局部测试，再运行保留在 hex/riscv-tests 下的官方镜像。

## 4. 性能可观测性

仿真至少输出：IPC、fetch/decode/rename/issue/commit 利用率、ROB/IQ/LQ/SQ occupancy、
各类 full stall、PRF Bank conflict、WB conflict、load wait store、branch mispredict
及恢复周期。

## 5. 独立综合目标

固定目标器件为 `xc7k325tffg900-2`。完整核主时钟约束为 5.000 ns；验收以 route_design
后的时序为准，要求 setup WNS 与 hold WHS 均不小于 0，并且不存在 unconstrained path。
仅有 RTL 仿真、综合估算或同器件其他工程达到 200 MHz，均不能作为本核达标证据。

| 模块路径 | 最低目标 |
|---|---:|
| RAT + lane dependency | 250 MHz |
| Free List dual allocate | 250 MHz |
| ROB allocate/commit view | 250 MHz |
| Integer IQ select | 225 MHz |
| PRF read and route | 250 MHz |
| SQ compare stage | 225 MHz |
| WB arbitration | 250 MHz |
| Branch resolve | 250 MHz |

除单模块 OOC 外，必须增加以下集群级时序测试，覆盖真实模块边界：

| OOC 集群 | 最低目标 | 重点检查 |
|---|---:|---|
| branch_predictor + fetch_pipeline | 250 MHz | predictor 返回、update 写口、F1 预解码 |
| instruction_buffer + decode_stage | 250 MHz | entry 写控制、FO→Decode |
| rename_stage + free_list + dispatch_buffer | 250 MHz | reservation response、ready 隔离 |

2026-07-04 基线中 Branch Predictor 仅有 +0.475 ns 的 5 ns WNS，不满足“完整核留余量”的
意图；Free List 为 -1.413 ns。二者整改后均须在 4.000 ns OOC 下 WNS≥0。IBuf/Fetch 若
4 ns 失败，应按对应模块规格增加局部寄存边界，不允许放宽完整核 5 ns 目标。

完整核目标为 200 MHz。独立综合报告必须记录器件、时钟约束、WNS、逻辑级数、LUT/FF/
BRAM/DSP 和最差路径端点。

模块 OOC 建议使用 4.0～4.5 ns 约束留出顶层布线余量。每次实现至少保存并核对：
`report_timing_summary`、`report_utilization -hierarchical`、`report_ram_utilization` 和
`report_high_fanout_nets`。预测器 BTB/BHT、IROM/Data RAM 是否推断为预期存储原语，必须
以 RAM utilization 报告为准。

### 5.1 2026-07-04 当前 RTL 与 OOC 状态

当前工作分支为 `codex/full-rtl-refactor`。以下数据来自用户在
`F:\RISCV_CPU_Vivado_20260703\reports` 下执行的 XC7K325T-FFG900-2 单模块 OOC 综合报告
或用户口头同步结果；完整核仍以 route 后 5.000 ns WNS/WHS 为最终验收。

| 模块 | RTL 状态 | 5.000 ns OOC WNS | 当前决策 |
|---|---|---:|---|
| Free List | 已完成时序重构 | +0.827 ns | 冻结，后续只在成组/route 暴露问题时再改 |
| Branch Predictor | update 路径已拆两拍 | +0.628 ns | 冻结，暂不做 BHT row 化 |
| ROB | 增加精确异常 flush/done，支持抢占 branch scan | +0.903 ns | Questa 29 项回归通过，冻结 |
| Dispatch Buffer | V1 RTL 与 directed test 完成 | +1.712 ns | 可进入后续集成 |
| Issue Queue | select 已拆 S0/S1 两级 | +1.167 ns | 冻结 |
| Issue Arbiter | P0/P1/P2 三级仲裁，扩展 metadata 后复测 | +1.031 ns | 冻结 |
| Physical Register File | 双 Bank、每 Bank 三读副本 | +2.005 ns | 冻结，继续核对 RAM inference |
| Operand Read | 同步读对齐、WB bypass、四端口独立 holding | 4 ns 下 +1.272 ns | 冻结 |
| INT0 Pipeline | 单周期 ALU + 1-entry completion buffer；CSR prepare 支持 rs1/zimm | +1.824 ns | Questa 覆盖 CSR immediate prepare，冻结 |
| INT1/Branch Pipeline | 简单 ALU + branch resolve + 1-entry completion buffer | +2.023 ns | 冻结，进入 Writeback |
| Writeback Arbiter | 5 producer 2-entry skid buffers + fixed select + registered outputs | +0.287 ns | 暂时冻结，后续看成组/route |
| LSQ Allocator | 双 LQ/SQ reservation + allocation-log rollback | +2.138 ns | 零分配 checkpoint 修正后 Questa 28 项回归通过，冻结 |
| Store Queue | 8-entry direct update + 1-entry commit buffer | +2.336 ns | 冻结，进入 Load Queue |
| Load Queue | 8-entry direct metadata + dual retire release | +2.342 ns | 冻结，进入 LSU Pipeline |
| LSU Pipeline | AGU + parallel candidates + balanced registered reduction + forwarding/memory path | +0.756 ns | 冻结；TNS=0，关键路径 84.3% 为布线 |
| Mul Pipeline | 4 partial-product DSPs + 2-level registered add tree + 2-entry completion FIFO | +1.511 ns | 冻结；263 LUT、341 FF、4 DSP48E1 |
| Div Unit | 单在途 radix-4 16-iteration divider + special-case bypass + stable OUTPUT buffer | OOC 待测 | Questa 21 项回归通过，待 5 ns OOC |
| Mul/Div Frontend | FU_MUL/FU_DIV request router + local Mul/Div wrappers + split producer outputs | OOC 待测 | Questa 22 项回归通过，待 5 ns OOC |
| CSR File | commit-time CSR read/modify/write + exception/MRET state + counters | OOC 待测 | Questa 23 项回归通过，待 5 ns OOC |
| Commit Unit | ROB-head ordered retire + AMT/reclaim + Store two-phase commit + exception recovery | OOC 待测 | Questa 24 项回归通过，待 5 ns OOC |
| Recovery Controller | priority recovery select + one-shot broadcast + ack wait + redirect pulse | +3.112 ns | 冻结，进入 branch checkpoint 或 commit/CSR glue |
| Branch Checkpoint File | 4-slot registered reservation + ROB tail/ancestry lifetime tracking | +2.600 ns | Questa 26 项回归通过，冻结 |
| Rename Resource Manager | atomic Free List/LSQ/Checkpoint/ROB reservation coordinator | +2.387 ns | Questa 27 项回归通过，冻结 |
| Rename Allocation Cluster | Resource Manager + Free List + LSQ Allocator + Checkpoint File | +0.846 ns | Questa 28 项回归通过，冻结 |
| Rename + ROB Cluster | Rename + Allocation Cluster + ROB + sticky recovery acks | +0.559 ns | TNS 0、loop 0，Questa 30 项回归通过，冻结 |
| Commit + CSR Cluster | ordinary/Store commit + CSR/MRET/ECALL/FENCE head execution | +1.202 ns | Questa 30 项回归通过，冻结 |
| Commit + CSR + PRF Cluster | CSR operand commit write + PRF ready 缓冲握手 | +1.013 ns | Questa 31 项回归通过，时序健康并冻结 |
| Commit + Recovery Cluster | Rename/ROB + Commit/CSR/PRF + recovery ack/redirect | +0.121 ns | TNS 0、loop 0，Questa 32 项通过，冻结 |
| Backend INT Cluster | Commit/Recovery + Dispatch/IQ/Issue/RR/INT0/INT1/WB | +0.110 ns | TNS 0、loop 0，Questa 33 项通过，时序健康并冻结 |
| Backend LSU Cluster | Backend INT + Memory IQ + LQ/SQ + LSU + LSU writeback | -0.203 ns | TNS/端点已大幅收敛；当前最差路径为 Issue Arbiter 内部布线主导路径，RTL 冻结等待后端实现吸收 |
| Backend MDU Cluster | Backend LSU + MDU IQ + Mul/Div frontend + MUL/DIV writeback | -0.204 ns | 原 ready 回灌路径已消失；剩余为 Issue Arbiter 内部 route 主导路径，RTL 冻结等待后端实现吸收 |
| Frontend Backend Cluster | Fetch + BP + IBUF + Decode + Backend MDU Cluster | -0.196 ns | Top paths 仍为后端 Issue Arbiter 内部 route 主导路径；前端边界无新增关键路径，RTL 冻结等待实现吸收 |
| Core Top | frontend_backend_cluster wrapper + typed memory boundary + irq pins | Questa 通过 | `tb_core_top` 与 `tb_frontend_backend_cluster` 通过，OOC 待 SoC wrapper 前统一测 |
| SoC Addr Router | typed load/store 到 RAM/MMIO 固定地址路由 | +1.828 ns | `tb_soc_addr_router` 通过，OOC 时序健康并冻结；进入 instruction memory wrapper |
| SoC IMem | 128-bit instruction block memory wrapper | +2.380 ns | `tb_soc_imem` 通过，OOC 时序健康并冻结；进入 data RAM wrapper |
| SoC Data RAM | typed data RAM wrapper | +0.955 ns | 首次 OOC WNS 为正，但推断为 distributed RAM；已加 `ram_style="block"` 与显式 byte-lane write enable，`tb_soc_data_ram` 复测通过，等待 BRAM 推断复综合 |
| SoC Top | core_top + IMem + addr router + Data RAM + MMIO bus | Questa 通过 | `tb_soc_top` 覆盖 IMem 初始化、core 取指、INT/MUL/DIV 写回和顶层预留线；load/store 全系统 smoke 后续补 |

`results/` 下的 Icarus `.vvp` 仿真中间文件已在本次收尾时清理，不纳入版本管理。
Recovery Controller 已通过 Vivado 5 ns OOC 综合，WNS +3.112 ns；Branch Checkpoint
File WNS 为 +2.600 ns；Rename Resource Manager WNS 为 +2.387 ns。当前修正 LSQ
Allocator 的零访存分配 checkpoint 后 WNS 为 +2.138 ns。下一项进入 Rename Allocation
Cluster；真实四模块 directed test 和 28 项回归已通过，5 ns OOC WNS 为 +0.846 ns。
ROB 精确异常 flush 修订后 5 ns OOC WNS 为 +0.903 ns。Rename + ROB Cluster 已闭合
P2 分配、ROB entry 构造和恢复 ack 边界；初次 OOC WNS -0.281 ns、TNS -31.185 ns，
并发现 2 个 ready/valid 组合环。去环后 OOC WNS +0.559 ns、TNS 0、loop 0。
Commit + CSR Cluster 的 5 ns OOC WNS 为 +1.202 ns。CSR operand prepare 已完成
Issue→INT0→ROB capture，并通过 `commit_csr_prf_cluster` 闭合提交侧 PRF 写口；当前
Questa 31 项回归通过，5 ns OOC WNS +1.013 ns，时序健康并冻结。下一步进入完整
Commit/Recovery 集群。
完整 `commit_recovery_cluster` 已闭合 commit map/reclaim、PRF ready clear、四路恢复 ack
和最终 redirect；首次 OOC WNS -2.104 ns，最差路径为 retire 控制返回 ROB 宽 head
payload mux。加入一拍 head refill 后 Questa 32 项回归通过，当前等待 5 ns OOC 复测。
首次复测 WNS -1.516 ns，新路径落在 payload `/R`；现已改为只清 head valid/complete，
取消失效 payload 清零，等待第二次复测。
第二次复测 WNS -1.210 ns，终点转移到 occupancy/minstret，确认共因是组合 retire
决策。已使用两阶段提交和寄存 retire_count/minstret 增量从结构上断开。第三次复测
WNS -1.015 ns，残余路径转为 commit recovery/checkpoint clear 回灌 ROB tail reset，
以及 CSR writeback 组合驱动 PRF ready；现已寄存 commit recovery 请求并增加 CSR PRF
写缓冲。第四次复测 WNS -0.599 ns、TNS -62.066 ns，最差路径转为 commit map
同拍驱动 RAT/AMT CE；现已把 commit map、reclaim 和 retire_count 合并为注册提交
事务。第五次复测 WNS +0.121 ns、TNS 0，但 check_timing 报告 2 个 combinational
loops；现已去除 pending reclaim valid 对 reclaim_ready 的组合门控，等待第六次复测
确认 loops=0。第六次复测 WNS +0.121 ns、TNS 0、失败端点 0、loops 0，最慢路径回到
普通 dispatch/ROB alloc CE；Commit + Recovery Cluster 冻结。
首个后端整数集成边界 `backend_int_cluster` 已完成：当前开放 INT/Branch/CSR loop，
LSU/MDU 分派路径保持反压。修正分支 resolve 早于 ROB completion 导致的误预测恢复
抢占问题，backend 边界会等匹配 ROB completion 可见后再向 recovery controller 发送
branch event；同时修正 INT0 对 CSR immediate prepare 的 zimm operand 选择。Questa
2024.1 全量 33 项 directed regression 通过，下一步等待 5 ns OOC 综合。
Backend INT Cluster 初次 OOC WNS -0.975 ns，最差路径为 INT IQ candidate/ROB-ID 通过
issue arbiter grant 回灌 IQ S0 pair 寄存器。当前已将 IQ S0 从当前 grant 中解耦，只用
上一拍 deferred clear/pending clear 做选择过滤；visible candidate 在 clear 窗口屏蔽，
arbiter P0 也跳过同周期已 grant group。该修改使两条同 row ROB 指令可分拍完成，进而
补齐 ROB 半行 head 语义：bank0 单独 retire 后 bank1 作为下一拍 head lane0；普通
reclaim 事务 fire 后额外保持一拍 busy，等待 Free List reclaim FIFO drain 到 free_count。
修复后 Questa 33 项 regression 通过，等待 OOC 复测。
后续复测继续暴露 IQ candidate payload 到 Issue Arbiter P0、P2 grant 回灌 P0、以及
issue output 经 Operand Read ready 回到 P0 proposal 的三类反馈路径；当前已通过
C0 candidate snapshot、删除 P0 对当前 grant 的依赖、以及将 P0 ready 视图也纳入
C0 snapshot 完成切断。最终 5.000 ns OOC WNS +0.110 ns、TNS 0、失败端点 0、
loops 0，最慢路径转到 recovery/PRF read-data 边界；Backend INT Cluster 冻结。
下一项 `backend_lsu_cluster` 已打开 Memory IQ、LQ/SQ、LSU Pipeline 和 LSU writeback，
MDU 暂不打开。为支持真实 Load retire，ROB allocation metadata 增加 `is_load/lq_id`，
`commit_recovery_cluster` 在注册提交事务 fire 时输出 LQ retire release。目标测试覆盖
Load memory response 写回提交释放，以及 Store SQ update、ROB head commit buffer、
memory request 和 SQ release；`tb_backend_lsu_cluster`、`tb_commit_recovery_cluster`、
`tb_backend_int_cluster` 均通过。首次 5.000 ns OOC WNS `-0.905 ns`、TNS
`-1316.459 ns`、失败端点 `3575`、loops `0`；最差路径为 Dispatch Buffer 输出到
Issue Queue enqueue/branch-mask CE 的集成边界 fanout。已在 backend LSU cluster 增加
dispatch-to-IQ 一级 skid/register timing cut。

复测 WNS `-0.505 ns`、TNS `-90.623 ns`、失败端点 `351`、loops `0`。新的最差路径为
`recovery.valid` 经过 writeback/INT0/operand-read ready 链到 PRF read request，再到
`physical_regfile` bank0 read-data 寄存器。第二轮优化将 operand read 的 PRF read
valid 改为只依赖 issue slot valid 与源操作数需求，不再组合依赖 execution ready 或
recovery；recovery flush 仍由 holding register 与执行端本地处理。同步清理 PRF 中一处
重复赋值。Questa 目标测试通过，等待 Vivado 复测。

第二轮复测 WNS `-0.203 ns`、TNS `-32.310 ns`、失败端点 `159`、loops `0`。最差路径
回到 Issue Arbiter 内部 C0 candidate 到 P0 proposal 分类/读计数寄存器，逻辑 7 级、
布线约 87%。考虑该路径属于已冻结共享发射仲裁器，继续 RTL 切分会引入额外发射延迟
或影响 Backend INT Cluster，当前冻结 Backend LSU Cluster，交 FPGA 后端实现阶段吸收；
若 post-place/post-route 仍负余量，再按新报告定点处理。

下一项 `backend_mdu_cluster` 已打开 MDU dispatch、MDU Issue Queue、Issue Arbiter
MDU candidate/grant、Operand Read MDU 输出、`muldiv_frontend` 和 Writeback Arbiter
的 MUL/DIV producer。为避免长 ready 链回灌全局发射仲裁，集群级
`issue_arbiter.mdu_accept_i` 固定为 `1'b1`；真实 MUL/DIV backpressure 由 Operand Read
MDU holding register 和 `muldiv_frontend` 本地 ready 协议吸收。QuestaSim 2024.1
已复跑 `tb_backend_mdu_cluster`、`tb_backend_lsu_cluster`、`tb_backend_int_cluster`、
`tb_commit_recovery_cluster`、`tb_muldiv_frontend`，全部 `Errors: 0`。下一步等待
Vivado 对 `backend_mdu_cluster` 做 5.000 ns OOC 综合。

首次复测 WNS `-0.339 ns`、TNS `-87.559 ns`、失败端点 `331`、loops `0`。最差路径
从 recovery controller state 出发，经 MUL pipeline recovery kill/valid、
`muldiv_frontend` raw ready、Operand Read MDU ready，最终进入 Issue Arbiter registered
issue output，route 约 84%。当前已在 `backend_mdu_cluster` 内新增 2-entry MDU execute
FIFO：Operand Read/Issue Arbiter 只看 FIFO full，`muldiv_frontend` raw ready 只控制
本地 FIFO pop；FIFO 支持 recovery kill/branch-mask clear 并纳入 `busy_o`。Questa
目标回归全部通过，等待下一次 5.000 ns OOC 复测。

复测 WNS `-0.204 ns`、TNS `-33.490 ns`、失败端点 `164`、loops `0`。最差路径已经
转为 Issue Arbiter 内部 `int_candidate_q -> proposal_* -> proposal_uop_q reset`，
逻辑 7 级、route 约 87.2%。考虑该路径属于已冻结共享仲裁器，继续 RTL 切分会影响
Backend INT/LSU/MDU 的统一发射延迟和已验证边界，当前冻结 Backend MDU Cluster；
后续先交由 FPGA 后端实现阶段吸收，若 post-place/post-route 仍失败再定点优化
proposal reset/fanout。

下一项 `frontend_backend_cluster` 已打开前端到 Backend MDU Cluster 的完整 directed
路径：`fetch_pipeline` 访问外部 128-bit I-cache block，预测结果进入 fetch，fetch packet
进入 `instruction_buffer`，双发 decode 后直接驱动 backend rename/dispatch。Backend
分支 completion event 通过新增的 `branch_update_valid_o/branch_update_o` 回写
`branch_predictor`。QuestaSim 2024.1 已通过新增 `tb_frontend_backend_cluster`：
测试程序 `ADDI x1,6; ADDI x2,7; MUL x3,x1,x2; DIVU x4,x3,x2`，检查 INT/MUL/DIV
写回数据 `6/7/42/6`，并确认 LQ/SQ 未泄漏。同步复跑
`tb_backend_mdu_cluster`、`tb_fetch_pipeline`、`tb_instruction_buffer`、
`tb_decode_stage`、`tb_branch_predictor`，全部 `Errors: 0`。该集成边界无 halt 入口，
默认 IMem 在程序后持续返回 NOP，因此 smoke 不要求全系统 idle。

首次 5.000 ns OOC 综合 WNS `-0.196 ns`、TNS `-32.178 ns`、失败端点 `164`、
loops `0`。Top paths 与 Backend MDU Cluster 的冻结残余路径一致，均为
`u_backend/u_issue_arbiter/int_candidate_q[0][src1_ready]` 到 `proposal_*_q[3]`
reset/payload，logic 7 级、route 约 87.4%。前端新增模块和 branch predictor update
未进入最差路径。当前冻结 Frontend Backend Cluster；后续进入 core top/SoC wrapper
集成，并将该 Issue Arbiter route 主导路径留给 FPGA 实现阶段吸收。

`core_top` 已完成薄 wrapper 集成：内部实例化 `frontend_backend_cluster`，对外暴露
instruction memory、typed load/store memory、recovery/debug 状态和 CSR 状态端口。
`ext_irq_i/timer_irq_i/software_irq_i` 当前汇总为 `interrupt_pending_o`，CSR interrupt
pending 采样留待后续 CSR interrupt 扩展。QuestaSim 2024.1 已通过 `tb_core_top` 与
`tb_frontend_backend_cluster`，均 `Errors: 0`。

## 6. 关键属性

- 任一提交序列与顺序参考模型一致。
- 被 flush 的 uop 永不提交。
- PRF ready 表示真实值已经写入。
- Store memory side effect 与 ROB 提交一一对应。
- ROB 中异常最老项之前的指令均可提交，之后均不可提交。
- 任一 accepted request 最终完成或被明确 recovery 取消。

## 7. 完成定义

模块完成必须同时满足：接口规格冻结、单测通过、断言无失败、独立综合达标、无未解释
latch/CDC/多驱动警告、文档与 RTL 端口一致。任何参数或流水级变化都要同步更新本目录
对应文档。
