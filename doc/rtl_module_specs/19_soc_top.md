# SoC 顶层设计大纲

建议模块名：`soc_top`。本文件定义 CPU core 之外的 SoC wrapper 边界，用于后续集成
片上存储器、地址路由和外设。V1 目标是保持结构简单、时序可控、接口可扩展，不在
SoC wrapper 内引入复杂总线协议。

## 1. 分层职责

### 1.1 core_top

`core_top` 只封装 CPU 前端、后端和 CSR/interrupt 入口：

- 内部实例化当前已冻结的 `frontend_backend_cluster`。
- 对外暴露 instruction memory 请求/响应接口。
- 对外暴露 typed load/store memory 请求/响应接口。
- 接收 `ext_irq_i/timer_irq_i/software_irq_i`，后续接入 CSR interrupt pending。
- 不包含 RAM、外设寄存器、UART/GPIO 等平台逻辑。

### 1.2 soc_top

`soc_top` 是 FPGA/板级可综合顶层：

- 实例化 `core_top`。
- 实例化 instruction ROM/RAM wrapper。
- 实例化 data RAM wrapper。
- 实例化简单地址路由器 `soc_addr_router`。
- 预留 MMIO 外设端口和中断汇总。
- 后续按地址窗口接入 UART、GPIO、Timer、CLINT-like software interrupt 等外设。

### 1.3 外设模块

外设模块不直接连接 CPU LSU。所有外设访问先进入 `soc_addr_router`，由地址窗口选择
目标外设。外设可逐步增加，不要求一次完成。

## 2. 建议地址空间

V1 采用固定地址窗口和简单高位译码。地址未命中返回 bus error，后续由 LSU/commit
转换为 load/store access fault。

| 地址范围 | 大小 | 目标 | 说明 |
|---|---:|---|---|
| `0x0000_0000` - `0x0000_FFFF` | 64 KiB | Boot ROM / IROM alias | 可选启动 ROM |
| `0x1000_0000` - `0x1000_0FFF` | 4 KiB | UART0 | 后续预留 |
| `0x1000_1000` - `0x1000_1FFF` | 4 KiB | GPIO0 | 后续预留 |
| `0x1000_2000` - `0x1000_2FFF` | 4 KiB | Timer/mtime/mtimecmp | 后续预留 |
| `0x1000_3000` - `0x1000_3FFF` | 4 KiB | Software IRQ / scratch | 后续预留 |
| `0x8000_0000` - `0x8003_FFFF` | 256 KiB | Data RAM / instruction RAM | 主存窗口 |

当前 fetch reset PC 仍使用 `RESET_PC`。若 reset PC 位于 `0x8000_0000`，IROM wrapper
从主存窗口取 128-bit instruction block；若后续需要 boot ROM，则通过参数选择
`RESET_PC=0x0000_0000`。

## 3. Core 侧接口

`core_top` 继续使用现有 typed/request 接口，不把 SoC 外设细节泄漏到 CPU 内部。

### 3.1 Instruction memory

| 方向 | 端口 | 说明 |
|---|---|---|
| output | `imem_req_valid_o` | 取 128-bit instruction block |
| output | `imem_req_addr_o[31:0]` | 16-byte 对齐地址 |
| input | `imem_resp_valid_i` | 固定或可变延迟响应 |
| input | `imem_resp_data_i[127:0]` | 四条 32-bit 指令 |

V1 可先只支持主存/IROM 命中；取指访问 MMIO 或非法地址时，后续补
instruction access fault 流程。

### 3.2 Data memory

沿用 `core_types_pkg.sv` 中的结构：

- `load_mem_req_t`
- `load_mem_resp_t`
- `store_mem_req_t`

Load 请求必须最终返回一次 response。Store 请求已经位于 commit side，因此一旦
`ready` 接收就可以产生外设 side effect。

## 4. SoC 地址路由

建议模块名：`soc_addr_router`。

当前状态：`rtl/soc/soc_addr_router.sv` 已完成 V1 RTL。实现保持 typed
load/store core 边界，内部使用单在途 MMIO 请求寄存器；core 侧请求被 router 接收后，
即使外设 `ready=0`，`periph_req_*` payload 也由寄存器保持稳定。MMIO 同周期 load/store
冲突固定为 store 优先。Questa directed test `tb_soc_addr_router` 已覆盖 RAM 透传、
MMIO read/write、外设反压保持、非法地址 error/sticky 以及 reset 清理。5.000 ns
OOC WNS 为 `+1.828 ns`，时序健康并冻结。

### 4.1 Load 路由

输入：`load_mem_req_t core_load_req_i`。

输出：

- 到 data RAM 的 load request。
- 到 MMIO peripheral bus 的 read request。
- 回 core 的 `load_mem_resp_t`。

规则：

1. 地址命中 RAM 窗口：转发给 `data_memory_banks`。
2. 地址命中 MMIO 窗口：转发给 peripheral read channel。
3. 地址未命中：返回 `error=1`，`data=0`，保留原 `lq_id`。

V1 注意事项：当前 LSU 尚未显式标记 MMIO load 为 serializing。接入有读副作用外设前，
必须补充 MMIO 属性识别或 serializing load 机制。没有读副作用的状态寄存器可先作为
调试窗口使用。

