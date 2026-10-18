// ============================================================================
// student_top.v —— 双发射 Tomasulo + ROB 乱序 RV32IM CPU
//
// 前端：pc_f 预取指针 + 4 深取指队列（单 outstanding 读，命中一行可入队两条），
//   FAT(BTB) 每取指槽一份预测，banked BHT(2x128x37)，RAS 提交期更新；
//   弹出（dispatch）时复核 JAL/JALR/分支预测，不符即在弹出点重定向。
// 后端：RS(16) + ROB(32，最多用30) + MOB(16) + PRF(64) + RAT快照(8) + 空闲列表
//   端口：port0 全功能（含分支解析/乘除/store），port1 简单 ALU，load 专用通道
//   CDB：cdbA(port0+div) / cdbB(port1) / cdb1(load)，三级唤醒
// 恢复：分支/JALR 分发时拍 RAT 快照；误预测一拍恢复 RAT + ROB/MOB/FL 回滚
// 访存：load 只有在 MOB 头才能发（保守）；store 提交时两级流水写 d-cache+写穿
// ============================================================================

`include "verilog/params.vh"

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

    localparam ALU_ADD = 4'd0, ALU_SUB = 4'd1, ALU_SLL = 4'd2, ALU_SLT = 4'd3,
               ALU_SLTU = 4'd4, ALU_XOR = 4'd5, ALU_SRL = 4'd6, ALU_SRA = 4'd7,
               ALU_OR  = 4'd8, ALU_AND = 4'd9, ALU_PASSB = 4'd10;

    // ==================== 可配置微架构参数 ====================
    parameter ISSUE_WIDTH = `CPU_ISSUE_WIDTH;      // 发射宽度：1 或 2
    parameter ROB_DEPTH   = `CPU_ROB_DEPTH;     // ROB 有效深度：16/32
    parameter PRF_SIZE    = `CPU_PRF_SIZE;     // 可分配物理寄存器数：64/96/128
    parameter RS_DEPTH    = `CPU_RS_DEPTH;     // 保留站有效深度：8/16
    parameter MOB_DEPTH   = `CPU_MOB_DEPTH;     // MOB 有效深度：8/16
    parameter Q_DEPTH     = `CPU_Q_DEPTH;      // 取指队列有效深度：2/4
    parameter ICACHE_LINES = `CPU_ICACHE_LINES;   // I-Cache 行数
    parameter DCACHE_LINES = `CPU_DCACHE_LINES;  // D-Cache 行数
    parameter ICACHE_WAYS  = `CPU_ICACHE_WAYS;     // I-Cache 相联度
    parameter DCACHE_WAYS  = `CPU_DCACHE_WAYS;     // D-Cache 相联度
    parameter STORE_BUF_DEPTH = `CPU_STORE_BUF_DEPTH;  // Store Buffer 深度

    localparam RSN = 16;            // 物理 RS 槽位数
    localparam ROBN = 32;           // 物理 ROB 槽位数
    localparam MOBN = 16;           // 物理 MOB 槽位数
    localparam QN = 4;              // 物理取指队列槽位数
    localparam FATN = 32;           // 物理 FAT 表项数
    localparam ISSUE2 = (ISSUE_WIDTH >= 2);

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

    function is_young;
        input [4:0] tag, br, tl;
        reg [4:0] d, r;
        begin
            d = tag - br;
            r = tl - br;
            is_young = (d != 5'd0) && (d < r);
        end
    endfunction

    // 译码宏（对任意指令字）
    `define DECODE(pref, iw) \
        wire [6:0] pref``_op  = iw[6:0]; \
        wire [2:0] pref``_f3  = iw[14:12]; \
        wire [6:0] pref``_f7  = iw[31:25]; \
        wire [4:0] pref``_rs1 = iw[19:15]; \
        wire [4:0] pref``_rs2 = iw[24:20]; \
        wire [4:0] pref``_rd  = iw[11:7]; \
        wire pref``_lui    = (pref``_op == OP_LUI); \
        wire pref``_auipc  = (pref``_op == OP_AUIPC); \
        wire pref``_jal    = (pref``_op == OP_JAL); \
        wire pref``_jalr   = (pref``_op == OP_JALR); \
        wire pref``_branch = (pref``_op == OP_BRANCH); \
        wire pref``_load   = (pref``_op == OP_LOAD); \
        wire pref``_store  = (pref``_op == OP_STORE); \
        wire pref``_opimm  = (pref``_op == OP_OPIMM); \
        wire pref``_opr    = (pref``_op == OP_OP); \
        wire pref``_mext   = pref``_opr && (pref``_f7 == 7'b0000001); \
        wire pref``_mem    = pref``_load || pref``_store; \
        wire [31:0] pref``_imm = \
            (pref``_lui || pref``_auipc) ? {iw[31:12], 12'b0} : \
            pref``_jal    ? {{12{iw[31]}}, iw[19:12], iw[20], iw[30:21], 1'b0} : \
            pref``_branch ? {{20{iw[31]}}, iw[7], iw[30:25], iw[11:8], 1'b0} : \
            pref``_store  ? {{20{iw[31]}}, iw[31:25], iw[11:7]} : \
                            {{20{iw[31]}}, iw[31:20]}; \
        wire pref``_regwrite = pref``_lui || pref``_auipc || pref``_jal || pref``_jalr || \
                               pref``_load || pref``_opimm || pref``_opr; \
        wire pref``_srcb_imm = pref``_lui || pref``_auipc || pref``_opimm || pref``_load || pref``_store; \
        wire pref``_srca_pc  = pref``_auipc; \
        wire pref``_has_pdst = pref``_regwrite && (pref``_rd != 5'd0); \
        wire pref``_s1_need  = !pref``_lui && !pref``_auipc && !pref``_jal; \
        wire pref``_s2_need  = pref``_opr || pref``_branch || pref``_store; \
        wire pref``_call = (pref``_jal || pref``_jalr) && (pref``_rd == 5'd1); \
        wire pref``_ret  = pref``_jalr && (pref``_rs1 == 5'd1) && (pref``_rd == 5'd0);

    function [3:0] aluop_of;
        input [31:0] iw;
        begin
            if (iw[6:0] == OP_LUI) aluop_of = ALU_PASSB;
            else if (iw[6:0] == OP_AUIPC || iw[6:0] == OP_JAL || iw[6:0] == OP_JALR ||
                     iw[6:0] == OP_LOAD || iw[6:0] == OP_STORE) aluop_of = ALU_ADD;
            else if (iw[6:0] == OP_OPIMM) begin
                case (iw[14:12])
                    3'b000:  aluop_of = ALU_ADD;
                    3'b010:  aluop_of = ALU_SLT;
                    3'b011:  aluop_of = ALU_SLTU;
                    3'b100:  aluop_of = ALU_XOR;
                    3'b110:  aluop_of = ALU_OR;
                    3'b111:  aluop_of = ALU_AND;
                    3'b001:  aluop_of = ALU_SLL;
                    default: aluop_of = iw[30] ? ALU_SRA : ALU_SRL;
                endcase
            end else if (iw[6:0] == OP_OP && iw[31:25] != 7'b0000001) begin
                case (iw[14:12])
                    3'b000:  aluop_of = iw[30] ? ALU_SUB : ALU_ADD;
                    3'b001:  aluop_of = ALU_SLL;
                    3'b010:  aluop_of = ALU_SLT;
                    3'b011:  aluop_of = ALU_SLTU;
                    3'b100:  aluop_of = ALU_XOR;
                    3'b101:  aluop_of = iw[30] ? ALU_SRA : ALU_SRL;
                    3'b110:  aluop_of = ALU_OR;
                    default: aluop_of = ALU_AND;
                endcase
            end else aluop_of = ALU_ADD;
        end
    endfunction

    // ==================== 分支预测器表项 ====================
    localparam BT_BR  = 2'd0;
    localparam BT_JMP = 2'd1;
    localparam BT_RET = 2'd2;

    // ==================== FAT（32 项全相联，双读口） ====================
    reg [31:0] fat_pc [0:FATN-1];
    reg [31:0] fat_target [0:FATN-1];
    reg [1:0]  fat_type [0:FATN-1];
    reg [FATN-1:0] fat_valid;
    reg [4:0]  fat_rr;

    reg [31:0] pc_f;

    wire [FATN-1:0] fat_match1, fat_match2;
    genvar gi;
    generate
        for (gi = 0; gi < FATN; gi = gi + 1) begin : g_fat
            assign fat_match1[gi] = fat_valid[gi] && (fat_pc[gi] == pc_f);
            assign fat_match2[gi] = fat_valid[gi] && (fat_pc[gi] == pc_f + 32'd4);
        end
    endgenerate

    integer fi;
    reg [31:0] fat1_target, fat2_target;
    reg [1:0]  fat1_type, fat2_type;
    always @(*) begin
        fat1_target = 32'b0; fat1_type = 2'b0;
        fat2_target = 32'b0; fat2_type = 2'b0;
        for (fi = FATN-1; fi >= 0; fi = fi - 1) begin
            if (fat_match1[fi]) begin fat1_target = fat_target[fi]; fat1_type = fat_type[fi]; end
            if (fat_match2[fi]) begin fat2_target = fat_target[fi]; fat2_type = fat_type[fi]; end
        end
    end

    // ==================== RAS（提交期更新，每拍至多 2 次操作） ====================
    reg [31:0] ras [0:7];
    reg [3:0]  ras_cnt;
    wire        commit0, commit1;
    wire [4:0]  rh  = rob_head[4:0];
    wire [4:0]  rh1 = rob_head[4:0] + 5'd1;
    wire        c0_push = commit0 && rob_is_call[rh];
    wire        c0_pop  = commit0 && rob_is_ret[rh] && rob_pred_taken[rh];
    wire        c1_push = commit1 && rob_is_call[rh1];
    wire        c1_pop  = commit1 && rob_is_ret[rh1] && rob_pred_taken[rh1];
    wire [3:0]  ras_cnt_eff = ras_cnt - {3'b0, (c0_pop || c1_pop)};
    wire [2:0]  ras_top_idx = ras_cnt_eff[2:0] - 3'd1;
    wire [31:0] ras_top = c1_push ? (rob_pc[rh1] + 32'd4) :
                          c0_push ? (rob_pc[rh]  + 32'd4) : ras[ras_top_idx];

    // ==================== 取指队列 ====================
    reg [31:0] q_pc   [0:QN-1];
    reg [31:0] q_ins  [0:QN-1];
    reg        q_ift  [0:QN-1];       // IF 级（FAT）预测
    reg [31:0] q_iftg [0:QN-1];
    reg [36:0] q_prd  [0:QN-1];       // BHT 表项（含 pv 折叠进 hit）
    reg        q_pv   [0:QN-1];
    reg [2:0]  q_cnt;                 // 0..QN

    // 在飞读（单 outstanding）
    reg        pend_v;
    reg        pend_m2;               // 取两个槽（f1,f2）
    reg [31:0] pend_pc;
    reg        pend_ift1, pend_ift2;
    reg [31:0] pend_iftg1, pend_iftg2;

    wire [31:0] ic_instr, ic_instr2;
    wire        ic_hit, ic_hit2, ic_busy;

    wire ic_miss  = pend_v && !ic_hit;
    wire front_stall = ic_miss || ic_busy;

    // ==================== BHT（2 bank x 128 x 37） ====================
    wire        iss0_fire;
    wire [31:0] iss0_pc;
    wire        iss0_is_cbranch, iss0_is_jalr, iss0_is_ret;
    wire        br0_taken;
    wire [31:0] resolve_target;
    wire [1:0]  iss0_bht;

    wire br0_resolve   = iss0_fire && iss0_is_cbranch;
    wire jalr0_resolve = iss0_fire && iss0_is_jalr;
    wire prd_we   = br0_resolve || jalr0_resolve;
    wire [1:0] new_bht = br0_taken ? (iss0_bht == 2'b11 ? 2'b11 : iss0_bht + 2'd1)
                                   : (iss0_bht == 2'b00 ? 2'b00 : iss0_bht - 2'd1);
    wire [36:0] prd_wdata =
        br0_resolve ? {1'b1, BT_BR, resolve_target, new_bht} :
                      {1'b1, iss0_is_ret ? BT_RET : BT_JMP, resolve_target, iss0_bht};
    wire we_bank0 = prd_we && !iss0_pc[2];
    wire we_bank1 = prd_we &&  iss0_pc[2];

    // 读口：f1 在 bank pc_f[2]，f2 在对侧 bank
    wire [6:0] rd_idx1 = pc_f[9:3];
    wire [6:0] rd_idx2 = (pc_f + 32'd4) >> 3;
    wire [36:0] bank0_rdata, bank1_rdata;
    reg  pv0, pv1;
    always @(posedge clock) begin
        if (reset) begin pv0 <= 1'b0; pv1 <= 1'b0; end
        else begin
            pv0 <= !we_bank0;
            pv1 <= !we_bank1;
        end
    end
    sram_fakeram #(.DEPTH(128), .WIDTH(37), .WRITE_GRANULARITY(37)) bht0 (
        .clk(clock), .en(1'b1), .we(we_bank0), .wmask(1'b1),
        .addr(we_bank0 ? iss0_pc[9:3] : (pc_f[2] ? rd_idx2 : rd_idx1)),
        .wdata(prd_wdata), .rdata(bank0_rdata));
    sram_fakeram #(.DEPTH(128), .WIDTH(37), .WRITE_GRANULARITY(37)) bht1 (
        .clk(clock), .en(1'b1), .we(we_bank1), .wmask(1'b1),
        .addr(we_bank1 ? iss0_pc[9:3] : (pc_f[2] ? rd_idx1 : rd_idx2)),
        .wdata(prd_wdata), .rdata(bank1_rdata));

    // ==================== FAT 学习/失效（解析时） ====================
    wire        flush;
    wire [31:0] flush_target;
    wire [4:0]  flush_idx;

    wire [FATN-1:0] fat_wmatch;
    generate
        for (gi = 0; gi < FATN; gi = gi + 1) begin : g_fatw
            assign fat_wmatch[gi] = fat_valid[gi] && (fat_pc[gi] == iss0_pc);
        end
    endgenerate
    reg [4:0] fat_wslot;
    always @(*) begin
        fat_wslot = fat_rr;
        for (fi = FATN-1; fi >= 0; fi = fi - 1)
            if (fat_wmatch[fi]) fat_wslot = fi[4:0];
    end

    // id 级重定向（pop 点）信号，后文定义
    wire        pop_redirect;
    wire [31:0] pop_red_target;
    wire        pop_redirect_jal;

    wire fat_learn_jal  = pop_redirect && pop_redirect_jal;
    wire fat_learn_jalr = jalr0_resolve;
    wire fat_learn_br   = br0_resolve && br0_taken;
    wire fat_inval_br   = br0_resolve && !br0_taken;
    wire [31:0] pop_red_pc;
    wire [31:0] pop_red_imm;
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
                fat_pc[fat_wslot]     <= fat_learn_jal ? pop_red_pc : iss0_pc;
                fat_target[fat_wslot] <= fat_learn_jal ? (pop_red_pc + pop_red_imm) : resolve_target;
                fat_type[fat_wslot]   <= fat_learn_jal ? BT_JMP :
                                         fat_learn_br  ? BT_BR  :
                                         (iss0_is_ret ? BT_RET : BT_JMP);
                fat_valid[fat_wslot]  <= 1'b1;
                if (fat_wslot == fat_rr) fat_rr <= fat_rr + 5'd1;
            end
        end
    end

    // ==================== 取指：IF 级预测与读发射 ====================
    // FAT 对 pc_f / pc_f+4 各查一次
    wire f1_fat_taken = (|fat_match1) &&
                        (fat1_type == BT_JMP || fat1_type == BT_BR ||
                         (fat1_type == BT_RET && ras_cnt_eff != 4'd0));
    wire [31:0] f1_fat_target = (fat1_type == BT_RET) ? ras_top : fat1_target;
    wire f2_fat_taken = (|fat_match2) &&
                        (fat2_type == BT_JMP || fat2_type == BT_BR ||
                         (fat2_type == BT_RET && ras_cnt_eff != 4'd0));
    wire [31:0] f2_fat_target = (fat2_type == BT_RET) ? ras_top : fat2_target;

    // 队列空位（本拍弹出后）
    wire [1:0] pop_n;                 // 本拍弹出条数（0/1/2），后文定义
    wire [2:0] q_space = Q_DEPTH - (q_cnt - {1'b0, pop_n});
    wire       f2_line_ok = (pc_f[3:2] != 2'b11);
    wire [1:0] fw_avail = f2_line_ok ? 2'd2 : 2'd1;

    wire [1:0] push_m = (q_space == 3'd0) ? 2'd0 :
                        f1_fat_taken ? 2'd1 :
                        (q_space == 3'd1) ? 2'd1 :
                        (ISSUE2 ? fw_avail : 2'd1);
    wire can_issue_read = !pend_v && (push_m != 2'd0) && !ic_miss && !ic_busy;

    wire [31:0] pc_f_next = f1_fat_taken ? f1_fat_target :
                            (push_m == 2'd2 && f2_fat_taken) ? f2_fat_target :
                            pc_f + {28'b0, push_m, 2'b0};

    // 读地址与对齐保持
    wire [31:0] read_addr = pend_v ? pend_pc : pc_f;
    wire        icache_hold = front_stall;

    // 数据到达（pend 有效且 hit）时入队
    wire        arrive    = pend_v && ic_hit;
    wire        arrive2   = arrive && pend_m2 && ic_hit2;
    wire [36:0] f1_prd = pc_f[2] ? bank1_rdata : bank0_rdata;
    wire [36:0] f2_prd = pc_f[2] ? bank0_rdata : bank1_rdata;
    wire        f1_pv  = pc_f[2] ? pv1 : pv0;
    wire        f2_pv  = pc_f[2] ? pv0 : pv1;

    // ==================== 后端结构 ====================
    reg [6:0]  RAT  [0:31];
    reg [6:0]  snap_rat [0:7][0:31];
    reg [3:0]  snap_head, snap_tail;
    reg [31:0] prf  [0:127];
    reg [127:0] prf_ready;
    reg [6:0]  fl [0:127];
    reg [7:0]  fl_head, fl_tail;

    // ROB
    reg        rob_done      [0:ROBN-1];
    reg [31:0] rob_pc        [0:ROBN-1];
    reg        rob_is_store  [0:ROBN-1];
    reg        rob_is_call   [0:ROBN-1];
    reg        rob_is_ret    [0:ROBN-1];
    reg        rob_pred_taken[0:ROBN-1];
    reg [4:0]  rob_rd        [0:ROBN-1];
    reg        rob_has_pdst  [0:ROBN-1];
    reg [6:0]  rob_pdst      [0:ROBN-1];
    reg [6:0]  rob_pold      [0:ROBN-1];
    reg [7:0]  rob_fl_head   [0:ROBN-1];
    reg [4:0]  rob_mob_tail  [0:ROBN-1];
    reg [5:0]  rob_next_tail [0:ROBN-1];
    reg [3:0]  rob_snap_idx  [0:ROBN-1];
    reg        rob_snap_val  [0:ROBN-1];
    reg [5:0]  rob_head, rob_tail;

    wire        rob_nonempty = (rob_head != rob_tail);
    wire [5:0]  rob_cnt      = rob_tail - rob_head;
    wire        rob_full1    = (rob_cnt >= ROB_DEPTH - 2);   // 留 2 条位置
    wire        rob_full2    = (rob_cnt >= ROB_DEPTH - 3);

    // RS
    reg        rs_valid   [0:RSN-1];
    reg [4:0]  rs_tag     [0:RSN-1];
    reg [31:0] rs_pc      [0:RSN-1];
    reg [31:0] rs_imm     [0:RSN-1];
    reg [3:0]  rs_aluop   [0:RSN-1];
    reg        rs_srca_pc [0:RSN-1];
    reg        rs_srcb_imm[0:RSN-1];
    reg [2:0]  rs_f3      [0:RSN-1];
    reg        rs_is_load [0:RSN-1];
    reg        rs_is_store[0:RSN-1];
    reg        rs_is_branch[0:RSN-1];
    reg        rs_is_jalr [0:RSN-1];
    reg        rs_is_ret_r[0:RSN-1];
    reg        rs_is_mul  [0:RSN-1];
    reg        rs_is_div  [0:RSN-1];
    reg        rs_wb_pc4  [0:RSN-1];
    reg        rs_pred_taken [0:RSN-1];
    reg [31:0] rs_pred_target[0:RSN-1];
    reg [1:0]  rs_bht     [0:RSN-1];
    reg [6:0]  rs_pdst    [0:RSN-1];
    reg        rs_has_pdst[0:RSN-1];
    reg [4:0]  rs_mob_ptr [0:RSN-1];
    reg [6:0]  rs_s1_tag  [0:RSN-1];
    reg        rs_s1_rdy  [0:RSN-1];
    reg [31:0] rs_s1_val  [0:RSN-1];
    reg [6:0]  rs_s2_tag  [0:RSN-1];
    reg        rs_s2_rdy  [0:RSN-1];
    reg [31:0] rs_s2_val  [0:RSN-1];

    wire [RSN-1:0] rs_valid_vec;
    genvar gv;
    generate
        for (gv = 0; gv < RSN; gv = gv + 1) begin : g_rsv
            assign rs_valid_vec[gv] = rs_valid[gv];
        end
    endgenerate
    wire [5:0] rs_free_cnt = RSN - $countones(rs_valid_vec);
    wire [5:0] rs_used_cnt = $countones(rs_valid_vec);
    wire rs_full1 = (rs_used_cnt >= RS_DEPTH);
    wire rs_full2 = (rs_used_cnt >= RS_DEPTH - 1);

    // MOB
    reg [4:0]  mob_tag     [0:MOBN-1];
    reg        mob_is_store[0:MOBN-1];
    reg        mob_addr_rdy[0:MOBN-1];
    reg [31:0] mob_addr    [0:MOBN-1];
    reg [31:0] mob_data    [0:MOBN-1];
    reg [2:0]  mob_f3      [0:MOBN-1];
    reg [4:0]  mob_head, mob_tail;

    wire        mob_nonempty = (mob_head != mob_tail);
    wire [4:0]  mob_cnt      = mob_tail - mob_head;
    wire        mob_full     = (mob_cnt >= MOB_DEPTH);

    // ==================== CDB ====================
    wire        cdbA_valid, cdbA_has;
    wire [6:0]  cdbA_pdst;
    wire [4:0]  cdbA_tag;
    wire [31:0] cdbA_val;
    wire        cdbB_valid, cdbB_has;
    wire [6:0]  cdbB_pdst;
    wire [4:0]  cdbB_tag;
    wire [31:0] cdbB_val;
    wire        cdb1_valid, cdb1_has;
    wire [6:0]  cdb1_pdst;
    wire [4:0]  cdb1_tag;
    wire [31:0] cdb1_val;

    // ==================== LSU 早期声明（供 issue 选择引用） ====================
    wire [127:0] dc_line_rdata;
    wire         dc_hit, dc_busy, dc_fillwrite, dc_crit_valid, dc_fill_clash;
    wire [31:0]  dc_crit_word;
    wire         dc_req, ic_req;
    wire [31:0]  dc_ar_addr, ic_ar_addr;
    wire         dc_ar_valid, ic_ar_valid;
    wire         dc_last_r, ic_last_r;
    wire         sb_full, sb_clear, sb_clear2, sb_clear3;

    reg        ld_mem_valid;
    reg [4:0]  ld_mem_tag;
    reg [6:0]  ld_mem_pdst;
    reg        ld_mem_has;
    reg [31:0] ld_mem_addr;
    reg [2:0]  ld_mem_f3;
    reg        our_fill;

    reg [31:0] mem_addr_r;
    reg        st_ph2v;

    wire ld_resolved = ld_mem_valid && (dc_hit || (dc_crit_valid && our_fill));
    wire [31:0] dc_word = dc_line_rdata[{mem_addr_r[3:2], 5'b0} +: 32];
    wire [31:0] ld_ext  = (dc_crit_valid && our_fill && !dc_hit)
                          ? load_extend(dc_crit_word, ld_mem_f3, mem_addr_r[1:0])
                          : load_extend(dc_word, ld_mem_f3, mem_addr_r[1:0]);

    // ==================== pop（dispatch）译码与预测复核 ====================
    wire [31:0] iw0 = q_ins[0];
    wire [31:0] iw1 = q_ins[1];
    `DECODE(d0, iw0)
    `DECODE(d1, iw1)

    // slot0 的 ID 级预测
    wire [36:0] prd0 = q_prd[0];
    wire        prd0_hit = q_pv[0] && prd0[36];
    wire [1:0]  prd0_type = prd0[35:34];
    wire [31:0] prd0_target = prd0[33:2];
    wire [1:0]  prd0_bht = prd0[1:0];
    wire p0_pred_taken = d0_jal ? 1'b1 :
                         d0_ret ? (ras_cnt_eff != 4'd0) :
                         d0_branch ? (prd0_hit && prd0_type == BT_BR && prd0_bht[1]) :
                         d0_jalr ? ((prd0_hit && prd0_type == BT_JMP) || q_ift[0]) : 1'b0;
    wire [31:0] p0_pred_target = d0_jal ? (q_pc[0] + d0_imm) :
                                 d0_ret ? ras_top :
                                 d0_branch ? prd0_target :
                                 (prd0_hit && prd0_type == BT_JMP) ? prd0_target :
                                 q_iftg[0];
    wire q0_control = d0_jal || d0_jalr || d0_branch;
    wire p0_mismatch = d0_jal ? (!q_ift[0] || q_iftg[0] != q_pc[0] + d0_imm)
                              : (q_ift[0] != p0_pred_taken);
    // 控制指令：若 IF 未预测对（taken），在 pop 点重定向（仅在实际弹出时生效）
    wire redir0_pre = (q_cnt > 3'd0) && q0_control && p0_mismatch && !flush;
    wire [31:0] redir0_target = p0_pred_taken ? p0_pred_target : (q_pc[0] + 32'd4);
    wire redir0;
    wire eff0_taken  = redir0 ? p0_pred_taken : q_ift[0];
    wire [31:0] eff0_target = redir0 ? p0_pred_target : q_iftg[0];

    // slot1 的 ID 级预测
    wire [36:0] prd1 = q_prd[1];
    wire        prd1_hit = q_pv[1] && prd1[36];
    wire [1:0]  prd1_type = prd1[35:34];
    wire [31:0] prd1_target = prd1[33:2];
    wire [1:0]  prd1_bht = prd1[1:0];
    wire p1_pred_taken = d1_jal ? 1'b1 :
                         d1_ret ? (ras_cnt_eff != 4'd0) :
                         d1_branch ? (prd1_hit && prd1_type == BT_BR && prd1_bht[1]) :
                         d1_jalr ? ((prd1_hit && prd1_type == BT_JMP) || q_ift[1]) : 1'b0;
    wire [31:0] p1_pred_target = d1_jal ? (q_pc[1] + d1_imm) :
                                 d1_ret ? ras_top :
                                 d1_branch ? prd1_target :
                                 (prd1_hit && prd1_type == BT_JMP) ? prd1_target :
                                 q_iftg[1];
    wire q1_control = d1_jal || d1_jalr || d1_branch;
    wire p1_mismatch = d1_jal ? (!q_ift[1] || q_iftg[1] != q_pc[1] + d1_imm)
                              : (q_ift[1] != p1_pred_taken);
    wire redir1_pre = (q_cnt > 3'd1) && q1_control && p1_mismatch && !flush;
    wire [31:0] redir1_target = p1_pred_taken ? p1_pred_target : (q_pc[1] + 32'd4);
    wire redir1;
    wire eff1_taken  = redir1 ? p1_pred_taken : q_ift[1];
    wire [31:0] eff1_target = redir1 ? p1_pred_target : q_iftg[1];

    assign pop_redirect      = redir0 || redir1;
    assign pop_red_target    = redir0 ? redir0_target : redir1_target;
    assign pop_redirect_jal  = redir0 ? d0_jal : d1_jal;
    assign pop_red_pc        = redir0 ? q_pc[0] : q_pc[1];
    assign pop_red_imm       = redir0 ? d0_imm : d1_imm;

    // ==================== 后端资源 / pop 决策 ====================
    wire snap_full = (snap_head[2:0] == snap_tail[2:0]) &&
                     (snap_head[3] != snap_tail[3]);
    wire [6:0] fl_free = fl_tail - fl_head;

    wire dsp0_need_snap = d0_branch || d0_jalr;
    wire dsp1_need_snap = d1_branch || d1_jalr;
    wire [1:0] nmem  = {1'b0, d0_mem} + {1'b0, d1_mem};
    wire [1:0] npdst = {1'b0, d0_has_pdst} + {1'b0, d1_has_pdst};

    wire can0 = (q_cnt > 3'd0) && !flush &&
                !rs_full1 && !rob_full1 &&
                (!d0_mem || !mob_full) &&
                (!dsp0_need_snap || !snap_full) &&
                (!d0_has_pdst || (fl_free >= 7'd1));
    wire can1_pre = ISSUE2 && can0 && (q_cnt > 3'd1) && !redir0_pre && !eff0_taken && !q0_control &&
                !rs_full2 && !rob_full2 &&
                (mob_cnt + nmem <= MOB_DEPTH) &&
                (!dsp1_need_snap || !snap_full) &&
                (fl_free >= {5'b0, npdst});
    assign redir0 = redir0_pre && can0;
    assign redir1 = redir1_pre && can1_pre;
    // redir0：只弹 q0（q1 及以后作废）；redir1：q0/q1 都弹（q1 用纠正后的预测）；
    // 否则按资源弹 1 或 2 条
    assign pop_n = redir0 ? (can0 ? 2'd1 : 2'd0) :
                   (can1_pre ? 2'd2 : (can0 ? 2'd1 : 2'd0));
    wire can1 = (pop_n == 2'd2);
    wire dsp0_en = (pop_n >= 2'd1);
    wire dsp1_en = ISSUE2 && (pop_n == 2'd2);

    // ==================== 重命名（两槽） ====================
    wire [6:0] alloc0 = fl[fl_head[6:0]];
    wire [6:0] alloc1 = fl[fl_head[6:0] + {6'b0, d0_has_pdst}];

    // CDB 旁路匹配（dispatch 用）
    wire [6:0] r0_s1 = RAT[d0_rs1];
    wire [6:0] r0_s2 = RAT[d0_rs2];
    wire       r1_s1_new = d0_has_pdst && (d1_rs1 == d0_rd);
    wire       r1_s2_new = d0_has_pdst && (d1_rs2 == d0_rd);
    wire [6:0] r1_s1 = r1_s1_new ? alloc0 : RAT[d1_rs1];
    wire [6:0] r1_s2 = r1_s2_new ? alloc0 : RAT[d1_rs2];

    function [31:0] pick_val;
        input [6:0] tag;
        input       dummy;
        begin
            if (tag == 6'd0) pick_val = 32'b0;
            else if (cdbA_valid && cdbA_has && cdbA_pdst == tag) pick_val = cdbA_val;
            else if (cdbB_valid && cdbB_has && cdbB_pdst == tag) pick_val = cdbB_val;
            else if (cdb1_valid && cdb1_has && cdb1_pdst == tag) pick_val = cdb1_val;
            else pick_val = prf[tag];
        end
    endfunction
    function pick_rdy;
        input [6:0] tag;
        begin
            pick_rdy = (tag == 6'd0) ||
                       (cdbA_valid && cdbA_has && cdbA_pdst == tag) ||
                       (cdbB_valid && cdbB_has && cdbB_pdst == tag) ||
                       (cdb1_valid && cdb1_has && cdb1_pdst == tag) ||
                       prf_ready[tag];
        end
    endfunction

    wire [6:0] pold0 = RAT[d0_rd];
    wire [6:0] pold1 = (d0_has_pdst && (d1_rd == d0_rd)) ? alloc0 : RAT[d1_rd];

    // RS 空槽选择（两个）
    integer di;
    reg [4:0] rs_alloc0, rs_alloc1;
    always @(*) begin
        rs_alloc0 = 5'd0;
        rs_alloc1 = 5'd0;
        for (di = RSN-1; di >= 0; di = di - 1)
            if (!rs_valid[di]) rs_alloc0 = di[4:0];
        for (di = RSN-1; di >= 0; di = di - 1)
            if (!rs_valid[di] && (di[4:0] != rs_alloc0)) rs_alloc1 = di[4:0];
    end

    // ==================== issue 选择 ====================
    wire        ld_port_free;
    wire        div_done_bcast;
    wire        cdb1_byp_valid = ld_resolved;
    wire [6:0]  cdb1_byp_pdst  = ld_mem_pdst;
    wire        cdb1_byp_has   = ld_mem_has;
    wire [31:0] cdb1_byp_val   = ld_ext;

    wire [RSN-1:0] cand0, cand1, candL;
    generate
        for (gv = 0; gv < RSN; gv = gv + 1) begin : g_cand
            wire mob_head_is_me = mob_nonempty &&
                                  !mob_is_store[mob_head[3:0]] &&
                                  (mob_tag[mob_head[3:0]] == rs_tag[gv]);
            wire s1_ok = rs_s1_rdy[gv] ||
                         (cdb1_byp_valid && cdb1_byp_has && (cdb1_byp_pdst == rs_s1_tag[gv]));
            wire s2_ok = rs_s2_rdy[gv] ||
                         (cdb1_byp_valid && cdb1_byp_has && (cdb1_byp_pdst == rs_s2_tag[gv]));
            wire rdy = rs_valid[gv] && s1_ok && s2_ok;
            assign candL[gv] = rdy && rs_is_load[gv] && mob_head_is_me && ld_port_free &&
                               !(flush && is_young(rs_tag[gv], flush_idx, rob_tail[4:0]));
            assign cand0[gv] = rdy && !rs_is_load[gv] &&
                               (rs_is_div[gv] ? (!div_busy && !div_done_bcast) : !div_done_bcast) &&
                               !(flush && is_young(rs_tag[gv], flush_idx, rob_tail[4:0]));
            assign cand1[gv] = rdy && !rs_is_load[gv] && !rs_is_store[gv] &&
                               !rs_is_branch[gv] && !rs_is_jalr[gv] &&
                               !rs_is_mul[gv] && !rs_is_div[gv] &&
                               !(flush && is_young(rs_tag[gv], flush_idx, rob_tail[4:0]));
        end
    endgenerate

    integer ii;
    reg [4:0] iss0_idx, iss1_idx;
    always @(*) begin
        iss0_idx = 5'd0;
        for (ii = RSN-1; ii >= 0; ii = ii - 1)
            if (cand0[ii]) iss0_idx = ii[4:0];
    end
    wire [RSN-1:0] cand1m = cand1 & ~(iss0_fire ? ({{(RSN-1){1'b0}}, 1'b1} << iss0_idx)
                                                : {RSN{1'b0}});
    always @(*) begin
        iss1_idx = 5'd0;
        for (ii = RSN-1; ii >= 0; ii = ii - 1)
            if (cand1m[ii]) iss1_idx = ii[4:0];
    end
    assign iss0_fire = |cand0;
    wire   iss1_fire = ISSUE2 && |cand1m;
    wire   issL_fire = |candL;

    // port0 字段
    assign iss0_pc         = rs_pc[iss0_idx];
    wire [4:0]  iss0_tag   = rs_tag[iss0_idx];
    wire [31:0] iss0_imm   = rs_imm[iss0_idx];
    wire [3:0]  iss0_aluop = rs_aluop[iss0_idx];
    wire        iss0_srca_pc  = rs_srca_pc[iss0_idx];
    wire        iss0_srcb_imm = rs_srcb_imm[iss0_idx];
    wire [2:0]  iss0_f3    = rs_f3[iss0_idx];
    wire        iss0_is_store = rs_is_store[iss0_idx];
    assign      iss0_is_cbranch = rs_is_branch[iss0_idx];
    assign      iss0_is_jalr    = rs_is_jalr[iss0_idx];
    assign      iss0_is_ret     = rs_is_jalr[iss0_idx] && rs_is_ret_r[iss0_idx];
    wire        iss0_is_mul  = rs_is_mul[iss0_idx];
    wire        iss0_is_div  = rs_is_div[iss0_idx];
    wire        iss0_wb_pc4  = rs_wb_pc4[iss0_idx];
    wire        iss0_pred_taken = rs_pred_taken[iss0_idx];
    wire [31:0] iss0_pred_target = rs_pred_target[iss0_idx];
    assign      iss0_bht     = rs_bht[iss0_idx];
    wire [6:0]  iss0_pdst  = rs_pdst[iss0_idx];
    wire        iss0_has_pdst = rs_has_pdst[iss0_idx];
    wire [4:0]  iss0_mob_ptr = rs_mob_ptr[iss0_idx];
    wire [31:0] iss0_op1   = rs_s1_rdy[iss0_idx] ? rs_s1_val[iss0_idx] :
                             (cdb1_byp_valid && cdb1_byp_has && (cdb1_byp_pdst == rs_s1_tag[iss0_idx]))
                             ? cdb1_byp_val : rs_s1_val[iss0_idx];
    wire [31:0] iss0_op2   = rs_s2_rdy[iss0_idx] ? rs_s2_val[iss0_idx] :
                             (cdb1_byp_valid && cdb1_byp_has && (cdb1_byp_pdst == rs_s2_tag[iss0_idx]))
                             ? cdb1_byp_val : rs_s2_val[iss0_idx];

    // port1 字段
    wire [31:0] iss1_pc    = rs_pc[iss1_idx];
    wire [4:0]  iss1_tag   = rs_tag[iss1_idx];
    wire [31:0] iss1_imm   = rs_imm[iss1_idx];
    wire [3:0]  iss1_aluop = rs_aluop[iss1_idx];
    wire        iss1_srca_pc  = rs_srca_pc[iss1_idx];
    wire        iss1_srcb_imm = rs_srcb_imm[iss1_idx];
    wire        iss1_wb_pc4  = rs_wb_pc4[iss1_idx];
    wire [6:0]  iss1_pdst  = rs_pdst[iss1_idx];
    wire        iss1_has_pdst = rs_has_pdst[iss1_idx];
    wire [31:0] iss1_op1   = rs_s1_rdy[iss1_idx] ? rs_s1_val[iss1_idx] :
                             (cdb1_byp_valid && cdb1_byp_has && (cdb1_byp_pdst == rs_s1_tag[iss1_idx]))
                             ? cdb1_byp_val : rs_s1_val[iss1_idx];
    wire [31:0] iss1_op2   = rs_s2_rdy[iss1_idx] ? rs_s2_val[iss1_idx] :
                             (cdb1_byp_valid && cdb1_byp_has && (cdb1_byp_pdst == rs_s2_tag[iss1_idx]))
                             ? cdb1_byp_val : rs_s2_val[iss1_idx];

    // load 通道字段
    wire [4:0]  issL_idx;
    reg  [4:0]  issL_idx_r;
    always @(*) begin
        issL_idx_r = 5'd0;
        for (ii = RSN-1; ii >= 0; ii = ii - 1)
            if (candL[ii]) issL_idx_r = ii[4:0];
    end
    assign issL_idx = issL_idx_r;
    wire [4:0]  issL_tag  = rs_tag[issL_idx];
    wire [31:0] issL_imm  = rs_imm[issL_idx];
    wire [2:0]  issL_f3   = rs_f3[issL_idx];
    wire [6:0]  issL_pdst = rs_pdst[issL_idx];
    wire        issL_has  = rs_has_pdst[issL_idx];
    wire [31:0] issL_op1  = rs_s1_rdy[issL_idx] ? rs_s1_val[issL_idx] :
                            (cdb1_byp_valid && cdb1_byp_has && (cdb1_byp_pdst == rs_s1_tag[issL_idx]))
                            ? cdb1_byp_val : rs_s1_val[issL_idx];

    // ==================== EX port0（0 拍组合） ====================
    wire [31:0] alu0_a = iss0_srca_pc ? iss0_pc : iss0_op1;
    wire [31:0] alu0_b = iss0_srcb_imm ? iss0_imm : iss0_op2;

    function [31:0] alu_do;
        input [3:0]  op;
        input [31:0] a, b;
        begin
            case (op)
                ALU_ADD:   alu_do = a + b;
                ALU_SUB:   alu_do = a - b;
                ALU_SLL:   alu_do = a << b[4:0];
                ALU_SLT:   alu_do = ($signed(a) < $signed(b)) ? 32'd1 : 32'd0;
                ALU_SLTU:  alu_do = (a < b) ? 32'd1 : 32'd0;
                ALU_XOR:   alu_do = a ^ b;
                ALU_SRL:   alu_do = a >> b[4:0];
                ALU_SRA:   alu_do = $signed(a) >>> b[4:0];
                ALU_OR:    alu_do = a | b;
                ALU_AND:   alu_do = a & b;
                default:   alu_do = b;
            endcase
        end
    endfunction

    wire [31:0] alu0_res = alu_do(iss0_aluop, alu0_a, alu0_b);

    wire signed [63:0] mul_ss  = $signed({iss0_op1[31], iss0_op1}) * $signed({iss0_op2[31], iss0_op2});
    wire [31:0] mul_uu_hi = mul_ss[63:32] + (iss0_op1[31] ? iss0_op2 : 32'b0)
                                          + (iss0_op2[31] ? iss0_op1 : 32'b0);
    wire [31:0] mul_su_hi = mul_uu_hi - (iss0_op1[31] ? iss0_op2 : 32'b0);
    reg [31:0] mul_res;
    always @(*) begin
        case (iss0_f3[1:0])
            2'b00:   mul_res = mul_ss[31:0];
            2'b01:   mul_res = mul_ss[63:32];
            2'b10:   mul_res = mul_su_hi;
            default: mul_res = mul_uu_hi;
        endcase
    end

    wire [31:0] iss0_result = iss0_wb_pc4 ? (iss0_pc + 32'd4) :
                              iss0_is_mul ? mul_res : alu0_res;

    // port0 分支解析
    reg br0_taken_c;
    always @(*) begin
        case (iss0_f3)
            3'b000:  br0_taken_c = (iss0_op1 == iss0_op2);
            3'b001:  br0_taken_c = (iss0_op1 != iss0_op2);
            3'b100:  br0_taken_c = ($signed(iss0_op1) <  $signed(iss0_op2));
            3'b101:  br0_taken_c = ($signed(iss0_op1) >= $signed(iss0_op2));
            3'b110:  br0_taken_c = (iss0_op1 <  iss0_op2);
            3'b111:  br0_taken_c = (iss0_op1 >= iss0_op2);
            default: br0_taken_c = 1'b0;
        endcase
    end
    assign br0_taken = br0_taken_c;
    wire        resolve_taken = iss0_is_jalr || (iss0_is_cbranch && br0_taken_c);
    wire [31:0] actual_target = iss0_is_jalr ? ((iss0_op1 + iss0_imm) & 32'hfffffffe)
                                             : (iss0_pc + iss0_imm);
    assign resolve_target = actual_target;
    wire resolve = iss0_fire && (iss0_is_cbranch || iss0_is_jalr);
    assign flush = resolve &&
                   (resolve_taken != iss0_pred_taken ||
                    (resolve_taken && (actual_target != iss0_pred_target)));
    assign flush_target = resolve_taken ? actual_target : (iss0_pc + 32'd4);
    assign flush_idx    = iss0_tag;

    // ==================== EX port1 ====================
    wire [31:0] alu1_a = iss1_srca_pc ? iss1_pc : iss1_op1;
    wire [31:0] alu1_b = iss1_srcb_imm ? iss1_imm : iss1_op2;
    wire [31:0] alu1_res = alu_do(iss1_aluop, alu1_a, alu1_b);
    wire [31:0] iss1_result = iss1_wb_pc4 ? (iss1_pc + 32'd4) : alu1_res;

    // ==================== 除法 ====================
    wire        div_busy, div_done;
    wire [31:0] div_result;
    reg  [4:0]  div_tag;
    reg  [6:0]  div_pdst;
    reg         div_has;
    reg         div_squash;
    reg         div_spec_r;
    reg  [31:0] div_spec_res_r;
    reg         div_done_r;
    reg  [31:0] div_result_r;

    wire div_zero = (iss0_op2 == 32'b0);
    wire div_ovf  = !iss0_f3[0] && (iss0_op1 == 32'h80000000) && (iss0_op2 == 32'hffffffff);
    wire div_special = div_zero || div_ovf;
    wire [31:0] div_spec_res = div_zero ? (iss0_f3[1] ? iss0_op1 : 32'hffffffff)
                                        : (iss0_f3[1] ? 32'b0 : 32'h80000000);
    wire div_start = iss0_fire && iss0_is_div;

    assign div_done_bcast = div_done_r && !div_squash;

    divider u_div (
        .clk(clock), .reset(reset),
        .start(div_start), .a(iss0_op1), .b(iss0_op2), .op(iss0_f3[1:0]),
        .busy(div_busy), .done(div_done), .result(div_result)
    );

    always @(posedge clock) begin
        if (reset) begin
            div_squash <= 1'b0;
            div_done_r <= 1'b0;
        end else begin
            if (div_start) begin
                div_tag        <= iss0_tag;
                div_pdst       <= iss0_pdst;
                div_has        <= iss0_has_pdst;
                div_spec_r     <= div_special;
                div_spec_res_r <= div_spec_res;
                div_squash     <= 1'b0;
            end
            if (div_done) begin
                if (!div_squash) begin
                    div_done_r   <= 1'b1;
                    div_result_r <= div_spec_r ? div_spec_res_r : div_result;
                end
                div_squash <= 1'b0;
            end else if (div_done_r) begin
                div_done_r <= 1'b0;
            end
            if (flush && (div_busy || div_done_r) &&
                is_young(div_tag, flush_idx, rob_tail[4:0])) begin
                div_squash <= 1'b1;
                div_done_r <= 1'b0;
            end
        end
    end
    wire div_cdb_squash = div_done_bcast && flush &&
                          is_young(div_tag, flush_idx, rob_tail[4:0]);

    // ==================== CDBA / CDBB ====================
    wire iss0_uses_cdb = !iss0_is_store && !iss0_is_cbranch && !iss0_is_div;
    assign cdbA_valid = (iss0_fire && iss0_uses_cdb) || (div_done_bcast && !div_cdb_squash);
    assign cdbA_tag   = div_done_bcast ? div_tag  : iss0_tag;
    assign cdbA_pdst  = div_done_bcast ? div_pdst : iss0_pdst;
    assign cdbA_has   = div_done_bcast ? div_has  : iss0_has_pdst;
    assign cdbA_val   = div_done_bcast ? div_result_r : iss0_result;

    assign cdbB_valid = iss1_fire;
    assign cdbB_tag   = iss1_tag;
    assign cdbB_pdst  = iss1_pdst;
    assign cdbB_has   = iss1_has_pdst;
    assign cdbB_val   = iss1_result;

    // ==================== LSU / d-cache 接口 ====================
    wire ld_kill     = flush && ld_mem_valid &&
                       is_young(ld_mem_tag, flush_idx, rob_tail[4:0]);

    // store 提交两级流水
    wire [3:0] mh  = mob_head[3:0];
    wire [3:0] mh1 = mob_head[3:0] + 4'd1;
    wire head_store_rdy = rob_nonempty && rob_done[rh] && rob_is_store[rh] &&
                          mob_nonempty && mob_is_store[mh] &&
                          (mob_tag[mh] == rh) && mob_addr_rdy[mh];
    wire next_store_rdy = (rob_cnt >= 2) && rob_done[rh1] && rob_is_store[rh1] &&
                          (mh1 != mob_tail) && mob_is_store[mh1] &&
                          (mob_tag[mh1] == rh1) && mob_addr_rdy[mh1];
    wire st_go  = st_ph2v && !sb_full && !dc_fill_clash && !dc_fillwrite;
    wire st_go1 = !dc_fillwrite && (!ld_mem_valid || ld_resolved) &&
                  ((!st_ph2v && head_store_rdy) || (st_go && next_store_rdy));
    wire dc_store_wr = st_go && dc_hit;
    wire sb_push     = st_go;
    wire st_commit_done = st_go;

    wire [2:0]  st_f3   = mob_f3[mh];
    wire [31:0] st_data = mob_data[mh];
    wire [31:0] st_addr = mem_addr_r;
    wire [31:0] st_w32  = (st_f3 == 3'b000) ? {4{st_data[7:0]}} :
                          (st_f3 == 3'b001) ? {2{st_data[15:0]}} : st_data;
    wire [3:0]  st_strb = (st_f3 == 3'b000) ? (4'b0001 << st_addr[1:0]) :
                          (st_f3 == 3'b001) ? (4'b0011 << st_addr[1:0]) : 4'b1111;

    wire [31:0] ld_issue_addr = issL_op1 + issL_imm;
    wire [31:0] dc_ex_addr = st_go1 ? (st_ph2v ? mob_addr[mh1] : mob_addr[mh]) :
                             issL_fire ? ld_issue_addr :
                             mem_addr_r;

    wire mem_hold = (ld_mem_valid && !ld_resolved) || (st_ph2v && !st_go);

    assign ld_port_free = (!ld_mem_valid || ld_resolved) && !st_ph2v && !st_go1 &&
                          !dc_fillwrite;

    wire dc_miss = ld_mem_valid && !ld_kill && !dc_hit && !dc_crit_valid;
    wire crit_consume = dc_crit_valid;

    assign cdb1_valid = ld_resolved && !ld_kill;
    assign cdb1_tag   = ld_mem_tag;
    assign cdb1_pdst  = ld_mem_pdst;
    assign cdb1_has   = ld_mem_has;
    assign cdb1_val   = ld_ext;

    always @(posedge clock) begin
        if (reset) begin
            mem_addr_r <= 32'b0;
        end else if (!mem_hold) begin
            mem_addr_r <= dc_ex_addr;
        end
    end

    always @(posedge clock) begin
        if (reset) begin
            st_ph2v <= 1'b0;
        end else begin
            if (st_go1)      st_ph2v <= 1'b1;
            else if (st_go)  st_ph2v <= 1'b0;
        end
    end

    always @(posedge clock) begin
        if (reset) begin
            ld_mem_valid <= 1'b0;
            our_fill     <= 1'b0;
        end else begin
            if (ld_kill || ld_resolved) begin
                ld_mem_valid <= 1'b0;
            end
            if (ld_mem_valid && dc_miss && !dc_busy) our_fill <= 1'b1;
            if (crit_consume) our_fill <= 1'b0;
            if (issL_fire) begin
                ld_mem_valid <= 1'b1;
                ld_mem_tag   <= issL_tag;
                ld_mem_pdst  <= issL_pdst;
                ld_mem_has   <= issL_has;
                ld_mem_addr  <= ld_issue_addr;
                ld_mem_f3    <= issL_f3;
                our_fill     <= 1'b0;
            end
        end
    end

    // ==================== 提交（每拍至多 2 条非 store；store 走 st 流水） ====================
    wire cmt0_valid = rob_nonempty && rob_done[rh] && !rob_is_store[rh];
    wire cmt1_valid = (rob_cnt >= 2) && rob_done[rh1] && !rob_is_store[rh1];
    assign commit0 = cmt0_valid;
    assign commit1 = ISSUE2 && cmt0_valid && cmt1_valid;
    wire [1:0] head_adv = commit1 ? 2'd2 :
                          (commit0 || st_commit_done) ? 2'd1 : 2'd0;

    // ==================== 顺序块 ====================
    // ---- RS ----
    integer ri;
    always @(posedge clock) begin
        if (reset) begin
            for (ri = 0; ri < RSN; ri = ri + 1) rs_valid[ri] <= 1'b0;
        end else begin
            for (ri = 0; ri < RSN; ri = ri + 1) begin
                // CDB 唤醒
                if (rs_valid[ri]) begin
                    if (!rs_s1_rdy[ri]) begin
                        if (cdbA_valid && cdbA_has && (cdbA_pdst == rs_s1_tag[ri])) begin
                            rs_s1_val[ri] <= cdbA_val; rs_s1_rdy[ri] <= 1'b1;
                        end else if (cdbB_valid && cdbB_has && (cdbB_pdst == rs_s1_tag[ri])) begin
                            rs_s1_val[ri] <= cdbB_val; rs_s1_rdy[ri] <= 1'b1;
                        end else if (cdb1_valid && cdb1_has && (cdb1_pdst == rs_s1_tag[ri])) begin
                            rs_s1_val[ri] <= cdb1_val; rs_s1_rdy[ri] <= 1'b1;
                        end
                    end
                    if (!rs_s2_rdy[ri]) begin
                        if (cdbA_valid && cdbA_has && (cdbA_pdst == rs_s2_tag[ri])) begin
                            rs_s2_val[ri] <= cdbA_val; rs_s2_rdy[ri] <= 1'b1;
                        end else if (cdbB_valid && cdbB_has && (cdbB_pdst == rs_s2_tag[ri])) begin
                            rs_s2_val[ri] <= cdbB_val; rs_s2_rdy[ri] <= 1'b1;
                        end else if (cdb1_valid && cdb1_has && (cdb1_pdst == rs_s2_tag[ri])) begin
                            rs_s2_val[ri] <= cdb1_val; rs_s2_rdy[ri] <= 1'b1;
                        end
                    end
                end
                // issue 出队
                if ((iss0_fire && (iss0_idx == ri[4:0])) ||
                    (iss1_fire && (iss1_idx == ri[4:0])) ||
                    (issL_fire && (issL_idx == ri[4:0])))
                    rs_valid[ri] <= 1'b0;
                // flush 杀年轻项
                if (flush && rs_valid[ri] &&
                    is_young(rs_tag[ri], flush_idx, rob_tail[4:0]))
                    rs_valid[ri] <= 1'b0;
                // dispatch 入队
                if (dsp0_en && (rs_alloc0 == ri[4:0])) begin
                    rs_valid[ri]    <= 1'b1;
                    rs_tag[ri]      <= rob_tail[4:0];
                    rs_pc[ri]       <= q_pc[0];
                    rs_imm[ri]      <= d0_imm;
                    rs_aluop[ri]    <= aluop_of(iw0);
                    rs_srca_pc[ri]  <= d0_srca_pc;
                    rs_srcb_imm[ri] <= d0_srcb_imm;
                    rs_f3[ri]       <= d0_f3;
                    rs_is_load[ri]  <= d0_load;
                    rs_is_store[ri] <= d0_store;
                    rs_is_branch[ri]<= d0_branch;
                    rs_is_jalr[ri]  <= d0_jalr;
                    rs_is_ret_r[ri] <= d0_ret;
                    rs_is_mul[ri]   <= d0_mext && !d0_f3[2];
                    rs_is_div[ri]   <= d0_mext &&  d0_f3[2];
                    rs_wb_pc4[ri]   <= d0_jal || d0_jalr;
                    rs_pred_taken[ri]  <= eff0_taken;
                    rs_pred_target[ri] <= eff0_target;
                    rs_bht[ri]      <= prd0_bht;
                    rs_pdst[ri]     <= alloc0;
                    rs_has_pdst[ri] <= d0_has_pdst;
                    rs_mob_ptr[ri]  <= mob_tail;
                    rs_s1_tag[ri]   <= r0_s1;
                    rs_s1_rdy[ri]   <= !d0_s1_need || pick_rdy(r0_s1);
                    rs_s1_val[ri]   <= pick_val(r0_s1, 1'b0);
                    rs_s2_tag[ri]   <= r0_s2;
                    rs_s2_rdy[ri]   <= !d0_s2_need || pick_rdy(r0_s2);
                    rs_s2_val[ri]   <= pick_val(r0_s2, 1'b0);
                end
                if (dsp1_en && (rs_alloc1 == ri[4:0])) begin
                    rs_valid[ri]    <= 1'b1;
                    rs_tag[ri]      <= rob_tail[4:0] + 5'd1;
                    rs_pc[ri]       <= q_pc[1];
                    rs_imm[ri]      <= d1_imm;
                    rs_aluop[ri]    <= aluop_of(iw1);
                    rs_srca_pc[ri]  <= d1_srca_pc;
                    rs_srcb_imm[ri] <= d1_srcb_imm;
                    rs_f3[ri]       <= d1_f3;
                    rs_is_load[ri]  <= d1_load;
                    rs_is_store[ri] <= d1_store;
                    rs_is_branch[ri]<= d1_branch;
                    rs_is_jalr[ri]  <= d1_jalr;
                    rs_is_ret_r[ri] <= d1_ret;
                    rs_is_mul[ri]   <= d1_mext && !d1_f3[2];
                    rs_is_div[ri]   <= d1_mext &&  d1_f3[2];
                    rs_wb_pc4[ri]   <= d1_jal || d1_jalr;
                    rs_pred_taken[ri]  <= eff1_taken;
                    rs_pred_target[ri] <= eff1_target;
                    rs_bht[ri]      <= prd1_bht;
                    rs_pdst[ri]     <= alloc1;
                    rs_has_pdst[ri] <= d1_has_pdst;
                    rs_mob_ptr[ri]  <= mob_tail + {4'b0, d0_mem};
                    rs_s1_tag[ri]   <= r1_s1;
                    rs_s1_rdy[ri]   <= !d1_s1_need || (!r1_s1_new && pick_rdy(r1_s1));
                    rs_s1_val[ri]   <= pick_val(r1_s1, 1'b0);
                    rs_s2_tag[ri]   <= r1_s2;
                    rs_s2_rdy[ri]   <= !d1_s2_need || (!r1_s2_new && pick_rdy(r1_s2));
                    rs_s2_val[ri]   <= pick_val(r1_s2, 1'b0);
                end
            end
        end
    end

    // ---- ROB ----
    always @(posedge clock) begin
        if (reset) begin
            rob_head <= 6'd0;
            rob_tail <= 6'd0;
        end else begin
            if (cdbA_valid) rob_done[cdbA_tag] <= 1'b1;
            if (cdbB_valid) rob_done[cdbB_tag] <= 1'b1;
            if (cdb1_valid) rob_done[cdb1_tag] <= 1'b1;
            if (iss0_fire && iss0_is_cbranch) rob_done[iss0_tag] <= 1'b1;
            if (iss0_fire && iss0_is_store)   rob_done[iss0_tag] <= 1'b1;
            if (flush) begin
                rob_tail <= rob_next_tail[flush_idx[4:0]];
            end else begin
                if (dsp0_en) begin
                    rob_done[rob_tail[4:0]]       <= 1'b0;
                    rob_pc[rob_tail[4:0]]         <= q_pc[0];
                    rob_is_store[rob_tail[4:0]]   <= d0_store;
                    rob_is_call[rob_tail[4:0]]    <= d0_call;
                    rob_is_ret[rob_tail[4:0]]     <= d0_ret;
                    rob_pred_taken[rob_tail[4:0]] <= eff0_taken;
                    rob_rd[rob_tail[4:0]]         <= d0_rd;
                    rob_has_pdst[rob_tail[4:0]]   <= d0_has_pdst;
                    rob_pdst[rob_tail[4:0]]       <= alloc0;
                    rob_pold[rob_tail[4:0]]       <= pold0;
                    rob_fl_head[rob_tail[4:0]]    <= fl_head + {6'b0, d0_has_pdst};
                    rob_mob_tail[rob_tail[4:0]]   <= mob_tail + {4'b0, d0_mem};
                    rob_next_tail[rob_tail[4:0]]  <= rob_tail + 6'd1;
                    rob_snap_idx[rob_tail[4:0]]   <= snap_tail;
                    rob_snap_val[rob_tail[4:0]]   <= dsp0_need_snap;
                end
                if (dsp1_en) begin
                    rob_done[rob_tail[4:0]+5'd1]       <= 1'b0;
                    rob_pc[rob_tail[4:0]+5'd1]         <= q_pc[1];
                    rob_is_store[rob_tail[4:0]+5'd1]   <= d1_store;
                    rob_is_call[rob_tail[4:0]+5'd1]    <= d1_call;
                    rob_is_ret[rob_tail[4:0]+5'd1]     <= d1_ret;
                    rob_pred_taken[rob_tail[4:0]+5'd1] <= eff1_taken;
                    rob_rd[rob_tail[4:0]+5'd1]         <= d1_rd;
                    rob_has_pdst[rob_tail[4:0]+5'd1]   <= d1_has_pdst;
                    rob_pdst[rob_tail[4:0]+5'd1]       <= alloc1;
                    rob_pold[rob_tail[4:0]+5'd1]       <= pold1;
                    rob_fl_head[rob_tail[4:0]+5'd1]    <= fl_head + {6'b0, d0_has_pdst} + {6'b0, d1_has_pdst};
                    rob_mob_tail[rob_tail[4:0]+5'd1]   <= mob_tail + {4'b0, d0_mem} + {4'b0, d1_mem};
                    rob_next_tail[rob_tail[4:0]+5'd1]  <= rob_tail + 6'd2;
                    rob_snap_idx[rob_tail[4:0]+5'd1]   <= snap_tail;
                    rob_snap_val[rob_tail[4:0]+5'd1]   <= dsp1_need_snap;
                end
                rob_tail <= rob_tail + {4'b0, pop_n};
            end
            rob_head <= rob_head + {4'b0, head_adv};
        end
    end

    wire dispatch_en_snap_print = (dsp0_en && dsp0_need_snap) || (dsp1_en && dsp1_need_snap);
    wire [31:0] pc_id_print = dsp1_en ? q_pc[1] : q_pc[0];
    // ---- RAT / 快照 ----
    integer ai;
    always @(posedge clock) begin
        if (reset) begin
            for (ai = 0; ai < 32; ai = ai + 1) RAT[ai] <= ai[6:0];
            snap_head <= 4'd0;
            snap_tail <= 4'd0;
        end else if (flush) begin
            for (ai = 0; ai < 32; ai = ai + 1)
                RAT[ai] <= snap_rat[rob_snap_idx[flush_idx[4:0]][2:0]][ai];
            snap_tail <= rob_snap_idx[flush_idx[4:0]] + 4'd1;
            snap_head <= snap_head + {3'b0, (commit0 && rob_snap_val[rh])} +
                                     {3'b0, (commit1 && rob_snap_val[rh1])};
        end else begin
            snap_head <= snap_head + {3'b0, (commit0 && rob_snap_val[rh])} +
                                     {3'b0, (commit1 && rob_snap_val[rh1])};
            if (dsp0_en && dsp0_need_snap) begin
                for (ai = 0; ai < 32; ai = ai + 1)
                    snap_rat[snap_tail[2:0]][ai] <=
                        (d0_has_pdst && (d0_rd == ai[4:0])) ? alloc0 : RAT[ai];
                snap_tail <= snap_tail + 4'd1;
            end else if (dsp1_en && dsp1_need_snap) begin
                for (ai = 0; ai < 32; ai = ai + 1)
                    snap_rat[snap_tail[2:0]][ai] <=
                        (d1_has_pdst && (d1_rd == ai[4:0])) ? alloc1 :
                        (d0_has_pdst && (d0_rd == ai[4:0])) ? alloc0 : RAT[ai];
                snap_tail <= snap_tail + 4'd1;
            end
            if (dsp0_en && d0_has_pdst) RAT[d0_rd] <= alloc0;
            if (dsp1_en && d1_has_pdst) RAT[d1_rd] <= alloc1;
        end
    end

    // ---- 空闲列表 ----
    integer fi2;
    always @(posedge clock) begin
        if (reset) begin
            fl_head <= 8'd0;
            fl_tail <= PRF_SIZE - 32;
            for (fi2 = 0; fi2 < PRF_SIZE - 32; fi2 = fi2 + 1) fl[fi2] = 7'd32 + fi2[6:0];
        end else begin
            if (commit0 && rob_has_pdst[rh]) begin
                fl[fl_tail[6:0]] <= rob_pold[rh];
                fl_tail <= fl_tail + 7'd1 + {6'b0, (commit1 && rob_has_pdst[rh1])};
            end else if (commit1 && rob_has_pdst[rh1]) begin
                fl[fl_tail[6:0]] <= rob_pold[rh1];
                fl_tail <= fl_tail + 7'd1;
            end
            if (commit1 && rob_has_pdst[rh] && rob_has_pdst[rh1])
                fl[fl_tail[6:0] + 7'd1] <= rob_pold[rh1];
            if (flush) fl_head <= rob_fl_head[flush_idx[4:0]];
            else fl_head <= fl_head + {5'b0, (dsp0_en && d0_has_pdst)} +
                                      {5'b0, (dsp1_en && d1_has_pdst)};
        end
    end

    // ---- PRF ----
    always @(posedge clock) begin
        if (reset) begin
            prf_ready <= {128{1'b1}};
        end else begin
            if (cdbA_valid && cdbA_has) begin
                prf[cdbA_pdst] <= cdbA_val;
                prf_ready[cdbA_pdst] <= 1'b1;
            end
            if (cdbB_valid && cdbB_has) begin
                prf[cdbB_pdst] <= cdbB_val;
                prf_ready[cdbB_pdst] <= 1'b1;
            end
            if (cdb1_valid && cdb1_has) begin
                prf[cdb1_pdst] <= cdb1_val;
                prf_ready[cdb1_pdst] <= 1'b1;
            end
            if (dsp0_en && d0_has_pdst) prf_ready[alloc0] <= 1'b0;
            if (dsp1_en && d1_has_pdst) prf_ready[alloc1] <= 1'b0;
        end
    end

    // ---- MOB ----
    wire [4:0] mob_snap = rob_mob_tail[flush_idx[4:0]];
    wire [4:0] mob_dh   = mob_snap - mob_head;
    wire [4:0] mob_dt   = mob_tail - mob_head;
    wire       mob_snap_behind = (mob_dh > mob_dt);

    always @(posedge clock) begin
        if (reset) begin
            mob_head <= 5'd0;
            mob_tail <= 5'd0;
        end else begin
            if (iss0_fire && iss0_is_store) begin
                mob_addr[iss0_mob_ptr[3:0]]     <= iss0_op1 + iss0_imm;
                mob_data[iss0_mob_ptr[3:0]]     <= iss0_op2;
                mob_f3[iss0_mob_ptr[3:0]]       <= iss0_f3;
                mob_addr_rdy[iss0_mob_ptr[3:0]] <= 1'b1;
            end
            if (issL_fire)           mob_head <= mob_head + 5'd1;
            else if (st_commit_done) mob_head <= mob_head + 5'd1;
            if (flush) begin
                mob_tail <= mob_snap_behind ? mob_head : mob_snap;
            end else begin
                if (dsp0_en && d0_mem) begin
                    mob_tag[mob_tail[3:0]]      <= rob_tail[4:0];
                    mob_is_store[mob_tail[3:0]] <= d0_store;
                    mob_addr_rdy[mob_tail[3:0]] <= 1'b0;
                end
                if (dsp1_en && d1_mem) begin
                    mob_tag[mob_tail[3:0] + {3'b0, d0_mem}]      <= rob_tail[4:0] + 5'd1;
                    mob_is_store[mob_tail[3:0] + {3'b0, d0_mem}] <= d1_store;
                    mob_addr_rdy[mob_tail[3:0] + {3'b0, d0_mem}] <= 1'b0;
                end
                mob_tail <= mob_tail + {3'b0, (dsp0_en && d0_mem)} + {3'b0, (dsp1_en && d1_mem)};
            end
        end
    end

    // ==================== RAS 更新（提交期） ====================
    wire [3:0] ras_cnt_n = ras_cnt + {3'b0, c0_push} + {3'b0, c1_push}
                                  - {3'b0, c0_pop} - {3'b0, c1_pop};
    wire [3:0] ras_pos1 = ras_cnt + {3'b0, c0_push} - {3'b0, c0_pop};
    always @(posedge clock) begin
        if (reset) begin
            ras_cnt <= 4'd0;
        end else begin
            if (c0_push && (ras_cnt != 4'd8))
                ras[ras_cnt[2:0]] <= rob_pc[rh] + 32'd4;
            if (c1_push && (ras_pos1 != 4'd8))
                ras[ras_pos1[2:0]] <= rob_pc[rh1] + 32'd4;
            ras_cnt <= (ras_cnt_n > 4'd8) ? 4'd8 : ras_cnt_n;
        end
    end

    // ==================== 前端：pc_f / pend / 队列 ====================
    // pop 点遇到预测 taken 的控制指令：后续顺序流作废，视同重定向
    wire pop_taken_redir = (dsp0_en && !dsp1_en && q0_control && eff0_taken) ||
                           (dsp1_en && q1_control && eff1_taken);
    wire q_clear = flush || pop_redirect || pop_taken_redir;

    integer qi;
    always @(posedge clock) begin
        if (reset) begin
            pc_f    <= 32'b0;
            pend_v  <= 1'b0;
            q_cnt   <= 3'd0;
        end else begin
            // ---- pc_f ----
            if (flush)                 pc_f <= flush_target;
            else if (pop_redirect)     pc_f <= pop_red_target;
            else if (q0_control && eff0_taken && dsp0_en && !dsp1_en)
                                       pc_f <= eff0_target;
            else if (dsp1_en && q1_control && eff1_taken)
                                       pc_f <= eff1_target;
            else if (can_issue_read)   pc_f <= pc_f_next;

            // ---- pend ----
            if (q_clear) begin
                pend_v <= 1'b0;
            end else begin
                if (can_issue_read) begin
                    pend_v     <= 1'b1;
                    pend_pc    <= pc_f;
                    pend_m2    <= (push_m == 2'd2);
                    pend_ift1  <= f1_fat_taken;
                    pend_iftg1 <= f1_fat_target;
                    pend_ift2  <= f2_fat_taken;
                    pend_iftg2 <= f2_fat_target;
                end else if (arrive) begin
                    pend_v <= 1'b0;
                end
            end

            // ---- 队列：弹出移位 + 到达入队 ----
            if (q_clear) begin
                q_cnt <= 3'd0;
            end else begin
                // 弹出移位
                for (qi = 0; qi < QN; qi = qi + 1) begin
                    if (qi >= pop_n) begin
                        q_pc[qi-pop_n]   <= q_pc[qi];
                        q_ins[qi-pop_n]  <= q_ins[qi];
                        q_ift[qi-pop_n]  <= q_ift[qi];
                        q_iftg[qi-pop_n] <= q_iftg[qi];
                        q_prd[qi-pop_n]  <= q_prd[qi];
                        q_pv[qi-pop_n]   <= q_pv[qi];
                    end
                end
                // 到达入队（追加在弹出后的尾部）
                if (arrive) begin
                    q_pc[q_cnt-pop_n]   <= pend_pc;
                    q_ins[q_cnt-pop_n]  <= ic_instr;
                    q_ift[q_cnt-pop_n]  <= pend_ift1;
                    q_iftg[q_cnt-pop_n] <= pend_iftg1;
                    q_prd[q_cnt-pop_n]  <= f1_prd;
                    q_pv[q_cnt-pop_n]   <= f1_pv;
                    if (arrive2) begin
                        q_pc[q_cnt-pop_n+3'd1]   <= pend_pc + 32'd4;
                        q_ins[q_cnt-pop_n+3'd1]  <= ic_instr2;
                        q_ift[q_cnt-pop_n+3'd1]  <= pend_ift2;
                        q_iftg[q_cnt-pop_n+3'd1] <= pend_iftg2;
                        q_prd[q_cnt-pop_n+3'd1]  <= f2_prd;
                        q_pv[q_cnt-pop_n+3'd1]   <= f2_pv;
                    end
                end
                q_cnt <= q_cnt - {1'b0, pop_n} + {2'b0, arrive} + {2'b0, arrive2};
            end
        end
    end

    // ==================== icache / dcache / storebuf / AXI ====================
    icache #(.LINES(ICACHE_LINES), .WAYS(ICACHE_WAYS)) u_icache (
        .clk(clock), .reset(reset),
        .pc_f(read_addr), .pc_id(pend_v ? pend_pc : read_addr),
        .front_stall(icache_hold),
        .instr(ic_instr), .instr2(ic_instr2), .hit(ic_hit), .hit2(ic_hit2),
        .miss(ic_miss), .busy(ic_busy),
        .req(ic_req), .grant(ic_grant),
        .ar_addr(ic_ar_addr), .ar_valid(ic_ar_valid), .ar_ready(arready),
        .rdata(rdata), .rvalid(rvalid), .last_r(ic_last_r)
    );

    dcache #(.LINES(DCACHE_LINES), .WAYS(DCACHE_WAYS)) u_dcache (
        .clk(clock), .reset(reset),
        .ex_addr(dc_ex_addr), .mem_addr(mem_addr_r), .hold(mem_hold),
        .store_wr(dc_store_wr),
        .store_wdata({4{st_w32}}),
        .store_wmask({{12'b0}, st_strb} << st_addr[3:0]),
        .hit(dc_hit), .line_rdata(dc_line_rdata),
        .miss(dc_miss), .busy(dc_busy), .fillwrite(dc_fillwrite), .fill_clash(dc_fill_clash),
        .crit_valid(dc_crit_valid), .crit_word(dc_crit_word), .crit_consume(crit_consume),
        .sb_clear(sb_clear), .sb_clear2(sb_clear2), .sb_clear3(sb_clear3),
        .req(dc_req), .grant(dc_grant),
        .ar_addr(dc_ar_addr), .ar_valid(dc_ar_valid), .ar_ready(arready),
        .rdata(rdata), .rvalid(rvalid), .last_r(dc_last_r)
    );

    storebuf #(.DEPTH(STORE_BUF_DEPTH)) u_storebuf (
        .clk(clock), .reset(reset),
        .push(sb_push), .push_addr({st_addr[31:2], 2'b00}),
        .push_data(st_w32), .push_strb(st_strb),
        .full(sb_full),
        .chk_line(mem_addr_r[31:4]), .chk_clear(sb_clear),
        .chk_line2(mem_addr_r[31:4] + 28'd1), .chk_clear2(sb_clear2),
        .chk_line3(mem_addr_r[31:4] + 28'd2), .chk_clear3(sb_clear3),
        .awaddr(awaddr), .awvalid(awvalid), .awready(awready),
        .wdata(wdata), .wstrb(wstrb), .wvalid(wvalid), .wready(wready),
        .bvalid(bvalid)
    );

    // ==================== AXI 读仲裁 ====================
    reg [1:0] ar_owner;
    wire dc_grant, ic_grant;
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
    assign dc_grant = (ar_owner == 2'd1);
    assign ic_grant = (ar_owner == 2'd2);

    assign araddr  = dc_grant ? dc_ar_addr : ic_ar_addr;
    assign arvalid = dc_grant ? dc_ar_valid : (ic_grant ? ic_ar_valid : 1'b0);
    assign rready  = 1'b1;
    assign bready  = 1'b1;

`ifdef OOO_DEBUG
    integer c_cycles, c_retire, c_flush;
    initial begin c_cycles=0;c_retire=0;c_flush=0; end
    always @(posedge clock) if (!reset) begin
        c_cycles <= c_cycles + 1;
        if (commit0 || st_commit_done) c_retire <= c_retire + 1 + (commit1 ? 1 : 0);
        if (flush) begin
            $display("[RSTR] cyc=%0d snapidx=%0d snap_a0=%0d", c_cycles, rob_snap_idx[flush_idx[4:0]], snap_rat[rob_snap_idx[flush_idx[4:0]][2:0]][10]);
            c_flush <= c_flush + 1;
            $display("[FLUSH] cyc=%0d pc=%h taken=%d target=%h pt=%d ptgt=%h head=%0d tail=%0d fidx=%0d ntail=%0d fpc=%h", c_cycles, iss0_pc, resolve_taken, flush_target, iss0_pred_taken, iss0_pred_target, rob_head, rob_tail, flush_idx, rob_next_tail[flush_idx[4:0]], rob_pc[flush_idx[4:0]]);
        end
        if (commit0 && rob_has_pdst[rh])
            $display("[WB] pc=%h rd=%d val=%h", rob_pc[rh], rob_rd[rh], prf[rob_pdst[rh]]);
        if (commit1 && rob_has_pdst[rh1])
            $display("[WB] pc=%h rd=%d val=%h", rob_pc[rh1], rob_rd[rh1], prf[rob_pdst[rh1]]);
        if (commit0 || st_commit_done) $display("[CMT] pc=%h", rob_pc[rh]);
        if (commit1) $display("[CMT] pc=%h", rob_pc[rh1]);
        if (awvalid && awready)
            $display("[ST] addr=%h data=%h strb=%b", awaddr, wdata, wstrb);
        if (awvalid && awready && awaddr == 32'h80000000)
            $display("[PERF] cycles=%0d retire=%0d flush=%0d", c_cycles, c_retire, c_flush);
        if (can_issue_read) $display("[RD] cyc=%0d pc=%h m=%0d", c_cycles, pc_f, push_m);
        if (arrive) $display("[ARR] cyc=%0d pc=%h m2=%d ins=%h", c_cycles, pend_pc, pend_m2, ic_instr);
        if (dsp0_en) $display("[POP] cyc=%0d pc=%h ins=%h n=%0d tail=%0d", c_cycles, q_pc[0], iw0, pop_n, rob_tail);
        if (c_cycles >= 1055 && c_cycles <= 1066) begin
            $display("[R10] cyc=%0d rat10=%0d dsp0=%d dsp1=%d d0rd=%0d d1rd=%0d a0=%0d a1=%0d flh=%0d", c_cycles, RAT[10], dsp0_en, dsp1_en, d0_rd, d1_rd, alloc0, alloc1, fl_head);
        end
        if (dispatch_en_snap_print) $display("[SNW] cyc=%0d slot=%0d a0=%0d", c_cycles, snap_tail, RAT[10]);
        if ((dsp0_en && d0_has_pdst && alloc0 == 6'd10) || (dsp1_en && d1_has_pdst && alloc1 == 6'd10))
            $display("[A10] cyc=%0d pc=%h", c_cycles, pc_id_print);
        if (commit0 && rob_pold[rh] == 6'd10) $display("[F10] cyc=%0d pc=%h", c_cycles, rob_pc[rh]);
        if (commit1 && rob_pold[rh1] == 6'd10) $display("[F10] cyc=%0d pc=%h", c_cycles, rob_pc[rh1]);
        if ((dsp0_en && q_pc[0] == 32'h4c) || (dsp1_en && q_pc[1] == 32'h4c))
            $display("[XOR] cyc=%0d rat10=%0d rdy=%d", c_cycles, RAT[10], prf_ready[RAT[10]]);
        if (dsp1_en) $display("[POP1] cyc=%0d pc=%h ins=%h", c_cycles, q_pc[1], iw1);
        if (pop_redirect) $display("[PRED] cyc=%0d target=%h", c_cycles, pop_red_target);
        if (iss0_fire && iss0_is_cbranch) $display("[BRI] cyc=%0d pc=%h op1=%h op2=%h taken=%d predt=%d", c_cycles, iss0_pc, iss0_op1, iss0_op2, resolve_taken, iss0_pred_taken);
        if (iss1_fire) $display("[IS1] cyc=%0d pc=%h", c_cycles, iss1_pc);
        if (cdbA_valid) $display("[CA] cyc=%0d tag=%0d pdst=%0d val=%h", c_cycles, cdbA_tag, cdbA_pdst, cdbA_val);
        if (cdbB_valid) $display("[CB] cyc=%0d tag=%0d pdst=%0d val=%h", c_cycles, cdbB_tag, cdbB_pdst, cdbB_val);
        if (c_cycles >= 70855 && c_cycles <= 70920)
            $display("[Q] cyc=%0d cnt=%0d q0=%h q1=%h q2=%h q3=%h pend=%d pc=%h m=%0d iss=%d arr=%d a2=%d popn=%0d",
                c_cycles, q_cnt, q_pc[0], q_pc[1], q_pc[2], q_pc[3], pend_v, pend_pc, push_m, can_issue_read, arrive, arrive2, pop_n);
        if (issL_fire) $display("[LDI] cyc=%0d pc=%h addr=%h", c_cycles, rs_pc[issL_idx], ld_issue_addr);
        if (cdb1_valid) $display("[LD1] cyc=%0d tag=%0d pdst=%0d val=%h", c_cycles, cdb1_tag, cdb1_pdst, cdb1_val);
        if (c_cycles >= 337 && c_cycles <= 340) begin
            for (ri = 0; ri < RSN; ri = ri + 1)
                if (rs_valid[ri] && rs_tag[ri] == 5'd14)
                    $display("[E14] cyc=%0d slot=%0d pc=%h ld=%d st=%d br=%d s1r=%d s2r=%d", c_cycles, ri, rs_pc[ri], rs_is_load[ri], rs_is_store[ri], rs_is_branch[ri], rs_s1_rdy[ri], rs_s2_rdy[ri]);
            $display("[ALLOC] cyc=%0d a0=%0d a1=%0d dsp0=%d dsp1=%d", c_cycles, rs_alloc0, rs_alloc1, dsp0_en, dsp1_en);
            $display("[C0] cyc=%0d cand0=%b cand1=%b candL=%b i0=%0d i1=%0d iL=%0d", c_cycles, cand0, cand1, candL, iss0_idx, iss1_idx, issL_idx);
        end
        if (c_cycles == 1500) begin
            $display("[MOBST] h=%0d t=%0d", mob_head, mob_tail);
            for (ri = 0; ri < RSN; ri = ri + 1)
                if (rs_valid[ri])
                    $display("[RS%0d] tag=%0d pc=%h ld=%d st=%d s1r=%d s2r=%d mob=%0d", ri, rs_tag[ri], rs_pc[ri], rs_is_load[ri], rs_is_store[ri], rs_s1_rdy[ri], rs_s2_rdy[ri], rs_mob_ptr[ri]);
            $display("[ROBST] head=%0d tail=%0d rsfree=%0d", rob_head, rob_tail, rs_free_cnt);
        end
        if (c_cycles >= 380 && c_cycles <= 410) begin
            if (flush) $display("[PCF] cyc=%0d flush -> %h", c_cycles, flush_target);
            else if (pop_redirect) $display("[PCF] cyc=%0d popredir -> %h q0=%h q1=%h d0jal=%d d1jal=%d ift0=%d ift1=%d pt0=%d pt1=%d", c_cycles, pop_red_target, q_pc[0], q_pc[1], d0_jal, d1_jal, q_ift[0], q_ift[1], p0_pred_taken, p1_pred_taken);
            else if (q0_control && eff0_taken && dsp0_en && !dsp1_en) $display("[PCF] cyc=%0d taken0 -> %h", c_cycles, eff0_target);
            else if (dsp1_en && q1_control && eff1_taken) $display("[PCF] cyc=%0d taken1 -> %h q1=%h", c_cycles, eff1_target, q_pc[1]);
            else if (can_issue_read) $display("[PCF] cyc=%0d read %h m=%0d", c_cycles, pc_f, push_m);
        end
        if (c_cycles == 71004) begin
            for (ri = 0; ri < ROBN; ri = ri + 1)
                $display("[ROB%0d] pc=%h done=%d st=%d nt=%0d", ri, rob_pc[ri], rob_done[ri], rob_is_store[ri], rob_next_tail[ri]);
        end
        if (c_cycles >= 71004 && c_cycles <= 71040)
            $display("[RH] cyc=%0d head=%0d tail=%0d pc=%h done=%d st=%d cmt0=%d cmt1=%d stgo1=%d stgo=%d", c_cycles, rob_head, rob_tail, rob_pc[rh], rob_done[rh], rob_is_store[rh], commit0, commit1, st_go1, st_go);
        if (c_cycles % 2000 == 1999)
            $display("[ALIVE] cyc=%0d retire=%0d flush=%0d pc_f=%h q_cnt=%0d head=%0d tail=%0d robpc=%h done=%d",
                c_cycles, c_retire, c_flush, pc_f, q_cnt, rob_head, rob_tail, rob_pc[rh], rob_done[rh]);
    end
`endif

endmodule
