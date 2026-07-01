# RISCV_CPU

本目录正在实现一个面向 RV32 的乱序、双发射处理器。目前 `core_top.sv` 已完成 IF/ID 与完整乱序 Backend 的结构串联，覆盖 RV32I/M 双路译码、Rename、ROB/IQ/LSQ、同步 PRF、五类执行单元、WB0/WB1 和最小机器态 CSR/精确提交通路。

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
│     ├─ alu_unit.sv
│     ├─ backend_top.sv
│     ├─ bru_unit.sv
│     ├─ core_top.sv
│     ├─ defines.svh
│     ├─ busy_table.sv
│     ├─ commit_controller.sv
│     ├─ core_port_pkg.sv
│     ├─ csr_commit_buffer.sv
│     ├─ csr_file.sv
│     ├─ csr_unit.sv
│     ├─ dispatch.sv
│     ├─ execute_stage.sv
│     ├─ free_list.sv
│     ├─ if_stage.sv
│     ├─ id_decode_pkg.sv
│     ├─ id_stage.sv
│     ├─ issue1_arbiter.sv
│     ├─ issue_queue.sv
│     ├─ issue_queue_pair.sv
│     ├─ lsq.sv
│     ├─ lsu_unit.sv
│     ├─ mlu_unit.sv
│     ├─ operand_read_stage.sv
│     ├─ physical_regfile.sv
│     ├─ rat_rrat.sv
│     ├─ rename_stage.sv
│     ├─ rob.sv
│     ├─ writeback_commit_stage.sv
│     └─ writeback_stage.sv
└─ test/
   ├─ tb_backend_control.sv
   ├─ tb_backend_datapath.sv
   ├─ tb_core_alu_instructions.sv
   ├─ tb_core_branch_instructions.sv
   ├─ tb_core_single_instruction.sv
   ├─ tb_core_subword_memory.sv
   ├─ tb_dispatch.sv
   ├─ tb_csr_file.sv
   ├─ tb_execute_stage.sv
   ├─ tb_issue_queue.sv
   ├─ tb_lsq.sv
   ├─ tb_lsu_four_cycle.sv
   ├─ tb_rename_stage.sv
   ├─ tb_rename_state.sv
   ├─ tb_id_decode_m.sv
   ├─ tb_physical_regfile.sv
   ├─ tb_writeback_commit_stage.sv
   ├─ tb_rob.sv
   └─ unified_memory_model.sv
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

`physical_regfile.sv` 实现 64×32-bit、同步 4 读 2 写物理寄存器堆。四个读端口供两条发射通道使用，两个写端口对应两组写回，p0 恒为零。PRF 内部不做写回前递；IQ 在广播当拍唤醒并选择，命中的广播数据随 issue 元数据锁存，由 `operand_read_stage.sv` 在广播值和 PRF 读值之间选择。无效读请求保持端口上次值，使操作数级反压时同步读结果保持稳定。

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

## 双分区 Issue Queue

`issue_queue.sv` 实现可复用的 8 项全相联 IQ bank，`issue_queue_pair.sv` 将其组成两个独立分区：

- IQ0 支持 ALU/MLU，IQ1 支持 ALU/BRU/CSR；
- 每个 bank 支持双入队、单发射和任意空槽复用；
- 使用 ROB head 与带环回位 tag 计算年龄，选择最老的已就绪兼容指令；
- 年轻 ready 指令可以越过等待操作数或等待功能单元的老指令；
- 两路写回广播当拍参与 wakeup 和 select，并将命中数据随 issue 包传递；
- 下游阻塞时锁存选中项及旁路数据，保证 issue valid/ready 稳定；
- 接收额度只由当前寄存项产生，不旁路本拍 issue 释放的槽位。

## 乱序 LSQ 与 issue1 仲裁

`lsq.sv` 实现参数化 8 项统一 Load/Store Queue，`issue1_arbiter.sv` 在 IQ1 与 LSQ 地址生成候选之间按 ROB 年龄仲裁：

- Load/Store 地址按 oldest-ready 乱序计算，年轻 Load 可越过尚未 ready 的普通指令；
- Store 地址只等待基址，Store data 独立从 PRF 或写回广播取得；
- Load 不预测越过地址未知的老 Store，避免引入内存违例 replay；
- 完整覆盖时从最年轻匹配老 Store 转发，部分覆盖采取保守等待；
- Load 可乱序请求内存并完成，Store 只有 ROB 顺序提交后才能写内存；
- 外部内存请求经过 LSQ 内的一项寄存请求级；
- LSQ tag 带 generation，恢复后的迟到 Load response 会被丢弃；
- 统一 `recover_event_t` 清除推测项，但保留已提交 Store，并按独立提交序号顺序排空；
- 地址未对齐和访问错误通过写回完成包送入 ROB，最终复用统一异常恢复通路。

