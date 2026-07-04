# Instruction Buffer 设计

建议模块名：instruction_buffer。

## 1. 端口

| 方向 | 端口 | 位宽/类型 | 说明 |
|---|---|---|---|
| input | fetch_valid_i | 1 | 取指包有效 |
| output | fetch_ready_o | 1 | 至少可容纳本包有效槽 |
| input | fetch_packet_i | fetch_packet_t | 最多四条 |
| output | decode_valid_o | 2 | 前缀有效 |
| input | decode_ready_i | 1 | Decode 接受整个输出 bundle |
| output | decode_slot0_o / decode_slot1_o | 2×fetch_slot_t | PC、inst、预测信息 |
| input | flush_i | 1 | 重定向清空 |
| output | occupancy_o | 4 | 0 至 8 |

## 2. 存储结构

8 个固定 entry 环形队列。每项保存 inst、pc、pred_taken、pred_target、fetch_id 和
fetch exception 的 valid/cause/tval。维护 3-bit head/tail 与 4-bit occupancy。

不使用整体移位。四写通过 tail、tail+1、tail+2、tail+3 的直接索引完成；双读通过
head 和 head+1 完成并锁存到双路输出寄存器。Decode 只能看到该寄存器，不直接看到
entry 阵列的异步读结果。

逻辑容量固定为 8，`occupancy_o` 等于环形存储占用数加输出寄存器有效数。输出寄存器
不是额外容量。

## 3. 接收与输出

    enqueue_count = popcount(fetch_packet.slot_valid)
    output_count  = popcount(decode_valid_o)
    refill_count  = output_can_refill ? min(storage_occupancy, 2) : 0

fetch_ready_o 只按当前总 free_count 判断，不利用同周期 Decode 消费腾出的空间，避免
Decode ready 进入 Fetch ready 路径。

decode_valid_o 只可为 00、01、11。输出寄存器为空，或原 bundle 本周期被整体接受时，
才从环形存储预取最多两条并推进 head。若存储为空而同周期刚 enqueue，允许下一周期
再预取，不建立 Fetch 到 Decode 的直通路径。

## 4. 同周期更新

同周期 enqueue/输出消费/预取时，分别更新 head、tail、存储占用和输出 valid。
当队列空且发生直通条件时，V1 仍建议先写队列、下一周期输出，以切断 Fetch 到 Decode
组合路径。

## 5. Flush

flush_i 优先于 enqueue/dequeue：清 occupancy、head/tail 复位，所有旧 entry 逻辑无效。
数据阵列无需清零。flush 同周期 fetch 输入不得被接受。

## 6. 断言

- 总 occupancy 不大于 8，且等于存储占用加输出有效数。
- fetch_fire 时 free_count 不小于 enqueue_count。
- decode_valid=10 永不出现。
- stall 时 decode_slots 和 decode_valid 保持。
- flush 后下一周期 occupancy 为 0。
