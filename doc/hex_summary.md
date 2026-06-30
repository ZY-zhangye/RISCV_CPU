# hex 文件夹 — 指令存储器初始化文件

更新时间：2026-06-28
路径：`hex/`

**本文件夹用于为 CPU 仿真提供指令存储器（IMEM）和数据存储器（DMEM）的初始内容。** 所有 .hex 和 .mif 文件均采用 32-bit 小端序每行一条指令/数据字的格式。

---

## 顶层文件

| 文件 | 用途 | 说明 |
|------|------|------|
| `inst.hex` | 主指令存储器初始内容 | 当前为 LED 测试程序（点灯循环），地址 0x0000_0000 开始 |
| `inst_ram.hex` | 含手工填充/辅助数据 | 部分指令字中间插有占位数据（0x22222222），供特定调试用 |
| `data_ram.hex` | 数据存储器初始内容 | 存储 ASCII 字符串 "UART Interrupt!\n" 等初始化数据 |
| `led_test.hex` | LED 点灯专用测试 | 与 `inst.hex` 类似但不完全相同，绑定了 GPIO 外设地址 |
| `timer.hex` | 定时器中断测试 | 含 mtvec/mstatus/MIE 配置，用于验证机器定时器中断路径 |
| `uart.hex` | UART 收发测试 | 含 UART 地址映射和中断使能，用于验证串口通信 |

---

## riscv-tests/ — RISC-V 架构验证套件

源自 [riscv-tests](https://github.com/riscv-software-src/riscv-tests) 官方仓库，编译为 RV32 二进制后转换为 HEX 格式，逐行验证乘法、异常、 CSR、浮点和处理器的非法指令检测。

### 测试集分组

#### rv32ui — 用户级整数指令

每组覆盖一条基础整数指令，包含功能测试和边界值：

`add`、`addi`、`and`、`andi`、`auipc`、`beq`、`bge`、`bgeu`、`blt`、`bltu`、`bne`、`fence_i`、`jal`、`jalr`、`lb`、`lbu`、`lh`、`lhu`、`lui`、`lw`、`ori`、`sll`、`slli`、`slt`、`slti`、`sltiu`、`sltu`、`sra`、`srai`、`srl`、`srli`、`sub`、`sw`、`xor`、`xori`

共 **36 个文件**（`rv32ui-p-*.hex`）。

#### rv32mi — 机器级指令

| 文件 | 测试内容 |
|------|---------|
| `breakpoint` | ebreak 断点异常 |
| `csr` | 基础 CSR 读写 |
| `illegal` | 非法指令触发 illegal-instruction 异常 |
| `instret_overflow` | instret CSR 溢出行为 |
| `lh-misaligned` | 半字非对齐 load |
| `lw-misaligned` | 字非对齐 load |
| `ma_addr` | 访存地址异常 |
| `ma_fetch` | 取指地址异常 |
| `mcsr` | M-mode CSR 全部字段 |
| `pmpaddr` | PMP 地址寄存器（无实际保护时读回零） |
| `sbreak` | ebreak 在 S-mode（同 M-mode 行为） |
| `scall` | ecall 在 M-mode |
| `sh-misaligned` | 半字非对齐 store |
| `shamt` | 移位量 5-bit 截断检查 |
| `sw-misaligned` | 字非对齐 store |
| `zicntr` | cycle/instret 计数器读取 |

#### rv32si — S-mode 指令

| 文件 | 测试内容 |
|------|---------|
| `csr` | S-mode CSR 读写（未实现特权时触发异常） |
| `dirty` | S-mode dirty 位行为 |
| `ma_fetch` | S-mode 取指异常 |
| `sbreak` | S-mode ebreak |
| `scall` | S-mode ecall |
| `wfi` | WFI 指令（当前无实现，NOP） |

#### rv32ua — 原子操作

A 扩展指令：`amoadd_w`、`amoand_w`、`amomax_w`、`amomaxu_w`、`amomin_w`、`amominu_w`、`amoor_w`、`amoswap_w`、`amoxor_w`、`lrsc`。每个测试有 **物理 (`-p-`)** 和 **虚拟 (`-v-`)** 两个版本。

**注意**：本处理器未实现 A 扩展，原子指令会被译码为非法指令。

#### rv32uc — 压缩指令

`rvc` — RV32C 压缩指令集测试。物理和虚拟两个版本。

**注意**：本处理器为 RV32 无 C 扩展，压缩指令会被译码为非法。

#### rv32uf/rv32ud — 单精度/双精度浮点

| 分组 | 指令 |
|:----:|------|
| `fadd` | 浮点加减 |
| `fclass` | 浮点分类 |
| `fcmp` | 浮点比较 |
| `fcvt` | 浮点转换 |
| `fcvt_w` | 浮点与整数互转 |
| `fdiv` | 浮点除法 |
| `fmadd` | 融合乘加 |
| `fmin` | 最小/最大值 |
| `ldst` | 浮点加载/存储 |
| `move` | 浮点寄存器移动 |
| `recoding` | 浮点编码格式 |

**注意**：本处理器未实现 F/D 扩展，浮点指令会被译码为非法。

### 辅助文件

| 文件 | 用途 |
|------|------|
| `index.csv` | 每个测试的基地址、结束地址、字节大小和合并后 hex 文件路径 |
| `convert_endian.c` | 将 32-bit 大端序 hex 文件转换为小端序的工具。编译运行后扫描当前目录下所有 `.hex` 文件并原地转换 |
| `irom.hex` | 整合后的指令 ROM 初始化文件 |
| `rv32-p-riscv.hex` | 部分已编译测试的合并文件 |

---

## 文件格式说明

每行一条 32-bit 数据，小端十六进制（文本格式）：

```
60001137        // 实际指令值：0x60001137 → lui sp, 0x60001
80010113        // 0x80010113 → addi sp, sp, -2048
```

仿真器在启动时将各行顺序写入模拟存储器的连续字地址。`mif` 文件使用 Quartus MIF 格式（分地址/数据列），主要用于 RTL 仿真工具的系统级初始化。

---

## 使用说明

在仿真验证中，通过选择不同的 .hex 文件作为 IMEM 初始化内容，可以运行不同的测试用例：

1. 冒烟测试：`inst.hex` 或 `led_test.hex`
2. 逐指令验证：`riscv-tests/rv32ui-p-*.hex`
3. CSR/异常验证：`riscv-tests/rv32mi-p-*.hex`
4. 中断验证：`timer.hex`

index.csv 记录了每个测试的**期望结束地址**和**字节大小**，验证平台读取该文件可自动判断测试通过条件（到达结束地址后检查 tohost/gp 值）。
