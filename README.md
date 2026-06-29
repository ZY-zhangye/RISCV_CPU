# RISCV_CPU

本目录正在实现一个面向 RV32 的乱序、双发射处理器。目前已完成双取指、RV32I/M 双路译码、双路 Rename、同步 4R2W 物理寄存器堆、32 项 ROB 和组合 Dispatch。

## 当前目录

```text
RISCV_CPU/
├─ LICENSE
├─ README.md
├─ doc/
│  ├─ free_list_rrat_busy_table_review.md
│  ├─ PLAN.md
│  ├─ RENAME_SUBSYSTEM_PLAN.md
│  ├─ rename_stage_review.md
│  └─ WORKSPACE_HANDOFF.md
├─ rtl/
│  └─ core/
│     ├─ defines.svh
│     ├─ busy_table.sv
│     ├─ core_port_pkg.sv
│     ├─ dispatch.sv
│     ├─ free_list.sv
│     ├─ if_stage.sv
│     ├─ id_decode_pkg.sv
│     ├─ id_stage.sv
│     ├─ physical_regfile.sv
│     ├─ rat_rrat.sv
│     ├─ rename_stage.sv
│     └─ rob.sv
└─ test/
   ├─ tb_dispatch.sv
   ├─ tb_rename_stage.sv
   ├─ tb_rename_state.sv
   ├─ tb_id_decode_m.sv
   ├─ tb_physical_regfile.sv
   └─ tb_rob.sv
```

## 设计基本理念

1. 处理器采用 RV32、双取指、双译码，并面向后续乱序超标量后端。
2. 级间使用 `valid/allowin` 握手；跨级反压应避免形成长组合链。组合 Dispatch 只读取 ROB/IQ/LSQ 的寄存占用状态，不旁路本拍出队或提交空间。
3. 需要吸收反压的流水级使用“主 buffer + skid buffer”。
4. `pipe_flush` 不在 IF/ID 直接清零 valid，而是作为元数据传播到 Rename；Rename 是错误路径指令进入乱序后端前的丢弃边界，后端存量状态由统一 recovery 信道恢复。
5. 译码逻辑放在 package 中，`id_stage` 只保留握手、buffer 和 package 调用。
6. ID 不读取寄存器值，也不实现顺序流水线中的地址前递、load-use 检测等逻辑；这些职责由 Rename、IQ/LSQ 和乱序调度结构承担。

## IF Stage

`rtl/core/if_stage.sv` 使用同步单周期指令存储器接口：

- `pc_out` 发出下一次请求地址；`inst_in` 与当前 `fs_pc` 对应。
- 指令数据宽度为 64 bit，每次最多取得两条 32-bit 指令。
- 指令存储器地址按 8 byte 对齐。
- 跳转到 `8N+4` 时，第一槽取 `inst_in[63:32]`，无法同时取得的第二槽填入 `32'h0000_0013`。
- 采用 64 项直接映射 BTB，每项带 2-bit 饱和计数器，可同时查询两个取指槽。
- 槽 0 预测跳转时，槽 1 属于错误路径并填入 NOP。
- JALR 当前不写入直接映射预测表。

IF 到 ID 的单槽格式为：

```text
{inst[31:0], pc[31:0], pred_taken, pred_target[31:0]}
```

完整总线排列为 `{lane1, lane0}`，宽度由 `FS_DS_WIDTH` 定义。

## ID Stage

`rtl/core/core_port_pkg.sv` 定义全核共用的端口类型：

- 功能单元、ALU、分支、访存和 CSR 操作枚举；
- 独立的 IF→ID `fs_ds_slot_t/fs_ds_bundle_t`；
- 独立的 ID→Rename `ds_rn_slot_t/ds_rn_bundle_t`。

`rtl/core/id_decode_pkg.sv` 只定义：

- 立即数生成函数；
- RV32I/M/Zicsr/SYSTEM 译码函数；
- 从 `fs_ds_slot_t` 构造 `ds_rn_slot_t` 的逻辑。

`rtl/core/id_stage.sv` 负责：

- 接收双槽 IF bundle；
- 主 buffer + skid buffer；
- 寄存后的 `ds_allowin`；
- 将两个槽分别交给译码 package；
- 通过 typed port 输出 `core_port_pkg::ds_rn_bundle_t` 到 Rename。

