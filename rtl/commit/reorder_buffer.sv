import core_types_pkg::*;

// 32-entry reorder buffer.
// Logical organization is 16 rows x 2 banks; ROB ID encoding is
// {row_index[3:0], bank_id}.  Internally the entry arrays are indexed directly
// by ROB ID to keep writeback/completion paths as direct indexed writes.
//
// V1 timing choice: every non-empty allocation bundle consumes one full row.
// A single-lane allocation leaves bank1 invalid and the next allocation starts
// from the next row.  This trades a little capacity for a simple commit head.
module reorder_buffer (
    input  logic                     clk_i,
    input  logic                     rst_i,

    input  logic [1:0]               alloc_valid_i,
    output logic                     alloc_ready_o,
    output logic [ROB_ID_W-1:0]      alloc_rob_id0_o,
    output logic [ROB_ID_W-1:0]      alloc_rob_id1_o,
    input  rob_alloc_t               alloc_entry0_i,
    input  rob_alloc_t               alloc_entry1_i,

    input  completion_t              complete0_i,
    input  completion_t              complete1_i,

    output logic [1:0]               head_valid_o,
    output rob_entry_t               head_entry0_o,
    output rob_entry_t               head_entry1_o,
    input  logic [1:0]               retire_count_i,

    input  logic                     branch_clear_valid_i,
    input  logic [CP_W-1:0]          branch_clear_id_i,
    output logic                     branch_clear_done_o,

    input  logic                     restore_valid_i,
    input  logic [ROB_ID_W-1:0]      restore_tail_i,
    output logic                     restore_done_o,

    output logic                     busy_o,
    output logic                     empty_o,
    output logic                     full_o,
    output logic [5:0]               occupancy_o
);

  localparam int ROB_ROWS = ROB_ENTRIES / 2;
  localparam int ROB_ROW_W = $clog2(ROB_ROWS);

  logic [ROB_ENTRIES-1:0] valid_q;
  logic [ROB_ENTRIES-1:0] complete_q;
  rob_alloc_t entry_q [0:ROB_ENTRIES-1];

  logic [ROB_ROW_W-1:0] head_row_q;
  logic [ROB_ROW_W-1:0] tail_row_q;
  logic [ROB_ROW_W:0] used_rows_q;
  logic [5:0] occupancy_q;

  rob_entry_t head_entry0_q;
  rob_entry_t head_entry1_q;

  logic scan_busy_q;
  logic scan_restore_q;
  logic [ROB_ROW_W-1:0] scan_row_q;
  logic [CP_W-1:0] scan_branch_id_q;
  logic [ROB_ID_W-1:0] scan_restore_tail_q;
  logic [ROB_ROW_W-1:0] scan_old_tail_row_q;
  logic [ROB_ROW_W:0] scan_used_rows_q;
  logic [5:0] scan_occupancy_q;
  logic branch_clear_done_q;
  logic restore_done_q;

  logic alloc_fire;
  logic alloc_legal;
  logic retire_row_fire;
  logic [1:0] head_row_count;

  function automatic logic [ROB_ROW_W-1:0] rob_id_row(
      input logic [ROB_ID_W-1:0] rob_id
  );
    rob_id_row = rob_id[ROB_ID_W-1:1];
  endfunction

  function automatic logic rob_id_bank(input logic [ROB_ID_W-1:0] rob_id);
    rob_id_bank = rob_id[0];
  endfunction

  function automatic logic [ROB_ID_W-1:0] make_rob_id(
      input logic [ROB_ROW_W-1:0] row,
      input logic                 bank
  );
    make_rob_id = {row, bank};
  endfunction

  function automatic logic [ROB_ROW_W-1:0] next_row(
      input logic [ROB_ROW_W-1:0] row
  );
    next_row = (row == ROB_ROWS - 1) ? '0 : row + 1'b1;
  endfunction

  function automatic logic row_in_range(
      input logic [ROB_ROW_W-1:0] row,
      input logic [ROB_ROW_W-1:0] start_row,
      input logic [ROB_ROW_W-1:0] end_row
  );
    begin
      if (start_row == end_row)
        row_in_range = 1'b0;
      else if (start_row < end_row)
        row_in_range = (row >= start_row) && (row < end_row);
      else
        row_in_range = (row >= start_row) || (row < end_row);
    end
  endfunction

  function automatic logic [1:0] lane_count(input logic [1:0] valid);
    lane_count = (valid == 2'b11) ? 2'd2 :
                 ((valid == 2'b01) ? 2'd1 : 2'd0);
  endfunction

  assign alloc_legal = (alloc_valid_i != 2'b10);
  assign alloc_ready_o = !scan_busy_q && alloc_legal && (used_rows_q != ROB_ROWS);
  assign alloc_fire = alloc_ready_o && (alloc_valid_i != 2'b00);

  assign head_row_count = {1'b0, head_entry0_q.valid} +
                          {1'b0, head_entry1_q.valid};
  assign retire_row_fire = !scan_busy_q && (used_rows_q != '0) &&
                           (retire_count_i != 2'd0) &&
                           (retire_count_i >= head_row_count);

  assign alloc_rob_id0_o = make_rob_id(tail_row_q, 1'b0);
  assign alloc_rob_id1_o = make_rob_id(tail_row_q, 1'b1);

  assign head_valid_o[0] = head_entry0_q.valid;
  assign head_valid_o[1] = head_entry1_q.valid;
  assign head_entry0_o = head_entry0_q;
  assign head_entry1_o = head_entry1_q;

  assign busy_o = scan_busy_q;
  assign empty_o = (used_rows_q == '0);
  assign full_o = (used_rows_q == ROB_ROWS);
  assign occupancy_o = occupancy_q;
  assign branch_clear_done_o = branch_clear_done_q;
  assign restore_done_o = restore_done_q;

  always_ff @(posedge clk_i) begin : rob_state
    integer entry_index;
    logic [ROB_ROW_W:0] used_rows_next;
    logic [5:0] occupancy_next;
    logic [ROB_ROW_W-1:0] head_row_next;
    logic [ROB_ROW_W-1:0] tail_after_restore;
    logic [ROB_ID_W-1:0] head_id0;
    logic [ROB_ID_W-1:0] head_id1;
    logic [ROB_ID_W-1:0] scan_id0;
    logic [ROB_ID_W-1:0] scan_id1;
    logic [1:0] scan_row_count;
    logic scan_row_survives;
    logic scan_last;
    logic kill_row;
    logic [CHECKPOINTS-1:0] clear_mask;
    rob_alloc_t alloc_tmp;
    rob_entry_t scan_entry0;
    rob_entry_t scan_entry1;
    rob_entry_t head0_next;
    rob_entry_t head1_next;

    if (rst_i) begin
      valid_q <= '0;
      complete_q <= '0;
      for (entry_index = 0; entry_index < ROB_ENTRIES; entry_index = entry_index + 1)
        entry_q[entry_index] <= '0;
      head_row_q <= '0;
      tail_row_q <= '0;
      used_rows_q <= '0;
      occupancy_q <= '0;
      head_entry0_q <= '0;
      head_entry1_q <= '0;
      scan_busy_q <= 1'b0;
      scan_restore_q <= 1'b0;
      scan_row_q <= '0;
      scan_branch_id_q <= '0;
      scan_restore_tail_q <= '0;
      scan_old_tail_row_q <= '0;
      scan_used_rows_q <= '0;
      scan_occupancy_q <= '0;
      branch_clear_done_q <= 1'b0;
      restore_done_q <= 1'b0;
    end else begin
      branch_clear_done_q <= 1'b0;
      restore_done_q <= 1'b0;

      if (restore_valid_i) begin
        scan_busy_q <= 1'b1;
        scan_restore_q <= 1'b1;
        scan_row_q <= '0;
        scan_restore_tail_q <= restore_tail_i;
        scan_old_tail_row_q <= tail_row_q;
        scan_used_rows_q <= '0;
        scan_occupancy_q <= '0;
      end else if (branch_clear_valid_i && !scan_busy_q) begin
        scan_busy_q <= 1'b1;
        scan_restore_q <= 1'b0;
        scan_row_q <= '0;
        scan_branch_id_q <= branch_clear_id_i;
      end else if (scan_busy_q) begin
        scan_last = (scan_row_q == ROB_ROWS - 1);
        scan_id0 = make_rob_id(scan_row_q, 1'b0);
        scan_id1 = make_rob_id(scan_row_q, 1'b1);
        scan_entry0.valid = valid_q[scan_id0];
        scan_entry0.complete = complete_q[scan_id0];
        scan_entry0.entry = entry_q[scan_id0];
        scan_entry1.valid = valid_q[scan_id1];
        scan_entry1.complete = complete_q[scan_id1];
        scan_entry1.entry = entry_q[scan_id1];

        if (scan_restore_q) begin
          kill_row = row_in_range(scan_row_q,
                                  rob_id_row(scan_restore_tail_q),
                                  scan_old_tail_row_q);
          if (kill_row) begin
            if ((scan_row_q == rob_id_row(scan_restore_tail_q)) &&
                rob_id_bank(scan_restore_tail_q)) begin
              valid_q[scan_id1] <= 1'b0;
              complete_q[scan_id1] <= 1'b0;
              scan_entry1.valid = 1'b0;
              scan_entry1.complete = 1'b0;
            end else begin
              valid_q[scan_id0] <= 1'b0;
              complete_q[scan_id0] <= 1'b0;
              valid_q[scan_id1] <= 1'b0;
              complete_q[scan_id1] <= 1'b0;
              scan_entry0.valid = 1'b0;
              scan_entry0.complete = 1'b0;
              scan_entry1.valid = 1'b0;
              scan_entry1.complete = 1'b0;
            end
          end
        end else begin
          clear_mask = ~(logic'(1'b1) << scan_branch_id_q);
          if (valid_q[scan_id0]) begin
            alloc_tmp = entry_q[scan_id0];
            alloc_tmp.branch_mask = alloc_tmp.branch_mask & clear_mask;
            entry_q[scan_id0] <= alloc_tmp;
            scan_entry0.entry = alloc_tmp;
          end
          if (valid_q[scan_id1]) begin
            alloc_tmp = entry_q[scan_id1];
            alloc_tmp.branch_mask = alloc_tmp.branch_mask & clear_mask;
            entry_q[scan_id1] <= alloc_tmp;
            scan_entry1.entry = alloc_tmp;
          end
        end

        scan_row_survives = scan_entry0.valid || scan_entry1.valid;
        scan_row_count = {1'b0, scan_entry0.valid} +
                         {1'b0, scan_entry1.valid};
        if (scan_restore_q) begin
          scan_used_rows_q <= scan_used_rows_q +
                              {{ROB_ROW_W{1'b0}}, scan_row_survives};
          scan_occupancy_q <= scan_occupancy_q + {4'd0, scan_row_count};
        end

        if (scan_row_q == head_row_q) begin
          head_entry0_q <= scan_entry0;
          head_entry1_q <= scan_entry1;
        end

        if (scan_last) begin
          scan_busy_q <= 1'b0;
          scan_row_q <= '0;
          if (scan_restore_q) begin
            tail_after_restore = rob_id_bank(scan_restore_tail_q) ?
                                 next_row(rob_id_row(scan_restore_tail_q)) :
                                 rob_id_row(scan_restore_tail_q);
            tail_row_q <= tail_after_restore;
            used_rows_q <= scan_used_rows_q +
                           {{ROB_ROW_W{1'b0}}, scan_row_survives};
            occupancy_q <= scan_occupancy_q + {4'd0, scan_row_count};
            restore_done_q <= 1'b1;
          end else begin
            branch_clear_done_q <= 1'b1;
          end
        end else begin
          scan_row_q <= next_row(scan_row_q);
        end
      end else begin
        used_rows_next = used_rows_q;
        occupancy_next = occupancy_q;
        head_row_next = head_row_q;

        if (complete0_i.valid && valid_q[complete0_i.rob_id]) begin
          complete_q[complete0_i.rob_id] <= 1'b1;
          if (complete0_i.exception_valid) begin
            alloc_tmp = entry_q[complete0_i.rob_id];
            alloc_tmp.exception_valid = 1'b1;
            alloc_tmp.exception_cause = complete0_i.exception_cause;
            alloc_tmp.exception_tval = complete0_i.exception_tval;
            entry_q[complete0_i.rob_id] <= alloc_tmp;
          end
        end

        if (complete1_i.valid && valid_q[complete1_i.rob_id]) begin
          complete_q[complete1_i.rob_id] <= 1'b1;
          if (complete1_i.exception_valid) begin
            alloc_tmp = entry_q[complete1_i.rob_id];
            alloc_tmp.exception_valid = 1'b1;
            alloc_tmp.exception_cause = complete1_i.exception_cause;
            alloc_tmp.exception_tval = complete1_i.exception_tval;
            entry_q[complete1_i.rob_id] <= alloc_tmp;
          end
        end

        if (retire_row_fire) begin
          head_id0 = make_rob_id(head_row_q, 1'b0);
          head_id1 = make_rob_id(head_row_q, 1'b1);
          valid_q[head_id0] <= 1'b0;
          complete_q[head_id0] <= 1'b0;
          valid_q[head_id1] <= 1'b0;
          complete_q[head_id1] <= 1'b0;
          head_row_next = next_row(head_row_q);
          head_row_q <= head_row_next;
          used_rows_next = used_rows_next - 1'b1;
          occupancy_next = occupancy_next - {4'd0, head_row_count};
        end

        if (alloc_fire) begin
          valid_q[alloc_rob_id0_o] <= alloc_valid_i[0];
          complete_q[alloc_rob_id0_o] <= alloc_entry0_i.exception_valid;
          entry_q[alloc_rob_id0_o] <= alloc_entry0_i;
          valid_q[alloc_rob_id1_o] <= alloc_valid_i[1];
          complete_q[alloc_rob_id1_o] <= alloc_valid_i[1] &&
                                         alloc_entry1_i.exception_valid;
          entry_q[alloc_rob_id1_o] <= alloc_entry1_i;
          tail_row_q <= next_row(tail_row_q);
          used_rows_next = used_rows_next + 1'b1;
          occupancy_next = occupancy_next + {4'd0, lane_count(alloc_valid_i)};
        end

        used_rows_q <= used_rows_next;
        occupancy_q <= occupancy_next;

        head_id0 = make_rob_id(head_row_next, 1'b0);
        head_id1 = make_rob_id(head_row_next, 1'b1);
        head0_next.valid = valid_q[head_id0];
        head0_next.complete = complete_q[head_id0];
        head0_next.entry = entry_q[head_id0];
        head1_next.valid = valid_q[head_id1];
        head1_next.complete = complete_q[head_id1];
        head1_next.entry = entry_q[head_id1];

        if ((used_rows_q == '0) && alloc_fire && !retire_row_fire) begin
          head0_next.valid = alloc_valid_i[0];
          head0_next.complete = alloc_entry0_i.exception_valid;
          head0_next.entry = alloc_entry0_i;
          head1_next.valid = alloc_valid_i[1];
          head1_next.complete = alloc_valid_i[1] && alloc_entry1_i.exception_valid;
          head1_next.entry = alloc_entry1_i;
        end

        if (complete0_i.valid && (rob_id_row(complete0_i.rob_id) == head_row_next)) begin
          if (!rob_id_bank(complete0_i.rob_id)) begin
            head0_next.complete = 1'b1;
            if (complete0_i.exception_valid) begin
              head0_next.entry.exception_valid = 1'b1;
              head0_next.entry.exception_cause = complete0_i.exception_cause;
              head0_next.entry.exception_tval = complete0_i.exception_tval;
            end
          end else begin
            head1_next.complete = 1'b1;
            if (complete0_i.exception_valid) begin
              head1_next.entry.exception_valid = 1'b1;
              head1_next.entry.exception_cause = complete0_i.exception_cause;
              head1_next.entry.exception_tval = complete0_i.exception_tval;
            end
          end
        end

        if (complete1_i.valid && (rob_id_row(complete1_i.rob_id) == head_row_next)) begin
          if (!rob_id_bank(complete1_i.rob_id)) begin
            head0_next.complete = 1'b1;
            if (complete1_i.exception_valid) begin
              head0_next.entry.exception_valid = 1'b1;
              head0_next.entry.exception_cause = complete1_i.exception_cause;
              head0_next.entry.exception_tval = complete1_i.exception_tval;
            end
          end else begin
            head1_next.complete = 1'b1;
            if (complete1_i.exception_valid) begin
              head1_next.entry.exception_valid = 1'b1;
              head1_next.entry.exception_cause = complete1_i.exception_cause;
              head1_next.entry.exception_tval = complete1_i.exception_tval;
            end
          end
        end

        if ((used_rows_next == '0) && !alloc_fire) begin
          head_entry0_q <= '0;
          head_entry1_q <= '0;
        end else begin
          head_entry0_q <= head0_next;
          head_entry1_q <= head1_next;
        end
      end
    end
  end

endmodule
