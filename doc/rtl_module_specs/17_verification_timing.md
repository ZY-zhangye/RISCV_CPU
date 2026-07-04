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
| ROB | V1 RTL 与 directed test 完成 | +1.36 ns | 可进入后续集成 |
| Dispatch Buffer | V1 RTL 与 directed test 完成 | +1.712 ns | 可进入后续集成 |
| Issue Queue | select 已拆 S0/S1 两级 | +1.167 ns | 冻结，下一步实现 issue_arbiter |

`results/` 下的 Icarus `.vvp` 仿真中间文件已在本次收尾时清理，不纳入版本管理。
下一次继续时应从 `doc/HANDOFF_2026-07-04.md` 和 `09_dispatch_issue.md` 的 5.1 节开始。

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
