`timescale 1ns/1ps

import core_types_pkg::*;

// fetch_pipeline.sv
// 取指流水线模块 (Instruction Fetch Pipeline)
// 职责：
// 1. 在 F0 阶段产生和管理 PC，并向外部指令存储器 (IMem) 发起读请求，同时查询分支预测器 (BP)；
// 2. 在 F1 阶段接收 IMem 响应数据并解析分支预测器的结果，做跳转重定向及不对齐检测；
// 3. 在 F2 阶段组装取指包 (fetch_packet_t) 并输出给下游指令缓存 (Instruction Buffer)；
// 4. 支持投机执行的纪元 (Epoch) 管理与分支恢复。

module fetch_pipeline (
    input  logic                         clk_i,             // 时钟信号
    input  logic                         rst_i,             // 复位信号 (高电平有效)

    // 流水线重定向接口 (来自执行单元/ROB 提交端，用于纠正预测错误或处理异常)
    input  logic                         redirect_valid_i,  // 重定向请求有效
    input  logic [31:0]                  redirect_target_i, // 重定向的目标 PC

    // 外部指令缓冲接口
    input  logic                         ibuf_ready_i,      // 下游指令缓冲已准备好接收 (Backpressure 反压控制)
    output logic                         fetch_valid_o,     // 输出取指数据有效 (F2 阶段数据就绪)
    output fetch_packet_t                 fetch_packet_o,    // 输出取指包

    // 分支预测器查询接口 (F0 阶段发起)
    output logic                         bp_query_valid_o,  // 查询请求有效
    output bp_query_t                    bp_query_o,        // 查询参数
    input  bp_pred_t                     bp_result_i,       // 预测器返回的结果 (F1 采样)

    // 指令存储器 (IMem) 接口
    output logic                         imem_req_valid_o,  // IMem 读请求有效
    output logic [31:0]                  imem_req_addr_o,   // IMem 读请求地址 (16字节对齐)
    input  logic                         imem_resp_valid_i, // IMem 响应数据有效
    input  logic [127:0]                 imem_resp_data_i   // IMem 返回的 128 位 (16字节) 指令块
);

  // 指令地址非对齐异常码定义 (按照 RISC-V 规范，不对齐异常码为 0)
  localparam logic [3:0] EXC_INST_ADDR_MISALIGNED = 4'd0;

  // ==========================================================================
  // 寄存状态与流水线寄存器 (Registers)
  // ==========================================================================
  logic [31:0] pc_f0_q;                          // F0 阶段寄存的程序计数器 (PC)
  logic [FETCH_ID_W_FULL-1:0] fetch_id_q;        // 取指事务 ID 计数器，用于流水线标识
  logic epoch_q;                                 // 当前系统取指纪元 (用于重定向后过滤在途的过期响应)

  // 存储器请求状态机控制寄存器
  // 由于每次最多仅能有一个未决 (in-flight) 的内存读请求，以此保证即使出现跳转重定向，时序也是安全的
  logic req_pending_q;                           // 标志当前有一个正在等待内存响应的读请求
  logic req_stale_q;                             // 标志在等待期间收到了重定向，当前的响应已过期需丢弃
  logic req_pred_captured_q;                     // 标志分支预测器的结果已提早在等待内存响应时被锁存
  logic [31:0] req_pc_q;                         // 锁存的请求 PC 地址
  logic [FETCH_ID_W_FULL-1:0] req_fetch_id_q;   // 锁存的取指 ID
  logic req_epoch_q;                             // 发起请求时的纪元
  bp_pred_t req_pred_q;                          // 锁存的预测器结果

  // F1 流水线暂存寄存器
  logic valid_f1_q;                              // F1 阶段数据有效标志
  logic [31:0] pc_f1_q;                          // F1 阶段指令 PC
  logic [127:0] imem_data_f1_q;                  // F1 阶段读出的原始指令块数据
  logic [FETCH_ID_W_FULL-1:0] fetch_id_f1_q;     // F1 阶段取指事务 ID
  logic epoch_f1_q;                              // F1 阶段纪元
  bp_pred_t pred_f1_q;                           // F1 阶段预测结果
  logic exception_f1_q;                          // F1 阶段是否存在地址对齐异常

  // F2 流水线暂存寄存器 (用于弹性缓冲握手)
  logic valid_f2_q;                              // F2 阶段数据有效标志
  fetch_packet_t packet_f2_q;                    // F2 阶段暂存的取指包数据

  // ==========================================================================
  // 流水线控制与握手逻辑
  // ==========================================================================
  logic f2_ready;                                // F2 阶段允许被写入 (当前无数据或下游已读取)
  logic f1_to_f2;                                // F1 成功传递到 F2 的握手信号
  logic issue_normal;                            // 允许发起正常指令取指 (PC 对齐且流水线空闲)
  logic issue_misaligned;                        // 触发不对齐处理 (PC 非4字节对齐)
  logic response_accept;                         // 允许接收当前到来的 IMem 响应数据
  logic response_drop;                           // 丢弃当前到来的 IMem 响应数据

  fetch_packet_t packet_from_f1;                 // 临时变量：在 F1 阶段组装好的取指包
  logic [1:0] start_slot;                        // 取指块的起始槽偏置号 (PC[3:2])
  logic prediction_taken;                        // 本次取指是否被确定发生了跳转预测
  logic [1:0] prediction_slot;                   // 块中发生跳转的最早分支指令槽号 (来自预测器)

  // 弹性握手计算
  assign f2_ready         = !valid_f2_q || ibuf_ready_i;
  assign f1_to_f2         = valid_f1_q && f2_ready;

  // 发起指令内存请求的使能条件：
  // 非复位、非正在重定向、在途请求清空、流水线级均空闲、且 PC 处于正常4字节边界对齐
  // 此设计限制了同时仅有一个 outstanding memory request，极大地简化了重定向时的排水 (drain) 逻辑
  assign issue_normal     = !rst_i && !redirect_valid_i && !req_pending_q &&
                            !valid_f1_q && !valid_f2_q &&
                            (pc_f0_q[1:0] == 2'b00);

  // 若 PC 不是 4 字节对齐的 (即 1:0 位不等于 00)，说明发生了跳转地址不对齐，需要产生不对齐异常
  assign issue_misaligned = !rst_i && !redirect_valid_i && !req_pending_q &&
                            !valid_f1_q && !valid_f2_q &&
                            (pc_f0_q[1:0] != 2'b00);

  // 指令存储器请求端口输出赋值
  assign imem_req_valid_o = issue_normal;
  assign imem_req_addr_o  = {pc_f0_q[31:4], 4'b0000}; // 强制 16 字节对齐读取
  assign bp_query_valid_o = issue_normal;
  assign bp_query_o.pc       = {pc_f0_q[31:4], 4'b0000};
  assign bp_query_o.fetch_id = fetch_id_q;

  // IMem 响应接受判定：必须是处于等待状态，非 stale，纪元相符，且当前没有发生重定向
  assign response_accept = req_pending_q && imem_resp_valid_i &&
                            !req_stale_q && (req_epoch_q == epoch_q) &&
                            !redirect_valid_i;

  // 丢弃响应判定：如果响应过期、纪元不合、或者当前系统正在进行重定向，需直接丢弃该响应
  assign response_drop   = req_pending_q && imem_resp_valid_i &&
                            (req_stale_q || (req_epoch_q != epoch_q) ||
                             redirect_valid_i);

  // ==========================================================================
  // 分支预测方向确认与取指块过滤
  // ==========================================================================
  assign start_slot      = pc_f1_q[3:2];         // 获取取指块的起始槽号 (0~3)
  assign prediction_slot = pred_f1_q.btb_slot;   // 获取跳转预测槽号 (0~3)

  // 确认预测方向是否为 Taken
  always @* begin
    prediction_taken = 1'b0;
    // 当命中 BTB 且 BHT 预测为 Taken 时判定发生跳转
    case (prediction_slot)
      2'd0: prediction_taken = pred_f1_q.btb_hit[0] && pred_f1_q.bht_taken[0];
      2'd1: prediction_taken = pred_f1_q.btb_hit[1] && pred_f1_q.bht_taken[1];
      2'd2: prediction_taken = pred_f1_q.btb_hit[2] && pred_f1_q.bht_taken[2];
      2'd3: prediction_taken = pred_f1_q.btb_hit[3] && pred_f1_q.bht_taken[3];
      default: prediction_taken = 1'b0;
    endcase
    // 只有在预测结果有效、跳转指令处于取指块的起始槽之后 (未越界) 且当前没有触发异常时，才生效
    prediction_taken = prediction_taken && pred_f1_q.valid &&
                       (prediction_slot >= start_slot) && !exception_f1_q;
  end

  // ==========================================================================
  // 取指包组装与有效槽掩码计算 (F1 -> F2 Pack)
  // ==========================================================================
  always @* begin
    packet_from_f1 = '0;
    packet_from_f1.block_pc        = {pc_f1_q[31:4], 4'b0000};
    packet_from_f1.fetch_id        = fetch_id_f1_q;
    packet_from_f1.pred_taken      = prediction_taken;
    packet_from_f1.pred_slot       = prediction_slot;
    packet_from_f1.pred_target     = prediction_taken ? pred_f1_q.btb_target : 32'b0;
    packet_from_f1.exception_valid = exception_f1_q;
    packet_from_f1.exception_cause = exception_f1_q ? EXC_INST_ADDR_MISALIGNED : 4'b0;
    packet_from_f1.exception_tval  = exception_f1_q ? pc_f1_q : 32'b0;

    // 将 128 位宽的数据拆分成 4 条 32 位宽指令并填入对应的 slot
    packet_from_f1.inst[0] = imem_data_f1_q[31:0];
    packet_from_f1.inst[1] = imem_data_f1_q[63:32];
    packet_from_f1.inst[2] = imem_data_f1_q[95:64];
    packet_from_f1.inst[3] = imem_data_f1_q[127:96];

    if (exception_f1_q) begin
      // 如果是非对齐异常，仅对应的起始异常槽位有效，用来将该异常向下游译码流水线传递
      case (start_slot)
        2'd0: packet_from_f1.slot_valid = 4'b0001;
        2'd1: packet_from_f1.slot_valid = 4'b0010;
        2'd2: packet_from_f1.slot_valid = 4'b0100;
        2'd3: packet_from_f1.slot_valid = 4'b1000;
        default: packet_from_f1.slot_valid = 4'b0000;
      endcase
    end else begin
      // 1. 根据起始偏置，忽略起始槽之前的指令 (由于 16 字节对齐读取)
      case (start_slot)
        2'd0: packet_from_f1.slot_valid = 4'b1111;
        2'd1: packet_from_f1.slot_valid = 4'b1110;
        2'd2: packet_from_f1.slot_valid = 4'b1100;
        2'd3: packet_from_f1.slot_valid = 4'b1000;
        default: packet_from_f1.slot_valid = 4'b0000;
      endcase
      // 2. 如果发生了分支跳转，则截断跳转点后面的所有指令 (将跳转点之后的 slot 无效化)
      if (prediction_taken) begin
        case (prediction_slot)
          2'd0: packet_from_f1.slot_valid &= 4'b0001;
          2'd1: packet_from_f1.slot_valid &= 4'b0011;
          2'd2: packet_from_f1.slot_valid &= 4'b0111;
          2'd3: packet_from_f1.slot_valid &= 4'b1111;
          default: packet_from_f1.slot_valid = 4'b0000;
        endcase
      end
    end
  end

  // 输出端连接
  assign fetch_valid_o  = valid_f2_q;
  assign fetch_packet_o = packet_f2_q;

  // ==========================================================================
  // 流水线状态更新时序逻辑 (Sequential Logic)
  // ==========================================================================
  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      // 寄存器同步复位初始化
      pc_f0_q             <= RESET_PC;
      fetch_id_q          <= '0;
      epoch_q             <= 1'b0;
      req_pending_q       <= 1'b0;
      req_stale_q         <= 1'b0;
      req_pred_captured_q <= 1'b0;
      req_pc_q            <= '0;
      req_fetch_id_q      <= '0;
      req_epoch_q         <= 1'b0;
      req_pred_q          <= '0;
      valid_f1_q          <= 1'b0;
      pc_f1_q             <= '0;
      imem_data_f1_q      <= '0;
      fetch_id_f1_q       <= '0;
      epoch_f1_q          <= 1'b0;
      pred_f1_q           <= '0;
      exception_f1_q      <= 1'b0;
      valid_f2_q          <= 1'b0;
      packet_f2_q         <= '0;
    end else if (redirect_valid_i) begin
      // 收到跳转重定向信号，冲刷整条流水线 (Flush)
      pc_f0_q        <= redirect_target_i; // 重定向下一时钟周期的 PC
      epoch_q        <= ~epoch_q;          // 反转纪元标记，使所有后续到达的过期 IMem 响应被标记为 stale
      valid_f1_q     <= 1'b0;
      valid_f2_q     <= 1'b0;

      // 如果当前有一个存储器请求已发出但尚未返回：
      // 将其标记为 stale，使其返回时被丢弃；若此时无未决请求，则清除标记
      if (req_pending_q && !imem_resp_valid_i) begin
        req_stale_q <= 1'b1;
      end else begin
        req_pending_q       <= 1'b0;
        req_stale_q         <= 1'b0;
        req_pred_captured_q <= 1'b0;
      end
    end else begin
      // 下游指令缓冲接收了当前 F2 包，允许更新 PC
      if (valid_f2_q && ibuf_ready_i) begin
        valid_f2_q <= 1'b0;
        fetch_id_q <= fetch_id_q + 1'b1;
        // 如果 F2 包内触发了跳转预测，则下一时钟周期 PC 转为跳转目标；否则顺序累加 16 字节
        if (packet_f2_q.pred_taken)
          pc_f0_q <= packet_f2_q.pred_target;
        else
          pc_f0_q <= packet_f2_q.block_pc + 32'd16;
      end

      // 流水线级间传递：F1 到 F2
      if (f1_to_f2) begin
        // 只有 F1 的纪元与当前系统纪元一致时，传给 F2 的数据才有效
        valid_f2_q  <= (epoch_f1_q == epoch_q);
        packet_f2_q <= packet_from_f1;
        valid_f1_q  <= 1'b0;
      end

      // 发起正常的 IMem 读请求
      if (issue_normal) begin
        req_pending_q       <= 1'b1;
        req_stale_q         <= 1'b0;
        req_pred_captured_q <= 1'b0;
        req_pc_q            <= pc_f0_q;
        req_fetch_id_q      <= fetch_id_q;
        req_epoch_q         <= epoch_q;
      end

      // PC 不对齐：不访问 IMem，直接在 F1 生成一条特殊的虚拟异常指令，进入流水线弹性队列传给译码
      if (issue_misaligned) begin
        valid_f1_q       <= 1'b1;
        pc_f1_q          <= pc_f0_q;
        imem_data_f1_q   <= '0;
        fetch_id_f1_q    <= fetch_id_q;
        epoch_f1_q       <= epoch_q;
        pred_f1_q        <= '0;
        exception_f1_q   <= 1'b1; // 触发不对齐异常标记
      end

      // 在等待内存返回时提前采样分支预测器的输出结果，避免时序恶化
      if (req_pending_q && !req_pred_captured_q) begin
        req_pred_q          <= bp_result_i;
        req_pred_captured_q <= 1'b1;
      end

      // 接收被接纳的正常 IMem 响应，填充 F1
      if (response_accept) begin
        valid_f1_q       <= 1'b1;
        pc_f1_q          <= req_pc_q;
        imem_data_f1_q   <= imem_resp_data_i;
        fetch_id_f1_q    <= req_fetch_id_q;
        epoch_f1_q       <= req_epoch_q;
        // 如果在等待期间已锁存预测结果，则使用锁存的；否则实时使用输入端口的数据
        pred_f1_q        <= req_pred_captured_q ? req_pred_q : bp_result_i;
        exception_f1_q   <= 1'b0;
        req_pending_q       <= 1'b0;
        req_stale_q         <= 1'b0;
        req_pred_captured_q <= 1'b0;
      end else if (response_drop) begin
        // 丢弃响应时释放等待寄存器
        req_pending_q       <= 1'b0;
        req_stale_q         <= 1'b0;
        req_pred_captured_q <= 1'b0;
      end
    end
  end

  // ==========================================================================
  // 系统断言 (SystemVerilog Assertions)
  // ==========================================================================
`ifdef FETCH_PIPELINE_ASSERTIONS
  // 断言：当发生下游反压暂停时，F2 寄存器中的数据包内容和有效信号必须保持稳定
  property p_f2_stable_when_stalled;
    @(posedge clk_i) disable iff (rst_i)
      fetch_valid_o && !ibuf_ready_i |=>
        fetch_valid_o && $stable(fetch_packet_o);
  endproperty
  assert property (p_f2_stable_when_stalled);

  // 断言：向外部 IMem 发出的所有读地址必须符合 16 字节对齐边界 (低 4 位为 0)
  property p_imem_aligned;
    @(posedge clk_i) imem_req_valid_o |-> (imem_req_addr_o[3:0] == 4'b0);
  endproperty
  assert property (p_imem_aligned);
`endif

endmodule
