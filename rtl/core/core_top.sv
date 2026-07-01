`include "defines.svh"

// =============================================================================
// RV32 双发射乱序处理器核顶层
// =============================================================================
// 本层只连接 IF / ID / backend_top，不包含 Cache、RAM 或 SoC 外设。
// IMEM 保持固定一周期的 64-bit 同步读接口；DMEM 延用 LSQ typed 请求/响应。
// =============================================================================
module core_top #(
    parameter int          RENAME_FIFO_DEPTH = 4,
    parameter int          MUL_LATENCY       = 3,
    parameter logic [31:0] RESET_PC          = `PC_START,
    parameter logic [31:0] MTVEC_RESET       = 32'h0000_0000,
    parameter logic [31:0] MHARTID           = 32'h0000_0000
) (
    input  logic                                      clk,
    input  logic                                      rst_n,

    // 固定一周期、双指令宽度的同步取指接口。
    output logic [`ADDR_WIDTH-1:0]                    imem_addr_o,
    output logic                                      imem_ren_o,
    input  logic [`DATA_WIDTH-1:0]                    imem_rdata_i,

    // 数据存储器请求/响应接口。
    output logic                                      dmem_request_valid_o,
    output      core_port_pkg::lsq_mem_request_t      dmem_request_o,
    input  logic                                      dmem_request_ready_i,
    input  wire core_port_pkg::lsq_mem_response_t     dmem_response_i,

    input  logic                                      irq_software_i,
    input  logic                                      irq_timer_i,
    input  logic                                      irq_external_i,

    // Vendor-neutral 乘除法 IP 适配接口。
    output logic                                      mul_request_valid_o,
    output logic signed [32:0]                        mul_operand_a_o,
    output logic signed [32:0]                        mul_operand_b_o,
    input  logic signed [65:0]                        mul_product_i,
    output logic                                      div_dividend_valid_o,
    input  logic                                      div_dividend_ready_i,
    output logic signed [32:0]                        div_dividend_data_o,
    output logic                                      div_divisor_valid_o,
    input  logic                                      div_divisor_ready_i,
    output logic signed [32:0]                        div_divisor_data_o,
    input  logic                                      div_result_valid_i,
    output logic                                      div_result_ready_o,
    input  logic signed [32:0]                        div_quotient_i,
    input  logic signed [32:0]                        div_remainder_i,

    // 前端恢复、预测训练与提交调试接口。
    output      core_port_pkg::recover_event_t        recover_o,
    output      core_port_pkg::branch_update_t        branch_update_o,
    output logic                                      fence_i_commit_o,
    output      core_port_pkg::rob_commit_bundle_t    commit_bus_o,
    output logic [1:0]                                commit_fire_o,
    output logic                                      core_idle_o
);
    import core_port_pkg::*;

    logic fs_to_ds_valid;
    logic ds_allowin;
    logic [`FS_DS_WIDTH-1:0] fs_to_ds_bus;
    logic [`EXC_WIDTH-1:0] fs_exc_bus;
    logic ds_to_rn_valid;
    logic rn_allowin;
    ds_rn_bundle_t ds_to_rn_bus;

    if_stage #(.RESET_PC(RESET_PC)) u_if_stage (
        .clk(clk),
        .rst_n(rst_n),
        .pc_out(imem_addr_o),
        .inst_ren(imem_ren_o),
        .inst_in(imem_rdata_i),
        .ds_allowin(ds_allowin),
        .fs_to_ds_valid(fs_to_ds_valid),
        .fs_to_ds_bus(fs_to_ds_bus),
        .recover(recover_o),
        .branch_update(branch_update_o),
        .fs_exc_bus(fs_exc_bus)
    );

    id_stage u_id_stage (
        .clk(clk),
        .rst_n(rst_n),
        .fs_to_ds_valid(fs_to_ds_valid),
        .ds_allowin(ds_allowin),
        .fs_to_ds_bus(fs_to_ds_bus),
        .fs_exc_bus(fs_exc_bus),
        .ds_to_rn_valid(ds_to_rn_valid),
        .rn_allowin(rn_allowin),
        .ds_to_rn_bus(ds_to_rn_bus),
        .recover(recover_o)
    );

    backend_top #(
        .RENAME_FIFO_DEPTH(RENAME_FIFO_DEPTH),
        .MUL_LATENCY(MUL_LATENCY),
        .RESET_PC(RESET_PC),
        .MTVEC_RESET(MTVEC_RESET),
        .MHARTID(MHARTID)
    ) u_backend (
        .clk(clk),
        .rst_n(rst_n),
        .ds_to_rn_valid(ds_to_rn_valid),
        .ds_to_rn_bus(ds_to_rn_bus),
        .rn_allowin(rn_allowin),
        .mem_request_valid(dmem_request_valid_o),
        .mem_request(dmem_request_o),
        .mem_request_ready(dmem_request_ready_i),
        .mem_response(dmem_response_i),
        .irq_software_i(irq_software_i),
        .irq_timer_i(irq_timer_i),
        .irq_external_i(irq_external_i),
        .mul_request_valid(mul_request_valid_o),
        .mul_operand_a(mul_operand_a_o),
        .mul_operand_b(mul_operand_b_o),
        .mul_product(mul_product_i),
        .div_dividend_valid(div_dividend_valid_o),
        .div_dividend_ready(div_dividend_ready_i),
        .div_dividend_data(div_dividend_data_o),
        .div_divisor_valid(div_divisor_valid_o),
        .div_divisor_ready(div_divisor_ready_i),
        .div_divisor_data(div_divisor_data_o),
        .div_result_valid(div_result_valid_i),
        .div_result_ready(div_result_ready_o),
        .div_quotient(div_quotient_i),
        .div_remainder(div_remainder_i),
        .recover_o(recover_o),
        .branch_update_o(branch_update_o),
        .fence_i_commit_o(fence_i_commit_o),
        .commit_bus_o(commit_bus_o),
        .commit_fire_o(commit_fire_o),
        .backend_idle_o(core_idle_o)
    );

endmodule
