// =============================================================================
// Rename Stage —— 双发射寄存器重命名与弹性缓冲
// =============================================================================
// 【模块角色】
//   Rename 级是前端（IF/ID）与乱序后端（Dispatch/ROB/IQ/LSQ）之间的关键桥梁。
//   核心职责：将架构寄存器号（rs1/rs2/rd）转换为物理寄存器号（prs1/prs2/pdst），
//   并在 renaming 完成时将结果锁存到参数化的输出 FIFO 中。
//
// 【架构总览】
//   输入侧：main + skid 双槽弹性缓冲，rn_allowin 寄存输出
//   核心：候选提取 → Free List 分配 → RAT 查询/旁路 → Busy Table 就绪 → 组包
//   输出侧：参数化深度的 renamed FIFO，双槽前缀 valid/ready 接口
//
// 【关键数据流（全组合路径，单周期完成）】
//   main_bundle(reg) → 候选压缩 → rat_req → RAT 查询 → rat_rsp
//   → busy_query → Busy Table 就绪判断 → renamed0/1 → FIFO 写入
//   总组合路径包含 RAT 查询、Busy Table 查询和 Free List 优先编码；是否满足
//   目标频率必须以综合和布局布线报告为准，必要时可在后续版本中继续流水化。
//
// 【状态更新边界】
//   rename_fire = 指令成功进入 renamed FIFO。只有 fire 时：
//     - Free List 消耗物理寄存器（alloc_fire）
//     - RAT 更新推测映射（rename_fire & pdst_valid）
//     - Busy Table 置位（alloc_event）
//   Dispatch 停顿仅让结果停留在 FIFO 中，不会重复分配。
//
// 【审阅结论】✅ 设计正确，架构完整。详见 doc/rename_stage_review.md。
// =============================================================================
module rename_stage #(
    parameter int ARCH_REG_COUNT     = core_port_pkg::ARCH_REG_COUNT,
    parameter int PHYS_REG_COUNT     = core_port_pkg::PHYS_REG_COUNT,
    parameter int RENAME_FIFO_DEPTH  = 2                         // 参数化，默认深 2
) (
    input  logic                                  clk,
    input  logic                                  rst_n,

    // ---- ID → Rename 输入接口 ----
    // ds_to_rn_valid / rn_allowin：标准 valid-ready 握手，allowin 寄存输出
    // ds_to_rn_bus：typed struct 双路译码包（ds_rn_bundle_t）
    input  logic                                  ds_to_rn_valid,
    output logic                                  rn_allowin,
    input  wire core_port_pkg::ds_rn_bundle_t     ds_to_rn_bus,

    // ---- Rename → Dispatch 输出接口 ----
    // rn_to_dp_valid / dp_ready：双槽前缀 valid/ready
    //   约束：valid[1] → valid[0]（slot1 有效必然要求 slot0 有效）
    //        fire[1]  → fire[0]（slot1 只能随 slot0 同拍被接收）
    // rn_to_dp_bus：rn_dp_bundle_t，含完整 rename_uop_t
    output logic [1:0]                            rn_to_dp_valid,
    input  logic [1:0]                            dp_ready,
    output core_port_pkg::rn_dp_bundle_t           rn_to_dp_bus,

    // ---- 后端回传信号 ----
    // commit_map：ROB 顺序提交端口，携带 stale_pdst 供 Free List 回收
    // writeback_event：执行写回端口，供 Busy Table 清除 busy 位
    input  wire core_port_pkg::commit_map_bundle_t commit_map,
    input  wire core_port_pkg::phys_reg_event_bundle_t writeback_event,

    // ---- 全局恢复 ----
    // recover：分支误预测/异常/中断的共享恢复信道
    //   优先级高于所有正常操作，清空两侧 buffer 并触发三个子模块自恢复
    input  wire core_port_pkg::recover_event_t     recover
);
    import core_port_pkg::*;

    localparam int FIFO_COUNT_WIDTH = $clog2(RENAME_FIFO_DEPTH + 1);

    // ══════════════════════════════════════════════════════════════════════════
    // 第一部分：ID 输入弹性缓冲（main + skid + registered allowin）
    // ══════════════════════════════════════════════════════════════════════════
    // 经典双槽缓冲模式，与 id_stage 保持一致：
    //   - main_valid/main_bundle：主槽，当前正在处理的译码包
    //   - skid_valid/skid_bundle：溢出槽，吸收 main 满时的额外输入
    //   - rn_allowin_r：寄存输出 → 割断 ID↔Rename 组合反压链
    //
    // 反压语义：
    //   rn_allowin_next = ~skid_valid_next
    //   即：如果 skid 即将被占用（下一拍），则本拍不接收 ID 数据。
    //   寄存输出的 allowin 有一拍反馈延迟——这是标准做法，避免了
    //   跨级组合 ready 链。代价是 main+skid 都满时会有一拍气泡。
    // ══════════════════════════════════════════════════════════════════════════
    logic          main_valid;
    logic          main_valid_next;
    logic          skid_valid;
    logic          skid_valid_next;
    logic          rn_allowin_r;
    logic          rn_allowin_next;
    logic          ds_push;
    ds_rn_bundle_t main_bundle;
    ds_rn_bundle_t main_bundle_next;
    ds_rn_bundle_t skid_bundle;
    ds_rn_bundle_t skid_bundle_next;

    // 当前 main bundle 去掉无效/flush 槽后的程序序候选。
    // 候选提取时完成两步操作：
    //   ① 丢弃 valid=0 的槽（IF NOP、软件 NOP）
    //   ② 丢弃 flush=1 的槽（flush 在 Rename 边界终结，不进后端）
    //   ③ 程序序压紧：若 lane0 被丢弃，原 lane1 提升为 candidate0
    ds_rn_slot_t candidate0;
    ds_rn_slot_t candidate1;
    logic [1:0]  candidate_count;
    ds_rn_bundle_t remaining_bundle;
    logic [1:0]  remaining_count;

    // ══════════════════════════════════════════════════════════════════════════
    // 第二部分：参数化 renamed FIFO
    // ══════════════════════════════════════════════════════════════════════════
    // 深度可参数化（默认 2），存储已分配好物理标签的 rename_uop_t。
    // 调度策略：移位寄存器式 FIFO——出队后保留项前移，入队在尾部追加。
    // 约束：FIFO 深 2 是硬下限，通过 $fatal 在编译时检查。
    // ══════════════════════════════════════════════════════════════════════════
    rn_dp_slot_t renamed_fifo      [0:RENAME_FIFO_DEPTH-1];
    rn_dp_slot_t renamed_fifo_next [0:RENAME_FIFO_DEPTH-1];
    logic [FIFO_COUNT_WIDTH-1:0] fifo_count;
    logic [FIFO_COUNT_WIDTH-1:0] fifo_count_next;
    integer dequeue_count;
    integer enqueue_count;
    integer retained_count;
    integer fifo_available;
    integer fifo_comb_idx;
    integer fifo_state_idx;

    // 已完成重命名但因 Dispatch/串行边界滞留在 FIFO 中的 uop 也必须监听
    // 写回。否则源寄存器可能在等待期间完成，等 uop 后续进入 IQ 时已经错过
    // CDB 脉冲，却仍携带旧的 src_ready=0，造成永久等待。
    function automatic logic fifo_wakeup_match(input phys_reg_idx_t preg);
        fifo_wakeup_match = (preg != '0)
                         && ((writeback_event.lane0.valid
                              && (writeback_event.lane0.preg == preg))
                             || (writeback_event.lane1.valid
                                 && (writeback_event.lane1.preg == preg)));
    endfunction

    rn_dp_slot_t renamed0;
    rn_dp_slot_t renamed1;

    // ══════════════════════════════════════════════════════════════════════════
    // 第三部分：三个子模块之间的 typed control bundle
    // ══════════════════════════════════════════════════════════════════════════
    // 所有级间信号使用 core_port_pkg 中定义的 packed struct，无手工位宽切片。
    // 关键时序对齐：
    //   - rename_fire, alloc_fire, alloc_event 必须是同一拍的组合信号
    //   - 三个子模块的寄存器在同一 posedge 更新
    //   - recover 信号同时广播给三个子模块
    // ══════════════════════════════════════════════════════════════════════════
    logic [1:0]             alloc_req;
    logic [1:0]             alloc_valid;
    logic [1:0]             alloc_fire;
    phys_reg_pair_t         alloc_preg;
    commit_map_bundle_t     commit_map_q;
    phys_reg_event_bundle_t free_event;
    logic [PHYS_REG_COUNT-1:0] free_bitmap_unused;
    logic [$clog2(PHYS_REG_COUNT+1)-1:0] free_count_unused;

    rat_rename_req_bundle_t rat_req;
    rat_rename_rsp_bundle_t rat_rsp;
    logic [1:0]             rename_fire;
    logic [PHYS_REG_COUNT-1:0] recover_used_mask;

    busy_query_bundle_t     busy_query;
    busy_ready_bundle_t     busy_ready;
    phys_reg_event_bundle_t alloc_event;
    logic [PHYS_REG_COUNT-1:0] busy_bitmap_unused;

    // ── 编译期断言：FIFO 深度至少为 2 ──
    initial begin
        if (RENAME_FIFO_DEPTH < 2)
            $fatal(1, "RENAME_FIFO_DEPTH must be at least 2");
    end

    assign rn_allowin = rn_allowin_r;
    assign ds_push    = ds_to_rn_valid & rn_allowin_r;

    // ==========================================================================
    // 组合逻辑块 A：输出 FIFO 的双路前缀 valid/ready
    // ==========================================================================
    // 前缀约束实现：
    //   - rn_to_dp_valid[0] 仅当 fifo_count ≠ 0（FIFO 非空）
    //   - rn_to_dp_valid[1] 仅当 fifo_count ≥ 2（至少两项，且 slot0 有效）
    //   → 自然满足 valid[1] → valid[0] 的蕴含关系
    //
    // dequeue_count 计算：
    //   - 仅当 slot0 被接收（valid[0] & ready[0]）才考虑 slot1
    //   - 这满足 fire[1] → fire[0] 的前缀约束
    //
    // fifo_available 含义：
    //   "本拍 dequeue 完毕后、enqueue 之前，FIFO 中的空位数"
    //   = depth - count + dequeue_count
    //   用于判断是否还有空间接收本拍新完成的重命名结果。
    //   ⚠️ fifo_available 仅依赖于 fifo_count（寄存）和 dp_ready（输入），
    //   不依赖于 rename_fire，不存在组合环路。
    // ==========================================================================
    always_comb begin
        rn_to_dp_valid = '0;
        rn_to_dp_bus   = '0;

        if (fifo_count != 0) begin
            rn_to_dp_valid[0]  = 1'b1;
            rn_to_dp_bus.lane0 = renamed_fifo[0];
        end
        if (fifo_count >= 2) begin
            rn_to_dp_valid[1]  = 1'b1;
            rn_to_dp_bus.lane1 = renamed_fifo[1];
        end

        dequeue_count = 0;
        if (rn_to_dp_valid[0] && dp_ready[0]) begin
            dequeue_count = 1;
            if (rn_to_dp_valid[1] && dp_ready[1])
                dequeue_count = 2;
        end

        fifo_available = RENAME_FIFO_DEPTH - fifo_count + dequeue_count;
    end

    // ==========================================================================
    // 组合逻辑块 B：候选提取与压缩
    // ==========================================================================
    // 从 main bundle 中提取有效且非 flush 的指令槽，按程序序压紧。
    //
    // 【flush 丢弃语义】
    //   方案规定：Rename 成为 flushed 指令进入乱序后端前的最终丢弃边界。
    //   main_bundle.laneX.flush=1 的槽不成为 candidate，不分配物理寄存器，
    //   不进入 renamed FIFO，不向后端传播。错误路径指令在此终结。
    //
    // 【压缩规则】
    //   - lane0 有效且非 flush → candidate0 = lane0
    //   - lane1 有效且非 flush → 若 candidate0 空则成为 candidate0，否则 candidate1
    //   - 无效槽和 flushed 槽直接跳过
    //   - 结果：candidate0 是程序序最老的有效非 flush 指令，
    //          candidate1 是次老的（如有）
    //
    // 【与异常指令的区别】
    //   异常指令（illegal=1）：valid=1, flush=0，正常成为 candidate，
    //   正常分配物理寄存器，正常进入后端。精确异常在 ROB 提交时处理。
    //   只有 flush=1 的指令（分支误预测路径上的指令）才在此丢弃。
    // ==========================================================================
    always_comb begin
        candidate0     = '0;
        candidate1     = '0;
        candidate_count = 0;

        if (main_valid && main_bundle.lane0.valid && !main_bundle.lane0.flush) begin
            candidate0      = main_bundle.lane0;
            candidate_count = 1;
        end

        if (main_valid && main_bundle.lane1.valid && !main_bundle.lane1.flush) begin
            if (candidate_count == 0)
                candidate0 = main_bundle.lane1;
            else
                candidate1 = main_bundle.lane1;
            candidate_count = candidate_count + 1'b1;
        end
    end

    // ==========================================================================
    // 组合逻辑块 C：资源请求与部分推进决策
    // ==========================================================================
    // 【alloc_req 生成】
    //   仅当指令写目标寄存器（rd_wen=1 且 rd≠0）时才申请物理寄存器。
    //   写 x0、无目标指令、分支指令不申请。
    //
    // 【rename_fire 决策——部分推进的核心】
    //   条件 1：有候选指令（candidate_count ≥ 1/2）
    //   条件 2：FIFO 有足够空间（fifo_available ≥ 1/2）
    //   条件 3：若需分配物理寄存器，Free List 必须有货（alloc_valid=1）
    //
    //   部分推进场景：
    //   - FIFO 空间只够 1 条 → 仅 rename_fire[0]=1
    //   - Free List 只剩 1 个 → 若 lane0 需要而 lane1 也需要 → 仅 fire[0]
    //   - 任何情况下 lane1 不能单独 fire（前缀约束）
    //
    // 【alloc_fire vs rename_fire】
    //   alloc_fire = rename_fire & alloc_req
    //   即：指令成功进入 FIFO 且确实申请了物理寄存器 → 才消耗 Free List
    //   不写目标的指令（如分支）：rename_fire=1 但 alloc_fire=0
    //   → Free List 不消耗，Busy Table 不置位，RAT 不更新
    // ==========================================================================
    always_comb begin
        alloc_req[0] = (candidate_count >= 1)
                     && candidate0.rd_wen && (candidate0.rd != '0);
        alloc_req[1] = (candidate_count >= 2)
                     && candidate1.rd_wen && (candidate1.rd != '0);

        rename_fire = '0;
        if ((candidate_count >= 1) && (fifo_available >= 1)
            && (!alloc_req[0] || alloc_valid[0])) begin
            rename_fire[0] = 1'b1;

            if ((candidate_count >= 2) && (fifo_available >= 2)
                && (!alloc_req[1] || alloc_valid[1]))
                rename_fire[1] = 1'b1;
        end

        enqueue_count = rename_fire[0] + rename_fire[1];
        alloc_fire[0] = rename_fire[0] & alloc_req[0];
        alloc_fire[1] = rename_fire[1] & alloc_req[1];
    end

    // ==========================================================================
    // 组合逻辑块 D：三个子模块的控制包构建
    // ==========================================================================
    // 本块从候选指令和 Free List 分配结果出发，构建：
    //   - rat_req：送往 RAT/RRAT 的查询请求
    //   - alloc_event：送往 Busy Table 的分配事件
    //   - free_event：从寄存后的 commit_map_q 提取回收事件，送 Free List
    //   - busy_query：送往 Busy Table 的就绪查询
    //
    // 【关键数据依赖】
    //   rat_req → rat_rsp（RAT 组合查询结果）
    //   busy_query 依赖 rat_rsp（源物理寄存器号来自 RAT 解析）
    //   → 组合路径：candidate → RAT → Busy Table
    //
    // 【free_event 数据流】
    //   commit_map_q.stale_pdst（ROB 提交后一拍携带）
    //   → free_event.preg → Free List free_mask
    //   → free_bitmap_next = (free_bitmap | free_mask) & ~alloc_mask
    //   注意：commit_map_q 中的 stale_pdst 来自 ROB 条目中保存的 rename 时刻快照。
    //   这里打一拍后再转发，切断 ROB/commit 控制到 Free List 位图 D 端的长路径；
    //   recover 同样已在 writeback_commit_stage 中寄存，因此恢复使用的 RRAT_next
    //   与 commit_map_q 自然对齐。
    // ==========================================================================
    always_comb begin
        rat_req = '0;

        rat_req.lane0.use_rs1    = candidate0.use_rs1;
        rat_req.lane0.use_rs2    = candidate0.use_rs2;
        rat_req.lane0.rs1        = candidate0.rs1;
        rat_req.lane0.rs2        = candidate0.rs2;
        rat_req.lane0.rd         = candidate0.rd;
        rat_req.lane0.pdst_valid = alloc_req[0] & alloc_valid[0];
        rat_req.lane0.pdst       = alloc_preg.lane0;

        rat_req.lane1.use_rs1    = candidate1.use_rs1;
        rat_req.lane1.use_rs2    = candidate1.use_rs2;
        rat_req.lane1.rs1        = candidate1.rs1;
        rat_req.lane1.rs2        = candidate1.rs2;
        rat_req.lane1.rd         = candidate1.rd;
        rat_req.lane1.pdst_valid = alloc_req[1] & alloc_valid[1];
        rat_req.lane1.pdst       = alloc_preg.lane1;

        alloc_event = '0;
        alloc_event.lane0.valid = alloc_fire[0];
        alloc_event.lane0.preg  = alloc_preg.lane0;
        alloc_event.lane1.valid = alloc_fire[1];
        alloc_event.lane1.preg  = alloc_preg.lane1;

        free_event = '0;
        free_event.lane0.valid = commit_map_q.lane0.valid
                               && (commit_map_q.lane0.stale_pdst != '0);
        free_event.lane0.preg  = commit_map_q.lane0.stale_pdst;
        free_event.lane1.valid = commit_map_q.lane1.valid
                               && (commit_map_q.lane1.stale_pdst != '0);
        free_event.lane1.preg  = commit_map_q.lane1.stale_pdst;

        busy_query = '0;
        busy_query.lane0.use_src1 = candidate0.use_rs1;
        busy_query.lane0.use_src2 = candidate0.use_rs2;
        busy_query.lane0.prs1     = rat_rsp.lane0.prs1;
        busy_query.lane0.prs2     = rat_rsp.lane0.prs2;
        busy_query.lane1.use_src1 = candidate1.use_rs1;
        busy_query.lane1.use_src2 = candidate1.use_rs2;
        busy_query.lane1.prs1     = rat_rsp.lane1.prs1;
        busy_query.lane1.prs2     = rat_rsp.lane1.prs2;
    end

    // ==========================================================================
    // 组合逻辑块 E：renamed uop 组包
    // ==========================================================================
    // 将候选指令的译码信息 + RAT 解析的物理寄存器号 + Busy Table 的就绪状态
    // + Free List 分配的新目标号，组合为完整的 rename_uop_t（即 rn_dp_slot_t）。
    //
    // 【pdst / stale_pdst 的条件赋值】
    //   仅当 alloc_fire=1（指令确实 fire 且确实分配）时，pdst 和 stale_pdst 才有效。
    //   否则为 0。下游通过 pdst_valid 区分：
    //     pdst_valid=1 → 该指令获得了新物理寄存器，pdst/stale_pdst 有效
    //     pdst_valid=0 → 该指令不写目标（分支/存储/写 x0），忽略 pdst/stale_pdst
    //
    // 【src_ready 含义】
    //   这是重命名时刻的 Busy Table 快照，告诉 IQ 该指令在进入后端时的源就绪状态。
    //   后续 IQ 需要自行监听写回总线（CDB）以更新内部 wakeup 状态。
    //   这里的 src_ready 只是初始值，可能从 ready 变为 not-ready 吗？
    //   → 不会。Busy Table 只从 busy→ready（写回清 0），不会从 ready→busy。
    //   所以初始 ready=1 意味着结果一定可用；ready=0 需要等待 CDB 唤醒。
    // ==========================================================================
    // 完整重命名结果仅在 rename_fire 对应 lane 为 1 时写入 FIFO。
    always_comb begin
        renamed0 = '0;
        renamed0.dec         = candidate0;
        renamed0.prs1        = rat_rsp.lane0.prs1;
        renamed0.prs2        = rat_rsp.lane0.prs2;
        renamed0.pdst        = alloc_fire[0] ? alloc_preg.lane0 : '0;
        renamed0.stale_pdst  = alloc_fire[0] ? rat_rsp.lane0.stale_pdst : '0;
        renamed0.src1_ready  = busy_ready.lane0.src1_ready;
        renamed0.src2_ready  = busy_ready.lane0.src2_ready;
        renamed0.pdst_valid  = alloc_fire[0];

        renamed1 = '0;
        renamed1.dec         = candidate1;
        renamed1.prs1        = rat_rsp.lane1.prs1;
        renamed1.prs2        = rat_rsp.lane1.prs2;
        renamed1.pdst        = alloc_fire[1] ? alloc_preg.lane1 : '0;
        renamed1.stale_pdst  = alloc_fire[1] ? rat_rsp.lane1.stale_pdst : '0;
        renamed1.src1_ready  = busy_ready.lane1.src1_ready;
        renamed1.src2_ready  = busy_ready.lane1.src2_ready;
        renamed1.pdst_valid  = alloc_fire[1];
    end

    // ==========================================================================
    // 组合逻辑块 F：部分推进后的残量 + main/skid 管理
    // ==========================================================================
    // 本块实现三步状态管理（在同一 always_comb 中，按代码序解析）：
    //
    // 【第 1 步：残量计算】
    //   如果所有候选都 fire 了（enqueue_count = candidate_count）
    //     → remaining_count = 0，main 变空
    //   如果仅 lane0 fire（enqueue_count = 1, candidate_count = 2）
    //     → remaining_bundle.lane0 = candidate1（原 lane1 挤压到 lane0 位置）
    //   如果都没 fire（enqueue_count = 0）
    //     → remaining_bundle 保留全部原始候选
    //
    // 【第 2 步：skid → main 提升】
    //   当 main 变空（remaining_count=0）且 skid 有数据时，
    //   skid 内容提升到 main，skid 清空。
    //   这确保 skid 中等待的指令尽快进入处理流水线。
    //
    // 【第 3 步：ID 新数据接收】
    //   ds_push = ds_to_rn_valid & rn_allowin_r
    //   若 main 空 → 直接进 main
    //   若 main 占 → 进 skid（前提是 skid 空；若 skid 也占，rn_allowin_r=0 阻止推送）
    //
    // 【rn_allowin 生成】
    //   rn_allowin_next = ~skid_valid_next
    //   含义：只有 skid 槽空闲时，才允许 ID 写入。
    //   寄存输出 → 割断 ID→Rename→Dispatch 的组合反压链
    // ==========================================================================
    always_comb begin
        remaining_bundle = '0;
        remaining_count  = candidate_count - enqueue_count;

        if (enqueue_count == 0) begin
            if (candidate_count >= 1)
                remaining_bundle.lane0 = candidate0;
            if (candidate_count >= 2)
                remaining_bundle.lane1 = candidate1;
        end else if ((enqueue_count == 1) && (candidate_count >= 2)) begin
            remaining_bundle.lane0 = candidate1;
        end

        main_valid_next  = main_valid;
        skid_valid_next  = skid_valid;
        main_bundle_next = main_bundle;
        skid_bundle_next = skid_bundle;

        if (main_valid) begin
            if (remaining_count == 0) begin
                main_valid_next  = 1'b0;
                main_bundle_next = '0;
            end else begin
                main_valid_next  = 1'b1;
                main_bundle_next = remaining_bundle;
            end
        end

        // main 完成后优先提升已等待的 skid bundle。
        if (!main_valid_next && skid_valid_next) begin
            main_valid_next  = 1'b1;
            main_bundle_next = skid_bundle_next;
            skid_valid_next  = 1'b0;
            skid_bundle_next = '0;
        end

        // 使用上一拍寄存的 rn_allowin 接收 ID 数据；两项缓冲吸收反馈延迟。
        if (ds_push) begin
            if (!main_valid_next) begin
                main_valid_next  = 1'b1;
                main_bundle_next = ds_to_rn_bus;
            end else begin
                skid_valid_next  = 1'b1;
                skid_bundle_next = ds_to_rn_bus;
            end
        end

        rn_allowin_next = ~skid_valid_next;
    end

    // ==========================================================================
    // 组合逻辑块 G：renamed FIFO 移位管理
    // ==========================================================================
    // 移位寄存器式 FIFO 操作：
    //   1. 出队：从头部移除 dequeue_count 项
    //   2. 压缩：保留项（retained_count = count - dequeue）向头部平移
    //   3. 入队：新项（renamed0/renamed1）追加到保留项之后
    //
    // 【写入顺序】
    //   renamed0 先写（程序序 lane0），renamed1 后写。
    //   若仅 fire lane0：写入位置 = retained_count
    //   若双 fire：lane0 写入 retained_count，lane1 写入 retained_count+1
    //
    // 【溢出保护】
    //   入队前已通过 fifo_available ≥ enqueue_count 保证空间充足，
    //   不会出现写入越界。
    // ==========================================================================
    always_comb begin
        for (fifo_comb_idx = 0; fifo_comb_idx < RENAME_FIFO_DEPTH;
             fifo_comb_idx = fifo_comb_idx + 1)
            renamed_fifo_next[fifo_comb_idx] = '0;

        retained_count = fifo_count - dequeue_count;
        for (fifo_comb_idx = 0; fifo_comb_idx < RENAME_FIFO_DEPTH;
             fifo_comb_idx = fifo_comb_idx + 1) begin
            if (fifo_comb_idx < retained_count) begin
                renamed_fifo_next[fifo_comb_idx]
                    = renamed_fifo[fifo_comb_idx + dequeue_count];
                if (fifo_wakeup_match(
                    renamed_fifo[fifo_comb_idx + dequeue_count].prs1))
                    renamed_fifo_next[fifo_comb_idx].src1_ready = 1'b1;
                if (fifo_wakeup_match(
                    renamed_fifo[fifo_comb_idx + dequeue_count].prs2))
                    renamed_fifo_next[fifo_comb_idx].src2_ready = 1'b1;
            end
        end

        if (rename_fire[0])
            renamed_fifo_next[retained_count] = renamed0;
        if (rename_fire[1])
            renamed_fifo_next[retained_count + rename_fire[0]] = renamed1;

        fifo_count_next = FIFO_COUNT_WIDTH'(retained_count + enqueue_count);
    end

    // ==========================================================================
    // 时序逻辑：输入缓冲 + 输出 FIFO 寄存
    // ==========================================================================
    // 【恢复优先级】
    //   恢复事件（recover.valid=1）时：
    //   - main/skid 清空（输入侧）
    //   - renamed FIFO 清空（输出侧）
    //   - rn_allowin_r 置 1（下一拍允许 ID 输入）
    //   三个子模块各自通过 recover 端口同步恢复内部状态。
    //
    //   恢复后下一拍：
    //   - main_valid=0, skid_valid=0, fifo_count=0
    //   - rn_allowin_r=1 → ID 可以推送新数据
    //   - 三个子模块状态已回滚到已提交状态
    //
    // 【两个 always_ff 块的原因】
    //   输入缓冲和输出 FIFO 的复位/恢复逻辑相同但数据路径独立，
    //   分为两个块便于综合优化，也便于未来修改其中之一而不影响另一个。
    // ==========================================================================
    // 状态寄存。recover 清空两侧 buffer，三个子模块各自恢复内部状态。
    always_ff @(posedge clk) begin
        if (!rst_n || recover.valid) begin
            main_valid   <= 1'b0;
            skid_valid   <= 1'b0;
            rn_allowin_r <= 1'b1;
            main_bundle  <= '0;
            skid_bundle  <= '0;
        end else begin
            main_valid   <= main_valid_next;
            skid_valid   <= skid_valid_next;
            rn_allowin_r <= rn_allowin_next;
            main_bundle  <= main_bundle_next;
            skid_bundle  <= skid_bundle_next;
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n || recover.valid) begin
            fifo_count <= '0;
            for (fifo_state_idx = 0; fifo_state_idx < RENAME_FIFO_DEPTH;
                 fifo_state_idx = fifo_state_idx + 1)
                renamed_fifo[fifo_state_idx] <= '0;
        end else begin
            fifo_count <= fifo_count_next;
            for (fifo_state_idx = 0; fifo_state_idx < RENAME_FIFO_DEPTH;
                 fifo_state_idx = fifo_state_idx + 1)
                renamed_fifo[fifo_state_idx] <= renamed_fifo_next[fifo_state_idx];
        end
    end

    // 提交 side-effect 事件包打一拍：RRAT 更新与 stale pdst 回收都消费
    // commit_map_q，避免 ROB head/commit gating 直接穿透到 Rename/Free List。
    always_ff @(posedge clk) begin
        if (!rst_n || recover.valid)
            commit_map_q <= '0;
        else
            commit_map_q <= commit_map;
    end

    // ==========================================================================
    // 子模块例化
    // ==========================================================================
    // 三个独立模块通过 typed struct 端口连接，接口已在 core_port_pkg 中统一定义。
    // 每个子模块接收 recover 信号并自行处理内部状态恢复。
    // 未使用的观测输出（free_bitmap_unused, free_count_unused, busy_bitmap_unused）
    // 通过显式命名标记 _unused，便于综合工具优化和代码审查。
    // ==========================================================================
    free_list #(
        .ARCH_REG_COUNT (ARCH_REG_COUNT),
        .PHYS_REG_COUNT (PHYS_REG_COUNT)
    ) u_free_list (
        .clk               (clk),
        .rst_n             (rst_n),
        .alloc_req         (alloc_req),
        .alloc_valid       (alloc_valid),
        .alloc_preg        (alloc_preg),
        .alloc_fire        (alloc_fire),
        .free_event        (free_event),
        .recover           (recover),
        .recover_used_mask (recover_used_mask),
        .free_bitmap_o     (free_bitmap_unused),
        .free_count_o      (free_count_unused)
    );

    rat_rrat #(
        .ARCH_REG_COUNT (ARCH_REG_COUNT),
        .PHYS_REG_COUNT (PHYS_REG_COUNT)
    ) u_rat_rrat (
        .clk               (clk),
        .rst_n             (rst_n),
        .rename_req        (rat_req),
        .rename_fire       (rename_fire),
        .rename_rsp        (rat_rsp),
        .commit_map        (commit_map_q),
        .recover           (recover),
        .recover_used_mask (recover_used_mask)
    );

    busy_table #(
        .PHYS_REG_COUNT (PHYS_REG_COUNT)
    ) u_busy_table (
        .clk             (clk),
        .rst_n           (rst_n),
        .query           (busy_query),
        .ready           (busy_ready),
        .alloc_event     (alloc_event),
        .writeback_event (writeback_event),
        .recover         (recover),
        .busy_bitmap_o   (busy_bitmap_unused)
    );

`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
        if (rst_n) begin
            assert (!(free_event.lane0.valid && free_event.lane1.valid
                      && (free_event.lane0.preg == free_event.lane1.preg)))
                else $error("rename_stage: duplicate stale pdst release");
        end
    end
`endif

endmodule
