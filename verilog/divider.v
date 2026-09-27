// divider.v —— 16 拍迭代除法器（恢复余数法，每拍 2 位，radix-4）
// 特殊情况（除零 / INT_MIN 溢出）在流水级内组合处理，不启动本模块。
// op: 0=DIV 1=DIVU 2=REM 3=REMU （即 funct3[1:0]）
module divider (
    input  wire        clk,
    input  wire        reset,
    input  wire        start,     // 单拍脉冲，本沿采样操作数
    input  wire [31:0] a,
    input  wire [31:0] b,
    input  wire [1:0]  op,
    output reg         busy,
    output wire        done,      // 组合输出：最后一个迭代拍为高
    output wire [31:0] result     // 组合输出，done 时有效
);
    reg [31:0] num, den, quot, rem;
    reg [4:0]  cnt;
    reg        q_neg, r_neg;
    reg [1:0]  op_r;

    wire        sign_op = ~op_r[0];              // DIV/REM 为有符号

    // 每拍串联两个 radix-2 恢复余数迭代
    wire [31:0] remA  = {rem[30:0], num[31]};
    wire        geA   = (remA >= den);
    wire [31:0] remA2 = geA ? (remA - den) : remA;
    wire [31:0] remB  = {remA2[30:0], num[30]};
    wire        geB   = (remB >= den);
    wire [31:0] rem_n   = geB ? (remB - den) : remB;
    wire [31:0] quot_n  = {quot[29:0], geA, geB};

    assign done = busy && (cnt == 5'd1);
    wire [31:0] q_fin = (sign_op && q_neg) ? -quot_n : quot_n;
    wire [31:0] r_fin = (sign_op && r_neg) ? -rem_n  : rem_n;
    assign result = op_r[1] ? r_fin : q_fin;

    always @(posedge clk) begin
        if (reset) begin
            busy <= 1'b0;
            cnt  <= 5'd0;
        end else if (start) begin
            busy  <= 1'b1;
            cnt   <= 5'd16;
            num   <= (op[0] || !a[31]) ? a : -a;  // 有符号取绝对值
            den   <= (op[0] || !b[31]) ? b : -b;
            quot  <= 32'b0;
            rem   <= 32'b0;
            q_neg <= !op[0] && (a[31] ^ b[31]);
            r_neg <= !op[0] && a[31];
            op_r  <= op;
        end else if (busy) begin
            num  <= {num[29:0], 2'b0};
            rem  <= rem_n;
            quot <= quot_n;
            cnt  <= cnt - 5'd1;
            if (cnt == 5'd1) busy <= 1'b0;
        end
    end
endmodule
