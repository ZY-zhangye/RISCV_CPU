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

### 1.1 LSQ Allocator V1 实现状态（2026-07-05）

`rtl/lsu/lsq_allocator.sv` 已实现独立 LQ/SQ ID allocator：

- LQ、SQ 各维护 8-bit free bitmap，每次可分别预留 0/1/2 个 ID。
- 选择结果进入 reservation 寄存器，并保持到 `alloc_fire_i` 或 `alloc_cancel_i`。
- `alloc_fire_i` 原子消耗 reservation 并写入 LQ/SQ allocation log。
- checkpoint 保存 LQ/SQ log tail，并通过独立 keep-count 表达同 bundle 中位于分支之前的
  LQ/SQ 分配数量。
- 分支恢复并行回退 LQ/SQ log，每周期最多各释放一个 ID；异常恢复一次清空未提交状态。
- retire/commit 通过独立双 lane release 接口归还 LQ/SQ ID。

当前模块只负责资源 ID 与恢复，不包含 LQ/SQ entry 数据、AGU、地址比较、转发或 Data RAM。

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

### 3.1 Store Queue V1 实现状态（2026-07-05）

`rtl/lsu/store_queue.sv` 已实现 8-entry 直接索引 SQ：

- Rename fire 使用 allocator 提供的 `sq_id` 写入 ROB ID 与 branch mask。
- LSU execution 按 `sq_id` 写地址、数据、byte enable 与异常信息；执行阶段不产生内存写。
- ROB-head Store 仅在 entry address/data ready 且无异常时进入 1-entry Store Commit Buffer。
- Data RAM 接受 commit buffer 请求后，产生单拍 commit done 与 allocator release。
- branch recovery 按 mask kill/clear SQ entry；exception recovery 清未提交 entry。
- 已进入 commit buffer 的 Store 不被年轻 branch recovery 杀死，并在 memory fire 前稳定保持。

## 4. LQ Entry

valid、rob_id、address_valid、address、size、unsigned_load、completed、forwarded、
exception_valid、branch_mask。

### 4.1 Load Queue V1 实现状态（2026-07-05）

`rtl/lsu/load_queue.sv` 已实现 8-entry 直接索引 LQ metadata array：

- 分配写入 ROB ID、PRD、mem op 与 branch mask。
- AGU 按 `lq_id` 写地址与地址异常；重复地址更新被 ready 契约阻止。
- LSU completion 标记 completed/forwarded，entry 保持到 retire。
- retire 支持双 lane 清 entry，并向 allocator 返回双 release 脉冲。
- branch recovery 按 mask kill/clear；exception recovery 清全部未提交 Load。

当前模块不执行 SQ compare、forward selection 或 Data RAM 请求；这些留在 `lsu_pipeline`。

## 5. LSU 周期

| 阶段 | 工作 |
|---|---|
| L0/AGU | base+imm，生成非对齐异常，写 LQ/SQ 地址和 Store 数据 |
| L1 | 并行生成 8 项 older/address/byte-overlap forwarding candidate |
| L2 | 通过 8→4→2→1 平衡比较树选择最近 Store 并寄存结果 |
| L3 | 根据已寄存候选执行 forwarding，或发起 BRAM 请求 |
| L4 | 接收 BRAM word，按 byte/half/word 提取与扩展 |
| L5 | 写入 LSU Completion Buffer |

候选生成、最近匹配归约和 completion 生成必须由寄存器隔开。最近项选择必须使用平衡树，
不得使用会综合成线性优先链的循环累计比较，也不得通过动态数组索引直接驱动 completion。

### 5.1 LSU Pipeline V1 实现状态（2026-07-05）

`rtl/lsu/lsu_pipeline.sv` 已实现保守单请求 LSU FSM：

- Store：AGU/对齐检查后直接更新 SQ，并生成不写 PRF 的 Store completion。
- Load：AGU 后并行寄存 8 项窄 forwarding candidate；下一拍使用 8→4→2→1 平衡树
  选择并寄存最近的更老匹配 Store，再由独立 decision 周期执行 forwarding/memory 分流。
- 任一更老 Store 地址未知时 Load 等待并重新 compare。
- 最近匹配 Store 完整覆盖且 data valid 时 forwarding；部分覆盖或 data 未就绪时等待。
- 无冲突时发出对齐的 Data RAM word request，response 后完成 byte/half/word 提取与扩展。
- Load/Store 非对齐产生 completion exception，不访问 Data RAM。
- 本地 1-entry completion buffer 支持背压；recovery 当拍组合抑制所有队列/内存副作用。

V1 同时只保留一个 LSU 请求，优先保证顺序约束与时序边界；吞吐优化留到成组验证后。

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

## 11. 当前验证状态

- `test/tb_lsq_allocator.sv` 覆盖双 LQ/SQ reservation、payload 保持、fire/cancel、
  checkpoint keep-count、多周期 rollback、release、exception flush 和无效 checkpoint no-op。
- QuestaSim：`tb_lsq_allocator` 通过，`Errors: 0, Warnings: 0`。
- 用户 OOC：200 MHz / 5.000 ns 下 WNS = +2.228 ns。
- `test/tb_store_queue.sv` 覆盖双 entry 分配、direct-index execute 更新、未提交 Store
  无内存副作用、commit buffer 背压、branch kill、异常阻止提交和 allocator release。
- QuestaSim：`tb_store_queue` 通过，`Errors: 0, Warnings: 0`。
- 用户 Store Queue OOC：200 MHz / 5.000 ns 下 WNS = +2.336 ns。
- `test/tb_load_queue.sv` 覆盖双 entry 分配、地址/异常更新、completion/forwarded、
  双 retire release、branch clear/kill 和 exception recovery。
- QuestaSim：`tb_load_queue` 通过，`Errors: 0, Warnings: 0`。
- 用户 Load Queue OOC：200 MHz / 5.000 ns 下 WNS = +2.342 ns。
- `test/tb_lsu_pipeline.sv` 覆盖 Store AGU/byte lane、无冲突 Load memory path、
  跨归约树两半的多候选最近 Store forwarding、未知老 Store 阻塞、非对齐异常和 recovery kill。
- QuestaSim：`tb_lsu_pipeline` 通过，`Errors: 0, Warnings: 0`。
- 用户 LSU Pipeline OOC 复测：200 MHz / 5.000 ns 下 WNS = +0.756 ns、TNS = 0；
  资源为 721 LUT、574 FF。最差路径为 L2 balanced reduction，数据路径 4.218 ns，
  其中布线占 84.3%。当前实现冻结，交由布局布线阶段继续优化。
