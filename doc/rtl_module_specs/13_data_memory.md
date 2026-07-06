# 四 Bank Data RAM 设计

建议模块名：data_memory_banks。

当前 SoC V1 wrapper 为 `rtl/soc/soc_data_ram.sv`。该模块直接对接
`soc_addr_router` 的 typed RAM 端口：`load_mem_req_t`、`load_mem_resp_t` 和
`store_mem_req_t`。V1 先实现为 32-bit word RAM，load 请求打一拍返回并带 response
holding，store 按 `byte_enable` 更新已对齐 word。首次 5 ns OOC WNS 为 `+0.955 ns`，
但 Vivado 报告显示推断为 distributed RAM，不满足 256 KiB 主存资源目标；当前已在
memory array 增加 `ram_style="block"`，并把写路径改为显式 byte-lane write enable，
等待复综合确认 RAMB 推断。`tb_soc_data_ram` 已覆盖初始化写入、load response 反压保持、
byte store、并行 load/store、窗口外 load error 和初始化写 error。

## 1. 组织

总容量 256 KB，按 32-bit word 低位交错为四个 Bank：

    word_addr = byte_addr[17:2]
    bank_id   = word_addr[1:0]
    bank_row  = word_addr[15:2]

每 Bank 16K×32-bit，优先推断或实例化 True Dual Port BRAM。

## 2. 端口

| 方向 | 端口 | 位宽 | 说明 |
|---|---|---:|---|
| input | load_valid_i | 1 | Load read |
| output | load_ready_o | 1 | 读端口可接收 |
| input | load_addr_i | 32 | 字节地址 |
| input | load_tag_i | typed | lq_id/rob_id/size |
| output | load_resp_valid_o | 1 | 固定延迟返回 |
| output | load_resp_data_o | 32 | 原始 word |
| output | load_resp_tag_o | typed | 对齐请求 tag |
| input | store_valid_i | 1 | 已提交 Store |
| output | store_ready_o | 1 | 写端口可接收 |
| input | store_addr_i | 32 | 字节地址 |
| input | store_data_i | 32 | 已对齐写数据 |
| input | store_be_i | 4 | byte enable |

## 3. 时序

请求周期寄存 bank_id、bank_row 和 tag。下一周期 BRAM 同步读，启用输出寄存器时再加
一拍。返回 mux 只在四个 Bank 已寄存输出之间选择，选择信号与请求同步流水。

固定读延迟通过参数 READ_LATENCY 明确，LSU 不得猜测 IP 配置。建议 V1 设为 2 个
memory 周期，并由 L3 进行 load 数据提取。

## 4. Load/Store 并行

Port A 只读 Load，Port B 只写已提交 Store，因此不同或相同 Bank 均可并行。若器件对
同地址 read-during-write 行为不确定，LSQ 应对同地址已提交 Store 做转发或延迟 Load，
不能依赖厂商未固定的返回语义。

## 5. 初始化与地址空间

DRAM 初始化文件和 MMIO 地址译码放在本模块外层。RAM 只接收合法本地地址；MMIO 由
独立串行通路处理，并标记为 serializing。

## 6. 物理约束

四个 Bank 使用层次保留和区域约束，使 LSU 靠近 BRAM 列。bank select、row address、
write enable 必须先寄存，禁止从 ROB/SQ 多路选择直接驱动 BRAM EN/WE。

## 7. 断言

- 请求地址位于 RAM 范围且已按 word 请求规范处理。
- store_be 非零。
- 每个 load request 恰好产生一次带相同 tag 的 response。
- reset/recovery 不取消已经接收的物理读；返回由 epoch/tag 在 LSU 侧丢弃。
