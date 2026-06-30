`include "defines.svh"

// =============================================================================
// 最小机器态 CSR 文件（无特权等级切换）
// =============================================================================
// 实现集合：mstatus、misa、mie、mtvec、mscratch、mepc、mcause、mtval、mip，
// 以及只读的 mvendorid/marchid/mimpid/mhartid。处理器始终运行在 M-mode，
// mstatus.MPP 因此硬连为 2'b11；不实现 delegation/PMP/S-mode。
//
// 关键精确状态语义：
//   trap：MPIE <- MIE，MIE <- 0，写 mepc/mcause/mtval；
//   mret：MIE <- MPIE，MPIE <- 1，返回 mepc；
//   interrupt mcause[31]=1，mtval=0；exception mcause[31]=0；
//   mtvec MODE=Vectored 仅对 interrupt 使用 BASE+4*cause。
//
// CSR 指令读口为一拍时序读。外部中断输入经过两级同步后形成 mip，避免把
// 异步引脚直接送入 ROB/提交组合路径。
// =============================================================================
module csr_file #(
    parameter logic [31:0] MTVEC_RESET = 32'h0000_0000,
    parameter logic [31:0] MHARTID      = 32'h0000_0000
) (
    input  logic                                     clk,
    input  logic                                     rst_n,

    input  wire core_port_pkg::csr_read_request_t    read_request,
    output      core_port_pkg::csr_read_response_t   read_response,

    // 来自 csr_commit_buffer，只在对应 ROB 项真正提交时有效。
    input  wire core_port_pkg::csr_execute_update_t  commit_update,

    // 精确 trap/mret 控制。
    input  wire core_port_pkg::trap_event_t           trap_event,
    input  logic                                     mret_valid,
    output logic [31:0]                              trap_target,
    output logic [31:0]                              mret_target,

    // 机器态标准中断源。
    input  logic                                     irq_software_i,
    input  logic                                     irq_timer_i,
    input  logic                                     irq_external_i,
    output logic                                     interrupt_pending,
    output logic [4:0]                               interrupt_cause
);
    import core_port_pkg::*;

    localparam logic [11:0] CSR_MSTATUS   = 12'h300;
    localparam logic [11:0] CSR_MISA      = 12'h301;
    localparam logic [11:0] CSR_MIE       = 12'h304;
    localparam logic [11:0] CSR_MTVEC     = 12'h305;
    localparam logic [11:0] CSR_MSCRATCH  = 12'h340;
    localparam logic [11:0] CSR_MEPC      = 12'h341;
    localparam logic [11:0] CSR_MCAUSE    = 12'h342;
    localparam logic [11:0] CSR_MTVAL     = 12'h343;
    localparam logic [11:0] CSR_MIP       = 12'h344;
    localparam logic [11:0] CSR_MVENDORID = 12'hF11;
    localparam logic [11:0] CSR_MARCHID   = 12'hF12;
    localparam logic [11:0] CSR_MIMPID    = 12'hF13;
    localparam logic [11:0] CSR_MHARTID   = 12'hF14;

    logic mstatus_mie;
    logic mstatus_mpie;
    logic mie_msie;
    logic mie_mtie;
    logic mie_meie;
    logic [31:0] mtvec;
    logic [31:0] mscratch;
    logic [31:0] mepc;
    logic [31:0] mcause;
    logic [31:0] mtval;

    logic irq_software_meta, irq_software_sync;
    logic irq_timer_meta,    irq_timer_sync;
    logic irq_external_meta, irq_external_sync;

    logic [31:0] mstatus_value;
    logic [31:0] mie_value;
    logic [31:0] mip_value;
    logic [31:0] read_data_comb;
    logic read_implemented_comb;
    logic read_writable_comb;

    always_comb begin
        mstatus_value = '0;
        mstatus_value[3]    = mstatus_mie;
        mstatus_value[7]    = mstatus_mpie;
        mstatus_value[12:11] = 2'b11; // only M-mode is implemented

        mie_value = '0;
        mie_value[3]  = mie_msie;
        mie_value[7]  = mie_mtie;
        mie_value[11] = mie_meie;

        mip_value = '0;
        mip_value[3]  = irq_software_sync;
        mip_value[7]  = irq_timer_sync;
        mip_value[11] = irq_external_sync;

        read_data_comb        = '0;
        read_implemented_comb = 1'b1;
        read_writable_comb    = 1'b1;
        unique case (read_request.addr)
            CSR_MSTATUS:  read_data_comb = mstatus_value;
            CSR_MISA: begin
                // RV32 + I + M. MXL[1:0]=01 at bits 31:30.
                read_data_comb     = 32'h4000_1100;
                read_writable_comb = 1'b0;
            end
            CSR_MIE:      read_data_comb = mie_value;
            CSR_MTVEC:    read_data_comb = mtvec;
            CSR_MSCRATCH: read_data_comb = mscratch;
            CSR_MEPC:     read_data_comb = mepc;
            CSR_MCAUSE:   read_data_comb = mcause;
            CSR_MTVAL:    read_data_comb = mtval;
            CSR_MIP: begin
                read_data_comb     = mip_value;
                read_writable_comb = 1'b0;
            end
            CSR_MVENDORID, CSR_MARCHID, CSR_MIMPID: begin
                read_data_comb     = '0;
                read_writable_comb = 1'b0;
            end
            CSR_MHARTID: begin
                read_data_comb     = MHARTID;
                read_writable_comb = 1'b0;
            end
            default: begin
                read_data_comb        = '0;
                read_implemented_comb = 1'b0;
                read_writable_comb    = 1'b0;
            end
        endcase

        // Base privileged-spec priority for standard M interrupts:
        // external > software > timer.
        interrupt_pending = 1'b0;
        interrupt_cause   = '0;
        if (mstatus_mie) begin
            if (mie_meie && irq_external_sync) begin
                interrupt_pending = 1'b1;
                interrupt_cause   = 5'd11;
            end else if (mie_msie && irq_software_sync) begin
                interrupt_pending = 1'b1;
                interrupt_cause   = 5'd3;
            end else if (mie_mtie && irq_timer_sync) begin
                interrupt_pending = 1'b1;
                interrupt_cause   = 5'd7;
            end
        end

        mret_target = mepc;
        trap_target = {mtvec[31:2], 2'b00};
        if (trap_event.is_interrupt && (mtvec[1:0] == 2'b01))
            trap_target = {mtvec[31:2], 2'b00}
                        + {25'b0, trap_event.cause, 2'b00};
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            read_response <= '0;
        end else begin
            read_response.valid <= read_request.valid;
            if (read_request.valid) begin
                read_response.data        <= read_data_comb;
                read_response.implemented <= read_implemented_comb;
                read_response.writable    <= read_writable_comb;
            end
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            irq_software_meta <= 1'b0;
            irq_software_sync <= 1'b0;
            irq_timer_meta    <= 1'b0;
            irq_timer_sync    <= 1'b0;
            irq_external_meta <= 1'b0;
            irq_external_sync <= 1'b0;
        end else begin
            irq_software_meta <= irq_software_i;
            irq_software_sync <= irq_software_meta;
            irq_timer_meta    <= irq_timer_i;
            irq_timer_sync    <= irq_timer_meta;
            irq_external_meta <= irq_external_i;
            irq_external_sync <= irq_external_meta;
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            mstatus_mie  <= 1'b0;
            mstatus_mpie <= 1'b0;
            mie_msie     <= 1'b0;
            mie_mtie     <= 1'b0;
            mie_meie     <= 1'b0;
            mtvec        <= {MTVEC_RESET[31:2],
                             (MTVEC_RESET[1:0] == 2'b01) ? 2'b01 : 2'b00};
            mscratch     <= '0;
            mepc         <= '0;
            mcause       <= '0;
            mtval        <= '0;
        end else if (trap_event.valid) begin
            // Trap wins over all normal CSR activity in this cycle. The commit
            // controller never presents a normal CSR commit concurrently.
            mstatus_mpie <= mstatus_mie;
            mstatus_mie  <= 1'b0;
            mepc         <= {trap_event.pc[31:2], 2'b00};
            mcause       <= {trap_event.is_interrupt, 26'b0, trap_event.cause};
            mtval        <= trap_event.is_interrupt ? '0 : trap_event.tval;
        end else if (mret_valid) begin
            mstatus_mie  <= mstatus_mpie;
            mstatus_mpie <= 1'b1;
        end else if (commit_update.valid && commit_update.write_enable) begin
            unique case (commit_update.addr)
                CSR_MSTATUS: begin
                    mstatus_mie  <= commit_update.write_data[3];
                    mstatus_mpie <= commit_update.write_data[7];
                end
                CSR_MIE: begin
                    mie_msie <= commit_update.write_data[3];
                    mie_mtie <= commit_update.write_data[7];
                    mie_meie <= commit_update.write_data[11];
                end
                CSR_MTVEC: begin
                    mtvec[31:2] <= commit_update.write_data[31:2];
                    mtvec[1:0]  <= (commit_update.write_data[1:0] == 2'b01)
                                  ? 2'b01 : 2'b00;
                end
                CSR_MSCRATCH: mscratch <= commit_update.write_data;
                CSR_MEPC:     mepc     <= {commit_update.write_data[31:2], 2'b00};
                CSR_MCAUSE:   mcause   <= commit_update.write_data;
                CSR_MTVAL:    mtval    <= commit_update.write_data;
                default: ; // read-only/unsupported writes are rejected earlier
            endcase
        end
    end

`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
        if (rst_n) begin
            assert (!(trap_event.valid && mret_valid))
                else $error("csr_file: trap and mret cannot occur together");
            assert (!(trap_event.valid && commit_update.valid))
                else $error("csr_file: trap and CSR commit cannot occur together");
        end
    end
`endif

endmodule
