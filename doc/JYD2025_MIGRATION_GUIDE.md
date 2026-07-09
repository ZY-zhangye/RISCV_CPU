# JYD2025 Vivado 移植指南

本文记录当前 OOO RV32 SoC 适配 `C:\Users\ZY\Desktop\JYD2025_Contest-rv32i` 板级工程时需要使用的顶层、地址图和集成注意事项。

## 顶层选择

Vivado 板级工程建议继续使用原工程的 `top.sv`、时钟、按键、开关、LED、数码管约束和虚拟外设连接方式。本仓库提供兼容包装层：

- `rtl/soc/my_cpu.sv`
- 模块名：`my_cpu`
- 端口：

```systemverilog
module my_cpu (
    input  logic        clk,
    input  logic        clk_cnt,
    input  logic        rst_n,
    output logic [31:0] led,
    input  logic [7:0]  key,
    input  logic [63:0] sw,
    output logic [39:0] seg
);
```

该端口签名与参考工程 `rtl/my_cpu.sv` 保持一致。参考工程中的 `top.sv` 可以继续实例化 `my_cpu`，只需要把本仓库 RTL 加入 Vivado sources，并确保 `rtl/soc/my_cpu.sv` 被选为 CPU 包装层。

## 必需 RTL 文件

Vivado 综合至少加入以下 RTL：

- `rtl/core_types_pkg.sv`
- `rtl/decode/decode_pkg.sv`
- `rtl/fetch/*.sv`
- `rtl/decode/decode_stage.sv`
- `rtl/rename/*.sv`
- `rtl/commit/*.sv`
- `rtl/prf/*.sv`
- `rtl/dispatch/*.sv`
- `rtl/issue/*.sv`
- `rtl/execution/*.sv`
- `rtl/lsu/*.sv`
- `rtl/writeback/*.sv`
- `rtl/backend/*.sv`
- `rtl/core_top.sv`
- `rtl/soc/soc_addr_router.sv`
- `rtl/soc/soc_imem.sv`
- `rtl/soc/soc_data_ram.sv`
- `rtl/soc/soc_periph_decode.sv`
- `rtl/soc/soc_top.sv`
- `rtl/soc/my_cpu.sv`

如果 Vivado 工程使用 XPM，需要启用 Xilinx XPM 库。`soc_imem` 在 `SYNTHESIS` 下使用 `xpm_memory_sdpram` 推断 16KB IROM。

## 最终地址图

| 区域 | 地址范围 | 属性 |
| --- | --- | --- |
| IROM 保留 | `0x8000_0000` - `0x800F_FFFF` | 预留 1MB |
| IROM 有效 | `0x8000_0000` - `0x8000_3FFF` | 16KB，只读，Vivado IP/XPM |
| IROM 扩展 | `0x8000_4000` - `0x800F_FFFF` | 留空 |
| DRAM 保留 | `0x8010_0000` - `0x801F_FFFF` | 预留 1MB |
| DRAM 有效 | `0x8010_0000` - `0x8013_FFFF` | 256KB，读写 |
| DRAM 扩展 | `0x8014_0000` - `0x801F_FFFF` | 留空 |
| MMIO | `0x8020_0000` - `0x8020_00FF` | 板级外设 |

`soc_top` 默认参数已经按该地址图设置：

```systemverilog
IROM_BASE  = 32'h8000_0000
IROM_BYTES = 16384
RAM_BASE   = 32'h8010_0000
RAM_BYTES  = 262144
MMIO_BASE  = 32'h8020_0000
MMIO_BYTES = 256
```

## 外设寄存器

所有本地外设访问都要求 4 字节对齐。写 32 位寄存器时 `wstrb` 必须为 `4'b1111`，否则返回错误。

| 地址 | 名称 | 访问 | 行为 |
| --- | --- | --- | --- |
| `0x8020_0000` | SW_LOW | 只读 | 返回 `sw[31:0]` |
| `0x8020_0004` | SW_HIGH | 只读 | 返回 `sw[63:32]` |
| `0x8020_0010` | KEY | 只读 | 返回 `{24'b0, key[7:0]}` |
| `0x8020_0020` | SEG | 读写 | 32 位数码管显示数据 |
| `0x8020_0040` | LED | 只写 | 32 位 LED 显示数据 |
| `0x8020_0050` | CNT | 读写 | 读计数值；写 `0x8000_0000` 开始计数；写 `0xFFFF_FFFF` 停止计数 |

