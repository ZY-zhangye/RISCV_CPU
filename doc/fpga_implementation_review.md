# XC7K325T FPGA 实现与时序约束核对

## 1. 目标与证据边界

- 目标器件：`xc7k325tffg900-2`。
- 主时钟目标：布局布线后不低于 200 MHz，即周期不大于 5.000 ns。
- 时序通过条件：`route_design` 后 setup WNS ≥ 0、hold WHS ≥ 0，且无未约束路径。
- 本文的优先级来自 RTL 结构审阅。没有 Vivado timing report 支撑的路径延迟或最高频率，
  不作为结论。
- XC7K325T 的逻辑、BRAM 和 DSP 容量足以容纳当前已实现模块；现阶段主要风险是组合
  深度、扇出和跨层次布线，而不是总容量。

建议实现流程至少保存：

```tcl
synth_design -top core_top -part xc7k325tffg900-2
create_clock -period 5.000 [get_ports clk_i]
opt_design
place_design
phys_opt_design
route_design
report_timing_summary
report_utilization -hierarchical
report_ram_utilization
report_high_fanout_nets
```

模块 OOC 可先使用 4.0～4.5 ns 约束，为顶层跨模块布线保留余量。

## 2. 已确认并已修改的 P0 项

### 2.1 Instruction Buffer 到 Decode

原结构由 `entries_q[head]` 的异步选择结果直接驱动 Decode，路径包含宽 entry Mux、跨模块
布线和完整指令译码。

当前约束与实现：

- Instruction Buffer 设置双路 FO 寄存输出；
- Decode 只看到 FO 寄存器，不直接看到 entry 阵列；
- FO stall 时 valid/payload 保持；
- FO 中的指令计入 8 项总容量，不暗中扩大队列；
- 不建立 Fetch 到 Decode 的空队列直通路径。

### 2.2 RAT map 到 PRD ready

原结构形成 `32:1 RAT 映射选择 → 64:1 PRD ready 选择 → WB tag bypass → R1 寄存器`
的级联，是 Rename 当前最明确的高风险路径。

当前约束与实现：

- RAT 映射结果先进入寄存器；
- ready table 仅由已寄存 PRD 编号查询；
- WB tag bypass 位于 ready 查询侧；
- allocator request 仅在映射寄存有效后发出。

### 2.3 Allocator response 契约

Free List、ROB、LSQ 和 Checkpoint 的资源选择不得从 Rename 请求同周期组合返回。

- allocator 必须输出寄存的 reservation/response；
- 请求在响应前保持稳定；
- reservation 在 `alloc_fire` 前不消耗资源；
- recovery/flush 使用 `alloc_cancel` 释放 reservation；
- Commit reclaim 先进入本地缓冲，不建立 Commit→Free List→Rename 的组合闭环。

当前 Rename RTL 已按该契约消费响应；Free List 等 allocator 模块尚未实现，后续实现必须
遵守该边界。

## 3. 待处理的 P1 项

### 3.1 Branch Predictor RAM 映射

当前 BTB 查询、tag/type 判断和依赖 BTB slot 的 BHT 查询写在同一查询时序块中；BTB 还
同时参与更新替换判断。该写法能通过功能仿真，但不能仅凭 RTL 断言 Vivado 一定推断为
预期的 RAM 原语。

后续候选重构：

1. BTB 查询输出先寄存，再做 tag/type 判断；更新口独立流水。
2. 将 BHT 组织为“每个 16-byte block 一行、每行四个 2-bit counter”，使 BTB 与整行
   BHT 能由同一个 block index 并行读取，避免 BHT 地址依赖 BTB slot。
3. 小型 BHT 可明确使用 distributed RAM；BTB 是否使用 BRAM 由 OOC 结果决定。
4. 修改前先冻结 Predictor→Fetch 的返回延迟，补齐 query/update 冲突测试。

必须用 `report_ram_utilization` 和最差路径报告确认映射，不能只看属性或综合无报错。

### 3.2 RAT checkpoint 与恢复扇出

四份 32×6-bit RAT snapshot 的容量不大，但 snapshot save、动态 checkpoint 选择和 branch
mask clear 可能产生高扇出及分散布线。若报告命中这些网络，优先采用分组寄存、控制复制
或局部 floorplan；精确异常继续保持每周期恢复两项，不改成单拍全表复制。

### 3.3 前端 ready/credit

Instruction Buffer 的容量计算、Fetch F2 ready 和请求 credit 位于相邻模块。当前规模较小，
但完整连接后需检查 ready 是否跨越多个流水级传播。若进入关键路径，在边界增加 skid
buffer，不把全局反压组合传回 F0。

## 4. 后续 RTL 禁区

- IQ/LSQ 使用固定槽位和本地 valid，不做出队后整体压缩。
- 禁止同周期 wakeup-select；写回唤醒最早下一周期参与 select。
- LSQ 的地址 match vector 与最近匹配选择/数据 Mux 必须分拍。
- PRF 读地址由已寄存的 issue 结果驱动，不叠加 issue select 路径。
- 禁止 ROB 全表关联搜索、Free List 全宽平铺优先编码和单拍全局恢复重算。
- branch kill/mask clear 若成为高扇出网络，采用分组或本地寄存处理。

## 5. 本轮状态

- 已落地：IBuf 寄存输出、Rename map/ready 分拍、allocator 寄存响应契约、ROB recovery
  raw 请求隔离、Issue/Operand Read snapshot timing cut、JYD2025 SoC 地址图和外设包装。
- 功能验证：官方支持回归 `51/51 PASS`；JYD2025 COE smoke 通过，`LED=0x0002_0001`，
  SEG 原始 32 位值 `0x3780_0000`。
