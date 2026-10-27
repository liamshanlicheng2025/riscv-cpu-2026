// Eight four-bit sums prepare their local carry in parallel. Group carry
// lookahead avoids putting a full-width carry chain after operand selection.
(* verilator_fast_eval = 1 *) module v2_add32 #(
  parameter integer SIM_FAST=
`ifdef VERILATOR
  1
`else
  0
`endif
) (
  input wire [31:0] a,b,
  output wire [31:0] sum
);
  /* verilator inline_module */
  /* verilator tracing_off */
  wire [31:0] grouped_sum;
  assign sum=SIM_FAST!=0 && ((^a)!==1'bx) && ((^b)!==1'bx) ? a+b:grouped_sum;
  wire [7:0] propagate,generate_carry;
  wire [8:0] carry;
  assign carry[0]=0;
  for(genvar group_index=0;group_index<8;group_index=group_index+1) begin: groups
    wire [4:0] local_sum={1'b0,a[group_index*4+:4]}+{1'b0,b[group_index*4+:4]};
    assign propagate[group_index]=&(a[group_index*4+:4]^b[group_index*4+:4]);
    assign generate_carry[group_index]=local_sum[4];
    wire [group_index:0] terms;
    for(genvar origin=0;origin<=group_index;origin=origin+1) begin: prefix_terms
      if(origin==group_index) begin: direct
        assign terms[origin]=generate_carry[origin];
      end else begin: propagated
        assign terms[origin]=generate_carry[origin] && (&propagate[group_index:origin+1]);
      end
    end
    assign carry[group_index+1]=|terms;
    assign grouped_sum[group_index*4+:4]=local_sum[3:0]+{3'd0,carry[group_index]};
  end
endmodule
