// dcache.v —— 直接映射数据 cache：1024 行 x 16B，写穿 + store miss 不分配
//
// 访问时序（与流水线配合）：
//   EX 拍：访存指令用组合 ALU 地址（ex_addr）发起 tag+data SRAM 读；
//   MEM 拍：rdata 有效，组合判断 hit。load 命中直接取数；miss 走填充流程。
//   store：hit 则在 MEM 拍同时写 data SRAM（字节写掩码）并把数据压入
//          store buffer 写穿到 AXI；miss 只压 store buffer。
// 端口冲突：MEM 拍 store 写 与 EX 拍 load 读 冲突时由顶层停顿 EX 一拍。
// 填充前必须等 store buffer 中落在目标 line 内的写全部完成（sb_clear），
// 否则 AXI 读可能读到尚未服务的旧数据。
// 填充顺带顺序预取下一行（要求预取行也无 pending store：sb_clear2）。
module dcache (
    input  wire        clk,
    input  wire        reset,
    input  wire [31:0] ex_addr,      // EX 拍组合地址
    input  wire [31:0] mem_addr,     // MEM 拍地址（EX/MEM 寄存器）
    input  wire        hold,         // 停顿/REFRESH 期间保持读 mem_addr
    input  wire        store_wr,     // MEM 拍 store 命中写
    input  wire [127:0] store_wdata,
    input  wire [15:0] store_wmask,
    output wire        hit,
    output wire [127:0] line_rdata,
    input  wire        miss,         // load miss（仅 IDLE 时有效）
    output wire        busy,
    output wire        fillwrite,    // 正在写回填充行（占口，需冻结流水线）
    output wire        fill_clash,   // mem_addr 落在正在填充的行（含预取行）内
    output reg         crit_valid,   // 首个填充字（miss 的目标字）已到
    output reg  [31:0] crit_word,
    input  wire        crit_consume, // 目标字已被流水线取走
    input  wire        sb_clear,     // store buffer 中无落在 miss line 的项
    input  wire        sb_clear2,    // 同上，针对 miss+1 行（预取用）
    input  wire        sb_clear3,    // 同上，针对 miss+2 行（预取用）
    // AXI 读通道（经顶层仲裁器共享）
    output wire        req,
    input  wire        grant,
    output wire [31:0] ar_addr,
    output wire        ar_valid,
    input  wire        ar_ready,
    input  wire [31:0] rdata,
    input  wire        rvalid,
    output wire        last_r
);
    // 独热编码：状态译码（fillwrite/busy 等广播信号）直接由单 FF 输出，
    // 避免多 bit 译码形成的高扇出深锥
    localparam S_IDLE    = 7'b0000001;
    localparam S_REQ     = 7'b0000010;
    localparam S_RECV    = 7'b0000100;
    localparam S_WRITE   = 7'b0001000;
    localparam S_WRITE2  = 7'b0010000;
    localparam S_WRITE3  = 7'b0100000;
    localparam S_REFRESH = 7'b1000000;
    localparam S_INIT_ST = 8'b10000000;   // 上电逐行清 valid（SRAM 无复位）

    localparam IBITS = 10;                 // 1024 行（16KB）
    localparam TAGW  = 32 - 4 - IBITS;     // tag 宽度 18

    reg [7:0]   state;
    reg [31:0]  miss_addr;
    reg [3:0]   ar_cnt;
    reg [3:0]   r_cnt;
    reg [383:0] line_buf;
    reg         do_pref, do_pref2;
    reg [IBITS-1:0] init_cnt;
    reg         init_done;

    wire [31:0] line2_addr = miss_addr + 32'd16;
    wire [31:0] line3_addr = miss_addr + 32'd32;

    assign busy     = (state != S_IDLE);
    assign fillwrite = state[6] | state[5] | state[4] | state[3];  // WRITE*/REFRESH
    // 填充期间提交 store 会打破 sb_clear 门控（早期释放后流水线已恢复），
    // 命中填充行/预取行的 store 必须等填充完成再按 hit 更新 cache。
    // 用行索引（10 bit）比较：跨 16KB 的别名只会造成无害的假停顿
    assign fill_clash = (state != S_IDLE) &&
                        ((mem_addr[3+IBITS:4] == miss_addr[3+IBITS:4]) ||
                         (do_pref  && (mem_addr[3+IBITS:4] == line2_addr[3+IBITS:4])) ||
                         (do_pref2 && (mem_addr[3+IBITS:4] == line3_addr[3+IBITS:4])));
    assign req      = (state == S_REQ) || (state == S_RECV);
    assign ar_valid = (state == S_REQ) && grant;
    // 关键字优先：前 4 拍从 miss 字开始（行内回绕），之后为预取行
    wire [1:0] ar_word = miss_addr[3:2] + ar_cnt[1:0];
    assign ar_addr  = (ar_cnt < 4)  ? {miss_addr[31:4], ar_word, 2'b00} :
                      (ar_cnt < 8)  ? {miss_addr[31:4] + 28'd1, ar_cnt[1:0], 2'b00} :
                                      {miss_addr[31:4] + 28'd2, ar_cnt[1:0], 2'b00};
    wire [3:0] last_beat = do_pref2 ? 4'd11 : do_pref ? 4'd7 : 4'd3;
    assign last_r   = (state == S_RECV) && rvalid && (r_cnt == last_beat);

    // ---- SRAM 端口 ----
    // data：fill 写 > store 写 > hold/EX 读
    // tag ：fill 写 > hold/EX 读（store 写不占 tag 口——EX 的 store 还要继续读 tag）
    wire we1 = (state == S_WRITE);
    wire we2 = (state == S_WRITE2) && do_pref;
    wire we3 = (state == S_WRITE3) && do_pref2;
    wire fill_wr = we1 || we2 || we3;
    wire [31:0] fill_line_addr = we2 ? line2_addr : we3 ? line3_addr : miss_addr;
    // fill_wr 的组合锥要驱动 data SRAM 的 wdata/wmask/addr/we 全部 mux
    //（16 个 lane 共享，合计上千负载），ABC 不插缓冲树，曾造成单级 17ns。
    // 手工复制多份（keep 防止被合并），每份只驱动一个消费组：
    (* keep *) wire fill_wr_a = fill_wr;              // data addr mux
    (* keep *) wire fill_wr_t = fill_wr;              // tag addr/we
    (* keep *) wire fill_wr_e = fill_wr;              // data we
    (* keep *) wire fill_wr_m = fill_wr;              // wmask mux
    (* keep *) wire [15:0] fill_wr_w = {16{fill_wr}}; // wdata mux（按字节 lane 分组）
    wire we      = fill_wr_e || store_wr;
    wire [IBITS-1:0] index = fill_wr_a ? fill_line_addr[3+IBITS:4]
                     : (store_wr || hold) ? mem_addr[3+IBITS:4]
                     : ex_addr[3+IBITS:4];
    wire [IBITS-1:0] tag_index = fill_wr_t ? fill_line_addr[3+IBITS:4]
                     : hold ? mem_addr[3+IBITS:4]
                     : ex_addr[3+IBITS:4];
    // 填充三个写状态依次消耗 line_buf 低 128 位，每写一段整体右移 128 位
    //（见 FSM），wdata 只剩 fill/store 二路选择，并按 lane 分组驱动
    wire [127:0] wdata;
    genvar lane;
    generate
        for (lane = 0; lane < 16; lane = lane + 1) begin : g_wdata
            assign wdata[lane*8 +: 8] = fill_wr_w[lane] ? line_buf[lane*8 +: 8]
                                                        : store_wdata[lane*8 +: 8];
        end
    endgenerate
    wire [15:0]  wmask = fill_wr_m ? 16'hFFFF : store_wmask;
    wire [TAGW-1:0] tag_wdata = fill_line_addr[31:4+IBITS];

    // valid 位并入 tag SRAM（最高位）：消除 1024 项 reg 阵列的写译码/读 mux
    wire init_active = (state == S_INIT_ST);
    wire [TAGW:0] tag_rdata;

    sram_fakeram #(.DEPTH(1<<IBITS), .WIDTH(TAGW+1), .WRITE_GRANULARITY(TAGW+1)) tag_ram (
        .clk(clk), .en(1'b1), .we(fill_wr_t || init_active), .wmask(1'b1),
        .addr(init_active ? init_cnt : tag_index),
        .wdata(init_active ? {(TAGW+1){1'b0}} : {1'b1, tag_wdata}), .rdata(tag_rdata));

    sram_fakeram #(.DEPTH(1<<IBITS), .WIDTH(128), .WRITE_GRANULARITY(8)) data_ram (
        .clk(clk), .en(1'b1), .we(we), .wmask(wmask),
        .addr(index), .wdata(wdata), .rdata(line_rdata));

    assign hit = init_done && (tag_rdata == {1'b1, mem_addr[31:4+IBITS]});

`ifdef DEBUG
    always @(posedge clk) begin
        if (state == S_REQ && grant && ar_ready) $display("[AR] %h", ar_addr);
        if (state == S_RECV && rvalid) $display("[R] rcnt=%0d data=%h", r_cnt, rdata);
        if (state == S_WRITE) $display("[FWR] line=%h buf=%h", miss_addr, line_buf[127:0]);
        if (miss_addr[31:4]==28'h2a) $display("[F2A] st=%0d miss=%h", state, miss_addr);
        if (mem_addr[31:4]==28'h5c || ex_addr[31:4]==28'h5c)

    end
`endif
    always @(posedge clk) begin
        if (reset) begin
            state      <= S_INIT_ST;
            init_cnt   <= {IBITS{1'b0}};
            init_done  <= 1'b0;
            ar_cnt     <= 4'd0;
            r_cnt      <= 4'd0;
            crit_valid <= 1'b0;
        end else begin
            if (crit_consume) crit_valid <= 1'b0;
            case (state)
                S_INIT_ST: begin
                    if (init_cnt == {(IBITS){1'b1}}) begin
                        state     <= S_IDLE;
                        init_done <= 1'b1;
                    end else
                        init_cnt <= init_cnt + 1'b1;
                end
                S_IDLE: if (miss && sb_clear) begin
                    miss_addr <= mem_addr;
                    ar_cnt    <= 4'd0;
                    crit_valid <= 1'b0;
                    // 预取至多两行：要求预取行无 pending store 且不越出 RAM
                    do_pref   <= sb_clear2 && ((mem_addr + 32'd16) < 32'h10000000);
                    do_pref2  <= sb_clear2 && sb_clear3 && ((mem_addr + 32'd32) < 32'h10000000);
                    state     <= S_REQ;
                end
                S_REQ: if (grant && ar_ready) begin
                    if (ar_cnt == last_beat) begin
                        state <= S_RECV;
                        r_cnt <= 3'd0;
                    end
                    ar_cnt <= ar_cnt + 3'd1;
                end
                S_RECV: if (rvalid) begin
                    // 前 4 个响应按 (miss_word+rcnt)%4 写回行内位置，其余按行序
                    if (r_cnt < 4)      line_buf[{miss_addr[3:2] + r_cnt[1:0], 5'b0} +: 32] <= rdata;
                    else if (r_cnt < 8) line_buf[{1'b1, r_cnt[1:0], 5'b0} +: 32] <= rdata;
                    else                line_buf[{2'b10, r_cnt[1:0], 5'b0} +: 32] <= rdata;
                    if (r_cnt == 4'd0) begin
                        crit_word  <= rdata;
                        crit_valid <= 1'b1;
                    end
                    if (r_cnt == last_beat) state <= S_WRITE;
                    r_cnt <= r_cnt + 4'd1;
                end
                // 每写完一段把 line_buf 右移 128 位，下一段总在 [127:0]
                S_WRITE:  begin
                    if (do_pref) line_buf[255:0] <= line_buf[383:128];
                    state <= do_pref ? S_WRITE2 : S_REFRESH;
                end
                S_WRITE2: begin
                    if (do_pref2) line_buf[127:0] <= line_buf[255:128];
                    state <= do_pref2 ? S_WRITE3 : S_REFRESH;
                end
                S_WRITE3: state <= S_REFRESH;
                // REFRESH：为等待中的 load 重读目标行（data SRAM 刚被写过，
                // rdata 已失效）；无等待时读 ex_addr，与 IDLE 行为一致
                S_REFRESH: state <= S_IDLE;
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
