# RTL 模块设计规格索引

本文档集把 FPGA_OOO_ARCHITECTURE_PLAN.md 转化为可直接指导 SystemVerilog
实现、单元验证和独立综合的模块规格。原文是架构规划，本目录进一步固定端口边界、
周期级行为、状态更新优先级和模块责任。

## 使用顺序

1. 先阅读 00_common_contract.md，所有模块必须遵守其中的接口和时序契约。
2. 按前端、重命名、调度、执行、访存、提交恢复的顺序实现。
3. 每完成一个模块，先用本文件给出的模块边界做单元测试和独立综合。
4. 若实现与规格不一致，应先更新规格并记录原因，再修改 RTL。

## 规划模块

| 文档 | 建议 RTL 模块 | 主要职责 |
|---|---|---|
| 00_common_contract.md | core_types_pkg | 参数、类型、握手、恢复优先级 |
| 01_core_top.md | core_top | 顶层连接、全局控制、性能计数 |
| 02_fetch_pipeline.md | fetch_pipeline | F0/F1/F2 取指流水和重定向 |
| 03_branch_predictor.md | branch_predictor | BTB、BHT 和预测更新 |
| 04_instruction_buffer.md | instruction_buffer | 4 写 2 读环形指令队列 |
| 05_decode.md | decode_stage | 双路 RV32IM_Zicsr 译码 |
| 06_rename.md | rename_stage、rat_amt | R0/R1 重命名和映射维护 |
| 07_free_list.md | free_list | 分组位图双分配和延迟回收 |
| 08_rob.md | reorder_buffer | 双分配、完成记录、双提交观察 |
| 09_dispatch_issue.md | dispatch_buffer、issue_queue、issue_arbiter | 分类分发、唤醒、选择 |
| 10_prf_operand.md | physical_regfile、operand_read | Banked PRF 和 RR 流水 |
| 11_integer_branch.md | int_pipeline、branch_unit | 整数执行和分支解析 |
| 12_lsq_lsu.md | load_queue、store_queue、lsu_pipeline | 地址生成、顺序检查和转发 |
| 13_data_memory.md | data_memory_banks | 四 Bank BRAM 数据存储 |
| 14_mul_div.md | mul_pipeline、div_unit | DSP 乘法和迭代除法 |
| 15_completion_writeback.md | completion_buffer、writeback_arbiter | 结果缓冲和双写回 |
| 16_commit_csr_recovery.md | commit_unit、csr_file、recovery_controller | 精确提交、异常和恢复 |
| 17_verification_timing.md | testbench/constraints | 验证矩阵和时序验收 |
| 18_architecture_decisions.md | architecture review | 已冻结的 V1 架构选择 |

## 关键架构参数

| 参数 | V1 值 |
|---|---:|
| XLEN | 32 |
| Fetch / Decode / Rename | 4 / 2 / 2 |
| 最大 Issue / Writeback / Commit | 3 / 2 / 2 |
| PRF / ROB | 64 / 32 |
| Integer IQ / Memory IQ / MDU IQ | 12 / 8 / 4 |
| LQ / SQ | 8 / 8 |
| Branch Checkpoint | 4 |
| 目标频率 | 200 MHz |

空目录不会被 Git 记录；本目录中的规格文件从现在开始构成重构版本的设计基线。
