`include "defines.svh"

// =============================================================================
// LSU 地址生成单元（AGU）
// =============================================================================
// 本单元只完成 base + immediate，并把可用的 Store data 返回 LSQ。它刻意
// 保持为组合级：issue 发出后的第 1 拍完成同步 PRF 读取，第 2 拍由 LSQ 锁存
// AGU 结果，第 3 拍 LSQ 的 memory_request_reg 对外发请求，第 4 拍同步 DMEM
// 返回结果。LSQ 内部的请求寄存级即“访存单元外打一拍”的时序切断点。
//
// 地址对齐检查、Store forwarding、提交后 Store 排空及访问异常仍由 LSQ
// 统一处理，避免在 AGU 和队列中复制状态。
// =============================================================================
module lsu_unit (
    input  logic                                      recover_valid,
    input  logic                                      in_valid,
    input  wire core_port_pkg::execute_operand_t      in_bus,
    output logic                                      in_ready,
    output      core_port_pkg::lsq_agu_result_t       agu_result
);
    import core_port_pkg::*;

    always_comb begin
        in_ready  = 1'b1;
        agu_result = '0;
        agu_result.valid      = in_valid && !recover_valid;
        agu_result.lsq_tag    = in_bus.issue.lsq_tag;
        agu_result.address    = in_bus.rs1_value
                              + in_bus.issue.uop.dec.imm;
        agu_result.store_data_valid = in_bus.issue.read_store_data;
        agu_result.store_data = in_bus.rs2_value;
    end

`ifndef SYNTHESIS
    always_comb begin
        if (in_valid)
            assert (in_bus.issue.from_lsq)
                else $error("lsu_unit: non-LSQ packet sent to AGU");
    end
`endif

endmodule
