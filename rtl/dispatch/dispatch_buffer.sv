import core_types_pkg::*;

// dispatch_buffer.sv
// 分派缓冲区 (Dispatch Buffer)
// 职责：
// 1. 作为重命名级（Rename）与发射队列（Issue Queue）之间的弹性边界（Elastic Buffer），缓存重命名后的微操作；
// 2. 维护一个 6 项容量的循环队列（Circular Buffer），支持双路顺序入队和顺序分派（In-order Dispatch）；
// 3. 微操作指令分类路由：
//    - `FU_LSU`（访存类）分派至 Memory Issue Queue (Mem IQ)；
//    - `FU_MUL/FU_DIV`（乘除法类）分派至 MDU Issue Queue (Mdu IQ)；
//    - 其它（普通整型、分支跳转、CSR 读写等）分派至 Integer Issue Queue (Int IQ)；
// 4. 双路顺序发射条件控制：
//    - 严格按顺序分派，保证 Lane 1 指令绝不越过被阻塞的 Lane 0 指令（即 Lane 1 发射蕴含 Lane 0 发射）；
//    - 动态整合分派端口：若两个同类型指令同时发射，自动将其排列至该类型 IQ 对应的 uop0 与 uop1 端口；
// 5. 遭遇全局恢复（Flush）时，一拍清空整个分派缓冲区。

