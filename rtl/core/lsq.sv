`include "defines.svh"

// =============================================================================
// 统一 Load/Store Queue
// =============================================================================
// 8 项全相联条目，支持每拍最多双入队、单 AGU 地址生成、单内存访问。
//
// 【模块角色】
//   LSQ 管理所有访存指令（load + store）的地址生成、内存访问调度、
//   store-to-load forwarding、以及已提交 store 的排空写回。它是乱序
//   处理器中除了 ROB 之外最复杂的结构。
//
// 【核心设计】
//   a. 地址生成（AGU）与内存访问分离为两级：
//      AGU 按 oldest-ready 乱序调度（只需基址 ready）；
//      内存访问在有地址、且已检测转发条件后才发起。
//   b. Load 不预测越过地址未知的老 Store。如果任意老 Store
//      地址未知、存在部分覆盖、或全覆盖但数据未就绪时，Load
//      必须等待。该等待由 load_safe 条件控制。
//   c. 完全覆盖且数据就绪的 Store 可以直接转发给 Load，
//      无需访问内存。转发数据在 LSQ 内部直接完成。
//   d. Store 可乱序完成地址和数据准备，但只有 ROB 顺序提交后
//      才产生外部内存写请求。Store 的排空顺序由 store_seq 保证。
//   e. 恢复时保留已提交的 Store，清除推测 Store。
//
// 【条目生命周期】
//   入队 → src1 ready → AGU 选择 → 地址生成
//     → Load: 判断冲突/转发 → 转发或内存请求 → 数据就绪
//     → Store: 等待 src2 data (CDB) → 等待 ROB 提交
//     → 完成事件 → WB1 握手 → 条目释放
// =============================================================================
module lsq #(
    parameter int DEPTH = core_port_pkg::LSQ_DEPTH
) (
    input  logic                                   clk,
    input  logic                                   rst_n,

    // ---- Dispatch 入队 ----
    // 前缀约束：enq_valid[1] 要求 enq_valid[0]。
    // capacity 由本拍开始时寄存 entry.valid 决定，不旁路本拍释放。
    input  logic [1:0]                             enq_valid,
    input  wire core_port_pkg::dp_lsq_bundle_t     enq_bus,
    output      core_port_pkg::dispatch_capacity_t capacity,

    // ---- 写回广播 ----
    // 两路写回广播（CDB），用于唤醒等待源操作数的条目。
    // Store 的 src2（store data）也通过广播捕获。
    input  wire core_port_pkg::phys_reg_write_bundle_t wakeup_bus,
    input  wire core_port_pkg::rob_tag_t           rob_head_tag,
    input  wire core_port_pkg::recover_event_t     recover,

    // ---- AGU 地址生成接口（→ issue1 仲裁 → AGU）----
    // 地址生成候选按 oldest-ready 调度，送往 issue1_arbiter 与 IQ 竞争 issue1。
    input  logic                                   lsu_available,
    output logic                                   agu_issue_valid,
    output      core_port_pkg::lsq_agu_issue_t     agu_issue_bus,
    input  logic                                   agu_issue_ready,
    output logic                                   agu_issue_fire,
    // AGU 返回结果：地址、Store data、地址对齐/异常。
    input  wire core_port_pkg::lsq_agu_result_t    agu_result,

    // ---- ROB 提交侧 ----
    // ROB 顺序提交时通知 LSQ。非 Store 的 commit 可以直接通过（ready=1）。
    // Store 需要等数据就绪后才能允许提交。
    input  wire core_port_pkg::rob_commit_bundle_t commit_bus,
    output logic [1:0]                             store_commit_ready,
    input  logic [1:0]                             commit_fire,

    // ---- 内存请求接口 ----
    // 寄存后输出到 DMEM。is_store=1 为写请求，is_store=0 为读请求。
    output logic                                   mem_request_valid,
    output      core_port_pkg::lsq_mem_request_t   mem_request,
    input  logic                                   mem_request_ready,
    input  wire core_port_pkg::lsq_mem_response_t  mem_response,

    // ---- 完成写回接口（→ WB1）----
    // Load 数据或 Store/异常完成事件，进入 WB1 写回仲裁。
    output logic                                   writeback_valid,
    output      core_port_pkg::lsq_writeback_t     writeback_bus,
    input  logic                                   writeback_ready,
    output logic                                   writeback_fire,

    output logic [$clog2(DEPTH+1)-1:0]             occupancy_o
);
    import core_port_pkg::*;

    localparam int INDEX_WIDTH = $clog2(DEPTH);
    localparam int COUNT_WIDTH = $clog2(DEPTH + 1);
    localparam int STORE_SEQ_WIDTH = $clog2(DEPTH * 2);

    // ══════════════════════════════════════════════════════════════════════════
    // 内部类型与状态
    // ══════════════════════════════════════════════════════════════════════════

    // ── LSQ 条目定义 ──
    // 每个条目记录一条访存指令从入队到排空的完整状态。
    // 字段按生命周期分组：
    //   第 1 组（入队时确定）：valid, lsq_tag, payload, src1/2_ready
    //   第 2 组（AGU 后更新）：address_issued, address_valid, address
    //   第 3 组（CDB 写回后）：store_data_valid, store_data
    //   第 4 组（ROB 提交后）：committed, store_seq
    //   第 5 组（内存/转发后）：load_data_valid/load_data / exception
    //   第 6 组（完成阶段）  ：completion_sent
    typedef struct packed {
        logic                       valid;              // 条目占用
        lsq_tag_t                   lsq_tag;            // 全局唯一标签（含 generation）
        dp_lsq_slot_t               payload;            // Dispatch 传来的全部信息
        logic                       src1_ready;         // 基址就绪
        logic                       src2_ready;         // store data 就绪（load 恒 1）
        logic                       address_issued;     // AGU 已发出但未返回
        logic                       address_valid;      // 地址已知
        logic [`ADDR_WIDTH-1:0]     address;            // 物理地址
        logic                       store_data_valid;   // store 数据就绪
        logic [XLEN-1:0]            store_data;         // store 写入数据
        logic                       committed;          // ROB 已提交
        logic [STORE_SEQ_WIDTH-1:0] store_seq;          // 提交顺序号（用于排空顺序）
        logic                       memory_requested;   // 已发出内存请求
        logic                       load_data_valid;    // load 数据有效
        logic [XLEN-1:0]            load_data;          // load 读回/转发数据
        logic                       exception_valid;    // 发生异常
        logic [`EXC_CODE_WIDTH-1:0] exc_code;
        logic [`ADDR_WIDTH-1:0]     exc_tval;
        logic                       completion_sent;    // 已完成事件已发出
    } lsq_entry_t;

    lsq_entry_t entries [0:DEPTH-1];
    logic [LSQ_GEN_WIDTH-1:0] slot_generation [0:DEPTH-1]; // 每个槽位的 generation 计数器
    logic [COUNT_WIDTH-1:0] occupancy;
    logic [STORE_SEQ_WIDTH-1:0] store_commit_tail;
    logic [STORE_SEQ_WIDTH-1:0] store_drain_head;
    logic [1:0] commit_store_count;
    logic committed_store_found;

    logic [INDEX_WIDTH-1:0] free_idx0;
    logic [INDEX_WIDTH-1:0] free_idx1;
    logic free_valid0;
    logic free_valid1;
    logic [1:0] enq_fire;
    logic [1:0] enq_count;

    logic agu_select_valid;
    logic [INDEX_WIDTH-1:0] agu_select_idx;
    logic [ROB_PTR_WIDTH-1:0] agu_select_age;
    logic [ROB_PTR_WIDTH-1:0] agu_scan_age;
    lsq_agu_issue_t agu_select_packet;
    logic agu_hold_valid;
    logic [INDEX_WIDTH-1:0] agu_hold_idx;
    lsq_agu_issue_t agu_hold_packet;

    logic completion_select_valid;
    logic [INDEX_WIDTH-1:0] completion_select_idx;
    logic [ROB_PTR_WIDTH-1:0] completion_select_age;
    logic completion_pending_valid;
    logic [INDEX_WIDTH-1:0] completion_pending_idx;
    lsq_tag_t completion_pending_tag;
    logic completion_pending_is_store;
    logic completion_pending_exception;
    lsq_writeback_t completion_pending_bus;

    logic memory_select_valid;
    logic memory_select_forward;
    logic [INDEX_WIDTH-1:0] memory_select_idx;
    logic [ROB_PTR_WIDTH-1:0] memory_select_age;
    logic [XLEN-1:0] memory_forward_data;
    lsq_mem_request_t memory_select_request;
    logic memory_select_q_valid;
    logic [INDEX_WIDTH-1:0] memory_select_q_idx;
    lsq_tag_t memory_select_q_tag;
    logic [XLEN-1:0] memory_forward_data_q;
    logic memory_request_reg_valid;
    lsq_mem_request_t memory_request_reg;

    logic [2:0] remove_count;
    integer preserve_count;

    integer agu_idx;
    integer commit_entry_idx;
    integer completion_idx;
    integer memory_idx;
    integer memory_store_idx;
    integer preserve_idx;
    integer free_scan_idx;
    integer reset_idx;
    integer commit_port_idx;

    logic scan_src1_ready;
    logic scan_src2_ready;
    logic [ROB_PTR_WIDTH-1:0] completion_scan_age;
    logic [ROB_PTR_WIDTH-1:0] memory_scan_age;
    logic load_safe;
    logic load_forward;
    logic [ROB_PTR_WIDTH-1:0] youngest_store_age;
    logic [XLEN-1:0] youngest_store_word;
    logic [3:0] load_mask;
    logic [3:0] store_mask;
    logic overlap;
    logic full_cover;

    // ══════════════════════════════════════════════════════════════════════════
    // 辅助函数
    // ══════════════════════════════════════════════════════════════════════════

    // 判断条目是否为 Store
    function automatic logic is_store_entry(input lsq_entry_t entry);
        is_store_entry = entry.payload.uop.dec.mem_write;
    endfunction

    // 写回广播匹配：给定物理寄存器号是否被本拍任一写回端口写入
    // 同时过滤 p0（preg=0 不存在唤醒）
    function automatic logic wakeup_match(input phys_reg_idx_t preg);
        wakeup_match = (preg != '0)
                     && ((wakeup_bus.lane0.valid
                          && (wakeup_bus.lane0.preg == preg))
                         || (wakeup_bus.lane1.valid
                             && (wakeup_bus.lane1.preg == preg)));
    endfunction

    // 获取写回广播中指定物理寄存器的数据（lane1 优先）
    function automatic logic [XLEN-1:0] wakeup_data(input phys_reg_idx_t preg);
        logic [XLEN-1:0] data;
        begin
            data = '0;
            if (wakeup_bus.lane0.valid && (wakeup_bus.lane0.preg == preg))
                data = wakeup_bus.lane0.data;
            if (wakeup_bus.lane1.valid && (wakeup_bus.lane1.preg == preg))
                data = wakeup_bus.lane1.data;
            wakeup_data = data;
        end
    endfunction

    // 字节掩码生成：根据访存类型和字内偏移产生字节使能掩码
    // 例如 MEM_WORD、偏移 0 → 4'b1111；MEM_HALF、偏移 2 → 4'b1100
    function automatic logic [3:0] byte_mask(
        input mem_op_e mem_op,
        input logic [1:0] offset
    );
        logic [3:0] base_mask;
        begin
            unique case (mem_op)
                MEM_BYTE,
                MEM_BYTE_U: base_mask = 4'b0001;
                MEM_HALF,
                MEM_HALF_U: base_mask = 4'b0011;
                default:    base_mask = 4'b1111;
            endcase
            byte_mask = base_mask << offset;
        end
    endfunction

    // 地址对齐检查：半字（最后 1 bit 非 0）、字（最后 2 bits 非 0）、字节永远对齐
    function automatic logic address_misaligned(
        input mem_op_e mem_op,
        input logic [`ADDR_WIDTH-1:0] address
    );
        unique case (mem_op)
            MEM_HALF,
            MEM_HALF_U: address_misaligned = address[0];
            MEM_WORD:   address_misaligned = |address[1:0];
            default:    address_misaligned = 1'b0; // MEM_BYTE 永远对齐
        endcase
    endfunction

    // Store 数据字对齐：将寄存器数据左移到正确的字内位置
    // 例如 offset=2 时左移 16 bit
    function automatic logic [XLEN-1:0] aligned_store_word(
        input logic [XLEN-1:0] data,
        input logic [1:0]      offset
    );
        aligned_store_word = data << (offset * 8);
    endfunction

    // Load 数据格式化：从字中取出正确位置和符号/零扩展
    // 先右移 offset×8 字节，再按访存类型做符号/零扩展
    function automatic logic [XLEN-1:0] format_load_data(
        input mem_op_e         mem_op,
        input logic [1:0]      offset,
        input logic [XLEN-1:0] word
    );
        logic [XLEN-1:0] shifted;
        begin
            shifted = word >> (offset * 8);
            unique case (mem_op)
                MEM_BYTE:   format_load_data = {{24{shifted[7]}}, shifted[7:0]};
                MEM_BYTE_U: format_load_data = {24'b0, shifted[7:0]};
                MEM_HALF:   format_load_data = {{16{shifted[15]}}, shifted[15:0]};
                MEM_HALF_U: format_load_data = {16'b0, shifted[15:0]};
                default:    format_load_data = shifted;
            endcase
        end
    endfunction

    // 检查条目是否被本拍 ROB 提交匹配：非异常 Store、tag 匹配
    // 用于 recover 时识别刚被提交的条目应保留
    function automatic logic commit_matches_entry(
        input lsq_entry_t entry
    );
        commit_matches_entry = (commit_fire[0] && commit_bus.lane0.is_store
                                && !commit_bus.lane0.exception_valid
                                && (commit_bus.lane0.tag == entry.payload.rob_tag))
                            || (commit_fire[1] && commit_bus.lane1.is_store
                                && !commit_bus.lane1.exception_valid
                                && (commit_bus.lane1.tag == entry.payload.rob_tag));
    endfunction

    // 构造 AGU 发出包：包含 src1 bypass 数据和 store 数据读取请求
    // Store 指令若 src2（数据）还没就绪，设置 read_store_data 标志通知 AGU 读 PRF
    function automatic lsq_agu_issue_t make_agu_packet(
        input lsq_entry_t entry
    );
        lsq_agu_issue_t packet;
        logic src2_now_ready;
        begin
            packet = '0;
            packet.lsq_tag = entry.lsq_tag;
            packet.rob_tag = entry.payload.rob_tag;
            packet.uop     = entry.payload.uop;

            if (wakeup_bus.lane0.valid
                && (wakeup_bus.lane0.preg == entry.payload.uop.prs1)) begin
                packet.src1_bypass_valid = 1'b1;
                packet.src1_bypass_data  = wakeup_bus.lane0.data;
            end
            if (wakeup_bus.lane1.valid
                && (wakeup_bus.lane1.preg == entry.payload.uop.prs1)) begin
                packet.src1_bypass_valid = 1'b1;
                packet.src1_bypass_data  = wakeup_bus.lane1.data;
            end

            src2_now_ready = entry.src2_ready
                           || wakeup_match(entry.payload.uop.prs2);
            packet.read_store_data = is_store_entry(entry)
                                   && !entry.store_data_valid
                                   && src2_now_ready;
            if (packet.read_store_data && wakeup_bus.lane0.valid
                && (wakeup_bus.lane0.preg == entry.payload.uop.prs2)) begin
                packet.src2_bypass_valid = 1'b1;
                packet.src2_bypass_data  = wakeup_bus.lane0.data;
            end
            if (packet.read_store_data && wakeup_bus.lane1.valid
                && (wakeup_bus.lane1.preg == entry.payload.uop.prs2)) begin
                packet.src2_bypass_valid = 1'b1;
                packet.src2_bypass_data  = wakeup_bus.lane1.data;
            end
            make_agu_packet = packet;
        end
    endfunction

    // ══════════════════════════════════════════════════════════════════════════
    // 组合逻辑块 A：双入队空槽扫描与 Dispatch capacity
    // ══════════════════════════════════════════════════════════════════════════
    // 扫描 entries[] 中 valid=0 的槽位，返回前两个空闲槽的索引。
    // capacity 向 Dispatch 报告本拍最多可接收几条指令（0/1/2）。
    //
    // 【时序约束】
    //   capacity 只依赖寄存的 entries[].valid，不使用本拍即将释放的槽位。
    //   这保证 Dispatch 看到的 capacity 变化只由 LSQ 内部状态更新驱动，
    //   不会形成 Dispatch↔LSQ 的组合环路。
    //
    // 【前缀约束】
    //   enq_fire[1] 要求 enq_valid[0] && enq_valid[1] && free_valid1。
    //   即 lane1 入队必须 lane0 也同时入队。这与上游 dispatch 的前缀约束一致。
    always_comb begin
        free_valid0 = 1'b0;
        free_valid1 = 1'b0;
        free_idx0   = '0;
        free_idx1   = '0;
        for (free_scan_idx = 0; free_scan_idx < DEPTH;
             free_scan_idx = free_scan_idx + 1) begin
            if (!entries[free_scan_idx].valid) begin
                if (!free_valid0) begin
                    free_valid0 = 1'b1;
                    free_idx0   = INDEX_WIDTH'(free_scan_idx);
                end else if (!free_valid1) begin
                    free_valid1 = 1'b1;
                    free_idx1   = INDEX_WIDTH'(free_scan_idx);
                end
            end
        end
        if (free_valid1)
            capacity = dispatch_capacity_t'(2);
        else if (free_valid0)
            capacity = dispatch_capacity_t'(1);
        else
            capacity = '0;
        enq_fire[0] = enq_valid[0] && free_valid0;
        enq_fire[1] = enq_valid[1] && enq_valid[0] && free_valid1;
        enq_count   = {1'b0, enq_fire[0]} + {1'b0, enq_fire[1]};
    end

    // ══════════════════════════════════════════════════════════════════════════
    // 组合逻辑块 B：AGU 地址生成 oldest-ready 乱序选择
    // ══════════════════════════════════════════════════════════════════════════
    // 从所有 address_valid=0 且 address_issued=0 且非异常的条目中，
    // 选择 src1（基址）已就绪的最老条目，送往 issue1_arbiter 与 IQ1 竞争。
    //
    // 【Store 地址与数据分离】
    //   Store 只需基址（src1）就绪就可以调度地址生成。
    //   Store 数据（src2）可以稍后通过 CDB 写回广播补齐，不阻塞地址生成。
    //   这允许不同 Store 的地址和数据并行准备。
    //
    // 【AGU hold 机制】
    //   AGU 选择结果在 issue1 反压时锁存到 agu_hold_valid/hold_packet，
    //   确保选中条目在反压期间不被其他新就绪条目抢走。
    always_comb begin
        agu_select_valid  = 1'b0;
        agu_select_idx    = '0;
        agu_select_age    = '1;
        agu_scan_age      = '0;
        agu_select_packet = '0;
        scan_src1_ready   = 1'b0;
        scan_src2_ready   = 1'b0;

        if (!agu_hold_valid && lsu_available) begin
            for (agu_idx = 0; agu_idx < DEPTH; agu_idx = agu_idx + 1) begin
                scan_src1_ready = !entries[agu_idx].payload.uop.dec.use_rs1
                               || entries[agu_idx].src1_ready
                               || wakeup_match(entries[agu_idx].payload.uop.prs1);
                agu_scan_age = entries[agu_idx].payload.rob_tag - rob_head_tag;
                if (entries[agu_idx].valid
                    && !entries[agu_idx].address_valid
                    && !entries[agu_idx].address_issued
                    && !entries[agu_idx].exception_valid
                    && scan_src1_ready
                    && (!agu_select_valid || (agu_scan_age < agu_select_age))) begin
                    agu_select_valid  = 1'b1;
                    agu_select_idx    = INDEX_WIDTH'(agu_idx);
                    agu_select_age    = agu_scan_age;
                    agu_select_packet = make_agu_packet(entries[agu_idx]);
                end
            end
        end

        agu_issue_valid = agu_hold_valid || agu_select_valid;
        agu_issue_bus   = agu_hold_valid ? agu_hold_packet : agu_select_packet;
        agu_issue_fire  = agu_issue_valid && agu_issue_ready;
    end

    // ══════════════════════════════════════════════════════════════════════════
    // 组合逻辑块 C：ROB Store 提交检查
    // ══════════════════════════════════════════════════════════════════════════
    // 当 ROB 尝试提交一条 Store 指令时，需要确认该 Store 在 LSQ 中的条目
    // 已经完成全部准备工作（地址已知、数据就绪、完成事件已发出）才能允许提交。
    //
    // store_commit_ready[port] = 0 → 对应 ROB commit 端口的 Store 暂不可提交。
    // 每个端口独立检查，搜索 entries[] 中与该端口 tag 匹配的条目。
    // 当前仅支持已就绪且完成事件已发出的 Store 提交。
    // 异常 Store 不产生提交等待（由 recovery 处理）。
    always_comb begin
        store_commit_ready = 2'b11;
        commit_store_count = '0;
        if (commit_fire[0] && commit_bus.lane0.is_store
            && !commit_bus.lane0.exception_valid)
            commit_store_count = commit_store_count + 1'b1;
        if (commit_fire[1] && commit_bus.lane1.is_store
            && !commit_bus.lane1.exception_valid)
            commit_store_count = commit_store_count + 1'b1;
        for (commit_port_idx = 0; commit_port_idx < 2;
             commit_port_idx = commit_port_idx + 1) begin
            if ((commit_port_idx == 0) && commit_bus.lane0.valid
                && commit_bus.lane0.is_store
                && !commit_bus.lane0.exception_valid) begin
                store_commit_ready[0] = 1'b0;
                for (commit_entry_idx = 0; commit_entry_idx < DEPTH;
                     commit_entry_idx = commit_entry_idx + 1)
                    if (entries[commit_entry_idx].valid
                        && (entries[commit_entry_idx].payload.rob_tag == commit_bus.lane0.tag)
                        && entries[commit_entry_idx].address_valid
                        && entries[commit_entry_idx].store_data_valid
                        && entries[commit_entry_idx].completion_sent)
                        store_commit_ready[0] = 1'b1;
            end
            if ((commit_port_idx == 1) && commit_bus.lane1.valid
                && commit_bus.lane1.is_store
                && !commit_bus.lane1.exception_valid) begin
                store_commit_ready[1] = 1'b0;
                for (commit_entry_idx = 0; commit_entry_idx < DEPTH;
                     commit_entry_idx = commit_entry_idx + 1)
                    if (entries[commit_entry_idx].valid
                        && (entries[commit_entry_idx].payload.rob_tag == commit_bus.lane1.tag)
                        && entries[commit_entry_idx].address_valid
                        && entries[commit_entry_idx].store_data_valid
                        && entries[commit_entry_idx].completion_sent)
                        store_commit_ready[1] = 1'b1;
            end
        end
    end

    // ══════════════════════════════════════════════════════════════════════════
    // 组合逻辑块 D：完成事件调度
    // ══════════════════════════════════════════════════════════════════════════
    // 从所有 !completion_sent 的条目中选择最老的即可发送完成事件的条目：
    //   - Load：load_data_valid（数据已就绪）
    //   - Store：地址有效 && 数据有效（但 Store 的完成不写 PRF，仅标记状态）
    //   - 任意：exception_valid（异常）
    //
    // 选中结果进入 completion_pending 单条目 buffer，再通过 writeback_valid/ready
    // 握手送往 WB1。一个 pending buffer 足以吸收 WB1 的短暂反压。
    always_comb begin
        completion_select_valid = 1'b0;
        completion_select_idx   = '0;
        completion_select_age   = '1;
        completion_scan_age = '0;
        for (completion_idx = 0; completion_idx < DEPTH;
             completion_idx = completion_idx + 1) begin
            completion_scan_age = entries[completion_idx].payload.rob_tag - rob_head_tag;
            if (entries[completion_idx].valid && !entries[completion_idx].completion_sent
                && (entries[completion_idx].exception_valid
                    || (!is_store_entry(entries[completion_idx])
                        && entries[completion_idx].load_data_valid)
                    || (is_store_entry(entries[completion_idx])
                        && entries[completion_idx].address_valid
                        && entries[completion_idx].store_data_valid))
                && (!completion_select_valid
                    || (completion_scan_age < completion_select_age))) begin
                completion_select_valid = 1'b1;
                completion_select_idx   = INDEX_WIDTH'(completion_idx);
                completion_select_age   = completion_scan_age;
            end
        end

        writeback_valid = completion_pending_valid;
        writeback_bus   = completion_pending_bus;
        writeback_fire  = writeback_valid && writeback_ready;
    end

    // ══════════════════════════════════════════════════════════════════════════
    // 组合逻辑块 E：安全内存调度 + Store-to-Load Forwarding
    // ══════════════════════════════════════════════════════════════════════════
    // 核心逻辑——也全是最深组合路径的来源。
    //
    // 【Load 的调度条件】
    //   1. address_valid=1, memory_requested=0, 非异常
    //   2. load_safe = true（没有不可穿越的老 Store）
    //   3. 如果没有更老的 Store 已准备好写入内存（committed & store_seq == drain_head），
    //      则 Load 会被选为内存访问候选
    //
    // 【Store 的调度条件】
    //   1. address_valid=1, memory_requested=0, 非异常
    //   2. committed=1 && store_seq == store_drain_head（队首已提交 Store）
    //   3. store_data_valid=1（数据就绪）
    //
    // 【Store-to-Load Forwarding】
    //   对于每个 Load，扫描所有比它老的 Store（age < load_age）：
    //     a. 地址未知或异常 → load_safe=0（不可穿越）
    //     b. 地址已知，不重叠   → 可越过（不触发转发不设限制）
    //     c. 地址重叠，部分覆盖  → load_safe=0（保守等待）
    //     d. 地址重叠，完全覆盖  → load_forward=true，记录 youngest_store_word
    //        同时要求 store_data_valid=1（数据就绪）
    //
    //   转发数据在 memory_select 时直接写入 load_data_valid/load_data，
    //   不经过外部内存路径。
    //
    // 【"最年轻老 Store"转发语义】
    //   多个老 Store 覆盖同一 Load 时，转发最年轻的那个（age 最接近 load）。
    //   因为最年轻的覆盖了之前所有老 Store 的写入，其数据就是最终值。
    //   代码中通过 youngest_store_age 持续更新来实现 this。
    always_comb begin
        memory_select_valid   = 1'b0;
        memory_select_forward = 1'b0;
        memory_select_idx     = '0;
        memory_select_age     = '1;
        memory_forward_data   = '0;
        memory_select_request = '0;
        load_safe             = 1'b0;
        load_forward          = 1'b0;
        youngest_store_age    = '0;
        youngest_store_word   = '0;
        load_mask             = '0;
        store_mask            = '0;
        overlap               = 1'b0;
        full_cover            = 1'b0;
        memory_scan_age       = '0;
        committed_store_found = 1'b0;

        if (!memory_request_reg_valid && !memory_select_q_valid) begin
            for (memory_idx = 0; memory_idx < DEPTH;
                 memory_idx = memory_idx + 1) begin
                memory_scan_age = entries[memory_idx].payload.rob_tag - rob_head_tag;
                if (entries[memory_idx].valid && entries[memory_idx].address_valid
                    && !entries[memory_idx].memory_requested
                    && !entries[memory_idx].exception_valid) begin
                    if (is_store_entry(entries[memory_idx])) begin
                        if (entries[memory_idx].committed
                            && (entries[memory_idx].store_seq == store_drain_head)
                            && entries[memory_idx].store_data_valid
                            ) begin
                            committed_store_found = 1'b1;
                            memory_select_valid   = 1'b1;
                            memory_select_forward = 1'b0;
                            memory_select_idx     = INDEX_WIDTH'(memory_idx);
                            memory_select_age     = memory_scan_age;
                            memory_select_request.is_store = 1'b1;
                            memory_select_request.lsq_tag  = entries[memory_idx].lsq_tag;
                            memory_select_request.rob_tag  = entries[memory_idx].payload.rob_tag;
                            memory_select_request.address  = entries[memory_idx].address;
                            memory_select_request.mem_op   = entries[memory_idx].payload.uop.dec.mem_op;
                            memory_select_request.write_strobe = byte_mask(
                                entries[memory_idx].payload.uop.dec.mem_op,
                                entries[memory_idx].address[1:0]);
                            memory_select_request.write_data = aligned_store_word(
                                entries[memory_idx].store_data,
                                entries[memory_idx].address[1:0]);
                        end
                    end else begin
                        load_safe          = 1'b1;
                        load_forward       = 1'b0;
                        youngest_store_age = '0;
                        youngest_store_word = '0;
                        load_mask = byte_mask(entries[memory_idx].payload.uop.dec.mem_op,
                                              entries[memory_idx].address[1:0]);

                        for (memory_store_idx = 0; memory_store_idx < DEPTH;
                             memory_store_idx = memory_store_idx + 1) begin
                            if (entries[memory_store_idx].valid
                                && is_store_entry(entries[memory_store_idx])
                                && ((entries[memory_store_idx].payload.rob_tag - rob_head_tag)
                                    < memory_scan_age)) begin
                                if (!entries[memory_store_idx].address_valid
                                    || entries[memory_store_idx].exception_valid) begin
                                    load_safe = 1'b0;
                                end else begin
                                    store_mask = byte_mask(
                                        entries[memory_store_idx].payload.uop.dec.mem_op,
                                        entries[memory_store_idx].address[1:0]);
                                    overlap = (entries[memory_store_idx].address[31:2]
                                               == entries[memory_idx].address[31:2])
                                           && (|(store_mask & load_mask));
                                    full_cover = ((store_mask & load_mask) == load_mask);
                                    if (overlap) begin
                                        if (!full_cover
                                            || !entries[memory_store_idx].store_data_valid) begin
                                            load_safe = 1'b0;
                                        end else if (!load_forward
                                            || ((entries[memory_store_idx].payload.rob_tag
                                                 - rob_head_tag) > youngest_store_age)) begin
                                            load_forward = 1'b1;
                                            youngest_store_age = entries[memory_store_idx].payload.rob_tag
                                                               - rob_head_tag;
                                            youngest_store_word = aligned_store_word(
                                                entries[memory_store_idx].store_data,
                                                entries[memory_store_idx].address[1:0]);
                                        end
                                    end
                                end
                            end
                        end

                        if (load_safe && !committed_store_found
                            && (!memory_select_valid
                                || (memory_scan_age < memory_select_age))) begin
                            memory_select_valid   = 1'b1;
                            memory_select_forward = load_forward;
                            memory_select_idx     = INDEX_WIDTH'(memory_idx);
                            memory_select_age     = memory_scan_age;
                            memory_forward_data = format_load_data(
                                entries[memory_idx].payload.uop.dec.mem_op,
                                entries[memory_idx].address[1:0], youngest_store_word);
                            memory_select_request.is_store = 1'b0;
                            memory_select_request.lsq_tag  = entries[memory_idx].lsq_tag;
                            memory_select_request.rob_tag  = entries[memory_idx].payload.rob_tag;
                            memory_select_request.address  = entries[memory_idx].address;
                            memory_select_request.mem_op   = entries[memory_idx].payload.uop.dec.mem_op;
                        end
                    end
                end
            end
        end

        mem_request_valid = memory_request_reg_valid;
        mem_request       = memory_request_reg;
    end

    // ══════════════════════════════════════════════════════════════════════════
    // 组合逻辑块 G：条目释放计数 + 恢复保留计数
    // ══════════════════════════════════════════════════════════════════════════
    // remove_count：本拍将要释放的条目数（写回或 Store 内存排空）
    //   来源 1：Store 内存写请求握手成功（条目真正释放）
    //   来源 2：非 Store 完成事件握手成功（Load 数据或异常）
    // preserve_count：recover 时需要保留的已提交 Store 数量
    //   （用于恢复后 occupancy 的正确值）
    //
    // 【Store 完成 vs Store 释放的时间差】
    //   Store 完成事件（completion_sent）只是通知 ROB 可以提交了，
    //   此时条目仍然有效（valid=1），直到内存写请求握手成功后才释放。
    //   这是 store 条目生命周期中最长的一段。
    // ══════════════════════════════════════════════════════════════════════════
    always_comb begin
        remove_count = '0;
        if (memory_request_reg_valid && mem_request_ready
            && memory_request_reg.is_store)
            remove_count = remove_count + 1'b1;
        if (writeback_fire
            && (!completion_pending_is_store || completion_pending_exception))
            remove_count = remove_count + 1'b1;

        preserve_count = 0;
        for (preserve_idx = 0; preserve_idx < DEPTH;
             preserve_idx = preserve_idx + 1)
            if (entries[preserve_idx].valid && is_store_entry(entries[preserve_idx])
                && (entries[preserve_idx].committed
                    || commit_matches_entry(entries[preserve_idx]))
                && !(memory_request_reg_valid && mem_request_ready
                     && memory_request_reg.is_store
                     && (memory_request_reg.lsq_tag == entries[preserve_idx].lsq_tag)))
                preserve_count = preserve_count + 1;
        occupancy_o = occupancy;
    end

    // ══════════════════════════════════════════════════════════════════════════
    // 时序逻辑：LSQ 主状态机
    // ══════════════════════════════════════════════════════════════════════════
    // 包含所有条目、指针和 buffer 的寄存更新。按更新类型分为：
    //
    //   【复位】全清。
    //   【恢复】保留已提交 Store，清除推测 Store。
    //   【正常】按以下顺序（同一个 always_ff 中代码序与更新顺序无关，
    //          非阻塞赋值为并发语义）：
    //         ① occupancy / store_commit_tail / store_drain_head 更新
    //         ② 写回广播唤醒所有条目 + Store 数据捕获 + ROB 提交标记
    //         ③ AGU 地址生成握手 + hold 管理
    //         ④ AGU 返回结果处理（地址、异常、Store 数据）
    //         ⑤ 内存请求寄存级状态机
    //         ⑥ 内存响应处理
    //         ⑦ 完成事件 pending buffer 管理
    //         ⑧ 新入队条目写入
    //
    // 同拍多个事件更新同一条目时的优先级（隐含在代码顺序 + 非阻塞赋值语义）：
    //   入队写入（最后）> AGU 返回（中间）> CDB 唤醒（最前）
    //   入队写 {} = '0 再赋部分字段，会在最后覆盖前面所有更新。
    //   但入队不可能与 AGU 返回或 CDB 唤醒在同一拍冲突（新写入条目之前 valid=0）。
    // ══════════════════════════════════════════════════════════════════════════
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            occupancy <= '0;
            agu_hold_valid <= 1'b0;
            agu_hold_idx   <= '0;
            agu_hold_packet <= '0;
            completion_pending_valid <= 1'b0;
            completion_pending_idx   <= '0;
            completion_pending_tag   <= '0;
            completion_pending_is_store <= 1'b0;
            completion_pending_exception <= 1'b0;
            completion_pending_bus <= '0;
            memory_select_q_valid <= 1'b0;
            memory_select_q_idx <= '0;
            memory_select_q_tag <= '0;
            memory_forward_data_q <= '0;
            memory_request_reg_valid <= 1'b0;
            memory_request_reg <= '0;
            store_commit_tail <= '0;
            store_drain_head  <= '0;
            for (reset_idx = 0; reset_idx < DEPTH; reset_idx = reset_idx + 1) begin
                entries[reset_idx] <= '0;
                slot_generation[reset_idx] <= '0;
            end
        end else if (recover.valid) begin
            // ── 恢复处理 ──
            // 清空推测 Store，保留已提交 Store（包括本拍刚提交的）。
            // occupancy 重建为 preserve_count（已提交 Store 数量）。
            // store_commit_tail 已计算本拍提交，继续递增。
            // store_drain_head 正常推进（内存写请求若本拍握手成功）。
            // completion_pending 和 agu_hold 必须清空（推测状态）。
            occupancy <= COUNT_WIDTH'(preserve_count);
            store_commit_tail <= store_commit_tail
                               + STORE_SEQ_WIDTH'(commit_store_count);
            if (memory_request_reg_valid && mem_request_ready
                && memory_request_reg.is_store)
                store_drain_head <= store_drain_head + 1'b1;
            agu_hold_valid <= 1'b0;
            completion_pending_valid <= 1'b0;
            memory_select_q_valid <= 1'b0;

            for (reset_idx = 0; reset_idx < DEPTH; reset_idx = reset_idx + 1) begin
                if (entries[reset_idx].valid && is_store_entry(entries[reset_idx])
                    && (entries[reset_idx].committed
                        || commit_matches_entry(entries[reset_idx]))
                    && !(memory_request_reg_valid && mem_request_ready
                         && memory_request_reg.is_store
                         && (memory_request_reg.lsq_tag == entries[reset_idx].lsq_tag))) begin
                    entries[reset_idx].valid     <= 1'b1;
                    entries[reset_idx].committed <= 1'b1;
                    if (commit_fire[0] && commit_bus.lane0.is_store
                        && !commit_bus.lane0.exception_valid
                        && (commit_bus.lane0.tag == entries[reset_idx].payload.rob_tag))
                        entries[reset_idx].store_seq <= store_commit_tail;
                    if (commit_fire[1] && commit_bus.lane1.is_store
                        && !commit_bus.lane1.exception_valid
                        && (commit_bus.lane1.tag == entries[reset_idx].payload.rob_tag))
                        entries[reset_idx].store_seq <= store_commit_tail
                                                     + STORE_SEQ_WIDTH'(
                                                         commit_fire[0]
                                                         && commit_bus.lane0.is_store
                                                         && !commit_bus.lane0.exception_valid);
                end else begin
                    entries[reset_idx].valid <= 1'b0;
                end
            end

            if (memory_request_reg_valid && memory_request_reg.is_store
                && !mem_request_ready)
                memory_request_reg_valid <= 1'b1;
            else
                memory_request_reg_valid <= 1'b0;
        end else begin
            // ── 正常路径 ──
            // occupancy 内嵌更新：加上每拍入住数，减去释放数。
            // commit_store_count 每拍递增，确保每个 Store 获得唯一顺序号。
            occupancy <= occupancy + COUNT_WIDTH'(enq_count)
                                   - COUNT_WIDTH'(remove_count);
            store_commit_tail <= store_commit_tail
                               + STORE_SEQ_WIDTH'(commit_store_count);
            if (memory_request_reg_valid && mem_request_ready
                && memory_request_reg.is_store)
                store_drain_head <= store_drain_head + 1'b1;

            // ── ① 写回广播唤醒 + commit 标记（8 项并行） ──
            // 每拍对所有有效条目并行做：
            //   a) 检查 CDB 端口是否命中 src1 / src2 → 标记就绪
            //      Store 数据命中 src2 时直接捕获写入数据
            //   b) 检查 commit_fire 是否命中本条目 → 标记 committed + 分配 store_seq
            //      （异常 Store 不标记——异常导致恢复，条目将被清除）
            for (reset_idx = 0; reset_idx < DEPTH; reset_idx = reset_idx + 1) begin
                if (entries[reset_idx].valid) begin
                    if (wakeup_match(entries[reset_idx].payload.uop.prs1))
                        entries[reset_idx].src1_ready <= 1'b1;
                    if (wakeup_match(entries[reset_idx].payload.uop.prs2)) begin
                        entries[reset_idx].src2_ready <= 1'b1;
                        if (is_store_entry(entries[reset_idx])) begin
                            entries[reset_idx].store_data_valid <= 1'b1;
                            entries[reset_idx].store_data
                                <= wakeup_data(entries[reset_idx].payload.uop.prs2);
                        end
                    end
                    if (commit_fire[0] && commit_bus.lane0.is_store
                        && !commit_bus.lane0.exception_valid
                        && (commit_bus.lane0.tag == entries[reset_idx].payload.rob_tag)) begin
                        entries[reset_idx].committed <= 1'b1;
                        entries[reset_idx].store_seq <= store_commit_tail;
                    end
                    if (commit_fire[1] && commit_bus.lane1.is_store
                        && !commit_bus.lane1.exception_valid
                        && (commit_bus.lane1.tag == entries[reset_idx].payload.rob_tag)) begin
                        entries[reset_idx].committed <= 1'b1;
                        entries[reset_idx].store_seq <= store_commit_tail
                                                     + STORE_SEQ_WIDTH'(
                                                         commit_fire[0]
                                                         && commit_bus.lane0.is_store
                                                         && !commit_bus.lane0.exception_valid);
                    end
                end
            end

            // ── ③ AGU 握手 + hold 管理 ──
            // AGU 地址生成请求通过 issue1_arbiter 竞争后握手。
            // 如果 hold 中有条目，优先处理 hold 条目；否则使用组合选择的候选。
            // hold 中的条目一旦握手成功，立即标记 address_issued。
            if (agu_hold_valid) begin
                if (agu_issue_fire) begin
                    if (entries[agu_hold_idx].valid
                        && (entries[agu_hold_idx].lsq_tag == agu_hold_packet.lsq_tag))
                        entries[agu_hold_idx].address_issued <= 1'b1;
                    agu_hold_valid <= 1'b0;
                end
            end else if (agu_select_valid) begin
                if (agu_issue_fire) begin
                    entries[agu_select_idx].address_issued <= 1'b1;
                end else begin
                    agu_hold_valid  <= 1'b1;
                    agu_hold_idx    <= agu_select_idx;
                    agu_hold_packet <= agu_select_packet;
                end
            end

            // ── ④ AGU 返回处理 ──
            // 地址生成完成，记录结果。同时检查地址对齐，如果 misaligned
            // 则在 LSQ 内部标记异常（不传递给 AGU 异常检测）。
            // tag + generation 双重检查防止误匹配。
            if (agu_result.valid
                && entries[agu_result.lsq_tag[INDEX_WIDTH-1:0]].valid
                && (entries[agu_result.lsq_tag[INDEX_WIDTH-1:0]].lsq_tag
                    == agu_result.lsq_tag)) begin
                entries[agu_result.lsq_tag[INDEX_WIDTH-1:0]].address_issued <= 1'b0;
                entries[agu_result.lsq_tag[INDEX_WIDTH-1:0]].address_valid  <= 1'b1;
                entries[agu_result.lsq_tag[INDEX_WIDTH-1:0]].address
                    <= agu_result.address;
                if (agu_result.store_data_valid) begin
                    entries[agu_result.lsq_tag[INDEX_WIDTH-1:0]].store_data_valid
                        <= 1'b1;
                    entries[agu_result.lsq_tag[INDEX_WIDTH-1:0]].store_data
                        <= agu_result.store_data;
                end
                if (agu_result.exception_valid
                    || address_misaligned(
                        entries[agu_result.lsq_tag[INDEX_WIDTH-1:0]].payload.uop.dec.mem_op,
                        agu_result.address)) begin
                    entries[agu_result.lsq_tag[INDEX_WIDTH-1:0]].exception_valid <= 1'b1;
                    if (agu_result.exception_valid) begin
                        entries[agu_result.lsq_tag[INDEX_WIDTH-1:0]].exc_code
                            <= agu_result.exc_code;
                        entries[agu_result.lsq_tag[INDEX_WIDTH-1:0]].exc_tval
                            <= agu_result.exc_tval;
                    end else begin
                        entries[agu_result.lsq_tag[INDEX_WIDTH-1:0]].exc_code
                            <= is_store_entry(entries[agu_result.lsq_tag[INDEX_WIDTH-1:0]])
                             ? `EXC_STORE_MISALIGNED : `EXC_LOAD_MISALIGNED;
                        entries[agu_result.lsq_tag[INDEX_WIDTH-1:0]].exc_tval
                            <= agu_result.address;
                    end
                end
            end

            // ── ⑤ 内存请求状态机 ──
            // 外部内存请求通过 memory_request_reg 寄存输出。
            //   握手成功 → Store 条目释放 / Load 条目等待响应
            //   寄存器空 + 有选择结果 → 写入寄存器（Load 转发直接返回）
            //
            // Store 的内存请求在握手成功时才释放条目（valid=0），
            // 保证 DMEM 握手中的请求不会丢失。
            if (memory_request_reg_valid && mem_request_ready) begin
                if (memory_request_reg.is_store
                    && entries[memory_request_reg.lsq_tag[INDEX_WIDTH-1:0]].valid
                    && (entries[memory_request_reg.lsq_tag[INDEX_WIDTH-1:0]].lsq_tag
                        == memory_request_reg.lsq_tag))
                    entries[memory_request_reg.lsq_tag[INDEX_WIDTH-1:0]].valid <= 1'b0;
                memory_request_reg_valid <= 1'b0;
            end
            if (memory_select_q_valid) begin
                if (entries[memory_select_q_idx].valid
                    && (entries[memory_select_q_idx].lsq_tag
                        == memory_select_q_tag)) begin
                    entries[memory_select_q_idx].load_data_valid <= 1'b1;
                    entries[memory_select_q_idx].load_data
                        <= memory_forward_data_q;
                end
                memory_select_q_valid <= 1'b0;
            end
            if (!memory_select_q_valid && !memory_request_reg_valid
                && memory_select_valid) begin
                entries[memory_select_idx].memory_requested <= 1'b1;
                if (memory_select_forward) begin
                    memory_select_q_valid  <= 1'b1;
                    memory_select_q_idx    <= memory_select_idx;
                    memory_select_q_tag    <= memory_select_request.lsq_tag;
                    memory_forward_data_q  <= memory_forward_data;
                end else begin
                    memory_request_reg_valid <= 1'b1;
                    memory_request_reg       <= memory_select_request;
                end
            end

            // ── ⑥ 内存响应处理 ──
            // 外部内存读响应返回。tag + generation 双重检查：
            //   必须与当前条目匹配（防止迟到的 Load 响应误匹配到复用后的新条目）。
            // 异常响应直接标记 exception，正常响应写入 load_data。
            // 注意：Store 写请求不产生 response（无数据返回）。
            if (mem_response.valid
                && entries[mem_response.lsq_tag[INDEX_WIDTH-1:0]].valid
                && (entries[mem_response.lsq_tag[INDEX_WIDTH-1:0]].lsq_tag
                    == mem_response.lsq_tag)
                && !is_store_entry(entries[mem_response.lsq_tag[INDEX_WIDTH-1:0]])) begin
                if (mem_response.exception_valid) begin
                    entries[mem_response.lsq_tag[INDEX_WIDTH-1:0]].exception_valid <= 1'b1;
                    entries[mem_response.lsq_tag[INDEX_WIDTH-1:0]].exc_code
                        <= mem_response.exc_code;
                    entries[mem_response.lsq_tag[INDEX_WIDTH-1:0]].exc_tval
                        <= mem_response.exc_tval;
                end else begin
                    entries[mem_response.lsq_tag[INDEX_WIDTH-1:0]].load_data_valid <= 1'b1;
                    entries[mem_response.lsq_tag[INDEX_WIDTH-1:0]].load_data
                        <= format_load_data(
                            entries[mem_response.lsq_tag[INDEX_WIDTH-1:0]].payload.uop.dec.mem_op,
                            entries[mem_response.lsq_tag[INDEX_WIDTH-1:0]].address[1:0],
                            mem_response.read_data);
                end
            end

            // ── ⑦ 完成事件 pending buffer ──
            // completion_pending 是 1 项寄存 buffer，暂存完成事件直到 WB1 握手。
            // 作用：解耦 completion_select（组合）和 writeback_ready（寄存外部），
            // 吸收 WB1 的短暂反压。
            //
            // 注意：Store 的 completion_sent 只标记状态，不释放条目。
            //   Store 条目在内存写请求握手后才释放（见⑤）。
            //   异常完成条目立即释放。
            if (completion_pending_valid && writeback_ready) begin
                if (!completion_pending_is_store || completion_pending_exception) begin
                    if (entries[completion_pending_idx].valid
                        && (entries[completion_pending_idx].lsq_tag
                            == completion_pending_tag))
                        entries[completion_pending_idx].valid <= 1'b0;
                end
                completion_pending_valid <= 1'b0;
            end
            if (!completion_pending_valid && completion_select_valid) begin
                completion_pending_valid <= 1'b1;
                completion_pending_idx   <= completion_select_idx;
                completion_pending_tag   <= entries[completion_select_idx].lsq_tag;
                completion_pending_is_store <= is_store_entry(entries[completion_select_idx]);
                completion_pending_exception <= entries[completion_select_idx].exception_valid;
                completion_pending_bus.rob_tag <= entries[completion_select_idx].payload.rob_tag;
                completion_pending_bus.pdst_valid
                    <= !is_store_entry(entries[completion_select_idx])
                    && !entries[completion_select_idx].exception_valid
                    && entries[completion_select_idx].payload.uop.pdst_valid;
                completion_pending_bus.pdst <= entries[completion_select_idx].payload.uop.pdst;
                completion_pending_bus.data <= entries[completion_select_idx].load_data;
                completion_pending_bus.exception_valid
                    <= entries[completion_select_idx].exception_valid;
                completion_pending_bus.exc_code <= entries[completion_select_idx].exc_code;
                completion_pending_bus.exc_tval <= entries[completion_select_idx].exc_tval;
                entries[completion_select_idx].completion_sent <= 1'b1;
            end

            // ── ⑧ 新入队 ──
            // Dispatch 送来的新指令写入空闲槽位。入队时：
            //   1. generation 递增（下次复用此槽时 tag 不同）
            //   2. 整条目清 0 后逐个字段赋值（确保旧数据的遗留位被清理）
            //   3. src1_ready / src2_ready 使用三重判断：
            //      ① 不使用该源 → ready
            //      ② Rename 快照（src1_ready from Busy Table）
            //      ③ 本拍 CDB 广播命中 → ready（当拍唤醒）
            //   4. Store 且 src2 本拍命中 CDB → 直接捕获 store_data
            // 入队放在时序块最后，保证其他更新（CDB 唤醒、AGU 返回等）
            // 不会因为入队块对整条目的 '0 赋值而被意外清除。
            if (enq_fire[0]) begin
                slot_generation[free_idx0] <= slot_generation[free_idx0] + 1'b1;
                entries[free_idx0] <= '0;
                entries[free_idx0].valid   <= 1'b1;
                entries[free_idx0].lsq_tag <= {
                    slot_generation[free_idx0] + 1'b1, free_idx0};
                entries[free_idx0].payload <= enq_bus.lane0;
                entries[free_idx0].src1_ready <= !enq_bus.lane0.uop.dec.use_rs1
                                              || enq_bus.lane0.uop.src1_ready
                                              || wakeup_match(enq_bus.lane0.uop.prs1);
                entries[free_idx0].src2_ready <= !enq_bus.lane0.uop.dec.use_rs2
                                              || enq_bus.lane0.uop.src2_ready
                                              || wakeup_match(enq_bus.lane0.uop.prs2);
                if (enq_bus.lane0.uop.dec.mem_write
                    && wakeup_match(enq_bus.lane0.uop.prs2)) begin
                    entries[free_idx0].store_data_valid <= 1'b1;
                    entries[free_idx0].store_data <= wakeup_data(enq_bus.lane0.uop.prs2);
                end
            end
            if (enq_fire[1]) begin
                slot_generation[free_idx1] <= slot_generation[free_idx1] + 1'b1;
                entries[free_idx1] <= '0;
                entries[free_idx1].valid   <= 1'b1;
                entries[free_idx1].lsq_tag <= {
                    slot_generation[free_idx1] + 1'b1, free_idx1};
                entries[free_idx1].payload <= enq_bus.lane1;
                entries[free_idx1].src1_ready <= !enq_bus.lane1.uop.dec.use_rs1
                                              || enq_bus.lane1.uop.src1_ready
                                              || wakeup_match(enq_bus.lane1.uop.prs1);
                entries[free_idx1].src2_ready <= !enq_bus.lane1.uop.dec.use_rs2
                                              || enq_bus.lane1.uop.src2_ready
                                              || wakeup_match(enq_bus.lane1.uop.prs2);
                if (enq_bus.lane1.uop.dec.mem_write
                    && wakeup_match(enq_bus.lane1.uop.prs2)) begin
                    entries[free_idx1].store_data_valid <= 1'b1;
                    entries[free_idx1].store_data <= wakeup_data(enq_bus.lane1.uop.prs2);
                end
            end
        end
    end

    // ══════════════════════════════════════════════════════════════════════════
    // 仿真断言（不在综合范围内）
    // ══════════════════════════════════════════════════════════════════════════
    // - 入队前缀约束（lane1 必须 lane0 同拍入队）
    // - 响应条目与 tag 匹配的检查已在主状态中硬编码，不重复断言
`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
        if (rst_n && !recover.valid) begin
            assert (!enq_valid[1] || enq_valid[0])
                else $error("lsq: enqueue lane1 requires lane0");
        end
    end
`endif

endmodule
