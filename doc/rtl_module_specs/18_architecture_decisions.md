# V1 架构决策记录

以下选择已于 2026-07-03 接受，作为 V1 RTL 实现基线。若后续综合、验证或性能数据
要求改变选择，应先更新本表和受影响模块规格，再修改 RTL。

| 编号 | 决策 | V1 已冻结选择 | 影响模块 |
|---|---|---|---|
| D01 | IROM/Data RAM 位于 core 内还是 SoC wrapper | 放 wrapper，core 使用 typed 请求接口 | core_top、fetch、data_memory |
| D02 | Branch checkpoint 保存完整 RAT 还是增量日志 | 4 份 RAT snapshot，先换取实现确定性 | rename、checkpoint |
| D03 | Free List 分支恢复方式 | allocation log tail，多周期回滚 | free_list、recovery |
| D04 | 是否实现 RAS | V1 不实现；JALR 使用 BTB，后续独立评估推测 RAS | predictor、checkpoint |
| D05 | PRF 使用 FF/LUTRAM/BRAM | 以独立综合结果决定，接口保持同步 RR | PRF |
| D06 | 单路分配后是否浪费 ROB bank1 | V1 浪费 bank1，优先简化提交 | ROB、Rename |
| D07 | Data RAM 固定读取延迟 | V1 明确为 2 个 memory 周期 | LSU、Data RAM |
| D08 | 部分 Store-to-Load Forwarding | V1 不合并，等待 Store 提交 | LSQ |
| D09 | CSR 返回值写回时点 | 仅 head 执行，经 completion 写 PRF 后提交 | CSR、WB、Commit |
| D10 | 正确分支 mask 清除用一拍广播还是分组清除 | 先分组/本地寄存，目标 200 MHz | IQ、ROB、LSQ、MDU |
| D11 | Instruction Buffer 是否组合直出 | 采用双路 FO 寄存输出，总容量仍为 8 | instruction_buffer、decode |
| D12 | RAT map 与 PRD ready 是否同拍级联 | 强制分拍；ready 只由已寄存 PRD 编号查询 | rename、rat_amt |
| D13 | Allocator 是否允许组合响应 | 禁止；使用保持到 fire/cancel 的寄存 reservation | free_list、rename、ROB、LSQ |
| D14 | 200 MHz 如何验收 | xc7k325tffg900-2、5.000 ns、route 后 WNS/WHS≥0、无未约束路径 | 全核 |
| D15 | Free List 分配返回结构 | S0/S1 分拍选择后进入单 reservation；不串联两个优先选择器 | free_list、rename |
| D16 | SoC 级总线和外设接入方式 | V1 使用固定地址窗口和简单 ready-valid 地址路由；预留单在途 MMIO 外设总线，暂不引入 AXI/Wishbone | soc_top、soc_addr_router、data_memory、peripherals |

## 变更规则

决策记录至少包含：选择、备选方案、理由、预期时序影响、验证方法和日期。涉及接口的
决策必须先更新 core_types_pkg 草案和对应端口表，再开始 RTL，避免模块各自解释架构。

## RAS 后续准入条件

只有当基础 OoO、Branch Recovery 和完整核 200 MHz 时序已稳定，且性能计数显示
JALR/return mispredict 是显著瓶颈时，才重新评估 8-entry 推测 RAS。届时必须同时
设计 call/return 识别、栈指针推测更新、checkpoint 保存与误预测恢复。
