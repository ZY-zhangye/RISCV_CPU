# Codex 工作区交接

更新时间：2026-06-28
工程目录：`F:\RISCV_CPU`

## 新对话首先读取

重新从 `F:\RISCV_CPU` 打开 Codex 工作区后，请先让 Codex 阅读：

1. `README.md`
2. `rtl/core/defines.svh`
3. `rtl/core/if_stage.sv`
4. `rtl/core/id_decode_pkg.sv`
5. `rtl/core/id_stage.sv`

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
- 执行和写回阶段负责屏蔽 flushed 指令的副作用；
- 后续新增 Rename、ROB、IQ、LSQ、执行与写回模块时，不要重新引入“见到 flush 就清空前级指令包”的语义。

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
ds_to_rn_bus[`DS_RN_WIDTH-1:0]
```

`ds_to_rn_bus = {lane1_decode, lane0_decode}`。

当前宽度：

- `FS_DS_SLOT_WIDTH = 97`
- `FS_DS_WIDTH = 194`
- `DS_RN_SLOT_WIDTH = 221`
- `DS_RN_WIDTH = 442`
- `EXC_WIDTH = 39`

修改 `decode_pkt_t` 后必须同步修改 `defines.svh` 的 `DS_RN_SLOT_WIDTH`，并用 `$bits(decode_pkt_t)` 检查一致性。

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

最终结果：`0 Errors, 0 Warnings`，行为测试输出 `PASS`。

## 已知约束和待确认项

1. `PC_START` 当前为 `32'h0000_0000`，接入 SoC 时需要按实际地址空间调整。
2. JALR 当前不更新直接映射 BTB；将来可增加独立间接跳转预测结构。
3. 软件中的真实 NOP 与 IF 填充 NOP 当前都会被 ID 标记为无效槽。若将来要求 `instret` 精确统计软件 NOP，需要增加显式 lane-valid，而不能只依赖 NOP 编码。
4. `decode_pkt_t` 已支持 RV32I、Zicsr 和基本 SYSTEM 分类；M、F、Zb 尚未实现。
5. 当前目录未形成完整 SoC，也还没有 Rename/ROB/IQ/LSQ/执行/写回实现。
6. 当前没有要求提交或推送；开始版本管理前先检查该目录是否已初始化 Git，并确认目标分支。

## 推荐后续实现顺序

1. 定义物理寄存器、ROB、IQ、LSQ 的共享类型和宽度。
2. 实现双路 Rename：RAT 查询、Free List 分配、Busy Table、组内 RAW 重命名。
3. 实现双路 ROB 分配和顺序提交骨架。
4. 按 `non-memory -> IQ`、`load/store -> LSQ` 分流。
5. 实现唤醒/选择、执行和 CDB/写回。
6. 在执行与写回处落实 `flush` 的副作用屏蔽，然后补充精确异常和恢复测试。

每完成一级，都应优先运行局部 QuestaSim 编译和定向 testbench，再扩展到完整处理器联调。
