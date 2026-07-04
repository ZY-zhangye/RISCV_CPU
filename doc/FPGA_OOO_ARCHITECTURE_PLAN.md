# 面向 FPGA 的双宽前端三发射乱序 RISC-V 核架构规划

> 目标平台：Xilinx XC7K325T-FFG900-2
> 目标 ISA：RV32I + M + Zicsr
> 设计目标：精确异常、至少双发射、具备三发射能力；在 XC7K325T-FFG900-2 上完成布局布线后主频不低于 200 MHz（5.000 ns）
> 存储条件：16 KB IROM、256 KB Data RAM，均基于 FPGA BRAM，可重新组织
> 性能评价：以类似 CoreMark 的综合程序性能为主要依据

---

## 1. 设计背景

现有乱序设计已经通过 RTL 功能验证，但在 FPGA 实现阶段出现严重时序问题：

- 目标器件：XC7K325T-FFG900-2
- 实际主频约为 50 MHz
- 主要时序瓶颈集中在：
  - ROB
  - Rename
  - 大范围组合搜索
  - 多级反压传播
  - 广播与恢复网络

因此，新版本不再针对原架构进行局部修补，而是重新规划一套面向 FPGA 物理实现的乱序超标量微架构。

新架构的核心原则是：

1. 正常执行路径必须拆分为清晰的流水阶段。
2. 避免全局 CAM、全宽优先编码器和大规模组合恢复。
3. 所有队列采用固定槽位和直接索引，不做整体压缩移动。
4. 后端阻塞不能在单周期内组合传播至前端。
5. 性能设计以 `IPC × Fmax` 为核心，而不是单纯追求更宽的理论发射宽度。

---

# 2. 核心总体定位

推荐采用：

> **四取指、双译码、双重命名、三路动态发射、双写回、双提交的乱序 RV32IM_Zicsr 核。**

主要宽度如下：

| 环节 | 宽度 |
|---|---:|
| IROM 取指 | 128 bit，最多 4 条指令 |
| Instruction Buffer 写入 | 最多 4 条 |
| Decode | 2 条 |
| Rename | 2 条 |
| ROB Allocate | 2 条 |
| Dispatch | 2 条 |
| 最大动态 Issue | 3 条 |
| 最大执行完成 | 3 条以上，允许缓冲 |
| 全局 Writeback | 2 条 |
| Commit | 2 条 |

该架构不采用全流水线严格三宽，而是使用：

- 双宽前端；
- 双宽分配；
- 三路后端发射；
- 双宽提交。

这样可以保留三发射性能潜力，同时避免三宽 Rename、ROB Allocate 和 Commit 再次成为关键路径。

---

# 3. 总体微架构

```text
                         ┌─────────────────────────┐
                         │ Branch Predictor        │
                         │ BTB + BHT               │
                         └────────────┬────────────┘
                                      │
┌─────┐  ┌─────┐  ┌─────┐  ┌────────────┐  ┌────────┐
│ F0  │→ │ F1  │→ │ F2  │→ │ Instr Buf  │→ │ Decode │
└─────┘  └─────┘  └─────┘  └────────────┘  │ 2-wide │
                                             └───┬────┘
                                                 │
                                           ┌─────▼─────┐
                                           │ Rename R0 │
                                           │ Map Read  │
                                           └─────┬─────┘
                                                 │
                                           ┌─────▼─────┐
                                           │ Rename R1 │
                                           │ Allocate  │
                                           └─────┬─────┘
                                                 │
                                           ┌─────▼─────┐
                                           │ Dispatch  │
                                           │ Buffer    │
                                           └─────┬─────┘
                                                 │
                    ┌────────────────────────────┼─────────────────────────┐
                    │                            │                         │
             ┌──────▼──────┐             ┌──────▼──────┐          ┌──────▼──────┐
             │ Integer IQ  │             │ Memory IQ   │          │ Mul/Div IQ  │
             │ 12 entries  │             │ 8 entries   │          │ 4 entries   │
             └──────┬──────┘             └──────┬──────┘          └──────┬──────┘
                    │                            │                         │
            ┌───────┴────────┐              ┌────▼────┐              ┌────▼────┐
            │                │              │ LSU/AGU │              │ MDU     │
       ┌────▼────┐      ┌────▼────┐         └────┬────┘              └────┬────┘
       │ INT0    │      │ INT1/BR │              │                         │
       └────┬────┘      └────┬────┘              │                         │
            └────────┬────────┴───────────────────┴─────────────────────────┘
                     │
               ┌─────▼─────┐
               │ Writeback │
               │ 2 ports   │
               └─────┬─────┘
                     │
              ┌──────▼──────┐
              │ PRF + ROB   │
              │ Complete    │
              └──────┬──────┘
                     │
               ┌─────▼─────┐
               │ Commit ×2 │
               └───────────┘
```

