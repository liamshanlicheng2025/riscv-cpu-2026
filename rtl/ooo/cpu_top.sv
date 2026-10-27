module cpu_top #(
  parameter integer ROB_ENTRIES=16, IQ_ENTRIES=2, LOAD_SLOTS=8, STORE_SLOTS=16,
  parameter integer CHECKPOINTS=4, RENAME_WIDTH=2, COMMIT_WIDTH=2, INTEGER_PORTS=2,
  parameter integer ICACHE_BYTES=1024, DCACHE_BYTES=4096, DCACHE_WAYS=2, DCACHE_LINE_BYTES=128, DCACHE_BANKS=4, D_MSHRS=4,
  parameter integer FETCH_QUEUE_ENTRIES=4, BHT_ENTRIES=128, BTB_ENTRIES=32, LOCAL_HISTORY_BITS=1, HISTORY_ENTRIES=64,
  parameter integer MAX_MEM_OUTSTANDING=64, RAM_BYTES=268435456, DIV_STEP_BITS=2, DIV_CACHE_ENABLE=1, LSU_PIPELINE=0
) (
  input logic clk, rst,
  output logic mem_req_valid, mem_req_write,
  output logic [31:0] mem_req_addr, mem_req_wdata,
  output logic [3:0] mem_req_wstrb,
  input logic mem_req_ready,
  input logic mem_rsp_valid,
  input logic [31:0] mem_rsp_rdata,
  input logic mem_rsp_error,
  output logic mem_rsp_ready,
  output logic halted, faulted,
  output logic [31:0] fault_pc, fault_inst,
  output logic fault_inst_valid,
  output logic [3:0] fault_cause,
  output logic [31:0] fault_addr,
  output logic [3:0] retire_valid,
  output logic [127:0] retire_pc, retire_inst,
  output logic [19:0] retire_rd,
  output logic [127:0] retire_value,
  output logic [3:0] retire_store,
  output logic [127:0] retire_addr, retire_wdata,
  output logic [15:0] retire_wstrb,
  output logic [63:0] cycle_count, retired_count, branch_miss_count, load_replay_count,
  output logic [63:0] icache_miss_count, dcache_miss_count
);
  import cpu_pkg::*;
  localparam integer HB=LOCAL_HISTORY_BITS>0 ? LOCAL_HISTORY_BITS:1;
  localparam integer RW=$clog2(ROB_ENTRIES), QW=$clog2(IQ_ENTRIES);
  localparam integer LT=$clog2(LOAD_SLOTS), ST=$clog2(STORE_SLOTS), CPW=$clog2(CHECKPOINTS);
  typedef logic [RW-1:0] rid_t;
  typedef struct packed {
    logic valid,done,iv,store,exiting;
    logic [4:0] rd;
    logic [3:0] fault;
    logic [ST-1:0] store_slot;
    logic [3:0] mask;
    logic [31:0] pc,inst,fault_address,address,wdata;
  } rob_t;
  typedef struct packed {
    logic valid,ready_a,ready_b,use_imm,sign_extend;
    rid_t rid,source_a,source_b;
    op_t op;
    logic [29:0] pc,prediction;
    logic [HB-1:0] history;
    logic [1:0] size;
    logic [CPW-1:0] checkpoint;
    // Keep full words aligned in the packed simulation representation too.
    logic [31:0] a,b,imm;
  } issue_t;
  typedef struct packed {
    logic valid,committed,issued,done;
    rid_t rid;
    logic [3:0] mask;
    logic [31:0] address,data,pc,inst;
  } store_t;
  typedef struct packed {
    logic valid,canceled,sign_extend;
    rid_t rid;
    logic [1:0] size;
    logic [31:0] address;
  } load_t;
  typedef enum logic [1:0] {RUN,DRAIN,DONE,FAULT} state_t;
  (* keep *) state_t state;
  // The run permission is stored directly. Decoding the two-bit terminal
  // state into every issue, rename and queue enable creates one large net.
  (* keep *) logic stopped;
  always_ff @(posedge clk) begin
    if(rst) stopped<=0;
    else if(exit_head || fault_head || cache_store_error) stopped<=1;
  end
  rob_t rob [ROB_ENTRIES];
  logic [31:0] values [ROB_ENTRIES],architectural [32];
  issue_t queue [3][IQ_ENTRIES],dispatch_payload[2];
  store_t stores [STORE_SLOTS];
  load_t loads [LOAD_SLOTS];
  (* keep *) rid_t head,tail;
  (* keep *) rid_t second_head;
  logic [ROB_ENTRIES-1:0] head_prefix;
  logic [ROB_ENTRIES-1:0] head_select_n;
  wire [ROB_ENTRIES-1:0] head_select=~head_select_n;
  wire [ROB_ENTRIES-1:0] second_select={head_select[ROB_ENTRIES-2:0],head_select[ROB_ENTRIES-1]};
  always_ff @(posedge clk) begin
    if(rst) head_select_n<=~ROB_ENTRIES'(1);
    else head_select_n<=~(ROB_ENTRIES'(1)<<next_head);
  end
  wire [RW-1:0] next_head=head+rid_t'(commit_count);
  always_ff @(posedge clk) begin
    if(rst) second_head<=1;
    else second_head<=next_head+1'b1;
  end
  for(genvar row=0;row<ROB_ENTRIES;row=row+1) begin: head_decode
    if(row==ROB_ENTRIES-1) begin: last_slot
      always_ff @(posedge clk) head_prefix[row]<=0;
    end else begin: prefix_state
      always_ff @(posedge clk) begin
        if(rst) head_prefix[row]<=0;
        else head_prefix[row]<=rid_t'(row)<next_head;
      end
    end
  end
  (* keep *) logic [RW:0] rob_count;
  wire [RW:0] next_rob_count=redirect ?
    (RW+1)'(age(redirect_rid))+1-(RW+1)'(commit_count):
    rob_count+(RW+1)'(dispatch_count)-(RW+1)'(commit_count);
  logic [1:0] dispatch_full;
  for(genvar lane=0;lane<2;lane=lane+1) begin: dispatch_credits
    always_ff @(posedge clk) begin
      if(rst) dispatch_full[lane]<=0;
      else dispatch_full[lane]<=int'(next_rob_count)>=ROB_ENTRIES-lane;
    end
  end
  logic [ST-1:0] store_head,store_tail;
  logic [ST:0] store_count;
  logic [CHECKPOINTS-1:0] checkpoint_valid;
  rid_t checkpoint_owner [CHECKPOINTS];
  logic [CPW-1:0] free_checkpoint;
  logic checkpoint_available;
  logic [1:0] fetch_valid,fetch_available,fetch_iv,pop_count;
  logic [63:0] fetch_pc,fetch_inst,fetch_prediction;
  logic [7:0] fetch_fault;
  logic [2*HB-1:0] fetch_history;
  decoded_t decoded [2];
  logic frontend_idle,stop_frontend,redirect,flush_all,exit_head,fault_head;
  wire frontend_redirect;
  // Independent recovery state for the front end bounds redirect fanout.
  // Preserve this RTL register boundary through the normal course synthesis.
  (* keep_hierarchy *) ooo_recovery_flag frontend_recovery (
    .clk(clk),.clear(rst || flush_all),.candidate(redirect_candidate),.active(frontend_redirect));
  logic [ROB_ENTRIES-1:0] redirect_kill;
  logic [31:0] redirect_pc;
  rid_t redirect_rid;
  logic [CPW-1:0] redirect_checkpoint;
  logic train_valid,train_taken;
  op_t train_op;
  logic [31:0] train_pc,train_target;
  logic [1:0] client_req_valid,client_req_ready,client_req_write,client_rsp_valid,client_rsp_ready,client_rsp_error;
  logic [63:0] client_req_addr,client_req_data,client_rsp_data;
  logic [7:0] client_req_mask;
  logic bus_req_valid,bus_req_ready,bus_req_write,bus_rsp_ready,controller_idle;
  logic [31:0] bus_req_addr,bus_req_data;
  logic [3:0] bus_req_mask;
  logic cache_idle,cache_load_valid,cache_load_ready,cache_load_hit;
  logic [31:0] cache_load_address,cache_load_data;
  logic [LT-1:0] cache_load_tag,cache_result_tag;
  logic cache_result_valid,cache_result_error;
  logic [31:0] cache_result_data;
  logic cache_store_valid,cache_store_ready,cache_store_done,cache_store_error;
  logic [ST-1:0] cache_store_tag,cache_store_done_tag;
  logic [31:0] cache_store_address,cache_store_data;
  logic [3:0] cache_store_mask;
  logic [1:0] rename_valid,commit_valid;
  logic [9:0] rename_rd,commit_rd;
  logic [2*RW-1:0] rename_slot,commit_slot;
  logic [19:0] source_register;
  logic [3:0] source_pending;
  logic [4*RW-1:0] source_slot;
  logic save_checkpoint,save_after_lane;
  logic [1:0] dispatch_valid,dispatch_prepare,rename_prepare;
  logic [1:0] dispatch_bank [2];
  logic [QW-1:0] dispatch_index [2];
  rid_t dispatch_rid [2],commit_rid [2];
  logic [1:0] dispatch_count,commit_count;
  logic [2:0] used_bank;
  logic [2:0] free_queue_valid;
  logic [QW-1:0] free_queue [3],selected [3];
  logic [QW:0] occupancy [3];
  // Memory operations issue in order. Keep their physical slots in FIFO
  // order too, so selecting the oldest does not need a ROB-age tournament.
  logic [QW-1:0] memory_head,memory_tail;
  logic [IQ_ENTRIES-1:0] memory_head_select;
  logic [QW:0] memory_count,memory_survivors;
  wire memory_push=(dispatch_valid[0] && dispatch_bank[0]==2) ||
                   (dispatch_valid[1] && dispatch_bank[1]==2);
  logic [2:0] select_valid,issue_fire;
  logic [2:0] selected_valid;
  logic [IQ_ENTRIES-1:0] select_ready [3];
  logic [IQ_ENTRIES-1:0] issue_select [3];
  logic [STORE_SLOTS-1:0] store_forward_candidates,store_send_candidates;
  logic [STORE_SLOTS*ST-1:0] store_owners;
  issue_t executing [3],memory_execute;
  logic memory_valid,memory_capture;
  wire [31:0] agu_address,agu_data;
  wire [3:0] agu_mask;
  logic [3:0] agu_fault;
  wire agu_exit;
  logic steer;
  logic load_available;
  logic [LT-1:0] free_load;
  localparam integer WRITEBACK_PORTS=5;
  logic [WRITEBACK_PORTS-1:0] wb_valid;
  rid_t wb_rid [WRITEBACK_PORTS];
  logic [31:0] wb_value [WRITEBACK_PORTS],wb_address[WRITEBACK_PORTS];
  logic [3:0] wb_fault [WRITEBACK_PORTS];
  logic [31:0] alu_result[2],branch_value,branch_next;
  logic branch_taken,branch_bad,branch_fire;
  logic branch_response_valid;
  rid_t branch_response_rid;
  logic [31:0] branch_response_value,branch_response_address;
  logic [3:0] branch_response_fault;
  always_ff @(posedge clk) begin
    branch_response_valid<=!rst && branch_fire;
    if(branch_fire) begin
      branch_response_rid<=executing[0].rid;branch_response_value<=branch_value;
      branch_response_fault<=branch_bad ? FAULT_TARGET_ALIGN:FAULT_NONE;
      branch_response_address<=branch_next;
    end
  end
  logic [31:0] execute_pc[2],execute_b[2];
  logic mdu_valid,mdu_ready,mdu_mul_ready,mdu_div_ready,mdu_result_valid,mdu_result_ready;
  logic [31:0] mdu_result;
  logic [7:0] mdu_result_tag;
  logic [255:0] mdu_kill;
  logic memory_allowed,memory_complete,store_allocate,load_allocate;
  logic [31:0] memory_address,memory_data,load_word,load_result;
  logic [3:0] memory_mask,memory_fault;
  logic memory_exit,forward_match,forward_full;
  logic [STORE_SLOTS-1:0] forward_select;
  logic store_pop,store_send_valid;
  logic [ST-1:0] store_send_slot;
  logic [ST:0] squashed_stores;
  logic exit_send,exit_accept;
  rob_t head_rob;
  rob_t commit_rob [2];
  wire [5:0] source_status [4];
  wire mdu_rob_valid,load_rob_valid;
  wire [63:0] memory_metadata;
  wire [ROB_ENTRIES*$bits(rob_t)-1:0] rob_words;
  wire [ROB_ENTRIES*6-1:0] rob_status_words;
  wire [ROB_ENTRIES-1:0] rob_valid_words;
  wire [ROB_ENTRIES*64-1:0] rob_instruction_words;
  for(genvar row=0;row<ROB_ENTRIES;row=row+1) begin: pack_rob
    assign rob_words[row*$bits(rob_t)+:$bits(rob_t)]=rob[row];
    assign rob_status_words[row*6+:6]={rob[row].valid,rob[row].done,rob[row].fault};
    assign rob_valid_words[row]=rob[row].valid;
    assign rob_instruction_words[row*64+:64]={rob[row].pc,rob[row].inst};
  end
    v2_read #(.WIDTH($bits(rob_t)),.ENTRIES(ROB_ENTRIES),.ONEHOT(1)) read_head_rob (.index(head),.select(head_select),.words(rob_words),.value(head_rob));
  for(genvar port=0;port<2;port=port+1) begin: commit_rob_ports
    assign commit_rid[port]=port==0 ? head:second_head;
    v2_read #(.WIDTH($bits(rob_t)),.ENTRIES(ROB_ENTRIES),.ONEHOT(1)) read_commit_rob (.index(commit_rid[port]),.select(port==0 ? head_select:second_select),.words(rob_words),.value(commit_rob[port]));
  end
  for(genvar port=0;port<4;port=port+1) begin: source_rob_ports
    v2_read #(.WIDTH(6),.ENTRIES(ROB_ENTRIES)) read_source_status (.index(source_slot[port*RW+:RW]),.select('0),.words(rob_status_words),.value(source_status[port]));
  end
    v2_read #(.WIDTH(1),.ENTRIES(ROB_ENTRIES)) read_mdu_rob (.index(rid_t'(mdu_result_tag)),.select('0),.words(rob_valid_words),.value(mdu_rob_valid));
    v2_read #(.WIDTH(1),.ENTRIES(ROB_ENTRIES)) read_load_rob (.index(result_load.rid),.select('0),.words(rob_valid_words),.value(load_rob_valid));
    v2_read #(.WIDTH(64),.ENTRIES(ROB_ENTRIES)) read_memory_rob (.index(memory_execute.rid),.select('0),.words(rob_instruction_words),.value(memory_metadata));

  logic [31:0] commit_value [2];
  logic [31:0] source_value_read [4];
  wire [ROB_ENTRIES*32-1:0] values_words;
  for(genvar row=0;row<ROB_ENTRIES;row=row+1) begin: pack_values
    assign values_words[row*32+:32]=values[row];
  end
  for(genvar port=0;port<2;port=port+1) begin: commit_value_ports
    v2_read #(.WIDTH(32),.ENTRIES(ROB_ENTRIES),.ONEHOT(1)) read_commit_value (.index(commit_rid[port]),.select(port==0 ? head_select:second_select),.words(values_words),.value(commit_value[port]));
  end
  for(genvar port=0;port<4;port=port+1) begin: source_value_read_ports
    v2_read #(.WIDTH(32),.ENTRIES(ROB_ENTRIES)) read_source_value_read (.index(source_slot[port*RW+:RW]),.select('0),.words(values_words),.value(source_value_read[port]));
  end

  logic [31:0] source_arch [4];
  wire [32*32-1:0] architectural_words;
  for(genvar row=0;row<32;row=row+1) begin: pack_architectural
    assign architectural_words[row*32+:32]=architectural[row];
  end
  for(genvar port=0;port<4;port=port+1) begin: source_arch_ports
    v2_read #(.WIDTH(32),.ENTRIES(32)) read_source_arch (.index(source_register[port*5+:5]),.select('0),.words(architectural_words),.value(source_arch[port]));
  end

  for(genvar bank=0;bank<3;bank=bank+1) begin: queue_reads
    wire [IQ_ENTRIES*$bits(issue_t)-1:0] queue_bank_words;
    issue_t picked;
    for(genvar row=0;row<IQ_ENTRIES;row=row+1) begin: columns
      issue_t readable;
      // Read the stored operands directly. Ready/valid qualify execution,
      // and the operation's operand mux chooses immediate versus register.
      // Unused fields need not pass through opcode-dependent zeroing gates.
      always_comb begin
        readable=queue[bank][row];
        // Integer banks never allocate memory-size fields.
        if(bank<2) begin readable.size=0;readable.sign_extend=0;end
      end
      assign queue_bank_words[row*$bits(issue_t)+:$bits(issue_t)]=readable;
    end
    v2_read #(.WIDTH($bits(issue_t)),.ENTRIES(IQ_ENTRIES),.ONEHOT(1)) read_executing
      (.index(selected[bank]),.select(issue_select[bank]),.words(queue_bank_words),.value(picked));
    always_comb begin
      executing[bank]=picked;
      // The memory bank contains only LOAD (20) and STORE (21). Their
      // common opcode bits need not be selected and decoded after the head.
      if(bank==2) executing[bank].op=picked.op[0] ? OP_STORE:OP_LOAD;
    end
  end

  store_t send_store;
  store_t forward_store;
  store_t head_store;
  wire [STORE_SLOTS*$bits(store_t)-1:0] stores_words;
  for(genvar row=0;row<STORE_SLOTS;row=row+1) begin: pack_stores
    assign stores_words[row*$bits(store_t)+:$bits(store_t)]=stores[row];
  end
    v2_read #(.WIDTH($bits(store_t)),.ENTRIES(STORE_SLOTS)) read_send_store (.index(store_send_slot),.select('0),.words(stores_words),.value(send_store));
    v2_read #(.WIDTH($bits(store_t)),.ENTRIES(STORE_SLOTS),.ONEHOT(1)) read_forward_store (.index(ST'(0)),.select(forward_select),.words(stores_words),.value(forward_store));
    v2_read #(.WIDTH($bits(store_t)),.ENTRIES(STORE_SLOTS)) read_head_store (.index(store_head),.select('0),.words(stores_words),.value(head_store));

  load_t result_load;
  wire [LOAD_SLOTS*$bits(load_t)-1:0] loads_words;
  for(genvar row=0;row<LOAD_SLOTS;row=row+1) begin: pack_loads
    assign loads_words[row*$bits(load_t)+:$bits(load_t)]=loads[row];
  end
    v2_read #(.WIDTH($bits(load_t)),.ENTRIES(LOAD_SLOTS)) read_result_load (.index(cache_result_tag),.select('0),.words(loads_words),.value(result_load));
  function automatic rid_t age(input rid_t rid);
    return rid-head;
  endfunction
  function automatic logic younger(input rid_t rid);
    return redirect_kill[rid];
  endfunction
  function automatic logic [31:0] extend_load(input logic [31:0] word_value,
      input logic [1:0] offset,size,input logic sign_extend);
    logic [31:0] shifted;
    begin
      shifted=word_value>>(8*offset);
      case(size)
        0:return {{24{sign_extend && shifted[7]}},shifted[7:0]};
        1:return {{16{sign_extend && shifted[15]}},shifted[15:0]};
        default:return shifted;
      endcase
    end
  endfunction
  assign halted=state==DONE;
  assign faulted=state==FAULT;
  assign load_replay_count=0;
  assign exit_head=!stopped && rob_count!=0 && head_rob.done && head_rob.exiting && head_rob.fault==0;
  assign fault_head=!stopped && rob_count!=0 && head_rob.done && head_rob.fault!=0;
  assign flush_all=stopped;
  assign stop_frontend=flush_all;
  assign exit_send=state==DRAIN && store_count==0 && cache_idle && frontend_idle && controller_idle;
  assign exit_accept=exit_send && mem_req_ready;
  assign mem_req_valid=state!=DONE && (exit_send || bus_req_valid);
  assign mem_req_write=exit_send || bus_req_write;
  assign mem_req_addr=exit_send ? 32'h80000000:bus_req_addr;
  assign mem_req_wdata=exit_send ? head_rob.wdata:bus_req_data;
  assign mem_req_wstrb=exit_send ? 4'hf:bus_req_mask;
  assign bus_req_ready=mem_req_ready && !exit_send && state!=DONE;
  assign mem_rsp_ready=bus_rsp_ready;
  v2_frontend #(.CACHE_BYTES(ICACHE_BYTES),.QUEUE_ENTRIES(FETCH_QUEUE_ENTRIES),
    .BHT_ENTRIES(BHT_ENTRIES),.BTB_ENTRIES(BTB_ENTRIES),.LOCAL_HISTORY_BITS(LOCAL_HISTORY_BITS),
    .HISTORY_ENTRIES(HISTORY_ENTRIES),.RAM_BYTES(RAM_BYTES)) frontend (
    .clk,.rst,.stop(stop_frontend),.redirect(frontend_redirect),.redirect_pc,.pop_count,
    .packet_valid(fetch_valid),.packet_available(fetch_available),.packet_pc(fetch_pc),.packet_inst(fetch_inst),.packet_prediction(fetch_prediction),
    .packet_fault(fetch_fault),.packet_inst_valid(fetch_iv),.packet_history(fetch_history),.train_history(executing[0].history),.train_valid,.train_taken,.train_op,.train_pc,.train_target,
    .mem_req_valid(client_req_valid[0]),.mem_req_ready(client_req_ready[0]),.mem_req_addr(client_req_addr[31:0]),
    .mem_rsp_valid(client_rsp_valid[0]),.mem_rsp_ready(client_rsp_ready[0]),.mem_rsp_data(client_rsp_data[31:0]),
    .mem_rsp_error(client_rsp_error[0]),.idle(frontend_idle),.miss_count(icache_miss_count));
  assign client_req_write[0]=0;assign client_req_data[31:0]=0;assign client_req_mask[3:0]=0;
  v2_dcache #(.CACHE_BYTES(DCACHE_BYTES),.LINE_BYTES(DCACHE_LINE_BYTES),.WAYS(DCACHE_WAYS),.DATA_BANKS(DCACHE_BANKS),.MSHRS(D_MSHRS),.LOAD_SLOTS(LOAD_SLOTS),.STORE_SLOTS(STORE_SLOTS),
    .CREDITS(MAX_MEM_OUTSTANDING),.RAM_BYTES(RAM_BYTES)) dcache (
    .clk,.rst,.load_valid(cache_load_valid),.load_address(cache_load_address),.load_tag(cache_load_tag),
    .load_ready(cache_load_ready),.load_hit(cache_load_hit),.load_data(cache_load_data),
    .result_valid(cache_result_valid),.result_ready(1'b1),.result_tag(cache_result_tag),
    .result_data(cache_result_data),.result_error(cache_result_error),
    .store_valid(cache_store_valid),.store_ready(cache_store_ready),.store_address(cache_store_address),
    .store_data(cache_store_data),.store_mask(cache_store_mask),.store_tag(cache_store_tag),
    .store_done(cache_store_done),.store_done_tag(cache_store_done_tag),.store_error(cache_store_error),
    .mem_req_valid(client_req_valid[1]),.mem_req_ready(client_req_ready[1]),.mem_req_write(client_req_write[1]),
    .mem_req_addr(client_req_addr[63:32]),.mem_req_data(client_req_data[63:32]),.mem_req_mask(client_req_mask[7:4]),
    .mem_rsp_valid(client_rsp_valid[1]),.mem_rsp_ready(client_rsp_ready[1]),.mem_rsp_data(client_rsp_data[63:32]),
    .mem_rsp_error(client_rsp_error[1]),.idle(cache_idle),.miss_count(dcache_miss_count));
  memory_controller #(.MAX_MEM_OUTSTANDING(MAX_MEM_OUTSTANDING)) memory_bus (
    .clk,.rst,.s_req_valid(client_req_valid),.s_req_ready(client_req_ready),.s_req_write(client_req_write),
    .s_req_addr(client_req_addr),.s_req_wdata(client_req_data),.s_req_wstrb(client_req_mask),
    .s_rsp_valid(client_rsp_valid),.s_rsp_ready(client_rsp_ready),.s_rsp_rdata(client_rsp_data),.s_rsp_error(client_rsp_error),
    .mem_req_valid(bus_req_valid),.mem_req_ready(bus_req_ready),.mem_req_write(bus_req_write),
    .mem_req_addr(bus_req_addr),.mem_req_wdata(bus_req_data),.mem_req_wstrb(bus_req_mask),
    .mem_rsp_valid,.mem_rsp_ready(bus_rsp_ready),.mem_rsp_rdata,.mem_rsp_error,.idle(controller_idle));
  for(genvar d=0;d<2;d=d+1) begin: decode_lanes
    decoder decoder_i(.inst(fetch_inst[d*32+:32]),.dec(decoded[d]));
    assign source_register[(d*2)*5+:5]=decoded[d].rs1;
    assign source_register[(d*2+1)*5+:5]=decoded[d].rs2;
    assign rename_slot[d*RW+:RW]=dispatch_rid[d];
    assign commit_slot[d*RW+:RW]=commit_rid[d];
  end
  v2_rename #(.SLOT_BITS(RW),.CHECKPOINTS(CHECKPOINTS),.PREPARE_SNAPSHOTS(1)) rename_maps (
    .clk,.rst,.dispatch_valid(rename_valid),.dispatch_rd(rename_rd),.dispatch_slot(rename_slot),
    .source_register,.source_pending,.source_slot,.commit_valid,.commit_rd,.commit_slot,
    .save_valid(save_checkpoint),.save_after_lane,.save_index(free_checkpoint),.prepare_save(checkpoint_available),
    .restore_valid(redirect),.restore_index(redirect_checkpoint));
  for(genvar p=0;p<2;p=p+1) begin: integer_units
    assign execute_pc[p]={executing[p].pc,2'b0};
    assign execute_b[p]=executing[p].use_imm ? executing[p].imm:executing[p].b;
    (* keep_hierarchy *) v2_alu alu_i(.op(executing[p].op),.a(executing[p].a),.b(execute_b[p]),
      .pc(execute_pc[p]),.imm(executing[p].imm),.result(alu_result[p]));
  end
  (* keep_hierarchy *) branch_unit branch_i(.op(executing[0].op),.a(executing[0].a),.b(executing[0].b),
    .pc(execute_pc[0]),.imm(executing[0].imm),.result(branch_value),.next_pc(branch_next),
    .taken(branch_taken),.misaligned(branch_bad));
  (* keep_hierarchy *) muldiv #(.DIV_STEP_BITS(DIV_STEP_BITS),.ENABLE_DIV_CACHE(DIV_CACHE_ENABLE),.TAG_BITS(RW)) mdu(.clk,.rst,.kill(flush_all),.kill_mask(mdu_kill),.req_valid(mdu_valid),.req_ready(mdu_ready),
    .mul_ready(mdu_mul_ready),.div_ready(mdu_div_ready),.req_op(executing[0].op),
    .req_a(executing[0].a),.req_b(executing[0].b),.req_tag(8'(executing[0].rid)),
    .rsp_valid(mdu_result_valid),.rsp_ready(mdu_result_ready),.rsp_result(mdu_result),.rsp_tag(mdu_result_tag));
  for(genvar bank=0;bank<3;bank=bank+1) begin: balanced_selection
    for(genvar q=0;q<IQ_ENTRIES;q=q+1) begin: candidate
      assign select_ready[bank][q]=queue[bank][q].valid && (bank==2 || (queue[bank][q].ready_a && queue[bank][q].ready_b));
    end
    if(bank==2) begin: fifo_selection
      assign selected[bank]=memory_head;
      assign selected_valid[bank]=memory_count!=0;
      assign issue_select[bank]=memory_head_select;
    end else begin: integer_selection
      wire [IQ_ENTRIES-1:0] allocate,surviving_ready,new_ready,next_grant;
      for(genvar q=0;q<IQ_ENTRIES;q=q+1) begin: allocated_slots
        wire allocated0=dispatch_valid[0] && dispatch_bank[0]==2'(bank) && dispatch_index[0]==QW'(q);
        wire allocated1=dispatch_valid[1] && dispatch_bank[1]==2'(bank) && dispatch_index[1]==QW'(q);
        assign allocate[q]=allocated0 || allocated1;
        assign new_ready[q]=(allocated0 && dispatch_payload[0].ready_a && dispatch_payload[0].ready_b) ||
                            (allocated1 && dispatch_payload[1].ready_a && dispatch_payload[1].ready_b);
        // Compute readiness after this edge's wakeups, issue and recovery.
        // A newly allocated entry is handled separately as the youngest.
        assign surviving_ready[q]=queue[bank][q].valid && !allocate[q] &&
          !(issue_fire[bank] && issue_select[bank][q]) && !younger(queue[bank][q].rid) && !flush_all &&
          (queue[bank][q].ready_a || (|issue_banks[bank].rows[q].wake_a)) &&
          (queue[bank][q].ready_b || (|issue_banks[bank].rows[q].wake_b));
      end
      v2_age_matrix #(.ENTRIES(IQ_ENTRIES)) choose (.clk,.rst,.allocate,.ready(surviving_ready),.grant(next_grant));
      // Select the next cycle's oldest ready instruction in parallel with
      // writing its operands. A dependent ALU can still execute next cycle.
      always_ff @(posedge clk) begin
        if(rst || flush_all) issue_select[bank]<=0;
        else issue_select[bank]<=(|next_grant) ? next_grant:new_ready;
      end
      assign selected[bank]=0;
      assign selected_valid[bank]=|issue_select[bank];
`ifndef SYNTHESIS
`ifdef V2_VERIFY
      for(genvar a=0;a<IQ_ENTRIES;a=a+1) begin: age_check
        for(genvar b=0;b<IQ_ENTRIES;b=b+1) begin: peer
          always_ff @(posedge clk) if(!rst && queue[bank][a].valid && queue[bank][b].valid)
            assert(choose.older[a][b]==(age(queue[bank][b].rid)<age(queue[bank][a].rid)))
              else $fatal(1,"issue age matrix disagrees with ROB order");
        end
        wire oracle_grant=select_ready[bank][a] && !(|(choose.older[a] & select_ready[bank]));
        always_ff @(posedge clk) if(!rst)
          assert(issue_select[bank][a]==oracle_grant) else $fatal(1,"registered issue selection differs from combinational oracle");
      end
      always_ff @(posedge clk) if(!rst)
        assert($onehot0(issue_select[bank]) && ((|select_ready[bank])==(|issue_select[bank])))
          else $fatal(1,"issue grant is not the unique oldest ready entry");
`endif
`endif
    end
    assign select_valid[bank]=selected_valid[bank] && (bank!=2 || (executing[bank].ready_a && executing[bank].ready_b));
  end
  for(genvar s=0;s<STORE_SLOTS;s=s+1) begin: store_candidates
    assign store_owners[s*ST+:ST]=ST'(s);
    assign store_forward_candidates[s]=stores[s].valid && stores[s].address[31:2]==memory_address[31:2] &&
                                       (|(stores[s].mask & memory_mask));
    assign store_send_candidates[s]=stores[s].valid && stores[s].committed && !stores[s].issued;
  end
  v2_ring_youngest #(.ENTRIES(STORE_SLOTS)) choose_forward (
    .ready(store_forward_candidates),.head(store_head),.valid(forward_match),.select(forward_select));
  v2_select #(.ENTRIES(STORE_SLOTS),.SLOT_BITS(ST)) choose_store (
    .ready(store_send_candidates),.owner(store_owners),.rob_head(store_head),.head_prefix('0),.wrapped_owner('0),.valid(store_send_valid),.index(store_send_slot));
  always_comb begin: select_instructions
    free_queue_valid=0;
    for(integer bank=0;bank<3;bank=bank+1) begin
      free_queue[bank]=0;occupancy[bank]=0;
      for(integer q=0;q<IQ_ENTRIES;q=q+1) begin
        if(queue[bank][q].valid) begin
          occupancy[bank]=occupancy[bank]+1'b1;
        end else if(!free_queue_valid[bank]) begin free_queue_valid[bank]=1;free_queue[bank]=QW'(q);end
      end
      if(bank==2) begin
        free_queue[bank]=memory_tail;free_queue_valid[bank]=int'(memory_count)<IQ_ENTRIES;
        occupancy[bank]=memory_count;
      end
    end
    checkpoint_available=0;free_checkpoint=0;
    for(integer c=0;c<CHECKPOINTS;c=c+1)
      if(!checkpoint_valid[c] && !checkpoint_available) begin checkpoint_available=1;free_checkpoint=CPW'(c);end
    load_available=0;free_load=0;
    for(integer l=0;l<LOAD_SLOTS;l=l+1)
      if(!loads[l].valid && !load_available) begin load_available=1;free_load=LT'(l);end
    mdu_kill='1;
    for(integer r=0;r<ROB_ENTRIES;r=r+1) mdu_kill[r]=!rob[r].valid;
  end
  always_comb begin
    memory_survivors=0;
    for(integer q=0;q<IQ_ENTRIES;q=q+1)
      if(queue[2][q].valid && !younger(queue[2][q].rid)) memory_survivors=memory_survivors+1'b1;
  end
  always_ff @(posedge clk) begin
    if(rst || flush_all) begin memory_head<=0;memory_tail<=0;memory_count<=0;end
    else begin
      memory_head<=memory_head+QW'(issue_fire[2]);
      if(redirect) begin
        // Recovery removes a suffix. The issuing surviving head, if any,
        // advances independently; it is included in memory_survivors.
        memory_tail<=memory_head+QW'(memory_survivors);
        memory_count<=memory_survivors-(QW+1)'(issue_fire[2]);
      end else begin
        memory_tail<=memory_tail+QW'(memory_push);
        memory_count<=memory_count+(QW+1)'(memory_push)-(QW+1)'(issue_fire[2]);
      end
    end
  end
  always_ff @(posedge clk) begin
    if(rst || flush_all) memory_head_select<=IQ_ENTRIES'(1);
    else if(issue_fire[2]) memory_head_select<={memory_head_select[IQ_ENTRIES-2:0],memory_head_select[IQ_ENTRIES-1]};
  end
  assign branch_fire=select_valid[0] && !younger(executing[0].rid) && is_branch(executing[0].op) && !flush_all && !mdu_result_valid;
  wire redirect_candidate=branch_fire && !branch_bad && branch_next!={executing[0].prediction,2'b0};
  for(genvar row=0;row<ROB_ENTRIES;row=row+1) begin: recovery_mask
    wire row_wrap,row_after_branch;
    if(row==ROB_ENTRIES-1) begin: last_slot
      assign row_wrap=0;
    end else begin: wrapped_slot
      assign row_wrap=rid_t'(row)<next_head;
    end
    if(row==0) begin: first_slot
      assign row_after_branch=0;
    end else begin: later_slot
      assign row_after_branch=rid_t'(row)>executing[0].rid;
    end
    wire branch_wrap=executing[0].rid<next_head;
    always_ff @(posedge clk) begin
      if(rst || flush_all) redirect_kill[row]<=0;
      else redirect_kill[row]<=redirect_candidate &&
        (row_wrap!=branch_wrap ? row_wrap:row_after_branch);
    end
  end
  always_ff @(posedge clk) begin
    if(rst || flush_all) redirect<=0;
    else redirect<=redirect_candidate;
    if(redirect_candidate) begin
      redirect_pc<=branch_next;redirect_rid<=executing[0].rid;redirect_checkpoint<=executing[0].checkpoint;
    end
  end
  assign train_valid=branch_fire && !branch_bad;
  assign train_op=executing[0].op;
  assign train_taken=branch_taken;
  assign train_pc=execute_pc[0];
  assign train_target=branch_next;
  assign mdu_valid=select_valid[0] && !younger(executing[0].rid) && is_mdu(executing[0].op) && !flush_all && !mdu_result_valid;
  assign mdu_result_ready=!flush_all;
  wire [IQ_ENTRIES-1:0] memory_live_entries;
  wire memory_head_live=|(memory_head_select & memory_live_entries);
  for(genvar q=0;q<IQ_ENTRIES;q=q+1) begin: memory_permissions
    assign memory_live_entries[q]=queue[2][q].valid && queue[2][q].ready_a && queue[2][q].ready_b &&
                                  !younger(queue[2][q].rid) && !flush_all;
`ifndef SYNTHESIS
`ifdef V2_VERIFY
    always_ff @(posedge clk) if(!rst && queue[2][q].valid)
      assert(queue[2][q].op==OP_LOAD || queue[2][q].op==OP_STORE)
        else $fatal(1,"non-memory operation in memory bank");
`endif
`endif
  end
`ifndef SYNTHESIS
`ifdef V2_VERIFY
  always_ff @(posedge clk) if(!rst)
    assert(memory_head_live==(select_valid[2] && !flush_all && !younger(executing[2].rid)))
      else $fatal(1,"memory permission differs from selected-entry predicate");
`endif
`endif
  // Prepare the effective address on the same edge that accepts its base
  // operand. Allocation and wakeup still make the instruction eligible on
  // the next cycle, but cache access no longer follows a selected adder.
  wire [IQ_ENTRIES*32-1:0] prepared_address_words;
  wire [31:0] dispatch_address[2];
  logic [31:0] dispatch_address_base[2];
  logic [1:0] dispatch_address_pending;
  rid_t dispatch_address_tag[2];
  wire [WRITEBACK_PORTS*RW-1:0] address_wb_tags;
  wire [WRITEBACK_PORTS*32-1:0] address_wb_values;
  for(genvar w=0;w<WRITEBACK_PORTS;w=w+1) begin: address_bypass_words
    assign address_wb_tags[w*RW+:RW]=wb_rid[w];
    assign address_wb_values[w*32+:32]=wb_value[w];
  end
  for(genvar lane=0;lane<2;lane=lane+1) begin: dispatch_address_sums
    (* keep_hierarchy *) v2_prepare_address #(.TAG_BITS(RW),.PORTS(WRITEBACK_PORTS)) prepare_sum
      (.base(dispatch_address_base[lane]),.offset(dispatch_payload[lane].imm),
       .pending(dispatch_address_pending[lane]),.source_tag(dispatch_address_tag[lane]),
       .wb_valid(wb_result_valid),.wb_tags(address_wb_tags),.wb_values(address_wb_values),.address(dispatch_address[lane]));
  end
  for(genvar q=0;q<IQ_ENTRIES;q=q+1) begin: address_preparation
    logic [31:0] address_q;
    wire [31:0] wake_address;
    wire allocation0=dispatch_prepare[0] && dispatch_bank[0]==2 && dispatch_index[0]==QW'(q);
    (* keep_hierarchy *) v2_add32 prepare_sum
      (.a(issue_banks[2].rows[q].wake_value_a),.b(queue[2][q].imm),.sum(wake_address));
    // Late slot/bank acceptance selects already-computed allocation sums.
    // If neither lane allocates this free row its prepared value is unused.
    always_ff @(posedge clk) begin
      if(!queue[2][q].valid) address_q<=allocation0 ? dispatch_address[0]:dispatch_address[1];
      else if(!queue[2][q].ready_a) address_q<=wake_address;
    end
    assign prepared_address_words[q*32+:32]=address_q;
`ifndef SYNTHESIS
`ifdef V2_VERIFY
    always_ff @(posedge clk) if(!rst && queue[2][q].valid && queue[2][q].ready_a)
      assert(address_q==queue[2][q].a+queue[2][q].imm)
        else $fatal(1,"prepared address differs from base plus immediate");
`endif
`endif
  end
  wire [IQ_ENTRIES-1:0] address_head_select;
  (* keep_hierarchy *) ooo_head_select #(.DEPTH(IQ_ENTRIES)) address_selection (
    .clk(clk),.clear(rst || flush_all),.advance(issue_fire[2]),.selection(address_head_select));
  v2_read #(.WIDTH(32),.ENTRIES(IQ_ENTRIES),.ONEHOT(1)) read_prepared_address
    (.index(memory_head),.select(address_head_select),.words(prepared_address_words),.value(agu_address));
  assign agu_data=executing[2].b<<(8*agu_address[1:0]);
  assign agu_mask=(executing[2].size==0 ? 4'b0001:executing[2].size==1 ? 4'b0011:4'b1111)<<agu_address[1:0];
  assign agu_exit=executing[2].op==OP_STORE && agu_address==32'h80000000 && executing[2].size==2;
  always_comb begin: address_checks
    agu_fault=FAULT_NONE;
    if((executing[2].size==1 && agu_address[0]) || (executing[2].size==2 && agu_address[1:0]!=0))
      agu_fault=executing[2].op==OP_LOAD ? FAULT_LOAD_ALIGN:FAULT_STORE_ALIGN;
    else if(agu_address>=RAM_BYTES && !agu_exit)
      agu_fault=executing[2].op==OP_LOAD ? FAULT_LOAD_RANGE:FAULT_STORE_RANGE;
  end
  if(LSU_PIPELINE!=0) begin: pipelined_memory
    assign memory_allowed=memory_valid && !flush_all && !younger(memory_execute.rid);
    assign memory_capture=memory_head_live &&
      (!memory_valid || younger(memory_execute.rid) || memory_complete || load_allocate);
    always_ff @(posedge clk) begin
      if(rst || flush_all) memory_valid<=0;
      else begin
        if(younger(memory_execute.rid) || memory_complete || load_allocate) memory_valid<=0;
        if(memory_capture) begin
          memory_valid<=1;memory_execute<=executing[2];
          memory_address<=agu_address;memory_data<=agu_data;memory_mask<=agu_mask;
          memory_fault<=agu_fault;memory_exit<=agu_exit;
        end
      end
    end
  end else begin: direct_memory
    assign memory_allowed=memory_head_live;
    assign memory_capture=0;
    assign memory_valid=select_valid[2];
    assign memory_execute=executing[2];
    assign memory_address=agu_address;assign memory_data=agu_data;assign memory_mask=agu_mask;
    assign memory_fault=agu_fault;assign memory_exit=agu_exit;
  end
  always_comb begin: memory_ordering
    forward_full=0;squashed_stores=0;
    for(integer s=0;s<STORE_SLOTS;s=s+1) begin
      if(stores[s].valid && !stores[s].committed && (younger(stores[s].rid) || flush_all))
        squashed_stores=squashed_stores+1'b1;
    end
    if(forward_match) forward_full=(forward_store.mask & memory_mask)==memory_mask;
  end
  assign cache_store_valid=store_send_valid && state!=DONE && state!=FAULT;
  assign cache_store_tag=store_send_slot;
  assign cache_store_address={send_store.address[31:2],2'b0};
  assign cache_store_data=send_store.data;
  assign cache_store_mask=send_store.mask;
  assign store_pop=store_count!=0 && head_store.done;
  assign cache_load_valid=memory_allowed && memory_execute.op==OP_LOAD && memory_fault==0 &&
                         !forward_match && load_available;
  assign cache_load_address={memory_address[31:2],2'b0};
  assign cache_load_tag=free_load;
  assign load_word=forward_full ? forward_store.data:cache_load_data;
  assign load_result=extend_load(load_word,memory_address[1:0],memory_execute.size,memory_execute.sign_extend);
  assign load_allocate=cache_load_valid && cache_load_ready && !cache_load_hit;
  assign store_allocate=memory_allowed && memory_execute.op==OP_STORE && memory_fault==0 && !memory_exit && int'(store_count)<STORE_SLOTS;
  assign memory_complete=memory_allowed && (memory_fault!=0 || memory_exit || store_allocate ||
                          (memory_execute.op==OP_LOAD && (forward_full || (cache_load_valid && cache_load_ready && cache_load_hit))));
  wire [WRITEBACK_PORTS-1:0] wb_result_valid;
  for(genvar w=0;w<WRITEBACK_PORTS;w=w+1) begin: register_results
    if(w==3) begin: memory_result
      // Stores complete and update their ROB metadata, but cannot own a
      // pending GPR source. Keep Store/exit admission off the wakeup bus.
      assign wb_result_valid[w]=memory_allowed && memory_execute.op==OP_LOAD && memory_fault==0 &&
        (forward_full || (cache_load_valid && cache_load_ready && cache_load_hit));
    end else begin: other_result
      assign wb_result_valid[w]=wb_valid[w] && wb_fault[w]==FAULT_NONE;
    end
`ifndef SYNTHESIS
`ifdef V2_VERIFY
    always_ff @(posedge clk) if(!rst) begin
      if(wb_result_valid[w]) assert(wb_valid[w] && wb_fault[w]==FAULT_NONE)
        else $fatal(1,"register result without successful completion");
      if(wb_valid[w] && wb_fault[w]==FAULT_NONE && rob[wb_rid[w]].rd!=0)
        assert(wb_result_valid[w]) else $fatal(1,"GPR completion missing its register result");
    end
`endif
`endif
  end
  always_comb begin: completion
    wb_valid=0;issue_fire=0;
    for(integer w=0;w<WRITEBACK_PORTS;w=w+1) begin wb_rid[w]=0;wb_value[w]=0;wb_fault[w]=0;wb_address[w]=0;end
    // Consumers qualify every payload with wb_valid. Keep data and tags
    // independent of late issue/cancel enables; gating whole result words
    // multiplies control fanout before operand capture and address preparation.
    wb_rid[0]=mdu_result_valid ? rid_t'(mdu_result_tag):executing[0].rid;
    wb_value[0]=mdu_result_valid ? mdu_result:alu_result[0];
    wb_rid[1]=executing[1].rid;wb_value[1]=alu_result[1];
    wb_rid[2]=result_load.rid;
    wb_value[2]=extend_load(cache_result_data,result_load.address[1:0],result_load.size,result_load.sign_extend);
    wb_fault[2]=cache_result_error ? FAULT_LOAD_BUS:FAULT_NONE;
    wb_address[2]=result_load.address;
    wb_rid[3]=memory_execute.rid;
    wb_value[3]=load_result;
    wb_fault[3]=memory_fault;wb_address[3]=memory_address;
    wb_rid[4]=branch_response_rid;wb_value[4]=branch_response_value;
    wb_fault[4]=branch_response_fault;wb_address[4]=branch_response_address;
    if(!flush_all) begin
      if(mdu_result_valid) begin
        wb_valid[0]=mdu_rob_valid && !younger(rid_t'(mdu_result_tag));
      end else if(select_valid[0] && !younger(executing[0].rid)) begin
        if(is_mdu(executing[0].op)) issue_fire[0]=mdu_ready;
        else begin
          issue_fire[0]=1;wb_valid[0]=!is_branch(executing[0].op);
          // Branch values and target faults use the delayed branch channel.
        end
      end
      if(INTEGER_PORTS==2 && select_valid[1] && !younger(executing[1].rid)) begin
        issue_fire[1]=1;wb_valid[1]=1;
      end
      if(cache_result_valid) begin
        wb_valid[2]=result_load.valid && !result_load.canceled &&
                    load_rob_valid && !younger(result_load.rid);
      end
      issue_fire[2]=LSU_PIPELINE!=0 ? memory_capture:(memory_complete || load_allocate);
      wb_valid[3]=memory_complete;
      wb_valid[4]=branch_response_valid && rob[branch_response_rid].valid && !younger(branch_response_rid);
    end
  end
  always_comb begin: retirement
    logic blocked_retirement,committed_store;
    blocked_retirement=0;committed_store=0;commit_count=0;commit_valid=0;commit_rd=0;
    for(integer lane=0;lane<2;lane=lane+1) begin
      if(lane<COMMIT_WIDTH && !blocked_retirement && !stopped && int'(rob_count)>lane &&
         commit_rob[lane].done && commit_rob[lane].fault==0 && !commit_rob[lane].exiting &&
         // In a two-entry retirement prefix, head has age zero. The
         // successor crosses the boundary only when the recovering branch is at head.
         (lane==0 || !redirect || redirect_rid!=head) && (!committed_store || !commit_rob[lane].store)) begin
        commit_count=commit_count+1'b1;
        commit_valid[lane]=commit_rob[lane].rd!=0;
        commit_rd[lane*5+:5]=commit_rob[lane].rd;
        if(commit_rob[lane].store) committed_store=1;
      end else blocked_retirement=1;
    end
  end
  always_comb begin: dispatch_control
    logic blocked_dispatch;
    integer bank_choice;
    blocked_dispatch=0;
    dispatch_prepare=0;dispatch_count=0;rename_prepare=0;rename_rd=0;used_bank=0;
    save_checkpoint=0;save_after_lane=0;
    for(integer lane=0;lane<2;lane=lane+1) begin
      dispatch_rid[lane]=tail+rid_t'(lane);dispatch_bank[lane]=0;dispatch_index[lane]=0;bank_choice=0;
      if(lane<RENAME_WIDTH && !blocked_dispatch && fetch_available[lane] && !dispatch_full[lane]) begin
        if(decoded[lane].op==OP_LOAD || decoded[lane].op==OP_STORE) bank_choice=2;
        else if(is_branch(decoded[lane].op) || is_mdu(decoded[lane].op) || INTEGER_PORTS==1) bank_choice=0;
        else if(used_bank[0] || !free_queue_valid[0]) bank_choice=1;
        else if(used_bank[1] || !free_queue_valid[1]) bank_choice=0;
        else bank_choice=(occupancy[1]<occupancy[0] || (occupancy[1]==occupancy[0] && steer)) ? 1:0;
        if(fetch_fault[lane*4+:4]!=0 || decoded[lane].illegal) begin
          dispatch_prepare[lane]=1;dispatch_count=dispatch_count+1'b1;
          dispatch_bank[lane]=3;
        end else if(!used_bank[bank_choice] && free_queue_valid[bank_choice] &&
                    (!is_branch(decoded[lane].op) || (checkpoint_available && !save_checkpoint))) begin
          dispatch_prepare[lane]=1;dispatch_count=dispatch_count+1'b1;
          dispatch_bank[lane]=2'(bank_choice);dispatch_index[lane]=free_queue[bank_choice];used_bank[bank_choice]=1;
          rename_prepare[lane]=decoded[lane].writes_rd;rename_rd[lane*5+:5]=decoded[lane].writes_rd ? decoded[lane].rd:5'd0;
          if(is_branch(decoded[lane].op)) begin save_checkpoint=1;save_after_lane=1'(lane);end
        end else blocked_dispatch=1;
      end else blocked_dispatch=1;
    end
    // Free rows may prepare payload while recovery/stop suppresses its
    // publication. Only valid bits and architectural maps see final accept.
    dispatch_valid=dispatch_prepare & {2{!flush_all && !redirect}};
    rename_valid=rename_prepare & {2{!flush_all && !redirect}};
    if(flush_all || redirect) begin dispatch_count=0;save_checkpoint=0;end
    pop_count=dispatch_count;
  end
  always_comb begin: capture_sources
    rid_t source_id;
    logic [4:0] register_id;
    logic pending,ready_value;
    logic [31:0] source_value;
    source_id=0;register_id=0;pending=0;ready_value=0;source_value=0;
    for(integer lane=0;lane<2;lane=lane+1) begin
      dispatch_address_base[lane]=0;dispatch_address_pending[lane]=0;dispatch_address_tag[lane]=0;
      dispatch_payload[lane]='0;dispatch_payload[lane].valid=1;dispatch_payload[lane].rid=dispatch_rid[lane];
      dispatch_payload[lane].op=decoded[lane].op;dispatch_payload[lane].imm=decoded[lane].imm;
      dispatch_payload[lane].pc=fetch_pc[lane*32+2+:30];
      dispatch_payload[lane].history=fetch_history[lane*HB+:HB];
      dispatch_payload[lane].prediction=fetch_prediction[lane*32+2+:30];
      dispatch_payload[lane].size=decoded[lane].mem_size;dispatch_payload[lane].sign_extend=decoded[lane].load_signed;
      dispatch_payload[lane].use_imm=decoded[lane].use_imm;dispatch_payload[lane].checkpoint=free_checkpoint;
      for(integer source_number=0;source_number<2;source_number=source_number+1) begin
        register_id=source_register[(lane*2+source_number)*5+:5];
        source_id=source_slot[(lane*2+source_number)*RW+:RW];
        pending=source_pending[lane*2+source_number] && register_id!=0 &&
                (source_number==0 ? decoded[lane].uses_rs1:decoded[lane].uses_rs2);
        // Preparation also predicts lane 0's rename when publication is
        // suppressed. Such an intra-bundle source has no value yet.
        if(lane==1 && rename_prepare[0] && rename_rd[4:0]!=0 && register_id==rename_rd[4:0] &&
            (source_number==0 ? decoded[lane].uses_rs1:decoded[lane].uses_rs2)) begin
          source_id=dispatch_rid[0];pending=1;
        end
        ready_value=!pending || (source_status[lane*2+source_number][5:4]==2'b11 && source_status[lane*2+source_number][3:0]==0);
        source_value=pending ? source_value_read[lane*2+source_number]:(register_id==0 ? 32'd0:source_arch[lane*2+source_number]);
        if(source_number==0) begin
          dispatch_address_base[lane]=source_value;
          dispatch_address_pending[lane]=pending;dispatch_address_tag[lane]=source_id;
        end
        for(integer w=0;w<WRITEBACK_PORTS;w=w+1)
          if(pending && wb_result_valid[w] && wb_rid[w]==source_id) begin ready_value=1;source_value=wb_value[w];end
        // A fresh intra-bundle writer has no value even if its old physical
        // row still contains a completed result from an earlier wrap.
        if(lane==1 && rename_prepare[0] && source_id==dispatch_rid[0] && pending) ready_value=0;
        if(source_number==0) begin
          dispatch_payload[lane].a=source_value;dispatch_payload[lane].ready_a=ready_value;
          dispatch_payload[lane].source_a=source_id;
        end else begin
          dispatch_payload[lane].b=source_value;dispatch_payload[lane].ready_b=ready_value;
          dispatch_payload[lane].source_b=source_id;
        end
      end
    end
  end
  always_ff @(posedge clk) begin: control_state
    if(rst) begin
      state<=RUN;head<=0;tail<=0;rob_count<=0;store_head<=0;store_tail<=0;store_count<=0;steer<=0;
      fault_pc<=0;fault_inst<=0;fault_inst_valid<=0;fault_cause<=0;fault_addr<=0;
      cycle_count<=0;retired_count<=0;branch_miss_count<=0;
      retire_valid<=0;retire_pc<=0;retire_inst<=0;retire_rd<=0;retire_value<=0;
      retire_store<=0;retire_addr<=0;retire_wdata<=0;retire_wstrb<=0;
    end else begin
      retire_valid<=0;retire_store<=0;
      if(state!=DONE && state!=FAULT) cycle_count<=cycle_count+1;
      head<=head+rid_t'(commit_count);
      if(redirect) tail<=redirect_rid+1'b1;
      else tail<=tail+rid_t'(dispatch_count);
      rob_count<=next_rob_count;
      store_count<=store_count+(ST+1)'(store_allocate)-(ST+1)'(store_pop)-squashed_stores;
      store_head<=store_head+ST'(store_pop);store_tail<=store_tail+ST'(store_allocate)-ST'(squashed_stores);
      if(dispatch_count!=0) steer<=!steer;
      if(redirect) branch_miss_count<=branch_miss_count+1;
      retired_count<=retired_count+64'(commit_count)+64'(exit_accept);
      for(integer lane=0;lane<2;lane=lane+1)
        if(int'(commit_count)>lane) begin
          retire_valid[lane]<=1;retire_pc[lane*32+:32]<=commit_rob[lane].pc;
          retire_inst[lane*32+:32]<=commit_rob[lane].inst;retire_rd[lane*5+:5]<=commit_rob[lane].rd;
          retire_value[lane*32+:32]<=commit_rob[lane].rd==0 ? 32'd0:commit_value[lane];
          retire_store[lane]<=commit_rob[lane].store;
          retire_addr[lane*32+:32]<=commit_rob[lane].address;
          retire_wdata[lane*32+:32]<=commit_rob[lane].wdata;
          retire_wstrb[lane*4+:4]<=commit_rob[lane].mask;
        end
      if(exit_head) state<=DRAIN;
      if(exit_accept) begin
        state<=DONE;retire_valid<=1;retire_store<=1;retire_pc[31:0]<=head_rob.pc;retire_inst[31:0]<=head_rob.inst;
        retire_rd[4:0]<=0;retire_value[31:0]<=0;retire_addr[31:0]<=32'h80000000;
        retire_wdata[31:0]<=head_rob.wdata;retire_wstrb[3:0]<=15;
      end
      if(fault_head) begin
        state<=FAULT;fault_pc<=head_rob.pc;fault_inst<=head_rob.inst;fault_inst_valid<=head_rob.iv;
        fault_cause<=head_rob.fault;fault_addr<=head_rob.fault_address;
      end
      if(cache_store_error) begin
        state<=FAULT;fault_cause<=FAULT_STORE_BUS;fault_pc<=stores[cache_store_done_tag].pc;
        fault_inst<=stores[cache_store_done_tag].inst;fault_inst_valid<=1;fault_addr<=stores[cache_store_done_tag].address;
      end
    end
  end
  for(genvar r=0;r<ROB_ENTRIES;r=r+1) begin: rob_rows
    logic [31:0] result_q;
    logic row_valid_q;
    logic row_done_q;
    logic row_iv_q;
    logic row_store_q;
    logic row_exiting_q;
    logic [4:0] row_rd_q;
    logic [3:0] row_fault_q;
    logic [ST-1:0] row_store_slot_q;
    logic [3:0] row_mask_q;
    logic [31:0] row_pc_q;
    logic [31:0] row_inst_q;
    logic [31:0] row_fault_address_q;
    logic [31:0] row_address_q;
    logic [31:0] row_wdata_q;
    assign rob[r]={row_valid_q,row_done_q,row_iv_q,row_store_q,row_exiting_q,row_rd_q,row_fault_q,row_store_slot_q,row_mask_q,row_pc_q,row_inst_q,row_fault_address_q,row_address_q,row_wdata_q};
    assign values[r]=result_q;
    always_ff @(posedge clk) begin
      if(rst) begin row_valid_q<=0;row_done_q<=0;end
      else begin
        for(integer lane=0;lane<2;lane=lane+1)
          if(int'(commit_count)>lane && commit_rid[lane]==rid_t'(r)) row_valid_q<=0;
        for(integer w=0;w<WRITEBACK_PORTS;w=w+1)
          if(wb_valid[w] && wb_rid[w]==rid_t'(r)) begin
            row_done_q<=1;
            if(wb_result_valid[w]) result_q<=wb_value[w];
            // Dispatch initializes fault state. Successful completions do
            // not need to drive the 32-bit exception-address write enable.
            if(wb_fault[w]!=FAULT_NONE) begin
              row_fault_q<=wb_fault[w];row_fault_address_q<=wb_address[w];
            end
          end
        // These fields belong to this live Store already. Capture them
        // while it waits too, keeping late completion/forwarding decisions
        // out of the Store metadata write enables. The allocating cycle
        // captures the final store_tail before marking the ROB entry done.
        if(memory_allowed && memory_execute.rid==rid_t'(r) && memory_execute.op==OP_STORE) begin
          row_address_q<=memory_address;row_wdata_q<=memory_data;row_mask_q<=memory_mask;
          row_exiting_q<=memory_exit;row_store_slot_q<=store_tail;
        end
        if(younger(rid_t'(r)) || (flush_all && rid_t'(r)!=head)) row_valid_q<=0;
        for(integer lane=0;lane<2;lane=lane+1)
          if(!row_valid_q && dispatch_rid[lane]==rid_t'(r)) begin
            row_pc_q<=fetch_pc[lane*32+:32];row_inst_q<=fetch_inst[lane*32+:32];row_iv_q<=fetch_iv[lane];
            row_rd_q<=rename_rd[lane*5+:5];row_store_q<=decoded[lane].op==OP_STORE;
            row_exiting_q<=0;
            row_fault_q<=fetch_fault[lane*4+:4]!=0 ? fetch_fault[lane*4+:4]:decoded[lane].illegal ? FAULT_ILLEGAL:FAULT_NONE;
            row_fault_address_q<=fetch_pc[lane*32+:32];row_address_q<=0;row_wdata_q<=0;row_mask_q<=0;
          end
        for(integer lane=0;lane<2;lane=lane+1)
          if(dispatch_valid[lane] && dispatch_rid[lane]==rid_t'(r)) begin
            row_valid_q<=1;row_done_q<=dispatch_bank[lane]==3;
          end
      end
    end
  end
  for(genvar r=0;r<32;r=r+1) begin: architectural_registers
    logic [31:0] value_q;
    assign architectural[r]=value_q;
    always_ff @(posedge clk) begin
      if(rst || r==0) value_q<=0;
      else for(integer lane=0;lane<2;lane=lane+1)
        if(commit_valid[lane] && commit_rd[lane*5+:5]==5'(r)) value_q<=commit_value[lane];
    end
  end
  for(genvar bank=0;bank<3;bank=bank+1) begin: issue_banks
    for(genvar q=0;q<IQ_ENTRIES;q=q+1) begin: rows
      logic row_valid_q;
      logic row_ready_a_q;
      logic row_ready_b_q;
      logic row_use_imm_q;
      logic row_sign_extend_q;
      rid_t row_rid_q;
      rid_t row_source_a_q;
      rid_t row_source_b_q;
      op_t row_op_q;
      logic [29:0] row_pc_q;
      logic [29:0] row_prediction_q;
      logic [HB-1:0] row_history_q;
      logic [1:0] row_size_q;
      logic [CPW-1:0] row_checkpoint_q;
      logic [31:0] row_a_q;
      logic [31:0] row_b_q;
      logic [31:0] row_imm_q;
      assign queue[bank][q]={row_valid_q,row_ready_a_q,row_ready_b_q,row_use_imm_q,row_sign_extend_q,row_rid_q,row_source_a_q,row_source_b_q,row_op_q,row_pc_q,row_prediction_q,row_history_q,row_size_q,row_checkpoint_q,row_a_q,row_b_q,row_imm_q};
      wire [WRITEBACK_PORTS-1:0] wake_a,wake_b;
      logic [31:0] wake_value_a,wake_value_b;
      for(genvar w=0;w<WRITEBACK_PORTS;w=w+1) begin: wake_matches
        // A pending source can only name a live GPR producer. Re-reading
        // its ROB rd on the broadcast path is redundant: retirement and
        // recovery invalidate old RAT mappings before a slot is reused.
        assign wake_a[w]=wb_result_valid[w] && row_source_a_q==wb_rid[w];
        assign wake_b[w]=wb_result_valid[w] && row_source_b_q==wb_rid[w];
      end
      always_comb begin
        wake_value_a=0;wake_value_b=0;
        for(integer w=0;w<WRITEBACK_PORTS;w=w+1) begin
          wake_value_a=wake_value_a | ({32{wake_a[w]}} & wb_value[w]);
          wake_value_b=wake_value_b | ({32{wake_b[w]}} & wb_value[w]);
        end
      end
      always_ff @(posedge clk) begin
        if(bank!=2) begin row_size_q<=0;row_sign_extend_q<=0;end
        if(rst) row_valid_q<=0;
        else begin
          if(row_valid_q && !row_ready_a_q && (|wake_a)) begin
            row_ready_a_q<=1;row_a_q<=wake_value_a;
          end
          if(row_valid_q && !row_ready_b_q && (|wake_b)) begin
            row_ready_b_q<=1;row_b_q<=wake_value_b;
          end
          if((issue_fire[bank] && issue_select[bank][q]) || younger(row_rid_q) || flush_all) row_valid_q<=0;
          for(integer lane=0;lane<2;lane=lane+1)
            if(dispatch_valid[lane] && dispatch_bank[lane]==2'(bank) && dispatch_index[lane]==QW'(q))
              row_valid_q<=1;
          for(integer lane=0;lane<2;lane=lane+1)
            if(!row_valid_q && dispatch_prepare[lane] && dispatch_bank[lane]==2'(bank) && dispatch_index[lane]==QW'(q)) begin
              row_rid_q<=dispatch_payload[lane].rid;
              row_op_q<=dispatch_payload[lane].op;row_use_imm_q<=dispatch_payload[lane].use_imm;
              row_ready_a_q<=dispatch_payload[lane].ready_a;
              row_ready_b_q<=dispatch_payload[lane].ready_b;
              if(dispatch_payload[lane].ready_a) row_a_q<=dispatch_payload[lane].a;
              else row_source_a_q<=dispatch_payload[lane].source_a;
              if(dispatch_payload[lane].ready_b) row_b_q<=dispatch_payload[lane].b;
              else row_source_b_q<=dispatch_payload[lane].source_b;
              if(dispatch_payload[lane].use_imm || is_branch(dispatch_payload[lane].op) ||
                 dispatch_payload[lane].op==OP_LUI || dispatch_payload[lane].op==OP_AUIPC)
                row_imm_q<=dispatch_payload[lane].imm;
              if(is_branch(dispatch_payload[lane].op) || dispatch_payload[lane].op==OP_AUIPC)
                row_pc_q<=dispatch_payload[lane].pc;
              if(is_branch(dispatch_payload[lane].op)) begin
                row_prediction_q<=dispatch_payload[lane].prediction;
                row_history_q<=dispatch_payload[lane].history;
                row_checkpoint_q<=dispatch_payload[lane].checkpoint;
              end
              if(bank==2) begin
                row_size_q<=dispatch_payload[lane].size;
                row_sign_extend_q<=dispatch_payload[lane].sign_extend;
              end
            end
        end
      end
    end
  end
  for(genvar cp=0;cp<CHECKPOINTS;cp=cp+1) begin: checkpoint_rows
    logic valid_q;
    rid_t owner_q;
    assign checkpoint_valid[cp]=valid_q;
    assign checkpoint_owner[cp]=owner_q;
    always_ff @(posedge clk) begin
      if(rst) begin valid_q<=0;owner_q<=0;end
      else begin
        if((branch_fire && executing[0].checkpoint==CPW'(cp)) || younger(owner_q) || flush_all)
          valid_q<=0;
        if(save_checkpoint && free_checkpoint==CPW'(cp)) begin
          valid_q<=1;owner_q<=dispatch_rid[save_after_lane];
        end
      end
    end
  end
  for(genvar s=0;s<STORE_SLOTS;s=s+1) begin: store_rows
    logic row_valid_q;
    logic row_committed_q;
    logic row_issued_q;
    logic row_done_q;
    rid_t row_rid_q;
    logic [3:0] row_mask_q;
    logic [31:0] row_address_q;
    logic [31:0] row_data_q;
    logic [31:0] row_pc_q;
    logic [31:0] row_inst_q;
    assign stores[s]={row_valid_q,row_committed_q,row_issued_q,row_done_q,row_rid_q,row_mask_q,row_address_q,row_data_q,row_pc_q,row_inst_q};
    always_ff @(posedge clk) begin
      if(rst) row_valid_q<=0;
      else begin
        if(store_pop && store_head==ST'(s)) row_valid_q<=0;
        if(cache_store_valid && cache_store_ready && store_send_slot==ST'(s)) row_issued_q<=1;
        if(cache_store_done && cache_store_done_tag==ST'(s)) row_done_q<=1;
        for(integer lane=0;lane<2;lane=lane+1)
          if(int'(commit_count)>lane && commit_rob[lane].store && commit_rob[lane].store_slot==ST'(s)) row_committed_q<=1;
        if(!row_committed_q && (younger(row_rid_q) || flush_all)) row_valid_q<=0;
        if(store_allocate && store_tail==ST'(s)) begin
          row_valid_q<=1;row_committed_q<=0;row_issued_q<=0;row_done_q<=0;
          row_rid_q<=memory_execute.rid;row_address_q<=memory_address;row_data_q<=memory_data;row_mask_q<=memory_mask;
          row_pc_q<=memory_metadata[63:32];row_inst_q<=memory_metadata[31:0];
        end
      end
    end
  end
  for(genvar l=0;l<LOAD_SLOTS;l=l+1) begin: load_rows
    logic row_valid_q;
    logic row_canceled_q;
    logic row_sign_extend_q;
    rid_t row_rid_q;
    logic [1:0] row_size_q;
    logic [31:0] row_address_q;
    assign loads[l]={row_valid_q,row_canceled_q,row_sign_extend_q,row_rid_q,row_size_q,row_address_q};
    always_ff @(posedge clk) begin
      if(rst) row_valid_q<=0;
      else begin
        if(cache_result_valid && cache_result_tag==LT'(l)) row_valid_q<=0;
        if(younger(row_rid_q) || flush_all) row_canceled_q<=1;
        if(load_allocate && free_load==LT'(l)) begin
          row_valid_q<=1;row_canceled_q<=0;row_rid_q<=memory_execute.rid;
          row_address_q<=memory_address;row_size_q<=memory_execute.size;row_sign_extend_q<=memory_execute.sign_extend;
        end
      end
    end
  end
`ifndef SYNTHESIS
`ifdef V2_VERIFY
  longint unsigned coverage_redirect,coverage_dual_commit,coverage_load_cancel,coverage_canceled_response;
  longint unsigned coverage_canceled_error,coverage_live_tag_reuse,coverage_forward,coverage_partial_wait,coverage_multi_load;
  longint unsigned coverage_mdu_cancel,coverage_victim_store_collision;
  longint unsigned coverage_memory_wrap,coverage_memory_recovery,coverage_cache_bank_overlap;
  logic [ROB_ENTRIES-1:0] monitored_mdu;
  always_ff @(posedge clk) begin: verify_state
    integer live_count,active_loads,memory_live;
    rid_t expected_tag;
    logic expected_pending;
    if(rst) begin
      coverage_redirect<=0;coverage_dual_commit<=0;coverage_load_cancel<=0;coverage_canceled_response<=0;
      coverage_canceled_error<=0;coverage_live_tag_reuse<=0;coverage_forward<=0;coverage_partial_wait<=0;
      coverage_multi_load<=0;coverage_mdu_cancel<=0;coverage_victim_store_collision<=0;monitored_mdu<=0;
      coverage_memory_wrap<=0;coverage_memory_recovery<=0;coverage_cache_bank_overlap<=0;
    end else begin
      live_count=0;active_loads=0;memory_live=0;expected_tag=0;expected_pending=0;
      for(integer q=0;q<IQ_ENTRIES;q=q+1) begin
        if(queue[2][q].valid) memory_live=memory_live+1;
        if(q<int'(memory_count)) begin
          assert(queue[2][QW'(memory_head+QW'(q))].valid) else $fatal(1,"memory FIFO hole");
          if(q>0) assert(age(queue[2][QW'(memory_head+QW'(q))].rid)>
            age(queue[2][QW'(memory_head+QW'(q-1))].rid)) else $fatal(1,"memory FIFO age order");
        end
      end
      assert(memory_live==int'(memory_count)) else $fatal(1,"memory FIFO count mismatch");
      for(integer bank=0;bank<3;bank=bank+1)
        for(integer q=0;q<IQ_ENTRIES;q=q+1) if(queue[bank][q].valid) begin
          if(!queue[bank][q].ready_a)
            assert(rob[queue[bank][q].source_a].valid && rob[queue[bank][q].source_a].rd!=0 &&
              age(queue[bank][q].source_a)<age(queue[bank][q].rid)) else $fatal(1,"invalid pending source A");
          if(!queue[bank][q].ready_b)
            assert(rob[queue[bank][q].source_b].valid && rob[queue[bank][q].source_b].rd!=0 &&
              age(queue[bank][q].source_b)<age(queue[bank][q].rid)) else $fatal(1,"invalid pending source B");
        end
      if(issue_fire[2] && memory_head==QW'(IQ_ENTRIES-1)) coverage_memory_wrap<=coverage_memory_wrap+1;
      if(redirect && memory_survivors!=memory_count) coverage_memory_recovery<=coverage_memory_recovery+1;
      if(dcache.data_write_valid && dcache.read_issue && !dcache.read_error && !dcache.fill_waiter_valid)
        coverage_cache_bank_overlap<=coverage_cache_bank_overlap+1;
      if(redirect) coverage_redirect<=coverage_redirect+1;
      if(commit_count==2) coverage_dual_commit<=coverage_dual_commit+1;
      if(memory_complete && memory_execute.op==OP_LOAD && forward_full) coverage_forward<=coverage_forward+1;
      if(memory_allowed && memory_execute.op==OP_LOAD && forward_match && !forward_full) coverage_partial_wait<=coverage_partial_wait+1;
      if(dcache.allocate && dcache.store_tag_hit && dcache.selected_line==dcache.store_line && cache_store_valid)
        coverage_victim_store_collision<=coverage_victim_store_collision+1;
      for(integer l=0;l<LOAD_SLOTS;l=l+1) begin
        if(loads[l].valid) active_loads=active_loads+1;
        if(loads[l].valid && !loads[l].canceled && younger(loads[l].rid)) coverage_load_cancel<=coverage_load_cancel+1;
        for(integer d=0;d<2;d=d+1)
          if(dispatch_valid[d] && loads[l].valid && loads[l].canceled && loads[l].rid==dispatch_rid[d])
            coverage_live_tag_reuse<=coverage_live_tag_reuse+1;
      end
      if(active_loads>1) coverage_multi_load<=coverage_multi_load+1;
      if(cache_result_valid && result_load.canceled) begin
        coverage_canceled_response<=coverage_canceled_response+1;
        if(cache_result_error) coverage_canceled_error<=coverage_canceled_error+1;
      end
      for(integer r=0;r<ROB_ENTRIES;r=r+1) begin
        if(rob[r].valid) live_count=live_count+1;
        if(monitored_mdu[r] && (younger(rid_t'(r)) || flush_all)) begin
          coverage_mdu_cancel<=coverage_mdu_cancel+1;monitored_mdu[r]<=0;
        end
        if(mdu_result_valid && mdu_result_ready && rid_t'(mdu_result_tag)==rid_t'(r)) monitored_mdu[r]<=0;
        if(mdu_valid && mdu_ready && executing[0].rid==rid_t'(r)) monitored_mdu[r]<=1;
      end
      for(integer r=0;r<ROB_ENTRIES;r=r+1)
        assert(head_prefix[r]==(rid_t'(r)<head)) else $fatal(1,"head decode mismatch");
      for(integer r=0;r<ROB_ENTRIES;r=r+1)
        assert(redirect_kill[r]==(redirect && (head_prefix[r]!=head_prefix[redirect_rid] ?
          head_prefix[r]:rid_t'(r)>redirect_rid))) else $fatal(1,"registered recovery mask mismatch");
      assert(head_select==(ROB_ENTRIES'(1)<<head)) else $fatal(1,"head selection mismatch");
      assert(second_head==head+rid_t'(1)) else $fatal(1,"second head mismatch");
      assert(stopped==(state!=RUN)) else $fatal(1,"run permission mismatch");
      for(integer lane=0;lane<2;lane=lane+1)
        assert(dispatch_full[lane]==(int'(rob_count)>=ROB_ENTRIES-lane)) else $fatal(1,"ROB credit mismatch");
      for(integer lane=0;lane<2;lane=lane+1)
        assert((lane==0 || !redirect || redirect_rid!=head)==!younger(commit_rid[lane]))
          else $fatal(1,"retirement recovery boundary mismatch");
      if(!stopped) begin
        assert(live_count==int'(rob_count)) else $fatal(1,"ROB live/count mismatch");
        for(integer a=1;a<32;a=a+1) begin
          expected_pending=0;expected_tag=0;
          for(integer r=0;r<ROB_ENTRIES;r=r+1)
            if(rob[r].valid && rob[r].rd==5'(a) && (!expected_pending || age(rid_t'(r))>age(expected_tag))) begin
              expected_pending=1;expected_tag=rid_t'(r);
            end
          assert(rename_maps.pending_q[a]==expected_pending) else $fatal(1,"RAT presence mismatch x%0d",a);
          if(expected_pending) assert(rename_maps.tag_q[a]==expected_tag) else $fatal(1,"RAT youngest-writer mismatch x%0d",a);
        end
      end
      for(integer a=0;a<WRITEBACK_PORTS;a=a+1)
        for(integer b=a+1;b<WRITEBACK_PORTS;b=b+1)
          assert(!(wb_valid[a] && wb_valid[b] && wb_rid[a]==wb_rid[b])) else $fatal(1,"duplicate result owner");
    end
  end
  final $display("V2_COVERAGE redirects=%0d dual_commit=%0d load_cancel=%0d canceled_response=%0d canceled_error=%0d live_tag_reuse=%0d forward=%0d partial_wait=%0d multi_load=%0d mdu_cancel=%0d victim_store_collision=%0d memory_wrap=%0d memory_recovery=%0d cache_bank_overlap=%0d",
    coverage_redirect,coverage_dual_commit,coverage_load_cancel,coverage_canceled_response,coverage_canceled_error,
    coverage_live_tag_reuse,coverage_forward,coverage_partial_wait,coverage_multi_load,coverage_mdu_cancel,coverage_victim_store_collision,
    coverage_memory_wrap,coverage_memory_recovery,coverage_cache_bank_overlap);
`endif
  always_ff @(posedge clk) if(!rst) begin
    assert(memory_head_select==(IQ_ENTRIES'(1)<<memory_head)) else $fatal(1,"memory head selection mismatch");
    assert(int'(memory_count)<=IQ_ENTRIES) else $fatal(1,"memory FIFO overflow");
    if(memory_count!=0) assert(queue[2][memory_head].valid) else $fatal(1,"memory FIFO head invalid");
    if(memory_push) assert(!queue[2][memory_tail].valid) else $fatal(1,"memory FIFO slot reused early");
    assert(int'(rob_count)<=ROB_ENTRIES) else $fatal(1,"ROB overflow");
    assert(int'(store_count)<=STORE_SLOTS) else $fatal(1,"store queue overflow");
    if(cache_result_valid) assert(result_load.valid) else $fatal(1,"unowned cache response");
    if(store_allocate) assert(!stores[store_tail].valid) else $fatal(1,"store slot reused early");
    for(integer d=0;d<2;d=d+1)
      if(dispatch_valid[d]) assert(!rob[dispatch_rid[d]].valid) else $fatal(1,"ROB reused early");
  end
`endif
  initial begin
    if(ROB_ENTRIES<8 || ROB_ENTRIES>128 || (ROB_ENTRIES&(ROB_ENTRIES-1))!=0 ||
       IQ_ENTRIES<2 || (IQ_ENTRIES&(IQ_ENTRIES-1))!=0 || CHECKPOINTS<2 ||
       (CHECKPOINTS&(CHECKPOINTS-1))!=0 || RENAME_WIDTH<1 || RENAME_WIDTH>2 ||
       COMMIT_WIDTH<1 || COMMIT_WIDTH>2 || INTEGER_PORTS<1 || INTEGER_PORTS>2 ||
       LOAD_SLOTS<2 || (LOAD_SLOTS&(LOAD_SLOTS-1))!=0 || STORE_SLOTS<2 ||
       (STORE_SLOTS&(STORE_SLOTS-1))!=0 || RAM_BYTES<4096 ||
       RAM_BYTES>268435456 || (RAM_BYTES&(RAM_BYTES-1))!=0)
      $fatal(1,"invalid Area-v2 dimensions");
  end
endmodule
