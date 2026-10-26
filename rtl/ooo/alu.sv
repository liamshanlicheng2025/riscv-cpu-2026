module alu (
  input cpu_pkg::op_t op,
  input logic [31:0] a, b, pc, imm,
  output logic [31:0] result
);
  import cpu_pkg::*;
  always_comb begin
    case (op)
      OP_ADD:   result = a + b;
      OP_SUB:   result = a - b;
      OP_SLL:   result = a << b[4:0];
      OP_SLT:   result = {31'b0, $signed(a) < $signed(b)};
      OP_SLTU:  result = {31'b0, a < b};
      OP_XOR:   result = a ^ b;
      OP_SRL:   result = a >> b[4:0];
      OP_SRA:   result = $signed(a) >>> b[4:0];
      OP_OR:    result = a | b;
      OP_AND:   result = a & b;
      OP_LUI:   result = imm;
      OP_AUIPC: result = pc + imm;
      default:  result = 32'b0;
    endcase
  end
endmodule
