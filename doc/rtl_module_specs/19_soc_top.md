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

- 接收板级 clock/reset，并在外部 reset 释放后生成一段内部上电计数复位。
- 实例化 `core_top`。
- 实例化 instruction ROM/RAM wrapper。
- 实例化 data RAM wrapper。
- 实例化简单地址路由器 `soc_addr_router`。
- 接入 JYD2025 板级 SW/KEY/SEG/LED/CNT 本地 MMIO 外设。
- 预留外部 MMIO 透传端口和中断汇总。
- 后续按地址窗口接入 UART、GPIO、Timer、CLINT-like software interrupt 等外设。

JYD2025 Vivado 工程侧使用 `rtl/soc/my_cpu.sv` 作为板级包装层。`my_cpu` 保持参考工程
端口签名：`clk`、`clk_cnt`、低有效 `rst_n`、`led[31:0]`、`key[7:0]`、
`sw[63:0]`、`seg[39:0]`。

### 1.3 外设模块

外设模块不直接连接 CPU LSU。所有外设访问先进入 `soc_addr_router`，由地址窗口选择
目标外设。外设可逐步增加，不要求一次完成。

### 1.4 Reset

`soc_top` 的外部 `rst_i` 为高有效同步 reset。内部增加参数化上电计数复位：

- 参数：`POWER_ON_RESET_CYCLES`，默认 `64`。
- 内部 reset：`soc_rst = rst_i || !power_on_reset_done_q`。
- 每次 `rst_i` 拉高都会清零计数器；`rst_i` 释放后，SoC 继续保持 reset
  `POWER_ON_RESET_CYCLES` 个 `clk_i` 周期。
- FPGA 上电配置后，计数器初值为 0，确保即使板级临时没有独立 reset 按键，也会自动
  产生一段内部复位窗口。

后续板级 wrapper 接差分时钟和 PLL 时，建议将 PLL `locked` 同步/取反后送入 `rst_i`，
并保留该计数复位作为二级保护。若后续引出实体 reset 按键，也接入同一路 `rst_i`。

## 2. 建议地址空间

V1 采用固定地址窗口和简单高位译码。地址未命中返回 bus error，后续由 LSU/commit
转换为 load/store access fault。

| 地址范围 | 大小 | 目标 | 说明 |
|---|---:|---|---|
| `0x8000_0000` - `0x800F_FFFF` | 1 MiB | IROM reserved | 指令空间保留窗口 |
| `0x8000_0000` - `0x8000_3FFF` | 16 KiB | IROM active | Vivado IP/XPM，只读 |
| `0x8000_4000` - `0x800F_FFFF` | 1008 KiB | IROM extension | 留空待扩展 |
| `0x8010_0000` - `0x801F_FFFF` | 1 MiB | DRAM reserved | 数据空间保留窗口 |
| `0x8010_0000` - `0x8013_FFFF` | 256 KiB | DRAM active | Vivado IP/BRAM，读写 |
| `0x8014_0000` - `0x801F_FFFF` | 768 KiB | DRAM extension | 留空待扩展 |
| `0x8020_0000` - `0x8020_00FF` | 256 B | MMIO | JYD2025 板级外设 |

当前 fetch reset PC 仍使用 `RESET_PC=0x8000_0000`。`soc_imem` 只响应 IROM active
窗口内的 128-bit instruction block 读取。官方仿真回归为了兼容既有 riscv-tests 链接
地址，会在 testbench 中覆盖 IROM/DRAM base；Vivado 综合使用默认地址图。

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

2026-07-09 post-route timing fix 后，RAM store 侧不再从 core store request 组合直通
`soc_data_ram`。`soc_addr_router` 内部增加 1-entry RAM store 输出寄存器：

- core 侧 Store 命中 RAM 且寄存器空时可先被 router 接收；
- `ram_store_req_o.valid/address/data/byte_enable` 只由本地寄存器驱动；
- RAM store pending 时，router 暂停接收 RAM/MMIO/bad load，避免已提交 Store
  被上游认为完成后一拍内 younger Load 读到旧值；
- 同拍 RAM store capture 不参与 load ready 组合门控，避免当前 core store address
  经地址译码重新进入 Data RAM enable 路径；
- `soc_data_ram` 的 RAM read enable 仅由 load valid/ready 控制，不再被 load address
  range compare 门控；地址错误仍在 response metadata 中记录，但不让地址比较结果进入
  BRAM enable；
