# Multiply/Divide Unit 设计

建议模块：mul_pipeline、div_unit、muldiv_frontend。

## 1. 公共端口

| 方向 | 端口 | 类型 | 说明 |
|---|---|---|---|
| input | req_valid_i | 1 | MDU IQ 请求 |
| output | req_ready_o | 1 | 对应单元可接受 |
| input | req_uop_i | execute_uop_t | 操作数、op、ID、mask |
| output | result_valid_o | 1 | 结果有效 |
| input | result_ready_i | 1 | Completion Buffer 接收 |
| output | result_o | completion_t | 最终 32-bit 结果 |
| input | recovery_i | recovery_t | 标记/取消错误路径 |

## 2. 乘法器

使用 DSP48 映射的有符号乘法流水，固定 3 至 4 周期，吞吐率 1/cycle。输入规范化为
33×33 signed，以统一 MUL、MULH、MULHSU、MULHU。每级同时流水 rob_id、prd、op、
branch_mask 和 valid。

输出根据 op 选择低 32 位或高 32 位，先进入深度 2 的 Mul Completion FIFO，再参与
全局 WB。

### 2.1 Mul Pipeline V1 实现状态（2026-07-05）

`rtl/execution/mul_pipeline.sv` 已实现可综合四级乘法流水：

- MUL/MULH/MULHSU/MULHU 统一归一化为 33×33 signed 乘法，结果为 66-bit。
- 33-bit 操作数拆为 signed high-16 与 unsigned low-17，显式生成 17×17、17×16、
  16×17、16×16 四个独立部分积 DSP；随后经两级寄存加法树重组，避免同拍 DSP 级联。
- 使用 `use_dsp` 属性引导 Vivado 推断 4 个 DSP48，不依赖 Xilinx IP 或厂商仿真模型。
- 无背压时固定四周期延迟、吞吐率 1/cycle；尾部由 2-entry completion FIFO 解耦。
- FIFO 满时整条乘法流水统一冻结，保证 product、ROB/PRD 和 branch mask 对齐。
- recovery 对四个流水级和 FIFO entry 分别执行 kill/clear，FIFO 可压缩被杀 head。
- 输出统一标记为 `PROD_MUL`，异常字段清零并保持标准 completion 背压契约。

## 3. 除法器

Radix-4 迭代，单在途，目标 16 至 18 周期。状态机：

    IDLE -> PREPARE -> ITERATE -> SIGN_FIX -> OUTPUT

DIV/DIVU/REM/REMU 共用 datapath。必须显式处理：

- 除数为 0：quotient 全 1，remainder=dividend。
- signed 最小负数除以 -1：quotient=最小负数，remainder=0。

OUTPUT 保持 result_valid，直到 Completion Buffer 接收。

### 3.1 Div Unit V1 实现状态（2026-07-05）

`rtl/execution/div_unit.sv` 已实现单在途 RV32M 除法/求余单元：

- DIV/DIVU/REM/REMU 共用 unsigned radix-4 长除法 datapath，signed 操作在 PREPARE
  阶段转换为绝对值，SIGN_FIX 阶段恢复 quotient/remainder 符号。
- 正常路径固定 16 个 ITERATE 周期，每周期消耗 dividend 高 2 bit；从输入接受到
  `result_valid_o` 无背压延迟为 18 cycle。
- 除数为 0、`0x8000_0000 / -1` 两类 RISC-V 特殊规则在 PREPARE 阶段直接旁路迭代。
- 每轮预存 divisor×1/×2/×3，并行生成 `trial-divisor{1,2,3}` 三个候选余数，再由比较结果
  选择，避免比较→倍数 mux→减法的串行关键路径。
- 单在途 busy 时 `req_ready_o=0`；OUTPUT 本身作为稳定 completion 缓冲，直到
  `result_ready_i` 接收。
- recovery 对当前项执行 kill/clear：异常清空全部状态；分支恢复命中 branch mask 时立即回到
  IDLE，未命中时只清除对应 checkpoint bit。
- 输出 completion 统一标记为 `PROD_DIV`，异常字段清零，`write_prf` 透传自 uop。

## 4. MDU Frontend

`rtl/execution/muldiv_frontend.sv` 已实现 MDU 请求分发与本地 Mul/Div 封装：

- 从 Operand Read 接收单路 `mdu_valid/mdu_ready/execute_uop_t`。
- 按 `fu_type` 将请求分发给 `mul_pipeline` 或 `div_unit`。
- 当 DIV 单元 busy 时，新的 DIV 请求反压；但 MUL 请求仍可通过独立的乘法流水继续接受。
- MUL/DIV completion 不在 frontend 内合并，分别暴露为独立 producer，直接对接
  `writeback_arbiter` 的 `mul`/`div` 输入。
- recovery 原样广播给两个子单元，错误路径结果由子单元本地 kill/clear。

### 4.1 Backend MDU Cluster 集成状态（2026-07-06）

`rtl/backend/backend_mdu_cluster.sv` 已在 Backend LSU Cluster 的冻结边界上打开 MDU
执行链路：

- Dispatch Buffer 新增 MDU 分派路径，经一级 skid/register 送入单组 `IQ_MDU_ENTRIES`
  Issue Queue。
