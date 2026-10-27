module muldiv #(
  parameter integer DIV_STEP_BITS=4, ENABLE_DIV_CACHE=1, TAG_BITS=8
)(
  input logic clk, rst, kill,
  input logic [255:0] kill_mask,
  input logic req_valid,
  output logic req_ready,
  output logic mul_ready,div_ready,
  input cpu_pkg::op_t req_op,
  input logic [31:0] req_a, req_b,
  input logic [7:0] req_tag,
  output logic rsp_valid,
  input logic rsp_ready,
  output logic [31:0] rsp_result,
  output logic [7:0] rsp_tag
);
  import cpu_pkg::*;
  localparam integer DIV_STEPS=32/DIV_STEP_BITS;
  localparam integer STEP_W=$clog2(DIV_STEPS);

  // Complete the arithmetic in one cycle, then retain up to three pending
  // results independently of the shared output register. Empty queues bypass
  // directly into that output; blocked results retain oldest-first ordering.
  logic [2:0] mul_valid_q,mul_live,mul_remaining;
  logic mul_ready0,mul_ready1,mul_ready2;
  logic [1:0] mul_head;
  logic [TAG_BITS-1:0] mul_tag_q [3];
  logic [31:0] mul_result_q [3];
  logic [31:0] mul_computed,correction_a,correction_b;
  logic [63:0] product;
  logic grant_new_mul;

  // 乘法输入打一拍，切断 issue/forwarding -> 32x32 multiplier -> result queue 的长路径。
  logic mul_req_valid_q;
  logic [5:0] mul_req_op_q;
  logic [31:0] mul_req_a_q,mul_req_b_q;
  logic [TAG_BITS-1:0] mul_req_tag_q;
  wire [TAG_BITS-1:0] mul_req_owner=mul_req_tag_q[TAG_BITS-1:0];

  logic div_busy_q,div_done_q;
  (* keep *) logic [TAG_BITS-1:0] div_tag_q;
  (* keep *) logic [31:0] quotient_q,divisor_q,div_result_q;
  (* keep *) logic [32:0] remainder_q;
  logic [STEP_W-1:0] step_q;
  logic quotient_negative_q,remainder_negative_q,remainder_operation_q;
  logic [31:0] quotient_next;
  logic [32:0] remainder_next,shifted,difference;
  (* keep *) logic [31:0] div_a_q,div_b_q;
  logic [31:0] completed_quotient,completed_remainder;
  logic div_signed_q;
  logic cache_valid_q,cache_signed_q,cache_hit;
  logic [31:0] cache_a_q,cache_b_q,cache_quotient_q,cache_remainder_q;
  logic shortcut;
  logic [31:0] shortcut_quotient,shortcut_remainder;
  integer leading_steps;

  logic out_valid_q,prefer_div_q,out_space,grant_mul,grant_div;
  (* keep *) logic [31:0] out_result_q;
  (* keep *) logic [TAG_BITS-1:0] out_tag_q;
  wire [TAG_BITS-1:0] req_owner=req_tag[TAG_BITS-1:0];
  wire [2**TAG_BITS-1:0] active_kill=kill_mask[2**TAG_BITS-1:0];
  logic request_mul,request_div,signed_divide,a_negative,b_negative;
  logic [31:0] a_magnitude,b_magnitude;
  logic div_live,div_result_live;

  assign request_mul=req_op>=OP_MUL && req_op<=OP_MULHU;
  assign request_div=req_op>=OP_DIV && req_op<=OP_REMU;
  assign signed_divide=req_op==OP_DIV || req_op==OP_REM;
  assign a_negative=signed_divide && req_a[31];
  assign b_negative=signed_divide && req_b[31];
  assign a_magnitude=a_negative ? (~req_a+32'd1) : req_a;
  assign b_magnitude=b_negative ? (~req_b+32'd1) : req_b;
  assign div_live=div_busy_q && !active_kill[div_tag_q];
  assign div_result_live=div_done_q && !active_kill[div_tag_q];
  assign rsp_valid=out_valid_q && !active_kill[out_tag_q] && !kill && !rst;
  assign rsp_result=out_result_q;
  assign rsp_tag=8'(out_tag_q);
  assign out_space=!out_valid_q || active_kill[out_tag_q] || rsp_ready;
  for(genvar stage=0;stage<3;stage=stage+1) begin : g_live
    assign mul_live[stage]=mul_valid_q[stage] && !active_kill[mul_tag_q[stage]];
    assign mul_remaining[stage]=mul_live[stage] && !(grant_mul && mul_head==2'(stage));
  end
  assign mul_head=mul_live[2] ? 2'd2 : mul_live[1] ? 2'd1 : 2'd0;
  assign grant_div=out_space && div_result_live && (!(|mul_live) || prefer_div_q);
  assign grant_mul=out_space && (|mul_live) && (!div_result_live || !prefer_div_q);
  assign mul_ready2=!mul_remaining[2];
  assign mul_ready1=!mul_remaining[1] || mul_ready2;
  assign mul_ready0=!mul_remaining[0] || mul_ready1;
  // Scheduler hints describe unit capacity before a request opcode/tag is chosen.
  assign mul_ready=!rst && !kill && !mul_req_valid_q && mul_ready0;
  // Reopen the launch slot after its pending result has left the divider.
  // This removes output arbitration and response backpressure from the
  // operand/cache write enables. Cancellation releases the slot on the edge.
  assign div_ready=!rst && !kill && !div_busy_q && !div_done_q;
  assign req_ready=!active_kill[req_owner] &&
    ((request_mul && mul_ready) || (request_div && div_ready));
  // Fresh requests affect only the registered output/data inputs, never the
  // structural ready hints or arbitration of already-buffered results.
  assign grant_new_mul=out_space && !grant_mul && !grant_div && mul_req_valid_q && !active_kill[mul_req_owner];
  assign product=mul_req_a_q*mul_req_b_q;
  assign correction_a=mul_req_a_q[31] && (mul_req_op_q==OP_MULH || mul_req_op_q==OP_MULHSU) ? mul_req_b_q:32'd0;
  assign correction_b=mul_req_b_q[31] && mul_req_op_q==OP_MULH ? mul_req_a_q:32'd0;
  assign mul_computed=mul_req_op_q==OP_MUL ? product[31:0] : product[63:32]-correction_a-correction_b;
  assign cache_hit=ENABLE_DIV_CACHE!=0 && cache_valid_q && cache_a_q==req_a && cache_b_q==req_b && cache_signed_q==signed_divide;
  assign completed_quotient=quotient_negative_q ? (~quotient_next+32'd1) : quotient_next;
  assign completed_remainder=remainder_negative_q ? (~remainder_next[31:0]+32'd1) : remainder_next[31:0];

  // Skip only whole zero radix groups: those restoring steps produce neither
  // quotient bits nor a remainder. Preserve at least one group for nonzero a.
  always_comb begin
    leading_steps=0;
    for(integer groups=1;groups<DIV_STEPS;groups=groups+1)
      if((a_magnitude>>(32-DIV_STEP_BITS*groups))==0) leading_steps=groups;
    shortcut=1;shortcut_quotient=0;shortcut_remainder=0;
    if(req_b==0) begin shortcut_quotient=32'hffffffff;shortcut_remainder=req_a;end
    else if(signed_divide && req_a==32'h80000000 && req_b==32'hffffffff)
      shortcut_quotient=32'h80000000;
    else if(a_magnitude<b_magnitude || a_magnitude==0) shortcut_remainder=req_a;
    else if(b_magnitude==1)
      shortcut_quotient=(a_negative^b_negative) ? (~a_magnitude+32'd1) : a_magnitude;
    else shortcut=0;
  end

  // Radix 16 by four restoring steps per cycle. DIV_STEP_BITS=2 selects radix 4.
  always_comb begin
    quotient_next=quotient_q;
    remainder_next=remainder_q;
    shifted=0;difference=0;
    // The state write and completion publication below already require a
    // live divide. Let dead arithmetic evaluate without putting the live
    // tag/kill decision in front of every restoring step and result bit.
    for(integer bit_step=0;bit_step<DIV_STEP_BITS;bit_step=bit_step+1) begin
      shifted={remainder_next[31:0],quotient_next[31]};
      quotient_next={quotient_next[30:0],1'b0};
      // With remainder < divisor, the subtraction sign is the borrow
      // decision and its low bits are also the next remainder.
      difference=shifted-{1'b0,divisor_q};
      if(!difference[32]) begin
        remainder_next=difference;
        quotient_next[0]=1'b1;
      end else remainder_next=shifted;
    end
  end

  always_ff @(posedge clk) begin
      // Output arbitration only replaces a free/accepted/canceled response.
      if(out_space) begin
        out_valid_q<=grant_div || grant_mul || grant_new_mul;
        if(grant_div) begin
          out_result_q<=div_result_q;out_tag_q<=div_tag_q;prefer_div_q<=0;
        end else if(grant_mul) begin
          out_result_q<=mul_result_q[mul_head];out_tag_q<=mul_tag_q[mul_head];prefer_div_q<=1;
        end else if(grant_new_mul) begin
          out_result_q<=mul_computed;out_tag_q<=mul_req_owner;prefer_div_q<=1;
        end
      end

      if(mul_ready2) begin
        mul_valid_q[2]<=mul_remaining[1];
        if(mul_remaining[1]) begin
          mul_tag_q[2]<=mul_tag_q[1];mul_result_q[2]<=mul_result_q[1];
        end
      end
      if(mul_ready1) begin
        mul_valid_q[1]<=mul_remaining[0];
        if(mul_remaining[0]) begin
          mul_tag_q[1]<=mul_tag_q[0];mul_result_q[1]<=mul_result_q[0];
        end
      end
      if(mul_ready0) begin
        mul_valid_q[0]<=mul_req_valid_q && !active_kill[mul_req_owner] && !grant_new_mul;
        if(mul_req_valid_q && !active_kill[mul_req_owner] && !grant_new_mul) begin
          mul_tag_q[0]<=mul_req_owner;mul_result_q[0]<=mul_computed;
        end
      end

      // 采样新的乘法请求；结果在下一拍从 mul_req_*_q 计算。
      if(req_valid && req_ready && request_mul) begin
        mul_req_valid_q<=1'b1;
        mul_req_op_q<=req_op;
        mul_req_a_q<=req_a;
        mul_req_b_q<=req_b;
        mul_req_tag_q<=req_owner;
      end
      if(mul_req_valid_q &&
         (active_kill[mul_req_owner] || grant_new_mul ||
          (mul_ready0 && !grant_new_mul)))
        mul_req_valid_q<=1'b0;

      if(active_kill[div_tag_q]) begin div_busy_q<=0;div_done_q<=0;end
      if(grant_div) div_done_q<=0;
      if(div_live) begin
        quotient_q<=quotient_next;remainder_q<=remainder_next;
        step_q<=step_q+1'b1;
        if(step_q==STEP_W'(DIV_STEPS-1)) begin
          div_busy_q<=0;div_done_q<=1;
          div_result_q<=remainder_operation_q ? completed_remainder:completed_quotient;
          // This point is unreachable for a selectively killed partial divide.
          // Completed arithmetic is pure and may remain cached after tag cancel.
          if(ENABLE_DIV_CACHE!=0) begin
            cache_valid_q<=1;cache_a_q<=div_a_q;cache_b_q<=div_b_q;cache_signed_q<=div_signed_q;
            cache_quotient_q<=completed_quotient;cache_remainder_q<=completed_remainder;
          end
        end
      end
      if(req_valid && req_ready && request_div) begin
        div_tag_q<=req_owner;
        div_a_q<=req_a;div_b_q<=req_b;div_signed_q<=signed_divide;
        quotient_negative_q<=a_negative^b_negative;remainder_negative_q<=a_negative;
        remainder_operation_q<=req_op==OP_REM || req_op==OP_REMU;
        div_busy_q<=0;div_done_q<=1;
        if(cache_hit)
          div_result_q<=(req_op==OP_REM || req_op==OP_REMU) ? cache_remainder_q:cache_quotient_q;
        else if(shortcut) begin
          div_result_q<=(req_op==OP_REM || req_op==OP_REMU) ? shortcut_remainder:shortcut_quotient;
          if(ENABLE_DIV_CACHE!=0) begin
            cache_valid_q<=1;cache_a_q<=req_a;cache_b_q<=req_b;cache_signed_q<=signed_divide;
            cache_quotient_q<=shortcut_quotient;cache_remainder_q<=shortcut_remainder;
          end
        end else begin
          div_busy_q<=1;div_done_q<=0;step_q<=STEP_W'(leading_steps);
          quotient_q<=a_magnitude<<(leading_steps*DIV_STEP_BITS);
          divisor_q<=b_magnitude;remainder_q<=0;
        end
      end
    // Operands and launch metadata may be sampled whenever the divider can
    // accept work. The busy/done flags alone commit an actual divide request.
    // While a divide is active these fields stay frozen for arithmetic/cache.
    if(div_ready) begin
      div_tag_q<=req_owner;div_a_q<=req_a;div_b_q<=req_b;div_signed_q<=signed_divide;
      quotient_negative_q<=a_negative^b_negative;remainder_negative_q<=a_negative;
      remainder_operation_q<=req_op==OP_REM || req_op==OP_REMU;
      step_q<=STEP_W'(leading_steps);
      quotient_q<=a_magnitude<<(leading_steps*DIV_STEP_BITS);
      divisor_q<=b_magnitude;remainder_q<=0;
      div_result_q<=cache_hit ? ((req_op==OP_REM || req_op==OP_REMU) ? cache_remainder_q:cache_quotient_q):
        ((req_op==OP_REM || req_op==OP_REMU) ? shortcut_remainder:shortcut_quotient);
    end

    // Canceled payloads may keep changing; validity alone controls visibility.
    // Resetting hundreds of unobservable data bits creates a shared long path.
    if(rst || kill) begin
      mul_valid_q<=0;div_busy_q<=0;div_done_q<=0;cache_valid_q<=0;
      out_valid_q<=0;prefer_div_q<=1;mul_req_valid_q<=0;
    end

  end
`ifndef SYNTHESIS
  always_ff @(posedge clk) if(!rst && !kill) begin
    if(req_valid) assert(req_tag==8'(req_owner)) else $fatal(1,"request tag exceeds configured width");
    assert(!(div_busy_q && div_done_q)) else $fatal(1,"divider owns both compute and result slots");
    if(div_live) assert(divisor_q!=0 && remainder_q<{1'b0,divisor_q})
      else $fatal(1,"restoring divider remainder invariant");
  end
`endif
  initial begin
    if(TAG_BITS<1 || TAG_BITS>8) $fatal(1,"TAG_BITS must be between 1 and 8");
    if(DIV_STEP_BITS!=2 && DIV_STEP_BITS!=4) $fatal(1,"DIV_STEP_BITS must be 2 or 4");
  end
endmodule
