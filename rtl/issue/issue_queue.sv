import core_types_pkg::*;

// Parameterized fixed-slot issue queue.
// Storage is split into field arrays to keep dynamic slot writes simple for
// both FPGA synthesis and lightweight simulators.
module issue_queue #(
    parameter int ENTRIES = 12,
    parameter int GROUPS  = 3
) (
    input  logic                    clk_i,
    input  logic                    rst_i,

    input  logic [1:0]              push_valid_i,
    output logic                    push_ready_o,
    input  issue_uop_t              push_uop0_i,
    input  issue_uop_t              push_uop1_i,

    input  logic [1:0]              wb_valid_i,
    input  logic [1:0][PRD_W-1:0]   wb_prd_i,

    output logic [GROUPS-1:0]       candidate_valid_o,
    output issue_uop_t              candidate_uop0_o,
    output issue_uop_t              candidate_uop1_o,
    output issue_uop_t              candidate_uop2_o,
    output logic [$clog2(ENTRIES)-1:0] candidate_slot0_o,
    output logic [$clog2(ENTRIES)-1:0] candidate_slot1_o,
    output logic [$clog2(ENTRIES)-1:0] candidate_slot2_o,

    input  logic [GROUPS-1:0]       issue_grant_i,
    input  recovery_t               recovery_i,

    output logic                    empty_o,
    output logic                    full_o,
    output logic [$clog2(ENTRIES+1)-1:0] occupancy_o
);

  localparam int SLOT_W = $clog2(ENTRIES);
  localparam int COUNT_W = $clog2(ENTRIES + 1);
  localparam int GROUP_SIZE = ENTRIES / GROUPS;
  localparam int PAIRS_PER_GROUP = (GROUP_SIZE + 1) / 2;
  localparam int PAIR_COUNT = GROUPS * PAIRS_PER_GROUP;

  logic [ENTRIES-1:0] valid_q;
  logic [ENTRIES-1:0] src1_ready_q;
  logic [ENTRIES-1:0] src2_ready_q;
  logic [ENTRIES-1:0] need_rs1_q;
  logic [ENTRIES-1:0] need_rs2_q;
  logic [ROB_ID_W-1:0] rob_id_q [0:ENTRIES-1];
  logic [PRD_W-1:0] prs1_q [0:ENTRIES-1];
  logic [PRD_W-1:0] prs2_q [0:ENTRIES-1];
  logic [CHECKPOINTS-1:0] branch_mask_q [0:ENTRIES-1];
  issue_uop_t payload_q [0:ENTRIES-1];

  logic [COUNT_W-1:0] count_q;
  logic [PAIR_COUNT-1:0] pair_valid_q;
  logic [SLOT_W-1:0] pair_slot_q [0:PAIR_COUNT-1];
  logic [ROB_ID_W-1:0] pair_rob_id_q [0:PAIR_COUNT-1];
  logic [GROUPS-1:0] candidate_valid_q;
  logic [SLOT_W-1:0] candidate_slot_q [0:GROUPS-1];
  logic [GROUPS-1:0] clear_valid_q;
  logic [SLOT_W-1:0] clear_slot_q [0:GROUPS-1];

  logic [1:0] push_count;
  logic [COUNT_W-1:0] free_count;
  logic push_fire;

  function automatic logic [1:0] valid_count(input logic [1:0] valid);
    valid_count = (valid == 2'b11) ? 2'd2 :
                  ((valid == 2'b01) ? 2'd1 : 2'd0);
  endfunction

  function automatic logic is_older(
      input logic [ROB_ID_W-1:0] a,
      input logic [ROB_ID_W-1:0] b
  );
    logic [ROB_ID_W-1:0] diff;
    begin
      diff = b - a;
      is_older = (diff != '0) && !diff[ROB_ID_W-1];
    end
  endfunction

  function automatic logic wake_src(
      input logic             ready,
      input logic             need_src,
      input logic [PRD_W-1:0] prs
  );
    begin
      wake_src = ready || !need_src ||
                 (wb_valid_i[0] && (wb_prd_i[0] == prs)) ||
                 (wb_valid_i[1] && (wb_prd_i[1] == prs));
    end
  endfunction

  function automatic issue_uop_t candidate_from_slot(
      input logic [SLOT_W-1:0] slot
  );
    issue_uop_t uop;
    begin
      uop = payload_q[slot];
      uop.src1_ready = src1_ready_q[slot];
      uop.src2_ready = src2_ready_q[slot];
      uop.branch_mask = branch_mask_q[slot];
      candidate_from_slot = uop;
    end
  endfunction

  assign push_count = valid_count(push_valid_i);
  assign free_count = ENTRIES[COUNT_W-1:0] - count_q;
  assign push_ready_o = !recovery_i.valid && (push_valid_i != 2'b10) &&
                        (push_count <= free_count);
  assign push_fire = push_ready_o && (push_valid_i != 2'b00);
  assign empty_o = (count_q == '0);
  assign full_o = (count_q == ENTRIES[COUNT_W-1:0]);
  assign occupancy_o = count_q;
  assign candidate_valid_o = candidate_valid_q;
  assign candidate_uop0_o = candidate_valid_q[0] ?
                             candidate_from_slot(candidate_slot_q[0]) : '0;
  assign candidate_uop1_o = ((GROUPS > 1) && candidate_valid_q[1]) ?
                             candidate_from_slot(candidate_slot_q[1]) : '0;
  assign candidate_uop2_o = ((GROUPS > 2) && candidate_valid_q[2]) ?
                             candidate_from_slot(candidate_slot_q[2]) : '0;
  assign candidate_slot0_o = candidate_slot_q[0];
  assign candidate_slot1_o = (GROUPS > 1) ? candidate_slot_q[1] : '0;
  assign candidate_slot2_o = (GROUPS > 2) ? candidate_slot_q[2] : '0;

  always_ff @(posedge clk_i) begin : issue_queue_state
    integer idx;
    integer group_idx;
    integer pair_idx;
    integer pair_local_idx;
    integer pair_linear_idx;
    integer local_idx;
    integer slot_idx;
    logic [ENTRIES-1:0] valid_next;
    logic [ENTRIES-1:0] src1_ready_next;
    logic [ENTRIES-1:0] src2_ready_next;
    logic [CHECKPOINTS-1:0] branch_mask_next [0:ENTRIES-1];
    logic [COUNT_W-1:0] count_next;
    logic [SLOT_W-1:0] push_slot0;
    logic [SLOT_W-1:0] push_slot1;
    logic found0;
    logic found1;
    logic selected;
    logic slot_ready;
    logic [SLOT_W-1:0] selected_slot;
    logic [ROB_ID_W-1:0] selected_rob_id;
    logic [CHECKPOINTS-1:0] clear_mask;

    if (rst_i) begin
      valid_q <= '0;
      src1_ready_q <= '0;
      src2_ready_q <= '0;
      need_rs1_q <= '0;
      need_rs2_q <= '0;
      for (idx = 0; idx < ENTRIES; idx = idx + 1) begin
        rob_id_q[idx] <= '0;
        prs1_q[idx] <= '0;
        prs2_q[idx] <= '0;
        branch_mask_q[idx] <= '0;
        payload_q[idx] <= '0;
      end
      count_q <= '0;
      pair_valid_q <= '0;
      candidate_valid_q <= '0;
      clear_valid_q <= '0;
      for (pair_idx = 0; pair_idx < PAIR_COUNT; pair_idx = pair_idx + 1) begin
        pair_slot_q[pair_idx] <= '0;
        pair_rob_id_q[pair_idx] <= '0;
      end
      for (group_idx = 0; group_idx < GROUPS; group_idx = group_idx + 1) begin
        candidate_slot_q[group_idx] <= '0;
        clear_slot_q[group_idx] <= '0;
      end
    end else begin
      valid_next = valid_q;
      src1_ready_next = src1_ready_q;
      src2_ready_next = src2_ready_q;
      for (idx = 0; idx < ENTRIES; idx = idx + 1)
        branch_mask_next[idx] = branch_mask_q[idx];
      count_next = count_q;

      if (recovery_i.valid) begin
        if (recovery_i.cause == REC_EXCEPT) begin
          valid_next = '0;
          count_next = '0;
          clear_valid_q <= '0;
        end else if (recovery_i.cause == REC_BRANCH) begin
          clear_mask = ~(logic'(1'b1) << recovery_i.checkpoint_id);
          count_next = '0;
          clear_valid_q <= '0;
          for (idx = 0; idx < ENTRIES; idx = idx + 1) begin
            if (valid_next[idx] && branch_mask_next[idx][recovery_i.checkpoint_id]) begin
              valid_next[idx] = 1'b0;
            end else if (valid_next[idx]) begin
              branch_mask_next[idx] = branch_mask_next[idx] & clear_mask;
              count_next = count_next + 1'b1;
            end
          end
        end
      end else begin
        for (group_idx = 0; group_idx < GROUPS; group_idx = group_idx + 1) begin
          if (clear_valid_q[group_idx] && valid_next[clear_slot_q[group_idx]]) begin
            valid_next[clear_slot_q[group_idx]] = 1'b0;
            count_next = count_next - 1'b1;
          end
        end
        clear_valid_q <= issue_grant_i & candidate_valid_q;
        for (group_idx = 0; group_idx < GROUPS; group_idx = group_idx + 1)
          clear_slot_q[group_idx] <= candidate_slot_q[group_idx];

        for (idx = 0; idx < ENTRIES; idx = idx + 1) begin
          if (valid_next[idx]) begin
            src1_ready_next[idx] = wake_src(src1_ready_next[idx],
                                            need_rs1_q[idx],
                                            prs1_q[idx]);
            src2_ready_next[idx] = wake_src(src2_ready_next[idx],
                                            need_rs2_q[idx],
                                            prs2_q[idx]);
          end
        end

        if (push_fire) begin
          found0 = 1'b0;
          found1 = 1'b0;
          push_slot0 = '0;
          push_slot1 = '0;
          for (idx = 0; idx < ENTRIES; idx = idx + 1) begin
            // Allocation deliberately observes only the cycle-start valid map.
            // A slot freed by deferred clear in this cycle is not reused until
            // the following cycle.  This cuts clear_slot -> free-search ->
            // payload CE timing paths.
            if (!found0 && !valid_q[idx]) begin
              found0 = 1'b1;
              push_slot0 = idx[SLOT_W-1:0];
            end else if (!found1 && !valid_q[idx]) begin
              found1 = 1'b1;
              push_slot1 = idx[SLOT_W-1:0];
            end
          end

          valid_next[push_slot0] = push_valid_i[0];
          payload_q[push_slot0] <= push_uop0_i;
          rob_id_q[push_slot0] <= push_uop0_i.rob_id;
          prs1_q[push_slot0] <= push_uop0_i.prs1;
          prs2_q[push_slot0] <= push_uop0_i.prs2;
          need_rs1_q[push_slot0] <= push_uop0_i.need_rs1;
          need_rs2_q[push_slot0] <= push_uop0_i.need_rs2;
          branch_mask_q[push_slot0] <= push_uop0_i.branch_mask;
          branch_mask_next[push_slot0] = push_uop0_i.branch_mask;
          src1_ready_next[push_slot0] = wake_src(push_uop0_i.src1_ready,
                                                 push_uop0_i.need_rs1,
                                                 push_uop0_i.prs1);
          src2_ready_next[push_slot0] = wake_src(push_uop0_i.src2_ready,
                                                 push_uop0_i.need_rs2,
                                                 push_uop0_i.prs2);

          if (push_valid_i[1]) begin
            valid_next[push_slot1] = 1'b1;
            payload_q[push_slot1] <= push_uop1_i;
            rob_id_q[push_slot1] <= push_uop1_i.rob_id;
            prs1_q[push_slot1] <= push_uop1_i.prs1;
            prs2_q[push_slot1] <= push_uop1_i.prs2;
            need_rs1_q[push_slot1] <= push_uop1_i.need_rs1;
            need_rs2_q[push_slot1] <= push_uop1_i.need_rs2;
            branch_mask_q[push_slot1] <= push_uop1_i.branch_mask;
            branch_mask_next[push_slot1] = push_uop1_i.branch_mask;
            src1_ready_next[push_slot1] = wake_src(push_uop1_i.src1_ready,
                                                   push_uop1_i.need_rs1,
                                                   push_uop1_i.prs1);
            src2_ready_next[push_slot1] = wake_src(push_uop1_i.src2_ready,
                                                   push_uop1_i.need_rs2,
                                                   push_uop1_i.prs2);
          end
          count_next = count_next + push_count;
        end
      end

      if (recovery_i.valid) begin
        candidate_valid_q <= '0;
        pair_valid_q <= '0;
        for (pair_idx = 0; pair_idx < PAIR_COUNT; pair_idx = pair_idx + 1) begin
          pair_slot_q[pair_idx] <= '0;
          pair_rob_id_q[pair_idx] <= '0;
        end
        for (group_idx = 0; group_idx < GROUPS; group_idx = group_idx + 1) begin
          candidate_slot_q[group_idx] <= '0;
        end
      end else begin
        // Stage S1: select the oldest registered pair winner in each group.
        // The grant cycle bubbles the visible candidate for that group.  S0
        // below already excludes the granted slot, so the next surviving
        // candidate can appear when the deferred clear is applied.
        for (group_idx = 0; group_idx < GROUPS; group_idx = group_idx + 1) begin
          selected = 1'b0;
          selected_slot = '0;
          selected_rob_id = '0;
          for (pair_idx = 0; pair_idx < PAIRS_PER_GROUP; pair_idx = pair_idx + 1) begin
            pair_linear_idx = group_idx * PAIRS_PER_GROUP + pair_idx;
            if (pair_valid_q[pair_linear_idx] && (!selected ||
                is_older(pair_rob_id_q[pair_linear_idx], selected_rob_id))) begin
              selected = 1'b1;
              selected_slot = pair_slot_q[pair_linear_idx];
              selected_rob_id = pair_rob_id_q[pair_linear_idx];
            end
          end
          if (issue_grant_i[group_idx] && candidate_valid_q[group_idx])
            candidate_valid_q[group_idx] <= 1'b0;
          else
            candidate_valid_q[group_idx] <= selected;
          candidate_slot_q[group_idx] <= selected_slot;
        end

        // Stage S0: reduce each 2-entry pair to one local winner.  This keeps
        // the storage/ready wakeup path out of the final group candidate mux.
        // Exclude the visible grant and the deferred-clear slot so stale
        // entries cannot be reintroduced into S1 while physical valid bits are
        // being updated.
        for (group_idx = 0; group_idx < GROUPS; group_idx = group_idx + 1) begin
          for (pair_idx = 0; pair_idx < PAIRS_PER_GROUP; pair_idx = pair_idx + 1) begin
            selected = 1'b0;
            selected_slot = '0;
            selected_rob_id = '0;
            pair_linear_idx = group_idx * PAIRS_PER_GROUP + pair_idx;
            for (pair_local_idx = 0; pair_local_idx < 2; pair_local_idx = pair_local_idx + 1) begin
              local_idx = pair_idx * 2 + pair_local_idx;
              if (local_idx < GROUP_SIZE) begin
                slot_idx = group_idx * GROUP_SIZE + local_idx;
                slot_ready = valid_q[slot_idx] &&
                             !(issue_grant_i[group_idx] &&
                               candidate_valid_q[group_idx] &&
                               (candidate_slot_q[group_idx] == slot_idx[SLOT_W-1:0])) &&
                             !(clear_valid_q[group_idx] &&
                               (clear_slot_q[group_idx] == slot_idx[SLOT_W-1:0])) &&
                             (!need_rs1_q[slot_idx] || src1_ready_q[slot_idx]) &&
                             (!need_rs2_q[slot_idx] || src2_ready_q[slot_idx]);
                if (slot_ready && (!selected ||
                    is_older(rob_id_q[slot_idx], selected_rob_id))) begin
                  selected = 1'b1;
                  selected_slot = slot_idx[SLOT_W-1:0];
                  selected_rob_id = rob_id_q[slot_idx];
                end
              end
            end
            pair_valid_q[pair_linear_idx] <= selected;
            pair_slot_q[pair_linear_idx] <= selected_slot;
            pair_rob_id_q[pair_linear_idx] <= selected_rob_id;
          end
        end
      end

      valid_q <= valid_next;
      src1_ready_q <= src1_ready_next;
      src2_ready_q <= src2_ready_next;
      for (idx = 0; idx < ENTRIES; idx = idx + 1)
        branch_mask_q[idx] <= branch_mask_next[idx];
      count_q <= count_next;
    end
  end

endmodule
