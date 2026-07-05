`timescale 1ns/1ps

import core_types_pkg::*;

// free_list.sv
// 物理寄存器空闲列表 (Physical Register Free List)
// 职责：
// 1. 管理物理寄存器池的分配与回收，维护空闲位图（`free_bitmap_q`）和空闲寄存器数量（`free_count_q`）；
// 2. 双分配机制：每周期最多分配 2 个物理寄存器（prd0, prd1），采用分组 Bitmap 和 16-bit 查找算法；
// 3. 多级流水时序设计 (Selection -> Reservation -> Fire)：
//    - 选拔（Selection）与保留（Reservation）分阶段打拍，切断前向分配请求到后向响应的超长跨模块组合路径；
// 4. 组内奇偶 Bank 偏好分配：尽可能分配一奇一偶物理寄存器，减少后续 PRF（物理寄存器堆）的读写 Bank 冲突；
// 5. 延迟回收缓冲（Reclaim FIFO）：Commit 退休的物理寄存器不组合写入主位图，而是先写入 2 项 FIFO，再逐周期异步归还，打断 Commit 到 Rename 的组合反馈环路；
// 6. 投机分支回滚：Checkpoint 仅记录分配日志尾指针（`allocation_tail_q`），误预测时启动多周期 rollback，逐周期将年轻分配的物理寄存器收回主位图；
// 7. 异常重建机制：当遭遇精确异常时，多周期顺序扫描 AMT（Committed 映射），在 `free_bitmap_q` 中将所有已提交寄存器标记为占用，其余恢复为空闲。

module free_list (
    input  logic                     clk_i,             // 时钟信号
    input  logic                     rst_i,             // 复位信号 (高电平有效)

    // 重命名分配 (Allocation) 接口
    input  logic [1:0]               alloc_count_i,     // 请求分配的 PRD 数量 (0/1/2)
    output logic                     alloc_valid_o,     // 分配就绪有效指示 (可满足当前的完整请求)
    output logic [PRD_W-1:0]         alloc_prd0_o,      // 分配的物理寄存器 0
    output logic [PRD_W-1:0]         alloc_prd1_o,      // 分配的物理寄存器 1
    input  logic                     alloc_fire_i,      // 重命名级握手确认，真正消耗这组 PRD
    input  logic                     alloc_cancel_i,    // 重命名级 flush 取消分配 (释放已保留的 PRD)

    // 提交回收 (Reclaim) 接口
    input  logic [1:0]               reclaim_valid_i,   // Commit 回收有效信号 (0/1/2)
    input  logic [PRD_W-1:0]         reclaim_prd0_i,    // 退休指令释放的旧目的物理寄存器 0
    input  logic [PRD_W-1:0]         reclaim_prd1_i,    // 退休指令释放的旧目的物理寄存器 1
    output logic                     reclaim_ready_o,   // 回收缓冲未满，允许接收回收请求

    // 分支备份与恢复接口
    input  logic                     checkpoint_save_i,       // 保存检查点信号 (在重命名级分支指令发射时)
    input  logic [CP_W-1:0]          checkpoint_id_i,         // 检查点 ID
    input  logic [1:0]               checkpoint_keep_count_i, // 本周期需保留的分支前分配数量 (0/1/2)
    input  logic                     checkpoint_clear_i,      // 分支预测正确，释放对应的检查点
    input  logic [CP_W-1:0]          checkpoint_clear_id_i,   // 释放的检查点 ID
    input  logic                     branch_restore_i,        // 分支误预测恢复触发信号
    input  logic [CP_W-1:0]          branch_restore_id_i,     // 恢复的目标检查点 ID
    output logic                     branch_restore_done_o,   // 分支恢复状态结束指示

    // 异常重建接口 (Exception Rebuild)
    input  logic                     rebuild_start_i,         // 精确异常触发重建信号
    input  logic [PRD_W-1:0]         amt_map_i [0:ARCH_REGS-1], // 从 AMT 模块输入的已提交映射关系 (共 32 项)
    output logic                     busy_o,                  // 模块忙指示 (正在进行回滚恢复或重建，暂停重命名分配)
    output logic                     rebuild_done_o,          // 异常重建完成脉冲
    output logic [6:0]               free_count_o             // 当前空闲物理寄存器总数
);

  // 奇偶物理寄存器掩码 (PRD[0]=0 为偶，PRD[0]=1 为奇，用于支持双 Bank 奇偶分配偏好)
  localparam logic [PHYS_REGS-1:0] EVEN_PRD_MASK = 64'h5555_5555_5555_5555;
  localparam logic [PHYS_REGS-1:0] ODD_PRD_MASK  = 64'haaaa_aaaa_aaaa_aaaa;

  // 状态寄存器
  logic [PHYS_REGS-1:0] free_bitmap_q;                  // 主空闲物理寄存器位图 (64位)
  logic [6:0] free_count_q;                             // 空闲物理寄存器计数
  logic [1:0] rotate_group_q;                           // 旋转起始组，用于轮询分配，防止低位比特成为热点

  // 保留站 (Reservation) 寄存器：用于打拍暂存已选出的候选物理寄存器，等待 Rename 火射
  logic reservation_valid_q;
  logic [1:0] reservation_count_q;
  logic [PRD_W-1:0] reservation_prd0_q;
  logic [PRD_W-1:0] reservation_prd1_q;

  // 选拔中转寄存器 (Selection)：用于在分配 2 个寄存器时，暂存第 1 个分配结果，在第二拍寻找第 2 个奇/偶物理寄存器
  logic selection_pending_q;
  logic [1:0] selection_count_q;
  logic [PRD_W-1:0] selection_prd0_q;

  // 延迟回收缓冲 FIFO (2项容量)：用于隔离 Commit 到 Rename 的组合反馈
  logic [PRD_W-1:0] reclaim_fifo_q [0:1];
  logic reclaim_head_q;
  logic reclaim_tail_q;
  logic [1:0] reclaim_count_q;

  // 分配日志 (Allocation Log)：记录每周期分配出的物理寄存器顺序
  logic [PRD_W-1:0] allocation_log_q [0:PHYS_REGS-1];
  logic [PRD_W-1:0] allocation_tail_q;                  // 分配日志写指针
  logic [PRD_W-1:0] checkpoint_tail_q [0:CHECKPOINTS-1];// 各分支检查点备份时的分配日志指针位置
  logic [CHECKPOINTS-1:0] checkpoint_valid_q;           // 检查点有效位图

  // 分支误预测多周期回滚 (Rollback) 状态寄存器
  logic rollback_busy_q;
  logic [PRD_W-1:0] rollback_target_q;                  // 回滚到的目标日志指针位置
  logic rollback_prd_valid_q;                           // 回滚寄存器写主位图使能
  logic rollback_prd_last_q;                            // 最后一项回滚指示
  logic [PRD_W-1:0] rollback_prd_q;                     // 正在回滚释放的物理寄存器号
  logic branch_restore_done_q;

  // 精确异常多周期重建 (Rebuild) 状态寄存器
  logic rebuild_busy_q;
  logic [4:0] rebuild_index_q;                          // 重建扫描的架构寄存器 index (32项)
  logic rebuild_pair_valid_q;                           // 锁存的待重建物理寄存器对有效位
  logic rebuild_pair_last_q;                            // 最后一对重建指示
  logic [PRD_W-1:0] rebuild_prd0_q;                     // 待占用的物理寄存器 0 (来自 AMT)
  logic [PRD_W-1:0] rebuild_prd1_q;                     // 待占用的物理寄存器 1 (来自 AMT)
  logic [PHYS_REGS-1:0] rebuild_used_bitmap_q;          // 临时记录已被占用的物理寄存器位图
  logic [6:0] rebuild_used_count_q;                     // 已占用物理寄存器总数
  logic rebuild_done_q;

  // 内部选择解算线
  logic [3:0] group_nonempty0;
  logic [3:0] group_nonempty1_even;
  logic [3:0] group_nonempty1_odd;
  logic [2:0] group_select0;
  logic [2:0] group_select1_even;
  logic [2:0] group_select1_odd;
  logic [4:0] bit_select0;
  logic [4:0] bit_select1_even;
  logic [4:0] bit_select1_odd;
  logic [15:0] selected_word0;
  logic [15:0] selected_word1_even;
  logic [15:0] selected_word1_odd;
  logic [15:0] selection_exclude_word1;
  logic [PHYS_REGS-1:0] available_bitmap1;
  logic [PHYS_REGS-1:0] even_bitmap1;
  logic [PHYS_REGS-1:0] odd_bitmap1;
  logic candidate0_valid;
  logic candidate1_even_valid;
  logic candidate1_odd_valid;
  logic candidate1_valid;
  logic [PRD_W-1:0] candidate_prd0;
  logic [PRD_W-1:0] candidate_prd1_even;
  logic [PRD_W-1:0] candidate_prd1_odd;
  logic [PRD_W-1:0] candidate_prd1;
  logic selection_request_ready;

  logic [1:0] reclaim_input_count;
  logic reclaim_accept;
  logic reclaim_drain;
  logic alloc_consume;

  // ==========================================================================
  // 选拔算法辅助函数 (Selection Helper Functions)
  // ==========================================================================
  // 从四个 nonempty 分组标志中选出非空的一组，基于 start_group 轮询，避免总分配低编号条目
  function automatic logic [2:0] pick_group(
      input logic [3:0] nonempty,
      input logic [1:0] start_group
  );
    begin
      pick_group = '0;
      case (start_group)
        2'd0: begin
          if (nonempty[0])      pick_group = 3'b100;
          else if (nonempty[1]) pick_group = 3'b101;
          else if (nonempty[2]) pick_group = 3'b110;
          else if (nonempty[3]) pick_group = 3'b111;
        end
        2'd1: begin
          if (nonempty[1])      pick_group = 3'b101;
          else if (nonempty[2]) pick_group = 3'b110;
          else if (nonempty[3]) pick_group = 3'b111;
          else if (nonempty[0]) pick_group = 3'b100;
        end
        2'd2: begin
          if (nonempty[2])      pick_group = 3'b110;
          else if (nonempty[3]) pick_group = 3'b111;
          else if (nonempty[0]) pick_group = 3'b100;
          else if (nonempty[1]) pick_group = 3'b101;
        end
        default: begin
          if (nonempty[3])      pick_group = 3'b111;
          else if (nonempty[0]) pick_group = 3'b100;
          else if (nonempty[1]) pick_group = 3'b101;
          else if (nonempty[2]) pick_group = 3'b110;
        end
      endcase
    end
  endfunction

  // 4-bit 优先级编码器：寻找第一个为 1 的位 (First-One)
  function automatic logic [2:0] pick_bit4(input logic [3:0] word);
    begin
      casez (word)
        4'b???1: pick_bit4 = 3'b100;
        4'b??10: pick_bit4 = 3'b101;
        4'b?100: pick_bit4 = 3'b110;
        4'b1000: pick_bit4 = 3'b111;
        default: pick_bit4 = 3'b000;
      endcase
    end
  endfunction

  // 16-bit 分级优先级编码器：定位 16-bit 字中第一个为 1 的位
  function automatic logic [4:0] pick_bit16(input logic [15:0] word);
    logic [3:0] nibble_nonempty;
    logic [1:0] nibble_index;
    logic [3:0] selected_nibble;
    logic [2:0] bit_in_nibble;
    begin
      pick_bit16 = '0;
      // 将 16-bit 拆分为四个 4-bit nibbles 并检测非空状态
      nibble_nonempty = {|word[15:12], |word[11:8], |word[7:4], |word[3:0]};
      nibble_index = 2'd0;
      selected_nibble = word[3:0];

      if (nibble_nonempty[0]) begin
        nibble_index = 2'd0;
        selected_nibble = word[3:0];
      end else if (nibble_nonempty[1]) begin
        nibble_index = 2'd1;
        selected_nibble = word[7:4];
      end else if (nibble_nonempty[2]) begin
        nibble_index = 2'd2;
        selected_nibble = word[11:8];
      end else if (nibble_nonempty[3]) begin
        nibble_index = 2'd3;
        selected_nibble = word[15:12];
      end

      // 对选出的 4-bit 块进行最终编码
      bit_in_nibble = pick_bit4(selected_nibble);
      if (bit_in_nibble[2]) begin
        pick_bit16 = {1'b1, nibble_index, bit_in_nibble[1:0]};
      end
    end
  endfunction

  function automatic logic [15:0] bit_onehot16(input logic [3:0] bit_index);
    begin
      case (bit_index)
        4'd0: bit_onehot16 = 16'h0001;
        4'd1: bit_onehot16 = 16'h0002;
        4'd2: bit_onehot16 = 16'h0004;
        4'd3: bit_onehot16 = 16'h0008;
        4'd4: bit_onehot16 = 16'h0010;
        4'd5: bit_onehot16 = 16'h0020;
        4'd6: bit_onehot16 = 16'h0040;
        4'd7: bit_onehot16 = 16'h0080;
        4'd8: bit_onehot16 = 16'h0100;
        4'd9: bit_onehot16 = 16'h0200;
        4'd10: bit_onehot16 = 16'h0400;
        4'd11: bit_onehot16 = 16'h0800;
        4'd12: bit_onehot16 = 16'h1000;
        4'd13: bit_onehot16 = 16'h2000;
        4'd14: bit_onehot16 = 16'h4000;
        default: bit_onehot16 = 16'h8000;
      endcase
    end
  endfunction

  function automatic logic [1:0] next_group(input logic [1:0] group_index);
    begin
      case (group_index)
        2'd0: next_group = 2'd1;
        2'd1: next_group = 2'd2;
        2'd2: next_group = 2'd3;
        default: next_group = 2'd0;
      endcase
    end
  endfunction

  // 将 64-bit 划分为 4 个 16-bit 组，输出每组是否非空的 4-bit 标志
  function automatic logic [3:0] group_nonempty(
      input logic [PHYS_REGS-1:0] bitmap
  );
    begin
      group_nonempty[0] = |bitmap[15:0];
      group_nonempty[1] = |bitmap[31:16];
      group_nonempty[2] = |bitmap[47:32];
      group_nonempty[3] = |bitmap[63:48];
    end
  endfunction

  function automatic logic [PRD_W-1:0] make_prd(
      input logic [2:0] group_select,
      input logic [4:0] bit_select
  );
    begin
      make_prd = {group_select[1:0], bit_select[3:0]};
    end
  endfunction

  function automatic logic candidate_valid(
      input logic [2:0] group_select,
      input logic [4:0] bit_select
  );
    begin
      candidate_valid = group_select[2] && bit_select[4];
    end
  endfunction

  function automatic logic [15:0] group_word(
      input logic [PHYS_REGS-1:0] bitmap,
      input logic [1:0] group_index
  );
    case (group_index)
      2'd0: group_word = bitmap[15:0];
      2'd1: group_word = bitmap[31:16];
      2'd2: group_word = bitmap[47:32];
      default: group_word = bitmap[63:48];
    endcase
  endfunction

  // ==========================================================================
  // 分配选择组合解算 (Combinational Allocation Selection Muxes)
  // ==========================================================================
  always @* begin
    // --- 第一路选拔 (Candidate 0) ---
    group_nonempty0 = group_nonempty(free_bitmap_q);
    group_select0 = pick_group(group_nonempty0, rotate_group_q);
    selected_word0 = group_word(free_bitmap_q, group_select0[1:0]);
    bit_select0 = pick_bit16(selected_word0);
    candidate0_valid = candidate_valid(group_select0, bit_select0);
    candidate_prd0 = make_prd(group_select0, bit_select0);

    // --- 第二路选拔 (Candidate 1) ---
    // 为了支持奇偶 Bank 分区偏好，必须排除刚刚在第一路选拔中选走的位
    selection_exclude_word1 = bit_onehot16(selection_prd0_q[3:0]);
    available_bitmap1 = free_bitmap_q;
    if (selection_pending_q) begin
      case (selection_prd0_q[5:4])
        2'd0:    available_bitmap1[15:0]  = free_bitmap_q[15:0]  & ~selection_exclude_word1;
        2'd1:    available_bitmap1[31:16] = free_bitmap_q[31:16] & ~selection_exclude_word1;
        2'd2:    available_bitmap1[47:32] = free_bitmap_q[47:32] & ~selection_exclude_word1;
        default: available_bitmap1[63:48] = free_bitmap_q[63:48] & ~selection_exclude_word1;
      endcase
    end

    // 拆分为奇、偶位图
    even_bitmap1 = available_bitmap1 & EVEN_PRD_MASK;
    odd_bitmap1 = available_bitmap1 & ODD_PRD_MASK;

    // 偶数物理寄存器选拔
    group_nonempty1_even = group_nonempty(even_bitmap1);
    group_select1_even = pick_group(group_nonempty1_even, selection_prd0_q[5:4]);
    selected_word1_even = group_word(even_bitmap1, group_select1_even[1:0]);
    bit_select1_even = pick_bit16(selected_word1_even);
    candidate1_even_valid = candidate_valid(group_select1_even, bit_select1_even);
    candidate_prd1_even = make_prd(group_select1_even, bit_select1_even);

    // 奇数物理寄存器选拔
    group_nonempty1_odd = group_nonempty(odd_bitmap1);
    group_select1_odd = pick_group(group_nonempty1_odd, selection_prd0_q[5:4]);
    selected_word1_odd = group_word(odd_bitmap1, group_select1_odd[1:0]);
    bit_select1_odd = pick_bit16(selected_word1_odd);
    candidate1_odd_valid = candidate_valid(group_select1_odd, bit_select1_odd);
    candidate_prd1_odd = make_prd(group_select1_odd, bit_select1_odd);

    // 判定奇偶 Bank 偏好：
    // 若第 0 路分配到了奇数 PRD (LSB=1)，第 1 路优先选拔偶数 PRD，反之亦然。
    // 如果偏好的 Bank 无可用寄存器，则降级分配同 Bank，并发出 bank_same 事件。
    if (selection_prd0_q[0]) begin
      candidate1_valid = candidate1_even_valid || candidate1_odd_valid;
      candidate_prd1 = candidate1_even_valid ? candidate_prd1_even :
                                               candidate_prd1_odd;
    end else begin
      candidate1_valid = candidate1_odd_valid || candidate1_even_valid;
      candidate_prd1 = candidate1_odd_valid ? candidate_prd1_odd :
                                             candidate_prd1_even;
    end

    // 判定分配请求是否可以被接受 (没有发生恢复、空闲队列未被锁死、请求数有效)
    selection_request_ready = !reservation_valid_q && !selection_pending_q &&
                              !busy_o && (alloc_count_i != 0) &&
                              (alloc_count_i != 2'd3);
  end

  // ==========================================================================
  // 回收及握手控制连线 (Reclaim & Flow Control Signals)
  // ==========================================================================
  assign reclaim_input_count = (reclaim_valid_i == 2'b11) ? 2'd2 :
                               ((reclaim_valid_i == 2'b01) ? 2'd1 : 2'd0);

  assign busy_o = rollback_busy_q || rebuild_busy_q;
  assign alloc_valid_o = reservation_valid_q && !busy_o;
  assign alloc_prd0_o = reservation_prd0_q;
  assign alloc_prd1_o = reservation_prd1_q;
  assign free_count_o = free_count_q;
  assign rebuild_done_o = rebuild_done_q;
  assign branch_restore_done_o = branch_restore_done_q;

  // 分配被消耗：重命名级握手成功且未被取消
  assign alloc_consume = alloc_fire_i && reservation_valid_q && !alloc_cancel_i;

  // 延迟回收 FIFO 释放（Drain）条件：FIFO 非空，且模块没有被恢复/重建占用
  assign reclaim_drain = (reclaim_count_q != 0) && !busy_o &&
                         !branch_restore_i && !rebuild_start_i;

  // 可接受外部 Commit 释放物理寄存器的就绪判定：
  // 必须满足当前 FIFO 内部剩余空槽足够容纳本周期的回收个数。
  assign reclaim_ready_o = !busy_o && !branch_restore_i && !rebuild_start_i &&
      (reclaim_input_count <= (2 - reclaim_count_q + reclaim_drain));
  assign reclaim_accept = (reclaim_input_count != 0) && reclaim_ready_o;

  // ==========================================================================
  // 核心时序控制逻辑 (Core Sequential Logic)
  // ==========================================================================
  always_ff @(posedge clk_i) begin : free_list_state
    integer cp_index;
    logic [PRD_W-1:0] rollback_index;
    logic [PHYS_REGS-1:0] used_next;
    logic [6:0] used_count_next;

    if (rst_i) begin
      // 初始化状态：p0-p31 被架构寄存器映射占用，p32-p63 进入空闲表
      free_bitmap_q <= 64'hffff_ffff_0000_0000;
      free_count_q <= 7'd32;
      rotate_group_q <= 2'd2;
      reservation_valid_q <= 1'b0;
      reservation_count_q <= 2'd0;
      reservation_prd0_q <= '0;
      reservation_prd1_q <= '0;
      selection_pending_q <= 1'b0;
      selection_count_q <= 2'd0;
      selection_prd0_q <= '0;
      reclaim_head_q <= 1'b0;
      reclaim_tail_q <= 1'b0;
      reclaim_count_q <= 2'd0;
      allocation_tail_q <= '0;
      checkpoint_valid_q <= '0;
      rollback_busy_q <= 1'b0;
      rollback_target_q <= '0;
      rollback_prd_valid_q <= 1'b0;
      rollback_prd_last_q <= 1'b0;
      rollback_prd_q <= '0;
      branch_restore_done_q <= 1'b0;
      rebuild_busy_q <= 1'b0;
      rebuild_index_q <= 5'd0;
      rebuild_pair_valid_q <= 1'b0;
      rebuild_pair_last_q <= 1'b0;
      rebuild_prd0_q <= '0;
      rebuild_prd1_q <= '0;
      rebuild_used_bitmap_q <= '0;
      rebuild_used_count_q <= 7'd0;
      rebuild_done_q <= 1'b0;
      branch_restore_done_q <= 1'b0;
    end else begin
      rebuild_done_q <= 1'b0;

      // ----------------------------------------------------------------------
      // 模式 A. 精确异常重建流程 (Rebuild Flow)
      // ----------------------------------------------------------------------
      // 遭遇精确异常时，需要把 Free List 重新初始化，清除所有的历史分配，
      // 并从 AMT 输入端逐周期提取已提交映射。
      if (rebuild_start_i) begin
        reservation_valid_q <= 1'b0;
        selection_pending_q <= 1'b0;
        reclaim_head_q <= 1'b0;
        reclaim_tail_q <= 1'b0;
        reclaim_count_q <= 2'd0;
        checkpoint_valid_q <= '0;
        rollback_busy_q <= 1'b0;
        rollback_prd_valid_q <= 1'b0;
        rebuild_busy_q <= 1'b1;
        rebuild_index_q <= 5'd0;
        rebuild_pair_valid_q <= 1'b0;
        rebuild_used_bitmap_q <= '0;
        rebuild_used_count_q <= 7'd0;
      end

      // ----------------------------------------------------------------------
      // 模式 B. 分支误预测多周期回滚流程 (Rollback Flow)
      // ----------------------------------------------------------------------
      // 分支预测失败时，按照 Checkpoint 保存的 allocation_log_q 尾指针，
      // 逆向多周期回滚，把这段时间内分配的所有物理寄存器逐个返还主位图。
      else if (branch_restore_i) begin
        reservation_valid_q <= 1'b0;
        selection_pending_q <= 1'b0;
        if (checkpoint_valid_q[branch_restore_id_i] &&
            (allocation_tail_q != checkpoint_tail_q[branch_restore_id_i])) begin
          rollback_busy_q <= 1'b1;
          rollback_target_q <= checkpoint_tail_q[branch_restore_id_i];
          rollback_prd_valid_q <= 1'b0;
        end else begin
          rollback_busy_q <= 1'b0;
          branch_restore_done_q <= 1'b1;
        end
        checkpoint_valid_q[branch_restore_id_i] <= 1'b0;
      end

      // ----------------------------------------------------------------------
      // 模式 C. 异常重建核心状态机步骤
      // ----------------------------------------------------------------------
      else if (rebuild_busy_q) begin
        used_next = rebuild_used_bitmap_q;
        used_count_next = rebuild_used_count_q;

        // 重建写入：每周期从寄存的 AMT 输出中，将对应的物理寄存器在临时 bitmap 中标为“已占用”。
        // 此处通过 rebuild_prdX_q 寄存器进行数据阻断，避免 32:1 复杂映射 Mux 延迟叠加进 Used Bit 位更新路径。
        if (rebuild_pair_valid_q) begin
          if (!used_next[rebuild_prd0_q]) begin
            used_next[rebuild_prd0_q] = 1'b1;
            used_count_next = used_count_next + 7'd1;
          end
          if (!used_next[rebuild_prd1_q]) begin
            used_next[rebuild_prd1_q] = 1'b1;
            used_count_next = used_count_next + 7'd1;
          end
          rebuild_used_bitmap_q <= used_next;
          rebuild_used_count_q <= used_count_next;

          // 扫描完成 (32项检查完)，空闲位图等于 used 位图按位取反（其中 p0 恒不空闲）
          if (rebuild_pair_last_q) begin
            free_bitmap_q <= ~used_next;
            free_bitmap_q[0] <= 1'b0;
            free_count_q <= 7'd64 - used_count_next;
            allocation_tail_q <= '0;
            rebuild_busy_q <= 1'b0;
            rebuild_index_q <= 5'd0;
            rebuild_pair_valid_q <= 1'b0;
            rebuild_done_q <= 1'b1;
            rotate_group_q <= 2'd0;
          end
        end

        // 顺序扫描 AMT 地址对，启动流水化读取
        if (!rebuild_pair_valid_q || !rebuild_pair_last_q) begin
          rebuild_prd0_q <= amt_map_i[rebuild_index_q];
          rebuild_prd1_q <= amt_map_i[rebuild_index_q + 1'b1];
          rebuild_pair_valid_q <= 1'b1;
          rebuild_pair_last_q <= (rebuild_index_q == 5'd30);
          if (rebuild_index_q != 5'd30)
            rebuild_index_q <= rebuild_index_q + 5'd2;
        end
      end

      // ----------------------------------------------------------------------
      // 模式 D. 分支回滚核心状态机步骤
      // ----------------------------------------------------------------------
      else if (rollback_busy_q) begin
        // 逐周期归还，将 rollback_prd_q（日志中读取的物理寄存器号）还原写回空闲位图
        if (rollback_prd_valid_q) begin
          free_bitmap_q[rollback_prd_q] <= 1'b1;
          free_count_q <= free_count_q + 7'd1;
          if (rollback_prd_last_q) begin
            rollback_busy_q <= 1'b0;
            rollback_prd_valid_q <= 1'b0;
            branch_restore_done_q <= 1'b1;
          end
        end

        // 从日志中读取上一周期被非正常消耗的物理寄存器
        if (!rollback_prd_valid_q || !rollback_prd_last_q) begin
          rollback_index = allocation_tail_q - 1'b1;
          rollback_prd_q <= allocation_log_q[rollback_index];
          rollback_prd_valid_q <= 1'b1;
          rollback_prd_last_q <= (rollback_index == rollback_target_q);
          allocation_tail_q <= rollback_index;
        end
      end

      // ----------------------------------------------------------------------
      // 模式 E. 正常运行状态机步骤 (Normal Execution)
      // ----------------------------------------------------------------------
      else begin
        // A. 释放正确预测的分支检查点
        if (checkpoint_clear_i)
          checkpoint_valid_q[checkpoint_clear_id_i] <= 1'b0;

        // B. 分支指令建立新检查点
        // 仅保存当前的分配日志写指针 tail (加上本周期确认分配的寄存器数量，作为分界线)
        if (checkpoint_save_i) begin
          cp_index = checkpoint_id_i;
          checkpoint_valid_q[cp_index] <= 1'b1;
          checkpoint_tail_q[cp_index] <= allocation_tail_q +
                                                    checkpoint_keep_count_i;
        end

        // C. 物理寄存器分配流水线逻辑
        if (alloc_cancel_i) begin
          // 取消：清空保留站和选拔标志，不消耗物理寄存器
          reservation_valid_q <= 1'b0;
          selection_pending_q <= 1'b0;
        end else if (alloc_consume) begin
          // 握手成功：物理寄存器正式扣除，写入分配日志
          free_bitmap_q[reservation_prd0_q] <= 1'b0;
          allocation_log_q[allocation_tail_q] <= reservation_prd0_q;
          if (reservation_count_q == 2'd2) begin
            free_bitmap_q[reservation_prd1_q] <= 1'b0;
            allocation_log_q[allocation_tail_q + 1'b1] <= reservation_prd1_q;
          end
          allocation_tail_q <= allocation_tail_q + reservation_count_q;
          // 旋转起始组，用于下次分配时避免资源热点
          rotate_group_q <= (reservation_count_q == 2'd2) ?
                            next_group(reservation_prd1_q[5:4]) :
                            next_group(reservation_prd0_q[5:4]);
          reservation_valid_q <= 1'b0;
        end else if (selection_pending_q &&
                     ((selection_count_q == 2'd1) || candidate1_valid)) begin
          // 选拔第二拍：若上一拍选拔了 prd0，本周期寻找到 prd1，则正式将其填入 Reservation
          reservation_valid_q <= 1'b1;
          reservation_count_q <= selection_count_q;
          reservation_prd0_q <= selection_prd0_q;
          reservation_prd1_q <= (selection_count_q == 2'd2) ? candidate_prd1 : '0;
          selection_pending_q <= 1'b0;
        end else if (selection_request_ready) begin
          // 选拔第一拍：当 Rename 有请求且保留站空闲时，锁存 prd0 以及请求数量
          selection_pending_q <= candidate0_valid;
          selection_count_q <= alloc_count_i;
          selection_prd0_q <= candidate_prd0;
        end

        // D. 退休回收延迟缓冲逻辑 (Reclaim buffer FIFO control)
        // 接受 Commit 释放的 prd，暂存入 reclaim_fifo_q 中
        if (reclaim_accept) begin
          reclaim_fifo_q[reclaim_tail_q] <= reclaim_prd0_i;
          if (reclaim_input_count == 2'd2)
            reclaim_fifo_q[~reclaim_tail_q] <= reclaim_prd1_i;
          reclaim_tail_q <= reclaim_tail_q + reclaim_input_count[0];
        end
        // FIFO 顺序异步释放
        if (reclaim_drain)
          reclaim_head_q <= ~reclaim_head_q;

        reclaim_count_q <= reclaim_count_q +
                           (reclaim_accept ? reclaim_input_count : 2'd0) -
                           (reclaim_drain ? 2'd1 : 2'd0);

        // 从 FIFO 释放的物理寄存器返还主位图
        if (reclaim_drain)
          free_bitmap_q[reclaim_fifo_q[reclaim_head_q]] <= 1'b1;

        // E. 计数器更新逻辑 (支持单周期同时进行分配与回收)
        case ({reclaim_drain, alloc_consume})
          2'b10: free_count_q <= free_count_q + 7'd1;
          2'b01: free_count_q <= free_count_q - reservation_count_q;
          2'b11: free_count_q <= free_count_q + 7'd1 - reservation_count_q;
          default: free_count_q <= free_count_q;
        endcase
      end
    end
  end

  // ==========================================================================
  // 系统断言 (SystemVerilog Assertions)
  // ==========================================================================
`ifdef FREE_LIST_ASSERTIONS
  // 断言 1：双路分配时得到的两个物理寄存器编号绝不能相同
  property p_alloc_distinct;
    @(posedge clk_i) disable iff (rst_i)
      alloc_valid_o && (reservation_count_q == 2) |->
        (alloc_prd0_o != alloc_prd1_o);
  endproperty
  assert property (p_alloc_distinct);

  // 断言 2：回收有效输入的前缀有效原则 (不能是 2'b10)
  property p_reclaim_prefix;
    @(posedge clk_i) disable iff (rst_i) reclaim_valid_i != 2'b10;
  endproperty
  assert property (p_reclaim_prefix);

  // 断言 3：物理寄存器 p0 (映射 x0 零寄存器) 绝不能被任何分配行为回收或占用
  property p_never_allocate_p0;
    @(posedge clk_i) disable iff (rst_i)
      alloc_valid_o |-> (alloc_prd0_o != 0) &&
        ((reservation_count_q != 2) || (alloc_prd1_o != 0));
  endproperty
  assert property (p_never_allocate_p0);
`endif

endmodule
