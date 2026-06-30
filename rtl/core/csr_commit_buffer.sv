// =============================================================================
// 单项 CSR 精确提交缓存
// =============================================================================
// CSR 执行结果完成时写入；只有 ROB 头相同 tag 的 CSR 真正 commit_fire 时，
// 才向 csr_file 产生 commit_update。缓存占用期间禁止下一条 CSR 执行，既简化
// RAW/WAW 顺序，也保证时序读看到的是前一条 CSR 提交后的状态。
// =============================================================================
module csr_commit_buffer (
    input  logic                                      clk,
    input  logic                                      rst_n,
    input  wire core_port_pkg::recover_event_t        recover,

    input  logic                                      enqueue_valid,
    input  wire core_port_pkg::csr_execute_update_t   enqueue_update,
    output logic                                      enqueue_ready,
    output logic                                      available,

    input  wire core_port_pkg::rob_commit_bundle_t    commit_bus,
    input  logic [1:0]                                commit_fire,
    output logic [1:0]                                commit_ready,
    output      core_port_pkg::csr_execute_update_t   commit_update
);
    import core_port_pkg::*;

    logic entry_valid;
    csr_execute_update_t entry;
    logic lane0_match;
    logic lane1_match;

    always_comb begin
        // 不提供“同拍提交旧项并接收新项”的旁路，确保下一条 CSR 最早在
        // 前一条实际提交后的下一周期发起时序读。
        available     = !entry_valid;
        enqueue_ready = !entry_valid;

        lane0_match = entry_valid && commit_bus.lane0.valid
                    && commit_bus.lane0.is_csr
                    && !commit_bus.lane0.exception_valid
                    && (commit_bus.lane0.tag == entry.rob_tag);
        lane1_match = entry_valid && commit_bus.lane1.valid
                    && commit_bus.lane1.is_csr
                    && !commit_bus.lane1.exception_valid
                    && (commit_bus.lane1.tag == entry.rob_tag);

        commit_ready = 2'b11;
        if (commit_bus.lane0.valid && commit_bus.lane0.is_csr
            && !commit_bus.lane0.exception_valid)
            commit_ready[0] = lane0_match;
        if (commit_bus.lane1.valid && commit_bus.lane1.is_csr
            && !commit_bus.lane1.exception_valid)
            commit_ready[1] = lane1_match;

        commit_update = entry;
        commit_update.valid = (commit_fire[0] && lane0_match)
                           || (commit_fire[1] && lane1_match);
    end

    always_ff @(posedge clk) begin
        if (!rst_n || recover.valid) begin
            entry_valid <= 1'b0;
            entry       <= '0;
        end else begin
            if ((commit_fire[0] && lane0_match)
                || (commit_fire[1] && lane1_match))
                entry_valid <= 1'b0;

            if (enqueue_valid && enqueue_ready) begin
                entry_valid <= 1'b1;
                entry       <= enqueue_update;
                entry.valid <= 1'b1;
            end
        end
    end

`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
        if (rst_n && !recover.valid) begin
            assert (!(enqueue_valid && !enqueue_ready))
                else $error("csr_commit_buffer: enqueue while full");
        end
    end
`endif

endmodule
