// Keep late bypass qualification after the arithmetic. Multiple matching
// channels retain the same last-channel priority as operand capture.
module v2_prepare_address #(
  parameter integer TAG_BITS=4, PORTS=5
)(
  input wire [31:0] base,offset,
  input wire pending,
  input wire [TAG_BITS-1:0] source_tag,
  input wire [PORTS-1:0] wb_valid,
  input wire [PORTS*TAG_BITS-1:0] wb_tags,
  input wire [PORTS*32-1:0] wb_values,
  output logic [31:0] address
);
  wire [31:0] base_sum;
  wire [31:0] forwarded_sum[PORTS];
  (* keep_hierarchy *) v2_add32 add_base(.a(base),.b(offset),.sum(base_sum));
  for(genvar port=0;port<PORTS;port=port+1) begin: forwarded
    (* keep_hierarchy *) v2_add32 add_value
      (.a(wb_values[port*32+:32]),.b(offset),.sum(forwarded_sum[port]));
  end
  always_comb begin
    address=base_sum;
    for(integer port=0;port<PORTS;port=port+1)
      if(pending && wb_valid[port] && source_tag==wb_tags[port*TAG_BITS+:TAG_BITS])
        address=forwarded_sum[port];
  end
endmodule
