`ifndef _DEFINES_SVH__
`define _DEFINES_SVH__

// -----------------------------------------------------------------------------
// 全局宽度
// -----------------------------------------------------------------------------
`define ADDR_WIDTH              32
`define INST_WIDTH              32
`define DATA_WIDTH              64

// RV32I 的 ADDI x0, x0, 0。无效取指槽统一用该指令填充。
`define NOP_INST                32'h0000_0013
`define RISCV_NOP               `NOP_INST
`define PC_START                32'h0000_0000
`define RESET_VECTOR            `PC_START

// -----------------------------------------------------------------------------
// IF -> ID 总线
// 每个槽携带：PC、指令、该槽的预测跳转标志和预测目标。
// 总线排列：{slot1, slot0}，每个槽内部沿用原工程 IF 级风格：
//           {inst, pc, pred_taken, pred_target}
// -----------------------------------------------------------------------------
`define FS_DS_SLOT_WIDTH        (2 * `ADDR_WIDTH + `INST_WIDTH + 1)
`define FS_DS_WIDTH             (2 * `FS_DS_SLOT_WIDTH)

`define FS_DS_SLOT0_LSB         0
`define FS_DS_SLOT0_MSB         (`FS_DS_SLOT_WIDTH - 1)
`define FS_DS_SLOT1_LSB         `FS_DS_SLOT_WIDTH
`define FS_DS_SLOT1_MSB         (`FS_DS_WIDTH - 1)

// -----------------------------------------------------------------------------
// 分支预测器：64 项直接映射 BTB + 每项一个 2-bit 饱和计数器。
// -----------------------------------------------------------------------------
`define BP_INDEX_WIDTH          6
`define BP_ENTRIES              (1 << `BP_INDEX_WIDTH)
`define BP_TAG_WIDTH            (`ADDR_WIDTH - `BP_INDEX_WIDTH - 2)

// -----------------------------------------------------------------------------
// 取指异常包：{exception_code[6:0], mtval[31:0]}
// -----------------------------------------------------------------------------
`define EXC_CODE_WIDTH          7
`define EXC_WIDTH               (`EXC_CODE_WIDTH + `ADDR_WIDTH)
`define EXC_NONE                7'b000_0000
`define EXC_IAM                 7'b010_0000
`define EXC_ILLEGAL_INST        7'b010_0010
`define EXC_BREAKPOINT          7'b010_0011
`define EXC_ECALL_M             7'b010_1011
`define EXC_MRET                7'b100_0000

// -----------------------------------------------------------------------------
// ID -> Rename 双路译码包宽度
// 与 id_decode_pkg::decode_pkt_t 保持一致。
// -----------------------------------------------------------------------------
`define DS_RN_SLOT_WIDTH        221
`define DS_RN_WIDTH             (2 * `DS_RN_SLOT_WIDTH)

`endif
