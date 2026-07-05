# Commit、CSR 与 Recovery 设计

建议模块：commit_unit、csr_file、branch_checkpoint_file、recovery_controller。

## 1. Commit 端口

| 方向 | 端口 | 类型 | 说明 |
|---|---|---|---|
| input | rob_head_valid_i | 2-bit | ROB head row |
| input | rob_head_i | 2×rob_entry_t | 两条最老指令 |
| output | retire_count_o | 2-bit | 0/1/2 |
| output | amt_update_o | 2×typed | new_prd 提交映射 |
| output | reclaim_o | 2×typed | old_prd 写 Reclaim Buffer |
| output | store_commit_o | typed | head Store 请求 |
| input | store_commit_done_i | 1 | Store 副作用已接受 |
| output | recovery_req_o | recovery_req_t | 异常/MRET/中断 |
| output | commit_trace_o | 2×typed | 调试和 instret |

## 2. 双提交条件

lane0 可提交条件：valid、complete、无待处理序列化动作，若为 Store 则
store_commit_done。lane1 只有 lane0 同周期提交、lane1 complete 且 lane0 不触发
异常/恢复时才可提交。

异常、MRET、ECALL、EBREAK、序列化 CSR 在 head 独占处理，本周期 retire_count 至多 1。

### 2.1 Commit Unit V1 实现状态（2026-07-05）

`rtl/commit/commit_unit.sv` 已实现保守按序提交控制：

- 从 ROB head row 的两路寄存输出生成 `retire_count_o`。
- 普通 complete 指令支持双提交；lane0 serializing 时只提交 lane0。
- 生成 `commit_map_t` AMT 更新和 old PRD reclaim 输出。
- Store 使用两阶段协议：先向 Store Queue 发 `store_commit_valid_o/sq_id`，
  capture 后进入 pending，直到 `store_commit_done_i` 才退休 ROB head。
- lane0 exception 不正常 retire，输出 CSR exception 写入端口和 `REC_EXCEPT` recovery。
- V1 暂不执行 CSR/MRET 指令副作用；相关集成留给后续 commit/CSR glue。

## 3. CSR 端口与状态

csr_file 至少实现 mstatus、mie、mtvec、mscratch、mepc、mcause、mtval、mip、
mcycle、minstret、mhartid。CSR 指令到达 ROB head 后读取、计算旧值返回 PRD，并在
提交点原子更新 CSR。

CSR 执行期间暂停年轻提交和新序列化操作，但不需要全核组合停顿；前端停止通过
recovery/serialize 状态逐级生效。

### 3.1 CSR File V1 实现状态（2026-07-05）

`rtl/commit/csr_file.sv` 已实现 commit-time machine-mode CSR 状态文件：

- 支持 `mstatus/mie/mtvec/mscratch/mepc/mcause/mtval/mip/mcycle/minstret/mhartid`。
- CSR 指令组合读旧值，时钟沿按 `CSR_RW/RS/RC/RWI/RSI/RCI` 原子更新。
- `CSRRS/CSRRC/CSRRSI/CSRRCI` 在 operand/zimm 为 0 时不写 CSR。
- `mhartid` 只读，未知地址或只读写入产生 `csr_illegal_o`。
- 异常入口写 `mepc/mcause/mtval`，并执行 machine-mode `mstatus` 栈切换；
  `exception_vector_o` 输出对齐后的 `mtvec`。
- `mret_valid_i` 恢复 `MIE/MPIE/MPP` 并输出 `mepc` 作为返回 PC。
- `mcycle` 每周期递增，`minstret` 按 retire_count 累加；CSR 写计数器时写入优先。

## 4. 精确异常

head 异常处理顺序：

1. 停止正常 retire。
2. 写 mepc、mcause、mtval 和 mstatus。
3. 发出 exception recovery。
4. RAT 从 AMT 恢复，ROB/IQ/LSQ 清年轻项。
5. Free List 多周期重建。
6. 所有恢复完成后 redirect 到 mtvec。