---

# 4. 推荐流水线

建议采用约 12～15 级流水。

```text
F0   PC 生成、预测器索引
F1   IROM、BTB、BHT 同步读取
F2   预测结果选择、取指块对齐
FB   Instruction Buffer 环形存储
FO   Instruction Buffer 寄存输出

D0   双译码
R0   RAT 映射查询并寄存
R1   PRD ready 查询、Lane 内依赖解析、已寄存资源响应
DP   Dispatch Buffer
IS   Issue Select
RR   PRF Read / Bypass Select
EX   整数执行、分支执行或 AGU
M0   访存地址寄存
M1   BRAM 读取
M2   Load 提取与扩展
WB   写回
CM   双提交
```

普通整数指令路径：

```text
F0 → F1 → F2 → FB → FO → D0 → R0 → R1 → DP → IS → RR → EX → WB → CM
```

Load 指令路径：

```text
F0 → F1 → F2 → FB → FO → D0 → R0 → R1 → DP → IS → RR
→ AGU → M0 → M1 → M2 → WB → CM
```

重点不是减少流水级，而是保证每一级组合逻辑可控。

---

# 5. 前端设计

## 5.1 IROM 组织

16 KB IROM 推荐改为：

```text
1024 × 128 bit
```

地址划分：

```text
block_index = PC[13:4]
slot_index  = PC[3:2]
```

每次读取 4 条 RV32 指令。

因为当前不支持 RVC，所有指令均为 32 bit，对齐和取指块切分较简单。

建议：

- 使用 BRAM 同步读取；
- 启用 BRAM 输出寄存器；
- IROM 输出必须进入流水寄存器；
- 不允许 IROM 输出直接参与复杂分支选择和前端反压。

---

## 5.2 Instruction Buffer

推荐配置：

```text
容量：8 条指令
输入：每周期最多 4 条
输出：每周期最多 2 条
```

采用环形队列，不采用整体移位结构。

环形存储到 Decode 之间必须设置双路寄存输出（FO）。FO 空闲或其 bundle 被 Decode
整体接受时，才从 head/head+1 预取下一组；反压期间 FO 的 valid 与 payload 保持不变。
容量统计包含 FO 中的 0～2 条指令，逻辑总容量仍为 8，不得借输出寄存器暗中扩大容量。
该边界用于切断 `entries[head]` 选择、跨模块布线和完整译码的单周期组合路径。

维护：

```text
head_ptr
tail_ptr
entry_valid
entry_inst
entry_pc
entry_pred_info
entry_fetch_id
```

如果一个 128-bit 取指块内部出现预测跳转：

- 保留跳转指令及其之前的指令；
- 丢弃跳转指令之后的 slot；
- 下一取指地址跳转至预测目标。

---

## 5.3 分支预测器

起步参数：

| 结构 | 参数 |
|---|---:|
| BTB | 128 项，直接映射 |
| BHT | 512 项，2-bit 饱和计数器 |
| 最大未决分支 | 4 条 |
| Branch Checkpoint | 4 项 |

预测流程：

```text
F0：PC 同时送 IROM、BTB、BHT
F1：得到指令块和预测器数据
F2：选择块内最早预测跳转，生成 next PC
```

每个取指块最多采用一个预测跳转。

V1 不实现 Return Address Stack（RAS）。JALR，包括常见函数返回，统一由 BTB 预测
目标。RAS 只影响返回预测准确率，不影响功能正确性；待基础乱序流水、分支恢复和
200 MHz 时序稳定后，再评估增加 8 项推测 RAS 及其 checkpoint 恢复。

---

# 6. Decode

Decode 宽度为 2。

每条指令输出统一的微操作信息：

```text
pc
inst
rs1
rs2
rd
need_rs1
need_rs2
write_rd
imm
fu_type
alu_op
branch_op
mem_op
muldiv_op
csr_op
is_ecall
is_ebreak
is_mret
pred_taken
pred_target
fetch_id
```

