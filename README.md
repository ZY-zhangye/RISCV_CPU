# RISCV_CPU

本目录正在实现一个面向 RV32 的乱序、双发射处理器。目前已完成前端的双取指级和双路译码级，后续计划依次实现重命名、ROB、IQ、LSQ、执行、写回与提交。

## 当前目录

```text
RISCV_CPU/
├─ README.md
├─ doc/
│  └─ WORKSPACE_HANDOFF.md
├─ rtl/
│  └─ core/
│     ├─ defines.svh
│     ├─ if_stage.sv
│     ├─ id_decode_pkg.sv
│     └─ id_stage.sv
└─ test/
```

## 设计基本理念

1. 处理器采用 RV32、双取指、双译码，并面向后续乱序超标量后端。
2. 级间使用 `valid/allowin` 握手；反压信号应当寄存，避免形成跨多级的组合 ready 链。
3. 需要吸收反压的流水级使用“主 buffer + skid buffer”。
4. `pipe_flush` 不在前端直接删除或清零指令。flush 是指令元数据，随流水线继续传递，后续在执行和写回路径屏蔽副作用。
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

`rtl/core/id_decode_pkg.sv` 定义：

- IF 槽与双槽 bundle 类型；
- 功能单元、ALU、分支、访存和 CSR 操作枚举；
- 立即数生成函数；
- RV32I/Zicsr/SYSTEM 译码函数；
- 送往 Rename 的 `decode_pkt_t`。

`rtl/core/id_stage.sv` 负责：

- 接收双槽 IF bundle；
- 主 buffer + skid buffer；
- 寄存后的 `ds_allowin`；
- 将两个槽分别交给译码 package；
- 输出 `{lane1_decode, lane0_decode}` 到 Rename。

每个 `decode_pkt_t` 当前为 221 bit，双路 `DS_RN_WIDTH` 为 442 bit。其中包含：

- PC、指令和分支预测信息；
- `rs1/rs2/rd`、源寄存器使用标志和写回使能；
- 立即数和源操作数选择；
- 功能单元与操作类型；
- 1-bit `alu_ext` 扩展运算标志；
- 异常信息；
- 1-bit `flush`。

IF 插入的 NOP 在 ID 中被标记为无效槽。非法指令仍以有效异常指令进入后端，以便将来由 ROB 实现精确异常。

## Flush 语义

`br_taken || exception_flag` 形成 ID 的 `pipe_flush`。其行为是：

- 不清空 `ds_valid` 或 `skid_valid`；
- 为主 buffer、skid buffer 及同拍接收/发送的指令设置 `flush=1`；
- Rename 反压时仍保持该标志；
- 指令通过正常握手继续流动；
- 后续执行和写回模块必须依据 `flush` 屏蔽寄存器、CSR、存储器等体系结构副作用。

## 编译检查

SystemVerilog package 必须先于使用它的模块编译：

```powershell
F:\questasim64_2024.1\win64\vlib.exe work
F:\questasim64_2024.1\win64\vlog.exe -sv `
  +incdir+F:\RISCV_CPU\rtl\core `
  F:\RISCV_CPU\rtl\core\id_decode_pkg.sv `
  F:\RISCV_CPU\rtl\core\if_stage.sv `
  F:\RISCV_CPU\rtl\core\id_stage.sv
```

截至 2026-06-28，上述文件已通过 QuestaSim 编译：`0 Errors, 0 Warnings`。行为测试已覆盖双取指、双路译码、反压、skid 搬运、分支预测和 flush 随流水线传播。

## 下一步

建议下一步实现双路 Rename，并首先确定：

1. RAT、Free List、Busy Table 和物理寄存器编号宽度；
2. 同一双发射组内 lane 1 对 lane 0 写后读相关的重命名规则；
3. 双路 ROB 原子分配及资源不足时的反压策略；
4. 非访存指令进入 IQ，load/store 进入 LSQ；
5. `flush` 在 Rename、ROB、IQ、LSQ、执行和写回中的连续传递与副作用屏蔽。

更详细的当前状态和新 Codex 对话接续方式见 `doc/WORKSPACE_HANDOFF.md`。
