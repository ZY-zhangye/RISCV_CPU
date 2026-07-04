# Fetch Pipeline 设计

建议模块名：fetch_pipeline，内部阶段 F0、F1、F2。

## 1. 输入输出端口

| 方向 | 端口 | 类型/位宽 | 说明 |
|---|---|---:|---|
| input | clk_i、rst_i | 1 | 时钟复位 |
| input | redirect_valid_i | 1 | 已寄存重定向 |
| input | redirect_pc_i | 32 | 分支、异常或 MRET 目标 |
| input | ibuf_ready_i | 1 | Instruction Buffer 可收一包 |
| output | fetch_valid_o | 1 | F2 包有效 |
| output | fetch_packet_o | fetch_packet_t | 最多四条指令 |
| output | bp_query_o | typed | F0 预测器查询 |
| input | bp_result_i | typed | F1 预测器结果 |
| output | imem_req_o | typed | 16-byte 对齐读请求 |
| input | imem_resp_i | typed | 128-bit 同步返回 |

## 2. 内部状态

- pc_f0_q：下一个投机请求 PC，每次发出请求后顺序推进。
- request metadata：保存未决 IROM 请求的 PC、fetch_id、epoch 和预测结果。
- F1 response FIFO：2 项，一项正常流水槽加一项 skid 槽。
- valid_f2_q：F2 弹性输出有效位。
- next_fetch_id_q：每发出一个取指事务递增，被冲刷的 ID 可以留下空洞。
- epoch_q：每次 redirect 或内部预测 taken 翻转，用于丢弃旧返回。

## 3. 周期级时序

| 周期阶段 | 主要工作 | 寄存输出 |
|---|---|---|
| F0 | 生成 block PC，查询 IROM/BTB/BHT，投机推进顺序 PC | PC、fetch_id、epoch |
| F1 | 接收 128-bit IROM 和预测元数据 | 2 项 response FIFO |
| F2 | 选择块内最早预测跳转，生成 slot_valid 和 next PC | fetch_packet |

F2 只做四槽小规模选择和地址生成。IROM 数据不得在同周期经过复杂预测选择后继续进入
Decode；必须先进入 Instruction Buffer。

## 4. PC 更新

优先级：

1. rst_i：PC 置 RESET_PC。
2. redirect_valid_i：清 F1/F2 valid，PC 置 redirect_pc_i，更新 epoch。
3. F1 选中的包预测 taken：PC 置预测目标，冲刷所有年轻响应和请求。
4. F0 发出普通请求：PC 投机更新为顺序下一块。
5. 其他情况：保持。

顺序 next PC 需要考虑当前 PC[3:2]，但输出包的 block_pc 始终 16-byte 对齐。
slot_valid 从起始 slot 开始，预测跳转之后的槽清零。

## 5. 反压

F2 使用一项弹性寄存器，F1 使用两项 response FIFO。前端以
`F2 + F1 FIFO + outstanding request` 计算信用，只有在已发请求一定有落点时
才继续发请求。ibuf_ready_i=0 时 F2 payload 保持；skid 槽先吸收已发响应，
信用耗尽后 F0 停发。反压不得越过 Instruction Buffer 直接依赖 Decode。

当 IROM 为一拍、有序同步返回时，流水填满后每周期可发出一个 128-bit 取指块。
若 IROM 延迟增加，本版本的单未决请求接口会自动降低速率，但不会丢失响应。

## 6. 异常与边界

- 当前无 RVC，PC[1:0] 非零形成 instruction-address-misaligned 取指异常包。
- 16 KB IROM 越界策略由顶层地址映射确定，可产生 access fault。
- redirect 与旧 IROM 返回同周期到达时，以 redirect 为准，旧 epoch 返回丢弃。

## 7. 关键断言

- imem_req 地址低 4 位为 0。
- fetch_packet.slot_valid 在预测跳转槽之后全为 0。
- redirect 后旧 epoch 包不会写入 ibuf。
- F2 stall 时 fetch_packet 稳定。
