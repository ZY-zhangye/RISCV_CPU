# 公共 RTL 接口与时序契约

## 1. 时钟与复位

所有时序模块使用单时钟 clk_i。rst_i 为高有效同步复位。

- 复位只强制清零 valid、指针、状态机和架构可见控制状态。
- 大型数据阵列不要求逐项复位；无效项内容不可被消费。
- 不使用数据作为时钟，不在 RTL 内生成门控时钟。
- 复位释放后的第一个上升沿开始接受输入。

## 2. 命名约定

| 后缀 | 含义 |
|---|---|
| _i / _o | 模块输入 / 输出 |
| _q / _d | 时序状态 / 下一状态 |
| _valid / _ready | 解耦接口有效与接收 |
| _fire | valid 与 ready 同时为 1 |
| _id | 直接索引编号，不允许关联搜索 |
| _mask | 每一位独立描述一个槽或分支 |

## 3. 解耦传输

单路接口传输条件：

    fire = valid && ready

发送端在 valid=1 且 ready=0 时必须保持 payload 不变。接收端只能在 fire 时
消费数据。普通数据流不得依赖跨越两个以上模块的组合 ready。

双路顺序接口使用 lane_valid[1:0]，必须满足前缀有效：

| lane_valid | 含义 |
|---|---|
| 00 | 无指令 |
| 01 | 仅 lane0 |
| 11 | lane0 和 lane1 |
| 10 | 非法 |

模块可以一次接受 0、1 或 2 条，但不能接受 lane1 而拒绝 lane0。队列型模块通过
accept_count 和 free_count 做本地决策，不能把内部逐槽搜索传播到上游。

## 4. 全局参数

建议在 core_types_pkg 中定义：

| 名称 | 值 | 位宽 |
|---|---:|---:|
| XLEN | 32 | 32 |
| ARCH_REGS | 32 | 5-bit 索引 |
| PHYS_REGS | 64 | 6-bit PRD |
| ROB_ENTRIES | 32 | 5-bit ROB ID |
| LQ_ENTRIES / SQ_ENTRIES | 8 / 8 | 3-bit ID |
| CHECKPOINTS | 4 | 2-bit ID，4-bit mask |
| FETCH_ID_WIDTH | 8 | 8-bit 环形序号 |

ROB ID 的逻辑编码为 {row_index[3:0], bank_id}。年龄比较必须使用环形指针和
wrap 信息，不能直接比较 ID 数值大小。

## 5. 公共数据类型

fetch_packet_t 至少包含：

| 字段 | 位宽 | 说明 |
|---|---:|---|
| block_pc | 32 | 128-bit 块基地址 |
| inst[4] | 4×32 | 四条指令 |
| slot_valid | 4 | 有效槽 |
| pred_taken | 1 | 本块采用预测跳转 |
| pred_slot | 2 | 最早预测跳转槽 |
| pred_target | 32 | 预测目标 |
| fetch_id | 8 | 取指事务编号 |

decoded_uop_t 保存架构译码信息，不含物理寄存器。renamed_uop_t 在其基础上加入
prs1、prs2、prd、old_prd、rob_id、lq_id、sq_id、checkpoint_id 和
branch_mask。执行端传输只携带本执行单元需要的字段，禁止让完整大总线穿越后端。

completion_t 至少包含 valid、prd、rob_id、data、exception_valid、
exception_cause、exception_tval 和 producer。

## 6. 状态更新优先级

所有包含推测状态的模块使用统一优先级：

1. rst_i
2. exception_recovery
3. branch_recovery
4. 正常 dequeue、enqueue、wakeup、writeback 或 commit

同周期发生恢复和普通写入时，年轻指令的普通写入必须被屏蔽。恢复请求进入控制器
后寄存一拍再分发，除执行分支本身外，不允许形成分支执行到前端 ready 的组合路径。

## 7. 分支掩码语义

每个未决分支占用一个 checkpoint bit。年轻 uop 的 branch_mask 记录它依赖的所有
未决分支。checkpoint k 误预测时：

    kill = branch_mask[k]

分支自身不被自己的 mask 杀死。正确解析后，各模块本地清除对应 mask 位；误预测时
先杀死带该位的项，再释放 checkpoint。

## 8. 异常语义

执行单元只产生异常记录，不直接修改 PC 或 CSR。异常 uop 可以进入 completion，
但不得写 PRF ready。ROB 在该项到达 head 时触发精确异常。Store 在提交前不得修改
Data RAM。

## 9. 组合路径禁令

- Commit 到 Free List 到 Rename Allocate。
- WB 到 Wakeup 到 Select 到 PRF Read 到 Execute。
- Branch Execute 到 RAT Restore 到 Rename Ready。
- LSQ Compare 到 BRAM Read 到 Load WB。
- 任一执行单元 stall 直接到 Fetch PC。

模块间 payload 输出原则上来自寄存器；ready 只允许在相邻弹性级之间组合传播一次。

## 10. 断言基线

每个模块至少加入以下 SVA：

- valid 且非 ready 时 payload 稳定。
- 双路 valid 不出现 10。
- 指针和 occupancy 不越界。
- 无效槽不产生写使能。
- x0 永不分配新 PRD，p0 永不写入。
- 被 recovery 杀死的 uop 不得提交或写存储器。
- 同一物理寄存器同周期最多一次最终写入。
