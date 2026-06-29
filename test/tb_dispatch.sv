`timescale 1ns/1ps
`include "defines.svh"

module tb_dispatch;
    import core_port_pkg::*;

    logic                    clk;
    logic                    rst_n;
    logic [1:0]              rn_to_dp_valid;
    rn_dp_bundle_t           rn_to_dp_bus;
    logic [1:0]              dp_ready;
    logic                    rob_allowin;
    rob_tag_pair_t           rob_alloc_tag;
    logic [1:0]              rob_alloc_valid;
    rn_rob_bundle_t          rob_alloc_bus;
    dispatch_capacity_t      iq0_capacity;
    dispatch_capacity_t      iq1_capacity;
    dispatch_capacity_t      lsq_capacity;
    logic [1:0]              iq0_enq_valid;
    logic [1:0]              iq1_enq_valid;
    logic [1:0]              lsq_enq_valid;
    dp_iq_bundle_t           iq0_enq_bus;
    dp_iq_bundle_t           iq1_enq_bus;
    dp_lsq_bundle_t          lsq_enq_bus;

    rob_complete_bundle_t    complete_bus;
    rob_commit_bundle_t      commit_bus;
    logic [1:0]              commit_ready;
    logic [1:0]              commit_fire;
    commit_map_bundle_t      commit_map;
    recover_event_t          recover;
    logic [$clog2(ROB_DEPTH+1)-1:0] occupancy;
    rob_tag_t                 rob_head_tag;

    dispatch u_dispatch (
        .rn_to_dp_valid (rn_to_dp_valid),
        .rn_to_dp_bus   (rn_to_dp_bus),
        .dp_ready       (dp_ready),
        .rob_allowin    (rob_allowin),
        .rob_alloc_tag  (rob_alloc_tag),
        .rob_alloc_valid(rob_alloc_valid),
        .rob_alloc_bus  (rob_alloc_bus),
        .iq0_capacity   (iq0_capacity),
        .iq1_capacity   (iq1_capacity),
        .iq0_enq_valid  (iq0_enq_valid),
        .iq1_enq_valid  (iq1_enq_valid),
        .iq0_enq_bus    (iq0_enq_bus),
        .iq1_enq_bus    (iq1_enq_bus),
        .lsq_capacity   (lsq_capacity),
        .lsq_enq_valid  (lsq_enq_valid),
        .lsq_enq_bus    (lsq_enq_bus)
    );

    rob u_rob (
        .clk           (clk),
        .rst_n         (rst_n),
        .alloc_valid   (rob_alloc_valid),
        .alloc_bus     (rob_alloc_bus),
        .rob_allowin   (rob_allowin),
        .alloc_tag     (rob_alloc_tag),
        .complete_bus  (complete_bus),
        .commit_bus    (commit_bus),
        .commit_ready  (commit_ready),
        .commit_fire   (commit_fire),
        .commit_map    (commit_map),
        .recover       (recover),
        .occupancy_o   (occupancy),
        .head_tag_o    (rob_head_tag)
    );

    always #5 clk = ~clk;

    task automatic cycle;
        @(posedge clk);
        #1;
    endtask

    task automatic clear_inputs;
        rn_to_dp_valid = '0;
        rn_to_dp_bus   = '0;
        complete_bus   = '0;
        commit_ready   = '0;
        recover        = '0;
        iq0_capacity   = 2;
        iq1_capacity   = 2;
        lsq_capacity   = 2;
    endtask

    task automatic clear_rob;
        begin
            rn_to_dp_valid = '0;
            recover.valid  = 1'b1;
            recover.reason = RECOVER_BRANCH;
            cycle();
            clear_inputs();
            #1;
            assert ((occupancy == 0) && rob_allowin)
                else $fatal(1, "ROB did not clear between dispatch scenarios");
        end
    endtask

    task automatic fill_uop(
        output rn_dp_slot_t uop,
        input  fu_type_e    fu_type,
        input  logic [31:0] pc,
        input  logic [4:0]  rd
    );
        begin
            uop                = '0;
            uop.dec.valid      = 1'b1;
            uop.dec.pc         = pc;
            uop.dec.inst       = 32'h0000_0033;
            uop.dec.fu_type    = fu_type;
            uop.dec.rd         = rd;
            uop.dec.rd_wen     = (rd != '0);
            uop.pdst           = phys_reg_idx_t'(32 + rd);
            uop.stale_pdst     = phys_reg_idx_t'(rd);
            uop.pdst_valid     = (rd != '0);
            uop.src1_ready     = 1'b1;
            uop.src2_ready     = 1'b1;
        end
    endtask

    integer fill_idx;

    initial begin
        clk   = 1'b0;
        rst_n = 1'b0;
        clear_inputs();
        repeat (2) cycle();
        rst_n = 1'b1;
        cycle();

        // 双 ALU 在容量相同时自动分散到两个 bank。
        fill_uop(rn_to_dp_bus.lane0, FU_ALU, 32'h1000, 5'd1);
        fill_uop(rn_to_dp_bus.lane1, FU_ALU, 32'h1004, 5'd2);
        rn_to_dp_valid = 2'b11;
        #1;
        assert ((dp_ready == 2'b11) && (rob_alloc_valid == 2'b11))
            else $fatal(1, "dual ALU dispatch was not accepted");
        assert ((iq0_enq_valid == 2'b01) && (iq1_enq_valid == 2'b01))
            else $fatal(1, "dual ALU did not balance across IQ banks");
        assert ((iq0_enq_bus.lane0.rob_tag == rob_alloc_tag.lane0)
                && (iq1_enq_bus.lane0.rob_tag == rob_alloc_tag.lane1))
            else $fatal(1, "balanced ALU ROB tags are wrong");
        cycle();
        clear_inputs();
        assert (occupancy == 2)
            else $fatal(1, "dispatch did not atomically allocate ROB entries");
        clear_rob();

        // MLU 固定 IQ0，BRU 固定 IQ1。
        fill_uop(rn_to_dp_bus.lane0, FU_MLU, 32'h2000, 5'd3);
        fill_uop(rn_to_dp_bus.lane1, FU_BRU, 32'h2004, 5'd4);
        rn_to_dp_valid = 2'b11;
        #1;
        assert ((iq0_enq_valid == 2'b01) && (iq1_enq_valid == 2'b01)
                && (iq0_enq_bus.lane0.uop.dec.fu_type == FU_MLU)
                && (iq1_enq_bus.lane0.uop.dec.fu_type == FU_BRU))
            else $fatal(1, "fixed IQ routing failed");
        clear_rob();

        // 两条 MLU 可以压紧到 IQ0 的两个写口。
        fill_uop(rn_to_dp_bus.lane0, FU_MLU, 32'h2100, 5'd3);
        fill_uop(rn_to_dp_bus.lane1, FU_MLU, 32'h2104, 5'd4);
        rn_to_dp_valid = 2'b11;
        #1;
        assert ((dp_ready == 2'b11) && (iq0_enq_valid == 2'b11)
                && (iq0_enq_bus.lane0.rob_tag == rob_alloc_tag.lane0)
                && (iq0_enq_bus.lane1.rob_tag == rob_alloc_tag.lane1))
            else $fatal(1, "same-bank dual enqueue failed");
        clear_rob();

        // IQ0 仅剩一个额度时只允许 lane0 部分推进，lane1 不能写 ROB。
        iq0_capacity = 1;
        iq1_capacity = 2;
        fill_uop(rn_to_dp_bus.lane0, FU_MLU, 32'h2200, 5'd3);
        fill_uop(rn_to_dp_bus.lane1, FU_MLU, 32'h2204, 5'd4);
        rn_to_dp_valid = 2'b11;
        #1;
        assert ((dp_ready == 2'b01) && (rob_alloc_valid == 2'b01)
                && (iq0_enq_valid == 2'b01))
            else $fatal(1, "dispatch prefix partial advancement failed");
        cycle();
        clear_inputs();
        assert (occupancy == 1)
            else $fatal(1, "partial dispatch allocated wrong ROB count");
        clear_rob();

        // lane0 目标满时，即使 lane1 的目标有空间也不能越过 lane0。
        iq0_capacity = 0;
        iq1_capacity = 2;
        fill_uop(rn_to_dp_bus.lane0, FU_MLU, 32'h2300, 5'd3);
        fill_uop(rn_to_dp_bus.lane1, FU_ALU, 32'h2304, 5'd4);
        rn_to_dp_valid = 2'b11;
        #1;
        assert ((dp_ready == 2'b00) && (rob_alloc_valid == 2'b00)
                && (iq0_enq_valid == 0) && (iq1_enq_valid == 0))
            else $fatal(1, "lane1 bypassed blocked lane0");
        clear_rob();

        // LSU 进入 LSQ，CSR 进入 IQ1；两个目标均使用压紧后的 lane0 写口。
        fill_uop(rn_to_dp_bus.lane0, FU_LSU, 32'h3000, 5'd5);
        rn_to_dp_bus.lane0.dec.mem_write = 1'b1;
        fill_uop(rn_to_dp_bus.lane1, FU_CSR, 32'h3004, 5'd6);
        rn_to_dp_valid = 2'b11;
        #1;
        assert ((lsq_enq_valid == 2'b01) && (iq1_enq_valid == 2'b01)
                && rob_alloc_bus.lane0.is_store
                && rob_alloc_bus.lane1.is_csr)
            else $fatal(1, "LSQ/CSR dispatch routing or ROB flags failed");
        clear_rob();

        // 异常和 FENCE 只进入 ROB，不消耗 IQ/LSQ；异常分配时已完成，
        // FENCE 等待未来内存序控制器完成。
        iq0_capacity = 0;
        iq1_capacity = 0;
        lsq_capacity = 0;
        fill_uop(rn_to_dp_bus.lane0, FU_NONE, 32'h4000, 5'd0);
        rn_to_dp_bus.lane0.dec.exc_code = `EXC_ILLEGAL_INST;
        rn_to_dp_bus.lane0.dec.exc_tval = 32'hdead_beef;
        fill_uop(rn_to_dp_bus.lane1, FU_SYS, 32'h4004, 5'd0);
        rn_to_dp_bus.lane1.dec.inst = 32'h0000_000f;
        rn_to_dp_valid = 2'b11;
        #1;
        assert ((dp_ready == 2'b11) && (rob_alloc_valid == 2'b11)
                && (iq0_enq_valid == 0) && (iq1_enq_valid == 0)
                && (lsq_enq_valid == 0))
            else $fatal(1, "ROB-only instructions incorrectly required a queue");
        assert (rob_alloc_bus.lane0.exception_valid
                && rob_alloc_bus.lane0.complete_on_alloc
                && rob_alloc_bus.lane1.is_fence
                && !rob_alloc_bus.lane1.complete_on_alloc)
            else $fatal(1, "ROB-only completion attributes are wrong");
        clear_rob();

        // 用组合 Dispatch 填满 ROB；ROB 拉低 allowin 后所有目标均停止接收。
        iq0_capacity = 2;
        for (fill_idx = 0; fill_idx < 16; fill_idx = fill_idx + 1) begin
            fill_uop(rn_to_dp_bus.lane0, FU_MLU, 32'h5000 + fill_idx*8, 5'd1);
            fill_uop(rn_to_dp_bus.lane1, FU_MLU, 32'h5004 + fill_idx*8, 5'd2);
            rn_to_dp_valid = 2'b11;
            #1;
            assert (dp_ready == 2'b11)
                else $fatal(1, "dispatch stopped before ROB became full");
            cycle();
            clear_inputs();
        end
        assert ((occupancy == ROB_DEPTH) && !rob_allowin)
            else $fatal(1, "ROB did not become full through dispatch");
        fill_uop(rn_to_dp_bus.lane0, FU_ALU, 32'h6000, 5'd1);
        rn_to_dp_valid = 2'b01;
        #1;
        assert ((dp_ready == 0) && (rob_alloc_valid == 0)
                && (iq0_enq_valid == 0) && (iq1_enq_valid == 0))
            else $fatal(1, "full ROB did not block combinational dispatch");

        $display("PASS: combinational dispatch routing + atomic ROB admission");
        $finish;
    end

endmodule
