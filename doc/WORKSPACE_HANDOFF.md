# Codex 工作区交接

更新时间：2026-06-30
工程目录：`F:\RISCV_CPU`

## 新对话首先读取

重新从 `F:\RISCV_CPU` 打开 Codex 工作区后，请先让 Codex 阅读：

1. `README.md`
2. `rtl/core/defines.svh`
3. `rtl/core/core_port_pkg.sv`
4. `rtl/core/if_stage.sv`
5. `rtl/core/id_decode_pkg.sv`
6. `rtl/core/id_stage.sv`
7. `doc/RENAME_SUBSYSTEM_PLAN.md`

可直接发送：

> 请先阅读 README.md 和 doc/WORKSPACE_HANDOFF.md，再检查 rtl/core 下现有 IF/ID 实现。继续工作时必须保持双发射、package 化译码、寄存反压 buffer，以及 flush 随流水线传播而不在前级清零指令的设计理念。

## 已完成内容

### 1. 双取指 IF

- 同步单周期 64-bit 指令存储器接口。
- 一次最多返回两条 RV32 指令。
- 支持非 8-byte 对齐的 `8N+4` 跳转目标，第二槽填 NOP。
- 双槽 BTB 查询和 2-bit 饱和计数器预测。
- 槽 0 预测跳转时将槽 1 填 NOP。
- IF 输出不额外寄存指令数据；只维护 PC、valid 和预测表等必要状态。

### 2. 双路 ID

- 译码逻辑位于 `id_decode_pkg.sv`。
- 流水线公共枚举和独立级间 packed struct 位于 `core_port_pkg.sv`。
- `id_stage.sv` 只维护握手、主 buffer、skid buffer 和双路 package 调用。
- 删除了顺序流水线参考设计中的寄存器堆读数、执行/访存前递、load-use 冒险检测等接口和逻辑。
- 输出面向 Rename，而不是直接面向 Execute。
- 基础 ALU 控制中保留 1-bit `alu_ext`，供后续 Zb 或自定义运算扩展。

### 3. Flush 约定

这是本工程后续实现必须遵守的基础约定：

- flush 不表示在当前流水级立即销毁指令；
- flush 作为每条指令的 1-bit 元数据继续传播；
- ID 的主 buffer 和 skid buffer 都保存 flush；
- 同拍发生 flush 与下游握手时，输出包组合并入当前 `pipe_flush`，防止漏标；
- IF/ID 前端不因 flush 直接清空 valid，继续携带元数据并按握手流动；
- Rename 是 flushed 指令进入乱序后端前的丢弃边界，不为其分配资源；
- 已进入后端的推测状态通过分支、异常和中断共享的 `recover_event_t` 信道恢复。

### 4. Rename 状态模块

- `free_list.sv`：64 个物理寄存器的位图 Free List，支持双分配、双回收和 RRAT live mask 恢复；
- `rat_rrat.sv`：32 项 RAT/RRAT，支持双路组内 RAW/WAW 旁路、顺序双提交和恢复；
- `busy_table.sv`：64-bit Busy Table，支持双分配置 busy、双写回清 busy 和组合写回旁路；
- 三个模块统一使用 `core_port_pkg::recover_event_t`；
- `test/tb_rename_state.sv` 已覆盖模块组合行为并输出 `PASS`。
- `rename_stage.sv` 已连接三个状态模块，实现主槽+skid、参数化 renamed FIFO、部分推进和双路前缀 valid/ready；
- `test/tb_rename_stage.sv` 已覆盖输出稳定、slot0 单发、slot1 留存、flush 丢弃和统一恢复。

### 5. ROB 与物理寄存器堆

- `physical_regfile.sv`：64×32-bit 同步 4R2W，p0 恒零，PRF 内部不做写回前递；
- `rob.sv`：32 项、双分配、双完成和双提交，使用带环回位的 tag；
- ROB 只有至少两个空项时才组合拉高 `rob_allowin`，不使用本拍提交空间；
- lane0 固定早于 lane1，年龄由 ROB 指针而非 PC 数值判断；
- `test/tb_rob.sv` 已覆盖越序完成、顺序提交、最后一个空项保留、异常阻断和 tag 环回检查。

### 6. 组合 Dispatch

- `dispatch.sv` 是无时钟、无内部状态的组合分流模块；
- ROB 与目标 IQ/LSQ 必须同时可接收，才允许对应 Rename 槽出队；
- lane1 不越过 lane0，但支持 lane0-only 部分推进；
- MLU→IQ0，BRU/CSR→IQ1，LSU→LSQ，ALU 根据剩余容量动态分流；
- `test/tb_dispatch.sv` 已与真实 ROB 联合验证原子准入、同 bank 双写和满 ROB 反压。