Decode 阶段只做：

- 指令格式识别；
- 立即数生成；
- FU 分类；
- 异常类型初步识别；
- 不做资源分配；
- 不直接查询 ROB、IQ、LSQ。

---

# 7. Rename

Rename 拆分为两个流水阶段。

---

## 7.1 Rename R0：Map Read

RAT：

```text
32 × 6 bit
```

由于 PRF 为 64 项，物理寄存器号宽度为 6 bit。

R0 完成：

- 两条指令的 4 个源寄存器 RAT 查询；
- 两个目的寄存器旧映射查询；
- 将 prs1/prs2/old_prd 与 uop、资源需求锁存到 R0/R1 边界。

RAT 应采用寄存器阵列和组合读，不使用 BRAM。

PRD ready table 不得通过 RAT 组合输出继续级联查询。ready 查询必须由已寄存的 PRD
编号驱动，并在下一边界锁存；写回 tag bypass 只允许位于 ready 查询这一侧。这样把
`32:1 RAT map mux → 64:1 ready mux` 拆成两个周期。

---

## 7.2 Lane 内 RAW

例如：

```assembly
add x5, x1, x2
sub x6, x5, x3
```

Lane1 的 `prs1` 使用 Lane0 新分配的物理寄存器：

```systemverilog
lane1_prs1 =
    lane0_write_rd &&
    (lane0_rd != 5'd0) &&
    (lane0_rd == lane1_rs1)
    ? lane0_new_prd
    : rat_rs1;
```

---

## 7.3 Lane 内 WAW

例如：

```assembly
add x5, x1, x2
sub x5, x3, x4
```

映射关系：

```text
lane0.old_prd = 原 RAT[x5]
lane1.old_prd = lane0.new_prd
最终 RAT[x5]  = lane1.new_prd
```

---

## 7.4 Rename R1：Allocate

R1 完成：

- 用 R0 已寄存的 PRD 编号查询 ready table，并执行写回 tag bypass；
- 处理 Lane0 → Lane1 的同组 RAW/WAW；
- 最多分配 2 个新 PRD；
- 最多分配 2 个 ROB 项；
- 最多分配 2 个 IQ 项；
- 最多分配 2 个 LQ/SQ 项；
- 最多分配 1 个 Branch Checkpoint；
- 更新 RAT；
- 清除新 PRD ready 位；
- 写 ROB；
- 输出至 Dispatch Buffer。

禁止形成：

```text
RAT Read
→ Lane Bypass
→ Free List Priority Encode
→ ROB Full
→ IQ Full
→ LSQ Full
→ RAT Write
→ Decode Ready
```

的单周期组合路径。

Allocator response 必须是寄存保持的 reservation，不得由请求在同周期穿过 Free List
优先编码器后组合返回。请求在 response 到达前保持稳定；response 在 `alloc_fire` 前不
消耗资源，flush 时由 `alloc_cancel` 释放。

---

# 8. Physical Register File

## 8.1 PRF 数量

推荐：

```text
64 个物理寄存器
```

初始映射：

```text
p0      固定映射 x0
p1-p31  初始映射 x1-x31
p32-p63 初始空闲
```

---

## 8.2 PRF Bank

按 PRD 最低位分成两个 Bank：

```text
Bank0：偶数 PRD
Bank1：奇数 PRD
```

每个 Bank 保存 32 个物理寄存器。

---

## 8.3 PRF 读端口

最大三发射最多需要 6 个源操作数。

推荐每个 Bank 复制 3 份读副本：

```text
Bank0_copy0
Bank0_copy1
Bank0_copy2

Bank1_copy0
Bank1_copy1
Bank1_copy2
```

逻辑上：

```text
每个 Bank：3R1W
整体：最多 6R2W
```

总存储容量：

```text
2 × 3 × 32 × 32 = 6144 bit
```

容量不大，但要严格控制写广播和物理布局。

---

## 8.4 PRF 读端口冲突

每周期发射的指令必须满足：

```text
Bank0 源操作数数量 ≤ 3
Bank1 源操作数数量 ≤ 3
```

如果三条候选指令对同一 Bank 的读请求超过 3 个，则减少发射数。

---

## 8.5 PRF 写端口冲突

全局最多有两个写回结果，但每个 Bank 只有一个物理写口。

若两个结果写入同一 Bank：

