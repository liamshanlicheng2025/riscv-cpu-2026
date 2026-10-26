module decoder (
  input  logic [31:0] inst,
  output cpu_pkg::decoded_t dec
);
  import cpu_pkg::*;

  always_comb begin
    dec = '0;
    dec.op = OP_ADD;
    dec.rs1 = inst[19:15];
    dec.rs2 = inst[24:20];
    dec.rd = inst[11:7];
    dec.illegal = 1'b0;
    case (inst[6:0])
      7'b0110111, 7'b0010111: begin
        dec.op = inst[6:0] == 7'b0110111 ? OP_LUI : OP_AUIPC;
        dec.imm = {inst[31:12], 12'b0};
        dec.writes_rd = 1'b1;
      end
      7'b1101111: begin
        dec.op = OP_JAL;
        dec.imm = {{11{inst[31]}}, inst[31], inst[19:12], inst[20],
                   inst[30:21], 1'b0};
        dec.writes_rd = 1'b1;
      end
      7'b1100111: begin
        dec.op = OP_JALR;
        dec.uses_rs1 = 1'b1;
        dec.writes_rd = 1'b1;
        dec.use_imm = 1'b1;
        dec.imm = {{20{inst[31]}}, inst[31:20]};
        dec.illegal = inst[14:12] != 3'b000;
      end
      7'b1100011: begin
        dec.uses_rs1 = 1'b1;
        dec.uses_rs2 = 1'b1;
        dec.imm = {{19{inst[31]}}, inst[31], inst[7], inst[30:25],
                   inst[11:8], 1'b0};
        case (inst[14:12])
          3'b000: dec.op = OP_BEQ;
          3'b001: dec.op = OP_BNE;
          3'b100: dec.op = OP_BLT;
          3'b101: dec.op = OP_BGE;
          3'b110: dec.op = OP_BLTU;
          3'b111: dec.op = OP_BGEU;
          default: dec.illegal = 1'b1;
        endcase
      end
      7'b0000011: begin
        dec.op = OP_LOAD;
        dec.uses_rs1 = 1'b1;
        dec.writes_rd = 1'b1;
        dec.use_imm = 1'b1;
        dec.imm = {{20{inst[31]}}, inst[31:20]};
        dec.mem_size = inst[13:12];
        dec.load_signed = !inst[14];
        case (inst[14:12])
          3'b000, 3'b001, 3'b010, 3'b100, 3'b101: ;
          default: dec.illegal = 1'b1;
        endcase
      end
      7'b0100011: begin
        dec.op = OP_STORE;
        dec.uses_rs1 = 1'b1;
        dec.uses_rs2 = 1'b1;
        dec.use_imm = 1'b1;
        dec.imm = {{20{inst[31]}}, inst[31:25], inst[11:7]};
        dec.mem_size = inst[13:12];
        case (inst[14:12])
          3'b000, 3'b001, 3'b010: ;
          default: dec.illegal = 1'b1;
        endcase
      end
      7'b0010011: begin
        dec.uses_rs1 = 1'b1;
        dec.writes_rd = 1'b1;
        dec.use_imm = 1'b1;
        dec.imm = {{20{inst[31]}}, inst[31:20]};
        case (inst[14:12])
          3'b000: dec.op = OP_ADD;
          3'b010: dec.op = OP_SLT;
          3'b011: dec.op = OP_SLTU;
          3'b100: dec.op = OP_XOR;
          3'b110: dec.op = OP_OR;
          3'b111: dec.op = OP_AND;
          3'b001: begin
            dec.op = OP_SLL;
            dec.imm = {27'b0, inst[24:20]};
            dec.illegal = inst[31:25] != 7'b0000000;
          end
          3'b101: begin
            dec.op = inst[30] ? OP_SRA : OP_SRL;
            dec.imm = {27'b0, inst[24:20]};
            dec.illegal = (inst[31:25] != 7'b0000000) &&
                          (inst[31:25] != 7'b0100000);
          end
          default: dec.illegal = 1'b1;
        endcase
      end
      7'b0110011: begin
        dec.uses_rs1 = 1'b1;
        dec.uses_rs2 = 1'b1;
        dec.writes_rd = 1'b1;
        if (inst[31:25] == 7'b0000001) begin
          case (inst[14:12])
            3'b000: dec.op = OP_MUL;
            3'b001: dec.op = OP_MULH;
            3'b010: dec.op = OP_MULHSU;
            3'b011: dec.op = OP_MULHU;
            3'b100: dec.op = OP_DIV;
            3'b101: dec.op = OP_DIVU;
            3'b110: dec.op = OP_REM;
            3'b111: dec.op = OP_REMU;
            default: dec.illegal = 1'b1;
          endcase
        end else begin
          case (inst[14:12])
            3'b000: dec.op = inst[30] ? OP_SUB : OP_ADD;
            3'b001: dec.op = OP_SLL;
            3'b010: dec.op = OP_SLT;
            3'b011: dec.op = OP_SLTU;
            3'b100: dec.op = OP_XOR;
            3'b101: dec.op = inst[30] ? OP_SRA : OP_SRL;
            3'b110: dec.op = OP_OR;
            3'b111: dec.op = OP_AND;
            default: dec.illegal = 1'b1;
          endcase
          dec.illegal = (inst[31:25] != 7'b0000000) &&
                        !((inst[31:25] == 7'b0100000) &&
                          ((inst[14:12] == 3'b000) ||
                           (inst[14:12] == 3'b101)));
        end
      end
      default: dec.illegal = 1'b1;
    endcase
    // x0 destinations still execute, but never allocate a physical register.
    dec.writes_rd = dec.writes_rd && dec.rd != 5'd0;
    if (dec.illegal) begin
      dec.uses_rs1 = 1'b0;
      dec.uses_rs2 = 1'b0;
      dec.writes_rd = 1'b0;
      dec.use_imm = 1'b0;
    end
  end
endmodule
