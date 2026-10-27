package cpu_pkg;
  typedef enum logic [5:0] {
    OP_ADD, OP_SUB, OP_SLL, OP_SLT, OP_SLTU, OP_XOR, OP_SRL, OP_SRA,
    OP_OR, OP_AND, OP_LUI, OP_AUIPC, OP_JAL, OP_JALR,
    OP_BEQ, OP_BNE, OP_BLT, OP_BGE, OP_BLTU, OP_BGEU,
    OP_LOAD, OP_STORE, OP_MUL, OP_MULH, OP_MULHSU, OP_MULHU,
    OP_DIV, OP_DIVU, OP_REM, OP_REMU
  } op_t;
  typedef struct packed {
    op_t op;
    logic [4:0] rs1, rs2, rd;
    logic uses_rs1, uses_rs2, writes_rd, use_imm;
    logic [31:0] imm;
    logic [1:0] mem_size;
    logic load_signed, illegal;
  } decoded_t;
  typedef struct packed {
    logic [31:0] pc, inst, predicted_pc;
    logic inst_valid;
    logic [3:0] fault;
    logic [31:0] fault_addr;
    logic [15:0] history;
    logic [511:0] ras_snapshot;
    logic [4:0] ras_count;
    logic predicted_taken;
    logic bimodal_taken, gshare_taken;
  } fetch_t;
  localparam logic [3:0] FAULT_NONE=0, FAULT_ILLEGAL=1,
    FAULT_FETCH_ALIGN=2, FAULT_FETCH_RANGE=3, FAULT_FETCH_BUS=4,
    FAULT_TARGET_ALIGN=5, FAULT_LOAD_ALIGN=6, FAULT_LOAD_RANGE=7,
    FAULT_STORE_ALIGN=8, FAULT_STORE_RANGE=9, FAULT_LOAD_BUS=10,
    FAULT_STORE_BUS=11;
  function automatic logic is_branch(input op_t op);
    return op >= OP_JAL && op <= OP_BGEU;
  endfunction
  function automatic logic is_mdu(input op_t op);
    return op >= OP_MUL && op <= OP_REMU;
  endfunction
  function automatic logic is_alu(input op_t op);
    return op <= OP_AUIPC;
  endfunction
endpackage
