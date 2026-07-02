// =============================================================================
// 两个独立静态分区 IQ bank 的薄封装
// =============================================================================
// 本质上是 issue_queue 模块的两个例化，固定参数：
//   IQ0：BANK_ID=0，支持 ALU / MLU，屏蔽 BRU / CSR
//   IQ1：BANK_ID=1，支持 ALU / BRU / CSR，屏蔽 MLU
//
// Dispatch 按 FU 类型路由：
//   ALU → 容量感知分流到 IQ0 或 IQ1
//   MLU → IQ0（固定）
//   BRU → IQ1（固定）
//   CSR → IQ1（固定）
// =============================================================================
module issue_queue_pair (
    input  logic                                  clk,
    input  logic                                  rst_n,
    input  wire core_port_pkg::recover_event_t    recover,
    input  wire core_port_pkg::rob_tag_t          rob_head_tag_iq0,
    input  wire core_port_pkg::rob_tag_t          rob_head_tag_iq1,
    input  wire core_port_pkg::phys_reg_write_bundle_t wakeup_bus,

    // ---- IQ0 入队与容量 ----
    input  logic [1:0]                            iq0_enq_valid,
    input  wire core_port_pkg::dp_iq_bundle_t     iq0_enq_bus,
    output      core_port_pkg::dispatch_capacity_t iq0_capacity,
    // ---- IQ1 入队与容量 ----
    input  logic [1:0]                            iq1_enq_valid,
    input  wire core_port_pkg::dp_iq_bundle_t     iq1_enq_bus,
    output      core_port_pkg::dispatch_capacity_t iq1_capacity,

    // ---- 功能单元可用性 ----
    // 各功能单元由外部执行单元通过本拍组合信号通知 IQ，
    // 用于 issue 选择时判断相应执行单元是否空闲。
    input  logic                                  alu0_available,
    input  logic                                  mlu_available,
    input  logic                                  alu1_available,
    input  logic                                  bru_available,
    input  logic                                  csr_available,

    // ---- issue0（AL0 / MLU）----
    output logic                                  issue0_valid,
    output      core_port_pkg::iq_issue_slot_t    issue0_bus,
    input  logic                                  issue0_ready,
    output logic                                  issue0_fire,
    output      core_port_pkg::iq_prf_read_req_t  issue0_prf_req,

    // ---- issue1（AL1 / BRU / CSR，与 LSQ 仲裁后决定）----
    output logic                                  issue1_valid,
    output      core_port_pkg::iq_issue_slot_t    issue1_bus,
    input  logic                                  issue1_ready,
    output logic                                  issue1_fire,
    output      core_port_pkg::iq_prf_read_req_t  issue1_prf_req
);
    // issue_queue 例化时各 bank 的 fu_available 输入固定：
    //   不支持的 FU 类型始终接 1'b0，确保永远不会被 select。
    // ==========================================================================
    // IQ0：ALU0 / MLU
    // 只关注 alu0_available、mlu_available，其余接 0。
    // ==========================================================================
    issue_queue #(.BANK_ID(0), .DEPTH(8)) u_iq0 (
        .clk            (clk),
        .rst_n          (rst_n),
        .enq_valid      (iq0_enq_valid),
        .enq_bus        (iq0_enq_bus),
        .capacity       (iq0_capacity),
        .wakeup_bus     (wakeup_bus),
        .rob_head_tag   (rob_head_tag_iq0),
        .recover        (recover),
        .alu_available  (alu0_available),
        .mlu_available  (mlu_available),
        .bru_available  (1'b0),
        .csr_available  (1'b0),
        .issue_valid    (issue0_valid),
        .issue_bus      (issue0_bus),
        .issue_ready    (issue0_ready),
        .issue_fire     (issue0_fire),
        .prf_read_req   (issue0_prf_req),
        .occupancy_o    ()
    );

    // ==========================================================================
    // IQ1：ALU1 / BRU / CSR
    // 只关注 alu1_available、bru_available、csr_available，MLU 接 0。
    // ==========================================================================
    issue_queue #(.BANK_ID(1), .DEPTH(8)) u_iq1 (
        .clk            (clk),
        .rst_n          (rst_n),
        .enq_valid      (iq1_enq_valid),
        .enq_bus        (iq1_enq_bus),
        .capacity       (iq1_capacity),
        .wakeup_bus     (wakeup_bus),
        .rob_head_tag   (rob_head_tag_iq1),
        .recover        (recover),
        .alu_available  (alu1_available),
        .mlu_available  (1'b0),
        .bru_available  (bru_available),
        .csr_available  (csr_available),
        .issue_valid    (issue1_valid),
        .issue_bus      (issue1_bus),
        .issue_ready    (issue1_ready),
        .issue_fire     (issue1_fire),
        .prf_read_req   (issue1_prf_req),
        .occupancy_o    ()
    );

endmodule
