`timescale 1ns/1ps

// decode_pkg.sv
// 译码辅助函数与单指令译码逻辑包 (Decode Helper & Single Slot Decoder Package)
// 职责：
// 1. 提供 RISC-V 各种指令格式的立即数解算与符号扩展函数（I型, S型, B型, U型, J型）；
// 2. 封装单条指令译码函数 `decode_slot`，完成操作码分类、源/目的寄存器提取、立即数拼装和非法指令识别；
// 3. 支持 RV32I、RV32M (乘除法) 以及 Zicsr 扩展指令集的全面译码。

package decode_pkg;
  import core_types_pkg::*;

  // 非法指令异常码定义
  localparam logic [3:0] EXC_ILLEGAL_INSTRUCTION = 4'd2;

  // ==========================================================================
  // 1. 立即数解析与扩展函数 (Immediate Extractors)
  // ==========================================================================
  // I 型指令立即数提取 (12位符号扩展)
  function automatic logic [31:0] imm_i(input logic [31:0] inst);
    imm_i = {{20{inst[31]}}, inst[31:20]};
  endfunction

  // S 型指令立即数提取 (12位符号扩展)
  function automatic logic [31:0] imm_s(input logic [31:0] inst);
    imm_s = {{20{inst[31]}}, inst[31:25], inst[11:7]};
  endfunction

  // B 型条件分支指令立即数提取 (13位符号扩展，最低位恒为0)
  function automatic logic [31:0] imm_b(input logic [31:0] inst);
    imm_b = {{19{inst[31]}}, inst[31], inst[7], inst[30:25],
             inst[11:8], 1'b0};
  endfunction

  // U 型高位立即数提取 (高20位有效，低12位填充0)
  function automatic logic [31:0] imm_u(input logic [31:0] inst);
    imm_u = {inst[31:12], 12'b0};
  endfunction

  // J 型无条件跳转指令立即数提取 (21位符号扩展，最低位恒为0)
  function automatic logic [31:0] imm_j(input logic [31:0] inst);
    imm_j = {{11{inst[31]}}, inst[31], inst[19:12], inst[20],
             inst[30:21], 1'b0};
  endfunction

  // ==========================================================================
  // 2. 单条指令译码函数 (Core Decode Slot Logic)
  // ==========================================================================
  function automatic decoded_uop_t decode_slot(input fetch_slot_t slot);
    decoded_uop_t result;
    logic legal;
    logic [6:0] opcode;
    logic [2:0] funct3;
    logic [6:0] funct7;

    result = '0;
    legal = 1'b1;
    opcode = slot.inst[6:0];
    funct3 = slot.inst[14:12];
    funct7 = slot.inst[31:25];

    // 透传基础属性
    result.pc = slot.pc;
    result.inst = slot.inst;
    result.rs1 = slot.inst[19:15];
    result.rs2 = slot.inst[24:20];
    result.rd = slot.inst[11:7];
    result.pred_taken = slot.pred_taken;
    result.pred_target = slot.pred_target;
    result.fetch_id = slot.fetch_id;

    // A. 优先处理前级传入的取指异常：
    // 若在取指时已经触发异常 (例如指令地址非对齐)，则该 slot 直接标记为异常，
    // 不再执行具体译码判断，保证取指阶段异常的优先级最高。
    if (slot.exception_valid) begin
      result.exception_valid = 1'b1;
      result.exception_cause = slot.exception_cause;
      result.exception_tval = slot.exception_tval;
    end else begin
      // B. 正常指令译码主状态机
      case (opcode)
        7'b0110111: begin // LUI 指令
          result.fu_type = FU_INT;
          result.alu_op = ALU_LUI;
          result.write_rd = (result.rd != 0);
          result.imm = imm_u(slot.inst);
        end

        7'b0010111: begin // AUIPC 指令
          result.fu_type = FU_INT;
          result.alu_op = ALU_AUIPC;
          result.write_rd = (result.rd != 0);
          result.imm = imm_u(slot.inst);
        end

        7'b1101111: begin // JAL 指令
          result.fu_type = FU_BRANCH;
          result.branch_op = BR_JAL;
          result.write_rd = (result.rd != 0);
          result.imm = imm_j(slot.inst);
        end

        7'b1100111: begin // JALR 指令
          if (funct3 == 3'b000) begin
            result.fu_type = FU_BRANCH;
            result.branch_op = BR_JALR;
            result.need_rs1 = 1'b1;
            result.write_rd = (result.rd != 0);
            result.imm = imm_i(slot.inst);
          end else begin
            legal = 1'b0;
          end
        end

        7'b1100011: begin // 条件分支指令组 (BEQ/BNE/BLT/BGE/BLTU/BGEU)
          result.fu_type = FU_BRANCH;
          result.need_rs1 = 1'b1;
          result.need_rs2 = 1'b1;
          result.imm = imm_b(slot.inst);
          case (funct3)
            3'b000: result.branch_op = BR_EQ;
            3'b001: result.branch_op = BR_NE;
            3'b100: result.branch_op = BR_LT;
            3'b101: result.branch_op = BR_GE;
            3'b110: result.branch_op = BR_LTU;
            3'b111: result.branch_op = BR_GEU;
            default: legal = 1'b0;
          endcase
        end

        7'b0000011: begin // 加载指令组 (LB/LH/LW/LBU/LHU)
          result.fu_type = FU_LSU;
          result.need_rs1 = 1'b1;
          result.write_rd = (result.rd != 0);
          result.imm = imm_i(slot.inst);
          case (funct3)
            3'b000: result.mem_op = MEM_LB;
            3'b001: result.mem_op = MEM_LH;
            3'b010: result.mem_op = MEM_LW;
            3'b100: result.mem_op = MEM_LBU;
            3'b101: result.mem_op = MEM_LHU;
            default: legal = 1'b0;
          endcase
        end

        7'b0100011: begin // 存储指令组 (SB/SH/SW)
          result.fu_type = FU_LSU;
          result.need_rs1 = 1'b1;
          result.need_rs2 = 1'b1;
          result.imm = imm_s(slot.inst);
          case (funct3)
            3'b000: result.mem_op = MEM_SB;
            3'b001: result.mem_op = MEM_SH;
            3'b010: result.mem_op = MEM_SW;
            default: legal = 1'b0;
          endcase
        end

        7'b0010011: begin // 寄存器-立即数整型指令 (ADDI/SLTI/SLTIU/XORI/ORI/ANDI/SLLI/SRLI/SRAI)
          result.fu_type = FU_INT;
          result.need_rs1 = 1'b1;
          result.write_rd = (result.rd != 0);
          result.imm = imm_i(slot.inst);
          case (funct3)
            3'b000: result.alu_op = ALU_ADD;  // ADDI
            3'b010: result.alu_op = ALU_SLT;  // SLTI
            3'b011: result.alu_op = ALU_SLTU; // SLTIU
            3'b100: result.alu_op = ALU_XOR;  // XORI
            3'b110: result.alu_op = ALU_OR;   // ORI
            3'b111: result.alu_op = ALU_AND;  // ANDI
            3'b001: begin // SLLI (逻辑左移)
              result.imm = {27'b0, slot.inst[24:20]}; // shift-amount (shamt)
              if (funct7 == 7'b0000000)
                result.alu_op = ALU_SLL;
              else
                legal = 1'b0;
            end
            3'b101: begin // SRLI/SRAI (逻辑/算术右移)
              result.imm = {27'b0, slot.inst[24:20]}; // shift-amount (shamt)
              if (funct7 == 7'b0000000)
                result.alu_op = ALU_SRL;
              else if (funct7 == 7'b0100000)
                result.alu_op = ALU_SRA;
              else
                legal = 1'b0;
            end
            default: legal = 1'b0;
          endcase
        end

        7'b0110011: begin // 寄存器-寄存器指令组 (RV32I 基础运算 与 RV32M 乘除法扩展)
          result.need_rs1 = 1'b1;
          result.need_rs2 = 1'b1;
          result.write_rd = (result.rd != 0);
          if (funct7 == 7'b0000001) begin
            // RV32M 乘除法扩展指令组
            case (funct3)
              3'b000: begin result.fu_type = FU_MUL; result.mul_op = MUL_MUL; end
              3'b001: begin result.fu_type = FU_MUL; result.mul_op = MUL_MULH; end
              3'b010: begin result.fu_type = FU_MUL; result.mul_op = MUL_MULHSU; end
              3'b011: begin result.fu_type = FU_MUL; result.mul_op = MUL_MULHU; end
              3'b100: begin result.fu_type = FU_DIV; result.div_op = DIV_DIV; end
              3'b101: begin result.fu_type = FU_DIV; result.div_op = DIV_DIVU; end
              3'b110: begin result.fu_type = FU_DIV; result.div_op = DIV_REM; end
              3'b111: begin result.fu_type = FU_DIV; result.div_op = DIV_REMU; end
              default: legal = 1'b0;
            endcase
          end else begin
            // RV32I 寄存器运算指令组
            result.fu_type = FU_INT;
            case ({funct7, funct3})
              {7'b0000000, 3'b000}: result.alu_op = ALU_ADD;
              {7'b0100000, 3'b000}: result.alu_op = ALU_SUB;
              {7'b0000000, 3'b001}: result.alu_op = ALU_SLL;
              {7'b0000000, 3'b010}: result.alu_op = ALU_SLT;
              {7'b0000000, 3'b011}: result.alu_op = ALU_SLTU;
              {7'b0000000, 3'b100}: result.alu_op = ALU_XOR;
              {7'b0000000, 3'b101}: result.alu_op = ALU_SRL;
              {7'b0100000, 3'b101}: result.alu_op = ALU_SRA;
              {7'b0000000, 3'b110}: result.alu_op = ALU_OR;
              {7'b0000000, 3'b111}: result.alu_op = ALU_AND;
              default: legal = 1'b0;
            endcase
          end
        end

        7'b0001111: begin // 访存屏障指令组 (FENCE / FENCE.I)
          if ((funct3 == 3'b000) ||
              ((funct3 == 3'b001) && (slot.inst[31:15] == 0) &&
               (slot.inst[11:7] == 0))) begin
            result.fu_type = FU_CSR;
            result.serializing = 1'b1; // 需流水线独占序列化
            result.is_fence = 1'b1;
          end else begin
            legal = 1'b0;
          end
        end

        7'b1110011: begin // 系统级指令 / CSR 寄存器指令 (SYSTEM / Zicsr)
          if (funct3 == 3'b000) begin
            // 无立即数系统操作 (ECALL/EBREAK/MRET)
            result.fu_type = FU_CSR;
            result.serializing = 1'b1; // 均标记为序列化独占，在 ROB head 串行处理
            case (slot.inst)
              32'h0000_0073: result.is_ecall = 1'b1;
              32'h0010_0073: result.is_ebreak = 1'b1;
              32'h3020_0073: result.is_mret = 1'b1;
              default: legal = 1'b0;
            endcase
          end else begin
            // CSR 寄存器读写指令组 (CSRRW/CSRRS/CSRRC/CSRRWI/CSRRSI/CSRRCI)
            result.fu_type = FU_CSR;
            result.serializing = 1'b1; // CSR 操作指令必须强序列化
            result.write_rd = (result.rd != 0);
            result.csr_addr = slot.inst[31:20]; // 提取 12 位 CSR 地址
            result.csr_zimm = slot.inst[19:15]; // 提取 CSR 5 位立即数操作数
            case (funct3)
              3'b001: begin result.csr_op = CSR_RW;  result.need_rs1 = 1'b1; end
              3'b010: begin result.csr_op = CSR_RS;  result.need_rs1 = 1'b1; end
              3'b011: begin result.csr_op = CSR_RC;  result.need_rs1 = 1'b1; end
              3'b101: result.csr_op = CSR_RWI;
              3'b110: result.csr_op = CSR_RSI;
              3'b111: result.csr_op = CSR_RCI;
              default: legal = 1'b0;
            endcase
          end
        end

        default: legal = 1'b0;
      endcase

      // C. 非法指令收尾：
      // 如果未被上述任何译码分支匹配，标记为非法指令异常 (Illegal Instruction)，
      // 并清空所有可能引起副作用的控制信号 (如写入 rd、访存、跳转等信号)。
      if (!legal) begin
        result.need_rs1 = 1'b0;
        result.need_rs2 = 1'b0;
        result.write_rd = 1'b0;
        result.fu_type = FU_NONE;
        result.serializing = 1'b0;
        result.is_ecall = 1'b0;
        result.is_ebreak = 1'b0;
        result.is_mret = 1'b0;
        result.is_fence = 1'b0;
        result.exception_valid = 1'b1;
        result.exception_cause = EXC_ILLEGAL_INSTRUCTION;
        result.exception_tval = slot.inst;
      end
    end

    return result;
  endfunction

endpackage
