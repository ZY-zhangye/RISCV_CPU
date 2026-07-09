// Simple SoC address router.
//
// V1 keeps the CPU memory boundary typed and uses fixed address windows:
// - RAM:  0x8010_0000..0x8013_FFFF
// - MMIO: 0x8020_0000..0x8020_00FF
// Loads to invalid addresses return an error response. Invalid stores are
// accepted and recorded in sticky_store_error_o; precise store access faults are
// left for a later CSR/commit extension.
import core_types_pkg::*;

module soc_addr_router #(
    parameter logic [XLEN-1:0] RAM_BASE  = 32'h8010_0000,
    parameter logic [XLEN-1:0] RAM_SIZE  = 32'h0004_0000,
    parameter logic [XLEN-1:0] MMIO_BASE = 32'h8020_0000,
    parameter logic [XLEN-1:0] MMIO_SIZE = 32'h0000_0100
) (
    input  logic                         clk_i,
    input  logic                         rst_i,

    input  load_mem_req_t                core_load_req_i,
    output logic                         core_load_req_ready_o,
    output load_mem_resp_t               core_load_resp_o,
    input  logic                         core_load_resp_ready_i,

    input  store_mem_req_t               core_store_req_i,
    output logic                         core_store_req_ready_o,

    output load_mem_req_t                ram_load_req_o,
    input  logic                         ram_load_req_ready_i,
    input  load_mem_resp_t               ram_load_resp_i,
    output logic                         ram_load_resp_ready_o,

    output store_mem_req_t               ram_store_req_o,
    input  logic                         ram_store_req_ready_i,

    output logic                         periph_req_valid_o,
    input  logic                         periph_req_ready_i,
    output logic                         periph_req_write_o,
    output logic [XLEN-1:0]              periph_req_addr_o,
    output logic [XLEN-1:0]              periph_req_wdata_o,
    output logic [3:0]                   periph_req_wstrb_o,
    input  logic                         periph_resp_valid_i,
    input  logic [XLEN-1:0]              periph_resp_rdata_i,
    input  logic                         periph_resp_error_i,

    output logic                         sticky_store_error_o,
    output logic                         mmio_busy_o
);

  typedef enum logic [1:0] {
    MMIO_IDLE,
    MMIO_LOAD_WAIT,
    MMIO_STORE_WAIT
  } mmio_state_t;

  mmio_state_t mmio_state_q;

  logic mmio_req_valid_q;
  logic mmio_req_write_q;
  logic [XLEN-1:0] mmio_req_addr_q;
  logic [XLEN-1:0] mmio_req_wdata_q;
  logic [3:0] mmio_req_wstrb_q;
  logic [LQ_ID_W-1:0] mmio_req_lq_id_q;

  load_mem_resp_t held_resp_q;
  logic held_resp_valid_q;

  logic core_load_is_ram;
  logic core_load_is_mmio;
  logic core_load_is_bad;
  logic core_store_is_ram;
  logic core_store_is_mmio;
  logic core_store_is_bad;
  logic can_accept_mmio;
  logic take_mmio_load;
  logic take_mmio_store;
  logic held_resp_fire;
  logic mmio_req_fire;
  store_mem_req_t ram_store_req_q;
  logic ram_store_req_valid_q;
  logic ram_store_fire;
  logic ram_store_accept;
  logic take_ram_store;
  logic block_ram_load;

  function automatic logic in_window(
      input logic [XLEN-1:0] addr,
      input logic [XLEN-1:0] base,
      input logic [XLEN-1:0] size
  );
    logic [XLEN-1:0] offset;
    begin
      offset = addr - base;
      in_window = (addr >= base) && (offset < size);
    end
  endfunction

  assign core_load_is_ram = core_load_req_i.valid &&
                            in_window(core_load_req_i.address,
                                      RAM_BASE, RAM_SIZE);
  assign core_load_is_mmio = core_load_req_i.valid &&
                             in_window(core_load_req_i.address,
                                       MMIO_BASE, MMIO_SIZE);
  assign core_load_is_bad = core_load_req_i.valid &&
                            !core_load_is_ram && !core_load_is_mmio;

  assign core_store_is_ram = core_store_req_i.valid &&
                             in_window(core_store_req_i.address,
                                       RAM_BASE, RAM_SIZE);
  assign core_store_is_mmio = core_store_req_i.valid &&
                              in_window(core_store_req_i.address,
                                        MMIO_BASE, MMIO_SIZE);
  assign core_store_is_bad = core_store_req_i.valid &&
                             !core_store_is_ram && !core_store_is_mmio;

  assign can_accept_mmio = (mmio_state_q == MMIO_IDLE) &&
                           !mmio_req_valid_q && !held_resp_valid_q;
  assign take_mmio_store = core_store_is_mmio && can_accept_mmio;
  assign take_mmio_load = core_load_is_mmio && can_accept_mmio &&
                          !core_store_is_mmio;
  assign held_resp_fire = held_resp_valid_q && core_load_resp_ready_i;
  assign mmio_req_fire = mmio_req_valid_q && periph_req_ready_i;
  assign ram_store_fire = ram_store_req_valid_q && ram_store_req_ready_i;
  assign ram_store_accept = !ram_store_req_valid_q || ram_store_fire;
  assign take_ram_store = core_store_is_ram && ram_store_accept;
  assign block_ram_load = ram_store_req_valid_q;

  assign periph_req_valid_o = mmio_req_valid_q;
  assign periph_req_write_o = mmio_req_write_q;
  assign periph_req_addr_o = mmio_req_addr_q;
  assign periph_req_wdata_o = mmio_req_wdata_q;
  assign periph_req_wstrb_o = mmio_req_wstrb_q;
  assign mmio_busy_o = mmio_req_valid_q || (mmio_state_q != MMIO_IDLE) ||
                       held_resp_valid_q;

  always_comb begin
    ram_load_req_o = '0;
    ram_store_req_o = ram_store_req_q;
    ram_store_req_o.valid = ram_store_req_valid_q;
    core_load_req_ready_o = 1'b0;
    core_store_req_ready_o = 1'b0;
    ram_load_resp_ready_o = 1'b0;

    core_load_resp_o = held_resp_valid_q ? held_resp_q : ram_load_resp_i;

    if (core_load_is_ram && !block_ram_load) begin
      ram_load_req_o = core_load_req_i;
      core_load_req_ready_o = ram_load_req_ready_i && !held_resp_valid_q;
    end else if (core_load_is_mmio) begin
      core_load_req_ready_o = take_mmio_load && !block_ram_load;
    end else if (core_load_is_bad) begin
      core_load_req_ready_o = !held_resp_valid_q && !block_ram_load;
    end

    if (core_store_is_ram) begin
      core_store_req_ready_o = ram_store_accept;
    end else if (core_store_is_mmio) begin
      core_store_req_ready_o = take_mmio_store;
    end else if (core_store_is_bad) begin
      core_store_req_ready_o = 1'b1;
    end

    ram_load_resp_ready_o = ram_load_resp_i.valid && !held_resp_valid_q &&
                            core_load_resp_ready_i;
  end

  always_ff @(posedge clk_i) begin
    if (rst_i) begin
      mmio_state_q <= MMIO_IDLE;
      mmio_req_valid_q <= 1'b0;
      mmio_req_write_q <= 1'b0;
      mmio_req_addr_q <= '0;
      mmio_req_wdata_q <= '0;
      mmio_req_wstrb_q <= '0;
      mmio_req_lq_id_q <= '0;
      ram_store_req_q <= '0;
      ram_store_req_valid_q <= 1'b0;
      held_resp_q <= '0;
      held_resp_valid_q <= 1'b0;
      sticky_store_error_o <= 1'b0;
    end else begin
      if (ram_store_fire)
        ram_store_req_valid_q <= 1'b0;

      if (take_ram_store) begin
        ram_store_req_q <= core_store_req_i;
        ram_store_req_valid_q <= 1'b1;
      end

      if (held_resp_fire) begin
        held_resp_valid_q <= 1'b0;
        held_resp_q <= '0;
      end

      if (take_mmio_store) begin
        mmio_req_valid_q <= 1'b1;
        mmio_req_write_q <= 1'b1;
        mmio_req_addr_q <= core_store_req_i.address;
        mmio_req_wdata_q <= core_store_req_i.data;
        mmio_req_wstrb_q <= core_store_req_i.byte_enable;
        mmio_req_lq_id_q <= '0;
      end else if (take_mmio_load) begin
        mmio_req_valid_q <= 1'b1;
        mmio_req_write_q <= 1'b0;
        mmio_req_addr_q <= core_load_req_i.address;
        mmio_req_wdata_q <= '0;
        mmio_req_wstrb_q <= '0;
        mmio_req_lq_id_q <= core_load_req_i.lq_id;
      end

      if (mmio_req_fire) begin
        mmio_req_valid_q <= 1'b0;
        mmio_state_q <= mmio_req_write_q ? MMIO_STORE_WAIT : MMIO_LOAD_WAIT;
      end

      if (core_load_is_bad && core_load_req_ready_o) begin
        held_resp_q.valid <= 1'b1;
        held_resp_q.lq_id <= core_load_req_i.lq_id;
        held_resp_q.data <= '0;
        held_resp_q.error <= 1'b1;
        held_resp_valid_q <= 1'b1;
      end

      if (core_store_is_bad && core_store_req_ready_o)
        sticky_store_error_o <= 1'b1;

      unique case (mmio_state_q)
        MMIO_IDLE: begin
        end
        MMIO_LOAD_WAIT: begin
          if (periph_resp_valid_i) begin
            held_resp_q.valid <= 1'b1;
            held_resp_q.lq_id <= mmio_req_lq_id_q;
            held_resp_q.data <= periph_resp_rdata_i;
            held_resp_q.error <= periph_resp_error_i;
            held_resp_valid_q <= 1'b1;
            mmio_state_q <= MMIO_IDLE;
          end
        end
        MMIO_STORE_WAIT: begin
          if (periph_resp_valid_i) begin
            if (periph_resp_error_i)
              sticky_store_error_o <= 1'b1;
            mmio_state_q <= MMIO_IDLE;
          end
        end
        default: mmio_state_q <= MMIO_IDLE;
      endcase
    end
  end

`ifndef SYNTHESIS
  always_ff @(posedge clk_i) begin
    if (!rst_i) begin
      if ($past(periph_req_valid_o && !periph_req_ready_i)) begin
        assert (periph_req_valid_o);
        assert ($stable(periph_req_write_o));
        assert ($stable(periph_req_addr_o));
        assert ($stable(periph_req_wdata_o));
        assert ($stable(periph_req_wstrb_o));
      end

      if (ram_load_resp_i.valid && held_resp_valid_q)
        assert (!ram_load_resp_ready_o)
          else $error("soc_addr_router accepted RAM response while holding one");
    end
  end
`endif

endmodule
