# Physical Register File 与 Operand Read 设计

建议模块：physical_regfile、operand_read_stage。

## 1. PRF 端口

| 方向 | 端口 | 位宽 | 说明 |
|---|---|---:|---|
| input | read_valid_i | 3×2 | 三条 issue、每条两源 |
| input | read_prd_i | 6×6 | 六个 PRD |
| output | read_data_o | 6×32 | 同步读返回 |
| input | wb_valid_i | 2 | 两个最终写回 |
| input | wb_prd_i | 2×6 | 写目标 |
| input | wb_data_i | 2×32 | 写数据 |
| output | ready_bits_o | 64 | Rename/Issue 初始 ready 查询 |
| input | alloc_clear_i | 2×6 | 新 PRD 清 ready |

## 2. Bank 结构

prd[0] 选择偶/奇 Bank。每 Bank 32 项，并复制三份读副本以实现逻辑 3R1W。一个 Bank
的写回必须同步写其三个副本。p0 读恒为 0，任何写 p0 被屏蔽并断言。

物理实现可使用 LUTRAM、FF 或分布式 RAM；必须以独立综合结果选择，不预设 BRAM
一定更优。

## 3. 读时序

IS 周期输出并寄存 issue grant。RR 周期：

1. 根据 PRD Bank 路由六个读地址到三个副本。
2. 时钟沿读取/锁存数据。
3. RR 输出寄存器形成执行输入。

WB 到 RR 只允许一个小型已寄存 bypass：若 RR 返回的 PRD 等于本周期最终 WB PRD，
选择 WB data。不得从所有 completion producer 建立旁路。

## 4. 写冲突

writeback_arbiter 保证同一 Bank 每周期最多一个写。PRF 不负责缓存第二个写；若仍收到
同 Bank 双写属于接口违例。ready bit 仅在真实写入 PRF 的时钟沿置 1。

alloc_clear 优先于旧 PRD 的 ready set 仅当编号相同且 generation 合法；正常情况下
Free List 不会在旧写回仍可能到达时重分配 PRD。

## 5. Operand Read 输出

| 字段 | 说明 |
|---|---|
| valid | 执行槽有效 |
| rob_id/prd | 完成路由 |
| src1/src2 | PRF 或 WB bypass 后数据 |
| imm/op | 执行控制 |
| branch_mask | 恢复过滤 |
| lq_id/sq_id | LSU 使用 |

执行端 backpressure 时 RR 采用每端口 1-entry skid/holding register。一个端口阻塞不能
无条件阻塞其他端口；全局 issue_arbiter 应只授权 ready 端口。

## 6. 断言

- p0 始终为 0 且 ready。
- 同 Bank 不出现两个 wb_valid。
- 被发射项的每个需要源在发射时 ready。
- RR stall 时输出稳定。
- PRF 副本在任意写后保持一致。
