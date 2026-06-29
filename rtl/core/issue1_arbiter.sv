// =============================================================================
// IQ1 / LSQ → issue1 年龄仲裁
// =============================================================================
// 纯组合逻辑，无状态。IQ1 和 LSQ 各有一个候选，仲裁规则：
//   - 若只有一侧 valid → 自然发射该侧
//   - 若两侧都 valid  → 选择 ROB 年龄更老的那条（环形距离更大 = 更老）
//   - 未获准的一侧保持 valid 不变（不消耗队列项）
//
// 两侧候选在各自的队列中已经完成源就绪判断和 FU 可用性检查，
// 这里只做年龄比较，不再重复判断就绪/可用性。
//
// 【PRF 读请求差异】
//   IQ 侧指令 src2 正常按 use_rs2 条件读取 PRF。
//   LSQ 侧：如果是 store 且 src2 数据需要通过 PRF 读到（read_store_data=1）
//   才读 src2 端口；否则跳过（数据会通过 CDB 广播或 AGU 返回补齐）。
// =============================================================================
module issue1_arbiter (
    // ---- 全局 ROB 头指针（用于年龄计算） ----
    input  wire core_port_pkg::rob_tag_t       rob_head_tag,

    // ---- IQ1 候选 ----
    input  logic                               iq_valid,
    input  wire core_port_pkg::iq_issue_slot_t iq_bus,
    output logic                               iq_ready,

    // ---- LSQ AGU 候选 ----
    input  logic                                lsq_valid,
    input  wire core_port_pkg::lsq_agu_issue_t  lsq_bus,
    output logic                                lsq_ready,

    // ---- 仲裁后输出，送往 Operand Read ----
    output logic                                issue_valid,
    output      core_port_pkg::issue1_slot_t     issue_bus,
    input  logic                                issue_ready,
    output logic                                issue_fire,

    // ---- PRF 读请求（发给物理寄存器堆） ----
    output      core_port_pkg::iq_prf_read_req_t prf_read_req
);
    import core_port_pkg::*;

    logic choose_lsq;
    logic [ROB_PTR_WIDTH-1:0] iq_age;
    logic [ROB_PTR_WIDTH-1:0] lsq_age;

    always_comb begin
        // ── 计算两路候选的年龄（距离 ROB head 的环形距离） ──
        // 年龄 = rob_tag - rob_head_tag（6-bit 无符号减法，自动 wrap）
        // 年龄值越大说明该指令越老。
        iq_age  = iq_bus.rob_tag  - rob_head_tag;
        lsq_age = lsq_bus.rob_tag - rob_head_tag;

        // ── 选择更老的候选 ──
        // LSQ 胜出条件：LSQ 有候选，且（IQ 无候选 或 LSQ 比 IQ 更老）
        choose_lsq = lsq_valid && (!iq_valid || (lsq_age < iq_age));
        // 注意：age 更小的数字 = 更老的指令。
        // 因为 age = (tag - head)，head 是最老的存活指令，
        // head 本身 age=0，紧挨着 head 的 age=1，以此类推。

        issue_valid = iq_valid || lsq_valid;
        issue_bus   = '0;

        // ── 选中的候选填充 issue_bus ──
        if (choose_lsq) begin
            // LSQ 胜出：填充完整 LSQ 发出包（含 from_lsq 标记、bypass 数据等）
            issue_bus.from_lsq         = 1'b1;
            issue_bus.lsq_tag          = lsq_bus.lsq_tag;
            issue_bus.rob_tag          = lsq_bus.rob_tag;
            issue_bus.uop              = lsq_bus.uop;
            issue_bus.read_store_data  = lsq_bus.read_store_data;
            issue_bus.src1_bypass_valid = lsq_bus.src1_bypass_valid;
            issue_bus.src1_bypass_data = lsq_bus.src1_bypass_data;
            issue_bus.src2_bypass_valid = lsq_bus.src2_bypass_valid;
            issue_bus.src2_bypass_data = lsq_bus.src2_bypass_data;
        end else if (iq_valid) begin
            // IQ 胜出：填充 IQ 发出包（from_lsq=0，无 lsq_tag 和 read_store_data）
            issue_bus.from_lsq         = 1'b0;
            issue_bus.rob_tag          = iq_bus.rob_tag;
            issue_bus.uop              = iq_bus.uop;
            issue_bus.src1_bypass_valid = iq_bus.src1_bypass_valid;
            issue_bus.src1_bypass_data = iq_bus.src1_bypass_data;
            issue_bus.src2_bypass_valid = iq_bus.src2_bypass_valid;
            issue_bus.src2_bypass_data = iq_bus.src2_bypass_data;
        end

        // ── per-side ready 信号 ──
        // 未被选中的那侧在本拍不会收到 ready 确认（但只要 issue_ready=1，
        // 选中的那侧会握手并清掉队列项）。两侧 ready 互斥。
        iq_ready  = issue_ready && issue_valid && !choose_lsq;
        lsq_ready = issue_ready && issue_valid && choose_lsq;
        issue_fire = issue_valid && issue_ready;

        // ── PRF 读请求 ──
        // src1：任意指令只要 use_rs1 就读取 PRF（bypass 数据已从 issue_bus 携带）
        // src2：IQ 指令按 use_rs2 条件；LSQ 指令只在真正需要读 store data 时读
        prf_read_req = '0;
        prf_read_req.src1.valid = issue_fire && issue_bus.uop.dec.use_rs1;
        prf_read_req.src1.preg  = issue_bus.uop.prs1;
        prf_read_req.src2.valid = issue_fire
                               && (issue_bus.from_lsq
                                   ? issue_bus.read_store_data     // LSQ: store data
                                   : issue_bus.uop.dec.use_rs2);  // IQ: 正常 src2
        prf_read_req.src2.preg  = issue_bus.uop.prs2;
    end

endmodule
