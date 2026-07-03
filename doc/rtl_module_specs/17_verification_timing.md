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

完整核目标为 200 MHz。独立综合报告必须记录器件、时钟约束、WNS、逻辑级数、LUT/FF/
BRAM/DSP 和最差路径端点。

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