异常指令本身不更新 AMT、不回收 old_prd、不增加 instret。

## 5. MRET 和中断

MRET 在 head 更新 mstatus，并 redirect 到 mepc。中断仅在指令边界且无更高优先级同步
异常时接受；mepc 写入下一条应执行 PC。中断复用异常恢复流程。

## 6. Branch Checkpoint

checkpoint_file 每项保存 RAT snapshot 或恢复句柄、Free List log tail、ROB tail、
LQ tail、SQ tail。分配最多每周期一个。正确分支解析释放 checkpoint 并清 mask；
误预测先广播恢复信息，等各模块 ack 后再释放槽。

## 7. Recovery Controller FSM

建议状态：

    IDLE
    BRANCH_BROADCAST
    BRANCH_WAIT_ACK
    EXCEPTION_DRAIN
    RAT_RESTORE
    FREELIST_REBUILD
    REDIRECT

分支恢复目标在数周期内完成即可，异常允许更长。控制器收集 frontend、rename、ROB、
IQ、LSQ、MDU 的 done/ack，避免假定所有模块一拍完成。

### 7.1 Recovery Controller V1 实现状态（2026-07-05）

`rtl/commit/recovery_controller.sv` 已实现恢复请求仲裁与广播 FSM：

- commit recovery 优先于 branch mispredict。
- branch mispredict 转换为 `REC_BRANCH` kill broadcast，携带 checkpoint 和 redirect PC。
- 正确分支不走 `REC_BRANCH`，只输出 `checkpoint_clear_valid_o/id`，避免误杀正确路径。
- FSM 顺序为 `IDLE -> BROADCAST -> WAIT_ACK -> REDIRECT`。
- `BROADCAST` 单拍输出 `recovery_t`；`WAIT_ACK` 等待参数化 done 向量全 1；
  `REDIRECT` 单拍输出 redirect valid/PC。
- busy 期间忽略新的年轻恢复请求，避免覆盖已锁存的更老恢复目标。

## 8. 优先级

同步异常 > MRET > 已接受中断 > branch mispredict > 正确分支解析。更老 ROB 事件优先于
更年轻事件。恢复进行时新的年轻事件忽略；更老异常若理论上可能出现，必须按 ROB 年龄
重新仲裁。

## 9. 断言

- Commit 严格按 ROB 顺序。
- 异常指令和所有年轻指令无架构副作用。
- AMT 只在 commit fire 更新。
- Store 只在 head 且无异常时写 Memory。
- recovery 完成前 Fetch 不从新目标继续提交包。

## 10. 当前验证状态

- `test/tb_csr_file.sv` 覆盖 CSR 读改写、只读/未知地址非法、`mcycle/minstret`、
  异常入口和 MRET 状态恢复。QuestaSim 最小测试和 23 项当前回归均通过，
  `Errors: 0, Warnings: 0`。Vivado 5 ns OOC 时序验证待运行后补充最终 WNS/资源。
- `test/tb_commit_unit.sv` 覆盖普通双提交、serializing 单提交、incomplete lane0 阻塞、
  lane1 exception 阻止同周期双提交、lane0 exception recovery，以及 Store 两阶段提交。
  QuestaSim 最小测试和 24 项当前回归均通过，`Errors: 0, Warnings: 0`。Vivado 5 ns OOC 时序验证待运行后补充最终 WNS/资源。
- `test/tb_recovery_controller.sv` 覆盖正确分支 checkpoint clear、branch mispredict broadcast、
  ack wait、redirect pulse、commit recovery 优先级，以及 busy 期间忽略新请求。
  QuestaSim 最小测试和 25 项当前回归均通过，`Errors: 0, Warnings: 0`。Vivado 5 ns OOC
  WNS 为 +3.112 ns，时序健康。
