`include "defines.svh"

module if_stage (
    input  logic                         clk,
    input  logic                         rst_n,
    // 取指端口：一次读取连续的两条 32-bit 指令
    output logic [`ADDR_WIDTH-1:0]       pc_out,
    output logic                         inst_ren,
    input  logic [`DATA_WIDTH-1:0]       inst_in,
    // 与译码阶段的数据接口
    input  logic                         ds_allowin,
    output logic                         fs_to_ds_valid,
    output logic [`FS_DS_WIDTH-1:0]      fs_to_ds_bus,
    // 分支重定向接口
    input  logic                         br_taken,
    input  logic [`ADDR_WIDTH-1:0]       br_target,
    // 分支预测器更新接口
    input  logic                         bp_update_valid,
    input  logic [`ADDR_WIDTH-1:0]       bp_update_pc,
    input  logic                         bp_update_taken,
    input  logic [`ADDR_WIDTH-1:0]       bp_update_target,
    input  logic                         bp_update_is_jalr,
    // 取指异常包
    output logic [`EXC_WIDTH-1:0]        fs_exc_bus,
    // 异常重定向接口
    input  logic                         exception_flag,
    input  logic [`ADDR_WIDTH-1:0]       exception_addr
);

    localparam int BP_ENTRIES   = `BP_ENTRIES;
    localparam int BP_TAG_WIDTH = `BP_TAG_WIDTH;

    // -------------------------------------------------------------------------
    // IF 级握手与 PC
    // 仅 fs_pc/valid 是流水级状态；inst_in 和输出总线均不再次寄存。
    // pc_out 给出下一拍请求地址，inst_in 对应本拍 fs_pc。
    // -------------------------------------------------------------------------
    logic [`ADDR_WIDTH-1:0] fs_pc;
    logic [`ADDR_WIDTH-1:0] seq_pc;
    logic [`ADDR_WIDTH-1:0] predicted_next_pc;
    logic [`ADDR_WIDTH-1:0] next_pc;
    logic                   fs_valid;
    logic                   fs_ready_go;
    logic                   fs_allowin;

    logic                   br_taken_r;
    logic [`ADDR_WIDTH-1:0] br_target_r;

    assign fs_ready_go    = 1'b1;
    assign fs_allowin     = ~fs_valid | (fs_ready_go & ds_allowin);
    assign fs_to_ds_valid = fs_valid & fs_ready_go;

    // 64-bit 指令存储器使用 8-byte 对齐地址；逻辑 PC 仍保留 bit[2]，
    // 以便跳转到 8N+4 时从 inst_in[63:32] 取出第一条指令。
    assign pc_out   = {next_pc[`ADDR_WIDTH-1:3], 3'b000};
    assign inst_ren = fs_allowin;

    // -------------------------------------------------------------------------
    // 双槽指令整理
    // -------------------------------------------------------------------------
    logic [`ADDR_WIDTH-1:0] slot0_pc;
    logic [`ADDR_WIDTH-1:0] slot1_pc;
    logic [`INST_WIDTH-1:0] slot0_inst_raw;
    logic [`INST_WIDTH-1:0] slot1_inst_raw;
    logic [`INST_WIDTH-1:0] slot0_inst;
    logic [`INST_WIDTH-1:0] slot1_inst;
    logic                   slot1_available;
    logic                   kill_fetch_packet;

    assign slot0_pc = fs_pc;
    assign slot1_pc = fs_pc + 32'd4;

    assign slot1_available = (fs_pc[2:0] == 3'b000);
    assign slot0_inst_raw  = (fs_pc[1:0] != 2'b00) ? `NOP_INST :
                            (fs_pc[2] ? inst_in[63:32] : inst_in[31:0]);
    assign slot1_inst_raw  = slot1_available ? inst_in[63:32] : `NOP_INST;

    // 分支纠正或异常跳转期间，当前返回的旧路径指令全部变为 NOP。
    assign kill_fetch_packet = br_taken | br_taken_r | exception_flag;

    // -------------------------------------------------------------------------
    // 双端口查询的直接映射 BTB + 2-bit 饱和计数器
    // -------------------------------------------------------------------------
    logic                    bp_valid   [0:BP_ENTRIES-1];
    logic [1:0]              bp_counter [0:BP_ENTRIES-1];
    logic [BP_TAG_WIDTH-1:0] bp_tag     [0:BP_ENTRIES-1];
    logic [`ADDR_WIDTH-1:0]  bp_target  [0:BP_ENTRIES-1];

    logic [`BP_INDEX_WIDTH-1:0] slot0_bp_index;
    logic [`BP_INDEX_WIDTH-1:0] slot1_bp_index;
    logic [BP_TAG_WIDTH-1:0]    slot0_bp_tag;
    logic [BP_TAG_WIDTH-1:0]    slot1_bp_tag;
    logic                       slot0_bp_hit;
    logic                       slot1_bp_hit;
    logic                       slot0_pred_taken;
    logic                       slot1_pred_taken;
    logic [`ADDR_WIDTH-1:0]     slot0_pred_target;
    logic [`ADDR_WIDTH-1:0]     slot1_pred_target;

    assign slot0_bp_index = slot0_pc[`BP_INDEX_WIDTH+1:2];
    assign slot1_bp_index = slot1_pc[`BP_INDEX_WIDTH+1:2];
    assign slot0_bp_tag   = slot0_pc[`ADDR_WIDTH-1:`BP_INDEX_WIDTH+2];
    assign slot1_bp_tag   = slot1_pc[`ADDR_WIDTH-1:`BP_INDEX_WIDTH+2];

    assign slot0_bp_hit = bp_valid[slot0_bp_index]
                        & (bp_tag[slot0_bp_index] == slot0_bp_tag);
    assign slot1_bp_hit = bp_valid[slot1_bp_index]
                        & (bp_tag[slot1_bp_index] == slot1_bp_tag);

    assign slot0_pred_taken = slot0_bp_hit
                            & bp_counter[slot0_bp_index][1]
                            & (fs_pc[1:0] == 2'b00);
    assign slot1_pred_taken = slot1_available
                            & slot1_bp_hit
                            & bp_counter[slot1_bp_index][1]
                            & ~slot0_pred_taken;

    assign slot0_pred_target = bp_target[slot0_bp_index];
    assign slot1_pred_target = bp_target[slot1_bp_index];

    // 槽 0 预测跳转后，槽 1 属于错误路径；8N+4 取指时槽 1 也不可用。
    assign slot0_inst = kill_fetch_packet ? `NOP_INST : slot0_inst_raw;
    assign slot1_inst = (kill_fetch_packet | slot0_pred_taken)
                      ? `NOP_INST : slot1_inst_raw;

    assign seq_pc = fs_pc + (slot1_available ? 32'd8 : 32'd4);
    assign predicted_next_pc = slot0_pred_taken ? slot0_pred_target :
                               slot1_pred_taken ? slot1_pred_target :
                               seq_pc;
    assign next_pc = exception_flag ? exception_addr :
                     br_taken_r      ? br_target_r :
                     predicted_next_pc;

    // 每个槽沿用参考实现的 {inst, pc, pred_taken, pred_target} 排列。
    assign fs_to_ds_bus = {
        slot1_inst,
        slot1_pc,
        (slot1_pred_taken & ~kill_fetch_packet),
        slot1_pred_target,
        slot0_inst,
        slot0_pc,
        (slot0_pred_taken & ~kill_fetch_packet),
        slot0_pred_target
    };

    // -------------------------------------------------------------------------
    // PC/valid 控制。无输出数据寄存器，下一级在 valid && allowin 时锁存。
    // -------------------------------------------------------------------------
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            fs_valid <= 1'b0;
            fs_pc    <= `PC_START - 32'd8;
        end else if (fs_allowin) begin
            fs_valid <= 1'b1;
            fs_pc    <= next_pc;
        end
    end

    // 延迟一拍保存分支纠正，使同步指令存储器返回的旧请求也被清成 NOP。
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            br_taken_r  <= 1'b0;
            br_target_r <= '0;
        end else begin
            if (br_taken) begin
                br_taken_r  <= 1'b1;
                br_target_r <= br_target;
            end else if (fs_allowin) begin
                br_taken_r <= 1'b0;
            end
        end
    end

    // JALR 目标可能动态变化，沿用参考实现：不写入该直接映射预测表。
    integer i;
    logic [`BP_INDEX_WIDTH-1:0] update_index;
    logic [BP_TAG_WIDTH-1:0]    update_tag;

    assign update_index = bp_update_pc[`BP_INDEX_WIDTH+1:2];
    assign update_tag   = bp_update_pc[`ADDR_WIDTH-1:`BP_INDEX_WIDTH+2];

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            for (i = 0; i < BP_ENTRIES; i = i + 1) begin
                bp_valid[i]   <= 1'b0;
                bp_counter[i] <= 2'b01;
                bp_tag[i]     <= '0;
                bp_target[i]  <= '0;
            end
        end else if (bp_update_valid && !bp_update_is_jalr) begin
            bp_valid[update_index]  <= 1'b1;
            bp_tag[update_index]    <= update_tag;
            bp_target[update_index] <= bp_update_target;

            if (!bp_valid[update_index] || (bp_tag[update_index] != update_tag)) begin
                bp_counter[update_index] <= bp_update_taken ? 2'b10 : 2'b01;
            end else if (bp_update_taken) begin
                if (bp_counter[update_index] != 2'b11)
                    bp_counter[update_index] <= bp_counter[update_index] + 2'b01;
            end else begin
                if (bp_counter[update_index] != 2'b00)
                    bp_counter[update_index] <= bp_counter[update_index] - 2'b01;
            end
        end
    end

    // -------------------------------------------------------------------------
    // 取指异常：RV32I 指令地址必须 4-byte 对齐。
    // -------------------------------------------------------------------------
    logic [`EXC_CODE_WIDTH-1:0] exception_code;
    logic [`ADDR_WIDTH-1:0]     exception_mtval;

    assign exception_code  = (fs_to_ds_valid && (fs_pc[1:0] != 2'b00))
                           ? `EXC_IAM : `EXC_NONE;
    assign exception_mtval = (exception_code == `EXC_IAM) ? fs_pc : '0;
    assign fs_exc_bus       = {exception_code, exception_mtval};

endmodule
