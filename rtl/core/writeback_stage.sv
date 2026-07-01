// =============================================================================
// 双写回仲裁
// =============================================================================
// WB0：ALU0 / MLU
// WB1：ALU1 / BRU / LSQ / CSR
//
// 两组各自 round-robin，彼此可同拍写 PRF、广播 Busy Table/IQ，并更新 ROB。
// CSR 只有在提交缓存可接收时才参与正常仲裁；非法 CSR 作为异常完成，不占用
// 提交缓存。所有来源自身均为 valid/ready 保持寄存器，因此未选中时数据稳定。
// =============================================================================
module writeback_stage (
    input  logic                                      clk,
    input  logic                                      rst_n,
    input  wire core_port_pkg::recover_event_t        recover,

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

    input  logic                                      csr_cache_ready,
    output logic                                      csr_cache_valid,
    output      core_port_pkg::csr_execute_update_t   csr_cache_update,

    output      core_port_pkg::phys_reg_write_bundle_t prf_write,
    output      core_port_pkg::phys_reg_write_bundle_t wakeup_bus,
    output      core_port_pkg::rob_complete_bundle_t   rob_complete,
    output      core_port_pkg::branch_update_t         branch_update
);
    import core_port_pkg::*;

    logic wb0_rr;
    logic [1:0] wb1_rr;
    logic wb0_valid;
    logic wb0_select_mlu;
    execute_writeback_t wb0_selected;
    logic wb1_valid;
    logic [1:0] wb1_select;
    execute_writeback_t wb1_selected;
    logic [3:0] wb1_source_valid;
    logic wb1_found;
    logic [1:0] scan_index;
    integer scan_offset;

    function automatic rob_complete_slot_t make_complete(
        input logic valid,
        input execute_writeback_t wb
    );
        rob_complete_slot_t slot;
        begin
            slot = '0;
            slot.valid           = valid;
            slot.tag             = wb.rob_tag;
            slot.exception_valid = wb.exception_valid;
            slot.exc_code        = wb.exc_code;
            slot.exc_tval        = wb.exc_tval;
            slot.redirect_valid  = wb.redirect_valid;
            slot.redirect_target = wb.redirect_target;
            slot.next_pc_valid   = wb.branch_valid;
            slot.next_pc         = wb.branch_taken
                                 ? wb.branch_target : (wb.branch_pc + 32'd4);
            make_complete = slot;
        end
    endfunction

    function automatic phys_reg_write_t make_prf_write(
        input logic valid,
        input execute_writeback_t wb
    );
        phys_reg_write_t write;
        begin
            write = '0;
            write.valid = valid && wb.pdst_valid && !wb.exception_valid;
            write.preg  = wb.pdst;
            write.data  = wb.data;
            make_prf_write = write;
        end
    endfunction

    always_comb begin
        // WB0 two-source round robin.
        wb0_valid = alu0_valid || mlu_valid;
        wb0_select_mlu = mlu_valid && (!alu0_valid || wb0_rr);
        wb0_selected = wb0_select_mlu ? mlu_bus : alu0_bus;
        alu0_ready = wb0_valid && !wb0_select_mlu;
        mlu_ready  = wb0_valid && wb0_select_mlu;

        // WB1 four-source rotating priority. Source numbering is stable so the
        // pointer can advance to selected+1 after every successful writeback.
        wb1_source_valid[0] = alu1_valid;
        wb1_source_valid[1] = bru_valid;
        wb1_source_valid[2] = lsq_valid;
        wb1_source_valid[3] = csr_valid
                            && (csr_bus.exception_valid
                                || (csr_cache_ready && csr_update.valid));
        wb1_found  = 1'b0;
        wb1_select = '0;
        for (scan_offset = 0; scan_offset < 4; scan_offset = scan_offset + 1) begin
            scan_index = wb1_rr + 2'(scan_offset);
            if (!wb1_found && wb1_source_valid[scan_index]) begin
                wb1_found  = 1'b1;
                wb1_select = scan_index;
            end
        end
        wb1_valid = wb1_found;
        wb1_selected = '0;
        unique case (wb1_select)
            2'd0: wb1_selected = alu1_bus;
            2'd1: wb1_selected = bru_bus;
            2'd2: begin
                wb1_selected.rob_tag         = lsq_bus.rob_tag;
                wb1_selected.pdst_valid      = lsq_bus.pdst_valid;
                wb1_selected.pdst            = lsq_bus.pdst;
                wb1_selected.data            = lsq_bus.data;
                wb1_selected.exception_valid = lsq_bus.exception_valid;
                wb1_selected.exc_code        = lsq_bus.exc_code;
                wb1_selected.exc_tval        = lsq_bus.exc_tval;
            end
            2'd3: wb1_selected = csr_bus;
            default: wb1_selected = '0;
        endcase

        alu1_ready = wb1_valid && (wb1_select == 2'd0);
        bru_ready  = wb1_valid && (wb1_select == 2'd1);
        lsq_ready  = wb1_valid && (wb1_select == 2'd2);
        csr_ready  = wb1_valid && (wb1_select == 2'd3);

        csr_cache_valid  = csr_ready && !csr_bus.exception_valid;
        csr_cache_update = csr_update;
        csr_cache_update.valid = csr_cache_valid;

        prf_write = '0;
        prf_write.lane0 = make_prf_write(wb0_valid, wb0_selected);
        prf_write.lane1 = make_prf_write(wb1_valid, wb1_selected);
        wakeup_bus = prf_write;

        rob_complete = '0;
        rob_complete.lane0 = make_complete(wb0_valid, wb0_selected);
        rob_complete.lane1 = make_complete(wb1_valid, wb1_selected);

        branch_update = '0;
        if (wb1_valid && (wb1_select == 2'd1) && bru_bus.branch_valid) begin
            branch_update.valid   = 1'b1;
            branch_update.pc      = bru_bus.branch_pc;
            branch_update.taken   = bru_bus.branch_taken;
            branch_update.target  = bru_bus.branch_target;
            branch_update.is_jalr = bru_bus.branch_is_jalr;
        end

        // recovery 拍禁止任何 PRF/CSR/ROB 副作用。执行单元会在同一上升沿
        // 清除 valid，显式屏蔽可避免错误路径数据仍写入物理寄存器阵列。
        if (recover.valid) begin
            alu0_ready = 1'b0;
            mlu_ready  = 1'b0;
            alu1_ready = 1'b0;
            bru_ready  = 1'b0;
            lsq_ready  = 1'b0;
            csr_ready  = 1'b0;
            csr_cache_valid = 1'b0;
            prf_write   = '0;
            wakeup_bus  = '0;
            rob_complete = '0;
            branch_update = '0;
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n || recover.valid) begin
            wb0_rr <= 1'b0;
            wb1_rr <= 2'd0;
        end else begin
            if (wb0_valid)
                wb0_rr <= wb0_select_mlu ? 1'b0 : 1'b1;
            if (wb1_valid)
                wb1_rr <= wb1_select + 2'd1;
        end
    end

`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
        if (rst_n && !recover.valid && csr_cache_valid) begin
            assert (csr_update.valid && (csr_update.rob_tag == csr_bus.rob_tag))
                else $error("writeback_stage: CSR data/update tag mismatch");
        end
    end
`endif

endmodule