- 高优先级结果本周期写回；
- 低优先级结果进入 Completion Buffer；
- 下一周期重试。

推荐优先级：

```text
Load > INT/Branch > MUL > DIV
```

ROB 只有在结果真正写入 PRF 后，才置 `complete`。

---

# 9. Free List

Free List 推荐采用分组 Bitmap。

结构：

```text
4 组 × 16 bit
```

分配流程：

```text
一级：选择非空组
二级：组内 first-one / second-one
```

避免使用：

```text
64-bit 全宽双分配优先编码器
```

分配策略尽量保证双发射新 PRD 位于不同 Bank：

```text
lane0_new_prd[0] != lane1_new_prd[0]
```

从而降低未来写回和读取冲突。

---

## 9.1 PRD 回收

Commit 每周期最多回收两个 `old_prd`。

不要建立：

```text
Commit → Free List → Rename Allocate
```

的同周期组合路径。

采用 2-entry Reclaim Buffer：

```text
Commit 本周期产生回收 PRD
→ 写入 Reclaim Buffer
→ 下一周期写入 Free List
```

---

# 10. ROB

## 10.1 ROB 规模

推荐：

```text
16 rows × 2 banks = 32 entries
```

ROB 按双宽分配组织。

ROB ID：

```text
rob_id = {row_index[3:0], bank_id}
```

执行单元和写回网络全程携带 ROB ID。

---

## 10.2 ROB 字段

### 行共享字段

```text
base_pc
fetch_id
```

### 每条指令字段

```text
valid
complete
arch_rd
new_prd
old_prd
write_rd
exception_valid
exception_cause
exception_tval
is_store
sq_id
is_branch
checkpoint_id
serializing
```

ROB 不保存普通执行结果。

执行结果只写入 PRF。

---

## 10.3 ROB 写回

写回时直接通过 ROB ID 索引：

```systemverilog
rob_complete[wb_rob_id] <= 1'b1;
```

禁止使用：

- 根据 `rd` 搜索；
- 根据 PC 搜索；
- 根据指令内容搜索；
- 遍历整个 ROB 匹配写回。

---

## 10.4 ROB 分配

每周期最多分配 2 条：

```text
lane0 → tail_row.bank0
lane1 → tail_row.bank1
```

初版允许 bank1 为空，但不允许：

```text
bank0 invalid
bank1 valid
```

避免提交端产生复杂空洞处理。

---

## 10.5 Commit

每周期最多提交 2 条，严格保持程序顺序。

```text
commit0 = bank0.valid && bank0.complete

commit1 = commit0
       && bank1.valid
       && bank1.complete
       && !bank0.exception_valid
```

遇到异常、MRET、ECALL、EBREAK 或序列化 CSR 时，只允许在 ROB head 处理。

---

# 11. Dispatch

Rename R1 后增加 Dispatch Buffer。

建议容量：

```text
4～6 条 uop
```

作用：

- 切断 Rename 与 IQ 的组合 ready 路径；
- 缓解不同 IQ 接收能力不同的问题；
- 支持整数、访存、MDU 的分类分发；
- 后端暂时阻塞时避免立即停止前端。

Dispatch Buffer 输出宽度：

```text
每周期最多 2 条
```

---

# 12. Issue Queue

采用分类调度器。

| 队列 | 容量 | 最大入队 | 最大发射 |
|---|---:|---:|---:|
| Integer IQ | 12 | 2 | 2 |
| Memory IQ | 8 | 2 | 1 |
| Mul/Div IQ | 4 | 2 | 1 |

总 Issue 上限为 3。

---

## 12.1 Issue Queue Entry

每项至少保存：

```text
valid
rob_id
prd
prs1
prs2
src1_ready
src2_ready
imm
fu_type
op
branch_mask
lq_id
sq_id
```

不进行整体压缩移动。

每个 entry 固定存在，使用 valid bit 管理。

---

## 12.2 Wakeup

Writeback 广播最多两个 PRD tag：

```text
wb0_prd
wb1_prd
```

每个 IQ entry 检查：

```text
prs1 == wb0_prd
prs1 == wb1_prd
prs2 == wb0_prd
prs2 == wb1_prd
```

Wakeup 只更新 ready bit。

---

## 12.3 Select

必须和 Wakeup 分周期：

```text
周期 N：
Writeback Broadcast
→ IQ Tag Compare
→ 更新 ready

周期 N+1：
IQ Select

周期 N+2：
PRF Read

周期 N+3：
Execute
```

