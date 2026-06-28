# Codex 工作区交接

更新时间：2026-06-28
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
- `$bits(core_port_pkg::ds_rn_slot_t) = 221`
- `$bits(core_port_pkg::ds_rn_bundle_t) = 442`
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

最终结果：`0 Errors, 0 Warnings`，行为测试输出 `PASS`。

## 已知约束和待确认项

1. `PC_START` 当前为 `32'h0000_0000`，接入 SoC 时需要按实际地址空间调整。
2. JALR 当前不更新直接映射 BTB；将来可增加独立间接跳转预测结构。
3. 软件中的真实 NOP 与 IF 填充 NOP 当前都会被 ID 标记为无效槽。若将来要求 `instret` 精确统计软件 NOP，需要增加显式 lane-valid，而不能只依赖 NOP 编码。
4. `ds_rn_slot_t` 已支持 RV32I、Zicsr 和基本 SYSTEM 分类；M、F、Zb 尚未实现。
5. 当前目录未形成完整 SoC；Rename 子系统已完成，但 ROB、Dispatch、IQ、LSQ、执行和写回尚未实现。
6. 当前变更尚未提交或推送。

## 推荐后续实现顺序

1. 定义 Rename→Dispatch/ROB 的资源接收契约。
2. 实现双路 ROB 分配和顺序提交骨架。
3. 按 `non-memory -> IQ`、`load/store -> LSQ` 分流。
4. 实现唤醒/选择、执行和 CDB/写回。
5. 补齐统一 recovery/flush 信道在全核的连接和恢复测试。

每完成一级，都应优先运行局部 QuestaSim 编译和定向 testbench，再扩展到完整处理器联调。
