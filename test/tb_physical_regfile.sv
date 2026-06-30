`timescale 1ns/1ps

module tb_physical_regfile;
    import core_port_pkg::*;

    logic                       clk;
    logic                       rst_n;
    phys_reg_read_req_bundle_t  read_req;
    phys_reg_read_data_bundle_t read_data;
    phys_reg_write_bundle_t     writeback;

    physical_regfile u_physical_regfile (
        .clk       (clk),
        .rst_n     (rst_n),
        .read_req  (read_req),
        .read_data (read_data),
        .writeback (writeback)
    );

    always #5 clk = ~clk;

    task automatic cycle;
        @(posedge clk);
        #1;
    endtask

    initial begin
        clk       = 1'b0;
        rst_n     = 1'b0;
        read_req  = '0;
        writeback = '0;

        repeat (2) cycle();
        rst_n = 1'b1;

        // 双写入 p1/p2。
        writeback.lane0.valid = 1'b1;
        writeback.lane0.preg  = 6'd1;
        writeback.lane0.data  = 32'h1111_1111;
        writeback.lane1.valid = 1'b1;
        writeback.lane1.preg  = 6'd2;
        writeback.lane1.data  = 32'h2222_2222;
        cycle();

        // 再写 p3/p4。PRF 不做同拍写读前递，因此下一拍再发读取请求。
        writeback.lane0.preg = 6'd3;
        writeback.lane0.data = 32'h3333_3333;
        writeback.lane1.preg = 6'd4;
        writeback.lane1.data = 32'h4444_4444;
        cycle();

        writeback = '0;
        read_req.port0 = '{valid: 1'b1, preg: 6'd1};
        read_req.port1 = '{valid: 1'b1, preg: 6'd2};
        read_req.port2 = '{valid: 1'b1, preg: 6'd3};
        read_req.port3 = '{valid: 1'b1, preg: 6'd4};
        cycle();
        assert (read_data.port0 == 32'h1111_1111
                && read_data.port1 == 32'h2222_2222
                && read_data.port2 == 32'h3333_3333
                && read_data.port3 == 32'h4444_4444)
            else $fatal(1, "four-port synchronous read failed");

        // p0 写入必须被忽略，读取恒为 0；无效读端口保持上次值，供下游
        // operand elastic stage 在反压期间稳定保存同步读结果。
        writeback = '0;
        writeback.lane0.valid = 1'b1;
        writeback.lane0.preg  = '0;
        writeback.lane0.data  = 32'hffff_ffff;
        read_req = '0;
        read_req.port0.valid = 1'b1;
        read_req.port0.preg  = '0;
        cycle();
        assert ((read_data.port0 == '0)
                && (read_data.port1 == 32'h2222_2222))
            else $fatal(1, "p0 zero or disabled-read hold semantics failed");

        // 先建立 p5 的旧值。
        writeback = '0;
        writeback.lane1.valid = 1'b1;
        writeback.lane1.preg  = 6'd5;
        writeback.lane1.data  = 32'h5555_aaaa;
        read_req = '0;
        cycle();

        // 同拍读取并覆盖 p5。PRF 自身不旁路，因此 RTL 同步读得到旧值；
        // 后续 IQ/operand-select 会用随 issue 锁存的广播值替代该读数。
        writeback.lane1.data  = 32'ha5a5_5a5a;
        read_req.port3.valid = 1'b1;
        read_req.port3.preg  = 6'd5;
        cycle();
        assert (read_data.port3 == 32'h5555_aaaa)
            else $fatal(1, "physical register file unexpectedly bypassed writeback");

        // 写入完成后的下一次同步读取应得到新值。
        writeback = '0;
        read_req.port3.valid = 1'b1;
        read_req.port3.preg  = 6'd5;
        cycle();
        assert (read_data.port3 == 32'ha5a5_5a5a)
            else $fatal(1, "written physical register did not retain data");

        $display("PASS: synchronous 4R2W physical register file");
        $finish;
    end

endmodule
