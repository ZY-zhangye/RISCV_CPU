# ROB 年龄比较与 LSQ 时序优化方案

日期：2026-07-03  
基线提交：`24b0da3 Pipeline LSQ memory select timing`  
目标：参考成熟开源乱序核的实现方式，消除当前 LSQ 中由全局 ROB 头指针、全表年龄比较和嵌套 Store 扫描形成的长组合路径，逐步逼近 200 MHz。

## 1. 当前问题

当前 200 MHz（5 ns）实现结果的主要指标为：

- WNS：`-7.680 ns`
- 最差数据路径：约 `12.168 ns`
- 最差路径起点：`u_backend/rob_head_tag_iq0_reg[0]`
- 最差路径终点：`u_lsq/memory_request_reg_reg[write_data][24]/CE`
- 该路径约 85% 为布线延迟，说明它既有较深逻辑，也跨越了较大的物理范围。

当前 `rtl/core/lsq.sv` 在 AGU、完成选择和内存选择中反复计算：

```systemverilog
entries[idx].payload.rob_tag - rob_head_tag
```

内存选择还在每个候选 Load 内再次扫描全部 Store，完成以下工作：

1. 用 ROB 年龄判断 Store 是否早于 Load。
2. 判断地址重叠、地址/数据是否有效。
3. 在全部命中 Store 中选择最年轻者。
4. 同时在同一个组合块中选择已提交 Store、生成请求数据并驱动请求寄存器 CE。

这构成了“全局 ROB head 高扇出 + Load 全表选择 + Store 全表扫描 + 优先级选择 + 宽数据 MUX + 寄存器 CE”的组合网络。仅在输出端增加一级寄存器，不能切断到该寄存器 CE 的选择路径。

## 2. 开源核实现调研

### 2.1 BOOM

BOOM 的 ROB 是带回绕语义的循环队列，head 指向最老指令，tail 指向最新指令；提交从 ROB head 开始。ROB 负责通知 LSU 有多少 Store 可以进入已提交状态，LSU 再按程序顺序排出这些 Store，而不是让所有 LSU 项持续对 ROB head 做减法比较。

BOOM 的 LSU 文档描述了 Store 依赖掩码方案：Load 在分派时记录它依赖的较老 Store 集合；Store 离开 STQ 时清除对应位。Load 查询时只与依赖集合中的 Store 比较地址。当前 BOOM v4 源码的具体组织已经演进为独立 LDQ/STQ、`next_stq_idx` 边界指针和多个 STQ head/tail 指针，但核心原则相同：LSU 内部用本地 Store 队列顺序表达依赖，而不是依赖全局 ROB head 的大范围组合年龄运算。

另外，BOOM 源码将年龄优先编码结果用 `SafeRegNext` 寄存，再读取对应队列项；Store 重试、Load 重试和 Store 提交也分成独立候选类后仲裁。这说明队列选择结果本身就是一个应当被切开的流水边界。

参考：

