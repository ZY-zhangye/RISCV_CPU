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

## 6. 当前 RTL 实现状态

截至 2026-07-05，`rtl/prf/physical_regfile.sv` 与
`test/tb_physical_regfile.sv` 已完成 V1 RTL 和 directed test：

- 64 项 PRF 按 PRD bit 0 分成偶/奇两个 32-entry Bank。
- 每个 Bank 使用三份显式单读副本；请求按 Bank 内出现顺序路由到 copy0/1/2。
- 读地址与 lane-to-copy 路由同步锁存，输出为一拍同步读结果。
- 每 Bank 只选择一个最终 WB，并向三个副本广播；同 Bank 双 WB 属于接口违例。
- ready bitmap 复位全 1；WB 置位，allocation clear 清零且同 PRD 时 clear 优先。
- 数据阵列不施加全阵列复位，以保留 FPGA RAM 推断；p0 读恒为 0、ready 恒为 1。

QuestaSim 2024.1 编译为 0 errors / 0 warnings，directed test 已覆盖六读、双异 Bank WB、
全部六个副本、交错 Bank 路由、p0/invalid 读、ready 更新优先级和 lane1-only WB。
5.000 ns OOC 最终 WNS 为 +2.005 ns、TNS 为 0；资源为 998 LUT（其中 144 LUT as
Memory）和 282 FF。当前 PRF 实现冻结，RAM inference 仍应在后续集成报告中持续核对。

`rtl/prf/operand_read_stage.sv` 与 `test/tb_operand_read_stage.sv` 也已完成 V1：

- 三个已寄存 issue slot 按 `issue_port_t` 路由到 INT0、INT1、LSU、MDU。
- issue metadata 与 PRF 一拍同步读返回对齐，最终 WB 提供双路 tag/data bypass。
- `pc/pred_taken/pred_target/checkpoint_id` 已补入 issue/execute uop 并由 Dispatch 透传。
- 每个执行端具有独立 metadata 与 response holding；阻塞时在本地保存 PRF 数据，其他
  端口仍可继续推进，不依赖共享 PRF copy 输出保持。
- Store 的 `src2` 同时形成 `store_data`；无源操作与 p0 源返回 0。
- Branch recovery 按 branch mask kill metadata/response，Exception recovery 全清。

QuestaSim 2024.1 已重编译并运行 Dispatch Buffer、Issue Queue、Issue Arbiter、PRF、
Operand Read 五项相关回归：0 errors / 0 warnings，全部 directed test 通过。
Operand Read 在 4.000 ns（250 MHz）OOC 下最终 WNS 为 +1.272 ns、TNS 为 0；资源为
1771 LUT、1888 FF。当前实现冻结，下一步进入 Integer Execute Pipeline。

## 7. 断言

- p0 始终为 0 且 ready。
- 同 Bank 不出现两个 wb_valid。
- 被发射项的每个需要源在发射时 ready。
- RR stall 时输出稳定。
- PRF 副本在任意写后保持一致。
