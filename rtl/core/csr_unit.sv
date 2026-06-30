`include "defines.svh"

// =============================================================================
// CSR 执行单元（时序读）
// =============================================================================
// CSR 指令先向 csr_file 发出一拍读请求，下一拍收到 data/implemented/writable，
// 再计算新值并形成执行完成包。未实现 CSR，或真正尝试写只读 CSR，均精确
// 转换为 illegal-instruction；CSRRS/CSRRC source=0 仍是合法只读访问。
//
// 新值只进入 csr_commit_buffer，不在乱序执行时修改 CSR 文件。提交缓存未空
// 时 execute_stage 会屏蔽 csr_available，确保后一条 CSR 不会读取旧状态。
// =============================================================================
module csr_unit (
    input  logic                                      clk,
    input  logic                                      rst_n,
    input  wire core_port_pkg::recover_event_t        recover,

    input  logic                                      in_valid,
    input  wire core_port_pkg::execute_operand_t      in_bus,
    output logic                                      in_ready,

    output      core_port_pkg::csr_read_request_t     csr_read_request,
    input  wire core_port_pkg::csr_read_response_t    csr_read_response,

    output logic                                      out_valid,
    output      core_port_pkg::execute_writeback_t    out_bus,
    output      core_port_pkg::csr_execute_update_t   csr_update,
    input  logic                                      out_ready
);
    import core_port_pkg::*;

    typedef enum logic [1:0] {
        CSR_IDLE,
        CSR_READ_WAIT,
        CSR_RESULT
    } csr_state_e;

    csr_state_e state;
    execute_operand_t pending_bus;
    logic [XLEN-1:0] source_reg;
    execute_writeback_t result_reg;
    csr_execute_update_t update_reg;
    logic [XLEN-1:0] csr_new_value;
    logic requested_write_enable;
    logic illegal_access;

    always_comb begin
        csr_new_value = csr_read_response.data;
        requested_write_enable = 1'b0;
        unique case (pending_bus.issue.uop.dec.csr_op)
            CSR_WRITE: begin
                csr_new_value = source_reg;
                requested_write_enable = 1'b1;
            end
            CSR_SET: begin
                csr_new_value = csr_read_response.data | source_reg;
                requested_write_enable = (source_reg != '0);
            end
            CSR_CLEAR: begin
                csr_new_value = csr_read_response.data & ~source_reg;
                requested_write_enable = (source_reg != '0);
            end
            default: begin
                csr_new_value = csr_read_response.data;
                requested_write_enable = 1'b0;
            end
        endcase
        illegal_access = !csr_read_response.implemented
                       || (requested_write_enable
                           && !csr_read_response.writable);

        in_ready = (state == CSR_IDLE);
        csr_read_request = '0;
        csr_read_request.valid = in_valid && in_ready && !recover.valid;
        csr_read_request.addr  = in_bus.issue.uop.dec.csr_addr;

        out_valid = (state == CSR_RESULT);
        out_bus   = result_reg;
        csr_update = update_reg;
        csr_update.valid = out_valid && !result_reg.exception_valid;
    end

    always_ff @(posedge clk) begin
        if (!rst_n || recover.valid) begin
            state       <= CSR_IDLE;
            pending_bus <= '0;
            source_reg  <= '0;
            result_reg  <= '0;
            update_reg  <= '0;
        end else begin
            unique case (state)
                CSR_IDLE: begin
                    if (in_valid) begin
                        pending_bus <= in_bus;
                        source_reg <= in_bus.issue.uop.dec.csr_use_imm
                                    ? in_bus.issue.uop.dec.imm
                                    : in_bus.rs1_value;
                        state <= CSR_READ_WAIT;
                    end
                end

                CSR_READ_WAIT: begin
                    if (csr_read_response.valid) begin
                        result_reg <= '0;
                        result_reg.rob_tag <= pending_bus.issue.rob_tag;
                        result_reg.pdst_valid <= pending_bus.issue.uop.pdst_valid
                                              && !illegal_access;
                        result_reg.pdst <= pending_bus.issue.uop.pdst;
                        result_reg.data <= csr_read_response.data;
                        result_reg.exception_valid <= illegal_access;
                        result_reg.exc_code <= illegal_access
                                             ? `EXC_ILLEGAL_INST : `EXC_NONE;
                        result_reg.exc_tval <= illegal_access
                                             ? pending_bus.issue.uop.dec.inst : '0;

                        update_reg <= '0;
                        update_reg.rob_tag <= pending_bus.issue.rob_tag;
                        update_reg.addr <= pending_bus.issue.uop.dec.csr_addr;
                        update_reg.write_enable <= requested_write_enable
                                                 && !illegal_access;
                        update_reg.write_data <= csr_new_value;
                        state <= CSR_RESULT;
                    end
                end

                CSR_RESULT: begin
                    if (out_ready)
                        state <= CSR_IDLE;
                end

                default: state <= CSR_IDLE;
            endcase
        end
    end

endmodule
