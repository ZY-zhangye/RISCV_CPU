import core_types_pkg::*;

// issue_arbiter.sv
// 发射仲裁器 (Issue Arbiter)
// 职责：
// 1. 三级流水全局发射仲裁设计 (Three-Stage Global Issue Arbitration)：
//    - P0 级（第一级，结构过滤）：在各发射队列送来的候选指令中，做局部端口结构检查，初步筛选出最多 2 个 INT、1 个 MEM 和 1 个 MDU 候选 proposal 并进行第一拍锁存。
//    - P1 级（第二级，冲突仲裁）：对 P0 锁存的 4 个候选 proposals 执行全局 3 发射带宽限制，以及物理寄存器堆（PRF）奇偶 Bank 每周期最多 3 读端口的访问限制，产生一个 4-bit 的发射掩码并进行第二拍锁存。
//    - P2 级（第三级，验证并输出）：对经过前两级筛选出的最终指令进行有效性重新验证（Re-validation）。由于指令在三周期流水线中穿行时，可能因分支恢复或重定向冲刷而变 stale，
//      此处通过比较候选 uop 的 ROB ID 与发射队列的当前输出，确认其是否依然有效，并在确认端口 Ready 后，生成最终物理发射信号和 Grants 授权信号。
// 2. 仲裁输出打拍：所有最终发往执行端的 valid、port 和 uop 控制包都在 P2 末尾寄存器打拍输出，提供完全隔离的高速时序路径。

