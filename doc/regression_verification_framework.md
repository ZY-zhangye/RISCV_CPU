# 回归验证框架

> 基于 `riscv-cpu-refactored` 工程，整理时间 2026-06-30

---

## 1. 概述

回归验证框架使用 **ModelSim (vsim)** 作为仿真器，通过 `run_all.bat` 批处理脚本驱动全量回归测试。测试平台为顶层 SoC 级 `tb_my_cpu`，加载 RISC-V 指令测试 hex 镜像，检查程序退出码判定通过/失败。

---

## 2. 测试平台：`tb_my_cpu`

### 2.1 结构

文件：`test/tb_my_cpu.sv`

```
clk_gen ─┐
clk_uart ─┤
rst_n    ─┤
         │  ┌──────────────┐
         └──┤   my_cpu     │
            │  (SoC 顶层)   │
            └──────────────┘
```

- 实例化 `my_cpu`（SoC 顶层），包含 CPU 核心、片上 RAM、UART、Timer、PLIC、LED
- 需 `DEBUG_EN` 宏开启内部 debug RAM 和写回观察端口

### 2.2 初始化流程

```systemverilog
// 加载 hex 到指令 RAM 和数据 RAM
$readmemh(MEM_ADDR, u_my_cpu.u_inst_ram.mem);
$readmemh(MEM_ADDR, u_my_cpu.u_data_ram.mem);
```

- 测试镜像文件路径：`hex/riscv-tests/rv32-p-riscv.hex`
- 指令 RAM 和数据 RAM **加载同一镜像**
- 不开启 `DEBUG_EN` 时直接 `$fatal` 退出

### 2.3 通过条件

```systemverilog
// 检测写回 PC == 0x8000_0044 作为程序终止标志
if (rst_n && (debug_wb_pc == 32'h8000_0044)) begin
    if (debug_data == 32'h0000_0001) begin
        $display("Test passed.");
    end else begin
        $display("Test failed. Expected 1 in x10, got %08h", debug_data);
    end
    $stop;
end
```

| 条件 | 判断 |
|------|------|
| `debug_wb_pc == 0x8000_0044` | 程序终止（约定地址） |
| `debug_data == 1` | 测试通过 |
| 其他值 | 测试失败 |
| 10000 ns 超时 | 视为超时失败 |

> **注意：** `debug_data` 实际读取 **x3 (gp)** 寄存器（`regfiles.sv:42`），而非 x10。测试程序将 pass(1)/fail 结果写入 gp。testbench 中 `$display` 打印的 "Expected 1 in x10" 为历史遗留的注释文字，与实际寄存器号不符，不影响仿真结果。**不应修改 `regfiles.sv` 的 debug_data 映射**，以保持 RISC-V 测试套件约定对齐。

### 2.4 Debug 观察端口

每个时钟周期打印：
- `debug_inst_pc`：当前取指 PC
- `debug_wb_pc`、`debug_wb_rf_wen`、`debug_wb_rf_addr`、`debug_wb_rf_data`：写回信息
- `debug_wb_fpu_rf_wen`：FPU 寄存器写使能
- `debug_data`：x10 寄存器值
- `led`、`plic_irq` 状态

---

## 3. 回归测试分组

`run_all.bat` 将测试用例分为 **7 组**，每组对应一个 RISC-V 官方测试集前缀：

### 3.1 基础指令 (base)

| 分组 | 测试前缀 | 指令数 | 说明 |
|------|----------|--------|------|
| **UI** | `rv32ui-p-` | 27 | RV32I 用户级基础指令 |
| **MI** | `rv32mi-p-` | 4 | 机器模式指令 |
| **UM** | `rv32um-p-` | 8 | M 扩展乘除法 |

**UI 指令清单：**

```
lh lhu sh sb lb lbu sw lw
add addi sub
and andi or ori xor xori
sll srl sra slli srli srai
slt slti sltu sltiu
beq bne blt bge bltu bgeu
jal jalr
lui auipc
```

**MI 指令清单：** `csr scall sbreak ma_fetch`

**UM 指令清单：** `mul mulh mulhu mulhsu div divu rem remu`

### 3.2 Z 扩展 (Z-bitman)

| 分组 | 测试前缀 | 指令数 | 说明 |
|------|----------|--------|------|
| **Zba** | `rv32uzba-p-` | 3 | 地址生成：sh1add sh2add sh3add |
| **Zbb** | `rv32uzbb-p-` | 11 | 位操作子集：andn orn xnor min max minu maxu sext_b sext_h zext_h orc_b rev8 |
| **Zbkb** | `rv32uzbkb-p-` | 5 | 打包：brev8 pack packh zip unzip |
| **Zbs** | `rv32uzbs-p-` | 8 | 单比特：bclr bclri bext bexti binv binvi bset bseti |

---

## 4. 运行模式

### 4.1 命令一览

