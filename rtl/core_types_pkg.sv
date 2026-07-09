`timescale 1ns/1ps

// core_types_pkg.sv
// 公共参数、类型定义 — V1 设计基线
// 所有 RTL 模块通过 import core_types_pkg::* 使用

package core_types_pkg;

  // ==========================================================================
  // 架构参数
  // ==========================================================================
  localparam int XLEN          = 32;   // 数据/地址字宽 (32位 RISC-V)
  localparam int ARCH_REGS     = 32;   // 架构寄存器数量 (x0–x31)
  localparam int PHYS_REGS     = 64;   // 物理寄存器数量 (用于寄存器重命名重映射，p0–p63)
  localparam int ROB_ENTRIES   = 32;   // 重排序缓冲 (ROB) 的容量，限制在途指令数
  localparam int LQ_ENTRIES    = 8;    // Load 队列的条目数
  localparam int SQ_ENTRIES    = 8;    // Store 队列的条目数
  localparam int IQ_INT_ENTRIES = 12;  // 整型发射队列 (Issue Queue) 条目数
  localparam int IQ_MEM_ENTRIES = 8;   // 访存发射队列条目数
  localparam int IQ_MDU_ENTRIES = 4;   // 乘除法发射队列条目数
  localparam int CHECKPOINTS   = 4;    // Speculative 分支检查点最大数量 (支持 4 个分支同时 speculative)
  localparam int FETCH_ID_W    = 8;    // 取指事务编号位宽 (Fetch Transaction ID)
  localparam int IBUF_ENTRIES  = 8;    // 指令缓冲 (Instruction Buffer) 的条目容量
  localparam int BTB_ENTRIES   = 128;  // 分支目标缓冲 (Branch Target Buffer) 的条目数
  localparam int BHT_ENTRIES   = 512;  // 分支历史表 (Branch History Table) 的条目数
  localparam int RESET_PC      = 32'h8000_0000; // 系统复位后的起始 PC

  // ==========================================================================
  // 索引与标识位宽计算
  // ==========================================================================
  localparam int PRD_W     = $clog2(PHYS_REGS);     // 物理寄存器索引位宽 (6位)
  localparam int ROB_ID_W  = $clog2(ROB_ENTRIES);    // ROB 条目索引位宽 (5位)
  localparam int LQ_ID_W   = $clog2(LQ_ENTRIES);     // Load 队列索引位宽 (3位)
  localparam int SQ_ID_W   = $clog2(SQ_ENTRIES);     // Store 队列索引位宽 (3位)
  localparam int CP_W      = $clog2(CHECKPOINTS);    // 分支检查点索引位宽 (2位)
  localparam int FETCH_ID_W_FULL = FETCH_ID_W;

  // ==========================================================================
  // 执行单元类型与操作码 (FU & Opcode)
  // ==========================================================================
  // 执行单元 (Functional Unit) 类型枚举
  typedef enum logic [2:0] {
    FU_NONE   = 3'd0,
    FU_INT    = 3'd1,   // 整型运算单元 INT0 或 INT1
    FU_BRANCH = 3'd2,   // 分支处理单元 (通常复用 INT1)
    FU_LSU    = 3'd3,   // 访存单元 Load/Store Unit
    FU_MUL    = 3'd4,   // 乘法执行单元
    FU_DIV    = 3'd5,   // 除法执行单元
    FU_CSR    = 3'd6    // CSR 寄存器读写单元
  } fu_t;

  // Registered issue-slot destination selected by the global issue arbiter.
  typedef enum logic [1:0] {
    ISSUE_INT0 = 2'd0,
    ISSUE_INT1 = 2'd1,
    ISSUE_LSU  = 2'd2,
    ISSUE_MDU  = 2'd3
  } issue_port_t;

  // ALU 操作码枚举
  typedef enum logic [3:0] {
    ALU_ADD,  ALU_SUB,  ALU_SLL,  ALU_SRL,
    ALU_SRA,  ALU_AND,  ALU_OR,   ALU_XOR,
    ALU_SLT,  ALU_SLTU, ALU_LUI,  ALU_AUIPC,
    ALU_PASS1 // 直接传递第一个操作数 (如 JALR 计算基准地址时使用)
  } alu_op_t;

  // 分支/跳转操作码枚举
  typedef enum logic [2:0] {
    BR_EQ,  BR_NE,  BR_LT,  BR_GE,
    BR_LTU, BR_GEU, BR_JAL, BR_JALR
  } branch_op_t;

  // 访存操作码枚举 (低位包含大小与符号，高位区分 Load/Store)
  typedef enum logic [2:0] {
    MEM_LB, MEM_LH, MEM_LW,
    MEM_LBU, MEM_LHU, MEM_SB,
    MEM_SH, MEM_SW
  } mem_op_t; // 实际编码结构为 {load=0/store=1, size[1:0], unsigned}

  // 乘法操作码
  typedef enum logic [1:0] {
    MUL_MUL, MUL_MULH, MUL_MULHSU, MUL_MULHU
  } mul_op_t;

  // 除法/求余操作码
  typedef enum logic [2:0] {
    DIV_DIV, DIV_DIVU, DIV_REM, DIV_REMU
  } div_op_t;

  // CSR 操作类型枚举
  typedef enum logic [2:0] {
    CSR_RW, CSR_RS, CSR_RC, CSR_RWI, CSR_RSI, CSR_RCI
  } csr_op_t;

  // ==========================================================================
  // 写回与仲裁 (Producer Identification)
  // ==========================================================================
  // 标志具体的数据产生源，用于物理寄存器堆 (PRF) 的写回端口仲裁
  typedef enum logic [2:0] {
    PROD_INT0   = 3'd0, // ALU 0 产生的写回数据
    PROD_INT1   = 3'd1, // ALU 1 / Branch 产生的写回数据
    PROD_LSU    = 3'd2, // 访存单元读出的写回数据
    PROD_MUL    = 3'd3, // 乘法器计算完毕的数据
    PROD_DIV    = 3'd4  // 除法器计算完毕的数据
  } producer_t;

  // ==========================================================================
  // 分支预测器接口数据结构
  // ==========================================================================
  // F0 阶段向分支预测器 (BP) 发起查询的请求包
  typedef struct packed {
    logic [31:0] pc;             // 本次查询的对齐基址 PC
    logic [FETCH_ID_W_FULL-1:0] fetch_id; // 对应的取指事务 ID
  } bp_query_t;

  // 分支预测器在 F1 阶段返回给取指流水线的预测结果束
  typedef struct packed {
    logic        valid;         // 预测结果是否有效 (BTB 是否命中)
    logic [ 3:0] btb_hit;       // 16字节块中，4个指令槽对应的 BTB 命中指示
    logic [31:0] btb_target;    // 预测的跳转目标 PC
    logic [ 1:0] btb_slot;      // BTB 中记录的最早发生跳转的分支指令槽编号 (0~3)
    logic [ 3:0] bht_taken;     // 4个指令槽对应的 BHT 方向预测 (1: Taken, 0: Not-Taken)
  } bp_pred_t;

  // 执行阶段向分支预测器发送的实际解析结果更新包
  typedef struct packed {
    logic [31:0] pc;            // 该分支指令的 PC
    logic [31:0] target;        // 该分支指令的实际跳转目标地址
    logic        taken;         // 该分支实际是否跳转 (1: Taken, 0: Not-Taken)
    logic        is_branch;     // 是否是条件分支指令
    logic        is_jal;        // 是否是 JAL 指令
    logic        is_jalr;       // 是否是 JALR 指令
  } branch_update_t;

  // 执行端分支解析事件。该事件只描述分支本身的实际结果，不直接驱动前端、
  // RAT、ROB 或 IQ；后续 recovery_controller 负责按优先级广播恢复。
  typedef struct packed {
    logic                 valid;         // 分支解析事件有效
    logic [ROB_ID_W-1:0]  rob_id;        // 对应 ROB ID
    logic [CP_W-1:0]      checkpoint_id; // 分支自身 checkpoint
    logic                 actual_taken;  // 实际方向
    logic [31:0]          actual_target; // 实际目标；not-taken 时为顺序 PC
    logic                 mispredict;    // 方向错误，或 taken 目标错误
    logic [31:0]          redirect_pc;   // 恢复时应跳转到的正确 PC
    branch_update_t       update;        // 写回分支预测器的更新信息
  } branch_resolve_t;

  // ==========================================================================
  // 取指包与槽定义 (Fetch Packet & Slots)
  // ==========================================================================
  // 取指包中单条指令的元数据槽位
  typedef struct packed {
    logic [31:0] pc;             // 该条指令的精确 PC
    logic [31:0] inst;           // 32位指令内容
    logic        pred_taken;     // 该指令是否被预测为跳转 (Speculative Direction)
    logic [31:0] pred_target;    // 该指令预测的跳转目标 PC
    logic [FETCH_ID_W_FULL-1:0] fetch_id; // 对应的取指事务 ID
    logic        exception_valid;// 是否携带取指异常 (如指令不对齐)
    logic [ 3:0] exception_cause;// 异常原因编码
    logic [31:0] exception_tval; // 精确的取指异常地址
  } fetch_slot_t;

  // F2 阶段向指令缓冲 (Instruction Buffer) 输出的完整 4 路取指包
  typedef struct packed {
    logic [31:0]                block_pc;      // 16字节对齐的取指块基 PC
    logic [3:0][31:0]           inst;          // 一次读取的 4 条指令
    logic [ 3:0]                slot_valid;    // 指示 4 条指令中哪些槽位是有效的 (受起始 PC 偏置与跳转截断影响)
    logic                       pred_taken;    // 整个取指块是否发生了跳转预测
    logic [ 1:0]                pred_slot;     // 块中发生跳转预测的最早槽位号
    logic [31:0]                pred_target;   // 预测的跳转目标 PC
    logic [FETCH_ID_W_FULL-1:0] fetch_id;      // 对应的取指事务 ID
    logic                       exception_valid;// 整个块是否触发了取指异常
    logic [ 3:0]                exception_cause;// 取指异常类型原因
    logic [31:0]                exception_tval; // 异常的附加信息 (触发异常的地址 PC)
  } fetch_packet_t;

  // ==========================================================================
  // 译码微操作 (Decode Stage Micro-op)
  // ==========================================================================
  // 译码阶段输出给重命名阶段 (Rename Stage) 的单条微操作结构
  typedef struct packed {
    logic [31:0] pc;             // 指令 PC
    logic [31:0] inst;           // 原始指令字

    // 架构寄存器字段
    logic [ 4:0] rs1;            // 源寄存器 1 索引
    logic [ 4:0] rs2;            // 源寄存器 2 索引
    logic [ 4:0] rd;             // 目的寄存器索引
    logic        need_rs1;       // 该指令是否需要读取 rs1
    logic        need_rs2;       // 该指令是否需要读取 rs2
    logic        write_rd;       // 该指令是否需要写入 rd (rd != x0)

    logic [31:0] imm;            // 符号扩展后的立即数

    // 功能单元和操作码选择
    fu_t         fu_type;        // 路由的目标执行单元类型
    alu_op_t     alu_op;         // ALU 操作类型选择
    branch_op_t  branch_op;      // 分支操作指令选择
    mem_op_t     mem_op;         // 访存操作指令选择
    mul_op_t     mul_op;         // 乘法指令选择
    div_op_t     div_op;         // 除法指令选择
    csr_op_t     csr_op;         // CSR 指令选择
    logic [11:0] csr_addr;       // CSR 编号
    logic [ 4:0] csr_zimm;       // CSR 立即数操作数

    // 特殊控制指令标记
    logic        serializing;   // 序列化标志 (如 CSR, MRET 等，需清空流水线或单发)
    logic        is_ecall;      // 环境调用指令
    logic        is_ebreak;     // 断点指令
    logic        is_mret;       // 机器模式返回指令
    logic        is_fence;      // 访存屏障指令

    // 预测元数据 (透传自 Fetch 阶段，用于执行端做误预测校验)
    logic        pred_taken;     // 预测方向
    logic [31:0] pred_target;    // 预测目标 PC
    logic [FETCH_ID_W_FULL-1:0] fetch_id; // 取指事务 ID

    // 译码阶段检测到的异常 (如非法指令)
    logic        exception_valid;
    logic [ 3:0] exception_cause;
    logic [31:0] exception_tval;
  } decoded_uop_t;

  // ==========================================================================
  // 重命名微操作 (Rename Stage Micro-op)
  // ==========================================================================
  // 重命名阶段分配了物理寄存器、ROB ID 和分支检查点后，送往发射队列 (IQ) 的结构
  typedef struct packed {
    // 基础译码信息
    decoded_uop_t dec;

    // 映射后的物理寄存器
    logic [PRD_W-1:0]    prs1;          // 重命名映射后的源物理寄存器 1 (p0–p63)
    logic [PRD_W-1:0]    prs2;          // 重命名映射后的源物理寄存器 2 (p0–p63)
    logic [PRD_W-1:0]    prd;           // 重命名分配的当前目的物理寄存器
    logic [PRD_W-1:0]    old_prd;       // 目的寄存器之前映射的旧物理寄存器 (Retire 时释放用)

    // 分配的核心资源 ID
    logic [ROB_ID_W-1:0] rob_id;        // 分配的 ROB 条目号
    logic [LQ_ID_W-1:0]  lq_id;         // 分配的 Load Queue 索引
    logic [SQ_ID_W-1:0]  sq_id;         // 分配的 Store Queue 索引

    // 投机掩码与检查点
    logic [CHECKPOINTS-1:0] branch_mask;   // 分支嵌套掩码 (记录在哪些 speculative 分支下执行)
    logic [CP_W-1:0]        checkpoint_id; // 若自身为分支指令，所分配的备份点 ID (用于快速恢复)

    // 物理寄存器状态就绪标志 (寄存器堆或旁路网络是否已产生该值)
    logic        src1_ready;    // 源操作数 1 是否已就绪
    logic        src2_ready;    // 源操作数 2 是否已就绪
  } renamed_uop_t;

  // ==========================================================================
  // 发射队列条目 (Issue Queue Entry)
  // ==========================================================================
  // 暂存在发射队列中等待操作数就绪的指令条目格式
  typedef struct packed {
    // 核心执行信息
    logic [PRD_W-1:0] prd;              // 目的物理寄存器
    logic [PRD_W-1:0] prs1;             // 源物理寄存器 1
    logic [PRD_W-1:0] prs2;             // 源物理寄存器 2
    logic             src1_ready;       // 源操作数 1 就绪状态 (1: 已就绪，可发射)
    logic             src2_ready;       // 源操作数 2 就绪状态 (1: 已就绪，可发射)
    logic [31:0]      imm;              // 立即数
    logic [31:0]      pc;               // 指令 PC
    logic             pred_taken;       // 前端预测方向
    logic [31:0]      pred_target;      // 前端预测目标

    // 执行功能具体指令
    fu_t              fu_type;
    alu_op_t          alu_op;
    branch_op_t       branch_op;
    mem_op_t          mem_op;
    mul_op_t          mul_op;
    div_op_t          div_op;
    csr_op_t          csr_op;
    logic [11:0]      csr_addr;
    logic [ 4:0]      csr_zimm;

    // 路由及回收 ID
    logic [ROB_ID_W-1:0] rob_id;        // 对应的 ROB 追踪 ID
    logic [PRD_W-1:0]    old_prd;       // 旧物理寄存器索引 (提交时用于释放)

    // 访存通道 ID
    logic [LQ_ID_W-1:0]  lq_id;
    logic [SQ_ID_W-1:0]  sq_id;
    logic [CP_W-1:0]     checkpoint_id; // 分支自身恢复检查点

    // 控制及掩码
    logic [CHECKPOINTS-1:0] branch_mask; // 投机分支掩码，用于在发生误预测时被快速 flush
    logic                    write_rd;    // 是否写寄存器堆
    logic                    is_load;     // 是否是加载指令
    logic                    is_store;    // 是否是存储指令
    logic                    serializing; // 是否为序列化独占指令

    // 发射时补充信息 (辅助发射决策)
    logic                    need_rs1;
    logic                    need_rs2;
  } issue_uop_t;

  // ==========================================================================
  // 执行操作数包 (Register Read to Execution Stage Interface)
  // ==========================================================================
  // 寄存器读取 (Register Read) 完毕后，发送给各具体执行单元的数据载荷
  typedef struct packed {
    logic        valid;                 // 操作数是否有效
    logic [ROB_ID_W-1:0] rob_id;        // 关联 of ROB 编号
    logic [PRD_W-1:0]    prd;           // 目标物理寄存器索引
    logic [31:0]          src1;         // 从 PRF 读出或旁路前传得到的 rs1 实际值
    logic [31:0]          src2;         // 从 PRF 读出或旁路前传得到的 rs2 实际值
    logic [31:0]          imm;          // 立即数值
    logic [31:0]          pc;           // 本指令 PC (分支单元计算 PC+imm 使用)
    logic                 pred_taken;   // 前端预测方向
    logic [31:0]          pred_target;  // 前端预测目标
    logic [CP_W-1:0]      checkpoint_id;// 分支自身恢复检查点

    fu_t                  fu_type;      // 执行单元类型
    alu_op_t              alu_op;
    branch_op_t           branch_op;
    mem_op_t              mem_op;
    mul_op_t              mul_op;
    div_op_t              div_op;
    csr_op_t              csr_op;
    logic [11:0]          csr_addr;
    logic [ 4:0]          csr_zimm;

    logic [CHECKPOINTS-1:0] branch_mask; // 分支掩码
    logic                   write_rd;    // 是否写回目的寄存器
    logic                   is_load;
    logic                   is_store;
    logic [LQ_ID_W-1:0]     lq_id;
    logic [SQ_ID_W-1:0]     sq_id;
    logic [31:0]            store_data;  // Store 指令待写入的实际数据

    logic                   serializing; // 序列化标志
    logic                   need_rs1;    // 执行端操作数 1 是否来自源寄存器
    logic                   need_rs2;    // 执行端操作数 2 是否来自源寄存器
  } execute_uop_t;

  // ==========================================================================
  // 写回完成总线结构 (Completion Writeback Bus)
  // ==========================================================================
  // 执行单元运行完毕后，输出给 ROB 进行状态更新以及 PRF 进行写回的数据包
  typedef struct packed {
    logic        valid;                 // 写回是否有效
    logic [PRD_W-1:0]    prd;           // 写入的目的物理寄存器
    logic [ROB_ID_W-1:0] rob_id;        // 关联的 ROB ID
    logic [31:0]          data;         // 运算结果数据

    logic        exception_valid;       // 运行期是否触发异常 (如零除、访存不对齐等)
    logic [ 3:0] exception_cause;       // 异常码
    logic [31:0] exception_tval;        // 异常附加值

    producer_t   producer;              // 产生该结果的数据源，用作仲裁分流
    logic        write_prf;             // 是否真正写入物理寄存器堆 (Store 或异常时为 0)
    logic        is_store;              // 标识此为 Store 确认包 (只更新 ROB，不写物理寄存器)
    logic [CHECKPOINTS-1:0] branch_mask; // 结果对应指令所在的投机分支掩码
  } completion_t;

  // ==========================================================================
  // Store Queue 与已提交 Store Memory Request
  // ==========================================================================
  typedef struct packed {
    logic                       valid;
    logic [ROB_ID_W-1:0]        rob_id;
    logic                       address_valid;
    logic [XLEN-1:0]            address;
    logic                       data_valid;
    logic [XLEN-1:0]            data;
    logic [3:0]                 byte_enable;
    logic                       exception_valid;
    logic [3:0]                 exception_cause;
    logic [XLEN-1:0]            exception_tval;
    logic [CHECKPOINTS-1:0]     branch_mask;
  } store_queue_entry_t;

  typedef struct packed {
    logic                       valid;
    logic [ROB_ID_W-1:0]        rob_id;
    logic [PRD_W-1:0]           prd;
    mem_op_t                    mem_op;
    logic                       address_valid;
    logic [XLEN-1:0]            address;
    logic                       completed;
    logic                       forwarded;
    logic                       exception_valid;
    logic [3:0]                 exception_cause;
    logic [XLEN-1:0]            exception_tval;
    logic [CHECKPOINTS-1:0]     branch_mask;
  } load_queue_entry_t;

  typedef struct packed {
    logic                       valid;
    logic [SQ_ID_W-1:0]         sq_id;
    logic [XLEN-1:0]            address;
    logic [XLEN-1:0]            data;
    logic [3:0]                 byte_enable;
  } store_mem_req_t;

  typedef struct packed {
    logic                       valid;
    logic [LQ_ID_W-1:0]         lq_id;
    logic [XLEN-1:0]            address;
  } load_mem_req_t;

  typedef struct packed {
    logic                       valid;
    logic [LQ_ID_W-1:0]         lq_id;
    logic [XLEN-1:0]            data;
  } load_mem_resp_t;

  // ==========================================================================
  // 重排序缓冲条目 (Reorder Buffer Fields)
  // ==========================================================================
  // 1. 重命名阶段分配 ROB 时写入的控制配置结构
  typedef struct packed {
    logic [ 4:0] arch_rd;               // 目的架构寄存器 (x0-x31)
    logic [PRD_W-1:0] new_prd;           // 新分配的目的物理寄存器 (p0-p63)
    logic [PRD_W-1:0] old_prd;           // 被覆盖的旧物理寄存器 (Retire 时回收)
    logic        write_rd;              // 是否需要写入寄存器

    logic        is_load;               // 是否为 Load 指令
    logic [LQ_ID_W-1:0] lq_id;          // 对应的 Load 队列索引 (用于 Retire 释放)
    logic        is_store;              // 是否为 Store 指令
    logic [SQ_ID_W-1:0] sq_id;          // 对应的 Store 队列索引 (用于 Commit 阶段触发 Cache 真正写入)
    logic        is_branch;             // 是否为分支跳转指令
    logic [CP_W-1:0] checkpoint_id;     // 关联的分支检查点 ID
    logic [CHECKPOINTS-1:0] branch_mask; // 指令所处的投机分支掩码
    logic        serializing;           // 流水线串行化控制标志

    logic        is_csr;                // 真正的 Zicsr 读改写指令
    csr_op_t     csr_op;
    logic [11:0] csr_addr;
    logic [ 4:0] csr_zimm;
    logic [31:0] csr_operand;           // 执行准备阶段捕获的 rs1 值
    logic        is_ecall;
    logic        is_ebreak;
    logic        is_mret;
    logic        is_fence;
    logic [31:0] inst;

    logic        exception_valid;       // 重命名或译码阶段发现的异常
    logic [ 3:0] exception_cause;
    logic [31:0] exception_tval;

    logic [31:0] pc;                    // 指令 PC
  } rob_alloc_t;

  // 2. ROB 提交阶段观察到的完整条目状态
  typedef struct packed {
    logic        valid;                 // 该条目是否已分配且有效
    logic        complete;              // 执行单元是否已写回完成 (准备好 Commit)
    rob_alloc_t  entry;                 // 分配时的初始控制信息
  } rob_entry_t;

  // ==========================================================================
  // 重命名与外部模块分配接口 (Allocation Request & Response)
  // ==========================================================================
  typedef struct packed {
    logic                   valid;
    logic [4:0]             arch_rd;
    logic [PRD_W-1:0]       prd;
  } commit_map_t;

  // 重命名阶段向物理寄存器 Free List、ROB、LSQ 请求分配资源的信号包
  typedef struct packed {
    logic          valid;
    logic [1:0]    lane_valid;     // 前缀有效：01/11
    logic [1:0]    need_prd;
    logic [1:0]    need_lq;
    logic [1:0]    need_sq;
    logic [1:0]    need_checkpoint;
  } alloc_req_t;

  // 资源分配响应包 (寄存后在 Rename 阶段使用)
  typedef struct packed {
    logic                 valid;         // 资源分配响应有效
    logic [1:0]           lane_valid;    // 可原子授予的前缀 lane
    logic [1:0][PRD_W-1:0]    prd;       // 分配的物理寄存器
    logic [1:0][ROB_ID_W-1:0] rob_id;    // 分配的 ROB ID
    logic [1:0][LQ_ID_W-1:0]  lq_id;     // 分配的 LQ ID
    logic [1:0][SQ_ID_W-1:0]  sq_id;     // 分配的 SQ ID
    logic [CP_W-1:0]      checkpoint_id; // 分配的分支恢复点
    logic                 bank_same;     // 物理寄存器访问冲突性能指示
  } alloc_resp_t;

  // ==========================================================================
  // 流水线恢复与重定向控制 (Speculative Recovery Control)
  // ==========================================================================
  // 流水线恢复触发原因类型枚举
  typedef enum logic [1:0] {
    REC_NONE    = 2'd0, // 无需恢复
    REC_BRANCH  = 2'd1, // 分支预测错误 (Speculative Misprediction)
    REC_EXCEPT  = 2'd2  // 异常触发、中断发生或 MRET 退出 (精确异常恢复)
  } recovery_cause_t;

  // 恢复控制指令总线结构 (执行端/提交端 -> 全局)
  typedef struct packed {
    logic                 valid;         // 恢复动作请求有效
    recovery_cause_t      cause;         // 恢复原因
    logic [CP_W-1:0]      checkpoint_id; // 若为分支恢复，对应的检查点 ID (用于回滚 RAT)
    logic [31:0]          redirect_pc;   // 重定向的正确指令流 PC 目标
  } recovery_t;

endpackage
