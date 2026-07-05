import core_types_pkg::*;

// reorder_buffer.sv
// 重排序缓冲区 (Reorder Buffer - ROB)
// 职责：
// 1. 维护在途（In-flight）指令的执行状态，保证乱序执行（Out-of-Order）指令能够按程序顺序提交（In-order Commit）与精确异常处理；
// 2. 逻辑组织结构：32 项容量，划分为 16 row × 2 bank。ROB ID 编码为 `{row_index[3:0], bank_id}`；
// 3. 时序折中（Row-based Allocation）：
//    - 每一组非空分配请求直接独占一整行（Row），即便只有单指令分配也会使 bank1 标记为无效，下一次分配直接从下一行开始。这极大地简化了头指针提交逻辑，用极小的容量牺牲换取高速时序；
// 4. 发射级直接索引完成（Direct-Indexed Writeback）：
//    - 写回总线使用 uop 的 `rob_id` 直接定位更新 complete 状态与异常信息，避免了复杂的 CAM 关联搜索；
// 5. 分支清空与恢复的多周期扫描机制（Multi-Cycle Sequential Scan）：
//    - 避开了单周期一拍对 32 项 entry 广播清 mask 或 kill 带来的巨大扇出与时序灾难。采用时状态机（scan_busy_q），
//      历时 16 个周期逐行（Row）清除分支掩码中的对应位（分支预测正确时），或清除大于恢复尾指针的所有年轻指令（分支预测失败时）。恢复期间暂停分配；
// 6. 退休级寄存器直出：ROB 头指针条目由寄存器 `head_entry0_q/head_entry1_q` 直出，与后续提交控制逻辑（Commit Unit）彻底打断组合延迟。

