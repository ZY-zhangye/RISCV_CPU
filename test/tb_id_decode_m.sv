`timescale 1ns/1ps
`include "defines.svh"

module tb_id_decode_m;
    import core_port_pkg::*;
    import id_decode_pkg::*;

    fs_ds_slot_t slot;
    ds_rn_slot_t decoded;

    function automatic logic [31:0] encode_m(
        input logic [2:0] funct3
    );
        encode_m = {7'b0000001, 5'd7, 5'd6, funct3, 5'd5, 7'b0110011};
    endfunction

    task automatic check_m(
        input logic [2:0] funct3,
        input mlu_op_e   expected_op
    );
        begin
            slot      = '0;
            slot.inst = encode_m(funct3);
            slot.pc   = 32'h0000_1000;
            decoded   = decode_instruction(slot, `EXC_NONE, '0);

            assert (decoded.valid && !decoded.illegal)
                else $fatal(1, "M decode marked invalid/illegal, funct3=%0d", funct3);
            assert (decoded.fu_type == FU_MLU && decoded.mlu_op == expected_op)
                else $fatal(1, "M decode mismatch, funct3=%0d fu=%0d op=%0d",
                            funct3, decoded.fu_type, decoded.mlu_op);
            assert (decoded.use_rs1 && decoded.use_rs2 && decoded.rd_wen)
                else $fatal(1, "M operand controls mismatch, funct3=%0d", funct3);
            assert ((decoded.rs1 == 5'd6) && (decoded.rs2 == 5'd7)
                    && (decoded.rd == 5'd5))
                else $fatal(1, "M register fields mismatch, funct3=%0d", funct3);
        end
    endtask

    initial begin
        check_m(3'b000, MLU_MUL);
        check_m(3'b001, MLU_MULH);
        check_m(3'b010, MLU_MULHSU);
        check_m(3'b011, MLU_MULHU);
        check_m(3'b100, MLU_DIV);
        check_m(3'b101, MLU_DIVU);
        check_m(3'b110, MLU_REM);
        check_m(3'b111, MLU_REMU);

        // 确认原有 RV32I OP 译码没有被 M 扩展分支覆盖。
        slot      = '0;
        slot.inst = {7'b0000000, 5'd7, 5'd6, 3'b000, 5'd5, 7'b0110011};
        decoded   = decode_instruction(slot, `EXC_NONE, '0);
        assert ((decoded.fu_type == FU_ALU) && (decoded.alu_op == ALU_ADD)
                && (decoded.mlu_op == MLU_NONE) && !decoded.illegal)
            else $fatal(1, "RV32I ADD decode regressed after M extension");

        $display("PASS: RV32M decode extension");
        $finish;
    end

endmodule
