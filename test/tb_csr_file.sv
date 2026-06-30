`timescale 1ns/1ps

module tb_csr_file;
    import core_port_pkg::*;

    logic clk;
    logic rst_n;
    csr_read_request_t read_request;
    csr_read_response_t read_response;
    csr_execute_update_t commit_update;
    trap_event_t trap_event;
    logic mret_valid;
    logic [31:0] trap_target, mret_target;
    logic irq_software_i, irq_timer_i, irq_external_i;
    logic interrupt_pending;
    logic [4:0] interrupt_cause;

    csr_file #(.MTVEC_RESET(32'h0000_0000)) dut (
        .clk(clk), .rst_n(rst_n),
        .read_request(read_request), .read_response(read_response),
        .commit_update(commit_update),
        .trap_event(trap_event), .mret_valid(mret_valid),
        .trap_target(trap_target), .mret_target(mret_target),
        .irq_software_i(irq_software_i), .irq_timer_i(irq_timer_i),
        .irq_external_i(irq_external_i),
        .interrupt_pending(interrupt_pending),
        .interrupt_cause(interrupt_cause)
    );

    always #5 clk = ~clk;

    task automatic cycle;
        @(posedge clk);
        #1;
    endtask

    task automatic write_csr(input logic [11:0] addr,
                             input logic [31:0] data);
        commit_update = '{valid:1'b1, rob_tag:'0, addr:addr,
                          write_enable:1'b1, write_data:data};
        cycle();
        commit_update = '0;
    endtask

    task automatic read_csr(input logic [11:0] addr,
                            output logic [31:0] data,
                            output logic implemented,
                            output logic writable);
        read_request = '{valid:1'b1, addr:addr};
        cycle();
        read_request = '0;
        assert (read_response.valid)
            else $fatal(1, "CSR synchronous read response missing");
        data        = read_response.data;
        implemented = read_response.implemented;
        writable    = read_response.writable;
        cycle();
    endtask

    logic [31:0] value;
    logic implemented;
    logic writable;

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        read_request = '0;
        commit_update = '0;
        trap_event = '0;
        mret_valid = 1'b0;
        irq_software_i = 1'b0;
        irq_timer_i = 1'b0;
        irq_external_i = 1'b0;
        repeat (2) cycle();
        rst_n = 1'b1;

        read_csr(12'h301, value, implemented, writable);
        assert (implemented && !writable && (value == 32'h4000_1100))
            else $fatal(1, "misa reset/read-only value is wrong");
        read_csr(12'h7ff, value, implemented, writable);
        assert (!implemented && !writable)
            else $fatal(1, "unsupported CSR was reported implemented");

        // Enable all three standard machine interrupts and vectored mtvec.
        write_csr(12'h300, 32'h0000_0088); // MPIE=1, MIE=1
        write_csr(12'h304, 32'h0000_0888); // MEIE/MSIE/MTIE
        write_csr(12'h305, 32'h0000_1001); // vectored, base 0x1000
        irq_software_i = 1'b1;
        irq_timer_i    = 1'b1;
        irq_external_i = 1'b1;
        repeat (3) cycle();
        assert (interrupt_pending && (interrupt_cause == 5'd11))
            else $fatal(1, "machine interrupt priority/gating failed");

        // Interrupt trap: vector, mepc alignment, mcause interrupt bit, mtval=0.
        trap_event = '{valid:1'b1, is_interrupt:1'b1, cause:5'd11,
                       pc:32'h0000_0123, tval:32'hffff_ffff};
        #1;
        assert (trap_target == 32'h0000_102c)
            else $fatal(1, "vectored interrupt target is wrong");
        cycle();
        trap_event = '0;
        assert (!interrupt_pending && (mret_target == 32'h0000_0120))
            else $fatal(1, "trap did not clear MIE or align mepc");
        read_csr(12'h300, value, implemented, writable);
        assert (!value[3] && value[7])
            else $fatal(1, "trap MIE/MPIE stack semantics failed");
        read_csr(12'h342, value, implemented, writable);
        assert (value == 32'h8000_000b)
            else $fatal(1, "interrupt mcause is wrong");
        read_csr(12'h343, value, implemented, writable);
        assert (value == '0)
            else $fatal(1, "interrupt mtval must be zero");

        // MRET restores MIE from MPIE and sets MPIE.
        mret_valid = 1'b1;
        cycle();
        mret_valid = 1'b0;
        read_csr(12'h300, value, implemented, writable);
        assert (value[3] && value[7])
            else $fatal(1, "mret MIE/MPIE restore failed");

        // Exception always uses direct BASE even when mtvec is vectored.
        trap_event = '{valid:1'b1, is_interrupt:1'b0, cause:5'd2,
                       pc:32'h0000_0207, tval:32'hdead_beef};
        #1;
        assert (trap_target == 32'h0000_1000)
            else $fatal(1, "exception incorrectly used vectored target");
        cycle();
        trap_event = '0;
        read_csr(12'h341, value, implemented, writable);
        assert (value == 32'h0000_0204)
            else $fatal(1, "exception mepc is wrong");
        read_csr(12'h342, value, implemented, writable);
        assert (value == 32'd2)
            else $fatal(1, "exception mcause is wrong");
        read_csr(12'h343, value, implemented, writable);
        assert (value == 32'hdead_beef)
            else $fatal(1, "exception mtval is wrong");

        $display("PASS: minimal machine CSR + precise exception/interrupt state");
        $finish;
    end

endmodule