每个 `ds_rn_slot_t` 当前为 225 bit，双路 `ds_rn_bundle_t` 为 450 bit；宽度均由 package 内的 `$bits` 自动派生，不再维护手工总线宽度宏。其中包含：

- PC、指令和分支预测信息；
- `rs1/rs2/rd`、源寄存器使用标志和写回使能；
- 立即数和源操作数选择；
- 功能单元与操作类型；
- 1-bit `alu_ext` 扩展运算标志；
- RV32M 的 `FU_MLU` 分类及 MUL/DIV/REM 操作枚举；
- 异常信息；
- 1-bit `flush`。

IF 插入的 NOP 在 ID 中被标记为无效槽。非法指令仍以有效异常指令进入后端，以便将来由 ROB 实现精确异常。

## Rename 状态模块

当前已完成三个独立状态模块：

- `free_list.sv`：64-bit 空闲位图、双路级联优先分配、双路 stale 标签回收，以及按 RRAT live mask 恢复；
- `rat_rrat.sv`：32 项 RAT/RRAT、双路查询和更新、lane1 对 lane0 的 RAW/WAW 旁路、双提交和 RRAT 恢复；
- `busy_table.sv`：64-bit busy 位图、双路分配置 busy、双写回清除和写回就绪旁路。

三个模块共享 `core_port_pkg::recover_event_t`，分支误预测、同步异常和外部中断使用同一条恢复信道。`p0` 在三个模块中均保持不可分配、不可重命名且始终 ready。

`physical_regfile.sv` 实现 64×32-bit、同步 4 读 2 写物理寄存器堆。四个读端口供两条发射通道使用，两个写端口对应两组写回，p0 恒为零。PRF 内部不做写回前递；后续 IQ 在广播当拍唤醒并选择，命中的广播数据随 issue 元数据锁存，由操作数选择级在广播值和 PRF 读值之间选择。

`rename_stage.sv` 已完成上述模块的集成：

- 输入侧使用主槽 + skid，`rn_allowin` 为寄存输出；
- 输出侧使用 `RENAME_FIFO_DEPTH` 参数化 renamed FIFO，默认深度为 2；
- 支持每拍重命名 0/1/2 条，资源不足时只推进程序序第一条；
- 输出遵循双路前缀 valid/ready，slot1 不会越过 slot0；
- flushed 指令在 Rename 边界直接丢弃，不更新 Free List、RAT 或 Busy Table；
- `recover_event_t` 同拍清空输入缓冲和输出 FIFO，并恢复三个状态模块。

## ROB

`rob.sv` 实现 32 项双路 ROB：

- 每拍最多按 lane0、lane1 程序序分配两项，并输出带环回位的 ROB tag；
- 只有至少两个空项时组合拉高 `rob_allowin`，且不旁路本拍提交空间；
- 支持两路乱序完成更新，以及严格前缀的单/双顺序提交；
- 只保存提交映射、PC、异常、重定向和串行属性，不保存执行译码结果；
- 异常、重定向、CSR、FENCE 和 MRET 会阻止同拍提交更年轻指令；
- 统一 `recover_event_t` 清空全部在途项。

## 组合 Dispatch

`dispatch.sv` 不含时钟和内部 buffer，直接连接 Rename 输出 FIFO 与 ROB/IQ/LSQ：

- 每条指令只有在 ROB 与目标队列都可接收时才会原子推进；
- lane1 不得越过 lane0，但目标资源不足时允许仅推进 lane0；
- MLU 固定进入 IQ0，BRU/CSR 固定进入 IQ1，Load/Store 进入 LSQ；
- 普通 ALU 根据两个 IQ bank 的剩余接收额度动态分流；
- FU_NONE、SYSTEM、异常和 FENCE 等仅进入 ROB；
- IQ/LSQ 的 0/1/2 接收额度必须由寄存占用状态产生，不旁路本拍出队空间。

## Flush 语义

`br_taken || exception_flag` 形成 ID 的 `pipe_flush`。其行为是：

- 不清空 `ds_valid` 或 `skid_valid`；
- 为主 buffer、skid buffer 及同拍接收/发送的指令设置 `flush=1`；
- Rename 反压时仍保持该标志；
- 指令通过正常握手继续流动；
- 后续 `rename_stage` 将作为 flushed 指令进入乱序后端前的丢弃边界，不分配物理寄存器，也不送入 ROB/IQ/LSQ；
- 已经进入后端的推测状态由统一 `recover_event_t` 信道恢复。

