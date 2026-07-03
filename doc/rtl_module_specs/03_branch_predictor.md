# Branch Predictor 设计

建议模块名：branch_predictor，V1 包含 BTB、BHT 和更新队列。

## 1. 端口

| 方向 | 端口 | 类型 | 说明 |
|---|---|---|---|
| input | query_valid_i | 1 | F0 查询有效 |
| input | query_pc_i | 32 | 16-byte 块地址 |
| output | pred_valid_o | 1 | F1 预测结果有效 |
| output | pred_slots_o | typed | 四槽 BTB 命中/类型/目标 |
| output | bht_taken_o | 4 | 各槽方向预测 |
| input | update_valid_i | 1 | 已提交或已解析分支更新 |
| input | update_i | branch_update_t | PC、目标、类型、实际方向 |

## 2. 结构

- BTB：128 项直接映射。每项保存 valid、tag、slot、target、branch type。
- BHT：512 项 2-bit 饱和计数器。
- Update Buffer：至少 2 项，隔离 EX/Commit 与预测 RAM 写口。

若单个 BTB 项只能描述一个分支，则记录一个 16-byte 块内程序顺序最早的控制流指令。

## 3. 查询时序

F0 用 query_pc 同时索引 BTB 和 BHT。F1 得到同步读结果并做 tag compare。预测器只输出
候选信息，块内“最早 taken 槽”由 Fetch F2 选择。

不得在 F1 同周期完成 BTB 读、tag compare、BHT 读、next PC 更新和 IROM 输出消费；
最终选择必须位于 F2。

## 4. 更新时序

update_valid 进入 Update Buffer，下一周期更新：

- 条件分支：更新 BHT 饱和计数器。
- 已执行控制流：写 BTB target/type。
- JAL/JALR：BTB 记录无条件 taken。

## 5. V1 返回预测

V1 不实现 Return Address Stack。JALR，包括典型的 jalr x0, x1, 0 函数返回，和其他
间接跳转一样使用 BTB 中记录的最近目标。BTB 未命中时按顺序地址继续取指，待 JALR
在 INT1 解析后重定向。

该选择不会影响程序正确性，只可能降低嵌套调用和递归场景的返回预测率。预测器模块
不保存栈指针，Branch Checkpoint 也不保存 RAS 状态。后续若增加推测 RAS，应作为独立
版本扩展，同时补充 checkpoint 恢复，不能在 V1 中加入仅提交更新的半推测状态。

## 6. 冲突规则

- 同周期查询与更新同一项时，查询返回旧值或新值均可，但必须固定并在测试中建模。
- 多个更新碰撞时，按程序顺序保留更年轻提交项，未处理项留在 Update Buffer。
- BTB 命中但 BHT not-taken 的条件分支仍输出顺序预测。

## 7. 断言与计数

断言非法 BTB type 不产生 taken；更新队列满时不得静默丢更新；JALR 预测目标只能
来自命中的 BTB。统计 query、BTB hit、BHT taken、JALR BTB hit、mispredict 和
target miss。
