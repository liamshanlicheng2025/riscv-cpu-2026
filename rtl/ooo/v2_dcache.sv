// One/two-way, write-through / no-write-allocate, critical-word-first cache.
// Word-interleaved single-port SRAM banks. A read can overlap a fill or
// Store write in the other bank; miss and response ownership stay independent.
module v2_dcache #(
  parameter integer CACHE_BYTES=2048, LINE_BYTES=64, WAYS=2, DATA_BANKS=4, MSHRS=4, LOAD_SLOTS=8, STORE_SLOTS=16,
  parameter integer CREDITS=64, RAM_BYTES=268435456,
  parameter integer LT=$clog2(LOAD_SLOTS), ST=$clog2(STORE_SLOTS)
)(
  input logic clk,rst,
  input logic load_valid,
  input logic [31:0] load_address,
  input logic [LT-1:0] load_tag,
  output logic load_ready,load_hit,
  output logic [31:0] load_data,
  output logic result_valid,
  input logic result_ready,
  output logic [LT-1:0] result_tag,
  output logic [31:0] result_data,
  output logic result_error,
  input logic store_valid,
  output logic store_ready,
  input logic [31:0] store_address,store_data,
  input logic [3:0] store_mask,
  input logic [ST-1:0] store_tag,
  output logic store_done,store_error,
  output logic [ST-1:0] store_done_tag,
  output logic mem_req_valid,mem_req_write,
  input logic mem_req_ready,
  output logic [31:0] mem_req_addr,mem_req_data,
  output logic [3:0] mem_req_mask,
  input logic mem_rsp_valid,
  output logic mem_rsp_ready,
  input logic [31:0] mem_rsp_data,
  input logic mem_rsp_error,
  output logic idle,
  output logic [63:0] miss_count
);
  localparam integer OFFSET=$clog2(LINE_BYTES), WORDS=LINE_BYTES/4, WW=OFFSET-2;
  localparam integer SETS=CACHE_BYTES/(WAYS*LINE_BYTES), SB=$clog2(SETS), LB=$clog2(CACHE_BYTES/LINE_BYTES), LINES=WAYS*SETS;
  localparam integer RB=$clog2(RAM_BYTES), TB=RB-SB-OFFSET, MB=$clog2(MSHRS);
  localparam integer FW=$clog2(CREDITS);
  localparam integer BANK_BITS=$clog2(DATA_BANKS), BW=BANK_BITS>0 ? BANK_BITS:1;
  localparam logic [BW-1:0] BANK_MASK=BW'(DATA_BANKS-1);
  typedef struct packed {
    logic valid;
    logic [LB-1:0] physical;
    logic [RB-OFFSET-1:0] address;
    logic [WW-1:0] critical;
    logic [WW:0] issued,returned;
    logic [WORDS-1:0] failed;
  } miss_t;
  typedef struct packed {logic valid,error;logic [LB-1:0] physical;logic [WW-1:0] word_index;} waiter_t;
  typedef struct packed {logic write;logic [ST-1:0] tag;logic [MB-1:0] slot;logic [WW-1:0] word_index;} owner_t;
  miss_t misses [MSHRS];
  waiter_t waiters [LOAD_SLOTS];
  owner_t owners [CREDITS],out_owner;
  logic [FW-1:0] head,tail;
  logic [FW:0] count;
  logic out_valid;
  logic [31:0] out_store_address,out_fill_address,out_data;
  logic [3:0] out_mask;
  wire [31:0] read_word;
  wire [31:0] bank_word[DATA_BANKS];
  logic [BW-1:0] read_bank;
  logic read_result_valid,read_result_error;
  logic [LT-1:0] read_result_tag;
  logic waiter_valid,waiter_error,waiter_issue,read_issue;
  logic [LT-1:0] waiter_tag,read_tag;
  logic read_error,lookup_hit;
  logic fill_waiter_valid,read_result_bypass;
  logic [LT-1:0] fill_waiter_tag;
  logic [31:0] read_result_value;
  logic [TB-1:0] tags [LINES];
  logic [LINES-1:0] tag_valid;
  logic [WORDS-1:0] word_valid [LINES];
  logic [SETS-1:0] replacement;
  logic [LINES-1:0] locked;
  logic [SB-1:0] load_set,store_set;
  logic [LB-1:0] load_line,store_line,selected_line;
  logic load_tag_hit,store_tag_hit;
  logic [1:0] load_matches,store_matches;
  logic victim_valid,free_valid,merge_valid,allocate;
  logic [MB-1:0] free_slot,merge_slot,selected_slot,send_slot;
  logic send_valid,send_fill,load_accept,store_accept,request_fire,response_fire,out_space;
  logic [MB-1:0] round_robin;
  logic [WW-1:0] send_word;
  logic [LB-1:0] response_line;
  logic [WW-1:0] response_word;
  logic fill_fire,data_write_valid;
  wire store_cache_request=!rst && store_valid && store_tag_hit && out_space &&
    int'(count)<CREDITS-1 && !fill_fire && !locked[store_line];
  wire [BW-1:0] load_bank=load_address[BW+1:2]&BANK_MASK;
  wire [BW-1:0] store_bank=store_address[BW+1:2]&BANK_MASK;
  wire [BW-1:0] fill_bank=response_word[BW-1:0]&BANK_MASK;
  wire load_bank_busy=(fill_fire && !mem_rsp_error && fill_bank==load_bank) ||
                     (store_cache_request && store_bank==load_bank);
  logic [LB+WW-1:0] data_write_address,data_read_address;
  logic [31:0] data_write_value;
  logic [3:0] data_write_mask;
  logic [MSHRS-1:0] release_miss;
  owner_t response_owner,following_owner;
  wire [(CREDITS)*$bits(owner_t)-1:0] owners_words;
  for(genvar row=0;row<CREDITS;row=row+1) begin: pack_owners
    assign owners_words[row*$bits(owner_t)+:$bits(owner_t)]=owners[row];
  end
  v2_read #(.WIDTH($bits(owner_t)),.ENTRIES(CREDITS)) read_owners
    (.index(FW'(head+1'b1)),.select('0),.words(owners_words),.value(following_owner));
  waiter_t result_waiter;
  wire [(LOAD_SLOTS)*$bits(waiter_t)-1:0] waiters_words;
  for(genvar row=0;row<LOAD_SLOTS;row=row+1) begin: pack_waiters
    assign waiters_words[row*$bits(waiter_t)+:$bits(waiter_t)]=waiters[row];
  end
  v2_read #(.WIDTH($bits(waiter_t)),.ENTRIES(LOAD_SLOTS)) read_waiters
    (.index(waiter_tag),.select('0),.words(waiters_words),.value(result_waiter));
  assign load_set=load_address[SB+OFFSET-1:OFFSET];
  assign store_set=store_address[SB+OFFSET-1:OFFSET];
  wire [LINES*WORDS-1:0] valid_words_flat;
  for(genvar row=0;row<LINES;row=row+1) begin: valid_columns
    assign valid_words_flat[row*WORDS+:WORDS]=word_valid[row];
  end
  wire load_word_present;
  wire [WORDS-1:0] load_line_words;
  // Select the line metadata first, then its word bit. This bounds the
  // late word-index fanout and avoids a full cache-wide bit decoder per
  // Load/waiter. It also keeps simulation operations at native word widths.
  v2_read #(.WIDTH(WORDS),.ENTRIES(LINES)) load_line_lookup
    (.index(load_line),.select('0),.words(valid_words_flat),.value(load_line_words));
  assign load_word_present=load_line_words[load_address[OFFSET-1:2]];
  wire [LOAD_SLOTS-1:0] waiter_word_present;
  for(genvar w=0;w<LOAD_SLOTS;w=w+1) begin: waiter_word_lookup
    wire [WORDS-1:0] line_words;
    v2_read #(.WIDTH(WORDS),.ENTRIES(LINES)) lookup
      (.index(waiters[w].physical),.select('0),.words(valid_words_flat),.value(line_words));
    assign waiter_word_present[w]=line_words[waiters[w].word_index];
  end
  for(genvar way=0;way<2;way=way+1) begin: tag_read
    if(way<WAYS) begin: active
    wire [SETS*(TB+1)-1:0] tag_words;
    wire [TB:0] load_metadata,store_metadata;
    for(genvar set_index=0;set_index<SETS;set_index=set_index+1) begin: columns
      assign tag_words[set_index*(TB+1)+:(TB+1)]={tag_valid[set_index*WAYS+way],tags[set_index*WAYS+way]};
    end
    v2_read #(.WIDTH(TB+1),.ENTRIES(SETS)) load_lookup
      (.index(load_set),.select('0),.words(tag_words),.value(load_metadata));
    v2_read #(.WIDTH(TB+1),.ENTRIES(SETS)) store_lookup
      (.index(store_set),.select('0),.words(tag_words),.value(store_metadata));
    assign load_matches[way]=load_metadata[TB] && load_metadata[TB-1:0]==load_address[RB-1:SB+OFFSET];
    assign store_matches[way]=store_metadata[TB] && store_metadata[TB-1:0]==store_address[RB-1:SB+OFFSET];
    end else begin: inactive
      assign load_matches[way]=0;
      assign store_matches[way]=0;
    end
  end
  assign load_tag_hit=|load_matches;
  assign store_tag_hit=|store_matches;
  assign load_line=WAYS==1 ? LB'(load_set):{load_set,!load_matches[0]};
  assign store_line=WAYS==1 ? LB'(store_set):{store_set,!store_matches[0]};
  assign lookup_hit=load_tag_hit && load_word_present;
  assign load_hit=0;
  assign result_valid=read_result_valid;
  assign result_tag=read_result_tag;
  assign result_error=read_result_error;
  assign mem_req_valid=!rst && out_valid && int'(count)<CREDITS;
  assign mem_req_write=out_owner.write;
  assign mem_req_addr=out_owner.write ? out_store_address:out_fill_address;
  assign mem_req_data=out_owner.write ? out_data:32'd0;
  assign mem_req_mask=out_owner.write ? out_mask:4'd0;
  assign request_fire=mem_req_valid && mem_req_ready;
  assign mem_rsp_ready=1;
  assign response_fire=mem_rsp_valid && count!=0;
  assign response_line=misses[response_owner.slot].physical;
  assign response_word=response_owner.word_index;
  assign fill_fire=response_fire && !response_owner.write;
  assign store_done=response_fire && response_owner.write;
  assign store_done_tag=response_owner.tag;
  assign store_error=store_done && mem_rsp_error;
  assign out_space=!out_valid || request_fire;
  always_comb begin: returning_load
    waiter_valid=0;waiter_tag=0;waiter_error=0;
    fill_waiter_valid=0;fill_waiter_tag=0;
    for(integer w=0;w<LOAD_SLOTS;w=w+1) begin
      if(!waiter_valid && waiters[w].valid &&
          (waiters[w].error || waiter_word_present[w])) begin
        waiter_valid=1;waiter_tag=LT'(w);waiter_error=waiters[w].error;
      end
      if(!fill_waiter_valid && fill_fire && waiters[w].valid &&
          waiters[w].physical==response_line && waiters[w].word_index==response_word) begin
        fill_waiter_valid=1;fill_waiter_tag=LT'(w);
      end
    end
    if(rst) begin waiter_valid=0;fill_waiter_valid=0;end
  end
  always_comb begin: locked_lines
    locked=0;
    for(integer m=0;m<MSHRS;m=m+1)
      if(misses[m].valid) locked[misses[m].physical]=1;
  end
  always_comb begin
    free_valid=0;free_slot=0;merge_valid=0;merge_slot=0;
    release_miss=0;
    for(integer m=0;m<MSHRS;m=m+1) begin
      if(misses[m].valid) begin
        if(load_tag_hit && misses[m].physical==load_line) begin merge_valid=1;merge_slot=MB'(m);end
        release_miss[m]=misses[m].returned==(WW+1)'(WORDS);
        for(integer w=0;w<LOAD_SLOTS;w=w+1)
          if(waiters[w].valid && waiters[w].physical==misses[m].physical) release_miss[m]=0;
      end else if(!free_valid) begin free_valid=1;free_slot=MB'(m);end
    end
    selected_line=load_line;victim_valid=load_tag_hit;
    if(!load_tag_hit) begin
      if(WAYS==1) begin
        selected_line=LB'(load_set);victim_valid=!locked[LB'(load_set)];
      end else begin
      if(!tag_valid[{load_set,1'b0}] && !locked[{load_set,1'b0}]) begin selected_line={load_set,1'b0};victim_valid=1;end
      else if(!tag_valid[{load_set,1'b1}] && !locked[{load_set,1'b1}]) begin selected_line={load_set,1'b1};victim_valid=1;end
      else if(!locked[{load_set,replacement[load_set]}]) begin selected_line={load_set,replacement[load_set]};victim_valid=1;end
      else if(!locked[{load_set,!replacement[load_set]}]) begin selected_line={load_set,!replacement[load_set]};victim_valid=1;end
      end
    end
    selected_slot=merge_valid ? merge_slot:free_slot;
    load_ready=!rst && !waiters[load_tag].valid &&
      (lookup_hit ? (!waiter_valid && !fill_waiter_valid && !load_bank_busy):(merge_valid || (free_valid && victim_valid)));
    load_accept=load_valid && load_ready;
    allocate=load_accept && !lookup_hit && !merge_valid;
    store_ready=!rst && out_space && int'(count)<CREDITS-1 && !fill_fire &&
                (!store_tag_hit || !locked[store_line]) &&
                !(allocate && store_tag_hit && selected_line==store_line);
    store_accept=store_valid && store_ready;
    send_valid=0;send_slot=0;
    for(integer offset=0;offset<MSHRS;offset=offset+1)
      if(!send_valid && misses[MB'(round_robin+MB'(offset))].valid &&
           misses[MB'(round_robin+MB'(offset))].issued<(WW+1)'(WORDS)) begin
        send_valid=1;send_slot=MB'(round_robin+MB'(offset));
      end
    send_fill=!rst && out_space && int'(count)<CREDITS-1 && !store_accept && send_valid;
    send_word=misses[send_slot].critical+misses[send_slot].issued[WW-1:0];
    data_write_valid=0;data_write_address=0;data_write_value=0;data_write_mask=0;
    if(fill_fire && !mem_rsp_error) begin
      data_write_valid=1;data_write_address={response_line,response_word};
      data_write_value=mem_rsp_data;data_write_mask=15;
    end else if(store_accept && store_tag_hit) begin
      data_write_valid=1;data_write_address={store_line,store_address[OFFSET-1:2]};
      data_write_value=store_data;data_write_mask=store_mask;
    end
    data_read_address=waiter_valid ? {result_waiter.physical,result_waiter.word_index}:
                                     {load_line,load_address[OFFSET-1:2]};
  end
  always_comb begin: quiescent_state
    idle=!out_valid && count==0 && !read_result_valid;
    for(integer m=0;m<MSHRS;m=m+1) if(misses[m].valid) idle=0;
    for(integer w=0;w<LOAD_SLOTS;w=w+1) if(waiters[w].valid) idle=0;
  end
  assign waiter_issue=fill_waiter_valid || (waiter_valid && (waiter_error ||
    !data_write_valid || (data_write_address[BW-1:0]&BANK_MASK)!=(data_read_address[BW-1:0]&BANK_MASK)));
  assign read_issue=waiter_issue || (load_accept && lookup_hit);
  assign read_tag=fill_waiter_valid ? fill_waiter_tag:waiter_issue ? waiter_tag:load_tag;
  assign read_error=fill_waiter_valid ? mem_rsp_error:(waiter_issue && waiter_error);
  assign load_data=32'd0;
  assign result_data=read_result_error ? 32'd0:read_result_bypass ? read_result_value:read_word;
  for(genvar bank=0;bank<DATA_BANKS;bank=bank+1) begin: data_banks
    wire write_bank=data_write_valid && (data_write_address[BW-1:0]&BANK_MASK)==BW'(bank);
    wire read_this_bank=read_issue && !read_error && !fill_waiter_valid && (data_read_address[BW-1:0]&BANK_MASK)==BW'(bank);
    sram_fakeram #(.DEPTH(CACHE_BYTES/(4*DATA_BANKS)),.WIDTH(32),.WRITE_GRANULARITY(8)) data_ram
      (.clk,.en(!rst && (write_bank || read_this_bank)),.we(write_bank),
       .wmask(data_write_mask),.addr(write_bank ? data_write_address[LB+WW-1:BANK_BITS]:data_read_address[LB+WW-1:BANK_BITS]),
       .wdata(data_write_value),.rdata(bank_word[bank]));
`ifndef SYNTHESIS
    always_ff @(posedge clk) if(!rst)
      assert(!(write_bank && read_this_bank)) else $fatal(1,"cache SRAM bank conflict");
`endif
  end
  assign read_word=bank_word[read_bank];
  always_ff @(posedge clk) begin
    read_result_valid<=!rst && read_issue;
    if(read_issue) begin
      read_bank<=data_read_address[BW-1:0]&BANK_MASK;
      read_result_tag<=read_tag;read_result_error<=read_error;read_result_bypass<=fill_waiter_valid;
      if(fill_waiter_valid) read_result_value<=mem_rsp_data;
    end
  end
  always_ff @(posedge clk) begin
    if(rst) begin
      head<=0;tail<=0;count<=0;out_valid<=0;out_owner<='0;
      response_owner<='0;
      out_store_address<=0;out_fill_address<=0;out_data<=0;out_mask<=0;round_robin<=0;miss_count<=0;
    end else begin
      if(request_fire && (count==0 || (response_fire && count==1))) response_owner<=out_owner;
      else if(response_fire) response_owner<=following_owner;
      case({request_fire,response_fire})
        2'b10:count<=count+1;
        2'b01:count<=count-1;
        default:;
      endcase
      if(request_fire) begin owners[tail]<=out_owner;tail<=tail+1'b1;out_valid<=0;end
      if(response_fire) head<=head+1'b1;
      // Prepare both request classes while the output slot is free. Only
      // valid and the one-bit class depend on the late store/fill grant.
      // A blocked published request keeps every field stable.
      if(out_space) begin
        out_owner.write<=store_accept;
        out_owner.tag<=store_tag;out_owner.slot<=send_slot;out_owner.word_index<=send_word;
        out_store_address<=store_address;
        out_fill_address<={{(32-RB){1'b0}},misses[send_slot].address,send_word,2'b0};
        out_data<=store_data;out_mask<=store_mask;
      end
      if(store_accept) begin
        out_valid<=1;
      end else if(send_fill) begin
        out_valid<=1;round_robin<=send_slot+1'b1;
      end
      if(allocate && !load_tag_hit) miss_count<=miss_count+1;
    end
  end
`ifndef SYNTHESIS
  always_ff @(posedge clk) if(!rst && count!=0)
    assert(response_owner==owners[head]) else $fatal(1,"cache response owner mismatch");
`endif
  for(genvar m=0;m<MSHRS;m=m+1) begin: miss_rows
    logic row_valid_q;
    logic [LB-1:0] row_physical_q;
    logic [RB-OFFSET-1:0] row_address_q;
    logic [WW-1:0] row_critical_q;
    logic [WW:0] row_issued_q;
    logic [WW:0] row_returned_q;
    logic [WORDS-1:0] row_failed_q;
    assign misses[m]={row_valid_q,row_physical_q,row_address_q,row_critical_q,row_issued_q,row_returned_q,row_failed_q};
    always_ff @(posedge clk) begin
      if(rst) begin row_valid_q<='0;row_physical_q<='0;row_address_q<='0;row_critical_q<='0;row_issued_q<='0;row_returned_q<='0;row_failed_q<='0; end
      else begin
        if(release_miss[m]) row_valid_q<=0;
        if(send_fill && send_slot==MB'(m)) row_issued_q<=row_issued_q+1;
        if(fill_fire && response_owner.slot==MB'(m)) begin
          row_returned_q<=row_returned_q+1;
          if(mem_rsp_error) row_failed_q[response_word]<=1;
        end
        if(allocate && free_slot==MB'(m)) begin
          row_valid_q<=1;row_physical_q<=selected_line;
          row_address_q<=load_address[RB-1:OFFSET];row_critical_q<=load_address[OFFSET-1:2];
          row_issued_q<=0;row_returned_q<=0;row_failed_q<=0;
        end
      end
    end
  end
  for(genvar w=0;w<LOAD_SLOTS;w=w+1) begin: waiter_rows
    logic row_valid_q;
    logic row_error_q;
    logic [LB-1:0] row_physical_q;
    logic [WW-1:0] row_word_index_q;
    assign waiters[w]={row_valid_q,row_error_q,row_physical_q,row_word_index_q};
    always_ff @(posedge clk) begin
      if(rst) begin row_valid_q<='0;row_error_q<='0;row_physical_q<='0;row_word_index_q<='0; end
      else begin
        if(waiter_issue && read_tag==LT'(w)) row_valid_q<=0;
        if(fill_fire && mem_rsp_error && row_valid_q && row_physical_q==response_line &&
            row_word_index_q==response_word) row_error_q<=1;
        if(load_accept && !lookup_hit && load_tag==LT'(w)) begin
          row_valid_q<=1;row_physical_q<=selected_line;row_word_index_q<=load_address[OFFSET-1:2];
          row_error_q<=(merge_valid && misses[merge_slot].failed[load_address[OFFSET-1:2]]) ||
            (fill_fire && mem_rsp_error && response_line==selected_line && response_word==load_address[OFFSET-1:2]);
        end
      end
    end
  end
  for(genvar line=0;line<LINES;line=line+1) begin: metadata
    logic valid_q;
    logic [TB-1:0] tag_q;
    logic [WORDS-1:0] words_q;
    assign tag_valid[line]=valid_q;
    assign tags[line]=tag_q;
    assign word_valid[line]=words_q;
    logic [WORDS-1:0] valid_next;
    always_comb begin
      valid_next=words_q;
      if(allocate && !load_tag_hit && selected_line==LB'(line)) valid_next=0;
      if(fill_fire && response_line==LB'(line)) valid_next[response_word]=!mem_rsp_error;
      if(store_accept && store_tag_hit && store_line==LB'(line) && store_mask==15)
        valid_next[store_address[OFFSET-1:2]]=1;
    end
    always_ff @(posedge clk) begin
      if(rst) begin valid_q<=0;words_q<=0;end
      else begin
        words_q<=valid_next;
        if(allocate && !load_tag_hit && selected_line==LB'(line)) begin
          valid_q<=1;tag_q<=load_address[RB-1:SB+OFFSET];
        end
      end
    end
  end
  for(genvar set_index=0;set_index<SETS;set_index=set_index+1) begin: lru
    logic way_q;
    assign replacement[set_index]=way_q;
    always_ff @(posedge clk) begin
      if(rst || WAYS==1) way_q<=0;
      else begin
        if(load_accept && load_set==SB'(set_index)) way_q<=!selected_line[0];
        if(store_accept && store_tag_hit && store_set==SB'(set_index)) way_q<=!store_line[0];
      end
    end
  end
  initial begin
    if(WAYS!=1 && WAYS!=2) $fatal(1,"cache ways must be 1 or 2");
    if(DATA_BANKS<1 || DATA_BANKS>WORDS || (DATA_BANKS&(DATA_BANKS-1))!=0)
      $fatal(1,"invalid cache bank count");
    if(LINE_BYTES<16 || (LINE_BYTES&(LINE_BYTES-1))!=0 || CACHE_BYTES<4*LINE_BYTES || (CACHE_BYTES&(CACHE_BYTES-1))!=0 || MSHRS<2 || (MSHRS&(MSHRS-1))!=0 ||
       CREDITS<2 || (CREDITS&(CREDITS-1))!=0) $fatal(1,"invalid cache dimensions");
  end
endmodule