## 操作数选择与执行簇

`execute_stage.sv` 组合两条独立执行通道，但不包含最终 WB0/WB1 仲裁：

- `operand_read_stage.sv` 将 issue 元数据与同步 PRF 返回对齐，广播旁路命中值优先；下游反压时保持整包稳定；
- issue0 路由到 ALU0 或 MLU，issue1 路由到 ALU1、BRU、CSR 或 LSQ-AGU；
- `alu_unit.sv` 完成 RV32I 整数运算，`bru_unit.sv` 计算真实下一 PC、链接值和预测失误重定向；
- `csr_unit.sv` 使用一拍时序读，返回旧 CSR 值并生成带 ROB tag 的延迟更新包；未实现 CSR 或写只读 CSR会形成精确非法指令异常；
- `mlu_unit.sv` 为 Vivado IP 适配层：乘法采用参数化固定多周期延迟，33×33 signed IP 统一覆盖四种乘法；除法的 dividend/divisor 独立 ready/valid，结果同样握手；
- MLU 对除零和 signed overflow 走 RISC-V 本地快速路径；recovery 后继续安全排空已送入 Divider IP 的半包和迟到结果；
- `lsu_unit.sv` 保持为组合 AGU，现有 LSQ 的 `memory_request_reg` 作为 DMEM 外部寄存级。无等待 Load 按“issue/PRF→AGU→请求寄存→同步 DMEM”在第 4 个流水周期取得内存结果。

ALU/MLU/BRU/CSR 均使用一项弹性结果寄存器；这些独立结果端口与 LSQ writeback 统一进入下述 WB0/WB1 仲裁。

## CSR、写回与精确提交

- `csr_file.sv` 实现最小机器态集合：`mstatus/misa/mie/mtvec/mscratch/mepc/mcause/mtval/mip` 及基本只读 ID CSR；不实现 S/U 特权切换、delegation 和 PMP；
- CSR 读采用一拍时序接口，切断 CSR mux→运算→WB 仲裁的组合路径；CSR 提交缓存占用时禁止后一条 CSR 执行，避免读到未提交旧状态；
- trap 入口执行 `MPIE←MIE, MIE←0`，写入对齐后的 `mepc`、规范 `mcause` 和 `mtval`；MRET 执行 `MIE←MPIE, MPIE←1`；
- 软件、定时器、外部中断经两级同步，标准优先级为 external > software > timer；`mtvec` 支持 Direct 与 Vectored，exception 始终走 BASE；
- `writeback_stage.sv` 对 WB0(ALU0/MLU) 和 WB1(ALU1/BRU/LSQ/CSR) 分别进行 round-robin 仲裁，同拍生成 PRF 写入、Busy Table/IQ 广播和 ROB complete；
- `csr_commit_buffer.sv` 只在匹配 ROB tag 真正提交时修改 CSR，非法 CSR 不进入缓存；
- `commit_controller.sv` 只在 ROB 精确边界触发 exception、branch recovery、MRET 或 interrupt；中断不与普通指令提交混在同一拍；
- `writeback_commit_stage.sv` 将上述模块封装为 typed-port 闭环。

## 完整后端顶层

`backend_top.sv` 已完成 ID→Rename 到精确提交的完整串联：

- ROB `commit_map` 回接 RRAT/Free List，WB 广播同时送 PRF、Busy Table、IQ 和 LSQ；
- IQ0 独占 issue0，IQ1 与 LSQ 以 ROB 年龄竞争 issue1，分别使用 PRF 0/1 与 2/3 读口；
- CSR、FENCE/FENCE.I、MRET 和异常指令使用单项串行锁存器，lane0 串行指令禁止 lane1 同拍进入；
- FENCE/FENCE.I 在 ROB 分配时完成，但提交必须等待 LSQ occupancy 为零；FENCE.I 提交输出单拍通知；
- BRU 对全部条件分支和跳转产生 typed predictor update，只有 WB1 真正接收时训练一次；误预测仍在 ROB 头统一恢复；
- 统一 recovery 同拍广播至 Rename、ROB、IQ、LSQ、Execute 和写回/CSR；已提交 Store 由 LSQ 保留并继续排空；
- 顶层保留 vendor-neutral 乘除法 IP 端口，并输出提交追踪和 `backend_idle_o` 调试接口。

## Core 顶层

`core_top.sv` 已连接 IF→ID→Rename→完整 Backend，并保留固定一周期 64-bit IMEM、typed DMEM、三类中断和 vendor-neutral 乘除法 IP 接口。前端直接接收 typed `recover_event_t` 与 `branch_update_t`；FENCE.I 提交会以 `RECOVER_FENCE_I` 清除年轻流水并从 `PC+4` 重取。Backend 内部维护 `retire_next_pc`，供空 ROB 精确中断写入 `mepc`。

