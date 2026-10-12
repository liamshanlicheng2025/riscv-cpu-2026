// icache.v —— 直接映射指令 cache：256 行 x 16B（4 字）
// tag 用一片 sram_fakeram(256x20)，data 用一片 sram_fakeram(256x128)，
// valid 位用独立 reg 阵列（sram_fakeram 无复位，valid 必须自行初始化）。
//
// 读端口时序约定（与流水线的配合）：
//   每拍都发 SRAM 读。正常流动时读 pc_f，下一拍 rdata 对应 pc_id（=旧 pc_f）；
//   前端停顿时改读 pc_id，保证停顿时 rdata 始终对应 ID 中的指令。
// miss 后流水线前端停顿，本模块走 REQ->RECV->WRITE->WRITE2->REFRESH 填充；
// 填充时顺带顺序预取下一行（代码局部性强，流式取指 miss 减半）。
// REFRESH 拍重新读 pc_id，释放后 ID 必定命中。
module icache (
    input  wire        clk,
    input  wire        reset,
    input  wire [31:0] pc_f,
    input  wire [31:0] pc_id,
    input  wire        front_stall,
    output wire [31:0] instr,
    output wire [31:0] instr2,
    output wire        hit,
    output wire        hit2,
    input  wire        miss,        // 组合输入：ID 指令缺失（仅 IDLE 时有效）
    output wire        busy,
    // AXI 读通道（经顶层仲裁器共享）
    output wire        req,
    input  wire        grant,
    output wire [31:0] ar_addr,
    output wire        ar_valid,
    input  wire        ar_ready,
    input  wire [31:0] rdata,
    input  wire        rvalid,
    output wire        last_r       // 正在消费最后一个响应（供仲裁器释放）
);
    localparam S_IDLE    = 3'd0;
    localparam S_REQ     = 3'd1;
    localparam S_RECV    = 3'd2;
    localparam S_WRITE   = 3'd3;
    localparam S_WRITE2  = 3'd4;
    localparam S_WRITE3  = 3'd5;
    localparam S_REFRESH = 3'd6;
    localparam S_INIT    = 3'd7;   // 上电逐行清 valid（SRAM 无复位）

    reg [2:0]   state;
    reg [31:0]  miss_addr;
    reg [3:0]   ar_cnt;
    reg [3:0]   r_cnt;
    reg [383:0] line_buf;
    reg         do_pref, do_pref2;  // 本 fill 预取的额外行数
    reg [7:0]   init_cnt;
    reg         init_done;

    wire [31:0] line2_addr = miss_addr + 32'd16;
    wire [31:0] line3_addr = miss_addr + 32'd32;

    assign busy   = (state != S_IDLE);
    assign req    = (state == S_REQ) || (state == S_RECV);
    assign ar_valid = (state == S_REQ) && grant;
    assign ar_addr  = {miss_addr[31:4] + {26'b0, ar_cnt[3:2]}, ar_cnt[1:0], 2'b00};
    wire [3:0] last_beat = do_pref2 ? 4'd11 : do_pref ? 4'd7 : 4'd3;
    assign last_r = (state == S_RECV) && rvalid && (r_cnt == last_beat);

    // ---- SRAM 端口 ----
    wire we1 = (state == S_WRITE);
    wire we2 = (state == S_WRITE2) && do_pref;
    wire we3 = (state == S_WRITE3) && do_pref2;
    wire we  = we1 || we2 || we3;
    wire [31:0] fill_line_addr = we2 ? line2_addr : we3 ? line3_addr : miss_addr;
    // we 要驱动 data SRAM 16 个 lane 的 we_in 与 addr mux，复制两份（keep 防合并）
    (* keep *) wire we_d = we;   // data SRAM we
    (* keep *) wire we_a = we;   // addr mux
    wire [7:0] index = we_a ? fill_line_addr[11:4]
                     : front_stall ? pc_id[11:4] : pc_f[11:4];
    wire [19:0] tag_wdata = fill_line_addr[31:12];

    // valid 位并入 tag SRAM（最高位）
    wire init_active = (state == S_INIT);
    wire [20:0] tag_rdata;
    wire [127:0] data_rdata;

    sram_fakeram #(.DEPTH(256), .WIDTH(21), .WRITE_GRANULARITY(21)) tag_ram (
        .clk(clk), .en(1'b1), .we(we || init_active), .wmask(1'b1),
        .addr(init_active ? init_cnt : index),
        .wdata(init_active ? 21'b0 : {1'b1, tag_wdata}), .rdata(tag_rdata));

    // 填充三个写状态依次消耗 line_buf 低 128 位，每写一段整体右移 128 位
    //（见 FSM），wdata 恒为 line_buf[127:0]，不再需要 we1/we2/we3 大 mux
    sram_fakeram #(.DEPTH(256), .WIDTH(128), .WRITE_GRANULARITY(8)) data_ram (
        .clk(clk), .en(1'b1), .we(we_d), .wmask(16'hFFFF),
        .addr(index),
        .wdata(line_buf[127:0]),
        .rdata(data_rdata));

    assign hit   = init_done && (tag_rdata == {1'b1, pc_id[31:12]});
    assign instr = data_rdata[{pc_id[3:2], 5'b0} +: 32];
    // 第二字（同 line 内相邻字；跨 line 时无效）
    assign instr2 = data_rdata[{pc_id[3:2] + 2'd1, 5'b0} +: 32];
    assign hit2   = hit && (pc_id[3:2] != 2'b11);

    always @(posedge clk) begin
        if (reset) begin
            state      <= S_INIT;
            init_cnt   <= 8'b0;
            init_done  <= 1'b0;
            ar_cnt     <= 4'd0;
            r_cnt      <= 4'd0;
        end else begin
            case (state)
                S_INIT: begin
                    if (init_cnt == 8'hFF) begin
                        state     <= S_IDLE;
                        init_done <= 1'b1;
                    end else
                        init_cnt <= init_cnt + 8'd1;
                end
                S_IDLE: if (miss) begin
                    miss_addr <= pc_id;
                    ar_cnt    <= 4'd0;
                    // 预取至多两行（不出 RAM 范围时）
                    do_pref   <= (pc_id + 32'd16) < 32'h10000000;
                    do_pref2  <= (pc_id + 32'd32) < 32'h10000000;
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
                    line_buf[{r_cnt, 5'b0} +: 32] <= rdata;
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
                S_REFRESH: state <= S_IDLE;
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
