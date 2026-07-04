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
  logic [3:0] group_nonempty1_even;
  logic [3:0] group_nonempty1_odd;
  logic [2:0] group_select0;
  logic [2:0] group_select1_even;
  logic [2:0] group_select1_odd;
  logic [4:0] bit_select0;
  logic [4:0] bit_select1_even;
  logic [4:0] bit_select1_odd;
  logic [15:0] selected_word0;
  logic [15:0] selected_word1_even;
  logic [15:0] selected_word1_odd;
  logic [15:0] selection_exclude_word1;
  logic [PHYS_REGS-1:0] available_bitmap1;
  logic [PHYS_REGS-1:0] even_bitmap1;
  logic [PHYS_REGS-1:0] odd_bitmap1;
  logic candidate0_valid;
  logic candidate1_even_valid;
  logic candidate1_odd_valid;
  logic candidate1_valid;
  logic [PRD_W-1:0] candidate_prd0;
  logic [PRD_W-1:0] candidate_prd1_even;
  logic [PRD_W-1:0] candidate_prd1_odd;
  logic [PRD_W-1:0] candidate_prd1;
  logic selection_request_ready;

  logic [1:0] reclaim_input_count;
  logic reclaim_accept;
  logic reclaim_drain;
  logic alloc_consume;

  function automatic logic [2:0] pick_group(
      input logic [3:0] nonempty,
      input logic [1:0] start_group
  );
    begin
      pick_group = '0;
      case (start_group)
        2'd0: begin
          if (nonempty[0])
            pick_group = 3'b100;
          else if (nonempty[1])
            pick_group = 3'b101;
          else if (nonempty[2])
            pick_group = 3'b110;
          else if (nonempty[3])
            pick_group = 3'b111;
        end
        2'd1: begin
          if (nonempty[1])
            pick_group = 3'b101;
          else if (nonempty[2])
            pick_group = 3'b110;
          else if (nonempty[3])
            pick_group = 3'b111;
          else if (nonempty[0])
            pick_group = 3'b100;
        end
        2'd2: begin
          if (nonempty[2])
            pick_group = 3'b110;
          else if (nonempty[3])
            pick_group = 3'b111;
          else if (nonempty[0])
            pick_group = 3'b100;
          else if (nonempty[1])
            pick_group = 3'b101;
        end
        default: begin
          if (nonempty[3])
            pick_group = 3'b111;
          else if (nonempty[0])
            pick_group = 3'b100;
          else if (nonempty[1])
            pick_group = 3'b101;
          else if (nonempty[2])
            pick_group = 3'b110;
        end
      endcase
    end
  endfunction

  function automatic logic [2:0] pick_bit4(input logic [3:0] word);
    begin
      casez (word)
        4'b???1: pick_bit4 = 3'b100;
        4'b??10: pick_bit4 = 3'b101;
        4'b?100: pick_bit4 = 3'b110;
        4'b1000: pick_bit4 = 3'b111;
        default: pick_bit4 = 3'b000;
      endcase
    end
  endfunction

  function automatic logic [4:0] pick_bit16(input logic [15:0] word);
    logic [3:0] nibble_nonempty;
    logic [1:0] nibble_index;
    logic [3:0] selected_nibble;
    logic [2:0] bit_in_nibble;
    begin
      pick_bit16 = '0;
      nibble_nonempty = {|word[15:12], |word[11:8], |word[7:4], |word[3:0]};
      nibble_index = 2'd0;
      selected_nibble = word[3:0];

      if (nibble_nonempty[0]) begin
        nibble_index = 2'd0;
        selected_nibble = word[3:0];
      end else if (nibble_nonempty[1]) begin
        nibble_index = 2'd1;
        selected_nibble = word[7:4];
      end else if (nibble_nonempty[2]) begin
        nibble_index = 2'd2;
        selected_nibble = word[11:8];
      end else if (nibble_nonempty[3]) begin
        nibble_index = 2'd3;
        selected_nibble = word[15:12];
      end

      bit_in_nibble = pick_bit4(selected_nibble);
      if (bit_in_nibble[2]) begin
        pick_bit16 = {1'b1, nibble_index, bit_in_nibble[1:0]};
      end
    end
  endfunction

  function automatic logic [15:0] bit_onehot16(input logic [3:0] bit_index);
    begin
      case (bit_index)
        4'd0: bit_onehot16 = 16'h0001;
        4'd1: bit_onehot16 = 16'h0002;
        4'd2: bit_onehot16 = 16'h0004;
        4'd3: bit_onehot16 = 16'h0008;
        4'd4: bit_onehot16 = 16'h0010;
        4'd5: bit_onehot16 = 16'h0020;
        4'd6: bit_onehot16 = 16'h0040;
        4'd7: bit_onehot16 = 16'h0080;
        4'd8: bit_onehot16 = 16'h0100;
        4'd9: bit_onehot16 = 16'h0200;
        4'd10: bit_onehot16 = 16'h0400;
        4'd11: bit_onehot16 = 16'h0800;
        4'd12: bit_onehot16 = 16'h1000;
        4'd13: bit_onehot16 = 16'h2000;
        4'd14: bit_onehot16 = 16'h4000;
        default: bit_onehot16 = 16'h8000;
      endcase
    end
  endfunction

  function automatic logic [1:0] next_group(input logic [1:0] group_index);
    begin
      case (group_index)
        2'd0: next_group = 2'd1;
        2'd1: next_group = 2'd2;
        2'd2: next_group = 2'd3;
        default: next_group = 2'd0;
      endcase
    end
  endfunction

  function automatic logic [3:0] group_nonempty(
      input logic [PHYS_REGS-1:0] bitmap
  );
    begin
      group_nonempty[0] = |bitmap[15:0];
      group_nonempty[1] = |bitmap[31:16];
      group_nonempty[2] = |bitmap[47:32];
      group_nonempty[3] = |bitmap[63:48];
    end
  endfunction

  function automatic logic [PRD_W-1:0] make_prd(
      input logic [2:0] group_select,
      input logic [4:0] bit_select
  );
    begin
      make_prd = {group_select[1:0], bit_select[3:0]};
    end
  endfunction

  function automatic logic candidate_valid(
      input logic [2:0] group_select,
      input logic [4:0] bit_select
  );
    begin
      candidate_valid = group_select[2] && bit_select[4];
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
    group_nonempty0 = group_nonempty(free_bitmap_q);
    group_select0 = pick_group(group_nonempty0, rotate_group_q);
    selected_word0 = group_word(free_bitmap_q, group_select0[1:0]);
    bit_select0 = pick_bit16(selected_word0);
    candidate0_valid = candidate_valid(group_select0, bit_select0);
    candidate_prd0 = make_prd(group_select0, bit_select0);
    selection_exclude_word1 = bit_onehot16(selection_prd0_q[3:0]);
    available_bitmap1 = free_bitmap_q;
    if (selection_pending_q) begin
      case (selection_prd0_q[5:4])
        2'd0:
          available_bitmap1[15:0] = free_bitmap_q[15:0] &
                                    ~selection_exclude_word1;
        2'd1:
          available_bitmap1[31:16] = free_bitmap_q[31:16] &
                                     ~selection_exclude_word1;
        2'd2:
          available_bitmap1[47:32] = free_bitmap_q[47:32] &
                                     ~selection_exclude_word1;
        default:
          available_bitmap1[63:48] = free_bitmap_q[63:48] &
                                     ~selection_exclude_word1;
      endcase
    end
    even_bitmap1 = available_bitmap1 & EVEN_PRD_MASK;
    odd_bitmap1 = available_bitmap1 & ODD_PRD_MASK;

    group_nonempty1_even = group_nonempty(even_bitmap1);
    group_select1_even = pick_group(group_nonempty1_even,
                                    selection_prd0_q[5:4]);
    selected_word1_even = group_word(even_bitmap1, group_select1_even[1:0]);
    bit_select1_even = pick_bit16(selected_word1_even);
    candidate1_even_valid = candidate_valid(group_select1_even,
                                            bit_select1_even);
    candidate_prd1_even = make_prd(group_select1_even, bit_select1_even);

    group_nonempty1_odd = group_nonempty(odd_bitmap1);
    group_select1_odd = pick_group(group_nonempty1_odd,
                                   selection_prd0_q[5:4]);
    selected_word1_odd = group_word(odd_bitmap1, group_select1_odd[1:0]);
    bit_select1_odd = pick_bit16(selected_word1_odd);
    candidate1_odd_valid = candidate_valid(group_select1_odd,
                                           bit_select1_odd);
    candidate_prd1_odd = make_prd(group_select1_odd, bit_select1_odd);

    if (selection_prd0_q[0]) begin
      candidate1_valid = candidate1_even_valid || candidate1_odd_valid;
      candidate_prd1 = candidate1_even_valid ? candidate_prd1_even :
                                               candidate_prd1_odd;
    end else begin
      candidate1_valid = candidate1_odd_valid || candidate1_even_valid;
      candidate_prd1 = candidate1_odd_valid ? candidate_prd1_odd :
                                             candidate_prd1_even;
    end

    selection_request_ready = !reservation_valid_q && !selection_pending_q &&
                              !busy_o && (alloc_count_i != 0) &&
                              (alloc_count_i != 2'd3);
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
                            next_group(reservation_prd1_q[5:4]) :
                            next_group(reservation_prd0_q[5:4]);
          reservation_valid_q <= 1'b0;
        end else if (selection_pending_q &&
                     ((selection_count_q == 2'd1) || candidate1_valid)) begin
          reservation_valid_q <= 1'b1;
          reservation_count_q <= selection_count_q;
          reservation_prd0_q <= selection_prd0_q;
          reservation_prd1_q <= (selection_count_q == 2'd2) ? candidate_prd1 : '0;
          selection_pending_q <= 1'b0;
        end else if (selection_request_ready) begin
          selection_pending_q <= candidate0_valid;
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
