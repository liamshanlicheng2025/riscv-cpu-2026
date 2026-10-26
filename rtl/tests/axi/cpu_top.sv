// Protocol exerciser replacing only the CPU behind the real student_top.
module cpu_top #(
  parameter integer RENAME_WIDTH=2,COMMIT_WIDTH=2,INTEGER_PORTS=2,
  ROB_ENTRIES=16,IQ_ENTRIES=2,CHECKPOINTS=4,LOAD_SLOTS=8,STORE_SLOTS=16,
  ICACHE_BYTES=1024,DCACHE_BYTES=4096,DCACHE_WAYS=2,DCACHE_LINE_BYTES=128,
  DCACHE_BANKS=4,FETCH_QUEUE_ENTRIES=4,BHT_ENTRIES=128,BTB_ENTRIES=32,
  RAM_BYTES=268435456,LSU_PIPELINE=1
) (
  input wire clk,rst,
  output wire mem_req_valid,mem_req_write,
  output wire [31:0] mem_req_addr,mem_req_wdata,
  output wire [3:0] mem_req_wstrb,
  input wire mem_req_ready,mem_rsp_valid,
  input wire [31:0] mem_rsp_rdata,
  input wire mem_rsp_error,
  output wire mem_rsp_ready,halted,faulted
);
  integer unsigned issued,returned,cycles;
  assign mem_req_valid=!rst && issued<=300;
  assign mem_req_write=issued==300 || issued%3==0;
  assign mem_req_addr=issued==300 ? 32'h80000000:32'h1000+4*issued;
  assign mem_req_wdata=32'hdeadbeef ^ issued;
  assign mem_req_wstrb=4'(issued%15+1);
  assign mem_rsp_ready=!rst && cycles%11<7;
  assign halted=issued==301;
  assign faulted=0;
  always @(posedge clk) begin
    if(rst) begin issued<=0;returned<=0;cycles<=0;end
    else begin
      cycles<=cycles+1;
      if(mem_req_valid && mem_req_ready) issued<=issued+1;
      if(mem_rsp_valid && mem_rsp_ready) begin
        assert(returned<issued && returned<300) else $fatal(1,"unexpected unified response");
        assert(mem_rsp_error==(returned%17==0)) else $fatal(1,"response error ownership");
        if(returned%3!=0)
          assert(mem_rsp_rdata==(32'ha5a51234 ^ returned)) else $fatal(1,"response data ownership");
        else assert(mem_rsp_rdata==0) else $fatal(1,"write response data");
        returned<=returned+1;
      end
    end
  end
  final begin
    assert(issued==301 && returned==300) else $fatal(1,"unified interface did not drain");
  end
endmodule