禁止：

```text
WB
→ Wakeup
→ Select
→ PRF Read
→ ALU
```

在一个周期完成。

---

## 12.4 Integer IQ 选择

不建议使用完整年龄矩阵。

建议：

1. 12 项分为 3～4 组；
2. 每组选择 1 个 ready 候选；
3. 从组候选中选择最老的 2 条；
4. 结合执行端口和 PRF Bank 约束做最终发射。

---

# 13. 执行端口

## 13.1 INT0

支持：

- ADD/SUB
- AND/OR/XOR
- SLT/SLTU
- LUI/AUIPC
- SLL/SRL/SRA

---

## 13.2 INT1 / Branch

支持：

- ADD/SUB
- AND/OR/XOR
- 比较
- BEQ/BNE/BLT/BGE/BLTU/BGEU
- JAL
- JALR

为降低面积和时序压力，可以只在 INT0 放完整桶形移位器。

---

## 13.3 LSU

支持：

- Load 地址生成；
- Store 地址生成；
- Store 数据准备；
- 非对齐检测；
- LQ/SQ 查询；
- Store-to-Load Forwarding；
- DRAM 请求。

---

## 13.4 MDU

支持：

```text
MUL
MULH
MULHSU
MULHU
DIV
DIVU
REM
REMU
```

---

# 14. 乘法器和除法器

## 14.1 乘法器

推荐使用 DSP48 实现流水乘法器。

目标：

```text
固定 3～4 周期延迟
每周期可接收 1 条乘法指令
```

不要继续使用大规模 RTL Booth 组合/多周期结构作为主方案。

乘法结果进入 Completion Buffer，再参与 WB 仲裁。

---

## 14.2 除法器

推荐：

```text
Radix-4 迭代除法器
约 16～18 周期
非流水
```

除法器独立运行，不阻塞 Integer IQ。

完成后将结果送入独立 Completion Buffer。

---

# 15. 最大三发射规则

允许的典型组合：

```text
INT0 + INT1 + LSU
INT0 + LSU + MUL
INT1 + LSU + MUL
INT0 + INT1 + MUL
```

不允许同周期发射 4 条。

全局 Issue Arbiter 负责检查：

- 总数不超过 3；
- 执行端口可接收；
- PRF Bank 读端口不超限；
- 不产生不可处理的执行冲突；
- 长延迟单元可接收；
- 必要的序列化约束满足。

---

# 16. Data RAM 组织

256 KB Data RAM：

```text
64K × 32 bit
```

推荐重新组织为 4 个交错 Bank。

```text
Bank0
Bank1
Bank2
Bank3
```

地址划分：

```text
word_addr = byte_addr[17:2]

bank_id  = word_addr[1:0]
bank_row = word_addr[15:2]
```

每个 Bank：

```text
16K × 32 bit = 64 KB
```

优势：

- 连续地址分布到不同 Bank；
- 返回选择只有 4:1；
- 地址译码简单；
- 便于物理分区；
- 可以降低大范围 BRAM 控制扇出。

---

## 16.1 端口规划

每个 Bank 推荐使用真双口或简单双口：

```text
Port A：Load Read
Port B：Committed Store Write
```

支持：

- 每周期最多 1 个 Load 请求；
- 每周期最多提交 1 个 Store；
- Load 与 Store 可以并行访问。

---

## 16.2 Load 流水

```text
L0：AGU 计算地址和非对齐检查
L1：地址寄存、Bank 选择
L2：BRAM 同步读取
L3：返回寄存、字节/半字选择、符号扩展
L4：Writeback
```

Load 固定约 4 周期执行延迟。

---

# 17. LSQ

建议配置：

```text
Load Queue  = 8 项
Store Queue = 8 项
```

---

## 17.1 Store Queue Entry

```text
valid
rob_id
address_valid
address
data_valid
data
byte_enable
exception_valid
```

Store 执行后只写入 SQ，不立即修改 DRAM。

Store 只有在满足以下条件时提交：

```text
位于 ROB head
无异常
地址有效
数据有效
DRAM 写口可接收
```

---

## 17.2 Load Queue Entry

```text
valid
rob_id
address_valid
address
completed
forwarded
exception_valid
```

---

## 17.3 第一版乱序访存规则

Load 可以乱序执行，但必须满足：