module dispatch_buffer (
    input  logic        clk_i,             // 时钟信号
    input  logic        rst_i,             // 复位信号 (高电平有效)

    // 重命名级（Rename Stage）输入接口
    input  logic [1:0]  rn_valid_i,        // 输入重命名微操作有效指示 (0/1/2)
    output logic        rn_ready_o,        // 本缓冲区空间足够，允许 Rename 输入 (反压)
    input  renamed_uop_t rn_uop0_i,        // lane0 锁存的重命名微操作 payload
    input  renamed_uop_t rn_uop1_i,        // lane1 锁存的重命名微操作 payload

    // 路由分派至整型发射队列 (Integer IQ) 端口
    output logic [1:0]  int_push_valid_o,  // 整型 IQ 写入有效指示
    input  logic [1:0]  int_push_ready_i,  // 整型 IQ 空槽就绪指示 (反压)
    output issue_uop_t  int_push_uop0_o,   // 写入整型 IQ 的 uop0
    output issue_uop_t  int_push_uop1_o,   // 写入整型 IQ 的 uop1

    // 路由分派至访存发射队列 (Memory IQ) 端口
    output logic [1:0]  mem_push_valid_o,  // 访存 IQ 写入有效指示
    input  logic [1:0]  mem_push_ready_i,  // 访存 IQ 空槽就绪指示 (反压)
    output issue_uop_t  mem_push_uop0_o,   // 写入访存 IQ 的 uop0
    output issue_uop_t  mem_push_uop1_o,   // 写入访存 IQ 的 uop1

    // 路由分派至乘除法发射队列 (MDU IQ) 端口
    output logic [1:0]  mdu_push_valid_o,  // MDU IQ 写入有效指示
    input  logic [1:0]  mdu_push_ready_i,  // MDU IQ 空槽就绪指示 (反压)
    output issue_uop_t  mdu_push_uop0_o,   // 写入 MDU IQ 的 uop0
    output issue_uop_t  mdu_push_uop1_o,   // 写入 MDU IQ 的 uop1

    // 写回唤醒广播
    input  logic [1:0]  wb_valid_i,        // 写回 ready 广播有效位
    input  logic [1:0][PRD_W-1:0] wb_prd_i,// 写回 ready 广播 PRD

    // 全局恢复控制
    input  recovery_t   recovery_i,        // 恢复控制信号 (分支误预测或精确异常)

    // 缓冲区状态输出
    output logic        empty_o,           // 缓冲区空状态指示
    output logic        full_o,            // 缓冲区满状态指示
    output logic [2:0]  occupancy_o        // 当前缓冲区占用项数
);

  localparam int DB_ENTRIES = 6;            // 分派队列大小
  localparam int PTR_W = 3;                 // 指针宽度

  // 指令分类枚举
  typedef enum logic [1:0] {
    CLASS_INT = 2'd0,                       // 整型执行类 (ALU/Branch/CSR)
    CLASS_MEM = 2'd1,                       // 访存执行类 (Load/Store)
    CLASS_MDU = 2'd2                        // 乘除法执行类 (MUL/DIV)
  } dispatch_class_t;

  // 缓冲区内部存储单元
  logic [DB_ENTRIES-1:0] valid_q;           // 各槽位有效标志位
  renamed_uop_t uop_q [0:DB_ENTRIES-1];     // 微操作 payload 寄存器数组
  logic [PTR_W-1:0] head_q;                 // 循环队列头指针 (出队端)
  logic [PTR_W-1:0] tail_q;                 // 循环队列尾指针 (入队端)
  logic [PTR_W-1:0] count_q;                // 当前队列占用条数

  // 内部临时判定信号
  renamed_uop_t head0_uop;
  renamed_uop_t head1_uop;
  issue_uop_t head0_issue;
  issue_uop_t head1_issue;
  dispatch_class_t head0_class;
  dispatch_class_t head1_class;
  logic head0_valid;
  logic head1_valid;
  logic dispatch0_fire;
  logic dispatch1_fire;
  logic [1:0] dispatch_count;
  logic [1:0] rn_count;
  logic [PTR_W-1:0] head1_ptr;
  logic [PTR_W-1:0] tail1_ptr;

  // 指针自增循环处理函数
  function automatic logic [PTR_W-1:0] ptr_inc(input logic [PTR_W-1:0] ptr);
    ptr_inc = (ptr == DB_ENTRIES - 1) ? '0 : ptr + 1'b1;
  endfunction

  // 指针加 2 循环处理函数
  function automatic logic [PTR_W-1:0] ptr_add2(input logic [PTR_W-1:0] ptr);
    ptr_add2 = ptr_inc(ptr_inc(ptr));
  endfunction

  // 计算输入的 valid 包含的有效个数
  function automatic logic [1:0] valid_count(input logic [1:0] valid);
    valid_count = (valid == 2'b11) ? 2'd2 :
                  ((valid == 2'b01) ? 2'd1 : 2'd0);
  endfunction

  function automatic logic wake_src(
      input logic             ready,
      input logic             need_src,
      input logic [PRD_W-1:0] prs
  );
    begin
      wake_src = ready || !need_src ||
                 (wb_valid_i[0] && (wb_prd_i[0] == prs)) ||
                 (wb_valid_i[1] && (wb_prd_i[1] == prs));
    end
  endfunction

  function automatic renamed_uop_t wake_renamed(input renamed_uop_t uop);
    renamed_uop_t woke;
    begin
      woke = uop;
      woke.src1_ready = wake_src(uop.src1_ready, uop.dec.need_rs1, uop.prs1);
      woke.src2_ready = wake_src(uop.src2_ready, uop.dec.need_rs2, uop.prs2);
      wake_renamed = woke;
    end
  endfunction

  // 指令分类解算器：将功能单元类型转换为分派路由类别
  function automatic dispatch_class_t classify(input renamed_uop_t uop);
    begin
      case (uop.dec.fu_type)
        FU_LSU:
          classify = CLASS_MEM;
        FU_MUL, FU_DIV:
          classify = CLASS_MDU;
        default:
          classify = CLASS_INT;
      endcase
    end
  endfunction

  // 格式转换函数：将 renamed_uop_t 转换为发射阶段所使用的 issue_uop_t
  function automatic issue_uop_t to_issue(input renamed_uop_t uop);
    issue_uop_t issue;
    begin
      issue = '0;
      issue.prd = uop.prd;
      issue.prs1 = uop.prs1;
      issue.prs2 = uop.prs2;
      issue.src1_ready = uop.src1_ready;
      issue.src2_ready = uop.src2_ready;
      issue.imm = uop.dec.imm;
      issue.pc = uop.dec.pc;
      issue.pred_taken = uop.dec.pred_taken;
      issue.pred_target = uop.dec.pred_target;
      issue.fu_type = uop.dec.fu_type;
      issue.alu_op = uop.dec.alu_op;
      issue.branch_op = uop.dec.branch_op;
      issue.mem_op = uop.dec.mem_op;
      issue.mul_op = uop.dec.mul_op;
      issue.div_op = uop.dec.div_op;
      issue.csr_op = uop.dec.csr_op;
      issue.csr_addr = uop.dec.csr_addr;
      issue.csr_zimm = uop.dec.csr_zimm;
      issue.rob_id = uop.rob_id;
      issue.old_prd = uop.old_prd;
      issue.lq_id = uop.lq_id;
      issue.sq_id = uop.sq_id;
      issue.checkpoint_id = uop.checkpoint_id;
      issue.branch_mask = uop.branch_mask;
      issue.write_rd = uop.dec.write_rd;
      issue.is_load = (uop.dec.fu_type == FU_LSU) &&
          ((uop.dec.mem_op == MEM_LB) || (uop.dec.mem_op == MEM_LH) ||
           (uop.dec.mem_op == MEM_LW) || (uop.dec.mem_op == MEM_LBU) ||
           (uop.dec.mem_op == MEM_LHU));
      issue.is_store = (uop.dec.fu_type == FU_LSU) &&
          ((uop.dec.mem_op == MEM_SB) || (uop.dec.mem_op == MEM_SH) ||
           (uop.dec.mem_op == MEM_SW));
      issue.serializing = uop.dec.serializing;
      issue.need_rs1 = uop.dec.need_rs1;
      issue.need_rs2 = uop.dec.need_rs2;
      return issue;
    end
  endfunction

  // 查询各执行队列空槽是否可接纳第 1 个分派 uop (对应 IQ port0)
  function automatic logic class_ready_one(
      input dispatch_class_t cls,
      input logic [1:0] int_ready,
      input logic [1:0] mem_ready,
      input logic [1:0] mdu_ready
  );
    begin
      case (cls)
        CLASS_MEM:
          class_ready_one = mem_ready[0];
        CLASS_MDU:
          class_ready_one = mdu_ready[0];
        default:
          class_ready_one = int_ready[0];
      endcase
    end
  endfunction

  // 查询各执行队列空槽是否可接纳第 2 个分派 uop (对应 IQ port1)
  function automatic logic class_ready_two(
      input dispatch_class_t cls,
      input logic [1:0] int_ready,
      input logic [1:0] mem_ready,
      input logic [1:0] mdu_ready
  );
    begin
      case (cls)
        CLASS_MEM:
          class_ready_two = mem_ready[1];
        CLASS_MDU:
          class_ready_two = mdu_ready[1];
        default:
          class_ready_two = int_ready[1];
      endcase
    end
  endfunction

  // 重命名级流控与握手判定
  assign rn_count = valid_count(rn_valid_i);
  // 当没有处于恢复模式、且缓冲区空余项足够容纳本周期请求数量时就绪
  assign rn_ready_o = !recovery_i.valid && (rn_valid_i != 2'b10) &&
                      (rn_count <= (DB_ENTRIES[PTR_W-1:0] - count_q));

  assign empty_o = (count_q == '0);
  assign full_o = (count_q == DB_ENTRIES[PTR_W-1:0]);
  assign occupancy_o = count_q;

  // 读头解算
  assign head1_ptr = ptr_inc(head_q);
  assign tail1_ptr = ptr_inc(tail_q);
  assign head0_valid = valid_q[head_q] && (count_q != '0);
  assign head1_valid = valid_q[head1_ptr] && (count_q >= 3'd2);
  assign head0_uop = uop_q[head_q];
  assign head1_uop = uop_q[head1_ptr];
  assign head0_issue = to_issue(wake_renamed(head0_uop));
  assign head1_issue = to_issue(wake_renamed(head1_uop));
  assign head0_class = classify(head0_uop);
  assign head1_class = classify(head1_uop);

  // 顺序发射握手解算：
  // 1. head0 指令有效，且目标 IQ 至少有一个就绪空槽时，head0 握手成功；
  // 2. head1 指令必须在 head0 握手成功的情况下才允许握手成功（实现顺序发射 In-order）；
  // 3. 若 head1 与 head0 属于同一种执行类，则要求目标 IQ 同时有 2 个就绪槽位；若不同类，则各自查询 ready[0] 即可。
  assign dispatch0_fire = head0_valid &&
                          class_ready_one(head0_class, int_push_ready_i,
                                          mem_push_ready_i, mdu_push_ready_i);
  assign dispatch1_fire = dispatch0_fire && head1_valid &&
      ((head1_class == head0_class) ?
       class_ready_two(head1_class, int_push_ready_i, mem_push_ready_i,
                       mdu_push_ready_i) :
       class_ready_one(head1_class, int_push_ready_i, mem_push_ready_i,
                       mdu_push_ready_i));
  assign dispatch_count = {1'b0, dispatch0_fire} + {1'b0, dispatch1_fire};

  // ==========================================================================
  // 分派指令路由连线组合块 (Combinational Dispatch Routing)
  // ==========================================================================
  always_comb begin
    int_push_valid_o = 2'b00;
    mem_push_valid_o = 2'b00;
    mdu_push_valid_o = 2'b00;
    int_push_uop0_o = '0;
    int_push_uop1_o = '0;
    mem_push_uop0_o = '0;
    mem_push_uop1_o = '0;
    mdu_push_uop0_o = '0;
    mdu_push_uop1_o = '0;

    // 分派 Lane 0 (对应 head0)
    if (dispatch0_fire) begin
      case (head0_class)
        CLASS_MEM: begin
          mem_push_valid_o[0] = 1'b1;
          mem_push_uop0_o = head0_issue;
        end
        CLASS_MDU: begin
          mdu_push_valid_o[0] = 1'b1;
          mdu_push_uop0_o = head0_issue;
        end
        default: begin
          int_push_valid_o[0] = 1'b1;
          int_push_uop0_o = head0_issue;
        end
      endcase
    end

    // 分派 Lane 1 (对应 head1)
    if (dispatch1_fire) begin
      case (head1_class)
        CLASS_MEM: begin
          // 若同一周期内分配了两个访存 uop，则 head1 写入 port1；否则写入 port0
          if (mem_push_valid_o[0]) begin
            mem_push_valid_o[1] = 1'b1;
            mem_push_uop1_o = head1_issue;
          end else begin
            mem_push_valid_o[0] = 1'b1;
            mem_push_uop0_o = head1_issue;
          end
        end
        CLASS_MDU: begin
          // 若同一周期内分配了两个 MDU uop，则 head1 写入 port1；否则写入 port0
          if (mdu_push_valid_o[0]) begin
            mdu_push_valid_o[1] = 1'b1;
            mdu_push_uop1_o = head1_issue;
          end else begin
            mdu_push_valid_o[0] = 1'b1;
            mdu_push_uop0_o = head1_issue;
          end
        end
        default: begin
          // 若同一周期内分配了两个整型 uop，则 head1 写入 port1；否则写入 port0
          if (int_push_valid_o[0]) begin
            int_push_valid_o[1] = 1'b1;
            int_push_uop1_o = head1_issue;
          end else begin
            int_push_valid_o[0] = 1'b1;
            int_push_uop0_o = head1_issue;
          end
        end
      endcase
    end
  end

  // ==========================================================================
  // 缓冲区队列指针与数据寄存器更新 (Sequential Queue Update Logic)
  // ==========================================================================
  always_ff @(posedge clk_i) begin : dispatch_buffer_state
    integer idx;
    logic [PTR_W-1:0] next_head;
    logic [PTR_W-1:0] next_tail;
    logic [PTR_W:0] next_count;

    if (rst_i) begin
      valid_q <= '0;
      for (idx = 0; idx < DB_ENTRIES; idx = idx + 1)
        uop_q[idx] <= '0;
      head_q <= '0;
      tail_q <= '0;
      count_q <= '0;
    end else if (recovery_i.valid) begin
      // 遭遇任何重定向恢复（分支误预测或异常）时，一拍直接清空整个分派缓冲区。
      // 注意：暂时采用全局清空的设计来缩短关键路径，简化恢复时序。
      valid_q <= '0;
      head_q <= '0;
      tail_q <= '0;
      count_q <= '0;
    end else begin
      next_head = head_q;
      next_tail = tail_q;
      next_count = {1'b0, count_q};

      for (idx = 0; idx < DB_ENTRIES; idx = idx + 1) begin
        if (valid_q[idx])
          uop_q[idx] <= wake_renamed(uop_q[idx]);
      end

      // 1. 指令出队 (Dispatch)
      if (dispatch_count != 0) begin
        valid_q[head_q] <= 1'b0;
        if (dispatch_count == 2'd2)
          valid_q[head1_ptr] <= 1'b0;
        next_head = (dispatch_count == 2'd2) ? ptr_add2(head_q) :
                                              ptr_inc(head_q);
        next_count = next_count - dispatch_count;
      end

      // 2. 指令入队 (Rename enqueue)
      if ((rn_valid_i != 2'b00) && rn_ready_o) begin
        valid_q[tail_q] <= rn_valid_i[0];
        uop_q[tail_q] <= wake_renamed(rn_uop0_i);
        if (rn_valid_i[1]) begin
          valid_q[tail1_ptr] <= 1'b1;
          uop_q[tail1_ptr] <= wake_renamed(rn_uop1_i);
        end
        next_tail = rn_valid_i[1] ? ptr_add2(tail_q) : ptr_inc(tail_q);
        next_count = next_count + rn_count;
      end

      head_q <= next_head;
      tail_q <= next_tail;
      count_q <= next_count[PTR_W-1:0];
    end
  end

endmodule
