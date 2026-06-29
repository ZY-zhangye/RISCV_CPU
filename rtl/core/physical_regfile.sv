`include "defines.svh"

// =============================================================================
// 64 x 32-bit 物理寄存器堆
//
// - 四个同步读端口：读请求在本拍给出，数据在下一个上升沿更新。
// - 两个同步写端口：对应两组写回通道。
// - p0 永远返回 0，所有对 p0 的写入都会被忽略。
// - 数据阵列不做复位：除 p0 外，RISC-V 不规定复位后的 GPR 内容；省去阵列
//   复位有利于综合工具采用更合适的存储结构。Busy Table 保证未完成值不会被使用。
// - 本模块不实现写回到读口的直接前递。IQ 可以在广播当拍完成唤醒和选择，
//   并将命中的广播数据与 issue 元数据一起锁存；后续操作数选择级在广播值
//   和本模块的同步读数据之间选择。
// - 若两路同时写同一标签，lane1 在 RTL 中优先；这种情况在正常后端中
//   不应发生，并由仿真断言报告。
// =============================================================================
module physical_regfile #(
    parameter int PHYS_REG_COUNT = core_port_pkg::PHYS_REG_COUNT
) (
    input  logic                                      clk,
    input  logic                                      rst_n,
    input  wire core_port_pkg::phys_reg_read_req_bundle_t read_req,
    output      core_port_pkg::phys_reg_read_data_bundle_t read_data,
    input  wire core_port_pkg::phys_reg_write_bundle_t     writeback
);
    import core_port_pkg::*;

    logic [XLEN-1:0] registers [0:PHYS_REG_COUNT-1];

    function automatic logic [XLEN-1:0] read_register(
        input phys_reg_read_req_t req
    );
        logic [XLEN-1:0] value;
        begin
            value = '0;
            if (req.valid && (req.preg != '0))
                value = registers[req.preg];
            read_register = value;
        end
    endfunction

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            read_data <= '0;
        end else begin
            read_data.port0 <= read_register(read_req.port0);
            read_data.port1 <= read_register(read_req.port1);
            read_data.port2 <= read_register(read_req.port2);
            read_data.port3 <= read_register(read_req.port3);

            if (writeback.lane0.valid && (writeback.lane0.preg != '0))
                registers[writeback.lane0.preg] <= writeback.lane0.data;
            if (writeback.lane1.valid && (writeback.lane1.preg != '0))
                registers[writeback.lane1.preg] <= writeback.lane1.data;

        end
    end

`ifndef SYNTHESIS
    always_ff @(posedge clk) begin
        if (rst_n && writeback.lane0.valid && writeback.lane1.valid
            && (writeback.lane0.preg != '0)
            && (writeback.lane0.preg == writeback.lane1.preg))
            $error("physical_regfile: duplicate write to p%0d",
                   writeback.lane0.preg);
    end
`endif

endmodule
