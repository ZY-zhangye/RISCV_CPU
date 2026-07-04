import core_types_pkg::*;

// Rename-to-Issue elastic boundary.
// Six-entry circular buffer, in-order dispatch, and class-compacted push ports
// for Integer/Branch/CSR, Memory, and MDU issue queues.
module dispatch_buffer (
    input  logic        clk_i,
    input  logic        rst_i,

    input  logic [1:0]  rn_valid_i,
    output logic        rn_ready_o,
    input  renamed_uop_t rn_uop0_i,
    input  renamed_uop_t rn_uop1_i,

    output logic [1:0]  int_push_valid_o,
    input  logic [1:0]  int_push_ready_i,
    output issue_uop_t  int_push_uop0_o,
    output issue_uop_t  int_push_uop1_o,

    output logic [1:0]  mem_push_valid_o,
    input  logic [1:0]  mem_push_ready_i,
    output issue_uop_t  mem_push_uop0_o,
    output issue_uop_t  mem_push_uop1_o,

    output logic [1:0]  mdu_push_valid_o,
    input  logic [1:0]  mdu_push_ready_i,
    output issue_uop_t  mdu_push_uop0_o,
    output issue_uop_t  mdu_push_uop1_o,

    input  recovery_t   recovery_i,

    output logic        empty_o,
    output logic        full_o,
    output logic [2:0]  occupancy_o
);

  localparam int DB_ENTRIES = 6;
  localparam int PTR_W = 3;

  typedef enum logic [1:0] {
    CLASS_INT = 2'd0,
    CLASS_MEM = 2'd1,
    CLASS_MDU = 2'd2
  } dispatch_class_t;

  logic [DB_ENTRIES-1:0] valid_q;
  renamed_uop_t uop_q [0:DB_ENTRIES-1];
  logic [PTR_W-1:0] head_q;
  logic [PTR_W-1:0] tail_q;
  logic [PTR_W-1:0] count_q;

  renamed_uop_t head0_uop;
  renamed_uop_t head1_uop;
  issue_uop_t head0_issue;
  issue_uop_t head1_issue;
  dispatch_class_t head0_class;
  dispatch_class_t head1_class;
  logic head0_valid;
  logic head1_valid;
  logic dispatch0_fire;
  logic dispatch1_fire;
  logic [1:0] dispatch_count;
  logic [1:0] rn_count;
  logic [PTR_W-1:0] head1_ptr;
  logic [PTR_W-1:0] tail1_ptr;

  function automatic logic [PTR_W-1:0] ptr_inc(input logic [PTR_W-1:0] ptr);
    ptr_inc = (ptr == DB_ENTRIES - 1) ? '0 : ptr + 1'b1;
  endfunction

  function automatic logic [PTR_W-1:0] ptr_add2(input logic [PTR_W-1:0] ptr);
    ptr_add2 = ptr_inc(ptr_inc(ptr));
  endfunction

  function automatic logic [1:0] valid_count(input logic [1:0] valid);
    valid_count = (valid == 2'b11) ? 2'd2 :
                  ((valid == 2'b01) ? 2'd1 : 2'd0);
  endfunction

  function automatic dispatch_class_t classify(input renamed_uop_t uop);
    begin
      case (uop.dec.fu_type)
        FU_LSU:
          classify = CLASS_MEM;
        FU_MUL, FU_DIV:
          classify = CLASS_MDU;
        default:
          classify = CLASS_INT;
      endcase
    end
  endfunction

  function automatic issue_uop_t to_issue(input renamed_uop_t uop);
    issue_uop_t issue;
    begin
      issue = '0;
      issue.prd = uop.prd;
      issue.prs1 = uop.prs1;
      issue.prs2 = uop.prs2;
      issue.src1_ready = uop.src1_ready;
      issue.src2_ready = uop.src2_ready;
      issue.imm = uop.dec.imm;
      issue.fu_type = uop.dec.fu_type;
      issue.alu_op = uop.dec.alu_op;
      issue.branch_op = uop.dec.branch_op;
      issue.mem_op = uop.dec.mem_op;
      issue.mul_op = uop.dec.mul_op;
      issue.div_op = uop.dec.div_op;
      issue.csr_op = uop.dec.csr_op;
      issue.csr_addr = uop.dec.csr_addr;
      issue.csr_zimm = uop.dec.csr_zimm;
      issue.rob_id = uop.rob_id;
      issue.old_prd = uop.old_prd;
      issue.lq_id = uop.lq_id;
      issue.sq_id = uop.sq_id;
      issue.branch_mask = uop.branch_mask;
      issue.write_rd = uop.dec.write_rd;
      issue.is_load = (uop.dec.fu_type == FU_LSU) &&
          ((uop.dec.mem_op == MEM_LB) || (uop.dec.mem_op == MEM_LH) ||
           (uop.dec.mem_op == MEM_LW) || (uop.dec.mem_op == MEM_LBU) ||
           (uop.dec.mem_op == MEM_LHU));
      issue.is_store = (uop.dec.fu_type == FU_LSU) &&
          ((uop.dec.mem_op == MEM_SB) || (uop.dec.mem_op == MEM_SH) ||
           (uop.dec.mem_op == MEM_SW));
      issue.serializing = uop.dec.serializing;
      issue.need_rs1 = uop.dec.need_rs1;
      issue.need_rs2 = uop.dec.need_rs2;
      return issue;
    end
  endfunction

  function automatic logic class_ready_one(
      input dispatch_class_t cls,
      input logic [1:0] int_ready,
      input logic [1:0] mem_ready,
      input logic [1:0] mdu_ready
  );
    begin
      case (cls)
        CLASS_MEM:
          class_ready_one = mem_ready[0];
        CLASS_MDU:
          class_ready_one = mdu_ready[0];
        default:
          class_ready_one = int_ready[0];
      endcase
    end
  endfunction

  function automatic logic class_ready_two(
      input dispatch_class_t cls,
      input logic [1:0] int_ready,
      input logic [1:0] mem_ready,
      input logic [1:0] mdu_ready
  );
    begin
      case (cls)
        CLASS_MEM:
          class_ready_two = mem_ready[1];
        CLASS_MDU:
          class_ready_two = mdu_ready[1];
        default:
          class_ready_two = int_ready[1];
      endcase
    end
  endfunction

  assign rn_count = valid_count(rn_valid_i);
  assign rn_ready_o = !recovery_i.valid && (rn_valid_i != 2'b10) &&
                      (rn_count <= (DB_ENTRIES[PTR_W-1:0] - count_q));

  assign empty_o = (count_q == '0);
  assign full_o = (count_q == DB_ENTRIES[PTR_W-1:0]);
  assign occupancy_o = count_q;

  assign head1_ptr = ptr_inc(head_q);
  assign tail1_ptr = ptr_inc(tail_q);
  assign head0_valid = valid_q[head_q] && (count_q != '0);
  assign head1_valid = valid_q[head1_ptr] && (count_q >= 3'd2);
  assign head0_uop = uop_q[head_q];
  assign head1_uop = uop_q[head1_ptr];
  assign head0_issue = to_issue(head0_uop);
  assign head1_issue = to_issue(head1_uop);
  assign head0_class = classify(head0_uop);
  assign head1_class = classify(head1_uop);

  assign dispatch0_fire = head0_valid &&
                          class_ready_one(head0_class, int_push_ready_i,
                                          mem_push_ready_i, mdu_push_ready_i);
  assign dispatch1_fire = dispatch0_fire && head1_valid &&
      ((head1_class == head0_class) ?
       class_ready_two(head1_class, int_push_ready_i, mem_push_ready_i,
                       mdu_push_ready_i) :
       class_ready_one(head1_class, int_push_ready_i, mem_push_ready_i,
                       mdu_push_ready_i));
  assign dispatch_count = {1'b0, dispatch0_fire} + {1'b0, dispatch1_fire};

  always_comb begin
    int_push_valid_o = 2'b00;
    mem_push_valid_o = 2'b00;
    mdu_push_valid_o = 2'b00;
    int_push_uop0_o = '0;
    int_push_uop1_o = '0;
    mem_push_uop0_o = '0;
    mem_push_uop1_o = '0;
    mdu_push_uop0_o = '0;
    mdu_push_uop1_o = '0;

    if (dispatch0_fire) begin
      case (head0_class)
        CLASS_MEM: begin
          mem_push_valid_o[0] = 1'b1;
          mem_push_uop0_o = head0_issue;
        end
        CLASS_MDU: begin
          mdu_push_valid_o[0] = 1'b1;
          mdu_push_uop0_o = head0_issue;
        end
        default: begin
          int_push_valid_o[0] = 1'b1;
          int_push_uop0_o = head0_issue;
        end
      endcase
    end

    if (dispatch1_fire) begin
      case (head1_class)
        CLASS_MEM: begin
          if (mem_push_valid_o[0]) begin
            mem_push_valid_o[1] = 1'b1;
            mem_push_uop1_o = head1_issue;
          end else begin
            mem_push_valid_o[0] = 1'b1;
            mem_push_uop0_o = head1_issue;
          end
        end
        CLASS_MDU: begin
          if (mdu_push_valid_o[0]) begin
            mdu_push_valid_o[1] = 1'b1;
            mdu_push_uop1_o = head1_issue;
          end else begin
            mdu_push_valid_o[0] = 1'b1;
            mdu_push_uop0_o = head1_issue;
          end
        end
        default: begin
          if (int_push_valid_o[0]) begin
            int_push_valid_o[1] = 1'b1;
            int_push_uop1_o = head1_issue;
          end else begin
            int_push_valid_o[0] = 1'b1;
            int_push_uop0_o = head1_issue;
          end
        end
      endcase
    end
  end

  always_ff @(posedge clk_i) begin : dispatch_buffer_state
    integer idx;
    logic [PTR_W-1:0] next_head;
    logic [PTR_W-1:0] next_tail;
    logic [PTR_W:0] next_count;

    if (rst_i) begin
      valid_q <= '0;
      for (idx = 0; idx < DB_ENTRIES; idx = idx + 1)
        uop_q[idx] <= '0;
      head_q <= '0;
      tail_q <= '0;
      count_q <= '0;
    end else if (recovery_i.valid) begin
      // V1 flushes the dispatch boundary on any recovery.  Selective mask clear
      // in a fixed-slot queue can create head holes; preserving survivors is a
      // later optimization if recovery refill cost becomes measurable.
      valid_q <= '0;
      head_q <= '0;
      tail_q <= '0;
      count_q <= '0;
    end else begin
      next_head = head_q;
      next_tail = tail_q;
      next_count = {1'b0, count_q};

      if (dispatch_count != 0) begin
        valid_q[head_q] <= 1'b0;
        if (dispatch_count == 2'd2)
          valid_q[head1_ptr] <= 1'b0;
        next_head = (dispatch_count == 2'd2) ? ptr_add2(head_q) :
                                              ptr_inc(head_q);
        next_count = next_count - dispatch_count;
      end

      if ((rn_valid_i != 2'b00) && rn_ready_o) begin
        valid_q[tail_q] <= rn_valid_i[0];
        uop_q[tail_q] <= rn_uop0_i;
        if (rn_valid_i[1]) begin
          valid_q[tail1_ptr] <= 1'b1;
          uop_q[tail1_ptr] <= rn_uop1_i;
        end
        next_tail = rn_valid_i[1] ? ptr_add2(tail_q) : ptr_inc(tail_q);
        next_count = next_count + rn_count;
      end

      head_q <= next_head;
      tail_q <= next_tail;
      count_q <= next_count[PTR_W-1:0];
    end
  end

endmodule
