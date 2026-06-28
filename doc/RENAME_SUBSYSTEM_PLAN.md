# 双发射 Rename 子系统设计方案

更新时间：2026-06-28

> 本文档用于评审下一阶段的 Rename 子系统设计，当前仅记录方案，不代表已经开始 RTL 实现。

## 当前实现状态

截至 2026-06-28，公共控制类型、三个独立状态模块和 `rename_stage.sv` 均已完成第一版 RTL。`test/tb_rename_state.sv` 与 `test/tb_rename_stage.sv` 已分别通过状态模块和 Rename 集成定向测试。

## 1. 设计目标

下一阶段构建面向 RV32 双发射乱序处理器的寄存器重命名子系统，采用显式物理寄存器重命名：

- 32 个架构整数寄存器；
- 64 个物理整数寄存器，物理寄存器编号宽度为 6 bit；
- 架构寄存器 `x0` 永远映射到物理寄存器 `p0`；
- 使用 Free List 管理未占用物理寄存器；
- 使用 RAT 保存推测映射，RRAT 保存已提交映射；
- 使用 Busy Table 保存物理寄存器结果是否就绪；
- 支持每拍最多重命名两条指令，并允许资源不足时只推进程序序靠前的一条；
- 使用公共 package 定义级间数据包和共享类型；
- 保持级间反压寄存化，不形成跨 ID、Rename、Dispatch 的长组合 ready 链。

本阶段只实现 Rename 子系统本身，不实现物理寄存器堆、ROB、Dispatch、IQ 或 LSQ 主体。

## 2. 总体结构

Rename 子系统划分为以下模块：

```text
                       +------------------+
ID decode bundle ----> | rename_stage     | ----> renamed bundle -> Dispatch
                       |                  |
                       | main + skid      |
                       | renamed FIFO     |
                       +----+----+----+----+
                            |    |    |
                 +----------+    |    +-----------+
                 |               |                |
          +------v------+ +------v------+ +-------v------+
          | free_list   | | rat_rrat    | | busy_table   |
          +-------------+ +-------------+ +--------------+
```

建议文件划分：

```text
rtl/core/
├─ core_port_pkg.sv
├─ free_list.sv
├─ rat_rrat.sv
├─ busy_table.sv
└─ rename_stage.sv
```

其中：

- `core_port_pkg.sv` 定义共享参数、枚举，以及每一段流水线各自独立的 packed struct；
- `free_list.sv` 只负责物理寄存器分配、回收和恢复；
- `rat_rrat.sv` 负责推测映射、提交映射、双路旁路和恢复；
- `busy_table.sv` 负责物理寄存器就绪状态；
- `rename_stage.sv` 负责输入缓冲、重命名调度、部分推进和输出握手。

## 3. 公共数据包

### 3.1 `core_port_pkg`

现有 `id_decode_pkg.sv` 中与具体译码算法无关的共享内容迁移到 `core_port_pkg.sv`，包括：

- 功能单元、ALU、分支、访存和 CSR 操作枚举；
- IF→ID 独立使用的 `fs_ds_slot_t/fs_ds_bundle_t`；
- ID→Rename 独立使用的 `ds_rn_slot_t/ds_rn_bundle_t`；
- Rename 输出包；
- 提交映射更新包；
- 写回唤醒包；
- 架构和物理寄存器数量及编号宽度。

`id_decode_pkg.sv` 只保留立即数生成、指令分类和 `ds_rn_slot_t` 构造函数，并通过 `import core_port_pkg::*` 使用公共类型。后续每增加一段流水线接口，都在同一公共 package 内新增该段专用的 slot/bundle 类型，不跨级复用万能结构体。

建议的 Rename 单指令输出信息为：

```systemverilog
typedef struct packed {
    ds_rn_slot_t dec;

    logic [PHYS_REG_IDX_WIDTH-1:0] prs1;
    logic [PHYS_REG_IDX_WIDTH-1:0] prs2;
    logic [PHYS_REG_IDX_WIDTH-1:0] pdst;
    logic [PHYS_REG_IDX_WIDTH-1:0] stale_pdst;

    logic src1_ready;
    logic src2_ready;
    logic pdst_valid;
} rename_uop_t;
```

字段语义：

- `prs1/prs2`：源架构寄存器当前对应的物理寄存器；
- `pdst`：本指令新分配的目标物理寄存器；
- `stale_pdst`：目标架构寄存器原来对应的物理寄存器，指令提交后由 Free List 回收；
- `src1_ready/src2_ready`：重命名时刻 Busy Table 给出的源就绪快照，后续仍需由 IQ 根据写回广播继续唤醒；
- `pdst_valid`：本指令是否实际分配了新物理寄存器。

