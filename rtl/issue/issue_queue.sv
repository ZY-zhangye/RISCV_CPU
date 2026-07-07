import core_types_pkg::*;

// issue_queue.sv
// 参数化固定槽位发射队列 (Parameterized Fixed-Slot Issue Queue)
// 职责：
// 1. 暂存待发射的微操作，维护各个指令操作数的就绪状态（Ready Bits）；
// 2. 支持双路入队（Double Push）：从分派缓冲区接收最多 2 条 uop，写入队列中的空闲槽位；
// 3. 支持双路写回唤醒（Double Wakeup）：周期 N 写回的 PRD tag 与队列中所有未就绪操作数进行比较，
//    在周期末更新 ready bit。新唤醒的 uop 最早在周期 N+1 参与 Select 仲裁，打断单周期组合环路；
// 4. 双级流水发射选择（Two-Stage Pipelined Selection）：
//    - 队列容量划分为 `GROUPS` 个组（如 12 项划分为 3 个组，每组 4 项），每组独立发射最多 1 条指令；
//    - Stage S0a：先把 grant/wakeup/checkpoint 后可参与选择的槽位压成 `issue_eligible_q` 位图；
//    - Stage S0b：将各组内的 slots 两两配对（Pair），选出每对中 eligible 且最老的 winner，将其锁存入 `pair_valid_q` 等寄存器；
//    - Stage S1（第二级）：从每组的各对 winner 中选出最老的 winner 锁存入全局候选 `candidate_valid_q`；
//    - 候选人保持锁死（Candidate Holding）：一旦锁存，该候选人必须一直保持在输出端，直到收到全局仲裁器的 `issue_grant_i` 授权，
//      这允许全局仲裁器（Issue Arbiter）跨周期计算而不会因为候选人变化导致冲突；
// 5. 分支误预测局部清除：根据误预测分支的 checkpoint_id，一拍清除所有年轻无效项，并剔除幸存项的 branch_mask 位；
// 6. 异常清除：发生精确异常时，一拍直接清空整个发射队列。