## 编译检查

SystemVerilog package 必须先于使用它的模块编译：

```powershell
F:\questasim64_2024.1\win64\vlib.exe work
F:\questasim64_2024.1\win64\vlog.exe -sv `
  +incdir+F:\RISCV_CPU\rtl\core `
  F:\RISCV_CPU\rtl\core\core_port_pkg.sv `
  F:\RISCV_CPU\rtl\core\dispatch.sv `
  F:\RISCV_CPU\rtl\core\id_decode_pkg.sv `
  F:\RISCV_CPU\rtl\core\if_stage.sv `
  F:\RISCV_CPU\rtl\core\id_stage.sv `
  F:\RISCV_CPU\rtl\core\free_list.sv `
  F:\RISCV_CPU\rtl\core\rat_rrat.sv `
  F:\RISCV_CPU\rtl\core\busy_table.sv `
  F:\RISCV_CPU\rtl\core\rename_stage.sv `
  F:\RISCV_CPU\rtl\core\physical_regfile.sv `
  F:\RISCV_CPU\rtl\core\rob.sv
```

Rename 状态模块定向测试：

```powershell
F:\questasim64_2024.1\win64\vlog.exe -sv `
  +incdir+F:\RISCV_CPU\rtl\core `
  F:\RISCV_CPU\rtl\core\core_port_pkg.sv `
  F:\RISCV_CPU\rtl\core\free_list.sv `
  F:\RISCV_CPU\rtl\core\rat_rrat.sv `
  F:\RISCV_CPU\rtl\core\busy_table.sv `
  F:\RISCV_CPU\test\tb_rename_state.sv
F:\questasim64_2024.1\win64\vsim.exe -c `
  -do "run -all; quit -f" tb_rename_state
```

Rename 级缓冲、部分推进和恢复测试：

```powershell
F:\questasim64_2024.1\win64\vlog.exe -sv `
  +incdir+F:\RISCV_CPU\rtl\core `
  F:\RISCV_CPU\rtl\core\core_port_pkg.sv `
  F:\RISCV_CPU\rtl\core\free_list.sv `
  F:\RISCV_CPU\rtl\core\rat_rrat.sv `
  F:\RISCV_CPU\rtl\core\busy_table.sv `
  F:\RISCV_CPU\rtl\core\rename_stage.sv `
  F:\RISCV_CPU\test\tb_rename_stage.sv
F:\questasim64_2024.1\win64\vsim.exe -c `
  -do "run -all; quit -f" tb_rename_stage
```

ROB 定向测试：

```powershell
F:\questasim64_2024.1\win64\vlog.exe -sv `
  +incdir+F:\RISCV_CPU\rtl\core `
  F:\RISCV_CPU\rtl\core\core_port_pkg.sv `
  F:\RISCV_CPU\rtl\core\rob.sv `
  F:\RISCV_CPU\test\tb_rob.sv
F:\questasim64_2024.1\win64\vsim.exe -c `
  -do "run -all; quit -f" tb_rob
```

组合 Dispatch 与 ROB 原子准入测试：

```powershell
F:\questasim64_2024.1\win64\vlog.exe -sv `
  +incdir+F:\RISCV_CPU\rtl\core `
  F:\RISCV_CPU\rtl\core\core_port_pkg.sv `
  F:\RISCV_CPU\rtl\core\dispatch.sv `
  F:\RISCV_CPU\rtl\core\rob.sv `
  F:\RISCV_CPU\test\tb_dispatch.sv
F:\questasim64_2024.1\win64\vsim.exe -c `
  -do "run -all; quit -f" tb_dispatch
```

RV32M 译码和物理寄存器堆还分别由 `tb_id_decode_m.sv`、`tb_physical_regfile.sv` 进行定向验证。

截至 2026-06-29，上述文件已通过 QuestaSim 编译：`0 Errors, 0 Warnings`。所有定向测试均输出 `PASS`。

## 下一步

建议下一步开始两个静态分区 IQ 的设计，并将其实际接收额度接入组合 Dispatch。

更详细的当前状态和新 Codex 对话接续方式见 `doc/WORKSPACE_HANDOFF.md`。

## 开源许可证

本项目采用 [Apache License 2.0](LICENSE) 开源。