ID 到 Rename 使用 package 中的 `ds_rn_bundle_t` typed port，避免长期手工维护位宽切片；实际宽度由 `$bits` 自动派生。

## 4. Free List

### 4.1 数据结构

Free List 使用 64-bit 位图：

- bit 为 `1` 表示对应物理寄存器空闲；
- bit 为 `0` 表示已被架构映射或推测指令占用；
- `free_bitmap[0]` 永远保持 `0`，禁止分配 `p0`。

复位状态：

```text
p0..p31  : 已占用，分别作为 x0..x31 的初始映射
p32..p63 : 空闲
```

### 4.2 双路分配

Free List 每拍最多提供两个不同的物理寄存器号。实现上可使用级联优先编码：

1. 第一个优先编码器从当前位图选择第一个空闲寄存器；
2. 临时屏蔽第一个结果；
3. 第二个优先编码器从剩余位图选择第二个空闲寄存器。

实际消耗数量取决于当前准备重命名的两条指令是否写 `rd`。写 `x0`、无目标指令、异常指令和 flushed 指令均不申请物理寄存器。

### 4.3 分配与回收时机

物理寄存器只在指令成功进入 renamed FIFO 时正式分配。进入 Rename 输入 buffer 不得提前改变 Free List。

ROB 提交时最多回收两个 `stale_pdst`。本拍回收的标签从下一拍开始参与重新分配，以避免形成 commit 到 Rename 优先编码器的长组合路径。

正常状态更新可表达为：

```text
free_next = (free_bitmap | commit_free_mask) & ~rename_alloc_mask
```

分配候选只从本拍开始时的 `free_bitmap` 产生，不从 `commit_free_mask` 直接旁路。

### 4.4 恢复

选择 RRAT 全恢复后，Free List 不采用简单历史快照，而是根据恢复后的 RRAT 重建：

```text
used_mask = RRAT 中所有有效物理映射的集合
free_bitmap = ~used_mask
free_bitmap[0] = 0
```

如果恢复与分支提交同拍发生，必须使用已经应用本拍提交更新的 `RRAT_next` 生成 `used_mask`。

## 5. RAT 与 RRAT

### 5.1 基本状态

RAT 和 RRAT 均包含 32 项，每项为 6-bit 物理寄存器编号。

复位时：

```text
RAT[xN]  = pN
RRAT[xN] = pN
```

并持续强制：

```text
RAT[x0]  = p0
RRAT[x0] = p0
```

### 5.2 双路查询与更新

每拍最多查询两条指令的：

- `rs1` 映射；
- `rs2` 映射；
- `rd` 原映射，即 `stale_pdst`。

RAT 只在相应指令成功进入 renamed FIFO 且 `pdst_valid=1` 时更新。

### 5.3 组内相关旁路

双发射组必须按 lane0、lane1 的程序序处理。

若 lane0 写某个架构寄存器，lane1 又读取该寄存器：

```text
lane1.prs = lane0.pdst
```

若 lane0 和 lane1 写同一个架构寄存器：

```text
lane0.stale_pdst = old RAT[rd]
lane1.stale_pdst = lane0.pdst
最终 RAT[rd]     = lane1.pdst
```

这同时解决双路组内 RAW 和 WAW 映射问题。

### 5.4 RRAT 提交

RRAT 由 ROB 的顺序提交端口更新，每拍最多接收两条提交映射。双提交必须按程序序依次作用，尤其要覆盖同拍两条指令写同一架构寄存器的情况。

Flushed、无目标或写 `x0` 的指令不得更新 RRAT。

## 6. Busy Table

Busy Table 使用 64-bit 位图：

- bit 为 `1` 表示物理寄存器结果尚未产生；
- bit 为 `0` 表示结果可读；
- `busy[0]` 永远为 `0`。

状态变化：

- Rename 分配新 `pdst` 时将对应 bit 置 `1`；
- 最多两个写回端口在结果产生时将对应 bit 清 `0`；
- 恢复到 RRAT 时整体清零，因为能够提交的物理寄存器结果必然已经产生。

同拍冲突时采用“新分配置 busy 优先于写回清除”的规则。

源就绪查询还需要处理两类旁路：

1. 若源物理寄存器本拍写回，可组合视为 ready；
2. 若 lane1 读取 lane0 本拍新分配的 `pdst`，必须强制标记为 not ready，不能读取该标签分配前的旧 Busy 状态。

## 7. Rename 级缓冲与握手

### 7.1 为什么需要 buffer

