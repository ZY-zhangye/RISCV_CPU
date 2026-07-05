`timescale 1ns/1ps

import core_types_pkg::*;

// operand_read_stage.sv
// 操作数读取阶段 (Operand Read Stage)
// 职责：
// 1. 发射与 PRF 读时序对齐：
//    - 将全局仲裁器输出并寄存的 3 条发射通道微操作与物理寄存器堆（PRF）的一周期同步读延迟进行对齐；
// 2. 写回旁路前传 (WB Bypass)：
//    - 检查 PRF 读返回的数据，如果读取的物理寄存器正巧在当前时钟周期执行最终写回（wb_valid_i），
//      则将写回总线数据（wb_data_i）直接旁路前传（Bypass）给该操作数，消除写回-读取时序泡；
// 3. 执行端弹性分流与反压吸收 (Holding Registers & Backpressure)：
//    - 将 3 条通用发射通道映射分发给 4 个独立的执行端（INT0, INT1, LSU, MDU）；
//    - 为每个执行端维护两级弹性暂存寄存器（`meta_uop_q` 与 `response_uop_q`）。当某个执行管道阻塞（如 LSU 被 Cache stall）时，
//      将读回的操作数数据在本地锁存（`meta_srcX_q`），防止因共享读端口输出在下周期改变而导致数据丢失；
//    - 产生就绪信号（`intX_issue_ready_o` 等）反馈给全局仲裁器，限制后续指令向已阻塞的通道发射。
// 4. 投机分支恢复：
//    - 在遭遇分支误预测恢复时，通过 `branch_mask` 清理在途等待读取操作数的无效指令。

module operand_read_stage (
    input  logic                         clk_i,             // 时钟信号
    input  logic                         rst_i,             // 复位信号 (高电平有效)

    // 全局发射仲裁级 (Issue Arbiter) 输入接口 (已打拍寄存)
    input  logic [2:0]                   issue_valid_i,     // 三个发射通道的有效位
    input  issue_port_t                  issue_port0_i,     // 通道 0 目的执行端口 (INT0/INT1/LSU/MDU)
    input  issue_port_t                  issue_port1_i,     // 通道 1 目的执行端口
    input  issue_port_t                  issue_port2_i,     // 通道 2 目的执行端口
    input  wire issue_uop_t              issue_uop0_i,      // 通道 0 uop payload
    input  wire issue_uop_t              issue_uop1_i,      // 通道 1 uop payload
    input  wire issue_uop_t              issue_uop2_i,      // 通道 2 uop payload

    // 物理寄存器堆 (PRF) 访问接口
    output logic [5:0]                   prf_read_valid_o,  // 发送给 PRF 的 6 路读有效位
    output logic [5:0][PRD_W-1:0]        prf_read_prd_o,    // 发送给 PRF 的 6 路读物理寄存器号
    input  wire logic [5:0][XLEN-1:0]    prf_read_data_i,   // PRF 一周期同步读返回的 6 路数据

    // 写回总线旁路接口 (Writeback Bypass)
    input  logic [1:0]                   wb_valid_i,        // 写回有效位
    input  wire logic [1:0][PRD_W-1:0]   wb_prd_i,          // 写回目的物理寄存器号
    input  wire logic [1:0][XLEN-1:0]    wb_data_i,         // 写回数据

    // 反馈给全局仲裁器的就绪信号 (控制下周期是否允许向该端口发射新指令)
    output logic                         int0_issue_ready_o,
    output logic                         int1_issue_ready_o,
    output logic                         lsu_issue_ready_o,
    output logic                         mdu_issue_ready_o,

    // 输出给 4 个执行端（Execution Units）的执行包接口
    output logic                         int0_valid_o,      // INT0 有效位
    input  logic                         int0_ready_i,      // INT0 就绪接收信号 (反压)
    output execute_uop_t                 int0_uop_o,        // INT0 执行包 payload

    output logic                         int1_valid_o,      // INT1 有效位
    input  logic                         int1_ready_i,      // INT1 就绪接收信号 (反压)
    output execute_uop_t                 int1_uop_o,        // INT1 执行包 payload

    output logic                         lsu_valid_o,       // LSU 有效位
    input  logic                         lsu_ready_i,       // LSU 就绪接收信号 (反压)
    output execute_uop_t                 lsu_uop_o,         // LSU 执行包 payload

    output logic                         mdu_valid_o,       // MDU 有效位
    input  logic                         mdu_ready_i,       // MDU 就绪接收信号 (反压)
    output execute_uop_t                 mdu_uop_o,         // MDU 执行包 payload

    // 恢复控制包 (分支误预测或异常)
    input  wire recovery_t               recovery_i
);

  localparam int PORTS = 4;                                 // 执行端个数 (0:INT0, 1:INT1, 2:LSU, 3:MDU)

  // 三个发射通道的重整理组合连线
  logic [2:0] slot_valid;
  issue_port_t slot_port [0:2];
  issue_uop_t slot_uop [0:2];

  // 整理路由后的输入（按四个执行端排列）
  logic [PORTS-1:0] incoming_valid;
  issue_uop_t incoming_uop [0:PORTS-1];
  logic [1:0] incoming_slot [0:PORTS-1];
  logic [PORTS-1:0] meta_ready;
  logic [PORTS-1:0] response_ready;

  // ----------------------------------------------------------------------
  // 第一级弹性缓冲区：元数据暂存器（Metadata Registers）
  // ----------------------------------------------------------------------
  // 锁存在途指令的控制信号、源发射通道 Slot 编号（用于对齐下周期 PRF 读返回）、以及阻塞时锁存的操作数数据
  logic [PORTS-1:0] meta_valid_q;                       // 元数据有效标志
  logic [PORTS-1:0] meta_data_valid_q;                  // 操作数数据已锁存标志 (表示阻塞期间使用了已捕获的数据)
  issue_uop_t meta_uop_q [0:PORTS-1];                   // 微操作 payload
  logic [1:0] meta_slot_q [0:PORTS-1];                  // 该指令原本处于哪个发射通道 (0/1/2)
  logic [XLEN-1:0] meta_src1_q [0:PORTS-1];             // 本地锁存的操作数 1 缓存
  logic [XLEN-1:0] meta_src2_q [0:PORTS-1];             // 本地锁存的操作数 2 缓存
  logic [XLEN-1:0] resolved_src1 [0:PORTS-1];           // 本周期解析出来的最终操作数 1
  logic [XLEN-1:0] resolved_src2 [0:PORTS-1];           // 本周期解析出来的最终操作数 2
  execute_uop_t meta_execute [0:PORTS-1];               // 准备发往下一级的执行 uop 结构

  // ----------------------------------------------------------------------
  // 第二级弹性缓冲区：执行端直出暂存器（Response/Output Registers）
  // ----------------------------------------------------------------------
  // 直出驱动执行单元的 uop，通过 response_ready 实现反压控制
  logic [PORTS-1:0] response_valid_q;
  execute_uop_t response_uop_q [0:PORTS-1];

  // 输入信号对齐
  assign slot_valid = issue_valid_i;
  assign slot_port[0] = issue_port0_i;
  assign slot_port[1] = issue_port1_i;
  assign slot_port[2] = issue_port2_i;
  assign slot_uop[0] = issue_uop0_i;
  assign slot_uop[1] = issue_uop1_i;
  assign slot_uop[2] = issue_uop2_i;

  // 各执行端直出暂存器的 ready 解算 (若直出寄存器为空，或者执行端就绪接收，则 ready)
  assign response_ready[ISSUE_INT0] = !response_valid_q[ISSUE_INT0] || int0_ready_i;
  assign response_ready[ISSUE_INT1] = !response_valid_q[ISSUE_INT1] || int1_ready_i;
  assign response_ready[ISSUE_LSU]  = !response_valid_q[ISSUE_LSU]  || lsu_ready_i;
  assign response_ready[ISSUE_MDU]  = !response_valid_q[ISSUE_MDU]  || mdu_ready_i;

  // 元数据暂存器的 ready 解算 (若元数据寄存器为空，或者直出寄存器能够接收，则 ready)
  assign meta_ready = ~meta_valid_q | response_ready;

  // 执行端直连输出
  assign int0_valid_o = response_valid_q[ISSUE_INT0];
  assign int1_valid_o = response_valid_q[ISSUE_INT1];
  assign lsu_valid_o  = response_valid_q[ISSUE_LSU];
  assign mdu_valid_o  = response_valid_q[ISSUE_MDU];
  assign int0_uop_o = response_uop_q[ISSUE_INT0];
  assign int1_uop_o = response_uop_q[ISSUE_INT1];
  assign lsu_uop_o  = response_uop_q[ISSUE_LSU];
  assign mdu_uop_o  = response_uop_q[ISSUE_MDU];

  // ==========================================================================
  // 写回旁路前传辅助函数 (Writeback Bypass Helper)
  // ==========================================================================
  // 检查读取的 prs 是否正在被 WB 写回，如果是，直接从写回总线上捕获最新数据。
  function automatic logic [XLEN-1:0] bypass_source(
      input logic                  need_source,
      input logic [PRD_W-1:0]      prs,
      input logic [XLEN-1:0]       raw_data
  );
    begin
      if (!need_source || (prs == '0))
        bypass_source = '0;
      else if (wb_valid_i[0] && (wb_prd_i[0] == prs))
        bypass_source = wb_data_i[0];
      else if (wb_valid_i[1] && (wb_prd_i[1] == prs))
        bypass_source = wb_data_i[1];
      else
        bypass_source = raw_data;
    end
  endfunction

  // 拼装 execute_uop_t 结构包
  function automatic execute_uop_t make_execute(
      input issue_uop_t             issue,
      input logic [XLEN-1:0]        src1,
      input logic [XLEN-1:0]        src2
  );
    execute_uop_t execute;
    begin
      execute = '0;
      execute.valid = 1'b1;
      execute.rob_id = issue.rob_id;
      execute.prd = issue.prd;
      execute.src1 = src1;
      execute.src2 = src2;
      execute.imm = issue.imm;
      execute.pc = issue.pc;
      execute.pred_taken = issue.pred_taken;
      execute.pred_target = issue.pred_target;
      execute.checkpoint_id = issue.checkpoint_id;
      execute.fu_type = issue.fu_type;
      execute.alu_op = issue.alu_op;
      execute.branch_op = issue.branch_op;
      execute.mem_op = issue.mem_op;
      execute.mul_op = issue.mul_op;
      execute.div_op = issue.div_op;
      execute.csr_op = issue.csr_op;
      execute.csr_addr = issue.csr_addr;
      execute.csr_zimm = issue.csr_zimm;
      execute.branch_mask = issue.branch_mask;
      execute.write_rd = issue.write_rd;
      execute.is_load = issue.is_load;
      execute.is_store = issue.is_store;
      execute.lq_id = issue.lq_id;
      execute.sq_id = issue.sq_id;
      execute.store_data = src2;                  // Store 指令的写数据由源操作数 2 填充
      execute.serializing = issue.serializing;
      make_execute = execute;
    end
  endfunction

  // 幸存指令清除已解析分支掩码位
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
  // 通道分发路由组合块 (Incoming Routing Combinational Block)
  // ==========================================================================
  // 将仲裁器发来的 3 条通用通道微操作路由重新排布，映射到 4 个特定的执行端口上。
  always_comb begin : incoming_router
    integer slot;
    integer port_index;
    incoming_valid = '0;
    for (port_index = 0; port_index < PORTS; port_index = port_index + 1) begin
      incoming_uop[port_index] = '0;
      incoming_slot[port_index] = '0;
    end

    for (slot = 0; slot < 3; slot = slot + 1) begin
      if (slot_valid[slot]) begin
        case (slot_port[slot])
          ISSUE_INT0: port_index = ISSUE_INT0;
          ISSUE_INT1: port_index = ISSUE_INT1;
          ISSUE_LSU:  port_index = ISSUE_LSU;
          default:    port_index = ISSUE_MDU;
        endcase
        incoming_valid[port_index] = 1'b1;
        incoming_uop[port_index] = slot_uop[slot];
        incoming_slot[port_index] = slot[1:0];           // 记录该 uop 来自哪一个发射 Slot
      end
    end
  end

  // ==========================================================================
  // 反馈给仲裁器的 Ready 状态指示
  // ==========================================================================
  // 必须满足当前没有全局恢复、本周期没有指令正在流入该端口、且该端口的暂存器能够接收。
  assign int0_issue_ready_o = !recovery_i.valid && !incoming_valid[ISSUE_INT0] && meta_ready[ISSUE_INT0];
  assign int1_issue_ready_o = !recovery_i.valid && !incoming_valid[ISSUE_INT1] && meta_ready[ISSUE_INT1];
  assign lsu_issue_ready_o  = !recovery_i.valid && !incoming_valid[ISSUE_LSU]  && meta_ready[ISSUE_LSU];
  assign mdu_issue_ready_o  = !recovery_i.valid && !incoming_valid[ISSUE_MDU]  && meta_ready[ISSUE_MDU];

  // ==========================================================================
  // 发送给 PRF 的同步读请求逻辑 (PRF synchronous reads generation)
  // ==========================================================================
  // 发射 Slot N (0/1/2) 规定绑定使用 PRF 的通道 2N 和 2N+1。
  // 发送读使能条件：Slot 有效、目标端口就绪接收、未遭遇全局恢复、且该指令明确需要此物理寄存器。
  always_comb begin : prf_request
    integer slot;
    logic target_ready;
    prf_read_valid_o = '0;
    prf_read_prd_o = '0;
    for (slot = 0; slot < 3; slot = slot + 1) begin
      case (slot_port[slot])
        ISSUE_INT0: target_ready = meta_ready[ISSUE_INT0];
        ISSUE_INT1: target_ready = meta_ready[ISSUE_INT1];
        ISSUE_LSU:  target_ready = meta_ready[ISSUE_LSU];
        default:    target_ready = meta_ready[ISSUE_MDU];
      endcase

      prf_read_valid_o[slot * 2] = slot_valid[slot] && target_ready &&
          !recovery_i.valid && slot_uop[slot].need_rs1;
      prf_read_valid_o[slot * 2 + 1] = slot_valid[slot] && target_ready &&
          !recovery_i.valid && slot_uop[slot].need_rs2;

      prf_read_prd_o[slot * 2] = slot_uop[slot].prs1;
      prf_read_prd_o[slot * 2 + 1] = slot_uop[slot].prs2;
    end
  end

  // ==========================================================================
  // 同步读返回操作数与旁路解算组合块 (Bypass & Response Builder)
  // ==========================================================================
  // 根据 meta 锁存的 Slot N 号，从对应的 prf_read_data_i[2N/2N+1] 中提取读出的物理寄存器值。
  // 若执行端发生阻塞，则直接使用本地捕获好的 `meta_srcX_q` 寄存器。
  always_comb begin : response_builder
    integer port_index;
    logic [XLEN-1:0] raw_src1;
    logic [XLEN-1:0] raw_src2;
    for (port_index = 0; port_index < PORTS; port_index = port_index + 1) begin
      case (meta_slot_q[port_index])
        2'd1: begin
          raw_src1 = prf_read_data_i[2];
          raw_src2 = prf_read_data_i[3];
        end
        2'd2: begin
          raw_src1 = prf_read_data_i[4];
          raw_src2 = prf_read_data_i[5];
        end
        default: begin
          raw_src1 = prf_read_data_i[0];
          raw_src2 = prf_read_data_i[1];
        end
      endcase

      if (meta_data_valid_q[port_index]) begin
        // LSU/MDU 反压阻塞期间，直接使用上周期已锁定捕获的数据，不再理会变动的 PRF 读返回
        resolved_src1[port_index] = meta_src1_q[port_index];
        resolved_src2[port_index] = meta_src2_q[port_index];
      end else begin
        // 正常情况下，提取 PRF 读返回，并经过写回旁路网络（Bypass）解算
        resolved_src1[port_index] = bypass_source(
            meta_uop_q[port_index].need_rs1,
            meta_uop_q[port_index].prs1,
            raw_src1);
        resolved_src2[port_index] = bypass_source(
            meta_uop_q[port_index].need_rs2,
            meta_uop_q[port_index].prs2,
            raw_src2);
      end
      meta_execute[port_index] = make_execute(meta_uop_q[port_index],
                                              resolved_src1[port_index],
                                              resolved_src2[port_index]);
    end
  end

  // ==========================================================================
  // 流水暂存状态时序逻辑 (Sequential holding & pipeline logic)
  // ==========================================================================
  always_ff @(posedge clk_i) begin : pipeline_state
    integer port_index;
    if (rst_i) begin
      meta_valid_q <= '0;
      meta_data_valid_q <= '0;
      response_valid_q <= '0;
      for (port_index = 0; port_index < PORTS; port_index = port_index + 1) begin
        meta_uop_q[port_index] <= '0;
        meta_slot_q[port_index] <= '0;
        meta_src1_q[port_index] <= '0;
        meta_src2_q[port_index] <= '0;
        response_uop_q[port_index] <= '0;
      end
    end else if (recovery_i.valid) begin
      // 遭遇全局恢复：根据 checkpoint_id 清理在途及输出暂存寄存器中的失效项，更新幸存项的分支掩码
      for (port_index = 0; port_index < PORTS; port_index = port_index + 1) begin
        if ((recovery_i.cause == REC_EXCEPT) ||
            (meta_valid_q[port_index] &&
             meta_uop_q[port_index].branch_mask[recovery_i.checkpoint_id])) begin
          meta_valid_q[port_index] <= 1'b0;
          meta_data_valid_q[port_index] <= 1'b0;
          meta_uop_q[port_index] <= '0;
        end else if (meta_valid_q[port_index]) begin
          meta_uop_q[port_index].branch_mask <= clear_checkpoint(
              meta_uop_q[port_index].branch_mask,
              recovery_i.checkpoint_id);
        end

        if ((recovery_i.cause == REC_EXCEPT) ||
            (response_valid_q[port_index] &&
             response_uop_q[port_index].branch_mask[recovery_i.checkpoint_id])) begin
          response_valid_q[port_index] <= 1'b0;
          response_uop_q[port_index] <= '0;
        end else if (response_valid_q[port_index]) begin
          response_uop_q[port_index].branch_mask <= clear_checkpoint(
              response_uop_q[port_index].branch_mask,
              recovery_i.checkpoint_id);
        end
      end
    end else begin
      for (port_index = 0; port_index < PORTS; port_index = port_index + 1) begin
        // --- 1. 第二级直出寄存器推移与保持控制 ---
        if (meta_valid_q[port_index] && response_ready[port_index]) begin
          // 顺利流转：将已解析好的 uop 锁入输出
          response_valid_q[port_index] <= 1'b1;
          response_uop_q[port_index] <= meta_execute[port_index];
        end else if (response_ready[port_index]) begin
          response_valid_q[port_index] <= 1'b0;
          response_uop_q[port_index] <= '0;
        end

        // --- 2. 第一级元数据阻塞及数据锁存控制 (Bypass holding register) ---
        if (meta_valid_q[port_index] && !response_ready[port_index]) begin
          // 遭遇后端反压阻塞：为了能够释放共享物理 RAM 端口，必须在本周期时钟沿，
          // 将已解析出的 resolved_src 数据锁存入本地 `meta_srcX_q` 寄存器中！
          if (!meta_data_valid_q[port_index]) begin
            meta_src1_q[port_index] <= resolved_src1[port_index];
            meta_src2_q[port_index] <= resolved_src2[port_index];
            meta_data_valid_q[port_index] <= 1'b1;       // 标记此后使用本地已捕获的数据
          end
        end else if (meta_valid_q[port_index]) begin
          // 顺利流转：清空上一级 valid 状态
          meta_valid_q[port_index] <= 1'b0;
          meta_data_valid_q[port_index] <= 1'b0;
        end else begin
          meta_valid_q[port_index] <= 1'b0;
          meta_data_valid_q[port_index] <= 1'b0;
        end

        // --- 3. 第一级元数据接纳新请求 ---
        if (incoming_valid[port_index] && meta_ready[port_index]) begin
          meta_valid_q[port_index] <= 1'b1;
          meta_data_valid_q[port_index] <= 1'b0;
          meta_uop_q[port_index] <= incoming_uop[port_index];
          meta_slot_q[port_index] <= incoming_slot[port_index];
        end
      end
    end
  end

  // ==========================================================================
  // 系统断言 (SystemVerilog Assertions)
  // ==========================================================================
`ifndef SYNTHESIS
  // 断言：当执行端不就绪（Stall）时，四个执行通道的输出端口和 valid 状态必须保持稳定
  property int0_hold_stable;
    @(posedge clk_i) disable iff (rst_i || recovery_i.valid)
      int0_valid_o && !int0_ready_i |=> int0_valid_o && $stable(int0_uop_o);
  endproperty
  property int1_hold_stable;
    @(posedge clk_i) disable iff (rst_i || recovery_i.valid)
      int1_valid_o && !int1_ready_i |=> int1_valid_o && $stable(int1_uop_o);
  endproperty
  property lsu_hold_stable;
    @(posedge clk_i) disable iff (rst_i || recovery_i.valid)
      lsu_valid_o && !lsu_ready_i |=> lsu_valid_o && $stable(lsu_uop_o);
  endproperty
  property mdu_hold_stable;
    @(posedge clk_i) disable iff (rst_i || recovery_i.valid)
      mdu_valid_o && !mdu_ready_i |=> mdu_valid_o && $stable(mdu_uop_o);
  endproperty

  assert property (int0_hold_stable);
  assert property (int1_hold_stable);
  assert property (lsu_hold_stable);
  assert property (mdu_hold_stable);

  // 断言：检查仲裁输入契约合法性
  always_ff @(posedge clk_i) begin : issue_contract_assertions
    integer first;
    integer second;
    if (!rst_i && !recovery_i.valid) begin
      for (first = 0; first < 3; first = first + 1) begin
        if (slot_valid[first]) begin
          // 检查 1：被发射的通道在 meta_read 端也必须就绪接收
          case (slot_port[first])
            ISSUE_INT0: assert (meta_ready[ISSUE_INT0]);
            ISSUE_INT1: assert (meta_ready[ISSUE_INT1]);
            ISSUE_LSU:  assert (meta_ready[ISSUE_LSU]);
            default:    assert (meta_ready[ISSUE_MDU]);
          endcase
          // 检查 2：到达操作数读取阶段的指令，必须在此前已被唤醒（操作数就绪）
          assert ((!slot_uop[first].need_rs1 || slot_uop[first].src1_ready) &&
                  (!slot_uop[first].need_rs2 || slot_uop[first].src2_ready))
            else $error("operand_read received a source-not-ready uop");
        end

        // 检查 3：同一个时钟周期接收的 3 个 slot 绝不能指向同一个目的执行端口（即不允许端口冲突发生在此处）
        for (second = first + 1; second < 3; second = second + 1) begin
          assert (!(slot_valid[first] && slot_valid[second] &&
                    (slot_port[first] == slot_port[second])))
            else $error("operand_read received duplicate execution ports");
        end
      end
    end
  end
`endif

endmodule
