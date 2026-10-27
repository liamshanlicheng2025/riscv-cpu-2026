module v2_select #(
  parameter integer ENTRIES=8, SLOT_BITS=5, INDEX_BITS=$clog2(ENTRIES), YOUNGEST=0, PREFIX_HEAD=0, REGISTERED_WRAP=0
)(
  input logic [ENTRIES-1:0] ready,
  input logic [ENTRIES*SLOT_BITS-1:0] owner,
  input logic [SLOT_BITS-1:0] rob_head,
  input logic [(2**SLOT_BITS)-1:0] head_prefix,
  input logic [ENTRIES-1:0] wrapped_owner,
  output logic valid,
  output logic [INDEX_BITS-1:0] index
);
  localparam integer LEAVES=2**$clog2(ENTRIES);
  // Give every level its own scalar wires. Older Verilator versions treat a
  // shared unpacked array as one dependency and misidentify a tree as a loop.
  for (genvar n=1;n<2*LEAVES;n=n+1) begin: node
    wire [SLOT_BITS-1:0] slot;
    wire wrapped;
    wire [INDEX_BITS-1:0] selected;
    wire winner;
    if(n>=LEAVES) begin: leaf
      if(n-LEAVES<ENTRIES) begin: used
        assign slot=owner[(n-LEAVES)*SLOT_BITS+:SLOT_BITS];
        assign wrapped=REGISTERED_WRAP!=0 ? wrapped_owner[n-LEAVES]:PREFIX_HEAD!=0 ? head_prefix[slot]:slot<rob_head;
        assign winner=ready[n-LEAVES];
      end else begin: padding
        assign slot=0;assign wrapped=0;assign winner=0;
      end
      assign selected=INDEX_BITS'(n-LEAVES);
    end else begin: branch
      wire left_older=node[2*n].wrapped!=node[2*n+1].wrapped ?
        !node[2*n].wrapped:node[2*n].slot<=node[2*n+1].slot;
      wire left_younger=node[2*n].wrapped!=node[2*n+1].wrapped ?
        node[2*n].wrapped:node[2*n].slot>=node[2*n+1].slot;
      wire left_wins=node[2*n].winner && (!node[2*n+1].winner ||
        (YOUNGEST!=0 ? left_younger:left_older));
      assign winner=node[2*n].winner || node[2*n+1].winner;
      assign selected=left_wins ? node[2*n].selected:node[2*n+1].selected;
      assign slot=left_wins ? node[2*n].slot:node[2*n+1].slot;
      assign wrapped=left_wins ? node[2*n].wrapped:node[2*n+1].wrapped;
    end
  end
  assign valid=node[1].winner;
  assign index=node[1].selected;
endmodule