```
run_all.bat                    # 全量回归：UI + MI + UM + Zba + Zbb + Zbkb + Zbs
run_all.bat base               # 基础回归：UI + MI + UM
run_all.bat z                  # Z 扩展回归：Zba + Zbb + Zbkb + Zbs
run_all.bat zba                # 仅 Zba 子集
run_all.bat zbb                # 仅 Zbb 子集
run_all.bat zbkb               # 仅 Zbkb 子集
run_all.bat zbs                # 仅 Zbs 子集
```

### 4.2 单组执行流程

```
┌──────────────┐
│  vlog 编译    │  ← 所有源文件增量编译
└──────┬───────┘
       ▼
┌──────────────┐
│  遍历测试用例  │  ← 对组内每个测试名
└──────┬───────┘
       ▼
┌──────────────────────────┐
│  检查 hex 文件是否存在    │
│  hex/riscv-tests/XXX.hex │
└──────┬───────────────────┘
       ▼
┌──────────────────────────┐
│  复制 hex → 统一文件名    │
│  → hex/riscv-tests       │
│    /rv32-p-riscv.hex     │
└──────┬───────────────────┘
       ▼
┌──────────────────────────┐
│  vsim -c 运行仿真         │
│  vsim -c -do "run -all"  │
│  tb_my_cpu               │
└──────┬───────────────────┘
       ▼
┌──────────────────────────┐
│  检查 Test passed.        │  ← findstr 判定
│  输出到 results/分_组.txt │
└──────┬───────────────────┘
       ▼
  ┌────┴────┐
  │ 通过？   │
  └──┬──┬───┘
  是 │  │ 否
     ▼  └──────────→ 打印 [FAILED]，中止回归
 继续下一条
```

### 4.3 关键特性

- **单 hex 加载机制**：每次仿真前将对应测试的 hex 复制为统一文件名 `rv32-p-riscv.hex`，测试平台固定加载此文件
- **fail-fast**：任一测试失败立即中止后续测试，返回 exit code 1
- **结果持久化**：每次仿真输出保存到 `results/` 目录，格式为 `{分组}_{测试名}.txt`

---

## 5. 结果输出

### 5.1 目录结构

```
results/
├── ui_add.txt        # UI add 指令测试结果
├── ui_sub.txt        # UI sub 指令测试结果
├── ui_lw.txt
├── ...
├── mi_csr.txt        # MI CSR 指令测试结果
├── um_mul.txt        # UM mul 指令测试结果
├── zba_sh1add.txt    # Zba sh1add 指令测试结果
├── zbb_andn.txt      # Zbb andn 指令测试结果
├── zbkb_pack.txt     # Zbkb pack 指令测试结果
└── zbs_bclr.txt      # Zbs bclr 指令测试结果
```

### 5.2 通过/失败判定

```
[PASSED] rv32ui-p-add        ← findstr 找到 "Test passed."
[FAILED] rv32ui-p-xxx        ← 未找到，打印仿真输出
```

---

## 6. 编译依赖

```bat
vlog -sv +incdir+rtl/cpu_top +incdir+rtl/my_cpu ^
    rtl/cpu_top/*.sv      ^
    rtl/cpu_top/*.svh     ^
    rtl/my_cpu/*.svh      ^
    rtl/my_cpu/*.sv       ^
    test/*.sv
```

- 需要 `+incdir` 指定两个 `defines.svh` 头文件搜索路径
- 所有 SV 源文件增量编译，无需手动管理文件列表

---

## 7. 验证架构特点

| 特点 | 说明 |
|------|------|
| **单 hex 加载** | 每次仅加载一个 hex，指令 RAM 和数据 RAM 加载同一镜像 |
| **debug 端口驱动** | 必须开启 `DEBUG_EN` 宏，依赖内部 debug RAM 和写回观察端口 |
| **退出条件固定** | `PC == 0x8000_0044` 作为程序结束地址 |
| **通过条件固定** | `debug_data`（即 x3/gp）== 1 判定通过 |
| **fail-fast** | 任一测试失败立即中止，不继续后续用例 |
| **全量回归覆盖** | UI(27) + MI(4) + UM(8) + Zba(3) + Zbb(11) + Zbkb(5) + Zbs(8) = **66 个测试用例** |

---

## 8. 验证状态

截至工程当前状态：

- **最后一次全量回归：`ALL TESTS PASSED`** ✅
- 流水线级间握手改造、bridge 读时序修复后均已通过 base 和 all 回归验证
- git HEAD: `fe91db1`（修复流水线冲刷和 bridge 读时序）

---

## 9. 扩展指南

### 9.1 新增测试用例

1. 将测试 hex 放入 `hex/riscv-tests/rv32p-{分组}-{测试名}.hex`
2. 在 `run_all.bat` 的对应分组变量中添加测试名
3. 运行回归验证

### 9.2 修改验证流程

- 修改 `test/tb_my_cpu.sv` 中的退出 PC 地址（当前为 `0x8000_0044`）或通过条件
- 修改 `run_all.bat` 添加新的测试分组
- 调整超时时间（当前 10000 ns，修改 `TIMEOUT_NS` 参数）
