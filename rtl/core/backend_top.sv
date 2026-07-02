`include "defines.svh"

// =============================================================================
// 双发射乱序后端集成顶层
// =============================================================================
module backend_top #(
    parameter int          RENAME_FIFO_DEPTH = 4,
    parameter int          MUL_LATENCY       = 3,
    parameter logic [31:0] RESET_PC          = `PC_START,
    parameter logic [31:0] MTVEC_RESET        = 32'h0000_0000,
    parameter logic [31:0] MHARTID            = 32'h0000_0000
) (
    input  logic                                      clk,
    input  logic                                      rst_n,

    input  logic                                      ds_to_rn_valid,
    input  wire core_port_pkg::ds_rn_bundle_t         ds_to_rn_bus,
    output logic                                      rn_allowin,

    output logic                                      mem_request_valid,
    output      core_port_pkg::lsq_mem_request_t      mem_request,
    input  logic                                      mem_request_ready,
    input  wire core_port_pkg::lsq_mem_response_t     mem_response,

    input  logic                                      irq_software_i,
    input  logic                                      irq_timer_i,
    input  logic                                      irq_external_i,

    output logic                                      mul_request_valid,
    output logic signed [32:0]                        mul_operand_a,
    output logic signed [32:0]                        mul_operand_b,
    input  logic signed [65:0]                        mul_product,
    output logic                                      div_dividend_valid,
    input  logic                                      div_dividend_ready,
    output logic signed [32:0]                        div_dividend_data,
    output logic                                      div_divisor_valid,
    input  logic                                      div_divisor_ready,
    output logic signed [32:0]                        div_divisor_data,
    input  logic                                      div_result_valid,
    output logic                                      div_result_ready,
    input  logic signed [32:0]                        div_quotient,
    input  logic signed [32:0]                        div_remainder,

    output      core_port_pkg::recover_event_t        recover_o,
    output      core_port_pkg::branch_update_t        branch_update_o,
    output logic                                      fence_i_commit_o,
    output      core_port_pkg::rob_commit_bundle_t    commit_bus_o,
    output logic [1:0]                                commit_fire_o,
    output logic                                      backend_idle_o
);
    import core_port_pkg::*;

    logic [1:0] rn_to_dp_valid;
    logic [1:0] dp_ready;
    rn_dp_bundle_t rn_to_dp_bus;
    commit_map_bundle_t commit_map;
    phys_reg_event_bundle_t writeback_event;

    logic dispatch_enable;
    logic serializing_pending;
    logic [1:0] rob_alloc_valid;
    rn_rob_bundle_t rob_alloc_bus;
    rob_tag_pair_t rob_alloc_tag;
    logic rob_allowin;
    logic [1:0] iq0_enq_valid, iq1_enq_valid, lsq_enq_valid;
    dp_iq_bundle_t iq0_enq_bus, iq1_enq_bus;
    dp_lsq_bundle_t lsq_enq_bus;
    dispatch_capacity_t iq0_capacity, iq1_capacity, lsq_capacity;

    rob_commit_bundle_t rob_commit_bus;
    logic [1:0] rob_commit_ready, rob_commit_fire;
    rob_complete_bundle_t rob_complete;
    logic [$clog2(ROB_DEPTH+1)-1:0] rob_occupancy;
    rob_tag_t rob_head_tag;
    rob_tag_t rob_head_tag_iq0;
    rob_tag_t rob_head_tag_iq1;
    rob_tag_t rob_head_tag_lsq;
    logic rob_empty;

    phys_reg_write_bundle_t wakeup_bus, prf_write;
    logic issue0_valid, issue0_ready, issue0_fire;
    iq_issue_slot_t issue0_bus;
    iq_prf_read_req_t issue0_prf_req;
    logic iq1_issue_valid, iq1_issue_ready;
    iq_issue_slot_t iq1_issue_bus;
    iq_prf_read_req_t iq1_prf_req_unused;
    logic lsq_issue_valid, lsq_issue_ready;
    lsq_agu_issue_t lsq_issue_bus;
    logic issue1_valid, issue1_ready, issue1_fire;
    issue1_slot_t issue1_bus;
    iq_prf_read_req_t issue1_prf_req;

    phys_reg_read_req_bundle_t prf_read_req;
    phys_reg_read_data_bundle_t prf_read_data;
    logic issue0_exec_valid, issue0_exec_ready;
    iq_issue_slot_t issue0_exec_bus;
    iq_prf_read_req_t issue0_prf_req_q;
    logic issue1_exec_valid, issue1_exec_ready;
    issue1_slot_t issue1_exec_bus;
    iq_prf_read_req_t issue1_prf_req_q;

    logic alu0_available, mlu_available, alu1_available;
    logic bru_available, csr_available, lsu_available;
    logic alu0_wb_valid, mlu_wb_valid, alu1_wb_valid;
    logic bru_wb_valid, csr_wb_valid;
    logic alu0_wb_ready, mlu_wb_ready, alu1_wb_ready;
    logic bru_wb_ready, csr_wb_ready;
    execute_writeback_t alu0_wb, mlu_wb, alu1_wb, bru_wb, csr_wb;
    csr_execute_update_t csr_update;
    lsq_agu_result_t lsu_agu_result;
    csr_read_request_t csr_read_request;
    csr_read_response_t csr_read_response;
    logic csr_commit_available;

    logic [1:0] store_commit_ready;
    logic lsq_wb_valid, lsq_wb_ready;
    lsq_writeback_t lsq_wb;
    logic [$clog2(LSQ_DEPTH+1)-1:0] lsq_occupancy;
    logic fence_commit_ready;
    logic lsq_empty_q;
    logic [`ADDR_WIDTH-1:0] retire_next_pc;

    function automatic logic serial_slot(input rn_rob_slot_t slot);
        serial_slot = slot.is_csr || slot.is_fence || slot.is_mret
                    || slot.exception_valid;
    endfunction

    assign dispatch_enable = !serializing_pending;
    assign rob_empty = (rob_occupancy == '0);
    // DMEM 请求在 Core 外还要经过固定的一拍寄存级。Store 从 LSQ 握手
    // 移除后，必须再观察一整拍 LSQ 稳定为空，才能保证该外部寄存级已经
    // 完成内存可见更新；否则 FENCE.I 的重取可能与 Store 写入同沿发生，
    // IMEM 仍会采到旧指令。
    assign fence_commit_ready = (lsq_occupancy == '0) && lsq_empty_q;
    assign commit_bus_o = rob_commit_bus;
    assign commit_fire_o = rob_commit_fire;
    assign fence_i_commit_o = (rob_commit_fire[0] && rob_commit_bus.lane0.is_fence_i)
                            || (rob_commit_fire[1] && rob_commit_bus.lane1.is_fence_i);
    assign backend_idle_o = rob_empty && fence_commit_ready
                          && !serializing_pending && csr_commit_available
                          && mlu_available && !recover_o.valid;

    always_comb begin
        writeback_event = '0;
        writeback_event.lane0.valid = wakeup_bus.lane0.valid;
        writeback_event.lane0.preg  = wakeup_bus.lane0.preg;
        writeback_event.lane1.valid = wakeup_bus.lane1.valid;
        writeback_event.lane1.preg  = wakeup_bus.lane1.preg;

        prf_read_req = '0;
        if (!recover_o.valid) begin
            if (issue0_exec_valid && issue0_exec_ready) begin
                prf_read_req.port0 = issue0_prf_req_q.src1;
                prf_read_req.port1 = issue0_prf_req_q.src2;
            end
            if (issue1_exec_valid && issue1_exec_ready) begin
                prf_read_req.port2 = issue1_prf_req_q.src1;
                prf_read_req.port3 = issue1_prf_req_q.src2;
            end
        end
    end

    assign issue0_ready = !issue0_exec_valid || issue0_exec_ready;
    assign issue1_ready = !issue1_exec_valid || issue1_exec_ready;

    always_ff @(posedge clk) begin
        if (!rst_n || recover_o.valid) begin
            issue0_exec_valid <= 1'b0;
            issue0_exec_bus   <= '0;
            issue0_prf_req_q  <= '0;
        end else if (issue0_ready) begin
            issue0_exec_valid <= issue0_valid;
            if (issue0_valid) begin
                issue0_exec_bus  <= issue0_bus;
                issue0_prf_req_q <= issue0_prf_req;
            end
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n || recover_o.valid) begin
            issue1_exec_valid <= 1'b0;
            issue1_exec_bus   <= '0;
            issue1_prf_req_q  <= '0;
        end else if (issue1_ready) begin
            issue1_exec_valid <= issue1_valid;
            if (issue1_valid) begin
                issue1_exec_bus  <= issue1_bus;
                issue1_prf_req_q <= issue1_prf_req;
            end
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n || recover_o.valid) begin
            rob_head_tag_iq0 <= '0;
            rob_head_tag_iq1 <= '0;
            rob_head_tag_lsq <= '0;
        end else begin
            rob_head_tag_iq0 <= rob_head_tag;
            rob_head_tag_iq1 <= rob_head_tag;
            rob_head_tag_lsq <= rob_head_tag;
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n || recover_o.valid)
            lsq_empty_q <= 1'b0;
        else
            lsq_empty_q <= (lsq_occupancy == '0);
    end

    always_ff @(posedge clk) begin
        if (!rst_n || recover_o.valid)
            serializing_pending <= 1'b0;
        else begin
            if ((rob_alloc_valid[0] && serial_slot(rob_alloc_bus.lane0))
                || (rob_alloc_valid[1] && serial_slot(rob_alloc_bus.lane1)))
                serializing_pending <= 1'b1;
            if ((rob_commit_fire[0]
                 && (rob_commit_bus.lane0.is_csr || rob_commit_bus.lane0.is_fence
                     || rob_commit_bus.lane0.is_mret
                     || rob_commit_bus.lane0.exception_valid))
                || (rob_commit_fire[1]
                    && (rob_commit_bus.lane1.is_csr || rob_commit_bus.lane1.is_fence
                        || rob_commit_bus.lane1.is_mret
                        || rob_commit_bus.lane1.exception_valid)))
                serializing_pending <= 1'b0;
        end
    end

    // 已提交边界的下一架构 PC。空 ROB 中断使用该值写 mepc，避免把
    // 推测取指 PC 或前端缓冲中的年轻 PC 当成精确中断返回地址。
    always_ff @(posedge clk) begin
        if (!rst_n)
            retire_next_pc <= RESET_PC;
        else if (recover_o.valid)
            retire_next_pc <= recover_o.target;
        else if (rob_commit_fire[1])
            retire_next_pc <= rob_commit_bus.lane1.next_pc_valid
                            ? rob_commit_bus.lane1.next_pc
                            : (rob_commit_bus.lane1.pc + 32'd4);
        else if (rob_commit_fire[0])
            retire_next_pc <= rob_commit_bus.lane0.next_pc_valid
                            ? rob_commit_bus.lane0.next_pc
                            : (rob_commit_bus.lane0.pc + 32'd4);
    end

    rename_stage #(.RENAME_FIFO_DEPTH(RENAME_FIFO_DEPTH)) u_rename (
        .clk(clk), .rst_n(rst_n), .ds_to_rn_valid(ds_to_rn_valid),
        .rn_allowin(rn_allowin), .ds_to_rn_bus(ds_to_rn_bus),
        .rn_to_dp_valid(rn_to_dp_valid), .dp_ready(dp_ready),
        .rn_to_dp_bus(rn_to_dp_bus), .commit_map(commit_map),
        .writeback_event(writeback_event), .recover(recover_o)
    );

    dispatch u_dispatch (
        .dispatch_enable(dispatch_enable),
        .rn_to_dp_valid(rn_to_dp_valid), .rn_to_dp_bus(rn_to_dp_bus),
        .dp_ready(dp_ready), .rob_allowin(rob_allowin),
        .rob_alloc_tag(rob_alloc_tag), .rob_alloc_valid(rob_alloc_valid),
        .rob_alloc_bus(rob_alloc_bus), .iq0_capacity(iq0_capacity),
        .iq1_capacity(iq1_capacity), .iq0_enq_valid(iq0_enq_valid),
        .iq1_enq_valid(iq1_enq_valid), .iq0_enq_bus(iq0_enq_bus),
        .iq1_enq_bus(iq1_enq_bus), .lsq_capacity(lsq_capacity),
        .lsq_enq_valid(lsq_enq_valid), .lsq_enq_bus(lsq_enq_bus)
    );

    rob u_rob (
        .clk(clk), .rst_n(rst_n), .alloc_valid(rob_alloc_valid),
        .alloc_bus(rob_alloc_bus), .rob_allowin(rob_allowin),
        .alloc_tag(rob_alloc_tag), .complete_bus(rob_complete),
        .commit_bus(rob_commit_bus), .commit_ready(rob_commit_ready),
        .commit_fire(rob_commit_fire), .commit_map(commit_map),
        .recover(recover_o), .occupancy_o(rob_occupancy),
        .head_tag_o(rob_head_tag), .head_tag_iq0(), .head_tag_iq1()
    );

    issue_queue_pair u_issue_queues (
        .clk(clk), .rst_n(rst_n), .recover(recover_o),
        .rob_head_tag_iq0(rob_head_tag_iq0),
        .rob_head_tag_iq1(rob_head_tag_iq1),
        .wakeup_bus(wakeup_bus),
        .iq0_enq_valid(iq0_enq_valid), .iq0_enq_bus(iq0_enq_bus),
        .iq0_capacity(iq0_capacity), .iq1_enq_valid(iq1_enq_valid),
        .iq1_enq_bus(iq1_enq_bus), .iq1_capacity(iq1_capacity),
        .alu0_available(alu0_available), .mlu_available(mlu_available),
        .alu1_available(alu1_available), .bru_available(bru_available),
        .csr_available(csr_available), .issue0_valid(issue0_valid),
        .issue0_bus(issue0_bus), .issue0_ready(issue0_ready),
        .issue0_fire(issue0_fire), .issue0_prf_req(issue0_prf_req),
        .issue1_valid(iq1_issue_valid), .issue1_bus(iq1_issue_bus),
        .issue1_ready(iq1_issue_ready), .issue1_fire(),
        .issue1_prf_req(iq1_prf_req_unused)
    );

    lsq u_lsq (
        .clk(clk), .rst_n(rst_n), .enq_valid(lsq_enq_valid),
        .enq_bus(lsq_enq_bus), .capacity(lsq_capacity),
        .wakeup_bus(wakeup_bus), .rob_head_tag(rob_head_tag_lsq),
        .recover(recover_o), .lsu_available(lsu_available),
        .agu_issue_valid(lsq_issue_valid), .agu_issue_bus(lsq_issue_bus),
        .agu_issue_ready(lsq_issue_ready), .agu_issue_fire(),
        .agu_result(lsu_agu_result), .commit_bus(rob_commit_bus),
        .store_commit_ready(store_commit_ready), .commit_fire(rob_commit_fire),
        .mem_request_valid(mem_request_valid), .mem_request(mem_request),
        .mem_request_ready(mem_request_ready), .mem_response(mem_response),
        .writeback_valid(lsq_wb_valid), .writeback_bus(lsq_wb),
        .writeback_ready(lsq_wb_ready), .writeback_fire(),
        .occupancy_o(lsq_occupancy)
    );

    issue1_arbiter u_issue1_arbiter (
        .rob_head_tag(rob_head_tag_lsq), .iq_valid(iq1_issue_valid),
        .iq_bus(iq1_issue_bus), .iq_ready(iq1_issue_ready),
        .lsq_valid(lsq_issue_valid), .lsq_bus(lsq_issue_bus),
        .lsq_ready(lsq_issue_ready), .issue_valid(issue1_valid),
        .issue_bus(issue1_bus), .issue_ready(issue1_ready),
        .issue_fire(issue1_fire), .prf_read_req(issue1_prf_req)
    );

    physical_regfile u_prf (
        .clk(clk), .rst_n(rst_n), .read_req(prf_read_req),
        .read_data(prf_read_data), .writeback(prf_write)
    );

    execute_stage #(.MUL_LATENCY(MUL_LATENCY)) u_execute (
        .clk(clk), .rst_n(rst_n), .recover(recover_o),
        .issue0_valid(issue0_exec_valid), .issue0_bus(issue0_exec_bus),
        .issue0_ready(issue0_exec_ready),
        .issue1_valid(issue1_exec_valid), .issue1_bus(issue1_exec_bus),
        .issue1_ready(issue1_exec_ready),
        .prf_read_data(prf_read_data), .alu0_available(alu0_available),
        .mlu_available(mlu_available), .alu1_available(alu1_available),
        .bru_available(bru_available), .csr_available(csr_available),
        .lsu_available(lsu_available), .alu0_wb_valid(alu0_wb_valid),
        .alu0_wb(alu0_wb), .alu0_wb_ready(alu0_wb_ready),
        .mlu_wb_valid(mlu_wb_valid), .mlu_wb(mlu_wb),
        .mlu_wb_ready(mlu_wb_ready), .alu1_wb_valid(alu1_wb_valid),
        .alu1_wb(alu1_wb), .alu1_wb_ready(alu1_wb_ready),
        .bru_wb_valid(bru_wb_valid), .bru_wb(bru_wb),
        .bru_wb_ready(bru_wb_ready), .csr_wb_valid(csr_wb_valid),
        .csr_wb(csr_wb), .csr_update(csr_update),
        .csr_wb_ready(csr_wb_ready), .lsu_agu_result(lsu_agu_result),
        .csr_commit_available(csr_commit_available),
        .csr_read_request(csr_read_request), .csr_read_response(csr_read_response),
        .mul_request_valid(mul_request_valid), .mul_operand_a(mul_operand_a),
        .mul_operand_b(mul_operand_b), .mul_product(mul_product),
        .div_dividend_valid(div_dividend_valid),
        .div_dividend_ready(div_dividend_ready),
        .div_dividend_data(div_dividend_data),
        .div_divisor_valid(div_divisor_valid), .div_divisor_ready(div_divisor_ready),
        .div_divisor_data(div_divisor_data), .div_result_valid(div_result_valid),
        .div_result_ready(div_result_ready), .div_quotient(div_quotient),
        .div_remainder(div_remainder)
    );

    writeback_commit_stage #(.MTVEC_RESET(MTVEC_RESET), .MHARTID(MHARTID))
    u_writeback_commit (
        .clk(clk), .rst_n(rst_n), .alu0_valid(alu0_wb_valid),
        .alu0_bus(alu0_wb), .alu0_ready(alu0_wb_ready),
        .mlu_valid(mlu_wb_valid), .mlu_bus(mlu_wb), .mlu_ready(mlu_wb_ready),
        .alu1_valid(alu1_wb_valid), .alu1_bus(alu1_wb),
        .alu1_ready(alu1_wb_ready), .bru_valid(bru_wb_valid),
        .bru_bus(bru_wb), .bru_ready(bru_wb_ready), .lsq_valid(lsq_wb_valid),
        .lsq_bus(lsq_wb), .lsq_ready(lsq_wb_ready), .csr_valid(csr_wb_valid),
        .csr_bus(csr_wb), .csr_update(csr_update), .csr_ready(csr_wb_ready),
        .csr_read_request(csr_read_request), .csr_read_response(csr_read_response),
        .csr_commit_available(csr_commit_available), .rob_commit_bus(rob_commit_bus),
        .rob_commit_fire(rob_commit_fire), .store_commit_ready(store_commit_ready),
        .fence_commit_ready(fence_commit_ready), .rob_empty(rob_empty),
        .interrupt_pc(retire_next_pc), .rob_commit_ready(rob_commit_ready),
        .irq_software_i(irq_software_i), .irq_timer_i(irq_timer_i),
        .irq_external_i(irq_external_i), .recover(recover_o),
        .prf_write(prf_write), .wakeup_bus(wakeup_bus),
        .rob_complete(rob_complete), .branch_update(branch_update_o)
    );

`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
        if (rst_n && !recover_o.valid) begin
            assert (!(serializing_pending && (|rob_alloc_valid)))
                else $error("backend_top: dispatch crossed serializing boundary");
            assert (!(rob_alloc_valid[0] && serial_slot(rob_alloc_bus.lane0)
                      && rob_alloc_valid[1]))
                else $error("backend_top: lane1 entered behind serializing lane0");
            if (fence_i_commit_o)
                assert (fence_commit_ready)
                    else $error("backend_top: FENCE.I committed before LSQ drained");
        end
    end
`endif

endmodule
