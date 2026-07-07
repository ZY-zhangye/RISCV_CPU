`timescale 1ns/1ps

import core_types_pkg::*;

// rat_amt.sv
// 寄存器别名表与活跃映射表 (Register Alias Table & Active Map Table)
// 职责：
// 1. 维护 Speculative RAT (寄存器别名表 `rat_q`)：保存架构寄存器到最新物理寄存器的映射关系，供译码/重命名级查询；
// 2. 维护 Committed AMT (活跃映射表 `amt_q`)：保存已提交（Retire）的架构寄存器到物理寄存器的映射关系；
// 3. 维护物理寄存器就绪状态表 (`prd_ready_q`)：记录每个物理寄存器数据是否已写回就绪；
// 4. 实现分支检查点（Checkpoint）备份与恢复：在分支指令发射时备份 Speculative RAT，在分支误预测时一拍快速回滚；
// 5. 实现精确异常（Exception）恢复：在发生异常时，多周期（16个时钟周期，每周期恢复2项）将 Speculative RAT 恢复至 AMT，避免一拍大面积赋值带来的时序瓶颈。

module rat_amt (
    input  logic                         clk_i,             // 时钟信号
    input  logic                         rst_i,             // 复位信号 (高电平有效)

    // 读端口接口 (译码与重命名级查询)
    input  logic [4:0]                   lane0_rs1_i,       // lane0 源寄存器 1 架构索引
    input  logic [4:0]                   lane0_rs2_i,       // lane0 源寄存器 2 架构索引
    input  logic [4:0]                   lane0_rd_i,        // lane0 目的寄存器架构索引 (用于查询 old_prd)
    input  logic [4:0]                   lane1_rs1_i,       // lane1 源寄存器 1 架构索引
    input  logic [4:0]                   lane1_rs2_i,       // lane1 源寄存器 2 架构索引
    input  logic [4:0]                   lane1_rd_i,        // lane1 目的寄存器架构索引 (用于查询 old_prd)
    output logic [PRD_W-1:0]             lane0_prs1_o,      // lane0 重命名后的物理源寄存器 1
    output logic [PRD_W-1:0]             lane0_prs2_o,      // lane0 重命名后的物理源寄存器 2
    output logic [PRD_W-1:0]             lane0_old_prd_o,   // lane0 对应的旧物理目的寄存器
    output logic [PRD_W-1:0]             lane1_prs1_o,      // lane1 重命名后的物理源寄存器 1
    output logic [PRD_W-1:0]             lane1_prs2_o,      // lane1 重命名后的物理源寄存器 2
    output logic [PRD_W-1:0]             lane1_old_prd_o,   // lane1 对应的旧物理目的寄存器
    input  logic [PRD_W-1:0]             ready_prs0_i,      // ready 查询 PRD 0 (已寄存映射)
    input  logic [PRD_W-1:0]             ready_prs1_i,      // ready 查询 PRD 1 (已寄存映射)
    input  logic [PRD_W-1:0]             ready_prs2_i,      // ready 查询 PRD 2 (已寄存映射)
    input  logic [PRD_W-1:0]             ready_prs3_i,      // ready 查询 PRD 3 (已寄存映射)
    output logic                         lane0_src1_ready_o,// lane0 物理源寄存器 1 就绪指示
    output logic                         lane0_src2_ready_o,// lane0 物理源寄存器 2 就绪指示
    output logic                         lane1_src1_ready_o,// lane1 物理源寄存器 1 就绪指示
    output logic                         lane1_src2_ready_o,// lane1 物理源寄存器 2 就绪指示

    // 重命名级 Speculative 写入端口 (指令离开重命名 R1 并成功发射时写入)
    input  logic [1:0]                   spec_write_valid_i,// 两路 Speculative 写入有效位
    input  logic [4:0]                   spec_write_rd0_i,  // lane0 目的架构寄存器
    input  logic [4:0]                   spec_write_rd1_i,  // lane1 目的架构寄存器
    input  logic [PRD_W-1:0]             spec_write_prd0_i, // lane0 新分配的物理寄存器
    input  logic [PRD_W-1:0]             spec_write_prd1_i, // lane1 新分配的物理寄存器

    // 提交级 (Commit) 写入端口 (指令退休时更新 AMT)
    input  commit_map_t                  commit_map0_i,     // lane0 提交映射信息 (包含 arch_rd, prd)
    input  commit_map_t                  commit_map1_i,     // lane1 提交映射信息 (包含 arch_rd, prd)
    input  logic [1:0]                   wb_ready_valid_i,  // 写回总线 ready 广播有效位
    input  logic [PRD_W-1:0]             wb_ready_prd0_i,   // 写回就绪的物理寄存器 0
    input  logic [PRD_W-1:0]             wb_ready_prd1_i,   // 写回就绪的物理寄存器 1

    // 分支备份与清除接口
    input  logic                         checkpoint_save_i,     // 分支指令重命名成功，保存检查点使能
    input  logic [CP_W-1:0]              checkpoint_id_i,       // 保存的分支检查点 ID
    input  logic                         checkpoint_after_lane1_i, // 检查点是在 lane1 之后保存 (还是 lane0 之后)
    input  logic                         checkpoint_clear_i,    // 分支预测正确，释放对应的检查点
    input  logic [CP_W-1:0]              checkpoint_clear_id_i, // 释放的检查点 ID
    output logic [CHECKPOINTS-1:0]        active_branch_mask_o,  // 输出当前激活的投机分支掩码
    output logic [PRD_W-1:0]              amt_map_o [0:ARCH_REGS-1],

    // 恢复控制接口 (分支误预测或精确异常)
    input  recovery_t                    recovery_i,            // 恢复控制包
    output logic                         restore_busy_o,        // 物理表忙于精确异常回滚指示 (暂停重命名)
    output logic                         recovery_done_o        // 恢复完成脉冲
);

  // 核心存储结构
  logic [PRD_W-1:0] rat_q [0:ARCH_REGS-1];      // Speculative RAT (32项)
  logic [PRD_W-1:0] amt_q [0:ARCH_REGS-1];      // Architectural AMT (32项)
  logic [PHYS_REGS-1:0] prd_ready_q;            // 物理寄存器就绪状态位图 (64位)

  // 投机检查点存储：保存发生分支指令时的整个 RAT 快照以及分支掩码
  logic [PRD_W-1:0] checkpoint_rat_q [0:CHECKPOINTS-1][0:ARCH_REGS-1];
  logic [CHECKPOINTS-1:0] checkpoint_valid_q;   // 检查点有效标志
  logic [CHECKPOINTS-1:0] checkpoint_mask_q [0:CHECKPOINTS-1]; // 各检查点保存时的分支嵌套掩码
  logic [CHECKPOINTS-1:0] active_branch_mask_q; // 当前在途激活的所有投机分支掩码

  // 精确异常恢复控制状态
  logic restore_busy_q;                         // 正在将 AMT 回制到 RAT
  logic [4:0] restore_index_q;                  // 当前恢复的架构寄存器索引
  logic recovery_done_q;                        // 恢复完成信号

  // ==========================================================================
  // 查询通路 (Combinational Read Paths)
  // ==========================================================================
  // 从 Speculative RAT 中根据架构索引查找对应的最新物理寄存器号
  assign lane0_prs1_o = rat_q[lane0_rs1_i];
  assign lane0_prs2_o = rat_q[lane0_rs2_i];
  assign lane0_old_prd_o = rat_q[lane0_rd_i];
  assign lane1_prs1_o = rat_q[lane1_rs1_i];
  assign lane1_prs2_o = rat_q[lane1_rs2_i];
  assign lane1_old_prd_o = rat_q[lane1_rd_i];

  // 查询对应的物理寄存器当前数据是否已经写回就绪 (Ready)
  // Ready 查询地址来自 Rename 中已寄存的映射结果，避免 RAT map mux 与
  // ready mux 同拍级联。
  assign lane0_src1_ready_o = prd_ready_q[ready_prs0_i];
  assign lane0_src2_ready_o = prd_ready_q[ready_prs1_i];
  assign lane1_src1_ready_o = prd_ready_q[ready_prs2_i];
  assign lane1_src2_ready_o = prd_ready_q[ready_prs3_i];

  assign active_branch_mask_o = active_branch_mask_q;
  assign restore_busy_o = restore_busy_q;
  assign recovery_done_o = recovery_done_q;

  generate
    for (genvar map_index = 0; map_index < ARCH_REGS; map_index = map_index + 1) begin : gen_amt_map
      assign amt_map_o[map_index] = amt_q[map_index];
    end
  endgenerate

  // ==========================================================================
  // 映射状态更新与异常恢复时序逻辑 (State Update & Recovery Logic)
  // ==========================================================================
  always_ff @(posedge clk_i) begin : rat_state
    integer index;
    integer cp_index;

    if (rst_i) begin
      // 复位时：RAT 与 AMT 均初始化为 1-to-1 映射关系 (R0->P0, R1->P1, ... R31->P31)
      for (index = 0; index < ARCH_REGS; index = index + 1) begin
        rat_q[index] <= index[PRD_W-1:0];
        amt_q[index] <= index[PRD_W-1:0];
      end
      prd_ready_q <= '1;                         // 初始物理寄存器均设为 Ready
      checkpoint_valid_q <= '0;
      active_branch_mask_q <= '0;
      restore_busy_q <= 1'b0;
      restore_index_q <= 5'd0;
      recovery_done_q <= 1'b0;
    end else begin
      recovery_done_q <= 1'b0;

      // 1. 分支预测失败恢复 (REC_BRANCH)
      // 若触发分支误预测，立即一拍将 Speculative RAT 从备份的检查点快照中还原。
      if (recovery_i.valid && (recovery_i.cause == REC_BRANCH)) begin
        if (checkpoint_valid_q[recovery_i.checkpoint_id]) begin
          for (index = 0; index < ARCH_REGS; index = index + 1)
            rat_q[index] <= checkpoint_rat_q[recovery_i.checkpoint_id][index];
          active_branch_mask_q <= checkpoint_mask_q[recovery_i.checkpoint_id];
          checkpoint_valid_q[recovery_i.checkpoint_id] <= 1'b0;
        end
        restore_busy_q <= 1'b0;
        recovery_done_q <= 1'b1;
      end

      // 2. 精确异常恢复开始 (REC_EXCEPT)
      // 若发生精确异常或中断，触发多周期 AMT -> RAT 恢复流程，清空分支快照并启动 restore_busy
      else if (recovery_i.valid && (recovery_i.cause == REC_EXCEPT)) begin
        restore_busy_q <= 1'b1;
        restore_index_q <= 5'd0;
        active_branch_mask_q <= '0;
        checkpoint_valid_q <= '0;
      end

      // 3. 精确异常多周期串行拷贝中
      // 为了避免一拍内对 32 个 6-bit 寄存器同时进行 AMT 覆盖带来的巨大布线与扇出延迟，
      // 该设计每周期仅将 2 个架构寄存器的映射关系由 AMT 拷回 RAT，耗时 16 个周期。
      else if (restore_busy_q) begin
        rat_q[restore_index_q] <= amt_q[restore_index_q];
        rat_q[restore_index_q + 1'b1] <= amt_q[restore_index_q + 1'b1];
        if (restore_index_q == 5'd30) begin
          restore_busy_q <= 1'b0;
          restore_index_q <= 5'd0;
          recovery_done_q <= 1'b1;
        end else begin
          restore_index_q <= restore_index_q + 5'd2;
        end
      end

      // 4. 正常执行时状态维护 (Normal Execution Path)
      else begin
        // A. 提交更新 AMT (Commit update)
        // 退休物理寄存器在 Commit 阶段真正写入 AMT。
        if (commit_map0_i.valid && (commit_map0_i.arch_rd != 0))
          amt_q[commit_map0_i.arch_rd] <= commit_map0_i.prd;
        if (commit_map1_i.valid && (commit_map1_i.arch_rd != 0))
          amt_q[commit_map1_i.arch_rd] <= commit_map1_i.prd;

        // B. 写回就绪状态更新 (Writeback ready bits update)
        // 执行单元完成计算并写回物理寄存器时，将其在就绪表中置 1。
        if (wb_ready_valid_i[0] && (wb_ready_prd0_i != 0))
          prd_ready_q[wb_ready_prd0_i] <= 1'b1;
        if (wb_ready_valid_i[1] && (wb_ready_prd1_i != 0))
          prd_ready_q[wb_ready_prd1_i] <= 1'b1;

        // C. 分支解析正确释放 (Branch resolve clean)
        // 分支被正确预测且退休时，释放对应的检查点，并清除投机掩码。
        if (checkpoint_clear_i) begin
          active_branch_mask_q[checkpoint_clear_id_i] <= 1'b0;
          checkpoint_valid_q[checkpoint_clear_id_i] <= 1'b0;
          for (index = 0; index < CHECKPOINTS; index = index + 1)
            checkpoint_mask_q[index][checkpoint_clear_id_i] <= 1'b0;
        end

        // D. 建立分支投机检查点 (Branch Checkpoint saving)
        // 当有分支指令重命名成功时，备份当前整个 Speculative RAT。
        // 特别注意：备份必须包含本周期正在 spec 写入的寄存器重映像结果（spec_write_prdX）。
        if (checkpoint_save_i) begin
          cp_index = checkpoint_id_i;
          checkpoint_valid_q[cp_index] <= 1'b1;
          checkpoint_mask_q[cp_index] <= active_branch_mask_q;

          for (index = 0; index < ARCH_REGS; index = index + 1) begin
            checkpoint_rat_q[cp_index][index] <= rat_q[index];

            // 如果本周期有对该架构寄存器的 spec 写入，备份对应的最新物理寄存器
            if (spec_write_valid_i[0] && (spec_write_rd0_i == index) &&
                (spec_write_rd0_i != 0))
              checkpoint_rat_q[cp_index][index] <= spec_write_prd0_i;

            // 若检查点建立在 lane1 指令之后，且 lane1 也对该寄存器有 spec 写入，则进一步覆盖
            if (checkpoint_after_lane1_i && spec_write_valid_i[1] &&
                (spec_write_rd1_i == index) && (spec_write_rd1_i != 0))
              checkpoint_rat_q[cp_index][index] <= spec_write_prd1_i;
          end
          active_branch_mask_q[cp_index] <= 1'b1;
        end

        // E. 寄存器重命名 Speculative 写入 (Speculative Rename update)
        // 当指令离开重命名流水级并成功发射时，更新 Speculative RAT 映射关系，
        // 并且由于物理目的寄存器尚未被真正写回，在就绪状态表中将其清 0。
        if (spec_write_valid_i[0] && (spec_write_rd0_i != 0)) begin
          rat_q[spec_write_rd0_i] <= spec_write_prd0_i;
          prd_ready_q[spec_write_prd0_i] <= 1'b0;
        end
        if (spec_write_valid_i[1] && (spec_write_rd1_i != 0)) begin
          rat_q[spec_write_rd1_i] <= spec_write_prd1_i;
          prd_ready_q[spec_write_prd1_i] <= 1'b0;
        end
      end

      // 保证架构 0 号寄存器 (x0/zero) 恒映射为物理 0 且始终就绪
      rat_q[0] <= '0;
      amt_q[0] <= '0;
      prd_ready_q[0] <= 1'b1;
    end
  end

  // ==========================================================================
  // 系统断言 (SystemVerilog Assertions)
  // ==========================================================================
`ifdef RAT_AMT_ASSERTIONS
  // 断言：x0 寄存器映射必须始终满足零寄存器契约
  property p_zero_mapping;
    @(posedge clk_i) rat_q[0] == 0 && amt_q[0] == 0 && prd_ready_q[0];
  endproperty
  assert property (p_zero_mapping);
`endif

endmodule
