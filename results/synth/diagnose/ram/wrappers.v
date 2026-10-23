// Generated SRAM wrappers; do not edit.
module sram_fakeram_128x37_m37 (
    input clk, en, we,
    input [0:0] wmask,
    input [6:0] addr,
    input [36:0] wdata,
    output [36:0] rdata);
    fakeram_asap7_128x37 lane_0 (
        .clk(clk), .ce_in(en & (~we | wmask[0])), .we_in(we),
        .addr_in(addr), .wd_in(wdata[36:0]), .rd_out(rdata[36:0]));
endmodule

module sram_fakeram_256x21_m21 (
    input clk, en, we,
    input [0:0] wmask,
    input [7:0] addr,
    input [20:0] wdata,
    output [20:0] rdata);
    fakeram_asap7_256x21 lane_0 (
        .clk(clk), .ce_in(en & (~we | wmask[0])), .we_in(we),
        .addr_in(addr), .wd_in(wdata[20:0]), .rd_out(rdata[20:0]));
endmodule

module sram_fakeram_256x128_m8 (
    input clk, en, we,
    input [15:0] wmask,
    input [7:0] addr,
    input [127:0] wdata,
    output [127:0] rdata);
    fakeram_asap7_256x8 lane_0 (
        .clk(clk), .ce_in(en & (~we | wmask[0])), .we_in(we),
        .addr_in(addr), .wd_in(wdata[7:0]), .rd_out(rdata[7:0]));
    fakeram_asap7_256x8 lane_1 (
        .clk(clk), .ce_in(en & (~we | wmask[1])), .we_in(we),
        .addr_in(addr), .wd_in(wdata[15:8]), .rd_out(rdata[15:8]));
    fakeram_asap7_256x8 lane_2 (
        .clk(clk), .ce_in(en & (~we | wmask[2])), .we_in(we),
        .addr_in(addr), .wd_in(wdata[23:16]), .rd_out(rdata[23:16]));
    fakeram_asap7_256x8 lane_3 (
        .clk(clk), .ce_in(en & (~we | wmask[3])), .we_in(we),
        .addr_in(addr), .wd_in(wdata[31:24]), .rd_out(rdata[31:24]));
    fakeram_asap7_256x8 lane_4 (
        .clk(clk), .ce_in(en & (~we | wmask[4])), .we_in(we),
        .addr_in(addr), .wd_in(wdata[39:32]), .rd_out(rdata[39:32]));
    fakeram_asap7_256x8 lane_5 (
        .clk(clk), .ce_in(en & (~we | wmask[5])), .we_in(we),
        .addr_in(addr), .wd_in(wdata[47:40]), .rd_out(rdata[47:40]));
    fakeram_asap7_256x8 lane_6 (
        .clk(clk), .ce_in(en & (~we | wmask[6])), .we_in(we),
        .addr_in(addr), .wd_in(wdata[55:48]), .rd_out(rdata[55:48]));
    fakeram_asap7_256x8 lane_7 (
        .clk(clk), .ce_in(en & (~we | wmask[7])), .we_in(we),
        .addr_in(addr), .wd_in(wdata[63:56]), .rd_out(rdata[63:56]));
    fakeram_asap7_256x8 lane_8 (
        .clk(clk), .ce_in(en & (~we | wmask[8])), .we_in(we),
        .addr_in(addr), .wd_in(wdata[71:64]), .rd_out(rdata[71:64]));
    fakeram_asap7_256x8 lane_9 (
        .clk(clk), .ce_in(en & (~we | wmask[9])), .we_in(we),
        .addr_in(addr), .wd_in(wdata[79:72]), .rd_out(rdata[79:72]));
    fakeram_asap7_256x8 lane_10 (
        .clk(clk), .ce_in(en & (~we | wmask[10])), .we_in(we),
        .addr_in(addr), .wd_in(wdata[87:80]), .rd_out(rdata[87:80]));
    fakeram_asap7_256x8 lane_11 (
        .clk(clk), .ce_in(en & (~we | wmask[11])), .we_in(we),
        .addr_in(addr), .wd_in(wdata[95:88]), .rd_out(rdata[95:88]));
    fakeram_asap7_256x8 lane_12 (
        .clk(clk), .ce_in(en & (~we | wmask[12])), .we_in(we),
        .addr_in(addr), .wd_in(wdata[103:96]), .rd_out(rdata[103:96]));
    fakeram_asap7_256x8 lane_13 (
        .clk(clk), .ce_in(en & (~we | wmask[13])), .we_in(we),
        .addr_in(addr), .wd_in(wdata[111:104]), .rd_out(rdata[111:104]));
    fakeram_asap7_256x8 lane_14 (
        .clk(clk), .ce_in(en & (~we | wmask[14])), .we_in(we),
        .addr_in(addr), .wd_in(wdata[119:112]), .rd_out(rdata[119:112]));
    fakeram_asap7_256x8 lane_15 (
        .clk(clk), .ce_in(en & (~we | wmask[15])), .we_in(we),
        .addr_in(addr), .wd_in(wdata[127:120]), .rd_out(rdata[127:120]));
