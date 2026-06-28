// =============================================================================
// RAT + RRAT —— 寄存器别名表（推测映射 + 已提交映射）
// =============================================================================
// 【模块角色】
//   RAT  (Register Alias Table)：保存当前推测状态下 32 个架构寄存器的物理映射。
//         Rename 每拍查询 RAT 获得源操作数的物理寄存器号，并在指令成功进入
//         renamed FIFO 后更新 RAT。
//   RRAT (Retirement RAT)：保存已提交的映射。仅在 ROB 顺序提交时更新。
//         恢复时 RAT 直接从 RRAT 复制（不保存分支检查点）。
//
// 【核心设计决策】
//   1. RAT 与 RRAT 合并在同一模块：两者共享架构寄存器索引空间，物理上相邻，
//      合并可减少模块间连线。两者各自独立的寄存器阵列（各 32×6 bit）。
//   2. 双路组内旁路：lane0 先查询 RAT，lane1 在此基础上旁路 lane0 本拍
//      新分配的 pdst。解决双发射组内的 RAW（lane1 读 lane0 写）和
//      WAW（两路同目标寄存器）映射问题。
//   3. 恢复使用 rrat_next：组合逻辑中先计算 RRAT_next（应用本拍提交更新），
//      恢复时 RAT <= RRAT_next，Free List 也从 RRAT_next 反推 used_mask。
//      这保证了"提交与恢复同拍"时的正确性。
//   4. x0 永映射到 p0：无论是正常更新、提交还是恢复，rd=0 / rat[0] / rrat[0]
//      始终强制为 0。
//
// 【审阅结论】✅ 设计正确，功能完备。见 doc/free_list_rrat_busy_table_review.md。
// =============================================================================
module rat_rrat #(
    parameter int ARCH_REG_COUNT = core_port_pkg::ARCH_REG_COUNT,
    parameter int PHYS_REG_COUNT = core_port_pkg::PHYS_REG_COUNT,
    parameter int ARCH_REG_WIDTH = $clog2(ARCH_REG_COUNT),
    parameter int PHYS_REG_WIDTH = $clog2(PHYS_REG_COUNT)
) (
    input  logic                                      clk,
    input  logic                                      rst_n,

    // ---- Rename 查询接口 ----
    // rename_req: 双路重命名请求，包含 rs1/rs2/rd 的架构寄存器索引、
    //             pdst（Free List 分配的物理目标号）和 pdst_valid。
    // rename_fire: 本拍该 lane 是否成功进入 renamed FIFO。
    //              fire=1 时 RAT 才更新；fire=0 时仅查询不修改。
    // rename_rsp: 双路查询结果——prs1/prs2（源物理寄存器号）和
    //             stale_pdst（目标架构寄存器原来的物理映射，提交后回收）。
    input  wire core_port_pkg::rat_rename_req_bundle_t rename_req,
    input  logic [1:0]                                rename_fire,
    output core_port_pkg::rat_rename_rsp_bundle_t      rename_rsp,

    // ---- 提交更新接口 ----
    // commit_map: ROB 顺序提交端口，每拍最多提交两条映射更新。
    //             lane0 的提交先于 lane1（程序序）。
    //             同拍双提交写同一 rd 时 lane1 胜出（后写覆盖）。
    input  wire core_port_pkg::commit_map_bundle_t     commit_map,

    // ---- 恢复接口 ----
    // recover: 全局恢复事件。valid=1 时 RAT <= RRAT_next。
    // recover_used_mask: 输出给 Free List，标记所有已提交映射占用的物理寄存器。
    //                    由 RRAT_next 生成（含本拍提交结果）。
    input  wire core_port_pkg::recover_event_t         recover,
    output logic [PHYS_REG_COUNT-1:0]                 recover_used_mask
);
    import core_port_pkg::*;

    // ── 内部状态：均为 32 项的 unpacked 数组，每项 6-bit ──
    phys_reg_idx_t rat  [0:ARCH_REG_COUNT-1];      // 推测映射（Rename 更新）
    phys_reg_idx_t rrat [0:ARCH_REG_COUNT-1];      // 已提交映射（ROB 提交更新）
    phys_reg_idx_t rrat_next [0:ARCH_REG_COUNT-1]; // 下一拍 RRAT = RRAT + 本拍提交

    integer rrat_idx;
    integer state_idx;

    // ==========================================================================
    // 组合逻辑 1：双路 RAT 查询 + lane0→lane1 旁路
    // ==========================================================================
    // 【查询阶段】
    //   lane0: 直接从 RAT 读取。若 use_rsX=0（指令不使用该源），返回 0。
    //          stale_pdst = RAT[rd]，即目标架构寄存器当前的物理映射。
    //   lane1: 先从 RAT 读取，然后检查是否需要旁路 lane0 本拍的新映射。
    //
    // 【旁路条件】（仅在 rename_fire[0]=1 且 lane0.pdst_valid=1 且 rd≠0 时生效）
    //   a) RAW 旁路：lane1.rs1 == lane0.rd → lane1.prs1 = lane0.pdst
    //              lane1.rs2 == lane0.rd → lane1.prs2 = lane0.pdst
    //      → 解决：lane0 写 x5，lane1 读 x5——lane1 应看到 lane0 的新映射。
    //   b) WAW 旁路：lane1.rd  == lane0.rd → lane1.stale_pdst = lane0.pdst
    //      → 解决：两路写同一寄存器——lane1 的 stale 应为 lane0 的 pdst
    //             而非 RAT 中的旧值。最终 RAT[rd] 指向 lane1.pdst（在时序块中）。
    //
    // 【关键边界】若 rename_fire[0]=0（lane0 未进入 FIFO），即使 lane0 的
    //   Free List 分配了 pdst，RAT 也未更新，lane1 不应旁路。
    //   代码通过 rename_fire[0] 条件正确保证这一点。
    // ==========================================================================
    always_comb begin
        // lane0 直接读取当前推测映射。
        rename_rsp.lane0.prs1 = rename_req.lane0.use_rs1
                              ? rat[rename_req.lane0.rs1] : '0;
        rename_rsp.lane0.prs2 = rename_req.lane0.use_rs2
                              ? rat[rename_req.lane0.rs2] : '0;
        rename_rsp.lane0.stale_pdst = (rename_req.lane0.rd != '0)
                                    ? rat[rename_req.lane0.rd] : '0;

        // lane1 先读取 RAT，再旁路 lane0 本拍建立的新映射。
        rename_rsp.lane1.prs1 = rename_req.lane1.use_rs1
                              ? rat[rename_req.lane1.rs1] : '0;
        rename_rsp.lane1.prs2 = rename_req.lane1.use_rs2
                              ? rat[rename_req.lane1.rs2] : '0;
        rename_rsp.lane1.stale_pdst = (rename_req.lane1.rd != '0)
                                    ? rat[rename_req.lane1.rd] : '0;

        if (rename_fire[0] && rename_req.lane0.pdst_valid
            && (rename_req.lane0.rd != '0)) begin
            if (rename_req.lane1.use_rs1
                && (rename_req.lane1.rs1 == rename_req.lane0.rd))
                rename_rsp.lane1.prs1 = rename_req.lane0.pdst;
            if (rename_req.lane1.use_rs2
                && (rename_req.lane1.rs2 == rename_req.lane0.rd))
                rename_rsp.lane1.prs2 = rename_req.lane0.pdst;
            if (rename_req.lane1.rd == rename_req.lane0.rd)
                rename_rsp.lane1.stale_pdst = rename_req.lane0.pdst;
        end
    end

    // ==========================================================================
    // 组合逻辑 2：RRAT_next 计算 + 恢复用 used_mask 生成
    // ==========================================================================
    // RRAT_next = RRAT 应用本拍顺序提交后的结果。
    // 用途：① 下一拍写入 RRAT；② 恢复时赋值给 RAT；③ 生成 Free List 恢复位图。
    //
    // 提交语义：
    //   - 仅当 commit_map.laneX.valid=1 且 rd≠0 时才更新（x0 不产生提交映射）。
    //   - lane0 先应用，lane1 后应用。同 rd 时 lane1 覆盖 lane0。
    //   - 强制 rrat_next[0]=0（x0 永映射到 p0）。
    //
    // recover_used_mask 生成：
    //   遍历 RRAT_next 的 32 项，将每项指向的物理寄存器号在 64-bit mask 中置 1。
    //   强制 bit[0]=1（p0 永远被视为"已占用"）。
    //   ⚠️ 注意：理论上可能出现多个架构寄存器映射到同一物理寄存器吗？
    //   正常提交状态下不会（RAT/RRAT 是一一映射）。但若存在 bug，
    //   used_mask 中重复置 1 无影响（只是少回收一个寄存器）。
    // ==========================================================================
    // RRAT_next 先应用本拍顺序提交，供 RRAT 写入、RAT 恢复和 Free List 重建。
    always_comb begin
        for (rrat_idx = 0; rrat_idx < ARCH_REG_COUNT; rrat_idx = rrat_idx + 1)
            rrat_next[rrat_idx] = rrat[rrat_idx];

        if (commit_map.lane0.valid && (commit_map.lane0.rd != '0))
            rrat_next[commit_map.lane0.rd] = commit_map.lane0.pdst;
        if (commit_map.lane1.valid && (commit_map.lane1.rd != '0))
            rrat_next[commit_map.lane1.rd] = commit_map.lane1.pdst;
        rrat_next[0] = '0;

        recover_used_mask = '0;
        for (rrat_idx = 0; rrat_idx < ARCH_REG_COUNT; rrat_idx = rrat_idx + 1)
            recover_used_mask[rrat_next[rrat_idx]] = 1'b1;
        recover_used_mask[0] = 1'b1;
    end

    // ==========================================================================
    // 时序逻辑：RAT/RRAT 状态更新
    // ==========================================================================
    // 【更新优先级】
    //   1. 复位：RAT[xN]=pN, RRAT[xN]=pN（一一映射）
    //   2. 恢复：RAT <= RRAT_next（覆盖所有推测映射）
    //   3. 正常：rat[lane0.rd] <= lane0.pdst（先写）
    //            rat[lane1.rd] <= lane1.pdst（后写，同 rd 时覆盖）
    //   4. 强制：rat[0]=0, rrat[0]=0（每拍）
    //
    // 【WAW 提交语义】
    //   若双提交写同一 rd：lane0 先更新 rrat_next[rd]=lane0.pdst，
    //   然后 lane1 更新 rrat_next[rd]=lane1.pdst。最终 RRAT 指向 lane1.pdst
    //   （程序序上 lane1 更新）。正确。
    //
    // 【部分推进场景】
    //   仅 rename_fire[0]=1 时，只更新 rat[lane0.rd]。
    //   lane1 未 fire，其请求保留在输入槽中，下一拍重新查询 RAT——
    //   此时 RAT 已包含 lane0 的新映射，lane1 自然能看到正确结果。
    // ==========================================================================
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            for (state_idx = 0; state_idx < ARCH_REG_COUNT;
                 state_idx = state_idx + 1) begin
                rat[state_idx]  <= PHYS_REG_WIDTH'(state_idx);
                rrat[state_idx] <= PHYS_REG_WIDTH'(state_idx);
            end
        end else begin
            // RRAT 每拍更新（应用本拍提交结果）
            for (state_idx = 0; state_idx < ARCH_REG_COUNT;
                 state_idx = state_idx + 1)
                rrat[state_idx] <= rrat_next[state_idx];

            if (recover.valid) begin
                // 恢复：RAT <= RRAT_next（已含本拍提交）
                for (state_idx = 0; state_idx < ARCH_REG_COUNT;
                     state_idx = state_idx + 1)
                    rat[state_idx] <= rrat_next[state_idx];
            end else begin
                // 正常推测更新：lane0 先写，lane1 后写（同 rd 时 lane1 胜出）
                if (rename_fire[0] && rename_req.lane0.pdst_valid
                    && (rename_req.lane0.rd != '0))
                    rat[rename_req.lane0.rd] <= rename_req.lane0.pdst;

                // lane1 后写，保证双路同 rd 时最终 RAT 指向 lane1.pdst。
                if (rename_fire[1] && rename_req.lane1.pdst_valid
                    && (rename_req.lane1.rd != '0))
                    rat[rename_req.lane1.rd] <= rename_req.lane1.pdst;
            end

            rat[0]  <= '0;
            rrat[0] <= '0;
        end
    end

endmodule