`id_stage` 向 Rename 接收的 `rn_allowin` 是寄存输出，而 Rename 后面还会受以下资源约束：

- Free List 剩余物理寄存器数量；
- renamed FIFO 剩余空间；
- Dispatch、ROB、IQ 和 LSQ 的反压。

若 Rename 没有自己的弹性存储，上述状态在相邻周期变化时可能导致译码包丢失、重复分配或产生长组合反压链。

因此采用：

- 一个译码包主槽；
- 一个译码包 skid 槽；
- 一个深度参数化的 renamed FIFO，默认 `RENAME_FIFO_DEPTH=2`。

### 7.2 状态更新边界

输入主槽和 skid 槽保存尚未完成重命名的 `decode_bundle_t`。renamed FIFO 保存已经分配好物理标签的 `rename_uop_t`。

RAT、Free List 和 Busy Table 的更新时机统一定义为：

```text
rename_fire = 指令成功进入 renamed FIFO
```

后续 Dispatch 停顿只会让结果停留在 renamed FIFO，不会再次分配，也不会改变已经锁存的物理标签。

### 7.3 部分推进

双路输入先移除无效槽并按程序序压紧。

当资源只能支持一条指令时：

- 只重命名程序序最老的一条；
- 第二条继续留在输入主槽；
- RAT 已包含第一条产生的新映射，因此第二条下一拍查询时自然观察到正确结果；
- 不允许下一组指令越过被保留的第二条。

若 lane0 本身无效、lane1 有效，则 lane1 作为当前最老指令处理。

### 7.4 Rename 到 Dispatch

输出采用双槽 `valid/ready` 接口，并保持前缀约束：

```text
valid[1] -> valid[0]
fire[1]  -> fire[0]
```

允许的接收数量为 0、1 或 2 条。只接收 slot0 后，原 slot1 在下一拍压到 slot0，保证输出顺序连续。

下游停顿时，对应 slot 的 `valid` 和完整 `rename_uop_t` 必须保持稳定。

`rn_allowin` 继续采用寄存输出，其计算只反映 Rename 输入主槽和 skid 槽是否还能可靠吸收下一拍 ID 数据。

## 8. Flush 与恢复策略

### 8.1 Flushed 指令边界

IF/ID 仍可保留当前“flush 作为指令元数据随 buffer 传播”的做法，但 Rename 成为错误路径指令进入乱序后端前的丢弃边界。

当 `ds_rn_slot_t.flush=1` 时，Rename：

- 消费该指令；
- 不申请物理寄存器；
- 不更新 RAT 或 Busy Table；
- 不进入 renamed FIFO；
- 不进入 ROB、IQ 或 LSQ。

这可以防止错误路径指令污染重命名状态或再次触发分支重定向。

### 8.2 RRAT 全恢复的限制

本方案不保存分支 RAT 检查点，也不通过 ROB 逆序回滚 RAT，而是直接恢复到 RRAT。因此，分支误预测不能在执行级立即执行 `RAT <= RRAT` 后直接从分支目标继续。

原因是 RRAT 只包含已提交状态。执行级分支之前可能仍有尚未提交的老指令，直接恢复会丢失这些老指令产生的映射。

所以本方案规定：

- 分支可以提前执行并记录真实方向和目标；
- 真正的恢复和前端重定向延迟到该分支到达 ROB 头；
- 此时所有更老指令已经提交，RRAT 已经包含正确的分支前状态；
- 如果分支自身写目标寄存器，应先提交该映射，再从 `RRAT_next` 恢复 RAT。

这种方式恢复简单但会增加误预测代价。将来若性能不足，可再升级为分支检查点或 ROB 回滚。

### 8.3 恢复优先级

分支误预测、同步异常和外部中断共享同一条全核 recovery/flush 信道；信道携带有效位、恢复原因和重定向目标，避免各流水级维护多套清空控制。`recover_valid` 的优先级高于：

- ID 输入接收；
- Rename 分配；
- renamed FIFO 出入队；
- 普通 RAT 和 Free List 更新；
- Busy Table 的普通置位与清除。

恢复同拍的顺序定义为：

1. 按 lane0、lane1 程序序计算本拍提交后的 `RRAT_next`；
2. `RAT <= RRAT_next`；
3. 根据 `RRAT_next` 重建 Free List；
4. Busy Table 清零；
5. 清空 Rename 主槽、skid 和 renamed FIFO；
6. 下一拍重新允许 ID 输入。

ROB、IQ、LSQ 和其他后端结构也必须在同一恢复事件下清空全部未提交状态。

## 9. 后端衔接

