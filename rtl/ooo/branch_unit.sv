module branch_unit (
  input cpu_pkg::op_t op,
  input logic [31:0] a, b, pc, imm,
  output logic [31:0] result, next_pc,
  output logic taken, misaligned
);
  import cpu_pkg::*;
  logic [31:0] target;
  always_comb begin
    result = pc + 32'd4;
    target = pc + imm;
    case (op)
      OP_JAL: taken = 1'b1;
      OP_JALR: begin
        taken = 1'b1;
        // RV32I clears only bit zero. Bit one must remain for fault detection.
        target = (a + imm) & 32'hfffffffe;
      end
      OP_BEQ:  taken = a == b;
      OP_BNE:  taken = a != b;
      OP_BLT:  taken = $signed(a) < $signed(b);
      OP_BGE:  taken = $signed(a) >= $signed(b);
      OP_BLTU: taken = a < b;
      OP_BGEU: taken = a >= b;
      default: taken = 1'b0;
    endcase
    next_pc = taken ? target : result;
    misaligned = taken && (target[1:0] != 2'b00);
  end
endmodule
