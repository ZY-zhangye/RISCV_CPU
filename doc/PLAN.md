# ROB、组合 Dispatch、双分区 IQ 与 PRF 实施计划

更新时间：2026-06-29

## 当前状态

已完成并通过 QuestaSim 定向验证：

- [x] RV32M 译码扩展及公共端口包；
- [x] 64×32-bit 同步 4R2W 物理寄存器堆；
- [x] 32 项双分配、双完成、双提交 ROB；
- [x] Rename→ROB/IQ/LSQ 组合 Dispatch；
- [x] ROB 与 Dispatch 联合原子准入测试；
- [x] 现有 Rename 状态和流水级回归。

尚未实现：

- [ ] 两个 8 项静态分区 IQ；
- [ ] 独立 LSQ 及其与 issue1 的仲裁；
- [ ] 写回广播当拍唤醒/选择和操作数选择级；
- [ ] ALU、MLU、BRU、LSU、CSR 执行与两组写回仲裁；
- [ ] Rename→Dispatch→ROB/IQ/LSQ 完整后端集成。

## 总体结构

- 不增加独立 Dispatch 流水级或 Dispatch buffer。
- Rename 的寄存输出 FIFO 直接连接纯组合 `dispatch`。
- 默认容量：32 项 ROB、两个 8 项 IQ bank、64×32-bit PRF。
- 全核最多双发射：
  - issue0：ALU0 / MLU。
  - issue1：ALU1 / BRU / LSU。
- LSQ 独立维护访存顺序，但与 IQ bank1 竞争 issue1。
- 两个 IQ bank 均支持双入队、单发射。

## 组合 Dispatch

- [x] 根据指令类型产生 ROB、IQ0、IQ1、LSQ 的 enqueue 包和 valid。
- [x] 每条指令必须同时获得一个 ROB 项和对应目标队列项，才能从 Rename FIFO 出队。
- [x] lane1 只有在 lane0 成功 Dispatch 后才能成功；lane1 资源不足时允许 lane0 单独推进。
- [x] 普通 ALU 根据两个 IQ 的可用项动态分流；同拍双 ALU 优先分别进入两个 bank。
- [x] MLU 固定进入 IQ0；BRU、CSR 固定进入 IQ1；Load/Store 进入 LSQ。
- [x] 异常、ECALL、EBREAK、MRET、FENCE 只分配 ROB。
- [x] ROB/IQ/LSQ 的接收能力只能由当前寄存占用状态产生：
  - 不使用本拍 commit 释放的 ROB 空间；
  - 不使用本拍 issue 释放的 IQ 空间；
  - 不把执行单元 `ready` 反向传播到 Rename。
- [x] 最长组合路径限制在“队列计数→分流和资源判断→Rename dequeue”，不会延伸到执行或写回级。
- [x] Dispatch 不保存任何状态；ALU 使用剩余容量和本拍已使用额度进行确定性均衡。

## ROB

- [x] 支持每拍双分配、两路乱序完成更新和前缀双顺序提交。
- [x] 只有至少两个空项时才组合拉高 `rob_allowin`；不使用本拍提交释放的空间。
- 条目只保存：
  - valid、complete、PC、ROB tag；
  - `rd/pdst/stale_pdst/pdst_valid`；
  - branch/store/CSR/fence/mret 属性；
  - 异常码和 tval；
  - 分支误预测及重定向目标。
- 不保存 ALU/MEM 操作、立即数、源寄存器或其他执行译码信息。
- [x] lane1 不得越过 lane0 提交；lane0 单独完成时允许单提交。
- [ ] 分支误预测到达 ROB 头时，由未来提交控制器根据 `commit_bus` 产生统一 recovery。
- [ ] 外部中断由未来提交控制器在提交边界全局采样，不复制进每个 ROB 条目。
- [x] ROB 提交生成 `commit_map_bundle_t`，可直接接入现有 RRAT 和 Free List。

## IQ、发射与 PRF

- [ ] IQ0 支持 ALU/MLU，IQ1 支持 ALU/BRU/CSR。
- [ ] IQ 保存执行控制、ROB tag、物理源/目标、源就绪位、PC、立即数及预测信息。
- [ ] 每个 bank 使用 oldest-ready 选择，并监听两路写回广播更新源就绪状态。
- [ ] IQ 条目只有在 issue 握手成功后删除。
- [ ] issue1 在 IQ1 与 LSQ 候选之间按 ROB 年龄选择。
- [x] PRF 使用同步 4 读 2 写：
  - issue0 使用读口0/1；
  - issue1 使用读口2/3；
  - PRF 内部不实现写回到读口的直接旁路；
  - p0 恒为零且禁止写入。
- [ ] IQ 在写回广播当拍完成唤醒和选择，同时把广播命中位及数据随 issue 元数据锁存。
- [ ] 下一拍操作数选择级在锁存的广播值与 PRF 同步读值之间选择，再送执行单元。
- [ ] 执行单元阻塞只影响对应 operand-read/issue 缓冲，不直接影响 IQ 满信号或 Rename。
- [ ] WB0 服务 ALU0/MLU，WB1 服务 ALU1/BRU/LSU；组内执行结果通过 `valid/ready` 仲裁。

## 数据包与验证

- [x] 公共包已增加 `FU_MLU`、RV32M 操作枚举、ROB tag 和 ROB/IQ/LSQ 入队包。
- [x] 已补齐 RV32M 的 MUL/DIV/REM 译码；MLU 执行器尚未实现。
- 验证：
  - [x] Dispatch 双路原子准入、同 bank 双写、ALU 分流和满 ROB 反压；
  - [x] Dispatch 不连接执行 `ready`、issue 或写回信号；
  - [x] ROB 双分配、乱序完成、双提交、环回和恢复；
  - [ ] IQ 最老就绪选择、双广播唤醒、阻塞保持和 recovery；
  - [x] PRF 同步四读双写、p0 恒零及无内部前递语义；
  - [ ] Rename→Dispatch→ROB/IQ→PRF 集成测试。

## 下一阶段边界

- 实现两个 8 项 IQ bank、双入队、单选择、两路广播唤醒和 recovery。
- IQ0 接收 ALU/MLU，IQ1 接收 ALU/BRU/CSR；普通 ALU 继续由组合 Dispatch 均衡分流。
- IQ 输出物理源寄存器地址、ROB tag 和广播旁路元数据，为后续操作数选择级做准备。
- LSQ、执行单元、DMEM 控制和最终写回仲裁继续保持在下一阶段之外。
