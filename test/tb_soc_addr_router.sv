import core_types_pkg::*;

module tb_soc_addr_router;
  timeunit 1ns;
  timeprecision 1ps;

  logic clk_i = 1'b0;
  logic rst_i = 1'b1;

  load_mem_req_t core_load_req_i = '0;
  logic core_load_req_ready_o;
  load_mem_resp_t core_load_resp_o;
  logic core_load_resp_ready_i = 1'b0;

  store_mem_req_t core_store_req_i = '0;
  logic core_store_req_ready_o;

  load_mem_req_t ram_load_req_o;
  logic ram_load_req_ready_i = 1'b0;
  load_mem_resp_t ram_load_resp_i = '0;
  logic ram_load_resp_ready_o;

  store_mem_req_t ram_store_req_o;
  logic ram_store_req_ready_i = 1'b0;

  logic periph_req_valid_o;
  logic periph_req_ready_i = 1'b0;
  logic periph_req_write_o;
  logic [XLEN-1:0] periph_req_addr_o;
  logic [XLEN-1:0] periph_req_wdata_o;
  logic [3:0] periph_req_wstrb_o;
  logic periph_resp_valid_i = 1'b0;
  logic [XLEN-1:0] periph_resp_rdata_i = '0;
  logic periph_resp_error_i = 1'b0;

  logic sticky_store_error_o;
  logic mmio_busy_o;

  soc_addr_router dut (.*);

  always #5 clk_i = ~clk_i;

  task automatic clear_inputs;
    begin
      core_load_req_i = '0;
      core_load_resp_ready_i = 1'b0;
      core_store_req_i = '0;
      ram_load_req_ready_i = 1'b0;
      ram_load_resp_i = '0;
      ram_store_req_ready_i = 1'b0;
      periph_req_ready_i = 1'b0;
      periph_resp_valid_i = 1'b0;
      periph_resp_rdata_i = '0;
      periph_resp_error_i = 1'b0;
    end
  endtask

  task automatic accept_ram_load;
    begin
      @(negedge clk_i);
      core_load_req_i.valid = 1'b1;
      core_load_req_i.lq_id = 3'd3;
      core_load_req_i.address = 32'h8010_0020;
      ram_load_req_ready_i = 1'b1;
      #1;
      if (!core_load_req_ready_o || !ram_load_req_o.valid ||
          ram_load_req_o.lq_id != 3'd3 ||
          ram_load_req_o.address != 32'h8010_0020)
        $fatal(1, "RAM load request passthrough mismatch");
      @(posedge clk_i); #1;
      core_load_req_i = '0;
      ram_load_req_ready_i = 1'b0;

      @(negedge clk_i);
      ram_load_resp_i.valid = 1'b1;
      ram_load_resp_i.lq_id = 3'd3;
      ram_load_resp_i.data = 32'h1234_5678;
      core_load_resp_ready_i = 1'b1;
      #1;
      if (!core_load_resp_o.valid || !ram_load_resp_ready_o ||
          core_load_resp_o.lq_id != 3'd3 ||
          core_load_resp_o.data != 32'h1234_5678)
        $fatal(1, "RAM load response passthrough mismatch");
      @(posedge clk_i); #1;
      ram_load_resp_i = '0;
      core_load_resp_ready_i = 1'b0;
    end
  endtask

  task automatic accept_ram_store;
    begin
      @(negedge clk_i);
      core_store_req_i.valid = 1'b1;
      core_store_req_i.sq_id = 3'd2;
      core_store_req_i.address = 32'h8010_0104;
      core_store_req_i.data = 32'hcafe_beef;
      core_store_req_i.byte_enable = 4'b1100;
      ram_store_req_ready_i = 1'b0;
      #1;
      if (!core_store_req_ready_o || ram_store_req_o.valid)
        $fatal(1, "RAM store buffer accept mismatch");
      @(posedge clk_i); #1;
      core_store_req_i = '0;
      if (!ram_store_req_o.valid ||
          ram_store_req_o.sq_id != 3'd2 ||
          ram_store_req_o.address != 32'h8010_0104 ||
          ram_store_req_o.data != 32'hcafe_beef ||
          ram_store_req_o.byte_enable != 4'b1100)
        $fatal(1, "RAM store request buffer mismatch");
      core_load_req_i.valid = 1'b1;
      core_load_req_i.lq_id = 3'd1;
      core_load_req_i.address = 32'h8010_0200;
      #1;
      if (core_load_req_ready_o || ram_load_req_o.valid)
        $fatal(1, "RAM load accepted while buffered Store is pending");
      core_load_req_i = '0;
      ram_store_req_ready_i = 1'b1;
      #1;
      if (!ram_store_req_o.valid ||
          ram_store_req_o.sq_id != 3'd2 ||
          ram_store_req_o.address != 32'h8010_0104 ||
          ram_store_req_o.data != 32'hcafe_beef ||
          ram_store_req_o.byte_enable != 4'b1100)
        $fatal(1, "RAM store request passthrough mismatch");
      @(posedge clk_i); #1;
      if (ram_store_req_o.valid)
        $fatal(1, "RAM store request did not drain");
      ram_store_req_ready_i = 1'b0;
    end
  endtask

  task automatic accept_mmio_load;
    begin
      @(negedge clk_i);
      core_load_req_i.valid = 1'b1;
      core_load_req_i.lq_id = 3'd5;
      core_load_req_i.address = 32'h8020_0004;
      periph_req_ready_i = 1'b0;
      #1;
      if (!core_load_req_ready_o)
        $fatal(1, "MMIO load was not accepted into router");
      @(posedge clk_i); #1;
      core_load_req_i.valid = 1'b1;
      core_load_req_i.lq_id = 3'd7;
      core_load_req_i.address = 32'h8020_0010;
      if (!periph_req_valid_o || periph_req_write_o ||
          periph_req_addr_o != 32'h8020_0004 || !mmio_busy_o)
        $fatal(1, "MMIO load request latch mismatch");

      repeat (2) begin
        @(posedge clk_i); #1;
        if (!periph_req_valid_o || periph_req_write_o ||
            periph_req_addr_o != 32'h8020_0004)
          $fatal(1, "MMIO load request did not hold under backpressure");
      end

      @(negedge clk_i);
      periph_req_ready_i = 1'b1;
      #1;
      if (!periph_req_valid_o)
        $fatal(1, "MMIO load request disappeared before peripheral ready");
      @(posedge clk_i); #1;
      periph_req_ready_i = 1'b0;
      core_load_req_i = '0;
      if (periph_req_valid_o)
        $fatal(1, "MMIO request valid remained after handshake");

      @(negedge clk_i);
      periph_resp_valid_i = 1'b1;
      periph_resp_rdata_i = 32'hfeed_1234;
      core_load_resp_ready_i = 1'b0;
      @(posedge clk_i); #1;
      periph_resp_valid_i = 1'b0;
      if (!core_load_resp_o.valid ||
          core_load_resp_o.lq_id != 3'd5 ||
          core_load_resp_o.data != 32'hfeed_1234)
        $fatal(1, "MMIO load response latch mismatch");

      repeat (2) begin
        @(posedge clk_i); #1;
        if (!core_load_resp_o.valid ||
            core_load_resp_o.data != 32'hfeed_1234)
          $fatal(1, "MMIO load response did not hold for core");
      end

      @(negedge clk_i);
      core_load_resp_ready_i = 1'b1;
      @(posedge clk_i); #1;
      core_load_resp_ready_i = 1'b0;
      if (core_load_resp_o.valid)
        $fatal(1, "MMIO load response did not clear after ready");
    end
  endtask

  task automatic accept_mmio_store;
    begin
      @(negedge clk_i);
      core_store_req_i.valid = 1'b1;
      core_store_req_i.sq_id = 3'd4;
      core_store_req_i.address = 32'h8020_0040;
      core_store_req_i.data = 32'h5566_7788;
      core_store_req_i.byte_enable = 4'b0011;
      #1;
      if (!core_store_req_ready_o)
        $fatal(1, "MMIO store was not accepted into router");
      @(posedge clk_i); #1;
      core_store_req_i = '0;
      if (!periph_req_valid_o || !periph_req_write_o ||
          periph_req_addr_o != 32'h8020_0040 ||
          periph_req_wdata_o != 32'h5566_7788 ||
          periph_req_wstrb_o != 4'b0011)
        $fatal(1, "MMIO store request latch mismatch");

      @(negedge clk_i);
      periph_req_ready_i = 1'b1;
      @(posedge clk_i); #1;
      periph_req_ready_i = 1'b0;
      @(negedge clk_i);
      periph_resp_valid_i = 1'b1;
      periph_resp_error_i = 1'b1;
      @(posedge clk_i); #1;
      periph_resp_valid_i = 1'b0;
      if (!sticky_store_error_o)
        $fatal(1, "MMIO store error did not set sticky flag");
    end
  endtask

  task automatic mmio_store_priority;
    begin
      @(negedge clk_i);
      core_load_req_i.valid = 1'b1;
      core_load_req_i.lq_id = 3'd1;
      core_load_req_i.address = 32'h8020_0008;
      core_store_req_i.valid = 1'b1;
      core_store_req_i.sq_id = 3'd6;
      core_store_req_i.address = 32'h8020_000c;
      core_store_req_i.data = 32'ha5a5_5a5a;
      core_store_req_i.byte_enable = 4'b1111;
      #1;
      if (core_load_req_ready_o || !core_store_req_ready_o)
        $fatal(1, "MMIO store priority ready mismatch");
      @(posedge clk_i); #1;
      core_load_req_i = '0;
      core_store_req_i = '0;
      if (!periph_req_valid_o || !periph_req_write_o ||
          periph_req_addr_o != 32'h8020_000c)
        $fatal(1, "MMIO store priority payload mismatch");
      @(negedge clk_i);
      periph_req_ready_i = 1'b1;
      @(posedge clk_i); #1;
      periph_req_ready_i = 1'b0;
      @(negedge clk_i);
      periph_resp_valid_i = 1'b1;
      periph_resp_error_i = 1'b0;
      @(posedge clk_i); #1;
      periph_resp_valid_i = 1'b0;
    end
  endtask

  task automatic invalid_accesses;
    begin
      @(negedge clk_i);
      core_load_req_i.valid = 1'b1;
      core_load_req_i.lq_id = 3'd6;
      core_load_req_i.address = 32'h4000_0000;
      core_load_resp_ready_i = 1'b0;
      #1;
      if (!core_load_req_ready_o)
        $fatal(1, "invalid load was not accepted");
      @(posedge clk_i); #1;
      core_load_req_i = '0;
      if (!core_load_resp_o.valid ||
          core_load_resp_o.lq_id != 3'd6 ||
          core_load_resp_o.data != 32'h0000_0000)
        $fatal(1, "invalid load error response mismatch");
      @(negedge clk_i);
      core_load_resp_ready_i = 1'b1;
      @(posedge clk_i); #1;
      core_load_resp_ready_i = 1'b0;

      @(negedge clk_i);
      core_store_req_i.valid = 1'b1;
      core_store_req_i.sq_id = 3'd7;
      core_store_req_i.address = 32'h4000_0004;
      core_store_req_i.data = 32'hdead_beef;
      core_store_req_i.byte_enable = 4'b1111;
      #1;
      if (!core_store_req_ready_o)
        $fatal(1, "invalid store was not accepted");
      @(posedge clk_i); #1;
      core_store_req_i = '0;
      if (!sticky_store_error_o)
        $fatal(1, "invalid store did not set sticky flag");
    end
  endtask

  initial begin
    clear_inputs();
    repeat (2) @(posedge clk_i);
    @(negedge clk_i);
    rst_i = 1'b0;
    @(posedge clk_i); #1;
    if (periph_req_valid_o || mmio_busy_o || sticky_store_error_o ||
        core_load_resp_o.valid)
      $fatal(1, "router reset state mismatch");

    accept_ram_load();
    accept_ram_store();
    accept_mmio_load();
    accept_mmio_store();

    @(negedge clk_i);
    rst_i = 1'b1;
    clear_inputs();
    @(posedge clk_i); #1;
    if (sticky_store_error_o || mmio_busy_o || periph_req_valid_o)
      $fatal(1, "router reset did not clear sticky/busy/request");
    @(negedge clk_i);
    rst_i = 1'b0;
    @(posedge clk_i); #1;

    mmio_store_priority();
    invalid_accesses();

    $display("PASS: soc_addr_router directed tests");
    $finish;
  end

  initial begin
    #200000;
    $fatal(1, "timeout");
  end
endmodule
