// =============================================================================
// Busy Table —— 物理寄存器就绪状态跟踪
// =============================================================================
// 【模块角色】
//   以 64-bit 位图记录每个物理寄存器的结果是否已就绪：
//     bit=1 → 结果尚未产生（busy）
//     bit=0 → 结果可读（ready）
//   Rename 阶段查询 Busy Table 为每条指令生成 src1_ready/src2_ready 初始快照。
//   后续 IQ 监听到写回广播后自行更新内部就绪状态（唤醒）。
//
// 【核心设计决策】
//   1. source_ready 函数的优先级链：
//       ① 不使用源或源为 p0      → ready（x0 恒为 0）
//       ② 源物理寄存器本拍被分配  → NOT ready（新值还没算出来）
//       ③ 源物理寄存器本拍被写回  → ready（结果刚刚产生，组合旁路）
//       ④ 否则查 busy_bitmap       → ~busy_bit（寄存器状态）
//      优先级②>③的原因：若同拍既分配又写回（不同指令、不同生命周期），
//      新分配的 pdst 对应的值尚未计算，应强制 not ready。写回的是旧生命周期的值。
//
//   2. 本拍写回组合旁路：即使 busy_bitmap 中该位仍为 1，只要本拍写回端口
//      包含该寄存器，即可视为 ready。这避免了一拍的唤醒延迟。
//
//   3. lane1 读 lane0 新 pdst 的正确性：若 rat_rrat 已将 lane1 的源旁路为
//      lane0 新分配的 pdst，busy_table 通过 alloc_mask 检测到该 pdst，
//      返回 not ready（优先级②）。这满足方案中「lane1 读 lane0 新目标时
//      强制标记 not ready」的要求。
//
//   4. 恢复清零：恢复时所有已提交的物理寄存器结果必然已产生，busy 全清零。
//
// 【状态更新公式】
//   busy_bitmap_next = (busy_bitmap & ~writeback_mask) | alloc_mask
//   即先清除写回完成的位，再置位新分配的位。alloc 优先于 writeback。
//   强制 busy_bitmap_next[0]=0（x0/p0 永为 ready）。
//
// 【审阅结论】✅ 设计正确，功能完备。见 doc/free_list_rrat_busy_table_review.md。
// =============================================================================
module busy_table #(
    parameter int PHYS_REG_COUNT = core_port_pkg::PHYS_REG_COUNT
) (
    input  logic                                      clk,
    input  logic                                      rst_n,

    // ---- 就绪查询接口 ----
    // query: 双路查询请求。prs1/prs2 来自 RAT 查询结果（已是物理寄存器号）。
    //        use_srcX 表示该指令是否使用该源操作数。
    // ready: 双路就绪结果。srcX_ready=1 表示该源物理寄存器的值已可用。
    input  wire core_port_pkg::busy_query_bundle_t    query,
    output core_port_pkg::busy_ready_bundle_t          ready,

    // ---- 状态更新接口 ----
    // alloc_event: Rename 成功分配 pdst 时置 busy。lane0/lane1 各一个端口。
    // writeback_event: 执行单元写回结果时清 busy。最多两个写回端口。
    //   注意：alloc 与 writeback 同拍的冲突由 bus 更新公式中的 | alloc_mask 后置解决，
    //   source_ready 查询中的冲突由 if-else 优先级链解决。
    // Rename 成功分配时置 busy；写回广播时清 busy。
    input  wire core_port_pkg::phys_reg_event_bundle_t alloc_event,
    input  wire core_port_pkg::phys_reg_event_bundle_t writeback_event,

    // ---- 恢复接口 ----
    // recover: 全局恢复事件。恢复时 busy_bitmap 整体清零。
    //   前提：RRAT 恢复意味着所有推测状态被丢弃，残留的 busy 位不再有效。
    input  wire core_port_pkg::recover_event_t         recover,
    output logic [PHYS_REG_COUNT-1:0]                 busy_bitmap_o
);
    // ── 内部状态 ──
    logic [PHYS_REG_COUNT-1:0] busy_bitmap;       // 当前拍 busy 位图（寄存输出）
    logic [PHYS_REG_COUNT-1:0] alloc_mask;         // 本拍 Rename 分配的置位掩码（组合）
    logic [PHYS_REG_COUNT-1:0] writeback_mask;     // 本拍写回清除掩码（组合）
    logic [PHYS_REG_COUNT-1:0] busy_bitmap_next;   // 下一拍 busy 位图（组合计算）

    // ==========================================================================
    // 函数：source_ready —— 判断单个源操作数是否就绪
    // ==========================================================================
    // 优先级链（按 if-else 顺序）：
    //   L1: !use_source || source_preg==0  → 指令不使用该源，或源为 x0/p0 → 恒 ready
    //   L2: alloc_bits[source_preg]==1     → 本拍刚分配，结果还未产生 → 强制 NOT ready
    //       ⚠️ 这同时覆盖了"lane1 读 lane0 新 pdst"的场景：
    //       rat_rrat 已将 lane1.prs 旁路为 lane0.pdst，busy_table 检测到
    //       alloc_mask[lane0.pdst]=1，返回 not ready。正确。
    //   L3: writeback_bits[source_preg]==1 → 本拍写回完成，组合旁路 → ready
    //       ⚠️ 如果 alloc 和 writeback 恰好指向同一 preg（不同生命周期），
    //       L2 已优先拦截。不会出现"新分配被错误标记为 ready"的问题。
    //   L4: default → ~busy_bits[source_preg]（查寄存状态）
    // ==========================================================================
    function automatic logic source_ready(
        input logic                                      use_source,
        input core_port_pkg::phys_reg_idx_t              source_preg,
        input logic [PHYS_REG_COUNT-1:0]                 busy_bits,
        input logic [PHYS_REG_COUNT-1:0]                 alloc_bits,
        input logic [PHYS_REG_COUNT-1:0]                 writeback_bits
    );
        if (!use_source || (source_preg == '0))
            source_ready = 1'b1;
        else if (alloc_bits[source_preg])
            source_ready = 1'b0;
        else if (writeback_bits[source_preg])
            source_ready = 1'b1;
        else
            source_ready = ~busy_bits[source_preg];
    endfunction

    // ==========================================================================
    // 组合逻辑：位图更新 + 双路就绪查询
    // ==========================================================================
    // alloc_mask / writeback_mask 生成：
    //   仅当 valid=1 且 preg≠0 时才有效（p0 不产生实际事件）。
    //
    // busy_bitmap_next 公式：
    //   (busy_bitmap & ~writeback_mask) | alloc_mask
    //   语义：先清除已写回的，再置位新分配的。
    //   若同一位同时出现在 writeback_mask 和 alloc_mask 中，
    //   &= ~writeback 先清零，| alloc_mask 重新置 1 → alloc 胜出。
    //   强制 bit[0]=0（p0 永不被标记为 busy）。
    //
    // 就绪查询：双路各两个源操作数，共 4 次 source_ready 调用。
    //   输入为 query 中经过 RAT 解析的物理寄存器号。
    // ==========================================================================
    always_comb begin
        alloc_mask = '0;
        if (alloc_event.lane0.valid && (alloc_event.lane0.preg != '0))
            alloc_mask[alloc_event.lane0.preg] = 1'b1;
        if (alloc_event.lane1.valid && (alloc_event.lane1.preg != '0))
            alloc_mask[alloc_event.lane1.preg] = 1'b1;

        writeback_mask = '0;
        if (writeback_event.lane0.valid && (writeback_event.lane0.preg != '0))
            writeback_mask[writeback_event.lane0.preg] = 1'b1;
        if (writeback_event.lane1.valid && (writeback_event.lane1.preg != '0))
            writeback_mask[writeback_event.lane1.preg] = 1'b1;

        // 同拍冲突时新分配置 busy 优先，避免读取旧生命周期的写回状态。
        busy_bitmap_next    = (busy_bitmap & ~writeback_mask) | alloc_mask;
        busy_bitmap_next[0] = 1'b0;

        ready.lane0.src1_ready = source_ready(
            query.lane0.use_src1, query.lane0.prs1,
            busy_bitmap, alloc_mask, writeback_mask
        );
        ready.lane0.src2_ready = source_ready(
            query.lane0.use_src2, query.lane0.prs2,
            busy_bitmap, alloc_mask, writeback_mask
        );
        ready.lane1.src1_ready = source_ready(
            query.lane1.use_src1, query.lane1.prs1,
            busy_bitmap, alloc_mask, writeback_mask
        );
        ready.lane1.src2_ready = source_ready(
            query.lane1.use_src2, query.lane1.prs2,
            busy_bitmap, alloc_mask, writeback_mask
        );
    end

    // ==========================================================================
    // 时序逻辑：busy_bitmap 寄存 + 恢复
    // ==========================================================================
    // 复位/恢复时整体清零。正常时寄存 busy_bitmap_next。
    // ==========================================================================
    always_ff @(posedge clk) begin
        if (!rst_n || recover.valid)
            busy_bitmap <= '0;
        else
            busy_bitmap <= busy_bitmap_next;
    end

    assign busy_bitmap_o = busy_bitmap;

endmodule
