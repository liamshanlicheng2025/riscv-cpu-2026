// ============================================================================
// student_top.v —— 五级流水线 RV32IM CPU（IF/ID/EX/MEM/WB）
//
// 结构：
//   IF  : i-cache 每拍读 pc_f（同步 SRAM，下一拍出数据）
//   ID  : tag 比较 + 译码 + 读寄存器堆；JAL 在此直接跳转
//   EX  : 前递后的 ALU/分支解析/JALR/乘法；访存指令本拍发 d-cache SRAM 读；
//         除法启动 32 拍迭代除法器（前端停顿）
//   MEM : d-cache 命中判断；load 取数；store 命中写 SRAM + 压 store buffer
//   WB  : 写回寄存器堆
//
// 停顿/冲刷：
//   - i-cache miss：前端停顿，填充完成后自动命中
//   - d-cache load miss / store buffer 满：整条流水线冻结
//   - store 写 SRAM 与 EX 读 SRAM 冲突：EX 停一拍
//   - 分支预测 not-taken，EX 解析，预测失败冲刷 IF/ID、ID/EX（2 拍代价）
//   - 前递：MEM 级（含 load 的 SRAM 读出）和 WB 级两级前递到 EX，无 load-use 气泡
// ============================================================================

module student_top (
    input  wire        clock,
    input  wire        reset,

    output wire [31:0] araddr,
    output wire        arvalid,
    input  wire        arready,
    input  wire [31:0] rdata,
    input  wire [1:0]  rresp,
    input  wire        rvalid,
    output wire        rready,

    output wire [31:0] awaddr,
    output wire        awvalid,
    input  wire        awready,
    output wire [31:0] wdata,
    output wire [3:0]  wstrb,
    output wire        wvalid,
    input  wire        wready,

    input  wire [1:0]  bresp,
    input  wire        bvalid,
    output wire        bready
);
    // ---------------- 操作码 ----------------
    localparam OP_LUI    = 7'b0110111;
    localparam OP_AUIPC  = 7'b0010111;
    localparam OP_JAL    = 7'b1101111;
    localparam OP_JALR   = 7'b1100111;
    localparam OP_BRANCH = 7'b1100011;
    localparam OP_LOAD   = 7'b0000011;
    localparam OP_STORE  = 7'b0100011;
    localparam OP_OPIMM  = 7'b0010011;
    localparam OP_OP     = 7'b0110011;

    // ---------------- ALU 操作编码 ----------------
    localparam ALU_ADD = 4'd0, ALU_SUB = 4'd1, ALU_SLL = 4'd2, ALU_SLT = 4'd3,
               ALU_SLTU = 4'd4, ALU_XOR = 4'd5, ALU_SRL = 4'd6, ALU_SRA = 4'd7,
               ALU_OR  = 4'd8, ALU_AND = 4'd9, ALU_PASSB = 4'd10;

    // ---------------- Load 数据扩展 ----------------
    function [31:0] load_extend;
        input [31:0] word;
        input [2:0]  f3;
        input [1:0]  a;
        reg [4:0] sh;
        begin
            sh = {a, 3'b000};
            case (f3)
                3'b000:  load_extend = {{24{word[sh+7]}},  word[sh +: 8]};
                3'b001:  load_extend = {{16{word[sh+15]}}, word[sh +: 16]};
                3'b010:  load_extend = word;
                3'b100:  load_extend = {24'b0, word[sh +: 8]};
                3'b101:  load_extend = {16'b0, word[sh +: 16]};
                default: load_extend = word;
            endcase
        end
    endfunction

    // ==================== 流水线寄存器 ====================
    reg [31:0] pc_f;
    reg [31:0] pc_id;
    reg        id_valid;
    reg        id_if_taken;      // IF 级（mini-BTB）预测结果，随指令带入 ID
    reg [31:0] id_if_target;


    reg        ex_valid;
    reg [31:0] ex_pc, ex_rs1v, ex_rs2v, ex_imm;
    reg [4:0]  ex_rs1, ex_rs2, ex_rd;
    reg [3:0]  ex_aluop;
    reg        ex_srca_pc, ex_srcb_imm;
    reg        ex_is_load, ex_is_store;
    reg [2:0]  ex_mem_f3;
    reg        ex_regwrite, ex_wb_pc4;
    reg        ex_is_branch;
    reg [2:0]  ex_br_f3;
    reg        ex_is_jalr;
    reg        ex_pred_taken;
    reg [31:0] ex_pred_target;
    reg [1:0]  ex_bht;
    reg        ex_is_call, ex_is_ret;
    reg        ex_is_mul;
    reg [2:0]  ex_m_f3;        // M 扩展 funct3
    reg        ex_is_div;

    reg        mem_valid, mem_regwrite, mem_is_load, mem_is_store;
    reg [2:0]  mem_f3;
    reg [31:0] mem_alu, mem_store_data, mem_pc;
    reg [4:0]  mem_rd;


    // ==================== 寄存器堆 ====================
    reg [31:0] rf [31:0];

    // ==================== cache / 子模块连线 ====================
    wire [31:0]  ic_instr;
    wire         ic_hit, ic_busy;
    wire         ic_req, dc_req;
    wire [31:0]  ic_ar_addr, dc_ar_addr;
    wire         ic_ar_valid, dc_ar_valid;
    wire         ic_last_r, dc_last_r;

    wire         dc_hit, dc_busy, dc_fillwrite, dc_crit_valid, dc_fill_clash;
    wire [31:0]  dc_crit_word;
    wire [127:0] dc_line_rdata;

    wire         sb_full, sb_clear, sb_clear2, sb_clear3;

    // ==================== 停顿 / 前进控制 ====================
    // d-cache 部分
    // load miss：目标字到达（crit_valid）后该 load 直接完成，填充转后台
    wire dc_miss   = mem_valid && mem_is_load && !dc_hit && !dc_crit_valid;
    wire sb_stall  = mem_valid && mem_is_store && sb_full;
    // dc_store_clash：store 落在正在填充的行内，等填充完成后按 hit 处理
    wire freeze_ls    = dc_miss || sb_stall;
    wire freeze_fw    = dc_fillwrite || dc_store_clash;
    wire pipe_freeze  = freeze_ls || freeze_fw;
    // ABC 不做高扇出缓冲：手工复制多份（keep 防止合并），分摊 ~700 个 latch mux 负载
    (* keep *) wire fz_hold1 = pipe_freeze;
    (* keep *) wire fz_hold2 = pipe_freeze;
    (* keep *) wire fz_hold3 = pipe_freeze;
    wire dc_store_clash = mem_valid && mem_is_store && dc_fill_clash;
    wire crit_consume = dc_crit_valid && mem_valid && mem_is_load && !pipe_freeze;

    // store(MEM) 写 data SRAM 与 load(EX) 读 data SRAM 冲突：EX 停一拍。
    // （store 在 EX 只读 tag SRAM，与 data SRAM 写不冲突）
    wire lx_stall  = ex_valid && ex_is_load && mem_valid && mem_is_store && dc_hit && !pipe_freeze;

    // 除法
    wire div_busy, div_done;
    wire [31:0] div_result;
    wire [31:0] fwd_a, fwd_b;   // 前递后的 EX 操作数（声明见 EX 部分）
    reg  div_started;           // 除法器已启动：多拍期间操作数前递会变化，
                                // 停顿/结果选择必须以 div_started 为准
    wire div_zero = (fwd_b == 32'b0);
    wire div_ovf  = !ex_m_f3[0] && (fwd_a == 32'h80000000) && (fwd_b == 32'hffffffff);
    wire div_special = div_zero || div_ovf;
    // 除法特殊情况（规范）：除零 DIV/DIVU=全1、REM/REMU=被除数；
    // INT_MIN/-1：DIV=INT_MIN、REM=0
    wire [31:0] div_spec_res = div_zero ? (ex_m_f3[1] ? fwd_a : 32'hffffffff)
                                        : (ex_m_f3[1] ? 32'b0 : 32'h80000000);
    // 特殊情况不阻止启动：除法器照常迭代（结果被丢弃），特殊结果随启动拍寄存。
    // div_req/div_stall 不再依赖前递操作数的 32bit 比较（晚到信号）。
    wire div_req   = ex_valid && ex_is_div;
    wire div_start = div_req && !div_busy && !div_started && !div_done && !pipe_freeze;
    wire div_stall = (div_req || div_started) && !div_done;
    reg        div_spec_r;
    reg [31:0] div_spec_res_r;
    always @(posedge clock) begin
        if (reset) div_started <= 1'b0;
        else if (div_start) div_started <= 1'b1;
        else if (div_done)  div_started <= 1'b0;
        if (div_start) begin
            div_spec_r     <= div_special;
            div_spec_res_r <= div_spec_res;
        end
    end

    // i-cache
    wire ic_miss  = id_valid && !ic_hit && !pipe_freeze && !div_stall && !lx_stall;
    wire ic_stall = ic_miss || ic_busy;

    wire front_stall = pipe_freeze || div_stall || lx_stall || ic_stall;
    wire front_adv   = !front_stall;

    // ==================== 重定向 ====================
    // 预测：ID 阶段用 BHT/BTB/RAS 预测分支与跳转；EX 阶段验证，失败则冲刷。
    // EX：分支/JALR 实际结果与预测不一致时重定向
    reg br_taken;
    always @(*) begin
        case (ex_br_f3)
            3'b000:  br_taken = (fwd_a == fwd_b);
            3'b001:  br_taken = (fwd_a != fwd_b);
            3'b100:  br_taken = ($signed(fwd_a) <  $signed(fwd_b));
            3'b101:  br_taken = ($signed(fwd_a) >= $signed(fwd_b));
            3'b110:  br_taken = (fwd_a <  fwd_b);
            3'b111:  br_taken = (fwd_a >= fwd_b);
            default: br_taken = 1'b0;
        endcase
    end
    wire        actual_taken  = ex_is_jalr || (ex_is_branch && br_taken);
    wire [31:0] actual_target = ex_is_jalr ? ((fwd_a + ex_imm) & 32'hfffffffe)
                                           : (ex_pc + ex_imm);
    wire ex_complete = ex_valid && !pipe_freeze && !div_stall && !lx_stall;
    wire ex_redirect = ex_valid && !pipe_freeze && (ex_is_branch || ex_is_jalr) &&
                       (actual_taken != ex_pred_taken ||
                        (actual_taken && (actual_target != ex_pred_target)));
    wire [31:0] ex_target = actual_taken ? actual_target : (ex_pc + 32'd4);

    // ==================== ID 译码（组合） ====================
    wire [6:0] d_op = ic_instr[6:0];
    wire [2:0] d_f3 = ic_instr[14:12];
    wire [6:0] d_f7 = ic_instr[31:25];
    wire [4:0] d_rs1 = ic_instr[19:15];
    wire [4:0] d_rs2 = ic_instr[24:20];
    wire [4:0] d_rd  = ic_instr[11:7];

    wire d_lui    = (d_op == OP_LUI);
    wire d_auipc  = (d_op == OP_AUIPC);
    wire d_jal    = (d_op == OP_JAL);
    wire d_jalr   = (d_op == OP_JALR);
    wire d_branch = (d_op == OP_BRANCH);
    wire d_load   = (d_op == OP_LOAD);
    wire d_store  = (d_op == OP_STORE);
    wire d_opimm  = (d_op == OP_OPIMM);
    wire d_opr    = (d_op == OP_OP);
    wire d_mext   = d_opr && (d_f7 == 7'b0000001);

    wire [31:0] d_imm =
        (d_lui || d_auipc) ? {ic_instr[31:12], 12'b0} :
        d_jal    ? {{12{ic_instr[31]}}, ic_instr[19:12], ic_instr[20],
                    ic_instr[30:21], 1'b0} :
        d_branch ? {{20{ic_instr[31]}}, ic_instr[7], ic_instr[30:25],
                    ic_instr[11:8], 1'b0} :
        d_store  ? {{20{ic_instr[31]}}, ic_instr[31:25], ic_instr[11:7]} :
                   {{20{ic_instr[31]}}, ic_instr[31:20]};

    reg [3:0] d_aluop;
    always @(*) begin
        if (d_lui) d_aluop = ALU_PASSB;
        else if (d_auipc || d_jal || d_jalr || d_load || d_store) d_aluop = ALU_ADD;
        else if (d_opimm) begin
            case (d_f3)
                3'b000:  d_aluop = ALU_ADD;
                3'b010:  d_aluop = ALU_SLT;
                3'b011:  d_aluop = ALU_SLTU;
                3'b100:  d_aluop = ALU_XOR;
                3'b110:  d_aluop = ALU_OR;
                3'b111:  d_aluop = ALU_AND;
                3'b001:  d_aluop = ALU_SLL;
                default: d_aluop = ic_instr[30] ? ALU_SRA : ALU_SRL;
            endcase
        end else if (d_opr && !d_mext) begin
            case (d_f3)
                3'b000:  d_aluop = d_f7[5] ? ALU_SUB : ALU_ADD;
                3'b001:  d_aluop = ALU_SLL;
                3'b010:  d_aluop = ALU_SLT;
                3'b011:  d_aluop = ALU_SLTU;
                3'b100:  d_aluop = ALU_XOR;
                3'b101:  d_aluop = d_f7[5] ? ALU_SRA : ALU_SRL;
                3'b110:  d_aluop = ALU_OR;
                default: d_aluop = ALU_AND;
            endcase
        end else d_aluop = ALU_ADD;
    end

    wire d_regwrite = d_lui || d_auipc || d_jal || d_jalr || d_load || d_opimm || d_opr;
    wire d_srcb_imm = d_lui || d_auipc || d_opimm || d_load || d_store;
    wire d_srca_pc  = d_auipc;

    // ==================== 分支预测器：BTB/BHT(SRAM) + RAS ====================
    // BTB/BHT 合并为一片 sram_fakeram（256 项 x 37 位：valid+type+target+bht），
    // IF 拍发读、ID 拍用数据（与 i-cache 指令数据同拍到达，停顿期间重读 pc_id
    // 保持对齐）。无 tag，别名靠 EX 验证兜底；SRAM 无复位，Verilator 下初值为 0
    // （valid=0），真实硅片上的垃圾预测也只会被 EX 验证冲刷，不影响正确性。
    // RAS：8 项返回地址栈（寄存器）。预测器更新都在 EX 完成拍（EX 指令绝不属于
    // 错误路径）。预测决策在 ID：预测跳转则冲刷 IF 中的顺序取指（1 拍代价）。
    localparam BT_BR  = 2'd0;   // 条件分支（看 BHT）
    localparam BT_JMP = 2'd1;   // JAL / JALR 调用（必跳）
    localparam BT_RET = 2'd2;   // 返回（看 RAS）

    reg [31:0] ras [0:7];
    reg [3:0]  ras_cnt;          // 0..8

    // 调用/返回识别
    wire d_call = (d_jal || d_jalr) && (d_rd == 5'd1);
    wire d_ret  = d_jalr && (d_rs1 == 5'd1) && (d_rd == 5'd0);

    // EX 完成的调用压栈 / 返回弹栈
    wire ex_push = ex_complete && ex_is_call;
    wire ex_pop  = ex_complete && ex_is_ret && ex_pred_taken; // 仅 RAS 预测过的返回弹栈
    wire [3:0] ras_cnt_eff = ex_pop ? (ras_cnt - 4'd1) : ras_cnt;

    wire [2:0] ras_top_idx = ras_cnt_eff[2:0] - 3'd1;
    wire [31:0] ras_top = ex_push ? (ex_pc + 32'd4) : ras[ras_top_idx];

    // ---- IF 级跳转目标表 FAT：32 项全相联（pc 全 tag 比较）----
    // 全相联比较器扇出小（每 bit 32 负载），避免大索引 mux 的时序灾难。
    // 预测 JAL/JALR 调用/返回/热分支，命中即 0 气泡跳转；错误由 ID 复核
    // （JAL 精确校验）与 EX 验证（分支/JALR）兜底，不影响正确性。
    // 分支条目带 2-bit BHT：taken 解析时写入/更新，not-taken 解析时清除命中项。
    localparam FATN = 32;
    reg [31:0] fat_pc [0:FATN-1];
    reg [31:0] fat_target [0:FATN-1];
    reg [1:0]  fat_type [0:FATN-1];
    reg [FATN-1:0] fat_valid;
    reg [4:0]  fat_rr;

    wire [FATN-1:0] fat_match;
    genvar gi;
    generate
        for (gi = 0; gi < FATN; gi = gi + 1) begin : g_fat
            assign fat_match[gi] = fat_valid[gi] && (fat_pc[gi] == pc_f);
        end
    endgenerate

    // 优先编码器取命中项（取最低位即可，全相联同 pc 至多一项有效）
    reg [31:0] fat_rd_target;
    reg [1:0]  fat_rd_type;
    integer fi;
    always @(*) begin
        fat_rd_target = 32'b0;
        fat_rd_type   = 2'b0;
        for (fi = FATN-1; fi >= 0; fi = fi - 1)
            if (fat_match[fi]) begin
                fat_rd_target = fat_target[fi];
                fat_rd_type   = fat_type[fi];
            end
    end

    wire if_pred_taken = (|fat_match) &&
                         (fat_rd_type == BT_JMP || fat_rd_type == BT_BR ||
                          (fat_rd_type == BT_RET && ras_cnt_eff != 4'd0));
    wire [31:0] if_pred_target = (fat_rd_type == BT_RET) ? ras_top : fat_rd_target;

    // ---- FAT 写入侧：解析时对 ex_pc 做全相联匹配（更新/失效用） ----
    wire [FATN-1:0] fat_wmatch;
    generate
        for (gi = 0; gi < FATN; gi = gi + 1) begin : g_fatw
            assign fat_wmatch[gi] = fat_valid[gi] && (fat_pc[gi] == ex_pc);
        end
    endgenerate
    reg [4:0] fat_wslot;
    always @(*) begin
        fat_wslot = fat_rr;
        for (fi = FATN-1; fi >= 0; fi = fi - 1)
            if (fat_wmatch[fi]) fat_wslot = fi[4:0];
    end

    // FAT 学习：JAL 在 ID 重定向时学习；JALR/taken 分支在 EX 解析时学习
    wire fat_learn_jal  = id_redirect && d_jal;
    wire fat_learn_jalr = ex_jalr_resolve;
    wire fat_learn_br   = ex_br_resolve && br_taken;
    wire fat_inval_br   = ex_br_resolve && !br_taken;
    integer fk;
    always @(posedge clock) begin
        if (reset) begin
            fat_valid <= {FATN{1'b0}};
            fat_rr    <= 5'd0;
        end else begin
            if (fat_inval_br) begin
                for (fk = 0; fk < FATN; fk = fk + 1)
                    if (fat_wmatch[fk]) fat_valid[fk] <= 1'b0;
            end
            if (fat_learn_jal || fat_learn_jalr || fat_learn_br) begin
                fat_pc[fat_wslot]     <= fat_learn_jal ? pc_id : ex_pc;
                fat_target[fat_wslot] <= fat_learn_jal ? (pc_id + d_imm) : actual_target;
                fat_type[fat_wslot]   <= fat_learn_jal ? BT_JMP :
                                         fat_learn_br  ? BT_BR  :
                                         (ex_is_ret ? BT_RET : BT_JMP);
                fat_valid[fat_wslot]  <= 1'b1;
                if (fat_wslot == fat_rr) fat_rr <= fat_rr + 5'd1;
            end
        end
    end

    // ---- 预测表 SRAM 读写 ----
    wire ex_br_resolve   = ex_valid && ex_is_branch && !pipe_freeze;
    wire ex_jalr_resolve = ex_valid && ex_is_jalr   && !pipe_freeze;
    // JAL 在 ID 拍直接算出精确目标，无需进预测表（写入只会顶掉读口）

    // BHT 更新基于 ID 拍随指令读出的旧值（锁存进 ID/EX 的 ex_bht）
    wire [1:0] new_bht = br_taken ? (ex_bht == 2'b11 ? 2'b11 : ex_bht + 2'd1)
                                  : (ex_bht == 2'b00 ? 2'b00 : ex_bht - 2'd1);
    wire prd_we    = ex_br_resolve || ex_jalr_resolve;
    wire [7:0] prd_widx  = ex_pc[9:2];
    wire [36:0] prd_wdata =
        ex_br_resolve   ? {1'b1, BT_BR, actual_target, new_bht} :
                          {1'b1, ex_is_ret ? BT_RET : BT_JMP, actual_target, ex_bht};

    // 读地址与 i-cache 同规则：正常读 pc_f，停顿重读 pc_id
    wire [7:0] prd_ridx = front_stall ? pc_id[9:2] : pc_f[9:2];
    wire [36:0] prd_rdata;
    // 写占口的拍，读数据无效：打一拍随指令流动
    reg  prd_pv;
    always @(posedge clock) begin
        if (reset) prd_pv <= 1'b0;
        else       prd_pv <= !prd_we;
    end

    sram_fakeram #(.DEPTH(256), .WIDTH(37), .WRITE_GRANULARITY(37)) pred_ram (
        .clk(clock), .en(1'b1), .we(prd_we), .wmask(1'b1),
        .addr(prd_we ? prd_widx : prd_ridx), .wdata(prd_wdata), .rdata(prd_rdata));

    wire        prd_hit    = prd_pv && prd_rdata[36];
    wire [1:0]  prd_type   = prd_rdata[35:34];
    wire [31:0] prd_target = prd_rdata[33:2];
    wire [1:0]  prd_bht    = prd_rdata[1:0];

    // ---- ID 级预测决策 ----
    wire id_pred_taken = d_jal ? 1'b1 :
                         d_ret  ? (ras_cnt_eff != 4'd0) :
                         d_branch ? (prd_hit && prd_type == BT_BR && prd_bht[1]) :
                         d_jalr ? ((prd_hit && prd_type == BT_JMP) || id_if_taken) : 1'b0;
    wire [31:0] id_pred_target = d_jal ? (pc_id + d_imm) :
                                 d_ret ? ras_top :
                                 d_branch ? prd_target :
                                 (prd_hit && prd_type == BT_JMP) ? prd_target :
                                 id_if_target;

    wire id_redirect = front_adv && id_valid &&
                       (d_jal ? (!id_if_taken || id_if_target != pc_id + d_imm)
                              : (id_if_taken ? !id_pred_taken : id_pred_taken));
    wire [31:0] id_target = id_pred_taken ? id_pred_target : (pc_id + 32'd4);

    // 流入 EX 的预测记录（供 EX 验证）
    wire eff_pred_taken  = id_redirect ? id_pred_taken : id_if_taken;
    wire [31:0] eff_pred_target = id_redirect ? id_pred_target : id_if_target;

    // ---- RAS 更新 ----
    always @(posedge clock) begin
        if (reset) begin
            ras_cnt      <= 4'd0;
        end else begin
            case ({ex_push, ex_pop})
                2'b10: begin
                    if (ras_cnt != 4'd8) begin
                        ras[ras_cnt[2:0]] <= ex_pc + 32'd4;
                        ras_cnt <= ras_cnt + 4'd1;
                    end
                end
                2'b01: if (ras_cnt != 4'd0) ras_cnt <= ras_cnt - 4'd1;
                default: ;
            endcase
        end
    end

    // ==================== IF / IF-ID ====================
    always @(posedge clock) begin
        if (reset) begin
            pc_f <= 32'b0;
        end else if (ex_redirect) begin
            pc_f <= ex_target;
        end else if (id_redirect) begin
            pc_f <= id_target;
        end else if (front_adv) begin
            pc_f <= if_pred_taken ? if_pred_target : (pc_f + 32'd4);
        end
    end

    always @(posedge clock) begin
        if (reset) begin
            id_valid     <= 1'b0;
            pc_id        <= 32'b0;
            id_if_taken  <= 1'b0;
            id_if_target <= 32'b0;
        end else if (ex_redirect) begin
            id_valid <= 1'b0;
        end else if (front_adv) begin
            pc_id        <= pc_f;
            id_valid     <= !id_redirect;
            id_if_taken  <= if_pred_taken;
            id_if_target <= if_pred_target;
        end
    end

    // ==================== 写回（MEM 级直接写寄存器堆，无独立 WB 级） ====================
    wire rf_we = mem_valid && mem_regwrite && (mem_rd != 5'd0) && !fz_hold2;
    always @(posedge clock) begin
        if (rf_we) rf[mem_rd] <= mem_wb_value;
    end

    // ==================== ID/EX ====================
    // 寄存器堆异步读：不用 32:1 mux 树（选择位每 bit 驱动 ~256 个节点，
    // 且该工具链会把别名复制/缓冲层次合并回去，无法手工分摊扇出），
    // 改为一热译码 + AND/OR 列读：rs1/rs2 每 bit 只驱动 32 个比较器，
    // 每根一热线驱动 32 个 AND，OR 树各级扇出 <= 2，全程低扇出。
    wire [31:0] rs1_sel, rs2_sel;
    wire [31:0] rf_rs1, rf_rs2;
    genvar ri, rb;
    generate
        for (ri = 0; ri < 32; ri = ri + 1) begin : g_rfdec
            assign rs1_sel[ri] = (d_rs1 == ri[4:0]);
            assign rs2_sel[ri] = (d_rs2 == ri[4:0]);
        end
        for (rb = 0; rb < 32; rb = rb + 1) begin : g_rfrd
            wire [31:0] col1, col2;
            for (ri = 0; ri < 32; ri = ri + 1) begin : g_rfcol
                assign col1[ri] = rf[ri][rb] && rs1_sel[ri];
                assign col2[ri] = rf[ri][rb] && rs2_sel[ri];
            end
            assign rf_rs1[rb] = |col1;
            assign rf_rs2[rb] = |col2;
        end
    endgenerate
    always @(posedge clock) begin
        if (reset) begin
            ex_valid <= 1'b0;
        end else if (front_adv) begin            if (ex_redirect) begin
                ex_valid <= 1'b0;      // 冲刷 ID 中的错误路径指令
            end else begin
                ex_valid     <= id_valid;
                ex_pc        <= pc_id;
                ex_rs1       <= d_rs1;
                ex_rs2       <= d_rs2;
                ex_rd        <= d_rd;
                // MEM->ID 旁路：MEM 本拍写入的寄存器，ID 同拍读到旧值，需旁路
                ex_rs1v      <= (d_rs1 != 5'd0 && rf_we && mem_rd == d_rs1)
                                ? mem_wb_value : rf_rs1;
                ex_rs2v      <= (d_rs2 != 5'd0 && rf_we && mem_rd == d_rs2)
                                ? mem_wb_value : rf_rs2;
                ex_imm       <= d_imm;
                ex_aluop     <= d_aluop;
                ex_srca_pc   <= d_srca_pc;
                ex_srcb_imm  <= d_srcb_imm;
                ex_is_load   <= d_load;
                ex_is_store  <= d_store;
                ex_mem_f3    <= d_f3;
                ex_regwrite  <= d_regwrite;
                ex_wb_pc4    <= d_jal || d_jalr;
                ex_is_branch <= d_branch;
                ex_br_f3     <= d_f3;
                ex_is_jalr   <= d_jalr;
                ex_pred_taken  <= eff_pred_taken;
                ex_pred_target <= eff_pred_target;
                ex_bht         <= prd_bht;
                ex_is_call   <= d_call;
                ex_is_ret    <= d_ret;
                ex_is_mul    <= d_mext && !d_f3[2];
                ex_is_div    <= d_mext &&  d_f3[2];
                ex_m_f3      <= d_f3;
            end
        end else if (!pipe_freeze && !div_stall && !lx_stall) begin
            // 仅 i-cache 停顿：ID 中是指令缺失的垃圾数据，绝不能进入 EX，
            // 注气泡（EX 下游继续排空）；真正的指令在填充完成后重新进入 ID
            ex_valid <= 1'b0;
        end else if (!pipe_freeze) begin
            // EX 指令被 div_stall/lx_stall 保持：捕获最新前递值，
            // 否则前递源（MEM/WB）排空后会退回 ID 时锁存的陈旧 rf 值
            ex_rs1v <= fwd_a;
            ex_rs2v <= fwd_b;
        end
    end

    // ==================== EX ====================
    // 前递
    wire [31:0] dc_word = dc_line_rdata[{mem_alu[3:2], 5'b0} +: 32];
    wire [31:0] mem_load_ext = dc_crit_valid ? load_extend(dc_crit_word, mem_f3, mem_alu[1:0])
                                             : load_extend(dc_word, mem_f3, mem_alu[1:0]);
    wire [31:0] mem_fwd = mem_is_load ? mem_load_ext : mem_alu;

    wire fa_mem = mem_valid && mem_regwrite && (mem_rd == ex_rs1) && (ex_rs1 != 5'd0);
    wire fb_mem = mem_valid && mem_regwrite && (mem_rd == ex_rs2) && (ex_rs2 != 5'd0);
    assign fwd_a = fa_mem ? mem_fwd : ex_rs1v;
    assign fwd_b = fb_mem ? mem_fwd : ex_rs2v;

    wire [31:0] alu_a = ex_srca_pc ? ex_pc : fwd_a;
    wire [31:0] alu_b = ex_srcb_imm ? ex_imm : fwd_b;

    reg [31:0] alu_res;
    always @(*) begin
        case (ex_aluop)
            ALU_ADD:   alu_res = alu_a + alu_b;
            ALU_SUB:   alu_res = alu_a - alu_b;
            ALU_SLL:   alu_res = alu_a << alu_b[4:0];
            ALU_SLT:   alu_res = ($signed(alu_a) < $signed(alu_b)) ? 32'd1 : 32'd0;
            ALU_SLTU:  alu_res = (alu_a < alu_b) ? 32'd1 : 32'd0;
            ALU_XOR:   alu_res = alu_a ^ alu_b;
            ALU_SRL:   alu_res = alu_a >> alu_b[4:0];
            ALU_SRA:   alu_res = $signed(alu_a) >>> alu_b[4:0];
            ALU_OR:    alu_res = alu_a | alu_b;
            ALU_AND:   alu_res = alu_a & alu_b;
            default:   alu_res = alu_b;   // ALU_PASSB
        endcase
    end

    // 乘法（单拍组合）：一个 33x33 有符号乘法器 + 符号修正
    // uu = ss + 2^32*(a[31]*b + b[31]*a)；su = uu - 2^32*a[31]*b（高 32 位模 2^32）
    wire signed [63:0] mul_ss  = $signed({fwd_a[31], fwd_a}) * $signed({fwd_b[31], fwd_b});
    wire [31:0] mul_uu_hi = mul_ss[63:32] + (fwd_a[31] ? fwd_b : 32'b0)
                                          + (fwd_b[31] ? fwd_a : 32'b0);
    wire [31:0] mul_su_hi = mul_uu_hi - (fwd_a[31] ? fwd_b : 32'b0);
    reg [31:0] mul_res;
    always @(*) begin
        case (ex_m_f3[1:0])
            2'b00:   mul_res = mul_ss[31:0];    // MUL
            2'b01:   mul_res = mul_ss[63:32];   // MULH
            2'b10:   mul_res = mul_su_hi;       // MULHSU
            default: mul_res = mul_uu_hi;       // MULHU
        endcase
    end

    wire [31:0] ex_result = ex_wb_pc4 ? (ex_pc + 32'd4) :
                            ex_is_mul ? mul_res :
                            ex_is_div ? (div_spec_r ? div_spec_res_r
                                                    : div_result) :
                            alu_res;

    divider u_div (
        .clk(clock), .reset(reset),
        .start(div_start), .a(fwd_a), .b(fwd_b), .op(ex_m_f3[1:0]),
        .busy(div_busy), .done(div_done), .result(div_result)
    );

`ifdef DEBUG
    always @(posedge clock) begin
        if (div_start) $display("[DIV] start a=%h b=%h op=%d", fwd_a, fwd_b, ex_m_f3[1:0]);
        if (div_done)  $display("[DIV] done result=%h", div_result);
        if (!reset && ex_valid && ex_is_div && div_special) $display("[DIV] special a=%h b=%h res=%h", fwd_a, fwd_b, div_spec_res);
    end
`endif

    // ==================== EX/MEM ====================
    always @(posedge clock) begin
        if (reset) begin
            mem_valid <= 1'b0;
        end else if (!fz_hold1) begin
            if (div_stall || lx_stall) begin
                mem_valid <= 1'b0;      // 除法期间/端口冲突时插气泡
            end else begin
                mem_valid      <= ex_valid;
                mem_alu        <= ex_result;
                mem_store_data <= fwd_b;
                mem_rd         <= ex_rd;
                mem_regwrite   <= ex_regwrite;
                mem_is_load    <= ex_is_load;
                mem_is_store   <= ex_is_store;
                mem_f3         <= ex_mem_f3;
                mem_pc         <= ex_pc;
            end
        end
    end

    // ==================== MEM ====================
    wire [31:0] st_w32  = (mem_f3 == 3'b000) ? {4{mem_store_data[7:0]}} :
                          (mem_f3 == 3'b001) ? {2{mem_store_data[15:0]}} :
                                               mem_store_data;
    wire [3:0]  st_strb = (mem_f3 == 3'b000) ? (4'b0001 << mem_alu[1:0]) :
                          (mem_f3 == 3'b001) ? (4'b0011 << mem_alu[1:0]) :
                                               4'b1111;
    wire dc_store_wr = mem_valid && mem_is_store && dc_hit && !fz_hold1;
    wire sb_push     = mem_valid && mem_is_store && !fz_hold1;

    wire [31:0] mem_wb_value = mem_is_load ? mem_load_ext : mem_alu;

`ifdef DEBUG
    integer c_cycles, c_retire, c_flush, c_icmiss, c_dcmiss, c_div, c_lx, c_sbfull, c_branch, c_jal, c_jalr, c_tmp1, c_tmp2, c_tmp3, c_tmp4;
    initial begin c_cycles=0;c_retire=0;c_flush=0;c_icmiss=0;c_dcmiss=0;c_div=0;c_lx=0;c_sbfull=0;c_branch=0;c_jal=0;c_jalr=0;c_tmp1=0;c_tmp2=0;c_tmp3=0;c_tmp4=0; end
    always @(posedge clock) if (!reset) begin
        c_cycles <= c_cycles + 1;
        if (!pipe_freeze && mem_valid) c_retire <= c_retire + 1;
        if (ex_redirect) c_flush <= c_flush + 1;
        if (prd_we && c_cycles < 3000)
            $display("[PRDWR] idx=%h wdata=%h", prd_widx, prd_wdata);
        if (front_adv && id_valid && d_branch && c_cycles < 3000)
            $display("[PRDRD] pc=%h pv=%d rdata=%h", pc_id, prd_pv, prd_rdata);
        if (front_adv && id_valid && d_branch && id_pred_taken && c_tmp4 < 2000 && c_cycles > 2000)
            $display("[BRID] pc=%h pred_t=%h rdata=%h pv=%d", pc_id, id_pred_target, prd_rdata, prd_pv);
        if (ex_redirect && ex_is_branch && c_tmp4 < 2000 && c_cycles > 2000) begin
            c_tmp4 <= c_tmp4 + 1;
            $display("[BRMISS] pc=%h taken=%d pred_taken=%d pred_t=%h actual_t=%h", ex_pc, br_taken, ex_pred_taken, ex_pred_target, actual_target);
        end
        if (ic_miss) c_icmiss <= c_icmiss + 1;
        if (dc_miss) c_dcmiss <= c_dcmiss + 1;
        if (div_start) c_div <= c_div + 1;
        if (lx_stall) c_lx <= c_lx + 1;
        if (sb_stall) c_sbfull <= c_sbfull + 1;
        if (!pipe_freeze && mem_valid && 0) ;
        if (ex_valid && ex_is_branch && ex_redirect) c_branch <= c_branch + 1;
        if (id_redirect) c_jal <= c_jal + 1;
        if (ex_valid && ex_is_jalr && ex_redirect) c_jalr <= c_jalr + 1;
        if (ex_br_resolve && br_taken) c_tmp1 <= c_tmp1 + 1;
        if (front_adv && id_valid && d_branch && id_pred_taken) c_tmp2 <= c_tmp2 + 1;
        if (front_adv && id_valid && d_branch && !id_pred_taken) c_tmp3 <= c_tmp3 + 1;
        if (front_adv && id_valid && d_branch && !prd_pv) c_tmp4 <= c_tmp4 + 1;

        if (front_adv && id_valid && d_jalr) begin
            if (id_if_taken) c_tmp1 <= c_tmp1 + 1;
            else if (d_ret) begin
                c_tmp2 <= c_tmp2 + 1;
                if (c_tmp2[9:0] == 10'd0)
                    $display("[RETNP] cyc=%0d pc=%h ras=%0d cnt=%0d", c_cycles, pc_id, ras_cnt, c_tmp2);
            end else c_tmp4 <= c_tmp4 + 1;
        end
        if (awvalid && awready && awaddr == 32'h80000000)
            $display("[PERF4] jalr_pred=%0d ret_nopred=%0d call_nopred=%0d", c_tmp1, c_tmp2, c_tmp4);
        if (front_adv && id_valid && d_jal) begin
            if (id_if_taken) c_tmp3 <= c_tmp3 + 1; else c_tmp4 <= c_tmp4 + 1;
        end
        if (awvalid && awready && awaddr == 32'h80000000) begin
            $display("[PERF3] jalr_ifpred=%0d jalr_nopred=%0d jal_ifpred=%0d jal_nopred=%0d", c_tmp1, c_tmp2, c_tmp3, c_tmp4);
            $display("[PERF2] br_taken=%0d br_predtaken=%0d br_notpred=%0d br_pvkill=%0d", c_tmp1, c_tmp2, c_tmp3, c_tmp4);
            $display("[PERF] cycles=%0d retire=%0d flush=%0d icmiss=%0d dcmiss=%0d div=%0d lx=%0d sbfull=%0d br_flush=%0d jal=%0d jalr=%0d",
                c_cycles, c_retire, c_flush, c_icmiss, c_dcmiss, c_div, c_lx, c_sbfull, c_branch, c_jal, c_jalr);
        end
    end
    always @(posedge clock) begin
        if (awvalid && awready)
            $display("[ST] addr=%h data=%h strb=%b", awaddr, wdata, wstrb);
        if (mem_valid && mem_is_load && mem_pc==32'h1bc)
            $display("[LDX] addr=%h hit=%d critv=%d val=%h", mem_alu, dc_hit, dc_crit_valid, mem_load_ext);
        if (dc_miss && c_cycles > 600 && c_cycles < 700)
            $display("[GATE] cyc=%0d line=%h clr=%d clr2=%d h=%0d t=%0d e0=%h e1=%h", c_cycles, mem_alu[31:4], sb_clear, sb_clear2, u_storebuf.head, u_storebuf.tail, u_storebuf.addr_q[0], u_storebuf.addr_q[1]);
        if (mem_valid && mem_is_store && mem_alu[31:4]==28'h2a)
            $display("[STX] addr=%h data=%h hit=%d freeze=%d cyc=%0d", mem_alu, st_w32, dc_hit, pipe_freeze, c_cycles);
        if (mem_valid && mem_is_load && mem_alu[31:4]==28'h2a)
            $display("[LD2A] addr=%h hit=%d critv=%d val=%h cyc=%0d", mem_alu, dc_hit, dc_crit_valid, mem_load_ext, c_cycles);
        if (mem_valid && mem_is_load && mem_alu[31:4]==28'h5c)
            $display("[LD] pc=%h addr=%h hit=%d val=%h", mem_pc, mem_alu, dc_hit, mem_load_ext);
        if (dc_store_wr && mem_alu[31:4]==28'h5c)
            $display("[CW] addr=%h wdata=%h wmask=%h", mem_alu, {4{st_w32}}, {{12'b0},st_strb} << mem_alu[3:0]);
        if (sb_push && mem_alu[31:4]==28'h5c)
            $display("[PUSH] addr=%h data=%h", mem_alu, st_w32);
        if (!reset && !pipe_freeze && mem_valid)
            $display("[MEM] pc=%h alu=%h ld=%d st=%d hit=%d fwd=%h", mem_pc, mem_alu, mem_is_load, mem_is_store, dc_hit, mem_wb_value);
        if (!reset && rf_we)
            $display("[WB] pc=%h rd=%d val=%h", mem_pc, mem_rd, mem_wb_value);
        if (ex_redirect)
            $display("[REDIR] ex_pc=%h target=%h", ex_pc, ex_target);
    end
`endif

    // ==================== AXI 读仲裁（i/d cache 共享 AR/R） ====================
    reg [1:0] ar_owner;   // 0=空闲 1=dcache 2=icache
    always @(posedge clock) begin
        if (reset) ar_owner <= 2'd0;
        else case (ar_owner)
            2'd0: if (dc_req)      ar_owner <= 2'd1;
                  else if (ic_req) ar_owner <= 2'd2;
            2'd1: if (dc_last_r)   ar_owner <= 2'd0;
            2'd2: if (ic_last_r)   ar_owner <= 2'd0;
            default: ar_owner <= 2'd0;
        endcase
    end
    wire dc_grant = (ar_owner == 2'd1);
    wire ic_grant = (ar_owner == 2'd2);

    assign araddr  = dc_grant ? dc_ar_addr : ic_ar_addr;
    assign arvalid = dc_grant ? dc_ar_valid : (ic_grant ? ic_ar_valid : 1'b0);
    assign rready  = 1'b1;
    assign bready  = 1'b1;

    // ==================== 子模块 ====================
    icache u_icache (
        .clk(clock), .reset(reset),
        .pc_f(pc_f), .pc_id(pc_id), .front_stall(front_stall),
        .instr(ic_instr), .hit(ic_hit),
        .miss(ic_miss), .busy(ic_busy),
        .req(ic_req), .grant(ic_grant),
        .ar_addr(ic_ar_addr), .ar_valid(ic_ar_valid), .ar_ready(arready),
        .rdata(rdata), .rvalid(rvalid), .last_r(ic_last_r)
    );

    dcache u_dcache (
        .clk(clock), .reset(reset),
        .ex_addr(alu_res), .mem_addr(mem_alu), .hold(fz_hold3),
        .store_wr(dc_store_wr),
        .store_wdata({4{st_w32}}),
        .store_wmask({{12'b0}, st_strb} << mem_alu[3:0]),
        .hit(dc_hit), .line_rdata(dc_line_rdata),
        .miss(dc_miss), .busy(dc_busy), .fillwrite(dc_fillwrite), .fill_clash(dc_fill_clash),
        .crit_valid(dc_crit_valid), .crit_word(dc_crit_word), .crit_consume(crit_consume),
        .sb_clear(sb_clear), .sb_clear2(sb_clear2), .sb_clear3(sb_clear3),
        .req(dc_req), .grant(dc_grant),
        .ar_addr(dc_ar_addr), .ar_valid(dc_ar_valid), .ar_ready(arready),
        .rdata(rdata), .rvalid(rvalid), .last_r(dc_last_r)
    );

    storebuf u_storebuf (
        .clk(clock), .reset(reset),
        .push(sb_push), .push_addr({mem_alu[31:2], 2'b00}),
        .push_data(st_w32), .push_strb(st_strb),
        .full(sb_full),
        .chk_line(mem_alu[31:4]), .chk_clear(sb_clear),
        .chk_line2(mem_alu[31:4] + 28'd1), .chk_clear2(sb_clear2),
        .chk_line3(mem_alu[31:4] + 28'd2), .chk_clear3(sb_clear3),
        .awaddr(awaddr), .awvalid(awvalid), .awready(awready),
        .wdata(wdata), .wstrb(wstrb), .wvalid(wvalid), .wready(wready),
        .bvalid(bvalid)
    );

endmodule