### 7. 双分区 Issue Queue

- `issue_queue.sv`：参数化 8 项全相联 bank，双入队、单发射和任意空槽复用；
- `issue_queue_pair.sv`：IQ0 支持 ALU/MLU，IQ1 支持 ALU/BRU/CSR；
- 使用 ROB head 计算环回年龄，执行 oldest-ready 选择，允许年轻 ready 指令越过阻塞老项；
- 两路写回广播当拍参与 wakeup/select，命中数据随 issue 包锁存；
- 下游阻塞时保持选中项和旁路数据稳定；
- `test/tb_issue_queue.sv` 已覆盖真实乱序、环回年龄、双广播、功能单元忙和满队列边界。

### 8. 乱序 LSQ 与 issue1 仲裁

- `lsq.sv`：8 项统一 LSQ，双入队，Load/Store 地址 oldest-ready 乱序生成；
- Store 地址和数据解耦；数据可从 PRF 或写回广播独立取得；
- Load 不越过地址未知的老 Store，完整覆盖时支持最年轻老 Store forwarding；
- Store 仅在 ROB 顺序提交后进入寄存的内存请求级；
- recovery 清除推测项但保留已提交 Store，独立 Store 提交序号确保恢复后排空顺序；
- `issue1_arbiter.sv` 按 ROB 环形年龄在 IQ1 与 LSQ 候选中选择最老项；
- `test/tb_lsq.sv` 已覆盖数据解耦、未知地址阻塞、非冲突 Load、转发、部分覆盖、未对齐异常和恢复。

### 9. 操作数选择与执行簇

- `operand_read_stage.sv`：将 issue 元数据与同步 PRF 返回对齐，广播旁路优先，支持下游反压保持；
- `execute_stage.sv`：issue0 路由 ALU0/MLU，issue1 路由 ALU1/BRU/CSR/LSU-AGU，保留独立结果端口等待写回仲裁；
- `alu_unit.sv`、`bru_unit.sv`：单周期组合计算加一项弹性结果寄存器；BRU 只上报真实重定向，统一 recovery 仍由 ROB 头产生；
- `csr_unit.sv`：返回 CSR 旧值并生成带 ROB tag 的延迟更新包，不在乱序执行时直接修改 CSR；
- `mlu_unit.sv`：33×33 signed Vivado Multiplier 固定延迟适配，Divider Generator 双输入/结果 ready-valid 适配，并覆盖 RISC-V 除零和 overflow；
- MLU recovery 会安全排空已经部分握手的 Divider 事务，旧结果不会误配给恢复后的新指令；
- `lsu_unit.sv` 只做组合 AGU，LSQ 的 `memory_request_reg` 在 DMEM 外打一拍；`tb_lsu_four_cycle.sv` 已验证结果进入第 4 个流水周期；
- `tb_execute_stage.sv` 覆盖旁路优先、ALU、BRU、CSR、LSU、乘法固定延迟、除法独立握手和 recovery 排空。

### 10. CSR、双写回与精确提交

- `csr_file.sv`：最小机器态 CSR，CSR 指令一拍时序读，标准 trap/mret 的 MIE/MPIE、mepc、mcause、mtval 更新；
- 机器软件/定时器/外部中断经过两级同步，优先级 external > software > timer，`mtvec` 支持 Direct/Vectored；
- `csr_unit.sv` 将未实现 CSR 或真实写只读 CSR转换为精确 illegal-instruction；
- `writeback_stage.sv`：WB0(ALU0/MLU) 与 WB1(ALU1/BRU/LSQ/CSR) 独立 round-robin，同时生成 PRF write、wakeup 和 ROB complete；
- `csr_commit_buffer.sv`：单项、按 ROB tag 匹配，只在 commit_fire 时写 CSR，并阻止后一条 CSR 提前读取；
- `commit_controller.sv`：异常、重定向、MRET 和中断只在 ROB 边界产生统一 recovery；
- `writeback_commit_stage.sv`：将 WB、CSR cache、CSR file 和 commit control 封装为完整闭环；
- `tb_csr_file.sv`、`tb_writeback_commit_stage.sv` 已覆盖异常/中断状态、时序读、双写回冲突和精确 CSR 提交。

## 当前关键接口

### IF -> ID

