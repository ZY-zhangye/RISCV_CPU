`include "defines.svh"

// =============================================================================
// 写回 + CSR + 精确提交薄封装
// =============================================================================
// 将两组写回仲裁、CSR 单项提交缓存、最小机器态 CSR 文件和提交控制器连接
// 成闭环。ROB/LSQ/Execute 顶层只需连接 typed ports，不再复制 trap 优先级。
// =============================================================================
module writeback_commit_stage #(
    parameter logic [31:0] MTVEC_RESET = 32'h0000_0000,
    parameter logic [31:0] MHARTID      = 32'h0000_0000
) (
    input  logic                                      clk,
    input  logic                                      rst_n,

    input  logic                                      alu0_valid,
    input  wire core_port_pkg::execute_writeback_t    alu0_bus,
    output logic                                      alu0_ready,
    input  logic                                      mlu_valid,
    input  wire core_port_pkg::execute_writeback_t    mlu_bus,
    output logic                                      mlu_ready,
    input  logic                                      alu1_valid,
    input  wire core_port_pkg::execute_writeback_t    alu1_bus,
    output logic                                      alu1_ready,
    input  logic                                      bru_valid,
    input  wire core_port_pkg::execute_writeback_t    bru_bus,
    output logic                                      bru_ready,
    input  logic                                      lsq_valid,
    input  wire core_port_pkg::lsq_writeback_t        lsq_bus,
    output logic                                      lsq_ready,
    input  logic                                      csr_valid,
    input  wire core_port_pkg::execute_writeback_t    csr_bus,
    input  wire core_port_pkg::csr_execute_update_t   csr_update,
    output logic                                      csr_ready,

    // Execute CSR 时序读口及“缓存为空”门控。
    input  wire core_port_pkg::csr_read_request_t     csr_read_request,
    output      core_port_pkg::csr_read_response_t    csr_read_response,
    output logic                                      csr_commit_available,

    // ROB/LSQ commit 侧。
    input  wire core_port_pkg::rob_commit_bundle_t    rob_commit_bus,
    input  logic [1:0]                                rob_commit_fire,
    input  logic [1:0]                                store_commit_ready,
    input  logic                                      rob_empty,
    input  logic [`ADDR_WIDTH-1:0]                    interrupt_pc,
    output logic [1:0]                                rob_commit_ready,

    // 中断引脚。
    input  logic                                      irq_software_i,
    input  logic                                      irq_timer_i,
    input  logic                                      irq_external_i,

    // 全核恢复及写回扇出。
    output      core_port_pkg::recover_event_t        recover,
    output      core_port_pkg::phys_reg_write_bundle_t prf_write,
    output      core_port_pkg::phys_reg_write_bundle_t wakeup_bus,
    output      core_port_pkg::rob_complete_bundle_t   rob_complete
);
    import core_port_pkg::*;

    logic csr_cache_valid;
    csr_execute_update_t csr_cache_update;
    logic csr_cache_enqueue_ready;
    logic [1:0] csr_commit_ready;
    csr_execute_update_t csr_commit_update;
    trap_event_t trap_event;
    logic mret_valid;
    logic [31:0] trap_target;
    logic [31:0] mret_target;
    logic interrupt_pending;
    logic [4:0] interrupt_cause;

    writeback_stage u_writeback (
        .clk(clk), .rst_n(rst_n), .recover(recover),
        .alu0_valid(alu0_valid), .alu0_bus(alu0_bus), .alu0_ready(alu0_ready),
        .mlu_valid(mlu_valid), .mlu_bus(mlu_bus), .mlu_ready(mlu_ready),
        .alu1_valid(alu1_valid), .alu1_bus(alu1_bus), .alu1_ready(alu1_ready),
        .bru_valid(bru_valid), .bru_bus(bru_bus), .bru_ready(bru_ready),
        .lsq_valid(lsq_valid), .lsq_bus(lsq_bus), .lsq_ready(lsq_ready),
        .csr_valid(csr_valid), .csr_bus(csr_bus), .csr_update(csr_update),
        .csr_ready(csr_ready),
        .csr_cache_ready(csr_cache_enqueue_ready),
        .csr_cache_valid(csr_cache_valid),
        .csr_cache_update(csr_cache_update),
        .prf_write(prf_write), .wakeup_bus(wakeup_bus),
        .rob_complete(rob_complete)
    );

    csr_commit_buffer u_csr_commit_buffer (
        .clk(clk), .rst_n(rst_n), .recover(recover),
        .enqueue_valid(csr_cache_valid),
        .enqueue_update(csr_cache_update),
        .enqueue_ready(csr_cache_enqueue_ready),
        .available(csr_commit_available),
        .commit_bus(rob_commit_bus), .commit_fire(rob_commit_fire),
        .commit_ready(csr_commit_ready),
        .commit_update(csr_commit_update)
    );

    csr_file #(.MTVEC_RESET(MTVEC_RESET), .MHARTID(MHARTID)) u_csr_file (
        .clk(clk), .rst_n(rst_n),
        .read_request(csr_read_request),
        .read_response(csr_read_response),
        .commit_update(csr_commit_update),
        .trap_event(trap_event), .mret_valid(mret_valid),
        .trap_target(trap_target), .mret_target(mret_target),
        .irq_software_i(irq_software_i),
        .irq_timer_i(irq_timer_i),
        .irq_external_i(irq_external_i),
        .interrupt_pending(interrupt_pending),
        .interrupt_cause(interrupt_cause)
    );

    commit_controller u_commit_controller (
        .commit_bus(rob_commit_bus),
        .store_commit_ready(store_commit_ready),
        .csr_commit_ready(csr_commit_ready),
        .rob_empty(rob_empty), .interrupt_pc(interrupt_pc),
        .interrupt_pending(interrupt_pending),
        .interrupt_cause(interrupt_cause),
        .trap_target(trap_target), .mret_target(mret_target),
        .commit_ready(rob_commit_ready),
        .recover(recover), .trap_event(trap_event),
        .mret_valid(mret_valid)
    );

endmodule
