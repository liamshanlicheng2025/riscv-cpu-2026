module v2_frontend #(
  parameter integer CACHE_BYTES=1024, QUEUE_ENTRIES=8, BHT_ENTRIES=256, BTB_ENTRIES=32,
  parameter integer LOCAL_HISTORY_BITS=1, HISTORY_ENTRIES=64,
  parameter integer RAM_BYTES=268435456, HB=(LOCAL_HISTORY_BITS>0 ? LOCAL_HISTORY_BITS:1)
)(
  input logic clk,rst,stop,redirect,
  input logic [31:0] redirect_pc,
  input logic [1:0] pop_count,
  output logic [1:0] packet_valid,packet_available,
  output logic [63:0] packet_pc,packet_inst,packet_prediction,
  output logic [7:0] packet_fault,
  output logic [1:0] packet_inst_valid,
  output logic [2*HB-1:0] packet_history,
  input logic [HB-1:0] train_history,
  input logic train_valid,train_taken,
  input cpu_pkg::op_t train_op,
  input logic [31:0] train_pc,train_target,
  output logic mem_req_valid,
  input logic mem_req_ready,
  output logic [31:0] mem_req_addr,
  input logic mem_rsp_valid,
  output logic mem_rsp_ready,
  input logic [31:0] mem_rsp_data,
  input logic mem_rsp_error,
  output logic idle,
  output logic [63:0] miss_count
);
  import cpu_pkg::*;
  localparam integer CB=$clog2(CACHE_BYTES), LINES=CACHE_BYTES/32, LB=$clog2(LINES);
  localparam integer QW=$clog2(QUEUE_ENTRIES), BW=$clog2(BHT_ENTRIES), TW=$clog2(BTB_ENTRIES);
  typedef struct packed {logic [3:0] fault;logic iv;logic [HB-1:0] history;logic [31:0] pc,inst,pred;} packet_t;
  packet_t fifo [QUEUE_ENTRIES],incoming[2];
  logic [QW-1:0] head,tail;
  logic [QUEUE_ENTRIES-1:0] head_select_n;
  wire [QUEUE_ENTRIES-1:0] head_select=~head_select_n;
  wire [QUEUE_ENTRIES-1:0] second_select={head_select[QUEUE_ENTRIES-2:0],head_select[QUEUE_ENTRIES-1]};
  always_ff @(posedge clk) begin
    if(rst || redirect) head_select_n<=~QUEUE_ENTRIES'(1);
    else head_select_n<=~(QUEUE_ENTRIES'(1)<<QW'(head+QW'(pop_count)));
  end
`ifndef SYNTHESIS
`ifdef V2_VERIFY
  always_ff @(posedge clk) if(!rst)
    assert(head_select==(QUEUE_ENTRIES'(1)<<head)) else $fatal(1,"fetch head selection mismatch");
`endif
`endif
  logic [QW:0] count;
  logic [1:0] push,raw_push;
  logic [31:0] pc,next_pc;
  logic blocked,next_blocked;
  logic even_read_valid,odd_read_valid;
  logic [CB-4:0] even_read_index,odd_read_index;
  wire [31:0] read_pc=redirect ? redirect_pc:next_pc;
  wire [31:0] read_pc_plus_four=read_pc+4;
  wire [CB-4:0] next_even_index=read_pc[2] ? read_pc_plus_four[CB-1:3]:read_pc[CB-1:3];
  wire [CB-4:0] next_odd_index=read_pc[CB-1:3];
  wire cache_write=!rst && mem_rsp_valid && !mem_rsp_error;
  wire even_write=cache_write && !return_address[2];
  wire odd_write=cache_write && return_address[2];
  logic fill_bypass;
  logic [CB-3:0] fill_bypass_index;
  logic [31:0] fill_bypass_value;
  logic [31:CB] tags [LINES];
  logic [LINES-1:0] tag_valid;
  logic [7:0] valid_words [LINES],failed_words [LINES];
  logic busy;
  logic [31:0] fill_line;
  logic [2:0] critical;
  logic [3:0] issued,returned;
  logic [2:0] send_word,return_word;
  logic [31:0] return_address;
  logic allocate;
  logic [LB-1:0] fetch_line;
  logic line_hit,word_ready[2],word_error[2];
  logic [31:0] fetch_pc[2],fetch_inst[2],prediction[2];
  logic [31:0] even_read,odd_read;
  logic [CB-4:0] even_index,odd_index;
  (* ram_style="registers" *) logic [1:0] bht [BHT_ENTRIES];
  logic [BHT_ENTRIES-1:0] bht_valid;
  (* ram_style="registers" *) logic [29:TW] btb_tag [BTB_ENTRIES];
  (* ram_style="registers" *) logic [29:0] btb_target [BTB_ENTRIES];
  logic [BTB_ENTRIES-1:0] btb_valid;
  logic [1:0] counter[2];
  localparam integer PATTERNS=2**LOCAL_HISTORY_BITS, PREDICTOR_ROWS=BHT_ENTRIES/PATTERNS;
  wire [PREDICTOR_ROWS*2-1:0] predictor_words;
  for(genvar row=0;row<PREDICTOR_ROWS;row=row+1) begin: predictor_columns
    wire [PATTERNS*3-1:0] patterns;
    wire [2:0] pattern;
    for(genvar h=0;h<PATTERNS;h=h+1) begin: outcomes
      assign patterns[h*3+:3]={bht_valid[row*PATTERNS+h],bht[row*PATTERNS+h]};
    end
    if(LOCAL_HISTORY_BITS==0) begin: without_history
      assign pattern=patterns;
    end else begin: with_history
      v2_read #(.WIDTH(3),.ENTRIES(PATTERNS)) history_lookup
        (.index(local_history[row%HISTORY_ENTRIES]),.select('0),.words(patterns),.value(pattern));
    end
    assign predictor_words[row*2+:2]=pattern[2] ? pattern[1:0]:2'd1;
  end
  for(genvar port=0;port<2;port=port+1) begin: predictor_reads
    if(LOCAL_HISTORY_BITS==0 || HISTORY_ENTRIES<=PREDICTOR_ROWS) begin: distributed
      v2_read #(.WIDTH(2),.ENTRIES(PREDICTOR_ROWS)) lookup
        (.index(fetch_pc[port][BW-LOCAL_HISTORY_BITS+1:2]),.select('0),.words(predictor_words),.value(counter[port]));
    end else begin: extended_history
      wire [BHT_ENTRIES*3-1:0] words;
      wire [2:0] value;
      for(genvar row=0;row<BHT_ENTRIES;row=row+1) begin: columns
        assign words[row*3+:3]={bht_valid[row],bht[row]};
      end
      v2_read #(.WIDTH(3),.ENTRIES(BHT_ENTRIES)) lookup
        (.index(fetch_bht[port]),.select('0),.words(words),.value(value));
      assign counter[port]=value[2] ? value[1:0]:2'd1;
    end
  end
  localparam integer BTB_WIDTH=61-TW;
  wire [BTB_ENTRIES*BTB_WIDTH-1:0] btb_words;
  wire [BTB_WIDTH-1:0] btb_read[2];
  for(genvar row=0;row<BTB_ENTRIES;row=row+1) begin: btb_columns
    assign btb_words[row*BTB_WIDTH+:BTB_WIDTH]={btb_valid[row],btb_tag[row],btb_target[row]};
  end
  for(genvar port=0;port<2;port=port+1) begin: btb_reads
    v2_read #(.WIDTH(BTB_WIDTH),.ENTRIES(BTB_ENTRIES)) lookup
      (.index(fetch_pc[port][TW+1:2]),.select('0),.words(btb_words),.value(btb_read[port]));
  end
  logic [31:0] immediate[2];
  localparam integer HI=$clog2(HISTORY_ENTRIES);
  logic [HB-1:0] local_history [HISTORY_ENTRIES];
  logic [HB-1:0] fetch_history [2];
  logic [BW-1:0] fetch_bht [2];
  logic [BW-1:0] train_bht;
  logic [TW-1:0] train_btb;
  logic [BHT_ENTRIES-1:0] counter_up_n,counter_down_n;
  localparam integer TRAIN_ROW_BITS=BW>5 ? 5:BW;
  localparam integer TRAIN_ROWS=2**TRAIN_ROW_BITS,TRAIN_BANKS=BHT_ENTRIES/TRAIN_ROWS;
  logic [TRAIN_BANKS-1:0] train_up_n,train_down_n;
  logic [TRAIN_ROW_BITS-1:0] train_row[TRAIN_BANKS];
  logic [HISTORY_ENTRIES-1:0] history_write_n;
  logic [BTB_ENTRIES-1:0] btb_write_n;
  logic outcome_positive_n;
  logic [29:TW] trained_btb_tag;
  logic [29:0] trained_btb_target;
  wire outcome_positive=~outcome_positive_n;
  always_ff @(posedge clk) if(train_valid) begin
    outcome_positive_n<=!train_taken;
    trained_btb_tag<=train_pc[31:TW+2];trained_btb_target<=train_target[31:2];
  end
  // The resolved branch drives only one small register group per bank.
  // Decode the bank-local row on the following cycle. Counter training is
  // delayed by one cycle, while local history and target training stay unchanged.
  for(genvar bank=0;bank<TRAIN_BANKS;bank=bank+1) begin: training_banks
    wire selected=!rst && train_valid && train_op>=OP_BEQ && train_op<=OP_BGEU &&
                  (train_bht>>TRAIN_ROW_BITS)==BW'(bank);
    always_ff @(posedge clk) begin
      train_up_n[bank]<=!(selected && train_taken);
      train_down_n[bank]<=!(selected && !train_taken);
      if(selected) train_row[bank]<=train_bht[TRAIN_ROW_BITS-1:0];
    end
  end
  for(genvar row=0;row<BHT_ENTRIES;row=row+1) begin: counter_decode
    logic up_n_q,down_n_q;
    assign counter_up_n[row]=up_n_q;
    assign counter_down_n[row]=down_n_q;
    wire selected=!rst && train_row[row/TRAIN_ROWS]==TRAIN_ROW_BITS'(row%TRAIN_ROWS);
    always_ff @(posedge clk) begin
      up_n_q<=!(selected && !train_up_n[row/TRAIN_ROWS]);
      down_n_q<=!(selected && !train_down_n[row/TRAIN_ROWS]);
    end
  end
  for(genvar row=0;row<HISTORY_ENTRIES;row=row+1) begin: history_decode
    logic write_n_q;
    assign history_write_n[row]=write_n_q;
    always_ff @(posedge clk) write_n_q<=!(!rst && LOCAL_HISTORY_BITS>0 && train_valid &&
      train_op>=OP_BEQ && train_op<=OP_BGEU && train_pc[HI+1:2]==HI'(row));
  end
  for(genvar row=0;row<BTB_ENTRIES;row=row+1) begin: target_decode
    logic write_n_q,valid_q;
    logic [29:TW] tag_q;
    logic [29:0] target_q;
    assign btb_write_n[row]=write_n_q;
    assign btb_valid[row]=valid_q;
    assign btb_tag[row]=tag_q;
    assign btb_target[row]=target_q;
    always_ff @(posedge clk) write_n_q<=!(!rst && train_valid && train_op==OP_JALR &&
      train_target<RAM_BYTES && train_target[1:0]==0 && train_btb==TW'(row));
    always_ff @(posedge clk) begin
      if(rst) valid_q<=0;
      else if(!write_n_q) begin
        valid_q<=1;tag_q<=trained_btb_tag;target_q<=trained_btb_target;
      end
    end
  end
  assign train_bht=LOCAL_HISTORY_BITS==0 ? train_pc[BW+1:2]:
    (train_pc[BW+1:2]<<LOCAL_HISTORY_BITS) | BW'(train_history);
  assign train_btb=train_pc[TW+1:2];
  assign fetch_pc[0]=pc;
  assign fetch_pc[1]=pc+4;
  assign even_index=pc[2] ? fetch_pc[1][CB-1:3]:pc[CB-1:3];
  assign odd_index=pc[CB-1:3];
  sram_fakeram #(.DEPTH(CACHE_BYTES/8),.WIDTH(32)) even_ram
    (.clk,.en(!rst),.we(even_write),.wmask(1'b1),
     .addr(even_write ? return_address[CB-1:3]:next_even_index),.wdata(mem_rsp_data),.rdata(even_read));
  sram_fakeram #(.DEPTH(CACHE_BYTES/8),.WIDTH(32)) odd_ram
    (.clk,.en(!rst),.we(odd_write),.wmask(1'b1),
     .addr(odd_write ? return_address[CB-1:3]:next_odd_index),.wdata(mem_rsp_data),.rdata(odd_read));
  always_ff @(posedge clk) begin
    even_read_valid<=!rst && !even_write;odd_read_valid<=!rst && !odd_write;
    even_read_index<=next_even_index;odd_read_index<=next_odd_index;
    fill_bypass<=cache_write;
    if(cache_write) begin fill_bypass_index<=return_address[CB-1:2];fill_bypass_value<=mem_rsp_data;end
  end
  packet_t packet_read[2];
  wire [QUEUE_ENTRIES*$bits(packet_t)-1:0] fifo_words;
  for(genvar row=0;row<QUEUE_ENTRIES;row=row+1) begin: fifo_read_words
    assign fifo_words[row*$bits(packet_t)+:$bits(packet_t)]=fifo[row];
  end
  for(genvar port=0;port<2;port=port+1) begin: fifo_read_ports
    v2_read #(.WIDTH($bits(packet_t)),.ENTRIES(QUEUE_ENTRIES),.ONEHOT(1)) lookup
      (.index(QW'(head+QW'(port))),.select(port==0 ? head_select:second_select),.words(fifo_words),.value(packet_read[port]));
`ifndef SYNTHESIS
`ifdef V2_VERIFY
    always_ff @(posedge clk) if(!rst && int'(count)>port) begin
      if(!packet_read[port].iv)
        assert(packet_read[port].inst==0 && packet_read[port].pred==packet_read[port].pc+4)
          else $fatal(1,"unnormalized fetch fault packet");
      if(!packet_read[port].iv || packet_read[port].inst[6:0]!=7'h63)
        assert(packet_read[port].history==0) else $fatal(1,"history on a non-conditional packet");
      if(!packet_read[port].iv || (packet_read[port].inst[6:0]!=7'h63 &&
         packet_read[port].inst[6:0]!=7'h6f && packet_read[port].inst[6:0]!=7'h67))
        assert(packet_read[port].pred==packet_read[port].pc+4) else $fatal(1,"non-control packet prediction");
    end
`endif
`endif
  end
  assign fetch_inst[0]=(fill_bypass && fill_bypass_index==fetch_pc[0][CB-1:2]) ? fill_bypass_value:
    pc[2] ? odd_read:even_read;
  assign fetch_inst[1]=(fill_bypass && fill_bypass_index==fetch_pc[1][CB-1:2]) ? fill_bypass_value:
    pc[2] ? even_read:odd_read;
  assign fetch_line=pc[CB-1:5];
  assign line_hit=tag_valid[fetch_line] && tags[fetch_line]==pc[31:CB];
  for(genvar p=0;p<2;p=p+1) begin: predict
    assign word_ready[p]=((fill_bypass && fill_bypass_index==fetch_pc[p][CB-1:2]) || (fetch_pc[p][2] ? (odd_read_valid && odd_read_index==odd_index):
      (even_read_valid && even_read_index==even_index))) && line_hit && (valid_words[fetch_line][fetch_pc[p][4:2]] || failed_words[fetch_line][fetch_pc[p][4:2]]);
    assign word_error[p]=failed_words[fetch_line][fetch_pc[p][4:2]];
    assign fetch_history[p]=LOCAL_HISTORY_BITS==0 ? '0:local_history[fetch_pc[p][HI+1:2]];
    assign fetch_bht[p]=LOCAL_HISTORY_BITS==0 ? fetch_pc[p][BW+1:2]:
      (fetch_pc[p][BW+1:2]<<LOCAL_HISTORY_BITS) | BW'(fetch_history[p]);
    always_comb begin
      prediction[p]=fetch_pc[p]+4;
      immediate[p]=0;
      case(fetch_inst[p][6:0])
        7'h6f: begin
          immediate[p]={{11{fetch_inst[p][31]}},fetch_inst[p][31],fetch_inst[p][19:12],fetch_inst[p][20],fetch_inst[p][30:21],1'b0};
          prediction[p]=fetch_pc[p]+immediate[p];
        end
        7'h63: begin
          immediate[p]={{19{fetch_inst[p][31]}},fetch_inst[p][31],fetch_inst[p][7],fetch_inst[p][30:25],fetch_inst[p][11:8],1'b0};
          if(counter[p][1]) prediction[p]=fetch_pc[p]+immediate[p];
        end
        7'h67: if(btb_read[p][BTB_WIDTH-1] && btb_read[p][30+:30-TW]==fetch_pc[p][31:TW+2])
          prediction[p]={btb_read[p][29:0],2'b0};
        default: ;
      endcase
    end
  end
  always_comb begin
    packet_available=0;packet_valid=0;packet_pc=0;packet_inst=0;packet_prediction=0;packet_fault=0;packet_inst_valid=0;packet_history=0;
    for(integer p=0;p<2;p=p+1) begin
      packet_available[p]=int'(count)>p;
      packet_valid[p]=packet_available[p] && !stop && !redirect;
      packet_pc[p*32+:32]=packet_read[p].pc;
      packet_inst[p*32+:32]=packet_read[p].inst;
      packet_prediction[p*32+:32]=packet_read[p].pred;
      packet_fault[p*4+:4]=packet_read[p].fault;
      packet_inst_valid[p]=packet_read[p].iv;
      packet_history[p*HB+:HB]=packet_read[p].history;
    end
  end
  always_comb begin: fetch_next
    raw_push=0;next_pc=pc;next_blocked=blocked;allocate=0;
    for(integer p=0;p<2;p=p+1) begin
      incoming[p]='0;incoming[p].pc=fetch_pc[p];incoming[p].pred=prediction[p];
      incoming[p].history=fetch_history[p];
      incoming[p].inst=fetch_inst[p];incoming[p].iv=1;
    end
    if(int'(count)-int'(pop_count)<QUEUE_ENTRIES) begin
      if(pc[1:0]!=0 || pc>=RAM_BYTES) begin
        incoming[0].fault=pc[1:0]!=0 ? FAULT_FETCH_ALIGN:FAULT_FETCH_RANGE;
        incoming[0].iv=0;incoming[0].inst=0;raw_push=1;next_blocked=1;
      end else if(word_ready[0]) begin
        raw_push=1;next_pc=prediction[0];
        if(word_error[0]) begin
          incoming[0].fault=FAULT_FETCH_BUS;incoming[0].iv=0;incoming[0].inst=0;next_blocked=1;
        end else if(prediction[0]==pc+4 && pc[4:2]!=7 && word_ready[1] &&
                    int'(count)-int'(pop_count)<QUEUE_ENTRIES-1) begin
          raw_push=2;next_pc=prediction[1];
          if(word_error[1]) begin
            incoming[1].fault=FAULT_FETCH_BUS;incoming[1].iv=0;incoming[1].inst=0;next_blocked=1;
          end
        end
      end else if(!busy && (!line_hit ||
        !(valid_words[fetch_line][pc[4:2]] || failed_words[fetch_line][pc[4:2]]))) allocate=!stop && !redirect && !blocked;
    end
    // Store complete normalized packets, so dequeue is just a row read.
    // These adjustments previously sat between the FIFO head and decode.
    for(integer p=0;p<2;p=p+1) begin
      if(!incoming[p].iv) begin
        incoming[p].inst=0;incoming[p].pred=incoming[p].pc+4;
      end
      if(!incoming[p].iv || incoming[p].inst[6:0]!=7'h63) incoming[p].history=0;
    end
  end
  assign push=(!stop && !redirect && !blocked) ? raw_push:2'd0;
  assign send_word=critical+issued[2:0];
  assign return_word=critical+returned[2:0];
  assign return_address=fill_line+{27'b0,return_word,2'b0};
  assign mem_req_valid=!rst && busy && issued<8;
  assign mem_req_addr=fill_line+{27'b0,send_word,2'b0};
  assign mem_rsp_ready=1;
  assign idle=!busy;
  always_ff @(posedge clk) begin
    if(rst) begin
      head<=0;tail<=0;count<=0;pc<=0;blocked<=0;
      busy<=0;issued<=0;returned<=0;critical<=0;fill_line<=0;miss_count<=0;
    end else begin
      if(redirect) begin head<=0;tail<=0;count<=0;pc<=redirect_pc;blocked<=0;end
      else begin
        head<=head+QW'(pop_count);tail<=tail+QW'(push);
        count<=count+(QW+1)'(push)-(QW+1)'(pop_count);
        pc<=next_pc;blocked<=next_blocked;
      end
      if(allocate) begin
        busy<=1;fill_line<={pc[31:5],5'b0};critical<=pc[4:2];issued<=0;returned<=0;
        miss_count<=miss_count+1;
      end
      if(mem_req_valid && mem_req_ready) issued<=issued+1;
      if(mem_rsp_valid) begin
        returned<=returned+1;
        if(returned==7) busy<=0;
      end
    end
  end
  for(genvar row=0;row<QUEUE_ENTRIES;row=row+1) begin: queue_write
    packet_t packet_q;
    assign fifo[row]=packet_q;
    // A free tail slot, or one consumed on this edge, may prepare the full
    // packet before word readiness/prediction decides whether to publish it.
    // The count/tail update still uses push, so unaccepted packets stay hidden.
    always_ff @(posedge clk)
      for(integer p=0;p<2;p=p+1)
        if(int'(count)-int'(pop_count)<QUEUE_ENTRIES-p && QW'(tail+QW'(p))==QW'(row))
          packet_q<=incoming[p];
`ifndef SYNTHESIS
`ifdef V2_VERIFY
    wire [QW-1:0] row_age=QW'(row)-head;
    always_ff @(posedge clk) if(!rst)
      for(integer p=0;p<2;p=p+1)
        if(int'(count)-int'(pop_count)<QUEUE_ENTRIES-p && QW'(tail+QW'(p))==QW'(row))
          assert(int'(row_age)>=int'(count) || int'(row_age)<int'(pop_count))
            else $fatal(1,"fetch preparation overwrote an unread packet");
`endif
`endif
  end
  for(genvar row=0;row<LINES;row=row+1) begin: tag_write
    logic valid_q;
    logic [31:CB] tag_q;
    logic [7:0] words_q,failed_q;
    assign tag_valid[row]=valid_q;
    assign tags[row]=tag_q;
    assign valid_words[row]=words_q;
    assign failed_words[row]=failed_q;
    logic [7:0] valid_next,failed_next;
    always_comb begin
      valid_next=words_q;failed_next=failed_q;
      if(allocate && fetch_line==LB'(row)) begin valid_next=0;failed_next=0;end
      if(mem_rsp_valid && fill_line[CB-1:5]==LB'(row)) begin
        valid_next[return_word]=!mem_rsp_error;failed_next[return_word]=mem_rsp_error;
      end
    end
    always_ff @(posedge clk) begin
      if(rst) valid_q<=0;
      else begin
        words_q<=valid_next;failed_q<=failed_next;
        if(allocate && fetch_line==LB'(row)) begin
          valid_q<=1;tag_q<=pc[31:CB];
        end
      end
    end
  end
  for(genvar row=0;row<BHT_ENTRIES;row=row+1) begin: counter_write
    logic valid_q;
    logic [1:0] counter_q;
    assign bht_valid[row]=valid_q;
    assign bht[row]=counter_q;
    wire [1:0] previous=valid_q ? counter_q:2'd1;
    always_ff @(posedge clk) begin
      if(rst) valid_q<=0;
      else if(!counter_up_n[row] || !counter_down_n[row]) begin
        valid_q<=1;
        counter_q<=((previous==3 ? 2'd3:previous+2'd1) & {2{!counter_up_n[row]}}) |
                  ((previous==0 ? 2'd0:previous-2'd1) & {2{!counter_down_n[row]}});
      end
    end
  end
  // Resolved local outcomes select a separate counter per recent pattern.
  // Carry the lookup history through the pipeline so training updates exactly
  // the counter used at fetch, even when another branch has since resolved.
  for(genvar h=0;h<HISTORY_ENTRIES;h=h+1) begin: history_write
    logic [HB-1:0] history_q;
    assign local_history[h]=history_q;
    always_ff @(posedge clk) begin
      if(rst) history_q<='0;
      else if(!history_write_n[h]) history_q<=(history_q<<1) | HB'(outcome_positive);
    end
  end
  initial begin
    if(LOCAL_HISTORY_BITS<0 || LOCAL_HISTORY_BITS>=BW || HISTORY_ENTRIES<2 ||
       (HISTORY_ENTRIES&(HISTORY_ENTRIES-1))!=0) $fatal(1,"invalid local predictor dimensions");
    if(CACHE_BYTES<64 || (CACHE_BYTES&(CACHE_BYTES-1))!=0 || QUEUE_ENTRIES<2 || (QUEUE_ENTRIES&(QUEUE_ENTRIES-1))!=0)
      $fatal(1,"invalid frontend dimensions");
  end
endmodule
