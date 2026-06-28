`timescale 1ns/1ps

module tb_rename_stage;
    import core_port_pkg::*;

    localparam int TEST_PHYS_REG_COUNT = 34;

    logic clk;
    logic rst_n;

    logic          ds_to_rn_valid;
    logic          rn_allowin;
    ds_rn_bundle_t ds_to_rn_bus;

    logic [1:0]    rn_to_dp_valid;
    logic [1:0]    dp_ready;
    rn_dp_bundle_t rn_to_dp_bus;

    commit_map_bundle_t commit_map;
    phys_reg_event_bundle_t writeback_event;
    recover_event_t recover;

    rn_dp_bundle_t held_output;

    rename_stage #(
        .PHYS_REG_COUNT    (TEST_PHYS_REG_COUNT),
        .RENAME_FIFO_DEPTH (2)
    ) dut (
        .clk             (clk),
        .rst_n           (rst_n),
        .ds_to_rn_valid  (ds_to_rn_valid),
        .rn_allowin      (rn_allowin),
        .ds_to_rn_bus    (ds_to_rn_bus),
        .rn_to_dp_valid  (rn_to_dp_valid),
        .dp_ready        (dp_ready),
        .rn_to_dp_bus    (rn_to_dp_bus),
        .commit_map      (commit_map),
        .writeback_event (writeback_event),
        .recover         (recover)
    );

    always #5 clk = ~clk;

    function automatic ds_rn_slot_t make_uop(
        input logic [31:0] pc,
        input logic [4:0]  rs1,
        input logic [4:0]  rs2,
        input logic [4:0]  rd,
        input logic        use_rs1,
        input logic        use_rs2,
        input logic        rd_wen,
        input logic        flush
    );
        ds_rn_slot_t uop;
        uop = '0;
        uop.valid   = 1'b1;
        uop.flush   = flush;
        uop.pc      = pc;
        uop.inst    = pc;
        uop.rs1     = rs1;
        uop.rs2     = rs2;
        uop.rd      = rd;
        uop.use_rs1 = use_rs1;
        uop.use_rs2 = use_rs2;
        uop.rd_wen  = rd_wen;
        uop.fu_type = FU_ALU;
        uop.alu_op  = ALU_ADD;
        make_uop = uop;
    endfunction

    task automatic tick;
        @(posedge clk);
        #1;
    endtask

    task automatic send_bundle(input ds_rn_bundle_t bundle);
        while (!rn_allowin)
            @(negedge clk);
        @(negedge clk);
        ds_to_rn_bus   = bundle;
        ds_to_rn_valid = 1'b1;
        tick();
        ds_to_rn_valid = 1'b0;
        ds_to_rn_bus   = '0;
    endtask

    task automatic clear_sideband;
        commit_map      = '0;
        writeback_event = '0;
        recover         = '0;
    endtask

    initial begin
        ds_rn_bundle_t bundle_a;
        ds_rn_bundle_t bundle_b;
        ds_rn_bundle_t bundle_flush;
        ds_rn_bundle_t bundle_d;

        clk             = 1'b0;
        rst_n           = 1'b0;
        ds_to_rn_valid  = 1'b0;
        ds_to_rn_bus    = '0;
        dp_ready        = '0;
        clear_sideband();

        repeat (2) tick();
        rst_n = 1'b1;
        tick();
        assert (rn_allowin && (rn_to_dp_valid == 2'b00))
            else $fatal(1, "rename reset state is wrong");

        // A: 仅有 p32/p33 两个空闲标签，两条均应同拍完成重命名。
        bundle_a = '0;
        bundle_a.lane0 = make_uop(32'h100, 5'd1, 5'd0, 5'd5,
                                  1'b1, 1'b0, 1'b1, 1'b0);
        bundle_a.lane1 = make_uop(32'h104, 5'd5, 5'd0, 5'd6,
                                  1'b1, 1'b0, 1'b1, 1'b0);
        send_bundle(bundle_a);
        tick();

        assert (rn_to_dp_valid == 2'b11)
            else $fatal(1, "bundle A should fill both FIFO slots");
        assert ((rn_to_dp_bus.lane0.pdst == 6'd32)
                && (rn_to_dp_bus.lane1.pdst == 6'd33))
            else $fatal(1, "bundle A physical destinations are wrong");
        assert ((rn_to_dp_bus.lane1.prs1 == 6'd32)
                && !rn_to_dp_bus.lane1.src1_ready)
            else $fatal(1, "bundle A lane1 RAW dependency is wrong");

        // 输出停顿时数据必须保持；ready1 单独拉高不得越过 slot0。
        held_output = rn_to_dp_bus;
        dp_ready = 2'b10;
        tick();
        dp_ready = '0;
        assert ((rn_to_dp_valid == 2'b11) && (rn_to_dp_bus === held_output))
            else $fatal(1, "prefix ready or output stability failed");

        // FIFO 满且 Free List 耗尽时，B 留在 main，flush bundle 留在 skid。
        bundle_b = '0;
        bundle_b.lane0 = make_uop(32'h200, 5'd2, 5'd0, 5'd7,
                                  1'b1, 1'b0, 1'b1, 1'b0);
        bundle_b.lane1 = make_uop(32'h204, 5'd7, 5'd0, 5'd8,
                                  1'b1, 1'b0, 1'b1, 1'b0);
        send_bundle(bundle_b);

        bundle_flush = '0;
        bundle_flush.lane0 = make_uop(32'h300, 5'd0, 5'd0, 5'd9,
                                      1'b0, 1'b0, 1'b1, 1'b1);
        bundle_flush.lane1 = make_uop(32'h304, 5'd0, 5'd0, 5'd10,
                                      1'b0, 1'b0, 1'b1, 1'b1);
        send_bundle(bundle_flush);
        assert (!rn_allowin)
            else $fatal(1, "registered backpressure should assert after skid fills");

        // 只接收 A0，A1 压到 slot0。
        dp_ready = 2'b01;
        tick();
        dp_ready = '0;
        assert ((rn_to_dp_valid == 2'b01)
                && (rn_to_dp_bus.lane0.dec.pc == 32'h104))
            else $fatal(1, "slot1 did not compact after slot0 dispatch");

        // A0 提交，回收初始映射 p5。回收标签从下一拍开始可分配。
        commit_map.lane0.valid      = 1'b1;
        commit_map.lane0.rd         = 5'd5;
        commit_map.lane0.pdst       = 6'd32;
        commit_map.lane0.stale_pdst = 6'd5;
        writeback_event.lane0.valid = 1'b1;
        writeback_event.lane0.preg  = 6'd32;
        tick();
        clear_sideband();

        // 下一拍只有 p5 空闲且 FIFO 只有一个空位，所以 B0 单发，B1 留存。
        tick();
        assert (rn_to_dp_valid == 2'b11)
            else $fatal(1, "B0 should append behind stalled A1");
        assert ((rn_to_dp_bus.lane0.dec.pc == 32'h104)
                && (rn_to_dp_bus.lane1.dec.pc == 32'h200)
                && (rn_to_dp_bus.lane1.pdst == 6'd5))
            else $fatal(1, "partial rename ordering or allocation is wrong");

        // 接收 A1，B0 压到 slot0；此时 B1 因无空闲标签继续等待。
        dp_ready = 2'b01;
        tick();
        dp_ready = '0;
        assert ((rn_to_dp_valid == 2'b01)
                && (rn_to_dp_bus.lane0.dec.pc == 32'h200))
            else $fatal(1, "B0 did not remain at FIFO head");

        // A1 提交回收 p6；下一拍 B1 获得 p6，并读取 B0 建立的 x7->p5。
        commit_map.lane0.valid      = 1'b1;
        commit_map.lane0.rd         = 5'd6;
        commit_map.lane0.pdst       = 6'd33;
        commit_map.lane0.stale_pdst = 6'd6;
        writeback_event.lane0.valid = 1'b1;
        writeback_event.lane0.preg  = 6'd33;
        tick();
        clear_sideband();
        tick();

        assert (rn_to_dp_valid == 2'b11)
            else $fatal(1, "B1 should enter FIFO after one tag is reclaimed");
        assert ((rn_to_dp_bus.lane0.dec.pc == 32'h200)
                && (rn_to_dp_bus.lane1.dec.pc == 32'h204)
                && (rn_to_dp_bus.lane1.pdst == 6'd6)
                && (rn_to_dp_bus.lane1.prs1 == 6'd5)
                && !rn_to_dp_bus.lane1.src1_ready)
            else $fatal(1, "retained lane1 rename result is wrong");

        // 同拍接收 B0/B1；skid 中的 flushed bundle 被提升后直接丢弃。
        dp_ready = 2'b11;
        tick();
        dp_ready = '0;
        tick();
        assert ((rn_to_dp_valid == 2'b00) && rn_allowin)
            else $fatal(1, "flushed bundle should not enter renamed FIFO");

        // 无目标指令无需 Free List，即使没有空闲标签仍可通过。
        bundle_d = '0;
        bundle_d.lane0 = make_uop(32'h400, 5'd1, 5'd2, 5'd0,
                                  1'b1, 1'b1, 1'b0, 1'b0);
        send_bundle(bundle_d);
        tick();
        assert ((rn_to_dp_valid == 2'b01)
                && !rn_to_dp_bus.lane0.pdst_valid)
            else $fatal(1, "non-destination uop should rename without a free preg");

        // 统一恢复信道必须清空输入/输出缓冲并恢复 allowin。
        recover.valid  = 1'b1;
        recover.reason = RECOVER_EXCEPTION;
        recover.target = 32'h0000_0100;
        tick();
        recover = '0;
        assert ((rn_to_dp_valid == 2'b00) && rn_allowin)
            else $fatal(1, "recover did not clear rename stage");

        $display("PASS: rename_stage buffering + partial rename + recovery");
        $finish;
    end

endmodule
