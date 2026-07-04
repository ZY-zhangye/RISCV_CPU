`timescale 1ns/1ps

import core_types_pkg::*;

// instruction_buffer.sv
// 指令缓冲区模块 (Instruction Buffer - IBuf)
// 职责：
// 1. 作为一个容量为 8 的环形 FIFO 缓冲队列，存放取指阶段输出的有效指令条目（fetch_slot_t）；
// 2. 支持单周期最多写入 4 条经过压缩整理（Compacted）的指令（针对取指块中 valid 槽不连续的情况）；
// 3. 支持单周期最多读出 2 条顺序指令，供下级超标量译码阶段（Decode）使用；
// 4. 采用读写指针（Head & Tail）的形式，无需进行昂贵的整阵列移位寄存器操作；
// 5. 通过双路寄存输出切断 entry 读 Mux 到 Decode 的组合路径；反压时输出自然保持。

module instruction_buffer (
    input  logic                clk_i,             // 时钟信号
    input  logic                rst_i,             // 复位信号 (高电平有效)

    // 前端取指（Fetch）输入接口
    input  logic                fetch_valid_i,     // 输入的取指数据有效
    output logic                fetch_ready_o,     // 缓冲区就绪，允许接收新的取指包
    input  fetch_packet_t       fetch_packet_i,    // 输入的取指包数据

    // 译码（Decode）读出接口 (2 路超标量)
    output logic [1:0]          decode_valid_o,    // 输出译码通道的有效指示 ([0]通道0，[1]通道1)
    input  logic                decode_ready_i,    // 下游译码阶段已准备好接收 (反压信号)
    output fetch_slot_t         decode_slot0_o,    // 译码通道 0 数据
    output fetch_slot_t         decode_slot1_o,    // 译码通道 1 数据

    // 系统冲刷与状态指示
    input  logic                flush_i,           // 冲刷信号 (分支误预测或异常时清空缓冲区)
    output logic [3:0]          occupancy_o        // 输出当前缓冲区中的指令占用数量 (0~8)
);

  // ==========================================================================
  // 寄存状态与流水线寄存器 (Queue Storage & Pointers)
  // ==========================================================================
  fetch_slot_t entries_q [0:IBUF_ENTRIES-1];       // 队列物理存储器 (8项指令槽)
  logic [2:0] head_q;                              // 读指针（指向待出队的头部项，3位自动Wrap-around模8）
  logic [2:0] tail_q;                              // 写指针（指向下一个写入位置，3位自动Wrap-around模8）
  logic [3:0] occupancy_q;                         // 环形存储占用数，不含输出寄存器
  logic [1:0] output_valid_q;                       // Decode 可见的寄存输出有效位
  fetch_slot_t [1:0] output_slots_q;                // Decode 可见的寄存输出 payload

  // ==========================================================================
  // 中间连线与控制信号 (Wires)
  // ==========================================================================
  fetch_slot_t head_slot0;                         // 指向 Head 的第一条指令
  fetch_slot_t head_slot1;                         // 指向 Head+1 的第二条指令
  fetch_slot_t [3:0] packet_slots;                 // 存储当前输入包拆解出的 4 个指令槽

  logic [2:0] enqueue_count;                       // 当前周期请求写入的有效指令数量 (0~4)
  logic [1:0] output_count;                        // 输出寄存器当前有效数 (0~2)
  logic [1:0] refill_count;                        // 本周期从环形存储预取到输出寄存器的数量
  logic [3:0] free_count;                          // 当前缓冲区的空闲槽数 (0~8)
  logic fetch_fire;                                // 取指端与缓冲区握手成功
  logic decode_fire;                               // 缓冲区与译码端握手成功
  logic output_can_refill;                         // 输出为空或本周期被整体消费

  // ==========================================================================
  // 辅助转换函数 (Helper Functions)
  // ==========================================================================
  // 指针加法，模 8 自动Wrap
  function automatic logic [2:0] ptr_add(
      input logic [2:0] base,
      input integer     offset
  );
    ptr_add = base + offset;
  endfunction

  // 从取指包 (fetch_packet_t) 中重构单条指令槽 (fetch_slot_t) 的元数据
  function automatic fetch_slot_t make_slot(
      input fetch_packet_t packet,
      input logic [1:0]    slot
  );
    fetch_slot_t result;
    result = '0;
    // 计算该槽位指令对应的绝对 PC
    result.pc = packet.block_pc + {28'b0, slot, 2'b0};
    case (slot)
      2'd0: result.inst = packet.inst[0];
      2'd1: result.inst = packet.inst[1];
      2'd2: result.inst = packet.inst[2];
      2'd3: result.inst = packet.inst[3];
      default: result.inst = 32'b0;
    endcase
    // 判定该槽位是否触发了分支预测跳转
    result.pred_taken = packet.pred_taken && (packet.pred_slot == slot);
    result.pred_target = result.pred_taken ? packet.pred_target : 32'b0;
    result.fetch_id = packet.fetch_id;
    // 异常有效性传递：包异常有效且当前指令槽处于有效掩码内
    case (slot)
      2'd0: result.exception_valid = packet.exception_valid && packet.slot_valid[0];
      2'd1: result.exception_valid = packet.exception_valid && packet.slot_valid[1];
      2'd2: result.exception_valid = packet.exception_valid && packet.slot_valid[2];
      2'd3: result.exception_valid = packet.exception_valid && packet.slot_valid[3];
      default: result.exception_valid = 1'b0;
    endcase
    result.exception_cause = result.exception_valid ? packet.exception_cause : 4'b0;
    result.exception_tval = result.exception_valid ? packet.exception_tval : 32'b0;
    return result;
  endfunction

  // ==========================================================================
  // 输入通道解析与写入控制逻辑 (Enqueue Path)
  // ==========================================================================
  always @* begin
    packet_slots[0] = make_slot(fetch_packet_i, 2'd0);
    packet_slots[1] = make_slot(fetch_packet_i, 2'd1);
    packet_slots[2] = make_slot(fetch_packet_i, 2'd2);
    packet_slots[3] = make_slot(fetch_packet_i, 2'd3);
  end

  // 计算当前取指包中 valid 的 slot 数量
  assign enqueue_count = fetch_packet_i.slot_valid[0] +
                         fetch_packet_i.slot_valid[1] +
                         fetch_packet_i.slot_valid[2] +
                         fetch_packet_i.slot_valid[3];
  assign output_count = output_valid_q[1] ? 2'd2 :
                        (output_valid_q[0] ? 2'd1 : 2'd0);
  assign occupancy_o = occupancy_q + output_count;
  assign free_count = IBUF_ENTRIES - occupancy_o;

  // 缓冲区有足够空间，且无冲刷，方可接纳新的取指数据
  assign fetch_ready_o = !flush_i && (enqueue_count <= free_count);
  assign fetch_fire = fetch_valid_i && fetch_ready_o;

  // ==========================================================================
  // 输出通道解算与暂存控制逻辑 (Dequeue Path)
  // ==========================================================================
  assign head_slot0 = entries_q[head_q];
  assign head_slot1 = entries_q[ptr_add(head_q, 1)];
  assign decode_valid_o = flush_i ? 2'b00 : output_valid_q;
  assign decode_slot0_o = output_slots_q[0];
  assign decode_slot1_o = output_slots_q[1];

  // 指令成功被译码接收的触发信号
  assign decode_fire = decode_ready_i && (decode_valid_o != 2'b00) && !flush_i;

  // 只有输出为空或当前 bundle 被整体接受时才预取，禁止覆盖被 stall 的输出。
  assign output_can_refill = (output_valid_q == 2'b00) || decode_fire;

  always @* begin
    refill_count = 2'd0;
    if (output_can_refill) begin
      if (occupancy_q >= 2)
        refill_count = 2'd2;
      else if (occupancy_q == 1)
        refill_count = 2'd1;
    end
  end

  // ==========================================================================
  // 时序更新逻辑 (Queue Operations)
  // ==========================================================================
  always_ff @(posedge clk_i) begin : ibuf_state
    integer write_offset;

    if (rst_i) begin
      head_q         <= 3'd0;
      tail_q         <= 3'd0;
      occupancy_q    <= 4'd0;
      output_valid_q <= 2'b00;
      output_slots_q <= '0;
    end else if (flush_i) begin
      // 发生流水线冲刷，清空缓冲区指针与锁定寄存器
      head_q         <= 3'd0;
      tail_q         <= 3'd0;
      occupancy_q    <= 4'd0;
      output_valid_q <= 2'b00;
      output_slots_q <= '0;
    end else begin
      // A. 输出级预取：entry 读 Mux 的结果只进入本级寄存器，不直达 Decode。
      if (output_can_refill) begin
        case (refill_count)
          2'd2: begin
            output_valid_q <= 2'b11;
            output_slots_q[0] <= head_slot0;
            output_slots_q[1] <= head_slot1;
          end
          2'd1: begin
            output_valid_q <= 2'b01;
            output_slots_q[0] <= head_slot0;
            output_slots_q[1] <= '0;
          end
          default: begin
            output_valid_q <= 2'b00;
            output_slots_q <= '0;
          end
        endcase
      end

      if (refill_count != 0)
        head_q <= ptr_add(head_q, refill_count);

      // B. 写入数据压入队列 (支持压缩存储)：
      // 提取取指包中有效的槽，并将其紧凑连续地（不带任何间隙/空槽）存入 tail_q 指向的位置
      if (fetch_fire) begin
        write_offset = 0;
        if (fetch_packet_i.slot_valid[0]) begin
          entries_q[ptr_add(tail_q, write_offset)] <= packet_slots[0];
          write_offset = write_offset + 1;
        end
        if (fetch_packet_i.slot_valid[1]) begin
          entries_q[ptr_add(tail_q, write_offset)] <= packet_slots[1];
          write_offset = write_offset + 1;
        end
        if (fetch_packet_i.slot_valid[2]) begin
          entries_q[ptr_add(tail_q, write_offset)] <= packet_slots[2];
          write_offset = write_offset + 1;
        end
        if (fetch_packet_i.slot_valid[3]) begin
          entries_q[ptr_add(tail_q, write_offset)] <= packet_slots[3];
          write_offset = write_offset + 1;
        end
        // 更新写指针
        tail_q <= ptr_add(tail_q, enqueue_count);
      end

      // C. 环形存储占用计算；输出寄存器另由 output_count 计入总 occupancy。
      case ({fetch_fire, (refill_count != 0)})
        2'b10: occupancy_q <= occupancy_q + enqueue_count; // 仅入队
        2'b01: occupancy_q <= occupancy_q - refill_count; // 仅预取
        2'b11: occupancy_q <= occupancy_q + enqueue_count - refill_count;
        default: occupancy_q <= occupancy_q;
      endcase
    end
  end

  // ==========================================================================
  // 系统断言 (SystemVerilog Assertions)
  // ==========================================================================
`ifdef INSTRUCTION_BUFFER_ASSERTIONS
  // 断言 1：缓冲区中指令的实际存储数永远不能超过缓冲区容量 (8)
  property p_occupancy_bound;
    @(posedge clk_i) disable iff (rst_i) occupancy_o <= IBUF_ENTRIES;
  endproperty
  assert property (p_occupancy_bound);

  // 断言 2：双路超标量译码中，不可以出现“仅路1有效但路0无效”的情况 (必须优先填充路0)
  property p_decode_prefix;
    @(posedge clk_i) disable iff (rst_i) decode_valid_o != 2'b10;
  endproperty
  assert property (p_decode_prefix);

  // 断言 3：当译码发生反压阻塞时，输出端口的数据（Valid 和指令槽内容）必须保持稳定翻转不变
  property p_decode_stable;
    @(posedge clk_i) disable iff (rst_i || flush_i)
      (decode_valid_o != 2'b00) && !decode_ready_i |=>
        $stable(decode_valid_o) && $stable(decode_slot0_o) &&
        $stable(decode_slot1_o);
  endproperty
  assert property (p_decode_stable);

  // 断言 4：入队写操作安全保证，写入的条目数绝不能大于当前缓冲区的空闲槽位
  property p_fetch_capacity;
    @(posedge clk_i) disable iff (rst_i)
      fetch_fire |-> (enqueue_count <= free_count);
  endproperty
  assert property (p_fetch_capacity);
`endif

endmodule