1. 所有更老 Store 的地址已经确定；
2. 若有相同地址的更老 Store：
   - 选择程序顺序上最近的匹配 Store；
   - 如果 Store 数据有效，进行 Store-to-Load Forwarding；
   - 如果数据无效，Load 等待；
3. 如果所有更老 Store 均不冲突，访问 DRAM；
4. 如果存在地址未知的更老 Store，Load 暂停。

该方案支持：

- Load 越过已知不冲突 Store；
- 年轻 Load 越过更老未完成 ALU 指令；
- 不同 Load 按 ready 状态乱序发射。

第一版不实现：

- Memory Dependency Predictor；
- Load 越过地址未知 Store；
- 访存违规检测和 Replay。

---

## 17.4 SQ 地址比较流水

避免单周期完成：

```text
8 项地址比较
→ 最近匹配选择
→ 数据选择
→ DRAM 请求
```

建议拆分：

```text
周期 A：生成 Match Vector
周期 B：选择最近 Store 或发起 DRAM
```

---

# 18. Writeback

## 18.1 全局写回端口

```text
WB0
WB1
```

写回内容：

```text
valid
prd
rob_id
data
exception_valid
exception_cause
exception_tval
```

写回时完成：

- PRF 写入；
- PRF ready bit 置位；
- ROB complete 置位；
- PRD tag 广播；
- IQ Wakeup。

---

## 18.2 Completion Buffer

每个可能产生写回冲突的执行单元必须具备结果缓冲。

建议：

| 单元 | 缓冲深度 |
|---|---:|
| INT0 | 1 |
| INT1 | 1 |
| LSU | 2 |
| MUL | 2 |
| DIV | 1 |

目的：

- 解决同周期三条以上结果完成；
- 解决同 Bank 双写冲突；
- 解决固定延迟单元完成碰撞；
- 避免全局停止执行后端。

---

# 19. 分支恢复

每个未决分支分配一个 Checkpoint。

每个 Checkpoint 保存：

```text
RAT Snapshot
Free List 恢复信息
ROB Tail
LQ Tail
SQ Tail
```

每条年轻 uop 携带：

```text
branch_mask[3:0]
```

分支误预测时：

```systemverilog
kill = entry.branch_mask[mispredict_checkpoint_id];
```

各模块本地清除：

- Dispatch Buffer；
- Integer IQ；
- Memory IQ；
- Mul/Div IQ；
- LQ；
- SQ；
- ROB 年轻项。

不建立统一的大范围组合 flush 回路。

---

# 20. 精确异常

核心原则：

> 执行可以乱序，架构状态必须按 ROB 顺序更新。

---

## 20.1 普通寄存器

执行完成时结果写 PRF。

只有 Commit 时：

- AMT 更新；
- old PRD 回收；
- `instret` 增加。

---

## 20.2 Store

Store 只有在 ROB head 提交时才真正写入 DRAM。

---

## 20.3 同步异常

执行单元发现异常后，仅写入 ROB：

```text
exception_valid
exception_cause
exception_tval
```

不立即重定向 PC。

异常指令到达 ROB head 后：

1. 停止 Commit；
2. 清除所有年轻指令；
3. 恢复 RAT；
4. 恢复 Free List；
5. 写入：
   - `mepc`
   - `mcause`
   - `mtval`
   - `mstatus`
6. PC 跳转至 `mtvec`。

---

# 21. Zicsr、ECALL、EBREAK 和 MRET

## 21.1 CSR 指令

CSR 指令作为序列化指令处理。

只有当 CSR 指令位于 ROB head，且所有更老 Store 均已处理时，才允许执行。

CSR 不参与普通乱序旁路和复杂重命名。

CSR 的架构状态只在 Commit 时更新。

---

## 21.2 ECALL

Machine Mode 下：

```text
cause = 11
```

ECALL 在 Decode 阶段识别，但只有到达 ROB head 时才触发异常。

---

## 21.3 EBREAK

```text
cause = 3
```

同样只在 ROB head 触发。

---

## 21.4 MRET

MRET 作为序列化指令处理。

到达 ROB head 后：

```text
PC ← mepc
mstatus.MIE ← mstatus.MPIE
mstatus.MPIE ← 1
清除所有年轻指令
```

---

## 21.5 非对齐异常

测试程序不会产生非对齐访存，因此直接抛出异常：

