`timescale 1ns/1ps

module tb_rename_state;
    import core_port_pkg::*;

    logic clk;
    logic rst_n;

    logic [1:0] alloc_req;
    logic [1:0] alloc_valid;
    phys_reg_pair_t alloc_preg;
    logic [1:0] alloc_fire;
    phys_reg_event_bundle_t free_event;
    logic [PHYS_REG_COUNT-1:0] free_bitmap;
    logic [$clog2(PHYS_REG_COUNT+1)-1:0] free_count;

    rat_rename_req_bundle_t rename_req;
    logic [1:0] rename_fire;
    rat_rename_rsp_bundle_t rename_rsp;
    commit_map_bundle_t commit_map;
    logic [PHYS_REG_COUNT-1:0] recover_used_mask;

    busy_query_bundle_t busy_query;
    busy_ready_bundle_t busy_ready;
    phys_reg_event_bundle_t alloc_event;
    phys_reg_event_bundle_t writeback_event;
    logic [PHYS_REG_COUNT-1:0] busy_bitmap;

    recover_event_t recover;
    integer exhaust_idx;

    free_list u_free_list (
        .clk               (clk),
        .rst_n             (rst_n),
        .alloc_req         (alloc_req),
        .alloc_valid       (alloc_valid),
        .alloc_preg        (alloc_preg),
        .alloc_fire        (alloc_fire),
        .free_event        (free_event),
        .recover           (recover),
        .recover_used_mask (recover_used_mask),
        .free_bitmap_o     (free_bitmap),
        .free_count_o      (free_count)
    );

    rat_rrat u_rat_rrat (
        .clk               (clk),
        .rst_n             (rst_n),
        .rename_req        (rename_req),
        .rename_fire       (rename_fire),
        .rename_rsp        (rename_rsp),
        .commit_map        (commit_map),
        .recover           (recover),
        .recover_used_mask (recover_used_mask)
    );

    busy_table u_busy_table (
        .clk             (clk),
        .rst_n           (rst_n),
        .query           (busy_query),
        .ready           (busy_ready),
        .alloc_event     (alloc_event),
        .writeback_event (writeback_event),
        .recover         (recover),
        .busy_bitmap_o   (busy_bitmap)
    );

    always #5 clk = ~clk;

    task automatic cycle;
        @(posedge clk);
        #1;
    endtask

    task automatic clear_inputs;
        alloc_req       = '0;
        alloc_fire      = '0;
        free_event      = '0;
        rename_req      = '0;
        rename_fire     = '0;
        commit_map      = '0;
        busy_query      = '0;
        alloc_event     = '0;
        writeback_event = '0;
        recover         = '0;
    endtask

    initial begin
        clk   = 1'b0;
        rst_n = 1'b0;
        clear_inputs();

        repeat (2) cycle();
        rst_n = 1'b1;
        cycle();

        // Reset: xN -> pN，只有 p32..p63 空闲，p0 永不 busy/free。
        assert (free_count == 32)
            else $fatal(1, "reset free_count expected 32, got %0d", free_count);
        assert (!free_bitmap[0] && free_bitmap[32] && free_bitmap[63])
            else $fatal(1, "free list reset map is wrong");
        assert (busy_bitmap == '0)
            else $fatal(1, "busy table must be clear after reset");

        // 双路重命名：lane0 x5->p32，lane1 x5->p33。
        // lane1 读取 x5，必须旁路到 p32，且同拍观察为 not ready。
        alloc_req = 2'b11;
        #1;
        assert (alloc_valid == 2'b11)
            else $fatal(1, "two allocations should be available");
        assert ((alloc_preg.lane0 == 6'd32) && (alloc_preg.lane1 == 6'd33))
            else $fatal(1, "unexpected initial allocation p%0d/p%0d",
                        alloc_preg.lane0, alloc_preg.lane1);

        rename_req.lane0.rd         = 5'd5;
        rename_req.lane0.pdst_valid = 1'b1;
        rename_req.lane0.pdst       = alloc_preg.lane0;
        rename_req.lane1.use_rs1    = 1'b1;
        rename_req.lane1.rs1        = 5'd5;
        rename_req.lane1.rd         = 5'd5;
        rename_req.lane1.pdst_valid = 1'b1;
        rename_req.lane1.pdst       = alloc_preg.lane1;
        rename_fire                 = 2'b11;
        alloc_fire                  = 2'b11;

        alloc_event.lane0.valid = 1'b1;
        alloc_event.lane0.preg  = alloc_preg.lane0;
        alloc_event.lane1.valid = 1'b1;
        alloc_event.lane1.preg  = alloc_preg.lane1;

        busy_query.lane1.use_src1 = 1'b1;
        busy_query.lane1.prs1     = alloc_preg.lane0;
        #1;
        assert (rename_rsp.lane0.stale_pdst == 6'd5)
            else $fatal(1, "lane0 stale pdst mismatch");
        assert (rename_rsp.lane1.prs1 == 6'd32)
            else $fatal(1, "lane1 RAW bypass mismatch");
        assert (rename_rsp.lane1.stale_pdst == 6'd32)
            else $fatal(1, "lane1 WAW stale pdst mismatch");
        assert (!busy_ready.lane1.src1_ready)
            else $fatal(1, "new lane0 destination must not be ready for lane1");

        cycle();
        clear_inputs();
        #1;
        assert ((free_count == 30) && busy_bitmap[32] && busy_bitmap[33])
            else $fatal(1, "allocation state update failed");

        // 查询更新后的 RAT，x5 应指向 lane1 的 p33。
        rename_req.lane0.use_rs1 = 1'b1;
        rename_req.lane0.rs1     = 5'd5;
        #1;
        assert (rename_rsp.lane0.prs1 == 6'd33)
            else $fatal(1, "RAT final WAW mapping should be p33");

        // 写回旁路当拍应 ready，时钟后 Busy bit 清零。
        busy_query.lane0.use_src1 = 1'b1;
        busy_query.lane0.prs1     = 6'd32;
        writeback_event.lane0.valid = 1'b1;
        writeback_event.lane0.preg  = 6'd32;
        writeback_event.lane1.valid = 1'b1;
        writeback_event.lane1.preg  = 6'd33;
        #1;
        assert (busy_ready.lane0.src1_ready)
            else $fatal(1, "writeback bypass should make source ready");
        cycle();
        clear_inputs();
        assert (!busy_bitmap[32] && !busy_bitmap[33])
            else $fatal(1, "writeback failed to clear busy bits");

        // 双提交同一架构寄存器：RRAT 最终指向 p33，同时回收 p5 和 p32。
        commit_map.lane0.valid      = 1'b1;
        commit_map.lane0.rd         = 5'd5;
        commit_map.lane0.pdst       = 6'd32;
        commit_map.lane0.stale_pdst = 6'd5;
        commit_map.lane1.valid      = 1'b1;
        commit_map.lane1.rd         = 5'd5;
        commit_map.lane1.pdst       = 6'd33;
        commit_map.lane1.stale_pdst = 6'd32;
        free_event.lane0.valid      = 1'b1;
        free_event.lane0.preg       = 6'd5;
        free_event.lane1.valid      = 1'b1;
        free_event.lane1.preg       = 6'd32;
        cycle();
        clear_inputs();
        assert (free_count == 32)
            else $fatal(1, "commit should reclaim two stale destinations");

        // 建立一个未提交的 x5->p5 推测映射，再通过统一恢复事件回到 RRAT 的 p33。
        alloc_req = 2'b01;
        #1;
        assert (alloc_preg.lane0 == 6'd5)
            else $fatal(1, "lowest reclaimed preg should be p5");
        rename_req.lane0.rd         = 5'd5;
        rename_req.lane0.pdst_valid = 1'b1;
        rename_req.lane0.pdst       = alloc_preg.lane0;
        rename_fire[0]              = 1'b1;
        alloc_fire[0]               = 1'b1;
        alloc_event.lane0.valid     = 1'b1;
        alloc_event.lane0.preg      = alloc_preg.lane0;
        cycle();
        clear_inputs();

        rename_req.lane0.use_rs1 = 1'b1;
        rename_req.lane0.rs1     = 5'd5;
        #1;
        assert (rename_rsp.lane0.prs1 == 6'd5)
            else $fatal(1, "speculative RAT update failed");

        recover.valid  = 1'b1;
        recover.reason = RECOVER_BRANCH;
        recover.target = 32'h0000_1000;
        cycle();
        clear_inputs();

        rename_req.lane0.use_rs1 = 1'b1;
        rename_req.lane0.rs1     = 5'd5;
        #1;
        assert (rename_rsp.lane0.prs1 == 6'd33)
            else $fatal(1, "RAT did not recover from RRAT");
        assert (free_bitmap[5] && free_bitmap[32] && !free_bitmap[33])
            else $fatal(1, "free list recovery does not match RRAT live set");
        assert (busy_bitmap == '0)
            else $fatal(1, "busy table must clear on recovery");

        // 同一 preg 同拍写回并重新分配时，新的生命周期必须保持 not ready。
        busy_query = '0;
        alloc_event = '0;
        writeback_event = '0;
        busy_query.lane0.use_src1 = 1'b1;
        busy_query.lane0.prs1     = 6'd40;
        alloc_event.lane0.valid   = 1'b1;
        alloc_event.lane0.preg    = 6'd40;
        writeback_event.lane0.valid = 1'b1;
        writeback_event.lane0.preg  = 6'd40;
        #1;
        assert (!busy_ready.lane0.src1_ready)
            else $fatal(1, "allocation must override same-cycle writeback readiness");
        cycle();
        clear_inputs();
        assert (busy_bitmap[40])
            else $fatal(1, "allocation must win busy state update conflict");

        // commit+recover 同拍：RRAT_next 必须包含提交映射；同时发生的推测
        // allocation/rename 必须被恢复优先级完全覆盖。
        alloc_req = 2'b01;
        #1;
        rename_req.lane0.rd         = 5'd10;
        rename_req.lane0.pdst_valid = 1'b1;
        rename_req.lane0.pdst       = alloc_preg.lane0;
        rename_fire[0]              = 1'b1;
        alloc_fire[0]               = 1'b1;
        alloc_event.lane0.valid     = 1'b1;
        alloc_event.lane0.preg      = alloc_preg.lane0;
        commit_map.lane0.valid      = 1'b1;
        commit_map.lane0.rd         = 5'd9;
        commit_map.lane0.pdst       = 6'd34;
        commit_map.lane0.stale_pdst = 6'd9;
        recover.valid               = 1'b1;
        recover.reason              = RECOVER_EXCEPTION;
        recover.target              = 32'h0000_0200;
        cycle();
        clear_inputs();

        rename_req.lane0.use_rs1 = 1'b1;
        rename_req.lane0.rs1     = 5'd9;
        rename_req.lane1.use_rs1 = 1'b1;
        rename_req.lane1.rs1     = 5'd10;
        #1;
        assert (rename_rsp.lane0.prs1 == 6'd34)
            else $fatal(1, "same-cycle commit was not included in RRAT recovery");
        assert (rename_rsp.lane1.prs1 == 6'd10)
            else $fatal(1, "recover failed to suppress speculative RAT update");
        assert (!free_bitmap[34] && free_bitmap[9] && (busy_bitmap == '0))
            else $fatal(1, "recover priority or live-mask rebuild failed");

        // x0 特例。
        rename_req = '0;
        rename_req.lane0.use_rs1    = 1'b1;
        rename_req.lane0.rs1        = 5'd0;
        rename_req.lane0.rd         = 5'd0;
        rename_req.lane0.pdst_valid = 1'b1;
        rename_req.lane0.pdst       = 6'd40;
        rename_fire[0]              = 1'b1;
        cycle();
        clear_inputs();
        rename_req.lane0.use_rs1 = 1'b1;
        rename_req.lane0.rs1     = 5'd0;
        #1;
        assert ((rename_rsp.lane0.prs1 == '0)
                && !free_bitmap[0] && !busy_bitmap[0])
            else $fatal(1, "p0 invariant failed");

        // 独立耗尽测试：复位后连续消耗 p32..p63，最终不再返回候选标签。
        rst_n = 1'b0;
        cycle();
        rst_n = 1'b1;
        cycle();
        for (exhaust_idx = 0; exhaust_idx < 16; exhaust_idx = exhaust_idx + 1) begin
            alloc_req  = 2'b11;
            alloc_fire = 2'b11;
            #1;
            assert (alloc_valid == 2'b11)
                else $fatal(1, "free list exhausted too early at pair %0d", exhaust_idx);
            cycle();
            clear_inputs();
        end
        alloc_req = 2'b11;
        #1;
        assert ((free_count == 0) && (alloc_valid == 2'b00))
            else $fatal(1, "free list exhaustion state is wrong");

        $display("PASS: free_list + rat_rrat + busy_table");
        $finish;
    end

endmodule
