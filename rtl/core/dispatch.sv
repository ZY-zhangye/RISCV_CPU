`include "defines.svh"

// =============================================================================
// Rename -> ROB / IQ0 / IQ1 / LSQ 组合 Dispatch
//
// 本模块没有时钟和内部状态。Rename 输出 FIFO 已经提供稳定寄存边界；
// Dispatch 只读取各目标结构由寄存占用量产生的接收额度，并在当前周期完成：
//   - ROB 与目标队列的原子准入；
//   - lane0 优先、lane1 不得越过 lane0 的前缀推进；
//   - ALU 在 IQ0/IQ1 之间的容量感知分流；
//   - 各目标输出端口的程序序压紧。
//
// capacity 必须只由目标队列当前寄存状态产生，不得加入本拍 issue/commit
// 释放的旁路额度，否则可能把执行或提交路径组合传播回 Rename。
// =============================================================================
module dispatch (
    input  logic                               dispatch_enable,
    // Rename 输出。
    input  logic [1:0]                         rn_to_dp_valid,
    input  wire core_port_pkg::rn_dp_bundle_t  rn_to_dp_bus,
    output logic [1:0]                         dp_ready,

    // ROB 分配资源和预分配 tag。
    input  logic                               rob_allowin,
    input  wire core_port_pkg::rob_tag_pair_t  rob_alloc_tag,
    output logic [1:0]                         rob_alloc_valid,
    output      core_port_pkg::rn_rob_bundle_t rob_alloc_bus,

    // 两个静态 IQ bank。每个 bank 本拍最多接收两条、后续每拍单发射。
    input  core_port_pkg::dispatch_capacity_t  iq0_capacity,
    input  core_port_pkg::dispatch_capacity_t  iq1_capacity,
    output logic [1:0]                         iq0_enq_valid,
    output logic [1:0]                         iq1_enq_valid,
    output      core_port_pkg::dp_iq_bundle_t  iq0_enq_bus,
    output      core_port_pkg::dp_iq_bundle_t  iq1_enq_bus,

    // 独立 LSQ；它将在后续与 IQ1 竞争 issue1。
    input  core_port_pkg::dispatch_capacity_t  lsq_capacity,
    output logic [1:0]                         lsq_enq_valid,
    output      core_port_pkg::dp_lsq_bundle_t lsq_enq_bus
);
    import core_port_pkg::*;

    typedef enum logic [1:0] {
        TARGET_ROB_ONLY = 2'd0,
        TARGET_IQ0      = 2'd1,
        TARGET_IQ1      = 2'd2,
        TARGET_LSQ      = 2'd3
    } dispatch_target_e;

    dispatch_target_e target0;
    dispatch_target_e target1;
    logic lane0_resource_ready;
    logic lane1_resource_ready;
    logic accept0;
    logic accept1;
    integer iq0_used;
    integer iq1_used;
    integer lsq_used;

    function automatic dispatch_target_e choose_target(
        input rn_dp_slot_t slot,
        input integer      used_iq0,
        input integer      used_iq1
    );
        integer remaining_iq0;
        integer remaining_iq1;
        begin
            remaining_iq0 = integer'(iq0_capacity) - used_iq0;
            remaining_iq1 = integer'(iq1_capacity) - used_iq1;
            unique case (slot.dec.fu_type)
                FU_MLU: choose_target = TARGET_IQ0;
                FU_BRU,
                FU_CSR: choose_target = TARGET_IQ1;
                FU_LSU: choose_target = TARGET_LSQ;
                FU_ALU: begin
                    // 相同容量时 lane0 首选 IQ0；处理 lane1 时，lane0 已使用
                    // 的额度会使另一侧剩余更多，从而自然把双 ALU 分散开。
                    if (remaining_iq0 > remaining_iq1)
                        choose_target = TARGET_IQ0;
                    else if (remaining_iq1 > remaining_iq0)
                        choose_target = TARGET_IQ1;
                    else if (used_iq0 > used_iq1)
                        choose_target = TARGET_IQ1;
                    else
                        choose_target = TARGET_IQ0;
                end
                default: choose_target = TARGET_ROB_ONLY;
            endcase
        end
    endfunction

    function automatic logic target_ready(
        input dispatch_target_e target,
        input integer           used_iq0,
        input integer           used_iq1,
        input integer           used_lsq
    );
        begin
            unique case (target)
                TARGET_IQ0:
                    target_ready = (integer'(iq0_capacity) > used_iq0);
                TARGET_IQ1:
                    target_ready = (integer'(iq1_capacity) > used_iq1);
                TARGET_LSQ:
                    target_ready = (integer'(lsq_capacity) > used_lsq);
                default:
                    target_ready = 1'b1;
            endcase
        end
    endfunction

    function automatic rn_rob_slot_t make_rob_slot(input rn_dp_slot_t slot);
        rn_rob_slot_t rob_slot;
        logic exception_valid;
        logic is_fence;
        logic is_fence_i;
        logic is_mret;
        begin
            exception_valid = (slot.dec.exc_code != `EXC_NONE)
                            && (slot.dec.exc_code != `EXC_MRET);
            is_fence = (slot.dec.inst[6:0] == 7'b0001111);
            is_fence_i = is_fence && (slot.dec.inst[14:12] == 3'b001);
            is_mret  = (slot.dec.exc_code == `EXC_MRET);

            rob_slot = '0;
            rob_slot.pc                = slot.dec.pc;
            rob_slot.rd                = slot.dec.rd;
            rob_slot.pdst              = slot.pdst;
            rob_slot.stale_pdst        = slot.stale_pdst;
            rob_slot.pdst_valid        = slot.pdst_valid;
            rob_slot.is_branch         = (slot.dec.fu_type == FU_BRU);
            rob_slot.is_store          = (slot.dec.fu_type == FU_LSU)
                                       && slot.dec.mem_write;
            rob_slot.is_csr            = (slot.dec.fu_type == FU_CSR);
            rob_slot.is_fence          = is_fence;
            rob_slot.is_fence_i        = is_fence_i;
            rob_slot.is_mret           = is_mret;
            rob_slot.exception_valid   = exception_valid;
            rob_slot.exc_code          = slot.dec.exc_code;
            rob_slot.exc_tval          = slot.dec.exc_tval;
            // 异常、MRET 和无执行单元的普通 SYSTEM 指令不等待执行完成。
            // FENCE 需要等待未来 LSQ/提交控制器确认内存序，因此不在分配时完成。
            rob_slot.complete_on_alloc = exception_valid
                                       || is_mret
                                       || is_fence
                                       || (slot.dec.fu_type == FU_NONE)
                                       || ((slot.dec.fu_type == FU_SYS)
                                           && !is_fence);
            make_rob_slot = rob_slot;
        end
    endfunction

    function automatic logic is_serializing(input rn_dp_slot_t slot);
        begin
            is_serializing = (slot.dec.fu_type == FU_CSR)
                           || (slot.dec.inst[6:0] == 7'b0001111)
                           || (slot.dec.exc_code != `EXC_NONE);
        end
    endfunction

    function automatic dp_iq_slot_t make_iq_slot(
        input rn_dp_slot_t slot,
        input rob_tag_t    tag
    );
        dp_iq_slot_t iq_slot;
        begin
            iq_slot.rob_tag = tag;
            iq_slot.uop     = slot;
            make_iq_slot    = iq_slot;
        end
    endfunction

    function automatic dp_lsq_slot_t make_lsq_slot(
        input rn_dp_slot_t slot,
        input rob_tag_t    tag
    );
        dp_lsq_slot_t lsq_slot;
        begin
            lsq_slot.rob_tag = tag;
            lsq_slot.uop     = slot;
            make_lsq_slot    = lsq_slot;
        end
    endfunction

    always_comb begin
        dp_ready       = '0;
        rob_alloc_valid = '0;
        rob_alloc_bus   = '0;
        iq0_enq_valid   = '0;
        iq1_enq_valid   = '0;
        lsq_enq_valid   = '0;
        iq0_enq_bus     = '0;
        iq1_enq_bus     = '0;
        lsq_enq_bus     = '0;

        iq0_used = 0;
        iq1_used = 0;
        lsq_used = 0;

        // lane0 先决定路由和资源。ROB 至少保留两个空项才允许任何接收。
        target0 = choose_target(rn_to_dp_bus.lane0, iq0_used, iq1_used);
        lane0_resource_ready = target_ready(target0, iq0_used, iq1_used, lsq_used);
        dp_ready[0] = dispatch_enable && rob_allowin && lane0_resource_ready;
        accept0     = rn_to_dp_valid[0] && dp_ready[0];

        if (accept0) begin
            unique case (target0)
                TARGET_IQ0: iq0_used = iq0_used + 1;
                TARGET_IQ1: iq1_used = iq1_used + 1;
                TARGET_LSQ: lsq_used = lsq_used + 1;
                default: ;
            endcase
        end

        // lane1 使用 lane0 已预留后的剩余额度，并且只有 lane0 真正接收后
        // 才能 ready，严格保持程序序前缀。
        target1 = choose_target(rn_to_dp_bus.lane1, iq0_used, iq1_used);
        lane1_resource_ready = target_ready(target1, iq0_used, iq1_used, lsq_used);
        dp_ready[1] = accept0 && rob_allowin && lane1_resource_ready
                    && !is_serializing(rn_to_dp_bus.lane0);
        accept1     = rn_to_dp_valid[1] && dp_ready[1];

        rob_alloc_valid[0] = accept0;
        rob_alloc_valid[1] = accept1;
        if (accept0)
            rob_alloc_bus.lane0 = make_rob_slot(rn_to_dp_bus.lane0);
        if (accept1)
            rob_alloc_bus.lane1 = make_rob_slot(rn_to_dp_bus.lane1);

        // 各队列输出重新压紧；某个 bank 只有一条时总是使用其 lane0 写口。
        if (accept0) begin
            unique case (target0)
                TARGET_IQ0: begin
                    iq0_enq_valid[0] = 1'b1;
                    iq0_enq_bus.lane0 = make_iq_slot(
                        rn_to_dp_bus.lane0, rob_alloc_tag.lane0);
                end
                TARGET_IQ1: begin
                    iq1_enq_valid[0] = 1'b1;
                    iq1_enq_bus.lane0 = make_iq_slot(
                        rn_to_dp_bus.lane0, rob_alloc_tag.lane0);
                end
                TARGET_LSQ: begin
                    lsq_enq_valid[0] = 1'b1;
                    lsq_enq_bus.lane0 = make_lsq_slot(
                        rn_to_dp_bus.lane0, rob_alloc_tag.lane0);
                end
                default: ;
            endcase
        end

        if (accept1) begin
            unique case (target1)
                TARGET_IQ0: begin
                    if (iq0_enq_valid[0]) begin
                        iq0_enq_valid[1] = 1'b1;
                        iq0_enq_bus.lane1 = make_iq_slot(
                            rn_to_dp_bus.lane1, rob_alloc_tag.lane1);
                    end else begin
                        iq0_enq_valid[0] = 1'b1;
                        iq0_enq_bus.lane0 = make_iq_slot(
                            rn_to_dp_bus.lane1, rob_alloc_tag.lane1);
                    end
                end
                TARGET_IQ1: begin
                    if (iq1_enq_valid[0]) begin
                        iq1_enq_valid[1] = 1'b1;
                        iq1_enq_bus.lane1 = make_iq_slot(
                            rn_to_dp_bus.lane1, rob_alloc_tag.lane1);
                    end else begin
                        iq1_enq_valid[0] = 1'b1;
                        iq1_enq_bus.lane0 = make_iq_slot(
                            rn_to_dp_bus.lane1, rob_alloc_tag.lane1);
                    end
                end
                TARGET_LSQ: begin
                    if (lsq_enq_valid[0]) begin
                        lsq_enq_valid[1] = 1'b1;
                        lsq_enq_bus.lane1 = make_lsq_slot(
                            rn_to_dp_bus.lane1, rob_alloc_tag.lane1);
                    end else begin
                        lsq_enq_valid[0] = 1'b1;
                        lsq_enq_bus.lane0 = make_lsq_slot(
                            rn_to_dp_bus.lane1, rob_alloc_tag.lane1);
                    end
                end
                default: ;
            endcase
        end
    end

endmodule