### 4.2 Store 路由

输入：`store_mem_req_t core_store_req_i`。

规则：

1. 地址命中 RAM 窗口：转发给 `data_memory_banks` store port。
2. 地址命中 MMIO 窗口：转发给 peripheral write channel。
3. 地址未命中：V1 可丢弃并记录 sticky bus error；后续扩展为 store access fault。

Store 来自 ROB-head commit buffer，天然满足“提交后才产生外设 side effect”。

### 4.3 RAM 与 MMIO 仲裁

RAM load/store 可并行。MMIO V1 采用单在途串行通道：

- 同一周期 load 与 store 同时命中 MMIO 时，store 优先或 load 优先必须固定，建议
  store 优先。
- MMIO request valid 且 ready 为 0 时，router 保持 payload 稳定。
- MMIO response 返回后再接受下一笔 MMIO load。

## 5. 预留外设总线

建议先定义内部轻量 peripheral bus，不引入 AXI/Wishbone。

| 方向 | 端口 | 位宽 | 说明 |
|---|---|---:|---|
| output | `periph_req_valid_o` | 1 | 外设访问请求 |
| input | `periph_req_ready_i` | 1 | 外设接收 |
| output | `periph_req_write_o` | 1 | 1=write，0=read |
| output | `periph_req_addr_o` | 32 | 全局字节地址 |
| output | `periph_req_wdata_o` | 32 | 写数据 |
| output | `periph_req_wstrb_o` | 4 | byte enable |
| input | `periph_resp_valid_i` | 1 | read 或 write ack |
| input | `periph_resp_rdata_i` | 32 | read data |
| input | `periph_resp_error_i` | 1 | 外设错误 |

后续若外设数量增加，可在 SoC 内部增加 `periph_decode`，把该总线拆成
`uart0/gpio0/timer/software_irq` 等子端口。

## 6. 中断预留

SoC 级中断汇总后接入 `core_top`：

- `timer_irq_o`：来自 timer/mtimecmp。
- `software_irq_o`：来自 software interrupt register。
- `ext_irq_o`：UART/GPIO 或外部 pin OR 后的机器外部中断。

外设中断 pending/enable 寄存器放在外设或 interrupt controller 内，CPU CSR 只观察
最终 interrupt lines。

## 7. 实现顺序

1. 新建 `core_top`，只包 `frontend_backend_cluster`，保持现有 directed test 通过。
   已完成。
2. 新建 `soc_addr_router`，支持 RAM 命中、非法地址 error、单在途 MMIO read/write 和
   外设反压 payload 保持。已完成 Questa directed test 与 5 ns OOC，冻结。
3. 新建 instruction memory wrapper，支持 128-bit block read。已完成 `soc_imem` V1：
   128-bit block 同步读、后一拍响应、仿真/测试 block 写入口和非法取指窗口 error
   预留；`tb_soc_imem` 通过，5 ns OOC WNS `+2.380 ns`，冻结。
4. 新建 data RAM wrapper，对接 `load_mem_req_t/store_mem_req_t/load_mem_resp_t`。已完成
   `soc_data_ram` V1：4 个 8-bit byte-lane RAM array、load 一拍响应与 holding、
   store/init 仲裁后的单一 lane 写入口，且不在 BRAM 输出寄存器前做同拍写直通；
   `tb_soc_data_ram` 通过，5 ns OOC WNS `+2.747 ns`，Vivado 推断 64 个 BRAM，冻结。
5. 新建 `soc_top`，连接 core、IROM/Data RAM/router 和空外设接口。已完成
   `rtl/soc/soc_top.sv`：实例化 `core_top`、`soc_imem`、`soc_addr_router` 和
   `soc_data_ram`，MMIO peripheral bus 直接暴露到顶层以便后续外设 decode。
   `tb_soc_top` smoke 已通过，覆盖 IMem 初始化、core 取指、INT/MUL/DIV 写回和顶层
   interrupt/error 预留线。全系统 load/store 指令 smoke 后续再加；当前 RAM/router
   load/store 行为由各自 directed test 覆盖。
6. 为 `soc_top` 增加 smoke test：从 memory 启动，执行普通 ALU/MUL/DIV/load/store，
   观察写回和 store side effect。
7. 后续逐个接入 UART、GPIO、Timer，每接一个外设先做 Questa directed test，再做
   5 ns OOC。

## 8. 时序原则

- 地址译码结果必须寄存后再驱动大 fanout 外设选择。
- Data RAM bank select、row、byte enable 进入 BRAM 前保持寄存边界。
- MMIO 通道可以牺牲吞吐，优先使用单在途状态机降低时序风险。
- 不允许外设 ready 组合回 fetch 或全局 pipeline 控制。
- 未使用外设端口必须给出确定 ready/response 默认值，避免 X 传播。

## 9. 验证要求

- RAM load/store 地址命中测试。
- MMIO read/write 地址命中测试。
- 非法地址 load 返回 `error=1`。
- Store 只在 commit 后进入 router。
- 外设 backpressure 下 payload 保持稳定。
- reset 后所有 request valid 清零。
- 后续 interrupt 外设接入后，验证 timer/software/ext irq 能被 CSR 提交边界采样。
