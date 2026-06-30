`timescale 1ns/1ps

module tb_lsu_four_cycle;
    import core_port_pkg::*;

    logic clk;
    logic rst_n;
    recover_event_t recover;
    logic [1:0] enq_valid;
    dp_lsq_bundle_t enq_bus;
    dispatch_capacity_t capacity;
    phys_reg_write_bundle_t wakeup_bus;
    rob_tag_t rob_head_tag;
    logic agu_issue_valid, agu_issue_ready, agu_issue_fire;
    lsq_agu_issue_t agu_issue_bus;
    lsq_agu_result_t agu_result;
    rob_commit_bundle_t commit_bus;
    logic [1:0] store_commit_ready, commit_fire;
    logic mem_request_valid, mem_request_ready;
    lsq_mem_request_t mem_request;
    lsq_mem_response_t mem_response;
    logic writeback_valid, writeback_ready, writeback_fire;
    lsq_writeback_t writeback_bus;

    logic issue_valid, issue_ready, issue_fire;
    issue1_slot_t issue_bus;
    iq_prf_read_req_t issue_prf_req;
    phys_reg_read_req_bundle_t prf_read_req;
    phys_reg_read_data_bundle_t prf_read_data;
    phys_reg_write_bundle_t prf_writeback;
    logic operand_valid, operand_ready;
    execute_operand_t operand_bus;

    integer edge_count;
    integer issue_edge;
    integer request_edge;

    lsq u_lsq (
        .clk(clk), .rst_n(rst_n),
        .enq_valid(enq_valid), .enq_bus(enq_bus), .capacity(capacity),
        .wakeup_bus(wakeup_bus), .rob_head_tag(rob_head_tag),
        .recover(recover), .lsu_available(1'b1),
        .agu_issue_valid(agu_issue_valid), .agu_issue_bus(agu_issue_bus),
        .agu_issue_ready(agu_issue_ready), .agu_issue_fire(agu_issue_fire),
        .agu_result(agu_result),
        .commit_bus(commit_bus), .store_commit_ready(store_commit_ready),
        .commit_fire(commit_fire),
        .mem_request_valid(mem_request_valid), .mem_request(mem_request),
        .mem_request_ready(mem_request_ready), .mem_response(mem_response),
        .writeback_valid(writeback_valid), .writeback_bus(writeback_bus),
        .writeback_ready(writeback_ready), .writeback_fire(writeback_fire),
        .occupancy_o()
    );

    issue1_arbiter u_issue1 (
        .rob_head_tag(rob_head_tag),
        .iq_valid(1'b0), .iq_bus('0), .iq_ready(),
        .lsq_valid(agu_issue_valid), .lsq_bus(agu_issue_bus),
        .lsq_ready(agu_issue_ready),
        .issue_valid(issue_valid), .issue_bus(issue_bus),
        .issue_ready(issue_ready), .issue_fire(issue_fire),
        .prf_read_req(issue_prf_req)
    );

    always_comb begin
        prf_read_req = '0;
        prf_read_req.port2 = issue_prf_req.src1;
        prf_read_req.port3 = issue_prf_req.src2;
    end

    physical_regfile u_prf (
        .clk(clk), .rst_n(rst_n), .read_req(prf_read_req),
        .read_data(prf_read_data), .writeback(prf_writeback)
    );

    operand_read_stage u_operand (
        .clk(clk), .rst_n(rst_n), .recover(recover),
        .in_valid(issue_valid), .in_bus(issue_bus), .in_ready(issue_ready),
        .prf_src1(prf_read_data.port2), .prf_src2(prf_read_data.port3),
        .out_valid(operand_valid), .out_bus(operand_bus),
        .out_ready(operand_ready)
    );

    lsu_unit u_agu (
        .recover_valid(recover.valid),
        .in_valid(operand_valid), .in_bus(operand_bus),
        .in_ready(operand_ready), .agu_result(agu_result)
    );

    always #5 clk = ~clk;

    // 同步单周期 DMEM 模型。请求在第 3 个边沿后握手，read_data 在该边沿
    // 后进入第 4 个流水周期；下一边沿由 LSQ 采样。
    always @(posedge clk) begin
        edge_count = edge_count + 1;
        if (rst_n && agu_issue_fire)
            issue_edge = edge_count;

        if (!rst_n) begin
            mem_response <= '0;
        end else begin
            mem_response.valid <= 1'b0;
            if (mem_request_valid && mem_request_ready
                && !mem_request.is_store) begin
                request_edge = edge_count;
                assert ((edge_count - issue_edge) == 3)
                    else $fatal(1,
                        "LSU request register timing is not fourth-cycle: issue=%0d request=%0d",
                        issue_edge, edge_count);
                mem_response.valid     <= 1'b1;
                mem_response.lsq_tag   <= mem_request.lsq_tag;
                mem_response.read_data <= 32'h89ab_cdef;
            end
        end
    end

    task automatic cycle;
        @(posedge clk);
        #1;
    endtask

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        recover = '0;
        enq_valid = '0;
        enq_bus = '0;
        wakeup_bus = '0;
        rob_head_tag = '0;
        commit_bus = '0;
        commit_fire = '0;
        mem_request_ready = 1'b1;
        mem_response = '0;
        writeback_ready = 1'b1;
        prf_writeback = '0;
        edge_count = 0;
        issue_edge = -1;
        request_edge = -1;

        repeat (2) cycle();
        rst_n = 1'b1;

        // 建立 Load base p5 = 0x1000。
        prf_writeback.lane0.valid = 1'b1;
        prf_writeback.lane0.preg  = phys_reg_idx_t'(5);
        prf_writeback.lane0.data  = 32'h0000_1000;
        cycle();
        prf_writeback = '0;

        enq_bus.lane0 = '0;
        enq_bus.lane0.rob_tag = rob_tag_t'(0);
        enq_bus.lane0.uop.dec.fu_type = FU_LSU;
        enq_bus.lane0.uop.dec.mem_op = MEM_WORD;
        enq_bus.lane0.uop.dec.use_rs1 = 1'b1;
        enq_bus.lane0.uop.dec.imm = 32'h40;
        enq_bus.lane0.uop.prs1 = phys_reg_idx_t'(5);
        enq_bus.lane0.uop.src1_ready = 1'b1;
        enq_bus.lane0.uop.pdst_valid = 1'b1;
        enq_bus.lane0.uop.pdst = phys_reg_idx_t'(6);
        enq_valid = 2'b01;
        cycle();
        enq_valid = '0;

        while ((issue_edge < 0) || (request_edge < 0))
            cycle();
        while (!writeback_valid)
            cycle();

        assert (writeback_bus.pdst_valid
                && (writeback_bus.pdst == phys_reg_idx_t'(6))
                && (writeback_bus.data == 32'h89ab_cdef))
            else $fatal(1, "four-cycle LSU load data/writeback failed");

        $display("PASS: LSU issue -> external request register -> fourth-cycle DMEM result");
        $finish;
    end

endmodule
