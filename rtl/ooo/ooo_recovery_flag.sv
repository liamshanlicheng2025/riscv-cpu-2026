// Replicated control state, sampled alongside the core recovery register.
// A preserved module boundary prevents merging the two flops into a single
// high-fanout driver. No combinational delay or extra recovery cycle is added.
module ooo_recovery_flag (
  input wire clk,clear,candidate,
  output logic active
);
  always_ff @(posedge clk) begin
    if(clear) active<=0;
    else active<=candidate;
  end
endmodule
