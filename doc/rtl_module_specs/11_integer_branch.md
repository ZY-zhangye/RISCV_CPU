# Integer 与 Branch Pipeline 设计

建议模块：int_pipeline0、int_branch_pipeline1、branch_unit。

## 1. 端口

| 方向 | 端口 | 类型 | 说明 |
|---|---|---|---|
| input | ex_valid_i | 1 | RR 输出有效 |
| output | ex_ready_o | 1 | Completion Buffer 可接收 |
| input | ex_uop_i | execute_uop_t | 操作、数据、ID、mask |
| output | result_valid_o | 1 | 执行结果有效 |
| input | result_ready_i | 1 | 本端 completion slot 可接收 |
| output | result_o | completion_t | 数据或异常 |
| output | branch_event_o | branch_resolve_t | INT1 分支解析 |

## 2. INT0 功能

INT0 支持 ADD/SUB、逻辑、比较、LUI/AUIPC 和完整移位。桶形移位器仅放在 INT0，
issue_arbiter 必须把移位操作限制到该端口。

## 3. INT1/Branch 功能

INT1 支持简单整数操作、比较、BEQ/BNE/BLT/BGE/BLTU/BGEU、JAL 和 JALR。
JALR 目标最低位清零；目标地址非 4-byte 对齐时记录 instruction-address-misaligned。

## 4. 时序

RR 输出在 EX 周期进入操作选择。简单 ALU 和分支比较在一个周期完成，结果写入本地
1-entry Completion Buffer。若独立综合低于 250 MHz，将移位或 branch target add
再切一级，但不能把结果直接组合送入全局 WB 仲裁。

## 5. 分支解析

branch_event 包含 rob_id、checkpoint_id、actual_taken、actual_target、mispredict、
redirect_pc 和预测更新信息。mispredict 条件为方向不同，或 taken 且目标不同。

branch_event 在 EX 末寄存。下一周期 recovery_controller 才广播恢复；branch_unit
不得直接控制 Fetch、RAT、ROB 或 IQ。

## 6. 异常和 Kill

若 ex_uop 已被更老恢复事件杀死，不产生 result 或 branch_event。ALU 普通结果写 PRF；
控制流指令只有 write_rd 的 JAL/JALR 才写 PRF。异常 completion 不写 PRF ready。

## 7. 断言

- 非 Branch uop 不产生 branch_event。
- JAL/JALR link 值为 pc+4。
- mispredict 的 redirect_pc 与实际执行结果一致。
- result stall 时 payload 稳定。