- `soc_data_ram` 增加 `TRUST_ROUTED_ADDR` 参数；standalone 默认继续用本地 range
  check 阻止越界 Store 写 RAM，`soc_top` 和 router+data_ram OOC wrapper 置为 1，
  由 `soc_addr_router` 保证 RAM Store 已命中窗口，避免 Data RAM 再把 range compare
  接到 BRAM write enable；
- 该边界用于切断 commit/recovery/LSU store valid 经过地址译码和 byte-lane 选择直达
  Data RAM BRAM write-enable 的长路径，同时切断 load address range compare 直达
  Data RAM BRAM read-enable 的长路径。

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
RAM Store 通过 router 内部 1-entry 寄存器输出到 data RAM，用一拍吞吐代价换取 RAM
write-enable 的本地寄存边界。

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
| input | `sw_i` | 64 | 板级开关输入 |
| input | `key_i` | 8 | 板级按键输入 |
| output | `led_o` | 32 | 板级 LED 输出 |
| output | `seg_o` | 40 | 板级 7 段数码管输出 |

当前 `soc_periph_decode` 解码 `0x8020_0000` - `0x8020_00FF` 本地外设：
SW 只读、KEY 只读、SEG 读写、LED 只写、CNT 读写控制。未命中本地 MMIO window 的访问
继续通过外部轻量 peripheral bus 透出；命中本地 window 但偏移未定义的访问返回错误。
CNT 默认按 50,000 个 `clk_cnt_i` 周期累加一次，停止命令同步到计数时钟域后保持最终
读数。

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
   每个 lane RAM 保持单写口/同步读模板。`tb_soc_data_ram` 通过，5 ns OOC WNS
   `+1.029 ns`，Vivado 推断 64 个 BRAM，冻结。
5. 新建 `soc_top`，连接 core、IROM/Data RAM/router 和空外设接口。已完成
   `rtl/soc/soc_top.sv`：实例化 `core_top`、`soc_imem`、`soc_addr_router` 和
   `soc_data_ram`，MMIO peripheral bus 经过 `soc_periph_decode` 后再暴露到顶层以便
   后续外设扩展。
   `tb_soc_top` smoke 已通过，覆盖 IMem 初始化、core 取指、INT/MUL/DIV 写回和顶层
   interrupt/error 预留线。全系统 load/store 指令 smoke 后续再加；当前 RAM/router
   load/store 行为由各自 directed test 覆盖。
6. 更新 `soc_periph_decode` 为 JYD2025 外设表：`SW_LOW/SW_HIGH/KEY/SEG/LED/CNT`
   均要求 4 字节对齐；SW/KEY 只读，LED 只写，SEG/CNT 读写。`clk_cnt_i` 用于数码管
   扫描和计数器域。
7. 为 `soc_top` 增加 smoke test：从 memory 启动，执行普通 ALU/MUL/DIV/load/store，
   观察写回和 store side effect。
8. 后续逐个接入 UART、GPIO、Timer，每接一个外设先做 Questa directed test，再做
   5 ns OOC。

## 8. 时序原则

- 地址译码结果必须寄存后再驱动大 fanout 外设选择。
- Data RAM bank select、row、byte enable 进入 BRAM 前保持寄存边界。
- MMIO 通道可以牺牲吞吐，优先使用单在途状态机降低时序风险。
- 不允许外设 ready 组合回 fetch 或全局 pipeline 控制。
- 未使用外设端口必须给出确定 ready/response 默认值，避免 X 传播。

## 9. 验证要求

当前基线：

- 官方支持回归：QuestaSim `51/51 PASS`。
- JYD2025 COE smoke：`tb_soc_withmext_coe` 运行 20000 cycle PASS。
- COE 期望输出：`LED = 0x0002_0001`，SEG MMIO 原始 32 位寄存器值为 `0x3780_0000`。
- `seg_o[39:0]` 是物理扫描输出，10 位 SEG 每 5 位一组轮换，波形中允许出现两个扫描相位。

- RAM load/store 地址命中测试。
- MMIO read/write 地址命中测试。
- SW/KEY/SEG/LED/CNT 外设访问权限和对齐错误测试。
- 非法地址 load 返回 `error=1`。
- Store 只在 commit 后进入 router。
- 外设 backpressure 下 payload 保持稳定。
- reset 后所有 request valid 清零。
- 后续 interrupt 外设接入后，验证 timer/software/ext irq 能被 CSR 提交边界采样。
