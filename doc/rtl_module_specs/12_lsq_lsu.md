# Load/Store Queue 与 LSU Pipeline 设计

建议模块：load_queue、store_queue、lsu_pipeline、store_commit_buffer。

## 1. 分配端口

| 方向 | 端口 | 类型 | 说明 |
|---|---|---|---|
| input | alloc_valid_i | 2-bit | Rename 的内存 uop |
| output | alloc_ready_o | 1 | LQ/SQ 空间足够 |
| output | alloc_lq_id_o | 2×3 | Load ID |
| output | alloc_sq_id_o | 2×3 | Store ID |
| input | recovery_i | recovery_t | tail 恢复和 kill |

LQ、SQ 各 8 个固定槽，环形分配。每个内存 uop 只占用一种队列。

## 2. LSU 执行端口

| 方向 | 端口 | 类型 | 说明 |
|---|---|---|---|
| input | issue_valid_i | 1 | Memory IQ 发射 |
| output | issue_ready_o | 1 | AGU 输入可接收 |
| input | issue_uop_i | execute_uop_t | base、offset、store data |
| output | load_result_o | completion_t | Load 返回或异常 |
| output | mem_req_o | load_mem_req_t | 访问 Data RAM |
| input | mem_resp_i | load_mem_resp_t | 同步返回 |
| input | store_commit_i | store_commit_t | ROB head Store |
| output | store_commit_ready_o | 1 | Store 已具备提交条件 |

## 3. SQ Entry

valid、rob_id、address_valid、address、data_valid、data、byte_enable、
exception_valid、branch_mask。Store 执行只更新 SQ，不写 Data RAM。

## 4. LQ Entry

valid、rob_id、address_valid、address、size、unsigned_load、completed、forwarded、
exception_valid、branch_mask。

## 5. LSU 周期

| 阶段 | 工作 |
|---|---|
| L0/AGU | base+imm，生成非对齐异常，写 LQ/SQ 地址和 Store 数据 |
| L1 | 对 Load 生成 older-store mask 和地址 match vector |
| L2 | 选择最近匹配 Store；转发或发起 BRAM 请求 |
| L3 | 接收 BRAM word，按 byte/half/word 提取与扩展 |
| L4 | 写入 LSU Completion Buffer |

L1 和 L2 必须由寄存器隔开。8 项比较、最近匹配选择和数据 mux 不得在一个周期完成。

## 6. Load 发射许可

Load 只有满足以下条件才离开 Memory IQ：

1. 所有更老 Store 地址有效。
2. 最近同地址覆盖 Store 的数据有效，或不存在覆盖冲突。
3. LQ entry 有效且未完成。
4. LSU pipeline 可接收。

第一版按访问字节范围判断冲突。若部分字节由 Store 覆盖而其余来自 RAM，V1 直接等待
Store 提交，不实现数据合并。

## 7. Store 提交

commit_unit 指示 head Store 后，SQ 检查 address_valid、data_valid、无异常。满足时写入
1-entry Store Commit Buffer；提交缓冲与 Data RAM fire 后才向 commit_unit 返回完成。
这样 Data RAM backpressure 不直接进入 ROB head 组合判断。

## 8. 非对齐和异常

byte 永不因对齐异常；half 要求 addr[0]=0；word 要求 addr[1:0]=0。异常写入对应
LQ/SQ 和 ROB，不发 memory request。异常 Store 永不进入 Store Commit Buffer。

## 9. 恢复

分支误预测按 checkpoint tail 回退 LQ/SQ，并本地杀 branch_mask 命中项。已经进入
Store Commit Buffer 的项必为已确认 ROB head，不会被分支恢复杀死。异常恢复清所有
未提交项。

## 10. 断言

- 未提交 Store 不产生 dmem write。
- Load 不越过地址未知的更老 Store。
- forwarding 总是选择最近的更老匹配 Store。
- 一个 lq_id/sq_id 在释放前不重复分配。
- 被 kill 或异常的请求不进入 Memory。
