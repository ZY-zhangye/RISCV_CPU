`timescale 1ns/1ps

import core_types_pkg::*;

// branch_predictor.sv
// 分支预测器模块 (Branch Predictor)
// 职责：
// 1. 采用 V1 版本设计：每 16 字节指令块（包含 4 个指令槽）占用 1 个 BTB 项；
// 2. 包含一个针对单条指令粒度的 BHT（分支历史表，存储 2-bit 饱和计数器）；
// 3. 包含一个容量为 2 的更新 FIFO 缓冲，用以平滑执行端的分支解析结果写回，避免阻塞。

module branch_predictor (
    input  logic           clk_i,             // 时钟信号
    input  logic           rst_i,             // 复位信号 (高电平有效)

    // 查询接口 (来自取指阶段 F0)
    input  logic           query_valid_i,     // 查询请求有效
    input  bp_query_t      query_i,           // 查询 PC 和取指 ID
    output bp_pred_t       pred_o,            // 输出预测结果 (F1 采样)

    // 更新接口 (来自流水线后端分支解析)
    input  logic           update_valid_i,    // 分支解析更新请求有效
    input  branch_update_t update_i           // 分支实际执行结果负载
);

  // 内部参数定义
  localparam int BTB_INDEX_W = $clog2(BTB_ENTRIES);   // BTB 条目索引位宽 (如 128 项对应 7 位)
  localparam int BHT_INDEX_W = $clog2(BHT_ENTRIES);   // BHT 条目索引位宽 (如 512 项对应 9 位)
  localparam int BTB_TAG_W   = 32 - BTB_INDEX_W - 4;  // BTB Tag 位宽 (去掉了低4位16字节块内偏移以及 Index 字段)

  // BTB 中记录的分支指令类型枚举
  typedef enum logic [1:0] {
    BTB_COND    = 2'd0,  // 条件分支指令 (B-type)
    BTB_JAL     = 2'd1,  // 立即数无条件跳转指令 (J-type)
    BTB_JALR    = 2'd2,  // 寄存器无条件跳转指令 (I-type)
    BTB_INVALID = 2'd3   // 无效项
  } btb_type_t;

  // BTB 表项结构体
  typedef struct packed {
    logic [BTB_TAG_W-1:0] tag;          // PC 标识 Tag
    logic [1:0]           slot;         // 该跳转指令在 16 字节对齐块中的槽位编号 (0~3)
    logic [31:0]          target;       // 预测的跳转目标 PC
    btb_type_t            branch_type;  // 分支指令类型
  } btb_entry_t;

  // BTB 存储阵列及有效位寄存器
  btb_entry_t btb_q [0:BTB_ENTRIES-1];
  logic [BTB_ENTRIES-1:0] btb_valid_q;

  // BHT 2-bit 饱和计数器阵列及有效位寄存器
  logic [1:0] bht_q [0:BHT_ENTRIES-1];
  logic [BHT_ENTRIES-1:0] bht_valid_q;

  // 更新缓冲 FIFO (容量为 2 的环形队列)，用以暂存执行端传入的分支更新请求
  branch_update_t update_fifo_q [0:1];
  logic update_head_q;                 // FIFO 读指针 (头)
  logic update_tail_q;                 // FIFO 写指针 (尾)
  logic [1:0] update_count_q;          // FIFO 计数器 (0/1/2)

  // 预测结果寄存器与输出
  bp_pred_t pred_q;
  assign pred_o = pred_q;

  // ==========================================================================
  // 辅助转换函数 (Helper Functions)
  // ==========================================================================
  // 从 PC 计算 BTB 索引：使用 pc[BTB_INDEX_W+3:4]
  function automatic logic [BTB_INDEX_W-1:0] btb_index(
      input logic [31:0] pc
  );
    btb_index = pc[BTB_INDEX_W+3:4];
  endfunction

  // 从 PC 计算 BTB Tag 标识
  function automatic logic [BTB_TAG_W-1:0] btb_tag(
      input logic [31:0] pc
  );
    btb_tag = pc[31:BTB_INDEX_W+4];
  endfunction

  // 从 PC 计算 BHT 索引：BHT 是指令粒度的，使用 pc[BHT_INDEX_W+1:2]
  function automatic logic [BHT_INDEX_W-1:0] bht_index(
      input logic [31:0] pc
  );
    bht_index = pc[BHT_INDEX_W+1:2];
  endfunction

  // 计算 2-bit 饱和历史计数器的下一次更新值
  // 强跳转 (11) <-> 弱跳转 (10) <-> 弱不跳转 (01) <-> 强不跳转 (00)
  function automatic logic [1:0] bht_next(
      input logic [1:0] old_counter,
      input logic       taken
  );
    if (taken)
      bht_next = (old_counter == 2'b11) ? 2'b11 : old_counter + 2'b01;
    else
      bht_next = (old_counter == 2'b00) ? 2'b00 : old_counter - 2'b01;
  endfunction

  // ==========================================================================
  // 核心时序控制逻辑 (Predictor State Engine)
  // ==========================================================================
  always_ff @(posedge clk_i) begin : predictor_state
    btb_entry_t query_entry;
    btb_entry_t update_entry;
    btb_entry_t replacement_entry;
    branch_update_t applied_update;
    logic [BTB_INDEX_W-1:0] query_btb_idx;
    logic [BHT_INDEX_W-1:0] query_bht_idx;
    logic [BTB_INDEX_W-1:0] update_btb_idx;
    logic [BHT_INDEX_W-1:0] update_bht_idx;
    logic query_tag_hit;
    logic update_replaces_btb;

    if (rst_i) begin
      // 同步复位初始化
      pred_q         <= '0;
      btb_valid_q    <= '0;
      bht_valid_q    <= '0;
      update_head_q  <= 1'b0;
      update_tail_q  <= 1'b0;
      update_count_q <= 2'd0;
    end else begin
      // ========================================================================
      // 1. 查询处理阶段 (F0 -> F1 寄存输出时序接口)
      // ========================================================================
      pred_q <= '0;
      if (query_valid_i) begin
        query_btb_idx = btb_index(query_i.pc);
        query_entry   = btb_q[query_btb_idx];
        // 判定 BTB 是否命中：有效位、Tag 匹配且类型不为无效项
        query_tag_hit = btb_valid_q[query_btb_idx] &&
                        (query_entry.tag == btb_tag(query_i.pc)) &&
                        (query_entry.branch_type != BTB_INVALID);

        if (query_tag_hit) begin
          pred_q.valid      <= 1'b1;
          pred_q.btb_slot   <= query_entry.slot;
          pred_q.btb_target <= query_entry.target;

          // 拼接 BHT 查询索引：通过 16字节块 PC 部分与块中命中分支的 slot 编号组合
          query_bht_idx = {query_i.pc[BTB_INDEX_W+3:4], query_entry.slot};

          case (query_entry.slot)
            2'd0: begin
              pred_q.btb_hit[0] <= 1'b1;
              if (query_entry.branch_type == BTB_COND)
                // 条件分支取决于 BHT 状态机的高位 (1: Taken, 0: Not-Taken)
                pred_q.bht_taken[0] <= bht_valid_q[query_bht_idx] &&
                                       bht_q[query_bht_idx][1];
              else if ((query_entry.branch_type == BTB_JAL) ||
                       (query_entry.branch_type == BTB_JALR))
                // 无条件跳转恒预测为 Taken
                pred_q.bht_taken[0] <= 1'b1;
            end
            2'd1: begin
              pred_q.btb_hit[1] <= 1'b1;
              if (query_entry.branch_type == BTB_COND)
                pred_q.bht_taken[1] <= bht_valid_q[query_bht_idx] &&
                                       bht_q[query_bht_idx][1];
              else if ((query_entry.branch_type == BTB_JAL) ||
                       (query_entry.branch_type == BTB_JALR))
                pred_q.bht_taken[1] <= 1'b1;
            end
            2'd2: begin
              pred_q.btb_hit[2] <= 1'b1;
              if (query_entry.branch_type == BTB_COND)
                pred_q.bht_taken[2] <= bht_valid_q[query_bht_idx] &&
                                       bht_q[query_bht_idx][1];
              else if ((query_entry.branch_type == BTB_JAL) ||
                       (query_entry.branch_type == BTB_JALR))
                pred_q.bht_taken[2] <= 1'b1;
            end
            2'd3: begin
              pred_q.btb_hit[3] <= 1'b1;
              if (query_entry.branch_type == BTB_COND)
                pred_q.bht_taken[3] <= bht_valid_q[query_bht_idx] &&
                                       bht_q[query_bht_idx][1];
              else if ((query_entry.branch_type == BTB_JAL) ||
                       (query_entry.branch_type == BTB_JALR))
                pred_q.bht_taken[3] <= 1'b1;
            end
            default: pred_q <= '0;
          endcase
        end
      end

      // ========================================================================
      // 2. 更新处理阶段 (FIFO 排水退休，每周期最多执行一次更新)
      // ========================================================================
      if (update_count_q != 2'd0) begin
        // 出队一个更新项并解析
        applied_update = update_fifo_q[update_head_q];
        update_btb_idx = btb_index(applied_update.pc);
        update_bht_idx = bht_index(applied_update.pc);
        update_entry   = btb_q[update_btb_idx];

        // A. 更新条件分支历史表 (BHT)
        if (applied_update.is_branch) begin
          if (bht_valid_q[update_bht_idx])
            // 改变已有的 2-bit 饱和计数器值
            bht_q[update_bht_idx] <= bht_next(bht_q[update_bht_idx],
                                              applied_update.taken);
          else
            // 未初始化条目，首次依实际方向以弱状态初始化 (Taken -> 10 弱跳转, Not Taken -> 01 弱不跳转)
            bht_q[update_bht_idx] <= applied_update.taken ? 2'b10 : 2'b01;
          bht_valid_q[update_bht_idx] <= 1'b1;
        end

        // B. 更新分支目标缓冲 (BTB)
        if (applied_update.is_branch || applied_update.is_jal ||
            applied_update.is_jalr) begin
          // 判定是否应当替换当前 BTB 中的数据项。
          // 当满足以下任一条件时进行覆盖更新：
          // 1) 原项无效；
          // 2) Tag 不匹配 (发生索引冲突)；
          // 3) 原项命中，但当前更新的分支比旧分支在 16字节块中更靠前 (slot更小)。
          // 这样做可保证多发射乱序执行下，每个 16 字节块总是只记录“最早触发跳转”的那个分支指令。
          update_replaces_btb = !btb_valid_q[update_btb_idx] ||
              (update_entry.tag != btb_tag(applied_update.pc)) ||
              (applied_update.pc[3:2] <= update_entry.slot);

          if (update_replaces_btb) begin
            replacement_entry.tag    = btb_tag(applied_update.pc);
            replacement_entry.slot   = applied_update.pc[3:2];
            replacement_entry.target = applied_update.target;
            if (applied_update.is_jalr)
              replacement_entry.branch_type = BTB_JALR;
            else if (applied_update.is_jal)
              replacement_entry.branch_type = BTB_JAL;
            else
              replacement_entry.branch_type = BTB_COND;

            btb_valid_q[update_btb_idx] <= 1'b1;
            btb_q[update_btb_idx]       <= replacement_entry;
          end
        end

        // 读指针移位
        update_head_q <= ~update_head_q;
      end

      // ========================================================================
      // 3. FIFO 写入控制阶段 (每周期可接收一个新的外部更新)
      // ========================================================================
      if (update_valid_i) begin
        update_fifo_q[update_tail_q] <= update_i;
        update_tail_q <= ~update_tail_q;
      end

      // FIFO 计数器控制：利用独热式/计数器更新
      case ({update_valid_i, (update_count_q != 2'd0)})
        2'b10: update_count_q <= update_count_q + 2'd1; // 仅写入
        2'b01: update_count_q <= update_count_q - 2'd1; // 仅读出
        default: update_count_q <= update_count_q;       // 同时读写 或 无操作
      endcase
    end
  end

  // ==========================================================================
  // 系统断言 (SystemVerilog Assertions)
  // ==========================================================================
`ifdef BRANCH_PREDICTOR_ASSERTIONS
  // 断言：验证 FIFO 在任何时候均不会发生溢出 (容量最大为 2)
  property p_update_buffer_capacity;
    @(posedge clk_i) disable iff (rst_i) update_count_q <= 2;
  endproperty
  assert property (p_update_buffer_capacity);

  // 断言：每次输入的跳转指令更新，其类型 (B-type, JAL, JALR) 必须是独热码 (One-hot) 关系
  property p_update_type_onehot;
    @(posedge clk_i) disable iff (rst_i)
      update_valid_i |-> $onehot({update_i.is_branch, update_i.is_jal,
                                  update_i.is_jalr});
  endproperty
  assert property (p_update_type_onehot);
`endif

endmodule
