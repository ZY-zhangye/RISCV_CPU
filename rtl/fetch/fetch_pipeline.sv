`timescale 1ns/1ps

import core_types_pkg::*;

// fetch_pipeline.sv
// 弹性流水化取指单元 (Elastic Instruction-Fetch Pipeline)
//
// 流水线阶段定义：
// F0：发起对齐的指令存储器 (IMem) 读请求与分支预测器 (BP) 查询，并推进投机 PC。
// F1：通过容量为 2 的 Skid FIFO 缓存按顺序到达的 IMem 响应数据。
// F2：选择并解析分支预测结果，组装取指包 (Fetch Packet)，并保持输出直至下游接收。
//
// 特性：
// 该接口允许最多一个未决且有序的 IMem 内存请求。在当前请求响应到达的同一个周期，
// 可以发起一个新的取指请求。对于单周期同步 IMem，可实现每周期发起一次请求的满吞吐。
// Skid FIFO 在正常流水状态下保持为空，仅当 F2 阶段发生反压阻塞时，用于吸收已发出的在途内存响应。

module fetch_pipeline (
    input  logic          clk_i,              // 时钟信号
    input  logic          rst_i,              // 复位信号 (高电平有效)

    // 外部重定向接口 (来自流水线后端，如执行端或提交端)
    input  logic          redirect_valid_i,   // 后端重定向有效
    input  logic [31:0]   redirect_target_i,  // 后端重定向的目标 PC

    // 外部指令缓冲 (Instruction Buffer) 接口
    input  logic          ibuf_ready_i,       // 下游指令缓冲就绪信号 (反压)
    output logic          fetch_valid_o,      // 输出的取指数据有效 (F2 阶段数据有效)
    output fetch_packet_t fetch_packet_o,     // 输出的取指数据包

    // 分支预测器查询接口
    output logic          bp_query_valid_o,   // 分支预测查询有效
    output bp_query_t     bp_query_o,         // 分支预测查询包 (F0 阶段输出)
    input  bp_pred_t      bp_result_i,        // 分支预测返回的结果

    // 指令存储器 (IMem) 接口
    output logic          imem_req_valid_o,   // IMem 读请求有效
    output logic [31:0]   imem_req_addr_o,    // IMem 读请求地址 (16字节对齐)
    input  logic          imem_resp_valid_i,  // IMem 响应有效
    input  logic [127:0]  imem_resp_data_i    // IMem 返回的 128 位指令块数据
);

  // 指令地址非对齐异常码定义
  localparam logic [3:0] EXC_INST_ADDR_MISALIGNED = 4'd0;

  // 前端最大存储容量 (3 = F2 阶段的 1 项 + F1 的 2 项 Skid FIFO 缓存)
  localparam int FRONT_CAPACITY = 3;

  // IMem 响应暂存条目结构体 (存储在 Skid FIFO 中)
  typedef struct packed {
    logic [31:0]                    pc;              // 该指令块对应的起始 PC
    logic [127:0]                   data;            // IMem 读出的 128 位数据
    logic [FETCH_ID_W_FULL-1:0]     fetch_id;        // 对应的取指事务 ID
    logic                           epoch;           // 发起请求时的系统纪元
    bp_pred_t                       prediction;      // 对应的分支预测结果
    logic                           exception_valid; // 是否携带取指异常
  } response_entry_t;

  // ==========================================================================
  // 寄存状态与流水线寄存器 (Registers)
  // ==========================================================================
  logic [31:0] pc_f0_q;                          // F0 阶段当前的程序计数器 (PC)
  logic [FETCH_ID_W_FULL-1:0] next_fetch_id_q;   // 下一个分配的取指事务 ID
  logic epoch_q;                                 // 当前系统取指纪元 (用于重定向后过滤在途的过期响应)

  // 外部 IMem 在途读请求状态跟踪
  logic req_pending_q;                           // 标志当前有一个正在等待内存响应的读请求
  logic req_stale_q;                             // 标志在等待期间收到了重定向，当前的响应已过期需丢弃
  logic req_pred_captured_q;                     // 标志分支预测器的结果已提早在等待内存响应时被锁存
  logic [31:0] req_pc_q;                         // 锁存的请求 PC 地址
  logic [FETCH_ID_W_FULL-1:0] req_fetch_id_q;   // 锁存的取指 ID
  logic req_epoch_q;                             // 发起请求时的系统纪元
  bp_pred_t req_pred_q;                          // 锁存的预测器结果

  // F1 Skid FIFO (容量为 2)，用于存储/滑移 IMem 响应数据
  response_entry_t response_fifo_q [0:1];
  logic response_head_q;                         // FIFO 读指针 (头)
  logic response_tail_q;                         // FIFO 写指针 (尾)
  logic [1:0] response_count_q;                  // FIFO 中当前存储的条目数量 (0/1/2)

  // F2 流水线级暂存寄存器
  logic valid_f2_q;                              // F2 阶段数据有效标志
  fetch_packet_t packet_f2_q;                    // F2 阶段暂存的取指包数据

  // ==========================================================================
  // 中间连线与控制信号 (Wires)
  // ==========================================================================
  response_entry_t response_head_entry;          // Skid FIFO 头部待读取的响应条目
  response_entry_t incoming_entry;               // 组装后的当前输入 IMem 响应条目
  response_entry_t misaligned_entry;             // 组装后的不对齐异常条目
  fetch_packet_t packet_from_head;               // F1 -> F2 转换出的临时取指包

  logic f2_ready;                                // F2 阶段允许被写入 (当前无数据或当前数据在这一拍被下游接收)
  logic f2_fire;                                 // F2 阶段数据成功传输给下游 (握手成功)
  logic response_dequeue;                        // Skid FIFO 出队使能
  logic response_event;                          // IMem 响应到达事件
  logic response_good;                           // 响应有效且非 stale (需要存入 FIFO)
  logic response_enqueue;                        // 确认将当前响应写入 Skid FIFO
  logic response_space;                          // Skid FIFO 还有空闲空间
  logic prediction_taken;                        // 分支预测是否判定跳转
  logic [1:0] prediction_slot;                   // 预测跳转的分支指令槽号 (0~3)
  logic internal_redirect;                       // F1 -> F2 阶段检测到预测跳转，触发前端内部 PC 重定向
  logic req_slot_available;                      // 指令存储器请求通道空闲 (当前无请求，或当前周期响应正好返回)
  logic [2:0] reserved_count;                    // 当前前端已分配/占用的总资源槽位数
  logic issue_credit;                            // 前端信誉度机制检查 (是否有足够的缓冲槽位发起新请求)
  logic issue_normal;                            // 发起正常取指请求
  logic issue_misaligned;                        // 发起不对齐异常处理请求

  // ==========================================================================
  // 流水线输出与弹性握手逻辑
  // ==========================================================================
  assign fetch_valid_o  = valid_f2_q && !redirect_valid_i;
  assign fetch_packet_o = packet_f2_q;

  assign f2_ready         = !valid_f2_q || ibuf_ready_i;
  assign f2_fire          = valid_f2_q && ibuf_ready_i;
  // 只有当 Skid FIFO 不为空，且 F2 阶段允许被写入时，才能将 FIFO 头部的数据出队送往 F2
  assign response_dequeue = (response_count_q != 0) && f2_ready;

  // 获取 Skid FIFO 头部的数据
  assign response_head_entry = response_fifo_q[response_head_q];
  assign prediction_slot = response_head_entry.prediction.btb_slot;

  // ==========================================================================
  // 分支预测方向确认 (F1 出队时解析)
  // ==========================================================================
  always @* begin
    prediction_taken = 1'b0;
    case (prediction_slot)
      2'd0: prediction_taken = response_head_entry.prediction.btb_hit[0] &&
                                    response_head_entry.prediction.bht_taken[0];
      2'd1: prediction_taken = response_head_entry.prediction.btb_hit[1] &&
                                    response_head_entry.prediction.bht_taken[1];
      2'd2: prediction_taken = response_head_entry.prediction.btb_hit[2] &&
                                    response_head_entry.prediction.bht_taken[2];
      2'd3: prediction_taken = response_head_entry.prediction.btb_hit[3] &&
                                    response_head_entry.prediction.bht_taken[3];
      default: prediction_taken = 1'b0;
    endcase
    // 只有当预测结果有效、分支指令在取指块起始槽之后且未触发任何异常时，跳转才真正有效
    prediction_taken = prediction_taken &&
                       response_head_entry.prediction.valid &&
                       (prediction_slot >= response_head_entry.pc[3:2]) &&
                       !response_head_entry.exception_valid;
  end

  // ==========================================================================
  // 取指数据包解算与槽有效掩码计算 (F1 -> F2 Pack)
  // ==========================================================================
  always @* begin
    packet_from_head = '0;
    packet_from_head.block_pc = {response_head_entry.pc[31:4], 4'b0};
    packet_from_head.inst[0] = response_head_entry.data[31:0];
    packet_from_head.inst[1] = response_head_entry.data[63:32];
    packet_from_head.inst[2] = response_head_entry.data[95:64];
    packet_from_head.inst[3] = response_head_entry.data[127:96];
    packet_from_head.fetch_id = response_head_entry.fetch_id;
    packet_from_head.pred_taken = prediction_taken;
    packet_from_head.pred_slot = prediction_slot;
    packet_from_head.pred_target = prediction_taken ?
                                   response_head_entry.prediction.btb_target : 32'b0;
    packet_from_head.exception_valid = response_head_entry.exception_valid;
    packet_from_head.exception_cause = response_head_entry.exception_valid ?
                                       EXC_INST_ADDR_MISALIGNED : 4'b0;
    packet_from_head.exception_tval = response_head_entry.exception_valid ?
                                      response_head_entry.pc : 32'b0;

    if (response_head_entry.exception_valid) begin
      // 地址非对齐异常，仅使能对应的起始槽位，以下传异常
      case (response_head_entry.pc[3:2])
        2'd0: packet_from_head.slot_valid = 4'b0001;
        2'd1: packet_from_head.slot_valid = 4'b0010;
        2'd2: packet_from_head.slot_valid = 4'b0100;
        2'd3: packet_from_head.slot_valid = 4'b1000;
        default: packet_from_head.slot_valid = 4'b0000;
      endcase
    end else begin
      // 正常流程：忽略当前 PC 之前的偏置指令
      case (response_head_entry.pc[3:2])
        2'd0: packet_from_head.slot_valid = 4'b1111;
        2'd1: packet_from_head.slot_valid = 4'b1110;
        2'd2: packet_from_head.slot_valid = 4'b1100;
        2'd3: packet_from_head.slot_valid = 4'b1000;
        default: packet_from_head.slot_valid = 4'b0000;
      endcase
      // 若预测为 Taken，截断跳转目标槽位后面的所有指令
      if (prediction_taken) begin
        case (prediction_slot)
          2'd0: packet_from_head.slot_valid &= 4'b0001;
          2'd1: packet_from_head.slot_valid &= 4'b0011;
          2'd2: packet_from_head.slot_valid &= 4'b0111;
          2'd3: packet_from_head.slot_valid &= 4'b1111;
          default: packet_from_head.slot_valid = 4'b0000;
        endcase
      end
    end
  end

  // ==========================================================================
  // 前端流控制与 Credit / Skid Buffer 逻辑
  // ==========================================================================
  // 内部重定向：F1 -> F2 时发现预测跳转 (需打断顺序取指，更新 PC 并冲刷在途请求)
  assign internal_redirect = response_dequeue && prediction_taken;

  assign response_event = req_pending_q && imem_resp_valid_i;
  // 只有当响应有效，非过期（Stale），纪元相符，且未触发任何重定向时，该响应才是合法的
  assign response_good  = response_event && !req_stale_q &&
                          (req_epoch_q == epoch_q) &&
                          !redirect_valid_i && !internal_redirect;
  // Skid FIFO 拥有空闲位置，或在当前周期正好要出队一项
  assign response_space = (response_count_q < 2) || response_dequeue;
  assign response_enqueue = response_good && response_space;

  // 组装当前到来的合法 IMem 响应数据包
  always @* begin
    incoming_entry = '0;
    incoming_entry.pc       = req_pc_q;
    incoming_entry.data     = imem_resp_data_i;
    incoming_entry.fetch_id = req_fetch_id_q;
    incoming_entry.epoch    = req_epoch_q;
    incoming_entry.prediction = req_pred_captured_q ? req_pred_q : bp_result_i;
  end

  // 组装本地直接合成的不对齐异常数据包
  always @* begin
    misaligned_entry = '0;
    misaligned_entry.pc = pc_f0_q;
    misaligned_entry.fetch_id = next_fetch_id_q;
    misaligned_entry.epoch = epoch_q;
    misaligned_entry.exception_valid = 1'b1;
  end

  // 信誉控制（Credit Mechanism）：
  // 计算当前已分配或已被占用的前端缓冲槽（F2 的 1 项 + Skid FIFO 的 0~2 项 + 正在等待的在途内存请求 1 项）
  assign reserved_count = response_count_q + valid_f2_q + req_pending_q;
  // 若减去当前周期释放的槽位（`f2_fire`），总占用依然小于 3（最大容量），则说明有信誉发起新请求
  assign issue_credit = (reserved_count - f2_fire) < FRONT_CAPACITY;

  // 内存请求通道就绪：若没有在途请求，或者当前周期在途请求正返回值，说明可发起下一次请求
  assign req_slot_available = !req_pending_q || imem_resp_valid_i;

  // 发起请求逻辑 (对于 1 周期延迟的内存，可实现每周期 1 次取指的满吞吐)
  assign issue_normal = !rst_i && !redirect_valid_i && !internal_redirect &&
                        req_slot_available && issue_credit &&
                        (pc_f0_q[1:0] == 2'b00);
  // 本地直接发起不对齐异常处理 (不经由内存查询，直接写入 Skid FIFO)
  assign issue_misaligned = !rst_i && !redirect_valid_i && !internal_redirect &&
                            !req_pending_q && issue_credit &&
                            (pc_f0_q[1:0] != 2'b00);

  assign imem_req_valid_o = issue_normal;
  assign imem_req_addr_o = {pc_f0_q[31:4], 4'b0};
  assign bp_query_valid_o = issue_normal;
  assign bp_query_o.pc = {pc_f0_q[31:4], 4'b0};
  assign bp_query_o.fetch_id = next_fetch_id_q;

  // ==========================================================================
  // 流水线状态更新时序逻辑 (Sequential Control Engine)
  // ==========================================================================
  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      // 同步复位复位初始化所有状态
      pc_f0_q             <= RESET_PC;
      next_fetch_id_q     <= '0;
      epoch_q             <= 1'b0;
      req_pending_q       <= 1'b0;
      req_stale_q         <= 1'b0;
      req_pred_captured_q <= 1'b0;
      req_pc_q            <= '0;
      req_fetch_id_q      <= '0;
      req_epoch_q         <= 1'b0;
      req_pred_q          <= '0;
      response_head_q     <= 1'b0;
      response_tail_q     <= 1'b0;
      response_count_q    <= 2'd0;
      valid_f2_q          <= 1'b0;
      packet_f2_q         <= '0;
    end else if (redirect_valid_i) begin
      // 后端（执行端或提交端）发出硬重定向信号：
      // 立即更新 F0 阶段 PC，并反转纪元（Epoch），使所有在途的旧响应失效
      pc_f0_q          <= redirect_target_i;
      epoch_q          <= ~epoch_q;
      response_head_q  <= 1'b0;
      response_tail_q  <= 1'b0;
      response_count_q <= 2'd0;
      valid_f2_q       <= 1'b0;

      // 若有在途内存请求，将其标记为 Stale，使其返回时被丢弃；否则彻底清空状态
      if (req_pending_q && !imem_resp_valid_i) begin
        req_stale_q <= 1'b1;
      end else begin
        req_pending_q       <= 1'b0;
        req_stale_q         <= 1'b0;
        req_pred_captured_q <= 1'b0;
      end
    end else if (internal_redirect) begin
      // 前端内部跳转重定向：
      // 当从 FIFO 头部出队预测为 Taken 的跳转包时，该跳转包进入 F2（它需要在下游执行）；
      // 但所有顺序发起的、比它更年轻的响应或在途请求均已被证实走错了分支路径，必须立即予以冲刷和丢弃。
      valid_f2_q       <= 1'b1;
      packet_f2_q      <= packet_from_head;
      pc_f0_q          <= packet_from_head.pred_target; // 更新为分支预测目标 PC
      epoch_q          <= ~epoch_q;                     // 改变纪元过滤旧的取指
      response_head_q  <= 1'b0;
      response_tail_q  <= 1'b0;
      response_count_q <= 2'd0;

      // 冲刷正在路上的非法请求
      if (req_pending_q && !imem_resp_valid_i) begin
        req_stale_q <= 1'b1;
      end else begin
        req_pending_q       <= 1'b0;
        req_stale_q         <= 1'b0;
        req_pred_captured_q <= 1'b0;
      end
    end else begin
      // F2 阶段握手成功，清空有效位
      if (f2_fire)
        valid_f2_q <= 1'b0;

      // Skid FIFO 出队，将其移送至 F2 阶段
      if (response_dequeue) begin
        // 仅当该项所属的纪元与当前系统一致时，转移到 F2 后的数据才是有效的
        valid_f2_q      <= (response_head_entry.epoch == epoch_q);
        packet_f2_q     <= packet_from_head;
        response_head_q <= ~response_head_q;
      end

      // 接收合法的 IMem 响应并压入 FIFO
      if (response_enqueue) begin
        response_fifo_q[response_tail_q] <= incoming_entry;
        response_tail_q <= ~response_tail_q;
      end

      // 本地合成不对齐异常包并直接压入 FIFO
      if (issue_misaligned) begin
        response_fifo_q[response_tail_q] <= misaligned_entry;
        response_tail_q <= ~response_tail_q;
        pc_f0_q <= {pc_f0_q[31:4], 4'b0} + 32'd16; // 推进到下一个 16 字节对齐块
        next_fetch_id_q <= next_fetch_id_q + 1'b1;
      end

      // 计数器计算逻辑：由于支持一周期同时压入（Enqueue）与弹出（Dequeue），采用 case 分析
      case ({(response_enqueue || issue_misaligned), response_dequeue})
        2'b10: response_count_q <= response_count_q + 2'd1; // 仅压入
        2'b01: response_count_q <= response_count_q - 2'd1; // 仅弹出
        default: response_count_q <= response_count_q;       // 无操作，或同时压入弹出（计数保持不变）
      endcase

      // 提前锁存分支预测器的结果以规避时序违例
      if (req_pending_q && !req_pred_captured_q) begin
        req_pred_q          <= bp_result_i;
        req_pred_captured_q <= 1'b1;
      end

      // 任意 IMem 响应返回后，释放在途标志
      if (response_event) begin
        req_pending_q       <= 1'b0;
        req_stale_q         <= 1'b0;
        req_pred_captured_q <= 1'b0;
      end

      // 发起正常取指读请求并更新状态
      if (issue_normal) begin
        req_pending_q       <= 1'b1;
        req_stale_q         <= 1'b0;
        req_pred_captured_q <= 1'b0;
        req_pc_q            <= pc_f0_q;
        req_fetch_id_q      <= next_fetch_id_q;
        req_epoch_q         <= epoch_q;
        pc_f0_q             <= {pc_f0_q[31:4], 4'b0} + 32'd16; // 顺序更新下一 PC (16字节对齐自增)
        next_fetch_id_q     <= next_fetch_id_q + 1'b1;
      end
    end
  end

  // ==========================================================================
  // 系统断言 (SystemVerilog Assertions)
  // ==========================================================================
`ifdef FETCH_PIPELINE_ASSERTIONS
  // 断言 1：当下游反压暂停，且没有后端硬重定向时，F2 阶段输出的取指数据包必须保持稳定
  property p_f2_stable_when_stalled;
    @(posedge clk_i) disable iff (rst_i)
      fetch_valid_o && !ibuf_ready_i && !redirect_valid_i |=>
        fetch_valid_o && $stable(fetch_packet_o);
  endproperty
  assert property (p_f2_stable_when_stalled);

  // 断言 2：向外部 IMem 发出的所有读地址必须符合 16 字节对齐（低 4 位为 0）
  property p_imem_aligned;
    @(posedge clk_i) imem_req_valid_o |-> (imem_req_addr_o[3:0] == 4'b0);
  endproperty
  assert property (p_imem_aligned);

  // 断言 3：当合法的 IMem 响应到达时，Skid FIFO 必须有空间可以容纳它，不会发生溢出
  property p_response_has_space;
    @(posedge clk_i) disable iff (rst_i)
      response_good |-> response_space;
  endproperty
  assert property (p_response_has_space);

  // 断言 4：信誉控制安全保证，已分配的前端资源槽位数不能超过最大上限 (3)
  property p_credit_bound;
    @(posedge clk_i) disable iff (rst_i) reserved_count <= FRONT_CAPACITY;
  endproperty
  assert property (p_credit_bound);
`endif

endmodule
