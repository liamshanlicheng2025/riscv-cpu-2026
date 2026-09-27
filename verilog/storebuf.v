// storebuf.v —— 8 项 store buffer（写穿队列）
// MEM 拍的 store 压入；按 FIFO 顺序向 AXI 发 AW/W（背靠背，每拍可发一项），
// 收到 B 后弹出。bready 常 1，响应按序返回，因此每收到一个 bvalid 弹一项。
// chk_line：检查是否有任何未弹出项落在同一 16B line（供 d-cache 填充门控）。
module storebuf (
    input  wire        clk,
    input  wire        reset,
    input  wire        push,
    input  wire [31:0] push_addr,   // 4 字节对齐地址
    input  wire [31:0] push_data,   // 已按字节 lane 摆好的数据
    input  wire [3:0]  push_strb,
    output wire        full,
    input  wire [27:0] chk_line,    // addr[31:4]
    output reg         chk_clear,
    input  wire [27:0] chk_line2,   // 预取行（miss line + 1）
    output reg         chk_clear2,
    input  wire [27:0] chk_line3,   // 预取行（miss line + 2）
    output reg         chk_clear3,
    output reg  [31:0] awaddr,
    output reg         awvalid,
    input  wire        awready,
    output reg  [31:0] wdata,
    output reg  [3:0]  wstrb,
    output reg         wvalid,
    input  wire        wready,
    input  wire        bvalid
);
    localparam DEPTH = 8;

    reg [31:0] addr_q [0:DEPTH-1];
    reg [31:0] data_q [0:DEPTH-1];
    reg [3:0]  strb_q [0:DEPTH-1];
    reg [3:0]  head, tail, issue;   // 多 1 位用于计数
    reg        issuing;

    wire [3:0] cnt = tail - head;
    assign full = cnt[3];   // cnt == 8

    integer k;
    always @(*) begin
        chk_clear  = 1'b1;
        chk_clear2 = 1'b1;
        chk_clear3 = 1'b1;
        for (k = 0; k < DEPTH; k = k + 1)
            if (k < cnt) begin
                if (addr_q[(head[2:0] + k[2:0])][31:4] == chk_line)  chk_clear  = 1'b0;
                if (addr_q[(head[2:0] + k[2:0])][31:4] == chk_line2) chk_clear2 = 1'b0;
                if (addr_q[(head[2:0] + k[2:0])][31:4] == chk_line3) chk_clear3 = 1'b0;
            end
    end

    // AW、W 均已握手完成（本拍完成的也算）
    wire issue_done = issuing &&
                      (!awvalid || (awvalid && awready)) &&
                      (!wvalid  || (wvalid  && wready));

    wire [3:0] start_i = (issuing && issue_done) ? issue + 4'd1 : issue;
    // 可启动：队列中还有未发射项，或本拍正好多压入一项
    wire       start   = (issuing && !issue_done) ? 1'b0
                       : (start_i != tail) || push;
    // 启动项数据：start_i==tail 表示就是本拍 push 的项（尚未写入队列）
    wire [31:0] start_addr = (start_i == tail) ? push_addr : addr_q[start_i[2:0]];
    wire [31:0] start_data = (start_i == tail) ? push_data : data_q[start_i[2:0]];
    wire [3:0]  start_strb = (start_i == tail) ? push_strb : strb_q[start_i[2:0]];

    always @(posedge clk) begin
        if (reset) begin
            head    <= 4'd0;
            tail    <= 4'd0;
            issue   <= 4'd0;
            issuing <= 1'b0;
            awvalid <= 1'b0;
            wvalid  <= 1'b0;
        end else begin
            if (bvalid) head <= head + 4'd1;
            if (push) begin
                addr_q[tail[2:0]] <= push_addr;
                data_q[tail[2:0]] <= push_data;
                strb_q[tail[2:0]] <= push_strb;
                tail <= tail + 4'd1;
            end
            if (issuing && !issue_done) begin
                if (awvalid && awready) awvalid <= 1'b0;
                if (wvalid && wready)  wvalid  <= 1'b0;
            end else begin
                if (issuing) issue <= issue + 4'd1;   // 当前项发完，推进
                if (start) begin
                    issuing <= 1'b1;
                    awvalid <= 1'b1;
                    awaddr  <= start_addr;
                    wvalid  <= 1'b1;
                    wdata   <= start_data;
                    wstrb   <= start_strb;
                end else begin
                    issuing <= 1'b0;
                    awvalid <= 1'b0;
                    wvalid  <= 1'b0;
                end
            end
        end
    end
endmodule
