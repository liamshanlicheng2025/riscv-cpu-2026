// The physical slots of a circular FIFO already encode age. Select the
// highest matching slot below head, or the highest slot overall if none
// wraps. Keep the winner one-hot through the data mux, avoiding an encode /
// decode round trip and a tournament that carries dynamic owner tags.
module v2_ring_youngest #(
  parameter integer ENTRIES=16, INDEX_BITS=$clog2(ENTRIES)
)(
  input wire [ENTRIES-1:0] ready,
  input wire [INDEX_BITS-1:0] head,
  output wire valid,
  output wire [ENTRIES-1:0] select
);
  wire [ENTRIES-1:0] below,below_winner,all_winner;
  for(genvar row=0;row<ENTRIES;row=row+1) begin: rows
    if(row==ENTRIES-1) begin: no_wrap
      assign below[row]=1'b0;
    end else begin: wrap
      assign below[row]=ready[row] && INDEX_BITS'(row)<head;
    end
    if(row==ENTRIES-1) begin: last_row
      assign below_winner[row]=below[row];
      assign all_winner[row]=ready[row];
    end else begin: prefix
      assign below_winner[row]=below[row] && !(|below[ENTRIES-1:row+1]);
      assign all_winner[row]=ready[row] && !(|ready[ENTRIES-1:row+1]);
    end
  end
  assign valid=|ready;
  assign select=(|below) ? below_winner:all_winner;
endmodule
