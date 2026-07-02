`timescale 1ns/1ps
`include "defines.svh"

module tb_rob;
    import core_port_pkg::*;

    logic                 clk;
    logic                 rst_n;
    logic [1:0]           alloc_valid;
    rn_rob_bundle_t       alloc_bus;
    logic                 rob_allowin;
    rob_tag_pair_t        alloc_tag;
    rob_complete_bundle_t complete_bus;
    rob_commit_bundle_t   commit_bus;
    logic [1:0]           commit_ready;
    logic [1:0]           commit_fire;
    commit_map_bundle_t   commit_map;
    recover_event_t       recover;
    logic [$clog2(ROB_DEPTH+1)-1:0] occupancy;
    rob_tag_t head_tag;

    rob u_rob (
        .clk           (clk),
        .rst_n         (rst_n),
        .alloc_valid   (alloc_valid),
        .alloc_bus     (alloc_bus),
        .rob_allowin   (rob_allowin),
        .alloc_tag     (alloc_tag),
        .complete_bus  (complete_bus),
        .commit_bus    (commit_bus),
        .commit_ready  (commit_ready),
        .commit_fire   (commit_fire),
        .commit_map    (commit_map),
        .recover       (recover),
        .occupancy_o   (occupancy),
        .head_tag_o    (head_tag),
        .head_tag_iq0  (),
        .head_tag_iq1  ()
    );

    always #5 clk = ~clk;

    task automatic cycle;
        @(posedge clk);
        #1;
    endtask

    task automatic clear_inputs;
        alloc_valid  = '0;
        alloc_bus    = '0;
        complete_bus = '0;
        commit_ready = '0;
        recover      = '0;
    endtask

    task automatic fill_alloc_slot(
        output rn_rob_slot_t slot,
        input  logic [31:0] pc,
        input  logic [4:0]  rd,
        input  logic [5:0]  pdst,
        input  logic [5:0]  stale_pdst,
        input  logic        complete_on_alloc
    );
        begin
            slot                   = '0;
            slot.pc                = pc;
            slot.rd                = rd;
            slot.pdst              = pdst;
            slot.stale_pdst        = stale_pdst;
            slot.pdst_valid        = (rd != '0);
            slot.complete_on_alloc = complete_on_alloc;
        end
    endtask

    integer pair_idx;
    rob_tag_t first_tag;
    rob_tag_t second_tag;

    initial begin
        clk   = 1'b0;
        rst_n = 1'b0;
        clear_inputs();

        repeat (2) cycle();
        rst_n = 1'b1;
        cycle();

        assert ((occupancy == 0) && rob_allowin)
            else $fatal(1, "ROB reset state is wrong");
        assert ((alloc_tag.lane0 == 0) && (alloc_tag.lane1 == 1))
            else $fatal(1, "initial allocation tags are wrong");

        // 两条未完成指令按 lane0、lane1 顺序分配。
        fill_alloc_slot(alloc_bus.lane0, 32'h1000, 5'd5, 6'd32, 6'd5, 1'b0);
        fill_alloc_slot(alloc_bus.lane1, 32'h1004, 5'd6, 6'd33, 6'd6, 1'b0);
        alloc_valid = 2'b11;
        first_tag   = alloc_tag.lane0;
        second_tag  = alloc_tag.lane1;
        cycle();
        clear_inputs();
        #1;
        assert ((occupancy == 2) && (alloc_tag.lane0 == 2))
            else $fatal(1, "dual allocation failed");

        // 年轻 lane1 先完成不能越过 lane0 提交。
        complete_bus.lane0.valid = 1'b1;
        complete_bus.lane0.tag   = second_tag;
        cycle();
        clear_inputs();
        #1;
        assert (!commit_bus.lane0.valid && !commit_bus.lane1.valid)
            else $fatal(1, "younger completion committed out of order");

        // lane0 完成后两项都成为提交候选，但允许只提交最老一项。
        complete_bus.lane0.valid = 1'b1;
        complete_bus.lane0.tag   = first_tag;
        cycle();
        clear_inputs();
        #1;
        assert (commit_bus.lane0.valid && commit_bus.lane1.valid)
            else $fatal(1, "dual completed entries were not exposed for commit");

        commit_ready = 2'b01;
        #1;
        assert ((commit_fire == 2'b01) && commit_map.lane0.valid
                && !commit_map.lane1.valid)
            else $fatal(1, "single prefix commit or commit map failed");
        cycle();
        clear_inputs();
        #1;
        assert ((occupancy == 1) && commit_bus.lane0.valid
                && (commit_bus.lane0.tag == second_tag))
            else $fatal(1, "ROB head did not advance after single commit");

        commit_ready = 2'b01;
        cycle();
        clear_inputs();
        assert (occupancy == 0)
            else $fatal(1, "second single commit failed");

        // 先验证“最后一个孤立空项不可使用”：占用 30 项时可接收一条，
        // 接收后 occupancy=31 且 allowin 拉低，另一条不能继续写入。
        for (pair_idx = 0; pair_idx < 15; pair_idx = pair_idx + 1) begin
            fill_alloc_slot(alloc_bus.lane0, 32'h1800 + pair_idx * 8,
                            5'd1, 6'd32, 6'd1, 1'b1);
            fill_alloc_slot(alloc_bus.lane1, 32'h1804 + pair_idx * 8,
                            5'd2, 6'd33, 6'd2, 1'b1);
            alloc_valid = 2'b11;
            cycle();
            clear_inputs();
        end
        assert ((occupancy == ROB_DEPTH-2) && rob_allowin)
            else $fatal(1, "ROB should allow allocation with two free entries");

        fill_alloc_slot(alloc_bus.lane0, 32'h1f00, 5'd3, 6'd34, 6'd3, 1'b1);
        alloc_valid = 2'b01;
        cycle();
        clear_inputs();
        assert ((occupancy == ROB_DEPTH-1) && !rob_allowin)
            else $fatal(1, "ROB did not reserve the final isolated free entry");

        alloc_valid = 2'b01;
        cycle();
        clear_inputs();
        assert (occupancy == ROB_DEPTH-1)
            else $fatal(1, "ROB accepted allocation with only one free entry");

        recover.valid  = 1'b1;
        recover.reason = RECOVER_BRANCH;
        cycle();
        clear_inputs();

        // 填满 ROB。占用 30 项时仍可双写；占满后 allowin 拉低。
        for (pair_idx = 0; pair_idx < 16; pair_idx = pair_idx + 1) begin
            fill_alloc_slot(alloc_bus.lane0, 32'h2000 + pair_idx * 8,
                            5'd1, 6'd32, 6'd1, 1'b1);
            fill_alloc_slot(alloc_bus.lane1, 32'h2004 + pair_idx * 8,
                            5'd2, 6'd33, 6'd2, 1'b1);
            alloc_valid = 2'b11;
            assert (rob_allowin)
                else $fatal(1, "ROB deasserted allowin before final pair");
            cycle();
            clear_inputs();
        end
        assert ((occupancy == ROB_DEPTH) && !rob_allowin)
            else $fatal(1, "ROB full/allowin state is wrong");

        // 即使本拍提交两个，allowin 也不能组合旁路本拍释放空间。
        commit_ready = 2'b11;
        #1;
        assert ((commit_fire == 2'b11) && !rob_allowin)
            else $fatal(1, "ROB allowin incorrectly used same-cycle commit credit");
        cycle();
        clear_inputs();
        #1;
        assert ((occupancy == ROB_DEPTH-2) && rob_allowin)
            else $fatal(1, "ROB did not reopen one cycle after dual commit");

        // 统一恢复清空全部在途项。
        recover.valid  = 1'b1;
        recover.reason = RECOVER_BRANCH;
        recover.target = 32'h8000_0000;
        cycle();
        clear_inputs();
        assert ((occupancy == 0) && rob_allowin && (alloc_tag.lane0 == 0))
            else $fatal(1, "ROB recovery did not reset queue state");

        // lane0 异常阻止同拍提交 lane1，且异常自身不更新 RRAT。
        fill_alloc_slot(alloc_bus.lane0, 32'h3000, 5'd5, 6'd40, 6'd5, 1'b1);
        alloc_bus.lane0.exception_valid = 1'b1;
        alloc_bus.lane0.exc_code        = `EXC_ILLEGAL_INST;
        alloc_bus.lane0.exc_tval        = 32'hffff_ffff;
        fill_alloc_slot(alloc_bus.lane1, 32'h3004, 5'd6, 6'd41, 6'd6, 1'b1);
        alloc_valid = 2'b11;
        cycle();
        clear_inputs();
        #1;
        assert (commit_bus.lane0.valid && !commit_bus.lane1.valid)
            else $fatal(1, "exception did not stop younger same-cycle commit");
        commit_ready = 2'b01;
        #1;
        assert (!commit_map.lane0.valid)
            else $fatal(1, "excepting instruction updated committed rename map");
        recover.valid  = 1'b1;
        recover.reason = RECOVER_EXCEPTION;
        cycle();
        clear_inputs();

        // 错误环回位的完成 tag 必须被忽略；正确 tag 才能置完成。
        fill_alloc_slot(alloc_bus.lane0, 32'h4000, 5'd7, 6'd42, 6'd7, 1'b0);
        alloc_valid = 2'b01;
        first_tag   = alloc_tag.lane0;
        cycle();
        clear_inputs();

        complete_bus.lane0.valid = 1'b1;
        complete_bus.lane0.tag   = first_tag ^ rob_tag_t'(ROB_DEPTH);
        cycle();
        clear_inputs();
        assert (!commit_bus.lane0.valid)
            else $fatal(1, "stale completion tag was accepted");

        complete_bus.lane0.valid = 1'b1;
        complete_bus.lane0.tag   = first_tag;
        cycle();
        clear_inputs();
        assert (commit_bus.lane0.valid)
            else $fatal(1, "matching completion tag was not accepted");

        $display("PASS: dual-allocate dual-complete dual-commit ROB");
        $finish;
    end

endmodule
