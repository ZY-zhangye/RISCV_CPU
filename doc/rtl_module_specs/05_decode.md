# Decode Stage 设计

建议模块名：decode_stage；纯译码逻辑建议放入 decode_pkg。

## 1. 端口

| 方向 | 端口 | 类型 | 说明 |
|---|---|---|---|
| input | in_valid_i | 2-bit | 前缀有效 |
| output | in_ready_o | 1 | 输出寄存器可接收 |
| input | fetch_slot_i | 2×fetch_slot_t | 两条原始指令 |
| output | out_valid_o | 2-bit | 双路译码结果 |
| input | out_ready_i | 1 | Rename R0 接收 |
| output | decoded_uop_o | 2×decoded_uop_t | 统一微操作 |
| input | flush_i | 1 | 清空输出寄存器 |

## 2. 译码输出

每条 decoded_uop 至少包含 pc、inst、rs1、rs2、rd、need_rs1、need_rs2、
write_rd、imm、fu_type、alu_op、branch_op、mem_op、muldiv_op、csr_op、
serializing、exception_valid/cause/tval 和预测元数据。

## 3. 时序

D0 单周期完成 opcode/funct 分类、立即数生成和非法指令判断，结果写入输出寄存器。
Decode 不查询 RAT、ROB、IQ、LSQ，也不做资源 ready 汇总。

若组合译码无法独立达到 250 MHz，应按“预译码 + 最终控制”拆成 D0/D1，但对外接口
保持不变。

## 4. 双路规则

lane0/lane1 独立译码，不在 Decode 处理 RAW/WAW。lane1 仅在 lane0 有效时有效。
遇到 lane0 序列化指令时，可以仍译码 lane1，但 Rename 必须只接受 lane0；为了减少
控制复杂度，也可在 Decode 将 lane1_valid 清零。

## 5. 异常

- 未支持编码：illegal instruction，tval=inst。
- ECALL/EBREAK：标记专用操作，最终异常在 ROB head 触发。
- 取指异常：优先于指令译码异常。
- MRET 和 CSR：标记 serializing。
- 非对齐访存不在 Decode 判断，由 AGU 使用最终地址判断。

## 6. 验证

对 RV32I、M、Zicsr 每种编码建立表驱动测试。随机指令应满足：任一 32-bit 编码只能
归入一个操作类别；非法编码不得产生寄存器写、访存或分支副作用。
