// Local copy of the memory FIFO head decode for its prepared-address read.
// This avoids driving both the entire issue payload and address mux from one
// flop, while advancing on exactly the same acceptance event.
module ooo_head_select #(parameter integer DEPTH=2) (
  input wire clk,clear,advance,
  output logic [DEPTH-1:0] selection
);
  always_ff @(posedge clk) begin
    if(clear) selection<=DEPTH'(1);
    else if(advance) selection<={selection[DEPTH-2:0],selection[DEPTH-1]};
  end
endmodule