非法访问规则：

- SW/KEY 写访问返回错误。
- LED 读访问返回错误。
- 未定义 MMIO 地址返回错误。
- 非 4 字节对齐访问返回错误。
- 对本地 32 位写寄存器的非全字写返回错误。

CNT 默认每 50,000 个 `clk_cnt` 周期累加一次，匹配 50MHz 计数时钟下的 1ms 粒度。
停止命令经过 CDC 同步后生效，停止后读数保持最终值。

## IROM/DRAM 说明

当前 `soc_imem` 综合路径使用 XPM 同步双口 RAM，接口保持内部取指端口和初始化写端口。未来若替换为 Vivado Block Memory Generator IP，需要保持以下语义：

- IROM 基地址为 `0x8000_0000`。
- 有效容量为 16KB。
- CPU 取指读宽为 128 bit，地址按 16 字节块对齐。
- CPU 运行时不写 IROM。

`soc_data_ram` 当前是字节 lane BRAM 形式，默认基地址为 `0x8010_0000`，容量 256KB。未来若替换为 Vivado IP，需要保持：

- 支持 32 位读写数据。
- 支持字节写使能。
- 支持非对齐 load/store 由现有 LSU 和 RAM wrapper 的字节窗口语义处理。

## 仿真兼容

官方 riscv-tests 和自定义指令测试仍使用 `0x8000_0000` 链接镜像。相关 testbench 显式覆盖：

```systemverilog
.IROM_BASE(IMAGE_BASE),
.IROM_BYTES(RAM_BYTES),
.RAM_BASE(IMAGE_BASE),
.RAM_BYTES(RAM_BYTES)
```

这是为了保留既有 `51/51 PASS` 回归基线。Vivado 板级综合不要使用这些测试覆盖参数，直接使用 `soc_top` 和 `my_cpu` 的默认地址图。

## 当前验证基线

QuestaSim 2024.1：

- 官方支持回归：`51/51 PASS`。
- JYD2025 COE smoke：

```powershell
vlog -sv -work questa_coe_work -f test\soc_withmext_coe.f
vsim -c -voptargs="+acc" -lib questa_coe_work tb_soc_withmext_coe -do "run -all; quit -f"
```

当前期望结果：

- `PASS: withmext COE boot smoke cycles=20000`
- `LED = 0x0002_0001`
- MMIO SEG 原始 32 位显示数据：`0x3780_0000`

`seg_o[39:0]` 是译码和扫描后的物理数码管输出，10 位 SEG 每 5 位一组轮换，因此波形中
会看到两个扫描相位。判断程序结果时优先看 `soc_periph_decode.seg_data_q` 或 SEG MMIO
寄存器读回值，而不是只看单一时刻的 `seg_o`。

## 接入步骤

1. 在 Vivado 工程中移除参考工程原来的占位 `rtl/my_cpu.sv`，或确保本仓库 `rtl/soc/my_cpu.sv` 的 `my_cpu` 定义唯一。
2. 按“必需 RTL 文件”加入本仓库 RTL，保持 package 文件先编译。
3. 保留参考工程 `top.sv` 中对 `my_cpu` 的实例化和板级端口连接。
4. 确认复位极性：板级 `rst_n` 为低有效，`my_cpu` 内部转换为 `soc_top.rst_i = !rst_n`。
5. 确认 `clk` 驱动 CPU/SoC，`clk_cnt` 驱动数码管扫描和计数器域。
6. 综合前检查程序链接地址：取指入口应位于 `0x8000_0000`，数据段应落在 `0x8010_0000` 起始的 DRAM 有效区。

## 后续可扩展点

- `0x8000_4000` - `0x800F_FFFF` 可扩展 IROM。
- `0x8014_0000` - `0x801F_FFFF` 可扩展 DRAM。
- `0x8020_0000` - `0x8020_00FF` 已按当前外设表定义；新增外设前应先确认是否扩展 MMIO window 或复用保留偏移。
