`include "defines.svh"

// =============================================================================
// 独立分区 Issue Queue bank
// =============================================================================
// 8 项全相联调度窗口，每拍最多双入队、单发射。
//
// 【模块角色】
//   每个 IQ bank 是一个独立的乱序发射窗口，管理已重命名、正在等待源操作数的
//   指令。它监听两路写回广播（CDB），在源就绪后按 oldest-ready 策略选择
//   一条指令发射到对应的执行单元。
//
// 【关键机制】
//   a. 唤醒（Wakeup）：每拍并行比较所有有效条目的源物理寄存器与 CDB 端口，
//      匹配时置位 src1/2_ready。同拍入队的条目也能通过当拍 CDB 匹配唤醒。
//   b. 选择（Select）：oldest-ready——从所有就绪（valid + 源就绪 + FU 可用）
//      的条目中，选择 ROB 环形年龄最小的。
//   c. Hold：下游阻塞时将选中条目锁存到 hold 寄存器，
//      保持 issue 接口稳定并避免重复选择。
//   d. 发射时捕获 bypass 数据：如果选中指令的源物理寄存器本拍被 CDB
//      写回，直接捕获旁路数据（不等待 PRF 读）。
//
// 【BANK_ID 差异】
//   BANK_ID=0：支持 ALU / MLU（例化为 IQ0）
//   BANK_ID=1：支持 ALU / BRU / CSR（例化为 IQ1）
// =============================================================================
module issue_queue #(
    parameter int BANK_ID = 0,
    parameter int DEPTH   = 8
) (
    input  logic                                  clk,
    input  logic                                  rst_n,

    input  logic [1:0]                            enq_valid,
    input  wire core_port_pkg::dp_iq_bundle_t     enq_bus,
    output      core_port_pkg::dispatch_capacity_t capacity,

    input  wire core_port_pkg::phys_reg_write_bundle_t wakeup_bus,
    input  wire core_port_pkg::rob_tag_t          rob_head_tag,
    input  wire core_port_pkg::recover_event_t    recover,

    input  logic                                  alu_available,
    input  logic                                  mlu_available,
    input  logic                                  bru_available,
    input  logic                                  csr_available,

    output logic                                  issue_valid,
    output      core_port_pkg::iq_issue_slot_t    issue_bus,
    input  logic                                  issue_ready,
    output logic                                  issue_fire,
    output      core_port_pkg::iq_prf_read_req_t  prf_read_req,

    output logic [$clog2(DEPTH+1)-1:0]            occupancy_o
);
    import core_port_pkg::*;

    localparam int INDEX_WIDTH = $clog2(DEPTH);
    localparam int COUNT_WIDTH = $clog2(DEPTH + 1);

    // ── 内部条目定义 ──
    // 每个条目保存一条指令的全部调度信息。
    // payload 来自 Dispatch（含译码、物理寄存器号、Rob tag 等）。
    // src1_ready/src2_ready 由写回广播置位，初始值来自 Rename 的 Busy Table 快照。
    typedef struct packed {
        logic        valid;             // 条目占用
        dp_iq_slot_t payload;           // Dispatch 传来的全部信息
        logic        src1_ready;        // 源 1 结果已就绪
        logic        src2_ready;        // 源 2 结果已就绪
    } iq_entry_t;

    iq_entry_t entries [0:DEPTH-1];

    logic [COUNT_WIDTH-1:0] occupancy;
    logic                   select_valid;
    logic [INDEX_WIDTH-1:0] select_idx;
    iq_issue_slot_t         select_packet;
    logic [ROB_PTR_WIDTH-1:0] select_age;
    logic [ROB_PTR_WIDTH-1:0] scan_age;
    logic                   scan_src1_ready;
    logic                   scan_src2_ready;

    logic                   hold_valid;
    logic [INDEX_WIDTH-1:0] hold_idx;
    iq_issue_slot_t         hold_packet;

    logic [INDEX_WIDTH-1:0] free_idx0;
    logic [INDEX_WIDTH-1:0] free_idx1;
    logic                   free_valid0;
    logic                   free_valid1;
    logic [1:0]             enq_fire;
    logic [1:0]             enq_count;
    logic [1:0]             issue_count;

    integer scan_idx;
    integer free_scan_idx;
    integer reset_idx;

    // ── 写回广播匹配 ──
    // 给定物理寄存器号是否被本拍任一写回端口写入。
    // preg=0（p0/x0）不参与匹配（恒 ready）。
    function automatic logic wakeup_match(input phys_reg_idx_t preg);
        wakeup_match = (preg != '0)
                     && ((wakeup_bus.lane0.valid
                          && (wakeup_bus.lane0.preg == preg))
                         || (wakeup_bus.lane1.valid
                             && (wakeup_bus.lane1.preg == preg)));
    endfunction

    // ── FU 类型支持检查 ──
    // 根据 BANK_ID 参数决定哪些功能单元可以由本 bank 发射。
    // IQ0: ALU / MLU
    // IQ1: ALU / BRU / CSR
    function automatic logic fu_supported(input fu_type_e fu_type);
        if (BANK_ID == 0)
            fu_supported = (fu_type == FU_ALU) || (fu_type == FU_MLU);
        else
            fu_supported = (fu_type == FU_ALU) || (fu_type == FU_BRU)
                         || (fu_type == FU_CSR);
    endfunction

    // ── 功能单元可用性 ──
    // 由外部执行单元在 issue 选择时通过组合信号告知。
    // 多周期指令（MUL/DIV）在忙时直接拉低对应 available，
    // 防止 IQ 将新指令发往正在计算的执行单元。
    function automatic logic fu_available(input fu_type_e fu_type);
        unique case (fu_type)
            FU_ALU: fu_available = alu_available;
            FU_MLU: fu_available = mlu_available;
            FU_BRU: fu_available = bru_available;
            FU_CSR: fu_available = csr_available;
            default: fu_available = 1'b0;
        endcase
    endfunction

    // ── 构造 issue 发出包 ──
    // 将条目内容打包为 iq_issue_slot_t，同时捕获本拍 CDB 写回数据。
    // 如果选中指令的源物理寄存器本拍正在被写回，将数据直接旁路到
    // issue 包中（不等待 PRF 同步读），实现写回旁路零延迟。
    function automatic iq_issue_slot_t make_issue_packet(input iq_entry_t entry);
        iq_issue_slot_t packet;
        begin
            packet = '0;
            packet.rob_tag = entry.payload.rob_tag;
            packet.uop     = entry.payload.uop;

            // src1 bypass：检查两路 CDB 是否写回本指令的 prs1
            if (entry.payload.uop.dec.use_rs1
                && (entry.payload.uop.prs1 != '0)) begin
                if (wakeup_bus.lane0.valid
                    && (wakeup_bus.lane0.preg == entry.payload.uop.prs1)) begin
                    packet.src1_bypass_valid = 1'b1;
                    packet.src1_bypass_data  = wakeup_bus.lane0.data;
                end
                if (wakeup_bus.lane1.valid
                    && (wakeup_bus.lane1.preg == entry.payload.uop.prs1)) begin
                    packet.src1_bypass_valid = 1'b1;
                    packet.src1_bypass_data  = wakeup_bus.lane1.data; // lane1 优先
                end
            end

            // src2 bypass：同理
            if (entry.payload.uop.dec.use_rs2
                && (entry.payload.uop.prs2 != '0)) begin
                if (wakeup_bus.lane0.valid
                    && (wakeup_bus.lane0.preg == entry.payload.uop.prs2)) begin
                    packet.src2_bypass_valid = 1'b1;
                    packet.src2_bypass_data  = wakeup_bus.lane0.data;
                end
                if (wakeup_bus.lane1.valid
                    && (wakeup_bus.lane1.preg == entry.payload.uop.prs2)) begin
                    packet.src2_bypass_valid = 1'b1;
                    packet.src2_bypass_data  = wakeup_bus.lane1.data; // lane1 优先
                end
            end

            make_issue_packet = packet;
        end
    endfunction

    // ══════════════════════════════════════════════════════════════════════════
    // 组合逻辑块 A：入队 + Dispatch capacity
    // ══════════════════════════════════════════════════════════════════════════
    // 扫描 entries[] 中 valid=0 的槽位，返回前两个空闲槽索引。
    //
    // 【时序约束】
    // capacity 只依赖寄存的 entry.valid。不旁路本拍 issue_fire
    // 即将释放的槽位。这避免了 issue→enqueue 的组合环路。
    // 代价是本拍 issue 释放的槽位下一拍才能被 Dispatch 看到。
    //
    // 【前缀约束】
    // enq_fire[1] = enq_valid[1] && enq_valid[0] && free_valid1
    // lane1 入队要求 lane0 也入队，与上游 dispatch 的 prefix 一致。
    // =========================================================================
    always_comb begin
        free_valid0 = 1'b0;
        free_valid1 = 1'b0;
        free_idx0   = '0;
        free_idx1   = '0;
        for (free_scan_idx = 0; free_scan_idx < DEPTH;
             free_scan_idx = free_scan_idx + 1) begin
            if (!entries[free_scan_idx].valid) begin
                if (!free_valid0) begin
                    free_valid0 = 1'b1;
                    free_idx0   = INDEX_WIDTH'(free_scan_idx);
                end else if (!free_valid1) begin
                    free_valid1 = 1'b1;
                    free_idx1   = INDEX_WIDTH'(free_scan_idx);
                end
            end
        end

        if (free_valid1)
            capacity = dispatch_capacity_t'(2);
        else if (free_valid0)
            capacity = dispatch_capacity_t'(1);
        else
            capacity = '0;

        enq_fire[0] = enq_valid[0] && free_valid0;
        enq_fire[1] = enq_valid[1] && enq_valid[0] && free_valid1;
        enq_count   = {1'b0, enq_fire[0]} + {1'b0, enq_fire[1]};
    end

    // ══════════════════════════════════════════════════════════════════════════
    // 组合逻辑块 B：Oldest-ready 选择 + issue 输出
    // ══════════════════════════════════════════════════════════════════════════
    // 从所有 valid、源就绪、FU 类型匹配且 FU 可用的条目中，选择 ROB 年龄
    // 最老的。年龄 = rob_tag - rob_head_tag（环形距离），值越小越老。
    //
    // 【就绪判断】
    //   每个条目在 scan 时通过三重条件检查 src1/2_ready：
    //     ① 不使用该源 → ready
    //     ② 条目内部寄存的 src1/2_ready 已被唤醒 → ready
    //     ③ 本拍 CDB 广播命中 → ready（当拍唤醒，无需额外周期）
    //
    // 【年轻 ready 越过老年未就绪】
    //   条件中要求 src1_ready && src2_ready，老指令只要任意源未就绪
    //   就被排除，年轻但就绪的指令自然被选中。无需额外逻辑。
    //
    // 【Hold 机制】
    //   如果下游阻塞，选中条目进入 hold 寄存器——不重复扫描选择。
    //   这保证了 issue 接口在反压期间输出稳定。
    // =========================================================================
    always_comb begin
        select_valid      = 1'b0;
        select_idx        = '0;
        select_packet     = '0;
        select_age        = '1;
        scan_age          = '0;
        scan_src1_ready   = 1'b0;
        scan_src2_ready   = 1'b0;

        if (!hold_valid) begin
            for (scan_idx = 0; scan_idx < DEPTH; scan_idx = scan_idx + 1) begin
                scan_src1_ready = !entries[scan_idx].payload.uop.dec.use_rs1
                               || entries[scan_idx].src1_ready
                               || wakeup_match(entries[scan_idx].payload.uop.prs1);
                scan_src2_ready = !entries[scan_idx].payload.uop.dec.use_rs2
                               || entries[scan_idx].src2_ready
                               || wakeup_match(entries[scan_idx].payload.uop.prs2);
                scan_age = entries[scan_idx].payload.rob_tag - rob_head_tag;

                if (entries[scan_idx].valid
                    && fu_supported(entries[scan_idx].payload.uop.dec.fu_type)
                    && fu_available(entries[scan_idx].payload.uop.dec.fu_type)
                    && scan_src1_ready && scan_src2_ready
                    && (!select_valid || (scan_age < select_age))) begin
                    select_valid  = 1'b1;
                    select_idx    = INDEX_WIDTH'(scan_idx);
                    select_age    = scan_age;
                    // 构造 issue 包：含 bypass 数据、rob_tag、完整 uop
                    select_packet = make_issue_packet(entries[scan_idx]);
                end
            end
        end
    end

    // ══════════════════════════════════════════════════════════════════════════
    // 组合逻辑块 C：Issue 输出 + PRF 读请求
    // ══════════════════════════════════════════════════════════════════════════
    // issue_valid 来自 hold 或 select 的组合结果。
    // PRF 读请求仅在 issue_fire 当拍有效——不会在阻塞时反复请求 PRF。
    // =========================================================================
    always_comb begin
        issue_valid = hold_valid || select_valid;
        issue_bus   = hold_valid ? hold_packet : select_packet;
        // 功能单元可用性在选择前判断；一旦 valid 在阻塞下被锁存，该选择
        // 即视为预留对应功能单元，随后遵守标准 valid/ready 直到握手。
        issue_fire  = issue_valid && issue_ready;

        prf_read_req = '0;
        prf_read_req.src1.valid = issue_fire && issue_bus.uop.dec.use_rs1;
        prf_read_req.src1.preg  = issue_bus.uop.prs1;
        prf_read_req.src2.valid = issue_fire && issue_bus.uop.dec.use_rs2;
        prf_read_req.src2.preg  = issue_bus.uop.prs2;

        issue_count = {1'b0, issue_fire};
        occupancy_o = occupancy;
    end

    // ══════════════════════════════════════════════════════════════════════════
    // 时序逻辑：IQ 状态更新
    // ══════════════════════════════════════════════════════════════════════════
    //  ① occupancy 更新 = 入队数 - 发射数
    //  ② 写回广播唤醒所有有效条目
    //  ③ issue 释放 + hold 管理
    //  ④ 新入队（放在最后，但入队与已有条目无重叠——free 槽位 valid=0）
    //
    // 【关键时序语义】
    //   入队条目当拍即可收到 CDB 广播的唤醒（wakeup_match 在入队块中同时检查）。
    //   这避免了新入队的源在 Rename 快照中标记为 not-ready、但 CDB 同拍写回时的
    //   漏唤醒问题。
    //
    //   Hold 中的条目在释放后才被扫入 select 候选。这避免了一条指令被重复发射。
    // =========================================================================
    always_ff @(posedge clk) begin
        if (!rst_n || recover.valid) begin
            occupancy <= '0;
            hold_valid <= 1'b0;
            hold_idx   <= '0;
            hold_packet <= '0;
            for (reset_idx = 0; reset_idx < DEPTH; reset_idx = reset_idx + 1)
                entries[reset_idx] <= '0;
        end else begin
            // ── ① occupancy 更新 ──
            occupancy <= occupancy + COUNT_WIDTH'(enq_count)
                                   - COUNT_WIDTH'(issue_count);

            // ── ② 写回广播唤醒（8 项并行） ──
            // 未被选中的等待项持续监听两路写回广播。
            for (reset_idx = 0; reset_idx < DEPTH; reset_idx = reset_idx + 1) begin
                if (entries[reset_idx].valid) begin
                    if (wakeup_match(entries[reset_idx].payload.uop.prs1))
                        entries[reset_idx].src1_ready <= 1'b1;
                    if (wakeup_match(entries[reset_idx].payload.uop.prs2))
                        entries[reset_idx].src2_ready <= 1'b1;
                end
            end

            // ── ③ Issue 释放 + hold 管理 ──
            // 有 hold 条目时优先使用 hold（对外输出稳定），发射后释放。
            // 无 hold 时使用 select 结果：发射则直接释放，阻塞则锁存到 hold。
            if (hold_valid) begin
                if (issue_fire) begin
                    entries[hold_idx].valid <= 1'b0;
                    hold_valid <= 1'b0;
                end
            end else if (select_valid) begin
                if (issue_fire) begin
                    entries[select_idx].valid <= 1'b0; // 直接发射+释放
                end else begin
                    hold_valid  <= 1'b1;   // 阻塞，进 hold
                    hold_idx    <= select_idx;
                    hold_packet <= select_packet; // 锁存 bypass 数据
                end
            end

            // ── ④ 新入队 ──
            // 分配槽来自本拍开始时 `entries[].valid=0` 的空槽，不会与
            // issue 清除的槽重合（issue 释放的槽下一拍才在组合中可见）。
            // src1/2_ready 的三重条件：
            //   ① 指令不使用该源 → ready
            //   ② Rename 时刻 Busy Table 快照 → 初始就绪
            //   ③ 本拍 CDB 广播匹配 → 当拍唤醒（零延迟）
            if (enq_fire[0]) begin
                entries[free_idx0].valid        <= 1'b1;
                entries[free_idx0].payload      <= enq_bus.lane0;
                entries[free_idx0].src1_ready   <= !enq_bus.lane0.uop.dec.use_rs1
                                                || enq_bus.lane0.uop.src1_ready
                                                || wakeup_match(enq_bus.lane0.uop.prs1);
                entries[free_idx0].src2_ready   <= !enq_bus.lane0.uop.dec.use_rs2
                                                || enq_bus.lane0.uop.src2_ready
                                                || wakeup_match(enq_bus.lane0.uop.prs2);
            end
            if (enq_fire[1]) begin
                entries[free_idx1].valid        <= 1'b1;
                entries[free_idx1].payload      <= enq_bus.lane1;
                entries[free_idx1].src1_ready   <= !enq_bus.lane1.uop.dec.use_rs1
                                                || enq_bus.lane1.uop.src1_ready
                                                || wakeup_match(enq_bus.lane1.uop.prs1);
                entries[free_idx1].src2_ready   <= !enq_bus.lane1.uop.dec.use_rs2
                                                || enq_bus.lane1.uop.src2_ready
                                                || wakeup_match(enq_bus.lane1.uop.prs2);
            end
        end
    end

    // ══════════════════════════════════════════════════════════════════════════
    // 仿真断言（不在综合范围内）
    // ══════════════════════════════════════════════════════════════════════════
    // - 入队前缀约束：lane1 要求 lane0 同拍
    // - FU 类型路由正确：入队的指令必须被当前 bank 支持
    //   如果断言触发，说明 dispatch 将错误 FU 类型的指令发到了本 bank。
    // =========================================================================
`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
        if (rst_n && !recover.valid) begin
            assert (!enq_valid[1] || enq_valid[0])
                else $error("issue_queue%0d: enqueue lane1 requires lane0", BANK_ID);
            if (enq_fire[0])
                assert (fu_supported(enq_bus.lane0.uop.dec.fu_type))
                    else $error("issue_queue%0d: unsupported lane0 FU (type=%0d)",
                                BANK_ID, enq_bus.lane0.uop.dec.fu_type);
            if (enq_fire[1])
                assert (fu_supported(enq_bus.lane1.uop.dec.fu_type))
                    else $error("issue_queue%0d: unsupported lane1 FU (type=%0d)",
                                BANK_ID, enq_bus.lane1.uop.dec.fu_type);
        end
    end
`endif

endmodule
