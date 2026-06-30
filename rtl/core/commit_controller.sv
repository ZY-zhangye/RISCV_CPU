`include "defines.svh"

// =============================================================================
// ROB 精确提交、trap 与统一 recovery 控制
// =============================================================================
// 同步异常/重定向/mret 只在对应 ROB 项到达提交头时触发。机器中断仅在安全
// 指令边界采样：ROB 为空，或 lane0 已完成可提交；中断优先于正常提交，因而
// mepc 指向尚未提交的 lane0 PC，不会重复/漏执行已提交指令。
// =============================================================================
module commit_controller (
    input  wire core_port_pkg::rob_commit_bundle_t commit_bus,
    input  logic [1:0]                             store_commit_ready,
    input  logic [1:0]                             csr_commit_ready,

    input  logic                                   rob_empty,
    input  logic [`ADDR_WIDTH-1:0]                 interrupt_pc,
    input  logic                                   interrupt_pending,
    input  logic [4:0]                             interrupt_cause,
    input  logic [`ADDR_WIDTH-1:0]                 trap_target,
    input  logic [`ADDR_WIDTH-1:0]                 mret_target,

    output logic [1:0]                             commit_ready,
    output      core_port_pkg::recover_event_t     recover,
    output      core_port_pkg::trap_event_t        trap_event,
    output logic                                   mret_valid
);
    import core_port_pkg::*;

    logic lane0_resource_ready;
    logic lane1_resource_ready;
    logic lane0_recovery;
    logic lane1_recovery;
    logic interrupt_safe;

    always_comb begin
        lane0_resource_ready = 1'b1;
        if (commit_bus.lane0.valid && !commit_bus.lane0.exception_valid) begin
            if (commit_bus.lane0.is_store)
                lane0_resource_ready = store_commit_ready[0];
            if (commit_bus.lane0.is_csr)
                lane0_resource_ready = lane0_resource_ready
                                     && csr_commit_ready[0];
        end

        lane1_resource_ready = 1'b1;
        if (commit_bus.lane1.valid && !commit_bus.lane1.exception_valid) begin
            if (commit_bus.lane1.is_store)
                lane1_resource_ready = store_commit_ready[1];
            if (commit_bus.lane1.is_csr)
                lane1_resource_ready = lane1_resource_ready
                                     && csr_commit_ready[1];
        end

        lane0_recovery = commit_bus.lane0.valid
                       && (commit_bus.lane0.exception_valid
                           || commit_bus.lane0.redirect_valid
                           || commit_bus.lane0.is_mret);
        lane1_recovery = commit_bus.lane1.valid
                       && (commit_bus.lane1.exception_valid
                           || commit_bus.lane1.redirect_valid
                           || commit_bus.lane1.is_mret);
        interrupt_safe = rob_empty || commit_bus.lane0.valid;

        commit_ready = '0;
        recover      = '0;
        trap_event   = '0;
        mret_valid   = 1'b0;

        // A pending interrupt is taken before the next not-yet-committed head
        // instruction. A synchronous head event has priority over interrupt.
        if (lane0_recovery) begin
            commit_ready[0] = 1'b1;
            if (commit_bus.lane0.exception_valid) begin
                trap_event.valid        = 1'b1;
                trap_event.is_interrupt = 1'b0;
                trap_event.cause        = commit_bus.lane0.exc_code[4:0];
                trap_event.pc           = commit_bus.lane0.pc;
                trap_event.tval         = commit_bus.lane0.exc_tval;
                recover.valid           = 1'b1;
                recover.reason          = RECOVER_EXCEPTION;
                recover.target          = trap_target;
            end else if (commit_bus.lane0.is_mret) begin
                mret_valid      = 1'b1;
                recover.valid   = 1'b1;
                recover.reason  = RECOVER_BRANCH;
                recover.target  = mret_target;
            end else begin
                recover.valid   = 1'b1;
                recover.reason  = RECOVER_BRANCH;
                recover.target  = commit_bus.lane0.redirect_target;
            end
        end else if (interrupt_pending && interrupt_safe) begin
            trap_event.valid        = 1'b1;
            trap_event.is_interrupt = 1'b1;
            trap_event.cause        = interrupt_cause;
            trap_event.pc           = commit_bus.lane0.valid
                                    ? commit_bus.lane0.pc : interrupt_pc;
            trap_event.tval         = '0;
            recover.valid           = 1'b1;
            recover.reason          = RECOVER_INTERRUPT;
            recover.target          = trap_target;
        end else begin
            commit_ready[0] = lane0_resource_ready;
            commit_ready[1] = lane0_resource_ready && lane1_resource_ready;

            // lane1 recovery is legal only when lane0 can commit in the same
            // cycle. ROB itself enforces commit_fire[1] -> commit_fire[0].
            if (lane1_recovery && lane0_resource_ready) begin
                commit_ready[1] = 1'b1;
                if (commit_bus.lane1.exception_valid) begin
                    trap_event.valid        = 1'b1;
                    trap_event.is_interrupt = 1'b0;
                    trap_event.cause        = commit_bus.lane1.exc_code[4:0];
                    trap_event.pc           = commit_bus.lane1.pc;
                    trap_event.tval         = commit_bus.lane1.exc_tval;
                    recover.valid           = 1'b1;
                    recover.reason          = RECOVER_EXCEPTION;
                    recover.target          = trap_target;
                end else if (commit_bus.lane1.is_mret) begin
                    mret_valid      = 1'b1;
                    recover.valid   = 1'b1;
                    recover.reason  = RECOVER_BRANCH;
                    recover.target  = mret_target;
                end else begin
                    recover.valid   = 1'b1;
                    recover.reason  = RECOVER_BRANCH;
                    recover.target  = commit_bus.lane1.redirect_target;
                end
            end
        end
    end

endmodule
