// =============================================================================
// Free List —— 物理寄存器空闲列表管理
// =============================================================================
// 【模块角色】
//   管理 64 个物理寄存器的分配、回收与恢复。采用 64-bit 位图表示空闲状态，
//   bit=1 表示空闲可分配，bit=0 表示已占用。bit[0]（p0/x0）永不可分配。
//
// 【核心设计决策】
//   1. 双路级联优先编码：先为 lane0 选空闲寄存器，临时屏蔽，再为 lane1 选。
//      保证两条指令不会分到同一个物理标签。
//   2. alloc_req 与 alloc_fire 分离：请求只查询候选标签，fire 才真正消耗。
//      这允许 Rename 级在判断下游可接收后才正式分配。
//   3. 本拍回收、下拍分配：commit 回收的标签写入 free_bitmap_next，
//      到下一拍才进入 free_bitmap（寄存状态），割断 commit→优先编码器的长组合路径。
//   4. 恢复不保存快照：恢复时根据 RRAT 的 live mask 反推 free_bitmap，
//      避免额外保存每拍的历史位图。
//
// 【状态更新公式】
//   free_bitmap_next = (free_bitmap | free_mask) & ~alloc_mask
//   其中 free_mask  来自 ROB 顺序提交回收（最多 2 个）
//         alloc_mask 来自本拍 fired 的分配（最多 2 个）
//   两者冲突时 alloc 优先（&= ~alloc_mask 在 | free_mask 之后生效）。
//
// 【审阅结论】✅ 设计正确，功能完备。见 doc/free_list_rrat_busy_table_review.md。
// =============================================================================
module free_list #(
    parameter int ARCH_REG_COUNT = core_port_pkg::ARCH_REG_COUNT,
    parameter int PHYS_REG_COUNT = core_port_pkg::PHYS_REG_COUNT,
    parameter int PHYS_REG_WIDTH = $clog2(PHYS_REG_COUNT)
) (
    input  logic                                  clk,
    input  logic                                  rst_n,

    // ---- Rename 分配接口 ----
    // alloc_req: 本拍 lane0/lane1 是否申请物理寄存器（由 Rename 级根据 rd_wen 决定）
    // alloc_valid: Free List 是否能为该 lane 提供空闲寄存器
    // alloc_preg: 分配到的物理寄存器号（组合输出，本拍有效）
    // alloc_fire: Rename 级确认本拍该 lane 成功进入 renamed FIFO，正式消耗标签
    input  logic [1:0]                            alloc_req,
    output logic [1:0]                            alloc_valid,
    output core_port_pkg::phys_reg_pair_t         alloc_preg,
    input  logic [1:0]                            alloc_fire,

    // ---- 提交回收接口 ----
    // free_event: ROB 顺序提交时送出 stale_pdst（被新映射替换的旧物理寄存器号）。
    // lane0 的提交先于 lane1（程序序）。preg=0 表示无有效回收（如目标为 x0）。
    // 【关键时序】本拍回收的标签通过 free_mask 进入 free_bitmap_next，
    // 下一拍才在 free_bitmap 中可见——即"回收延迟一拍"。
    input  wire core_port_pkg::phys_reg_event_bundle_t free_event,

    // ---- 恢复接口 ----
    // recover: 全局恢复事件（分支误预测到达 ROB 头 / 异常 / 中断）
    // recover_used_mask: 由 rat_rrat 模块根据 RRAT_next 生成，
    //   标记所有已提交映射占用的物理寄存器。Free List 据此反推空闲位图。
    input  wire core_port_pkg::recover_event_t     recover,
    input  logic [PHYS_REG_COUNT-1:0]             recover_used_mask,

    // ---- 状态观测 ----
    // free_bitmap_o: 当前空闲位图（组合输出，用于外部监测/调试）
    // free_count_o: 当前空闲物理寄存器数量（不含 p0）
    output logic [PHYS_REG_COUNT-1:0]             free_bitmap_o,
    output logic [$clog2(PHYS_REG_COUNT+1)-1:0]   free_count_o
);
    // ── 内部状态 ──
    logic [PHYS_REG_COUNT-1:0] free_bitmap;          // 当前拍空闲位图（寄存输出）
    logic [PHYS_REG_COUNT-1:0] alloc_search_bitmap;  // 级联编码的搜索位图（lane0 分配后临时屏蔽）
    logic [PHYS_REG_COUNT-1:0] alloc_mask;            // 本拍分配消耗的位图（组合）
    logic [PHYS_REG_COUNT-1:0] free_mask;             // 本拍提交回收的位图（组合）
    logic [PHYS_REG_COUNT-1:0] free_bitmap_next;      // 下一拍空闲位图（组合计算，寄存输入）

    integer lane;
    integer search_preg;
    integer count_idx;
    integer reset_preg;
    logic   found;

    // ==========================================================================
    // 组合逻辑 1：双路级联优先编码分配
    // ==========================================================================
    // 从 free_bitmap（寄存状态）中按 lane0→lane1 顺序搜索空闲寄存器。
    // lane0 选中后立即在 alloc_search_bitmap 中屏蔽该位，lane1 只能从剩余位中选。
    // 搜索从索引 1 开始（跳过 p0），保证 p0 永不被分配。
    //
    // 综合工具可能将该循环实现为优先链或分层优先树；实际关键路径必须以目标
    // 器件的综合/布局布线报告为准，不能仅根据循环项数推断。
    // ==========================================================================
    always_comb begin
        alloc_valid         = '0;
        alloc_preg          = '0;
        alloc_search_bitmap = free_bitmap;

        // 级联优先编码，保证两个请求不会拿到同一个标签。
        for (lane = 0; lane < 2; lane = lane + 1) begin
            found = 1'b0;
            if (alloc_req[lane]) begin
                for (search_preg = 1; search_preg < PHYS_REG_COUNT;
                     search_preg = search_preg + 1) begin
                    if (!found && alloc_search_bitmap[search_preg]) begin
                        alloc_valid[lane] = 1'b1;
                        if (lane == 0)
                            alloc_preg.lane0 = PHYS_REG_WIDTH'(search_preg);
                        else
                            alloc_preg.lane1 = PHYS_REG_WIDTH'(search_preg);
                        alloc_search_bitmap[search_preg] = 1'b0;
                        found = 1'b1;
                    end
                end
            end
        end
    end

    // ==========================================================================
    // 组合逻辑 2：位图更新计算
    // ==========================================================================
    // alloc_mask: 仅当 alloc_fire=1 且本拍确实分配到了有效标签时才消耗。
    //   若 alloc_req=1 但 alloc_fire=0（下游停顿导致未进入 FIFO），不消耗。
    // free_mask:  仅当提交端口 valid=1 且 preg≠0（p0 不属于可回收资源）时回收。
    //
    // free_bitmap_next 公式：
    //   (free_bitmap | free_mask) & ~alloc_mask
    // 同标签冲突时，& ~alloc_mask 后于 | free_mask 生效 → alloc 优先。
    // 正常使用时不会出现同标签冲突（分配的标签必然在位图中为 1，
    // 回收的标签必然在位图中为 0，两者集合不相交）。
    // ==========================================================================
    always_comb begin
        alloc_mask = '0;
        if (alloc_fire[0] && alloc_valid[0])
            alloc_mask[alloc_preg.lane0] = 1'b1;
        if (alloc_fire[1] && alloc_valid[1])
            alloc_mask[alloc_preg.lane1] = 1'b1;

        free_mask = '0;
        if (free_event.lane0.valid && (free_event.lane0.preg != '0))
            free_mask[free_event.lane0.preg] = 1'b1;
        if (free_event.lane1.valid && (free_event.lane1.preg != '0))
            free_mask[free_event.lane1.preg] = 1'b1;

        // 同标签冲突时分配优先；正常设计中待分配标签不会来自本拍 free_mask。
        free_bitmap_next    = (free_bitmap | free_mask) & ~alloc_mask;
        free_bitmap_next[0] = 1'b0;
    end

    // ==========================================================================
    // 组合逻辑 3：空闲计数（用于监测和反压判断）
    // ==========================================================================
    // 统计 free_bitmap 中 bit=1 的数量（不含 p0）。
    // 综合通常形成加法树；该调试计数不参与 alloc_valid 决策。
    // Rename 级可据此判断是否还有物理寄存器可供分配。
    // ==========================================================================
    always_comb begin
        free_count_o = '0;
        for (count_idx = 1; count_idx < PHYS_REG_COUNT; count_idx = count_idx + 1)
            free_count_o = free_count_o + free_bitmap[count_idx];
    end

    // ==========================================================================
    // 时序逻辑：状态寄存与恢复
    // ==========================================================================
    // 复位：p0..p31 已占用（映射到 x0..x31），p32..p63 空闲可分配。
    //       这符合方案中的初始映射 xN→pN。
    // 恢复：recover.valid 优先级高于正常更新。使用 recover_used_mask 反推
    //       空闲位图：free = ~used，并强制 bit[0]=0。
    //       注意 recover_used_mask 由 rat_rrat 根据已应用本拍提交的 RRAT_next
    //       生成，满足方案中"恢复与提交同拍时使用 RRAT_next"的要求。
    // 正常：寄存 free_bitmap_next。
    // ==========================================================================
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            free_bitmap <= '0;
            for (reset_preg = ARCH_REG_COUNT; reset_preg < PHYS_REG_COUNT;
                 reset_preg = reset_preg + 1)
                free_bitmap[reset_preg] <= 1'b1;
        end else if (recover.valid) begin
            free_bitmap    <= ~recover_used_mask;
            free_bitmap[0] <= 1'b0;
        end else begin
            free_bitmap <= free_bitmap_next;
        end
    end

    assign free_bitmap_o = free_bitmap;

endmodule
