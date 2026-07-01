`include "defines.svh"

module id_stage (
    input  logic                     clk,
    input  logic                     rst_n,

    // IF -> ID
    input  logic                     fs_to_ds_valid,
    output logic                     ds_allowin,
    input  logic [`FS_DS_WIDTH-1:0]  fs_to_ds_bus,
    input  logic [`EXC_WIDTH-1:0]    fs_exc_bus,

    // ID -> Rename：双路译码包
    output logic                         ds_to_rn_valid,
    input  logic                         rn_allowin,
    output core_port_pkg::ds_rn_bundle_t ds_to_rn_bus,

    // 全局恢复。这里只记录 flush，不在 ID 删除年轻指令。
    input  wire core_port_pkg::recover_event_t recover
);
    import core_port_pkg::*;
    import id_decode_pkg::*;

    logic                    ds_valid;
    logic                    ds_valid_next;
    logic                    skid_valid;
    logic                    skid_valid_next;
    logic                    ds_allowin_r;
    logic                    ds_allowin_next;
    logic                    ds_pop;
    logic                    fs_push;
    logic                    pipe_flush;

    logic [`FS_DS_WIDTH-1:0] main_bus;
    logic [`FS_DS_WIDTH-1:0] main_bus_next;
    logic [`EXC_WIDTH-1:0]   main_exc;
    logic [`EXC_WIDTH-1:0]   main_exc_next;
    logic [`FS_DS_WIDTH-1:0] skid_bus;
    logic [`FS_DS_WIDTH-1:0] skid_bus_next;
    logic [`EXC_WIDTH-1:0]   skid_exc;
    logic [`EXC_WIDTH-1:0]   skid_exc_next;
    logic                    main_flush;
    logic                    main_flush_next;
    logic                    skid_flush;
    logic                    skid_flush_next;

    assign ds_allowin     = ds_allowin_r;
    assign ds_to_rn_valid = ds_valid;
    assign ds_pop         = ds_valid & rn_allowin;
    assign fs_push        = fs_to_ds_valid & ds_allowin_r;
    assign pipe_flush     = recover.valid;

    // 主槽 + skid 槽构成两项弹性 buffer。ds_allowin 只由寄存器驱动，
    // Rename 的组合反压不会直接穿过 ID 传回 IF。
    always_comb begin
        ds_valid_next   = ds_valid;
        skid_valid_next = skid_valid;
        main_bus_next   = main_bus;
        main_exc_next   = main_exc;
        skid_bus_next   = skid_bus;
        skid_exc_next   = skid_exc;
        main_flush_next = main_flush;
        skid_flush_next = skid_flush;

        unique case ({ds_pop, fs_push})
            2'b00: begin
                // 保持
            end

            2'b01: begin
                if (!ds_valid) begin
                    ds_valid_next = 1'b1;
                    main_bus_next = fs_to_ds_bus;
                    main_exc_next = fs_exc_bus;
                    main_flush_next = pipe_flush;
                end else begin
                    skid_valid_next = 1'b1;
                    skid_bus_next   = fs_to_ds_bus;
                    skid_exc_next   = fs_exc_bus;
                    skid_flush_next = pipe_flush;
                end
            end

            2'b10: begin
                if (skid_valid) begin
                    ds_valid_next   = 1'b1;
                    main_bus_next   = skid_bus;
                    main_exc_next   = skid_exc;
                    main_flush_next = skid_flush;
                    skid_valid_next = 1'b0;
                    skid_flush_next = 1'b0;
                end else begin
                    ds_valid_next = 1'b0;
                    main_flush_next = 1'b0;
                end
            end

            2'b11: begin
                // 主槽被 Rename 接收的同时，用 IF 新数据直接替换。
                main_bus_next = fs_to_ds_bus;
                main_exc_next = fs_exc_bus;
                ds_valid_next = 1'b1;
                main_flush_next = pipe_flush;
            end

            default: begin
                // time 0 的未初始化组合输入保持当前状态；复位上升沿后
                // ds_pop/fs_push 均为确定值。
            end
        endcase

        // flush 到来时，所有仍驻留于 ID buffer 的年轻指令都被打上标记。
        // 它们继续按照正常握手向后流动，不在本级被清空。
        if (pipe_flush) begin
            if (ds_valid_next)
                main_flush_next = 1'b1;
            if (skid_valid_next)
                skid_flush_next = 1'b1;
        end

        ds_allowin_next = ~skid_valid_next;
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            ds_valid     <= 1'b0;
            skid_valid   <= 1'b0;
            ds_allowin_r <= 1'b1;
            main_bus     <= '0;
            main_exc     <= '0;
            skid_bus     <= '0;
            skid_exc     <= '0;
            main_flush   <= 1'b0;
            skid_flush   <= 1'b0;
        end else begin
            ds_valid     <= ds_valid_next;
            skid_valid   <= skid_valid_next;
            ds_allowin_r <= ds_allowin_next;
            main_bus     <= main_bus_next;
            main_exc     <= main_exc_next;
            skid_bus     <= skid_bus_next;
            skid_exc     <= skid_exc_next;
            main_flush   <= main_flush_next;
            skid_flush   <= skid_flush_next;
        end
    end

    fs_ds_bundle_t fetch_bundle;
    ds_rn_slot_t   lane0_decode;
    ds_rn_slot_t   lane1_decode;

    always_comb begin
        fetch_bundle = fs_ds_bundle_t'(main_bus);

        lane0_decode = decode_instruction(
            fetch_bundle.lane0,
            main_exc[`EXC_WIDTH-1 -: `EXC_CODE_WIDTH],
            main_exc[`ADDR_WIDTH-1:0]
        );
        // 组合并入当前 pipe_flush，保证恢复信号与 Rename 接收发生在同一拍时，
        // 被接收的指令也能观察到 flush，而不是等到下一拍才打标。
        lane0_decode.flush = main_flush | pipe_flush;

        // 当前 IF 异常包描述起始 PC；发生异常时第二槽不应进入后端。
        if (main_exc[`EXC_WIDTH-1 -: `EXC_CODE_WIDTH] != `EXC_NONE) begin
            lane1_decode = '0;
            lane1_decode.inst = `NOP_INST;
            lane1_decode.pc   = fetch_bundle.lane1.pc;
            lane1_decode.flush = main_flush | pipe_flush;
        end else begin
            lane1_decode = decode_instruction(
                fetch_bundle.lane1,
                `EXC_NONE,
                '0
            );
            lane1_decode.flush = main_flush | pipe_flush;
        end

        ds_to_rn_bus.lane0 = lane0_decode;
        ds_to_rn_bus.lane1 = lane1_decode;
    end

endmodule