- Instruction Address Misaligned；
- Load Address Misaligned；
- Store Address Misaligned。

不实现跨字访存拼接。

---

# 22. RAT、AMT 和恢复

维护：

```text
RAT：推测映射
AMT：退休映射
```

正常 Commit：

```text
AMT[arch_rd] ← new_prd
old_prd 进入回收队列
```

分支误预测：

```text
RAT ← Branch Checkpoint
恢复 ROB/LQ/SQ Tail
```

精确异常：

```text
RAT ← AMT
```

---

## 22.1 Free List 异常恢复

异常低频，因此允许多周期恢复。

流程：

```text
Cycle 0：停止前端、Rename、Dispatch、Commit
Cycle 1：RAT ← AMT
Cycle 2～N：扫描 PRF，重建 Free List
Cycle N+1：PC ← mtvec
```

不为异常恢复构造单周期大规模组合逻辑。

---

# 23. 必须切断的组合路径

以下路径禁止存在：

```text
Commit → Free List → Rename Allocate
```

```text
Writeback → IQ Wakeup → Select → PRF Read → Execute
```

```text
LSQ Compare → DRAM Read → Load Writeback
```

```text
Branch Execute → RAT Restore → Rename Ready
```

```text
ROB Full → Decode Ready → IF PC
```

```text
Execution Unit Stall → Frontend Stall
```

所有主要模块之间必须通过寄存器或 Buffer 解耦。

---

# 24. 关键流水寄存器边界

以下位置必须寄存：

```text
IROM 输出
BTB/BHT 输出
Decode 输出
RAT 查询结果
Free List 分配结果
ROB 分配结果
Dispatch 输出
Issue Select 结果
PRF 读取结果
AGU 地址
SQ Match Vector
DRAM 输出
Load 扩展结果
Writeback 仲裁结果
Commit 回收结果
```

---

# 25. 反压规则

每个阶段只和相邻阶段握手。

推荐局部缓冲：

```text
Instruction Buffer
Decode/Rename Register
Dispatch Buffer
Issue Queue
Completion Buffer
Store Commit Buffer
```

后端阻塞必须逐级传播。

禁止：

```text
WB 无法写回
→ 同周期直接阻止 PC 更新
```

---

# 26. V1 推荐参数

```text
ISA
  RV32I + M + Zicsr
  Machine Mode
  ECALL / EBREAK / MRET
  精确异常
  非对齐访问抛异常

Frontend
  128-bit IROM
  4-fetch
  8-entry Instruction Buffer
  2-decode
  BTB 128
  BHT 512
  V1 no RAS，JALR target predicted by BTB

Rename
  2-wide
  2-stage
  64 physical registers
  RAT + AMT
  4 branch checkpoints
  4×16-bit grouped bitmap Free List

ROB
  32 entries
  16 rows × 2 banks
  2 allocate
  2 commit

Scheduler
  Integer IQ 12，最多发射 2 条
  Memory IQ 8，最多发射 1 条
  Mul/Div IQ 4，最多发射 1 条
  全局最大 3 issue

PRF
  2 banks
  每 Bank 3 份读副本
  每 Bank 1 个写口
  2 个全局 WB
  同 Bank 写冲突进入 Completion Buffer

Execution
  2 × Integer Pipeline
  Branch 挂在 INT1
  1 × LSU
  1 × DSP48 流水乘法器
  1 × Radix-4 迭代除法器

Memory
  256 KB
  4-way low-address interleaved BRAM banks
  每周期最多 1 Load Request
  每周期最多 1 Committed Store
  LQ 8
  SQ 8
  Load 可越过地址已知且不冲突的 Store

Recovery
  分支：Checkpoint 恢复
  异常：AMT 恢复，多周期重建 Free List

Frequency
  最低目标：150 MHz
  主设计目标：200 MHz
  冲击目标：225 MHz
```

---

# 27. 推荐开发顺序

## P0：建立周期级性能模型

统计：

- Decode 利用率；
- 双宽 Rename 利用率；
- 三发射利用率；
- ROB Full 周期；
- IQ Full 周期；
- PRF Bank 冲突；
- WB 冲突；
- Load 等待 Store 周期；
- 分支误预测损失；
- Mul/Div 阻塞；
- LQ/SQ 占用率。

比较参数：

```text
ROB：16 / 24 / 32
Integer IQ：8 / 12 / 16
LQ/SQ：4 / 8
Issue Width：2 / 3
PRF：48 / 64
```

