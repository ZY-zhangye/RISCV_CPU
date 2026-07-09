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
    output logic [ROB_ID_W-1:0]      head_rob_id_o,     // 当前 ROB head ID
    output rob_entry_t               head_entry0_o,     // ROB 头指针 lane0 完整条目 (已锁存输出)
    output rob_entry_t               head_entry1_o,     // ROB 头指针 lane1 完整条目 (已锁存输出)
    input  logic [1:0]               retire_count_i,    // Commit 阶段退休指令数 (0/1/2)

    // 精确异常恢复：清空所有在途项并取消正在进行的分支扫描
    input  logic                     exception_flush_i,
    output logic                     exception_flush_done_o,

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

  typedef struct packed {
    logic [ 4:0] arch_rd;
    logic [PRD_W-1:0] new_prd;
    logic [PRD_W-1:0] old_prd;
    logic        write_rd;
    logic        is_load;
    logic [LQ_ID_W-1:0] lq_id;
    logic        is_store;
    logic [SQ_ID_W-1:0] sq_id;
    logic        is_branch;
    logic [CP_W-1:0] checkpoint_id;
    logic        serializing;
    logic        is_csr;
    csr_op_t     csr_op;
    logic [11:0] csr_addr;
    logic [ 4:0] csr_zimm;
    logic        is_ecall;
    logic        is_ebreak;
    logic        is_mret;
    logic        is_fence;
    logic [31:0] inst;
    logic [31:0] pc;
  } rob_payload_t;

  // ROB 存储阵列。宽 payload 与完成/异常/分支 mask 等动态状态拆分，避免
  // recovery、branch-clear 和 completion 同时驱动整条 payload。
  logic [ROB_ENTRIES-1:0] valid_q;                       // 有效标志位图
  logic [ROB_ENTRIES-1:0] complete_q;                    // 完成标志位图
  rob_payload_t payload_q [0:ROB_ENTRIES-1];             // allocation 后基本不变的 payload
  logic [CHECKPOINTS-1:0] branch_mask_q [0:ROB_ENTRIES-1];
  logic [XLEN-1:0] csr_operand_q [0:ROB_ENTRIES-1];
  logic exception_valid_q [0:ROB_ENTRIES-1];
  logic [3:0] exception_cause_q [0:ROB_ENTRIES-1];
  logic [XLEN-1:0] exception_tval_q [0:ROB_ENTRIES-1];

  // 指针及深度计数器
  logic [ROB_ROW_W-1:0] head_row_q;                      // 头行指针 (指向即将退休的行)
  logic head_bank_q;                                      // 头行内当前可见的最老 bank
  logic [ROB_ROW_W-1:0] tail_row_q;                      // 尾行指针 (指向新分配写入的行)
  logic [ROB_ROW_W:0] used_rows_q;                       // 当前已占用 Row 数量 (0 ~ 16)
  logic full_q;                                           // used_rows_q == ROB_ROWS 的寄存影子，切断分配 ready 长路径
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
  logic exception_flush_done_q;
  logic exception_flush_pending_q;
  logic restore_pending_q;
  logic [ROB_ID_W-1:0] restore_tail_pending_q;
  logic branch_clear_pending_q;
  logic [CP_W-1:0] branch_clear_id_pending_q;
  logic alloc_pending_q;
  logic [1:0] alloc_pending_valid_q;
  logic [ROB_ID_W-1:0] alloc_pending_id0_q;
  logic [ROB_ID_W-1:0] alloc_pending_id1_q;
  rob_alloc_t alloc_pending_entry0_q;
  rob_alloc_t alloc_pending_entry1_q;

  logic alloc_fire;
  logic retire_row_fire;
  logic retire_lane0_fire;
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

  function automatic logic restore_kills_id(
      input logic [ROB_ID_W-1:0] rob_id,
      input logic [ROB_ID_W-1:0] restore_tail,
      input logic [ROB_ROW_W-1:0] old_tail_row
  );
    logic [ROB_ROW_W-1:0] row;
    begin
      row = rob_id_row(rob_id);
      if (!row_in_range(row, rob_id_row(restore_tail), old_tail_row)) begin
        restore_kills_id = 1'b0;
      end else if ((row == rob_id_row(restore_tail)) &&
                   rob_id_bank(restore_tail)) begin
        restore_kills_id = rob_id_bank(rob_id);
      end else begin
        restore_kills_id = 1'b1;
      end
    end
  endfunction

  function automatic logic [1:0] lane_count(input logic [1:0] valid);
    lane_count = (valid == 2'b11) ? 2'd2 :
                  ((valid == 2'b01) ? 2'd1 : 2'd0);
  endfunction

  function automatic rob_payload_t payload_from_alloc(input rob_alloc_t entry);
    begin
      payload_from_alloc.arch_rd = entry.arch_rd;
      payload_from_alloc.new_prd = entry.new_prd;
      payload_from_alloc.old_prd = entry.old_prd;
      payload_from_alloc.write_rd = entry.write_rd;
      payload_from_alloc.is_load = entry.is_load;
      payload_from_alloc.lq_id = entry.lq_id;
      payload_from_alloc.is_store = entry.is_store;
      payload_from_alloc.sq_id = entry.sq_id;
      payload_from_alloc.is_branch = entry.is_branch;
      payload_from_alloc.checkpoint_id = entry.checkpoint_id;
      payload_from_alloc.serializing = entry.serializing;
      payload_from_alloc.is_csr = entry.is_csr;
      payload_from_alloc.csr_op = entry.csr_op;
      payload_from_alloc.csr_addr = entry.csr_addr;
      payload_from_alloc.csr_zimm = entry.csr_zimm;
      payload_from_alloc.is_ecall = entry.is_ecall;
      payload_from_alloc.is_ebreak = entry.is_ebreak;
      payload_from_alloc.is_mret = entry.is_mret;
      payload_from_alloc.is_fence = entry.is_fence;
      payload_from_alloc.inst = entry.inst;
      payload_from_alloc.pc = entry.pc;
    end
  endfunction

  function automatic rob_alloc_t make_alloc_entry(input logic [ROB_ID_W-1:0] rob_id);
    rob_payload_t payload;
    begin
      payload = payload_q[rob_id];
      make_alloc_entry.arch_rd = payload.arch_rd;
      make_alloc_entry.new_prd = payload.new_prd;
      make_alloc_entry.old_prd = payload.old_prd;
      make_alloc_entry.write_rd = payload.write_rd;
      make_alloc_entry.is_load = payload.is_load;
      make_alloc_entry.lq_id = payload.lq_id;
      make_alloc_entry.is_store = payload.is_store;
      make_alloc_entry.sq_id = payload.sq_id;
      make_alloc_entry.is_branch = payload.is_branch;
      make_alloc_entry.checkpoint_id = payload.checkpoint_id;
      make_alloc_entry.branch_mask = branch_mask_q[rob_id];
      make_alloc_entry.serializing = payload.serializing;
      make_alloc_entry.is_csr = payload.is_csr;
      make_alloc_entry.csr_op = payload.csr_op;
      make_alloc_entry.csr_addr = payload.csr_addr;
      make_alloc_entry.csr_zimm = payload.csr_zimm;
      make_alloc_entry.csr_operand = csr_operand_q[rob_id];
      make_alloc_entry.is_ecall = payload.is_ecall;
      make_alloc_entry.is_ebreak = payload.is_ebreak;
      make_alloc_entry.is_mret = payload.is_mret;
      make_alloc_entry.is_fence = payload.is_fence;
      make_alloc_entry.inst = payload.inst;
      make_alloc_entry.exception_valid = exception_valid_q[rob_id];
      make_alloc_entry.exception_cause = exception_cause_q[rob_id];
      make_alloc_entry.exception_tval = exception_tval_q[rob_id];
      make_alloc_entry.pc = payload.pc;
    end
  endfunction

  function automatic rob_entry_t make_head_entry(input logic [ROB_ID_W-1:0] rob_id);
    begin
      make_head_entry.valid = valid_q[rob_id];
      make_head_entry.complete = complete_q[rob_id];
      make_head_entry.entry = make_alloc_entry(rob_id);
    end
  endfunction

  task automatic write_alloc_entry(
      input logic [ROB_ID_W-1:0] rob_id,
      input logic                valid,
      input rob_alloc_t          entry
  );
    begin
      valid_q[rob_id] <= valid;
      complete_q[rob_id] <= valid && entry.exception_valid;
      payload_q[rob_id] <= payload_from_alloc(entry);
      branch_mask_q[rob_id] <= entry.branch_mask;
      csr_operand_q[rob_id] <= '0;
      exception_valid_q[rob_id] <= entry.exception_valid;
      exception_cause_q[rob_id] <= entry.exception_cause;
      exception_tval_q[rob_id] <= entry.exception_tval;
    end
  endtask

  task automatic capture_completion(input completion_t completion);
    rob_payload_t payload;
    begin
      if (completion.valid && valid_q[completion.rob_id]) begin
        payload = payload_q[completion.rob_id];
        complete_q[completion.rob_id] <= 1'b1;
        if (payload.is_csr)
          csr_operand_q[completion.rob_id] <= completion.data;
        if (completion.exception_valid) begin
          exception_valid_q[completion.rob_id] <= 1'b1;
          exception_cause_q[completion.rob_id] <= completion.exception_cause;
          exception_tval_q[completion.rob_id] <= completion.exception_tval;
        end
      end
    end
  endtask

`ifndef SYNTHESIS
  rob_alloc_t entry_q [0:ROB_ENTRIES-1];

  always_comb begin : rob_entry_debug_mirror
    for (int dbg_idx = 0; dbg_idx < ROB_ENTRIES; dbg_idx = dbg_idx + 1)
      entry_q[dbg_idx] = make_alloc_entry(dbg_idx[ROB_ID_W-1:0]);
  end
`endif

  // Ready 只表示本地容量/扫描状态，不能反向依赖 alloc_valid，否则与上游
  // ready->valid 协调逻辑形成组合环。非法 2'b10 不满足 lane0，因此不会 fire。
  assign alloc_ready_o = !scan_busy_q &&
                         !alloc_pending_q &&
                         !exception_flush_pending_q &&
                         !restore_pending_q &&
                         !branch_clear_pending_q &&
                         !exception_flush_i &&
                         !restore_valid_i &&
                         !branch_clear_valid_i &&
                         !full_q;
  assign alloc_fire = alloc_ready_o && alloc_valid_i[0];

  // 退休发射判定：ROB 非空、没有在扫描、提交端发出非零信号、且提交数量能覆盖当前整行已有的有效项
  assign head_row_count = {1'b0, head_entry0_q.valid} +
                          {1'b0, head_entry1_q.valid};
  assign retire_row_fire = !scan_busy_q && (used_rows_q != '0) &&
                           (retire_count_i != 2'd0) &&
                           (retire_count_i >= head_row_count);
  assign retire_lane0_fire = !scan_busy_q && (used_rows_q != '0) &&
                             !head_bank_q && (retire_count_i == 2'd1) &&
                             head_entry0_q.valid && head_entry1_q.valid;

  assign alloc_rob_id0_o = make_rob_id(tail_row_q, 1'b0);
  assign alloc_rob_id1_o = make_rob_id(tail_row_q, 1'b1);

  assign head_valid_o[0] = head_entry0_q.valid;
  assign head_valid_o[1] = head_entry1_q.valid;
  assign head_rob_id_o = make_rob_id(head_row_q, head_bank_q);
  assign head_entry0_o = head_entry0_q;
  assign head_entry1_o = head_entry1_q;

  assign busy_o = scan_busy_q || exception_flush_pending_q ||
                  restore_pending_q || branch_clear_pending_q;
  assign empty_o = (used_rows_q == '0);
  assign full_o = full_q;
  assign occupancy_o = occupancy_q;
  assign branch_clear_done_o = branch_clear_done_q;
  assign restore_done_o = restore_done_q;
  assign exception_flush_done_o = exception_flush_done_q;

  // ==========================================================================
  // 主更新时序逻辑 (ROB Core Sequential Logic)
  // ==========================================================================
  always_ff @(posedge clk_i) begin : rob_state
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
    rob_payload_t completion_payload0;
    rob_payload_t completion_payload1;
    rob_entry_t scan_entry0;
    rob_entry_t scan_entry1;
    rob_entry_t head0_next;
    rob_entry_t head1_next;

    if (rst_i) begin
      valid_q <= '0;
      complete_q <= '0;
      head_row_q <= '0;
      head_bank_q <= 1'b0;
      tail_row_q <= '0;
      used_rows_q <= '0;
      full_q <= 1'b0;
      occupancy_q <= '0;
      head_entry0_q.valid <= 1'b0;
      head_entry0_q.complete <= 1'b0;
      head_entry1_q.valid <= 1'b0;
      head_entry1_q.complete <= 1'b0;
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
      exception_flush_done_q <= 1'b0;
      exception_flush_pending_q <= 1'b0;
      restore_pending_q <= 1'b0;
      restore_tail_pending_q <= '0;
      branch_clear_pending_q <= 1'b0;
      branch_clear_id_pending_q <= '0;
      alloc_pending_q <= 1'b0;
      alloc_pending_valid_q <= '0;
      alloc_pending_id0_q <= '0;
      alloc_pending_id1_q <= '0;
    end else begin
      branch_clear_done_q <= 1'b0;
      restore_done_q <= 1'b0;
      exception_flush_done_q <= 1'b0;

      if (alloc_fire) begin
        alloc_pending_q <= 1'b1;
        alloc_pending_valid_q <= alloc_valid_i;
        alloc_pending_id0_q <= alloc_rob_id0_o;
        alloc_pending_id1_q <= alloc_rob_id1_o;
        alloc_pending_entry0_q <= alloc_entry0_i;
        alloc_pending_entry1_q <= alloc_entry1_i;
      end

      // Raw recovery/checkpoint requests are captured first and applied on the
      // following cycle. This keeps global recovery controller state off the
      // wide ROB entry/valid/complete write-enable network.
      if (exception_flush_i) begin
        exception_flush_pending_q <= 1'b1;
        restore_pending_q <= 1'b0;
        branch_clear_pending_q <= 1'b0;
      end else if (restore_valid_i) begin
        restore_pending_q <= 1'b1;
        restore_tail_pending_q <= restore_tail_i;
        branch_clear_pending_q <= 1'b0;
      end else if (branch_clear_valid_i && !branch_clear_pending_q) begin
        branch_clear_pending_q <= 1'b1;
        branch_clear_id_pending_q <= branch_clear_id_i;
      end

      // 模式 A. 精确异常清空。Entry payload 可保留，valid/complete 全清后不可见。
      // ----------------------------------------------------------------------
      if (exception_flush_pending_q) begin
        valid_q <= '0;
        complete_q <= '0;
        head_row_q <= '0;
        head_bank_q <= 1'b0;
        tail_row_q <= '0;
        used_rows_q <= '0;
        full_q <= 1'b0;
        occupancy_q <= '0;
        head_entry0_q.valid <= 1'b0;
        head_entry0_q.complete <= 1'b0;
        head_entry1_q.valid <= 1'b0;
        head_entry1_q.complete <= 1'b0;
        scan_busy_q <= 1'b0;
        scan_restore_q <= 1'b0;
        scan_row_q <= '0;
        scan_branch_id_q <= '0;
        scan_restore_tail_q <= '0;
        scan_old_tail_row_q <= '0;
        scan_used_rows_q <= '0;
        scan_occupancy_q <= '0;
        exception_flush_pending_q <= 1'b0;
        restore_pending_q <= 1'b0;
        branch_clear_pending_q <= 1'b0;
        alloc_pending_q <= 1'b0;
        alloc_pending_valid_q <= '0;
        exception_flush_done_q <= 1'b1;
      end

      // ----------------------------------------------------------------------
      // 模式 B. 分支恢复扫描初始化 (REC_BRANCH)
      // ----------------------------------------------------------------------
      else if (restore_pending_q) begin
        scan_busy_q <= 1'b1;
        scan_restore_q <= 1'b1;
        scan_row_q <= '0;
        scan_restore_tail_q <= restore_tail_pending_q;
        scan_used_rows_q <= '0;
        scan_occupancy_q <= '0;
        restore_pending_q <= 1'b0;

        if (alloc_pending_q) begin
          write_alloc_entry(alloc_pending_id0_q, alloc_pending_valid_q[0],
                            alloc_pending_entry0_q);
          write_alloc_entry(alloc_pending_id1_q, alloc_pending_valid_q[1],
                            alloc_pending_entry1_q);

          scan_old_tail_row_q <= next_row(tail_row_q);
          tail_row_q <= next_row(tail_row_q);
          alloc_pending_q <= 1'b0;
          alloc_pending_valid_q <= '0;
        end else begin
          scan_old_tail_row_q <= tail_row_q;
        end

        // A restore scan starts one cycle after the raw recovery request. Keep
        // one-cycle completion pulses while normal ROB mutation is paused; the
        // following scan still clears any younger entries killed by recovery.
        capture_completion(complete0_i);
        capture_completion(complete1_i);
      end

      // ----------------------------------------------------------------------
      // 模式 C. 分支正确解析扫描初始化 (Branch resolve clean)
      // ----------------------------------------------------------------------
      else if (branch_clear_pending_q && !scan_busy_q) begin
        scan_busy_q <= 1'b1;
        scan_restore_q <= 1'b0;
        scan_row_q <= '0;
        scan_branch_id_q <= branch_clear_id_pending_q;
        branch_clear_pending_q <= 1'b0;

        if (alloc_pending_q) begin
          write_alloc_entry(alloc_pending_id0_q, alloc_pending_valid_q[0],
                            alloc_pending_entry0_q);
          write_alloc_entry(alloc_pending_id1_q, alloc_pending_valid_q[1],
                            alloc_pending_entry1_q);

          tail_row_q <= next_row(tail_row_q);
          used_rows_q <= used_rows_q + 1'b1;
          full_q <= ((used_rows_q + 1'b1) == ROB_ROWS);
          occupancy_q <= occupancy_q +
              {4'd0, lane_count(alloc_pending_valid_q)};
          alloc_pending_q <= 1'b0;
          alloc_pending_valid_q <= '0;
        end

        // A correct-branch clear scan starts while younger work may still be
        // completing. The scan will clear branch masks on following cycles, but
        // the completion pulse itself must be captured in this init cycle.
        capture_completion(complete0_i);
        capture_completion(complete1_i);
      end

      // ----------------------------------------------------------------------
      // 模式 D. 活跃多周期扫描处理 (Active Sequential Scan)
      // ----------------------------------------------------------------------
      else if (scan_busy_q) begin
        scan_last = (scan_row_q == ROB_ROWS - 1);
        scan_id0 = make_rob_id(scan_row_q, 1'b0);
        scan_id1 = make_rob_id(scan_row_q, 1'b1);
        scan_entry0 = make_head_entry(scan_id0);
        scan_entry1 = make_head_entry(scan_id1);

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
            branch_mask_q[scan_id0] <= branch_mask_q[scan_id0] & clear_mask;
            scan_entry0.entry.branch_mask =
                scan_entry0.entry.branch_mask & clear_mask;
          end
          if (valid_q[scan_id1]) begin
            branch_mask_q[scan_id1] <= branch_mask_q[scan_id1] & clear_mask;
            scan_entry1.entry.branch_mask =
                scan_entry1.entry.branch_mask & clear_mask;
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

        // Checkpoint scans are metadata operations, not execution stalls. Keep
        // accepting completions for entries that survive the active scan;
        // otherwise a completion that arrives during recovery is lost forever.
        if (complete0_i.valid && valid_q[complete0_i.rob_id] &&
            (!scan_restore_q ||
             !restore_kills_id(complete0_i.rob_id, scan_restore_tail_q,
                               scan_old_tail_row_q))) begin
          completion_payload0 = payload_q[complete0_i.rob_id];
          complete_q[complete0_i.rob_id] <= 1'b1;
          if (rob_id_row(complete0_i.rob_id) == scan_row_q) begin
            if (rob_id_bank(complete0_i.rob_id))
              scan_entry1.complete = 1'b1;
            else
              scan_entry0.complete = 1'b1;
          end

          if (completion_payload0.is_csr) begin
            csr_operand_q[complete0_i.rob_id] <= complete0_i.data;
            if (rob_id_row(complete0_i.rob_id) == scan_row_q) begin
              if (rob_id_bank(complete0_i.rob_id))
                scan_entry1.entry.csr_operand = complete0_i.data;
              else
                scan_entry0.entry.csr_operand = complete0_i.data;
            end
          end
          if (complete0_i.exception_valid) begin
            exception_valid_q[complete0_i.rob_id] <= 1'b1;
            exception_cause_q[complete0_i.rob_id] <= complete0_i.exception_cause;
            exception_tval_q[complete0_i.rob_id] <= complete0_i.exception_tval;
            if (rob_id_row(complete0_i.rob_id) == scan_row_q) begin
              if (rob_id_bank(complete0_i.rob_id)) begin
                scan_entry1.entry.exception_valid = 1'b1;
                scan_entry1.entry.exception_cause = complete0_i.exception_cause;
                scan_entry1.entry.exception_tval = complete0_i.exception_tval;
              end else begin
                scan_entry0.entry.exception_valid = 1'b1;
                scan_entry0.entry.exception_cause = complete0_i.exception_cause;
                scan_entry0.entry.exception_tval = complete0_i.exception_tval;
              end
            end
          end
        end

        if (complete1_i.valid && valid_q[complete1_i.rob_id] &&
            (!scan_restore_q ||
             !restore_kills_id(complete1_i.rob_id, scan_restore_tail_q,
                               scan_old_tail_row_q))) begin
          completion_payload1 = payload_q[complete1_i.rob_id];
          complete_q[complete1_i.rob_id] <= 1'b1;
          if (rob_id_row(complete1_i.rob_id) == scan_row_q) begin
            if (rob_id_bank(complete1_i.rob_id))
              scan_entry1.complete = 1'b1;
            else
              scan_entry0.complete = 1'b1;
          end

          if (completion_payload1.is_csr) begin
            csr_operand_q[complete1_i.rob_id] <= complete1_i.data;
            if (rob_id_row(complete1_i.rob_id) == scan_row_q) begin
              if (rob_id_bank(complete1_i.rob_id))
                scan_entry1.entry.csr_operand = complete1_i.data;
              else
                scan_entry0.entry.csr_operand = complete1_i.data;
            end
          end
          if (complete1_i.exception_valid) begin
            exception_valid_q[complete1_i.rob_id] <= 1'b1;
            exception_cause_q[complete1_i.rob_id] <= complete1_i.exception_cause;
            exception_tval_q[complete1_i.rob_id] <= complete1_i.exception_tval;
            if (rob_id_row(complete1_i.rob_id) == scan_row_q) begin
              if (rob_id_bank(complete1_i.rob_id)) begin
                scan_entry1.entry.exception_valid = 1'b1;
                scan_entry1.entry.exception_cause = complete1_i.exception_cause;
                scan_entry1.entry.exception_tval = complete1_i.exception_tval;
              end else begin
                scan_entry0.entry.exception_valid = 1'b1;
                scan_entry0.entry.exception_cause = complete1_i.exception_cause;
                scan_entry0.entry.exception_tval = complete1_i.exception_tval;
              end
            end
          end
        end

        // 扫描行遇到当前 head 时，同步更新提交输出。必须放在 completion
        // 合并之后，否则同拍完成的 head 项会以旧 complete 位重新锁存。
        if (scan_row_q == head_row_q) begin
          if (head_bank_q) begin
            head_entry0_q <= scan_entry1;
            head_entry1_q.valid <= 1'b0;
            head_entry1_q.complete <= 1'b0;
          end else begin
            head_entry0_q <= scan_entry0;
            head_entry1_q <= scan_entry1;
          end
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
            used_rows_next = scan_used_rows_q +
                             {{ROB_ROW_W{1'b0}}, scan_row_survives};
            used_rows_q <= used_rows_next;
            full_q <= (used_rows_next == ROB_ROWS);
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
      // 模式 E. 正常运行状态更新 (Normal execution: Alloc, Complete, Retire)
      // ----------------------------------------------------------------------
      else begin
        used_rows_next = used_rows_q;
        occupancy_next = occupancy_q;
        head_row_next = head_row_q;

        if (alloc_pending_q) begin
          write_alloc_entry(alloc_pending_id0_q, alloc_pending_valid_q[0],
                            alloc_pending_entry0_q);
          write_alloc_entry(alloc_pending_id1_q, alloc_pending_valid_q[1],
                            alloc_pending_entry1_q);

          tail_row_q <= next_row(tail_row_q);
          used_rows_next = used_rows_next + 1'b1;
          occupancy_next = occupancy_next +
              {4'd0, lane_count(alloc_pending_valid_q)};
          alloc_pending_q <= 1'b0;
          alloc_pending_valid_q <= '0;
        end

        // 1. 写回通道 0 完成记录 (直接寻址更新)
        capture_completion(complete0_i);

        // 2. 写回通道 1 完成记录 (直接寻址更新)
        capture_completion(complete1_i);

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
          head_bank_q <= 1'b0;
          used_rows_next = used_rows_next - 1'b1;
          occupancy_next = occupancy_next - {4'd0, head_row_count};
        end else if (retire_lane0_fire) begin
          head_id0 = make_rob_id(head_row_q, 1'b0);
          valid_q[head_id0] <= 1'b0;
          complete_q[head_id0] <= 1'b0;
          head_bank_q <= 1'b1;
          occupancy_next = occupancy_next - 6'd1;
        end

        used_rows_q <= used_rows_next;
        full_q <= (used_rows_next == ROB_ROWS);
        occupancy_q <= occupancy_next;

        // 5. Head payload 只按已寄存的 head_row_q 读取。退休拍清空可见
        // head，下一拍再从新 head_row_q refill，以切断
        // head payload -> commit -> retire -> wide payload mux 的长组合路径。
        head_id0 = make_rob_id(head_row_q, head_bank_q);
        head_id1 = make_rob_id(head_row_q, 1'b1);
        head0_next = make_head_entry(head_id0);
        if (!head_bank_q) begin
          head1_next = make_head_entry(head_id1);
        end else begin
          head1_next = head_entry1_q;
          head1_next.valid = 1'b0;
          head1_next.complete = 1'b0;
        end

        if (retire_row_fire) begin
          head0_next.valid = 1'b0;
          head0_next.complete = 1'b0;
          head1_next.valid = 1'b0;
          head1_next.complete = 1'b0;
        end else if (retire_lane0_fire) begin
          head_id1 = make_rob_id(head_row_q, 1'b1);
          head0_next = make_head_entry(head_id1);
          head1_next = head_entry1_q;
          head1_next.valid = 1'b0;
          head1_next.complete = 1'b0;
        end

        // 旁路直通：若本周期正在完成（Writeback）的指令就是下一周期的 head，则直接旁路更新就绪标志
        if (!retire_row_fire && complete0_i.valid &&
            (rob_id_row(complete0_i.rob_id) == head_row_q)) begin
          if (!rob_id_bank(complete0_i.rob_id)) begin
            head0_next.complete = 1'b1;
            if (head0_next.entry.is_csr)
              head0_next.entry.csr_operand = complete0_i.data;
            if (complete0_i.exception_valid) begin
              head0_next.entry.exception_valid = 1'b1;
              head0_next.entry.exception_cause = complete0_i.exception_cause;
              head0_next.entry.exception_tval = complete0_i.exception_tval;
            end
          end else begin
            head1_next.complete = 1'b1;
            if (head1_next.entry.is_csr)
              head1_next.entry.csr_operand = complete0_i.data;
            if (complete0_i.exception_valid) begin
              head1_next.entry.exception_valid = 1'b1;
              head1_next.entry.exception_cause = complete0_i.exception_cause;
              head1_next.entry.exception_tval = complete0_i.exception_tval;
            end
          end
        end

        if (!retire_row_fire && complete1_i.valid &&
            (rob_id_row(complete1_i.rob_id) == head_row_q)) begin
          if (!rob_id_bank(complete1_i.rob_id)) begin
            head0_next.complete = 1'b1;
            if (head0_next.entry.is_csr)
              head0_next.entry.csr_operand = complete1_i.data;
            if (complete1_i.exception_valid) begin
              head0_next.entry.exception_valid = 1'b1;
              head0_next.entry.exception_cause = complete1_i.exception_cause;
              head0_next.entry.exception_tval = complete1_i.exception_tval;
            end
          end else begin
            head1_next.complete = 1'b1;
            if (head1_next.entry.is_csr)
              head1_next.entry.csr_operand = complete1_i.data;
            if (complete1_i.exception_valid) begin
              head1_next.entry.exception_valid = 1'b1;
              head1_next.entry.exception_cause = complete1_i.exception_cause;
              head1_next.entry.exception_tval = complete1_i.exception_tval;
            end
          end
        end

        if (used_rows_q == '0) begin
          head_entry0_q.valid <= 1'b0;
          head_entry0_q.complete <= 1'b0;
          head_entry1_q.valid <= 1'b0;
          head_entry1_q.complete <= 1'b0;
        end else begin
          head_entry0_q <= head0_next;
          head_entry1_q <= head1_next;
        end
      end
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk_i) begin : rob_interface_assertions
    if (!rst_i) begin
      assert (alloc_valid_i != 2'b10)
        else $error("ROB allocation valid must be prefix encoded");
      assert (full_q == (used_rows_q == ROB_ROWS))
        else $error("ROB full_q must track used_rows_q");
    end
  end
`endif

endmodule