Core 外部现已加入测试专用统一行为内存：IMEM 为一拍同步读，DMEM 请求必须先进入 Core 外的一项寄存器，再访问统一 word array。RV32I 整数 ALU、立即数、移位、比较、LUI/AUIPC、六类条件分支、JAL/JALR，以及 LB/LBU/LH/LHU/LW/SB/SH/SW 单项测试均已通过。LW 用周期断言确认外部寄存级，分支测试覆盖 update、恢复目标、链接值和错误路径隔离。官方 HEX 回归尚未开始。

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
  F:\RISCV_CPU\rtl\core\backend_top.sv `
  F:\RISCV_CPU\rtl\core\core_top.sv `
  F:\RISCV_CPU\rtl\core\dispatch.sv `
  F:\RISCV_CPU\rtl\core\id_decode_pkg.sv `
  F:\RISCV_CPU\rtl\core\if_stage.sv `
  F:\RISCV_CPU\rtl\core\id_stage.sv `
  F:\RISCV_CPU\rtl\core\issue_queue.sv `
  F:\RISCV_CPU\rtl\core\issue_queue_pair.sv `
  F:\RISCV_CPU\rtl\core\lsq.sv `
  F:\RISCV_CPU\rtl\core\issue1_arbiter.sv `
  F:\RISCV_CPU\rtl\core\operand_read_stage.sv `
  F:\RISCV_CPU\rtl\core\alu_unit.sv `
  F:\RISCV_CPU\rtl\core\bru_unit.sv `
  F:\RISCV_CPU\rtl\core\csr_unit.sv `
  F:\RISCV_CPU\rtl\core\lsu_unit.sv `
  F:\RISCV_CPU\rtl\core\mlu_unit.sv `
  F:\RISCV_CPU\rtl\core\execute_stage.sv `
  F:\RISCV_CPU\rtl\core\writeback_stage.sv `
  F:\RISCV_CPU\rtl\core\csr_commit_buffer.sv `
  F:\RISCV_CPU\rtl\core\csr_file.sv `
  F:\RISCV_CPU\rtl\core\commit_controller.sv `
  F:\RISCV_CPU\rtl\core\writeback_commit_stage.sv `
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

双分区 IQ 乱序发射测试：

```powershell
F:\questasim64_2024.1\win64\vlog.exe -sv `
  +incdir+F:\RISCV_CPU\rtl\core `
  F:\RISCV_CPU\rtl\core\core_port_pkg.sv `
  F:\RISCV_CPU\rtl\core\issue_queue.sv `
  F:\RISCV_CPU\rtl\core\issue_queue_pair.sv `
  F:\RISCV_CPU\test\tb_issue_queue.sv
F:\questasim64_2024.1\win64\vsim.exe -c `
  -do "run -all; quit -f" tb_issue_queue
```

乱序 LSQ、Store forwarding、统一恢复和 issue1 仲裁测试：

```powershell
F:\questasim64_2024.1\win64\vlog.exe -sv `
  +incdir+F:\RISCV_CPU\rtl\core `
  F:\RISCV_CPU\rtl\core\core_port_pkg.sv `
  F:\RISCV_CPU\rtl\core\lsq.sv `
  F:\RISCV_CPU\rtl\core\issue1_arbiter.sv `
  F:\RISCV_CPU\test\tb_lsq.sv
F:\questasim64_2024.1\win64\vsim.exe -c `
  -do "run -all; quit -f" tb_lsq
```

操作数选择、五类执行单元、MLU IP 握手和 recovery 排空测试由 `tb_execute_stage.sv` 覆盖；`tb_lsu_four_cycle.sv` 检查四周期访存路径；`tb_csr_file.sv` 与 `tb_writeback_commit_stage.sv` 覆盖 CSR trap/mret、中断优先级、双写回仲裁和精确提交缓存。`tb_backend_datapath.sv` 与 `tb_backend_control.sv` 进一步覆盖完整后端的 RAW/WAW、长 DIV 越序完成、Store forwarding、分支训练/recovery、连续 CSR、FENCE.I、非法 CSR 和 MRET。

截至 2026-07-01，包含 `core_top.sv` 和统一行为内存的全量编译为 `0 Errors, 0 Warnings`。十四项既有测试与四项 Core 单项测试共十八项全部输出 `PASS`。

## 下一步

下一步继续扩展自设单项测试，依次覆盖 RV32M、CSR/SYSTEM、异常和 FENCE.I；单项门禁稳定后再运行组合场景与官方 HEX 回归。

更详细的当前状态和新 Codex 对话接续方式见 `doc/WORKSPACE_HANDOFF.md`。

## 开源许可证

本项目采用 [Apache License 2.0](LICENSE) 开源。
