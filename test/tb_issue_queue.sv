`timescale 1ns/1ps

module tb_issue_queue;
    import core_port_pkg::*;

    logic clk;
    logic rst_n;
    recover_event_t recover;
    rob_tag_t rob_head_tag;
    phys_reg_write_bundle_t wakeup_bus;

    logic [1:0] iq0_enq_valid;
    logic [1:0] iq1_enq_valid;
    dp_iq_bundle_t iq0_enq_bus;
    dp_iq_bundle_t iq1_enq_bus;
    dispatch_capacity_t iq0_capacity;
    dispatch_capacity_t iq1_capacity;

    logic alu0_available;
    logic mlu_available;
    logic alu1_available;
    logic bru_available;
    logic csr_available;

    logic issue0_valid;
    logic issue0_ready;
    logic issue0_fire;
    iq_issue_slot_t issue0_bus;
    iq_prf_read_req_t issue0_prf_req;
    logic issue1_valid;
    logic issue1_ready;
    logic issue1_fire;
    iq_issue_slot_t issue1_bus;
    iq_prf_read_req_t issue1_prf_req;

    issue_queue_pair u_issue_queue_pair (
        .clk              (clk),
        .rst_n            (rst_n),
        .recover          (recover),
        .rob_head_tag     (rob_head_tag),
        .wakeup_bus       (wakeup_bus),
        .iq0_enq_valid    (iq0_enq_valid),
        .iq0_enq_bus      (iq0_enq_bus),
        .iq0_capacity     (iq0_capacity),
        .iq1_enq_valid    (iq1_enq_valid),
        .iq1_enq_bus      (iq1_enq_bus),
        .iq1_capacity     (iq1_capacity),
        .alu0_available   (alu0_available),
        .mlu_available    (mlu_available),
        .alu1_available   (alu1_available),
        .bru_available    (bru_available),
        .csr_available    (csr_available),
        .issue0_valid     (issue0_valid),
        .issue0_bus       (issue0_bus),
        .issue0_ready     (issue0_ready),
        .issue0_fire      (issue0_fire),
        .issue0_prf_req   (issue0_prf_req),
        .issue1_valid     (issue1_valid),
        .issue1_bus       (issue1_bus),
        .issue1_ready     (issue1_ready),
        .issue1_fire      (issue1_fire),
        .issue1_prf_req   (issue1_prf_req)
    );

    always #5 clk = ~clk;

    task automatic cycle;
        @(posedge clk);
        #1;
    endtask

    task automatic clear_inputs;
        recover        = '0;
        wakeup_bus     = '0;
        iq0_enq_valid  = '0;
        iq1_enq_valid  = '0;
        iq0_enq_bus    = '0;
        iq1_enq_bus    = '0;
        rob_head_tag   = '0;
        alu0_available = 1'b1;
        mlu_available  = 1'b1;
        alu1_available = 1'b1;
        bru_available  = 1'b1;
        csr_available  = 1'b1;
        issue0_ready   = 1'b0;
        issue1_ready   = 1'b0;
    endtask

    task automatic clear_queues;
        begin
            iq0_enq_valid = '0;
            iq1_enq_valid = '0;
            wakeup_bus    = '0;
            recover.valid = 1'b1;
            recover.reason = RECOVER_BRANCH;
            cycle();
            clear_inputs();
            #1;
            assert ((iq0_capacity == 2) && (iq1_capacity == 2)
                    && !issue0_valid && !issue1_valid)
                else $fatal(1, "IQ recovery did not clear both banks");
        end
    endtask

    task automatic fill_iq_slot(
        output dp_iq_slot_t slot,
        input  rob_tag_t    tag,
        input  fu_type_e    fu_type,
        input  logic [5:0]  prs1,
        input  logic        use_rs1,
        input  logic        src1_ready,
        input  logic [5:0]  prs2,
        input  logic        use_rs2,
        input  logic        src2_ready
    );
        begin
            slot                    = '0;
            slot.rob_tag            = tag;
            slot.uop.dec.valid      = 1'b1;
            slot.uop.dec.fu_type    = fu_type;
            slot.uop.dec.use_rs1    = use_rs1;
            slot.uop.dec.use_rs2    = use_rs2;
            slot.uop.prs1           = prs1;
            slot.uop.prs2           = prs2;
            slot.uop.src1_ready     = src1_ready;
            slot.uop.src2_ready     = src2_ready;
        end
    endtask

    integer fill_pair;

    initial begin
        clk   = 1'b0;
        rst_n = 1'b0;
        clear_inputs();
        repeat (2) cycle();
        rst_n = 1'b1;
        cycle();

        assert ((iq0_capacity == 2) && (iq1_capacity == 2))
            else $fatal(1, "IQ reset capacity is wrong");

        // 真正乱序：老 MLU 等待 p10，年轻 ALU 已 ready，应先发射年轻项。
        fill_iq_slot(iq0_enq_bus.lane0, rob_tag_t'(0), FU_MLU,
                     6'd10, 1'b1, 1'b0, '0, 1'b0, 1'b1);
        fill_iq_slot(iq0_enq_bus.lane1, rob_tag_t'(1), FU_ALU,
                     '0, 1'b0, 1'b1, '0, 1'b0, 1'b1);
        iq0_enq_valid = 2'b11;
        cycle();
        iq0_enq_valid = '0;
        issue0_ready  = 1'b1;
        #1;
        assert (issue0_valid && issue0_fire
                && (issue0_bus.rob_tag == rob_tag_t'(1)))
            else $fatal(1, "younger ready instruction did not bypass blocked older entry");
        cycle();
        issue0_ready = 1'b0;
        #1;
        assert (!issue0_valid)
            else $fatal(1, "blocked older entry issued without wakeup");

        // 写回广播当拍唤醒并选择老指令，同时把广播数据带入 issue 包。
        wakeup_bus.lane0.valid = 1'b1;
        wakeup_bus.lane0.preg  = 6'd10;
        wakeup_bus.lane0.data  = 32'haaaa_0010;
        issue0_ready = 1'b1;
        #1;
        assert (issue0_valid && issue0_fire
                && (issue0_bus.rob_tag == rob_tag_t'(0))
                && issue0_bus.src1_bypass_valid
                && (issue0_bus.src1_bypass_data == 32'haaaa_0010))
            else $fatal(1, "same-cycle wakeup/select or bypass capture failed");
        assert (issue0_prf_req.src1.valid
                && (issue0_prf_req.src1.preg == 6'd10))
            else $fatal(1, "IQ did not drive PRF source address on issue");
        cycle();
        clear_inputs();
        assert (iq0_capacity == 2)
            else $fatal(1, "IQ0 entries were not released after issue");

        // ROB tag 环回年龄：head=62 时，tag63 比 tag0 更老，不能按数值排序。
        rob_head_tag = rob_tag_t'(62);
        fill_iq_slot(iq0_enq_bus.lane0, rob_tag_t'(0), FU_ALU,
                     '0, 1'b0, 1'b1, '0, 1'b0, 1'b1);
        fill_iq_slot(iq0_enq_bus.lane1, rob_tag_t'(63), FU_ALU,
                     '0, 1'b0, 1'b1, '0, 1'b0, 1'b1);
        iq0_enq_valid = 2'b11;
        cycle();
        iq0_enq_valid = '0;
        issue0_ready  = 1'b1;
        #1;
        assert (issue0_fire && (issue0_bus.rob_tag == rob_tag_t'(63)))
            else $fatal(1, "ROB wrap-aware oldest selection failed");
        clear_queues();

        // Bank1 中 BRU 不可接收时，年轻 ALU 可越过；BRU 恢复后再发射老项。
        bru_available = 1'b0;
        fill_iq_slot(iq1_enq_bus.lane0, rob_tag_t'(0), FU_BRU,
                     '0, 1'b0, 1'b1, '0, 1'b0, 1'b1);
        fill_iq_slot(iq1_enq_bus.lane1, rob_tag_t'(1), FU_ALU,
                     '0, 1'b0, 1'b1, '0, 1'b0, 1'b1);
        iq1_enq_valid = 2'b11;
        cycle();
        iq1_enq_valid = '0;
        issue1_ready  = 1'b1;
        #1;
        assert (issue1_fire && (issue1_bus.rob_tag == rob_tag_t'(1)))
            else $fatal(1, "IQ1 did not skip unavailable BRU");
        cycle();
        bru_available = 1'b1;
        #1;
        assert (issue1_fire && (issue1_bus.rob_tag == rob_tag_t'(0)))
            else $fatal(1, "older BRU did not issue when unit became available");
        clear_queues();

        // 两个源由不同广播端口同时唤醒。
        fill_iq_slot(iq0_enq_bus.lane0, rob_tag_t'(0), FU_MLU,
                     6'd20, 1'b1, 1'b0, 6'd21, 1'b1, 1'b0);
        iq0_enq_valid = 2'b01;
        cycle();
        iq0_enq_valid = '0;
        wakeup_bus.lane0 = '{valid: 1'b1, preg: 6'd20, data: 32'h2020_2020};
        wakeup_bus.lane1 = '{valid: 1'b1, preg: 6'd21, data: 32'h2121_2121};
        issue0_ready = 1'b1;
        #1;
        assert (issue0_fire && issue0_bus.src1_bypass_valid
                && issue0_bus.src2_bypass_valid
                && (issue0_bus.src1_bypass_data == 32'h2020_2020)
                && (issue0_bus.src2_bypass_data == 32'h2121_2121))
            else $fatal(1, "dual-broadcast source wakeup failed");
        clear_queues();

        // 下游阻塞时锁存选中包；广播撤销后旁路数据仍必须稳定。
        fill_iq_slot(iq0_enq_bus.lane0, rob_tag_t'(0), FU_MLU,
                     6'd30, 1'b1, 1'b0, '0, 1'b0, 1'b1);
        iq0_enq_valid = 2'b01;
        cycle();
        iq0_enq_valid = '0;
        wakeup_bus.lane0 = '{valid: 1'b1, preg: 6'd30, data: 32'h3030_3030};
        issue0_ready = 1'b0;
        #1;
        assert (issue0_valid && !issue0_fire
                && issue0_bus.src1_bypass_valid)
            else $fatal(1, "stalled wakeup candidate was not presented");
        cycle();
        wakeup_bus = '0;
        #1;
        assert (issue0_valid && !issue0_fire
                && issue0_bus.src1_bypass_valid
                && (issue0_bus.src1_bypass_data == 32'h3030_3030))
            else $fatal(1, "stalled issue packet or bypass data changed");
        issue0_ready = 1'b1;
        #1;
        assert (issue0_fire)
            else $fatal(1, "held issue packet did not fire after ready");
        cycle();
        clear_inputs();

        // 填满 IQ0。满队列本拍即使发射也不能组合旁路释放额度。
        issue0_ready = 1'b0;
        for (fill_pair = 0; fill_pair < 4; fill_pair = fill_pair + 1) begin
            fill_iq_slot(iq0_enq_bus.lane0, rob_tag_t'(fill_pair*2), FU_ALU,
                         '0, 1'b0, 1'b1, '0, 1'b0, 1'b1);
            fill_iq_slot(iq0_enq_bus.lane1, rob_tag_t'(fill_pair*2+1), FU_ALU,
                         '0, 1'b0, 1'b1, '0, 1'b0, 1'b1);
            iq0_enq_valid = 2'b11;
            cycle();
            iq0_enq_valid = '0;
        end
        #1;
        assert (iq0_capacity == 0)
            else $fatal(1, "IQ0 did not report full capacity");
        issue0_ready = 1'b1;
        #1;
        assert (issue0_fire && (iq0_capacity == 0))
            else $fatal(1, "IQ capacity incorrectly bypassed same-cycle issue");
        cycle();
        issue0_ready = 1'b0;
        #1;
        assert (iq0_capacity == 1)
            else $fatal(1, "IQ capacity did not reopen after registered issue");

        clear_queues();
        $display("PASS: two-bank out-of-order issue queues");
        $finish;
    end

endmodule
