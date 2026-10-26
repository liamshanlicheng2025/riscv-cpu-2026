// Course AXI4-Lite interface. Responses retain the CPU's unified acceptance
// order; AW and W are tracked independently under channel backpressure.
module student_top #(
  parameter integer ISSUE_WIDTH=2, COMMIT_WIDTH=2, INTEGER_PORTS=2,
  parameter integer ROB_DEPTH=16, RS_DEPTH=2, CHECKPOINTS=4,
  parameter integer LOAD_SLOTS=8, STORE_BUF_DEPTH=16,
  parameter integer ICACHE_BYTES=1024, DCACHE_BYTES=2048, DCACHE_WAYS=2,
  parameter integer DCACHE_LINE_BYTES=128, DCACHE_BANKS=4,
  parameter integer Q_DEPTH=4, BHT_ENTRIES=128, BTB_ENTRIES=32, LSU_PIPELINE=0,
  parameter integer RAM_BYTES=268435456
) (
  input wire clock,reset,
  output wire [31:0] araddr,
  output wire arvalid,
  input wire arready,
  input wire [31:0] rdata,
  input wire [1:0] rresp,
  input wire rvalid,
  output wire rready,
  output wire [31:0] awaddr,
  output wire awvalid,
  input wire awready,
  output wire [31:0] wdata,
  output wire [3:0] wstrb,
  output wire wvalid,
  input wire wready,
  input wire [1:0] bresp,
  input wire bvalid,
  output wire bready
);
  wire req_valid,req_write,req_ready,rsp_valid,rsp_ready,rsp_error;
  wire [31:0] req_addr,req_data,rsp_data;
  wire [3:0] req_mask;
  wire halted,faulted;
  reg [1:0] owners[0:63];
  reg [5:0] head,tail;
  reg [6:0] count;
  reg write_pending,aw_sent,w_sent;
  reg [31:0] write_address,write_value;
  reg [3:0] write_mask;
  reg [1:0] response_owner;
  wire owner_write=response_owner[0];
  wire owner_exit=response_owner[1];
  wire response_present=count!=0;
  wire write_finished=write_pending && (aw_sent || awready) && (w_sent || wready);
  wire response_fire=(rvalid && rready) || (bvalid && bready);
  wire space=count<64 || response_fire;
  assign araddr=req_addr;
  assign arvalid=!reset && req_valid && !req_write && space;
  wire direct_write=!reset && !write_pending && req_valid && req_write && space;
  assign awaddr=write_pending ? write_address:req_addr;
  assign awvalid=!reset && ((write_pending && !aw_sent) || direct_write);
  assign wdata=write_pending ? write_value:req_data;
  assign wstrb=write_pending ? write_mask:req_mask;
  assign wvalid=!reset && ((write_pending && !w_sent) || direct_write);
  assign req_ready=!reset && space && (req_write ? (!write_pending || write_finished):arready);
  assign rsp_valid=!reset && response_present && !owner_exit && (owner_write ? bvalid:rvalid);
  assign rsp_data=owner_write ? 32'd0:rdata;
  assign rsp_error=owner_write ? |bresp:|rresp;
  assign rready=!reset && response_present && !owner_write && rsp_ready;
  // The exit write is outside the core's transaction controller. Its B
  // response must still handshake before the course simulator terminates.
  assign bready=!reset && response_present && owner_write && (owner_exit || rsp_ready);
  wire request_fire=req_valid && req_ready;
  always @(posedge clock) begin
    if(reset) begin
      head<=0;tail<=0;count<=0;write_pending<=0;aw_sent<=0;w_sent<=0;
      response_owner<=0;
    end else begin
      if(request_fire && (count==0 || (response_fire && count==1)))
        response_owner<={req_write && req_addr==32'h80000000,req_write};
      else if(response_fire) response_owner<=owners[6'(head+1'b1)];
      case({request_fire,response_fire})
        2'b10: count<=count+1'b1;
        2'b01: count<=count-1'b1;
        default: ;
      endcase
      if(response_fire) head<=head+1'b1;
      if(write_pending) begin
        if(awvalid && awready) aw_sent<=1;
        if(wvalid && wready) w_sent<=1;
        if(write_finished) write_pending<=0;
      end
      if(request_fire) begin
        owners[tail]<={req_write && req_addr==32'h80000000,req_write};
        tail<=tail+1'b1;
        if(req_write) begin
          write_pending<=write_pending || !(awready && wready);
          aw_sent<=!write_pending && awready;w_sent<=!write_pending && wready;
          write_address<=req_addr;write_value<=req_data;write_mask<=req_mask;
        end
      end
    end
  end
`ifndef SYNTHESIS
  always @(posedge clock) if(!reset && count!=0)
    assert(response_owner==owners[head]) else $fatal(1,"AXI response owner mismatch");
`endif
  cpu_top #(
    .RENAME_WIDTH(ISSUE_WIDTH),.COMMIT_WIDTH(COMMIT_WIDTH),.INTEGER_PORTS(INTEGER_PORTS),
    .ROB_ENTRIES(ROB_DEPTH),.IQ_ENTRIES(RS_DEPTH),.CHECKPOINTS(CHECKPOINTS),
    .LOAD_SLOTS(LOAD_SLOTS),.STORE_SLOTS(STORE_BUF_DEPTH),
    .ICACHE_BYTES(ICACHE_BYTES),.DCACHE_BYTES(DCACHE_BYTES),.DCACHE_WAYS(DCACHE_WAYS),
    .DCACHE_LINE_BYTES(DCACHE_LINE_BYTES),.DCACHE_BANKS(DCACHE_BANKS),
    .FETCH_QUEUE_ENTRIES(Q_DEPTH),.BHT_ENTRIES(BHT_ENTRIES),.BTB_ENTRIES(BTB_ENTRIES),
    .RAM_BYTES(RAM_BYTES),.LSU_PIPELINE(LSU_PIPELINE)
  ) cpu (
    .clk(clock),.rst(reset),.mem_req_valid(req_valid),.mem_req_write(req_write),
    .mem_req_addr(req_addr),.mem_req_wdata(req_data),.mem_req_wstrb(req_mask),.mem_req_ready(req_ready),
    .mem_rsp_valid(rsp_valid),.mem_rsp_rdata(rsp_data),.mem_rsp_error(rsp_error),.mem_rsp_ready(rsp_ready),
    .halted(halted),.faulted(faulted)
  );
endmodule
