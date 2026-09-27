`define DEBUG
// ============================================================================
// student_top.v —— 多周期 RV32IM 骨架 CPU（Verilog 逐行教学注释版）
// ============================================================================
//
// 【给初学者的 Verilog 三分钟速成】
// Verilog 不是程序，是"电路描述"。你写的每一行都会被综合成真实的硬件：
//   - wire（线网）：一根导线，用 assign 持续赋值，对应组合逻辑（与门、加法器…）
//   - reg（寄存器变量）：在 always 块里被赋值；如果只在 @(posedge clock) 里赋值，
//     综合出来就是 D 触发器（真正存状态的寄存器）
//   - always @(posedge clock)：每个时钟上升沿执行一次，描述"时序逻辑"
//   - <=（非阻塞赋值）：时序逻辑专用。含义是"本沿采样旧值，沿过后才更新"，
//     同一 always 块里所有 <= 是"同时"生效的（像所有触发器共用同一个时钟）
//   - = （阻塞赋值）：立即生效，只用于组合逻辑和 function 内部
//   黄金法则：always @(posedge) 里只用 <=，组合逻辑/function 里只用 =。
//
// 【本 CPU 的整体结构】
// 多周期状态机：一条指令分多个时钟周期走完，每拍只做一件事——
//   IF(取指) -> ID(译码) -> EX(执行) -> MEM(访存) -> WB(写回)
// 每个状态就是一个 FSM 状态，state 寄存器记着"现在走到哪一步"。
// 优点：简单可靠；缺点：一条指令 ~20 拍，慢。后续升级路线：
//   五级流水线 -> Tomasulo + ROB 乱序执行
//
// ============================================================================

module student_top (
    // module = 一个硬件模块（相当于芯片的一个功能单元），括号里是对外的引脚
    input  wire        clock,    // 时钟：所有触发器都在它的上升沿更新
    input  wire        reset,    // 同步复位，高电平有效（框架启动时保持 5 拍高电平）

    // ---- AXI4-Lite 读地址通道 (AR)：CPU 告诉内存"我要读哪个地址" ----
    output wire [31:0] araddr,   // [31:0] 表示 32 位宽，bit31 到 bit0
    output wire        arvalid,  // Master 拉高："地址有效，请接收"
    input  wire        arready,  // Slave 拉高："我准备好了"
    // 握手规则：valid 和 ready 在同一上升沿同时为 1，传输才算发生。
    // 铁律：valid 一旦拉高，握手完成前不能撤、不能改数据！

    // ---- AXI4-Lite 读数据通道 (R)：内存把读到的数据送回来 ----
    input  wire [31:0] rdata,
    input  wire [1:0]  rresp,    // 读响应状态：2'b00=OKAY 正常
    input  wire        rvalid,
    output wire        rready,

    // ---- AXI4-Lite 写地址通道 (AW) ----
    output wire [31:0] awaddr,
    output wire        awvalid,
    input  wire        awready,

    // ---- AXI4-Lite 写数据通道 (W) ----
    output wire [31:0] wdata,
    output wire [3:0]  wstrb,    // 字节写使能：4 位分别控制 4 个字节写不写
    output wire        wvalid,
    input  wire        wready,

    // ---- AXI4-Lite 写响应通道 (B)：内存告知"写完成了" ----
    input  wire [1:0]  bresp,
    input  wire        bvalid,
    output wire        bready
);

    // ==================== 状态机状态编码 ====================
    // localparam：编译期常量，不生成硬件。给状态起名比直接写数字易读。
    localparam S_IF_AR = 4'd0;   // 取指 1：发读地址（4'd0 = 4 位宽的十进制 0）
    localparam S_IF_R  = 4'd1;   // 取指 2：收指令数据
    localparam S_ID    = 4'd2;   // 译码：读寄存器堆、生成立即数
    localparam S_EX    = 4'd3;   // 执行：ALU 运算 / 分支跳转 / 算访存地址
    localparam S_LD_AR = 4'd4;   // Load 1：发读地址
    localparam S_LD_R  = 4'd5;   // Load 2：收数据
    localparam S_ST_AW = 4'd6;   // Store 1：发写地址 + 写数据
    localparam S_ST_B  = 4'd7;   // Store 2：等写响应
    localparam S_WB    = 4'd8;   // 写回：把结果存入寄存器堆

    // ==================== RISC-V 指令操作码（opcode，指令低 7 位） ====================
    // 7'b0110111 表示 7 位二进制数。opcode 决定这是哪一类指令。
    localparam OP_LUI    = 7'b0110111;   // 加载高位立即数
    localparam OP_AUIPC  = 7'b0010111;   // PC 相对加高位立即数
    localparam OP_JAL    = 7'b1101111;   // 无条件跳转并链接
    localparam OP_JALR   = 7'b1100111;   // 寄存器间接跳转
    localparam OP_BRANCH = 7'b1100011;   // 条件分支（BEQ/BNE/BLT/...）
    localparam OP_LOAD   = 7'b0000011;   // 读内存（LB/LH/LW/LBU/LHU）
    localparam OP_STORE  = 7'b0100011;   // 写内存（SB/SH/SW）
    localparam OP_OPIMM  = 7'b0010011;   // 寄存器-立即数运算（ADDI/ANDI/...）
    localparam OP_OP     = 7'b0110011;   // 寄存器-寄存器运算（ADD/SUB/MUL/...）

    // ==================== CPU 内部状态（综合出来都是触发器） ====================
    reg [3:0]  state;            // FSM 当前状态
    reg [31:0] pc;               // 程序计数器：当前指令地址
    reg [31:0] instr;            // 当前指令本身（32 位）
    reg [31:0] rf [31:0];        // 寄存器堆：32 个 32 位通用寄存器 x0~x31
                                 // （数组型 reg，综合成一小块寄存器阵列；
                                 //   RISC-V 规定 x0 恒为 0，我们永远不写它）
    reg [31:0] rs1_v, rs2_v;     // ID 阶段锁存的两个源操作数
    reg [31:0] imm;              // ID 阶段拼出来的立即数
    reg [31:0] alu_out;          // EX 结果；Load/Store 时兼任访存地址
    reg [4:0]  rd_idx;           // 目的寄存器编号（5 位可表示 0~31）

    // ==================== 总线输出寄存器 ====================
    // 输出先用 reg 驱动、再用 assign 连到端口上：
    // 这样 valid/地址/数据都是"寄存器输出"，天然满足 AXI 的稳定性要求。
    reg [31:0] araddr_r;
    reg        arvalid_r;
    reg [31:0] awaddr_r;
    reg        awvalid_r;
    reg [31:0] wdata_r;
    reg [3:0]  wstrb_r;
    reg        wvalid_r;
    reg        aw_done, w_done;  // Store 时 AW、W 两个通道各自的握手完成标志

    // assign：持续赋值（组合逻辑），把内部 reg 连到输出端口
    assign araddr  = araddr_r;
    assign arvalid = arvalid_r;
    assign awaddr  = awaddr_r;
    assign awvalid = awvalid_r;
    assign wdata   = wdata_r;
    assign wstrb   = wstrb_r;
    assign wvalid  = wvalid_r;
    // 我们每次只发起一个事务，响应永远有能力接收，所以 ready 常置 1（合法做法）
    assign rready  = 1'b1;       // 1'b1 = 1 位二进制常量 1
    assign bready  = 1'b1;

    // ==================== Load 数据扩展函数 ====================
    // function：可综合的"组合逻辑函数"，调用处会展开成电路。
    // 内存是 32 位对齐读出的，LB/LH 要从 4 字节里挑出目标字节/半字并扩展符号。
    function [31:0] load_extend;
        input [31:0] word;     // 从内存读出的整字
        input [2:0]  f3;       // funct3：区分 LB/LH/LW/LBU/LHU
        input [1:0]  a;        // 地址低 2 位：目标在字内的偏移
        reg [4:0] sh;          // 临时变量：移位量（bit 数）
        begin
            sh = {a, 3'b000};  // {a, 3'b000} 是拼接：a*8，即字节偏移换成 bit 偏移
            case (f3)
                // word[sh +: 8] 是"索引部分选择"：从第 sh 位起取 8 位
                // {{24{X}}, Y} 是复制拼接：把符号位 X 复制 24 次接在 Y 前面（符号扩展）
                3'b000:  load_extend = {{24{word[sh+7]}},  word[sh +: 8]};  // LB  有符号字节
                3'b001:  load_extend = {{16{word[sh+15]}}, word[sh +: 16]}; // LH  有符号半字
                3'b010:  load_extend = word;                                // LW  整字
                3'b100:  load_extend = {24'b0, word[sh +: 8]};              // LBU 无符号字节
                3'b101:  load_extend = {16'b0, word[sh +: 16]};             // LHU 无符号半字
                default: load_extend = word;
            endcase
        end
    endfunction

    // ==================== 指令字段切分（组合逻辑，纯连线） ====================
    wire [6:0] opcode = instr[6:0];    // 操作码：指令最低 7 位
    wire [2:0] funct3 = instr[14:12];  // 3 位功能码：区分同类指令里的具体操作
    wire [6:0] funct7 = instr[31:25];  // 7 位功能码：进一步区分（如 ADD/SUB、M 扩展）

    // ==================== M 扩展：乘法 ====================
    // 32x32 乘法结果是 64 位；MUL 取低 32 位，MULH 系列取高 32 位。
    // $signed() 把操作数当补码有符号数处理。
    // 注意：这会被综合成大型组合乘法器，面积大、延迟长，
    // 后期优化频率时可换成多拍迭代乘法器。
    wire signed [63:0] mul_ss = $signed(rs1_v) * $signed(rs2_v);          // MULH：有符号×有符号
    wire signed [63:0] mul_su = $signed(rs1_v) * $signed({1'b0, rs2_v});  // MULHSU：有符号×无符号
    wire [63:0]        mul_uu = {32'b0, rs1_v} * {32'b0, rs2_v};          // MULHU：无符号×无符号

    // 除法的两种特殊情况（RISC-V 规范强制规定，不能靠硬件默认行为）：
    wire div_zero = (rs2_v == 32'b0);                                  // 除数为 0
    wire div_ovf  = (rs1_v == 32'h80000000) && (rs2_v == 32'hffffffff); // 有符号溢出：INT_MIN / -1

    integer i;  // 预留的循环变量（当前未用，批量初始化寄存器堆时会用到）

    // ==================== 主时序逻辑：整个 CPU 就这一个 always 块 ====================
    // 每当时钟上升沿到来：根据当前 state 做本拍该做的事，并算出下一个 state。
    // 所有赋值都用 <=（非阻塞）：右侧用的都是"本沿之前的旧值"，
    // 这正是硬件触发器的行为——所以一个块里先后写 pc <= ... 不会互相干扰。
    always @(posedge clock) begin
        if (reset) begin
            // ---- 同步复位：把所有关键状态拉回初始值 ----
            state     <= S_IF_AR;   // 从取指开始
            pc        <= 32'b0;     // 程序从地址 0 开始执行
            arvalid_r <= 1'b0;      // 复位期间不能发起任何总线事务
            awvalid_r <= 1'b0;
            wvalid_r  <= 1'b0;
            aw_done   <= 1'b0;
            w_done    <= 1'b0;
        end else begin
            case (state)

                // ---------------- 取指 1：发读地址 ----------------
                S_IF_AR: begin
                    arvalid_r <= 1'b1;   // 拉高 valid（下一拍才生效），并一直保持
                    araddr_r  <= pc;     // 地址保持稳定，直到握手成功
                    if (arvalid_r && arready) begin  // 握手成功（用的是旧值，符合触发器语义）
                        arvalid_r <= 1'b0;           // 成功后撤掉 valid
                        state     <= S_IF_R;         // 进入"等数据"状态
                    end
                end

                // ---------------- 取指 2：收指令 ----------------
                S_IF_R: begin
                    // rready 常 1，所以 rvalid 为 1 的这一拍握手就已完成
                    if (rvalid) begin
                        if (rresp != 2'b00)
                            // $display：仿真时的打印语句，综合时被忽略（调试神器）
                            $display("[student_top] IFETCH error rresp=%b pc=%h", rresp, pc);
                        instr <= rdata;   // 锁存指令
                        state <= S_ID;
                    end
                end

                // ---------------- 译码 ----------------
                S_ID: begin
                    // 从寄存器堆取源操作数。instr[19:15] 是 rs1 字段，[24:20] 是 rs2 字段。
                    rs1_v  <= rf[instr[19:15]];
                    rs2_v  <= rf[instr[24:20]];
                    rd_idx <= instr[11:7];           // rd：目的寄存器编号
                    // 立即数生成：不同指令格式把 imm 的各位散落在指令不同位置，
                    // 这里按格式把它们拼回来并做符号扩展（{{20{instr[31]}}, ...}）。
                    case (opcode)
                        OP_LUI, OP_AUIPC:
                            imm <= {instr[31:12], 12'b0};                            // U 型：高 20 位
                        OP_JAL:
                            imm <= {{12{instr[31]}}, instr[19:12], instr[20],
                                    instr[30:21], 1'b0};                             // J 型
                        OP_BRANCH:
                            imm <= {{20{instr[31]}}, instr[7], instr[30:25],
                                    instr[11:8], 1'b0};                              // B 型
                        OP_STORE:
                            imm <= {{20{instr[31]}}, instr[31:25], instr[11:7]};     // S 型
                        default:
                            imm <= {{20{instr[31]}}, instr[31:20]};                  // I 型
                    endcase
                    state <= S_EX;
                end

                // ---------------- 执行 ----------------
                S_EX: begin
                    case (opcode)
                        OP_LUI: begin               // rd = imm << 12（imm 已拼好）
                            alu_out <= imm;
                            state   <= S_WB;
                        end
                        OP_AUIPC: begin             // rd = pc + imm（PC 相对寻址）
                            alu_out <= pc + imm;
                            state   <= S_WB;
                        end
                        OP_JAL: begin               // 无条件跳转到 pc+imm
                            if (rd_idx != 5'd0) rf[rd_idx] <= pc + 32'd4;  // rd 存返回地址
                            pc    <= pc + imm;      // 立即更新 PC，直接回取指
                            state <= S_IF_AR;
                        end
                        OP_JALR: begin              // 跳转到 (rs1+imm)，最低位清零
                            if (rd_idx != 5'd0) rf[rd_idx] <= pc + 32'd4;
                            pc    <= (rs1_v + imm) & 32'hfffffffe;  // & 是按位与，清 bit0
                            state <= S_IF_AR;
                        end
                        OP_BRANCH: begin            // 条件成立则 pc+imm，否则 pc+4
                            case (funct3)           // ? : 是条件运算符（多路选择器）
                                3'b000:  pc <= (rs1_v == rs2_v) ? pc + imm : pc + 32'd4; // BEQ
                                3'b001:  pc <= (rs1_v != rs2_v) ? pc + imm : pc + 32'd4; // BNE
                                // $signed：按补码比较有符号数
                                3'b100:  pc <= ($signed(rs1_v) <  $signed(rs2_v)) ? pc + imm : pc + 32'd4; // BLT
                                3'b101:  pc <= ($signed(rs1_v) >= $signed(rs2_v)) ? pc + imm : pc + 32'd4; // BGE
                                3'b110:  pc <= (rs1_v <  rs2_v) ? pc + imm : pc + 32'd4; // BLTU
                                3'b111:  pc <= (rs1_v >= rs2_v) ? pc + imm : pc + 32'd4; // BGEU
                                default: pc <= pc + 32'd4;
                            endcase
                            state <= S_IF_AR;
                        end
                        OP_LOAD: begin
                            alu_out <= rs1_v + imm; // 算出访存地址，转 Load 流程
                            state   <= S_LD_AR;
                        end
                        OP_STORE: begin
                            alu_out <= rs1_v + imm; // 算出访存地址，转 Store 流程
                            aw_done <= 1'b0;        // 清零两个通道的完成标志
                            w_done  <= 1'b0;
                            state   <= S_ST_AW;
                        end
                        OP_OPIMM: begin             // 寄存器与立即数运算
                            case (funct3)
                                3'b000:  alu_out <= rs1_v + imm;                                     // ADDI
                                3'b010:  alu_out <= ($signed(rs1_v) < $signed(imm)) ? 32'd1 : 32'd0; // SLTI
                                3'b011:  alu_out <= (rs1_v < imm) ? 32'd1 : 32'd0;                   // SLTIU
                                3'b100:  alu_out <= rs1_v ^ imm;                                     // XORI（^ 异或）
                                3'b110:  alu_out <= rs1_v | imm;                                     // ORI （| 或）
                                3'b111:  alu_out <= rs1_v & imm;                                     // ANDI（& 与）
                                3'b001:  alu_out <= rs1_v << instr[24:20];                           // SLLI 左移
                                // >>> 是算术右移（补符号位），>> 是逻辑右移（补 0）；
                                // instr[30] 区分 SRAI/SRLI
                                3'b101:  alu_out <= instr[30] ? $signed(rs1_v) >>> instr[24:20]
                                                              : rs1_v >> instr[24:20];
                            endcase
                            state <= S_WB;
                        end
                        OP_OP: begin                // 寄存器与寄存器运算
                            if (funct7 == 7'b0000001) begin
                                // ---- M 扩展（乘除法）----
                                // 先用运算符实现保正确性；除法会被综合成很大的组合除法器，
                                // 后期优化面积/频率时应换成多拍迭代除法器。
                                case (funct3)
                                    3'b000:  alu_out <= mul_ss[31:0];                          // MUL  取低 32 位
                                    3'b001:  alu_out <= mul_ss[63:32];                         // MULH
                                    3'b010:  alu_out <= mul_su[63:32];                         // MULHSU
                                    3'b011:  alu_out <= mul_uu[63:32];                         // MULHU
                                    // DIV 除零得全 1，溢出得 INT_MIN（规范规定）
                                    3'b100:  alu_out <= div_zero ? 32'hffffffff
                                                        : div_ovf ? 32'h80000000
                                                        : $signed(rs1_v) / $signed(rs2_v);
                                    3'b101:  alu_out <= div_zero ? 32'hffffffff                // DIVU
                                                        : rs1_v / rs2_v;
                                    // REM 除零得被除数，溢出得 0（规范规定）
                                    3'b110:  alu_out <= div_zero ? rs1_v
                                                        : div_ovf ? 32'b0
                                                        : $signed(rs1_v) % $signed(rs2_v);
                                    3'b111:  alu_out <= div_zero ? rs1_v                       // REMU
                                                        : rs1_v % rs2_v;
                                endcase
                            end else begin
                                // ---- 基础整数运算（funct7[5] 区分 ADD/SUB、SRL/SRA）----
                                case (funct3)
                                    3'b000:  alu_out <= funct7[5] ? rs1_v - rs2_v : rs1_v + rs2_v;   // SUB/ADD
                                    3'b001:  alu_out <= rs1_v << rs2_v[4:0];                         // SLL
                                    3'b010:  alu_out <= ($signed(rs1_v) < $signed(rs2_v)) ? 32'd1 : 32'd0; // SLT
                                    3'b011:  alu_out <= (rs1_v < rs2_v) ? 32'd1 : 32'd0;             // SLTU
                                    3'b100:  alu_out <= rs1_v ^ rs2_v;                               // XOR
                                    3'b101:  alu_out <= funct7[5] ? $signed(rs1_v) >>> rs2_v[4:0]
                                                                  : rs1_v >> rs2_v[4:0];             // SRA/SRL
                                    3'b110:  alu_out <= rs1_v | rs2_v;                               // OR
                                    3'b111:  alu_out <= rs1_v & rs2_v;                               // AND
                                endcase
                            end
                            state <= S_WB;
                        end
                        default: begin
                            // 遇到不认识的指令：打印现场，方便调试（综合时 $display 被忽略）
                            $display("[student_top] unknown opcode=%b pc=%h instr=%h", opcode, pc, instr);
                            state <= S_WB;
                        end
                    endcase
                end

                // ---------------- Load 1：发读地址 ----------------
                S_LD_AR: begin
                    arvalid_r <= 1'b1;
                    araddr_r  <= {alu_out[31:2], 2'b00};   // 总线要求 4 字节对齐：低 2 位清 0
                    if (arvalid_r && arready) begin
                        arvalid_r <= 1'b0;
                        state     <= S_LD_R;
                    end
                end

                // ---------------- Load 2：收数据并按 LB/LH/LW 扩展 ----------------
                S_LD_R: begin
                    if (rvalid) begin
                        if (rresp != 2'b00)
                            $display("[student_top] LOAD error rresp=%b addr=%h", rresp, alu_out);
                        // 调用上面的 function：从整字中挑出目标字节/半字
                        alu_out <= load_extend(rdata, funct3, alu_out[1:0]);
                        state   <= S_WB;
                    end
                end

                // ---------------- Store 1：同时发写地址(AW)和写数据(W) ----------------
                S_ST_AW: begin
                    // 协议允许 AW 和 W 以任意先后握手，所以两个通道各自独立推进：
                    if (!aw_done && !awvalid_r) begin   // 还没发过：发起 AW
                        awvalid_r <= 1'b1;
                        awaddr_r  <= {alu_out[31:2], 2'b00};
                    end
                    if (!w_done && !wvalid_r) begin     // 还没发过：发起 W
                        wvalid_r <= 1'b1;
                        case (funct3)
                            3'b000: begin                              // SB：只写 1 个字节
                                wstrb_r <= 4'b0001 << alu_out[1:0];    // 掩码移到目标字节 lane
                                wdata_r <= {4{rs2_v[7:0]}};            // 字节复制到 4 个 lane
                            end
                            3'b001: begin                              // SH：写 2 个字节
                                wstrb_r <= 4'b0011 << alu_out[1:0];
                                wdata_r <= {2{rs2_v[15:0]}};
                            end
                            default: begin                             // SW：写整个字
                                wstrb_r <= 4'b1111;
                                wdata_r <= rs2_v;
                            end
                        endcase
                    end
                    // 哪个通道握手成功，就撤哪个 valid 并记下完成标志
                    if (awvalid_r && awready) begin
                        awvalid_r <= 1'b0;
                        aw_done   <= 1'b1;
                    end
                    if (wvalid_r && wready) begin
                        wvalid_r <= 1'b0;
                        w_done   <= 1'b1;
                    end
                    // 两个通道都完成了（包括本拍刚完成的），才去等写响应
                    if ((aw_done || (awvalid_r && awready)) &&
                        (w_done  || (wvalid_r  && wready)))
                        state <= S_ST_B;
                end

                // ---------------- Store 2：等写响应 ----------------
                S_ST_B: begin
                    if (bvalid) begin   // bready 常 1，bvalid 一拍即完成握手
`ifdef DEBUG
                        $display("[ST] addr=%h data=%h strb=%b", {alu_out[31:2],2'b00}, wdata_r, wstrb_r);
`endif
                        if (bresp != 2'b00)
                            $display("[student_top] STORE error bresp=%b addr=%h", bresp, alu_out);
                        // 向 0x80000000 的 SW 走到这里，仿真器就会捕获结果并结束仿真
                        pc    <= pc + 32'd4;
                        state <= S_IF_AR;
                    end
                end

                // ---------------- 写回 ----------------
                S_WB: begin
`ifdef DEBUG
                    if (rd_idx != 5'd0) $display("[WB] pc=%h rd=%d val=%h", pc, rd_idx, alu_out);
`endif
                    if (rd_idx != 5'd0) rf[rd_idx] <= alu_out;  // x0 恒为 0，永不写入
                    pc    <= pc + 32'd4;                        // 顺序执行下一条
                    state <= S_IF_AR;
                end

                default: state <= S_IF_AR;   // 兜底：状态寄存器出现意外值时回到取指
            endcase
        end
    end

endmodule
