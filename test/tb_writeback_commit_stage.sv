`timescale 1ns/1ps
`include "defines.svh"

module tb_writeback_commit_stage;
    import core_port_pkg::*;

    logic clk, rst_n;
    logic alu0_valid, mlu_valid, alu1_valid, bru_valid, lsq_valid, csr_valid;
    execute_writeback_t alu0_bus, mlu_bus, alu1_bus, bru_bus, csr_bus;
    lsq_writeback_t lsq_bus;
    csr_execute_update_t csr_update;
    logic alu0_ready, mlu_ready, alu1_ready, bru_ready, lsq_ready, csr_ready;
    csr_read_request_t csr_read_request;
    csr_read_response_t csr_read_response;
    logic csr_commit_available;
    rob_commit_bundle_t rob_commit_bus;
    logic [1:0] rob_commit_fire, store_commit_ready, rob_commit_ready;
    logic rob_empty;
    logic [31:0] interrupt_pc;
    logic irq_software_i, irq_timer_i, irq_external_i;
    recover_event_t recover;
    phys_reg_write_bundle_t prf_write, wakeup_bus;
    rob_complete_bundle_t rob_complete;
    branch_update_t branch_update;
    integer next_tag;

    writeback_commit_stage dut (
        .clk(clk), .rst_n(rst_n),
        .alu0_valid(alu0_valid), .alu0_bus(alu0_bus), .alu0_ready(alu0_ready),
        .mlu_valid(mlu_valid), .mlu_bus(mlu_bus), .mlu_ready(mlu_ready),
        .alu1_valid(alu1_valid), .alu1_bus(alu1_bus), .alu1_ready(alu1_ready),
        .bru_valid(bru_valid), .bru_bus(bru_bus), .bru_ready(bru_ready),
        .lsq_valid(lsq_valid), .lsq_bus(lsq_bus), .lsq_ready(lsq_ready),
        .csr_valid(csr_valid), .csr_bus(csr_bus), .csr_update(csr_update),
        .csr_ready(csr_ready),
        .csr_read_request(csr_read_request),
        .csr_read_response(csr_read_response),
        .csr_commit_available(csr_commit_available),
        .csr_commit_ready_o(),
        .rob_commit_bus(rob_commit_bus), .rob_commit_fire(rob_commit_fire),
        .store_commit_ready(store_commit_ready), .fence_commit_ready(1'b1),
        .rob_empty(rob_empty),
        .interrupt_pc(interrupt_pc), .rob_commit_ready(rob_commit_ready),
        .irq_software_i(irq_software_i), .irq_timer_i(irq_timer_i),
        .irq_external_i(irq_external_i),
        .recover(recover), .prf_write(prf_write),
        .wakeup_bus(wakeup_bus), .rob_complete(rob_complete),
        .branch_update(branch_update)
    );

    always #5 clk = ~clk;

    task automatic cycle;
        @(posedge clk);
        #1;
    endtask

    task automatic clear_wb;
        alu0_valid = 1'b0;
        mlu_valid  = 1'b0;
        alu1_valid = 1'b0;
        bru_valid  = 1'b0;
        lsq_valid  = 1'b0;
        csr_valid  = 1'b0;
        alu0_bus = '0;
        mlu_bus  = '0;
        alu1_bus = '0;
        bru_bus  = '0;
        lsq_bus  = '0;
        csr_bus  = '0;
        csr_update = '0;
    endtask

    task automatic commit_csr(input logic [11:0] addr,
                              input logic [31:0] data);
        rob_tag_t tag;
        begin
            tag = rob_tag_t'(next_tag);
            next_tag = next_tag + 1;
            csr_bus = '0;
            csr_bus.rob_tag = tag;
            csr_update = '{valid:1'b1, rob_tag:tag, addr:addr,
                           write_enable:1'b1, write_data:data};
            csr_valid = 1'b1;
            #1;
            assert (csr_ready && csr_commit_available)
                else $fatal(1, "CSR writeback was not accepted by empty cache");
            cycle();
            csr_valid = 1'b0;
            csr_update = '0;
            assert (!csr_commit_available)
                else $fatal(1, "CSR cache did not become occupied");

            rob_commit_bus = '0;
            rob_commit_bus.lane0.valid = 1'b1;
            rob_commit_bus.lane0.tag   = tag;
            rob_commit_bus.lane0.is_csr = 1'b1;
            rob_empty = 1'b0;
            #1;
            assert (rob_commit_ready[0])
                else $fatal(1, "matching CSR could not commit");
            rob_commit_fire = 2'b01;
            cycle();
            rob_commit_fire = '0;
            rob_commit_bus = '0;
            rob_empty = 1'b1;
            assert (csr_commit_available)
                else $fatal(1, "CSR cache did not release after commit");
        end
    endtask

    task automatic read_csr(input logic [11:0] addr,
                            output logic [31:0] data);
        begin
            csr_read_request = '{valid:1'b1, addr:addr};
            cycle();
            csr_read_request = '0;
            assert (csr_read_response.valid && csr_read_response.implemented)
                else $fatal(1, "integrated CSR read failed");
            data = csr_read_response.data;
            cycle();
        end
    endtask

    logic [31:0] value;

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        clear_wb();
        csr_read_request = '0;
        rob_commit_bus = '0;
        rob_commit_fire = '0;
        store_commit_ready = 2'b11;
        rob_empty = 1'b1;
        interrupt_pc = 32'h0000_0400;
        irq_software_i = 1'b0;
        irq_timer_i = 1'b0;
        irq_external_i = 1'b0;
        next_tag = 1;
        repeat (2) cycle();
        rst_n = 1'b1;

        // WB0 simultaneous collision: initial pointer chooses ALU0, then MLU.
        alu0_bus = '0;
        alu0_bus.rob_tag = rob_tag_t'(10);
        alu0_bus.pdst_valid = 1'b1;
        alu0_bus.pdst = phys_reg_idx_t'(3);
        alu0_bus.data = 32'h1111_1111;
        mlu_bus = '0;
        mlu_bus.rob_tag = rob_tag_t'(11);
        mlu_bus.pdst_valid = 1'b1;
        mlu_bus.pdst = phys_reg_idx_t'(4);
        mlu_bus.data = 32'h2222_2222;
        alu0_valid = 1'b1;
        mlu_valid = 1'b1;
        #1;
        assert (alu0_ready && !mlu_ready && prf_write.lane0.valid
                && (prf_write.lane0.preg == phys_reg_idx_t'(3))
                && rob_complete.lane0.valid)
            else $fatal(1, "WB0 initial arbitration failed");
        cycle();
        alu0_valid = 1'b0;
        #1;
        assert (mlu_ready && (prf_write.lane0.preg == phys_reg_idx_t'(4)))
            else $fatal(1, "WB0 MLU service failed");
        cycle();
        mlu_valid = 1'b0;

        // WB1 LSQ exception completes ROB but must not write PRF/broadcast.
        lsq_bus = '0;
        lsq_bus.rob_tag = rob_tag_t'(12);
        lsq_bus.pdst_valid = 1'b1;
        lsq_bus.pdst = phys_reg_idx_t'(5);
        lsq_bus.exception_valid = 1'b1;
        lsq_bus.exc_code = `EXC_LOAD_ACCESS;
        lsq_bus.exc_tval = 32'hdead_0000;
        lsq_valid = 1'b1;
        #1;
        assert (lsq_ready && rob_complete.lane1.valid
                && rob_complete.lane1.exception_valid
                && !prf_write.lane1.valid && !wakeup_bus.lane1.valid)
            else $fatal(1, "WB1 exception suppression failed");
        cycle();
        lsq_valid = 1'b0;

        // CSR updates are invisible until the matching ROB commit.
        commit_csr(12'h340, 32'h1234_5678);
        read_csr(12'h340, value);
        assert (value == 32'h1234_5678)
            else $fatal(1, "CSR precise commit value failed");

        // Configure interrupt handling through the same commit cache.
        commit_csr(12'h305, 32'h0000_1001);
        commit_csr(12'h304, 32'h0000_0800); // MEIE
        commit_csr(12'h300, 32'h0000_0008); // MIE
        irq_external_i = 1'b1;
        repeat (3) cycle();
        #1;
        assert (recover.valid && (recover.reason == RECOVER_INTERRUPT)
                && (recover.target == 32'h0000_102c))
            else $fatal(1, "integrated interrupt recovery target failed");
        cycle();
        irq_external_i = 1'b0;
        read_csr(12'h341, value);
        assert (value == 32'h0000_0400)
            else $fatal(1, "interrupt mepc boundary failed");
        read_csr(12'h342, value);
        assert (value == 32'h8000_000b)
            else $fatal(1, "interrupt mcause commit failed");

        // MRET redirects to mepc and restores interrupt enable stack.
        rob_commit_bus = '0;
        rob_commit_bus.lane0.valid = 1'b1;
        rob_commit_bus.lane0.is_mret = 1'b1;
        rob_empty = 1'b0;
        #1;
        assert (rob_commit_ready[0])
            else $fatal(1, "mret precise commit ready failed");
        rob_commit_fire = 2'b01;
        cycle();
        assert (recover.valid && (recover.target == 32'h0000_0400))
            else $fatal(1, "mret precise redirect failed");
        rob_commit_fire = '0;
        rob_commit_bus = '0;

        $display("PASS: WB0/WB1 arbitration + CSR cache + precise trap commit");
        $finish;
    end

endmodule