module reorder_buffer (
    input  logic                     clk_i,             // 时钟信号
    input  logic                     rst_i,             // 复位信号 (高电平有效)

    // 重命名级分配 (Allocation) 接口
    input  logic [1:0]               alloc_valid_i,     // 分配有效指示位 (0/1/2)
    output logic                     alloc_ready_o,     // ROB 可接纳分配请求指示 (有空余 Row)
    output logic [ROB_ID_W-1:0]      alloc_rob_id0_o,   // 分配给 lane0 的 ROB ID
    output logic [ROB_ID_W-1:0]      alloc_rob_id1_o,   // 分配给 lane1 的 ROB ID
    input  rob_alloc_t               alloc_entry0_i,    // 分配给 lane0 的 entry 数据
    input  rob_alloc_t               alloc_entry1_i,    // 分配给 lane1 的 entry 数据

    // 写回/完成 (Completion) 接口 (由写回总线驱动，直接索引写入)
    input  completion_t              complete0_i,       // 写回通道 0 完成包
    input  completion_t              complete1_i,       // 写回通道 1 完成包

    // 提交级 (Commit) 接口
    output logic [1:0]               head_valid_o,      // ROB 头指针两路 valid 指示
    output rob_entry_t               head_entry0_o,     // ROB 头指针 lane0 完整条目 (已锁存输出)
    output rob_entry_t               head_entry1_o,     // ROB 头指针 lane1 完整条目 (已锁存输出)
    input  logic [1:0]               retire_count_i,    // Commit 阶段退休指令数 (0/1/2)

    // 分支预测正确释放接口 (多周期扫描清除 Mask 位)
    input  logic                     branch_clear_valid_i,   // 启动分支正确释放扫描
    input  logic [CP_W-1:0]          branch_clear_id_i,      // 被释放的分支检查点 ID
    output logic                     branch_clear_done_o,    // 清除扫描完成脉冲

    // 分支预测失败恢复接口 (多周期扫描清理年轻项)
    input  logic                     restore_valid_i,   // 启动分支误预测回滚扫描
    input  logic [ROB_ID_W-1:0]      restore_tail_i,    // 恢复的目标 ROB 尾指针
    output logic                     restore_done_o,    // 恢复扫描完成脉冲

    // 状态指示
    output logic                     busy_o,            // ROB 忙指示 (处于分支清空或恢复扫描中)
    output logic                     empty_o,           // ROB 空状态
    output logic                     full_o,            // ROB 满状态
    output logic [5:0]               occupancy_o        // 在途微操作总个数 (0 ~ 32)
);

  localparam int ROB_ROWS = ROB_ENTRIES / 2;             // 16 行
  localparam int ROB_ROW_W = $clog2(ROB_ROWS);           // 4 位

  // ROB 存储阵列
  logic [ROB_ENTRIES-1:0] valid_q;                       // 有效标志位图
  logic [ROB_ENTRIES-1:0] complete_q;                    // 完成标志位图
  rob_alloc_t entry_q [0:ROB_ENTRIES-1];                 // 分配信息存储阵列

  // 指针及深度计数器
  logic [ROB_ROW_W-1:0] head_row_q;                      // 头行指针 (指向即将退休的行)
  logic [ROB_ROW_W-1:0] tail_row_q;                      // 尾行指针 (指向新分配写入的行)
  logic [ROB_ROW_W:0] used_rows_q;                       // 当前已占用 Row 数量 (0 ~ 16)
  logic [5:0] occupancy_q;                               // 当前在途 uop 占用总数

  // 提交级输出寄存器
  rob_entry_t head_entry0_q;
  rob_entry_t head_entry1_q;

  // 扫描状态机控制寄存器
  logic scan_busy_q;                                     // 扫描工作状态指示
  logic scan_restore_q;                                  // 当前正在执行回滚恢复扫描 (1: 回滚恢复, 0: 正确分支释放清除 mask)
  logic [ROB_ROW_W-1:0] scan_row_q;                      // 当前扫描行索引 (0 ~ 15)
  logic [CP_W-1:0] scan_branch_id_q;                     // 正确分支释放的分支 ID
  logic [ROB_ID_W-1:0] scan_restore_tail_q;              // 回滚恢复的目标尾指针
  logic [ROB_ROW_W-1:0] scan_old_tail_row_q;             // 回滚发生前的旧尾行位置
  logic [ROB_ROW_W:0] scan_used_rows_q;                  // 回滚扫描时临时重算的有效 Row 数
  logic [5:0] scan_occupancy_q;                          // 回滚扫描时临时重算的有效 uop 数
  logic branch_clear_done_q;
  logic restore_done_q;

  logic alloc_fire;
  logic alloc_legal;
  logic retire_row_fire;
  logic [1:0] head_row_count;

  // ==========================================================================
  // 指针/索引变换辅助函数
  // ==========================================================================
  function automatic logic [ROB_ROW_W-1:0] rob_id_row(
      input logic [ROB_ID_W-1:0] rob_id
  );
    rob_id_row = rob_id[ROB_ID_W-1:1];
  endfunction

  // 提取 ROB ID 对应的 Bank (0/1)
  function automatic logic rob_id_bank(input logic [ROB_ID_W-1:0] rob_id);
    rob_id_bank = rob_id[0];
  endfunction

  function automatic logic [ROB_ID_W-1:0] make_rob_id(
      input logic [ROB_ROW_W-1:0] row,
      input logic                 bank
  );
    make_rob_id = {row, bank};
  endfunction

  function automatic logic [ROB_ROW_W-1:0] next_row(
      input logic [ROB_ROW_W-1:0] row
  );
    next_row = (row == ROB_ROWS - 1) ? '0 : row + 1'b1;
  endfunction

  // 范围判定：检查 row 是否处于 [start_row, end_row) 投机回滚环形区间内
  function automatic logic row_in_range(
      input logic [ROB_ROW_W-1:0] row,
      input logic [ROB_ROW_W-1:0] start_row,
      input logic [ROB_ROW_W-1:0] end_row
  );
    begin
      if (start_row == end_row)
        row_in_range = 1'b0;
      else if (start_row < end_row)
        row_in_range = (row >= start_row) && (row < end_row);
      else
        row_in_range = (row >= start_row) || (row < end_row);
    end
  endfunction

  function automatic logic [1:0] lane_count(input logic [1:0] valid);
    lane_count = (valid == 2'b11) ? 2'd2 :
                  ((valid == 2'b01) ? 2'd1 : 2'd0);
  endfunction

  // 分配流控判定：没有在扫描、没有非法分配（不能是 2'b10 这种前置无效）、且 ROB Row 还有空余
  assign alloc_legal = (alloc_valid_i != 2'b10);
  assign alloc_ready_o = !scan_busy_q && alloc_legal && (used_rows_q != ROB_ROWS);
  assign alloc_fire = alloc_ready_o && (alloc_valid_i != 2'b00);

  // 退休发射判定：ROB 非空、没有在扫描、提交端发出非零信号、且提交数量能覆盖当前整行已有的有效项
  assign head_row_count = {1'b0, head_entry0_q.valid} +
                          {1'b0, head_entry1_q.valid};
  assign retire_row_fire = !scan_busy_q && (used_rows_q != '0) &&
                           (retire_count_i != 2'd0) &&
                           (retire_count_i >= head_row_count);

  assign alloc_rob_id0_o = make_rob_id(tail_row_q, 1'b0);
  assign alloc_rob_id1_o = make_rob_id(tail_row_q, 1'b1);

  assign head_valid_o[0] = head_entry0_q.valid;
  assign head_valid_o[1] = head_entry1_q.valid;
  assign head_entry0_o = head_entry0_q;
  assign head_entry1_o = head_entry1_q;

  assign busy_o = scan_busy_q;
  assign empty_o = (used_rows_q == '0);
  assign full_o = (used_rows_q == ROB_ROWS);
  assign occupancy_o = occupancy_q;
  assign branch_clear_done_o = branch_clear_done_q;
  assign restore_done_o = restore_done_q;

  // ==========================================================================
  // 主更新时序逻辑 (ROB Core Sequential Logic)
  // ==========================================================================
  always_ff @(posedge clk_i) begin : rob_state
    integer entry_index;
    logic [ROB_ROW_W:0] used_rows_next;
    logic [5:0] occupancy_next;
    logic [ROB_ROW_W-1:0] head_row_next;
    logic [ROB_ROW_W-1:0] tail_after_restore;
    logic [ROB_ID_W-1:0] head_id0;
    logic [ROB_ID_W-1:0] head_id1;
    logic [ROB_ID_W-1:0] scan_id0;
    logic [ROB_ID_W-1:0] scan_id1;
    logic [1:0] scan_row_count;
    logic scan_row_survives;
    logic scan_last;
    logic kill_row;
    logic [CHECKPOINTS-1:0] clear_mask;
    rob_alloc_t alloc_tmp;
    rob_entry_t scan_entry0;
    rob_entry_t scan_entry1;
    rob_entry_t head0_next;
    rob_entry_t head1_next;

    if (rst_i) begin
      valid_q <= '0;
      complete_q <= '0;
      for (entry_index = 0; entry_index < ROB_ENTRIES; entry_index = entry_index + 1)
        entry_q[entry_index] <= '0;
      head_row_q <= '0;
      tail_row_q <= '0;
      used_rows_q <= '0;
      occupancy_q <= '0;
      head_entry0_q <= '0;
      head_entry1_q <= '0;
      scan_busy_q <= 1'b0;
      scan_restore_q <= 1'b0;
      scan_row_q <= '0;
      scan_branch_id_q <= '0;
      scan_restore_tail_q <= '0;
      scan_old_tail_row_q <= '0;
      scan_used_rows_q <= '0;
      scan_occupancy_q <= '0;
      branch_clear_done_q <= 1'b0;
      restore_done_q <= 1'b0;
    end else begin
      branch_clear_done_q <= 1'b0;
      restore_done_q <= 1'b0;

      // ----------------------------------------------------------------------
      // 模式 A. 分支恢复扫描初始化 (REC_BRANCH)
      // ----------------------------------------------------------------------
      if (restore_valid_i) begin
        scan_busy_q <= 1'b1;
        scan_restore_q <= 1'b1;
        scan_row_q <= '0;
        scan_restore_tail_q <= restore_tail_i;
        scan_old_tail_row_q <= tail_row_q;
        scan_used_rows_q <= '0;
        scan_occupancy_q <= '0;
      end

      // ----------------------------------------------------------------------
      // 模式 B. 分支正确解析扫描初始化 (Branch resolve clean)
      // ----------------------------------------------------------------------
      else if (branch_clear_valid_i && !scan_busy_q) begin
        scan_busy_q <= 1'b1;
        scan_restore_q <= 1'b0;
        scan_row_q <= '0;
        scan_branch_id_q <= branch_clear_id_i;
      end

      // ----------------------------------------------------------------------
      // 模式 C. 活跃多周期扫描处理 (Active Sequential Scan)
      // ----------------------------------------------------------------------
      else if (scan_busy_q) begin
        scan_last = (scan_row_q == ROB_ROWS - 1);
        scan_id0 = make_rob_id(scan_row_q, 1'b0);
        scan_id1 = make_rob_id(scan_row_q, 1'b1);
        scan_entry0.valid = valid_q[scan_id0];
        scan_entry0.complete = complete_q[scan_id0];
        scan_entry0.entry = entry_q[scan_id0];
        scan_entry1.valid = valid_q[scan_id1];
        scan_entry1.complete = complete_q[scan_id1];
        scan_entry1.entry = entry_q[scan_id1];

        // 1. 若为分支回滚扫描 (Rollback scan)
        if (scan_restore_q) begin
          // 判定当前行是否处于被撤回（Kill）的投机年龄区间
          kill_row = row_in_range(scan_row_q,
                                  rob_id_row(scan_restore_tail_q),
                                  scan_old_tail_row_q);
          if (kill_row) begin
            // 精细比对目标 tail_id 的 bank 状态，决定是否清理整个 Row，还是仅清理 bank1
            if ((scan_row_q == rob_id_row(scan_restore_tail_q)) &&
                rob_id_bank(scan_restore_tail_q)) begin
              valid_q[scan_id1] <= 1'b0;
              complete_q[scan_id1] <= 1'b0;
              scan_entry1.valid = 1'b0;
              scan_entry1.complete = 1'b0;
            end else begin
              valid_q[scan_id0] <= 1'b0;
              complete_q[scan_id0] <= 1'b0;
              valid_q[scan_id1] <= 1'b0;
              complete_q[scan_id1] <= 1'b0;
              scan_entry0.valid = 1'b0;
              scan_entry0.complete = 1'b0;
              scan_entry1.valid = 1'b0;
              scan_entry1.complete = 1'b0;
            end
          end
        end

        // 2. 若为分支正确释放扫描 (Clear mask scan)
        else begin
          clear_mask = ~(logic'(1'b1) << scan_branch_id_q);
          if (valid_q[scan_id0]) begin
            alloc_tmp = entry_q[scan_id0];
            alloc_tmp.branch_mask = alloc_tmp.branch_mask & clear_mask;
            entry_q[scan_id0] <= alloc_tmp;
            scan_entry0.entry = alloc_tmp;
          end
          if (valid_q[scan_id1]) begin
            alloc_tmp = entry_q[scan_id1];
            alloc_tmp.branch_mask = alloc_tmp.branch_mask & clear_mask;
            entry_q[scan_id1] <= alloc_tmp;
            scan_entry1.entry = alloc_tmp;
          end
        end

        // 3. 统计扫描存活的条数与行数 (仅用于回滚重算)
        scan_row_survives = scan_entry0.valid || scan_entry1.valid;
        scan_row_count = {1'b0, scan_entry0.valid} +
                         {1'b0, scan_entry1.valid};
        if (scan_restore_q) begin
          scan_used_rows_q <= scan_used_rows_q +
                              {{ROB_ROW_W{1'b0}}, scan_row_survives};
          scan_occupancy_q <= scan_occupancy_q + {4'd0, scan_row_count};
        end

        // 扫描行遇到当前的头行时，同步更新输出寄存器
        if (scan_row_q == head_row_q) begin
          head_entry0_q <= scan_entry0;
          head_entry1_q <= scan_entry1;
        end

        // 4. 扫描完成收尾
        if (scan_last) begin
          scan_busy_q <= 1'b0;
          scan_row_q <= '0;
          if (scan_restore_q) begin
            // 误预测回退完毕，根据恢复目标重新对齐尾指针 tail_row
            tail_after_restore = rob_id_bank(scan_restore_tail_q) ?
                                 next_row(rob_id_row(scan_restore_tail_q)) :
                                 rob_id_row(scan_restore_tail_q);
            tail_row_q <= tail_after_restore;
            used_rows_q <= scan_used_rows_q +
                           {{ROB_ROW_W{1'b0}}, scan_row_survives};
            occupancy_q <= scan_occupancy_q + {4'd0, scan_row_count};
            restore_done_q <= 1'b1;
          end else begin
            branch_clear_done_q <= 1'b1;
          end
        end else begin
          scan_row_q <= next_row(scan_row_q);
        end
      end

      // ----------------------------------------------------------------------
      // 模式 D. 正常运行状态更新 (Normal execution: Alloc, Complete, Retire)
      // ----------------------------------------------------------------------
      else begin
        used_rows_next = used_rows_q;
        occupancy_next = occupancy_q;
        head_row_next = head_row_q;

        // 1. 写回通道 0 完成记录 (直接寻址更新)
        if (complete0_i.valid && valid_q[complete0_i.rob_id]) begin
          complete_q[complete0_i.rob_id] <= 1'b1;
          if (complete0_i.exception_valid) begin
            alloc_tmp = entry_q[complete0_i.rob_id];
            alloc_tmp.exception_valid = 1'b1;
            alloc_tmp.exception_cause = complete0_i.exception_cause;
            alloc_tmp.exception_tval = complete0_i.exception_tval;
            entry_q[complete0_i.rob_id] <= alloc_tmp;
          end
        end

        // 2. 写回通道 1 完成记录 (直接寻址更新)
        if (complete1_i.valid && valid_q[complete1_i.rob_id]) begin
          complete_q[complete1_i.rob_id] <= 1'b1;
          if (complete1_i.exception_valid) begin
            alloc_tmp = entry_q[complete1_i.rob_id];
            alloc_tmp.exception_valid = 1'b1;
            alloc_tmp.exception_cause = complete1_i.exception_cause;
            alloc_tmp.exception_tval = complete1_i.exception_tval;
            entry_q[complete1_i.rob_id] <= alloc_tmp;
          end
        end

        // 3. 指令提交行出队 (Retire)
        if (retire_row_fire) begin
          head_id0 = make_rob_id(head_row_q, 1'b0);
          head_id1 = make_rob_id(head_row_q, 1'b1);
          valid_q[head_id0] <= 1'b0;
          complete_q[head_id0] <= 1'b0;
          valid_q[head_id1] <= 1'b0;
          complete_q[head_id1] <= 1'b0;

          head_row_next = next_row(head_row_q);
          head_row_q <= head_row_next;
          used_rows_next = used_rows_next - 1'b1;
          occupancy_next = occupancy_next - {4'd0, head_row_count};
        end

        // 4. 指令分配入队 (Alloc)
        if (alloc_fire) begin
          valid_q[alloc_rob_id0_o] <= alloc_valid_i[0];
          complete_q[alloc_rob_id0_o] <= alloc_entry0_i.exception_valid;
          entry_q[alloc_rob_id0_o] <= alloc_entry0_i;

          valid_q[alloc_rob_id1_o] <= alloc_valid_i[1];
          complete_q[alloc_rob_id1_o] <= alloc_valid_i[1] &&
                                         alloc_entry1_i.exception_valid;
          entry_q[alloc_rob_id1_o] <= alloc_entry1_i;

          tail_row_q <= next_row(tail_row_q);
          used_rows_next = used_rows_next + 1'b1;
          occupancy_next = occupancy_next + {4'd0, lane_count(alloc_valid_i)};
        end

        used_rows_q <= used_rows_next;
        occupancy_q <= occupancy_next;

        // 5. 解算下一周期的头指针输出寄存器 (Pipelining head_entry)
        head_id0 = make_rob_id(head_row_next, 1'b0);
        head_id1 = make_rob_id(head_row_next, 1'b1);
        head0_next.valid = valid_q[head_id0];
        head0_next.complete = complete_q[head_id0];
        head0_next.entry = entry_q[head_id0];
        head1_next.valid = valid_q[head_id1];
        head1_next.complete = complete_q[head_id1];
        head1_next.entry = entry_q[head_id1];

        // 旁路直通：若原本为空，本周期发生分配，则下一周期的 head_entry 直接由 alloc 数据填充
        if ((used_rows_q == '0) && alloc_fire && !retire_row_fire) begin
          head0_next.valid = alloc_valid_i[0];
          head0_next.complete = alloc_entry0_i.exception_valid;
          head0_next.entry = alloc_entry0_i;
          head1_next.valid = alloc_valid_i[1];
          head1_next.complete = alloc_valid_i[1] && alloc_entry1_i.exception_valid;
          head1_next.entry = alloc_entry1_i;
        end

        // 旁路直通：若本周期正在完成（Writeback）的指令就是下一周期的 head，则直接旁路更新就绪标志
        if (complete0_i.valid && (rob_id_row(complete0_i.rob_id) == head_row_next)) begin
          if (!rob_id_bank(complete0_i.rob_id)) begin
            head0_next.complete = 1'b1;
            if (complete0_i.exception_valid) begin
              head0_next.entry.exception_valid = 1'b1;
              head0_next.entry.exception_cause = complete0_i.exception_cause;
              head0_next.entry.exception_tval = complete0_i.exception_tval;
            end
          end else begin
            head1_next.complete = 1'b1;
            if (complete0_i.exception_valid) begin
              head1_next.entry.exception_valid = 1'b1;
              head1_next.entry.exception_cause = complete0_i.exception_cause;
              head1_next.entry.exception_tval = complete0_i.exception_tval;
            end
          end
        end

        if (complete1_i.valid && (rob_id_row(complete1_i.rob_id) == head_row_next)) begin
          if (!rob_id_bank(complete1_i.rob_id)) begin
            head0_next.complete = 1'b1;
            if (complete1_i.exception_valid) begin
              head0_next.entry.exception_valid = 1'b1;
              head0_next.entry.exception_cause = complete1_i.exception_cause;
              head0_next.entry.exception_tval = complete1_i.exception_tval;
            end
          end else begin
            head1_next.complete = 1'b1;
            if (complete1_i.exception_valid) begin
              head1_next.entry.exception_valid = 1'b1;
              head1_next.entry.exception_cause = complete1_i.exception_cause;
              head1_next.entry.exception_tval = complete1_i.exception_tval;
            end
          end
        end

        if ((used_rows_next == '0) && !alloc_fire) begin
          head_entry0_q <= '0;
          head_entry1_q <= '0;
        end else begin
          head_entry0_q <= head0_next;
          head_entry1_q <= head1_next;
        end
      end
    end
  end

endmodule
