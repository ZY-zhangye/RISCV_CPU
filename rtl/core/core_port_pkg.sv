`include "defines.svh"

// =============================================================================
// Core 流水线公共端口包
//
// 本 package 只保存跨模块共享的枚举和 packed 数据包定义。每一段流水线
// 使用独立的 slot/bundle 类型，避免后续新增字段时误改其他级间接口。
// =============================================================================
package core_port_pkg;

    localparam int ARCH_REG_COUNT     = 32;
    localparam int PHYS_REG_COUNT     = 64;
    localparam int ARCH_REG_IDX_WIDTH = $clog2(ARCH_REG_COUNT);
    localparam int PHYS_REG_IDX_WIDTH = $clog2(PHYS_REG_COUNT);
    localparam int RENAME_WIDTH       = 2;
    localparam int COMMIT_WIDTH       = 2;
    localparam int WRITEBACK_WIDTH    = 2;

    typedef logic [ARCH_REG_IDX_WIDTH-1:0] arch_reg_idx_t;
    typedef logic [PHYS_REG_IDX_WIDTH-1:0] phys_reg_idx_t;

    typedef enum logic [2:0] {
        FU_NONE = 3'd0,
        FU_ALU  = 3'd1,
        FU_LSU  = 3'd2,
        FU_BRU  = 3'd3,
        FU_CSR  = 3'd4,
        FU_SYS  = 3'd5
    } fu_type_e;

    typedef enum logic [3:0] {
        ALU_ADD  = 4'd0,
        ALU_SUB  = 4'd1,
        ALU_SLL  = 4'd2,
        ALU_SLT  = 4'd3,
        ALU_SLTU = 4'd4,
        ALU_XOR  = 4'd5,
        ALU_SRL  = 4'd6,
        ALU_SRA  = 4'd7,
        ALU_OR   = 4'd8,
        ALU_AND  = 4'd9
    } alu_op_e;

    typedef enum logic [2:0] {
        BR_NONE = 3'd0,
        BR_BEQ  = 3'd1,
        BR_BNE  = 3'd2,
        BR_BLT  = 3'd3,
        BR_BGE  = 3'd4,
        BR_BLTU = 3'd5,
        BR_BGEU = 3'd6,
        BR_JUMP = 3'd7
    } branch_op_e;

    typedef enum logic [2:0] {
        MEM_NONE   = 3'd0,
        MEM_BYTE   = 3'd1,
        MEM_HALF   = 3'd2,
        MEM_WORD   = 3'd3,
        MEM_BYTE_U = 3'd4,
        MEM_HALF_U = 3'd5
    } mem_op_e;

    typedef enum logic [1:0] {
        CSR_NONE  = 2'd0,
        CSR_WRITE = 2'd1,
        CSR_SET   = 2'd2,
        CSR_CLEAR = 2'd3
    } csr_op_e;

    // -------------------------------------------------------------------------
    // 全核统一恢复事件
    // 分支误预测、同步异常和外部中断共享该信道。
    // -------------------------------------------------------------------------
    typedef enum logic [1:0] {
        RECOVER_NONE      = 2'd0,
        RECOVER_BRANCH    = 2'd1,
        RECOVER_EXCEPTION = 2'd2,
        RECOVER_INTERRUPT = 2'd3
    } recover_reason_e;

    typedef struct packed {
        logic                   valid;
        recover_reason_e        reason;
        logic [`ADDR_WIDTH-1:0] target;
    } recover_event_t;

    // -------------------------------------------------------------------------
    // IF -> ID
    // -------------------------------------------------------------------------
    typedef struct packed {
        logic [`INST_WIDTH-1:0] inst;
        logic [`ADDR_WIDTH-1:0] pc;
        logic                   pred_taken;
        logic [`ADDR_WIDTH-1:0] pred_target;
    } fs_ds_slot_t;

    typedef struct packed {
        fs_ds_slot_t lane1;
        fs_ds_slot_t lane0;
    } fs_ds_bundle_t;

    // -------------------------------------------------------------------------
    // ID -> Rename
    // 这里只描述架构寄存器和指令控制信息；物理寄存器标签由 Rename 添加。
    // -------------------------------------------------------------------------
    typedef struct packed {
        logic                   valid;
        logic                   flush;
        logic [`ADDR_WIDTH-1:0] pc;
        logic [`INST_WIDTH-1:0] inst;
        logic                   pred_taken;
        logic [`ADDR_WIDTH-1:0] pred_target;

        logic [4:0]             rs1;
        logic [4:0]             rs2;
        logic [4:0]             rd;
        logic                   use_rs1;
        logic                   use_rs2;
        logic                   rd_wen;

        logic [`ADDR_WIDTH-1:0] imm;
        logic                   src1_is_pc;
        logic                   src2_is_imm;

        fu_type_e               fu_type;
        alu_op_e                alu_op;
        logic                   alu_ext;
        branch_op_e             branch_op;
        mem_op_e                mem_op;
        logic                   mem_write;

        csr_op_e                csr_op;
        logic                   csr_use_imm;
        logic [11:0]            csr_addr;

        logic                   illegal;
        logic [`EXC_CODE_WIDTH-1:0] exc_code;
        logic [`ADDR_WIDTH-1:0] exc_tval;
    } ds_rn_slot_t;

    typedef struct packed {
        ds_rn_slot_t lane1;
        ds_rn_slot_t lane0;
    } ds_rn_bundle_t;

    // -------------------------------------------------------------------------
    // Rename -> Dispatch
    // -------------------------------------------------------------------------
    typedef struct packed {
        ds_rn_slot_t  dec;
        phys_reg_idx_t prs1;
        phys_reg_idx_t prs2;
        phys_reg_idx_t pdst;
        phys_reg_idx_t stale_pdst;
        logic          src1_ready;
        logic          src2_ready;
        logic          pdst_valid;
    } rn_dp_slot_t;

    typedef struct packed {
        rn_dp_slot_t lane1;
        rn_dp_slot_t lane0;
    } rn_dp_bundle_t;

    // -------------------------------------------------------------------------
    // Rename 状态模块控制包
    // -------------------------------------------------------------------------
    typedef struct packed {
        logic          use_rs1;
        logic          use_rs2;
        arch_reg_idx_t rs1;
        arch_reg_idx_t rs2;
        arch_reg_idx_t rd;
        logic          pdst_valid;
        phys_reg_idx_t pdst;
    } rat_rename_req_t;

    typedef struct packed {
        rat_rename_req_t lane1;
        rat_rename_req_t lane0;
    } rat_rename_req_bundle_t;

    typedef struct packed {
        phys_reg_idx_t prs1;
        phys_reg_idx_t prs2;
        phys_reg_idx_t stale_pdst;
    } rat_rename_rsp_t;

    typedef struct packed {
        rat_rename_rsp_t lane1;
        rat_rename_rsp_t lane0;
    } rat_rename_rsp_bundle_t;

    typedef struct packed {
        logic          valid;
        arch_reg_idx_t rd;
        phys_reg_idx_t pdst;
        phys_reg_idx_t stale_pdst;
    } commit_map_update_t;

    typedef struct packed {
        commit_map_update_t lane1;
        commit_map_update_t lane0;
    } commit_map_bundle_t;

    typedef struct packed {
        logic          valid;
        phys_reg_idx_t preg;
    } phys_reg_event_t;

    typedef struct packed {
        phys_reg_event_t lane1;
        phys_reg_event_t lane0;
    } phys_reg_event_bundle_t;

    typedef struct packed {
        logic          use_src1;
        logic          use_src2;
        phys_reg_idx_t prs1;
        phys_reg_idx_t prs2;
    } busy_query_t;

    typedef struct packed {
        busy_query_t lane1;
        busy_query_t lane0;
    } busy_query_bundle_t;

    typedef struct packed {
        logic src1_ready;
        logic src2_ready;
    } busy_ready_t;

    typedef struct packed {
        busy_ready_t lane1;
        busy_ready_t lane0;
    } busy_ready_bundle_t;

    typedef struct packed {
        phys_reg_idx_t lane1;
        phys_reg_idx_t lane0;
    } phys_reg_pair_t;

    localparam int FS_DS_SLOT_WIDTH = $bits(fs_ds_slot_t);
    localparam int FS_DS_WIDTH      = $bits(fs_ds_bundle_t);
    localparam int DS_RN_SLOT_WIDTH = $bits(ds_rn_slot_t);
    localparam int DS_RN_WIDTH      = $bits(ds_rn_bundle_t);
    localparam int RN_DP_SLOT_WIDTH = $bits(rn_dp_slot_t);
    localparam int RN_DP_WIDTH      = $bits(rn_dp_bundle_t);

endpackage
