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

- 已落地：IBuf 寄存输出、Rename map/ready 分拍、设计文档与 allocator 寄存响应契约。
- 功能验证：对应 directed tests 必须通过；完整回归结果记录在提交说明中。
- 尚未证明：200 MHz。最终结论等待用户侧 Vivado 综合、布局布线和报告回传。
