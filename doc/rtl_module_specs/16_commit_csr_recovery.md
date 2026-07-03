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

## 3. CSR 端口与状态

csr_file 至少实现 mstatus、mie、mtvec、mscratch、mepc、mcause、mtval、mip、
mcycle、minstret、mhartid。CSR 指令到达 ROB head 后读取、计算旧值返回 PRD，并在
提交点原子更新 CSR。

CSR 执行期间暂停年轻提交和新序列化操作，但不需要全核组合停顿；前端停止通过
recovery/serialize 状态逐级生效。

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