- 已证明：完整 Vivado route 后 setup WNS `+0.027 ns`、hold WHS `+0.061 ns`，满足
  5.000 ns 主时钟目标。余量仍紧，后续修改 RTL 后必须重新跑完整 route。

后续时序修复注意：

- raw recovery/checkpoint 广播不得直接扇入 ROB/IQ/LSQ 宽 payload 阵列的更新选择；
  先使用本地 pending/snapshot 寄存器。
- 不要恢复无效 payload 的大规模清零；valid/complete 是架构可见性的边界。
- ROB 年龄比较必须以 ROB head 为参考，特别是 Memory IQ 与 Load 等待更老 Store 的逻辑。
- 如果 route 再次失败，先按最新报告定位具体 fanout/endpoint，再决定是否增加 snapshot；
  不先改实现 directive 或重写已验证的功能边界。

## 6. 2026-07-04 真实 5 ns OOC 报告回填

报告目录：`F:\RISCV_CPU_Vivado_20260703\reports_200mhz`。以下结果来自 Vivado 2023.2、
器件 `xc7k325tffg900-2`、5.000 ns 时钟约束下的 synthesized/unplaced OOC 报告：

| 模块 | WNS |
|---|---:|
| branch_predictor | +0.475 ns |
| fetch_pipeline | +1.655 ns |
| instruction_buffer | +1.485 ns |
| decode_stage | +2.728 ns |
| free_list | **-1.413 ns** |
| rat_amt | +2.529 ns |
| rename_stage | +2.468 ns |

当前仅 Free List 违反 200 MHz：TNS=-10.926 ns、16 个失败端点，最差路径从
`selection_prd0_q_reg[1]` 到 `reservation_prd1_q_reg[1]`，数据路径 6.387 ns、17 级逻辑，
其中有 6 个 CARRY4。关键路径验证了第二 PRD 选择仍然过深，并暴露出旋转组索引使用
整数加法导致宽 carry chain 的综合问题。

整改顺序为：显式 case 旋转优先级 → S0 寄存 one-hot exclude mask → 并行偶/奇候选 →
必要时再增加 S1 寄存边界。Free List 重新综合需达到 5 ns WNS≥+1.0 ns，且 4 ns WNS≥0。

Branch Predictor 虽通过，但 WNS 只有 +0.475 ns，继续列为 P1 观察项；其最差路径在更新
FIFO PC 到 BTB 写使能，而不是预测查询路径。完整核是否达到 200 MHz 仍必须等待布局布线
后的 timing summary，不能由本次 OOC 综合直接宣布达标。

## 7. Free List 之外的风险清单

### 7.1 P0：Branch Predictor 面积与更新路径

Predictor 是当前最大且裕量最小的已通过模块。BTB/BHT 基本没有形成目标 RAM 结构，导致
8115 FF、4162 LUT 和 2265 个 F7/F8 Mux。更新路径把 Update FIFO PC 动态索引、旧 BTB
entry 读取、tag/slot 替换判断和 entry write-enable 串在一起。

优化方向：更新端拆成 read/compare-write 多拍；BHT 改为 block-indexed 128×8-bit 行；
查询、更新端口按同步 RAM 模板重写；增加 update queue 满握手。修改后要求 4 ns OOC
通过，并以 RAM utilization 和 MUX 数量验证结构真正改变。

### 7.2 P1：Instruction Buffer 多写布线

IBuf 的最差路径由 tail 指针进入宽 entry 阵列控制，布线占 83.5%。当前 8 项容量下仍能
通过，但全核中与 Fetch、Decode 相邻，宽 payload 很容易扩大布线压力。

优化方向：仅在成组 OOC/route 失败时增加 enqueue command 寄存器，预生成 compaction、
one-hot write enable 和局部 payload；pending command 必须计入容量。FO 输出寄存边界保留。

### 7.3 P1：Fetch prediction 控制布线

Fetch 的最差路径从 response FIFO 内 prediction slot 到 F2 packet 控制，布线占 83.2%。
优化方向是在 F1 增加 prediction predecode，仅向 F2 传递 taken/target/final slot mask；不得
把 Predictor、IROM、IBuf ready 重新串成组合控制链。

### 7.4 P2：Rename/RAT 集成与恢复扇出

Rename/RAT 单模块内部裕量充足，说明 map/ready 分拍有效。风险来自尚未综合的模块边界和
全局恢复网络：Free List response、Dispatch ready、checkpoint snapshot、branch mask clear。
保持寄存 allocator response，并对 Rename+Free List+Dispatch 做成组 OOC；恢复控制若进入
route 关键路径，再采用分组/复制，不提前破坏正常路径。

### 7.5 当前无需调整：Decode

Decode WNS=+2.728 ns，最差路径仅 2 级 LUT，现有输入/输出寄存器有效。除非 ISA 扩展或
成组 OOC 出现新路径，否则不为追求局部数字继续增加流水级。

## 8. 报告使用限制

上述报告均为 synthesized/unplaced OOC，hold 路径未形成最终物理验证；报告中的 route
delay 是估算值。下一步除单模块 4 ns 压力测试外，还必须增加以下成组 OOC：

- `branch_predictor + fetch_pipeline`
- `instruction_buffer + decode_stage`
- `rename_stage + free_list + dispatch_buffer`

当前 200 MHz 最终结论以完整 `place_design/route_design` 后的 WNS/WHS 为准：setup
WNS `+0.027 ns`，hold WHS `+0.061 ns`。后续任何影响 ROB recovery、Issue/LSU、SoC
memory/MMIO 或 clock/reset 结构的 RTL 修改，都必须重新核对 timing summary、
high-fanout、design analysis 和 RAM utilization 报告。