module issue_queue #(
    parameter int ENTRIES = 12,             // 发射队列槽位总数
    parameter int GROUPS  = 3              // 发射队列的分组数 (每个组独立选出一个发射候选)
) (
    input  logic                    clk_i,             // 时钟信号
    input  logic                    rst_i,             // 复位信号 (高电平有效)

    // 分派级 (Dispatch Buffer) 输入接口
    input  logic [1:0]              push_valid_i,      // 输入 uop 有效位
    output logic                    push_ready_o,      // 发射队列未满，允许写入 (反压)
    input  issue_uop_t              push_uop0_i,       // 入队 uop0 payload
    input  issue_uop_t              push_uop1_i,       // 入队 uop1 payload

    // 写回唤醒 (Wakeup) 输入端口
    input  logic [1:0]              wb_valid_i,        // 两路写回总线有效位
    input  logic [1:0][PRD_W-1:0]   wb_prd_i,          // 两路写回物理寄存器号 (唤醒 Tag)
    input  logic [PHYS_REGS-1:0]    prf_ready_bits_i,  // PRF ready 位图，用于补偿错过的单周期 wakeup

    // 全局发射候选 (Candidates) 输出端口
    output logic [GROUPS-1:0]       candidate_valid_o, // 发射候选有效指示
    output issue_uop_t              candidate_uop0_o,  // 组 0 候选 uop
    output issue_uop_t              candidate_uop1_o,  // 组 1 候选 uop
    output issue_uop_t              candidate_uop2_o,  // 组 2 候选 uop
    output logic [$clog2(ENTRIES)-1:0] candidate_slot0_o, // 组 0 候选槽位号
    output logic [$clog2(ENTRIES)-1:0] candidate_slot1_o, // 组 1 候选槽位号
    output logic [$clog2(ENTRIES)-1:0] candidate_slot2_o, // 组 2 候选槽位号

    // 全局仲裁 (Arbiter) 授权及控制输入
    input  logic [GROUPS-1:0]       issue_grant_i,     // 仲裁授权信号 (对应各组)
    input  logic [GROUPS-1:0]       candidate_reselect_i, // 外部约束阻塞当前候选时请求重选
    input  logic                    checkpoint_clear_i, // 分支预测正确，清除对应投机掩码
    input  logic [CP_W-1:0]         checkpoint_clear_id_i,
    input  recovery_t               recovery_i,        // 恢复控制信号 (分支误预测或精确异常)

    // 发射队列状态输出
    output logic                    empty_o,           // 发射队列空指示
    output logic                    full_o,            // 发射队列满指示
    output logic [$clog2(ENTRIES+1)-1:0] occupancy_o   // 当前发射队列占用条数
);

  localparam int SLOT_W = $clog2(ENTRIES);
  localparam int COUNT_W = $clog2(ENTRIES + 1);
  localparam int GROUP_SIZE = ENTRIES / GROUPS;          // 每组拥有的槽位数 (如 12/3 = 4项)
  localparam int PAIRS_PER_GROUP = (GROUP_SIZE + 1) / 2; // 每组划分为配对对数 (如 4/2 = 2对)
  localparam int PAIR_COUNT = GROUPS * PAIRS_PER_GROUP;  // 全局总配对数 (如 3*2 = 6对)

  // ==========================================================================
  // 发射队列存储单元 (Storage split into arrays for FPGA synthesis)
  // ==========================================================================
  logic [ENTRIES-1:0] valid_q;                           // 槽位占用有效标志位
  logic [ENTRIES-1:0] src1_ready_q;                      // 源操作数 1 就绪标志
  logic [ENTRIES-1:0] src2_ready_q;                      // 源操作数 2 就绪标志
  logic [ENTRIES-1:0] need_rs1_q;                        // 指令是否需要源寄存器 1
  logic [ENTRIES-1:0] need_rs2_q;                        // 指令是否需要源寄存器 2
  logic [ROB_ID_W-1:0] rob_id_q [0:ENTRIES-1];           // 重排序缓存 ID (用于判定年龄)
  logic [PRD_W-1:0] prs1_q [0:ENTRIES-1];                // 物理源寄存器 1 号
  logic [PRD_W-1:0] prs2_q [0:ENTRIES-1];                // 物理源寄存器 2 号
  logic [CHECKPOINTS-1:0] branch_mask_q [0:ENTRIES-1];   // 分支投机掩码
  issue_uop_t payload_q [0:ENTRIES-1];                   // 微操作完整 payload 寄存器数组

  // 内部寄存器及流水线寄存器
  logic [COUNT_W-1:0] count_q;                           // 队列占用计数器

  // Stage S0 寄存器：锁存各对（Pair）的局部胜出者
  logic [PAIR_COUNT-1:0] pair_valid_q;
  logic [SLOT_W-1:0] pair_slot_q [0:PAIR_COUNT-1];
  logic [ROB_ID_W-1:0] pair_rob_id_q [0:PAIR_COUNT-1];
  logic [ENTRIES-1:0] issue_eligible_q;
  logic [ENTRIES-1:0] issue_eligible_d;
  logic [ENTRIES-1:0] grant_kill_d;

  // Stage S1 寄存器：锁存每组的发射候选人
  logic [GROUPS-1:0] candidate_valid_q;
  logic [SLOT_W-1:0] candidate_slot_q [0:GROUPS-1];

  // 清除寄存器仅保留给组合输出屏蔽和调试可见性。当前 grant 会在
  // 本拍直接从 valid_next 中移除，避免 slot 被同拍复用后又被下一拍清掉。
  logic [GROUPS-1:0] clear_valid_q;
  logic [SLOT_W-1:0] clear_slot_q [0:GROUPS-1];

  logic [1:0] push_count;
  logic [COUNT_W-1:0] free_count;
  logic push_fire;

  // ==========================================================================
  // 辅助函数 (Helper Functions)
  // ==========================================================================
  // 统计本周期入队的指令数量
  function automatic logic [1:0] valid_count(input logic [1:0] valid);
    valid_count = (valid == 2'b11) ? 2'd2 :
                  ((valid == 2'b01) ? 2'd1 : 2'd0);
  endfunction

  // 年龄判定函数：使用 ROB ID 的环回差值，判断指令 A 是否比 B 更老 (更老则拥有更高发射优先级)
  function automatic logic is_older(
      input logic [ROB_ID_W-1:0] a,
      input logic [ROB_ID_W-1:0] b
  );
    logic [ROB_ID_W-1:0] diff;
    begin
      diff = b - a;
      is_older = (diff != '0) && !diff[ROB_ID_W-1];
    end
  endfunction

  // 操作数唤醒判断：若原本已就绪、或者不需要此操作数、或者写回总线上正好广播了该 PRD，则就绪
  function automatic logic wake_src(
      input logic             ready,
      input logic             need_src,
      input logic [PRD_W-1:0] prs
  );
    begin
      wake_src = ready || !need_src ||
                 prf_ready_bits_i[prs] ||
                 (wb_valid_i[0] && (wb_prd_i[0] == prs)) ||
                 (wb_valid_i[1] && (wb_prd_i[1] == prs));
    end
  endfunction

  // 拼接输出候选微操作数据包
  function automatic issue_uop_t candidate_from_slot(
      input logic [SLOT_W-1:0] slot
  );
    issue_uop_t uop;
    begin
      uop = payload_q[slot];
      uop.src1_ready = src1_ready_q[slot];
      uop.src2_ready = src2_ready_q[slot];
      uop.branch_mask = branch_mask_q[slot];
      candidate_from_slot = uop;
    end
  endfunction

  function automatic logic control_ready_for_issue(
      input issue_uop_t uop,
      input logic [CHECKPOINTS-1:0] branch_mask
  );
    begin
      control_ready_for_issue =
          (uop.fu_type != FU_BRANCH) || (branch_mask == '0);
    end
  endfunction

  function automatic logic [CHECKPOINTS-1:0] clear_checkpoint(
      input logic [CHECKPOINTS-1:0] mask,
      input logic [CP_W-1:0] checkpoint_id
  );
    logic [CHECKPOINTS-1:0] one_hot;
    begin
      one_hot = '0;
      one_hot[checkpoint_id] = 1'b1;
      clear_checkpoint = mask & ~one_hot;
    end
  endfunction

  // ==========================================================================
  // 入队与流控组合逻辑
  // ==========================================================================
  assign push_count = valid_count(push_valid_i);
  assign free_count = ENTRIES[COUNT_W-1:0] - count_q;
  // 必须满足前置有效（前缀有效原则：不能是 2'b10），且空余槽位大于等于请求数
  assign push_ready_o = !recovery_i.valid && (push_valid_i != 2'b10) &&
                        (push_count <= free_count);
  assign push_fire = push_ready_o && (push_valid_i != 2'b00);

  assign empty_o = (count_q == '0);
  assign full_o = (count_q == ENTRIES[COUNT_W-1:0]);
  assign occupancy_o = count_q;

  // 发射候选直连输出
  assign candidate_valid_o = candidate_valid_q & ~clear_valid_q;
  assign candidate_uop0_o = candidate_valid_o[0] ?
                             candidate_from_slot(candidate_slot_q[0]) : '0;
  assign candidate_uop1_o = ((GROUPS > 1) && candidate_valid_o[1]) ?
                             candidate_from_slot(candidate_slot_q[1]) : '0;
  assign candidate_uop2_o = ((GROUPS > 2) && candidate_valid_o[2]) ?
                             candidate_from_slot(candidate_slot_q[2]) : '0;
  assign candidate_slot0_o = candidate_slot_q[0];
  assign candidate_slot1_o = (GROUPS > 1) ? candidate_slot_q[1] : '0;
  assign candidate_slot2_o = (GROUPS > 2) ? candidate_slot_q[2] : '0;

  // Keep the S0a eligible bitmap independent from the main queue update
  // network.  This prevents push-slot search, count update and branch-mask
  // writeback logic from being pulled into the eligible register D path.
  always_comb begin : issue_eligible_comb
    integer idx;
    integer group_idx;
    logic [CHECKPOINTS-1:0] visible_branch_mask;

    grant_kill_d = '0;
    for (group_idx = 0; group_idx < GROUPS; group_idx = group_idx + 1) begin
      if (issue_grant_i[group_idx] && candidate_valid_q[group_idx])
        grant_kill_d[candidate_slot_q[group_idx]] = 1'b1;
    end

    issue_eligible_d = '0;
    for (idx = 0; idx < ENTRIES; idx = idx + 1) begin
      visible_branch_mask = branch_mask_q[idx];
      if (checkpoint_clear_i)
        visible_branch_mask = clear_checkpoint(visible_branch_mask,
                                               checkpoint_clear_id_i);
      if (recovery_i.valid && (recovery_i.cause == REC_BRANCH))
        visible_branch_mask = clear_checkpoint(visible_branch_mask,
                                               recovery_i.checkpoint_id);

      issue_eligible_d[idx] =
          valid_q[idx] &&
          !grant_kill_d[idx] &&
          !(recovery_i.valid && (recovery_i.cause == REC_EXCEPT)) &&
          !(recovery_i.valid && (recovery_i.cause == REC_BRANCH) &&
            branch_mask_q[idx][recovery_i.checkpoint_id]) &&
          control_ready_for_issue(payload_q[idx], visible_branch_mask) &&
          (!need_rs1_q[idx] || wake_src(src1_ready_q[idx],
                                        need_rs1_q[idx],
                                        prs1_q[idx])) &&
          (!need_rs2_q[idx] || wake_src(src2_ready_q[idx],
                                        need_rs2_q[idx],
                                        prs2_q[idx]));
    end
  end

  // ==========================================================================
  // 发射队列主时序块 (Sequential Queue State & Selection Logic)
  // ==========================================================================
  always_ff @(posedge clk_i) begin : issue_queue_state
    integer idx;
    integer group_idx;
    integer pair_idx;
    integer pair_local_idx;
    integer pair_linear_idx;
    integer local_idx;
    integer slot_idx;
    logic [ENTRIES-1:0] valid_next;
    logic [ENTRIES-1:0] src1_ready_next;
    logic [ENTRIES-1:0] src2_ready_next;
    logic [ENTRIES-1:0] branch_mask_we;
    logic [CHECKPOINTS-1:0] branch_mask_wdata [0:ENTRIES-1];
    logic [COUNT_W-1:0] count_next;
    logic [ENTRIES-1:0] alloc_search_valid;
    logic [SLOT_W-1:0] push_slot0;
    logic [SLOT_W-1:0] push_slot1;
    logic found0;
    logic found1;
    logic selected;
    logic slot_ready;
    logic [SLOT_W-1:0] selected_slot;
    logic [ROB_ID_W-1:0] selected_rob_id;
    logic [CHECKPOINTS-1:0] clear_mask;

    if (rst_i) begin
      valid_q <= '0;
      src1_ready_q <= '0;
      src2_ready_q <= '0;
      need_rs1_q <= '0;
      need_rs2_q <= '0;
      for (idx = 0; idx < ENTRIES; idx = idx + 1) begin
        rob_id_q[idx] <= '0;
        prs1_q[idx] <= '0;
        prs2_q[idx] <= '0;
        branch_mask_q[idx] <= '0;
        payload_q[idx] <= '0;
      end
      count_q <= '0;
      pair_valid_q <= '0;
      issue_eligible_q <= '0;
      candidate_valid_q <= '0;
      clear_valid_q <= '0;
      for (pair_idx = 0; pair_idx < PAIR_COUNT; pair_idx = pair_idx + 1) begin
        pair_slot_q[pair_idx] <= '0;
        pair_rob_id_q[pair_idx] <= '0;
      end
      for (group_idx = 0; group_idx < GROUPS; group_idx = group_idx + 1) begin
        candidate_slot_q[group_idx] <= '0;
        clear_slot_q[group_idx] <= '0;
      end
    end else begin
      valid_next = valid_q;
      src1_ready_next = src1_ready_q;
      src2_ready_next = src2_ready_q;
      branch_mask_we = '0;
      for (idx = 0; idx < ENTRIES; idx = idx + 1)
        branch_mask_wdata[idx] = branch_mask_q[idx];
      count_next = count_q;
      alloc_search_valid = valid_q;

      // ----------------------------------------------------------------------
      // 1. 全局恢复与冲刷判定 (Recovery & Flush logic)
      // ----------------------------------------------------------------------
      if (recovery_i.valid) begin
        if (recovery_i.cause == REC_EXCEPT) begin
          // 精确异常触发，直接一拍拉空发射队列
          valid_next = '0;
          count_next = '0;
          clear_valid_q <= '0;
        end else if (recovery_i.cause == REC_BRANCH) begin
          // 分支误预测回滚：计算掩码，清除所有处于该分支掩码之下的年轻指令，并扣减数量
          clear_mask = clear_checkpoint({CHECKPOINTS{1'b1}},
                                        recovery_i.checkpoint_id);
          count_next = '0;
          clear_valid_q <= '0;
          for (idx = 0; idx < ENTRIES; idx = idx + 1) begin
            if (valid_next[idx] && branch_mask_q[idx][recovery_i.checkpoint_id]) begin
              valid_next[idx] = 1'b0;
            end else if (valid_next[idx]) begin
              // 保留的幸存指令，剔除对应的分支有效位
              branch_mask_wdata[idx] = branch_mask_q[idx] & clear_mask;
              branch_mask_we[idx] = 1'b1;
              count_next = count_next + 1'b1;
            end
          end
        end
      end

      // ----------------------------------------------------------------------
      // 2. 正常运行下的队列更新与唤醒 (Enqueue, Wakeup & Deferred Clear)
      // ----------------------------------------------------------------------
      else begin
        if (checkpoint_clear_i) begin
          for (idx = 0; idx < ENTRIES; idx = idx + 1) begin
            if (valid_q[idx]) begin
              branch_mask_wdata[idx] = clear_checkpoint(
                  branch_mask_q[idx],
                  checkpoint_clear_id_i);
              branch_mask_we[idx] = 1'b1;
            end
          end
        end

        // A. 当前 grant 立即清除：这样 free-slot 搜索可安全复用该 slot，
        // 且不会留下下一拍的 stale clear 去误杀新入队 uop。
        clear_valid_q <= '0;
        for (group_idx = 0; group_idx < GROUPS; group_idx = group_idx + 1) begin
          if (issue_grant_i[group_idx] && candidate_valid_q[group_idx] &&
              valid_next[candidate_slot_q[group_idx]]) begin
            valid_next[candidate_slot_q[group_idx]] = 1'b0;
            count_next = count_next - 1'b1;
          end
          clear_slot_q[group_idx] <= candidate_slot_q[group_idx];
        end

        // B. 写回就绪唤醒逻辑 (Wakeup)
        // 遍历所有占用状态槽位，与写回总线 tag 进行比较，唤醒处于等待该操作数的指令
        for (idx = 0; idx < ENTRIES; idx = idx + 1) begin
          if (valid_next[idx]) begin
            src1_ready_next[idx] = wake_src(src1_ready_next[idx],
                                            need_rs1_q[idx],
                                            prs1_q[idx]);
            src2_ready_next[idx] = wake_src(src2_ready_next[idx],
                                            need_rs2_q[idx],
                                            prs2_q[idx]);
          end
        end

        // C. 指令入队逻辑 (Enqueue)
        if (push_fire) begin
          found0 = 1'b0;
          found1 = 1'b0;
          push_slot0 = '0;
          push_slot1 = '0;

          // 查找空位：只使用周期开始时的有效图，不同拍复用刚被 grant
          // 清除的 slot。这样 candidate_slot_q 不会进入入队写使能/branch_mask
          // CE 路径；push_ready_o 本身也只基于周期开始的 free_count。
          for (idx = 0; idx < ENTRIES; idx = idx + 1) begin
            if (!found0 && !alloc_search_valid[idx]) begin
              found0 = 1'b1;
              push_slot0 = idx[SLOT_W-1:0];
              alloc_search_valid[idx] = 1'b1;
            end else if (!found1 && !alloc_search_valid[idx]) begin
              found1 = 1'b1;
              push_slot1 = idx[SLOT_W-1:0];
              alloc_search_valid[idx] = 1'b1;
            end
          end

          // 锁入第 0 路 uop
          valid_next[push_slot0] = push_valid_i[0];
          payload_q[push_slot0] <= push_uop0_i;
          rob_id_q[push_slot0] <= push_uop0_i.rob_id;
          prs1_q[push_slot0] <= push_uop0_i.prs1;
          prs2_q[push_slot0] <= push_uop0_i.prs2;
          need_rs1_q[push_slot0] <= push_uop0_i.need_rs1;
          need_rs2_q[push_slot0] <= push_uop0_i.need_rs2;
          branch_mask_wdata[push_slot0] = checkpoint_clear_i ?
              clear_checkpoint(push_uop0_i.branch_mask,
                               checkpoint_clear_id_i) :
              push_uop0_i.branch_mask;
          branch_mask_we[push_slot0] = push_valid_i[0];
          // 新入队 uop 可能会与本周期正在写回的 tag 发生写回旁路唤醒比较
          src1_ready_next[push_slot0] = wake_src(push_uop0_i.src1_ready,
                                                 push_uop0_i.need_rs1,
                                                 push_uop0_i.prs1);
          src2_ready_next[push_slot0] = wake_src(push_uop0_i.src2_ready,
                                                 push_uop0_i.need_rs2,
                                                 push_uop0_i.prs2);

          // 锁入第 1 路 uop
          if (push_valid_i[1]) begin
            valid_next[push_slot1] = 1'b1;
            payload_q[push_slot1] <= push_uop1_i;
            rob_id_q[push_slot1] <= push_uop1_i.rob_id;
            prs1_q[push_slot1] <= push_uop1_i.prs1;
            prs2_q[push_slot1] <= push_uop1_i.prs2;
            need_rs1_q[push_slot1] <= push_uop1_i.need_rs1;
            need_rs2_q[push_slot1] <= push_uop1_i.need_rs2;
            branch_mask_wdata[push_slot1] = checkpoint_clear_i ?
                clear_checkpoint(push_uop1_i.branch_mask,
                                 checkpoint_clear_id_i) :
                push_uop1_i.branch_mask;
            branch_mask_we[push_slot1] = 1'b1;
            src1_ready_next[push_slot1] = wake_src(push_uop1_i.src1_ready,
                                                   push_uop1_i.need_rs1,
                                                   push_uop1_i.prs1);
            src2_ready_next[push_slot1] = wake_src(push_uop1_i.src2_ready,
                                                   push_uop1_i.need_rs2,
                                                   push_uop1_i.prs2);
          end
          count_next = count_next + push_count;
        end
      end

      // ----------------------------------------------------------------------
      // 3. 流水化发射选拔时序 (Pipelined Selection Stage S0 & S1)
      // ----------------------------------------------------------------------
      if (recovery_i.valid) begin
        candidate_valid_q <= '0;
        pair_valid_q <= '0;
        issue_eligible_q <= '0;
        for (pair_idx = 0; pair_idx < PAIR_COUNT; pair_idx = pair_idx + 1) begin
          pair_slot_q[pair_idx] <= '0;
          pair_rob_id_q[pair_idx] <= '0;
        end
        for (group_idx = 0; group_idx < GROUPS; group_idx = group_idx + 1) begin
          candidate_slot_q[group_idx] <= '0;
        end
      end else begin
        // --- Stage S1: 组候选选拔与保持逻辑 (Select group candidates from S0 winners) ---
        // 从 S0 寄存的配对胜出者（pair winner）中，选择年龄最老（oldest）的一个作为本组候选人。
        // 该候选人在没有被 global arbiter 真正 grant 时，其 valid 状态会被锁定（Hold），
        // 从而提供给全局仲裁一个完全稳定的信号源，利于跨周期仲裁。
        for (group_idx = 0; group_idx < GROUPS; group_idx = group_idx + 1) begin
          selected = 1'b0;
          selected_slot = '0;
          selected_rob_id = '0;
          for (pair_idx = 0; pair_idx < PAIRS_PER_GROUP; pair_idx = pair_idx + 1) begin
            pair_linear_idx = group_idx * PAIRS_PER_GROUP + pair_idx;
            if (pair_valid_q[pair_linear_idx] &&
                issue_eligible_q[pair_slot_q[pair_linear_idx]] &&
                (rob_id_q[pair_slot_q[pair_linear_idx]] ==
                 pair_rob_id_q[pair_linear_idx]) &&
                !(clear_valid_q[group_idx] &&
                  (clear_slot_q[group_idx] == pair_slot_q[pair_linear_idx])) &&
                (!selected ||
                is_older(pair_rob_id_q[pair_linear_idx], selected_rob_id))) begin
              selected = 1'b1;
              selected_slot = pair_slot_q[pair_linear_idx];
              selected_rob_id = pair_rob_id_q[pair_linear_idx];
            end
          end

          if (issue_grant_i[group_idx] && candidate_valid_q[group_idx]) begin
            // 获得授权：清空候选标志，允许下个候选人浮现
            candidate_valid_q[group_idx] <= 1'b0;
            candidate_slot_q[group_idx] <= '0;
          end else if (candidate_reselect_i[group_idx] &&
                       candidate_valid_q[group_idx]) begin
            // 当前候选被 IQ 外部的约束长期阻塞时，不清除队列项，只允许
            // 用最新 S0 winner 重新装载候选，避免 held younger uop 阻塞 older ready uop。
            candidate_valid_q[group_idx] <= selected;
            candidate_slot_q[group_idx] <= selected_slot;
          end else if (!candidate_valid_q[group_idx]) begin
            // 空闲状态：装载最新选出的候选人并锁定输出
            candidate_valid_q[group_idx] <= selected;
            candidate_slot_q[group_idx] <= selected_slot;
          end
        end

        // --- Stage S0: 配对局部选拔逻辑 (Pairs reduction) ---
        // 将组内所有槽位两两配对（如每组 4 项分成 2 对），并在每对内选出 ready 且最老的 winner。
        // S0 只消费上一拍锁存的 issue_eligible_q，避免 valid/wakeup/control-ready 的宽组合路径
        // 直接落到 pair_* 寄存器。
        // 选择时只排除上周期已被 grant 但仍在清有效位过程中的 slot 标志。
        // 当前 grant 只清 S1 candidate，不反馈进 S0 pair 选择，避免 IQ->arbiter->IQ 的组合时序回路。
        for (group_idx = 0; group_idx < GROUPS; group_idx = group_idx + 1) begin
          for (pair_idx = 0; pair_idx < PAIRS_PER_GROUP; pair_idx = pair_idx + 1) begin
            selected = 1'b0;
            selected_slot = '0;
            selected_rob_id = '0;
            pair_linear_idx = group_idx * PAIRS_PER_GROUP + pair_idx;

            for (pair_local_idx = 0; pair_local_idx < 2; pair_local_idx = pair_local_idx + 1) begin
              local_idx = pair_idx * 2 + pair_local_idx;
              if (local_idx < GROUP_SIZE) begin
                slot_idx = group_idx * GROUP_SIZE + local_idx;
                slot_ready = issue_eligible_q[slot_idx] &&
                             !(clear_valid_q[group_idx] &&
                               (clear_slot_q[group_idx] == slot_idx[SLOT_W-1:0]));

                if (slot_ready && (!selected ||
                    is_older(rob_id_q[slot_idx], selected_rob_id))) begin
                  selected = 1'b1;
                  selected_slot = slot_idx[SLOT_W-1:0];
                  selected_rob_id = rob_id_q[slot_idx];
                end
              end
            end

            pair_valid_q[pair_linear_idx] <= selected;
            pair_slot_q[pair_linear_idx] <= selected_slot;
            pair_rob_id_q[pair_linear_idx] <= selected_rob_id;
          end
        end
      end

      // 时钟沿写入状态向量
      issue_eligible_q <= recovery_i.valid ? '0 : issue_eligible_d;
      valid_q <= valid_next;
      src1_ready_q <= src1_ready_next;
      src2_ready_q <= src2_ready_next;
      for (idx = 0; idx < ENTRIES; idx = idx + 1) begin
        if (branch_mask_we[idx])
          branch_mask_q[idx] <= branch_mask_wdata[idx];
      end
      count_q <= count_next;
    end
  end

endmodule
