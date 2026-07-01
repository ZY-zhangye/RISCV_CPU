# 前后端集成与分层回归验证计划

更新时间：2026-06-30

## 总结

下一阶段连接 `IF/ID → backend_top`，形成可运行 RV32I/M/Zicsr 程序的 `core_top.sv`，使用统一行为内存完成验证；Cache、UART、Timer、PLIC 和完整 SoC 暂不实现。

本文件只记录已经确定的后续方案。写入计划后不立即实施 RTL 或测试代码，实际开发需要单独开始。

当前进度（2026-07-01）：IF/ID→Backend 的 `core_top.sv`、统一 recovery、FENCE.I 重取和 `retire_next_pc` 已完成；Core 外统一行为内存及 DMEM 外部寄存级已建立；RV32I 整数 ALU、移位、比较、分支跳转及 byte/half/word 访存单项测试均已通过。下一门禁为 RV32M 和 CSR/SYSTEM 单项测试。

## 关键设计

- 将 IF、ID 改用 typed `recover_event_t` 和 `branch_update_t`，统一分支、异常、中断与 FENCE.I 恢复。
- 新增 `RECOVER_FENCE_I`。FENCE.I 提交并等待 LSQ 清空后：
  - 输出失效通知；
  - 清空 Rename、ID、IF 中的年轻指令；
  - 从 FENCE.I 的 `PC+4` 重新取指。
- ROB completion/commit 增加分支实际下一 PC。Backend 维护 `retire_next_pc`：
  - 复位为参数化 `RESET_PC`；
  - 普通提交更新为最年轻提交指令的 `PC+4`；
  - 分支使用实际下一 PC；
  - recovery 使用恢复目标；
  - 空 ROB 中断直接使用该寄存器，不再依赖外部 `interrupt_pc_i`。
- 新增 `core_top.sv`，连接 IF、ID 和 Backend：
  - 保留固定一周期、64-bit 同步 IMEM 接口；
  - 保留现有 typed DMEM ready/response 接口；
  - 保留乘除法 IP 适配端口、三类中断、提交追踪和恢复输出；
  - `RESET_PC` 参数默认保持兼容，回归平台设为 `0x8000_0000`。
- 本阶段不增加 IMEM access-error 输入，`ma_fetch` 明确列为暂不支持。

## 分层验证

严格按以下门禁顺序执行，前一级全部通过后才进入下一级。

### 1. 基础门禁

- 全量编译必须为 `0 Errors, 0 Warnings`。
- 保留现有十四项模块与后端集成测试，必须全部通过。

### 2. 自设单项指令测试

- 使用 SystemVerilog 指令编码函数生成微程序，避免依赖外部汇编工具。
- 每个用例复位后独立运行，只验证一个目标操作。
- 覆盖：
  - RV32I ALU、立即数、移位、比较；
  - 条件分支、JAL、JALR、LUI、AUIPC；
  - byte/half/word Load/Store 与符号扩展；
  - MUL/MULH/MULHSU/MULHU、DIV/DIVU/REM/REMU 及边界情况；
  - CSR 六种形式、ECALL、EBREAK、MRET、FENCE/FENCE.I；
  - 非法指令和访存不对齐。
- 每例通过固定结束 PC 和已提交 x3/gp 判定结果。

### 3. 自设组合场景

- 双发射、RAW/WAW、跨 IQ 唤醒、写回冲突；
- 长 DIV 与年轻 ALU 越序完成、顺序提交；
- Store forwarding、Load/Store 混排、已提交 Store 排空；
- 正确/错误预测、连续 recovery；
- 连续 CSR、异常、中断、MRET；
- 自修改代码验证 FENCE.I 清流水并重新取指。

### 4. 官方 HEX 回归

- 统一行为内存同时服务 IMEM/DMEM，确保 Store 修改可被后续取指观察。
- 通过 `+HEX=<path>` 直接加载用例，不复制或改写原始 HEX。
- 结束条件沿用旧设计：任一提交口 PC=`0x8000_0044`，随后通过 RRAT→PRF 仿真只读路径检查已提交 x3/gp：
  - `gp==1`：PASS；
  - 其他值：FAIL。
- 首版运行：
  - `rv32ui-p-*`，跳过 `ma_data`；
  - 全部八项 `rv32um-p-*`；
  - RV32MI 的 `breakpoint/csr/illegal/lh-misaligned/lw-misaligned/sh-misaligned/sw-misaligned/scall/sbreak/shamt`。
- 暂时跳过 `ma_fetch/ma_addr/mcsr/pmpaddr/zicntr/instret_overflow`，以及 S/A/C/F/D/Z 扩展，并在清单中记录原因。

## 回归基础设施

- 使用 PowerShell 作为主入口，BAT 仅作兼容包装。
- 支持 `unit`、`directed`、`official`、`all` 四种模式。
- 使用清单记录用例、HEX 路径、分组、超时周期和跳过原因。
- 默认 fail-fast；每项日志保存至忽略追踪的 `results/`。
- 超时按周期计数，默认十万周期；超时、断言、非零仿真退出码或缺少 PASS 均视为失败。
- 乘法采用固定延迟模型，除法采用 ready/valid 行为模型。

## 验收标准

- 编译 `0 Errors, 0 Warnings`。
- 原十四项测试全部保持通过。
- 所有单项指令和组合场景测试通过。
- 官方允许清单全部通过，跳过项均有明确原因。
- FENCE.I 后不存在旧指令提交。
- recovery 后 RAT/RRAT/Free List 一致，已提交 Store 保留并排空。
- 空 ROB 中断的 `mepc` 等于 `retire_next_pc`。

## 本阶段范围约束

- 不实现 Cache、MMIO、UART、Timer、PLIC 或完整 SoC。
- 不实现取指访问错误、Store access fault 精确报告、内存违例 replay、PMP 或多特权等级。
- 不修改或原地转换 `hex/` 下的回归镜像；两份旧设计回归说明作为验证思路和用例来源保留。
