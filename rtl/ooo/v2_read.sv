// Hardware uses a balanced decoded OR tree. The equivalent simulator
// expression avoids evaluating every masked word on every clock edge.
(* verilator_fast_eval = 1 *) module v2_read #(
  parameter integer WIDTH=32, ENTRIES=32, INDEX_BITS=$clog2(ENTRIES), ONEHOT=0,
  parameter integer SIM_FAST=
`ifdef VERILATOR
  1
`else
  0
`endif
)(
  input logic [INDEX_BITS-1:0] index,
  input logic [ENTRIES-1:0] select,
  input logic [ENTRIES*WIDTH-1:0] words,
  output wire [WIDTH-1:0] value
);
  /* verilator inline_module */
  /* verilator tracing_off */
  localparam integer LEAVES=2**$clog2(ENTRIES);
  if(SIM_FAST!=0) begin: simulator_read
    logic [WIDTH-1:0] selected_word;
    always_comb begin
      selected_word='0;
      if(ONEHOT==0 && INDEX_BITS>=$clog2(ENTRIES) && INDEX_BITS<32 && ((^index)!==1'bx)) begin
        if(int'(index)<ENTRIES) selected_word=words[int'(index)*WIDTH+:WIDTH] & {WIDTH{1'b1}};
      end else if(ONEHOT!=0 && ((^select)!==1'bx)) begin
        for(integer row=0;row<ENTRIES;row=row+1)
          if(select[row]) selected_word=selected_word | words[row*WIDTH+:WIDTH];
      end else begin
        // Preserve duplicate matches with a narrow overridden index, and
        // the original four-state propagation when any selector bit is X/Z.
        for(integer row=0;row<ENTRIES;row=row+1)
          selected_word=selected_word | (words[row*WIDTH+:WIDTH] &
            {WIDTH{ONEHOT!=0 ? select[row]:index==INDEX_BITS'(row)}});
      end
    end
    assign value=selected_word;
  end else begin: decoded_tree
    for(genvar n=1;n<2*LEAVES;n=n+1) begin: node
      wire [WIDTH-1:0] bits;
      if(n>=LEAVES) begin: leaf
        if(n-LEAVES<ENTRIES) begin: used
          wire selected=ONEHOT!=0 ? select[n-LEAVES]:index==INDEX_BITS'(n-LEAVES);
          assign bits=words[(n-LEAVES)*WIDTH+:WIDTH] & {WIDTH{selected}};
        end else begin: padding
          assign bits='0;
        end
      end else begin: branch
        assign bits=node[2*n].bits | node[2*n+1].bits;
      end
    end
    assign value=node[1].bits;
  end
endmodule
