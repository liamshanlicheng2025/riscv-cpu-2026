// Dispatch is in program order, with at most one allocation per bank per
// cycle. Every new slot is younger than all surviving slots. Keeping those
// pairwise relations removes ROB-tag comparisons from the issue path.
module v2_age_matrix #(
  parameter integer ENTRIES=8
)(
  input wire clk,rst,
  input wire [ENTRIES-1:0] allocate,ready,
  output wire [ENTRIES-1:0] grant
);
  wire [ENTRIES-1:0] older[ENTRIES];
  // Keep pair storage at module scope: some synthesis frontends do not
  // resolve a mirrored reference into an if/else-generated sibling scope.
  logic [ENTRIES*(ENTRIES-1)/2-1:0] precedes;
  for(genvar row=0;row<ENTRIES;row=row+1) begin: rows
    for(genvar other=0;other<ENTRIES;other=other+1) begin: columns
      if(row==other) begin: diagonal
        assign older[row][other]=0;
      end else if(row<other) begin: relation
        localparam integer PAIR=row*(2*ENTRIES-row-1)/2+other-row-1;
        always_ff @(posedge clk) begin
          if(rst) precedes[PAIR]<=0;
          else if(allocate[row]) precedes[PAIR]<=1;
          else if(allocate[other]) precedes[PAIR]<=0;
        end
        assign older[row][other]=precedes[PAIR];
      end else begin: mirrored_relation
        // One bit describes a pair. Reset ordering among invalid entries
        // is irrelevant; allocating either member establishes its age.
        localparam integer PAIR=other*(2*ENTRIES-other-1)/2+row-other-1;
        assign older[row][other]=~precedes[PAIR];
      end
    end
    assign grant[row]=ready[row] && !(|(older[row] & ready));
  end
`ifndef SYNTHESIS
  always_ff @(posedge clk) if(!rst)
    assert($onehot0(allocate)) else $fatal(1,"multiple allocations to one issue bank");
`endif
endmodule