- [BOOM Reorder Buffer](https://docs.boom-core.org/en/latest/sections/reorder-buffer.html)
- [BOOM Load/Store Unit](https://docs.boom-core.org/en/latest/sections/load-store-unit.html)
- [BOOM Issue Unit](https://docs.boom-core.org/en/latest/sections/issue-units.html)
- [BOOM v4 LSU source](https://github.com/riscv-boom/riscv-boom/blob/master/src/main/scala/v4/lsu/lsu.scala)

### 2.2 XiangShan

XiangShan 将 ROB 实现为带类型的循环指针和 8 bank 存储。ROB 的 bank 读地址本身经过寄存，提交读取按当前行/下一行组织，避免把大容量 ROB 做成一次性宽组合读取。

与本设计最差路径最接近的是 XiangShan 的 Store Queue 转发模块。其源码明确规定查询请求两拍后返回，并划分为三级：

1. Stage 0：根据 SQ dequeue 指针和 Load 的 `sqIdx` 生成环形年龄掩码，同时准备地址范围。
2. Stage 1：只在年龄掩码内比较地址和字节范围，选择最年轻的匹配 Store。
3. Stage 2：根据已寄存的候选项生成最终转发数据和掩码。

Stage 1 到 Stage 2 之间对候选 Store、选择 one-hot、无效地址信息和 Load 属性使用了大量 `RegEnable`。此外，Store Queue 到 Store Buffer 还有专门的顺序排出流水，源码注释明确说明其用途之一是消除 SQ 与 SBuffer 之间的时序路径。

参考：

- [XiangShan ROB source](https://github.com/OpenXiangShan/XiangShan/blob/kunminghu-v3/src/main/scala/xiangshan/backend/rob/Rob.scala)
- [XiangShan NewStoreQueue source](https://github.com/OpenXiangShan/XiangShan/blob/kunminghu-v3/src/main/scala/xiangshan/mem/lsqueue/NewStoreQueue.scala)

### 2.3 可借鉴结论

| 问题 | 当前实现 | BOOM / XiangShan | 本设计建议 |
| --- | --- | --- | --- |
| Store 是否比 Load 老 | 每拍用 `rob_tag - rob_head_tag` 判断 | STQ 边界指针、依赖掩码、环形年龄掩码 | 使用本地 Store 依赖掩码 |
| Store drain | 与 Load 选择、转发共用组合扫描 | 独立 STQ head/commit head，按序排出 | 用 `store_seq == store_drain_head` 建立独立流水 |
| Load forwarding | 选择 Load 后嵌套扫描所有 Store，并在同拍生成数据 | 多级流水，先年龄掩码，再匹配，再生成数据 | 三级查询流水 |
| 最老候选选择 | 全表 ROB 距离减法 | 本地队列顺序、年龄优先编码器，结果寄存 | 8 项年龄矩阵或本地队列指针 |
| 完成总线生成 | 组合选择直接驱动宽总线寄存器 CE | 选择和读取分级 | 先寄存 idx/tag，再索引读取 |

不建议逐行移植 BOOM 或 XiangShan：两者是 Chisel 设计，队列宽度、端口数量、恢复协议和存储系统均与本项目不同。应复用其结构原则，并保持当前 SystemVerilog 风格和接口协议。

## 3. 推荐的新方案

### 阶段 A：去除 LSQ 对全局 ROB head 的关键依赖

优先级：最高。

在每个 Load 项中增加 `older_store_mask[LSQ_DEPTH-1:0]`：

- Load 分配时，掩码记录当时所有有效 Store 槽位。
- 双发同拍中，若 lane 0 是 Store、lane 1 是 Load，应把 lane 0 对应位加入 lane 1 的掩码。
- Store 排出并释放槽位时，广播其 one-hot 槽位号，清除所有 Load 的对应位。
- 槽位复用后的新 Store 不得重新加入旧 Load 的掩码，因此必须保证旧位在槽位可复用前已经清除。
- 恢复时清除被取消 Load 的掩码；保留的已提交 Store 继续按现有恢复规则处理。

Load 只扫描 `older_store_mask` 中的 Store。这样可以从转发网络中删除以下组合运算：

```systemverilog
(store.rob_tag - rob_head_tag) < (load.rob_tag - rob_head_tag)
```

需要增加断言：

- 有效 Load 的依赖位只能指向有效且比它早分配的 Store。
- Store 槽位释放后，下一拍所有 Load 的对应依赖位必须为 0。
- 槽位复用的新 Store不能阻塞已经存在的旧 Load。

### 阶段 B：拆分 Store drain 与 Load 调度

优先级：最高，可与阶段 A 一起实施。

当前 Store 已有 `store_seq` 和 `store_drain_head`，因此不需要再参与 ROB 年龄最小值选择。建立独立的 Store drain 候选流水：

1. S0 对有效、已提交且 `store_seq == store_drain_head` 的项做 one-hot 匹配。
2. 寄存 Store 的 `idx/tag`。
3. S1 索引读取地址、数据、mask，生成 `memory_request_reg`。

Load 请求和 Store drain 在请求寄存器之前做小型仲裁。Store drain 可设为高优先级，也可采用防饥饿轮转，但不能再与 Load forwarding 的嵌套扫描共用一条组合路径。

恢复时若 drain 流水中存在尚未握手的 Store，清空流水并从仍然有效的已提交 Store 重新选择；只有请求真正进入可保持的请求寄存器后，才按照现有协议保留它。

### 阶段 C：把 Load forwarding 改为三级流水

优先级：最高，是消除 12 ns 路径的核心结构修改。

建议流水如下：

#### F0：Load 候选选择

- 从 `valid && address_valid && !memory_requested` 的 Load 中选一个候选。
- 寄存 `load_idx`、`lsq_tag`、地址、操作类型和 `older_store_mask`。
- 本级不读取 Store data，也不生成 memory request。

#### F1：Store 依赖与地址匹配

- 仅扫描 F0 寄存掩码内的 Store。
- 生成地址未知、数据未知、字节覆盖和可转发候选向量。
- 用旋转优先编码器选出最年轻的可转发 Store。
- 寄存匹配结果、Store idx/tag 和 Load 信息。

#### F2：数据生成或访存请求

- 若存在更老但地址未知的 Store，标记本次重试，不置 `memory_requested`。
- 若最年轻匹配 Store 数据未就绪，标记等待，不置 `memory_requested`。
- 若可完整转发，索引读取 Store data，生成 Load data。
- 若无依赖冲突，生成 `memory_request_reg`。
- `memory_request_reg_valid` 的 CE 只由 F2 的寄存 valid 驱动。

如果最老 ready Load 被未知 Store 长期阻塞，不能永久阻塞其他 Load。第一版可增加一个 `forward_retry_mask` 或 round-robin 起点：被阻塞的 Load 下一拍暂时降级，使其他 ready Load 有机会进入 F0。保持正确性优先，吞吐优化随后根据性能测试调整。

### 阶段 D：用本地年龄矩阵替代 AGU/Completion 的 ROB 减法

优先级：中。

统一 LSQ 允许空洞和任意槽位复用，单纯按槽位号优先不能表示年龄。对当前 8 项深度，建议增加 8x8 的本地年龄矩阵：

- `older[i][j] == 1` 表示项 i 比项 j 老。
- 新项写入槽位 j 时，所有当前有效项 i 设置 `older[i][j]`，并清除 `older[j][i]`。
- 项释放时清除对应行和列。
- 候选 i 是最老项，当且仅当不存在候选 j 满足 `older[j][i]`。

该方案只增加约 64 bit 顺序状态，避免每个候选都做 ROB tag 减法，也消除 ROB head 的全局扇出。它适合当前较小 LSQ；若未来 LSQ 深度显著增加，再考虑彻底拆分 LQ/SQ 或使用循环队列指针。

Completion 建议进一步拆为：

1. C0：生成候选 bitmap，利用年龄矩阵选 idx，寄存 idx/tag。
2. C1：索引读取对应 entry，组装 `completion_pending_bus`。

这可消除当前 `completion_select` 到 `completion_pending_bus.pdst/data/exception` CE 的宽组合路径。

### 阶段 E：物理实现与高扇出收尾

优先级：在结构路径消除后进行。

- 保留 `rob_head_tag` 仅用于真正需要精确 ROB 边界的少数逻辑，不再参与 LSQ 全表调度。
- 检查综合器是否合并 `rob_head_tag_iq0/iq1/lsq` 复制寄存器；必要时使用层次边界或局部寄存器复制，但不应先用属性掩盖结构问题。
- 对 commit/head、occupancy、main_valid 等高扇出控制信号按模块局部寄存。
- 每完成一个阶段就重新综合、布局并报告时序，避免多个结构变化叠加后无法判断收益。

## 4. 实施顺序与验收标准

### 里程碑 1：依赖掩码 + Store drain 独立流水

范围：阶段 A、B。

验收：

- RTL unit/all 回归通过。
- 时序报告中不再出现 `rob_head_tag_* -> memory_request_reg/*CE`。
- Store drain 路径不再经过 Load forwarding 选择器。

### 里程碑 2：三级 Load forwarding

范围：阶段 C。

验收：

- Load 转发响应延迟按新协议增加两拍，但功能测试全部通过。
- `memory_request_reg` 的输入和 CE 仅来自流水寄存器。
- 最差路径不再横跨 Load 选择、Store 全表扫描和宽数据 MUX。
- 单级目标延迟小于 5 ns；若尚未达到，依据新最差路径继续细分 F1。

### 里程碑 3：本地年龄矩阵 + Completion 流水

范围：阶段 D。

验收：

- `lsq.sv` 的 AGU、Completion、Memory 调度中不再使用 `rob_tag - rob_head_tag`。
- ROB head 在 LSQ 内不再是高扇出时序起点。
- Completion 路径不再直接驱动宽总线寄存器 CE。

### 里程碑 4：200 MHz 收敛

范围：阶段 E及新报告暴露的路径。

验收：

- 5 ns 约束下 setup WNS >= 0。
- hold WNS >= 0。
- RTL 全回归通过；必要时增加门级或综合网表抽查。
- 对新增流水导致的 Load/Store 吞吐变化进行基本性能对比。

## 5. 必须补充的验证场景

在现有 `tb_lsq` 基础上至少增加：

1. 同拍 lane 0 Store、lane 1 Load 的依赖掩码。
2. Store 释放后槽位立即复用，新 Store 不得阻塞旧 Load。
3. 多个较老 Store 同地址时选择最年轻者转发。
4. 较老 Store 地址未知、数据未知、部分字节覆盖的等待行为。
5. Load 被阻塞时，其他无冲突 Load 能继续取得进展。
6. Store drain 与 Load forwarding 同时产生候选时的仲裁。
7. 恢复发生在 F0/F1/F2 以及 Store drain 流水各阶段。
8. 已进入请求寄存器但尚未握手的已提交 Store 在恢复后不丢失、不重复。

## 6. 最终判断

当前最差路径不是简单的编码风格问题，而是调度信息组织方式造成的结构路径。继续复制 ROB head 寄存器或只在输出端加寄存器，收益会受到高扇出和嵌套扫描限制。

最值得参考的不是某一段开源代码，而是 BOOM 和 XiangShan 共同采用的三个原则：

1. 用 LSU 本地队列顺序表达 Store/Load 年龄关系。
2. Store 按提交队头独立排出，不参与通用最老访存搜索。
3. 年龄掩码、地址匹配、最年轻 Store 选择和数据生成分拍完成。

建议下一次 RTL 修改从阶段 A+B 开始，完成回归和一次 200 MHz 实现后，再进入阶段 C。这样每一步都能从时序报告中验证结构收益，同时把恢复协议和槽位复用风险控制在可审查范围内。
