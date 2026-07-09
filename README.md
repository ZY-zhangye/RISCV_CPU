# RISCV_CPU

RV32IM/Zicsr 双发射乱序 CPU RTL 工程，包含前端取指/预测、Rename、ROB、Issue、LSU、MDU、CSR/提交恢复、SoC RAM/MMIO wrapper，以及面向 Questa 和 Vivado 的验证与时序收敛记录。

当前主线已完成 SoC 级集成，并在 Kintex-7 `xc7k325tffg900-2`、5.000 ns 主时钟约束下通过 post-route 时序：

- Setup WNS: `+0.027 ns`
- Hold WHS: `+0.061 ns`

余量仍然偏紧，但当前版本已满足 route 后 setup/hold 均非负的主目标。

## 目录结构

```text
RISCV_CPU/
├─ LICENSE
├─ README.md
├─ doc/
│  ├─ JYD2025_MIGRATION_GUIDE.md
│  ├─ FPGA_OOO_ARCHITECTURE_PLAN.md
│  ├─ fpga_implementation_review.md
│  └─ rtl_module_specs/
├─ hex/
│  └─ riscv-tests/
├─ rtl/
│  ├─ backend/
│  ├─ commit/
│  ├─ decode/
│  ├─ dispatch/
│  ├─ execution/
│  ├─ fetch/
│  ├─ issue/
│  ├─ lsu/
│  ├─ prf/
│  ├─ rename/
│  ├─ soc/
│  ├─ core_top.sv
│  └─ core_types_pkg.sv
└─ test/
   ├─ soc_official_hex.f
   ├─ soc_custom_instr.f
   ├─ tb_soc_official_hex.sv
   ├─ tb_soc_custom_instr.sv
   └─ tb_*.sv
```

## RTL 状态

- 前端：`branch_predictor`、`fetch_pipeline`、`instruction_buffer`、`decode_stage`。
- Rename/资源管理：`rename_stage`、Free List、RAT/AMT、LSQ allocator、checkpoint file、ROB allocation cluster。
- 后端：整数/访存/MDU issue queues，统一 issue arbiter，同步 PRF，operand read，INT0/INT1、LSU、Mul/Div frontend。
- 提交恢复：ROB、CSR file、commit unit、recovery controller、commit/CSR/PRF cluster。
- SoC wrapper：instruction memory、data RAM、地址路由、LED/MMIO decode、`soc_top` power-on reset。

近期关键时序修复集中在 ROB recovery 路径：ROB 宽状态阵列不再由 raw recovery/checkpoint 请求直接选择更新路径，`exception_flush_i`、`restore_valid_i`、`branch_clear_valid_i` 只捕获到本地 pending 寄存器，数组可见性继续由 `valid_q` 控制。

后续修 Vivado 时序时保持以下约束：

- recovery/checkpoint 原始广播不要直接扇入 ROB/IQ/LSQ 的宽 payload 阵列更新选择；先进入本地 pending 或 snapshot 寄存器。
- ROB 年龄比较必须以当前 ROB head 为参考点，尤其是 Memory IQ 选择和 Load 等待更老 Store 的判断；不能只用两个 ROB ID 的简单环形差值判断 older。
- `valid_q == 0` 的 payload 必须视为架构不可见，时序修复不要为了“清干净”而恢复 payload 大规模同步清零。
- 写回监视 CSR 指令时要使用 commit-side CSR read data；直接在 retire 同拍读 PRF 会看到旧值，容易误判。

## 验证状态

QuestaSim 2024.1 当前基线：

- `vlog -sv -work questa_official_hex_work -f test/soc_official_hex.f`
- 官方支持集 `51/51 PASS`
  - RV32UI：所有 `rv32ui-p-*`，但排除 `rv32ui-p-fence_i`
  - RV32UM：8/8
  - RV32MI CSR：`rv32mi-p-csr`、`rv32mi-p-mcsr`
- `vlog -sv -work questa_custom_instr_work -f test/soc_custom_instr.f`
- 自定义 SoC 指令回归：`39/39 PASS`
- JYD2025 COE boot smoke：
  - `vlog -sv -work questa_coe_work -f test/soc_withmext_coe.f`
  - `vsim -c -voptargs="+acc" -lib questa_coe_work tb_soc_withmext_coe -do "run -all; quit -f"`
  - 当前结果：`PASS`，`LED = 0x0002_0001`
  - 数码管扫描输出 `seg` 会在两组 5 位之间轮换；以 MMIO 可直接读写的译码前 32 位 SEG 数据为准，正确值为 `0x3780_0000`。

`rv32ui-p-fence_i` 仍作为架构豁免项：该官方用例运行时修改 instruction memory，而当前最终 SoC 规则不允许运行时改 IMem。

## 常用命令

编译官方 HEX harness：

```powershell
vlog -sv -work questa_official_hex_work -f test/soc_official_hex.f
```

运行单个官方 HEX：

```powershell
vsim -c -quiet -work questa_official_hex_work tb_soc_official_hex `
  +HEX=hex/riscv-tests/rv32ui-p-simple.hex `
  +TEST=rv32ui-p-simple `
  +MAX_CYCLES=100000 `
  -do "run -all; quit -f"
```

编译并运行自定义 SoC 指令回归：

```powershell
vlog -sv -work questa_custom_instr_work -f test/soc_custom_instr.f
vsim -c -quiet -work questa_custom_instr_work tb_soc_custom_instr -do "run -all; quit -f"
```

## 文档

模块规格与时序记录主要在 `doc/rtl_module_specs/` 下；JYD2025 板级移植见 `doc/JYD2025_MIGRATION_GUIDE.md`。FPGA 实现原则和报告使用边界见 `doc/fpga_implementation_review.md`。

## 许可证

本项目采用 [Apache License 2.0](LICENSE) 开源。
