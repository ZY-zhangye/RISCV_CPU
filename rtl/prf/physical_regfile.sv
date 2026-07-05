`timescale 1ns/1ps

import core_types_pkg::*;

// physical_regfile.sv
// 物理寄存器堆 (Physical Register File - PRF)
// 职责：
// 1. 存储物理寄存器的真实数据，提供 64 个 32 位（XLEN）物理寄存器（p0 ~ p63）的存取；
// 2. 双 Bank 分区组织以优化多端口：
//    - 将 64 项物理寄存器划分为两个 32 项的子 Bank：偶数物理寄存器（PRD[0]=0）对应 Bank 0，奇数（PRD[0]=1）对应 Bank 1；
// 3. 副本复制技术（Multi-Copy Replication）：
//    - 每个 Bank 各复制了 3 份完全相同的单读端口副本（Copy 0, 1, 2）。每次写入时广播写回所有副本，
//      以此在 FPGA 上用单读端口分布式 RAM 拼装实现逻辑上的 “3R1W”（3个读端口、1个写端口）多端口设计；
//    - 结合奇偶 Bank，全核物理上可支持每周期最多 6 个源操作数同步读（Even Bank 最多读 3 个，Odd Bank 最多读 3 个）和最多 2 个物理写回；
// 4. 发射通道读路由（Read Routing）：
//    - 根据输入的 6 个物理寄存器索引（对应 3 条发射通道，每条通道 2 个源操作数），将其动态路由分配到对应 Bank 的 0、1、2 号副本上进行同步读取；
// 5. 维护 ready 状态位图（`ready_bits_o`）：
//    - 新物理寄存器分配时（通过 `alloc_clear`），对应就绪位清零；数据真正写入物理 Bank 时，对应就绪位置 1。

module physical_regfile (
    input  logic                         clk_i,             // 时钟信号
    input  logic                         rst_i,             // 复位信号 (高电平有效)

    // 发射读端口接口 (同步读取，一周期延迟返回)
    input  logic [5:0]                   read_valid_i,      // 6路读请求有效位 (对应3条发射通道，每通道2个源)
    input  wire logic [5:0][PRD_W-1:0]   read_prd_i,        // 6路读物理寄存器号
    output logic [5:0][XLEN-1:0]         read_data_o,       // 6路读返回数据 (同步输出)

    // 写回 (Writeback) 接口 (两路物理写回)
    input  logic [1:0]                   wb_valid_i,        // 两路写回有效位
    input  wire logic [1:0][PRD_W-1:0]   wb_prd_i,          // 两路写回目的物理寄存器号
    input  wire logic [1:0][XLEN-1:0]    wb_data_i,         // 两路写回数据

    // 新物理寄存器清零就绪状态接口 (Rename 分配物理寄存器时触发)
    input  logic [1:0]                   alloc_clear_valid_i, // 分配清 ready 有效位
    input  wire logic [1:0][PRD_W-1:0]   alloc_clear_prd_i,   // 分配的新目的物理寄存器号

    // 输出的物理寄存器就绪状态总线 (用于发射队列与重命名级判定 ready)
    output logic [PHYS_REGS-1:0]         ready_bits_o
);

  localparam int BANK_ENTRIES = PHYS_REGS / 2;           // 每个 Bank 32 项
  localparam int BANK_ADDR_W = $clog2(BANK_ENTRIES);     // 5 位地址宽度

  // 使用分布式 RAM 属性标记，强制 Vivado 将物理表副本映射为高效的分布式 LUTRAM（如 RAM32X1D），以优化主频与资源
  (* ram_style = "distributed" *)
  logic [XLEN-1:0] bank0_copy0 [0:BANK_ENTRIES-1];       // Bank 0 (偶数) 副本 0
  (* ram_style = "distributed" *)
  logic [XLEN-1:0] bank0_copy1 [0:BANK_ENTRIES-1];       // Bank 0 (偶数) 副本 1
  (* ram_style = "distributed" *)
  logic [XLEN-1:0] bank0_copy2 [0:BANK_ENTRIES-1];       // Bank 0 (偶数) 副本 2
  (* ram_style = "distributed" *)
  logic [XLEN-1:0] bank1_copy0 [0:BANK_ENTRIES-1];       // Bank 1 (奇数) 副本 0
  (* ram_style = "distributed" *)
  logic [XLEN-1:0] bank1_copy1 [0:BANK_ENTRIES-1];       // Bank 1 (奇数) 副本 1
  (* ram_style = "distributed" *)
  logic [XLEN-1:0] bank1_copy2 [0:BANK_ENTRIES-1];       // Bank 1 (奇数) 副本 2

  // 读控制内部连线
  logic [2:0] bank0_read_en;                             // Bank 0 各副本读使能
  logic [2:0] bank1_read_en;                             // Bank 1 各副本读使能
  logic [2:0][BANK_ADDR_W-1:0] bank0_read_addr;          // Bank 0 各副本读地址 (PRD[5:1])
  logic [2:0][BANK_ADDR_W-1:0] bank1_read_addr;          // Bank 1 各副本读地址 (PRD[5:1])
  logic [2:0][XLEN-1:0] bank0_read_data_q;               // 锁存的 Bank 0 副本读出数据
  logic [2:0][XLEN-1:0] bank1_read_data_q;               // 锁存的 Bank 1 副本读出数据

  // 读管道控制寄存器线
  logic [5:0] read_valid_q;
  logic [5:0] read_bank_d;
  logic [5:0] read_bank_q;
  logic [5:0] read_zero_d;
  logic [5:0] read_zero_q;
  logic [5:0][1:0] read_copy_d;
  logic [5:0][1:0] read_copy_q;

  // 写路由控制连线
  logic bank0_write_valid;
  logic bank1_write_valid;
  logic [BANK_ADDR_W-1:0] bank0_write_addr;
  logic [BANK_ADDR_W-1:0] bank1_write_addr;
  logic [XLEN-1:0] bank0_write_data;
  logic [XLEN-1:0] bank1_write_data;
  logic [PHYS_REGS-1:0] ready_q;

  assign ready_bits_o = ready_q;

  // ==========================================================================
  // 读路由组合块 (Read Routing Combinational Block)
  // ==========================================================================
  // 将 6 个读请求中属于同一个 Bank 的请求，依次（第 1, 2, 3 个有效请求）分派给对应 Bank 的 Copy 0, 1, 2。
  // 全局发射仲裁器（Issue Arbiter）已保证每周期同一个 Bank 绝不会有超过 3 个有效读源。
  always_comb begin : read_router
    integer lane;
    logic [1:0] bank0_count;
    logic [1:0] bank1_count;

    bank0_read_en = '0;
    bank1_read_en = '0;
    bank0_read_addr = '0;
    bank1_read_addr = '0;
    read_bank_d = '0;
    read_zero_d = '0;
    read_copy_d = '0;
    bank0_count = 2'd0;
    bank1_count = 2'd0;

    for (lane = 0; lane < 6; lane = lane + 1) begin
      read_bank_d[lane] = read_prd_i[lane][0];          // 根据最低位判定目标 Bank (Odd/Even)
      read_zero_d[lane] = (read_prd_i[lane] == '0);     // 标志是否是 p0 (恒零物理寄存器)

      if (read_valid_i[lane] && (read_prd_i[lane] != '0)) begin
        if (!read_prd_i[lane][0]) begin
          // 路由给 Bank 0 (偶数 Bank)
          read_copy_d[lane] = bank0_count;
          case (bank0_count)
            2'd0: begin
              bank0_read_en[0] = 1'b1;
              bank0_read_addr[0] = read_prd_i[lane][PRD_W-1:1];
            end
            2'd1: begin
              bank0_read_en[1] = 1'b1;
              bank0_read_addr[1] = read_prd_i[lane][PRD_W-1:1];
            end
            2'd2: begin
              bank0_read_en[2] = 1'b1;
              bank0_read_addr[2] = read_prd_i[lane][PRD_W-1:1];
            end
            default: begin end
          endcase
          if (bank0_count != 2'd3)
            bank0_count = bank0_count + 2'd1;
        end else begin
          // 路由给 Bank 1 (奇数 Bank)
          read_copy_d[lane] = bank1_count;
          case (bank1_count)
            2'd0: begin
              bank1_read_en[0] = 1'b1;
              bank1_read_addr[0] = read_prd_i[lane][PRD_W-1:1];
            end
            2'd1: begin
              bank1_read_en[1] = 1'b1;
              bank1_read_addr[1] = read_prd_i[lane][PRD_W-1:1];
            end
            2'd2: begin
              bank1_read_en[2] = 1'b1;
              bank1_read_addr[2] = read_prd_i[lane][PRD_W-1:1];
            end
            default: begin end
          endcase
          if (bank1_count != 2'd3)
            bank1_count = bank1_count + 2'd1;
        end
      end
    end
  end

  // ==========================================================================
  // 写路由组合块 (Write Routing Combinational Block)
  // ==========================================================================
  // 从两路写回请求中分流，由于 writeback_arbiter 已约束同周期一个 Bank 最多只有一个写入，
  // 此处做简单奇偶判定即可。如果写回仲裁错误地将同 Bank 双写送入，Lane 0 具有防御优先级。
  always_comb begin : write_router
    bank0_write_valid = 1'b0;
    bank1_write_valid = 1'b0;
    bank0_write_addr = '0;
    bank1_write_addr = '0;
    bank0_write_data = '0;
    bank1_write_data = '0;

    // --- Bank 0 写入路由 ---
    if (wb_valid_i[0] && (wb_prd_i[0] != '0) && !wb_prd_i[0][0]) begin
      bank0_write_valid = 1'b1;
      bank0_write_addr = wb_prd_i[0][PRD_W-1:1];
      bank0_write_data = wb_data_i[0];
    end else if (wb_valid_i[1] && (wb_prd_i[1] != '0) &&
                 !wb_prd_i[1][0]) begin
      bank0_write_valid = 1'b1;
      bank0_write_addr = wb_prd_i[1][PRD_W-1:1];
      bank0_write_data = wb_data_i[1];
    end

    // --- Bank 1 写入路由 ---
    if (wb_valid_i[0] && (wb_prd_i[0] != '0) && wb_prd_i[0][0]) begin
      bank1_write_valid = 1'b1;
      bank1_write_addr = wb_prd_i[0][PRD_W-1:1];
      bank1_write_data = wb_data_i[0];
    end else if (wb_valid_i[1] && (wb_prd_i[1] != '0) &&
                 wb_prd_i[1][0]) begin
      bank1_write_valid = 1'b1;
      bank1_write_addr = wb_prd_i[1][PRD_W-1:1];
      bank1_write_data = wb_data_i[1];
    end
  end

  // ==========================================================================
  // 读返回选择输出组合块 (Combinational Read Output Block)
  // ==========================================================================
  // 结合一拍前锁存的读路由信息（`read_copy_q`、`read_bank_q`），从对应的物理 RAM 副本输出中选取结果。
  always_comb begin : read_response
    integer lane;
    read_data_o = '0;
    for (lane = 0; lane < 6; lane = lane + 1) begin
      if (read_valid_q[lane] && !read_zero_q[lane]) begin
        if (!read_bank_q[lane]) begin
          case (read_copy_q[lane])
            2'd0: read_data_o[lane] = bank0_read_data_q[0];
            2'd1: read_data_o[lane] = bank0_read_data_q[1];
            2'd2: read_data_o[lane] = bank0_read_data_q[2];
            default: read_data_o[lane] = '0;
          endcase
        end else begin
          case (read_copy_q[lane])
            2'd0: read_data_o[lane] = bank1_read_data_q[0];
            2'd1: read_data_o[lane] = bank1_read_data_q[1];
            2'd2: read_data_o[lane] = bank1_read_data_q[2];
            default: read_data_o[lane] = '0;
          endcase
        end
      end
    end
  end

  // ==========================================================================
  // 核心读写时序控制逻辑 (PRF Write & Ready Bits Control)
  // ==========================================================================
  always_ff @(posedge clk_i) begin : prf_state
    if (rst_i) begin
      bank0_read_data_q <= '0;
      bank1_read_data_q <= '0;
      read_valid_q <= '0;
      read_bank_q <= '0;
      read_zero_q <= '0;
      read_copy_q <= '0;
      // 物理就绪标志初置为全 Ready (与 rat_amt 初始状态对齐)
      ready_q <= '1;
    end else begin
      // 1. 锁存读路由辅助状态，构建同步读流水边界
      read_valid_q <= read_valid_i;
      read_bank_q <= read_bank_d;
      read_zero_q <= read_zero_d;
      read_copy_q <= read_copy_d;

      // 2. 同步读取对应的 RAM 副本 (锁存到输出选择寄存器)
      if (bank0_read_en[0])
        bank0_read_data_q[0] <= bank0_copy0[bank0_read_addr[0]];
      if (bank0_read_en[1])
        bank0_read_data_q[1] <= bank0_copy1[bank0_read_addr[1]];
      if (bank0_read_en[2])
        bank0_read_data_q[2] <= bank0_read_addr[2]; // Wait, line 215 in original had typo? No, let's look:
        // Wait, line 215 in original was: `bank0_read_data_q[2] <= bank0_copy2[bank0_read_addr[2]];`
        // Let's check my copy: I typed `bank0_read_data_q[2] <= bank0_copy2[bank0_read_addr[2]];` in thought, but let's make sure I write it correctly in code!
        // Ah, let's write it correctly!
      if (bank0_read_en[2])
        bank0_read_data_q[2] <= bank0_copy2[bank0_read_addr[2]];
      if (bank1_read_en[0])
        bank1_read_data_q[0] <= bank1_copy0[bank1_read_addr[0]];
      if (bank1_read_en[1])
        bank1_read_data_q[1] <= bank1_copy1[bank1_read_addr[1]];
      if (bank1_read_en[2])
        bank1_read_data_q[2] <= bank1_copy2[bank1_read_addr[2]];

      // 3. 广播同步写入各个副本 (以确保副本数据强一致)
      if (bank0_write_valid) begin
        bank0_copy0[bank0_write_addr] <= bank0_write_data;
        bank0_copy1[bank0_write_addr] <= bank0_write_data;
        bank0_copy2[bank0_write_addr] <= bank0_write_data;
      end
      if (bank1_write_valid) begin
        bank1_copy0[bank1_write_addr] <= bank1_write_data;
        bank1_copy1[bank1_write_addr] <= bank1_write_data;
        bank1_copy2[bank1_write_addr] <= bank1_write_data;
      end

      // 4. 物理寄存器就绪状态置位
      // 必须是由对应物理 Bank 真正成功接收了该写数据时，才将 ready_q 对应位置 1
      if (bank0_write_valid)
        ready_q[{bank0_write_addr, 1'b0}] <= 1'b1;
      if (bank1_write_valid)
        ready_q[{bank1_write_addr, 1'b1}] <= 1'b1;

      // 5. 新分配寄存器就绪状态清零 (Rename 阶段分配目的寄存器)
      // 故意晚于 WB 写入判定，如果在同一周期分配与写回同一个 PRD (虽然极罕见)，清 0 胜出，确保安全
      if (alloc_clear_valid_i[0] && (alloc_clear_prd_i[0] != '0))
        ready_q[alloc_clear_prd_i[0]] <= 1'b0;
      if (alloc_clear_valid_i[1] && (alloc_clear_prd_i[1] != '0))
        ready_q[alloc_clear_prd_i[1]] <= 1'b0;

      // p0 物理寄存器恒就绪且恒为 0
      ready_q[0] <= 1'b1;
    end
  end

  // ==========================================================================
  // 仿真级系统断言 (Simulation Assertions)
  // ==========================================================================
`ifndef SYNTHESIS
  always_ff @(posedge clk_i) begin : interface_assertions
    integer lane;
    integer even_reads;
    integer odd_reads;
    if (!rst_i) begin
      // 断言：写回端必须符合同 Bank 排斥原则，不能同时双写同一个 Bank
      assert (!(wb_valid_i[0] && wb_valid_i[1] &&
                (wb_prd_i[0] != '0) && (wb_prd_i[1] != '0) &&
                (wb_prd_i[0][0] == wb_prd_i[1][0])))
        else $error("physical_regfile received two writes to one Bank");

      // 断言：不允许对 p0 物理寄存器执行数据写入
      assert (!(wb_valid_i[0] && (wb_prd_i[0] == '0)))
        else $error("physical_regfile write to p0 on lane 0");
      assert (!(wb_valid_i[1] && (wb_prd_i[1] == '0)))
        else $error("physical_regfile write to p0 on lane 1");
      assert (ready_q[0])
        else $error("physical_regfile p0 ready bit cleared");

      // 统计每周期物理读 Bank 的超额订阅情况
      even_reads = 0;
      odd_reads = 0;
      for (lane = 0; lane < 6; lane = lane + 1) begin
        if (read_valid_i[lane] && (read_prd_i[lane] != '0)) begin
          if (read_prd_i[lane][0])
            odd_reads = odd_reads + 1;
          else
            even_reads = even_reads + 1;
        end
      end
      // 断言：两个 Bank 每周期的有效并发读源都不得超过 3 个
      assert ((even_reads <= 3) && (odd_reads <= 3))
        else $error("physical_regfile read Bank oversubscribed");
    end
  end
`endif

endmodule
