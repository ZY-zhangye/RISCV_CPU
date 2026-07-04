`timescale 1ns/1ps

import core_types_pkg::*;

// rename_stage.sv
// 寄存器重命名流水级 (Register Rename Stage)
// 职责：
// 1. 将译码阶段输入的架构寄存器索引（rs1, rs2, rd）映射为物理寄存器索引（prs1, prs2, prd）；
// 2. 实现两级重命名流水线（R0 读映射表 RAT，R1 向 Free List/ROB/LSQ 发起资源分配请求并执行重映射更新）；
// 3. 处理双路超标量组内的数据相关性（Intra-group Dependencies）：
//    - RAW（写读相关）：若 Lane 1 读取 Lane 0 正在写入的 rd，则直接前传重命名结果；
//    - WAW（写写相关）：若两路同时写入相同的 rd，修正旧目的物理寄存器（old_prd）以备正确释放；
// 4. 维护分支投机执行机制：限制每周期最多分配 1 个分支检查点，处理分支掩码（Branch Mask）继承，
//    并在发生分支误预测/异常时执行 RAT 状态回滚恢复。

module rename_stage (
    input  logic                         clk_i,             // 时钟信号
    input  logic                         rst_i,             // 复位信号 (高电平有效)

    // 前级译码级（Decode）输入接口
    input  logic [1:0]                   dec_valid_i,       // 译码指令有效位
    output logic                         dec_ready_o,       // 译码级就绪，允许接收译码结果 (反压)
    input  decoded_uop_t                 dec_uop0_i,        // lane0 译码微操作 payload
    input  decoded_uop_t                 dec_uop1_i,        // lane1 译码微操作 payload

    // 后级发射/分派（Dispatch/Issue）输出接口
    output logic [1:0]                   rn_valid_o,        // 重命名微操作有效位
    input  logic                         rn_ready_i,        // 后级就绪信号 (反压)
    output renamed_uop_t                 rn_uop0_o,         // lane0 重命名后的微操作 payload
    output renamed_uop_t                 rn_uop1_o,         // lane1 重命名后的微操作 payload

    // 外部物理资源分配（Allocation）接口 (向 Free List、ROB、LSQ 申请)
    output alloc_req_t                   alloc_req_o,       // 资源分配请求包
    input  alloc_resp_t                  alloc_resp_i,      // 资源分配响应包
    output logic                         alloc_fire_o,      // 分配成功确认信号 (与 rn_fire 同步)
    output logic                         alloc_cancel_o,    // 分配取消信号 (在 R1 阶段遭遇 flush 冲刷时有效)

    // 物理映射表 (RAT/AMT) 的更新维护信号
    input  commit_map_t                  commit_map0_i,     // commit 阶段 lane0 回收 AMT 映射
    input  commit_map_t                  commit_map1_i,     // commit 阶段 lane1 回收 AMT 映射
    input  logic [1:0]                   wb_ready_valid_i,  // 写回总线 ready 广播有效位
    input  logic [PRD_W-1:0]             wb_ready_prd0_i,   // 写回 prd0
    input  logic [PRD_W-1:0]             wb_ready_prd1_i,   // 写回 prd1

    // 分支释放与投机恢复控制
    input  logic                         checkpoint_clear_i,     // 分支预测正确，清空对应检查点信号
    input  logic [CP_W-1:0]              checkpoint_clear_id_i,  // 释放的检查点 ID
    input  recovery_t                    recovery_i,             // 恢复控制请求 (分支误预测或精确异常)
    output logic                         recovery_done_o         // 物理表恢复完毕指示
);

  // R0 流水线寄存器：锁存译码级输入
  logic [1:0] r0_valid_q;
  decoded_uop_t r0_uop0_q;
  decoded_uop_t r0_uop1_q;

  // R1 流水线寄存器：锁存重命名后的微操作，等待后级 Rename Ready 并发起资源分配
  logic [1:0] r1_valid_q;
  renamed_uop_t r1_uop0_q;
  renamed_uop_t r1_uop1_q;

  // 从 RAT 读取的物理寄存器映射及状态连线
  logic [PRD_W-1:0] lane0_prs1;
  logic [PRD_W-1:0] lane0_prs2;
  logic [PRD_W-1:0] lane0_old_prd;
  logic [PRD_W-1:0] lane1_prs1_base;
  logic [PRD_W-1:0] lane1_prs2_base;
  logic [PRD_W-1:0] lane1_old_prd_base;
  logic lane0_src1_ready;
  logic lane0_src2_ready;
  logic lane1_src1_ready_base;
  logic lane1_src2_ready_base;

  // 结合写回旁路计算出的操作数即时就绪状态 (Instant Ready)
  logic lane0_src1_ready_now;
  logic lane0_src2_ready_now;
  logic lane1_src1_ready_now;
  logic lane1_src2_ready_now;

  // 分支控制掩码与恢复状态
  logic [CHECKPOINTS-1:0] active_branch_mask;     // 物理表当前处于激活状态的投机分支掩码
  logic [CHECKPOINTS-1:0] effective_branch_mask;  // 排除当前周期被 Clear 后的有效分支掩码
  logic rat_restore_busy;                         // 物理表忙于从检查点或 AMT 恢复状态
  logic rat_recovery_done;                        // 物理表恢复完成

  // 操作类型预解析
  logic lane0_is_load;
  logic lane0_is_store;
  logic lane0_is_branch;
  logic lane1_is_load;
  logic lane1_is_store;
  logic lane1_is_branch;

  logic truncate_lane1;                           // 超标量合并限制：强制截断 lane1（如两路都是分支跳转）
  logic [1:0] requested_lanes;                    // R0 向 R1 发起重命名的有效路数
  logic [1:0] granted_lanes;                      // 分配器授权成功的有效路数
  logic r1_load;                                  // R1 寄存器加载使能信号
  logic rn_fire;                                  // 重命名向分派阶段发射的握手确认信号
  logic partial_fire;                             // 部分发射标志 (超标量组拆包：只发射了 lane0，lane1 需暂留重拍)

  // 物理映射表 spec 更新控制
  logic [1:0] spec_write_valid;                   // speculative 写入 RAT 使能
  logic checkpoint_save;                          // 确认需要保存分支检查点
  logic checkpoint_after_lane1;                   // 检查点是否在 lane1 指令之后建立
  logic [CP_W-1:0] checkpoint_save_id;            // 保存的检查点 ID

  // ==========================================================================
  // 辅助解析函数
  // ==========================================================================
  function automatic logic is_load(input decoded_uop_t uop);
    is_load = (uop.fu_type == FU_LSU) && (uop.mem_op <= MEM_LHU);
  endfunction

  function automatic logic is_store(input decoded_uop_t uop);
    is_store = (uop.fu_type == FU_LSU) && (uop.mem_op >= MEM_SB);
  endfunction

  assign lane0_is_load   = is_load(r0_uop0_q);
  assign lane0_is_store  = is_store(r0_uop0_q);
  assign lane0_is_branch = (r0_uop0_q.fu_type == FU_BRANCH);
  assign lane1_is_load   = is_load(r0_uop1_q);
  assign lane1_is_store  = is_store(r0_uop1_q);
  assign lane1_is_branch = (r0_uop1_q.fu_type == FU_BRANCH);

  // 计算有效的投机分支掩码（剔除当前周期正常解析并释放的分支点）
  always @* begin
    effective_branch_mask = active_branch_mask;
    if (checkpoint_clear_i)
      effective_branch_mask[checkpoint_clear_id_i] = 1'b0;
  end

  // ==========================================================================
  // 写回旁路前传 (Writeback Bypass Network)
  // ==========================================================================
  // 当从 RAT 读出物理寄存器时，如果该物理寄存器正巧在当前时钟周期执行写回（Ready 广播），
  // 则可以直接前传（Bypass）将其标记为 Ready，避免产生额外的时序气泡。
  assign lane0_src1_ready_now = lane0_src1_ready ||
      (wb_ready_valid_i[0] && (wb_ready_prd0_i == lane0_prs1)) ||
      (wb_ready_valid_i[1] && (wb_ready_prd1_i == lane0_prs1));
  assign lane0_src2_ready_now = lane0_src2_ready ||
      (wb_ready_valid_i[0] && (wb_ready_prd0_i == lane0_prs2)) ||
      (wb_ready_valid_i[1] && (wb_ready_prd1_i == lane0_prs2));
  assign lane1_src1_ready_now = lane1_src1_ready_base ||
      (wb_ready_valid_i[0] && (wb_ready_prd0_i == lane1_prs1_base)) ||
      (wb_ready_valid_i[1] && (wb_ready_prd1_i == lane1_prs1_base));
  assign lane1_src2_ready_now = lane1_src2_ready_base ||
      (wb_ready_valid_i[0] && (wb_ready_prd0_i == lane1_prs2_base)) ||
      (wb_ready_valid_i[1] && (wb_ready_prd1_i == lane1_prs2_base));

  // ==========================================================================
  // 超标量结构限制与重命名请求生成
  // ==========================================================================
  // 结构限制：因为硬件每周期最多分配 1 个分支检查点，
  // 如果超标量组内的两条指令（Lane 0 和 Lane 1）全是分支跳转，则必须截断 Lane 1。
  // 被截断的 Lane 1 之后会在 R0 中“重拍”平移到 Lane 0 重新处理。
  assign truncate_lane1 = r0_valid_q[0] && r0_valid_q[1] &&
                          lane0_is_branch && lane1_is_branch;
  assign requested_lanes[0] = r0_valid_q[0];
  assign requested_lanes[1] = r0_valid_q[1] && !truncate_lane1;

  // 拼装向物理资源池（ROB/Free List/LSQ）发起的分配请求
  always @* begin
    alloc_req_o = '0;
    alloc_req_o.valid = (requested_lanes != 2'b00) &&
                        (r1_valid_q == 2'b00) && !rat_restore_busy &&
                        !recovery_i.valid;
    alloc_req_o.lane_valid = requested_lanes;
    alloc_req_o.need_prd[0] = requested_lanes[0] && r0_uop0_q.write_rd;
    alloc_req_o.need_prd[1] = requested_lanes[1] && r0_uop1_q.write_rd;
    alloc_req_o.need_lq[0] = requested_lanes[0] && lane0_is_load;
    alloc_req_o.need_lq[1] = requested_lanes[1] && lane1_is_load;
    alloc_req_o.need_sq[0] = requested_lanes[0] && lane0_is_store;
    alloc_req_o.need_sq[1] = requested_lanes[1] && lane1_is_store;
    alloc_req_o.need_checkpoint[0] = requested_lanes[0] && lane0_is_branch;
    alloc_req_o.need_checkpoint[1] = requested_lanes[1] && lane1_is_branch;
  end

  // 计算授权路数 (必须是两路皆成功，或仅成功了第 0 路，不允许发生只授权第 1 路的逆向情况)
  assign granted_lanes[0] = alloc_resp_i.valid && alloc_req_o.valid &&
                            alloc_resp_i.lane_valid[0] && requested_lanes[0];
  assign granted_lanes[1] = alloc_resp_i.valid && alloc_req_o.valid &&
                            alloc_resp_i.lane_valid[1] && requested_lanes[1] &&
                            granted_lanes[0];

  // 资源成功分配后，允许将数据载入 R1 流水寄存器
  assign r1_load = (r1_valid_q == 2'b00) && (granted_lanes != 2'b00);

  // ==========================================================================
  // 发射与反压逻辑
  // ==========================================================================
  assign rn_valid_o = recovery_i.valid ? 2'b00 : r1_valid_q;
  assign rn_uop0_o = r1_uop0_q;
  assign rn_uop1_o = r1_uop1_q;

  // 重命名与后级 Dispatch 握手成功
  assign rn_fire = (rn_valid_o != 2'b00) && rn_ready_i;
  assign alloc_fire_o = rn_fire;
  // 若 R1 阶段中发生了硬冲刷重定向，则需要撤销当前已经向资源池申请分配但未送出的资源
  assign alloc_cancel_o = recovery_i.valid && (r1_valid_q != 2'b00);

  // 部分发射：只发射了 lane0（有效且 ready），但 lane1 有效且未被发射，需要将 lane1 移至下个周期的 lane0 重新调度
  assign partial_fire = rn_fire && (r1_valid_q == 2'b01) && r0_valid_q[1];

  // 译码级反压就绪：没有硬恢复、物理表没有在回滚、且 R0 流水寄存器已被读走清空
  assign dec_ready_o = !recovery_i.valid && !rat_restore_busy &&
                       (r0_valid_q == 2'b00);

  // 只有当重命名结果成功发射给 Dispatch 阶段后，才允许 Speculative 更新 speculative RAT 映射表
  assign spec_write_valid[0] = rn_fire && r1_valid_q[0] &&
                               r1_uop0_q.dec.write_rd;
  assign spec_write_valid[1] = rn_fire && r1_valid_q[1] &&
                               r1_uop1_q.dec.write_rd;

  // 检查点备份控制
  assign checkpoint_save = rn_fire &&
      ((r1_valid_q[0] && (r1_uop0_q.dec.fu_type == FU_BRANCH)) ||
       (r1_valid_q[1] && (r1_uop1_q.dec.fu_type == FU_BRANCH)));
  assign checkpoint_after_lane1 = r1_valid_q[1] &&
                                  (r1_uop1_q.dec.fu_type == FU_BRANCH);
  assign checkpoint_save_id = checkpoint_after_lane1 ?
                               r1_uop1_q.checkpoint_id : r1_uop0_q.checkpoint_id;

  // ==========================================================================
  // 实例化寄存器别名表/活跃映射表 (RAT/AMT) 物理模块
  // ==========================================================================
  rat_amt u_rat_amt (
      .clk_i,
      .rst_i,
      .lane0_rs1_i(r0_uop0_q.rs1),
      .lane0_rs2_i(r0_uop0_q.rs2),
      .lane0_rd_i(r0_uop0_q.rd),
      .lane1_rs1_i(r0_uop1_q.rs1),
      .lane1_rs2_i(r0_uop1_q.rs2),
      .lane1_rd_i(r0_uop1_q.rd),

      .lane0_prs1_o(lane0_prs1),
      .lane0_prs2_o(lane0_prs2),
      .lane0_old_prd_o(lane0_old_prd),
      .lane1_prs1_o(lane1_prs1_base),
      .lane1_prs2_o(lane1_prs2_base),
      .lane1_old_prd_o(lane1_old_prd_base),

      .lane0_src1_ready_o(lane0_src1_ready),
      .lane0_src2_ready_o(lane0_src2_ready),
      .lane1_src1_ready_o(lane1_src1_ready_base),
      .lane1_src2_ready_o(lane1_src2_ready_base),

      .spec_write_valid_i(spec_write_valid),
      .spec_write_rd0_i(r1_uop0_q.dec.rd),
      .spec_write_rd1_i(r1_uop1_q.dec.rd),
      .spec_write_prd0_i(r1_uop0_q.prd),
      .spec_write_prd1_i(r1_uop1_q.prd),

      .commit_map0_i,
      .commit_map1_i,
      .wb_ready_valid_i,
      .wb_ready_prd0_i,
      .wb_ready_prd1_i,

      .checkpoint_save_i(checkpoint_save),
      .checkpoint_id_i(checkpoint_save_id),
      .checkpoint_after_lane1_i(checkpoint_after_lane1),
      .checkpoint_clear_i,
      .checkpoint_clear_id_i,

      .active_branch_mask_o(active_branch_mask),
      .recovery_i,
      .restore_busy_o(rat_restore_busy),
      .recovery_done_o(rat_recovery_done)
  );

  assign recovery_done_o = rat_recovery_done;

  // ==========================================================================
  // 流水线寄存器更新时序逻辑 (Sequential Pipeline Control)
  // ==========================================================================
  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      r0_valid_q <= 2'b00;
      r1_valid_q <= 2'b00;
      r0_uop0_q <= '0;
      r0_uop1_q <= '0;
      r1_uop0_q <= '0;
      r1_uop1_q <= '0;
    end else if (recovery_i.valid) begin
      // 遭遇全局冲刷，清空当前重命名两级流水线的所有在途数据
      r0_valid_q <= 2'b00;
      r1_valid_q <= 2'b00;
    end else begin
      // 1. 分支预测正确释放：更新暂存在重命名级的分支掩码
      if (checkpoint_clear_i) begin
        case (checkpoint_clear_id_i)
          2'd0: begin
            r1_uop0_q.branch_mask[0] <= 1'b0;
            r1_uop1_q.branch_mask[0] <= 1'b0;
          end
          2'd1: begin
            r1_uop0_q.branch_mask[1] <= 1'b0;
            r1_uop1_q.branch_mask[1] <= 1'b0;
          end
          2'd2: begin
            r1_uop0_q.branch_mask[2] <= 1'b0;
            r1_uop1_q.branch_mask[2] <= 1'b0;
          end
          2'd3: begin
            r1_uop0_q.branch_mask[3] <= 1'b0;
            r1_uop1_q.branch_mask[3] <= 1'b0;
          end
        endcase
      end

      // 2. 握手出队：
      // 如果微操作成功发射给下一级：清空 r1 寄存器。
      // 若发生部分发射（partial_fire），将 lane1 平移锁入下周期的 lane0 重新开始重命名。
      if (rn_fire) begin
        r1_valid_q <= 2'b00;
        if (partial_fire) begin
          r0_valid_q <= 2'b01;
          r0_uop0_q <= r0_uop1_q;
        end else begin
          r0_valid_q <= 2'b00;
        end
      end

      // 3. R0 寄存器入队锁存译码数据：
      // 只有在就绪且译码输入有效时，接纳新指令进入 R0 流水寄存器。
      if (dec_ready_o && (dec_valid_i != 2'b00)) begin
        r0_valid_q[0] <= dec_valid_i[0];
        r0_valid_q[1] <= dec_valid_i[1] && dec_valid_i[0]; // 严格要求前缀有效
        if (dec_valid_i[0])
          r0_uop0_q <= dec_uop0_i;
        if (dec_valid_i[1] && dec_valid_i[0])
          r0_uop1_q <= dec_uop1_i;
      end

      // 4. R1 寄存器数据写入与重映射解算 (R0 -> R1, Rename Map logic)
      if (r1_load) begin
        r1_valid_q <= granted_lanes;

        // A. Lane 0 重命名组合填充
        r1_uop0_q <= '0;
        r1_uop0_q.dec <= r0_uop0_q;
        r1_uop0_q.prs1 <= lane0_prs1;
        r1_uop0_q.prs2 <= lane0_prs2;
        // 分配物理目的寄存器 prd 与记录被覆盖的旧物理寄存器 old_prd
        r1_uop0_q.prd <= r0_uop0_q.write_rd ? alloc_resp_i.prd[0] : '0;
        r1_uop0_q.old_prd <= r0_uop0_q.write_rd ? lane0_old_prd : '0;
        r1_uop0_q.rob_id <= alloc_resp_i.rob_id[0];
        r1_uop0_q.lq_id <= alloc_resp_i.lq_id[0];
        r1_uop0_q.sq_id <= alloc_resp_i.sq_id[0];
        r1_uop0_q.checkpoint_id <= alloc_resp_i.checkpoint_id;
        r1_uop0_q.branch_mask <= effective_branch_mask;
        // 判定操作数就绪状态：如果该指令根本不需要源操作数，或该操作数本就处于 Ready，则置为 Ready
        r1_uop0_q.src1_ready <= !r0_uop0_q.need_rs1 || lane0_src1_ready_now;
        r1_uop0_q.src2_ready <= !r0_uop0_q.need_rs2 || lane0_src2_ready_now;

        // B. Lane 1 重命名组合填充 (处理组内 RAW 与 WAW 冲突)
        if (granted_lanes[1]) begin
          r1_uop1_q <= '0;
          r1_uop1_q.dec <= r0_uop1_q;

          // 写读相关性（RAW）处理：
          // 若 Lane 1 读取的源架构寄存器等于 Lane 0 写入的目的架构寄存器（且不是 x0），
          // 则直接将 Lane 1 的物理源寄存器绑定到分配给 Lane 0 的 prd[0] 上；否则，使用 RAT 的正常输出。
          r1_uop1_q.prs1 <= (r0_uop0_q.write_rd &&
              (r0_uop0_q.rd == r0_uop1_q.rs1) && (r0_uop1_q.rs1 != 0)) ?
              alloc_resp_i.prd[0] : lane1_prs1_base;
          r1_uop1_q.prs2 <= (r0_uop0_q.write_rd &&
              (r0_uop0_q.rd == r0_uop1_q.rs2) && (r0_uop1_q.rs2 != 0)) ?
              alloc_resp_i.prd[0] : lane1_prs2_base;

          r1_uop1_q.prd <= r0_uop1_q.write_rd ? alloc_resp_i.prd[1] : '0;

          // 写写相关性（WAW）处理：
          // 若 Lane 1 与 Lane 0 写入同一个架构寄存器（且不是 x0），则被 Lane 1 覆盖的“旧”物理寄存器
          // 实际上是刚刚分配给 Lane 0 的物理寄存器 prd[0]，这样才能保证将来 Retire 时回收逻辑正常。
          r1_uop1_q.old_prd <= (r0_uop1_q.write_rd && r0_uop0_q.write_rd &&
              (r0_uop0_q.rd == r0_uop1_q.rd) && (r0_uop1_q.rd != 0)) ?
              alloc_resp_i.prd[0] :
              (r0_uop1_q.write_rd ? lane1_old_prd_base : '0);

          r1_uop1_q.rob_id <= alloc_resp_i.rob_id[1];
          r1_uop1_q.lq_id <= alloc_resp_i.lq_id[1];
          r1_uop1_q.sq_id <= alloc_resp_i.sq_id[1];
          r1_uop1_q.checkpoint_id <= alloc_resp_i.checkpoint_id;

          // 投机掩码继承：
          // 若 Lane 0 为分支指令，则 Lane 1 执行时必须投机在该分支指令之下（更新 Lane 1 的 Branch Mask）
          r1_uop1_q.branch_mask <= effective_branch_mask |
              ((lane0_is_branch) ?
               ({{(CHECKPOINTS-1){1'b0}}, 1'b1} << alloc_resp_i.checkpoint_id) : '0);

          // RAW 下的操作数就绪状态判定：
          // 若存在 RAW 冲突，则 Lane 1 的该操作数不可能在发射时 Ready（必须设为 0，等待 Lane 0 执行完毕写回前传）
          r1_uop1_q.src1_ready <= !r0_uop1_q.need_rs1 ||
              !((r0_uop0_q.write_rd) && (r0_uop0_q.rd == r0_uop1_q.rs1) &&
                (r0_uop1_q.rs1 != 0)) && lane1_src1_ready_now;
          r1_uop1_q.src2_ready <= !r0_uop1_q.need_rs2 ||
              !((r0_uop0_q.write_rd) && (r0_uop0_q.rd == r0_uop1_q.rs2) &&
                (r0_uop1_q.rs2 != 0)) && lane1_src2_ready_now;
        end
      end
    end
  end

  // ==========================================================================
  // 系统断言 (SystemVerilog Assertions)
  // ==========================================================================
`ifdef RENAME_STAGE_ASSERTIONS
  // 断言 1：输入有效位必须符合前缀有效原则 (不能是 2'b10)
  property p_input_prefix;
    @(posedge clk_i) disable iff (rst_i) dec_valid_i != 2'b10;
  endproperty
  assert property (p_input_prefix);

  // 断言 2：输出有效位必须符合前缀有效原则 (不能是 2'b10)
  property p_output_prefix;
    @(posedge clk_i) disable iff (rst_i) rn_valid_o != 2'b10;
  endproperty
  assert property (p_output_prefix);

  // 断言 3：架构寄存器 x0 (Zero 寄存器) 绝不能被重分配，且映射物理寄存器 prd 必须恒为 0
  property p_x0_not_allocated;
    @(posedge clk_i) disable iff (rst_i)
      spec_write_valid[0] |-> (r1_uop0_q.dec.rd != 0 && r1_uop0_q.prd != 0);
  endproperty
  assert property (p_x0_not_allocated);
`endif

endmodule