- Issue Arbiter 打开 MDU candidate/grant，Operand Read 打开 MDU 输出端口，
  `muldiv_frontend` 连接到本地 `mul_pipeline` 和 `div_unit`。
- Writeback Arbiter 打开 `PROD_MUL`、`PROD_DIV` 两个 producer 输入，与 INT/LSU
  completion 共同仲裁双写回端口。
- 分支 completion event 除送入 recovery/commit 外，也通过
  `branch_update_valid_o/branch_update_o` 暴露给前端集成边界，用于更新
  `branch_predictor`。
- 集群级 `mdu_accept_i` 固定为 `1'b1`，不把 MUL/DIV 子单元 ready 组合反馈到全局
  Issue Arbiter；真实反压由 Operand Read 的 MDU holding register 通过 `mdu_ex_ready`
  吸收，DIV busy 或 completion backpressure 只停留在 MDU 本地链路。
- 首次 Backend MDU Cluster OOC 暴露 recovery/MUL-DIV ready 经 Operand Read 回灌
  Issue Arbiter P2 的路径。当前集群内增加 2-entry MDU execute FIFO，Operand Read
  只看 FIFO full 形成 `mdu_ex_ready`，`muldiv_frontend` raw ready 只控制 FIFO pop；
  FIFO 对 recovery 执行错误路径清除和幸存项 branch mask 清理，并纳入 `busy_o`。

该设计选择会在 MDU 子单元忙时占用 Operand Read 的 MDU holding entry，但换取更清晰的
集成时序边界，避免 `div_unit busy -> muldiv_frontend ready -> operand_read ready ->
issue_arbiter proposal/grant` 的跨模块组合长路径。

## 5. Recovery

乘法流水中的错误路径项不能简单停整条流水；每级按 branch_mask kill valid。除法器若
当前项被 kill，可立即回到 IDLE。正确分支解析清 mask 位。

## 6. 时序约束

乘法器每级 DSP 之间必须有寄存器；不允许组合符号修正跨越多个 DSP 级。除法器每轮
仅完成固定 radix-4 步骤，余数比较/选择必须独立达到 225 MHz 以上。

## 7. 断言

- 乘法输出延迟固定且 tag 不乱序。
- 除法器 busy 时不接受第二项。
- 被 kill 的 MDU 项不进入 Completion Buffer。
- 所有特殊除法结果符合 RISC-V 规范。

## 8. 当前验证状态

- `test/tb_mul_pipeline.sv` 覆盖四种乘法 signedness、高低半选择、96 组随机黄金模型、固定四拍延迟、
  连续四拍满吞吐、completion 背压、流水中 kill、checkpoint clear、FIFO kill/compact
  和 exception flush。
- QuestaSim：`tb_mul_pipeline` 及 16 项相关回归通过，`Errors: 0, Warnings: 0`。
- 初版完整 33×33 DSP 推断在 5.000 ns OOC 下 WNS = -0.114 ns，关键路径为同拍
  DSP partial-product cascade。改为四路独立部分积与两级加法树后，用户 OOC 复测
  WNS = +1.511 ns、TNS = 0；资源为 263 LUT、341 FF、4 DSP48E1。当前实现冻结。
- `test/tb_div_unit.sv` 已新增 directed/random 测试，覆盖正常 18-cycle 延迟、四类
  DIV/REM op、除零、signed overflow、busy ready、输出背压、in-flight kill、
  unrelated checkpoint clear、OUTPUT kill 和 exception flush。QuestaSim 最小测试和 22 项
  当前回归均通过，`Errors: 0, Warnings: 0`。Vivado 5 ns OOC 时序验证待运行后补充最终 WNS/资源。
- `test/tb_muldiv_frontend.sv` 覆盖 MUL/DIV 基本路由、DIV busy 下 MUL 继续接受、
  DIV busy 拒绝第二个 DIV，以及 recovery 对 MUL/DIV 子单元的转发 kill。QuestaSim 最小测试和
  22 项当前回归均通过，`Errors: 0, Warnings: 0`。Vivado 5 ns OOC 时序验证待运行后补充最终 WNS/资源。
- `test/tb_backend_mdu_cluster.sv` 覆盖 Backend MDU 集成边界中的 MUL 写回、DIV 写回、
  MDU issue occupancy 清空、ROB retire 和 backend idle 收敛。QuestaSim 2024.1 已复跑
  `tb_backend_mdu_cluster`、`tb_backend_lsu_cluster`、`tb_backend_int_cluster`、
  `tb_commit_recovery_cluster`、`tb_muldiv_frontend`，全部 `Errors: 0`。Vivado 5 ns
  首次 OOC WNS `-0.339 ns`，已加入 2-entry MDU execute FIFO timing cut；复测 WNS
  `-0.204 ns`，失败端点降到 `164`，loops `0`。剩余最差路径为 Issue Arbiter 内部
  route 主导路径，当前冻结 Backend MDU Cluster，等待 FPGA 后端实现阶段吸收。
- 为支持 `frontend_backend_cluster`，`tb_backend_mdu_cluster` 已补齐
  `branch_update_valid_o/branch_update_o` 端口连接并复跑通过，`Errors: 0`。