Rename 本阶段只输出统一的 renamed bundle，不直接决定最终队列。未来 Dispatch 按已有方向分流：

```text
所有有效指令 -> ROB
非访存指令   -> IQ
load/store    -> LSQ
```

允许 slot0 单发后，Dispatch 必须根据程序序提供前缀 ready，不能在 slot0 无法接收时单独接收 slot1。

## 10. 验证计划

### 10.1 Free List

- 复位后只有 `p32..p63` 可分配；
- `p0` 永远不可分配；
- 单路和双路分配返回不同标签；
- 资源只剩一个时只允许最老写目标指令推进；
- 双路提交回收正确；
- 本拍回收标签下一拍才可重新分配；
- 恢复后位图与 RRAT live mask 完全一致。

### 10.2 RAT/RRAT

- 复位映射为 `xN->pN`；
- 单路和双路 RAT 更新；
- lane1 对 lane0 的 RAW 旁路；
- 双路同目标 WAW 的 stale 链；
- 双提交写同一架构寄存器时最终映射正确；
- `x0` 映射不可修改；
- 提交与恢复同拍时使用 `RRAT_next`。

### 10.3 Busy Table

- 新分配目标被置 busy；
- 双写回清除正确；
- 写回同拍源查询旁路；
- lane1 读取 lane0 新目标时保持 not ready；
- `p0` 永远 ready；
- 恢复清零。

### 10.4 Rename 集成

- 双路连续重命名；
- lane0 单发并保留 lane1；
- lane1 压缩到 slot0；
- 软件 NOP 或无效槽不占资源；
- 异常指令进入后端但不错误分配目标；
- flushed 指令在 Rename 丢弃；
- ID 反压下主槽和 skid 数据保持；
- Dispatch 反压下 renamed FIFO 标签保持稳定；
- 恢复清空全部 Rename 内部状态；
- Free List 耗尽后正确反压，提交回收后恢复运行。

### 10.5 建议断言

- `RAT[0] == 0`、`RRAT[0] == 0`；
- `free_bitmap[0] == 0`、`busy_bitmap[0] == 0`；
- 同拍分配的两个物理标签不相等；
- `out_valid[1]` 蕴含 `out_valid[0]`；
- slot1 被接收时 slot0 必须同拍被接收；
- 下游停顿时输出数据稳定；
- 没有 `rename_fire` 时不得消耗 Free List 或更新 RAT；
- flushed 指令不得产生 `pdst_valid`；
- RAT/RRAT 中除 `x0` 外的有效提交映射不应出现非法物理编号。

### 10.6 工具与完成标准

优先使用 QuestaSim 2024.1 进行：

1. package 与单模块编译；
2. Free List、RAT/RRAT、Busy Table 定向测试；
3. Rename 集成 testbench；
4. 双发射、部分推进、反压和恢复随机组合测试。

完成标准：

- 编译结果 `0 Errors, 0 Warnings`；
- 所有定向测试和断言通过；
- package 的 `$bits` 与所有公开接口一致；
- 实现完成后同步更新 `README.md` 和 `doc/WORKSPACE_HANDOFF.md`。

## 11. 当前已锁定的选择

1. 64 个物理寄存器，`p0` 永久对应 `x0`；
2. Free List 独立模块；
3. RAT 与 RRAT 合并为一个模块；
4. Busy Table 作为独立模块在本阶段一并实现；
5. Rename 使用输入主槽、skid 和 renamed FIFO；
6. 允许资源不足时只推进程序序第一条指令；
7. Rename 到 Dispatch 使用双槽 valid/ready 前缀接口；
8. flushed 指令在 Rename 直接丢弃；
9. 分支误预测采用 ROB 头触发的 RRAT 全恢复；
10. 暂不实现分支检查点或 ROB 逆序回滚；
11. Busy Table 暂定两个写回端口；
12. Free List 本拍回收的物理寄存器从下一拍开始可分配。
13. 分支误预测、异常和中断共享统一 recovery/flush 信道。
14. ID→Rename 使用 `core_port_pkg::ds_rn_bundle_t` typed port，后续级间各自定义独立 packet 类型。
15. renamed FIFO 深度参数化，默认深度为 2。

## 12. 已完成确认

以下评审项已经确定：

1. 接受误预测恢复等待分支到达 ROB 头，并与异常、中断共用 recovery/flush 信道；
2. Rename 是 flushed 指令进入后端前的最终丢弃边界；
3. 本拍提交回收的物理标签从下一拍开始重新参与分配；
4. 使用 typed struct 替换 ID→Rename 扁平总线；
5. renamed FIFO 使用参数化深度，默认值为 2。