endmodule

module sram_fakeram_1024x19_m19 (
    input clk, en, we,
    input [0:0] wmask,
    input [9:0] addr,
    input [18:0] wdata,
    output [18:0] rdata);
    fakeram_asap7_1024x19 lane_0 (
        .clk(clk), .ce_in(en & (~we | wmask[0])), .we_in(we),
        .addr_in(addr), .wd_in(wdata[18:0]), .rd_out(rdata[18:0]));
endmodule

module sram_fakeram_1024x128_m8 (
    input clk, en, we,
    input [15:0] wmask,
    input [9:0] addr,
    input [127:0] wdata,
    output [127:0] rdata);
    fakeram_asap7_1024x8 lane_0 (
        .clk(clk), .ce_in(en & (~we | wmask[0])), .we_in(we),
        .addr_in(addr), .wd_in(wdata[7:0]), .rd_out(rdata[7:0]));
    fakeram_asap7_1024x8 lane_1 (
        .clk(clk), .ce_in(en & (~we | wmask[1])), .we_in(we),
        .addr_in(addr), .wd_in(wdata[15:8]), .rd_out(rdata[15:8]));
    fakeram_asap7_1024x8 lane_2 (
        .clk(clk), .ce_in(en & (~we | wmask[2])), .we_in(we),
        .addr_in(addr), .wd_in(wdata[23:16]), .rd_out(rdata[23:16]));
    fakeram_asap7_1024x8 lane_3 (
        .clk(clk), .ce_in(en & (~we | wmask[3])), .we_in(we),
        .addr_in(addr), .wd_in(wdata[31:24]), .rd_out(rdata[31:24]));
    fakeram_asap7_1024x8 lane_4 (
        .clk(clk), .ce_in(en & (~we | wmask[4])), .we_in(we),
        .addr_in(addr), .wd_in(wdata[39:32]), .rd_out(rdata[39:32]));
    fakeram_asap7_1024x8 lane_5 (
        .clk(clk), .ce_in(en & (~we | wmask[5])), .we_in(we),
        .addr_in(addr), .wd_in(wdata[47:40]), .rd_out(rdata[47:40]));
    fakeram_asap7_1024x8 lane_6 (
        .clk(clk), .ce_in(en & (~we | wmask[6])), .we_in(we),
        .addr_in(addr), .wd_in(wdata[55:48]), .rd_out(rdata[55:48]));
    fakeram_asap7_1024x8 lane_7 (
        .clk(clk), .ce_in(en & (~we | wmask[7])), .we_in(we),
        .addr_in(addr), .wd_in(wdata[63:56]), .rd_out(rdata[63:56]));
    fakeram_asap7_1024x8 lane_8 (
        .clk(clk), .ce_in(en & (~we | wmask[8])), .we_in(we),
        .addr_in(addr), .wd_in(wdata[71:64]), .rd_out(rdata[71:64]));
    fakeram_asap7_1024x8 lane_9 (
        .clk(clk), .ce_in(en & (~we | wmask[9])), .we_in(we),
        .addr_in(addr), .wd_in(wdata[79:72]), .rd_out(rdata[79:72]));
    fakeram_asap7_1024x8 lane_10 (
        .clk(clk), .ce_in(en & (~we | wmask[10])), .we_in(we),
        .addr_in(addr), .wd_in(wdata[87:80]), .rd_out(rdata[87:80]));
    fakeram_asap7_1024x8 lane_11 (
        .clk(clk), .ce_in(en & (~we | wmask[11])), .we_in(we),
        .addr_in(addr), .wd_in(wdata[95:88]), .rd_out(rdata[95:88]));
    fakeram_asap7_1024x8 lane_12 (
        .clk(clk), .ce_in(en & (~we | wmask[12])), .we_in(we),
        .addr_in(addr), .wd_in(wdata[103:96]), .rd_out(rdata[103:96]));
    fakeram_asap7_1024x8 lane_13 (
        .clk(clk), .ce_in(en & (~we | wmask[13])), .we_in(we),
        .addr_in(addr), .wd_in(wdata[111:104]), .rd_out(rdata[111:104]));
    fakeram_asap7_1024x8 lane_14 (
        .clk(clk), .ce_in(en & (~we | wmask[14])), .we_in(we),
        .addr_in(addr), .wd_in(wdata[119:112]), .rd_out(rdata[119:112]));
    fakeram_asap7_1024x8 lane_15 (
        .clk(clk), .ce_in(en & (~we | wmask[15])), .we_in(we),
        .addr_in(addr), .wd_in(wdata[127:120]), .rd_out(rdata[127:120]));
endmodule
