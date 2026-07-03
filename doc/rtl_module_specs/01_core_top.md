# Core 顶层设计

建议模块名：core_top。

## 1. 职责

core_top 只负责模块实例化、流水接口连接、全局恢复路由、外部存储器/中断接口和
性能计数汇总。顶层不得包含大规模调度、ROB 搜索或旁路选择逻辑。

## 2. 外部端口

| 方向 | 端口 | 位宽 | 说明 |
|---|---|---:|---|
| input | clk_i | 1 | 核心时钟 |
| input | rst_i | 1 | 同步复位 |
| input | ext_irq_i | 1 | 机器外部中断 |
| input | timer_irq_i | 1 | 机器定时中断 |
| input | software_irq_i | 1 | 机器软件中断 |
| output | imem_req_valid_o | 1 | 可选外部 IROM 请求 |
| output | imem_req_addr_o | 32 | 16-byte 对齐地址 |
| input | imem_resp_valid_i | 1 | IROM 返回有效 |
| input | imem_resp_data_i | 128 | 四条指令 |
| output | dmem_load_req_o | 1 | Load 请求 |
| output | dmem_store_req_o | 1 | 已提交 Store 请求 |
| output | dmem_addr_o | 32 | 字节地址 |
| output | dmem_wdata_o | 32 | 写数据 |
| output | dmem_wstrb_o | 4 | byte enable |
| input | dmem_ready_i | 1 | 请求接收 |
| input | dmem_rvalid_i | 1 | Load 返回 |
| input | dmem_rdata_i | 32 | 读取数据 |
| output | commit_trace_o | typed | 双提交调试信息 |

若 IROM/Data RAM 实例化在核内，外部端口可替换为初始化文件参数和 MMIO 接口，但
内部 fetch/LSU 的 ready-valid 契约不变。

## 3. 内部连接

数据流为：

    fetch -> instruction_buffer -> decode -> rename
          -> dispatch -> issue -> operand_read -> execute
          -> completion -> writeback -> ROB/PRF -> commit

控制流为：

    branch_unit -> recovery_controller -> frontend/rename/queues/ROB/LSQ
    ROB head exception -> commit_unit -> CSR/recovery_controller

所有跨子系统的控制事件必须先在产生侧寄存。顶层只扇出已寄存的 recovery event。

## 4. 周期行为

- 正常周期：各相邻级独立握手，顶层不计算全局 enable。
- 分支误预测：EX 周期产生结果，下一周期 recovery_controller 广播 kill 和 redirect。
- 精确异常：CM 观察到 head 异常，随后进入多周期恢复；恢复结束后前端重新启动。
- 中断：仅在安全提交边界采样，转换成与异常相同的提交侧恢复事务。

## 5. 顶层约束

- 不允许以一个组合表达式汇总所有 queue_full 后直接控制 Fetch。
- 高频广播信号只允许 recovery、两个 WB tag 和时钟复位；必要时在区域边界复制寄存器。
- commit_trace 必须来自提交寄存器，不能从 ROB 阵列长路径组合导出。

## 6. 性能计数

至少汇总 cycle、instret、decode_count、issue_count、commit_count、ROB full、
各 IQ full、PRF bank conflict、WB conflict、load wait store、branch mispredict。
计数器不参与功能控制，可通过 generate 参数关闭。