---

## P1：前端与双宽 Decode

实现：

```text
128-bit IROM
4-fetch
Instruction Buffer
2-decode
基础分支预测
```

先验证前端连续供给能力。

---

## P2：双宽 Rename + ROB，顺序执行

实现：

```text
RAT
AMT
Free List
2-wide Rename
32-entry ROB
2-wide Commit
```

此阶段执行仍可按序。

目的：

- 单独验证 Rename；
- 单独验证 ROB；
- 提前综合检查 Fmax；
- 确保不再出现 50 MHz 级关键路径。

---

## P3：Integer OoO

加入：

```text
Integer IQ
PRF
INT0
INT1/Branch
2-way WB
Wakeup/Select
```

先只支持：

- RV32I 整数运算；
- Branch/JAL/JALR；
- 不接 LSU；
- 不接 M 扩展；
- 不接 CSR。

---

## P4：LSU 与顺序访存约束

加入：

```text
Memory IQ
LQ
SQ
4-bank Data RAM
Store Commit
```

初期所有 Load 等待更老 Store 地址确定。

---

## P5：乱序 Load

加入：

```text
Store Address Compare
Store-to-Load Forwarding
Load 越过已知不冲突 Store
```

---

## P6：M 扩展

加入：

```text
DSP48 流水乘法器
Radix-4 除法器
Mul/Div IQ
Completion Buffer
```

---

## P7：Zicsr 和精确异常

加入：

```text
CSR 序列化执行
ECALL
EBREAK
MRET
精确异常
AMT 恢复
多周期 Free List 重建
```

---

## P8：性能调优

根据实际评测程序和综合结果调整：

- ROB 深度；
- IQ 容量；
- BTB/BHT；
- 分支恢复；
- PRF Bank 分配策略；
- WB 仲裁；
- LSU 发射；
- Load 延迟；
- 乘法流水级数。

---

# 28. 独立模块综合目标

完整核目标为 200 MHz 时，各核心模块应保留足够余量。

| 模块 | 独立综合目标 |
|---|---:|
| RAT + Lane 依赖 | ≥ 250 MHz |
| Free List 双分配 | ≥ 250 MHz |
| ROB 双分配/提交 | ≥ 250 MHz |
| Integer IQ Select | ≥ 225 MHz |
| PRF Read | ≥ 250 MHz |
| SQ 地址比较 | ≥ 225 MHz |
| DRAM Bank Read | ≥ 250 MHz |
| WB 仲裁 | ≥ 250 MHz |
| Branch Redirect | ≥ 250 MHz |

单模块只达到 200 MHz，完整布局布线后通常难以稳定达到 200 MHz。

---

# 29. RTL 设计禁区

禁止在关键路径中使用以下模式：

```systemverilog
for (int i = 0; i < ROB_DEPTH; i++) begin
    if (rob[i].valid && rob[i].rd == wb_rd)
        ...
end
```

禁止：

- ROB 关联搜索；
- Free List 全宽平铺优先编码；
- IQ 整体压缩；
- LSQ 整体移动；
- Flush 时全局组合重算状态；
- Commit 和 Rename 同周期组合闭环；
- WB 和 Issue 同周期 Wakeup-Select 闭环；
- 反压跨越多个流水级直接传播；
- 通过大宽度 packed bus 让无关字段跨越整个后端。

推荐：

- 直接索引；
- 固定槽位；
- 本地 valid；
- 本地 kill；
- 分级选择；
- Pipeline Register；
- Completion Buffer；
- Banked Storage。

---

# 30. 当前架构结论

当前推荐方案为：

> **128-bit 四取指、双译码、双重命名、32 项 ROB、64 项物理寄存器、三路动态发射、双写回、双提交、支持乱序 Load 和按序 Store 提交的 RV32IM_Zicsr 乱序核。**

该方案的重点不是理论最大宽度，而是：

1. 保证至少双发射；
2. 后端具备真实三发射能力；
3. 通过分阶段 Rename 和直接索引 ROB 消除当前关键路径；
4. 通过 Banked PRF 和发射约束控制多端口代价；
5. 通过 4-Bank Data RAM 降低 BRAM 路由压力；
6. 通过 Store Commit 和 ROB 保证精确异常；
7. 以 200 MHz 作为主设计目标；
8. 保留后续升级为三译码、三重命名的可能。