```systemverilog
fs_to_ds_valid
ds_allowin
fs_to_ds_bus[`FS_DS_WIDTH-1:0]
fs_exc_bus[`EXC_WIDTH-1:0]
```

### ID -> Rename

```systemverilog
ds_to_rn_valid
rn_allowin
core_port_pkg::ds_rn_bundle_t ds_to_rn_bus
```

`ds_to_rn_bus.lane0/lane1` 分别为 `core_port_pkg::ds_rn_slot_t`。

当前宽度：

- `FS_DS_SLOT_WIDTH = 97`
- `FS_DS_WIDTH = 194`
- `$bits(core_port_pkg::ds_rn_slot_t) = 225`
- `$bits(core_port_pkg::ds_rn_bundle_t) = 450`
- `EXC_WIDTH = 39`

ID→Rename 已使用 typed port，修改 `ds_rn_slot_t` 后 package 会自动派生宽度，不再同步维护 `defines.svh` 宏。

## 验证状态

QuestaSim 2024.1 路径：

```text
F:\questasim64_2024.1\win64
```

已完成的验证项目：

- IF 顺序双取值；
- `8N+4` 目标的单槽取值与第二槽 NOP；
- lane 0/lane 1 分支预测；
- ID 双路 ALU/load 译码；
- Rename 反压下主 buffer 保持；
- 第二组取指包进入 skid；
- skid 向主 buffer 搬运；
- NOP 槽无效化；
- flush 同拍输出、反压保持及正常握手流出。
- Free List 双分配、双回收和 RRAT live mask 恢复；
- RAT/RRAT 的 lane1 RAW/WAW 旁路和双提交；
- Busy Table 的分配置忙、写回唤醒和恢复清零。
- Rename 输出停顿保持、双路前缀接收、主/skid 反压和参数化 FIFO；
- 只剩一个物理标签时 lane0 单发、lane1 留存并在回收后继续；
- flushed bundle 丢弃及统一 recovery 清空。
- ROB 双分配、乱序双完成、前缀双提交、满边界和统一恢复。
- 组合 Dispatch 的 ALU 均衡、固定功能单元路由、部分推进和 ROB 原子写入。
- 两个 IQ bank 的 oldest-ready 乱序选择、双广播当拍唤醒、阻塞保持和恢复。
- LSQ 乱序地址生成、Store-to-Load forwarding、提交 Store 恢复保留和 issue1 仲裁。
- 操作数级广播/PRF 选择、ALU/BRU/CSR 结果和执行端反压。
- MLU 固定延迟乘法、Divider 双输入握手、除零/溢出及 recovery 安全排空。
- LSU issue→PRF→AGU→外部请求寄存→同步 DMEM 第四周期返回。
- CSR 时序读、非法访问、trap/mret、机器中断同步与标准优先级。
- WB0/WB1 round-robin、异常禁止 PRF 写入、CSR tag 匹配提交和统一 recovery。

最终结果：`0 Errors, 0 Warnings`，行为测试输出 `PASS`。

## 已知约束和待确认项

1. `PC_START` 当前为 `32'h0000_0000`，接入 SoC 时需要按实际地址空间调整。
2. JALR 当前不更新直接映射 BTB；将来可增加独立间接跳转预测结构。
3. 软件中的真实 NOP 与 IF 填充 NOP 当前都会被 ID 标记为无效槽。若将来要求 `instret` 精确统计软件 NOP，需要增加显式 lane-valid，而不能只依赖 NOP 编码。
4. `ds_rn_slot_t` 已支持 RV32I/M、Zicsr 和基本 SYSTEM 分类；F、Zb 尚未实现。
5. `physical_regfile.sv` 已实现同步 4R2W 和 p0 恒零；PRF 内部不做前递，无效读请求保持上次值，`operand_read_stage.sv` 选择广播值或 PRF 读值。
6. 当前目录未形成完整 SoC；Rename、PRF、ROB、Dispatch、IQ、LSQ、执行、WB0/WB1 和机器态 CSR/提交控制已完成，但全后端顶层接线尚未实现。
7. LSQ 当前对地址未知老 Store 采取保守阻塞；部分覆盖不合并，MMIO/强序访问分类和违例 replay 尚未实现。
8. MLU 当前采用单在途策略；乘法 `MUL_LATENCY` 必须与 Vivado IP 配置一致，Divider 建议配置为 33-bit signed 并分别接出 quotient/remainder。
9. CSR 仅实现 M-mode 最小集合，不实现特权等级切换、delegation、PMP 和 S/U CSR；`MTVEC_RESET`、`MHARTID` 与空 ROB 时的 `interrupt_pc` 由 SoC 顶层确定。

## 推荐后续实现顺序

1. 串联 Rename→Dispatch→ROB/IQ/LSQ→Execute→Writeback/Commit 完整后端。
2. 将写回连接 PRF、Busy Table 与 ROB complete，将 commit_ready/recover 连接 LSQ 和 Rename 状态恢复。
3. 确认 SoC 的 trap vector、CLINT/外部中断引脚及空 ROB 下一 PC。
4. 补齐双发射、写回拥塞、异常/中断和连续 recovery 压力测试。

每完成一级，都应优先运行局部 QuestaSim 编译和定向 testbench，再扩展到完整处理器联调。
