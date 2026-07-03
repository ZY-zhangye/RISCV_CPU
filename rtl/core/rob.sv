`include "defines.svh"

// =============================================================================
// 双分配、双完成、双提交 Reorder Buffer
//
// 设计约定：
//   1. 只有当前至少存在两个空项时 rob_allowin 才为 1。即使上游本拍只有
//      lane0 有效，也不使用最后一个孤立空项，以简化分配边界控制。
//   2. rob_allowin 只依赖寄存后的 occupancy，不旁路本拍提交释放的空间。
//   3. 分配顺序固定为 lane0 -> tail，lane1 -> tail+1。PC 数值不参与年龄
//      比较，因为循环和跳转后年轻指令的 PC 完全可能更小。
//   4. 提交严格遵守前缀顺序：lane1 不能越过 lane0；lane0 单独完成时允许
//      单提交。异常、重定向和串行指令会阻止同拍提交更年轻的 lane1。
// =============================================================================
module rob (
    input  logic                                  clk,
    input  logic                                  rst_n,

    // Rename/组合分流侧。alloc_valid 必须满足前缀约束。
    input  logic [1:0]                            alloc_valid,
    input  wire core_port_pkg::rn_rob_bundle_t    alloc_bus,
    output logic                                  rob_allowin,
    output      core_port_pkg::rob_tag_pair_t     alloc_tag,

    // 两路执行完成更新，可乱序到达。
    input  wire core_port_pkg::rob_complete_bundle_t complete_bus,

    // 提交候选和提交握手。commit_ready 同样必须满足前缀语义。
    output      core_port_pkg::rob_commit_bundle_t commit_bus,
    input  logic [1:0]                            commit_ready,
    output logic [1:0]                            commit_fire,
    output      core_port_pkg::commit_map_bundle_t commit_map,

    // 全核统一恢复。当前约定恢复事件在 ROB 头处理，因此恢复后 ROB 为空。
    input  wire core_port_pkg::recover_event_t    recover,

    output logic [$clog2(core_port_pkg::ROB_DEPTH+1)-1:0] occupancy_o,
    output      core_port_pkg::rob_tag_t           head_tag_o,
    output      core_port_pkg::rob_tag_t           head_tag_iq0,
    output      core_port_pkg::rob_tag_t           head_tag_iq1
);
    import core_port_pkg::*;

    localparam int ROB_COUNT_WIDTH = $clog2(ROB_DEPTH + 1);

    typedef struct packed {
        logic                       valid;
        logic                       complete;
        rob_tag_t                   tag;
        logic [`ADDR_WIDTH-1:0]     pc;
        arch_reg_idx_t              rd;
        phys_reg_idx_t              pdst;
        phys_reg_idx_t              stale_pdst;
        logic                       pdst_valid;
        logic                       is_branch;
        logic                       is_store;
        logic                       is_csr;
        logic                       is_fence;
        logic                       is_fence_i;
        logic                       is_mret;
        logic                       exception_valid;
        logic [`EXC_CODE_WIDTH-1:0] exc_code;
        logic [`ADDR_WIDTH-1:0]     exc_tval;
        logic                       redirect_valid;
        logic [`ADDR_WIDTH-1:0]     redirect_target;
        logic                       next_pc_valid;
        logic [`ADDR_WIDTH-1:0]     next_pc;
    } rob_entry_t;

    rob_entry_t entries [0:ROB_DEPTH-1];
    rob_entry_t head_entry0;
    rob_entry_t head_entry1;
    rob_commit_bundle_t commit_bus_q;
    rob_commit_bundle_t commit_bus_next;

    rob_tag_t head_ptr;
    rob_tag_t tail_ptr;
    rob_tag_t head_ptr_plus_one;
    rob_tag_t tail_ptr_plus_one;
    rob_tag_t next_head_ptr;
    rob_tag_t next_head_ptr_plus_one;
    logic [ROB_COUNT_WIDTH-1:0] occupancy;
    logic [ROB_COUNT_WIDTH-1:0] occupancy_next;
    logic [1:0] alloc_fire;
    logic [1:0] alloc_count;
    logic [1:0] commit_count;
    logic commit_recover_now;
    integer reset_idx;

    function automatic logic stop_younger_commit(input rob_entry_t entry);
        stop_younger_commit = entry.exception_valid
                            || entry.redirect_valid
                            || entry.is_csr
                            || entry.is_fence
                            || entry.is_mret;
    endfunction

    function automatic rob_commit_slot_t make_commit_slot(input rob_entry_t entry);
        rob_commit_slot_t slot;
        begin
            slot = '0;
            slot.valid           = entry.valid && entry.complete;
            slot.tag             = entry.tag;
            slot.pc              = entry.pc;
            slot.rd              = entry.rd;
            slot.pdst            = entry.pdst;
            slot.stale_pdst      = entry.stale_pdst;
            slot.pdst_valid      = entry.pdst_valid;
            slot.is_branch       = entry.is_branch;
            slot.is_store        = entry.is_store;
            slot.is_csr          = entry.is_csr;
            slot.is_fence        = entry.is_fence;
            slot.is_fence_i      = entry.is_fence_i;
            slot.is_mret         = entry.is_mret;
            slot.exception_valid = entry.exception_valid;
            slot.exc_code        = entry.exc_code;
            slot.exc_tval        = entry.exc_tval;
            slot.redirect_valid  = entry.redirect_valid;
            slot.redirect_target = entry.redirect_target;
            slot.next_pc_valid   = entry.next_pc_valid;
            slot.next_pc         = entry.next_pc;
            make_commit_slot = slot;
        end
    endfunction

    function automatic rob_entry_t make_alloc_entry(
        input rn_rob_slot_t slot,
        input rob_tag_t     tag
    );
        rob_entry_t entry;
        begin
            entry = '{
                valid:             1'b1,
                complete:          slot.complete_on_alloc,
                tag:               tag,
                pc:                slot.pc,
                rd:                slot.rd,
                pdst:              slot.pdst,
                stale_pdst:        slot.stale_pdst,
                pdst_valid:        slot.pdst_valid,
                is_branch:         slot.is_branch,
                is_store:          slot.is_store,
                is_csr:            slot.is_csr,
                is_fence:          slot.is_fence,
                is_fence_i:        slot.is_fence_i,
                is_mret:           slot.is_mret,
                exception_valid:   slot.exception_valid,
                exc_code:          slot.exc_code,
                exc_tval:          slot.exc_tval,
                redirect_valid:    1'b0,
                redirect_target:   '0,
                next_pc_valid:     1'b0,
                next_pc:           '0
            };
            make_alloc_entry = entry;
        end
    endfunction

    function automatic rob_entry_t entry_after_updates(input rob_tag_t tag);
        rob_entry_t entry;
        begin
            entry = entries[tag[ROB_INDEX_WIDTH-1:0]];

            if (complete_bus.lane0.valid && entry.valid
                && (entry.tag == complete_bus.lane0.tag)
                && (tag == complete_bus.lane0.tag)) begin
                entry.complete         = 1'b1;
                entry.exception_valid  = complete_bus.lane0.exception_valid;
                entry.exc_code         = complete_bus.lane0.exc_code;
                entry.exc_tval         = complete_bus.lane0.exc_tval;
                entry.redirect_valid   = complete_bus.lane0.redirect_valid;
                entry.redirect_target  = complete_bus.lane0.redirect_target;
                entry.next_pc_valid    = complete_bus.lane0.next_pc_valid;
                entry.next_pc          = complete_bus.lane0.next_pc;
            end
            if (complete_bus.lane1.valid && entry.valid
                && (entry.tag == complete_bus.lane1.tag)
                && (tag == complete_bus.lane1.tag)) begin
                entry.complete         = 1'b1;
                entry.exception_valid  = complete_bus.lane1.exception_valid;
                entry.exc_code         = complete_bus.lane1.exc_code;
                entry.exc_tval         = complete_bus.lane1.exc_tval;
                entry.redirect_valid   = complete_bus.lane1.redirect_valid;
                entry.redirect_target  = complete_bus.lane1.redirect_target;
                entry.next_pc_valid    = complete_bus.lane1.next_pc_valid;
                entry.next_pc          = complete_bus.lane1.next_pc;
            end

            if (commit_fire[0] && (tag == head_ptr))
                entry.valid = 1'b0;
            if (commit_fire[1] && (tag == head_ptr_plus_one))
                entry.valid = 1'b0;

            if (alloc_fire[0] && (tag == tail_ptr))
                entry = make_alloc_entry(alloc_bus.lane0, tail_ptr);
            if (alloc_fire[1] && (tag == tail_ptr_plus_one))
                entry = make_alloc_entry(alloc_bus.lane1, tail_ptr_plus_one);

            entry_after_updates = entry;
        end
    endfunction

    always_comb begin
        head_ptr_plus_one = head_ptr + ROB_PTR_WIDTH'(1);
        tail_ptr_plus_one = tail_ptr + ROB_PTR_WIDTH'(1);

        alloc_tag.lane0 = tail_ptr;
        alloc_tag.lane1 = tail_ptr_plus_one;

        // 不使用本拍 commit_count，确保提交路径不会组合传播到 Rename。
        rob_allowin = (occupancy <= ROB_COUNT_WIDTH'(ROB_DEPTH - 2));
        alloc_fire[0] = alloc_valid[0] && rob_allowin;
        alloc_fire[1] = alloc_valid[1] && alloc_valid[0] && rob_allowin;
        alloc_count   = {1'b0, alloc_fire[0]} + {1'b0, alloc_fire[1]};

        commit_bus = recover.valid ? '0 : commit_bus_q;

        commit_fire[0] = !recover.valid && commit_bus.lane0.valid
                       && commit_ready[0];
        commit_fire[1] = !recover.valid && commit_bus.lane1.valid
                       && commit_ready[1] && commit_fire[0];
        commit_count   = {1'b0, commit_fire[0]} + {1'b0, commit_fire[1]};
        commit_recover_now = (commit_fire[0]
                              && (commit_bus.lane0.exception_valid
                                  || commit_bus.lane0.redirect_valid
                                  || commit_bus.lane0.is_mret
                                  || commit_bus.lane0.is_fence_i))
                          || (commit_fire[1]
                              && (commit_bus.lane1.exception_valid
                                  || commit_bus.lane1.redirect_valid
                                  || commit_bus.lane1.is_mret
                                  || commit_bus.lane1.is_fence_i));
        occupancy_next = occupancy + ROB_COUNT_WIDTH'(alloc_count)
                                   - ROB_COUNT_WIDTH'(commit_count);
        next_head_ptr = head_ptr + ROB_PTR_WIDTH'(commit_count);
        next_head_ptr_plus_one = next_head_ptr + ROB_PTR_WIDTH'(1);

        commit_bus_next = '0;
        head_entry0 = entry_after_updates(next_head_ptr);
        head_entry1 = entry_after_updates(next_head_ptr_plus_one);

        if (!recover.valid && !commit_recover_now) begin
            if ((occupancy_next != 0) && head_entry0.valid && head_entry0.complete)
                commit_bus_next.lane0 = make_commit_slot(head_entry0);

            if ((occupancy_next >= 2) && commit_bus_next.lane0.valid
                && !stop_younger_commit(head_entry0)
                && head_entry1.valid && head_entry1.complete)
                commit_bus_next.lane1 = make_commit_slot(head_entry1);
        end

        // 只有真正提交且确实更新架构映射的指令才更新 RRAT/Free List。
        // 异常指令本身不提交其推测映射；误预测分支则可以正常提交映射。
        commit_map = '0;
        commit_map.lane0.valid = commit_fire[0]
                               && commit_bus.lane0.pdst_valid
                               && !commit_bus.lane0.exception_valid;
        commit_map.lane0.rd         = commit_bus.lane0.rd;
        commit_map.lane0.pdst       = commit_bus.lane0.pdst;
        commit_map.lane0.stale_pdst = commit_bus.lane0.stale_pdst;
        commit_map.lane1.valid = commit_fire[1]
                               && commit_bus.lane1.pdst_valid
                               && !commit_bus.lane1.exception_valid;
        commit_map.lane1.rd         = commit_bus.lane1.rd;
        commit_map.lane1.pdst       = commit_bus.lane1.pdst;
        commit_map.lane1.stale_pdst = commit_bus.lane1.stale_pdst;

        occupancy_o = occupancy;
        head_tag_o  = head_ptr;
        head_tag_iq0 = head_ptr;
        head_tag_iq1 = head_ptr;
    end

    always_ff @(posedge clk) begin
        if (!rst_n || recover.valid) begin
            head_ptr  <= '0;
            tail_ptr  <= '0;
            occupancy <= '0;
            commit_bus_q <= '0;
            for (reset_idx = 0; reset_idx < ROB_DEPTH; reset_idx = reset_idx + 1)
                entries[reset_idx] <= '0;
        end else begin
            head_ptr  <= head_ptr + ROB_PTR_WIDTH'(commit_count);
            tail_ptr  <= tail_ptr + ROB_PTR_WIDTH'(alloc_count);
            occupancy <= occupancy + ROB_COUNT_WIDTH'(alloc_count)
                                   - ROB_COUNT_WIDTH'(commit_count);
            commit_bus_q <= commit_bus_next;

            if (commit_fire[0])
                entries[head_ptr[ROB_INDEX_WIDTH-1:0]].valid <= 1'b0;
            if (commit_fire[1])
                entries[head_ptr_plus_one[ROB_INDEX_WIDTH-1:0]].valid <= 1'b0;

            if (complete_bus.lane0.valid
                && entries[complete_bus.lane0.tag[ROB_INDEX_WIDTH-1:0]].valid
                && (entries[complete_bus.lane0.tag[ROB_INDEX_WIDTH-1:0]].tag
                    == complete_bus.lane0.tag)) begin
                entries[complete_bus.lane0.tag[ROB_INDEX_WIDTH-1:0]].complete
                    <= 1'b1;
                entries[complete_bus.lane0.tag[ROB_INDEX_WIDTH-1:0]].redirect_valid
                    <= complete_bus.lane0.redirect_valid;
                entries[complete_bus.lane0.tag[ROB_INDEX_WIDTH-1:0]].redirect_target
                    <= complete_bus.lane0.redirect_target;
                entries[complete_bus.lane0.tag[ROB_INDEX_WIDTH-1:0]].next_pc_valid
                    <= complete_bus.lane0.next_pc_valid;
                entries[complete_bus.lane0.tag[ROB_INDEX_WIDTH-1:0]].next_pc
                    <= complete_bus.lane0.next_pc;
                if (complete_bus.lane0.exception_valid) begin
                    entries[complete_bus.lane0.tag[ROB_INDEX_WIDTH-1:0]].exception_valid
                        <= 1'b1;
                    entries[complete_bus.lane0.tag[ROB_INDEX_WIDTH-1:0]].exc_code
                        <= complete_bus.lane0.exc_code;
                    entries[complete_bus.lane0.tag[ROB_INDEX_WIDTH-1:0]].exc_tval
                        <= complete_bus.lane0.exc_tval;
                end
            end

            if (complete_bus.lane1.valid
                && entries[complete_bus.lane1.tag[ROB_INDEX_WIDTH-1:0]].valid
                && (entries[complete_bus.lane1.tag[ROB_INDEX_WIDTH-1:0]].tag
                    == complete_bus.lane1.tag)) begin
                entries[complete_bus.lane1.tag[ROB_INDEX_WIDTH-1:0]].complete
                    <= 1'b1;
                entries[complete_bus.lane1.tag[ROB_INDEX_WIDTH-1:0]].redirect_valid
                    <= complete_bus.lane1.redirect_valid;
                entries[complete_bus.lane1.tag[ROB_INDEX_WIDTH-1:0]].redirect_target
                    <= complete_bus.lane1.redirect_target;
                entries[complete_bus.lane1.tag[ROB_INDEX_WIDTH-1:0]].next_pc_valid
                    <= complete_bus.lane1.next_pc_valid;
                entries[complete_bus.lane1.tag[ROB_INDEX_WIDTH-1:0]].next_pc
                    <= complete_bus.lane1.next_pc;
                if (complete_bus.lane1.exception_valid) begin
                    entries[complete_bus.lane1.tag[ROB_INDEX_WIDTH-1:0]].exception_valid
                        <= 1'b1;
                    entries[complete_bus.lane1.tag[ROB_INDEX_WIDTH-1:0]].exc_code
                        <= complete_bus.lane1.exc_code;
                    entries[complete_bus.lane1.tag[ROB_INDEX_WIDTH-1:0]].exc_tval
                        <= complete_bus.lane1.exc_tval;
                end
            end

            if (alloc_fire[0]) begin
                entries[tail_ptr[ROB_INDEX_WIDTH-1:0]]
                    <= make_alloc_entry(alloc_bus.lane0, tail_ptr);
            end

            if (alloc_fire[1]) begin
                entries[tail_ptr_plus_one[ROB_INDEX_WIDTH-1:0]]
                    <= make_alloc_entry(alloc_bus.lane1, tail_ptr_plus_one);
            end
        end
    end

`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
        if (rst_n && !recover.valid) begin
            assert (!alloc_valid[1] || alloc_valid[0])
                else $error("rob: alloc lane1 cannot be valid without lane0");
            assert (!commit_ready[1] || commit_ready[0])
                else $error("rob: commit lane1 ready requires lane0 ready");
        end
    end
`endif

endmodule