module issue_arbiter (
    input  logic                    clk_i,             // 时钟信号
    input  logic                    rst_i,             // 复位信号 (高电平有效)

    // 各发射队列（Issue Queue）候选 uop 输入
    input  logic [2:0]              int_candidate_valid_i, // 整型 IQ 送出的各候选有效位 (来自 3 个组)
    input  issue_uop_t              int_candidate_uop0_i,  // 组 0 的整型候选 uop
    input  issue_uop_t              int_candidate_uop1_i,  // 组 1 的整型候选 uop
    input  issue_uop_t              int_candidate_uop2_i,  // 组 2 的整型候选 uop

    input  logic [1:0]              mem_candidate_valid_i, // 访存 IQ 送出的候选有效位 (来自 2 个组)
    input  issue_uop_t              mem_candidate_uop0_i,  // 组 0 的访存候选 uop
    input  issue_uop_t              mem_candidate_uop1_i,  // 组 1 的访存候选 uop
    input  logic [1:0]              mem_issue_allowed_i,   // 访存发射许可标志 (检查 LSQ 冲突)

    input  logic                    mdu_candidate_valid_i, // MDU 发射队列候选有效位
    input  issue_uop_t              mdu_candidate_uop_i,   // MDU 候选 uop
    input  logic                    mdu_accept_i,          // MDU 执行端接收允许标志

    // 执行管道就绪状态输入 (反压信号)
    input  logic                    int0_ready_i,          // 整数流水线 0 就绪
    input  logic                    int1_ready_i,          // 整数流水线 1 就绪
    input  logic                    lsu_ready_i,           // 访存访存流线就绪
    input  logic                    mdu_ready_i,           // MDU 流水线就绪
    input  logic                    issue_block_i,         // 下一拍将进入全局恢复，暂不授予 IQ
    input  recovery_t               recovery_i,            // 恢复控制包 (分支误预测或精确异常)

    // 发发射授权信号 (Grants，送回各 IQ 用以清除被发射槽位)
    output logic [2:0]              int_issue_grant_o,     // 授予整型 IQ 各组的发射信号
    output logic [1:0]              mem_issue_grant_o,     // 授予访存 IQ 各组的发射信号
    output logic                    mdu_issue_grant_o,     // 授予 MDU IQ 的发射信号

    // 执行端 (Execution Stages / Operand Read) 接口 (已打拍输出)
    output logic [2:0]              issue_valid_o,         // 三条发射通道有效位
    output issue_port_t             issue_port0_o,         // 发射通道 0 目的执行端口
    output issue_port_t             issue_port1_o,         // 发射通道 1 目的执行端口
    output issue_port_t             issue_port2_o,         // 发射通道 2 目的执行端口
    output issue_uop_t              issue_uop0_o,          // 发射通道 0 uop payload
    output issue_uop_t              issue_uop1_o,          // 发射通道 1 uop payload
    output issue_uop_t              issue_uop2_o           // 发射通道 2 uop payload
);

  localparam int PROPOSALS = 4;                            // P0 暂存 proposals 的最大数

  issue_uop_t int_candidate [0:2];
  issue_uop_t mem_candidate [0:1];

  // C0 input snapshot.  The backend-level critical path was dominated by
  // routed IQ candidate payload wires feeding the P0 proposal registers.
  // Snapshot the candidate boundary first; P2 still revalidates against the
  // live IQ outputs before issuing a grant.
  logic [2:0] int_candidate_valid_q;
  issue_uop_t int_candidate_q [0:2];
  logic [1:0] mem_candidate_valid_q;
  issue_uop_t mem_candidate_q [0:1];
  logic [1:0] mem_issue_allowed_q;
  logic mdu_candidate_valid_q;
  issue_uop_t mdu_candidate_uop_q;
  logic mdu_accept_q;
  logic int0_ready_q;
  logic int1_ready_q;
  logic lsu_ready_q;
  logic mdu_ready_q;

  // P0 流水线暂存寄存器线
  logic [PROPOSALS-1:0] proposal_valid_d;
  logic [PROPOSALS-1:0] proposal_valid_q;
  issue_uop_t proposal_uop_d [0:PROPOSALS-1];
  issue_uop_t proposal_uop_q [0:PROPOSALS-1];
  issue_port_t proposal_port_d [0:PROPOSALS-1];
  issue_port_t proposal_port_q [0:PROPOSALS-1];
  logic [2:0] proposal_int_group_d [0:PROPOSALS-1];
  logic [2:0] proposal_int_group_q [0:PROPOSALS-1];
  logic [1:0] proposal_mem_group_d [0:PROPOSALS-1];
  logic [1:0] proposal_mem_group_q [0:PROPOSALS-1];
  logic proposal_mdu_group_d [0:PROPOSALS-1];
  logic proposal_mdu_group_q [0:PROPOSALS-1];
  logic [1:0] proposal_even_reads_d [0:PROPOSALS-1];
  logic [1:0] proposal_even_reads_q [0:PROPOSALS-1];
  logic [1:0] proposal_odd_reads_d [0:PROPOSALS-1];
  logic [1:0] proposal_odd_reads_q [0:PROPOSALS-1];

  // P1 流水线暂存寄存器线 (只过滤出掩码，payload 寄存器无条件传递以优化时序)
  logic [PROPOSALS-1:0] selected_valid_d;
  logic [PROPOSALS-1:0] selected_valid_q;
  issue_uop_t selected_uop_q [0:PROPOSALS-1];
  issue_port_t selected_port_q [0:PROPOSALS-1];
  logic [2:0] selected_int_group_q [0:PROPOSALS-1];
  logic [1:0] selected_mem_group_q [0:PROPOSALS-1];
  logic selected_mdu_group_q [0:PROPOSALS-1];

  // P2 发射输出寄存器驱动线
  logic [2:0] int_issue_grant_d;
  logic [1:0] mem_issue_grant_d;
  logic mdu_issue_grant_d;
  logic [2:0] issue_valid_d;
  issue_port_t issue_port_d [0:2];
  issue_uop_t issue_uop_d [0:2];

  assign int_candidate[0] = int_candidate_uop0_i;
  assign int_candidate[1] = int_candidate_uop1_i;
  assign int_candidate[2] = int_candidate_uop2_i;
  assign mem_candidate[0] = mem_candidate_uop0_i;
  assign mem_candidate[1] = mem_candidate_uop1_i;

  // ==========================================================================
  // 辅助判定函数 (Timing Helper Functions)
  // ==========================================================================
  // 检查操作数就绪状态
  function automatic logic operands_ready(input issue_uop_t uop);
    begin
      operands_ready = (!uop.need_rs1 || uop.src1_ready) &&
                       (!uop.need_rs2 || uop.src2_ready);
    end
  endfunction

  // 判定是否是移位操作 (移位指令规定只能在 INT0 管道运行)
  function automatic logic is_shift(input issue_uop_t uop);
    begin
      is_shift = (uop.fu_type == FU_INT) &&
                 ((uop.alu_op == ALU_SLL) ||
                  (uop.alu_op == ALU_SRL) ||
                  (uop.alu_op == ALU_SRA));
    end
  endfunction

  // 判定是否是分支指令 (分支规定只能在 INT1 管道运行)
  function automatic logic is_branch(input issue_uop_t uop);
    begin
      is_branch = (uop.fu_type == FU_BRANCH);
    end
  endfunction

  function automatic logic branch_unmasked(input issue_uop_t uop);
    begin
      branch_unmasked = (uop.branch_mask == '0);
    end
  endfunction

  function automatic logic is_csr(input issue_uop_t uop);
    begin
      is_csr = (uop.fu_type == FU_CSR);
    end
  endfunction

  // 统计指令读取的偶数物理源寄存器（LSB=0）数量
  function automatic logic [1:0] even_read_count(input issue_uop_t uop);
    begin
      even_read_count = {1'b0, (uop.need_rs1 && !uop.prs1[0])} +
                        {1'b0, (uop.need_rs2 && !uop.prs2[0])};
    end
  endfunction

  // 统计指令读取的奇数物理源寄存器（LSB=1）数量
  function automatic logic [1:0] odd_read_count(input issue_uop_t uop);
    begin
      odd_read_count = {1'b0, (uop.need_rs1 && uop.prs1[0])} +
                       {1'b0, (uop.need_rs2 && uop.prs2[0])};
    end
  endfunction

  function automatic logic [ROB_ID_W-1:0] uop_rob_id(input issue_uop_t uop);
    begin
      uop_rob_id = uop.rob_id;
    end
  endfunction

  function automatic logic same_issue_identity(
      input issue_uop_t live_uop,
      input issue_uop_t selected
  );
    begin
      same_issue_identity = (live_uop.rob_id == selected.rob_id) &&
                            (live_uop.pc == selected.pc) &&
                            (live_uop.fu_type == selected.fu_type);
    end
  endfunction

  // 优先级检索：获取掩码中第 1, 2, 3 个有效位的索引位置
  function automatic logic [1:0] first_index(input logic [3:0] mask);
    begin
      casex (mask)
        4'bxxx1: first_index = 2'd0;
        4'bxx10: first_index = 2'd1;
        4'bx100: first_index = 2'd2;
        default: first_index = 2'd3;
      endcase
    end
  endfunction

  function automatic logic [1:0] second_index(input logic [3:0] mask);
    begin
      case (mask)
        4'b0011, 4'b0111, 4'b1011, 4'b1111: second_index = 2'd1;
        4'b0101, 4'b0110, 4'b1101, 4'b1110: second_index = 2'd2;
        4'b1001, 4'b1010, 4'b1100:          second_index = 2'd3;
        default:                            second_index = 2'd0;
      endcase
    end
  endfunction

  function automatic logic [1:0] third_index(input logic [3:0] mask);
    begin
      case (mask)
        4'b0111, 4'b1111: third_index = 2'd2;
        4'b1011, 4'b1101, 4'b1110: third_index = 2'd3;
        default: third_index = 2'd0;
      endcase
    end
  endfunction

  function automatic logic has_second(input logic [3:0] mask);
    begin
      has_second =
          (mask[0] && (mask[1] || mask[2] || mask[3])) ||
          (mask[1] && (mask[2] || mask[3])) ||
          (mask[2] && mask[3]);
    end
  endfunction

  function automatic logic has_third(input logic [3:0] mask);
    begin
      has_third =
          (mask[0] && mask[1] && mask[2]) ||
          (mask[0] && mask[1] && mask[3]) ||
          (mask[0] && mask[2] && mask[3]) ||
          (mask[1] && mask[2] && mask[3]);
    end
  endfunction

  function automatic issue_uop_t selected_uop(input logic [1:0] index);
    begin
      case (index)
        2'd1: selected_uop = selected_uop_q[1];
        2'd2: selected_uop = selected_uop_q[2];
        2'd3: selected_uop = selected_uop_q[3];
        default: selected_uop = selected_uop_q[0];
      endcase
    end
  endfunction

  function automatic issue_port_t normalize_port(input logic [1:0] port_bits);
    begin
      case (port_bits)
        ISSUE_INT1: normalize_port = ISSUE_INT1;
        ISSUE_LSU:  normalize_port = ISSUE_LSU;
        ISSUE_MDU:  normalize_port = ISSUE_MDU;
        default:    normalize_port = ISSUE_INT0;
      endcase
    end
  endfunction

  function automatic issue_port_t selected_port(input logic [1:0] index);
    begin
      case (index)
        2'd1: selected_port = normalize_port(selected_port_q[1]);
        2'd2: selected_port = normalize_port(selected_port_q[2]);
        2'd3: selected_port = normalize_port(selected_port_q[3]);
        default: selected_port = normalize_port(selected_port_q[0]);
      endcase
    end
  endfunction

  // ==========================================================================
  // P0 级：结构合法性初筛 (Port constraints checking)
  // ==========================================================================
  // 检查每路候选 uop 操作数是否 ready、目标端口是否冲突，并选拔最多 2 个 INT、1 个 MEM 和 1 个 MDU 候选送入第一拍锁存
  always @* begin : preselect
    integer idx;
    logic [1:0] int_proposal_count;
    logic [2:0] int_selected;
    logic int0_used;
    logic int1_used;
    logic mem_selected;

    proposal_valid_d = '0;
    int_selected = '0;
    int0_used = 1'b0;
    int1_used = 1'b0;
    mem_selected = 1'b0;
    int_proposal_count = 2'd0;
    for (idx = 0; idx < PROPOSALS; idx = idx + 1) begin
      proposal_uop_d[idx] = '0;
      proposal_port_d[idx] = ISSUE_INT0;
      proposal_int_group_d[idx] = '0;
      proposal_mem_group_d[idx] = '0;
      proposal_mdu_group_d[idx] = 1'b0;
      proposal_even_reads_d[idx] = '0;
      proposal_odd_reads_d[idx] = '0;
    end

    if (!rst_i && !recovery_i.valid) begin
      // A. 分支跳转指令挑选：只允许分配到 INT1 通道
      for (idx = 0; idx < 3; idx = idx + 1) begin
        if (!int1_used && int_candidate_valid_q[idx] &&
            is_branch(int_candidate_q[idx]) &&
            branch_unmasked(int_candidate_q[idx]) &&
            operands_ready(int_candidate_q[idx]) && int1_ready_q) begin
          proposal_valid_d[int_proposal_count] = 1'b1;
          proposal_uop_d[int_proposal_count] = int_candidate_q[idx];
          proposal_port_d[int_proposal_count] = ISSUE_INT1;
          proposal_int_group_d[int_proposal_count][idx] = 1'b1;
          proposal_even_reads_d[int_proposal_count] =
              even_read_count(int_candidate_q[idx]);
          proposal_odd_reads_d[int_proposal_count] =
              odd_read_count(int_candidate_q[idx]);
          int_selected[idx] = 1'b1;
          int1_used = 1'b1;
          int_proposal_count = int_proposal_count + 2'd1;
        end
      end

      // B. CSR 操作数准备固定走 INT0，不占用 INT1/Branch 通道。
      for (idx = 0; idx < 3; idx = idx + 1) begin
        if (!int0_used && !int_selected[idx] &&
            int_candidate_valid_q[idx] &&
            is_csr(int_candidate_q[idx]) &&
            operands_ready(int_candidate_q[idx]) && int0_ready_q) begin
          proposal_valid_d[int_proposal_count] = 1'b1;
          proposal_uop_d[int_proposal_count] = int_candidate_q[idx];
          proposal_port_d[int_proposal_count] = ISSUE_INT0;
          proposal_int_group_d[int_proposal_count][idx] = 1'b1;
          proposal_even_reads_d[int_proposal_count] =
              even_read_count(int_candidate_q[idx]);
          proposal_odd_reads_d[int_proposal_count] =
              odd_read_count(int_candidate_q[idx]);
          int_selected[idx] = 1'b1;
          int0_used = 1'b1;
          int_proposal_count = int_proposal_count + 2'd1;
        end
      end

      // C. 移位指令挑选：只允许分配到 INT0 通道
      for (idx = 0; idx < 3; idx = idx + 1) begin
        if (!int0_used && !int_selected[idx] &&
            int_candidate_valid_q[idx] &&
            is_shift(int_candidate_q[idx]) &&
            operands_ready(int_candidate_q[idx]) && int0_ready_q) begin
          proposal_valid_d[int_proposal_count] = 1'b1;
          proposal_uop_d[int_proposal_count] = int_candidate_q[idx];
          proposal_port_d[int_proposal_count] = ISSUE_INT0;
          proposal_int_group_d[int_proposal_count][idx] = 1'b1;
          proposal_even_reads_d[int_proposal_count] =
              even_read_count(int_candidate_q[idx]);
          proposal_odd_reads_d[int_proposal_count] =
              odd_read_count(int_candidate_q[idx]);
          int_selected[idx] = 1'b1;
          int0_used = 1'b1;
          int_proposal_count = int_proposal_count + 2'd1;
        end
      end

      // D. 普通整型指令挑选：可分配到 INT0 或 INT1
      for (idx = 0; idx < 3; idx = idx + 1) begin
        if (!int_selected[idx] && int_candidate_valid_q[idx] &&
            (int_candidate_q[idx].fu_type == FU_INT) &&
            !is_branch(int_candidate_q[idx]) && !is_csr(int_candidate_q[idx]) &&
            !is_shift(int_candidate_q[idx]) &&
            operands_ready(int_candidate_q[idx]) &&
            ((!int0_used && int0_ready_q) ||
             (!int1_used && int1_ready_q))) begin
          proposal_valid_d[int_proposal_count] = 1'b1;
          proposal_uop_d[int_proposal_count] = int_candidate_q[idx];
          proposal_int_group_d[int_proposal_count][idx] = 1'b1;
          proposal_even_reads_d[int_proposal_count] =
              even_read_count(int_candidate_q[idx]);
          proposal_odd_reads_d[int_proposal_count] =
              odd_read_count(int_candidate_q[idx]);
          if (!int0_used && int0_ready_q) begin
            proposal_port_d[int_proposal_count] = ISSUE_INT0;
            int0_used = 1'b1;
          end else begin
            proposal_port_d[int_proposal_count] = ISSUE_INT1;
            int1_used = 1'b1;
          end
          int_selected[idx] = 1'b1;
          int_proposal_count = int_proposal_count + 2'd1;
        end
      end

      // E. 访存指令挑选：分配到固定 LSU proposal 槽，避免经过 INT
      // proposal 压缩链。
      for (idx = 0; idx < 2; idx = idx + 1) begin
        if (!mem_selected && mem_candidate_valid_q[idx] &&
            mem_issue_allowed_q[idx] && operands_ready(mem_candidate_q[idx]) &&
            lsu_ready_q) begin
          proposal_valid_d[2] = 1'b1;
          proposal_uop_d[2] = mem_candidate_q[idx];
          proposal_port_d[2] = ISSUE_LSU;
          proposal_mem_group_d[2][idx] = 1'b1;
          proposal_even_reads_d[2] =
              even_read_count(mem_candidate_q[idx]);
          proposal_odd_reads_d[2] =
              odd_read_count(mem_candidate_q[idx]);
          mem_selected = 1'b1;
        end
      end

      // F. MDU 乘除法指令挑选：固定 MDU proposal 槽。
      if (mdu_candidate_valid_q &&
          mdu_accept_q && mdu_ready_q &&
          operands_ready(mdu_candidate_uop_q)) begin
        proposal_valid_d[3] = 1'b1;
        proposal_uop_d[3] = mdu_candidate_uop_q;
        proposal_port_d[3] = ISSUE_MDU;
        proposal_mdu_group_d[3] = 1'b1;
        proposal_even_reads_d[3] =
            even_read_count(mdu_candidate_uop_q);
        proposal_odd_reads_d[3] =
            odd_read_count(mdu_candidate_uop_q);
      end
    end
  end

  // ==========================================================================
  // P1 级：全局带宽与 PRF Bank 读资源仲裁 (Global limits & PRF Bank conflicts)
  // ==========================================================================
  // 只有 4 个 P0 暂存的 proposals 参与仲裁计算。
  // 时序限制：每周期全核最多发射 3 条指令；同时物理寄存器堆的奇、偶 Bank 读端口分别不超过 3 个。
  // 此处仅生成并传递 4-bit 有效掩码 `selected_valid_d`，其余复杂 payload 硬件不做组合 gating 直接传递。
  always @* begin : select_mask
    integer idx;
    logic [1:0] issue_count;
    logic [2:0] even_reads;
    logic [2:0] odd_reads;
    logic [2:0] next_even;
    logic [2:0] next_odd;

    selected_valid_d = '0;
    issue_count = 2'd0;
    even_reads = '0;
    odd_reads = '0;

    if (!rst_i && !recovery_i.valid) begin
      for (idx = 0; idx < PROPOSALS; idx = idx + 1) begin
        next_even = even_reads + proposal_even_reads_q[idx];
        next_odd = odd_reads + proposal_odd_reads_q[idx];

        // 顺序挑选，同时累加判断全核 3 发送限制与 PRF 奇偶 Bank 各 3 读限制
        if (proposal_valid_q[idx] && (issue_count != 2'd3) &&
            (next_even <= 3) && (next_odd <= 3)) begin
          selected_valid_d[idx] = 1'b1;
          even_reads = next_even;
          odd_reads = next_odd;
          issue_count = issue_count + 2'd1;
        end
      end
    end
  end

  // ==========================================================================
  // P2 级：安全期再次验证并生成最终发射指令 (Re-validation & Finalize)
  // ==========================================================================
  // 由于指令在前两拍计算中在途停留，如果在此期间发生了分支恢复或 Flush，指令可能变 stale。
  // 此处将最终筛选出的 entries 与各 IQ 输出的最新有效指令进行 ROB ID 比较，安全匹配且执行端口就绪时正式授权。
  // 仲裁后的 final outputs 包含 3 路发射通道信息和 IQ grant，时钟沿打拍寄存输出。
  // grant 会比原组合路径晚一拍清 IQ；上一拍 grant 高时屏蔽对应组的 live candidate，
  // 防止 held candidate 在清除落地前被重复发射。
  always @* begin : finalize
    integer idx;
    logic [3:0] fire;
    logic source_match;
    logic endpoint_ready;
    logic [1:0] slot0_index;
    logic [1:0] slot1_index;
    logic [1:0] slot2_index;
    logic slot0_present;
    logic slot1_present;
    logic slot2_present;
    logic [2:0] int_live_valid;
    logic [1:0] mem_live_valid;
    logic mdu_live_valid;

    fire = '0;
    int_issue_grant_d = '0;
    mem_issue_grant_d = '0;
    mdu_issue_grant_d = 1'b0;
    issue_valid_d = '0;
    int_live_valid = int_candidate_valid_i & ~int_issue_grant_o;
    mem_live_valid = mem_candidate_valid_i & ~mem_issue_grant_o;
    mdu_live_valid = mdu_candidate_valid_i && !mdu_issue_grant_o;
    for (idx = 0; idx < 3; idx = idx + 1) begin
      issue_port_d[idx] = ISSUE_INT0;
      issue_uop_d[idx] = '0;
    end

    // Payload packing is driven only by the registered P1 selection mask.
    // Live P2 revalidation may clear a slot's valid bit, leaving a harmless
    // bubble, but it must not steer the wide issue_uop output mux.
    slot0_index = first_index(selected_valid_q);
    slot1_index = second_index(selected_valid_q);
    slot2_index = third_index(selected_valid_q);
    slot0_present = |selected_valid_q;
    slot1_present = has_second(selected_valid_q);
    slot2_present = has_third(selected_valid_q);
    issue_uop_d[0] = selected_uop(slot0_index);
    issue_uop_d[1] = selected_uop(slot1_index);
    issue_uop_d[2] = selected_uop(slot2_index);
    issue_port_d[0] = selected_port(slot0_index);
    issue_port_d[1] = selected_port(slot1_index);
    issue_port_d[2] = selected_port(slot2_index);

    if (!rst_i && !recovery_i.valid && !issue_block_i) begin
      for (idx = 0; idx < PROPOSALS; idx = idx + 1) begin
        // 与 IQ 实时送来的候选身份进行多路比较匹配。ROB ID 会环回，
        // 仅比较 ROB ID 可能让旧 proposal 在 ID 复用后错误发射。
        source_match =
            (selected_int_group_q[idx][0] && int_live_valid[0] &&
             same_issue_identity(int_candidate_uop0_i, selected_uop_q[idx])) ||
            (selected_int_group_q[idx][1] && int_live_valid[1] &&
             same_issue_identity(int_candidate_uop1_i, selected_uop_q[idx])) ||
            (selected_int_group_q[idx][2] && int_live_valid[2] &&
             same_issue_identity(int_candidate_uop2_i, selected_uop_q[idx])) ||
            (selected_mem_group_q[idx][0] && mem_live_valid[0] &&
             same_issue_identity(mem_candidate_uop0_i, selected_uop_q[idx])) ||
            (selected_mem_group_q[idx][1] && mem_live_valid[1] &&
             same_issue_identity(mem_candidate_uop1_i, selected_uop_q[idx])) ||
            (selected_mdu_group_q[idx] && mdu_live_valid &&
             same_issue_identity(mdu_candidate_uop_i, selected_uop_q[idx]));

        case (selected_port_q[idx])
          ISSUE_INT0: endpoint_ready = int0_ready_i;
          ISSUE_INT1: endpoint_ready = int1_ready_i;
          // Use the C0-registered allow mask, not the live cluster input.
          // After the cluster also registers mem_issue_allowed, this keeps the
          // older-store check off the P2 fire → issue_valid/grant path.
          // Stale allow=0 only inserts a bubble; allow is monotonic 0→1 for a
          // held load once all older stores have addresses.
          ISSUE_LSU: endpoint_ready = lsu_ready_i &&
              (|(selected_mem_group_q[idx] & mem_issue_allowed_q));
          default: endpoint_ready = mdu_ready_i && mdu_accept_i;
        endcase

        fire[idx] = selected_valid_q[idx] && source_match && endpoint_ready;
      end

      // 生成给各 IQ 组的 grant，下一拍寄存输出并清除被发射候选。
      int_issue_grant_d =
          ({3{fire[0]}} & selected_int_group_q[0]) |
          ({3{fire[1]}} & selected_int_group_q[1]) |
          ({3{fire[2]}} & selected_int_group_q[2]) |
          ({3{fire[3]}} & selected_int_group_q[3]);
      mem_issue_grant_d =
          ({2{fire[0]}} & selected_mem_group_q[0]) |
          ({2{fire[1]}} & selected_mem_group_q[1]) |
          ({2{fire[2]}} & selected_mem_group_q[2]) |
          ({2{fire[3]}} & selected_mem_group_q[3]);
      mdu_issue_grant_d =
          (fire[0] && selected_mdu_group_q[0]) ||
          (fire[1] && selected_mdu_group_q[1]) ||
          (fire[2] && selected_mdu_group_q[2]) ||
          (fire[3] && selected_mdu_group_q[3]);

      // The visible valid bits follow the registered packing order above.
      // If an earlier proposal fails live validation while a later one fires,
      // the issue vector may contain a bubble; operand_read consumes each
      // slot independently.
      issue_valid_d[0] = slot0_present && fire[slot0_index];
      issue_valid_d[1] = slot1_present && fire[slot1_index];
      issue_valid_d[2] = slot2_present && fire[slot2_index];
    end
  end

  // ==========================================================================
  // C0 候选输入寄存器打拍 (Candidate Input Snapshot)
  // ==========================================================================
  always_ff @(posedge clk_i) begin : candidate_input_registers
    if (rst_i || recovery_i.valid) begin
      int_candidate_valid_q <= '0;
      mem_candidate_valid_q <= '0;
      mem_issue_allowed_q <= '0;
      mdu_candidate_valid_q <= 1'b0;
      mdu_accept_q <= 1'b0;
      int0_ready_q <= 1'b0;
      int1_ready_q <= 1'b0;
      lsu_ready_q <= 1'b0;
      mdu_ready_q <= 1'b0;
      int_candidate_q[0] <= '0;
      int_candidate_q[1] <= '0;
      int_candidate_q[2] <= '0;
      mem_candidate_q[0] <= '0;
      mem_candidate_q[1] <= '0;
      mdu_candidate_uop_q <= '0;
    end else begin
      int_candidate_valid_q <= int_candidate_valid_i;
      int_candidate_q[0] <= int_candidate_uop0_i;
      int_candidate_q[1] <= int_candidate_uop1_i;
      int_candidate_q[2] <= int_candidate_uop2_i;
      mem_candidate_valid_q <= mem_candidate_valid_i;
      mem_candidate_q[0] <= mem_candidate_uop0_i;
      mem_candidate_q[1] <= mem_candidate_uop1_i;
      mem_issue_allowed_q <= mem_issue_allowed_i;
      mdu_candidate_valid_q <= mdu_candidate_valid_i;
      mdu_candidate_uop_q <= mdu_candidate_uop_i;
      mdu_accept_q <= mdu_accept_i;
      int0_ready_q <= int0_ready_i;
      int1_ready_q <= int1_ready_i;
      lsu_ready_q <= lsu_ready_i;
      mdu_ready_q <= mdu_ready_i;
    end
  end

  // ==========================================================================
  // P0 流水寄存器打拍 (Stage 0 Registers)
  // ==========================================================================
  always_ff @(posedge clk_i) begin : proposal_registers
    integer idx;
    if (rst_i || recovery_i.valid) begin
      proposal_valid_q <= '0;
      for (idx = 0; idx < PROPOSALS; idx = idx + 1) begin
        proposal_uop_q[idx] <= '0;
        proposal_port_q[idx] <= ISSUE_INT0;
        proposal_int_group_q[idx] <= '0;
        proposal_mem_group_q[idx] <= '0;
        proposal_mdu_group_q[idx] <= 1'b0;
        proposal_even_reads_q[idx] <= '0;
        proposal_odd_reads_q[idx] <= '0;
      end
    end else begin
      proposal_valid_q <= proposal_valid_d;
      for (idx = 0; idx < PROPOSALS; idx = idx + 1) begin
        proposal_uop_q[idx] <= proposal_uop_d[idx];
        proposal_port_q[idx] <= proposal_port_d[idx];
        proposal_int_group_q[idx] <= proposal_int_group_d[idx];
        proposal_mem_group_q[idx] <= proposal_mem_group_d[idx];
        proposal_mdu_group_q[idx] <= proposal_mdu_group_d[idx];
        proposal_even_reads_q[idx] <= proposal_even_reads_d[idx];
        proposal_odd_reads_q[idx] <= proposal_odd_reads_d[idx];
      end
    end
  end

  // ==========================================================================
  // P1 流水寄存器打拍 (Stage 1 Registers)
  // ==========================================================================
  always_ff @(posedge clk_i) begin : selection_registers
    integer idx;
    if (rst_i || recovery_i.valid) begin
      selected_valid_q <= '0;
      for (idx = 0; idx < PROPOSALS; idx = idx + 1) begin
        selected_uop_q[idx] <= '0;
        selected_port_q[idx] <= ISSUE_INT0;
        selected_int_group_q[idx] <= '0;
        selected_mem_group_q[idx] <= '0;
        selected_mdu_group_q[idx] <= 1'b0;
      end
    end else begin
      selected_valid_q <= selected_valid_d;
      for (idx = 0; idx < PROPOSALS; idx = idx + 1) begin
        // 时序优化：数据部分的传递是无条件（无 gating Mux 延迟）的
        selected_uop_q[idx] <= proposal_uop_q[idx];
        selected_port_q[idx] <= proposal_port_q[idx];
        selected_int_group_q[idx] <= proposal_int_group_q[idx];
        selected_mem_group_q[idx] <= proposal_mem_group_q[idx];
        selected_mdu_group_q[idx] <= proposal_mdu_group_q[idx];
      end
    end
  end

  // ==========================================================================
  // P2 发射输出寄存器打拍 (Stage 2 Registers - Outputs to execution units)
  // ==========================================================================
  always_ff @(posedge clk_i) begin : issue_registers
    if (rst_i || recovery_i.valid) begin
      int_issue_grant_o <= '0;
      mem_issue_grant_o <= '0;
      mdu_issue_grant_o <= 1'b0;
      issue_valid_o <= '0;
      issue_port0_o <= ISSUE_INT0;
      issue_port1_o <= ISSUE_INT0;
      issue_port2_o <= ISSUE_INT0;
      issue_uop0_o <= '0;
      issue_uop1_o <= '0;
      issue_uop2_o <= '0;
    end else begin
      int_issue_grant_o <= int_issue_grant_d;
      mem_issue_grant_o <= mem_issue_grant_d;
      mdu_issue_grant_o <= mdu_issue_grant_d;
      issue_valid_o <= issue_valid_d;
      issue_port0_o <= issue_port_d[0];
      issue_port1_o <= issue_port_d[1];
      issue_port2_o <= issue_port_d[2];
      issue_uop0_o <= issue_uop_d[0];
      issue_uop1_o <= issue_uop_d[1];
      issue_uop2_o <= issue_uop_d[2];
    end
  end

endmodule
