(* verilator_fast_eval = 1 *) module v2_alu #(
  parameter integer SIM_FAST=
`ifdef VERILATOR
  1
`else
  0
`endif
) (
  input cpu_pkg::op_t op,
  input logic [31:0] a,b,pc,imm,
  output logic [31:0] result
);
  /* verilator inline_module */
  /* verilator tracing_off */
  import cpu_pkg::*;
  // Compare four byte groups in parallel, then combine from the most
  // significant group. SLT/SLTU need not traverse a 32-bit subtract chain.
  wire [3:0] less,equal;
  for(genvar group_index=0;group_index<4;group_index=group_index+1) begin: compare_groups
    assign less[group_index]=a[group_index*8+:8]<b[group_index*8+:8];
    assign equal[group_index]=a[group_index*8+:8]==b[group_index*8+:8];
  end
  wire grouped_unsigned_less=less[3] || (equal[3] && less[2]) ||
    ((&equal[3:2]) && less[1]) || ((&equal[3:1]) && less[0]);
  wire operands_known=((^a)!==1'bx) && ((^b)!==1'bx);
  wire unsigned_less=SIM_FAST!=0 && operands_known ? a<b:grouped_unsigned_less;
  wire signed_less=SIM_FAST!=0 && operands_known ? $signed(a)<$signed(b):
    (a[31]!=b[31] ? a[31]:grouped_unsigned_less);
  always_comb begin
    case(op)
      OP_ADD: result=a+b;
      OP_SUB: result=a-b;
      OP_SLL: result=a<<b[4:0];
      OP_SLT: result={31'd0,signed_less};
      OP_SLTU: result={31'd0,unsigned_less};
      OP_XOR: result=a^b;
      OP_SRL: result=a>>b[4:0];
      OP_SRA: result=$signed(a)>>>b[4:0];
      OP_OR: result=a|b;
      OP_AND: result=a&b;
      OP_LUI: result=imm;
      OP_AUIPC: result=pc+imm;
      default: result=0;
    endcase
  end
endmodule
