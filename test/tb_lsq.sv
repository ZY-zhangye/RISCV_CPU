`timescale 1ns/1ps
`include "defines.svh"

module tb_lsq;
    import core_port_pkg::*;

    logic clk;
    logic rst_n;
    logic [1:0] enq_valid;
    dp_lsq_bundle_t enq_bus;
    dispatch_capacity_t capacity;
    phys_reg_write_bundle_t wakeup_bus;
    rob_tag_t rob_head_tag;
    recover_event_t recover;
    logic lsu_available;
    logic agu_issue_valid;
    lsq_agu_issue_t agu_issue_bus;
    logic agu_issue_ready;
    logic agu_issue_fire;
    lsq_agu_result_t agu_result;
    rob_commit_bundle_t commit_bus;
    logic [1:0] store_commit_ready;
    logic [1:0] commit_fire;
    logic mem_request_valid;
    lsq_mem_request_t mem_request;
    logic mem_request_ready;
    lsq_mem_response_t mem_response;
    logic writeback_valid;
    lsq_writeback_t writeback_bus;
    logic writeback_ready;
    logic writeback_fire;
    logic [$clog2(LSQ_DEPTH+1)-1:0] occupancy;

    // issue1 arbiter 的另一侧使用测试 IQ 候选。
    logic iq_candidate_valid;
    iq_issue_slot_t iq_candidate_bus;
    logic iq_candidate_ready;
    logic issue1_valid;
    issue1_slot_t issue1_bus;
    logic issue1_ready;
    logic issue1_fire;
    iq_prf_read_req_t issue1_prf_req;

    lsq u_lsq (
        .clk                (clk),
        .rst_n              (rst_n),
        .enq_valid          (enq_valid),
        .enq_bus            (enq_bus),
        .capacity           (capacity),
        .wakeup_bus         (wakeup_bus),
        .rob_head_tag       (rob_head_tag),
        .recover            (recover),
        .lsu_available      (lsu_available),
        .agu_issue_valid    (agu_issue_valid),
        .agu_issue_bus      (agu_issue_bus),
        .agu_issue_ready    (agu_issue_ready),
        .agu_issue_fire     (agu_issue_fire),
        .agu_result         (agu_result),
        .commit_bus         (commit_bus),
        .store_commit_ready (store_commit_ready),
        .commit_fire        (commit_fire),
        .mem_request_valid  (mem_request_valid),
        .mem_request        (mem_request),
        .mem_request_ready  (mem_request_ready),
        .mem_response       (mem_response),
        .writeback_valid    (writeback_valid),
        .writeback_bus      (writeback_bus),
        .writeback_ready    (writeback_ready),
        .writeback_fire     (writeback_fire),
        .occupancy_o        (occupancy)
    );

    issue1_arbiter u_issue1_arbiter (
        .rob_head_tag (rob_head_tag),
        .iq_valid     (iq_candidate_valid),
        .iq_bus       (iq_candidate_bus),
        .iq_ready     (iq_candidate_ready),
        .lsq_valid    (agu_issue_valid),
        .lsq_bus      (agu_issue_bus),
        .lsq_ready    (agu_issue_ready),
        .issue_valid  (issue1_valid),
        .issue_bus    (issue1_bus),
        .issue_ready  (issue1_ready),
        .issue_fire   (issue1_fire),
        .prf_read_req (issue1_prf_req)
    );

    always #5 clk = ~clk;

    task automatic cycle;
        @(posedge clk);
        #1;
    endtask

    task automatic clear_inputs;
        enq_valid          = '0;
        enq_bus            = '0;
        wakeup_bus         = '0;
        rob_head_tag       = '0;
        recover            = '0;
        lsu_available      = 1'b1;
        agu_result         = '0;
        commit_bus         = '0;
        commit_fire        = '0;
        mem_request_ready  = 1'b0;
        mem_response       = '0;
        writeback_ready    = 1'b0;
        iq_candidate_valid = 1'b0;
        iq_candidate_bus   = '0;
        issue1_ready       = 1'b1;
    endtask

    task automatic clear_lsq;
        begin
            enq_valid    = '0;
            wakeup_bus   = '0;
            agu_result   = '0;
            commit_fire  = '0;
            commit_bus   = '0;
            mem_response = '0;
            recover.valid  = 1'b1;
            recover.reason = RECOVER_BRANCH;
            cycle();
            clear_inputs();
            #1;
            assert ((occupancy == 0) && (capacity == 2)
                    && !agu_issue_valid && !writeback_valid)
                else $fatal(1, "LSQ recovery did not clear speculative state");
        end
    endtask

    task automatic fill_mem_slot(
        output dp_lsq_slot_t slot,
        input  rob_tag_t    rob_tag,
        input  logic        is_store,
        input  mem_op_e     mem_op,
        input  logic [5:0]  prs1,
        input  logic        src1_ready,
        input  logic [5:0]  prs2,
        input  logic        src2_ready,
        input  logic [5:0]  pdst
    );
        begin
            slot                     = '0;
            slot.rob_tag             = rob_tag;
            slot.uop.dec.valid       = 1'b1;
            slot.uop.dec.fu_type     = FU_LSU;
            slot.uop.dec.mem_write   = is_store;
            slot.uop.dec.mem_op      = mem_op;
            slot.uop.dec.use_rs1     = 1'b1;
            slot.uop.dec.use_rs2     = is_store;
            slot.uop.prs1            = prs1;
            slot.uop.prs2            = prs2;
            slot.uop.src1_ready      = src1_ready;
            slot.uop.src2_ready      = src2_ready;
            slot.uop.pdst            = pdst;
            slot.uop.pdst_valid      = !is_store;
        end
    endtask

    task automatic send_agu_result(
        input lsq_tag_t tag,
        input logic [31:0] address,
        input logic store_data_valid,
        input logic [31:0] store_data
    );
        begin
            agu_result = '0;
            agu_result.valid            = 1'b1;
            agu_result.lsq_tag          = tag;
            agu_result.address          = address;
            agu_result.store_data_valid = store_data_valid;
            agu_result.store_data       = store_data;
            cycle();
            agu_result = '0;
        end
    endtask

    lsq_tag_t store_tag;
    lsq_tag_t load_tag;
    lsq_tag_t store_tag1;
    integer store_wb_count;

    initial begin
        clk   = 1'b0;
        rst_n = 1'b0;
        clear_inputs();
        repeat (2) cycle();
        rst_n = 1'b1;
        cycle();
        assert ((capacity == 2) && (occupancy == 0))
            else $fatal(1, "LSQ reset state is wrong");

        // ------------------------------------------------------------------
        // Store 地址与数据解耦；已提交 Store 在 recovery 中必须保留。
        // ------------------------------------------------------------------
        fill_mem_slot(enq_bus.lane0, rob_tag_t'(0), 1'b1, MEM_WORD,
                      6'd5, 1'b1, 6'd6, 1'b0, '0);
        enq_valid = 2'b01;
        cycle();
        enq_valid = '0;
        #1;
        assert (issue1_valid && issue1_bus.from_lsq
                && !issue1_bus.read_store_data)
            else $fatal(1, "Store address did not issue independently of data");
        store_tag = issue1_bus.lsq_tag;
        assert (issue1_fire && !issue1_prf_req.src2.valid)
            else $fatal(1, "Store data PRF read should be suppressed while not ready");
        cycle();

        send_agu_result(store_tag, 32'h0000_1000, 1'b0, '0);
        assert (!writeback_valid)
            else $fatal(1, "Store completed before data became ready");

        wakeup_bus.lane0 = '{valid: 1'b1, preg: 6'd6, data: 32'h1122_3344};
        cycle();
        wakeup_bus = '0;
        cycle();
        #1;
        assert (writeback_valid && !writeback_bus.pdst_valid
                && (writeback_bus.rob_tag == rob_tag_t'(0)))
            else $fatal(1, "Store did not complete after broadcast data arrived");
        writeback_ready = 1'b1;
        cycle();
        writeback_ready = 1'b0;

        commit_bus.lane0.valid    = 1'b1;
        commit_bus.lane0.tag      = rob_tag_t'(0);
        commit_bus.lane0.is_store = 1'b1;
        #1;
        assert (store_commit_ready[0])
            else $fatal(1, "prepared Store blocked ROB commit");
        commit_fire = 2'b01;
        cycle();
        commit_bus  = '0;
        commit_fire = '0;
        cycle();
        #1;
        assert (mem_request_valid && mem_request.is_store
                && (mem_request.address == 32'h1000)
                && (mem_request.write_data == 32'h1122_3344)
                && (mem_request.write_strobe == 4'b1111))
            else $fatal(1, "committed Store did not enter registered memory request");

        recover.valid  = 1'b1;
        recover.reason = RECOVER_EXCEPTION;
        cycle();
        recover = '0;
        #1;
        assert (mem_request_valid && (occupancy == 1))
            else $fatal(1, "recovery incorrectly discarded committed Store");
        mem_request_ready = 1'b1;
        cycle();
        mem_request_ready = 1'b0;
        assert ((occupancy == 0) && !mem_request_valid)
            else $fatal(1, "accepted committed Store was not drained");

        // 双 Store 同拍提交后即使发生 recovery，也必须保持提交顺序排空。
        fill_mem_slot(enq_bus.lane0, rob_tag_t'(0), 1'b1, MEM_WORD,
                      6'd1, 1'b1, 6'd2, 1'b1, '0);
        fill_mem_slot(enq_bus.lane1, rob_tag_t'(1), 1'b1, MEM_WORD,
                      6'd3, 1'b1, 6'd4, 1'b1, '0);
        enq_valid = 2'b11;
        cycle();
        enq_valid = '0;
        store_tag = issue1_bus.lsq_tag;
        cycle();
        store_tag1 = issue1_bus.lsq_tag;
        send_agu_result(store_tag, 32'h0000_1800, 1'b1, 32'h1111_1111);
        send_agu_result(store_tag1, 32'h0000_1804, 1'b1, 32'h2222_2222);

        writeback_ready = 1'b1;
        store_wb_count = 0;
        while (store_wb_count < 2) begin
            #1;
            if (writeback_fire)
                store_wb_count = store_wb_count + 1;
            cycle();
        end
        writeback_ready = 1'b0;

        commit_bus.lane0.valid    = 1'b1;
        commit_bus.lane0.tag      = rob_tag_t'(0);
        commit_bus.lane0.is_store = 1'b1;
        commit_bus.lane1.valid    = 1'b1;
        commit_bus.lane1.tag      = rob_tag_t'(1);
        commit_bus.lane1.is_store = 1'b1;
        #1;
        assert (store_commit_ready == 2'b11)
            else $fatal(1, "dual prepared Stores blocked commit");
        commit_fire = 2'b11;
        cycle();
        commit_fire = '0;
        commit_bus  = '0;
        recover.valid  = 1'b1;
        recover.reason = RECOVER_BRANCH;
        cycle();
        recover = '0;
        cycle();
        #1;
        assert (mem_request_valid && mem_request.is_store
                && (mem_request.address == 32'h1800))
            else $fatal(1, "first committed Store lost order across recovery");
        mem_request_ready = 1'b1;
        cycle();
        mem_request_ready = 1'b0;
        cycle();
        #1;
        assert (mem_request_valid && mem_request.is_store
                && (mem_request.address == 32'h1804))
            else $fatal(1, "second committed Store lost order across recovery");
        mem_request_ready = 1'b1;
        cycle();
        mem_request_ready = 1'b0;
        assert (occupancy == 0)
            else $fatal(1, "dual committed Stores did not drain");

        // ------------------------------------------------------------------
        // 未知老 Store 地址阻塞年轻 Load；issue1 按 ROB 年龄仲裁。
        // ------------------------------------------------------------------
        fill_mem_slot(enq_bus.lane0, rob_tag_t'(0), 1'b1, MEM_WORD,
                      6'd10, 1'b0, 6'd11, 1'b1, '0);
        fill_mem_slot(enq_bus.lane1, rob_tag_t'(1), 1'b0, MEM_WORD,
                      6'd12, 1'b1, '0, 1'b1, 6'd40);
        enq_valid = 2'b11;
        cycle();
        enq_valid = '0;

        // 制造更老 IQ1 候选；仲裁应先给 IQ，LSQ 候选被锁存。
        iq_candidate_valid       = 1'b1;
        iq_candidate_bus.rob_tag = rob_tag_t'(0);
        iq_candidate_bus.uop.dec.fu_type = FU_ALU;
        #1;
        assert (issue1_fire && !issue1_bus.from_lsq && iq_candidate_ready)
            else $fatal(1, "issue1 did not choose older IQ1 candidate");
        cycle();
        iq_candidate_valid = 1'b0;
        #1;
        assert (issue1_fire && issue1_bus.from_lsq
                && (issue1_bus.rob_tag == rob_tag_t'(1)))
            else $fatal(1, "held LSQ candidate did not issue after IQ1");
        load_tag = issue1_bus.lsq_tag;
        cycle();
        send_agu_result(load_tag, 32'h0000_2000, 1'b0, '0);
        cycle();
        assert (!mem_request_valid)
            else $fatal(1, "Load crossed an older Store with unknown address");

        wakeup_bus.lane0 = '{valid: 1'b1, preg: 6'd10, data: 32'h0000_3000};
        #1;
        assert (issue1_fire && issue1_bus.from_lsq
                && issue1_bus.read_store_data)
            else $fatal(1, "older Store did not issue after base wakeup");
        store_tag = issue1_bus.lsq_tag;
        cycle();
        wakeup_bus = '0;
        send_agu_result(store_tag, 32'h0000_3000, 1'b1, 32'haabb_ccdd);
        cycle();
        #1;
        assert (mem_request_valid && !mem_request.is_store
                && (mem_request.lsq_tag == load_tag))
            else $fatal(1, "safe non-aliasing Load did not issue to memory");

        // 先接收 Store 完成事件，再接收内存请求和 Load response。
        if (writeback_valid) begin
            writeback_ready = 1'b1;
            cycle();
            writeback_ready = 1'b0;
        end
        mem_request_ready = 1'b1;
        cycle();
        mem_request_ready = 1'b0;
        mem_response.valid     = 1'b1;
        mem_response.lsq_tag   = load_tag;
        mem_response.read_data = 32'h5566_7788;
        cycle();
        mem_response = '0;
        cycle();
        #1;
        assert (writeback_valid && writeback_bus.pdst_valid
                && (writeback_bus.pdst == 6'd40)
                && (writeback_bus.data == 32'h5566_7788))
            else $fatal(1, "Load response did not produce WB1 payload");
        writeback_ready = 1'b1;
        cycle();
        writeback_ready = 1'b0;
        clear_lsq();

        // ------------------------------------------------------------------
        // 完整覆盖 Store-to-Load forwarding，不产生 DMEM Load 请求。
        // ------------------------------------------------------------------
        fill_mem_slot(enq_bus.lane0, rob_tag_t'(0), 1'b1, MEM_WORD,
                      6'd1, 1'b1, 6'd2, 1'b1, '0);
        fill_mem_slot(enq_bus.lane1, rob_tag_t'(1), 1'b0, MEM_WORD,
                      6'd3, 1'b1, '0, 1'b1, 6'd41);
        enq_valid = 2'b11;
        cycle();
        enq_valid = '0;
        store_tag = issue1_bus.lsq_tag;
        cycle();
        #1;
        load_tag = issue1_bus.lsq_tag;
        send_agu_result(store_tag, 32'h0000_4000, 1'b1, 32'hcafe_babe);
        send_agu_result(load_tag, 32'h0000_4000, 1'b0, '0);
        // Store 完成事件先占用 buffer。
        cycle();
        if (writeback_valid) begin
            writeback_ready = 1'b1;
            cycle();
            writeback_ready = 1'b0;
        end
        cycle();
        #1;
        assert (!mem_request_valid && writeback_valid
                && writeback_bus.pdst_valid
                && (writeback_bus.data == 32'hcafe_babe))
            else $fatal(1, "Store-to-Load forwarding failed or touched DMEM");
        writeback_ready = 1'b1;
        cycle();
        writeback_ready = 1'b0;
        clear_lsq();

        // ------------------------------------------------------------------
        // 部分覆盖采取保守等待；地址未对齐通过统一异常完成路径上报。
        // ------------------------------------------------------------------
        fill_mem_slot(enq_bus.lane0, rob_tag_t'(0), 1'b1, MEM_BYTE,
                      6'd1, 1'b1, 6'd2, 1'b1, '0);
        fill_mem_slot(enq_bus.lane1, rob_tag_t'(1), 1'b0, MEM_WORD,
                      6'd3, 1'b1, '0, 1'b1, 6'd42);
        enq_valid = 2'b11;
        cycle();
        enq_valid = '0;
        store_tag = issue1_bus.lsq_tag;
        cycle();
        #1;
        load_tag = issue1_bus.lsq_tag;
        send_agu_result(store_tag, 32'h0000_5001, 1'b1, 32'h0000_00aa);
        send_agu_result(load_tag, 32'h0000_5000, 1'b0, '0);
        repeat (2) cycle();
        assert (!mem_request_valid)
            else $fatal(1, "partially covered Load should wait conservatively");
        clear_lsq();

        fill_mem_slot(enq_bus.lane0, rob_tag_t'(0), 1'b0, MEM_WORD,
                      6'd3, 1'b1, '0, 1'b1, 6'd43);
        enq_valid = 2'b01;
        cycle();
        enq_valid = '0;
        load_tag = issue1_bus.lsq_tag;
        cycle();
        send_agu_result(load_tag, 32'h0000_6002, 1'b0, '0);
        cycle();
        #1;
        assert (writeback_valid && writeback_bus.exception_valid
                && (writeback_bus.exc_code == `EXC_LOAD_MISALIGNED)
                && !mem_request_valid)
            else $fatal(1, "misaligned Load did not use ROB exception path");

        $display("PASS: out-of-order LSQ + issue1 arbitration + unified recovery");
        $finish;
    end

endmodule
