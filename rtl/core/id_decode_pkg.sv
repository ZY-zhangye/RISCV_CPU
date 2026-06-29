`include "defines.svh"

package id_decode_pkg;
    import core_port_pkg::*;

    function automatic logic [31:0] imm_i(input logic [31:0] inst);
        imm_i = {{20{inst[31]}}, inst[31:20]};
    endfunction

    function automatic logic [31:0] imm_s(input logic [31:0] inst);
        imm_s = {{20{inst[31]}}, inst[31:25], inst[11:7]};
    endfunction

    function automatic logic [31:0] imm_b(input logic [31:0] inst);
        imm_b = {{19{inst[31]}}, inst[31], inst[7], inst[30:25],
                 inst[11:8], 1'b0};
    endfunction

    function automatic logic [31:0] imm_u(input logic [31:0] inst);
        imm_u = {inst[31:12], 12'b0};
    endfunction

    function automatic logic [31:0] imm_j(input logic [31:0] inst);
        imm_j = {{11{inst[31]}}, inst[31], inst[19:12], inst[20],
                 inst[30:21], 1'b0};
    endfunction

    function automatic ds_rn_slot_t decode_instruction(
        input fs_ds_slot_t                 slot,
        input logic [`EXC_CODE_WIDTH-1:0] fetch_exc_code,
        input logic [`ADDR_WIDTH-1:0]     fetch_exc_tval
    );
        ds_rn_slot_t d;
        logic [6:0] opcode;
        logic [2:0] funct3;
        logic [6:0] funct7;
        logic       legal;

        d = '0;
        opcode = slot.inst[6:0];
        funct3 = slot.inst[14:12];
        funct7 = slot.inst[31:25];
        legal = 1'b1;

        d.valid       = (slot.inst != `NOP_INST);
        d.pc          = slot.pc;
        d.inst        = slot.inst;
        d.pred_taken  = slot.pred_taken;
        d.pred_target = slot.pred_target;
        d.rs1         = slot.inst[19:15];
        d.rs2         = slot.inst[24:20];
        d.rd          = slot.inst[11:7];
        d.fu_type     = FU_NONE;
        d.alu_op      = ALU_ADD;
        d.mlu_op      = MLU_NONE;
        d.branch_op   = BR_NONE;
        d.mem_op      = MEM_NONE;
        d.csr_op      = CSR_NONE;
        d.exc_code    = fetch_exc_code;
        d.exc_tval    = fetch_exc_tval;

        // 上游取指异常优先，异常指令仍需进入 ROB 以实现精确异常。
        if (fetch_exc_code != `EXC_NONE) begin
            d.valid = 1'b1;
        end else if (slot.inst == `NOP_INST) begin
            // IF 插入的 NOP 不占用后端资源；真正的软件 NOP 也可安全丢弃。
            d.valid = 1'b0;
        end else begin
            unique case (opcode)
                7'b0110111: begin // LUI
                    d.fu_type     = FU_ALU;
                    d.alu_op      = ALU_ADD;
                    d.imm         = imm_u(slot.inst);
                    d.src2_is_imm = 1'b1;
                    d.rd_wen      = (d.rd != 5'd0);
                end

                7'b0010111: begin // AUIPC
                    d.fu_type     = FU_ALU;
                    d.alu_op      = ALU_ADD;
                    d.imm         = imm_u(slot.inst);
                    d.src1_is_pc  = 1'b1;
                    d.src2_is_imm = 1'b1;
                    d.rd_wen      = (d.rd != 5'd0);
                end

                7'b1101111: begin // JAL
                    d.fu_type   = FU_BRU;
                    d.branch_op = BR_JUMP;
                    d.imm       = imm_j(slot.inst);
                    d.rd_wen    = (d.rd != 5'd0);
                end

                7'b1100111: begin // JALR
                    if (funct3 == 3'b000) begin
                        d.fu_type   = FU_BRU;
                        d.branch_op = BR_JUMP;
                        d.imm       = imm_i(slot.inst);
                        d.use_rs1   = 1'b1;
                        d.rd_wen    = (d.rd != 5'd0);
                    end else begin
                        legal = 1'b0;
                    end
                end

                7'b1100011: begin // 条件分支
                    d.fu_type = FU_BRU;
                    d.imm     = imm_b(slot.inst);
                    d.use_rs1 = 1'b1;
                    d.use_rs2 = 1'b1;
                    unique case (funct3)
                        3'b000: d.branch_op = BR_BEQ;
                        3'b001: d.branch_op = BR_BNE;
                        3'b100: d.branch_op = BR_BLT;
                        3'b101: d.branch_op = BR_BGE;
                        3'b110: d.branch_op = BR_BLTU;
                        3'b111: d.branch_op = BR_BGEU;
                        default: legal = 1'b0;
                    endcase
                end

                7'b0000011: begin // LOAD
                    d.fu_type     = FU_LSU;
                    d.imm         = imm_i(slot.inst);
                    d.use_rs1     = 1'b1;
                    d.src2_is_imm = 1'b1;
                    d.rd_wen      = (d.rd != 5'd0);
                    unique case (funct3)
                        3'b000: d.mem_op = MEM_BYTE;
                        3'b001: d.mem_op = MEM_HALF;
                        3'b010: d.mem_op = MEM_WORD;
                        3'b100: d.mem_op = MEM_BYTE_U;
                        3'b101: d.mem_op = MEM_HALF_U;
                        default: legal = 1'b0;
                    endcase
                end

                7'b0100011: begin // STORE
                    d.fu_type  = FU_LSU;
                    d.imm      = imm_s(slot.inst);
                    d.use_rs1  = 1'b1;
                    d.use_rs2  = 1'b1;
                    d.mem_write = 1'b1;
                    unique case (funct3)
                        3'b000: d.mem_op = MEM_BYTE;
                        3'b001: d.mem_op = MEM_HALF;
                        3'b010: d.mem_op = MEM_WORD;
                        default: legal = 1'b0;
                    endcase
                end

                7'b0010011: begin // OP-IMM
                    d.fu_type     = FU_ALU;
                    d.imm         = imm_i(slot.inst);
                    d.use_rs1     = 1'b1;
                    d.src2_is_imm = 1'b1;
                    d.rd_wen      = (d.rd != 5'd0);
                    unique case (funct3)
                        3'b000: d.alu_op = ALU_ADD;
                        3'b010: d.alu_op = ALU_SLT;
                        3'b011: d.alu_op = ALU_SLTU;
                        3'b100: d.alu_op = ALU_XOR;
                        3'b110: d.alu_op = ALU_OR;
                        3'b111: d.alu_op = ALU_AND;
                        3'b001: begin
                            d.alu_op = ALU_SLL;
                            legal = (funct7 == 7'b0000000);
                        end
                        3'b101: begin
                            if (funct7 == 7'b0000000)
                                d.alu_op = ALU_SRL;
                            else if (funct7 == 7'b0100000)
                                d.alu_op = ALU_SRA;
                            else
                                legal = 1'b0;
                        end
                        default: legal = 1'b0;
                    endcase
                end

                7'b0110011: begin // OP
                    d.use_rs1 = 1'b1;
                    d.use_rs2 = 1'b1;
                    d.rd_wen  = (d.rd != 5'd0);
                    if (funct7 == 7'b0000001) begin
                        d.fu_type = FU_MLU;
                        unique case (funct3)
                            3'b000: d.mlu_op = MLU_MUL;
                            3'b001: d.mlu_op = MLU_MULH;
                            3'b010: d.mlu_op = MLU_MULHSU;
                            3'b011: d.mlu_op = MLU_MULHU;
                            3'b100: d.mlu_op = MLU_DIV;
                            3'b101: d.mlu_op = MLU_DIVU;
                            3'b110: d.mlu_op = MLU_REM;
                            3'b111: d.mlu_op = MLU_REMU;
                            default: legal = 1'b0;
                        endcase
                    end else begin
                        d.fu_type = FU_ALU;
                        unique case ({funct7, funct3})
                            10'b0000000_000: d.alu_op = ALU_ADD;
                            10'b0100000_000: d.alu_op = ALU_SUB;
                            10'b0000000_001: d.alu_op = ALU_SLL;
                            10'b0000000_010: d.alu_op = ALU_SLT;
                            10'b0000000_011: d.alu_op = ALU_SLTU;
                            10'b0000000_100: d.alu_op = ALU_XOR;
                            10'b0000000_101: d.alu_op = ALU_SRL;
                            10'b0100000_101: d.alu_op = ALU_SRA;
                            10'b0000000_110: d.alu_op = ALU_OR;
                            10'b0000000_111: d.alu_op = ALU_AND;
                            default: legal = 1'b0;
                        endcase
                    end
                end

                7'b1110011: begin // SYSTEM / Zicsr
                    if (slot.inst == 32'h0000_0073) begin
                        d.fu_type  = FU_SYS;
                        d.exc_code = `EXC_ECALL_M;
                    end else if (slot.inst == 32'h0010_0073) begin
                        d.fu_type  = FU_SYS;
                        d.exc_code = `EXC_BREAKPOINT;
                    end else if (slot.inst == 32'h3020_0073) begin
                        d.fu_type  = FU_SYS;
                        d.exc_code = `EXC_MRET;
                    end else begin
                        d.fu_type    = FU_CSR;
                        d.csr_addr   = slot.inst[31:20];
                        d.rd_wen     = (d.rd != 5'd0);
                        d.csr_use_imm = funct3[2];
                        d.use_rs1    = ~funct3[2];
                        d.imm        = {27'b0, slot.inst[19:15]};
                        unique case (funct3)
                            3'b001, 3'b101: d.csr_op = CSR_WRITE;
                            3'b010, 3'b110: d.csr_op = CSR_SET;
                            3'b011, 3'b111: d.csr_op = CSR_CLEAR;
                            default: legal = 1'b0;
                        endcase
                    end
                end

                7'b0001111: begin // FENCE/FENCE.I，后端作为串行化指令处理
                    d.fu_type = FU_SYS;
                    legal = (funct3 == 3'b000) || (funct3 == 3'b001);
                end

                default: legal = 1'b0;
            endcase

            if (!legal) begin
                d.illegal  = 1'b1;
                d.exc_code = `EXC_ILLEGAL_INST;
                d.exc_tval = slot.inst;
                // 非法指令只进入 ROB，不应被错误地发往某个执行单元。
                d.fu_type  = FU_NONE;
                d.rd_wen   = 1'b0;
                d.use_rs1  = 1'b0;
                d.use_rs2  = 1'b0;
            end
        end

        decode_instruction = d;
    endfunction

endpackage
