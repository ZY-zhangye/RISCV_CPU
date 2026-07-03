# Rename、RAT 与 AMT 设计

建议模块名：rename_stage、rat_amt。Rename 分 R0 Map Read 和 R1 Allocate 两级。

## 1. 端口

| 方向 | 端口 | 类型 | 说明 |
|---|---|---|---|
| input | dec_valid_i | 2-bit | 双路前缀有效 |
| output | dec_ready_o | 1 | R0 输入寄存器可接收 |
| input | dec_uop_i | 2×decoded_uop_t | 译码微操作 |
| output | rn_valid_o | 2-bit | 已重命名 bundle |
| input | rn_ready_i | 1 | Dispatch Buffer 可接收 |
| output | rn_uop_o | 2×renamed_uop_t | 物理寄存器和各类 ID |
| input | commit_map_i | 2×typed | AMT 更新与 old_prd 回收事件 |
| input | wb_ready_set_i | 2×PRD | 写回 ready 更新 |
| input | recovery_i | recovery_t | 分支或异常恢复 |
| output | alloc_req_o | alloc_req_t | Free List/ROB/LSQ/Checkpoint 需求 |
| input | alloc_resp_i | alloc_resp_t | R1 使用的已寄存分配结果 |

## 2. RAT/AMT

RAT 和 AMT 均为 32×6-bit 寄存器阵列。x0 始终映射 p0。

- RAT 是推测映射，由 Rename R1 更新。
- AMT 是已提交映射，由 Commit 更新。
- 分支恢复从 checkpoint 恢复 RAT。
- 精确异常恢复把 RAT 逐项或双项复制为 AMT，不走单周期 32 项大多路器。

## 3. R0 时序

R0 组合读取最多四个源映射和两个旧目的映射，同时读取 PRD ready table。周期末锁存：

- lane0 的 prs1/prs2/old_prd。
- lane1 的基础 RAT 结果。
- 两 lane 资源需求。
- lane 内 RAW/WAW 比较结果。

R0 不执行 Free List 优先编码，也不写 RAT。

## 4. R1 时序

R1 从已寄存的 allocator response 获得最多两个 PRD、ROB ID、LQ/SQ ID 和最多一个
checkpoint。发生 rn_fire 时原子执行：

1. 生成 lane0/lane1 最终 prs、prd、old_prd。
2. 更新 RAT，WAW 时 lane1 最终覆盖 lane0。
3. 清新 PRD ready。
4. 向 ROB 和相应队列发送分配写入。
5. 将 renamed_uop 写入 Dispatch Buffer。

所有资源必须同时可用才允许该 lane 接受。双路不能出现部分写 ROB、未写 IQ 的状态。

## 5. Lane 内依赖

RAW：lane1 的源寄存器命中 lane0.rd 时，使用 lane0.new_prd，ready=0。

WAW：lane1.rd 等于 lane0.rd 时，lane1.old_prd=lane0.new_prd，最终 RAT 指向
lane1.new_prd。lane0 的 old_prd 仍在 lane0 提交时回收。

x0 不分配新 PRD，不产生 WAW/RAW 物理依赖。

## 6. 接受宽度

lane0 若资源不足则两 lane 均停。lane0 可接受但 lane1 资源不足时，允许单收 lane0，
lane1 必须由 Decode/R0 弹性寄存器保持并在下一次成为 lane0。序列化指令后不得同周期
分配更年轻 lane。

## 7. 恢复

分支误预测时：

- 恢复 checkpoint RAT snapshot。
- 清空 R0/R1 中所有错误路径 uop。
- allocator 使用 checkpoint 保存的 tail/bitmap 恢复。

异常时进入 restore FSM：停止新分配，RAT←AMT，触发 Free List 重建，完成后恢复 ready。

## 8. 关键断言

- 同一周期所有资源分配与 rn_fire 原子一致。
- RAT[x0] 和 AMT[x0] 始终为 p0。
- 任一 active RAT 映射不指向 Free List 中的空闲 PRD。
- lane1 RAW/WAW 结果与顺序执行两个单独 rename 等价。
