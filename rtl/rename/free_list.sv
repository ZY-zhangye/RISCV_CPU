`timescale 1ns/1ps

import core_types_pkg::*;

// Grouped-bitmap physical register free list.
// Normal allocation is deliberately split into selection -> reservation -> fire.
// No request-to-response combinational path crosses this module boundary.
module free_list (
    input  logic                     clk_i,
    input  logic                     rst_i,

    input  logic [1:0]               alloc_count_i,
    output logic                     alloc_valid_o,
    output logic [PRD_W-1:0]         alloc_prd0_o,
    output logic [PRD_W-1:0]         alloc_prd1_o,
    input  logic                     alloc_fire_i,
    input  logic                     alloc_cancel_i,

    input  logic [1:0]               reclaim_valid_i,
    input  logic [PRD_W-1:0]         reclaim_prd0_i,
    input  logic [PRD_W-1:0]         reclaim_prd1_i,
    output logic                     reclaim_ready_o,

    input  logic                     checkpoint_save_i,
    input  logic [CP_W-1:0]          checkpoint_id_i,
    input  logic [1:0]               checkpoint_keep_count_i,
    input  logic                     checkpoint_clear_i,
    input  logic [CP_W-1:0]          checkpoint_clear_id_i,
    input  logic                     branch_restore_i,
    input  logic [CP_W-1:0]          branch_restore_id_i,
    output logic                     branch_restore_done_o,

    input  logic                     rebuild_start_i,
    input  logic [PRD_W-1:0]         amt_map_i [0:ARCH_REGS-1],
    output logic                     busy_o,
    output logic                     rebuild_done_o,
    output logic [6:0]               free_count_o
);

  localparam logic [PHYS_REGS-1:0] EVEN_PRD_MASK = 64'h5555_5555_5555_5555;
  localparam logic [PHYS_REGS-1:0] ODD_PRD_MASK  = 64'haaaa_aaaa_aaaa_aaaa;

  logic [PHYS_REGS-1:0] free_bitmap_q;
  logic [6:0] free_count_q;
  logic [1:0] rotate_group_q;

  logic reservation_valid_q;
  logic [1:0] reservation_count_q;
  logic [PRD_W-1:0] reservation_prd0_q;
  logic [PRD_W-1:0] reservation_prd1_q;
  logic selection_pending_q;
  logic [1:0] selection_count_q;
  logic [PRD_W-1:0] selection_prd0_q;

  logic [PRD_W-1:0] reclaim_fifo_q [0:1];
  logic reclaim_head_q;
  logic reclaim_tail_q;
  logic [1:0] reclaim_count_q;

  logic [PRD_W-1:0] allocation_log_q [0:PHYS_REGS-1];
  logic [PRD_W-1:0] allocation_tail_q;
  logic [PRD_W-1:0] checkpoint_tail_q [0:CHECKPOINTS-1];
  logic [CHECKPOINTS-1:0] checkpoint_valid_q;

  logic rollback_busy_q;
  logic [PRD_W-1:0] rollback_target_q;
  logic rollback_prd_valid_q;
  logic rollback_prd_last_q;
  logic [PRD_W-1:0] rollback_prd_q;
  logic branch_restore_done_q;

  logic rebuild_busy_q;
  logic [4:0] rebuild_index_q;
  logic rebuild_pair_valid_q;
  logic rebuild_pair_last_q;
  logic [PRD_W-1:0] rebuild_prd0_q;
  logic [PRD_W-1:0] rebuild_prd1_q;
  logic [PHYS_REGS-1:0] rebuild_used_bitmap_q;
  logic [6:0] rebuild_used_count_q;
  logic rebuild_done_q;

  logic [3:0] group_nonempty0;
  logic [3:0] group_nonempty1;
  logic [2:0] group_select0;
  logic [2:0] group_select1;
  logic [4:0] bit_select0;
  logic [4:0] bit_select1;
  logic [15:0] selected_word0;
  logic [15:0] selected_word1;
  logic [PHYS_REGS-1:0] remaining_bitmap;
  logic [PHYS_REGS-1:0] preferred_bitmap;
  logic [PHYS_REGS-1:0] second_bitmap;
  logic candidate0_valid;
  logic candidate1_valid;
  logic [PRD_W-1:0] candidate_prd0;
  logic [PRD_W-1:0] candidate_prd1;
  logic selection_can_start;

  logic [1:0] reclaim_input_count;
  logic reclaim_accept;
  logic reclaim_drain;
  logic alloc_consume;

  function automatic logic [2:0] pick_group(
      input logic [3:0] nonempty,
      input logic [1:0] start_group
  );
    integer offset;
    logic found;
    logic [1:0] group_index;
    begin
      pick_group = '0;
      found = 1'b0;
      for (offset = 0; offset < 4; offset = offset + 1) begin
        group_index = start_group + offset;
        if (!found && nonempty[group_index]) begin
          pick_group = {1'b1, group_index};
          found = 1'b1;
        end
      end
    end
  endfunction

  function automatic logic [4:0] pick_bit16(input logic [15:0] word);
    integer bit_index;
    logic found;
    begin
      pick_bit16 = '0;
      found = 1'b0;
      for (bit_index = 0; bit_index < 16; bit_index = bit_index + 1) begin
        if (!found && word[bit_index]) begin
          pick_bit16 = {1'b1, bit_index[3:0]};
          found = 1'b1;
        end
      end
    end
  endfunction

  function automatic logic [15:0] group_word(
      input logic [PHYS_REGS-1:0] bitmap,
      input logic [1:0] group_index
  );
    case (group_index)
      2'd0: group_word = bitmap[15:0];
      2'd1: group_word = bitmap[31:16];
      2'd2: group_word = bitmap[47:32];
      default: group_word = bitmap[63:48];
    endcase
  endfunction

  always @* begin
    group_nonempty0[0] = |free_bitmap_q[15:0];
    group_nonempty0[1] = |free_bitmap_q[31:16];
    group_nonempty0[2] = |free_bitmap_q[47:32];
    group_nonempty0[3] = |free_bitmap_q[63:48];
    group_select0 = pick_group(group_nonempty0, rotate_group_q);
    selected_word0 = group_word(free_bitmap_q, group_select0[1:0]);
    bit_select0 = pick_bit16(selected_word0);
    candidate0_valid = group_select0[2] && bit_select0[4];
    candidate_prd0 = {group_select0[1:0], bit_select0[3:0]};

    remaining_bitmap = free_bitmap_q;
    if (selection_pending_q)
      remaining_bitmap[selection_prd0_q] = 1'b0;

    preferred_bitmap = remaining_bitmap &
                       (selection_prd0_q[0] ? EVEN_PRD_MASK : ODD_PRD_MASK);
    second_bitmap = (preferred_bitmap != 0) ? preferred_bitmap : remaining_bitmap;
    group_nonempty1[0] = |second_bitmap[15:0];
    group_nonempty1[1] = |second_bitmap[31:16];
    group_nonempty1[2] = |second_bitmap[47:32];
    group_nonempty1[3] = |second_bitmap[63:48];
    group_select1 = pick_group(group_nonempty1, selection_prd0_q[5:4]);
    selected_word1 = group_word(second_bitmap, group_select1[1:0]);
    bit_select1 = pick_bit16(selected_word1);
    candidate1_valid = group_select1[2] && bit_select1[4];
    candidate_prd1 = {group_select1[1:0], bit_select1[3:0]};

    selection_can_start = !reservation_valid_q && !selection_pending_q &&
                          !busy_o && (alloc_count_i != 0) &&
                          (alloc_count_i != 2'd3) && candidate0_valid;
  end

  assign reclaim_input_count = (reclaim_valid_i == 2'b11) ? 2'd2 :
                               ((reclaim_valid_i == 2'b01) ? 2'd1 : 2'd0);

  assign busy_o = rollback_busy_q || rebuild_busy_q;
  assign alloc_valid_o = reservation_valid_q && !busy_o;
  assign alloc_prd0_o = reservation_prd0_q;
  assign alloc_prd1_o = reservation_prd1_q;
  assign free_count_o = free_count_q;
  assign rebuild_done_o = rebuild_done_q;
  assign branch_restore_done_o = branch_restore_done_q;
  assign alloc_consume = alloc_fire_i && reservation_valid_q && !alloc_cancel_i;

  assign reclaim_drain = (reclaim_count_q != 0) && !busy_o &&
                         !branch_restore_i && !rebuild_start_i;
  assign reclaim_ready_o = !busy_o && !branch_restore_i && !rebuild_start_i &&
      (reclaim_input_count <= (2 - reclaim_count_q + reclaim_drain));
  assign reclaim_accept = (reclaim_input_count != 0) && reclaim_ready_o;

  always_ff @(posedge clk_i) begin : free_list_state
    integer cp_index;
    logic [PRD_W-1:0] rollback_index;
    logic [PHYS_REGS-1:0] used_next;
    logic [6:0] used_count_next;

    if (rst_i) begin
      free_bitmap_q <= 64'hffff_ffff_0000_0000;
      free_count_q <= 7'd32;
      rotate_group_q <= 2'd2;
      reservation_valid_q <= 1'b0;
      reservation_count_q <= 2'd0;
      reservation_prd0_q <= '0;
      reservation_prd1_q <= '0;
      selection_pending_q <= 1'b0;
      selection_count_q <= 2'd0;
      selection_prd0_q <= '0;
      reclaim_head_q <= 1'b0;
      reclaim_tail_q <= 1'b0;
      reclaim_count_q <= 2'd0;
      allocation_tail_q <= '0;
      checkpoint_valid_q <= '0;
      rollback_busy_q <= 1'b0;
      rollback_target_q <= '0;
      rollback_prd_valid_q <= 1'b0;
      rollback_prd_last_q <= 1'b0;
      rollback_prd_q <= '0;
      branch_restore_done_q <= 1'b0;
      rebuild_busy_q <= 1'b0;
      rebuild_index_q <= 5'd0;
      rebuild_pair_valid_q <= 1'b0;
      rebuild_pair_last_q <= 1'b0;
      rebuild_prd0_q <= '0;
      rebuild_prd1_q <= '0;
      rebuild_used_bitmap_q <= '0;
      rebuild_used_count_q <= 7'd0;
      rebuild_done_q <= 1'b0;
      branch_restore_done_q <= 1'b0;
    end else begin
      rebuild_done_q <= 1'b0;

      if (rebuild_start_i) begin
        reservation_valid_q <= 1'b0;
        selection_pending_q <= 1'b0;
        reclaim_head_q <= 1'b0;
        reclaim_tail_q <= 1'b0;
        reclaim_count_q <= 2'd0;
        checkpoint_valid_q <= '0;
        rollback_busy_q <= 1'b0;
        rollback_prd_valid_q <= 1'b0;
        rebuild_busy_q <= 1'b1;
        rebuild_index_q <= 5'd0;
        rebuild_pair_valid_q <= 1'b0;
        rebuild_used_bitmap_q <= '0;
        rebuild_used_count_q <= 7'd0;
      end else if (branch_restore_i) begin
        reservation_valid_q <= 1'b0;
        selection_pending_q <= 1'b0;
        if (checkpoint_valid_q[branch_restore_id_i] &&
            (allocation_tail_q != checkpoint_tail_q[branch_restore_id_i])) begin
          rollback_busy_q <= 1'b1;
          rollback_target_q <= checkpoint_tail_q[branch_restore_id_i];
          rollback_prd_valid_q <= 1'b0;
        end else begin
          rollback_busy_q <= 1'b0;
          branch_restore_done_q <= 1'b1;
        end
        checkpoint_valid_q[branch_restore_id_i] <= 1'b0;
      end else if (rebuild_busy_q) begin
        used_next = rebuild_used_bitmap_q;
        used_count_next = rebuild_used_count_q;

        // Mark only registered AMT outputs. The 32:1 AMT read Mux is isolated
        // from the used-bitmap decoder/update path by rebuild_prd*_q.
        if (rebuild_pair_valid_q) begin
          if (!used_next[rebuild_prd0_q]) begin
            used_next[rebuild_prd0_q] = 1'b1;
            used_count_next = used_count_next + 7'd1;
          end
          if (!used_next[rebuild_prd1_q]) begin
            used_next[rebuild_prd1_q] = 1'b1;
            used_count_next = used_count_next + 7'd1;
          end
          rebuild_used_bitmap_q <= used_next;
          rebuild_used_count_q <= used_count_next;

          if (rebuild_pair_last_q) begin
            free_bitmap_q <= ~used_next;
            free_bitmap_q[0] <= 1'b0;
            free_count_q <= 7'd64 - used_count_next;
            allocation_tail_q <= '0;
            rebuild_busy_q <= 1'b0;
            rebuild_index_q <= 5'd0;
            rebuild_pair_valid_q <= 1'b0;
            rebuild_done_q <= 1'b1;
            rotate_group_q <= 2'd0;
          end
        end

        if (!rebuild_pair_valid_q || !rebuild_pair_last_q) begin
          rebuild_prd0_q <= amt_map_i[rebuild_index_q];
          rebuild_prd1_q <= amt_map_i[rebuild_index_q + 1'b1];
          rebuild_pair_valid_q <= 1'b1;
          rebuild_pair_last_q <= (rebuild_index_q == 5'd30);
          if (rebuild_index_q != 5'd30)
            rebuild_index_q <= rebuild_index_q + 5'd2;
        end
      end else if (rollback_busy_q) begin
        // The log lookup and bitmap write are separated by rollback_prd_q.
        if (rollback_prd_valid_q) begin
          free_bitmap_q[rollback_prd_q] <= 1'b1;
          free_count_q <= free_count_q + 7'd1;
          if (rollback_prd_last_q) begin
            rollback_busy_q <= 1'b0;
            rollback_prd_valid_q <= 1'b0;
            branch_restore_done_q <= 1'b1;
          end
        end

        if (!rollback_prd_valid_q || !rollback_prd_last_q) begin
          rollback_index = allocation_tail_q - 1'b1;
          rollback_prd_q <= allocation_log_q[rollback_index];
          rollback_prd_valid_q <= 1'b1;
          rollback_prd_last_q <= (rollback_index == rollback_target_q);
          allocation_tail_q <= rollback_index;
        end
      end else begin
        if (checkpoint_clear_i)
          checkpoint_valid_q[checkpoint_clear_id_i] <= 1'b0;

        if (checkpoint_save_i) begin
          cp_index = checkpoint_id_i;
          checkpoint_valid_q[cp_index] <= 1'b1;
          checkpoint_tail_q[cp_index] <= allocation_tail_q +
                                                   checkpoint_keep_count_i;
        end

        if (alloc_cancel_i) begin
          reservation_valid_q <= 1'b0;
          selection_pending_q <= 1'b0;
        end else if (alloc_consume) begin
          free_bitmap_q[reservation_prd0_q] <= 1'b0;
          allocation_log_q[allocation_tail_q] <= reservation_prd0_q;
          if (reservation_count_q == 2'd2) begin
            free_bitmap_q[reservation_prd1_q] <= 1'b0;
            allocation_log_q[allocation_tail_q + 1'b1] <= reservation_prd1_q;
          end
          allocation_tail_q <= allocation_tail_q + reservation_count_q;
          rotate_group_q <= (reservation_count_q == 2'd2) ?
                            reservation_prd1_q[5:4] + 2'd1 :
                            reservation_prd0_q[5:4] + 2'd1;
          reservation_valid_q <= 1'b0;
        end else if (selection_pending_q &&
                     ((selection_count_q == 2'd1) || candidate1_valid)) begin
          reservation_valid_q <= 1'b1;
          reservation_count_q <= selection_count_q;
          reservation_prd0_q <= selection_prd0_q;
          reservation_prd1_q <= (selection_count_q == 2'd2) ? candidate_prd1 : '0;
          selection_pending_q <= 1'b0;
        end else if (selection_can_start) begin
          selection_pending_q <= 1'b1;
          selection_count_q <= alloc_count_i;
          selection_prd0_q <= candidate_prd0;
        end

        if (reclaim_accept) begin
          reclaim_fifo_q[reclaim_tail_q] <= reclaim_prd0_i;
          if (reclaim_input_count == 2'd2)
            reclaim_fifo_q[~reclaim_tail_q] <= reclaim_prd1_i;
          reclaim_tail_q <= reclaim_tail_q + reclaim_input_count[0];
        end
        if (reclaim_drain)
          reclaim_head_q <= ~reclaim_head_q;
        reclaim_count_q <= reclaim_count_q +
                           (reclaim_accept ? reclaim_input_count : 2'd0) -
                           (reclaim_drain ? 2'd1 : 2'd0);

        if (reclaim_drain)
          free_bitmap_q[reclaim_fifo_q[reclaim_head_q]] <= 1'b1;

        case ({reclaim_drain, alloc_consume})
          2'b10: free_count_q <= free_count_q + 7'd1;
          2'b01: free_count_q <= free_count_q - reservation_count_q;
          2'b11: free_count_q <= free_count_q + 7'd1 - reservation_count_q;
          default: free_count_q <= free_count_q;
        endcase
      end
    end
  end

`ifdef FREE_LIST_ASSERTIONS
  property p_alloc_distinct;
    @(posedge clk_i) disable iff (rst_i)
      alloc_valid_o && (reservation_count_q == 2) |->
        (alloc_prd0_o != alloc_prd1_o);
  endproperty
  assert property (p_alloc_distinct);

  property p_reclaim_prefix;
    @(posedge clk_i) disable iff (rst_i) reclaim_valid_i != 2'b10;
  endproperty
  assert property (p_reclaim_prefix);

  property p_never_allocate_p0;
    @(posedge clk_i) disable iff (rst_i)
      alloc_valid_o |-> (alloc_prd0_o != 0) &&
        ((reservation_count_q != 2) || (alloc_prd1_o != 0));
  endproperty
  assert property (p_never_allocate_p0);
`endif

endmodule
