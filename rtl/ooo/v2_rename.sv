// ROB-tag rename map with branch snapshots and commit invalidation.
// Read the current map once; lane 1 uses an explicit lane-0 bypass rather
// than dynamically reading an entire modified next-state register array.
module v2_rename #(
  parameter integer SLOT_BITS=5, CHECKPOINTS=4, PREPARE_SNAPSHOTS=0,
  parameter integer CHECKPOINT_BITS=$clog2(CHECKPOINTS)
)(
  input logic clk,rst,
  input logic [1:0] dispatch_valid,
  input logic [9:0] dispatch_rd,
  input logic [2*SLOT_BITS-1:0] dispatch_slot,
  input logic [19:0] source_register,
  output logic [3:0] source_pending,
  output logic [4*SLOT_BITS-1:0] source_slot,
  input logic [1:0] commit_valid,
  input logic [9:0] commit_rd,
  input logic [2*SLOT_BITS-1:0] commit_slot,
  input logic save_valid,save_after_lane,
  input logic prepare_save,
  input logic [CHECKPOINT_BITS-1:0] save_index,
  input logic restore_valid,
  input logic [CHECKPOINT_BITS-1:0] restore_index
);
  logic [31:0] pending_q;
  logic [SLOT_BITS-1:0] tag_q[32];
  logic [31:0] checkpoint_pending[CHECKPOINTS];
  logic [SLOT_BITS-1:0] checkpoint_tag[CHECKPOINTS][32];
  logic [1:0] checkpoint_commit_valid;
  logic [9:0] checkpoint_commit_rd;
  logic [2*SLOT_BITS-1:0] checkpoint_commit_slot;
  always_ff @(posedge clk) begin
    checkpoint_commit_valid<=rst ? 2'd0:commit_valid;
    checkpoint_commit_rd<=commit_rd;checkpoint_commit_slot<=commit_slot;
  end
  wire [32*(SLOT_BITS+1)-1:0] current_words;
  for(genvar r=0;r<32;r=r+1) begin: map_columns
    assign current_words[r*(SLOT_BITS+1)+:(SLOT_BITS+1)]={pending_q[r],tag_q[r]};
  end
  for(genvar port=0;port<4;port=port+1) begin: source_reads
    wire [SLOT_BITS:0] current;
    wire bypass=port>=2 && dispatch_valid[0] && dispatch_rd[4:0]!=0 &&
      dispatch_rd[4:0]==source_register[port*5+:5];
    v2_read #(.WIDTH(SLOT_BITS+1),.ENTRIES(32)) lookup
      (.index(source_register[port*5+:5]),.select('0),.words(current_words),.value(current));
    assign source_pending[port]=bypass || current[SLOT_BITS];
    assign source_slot[port*SLOT_BITS+:SLOT_BITS]=bypass ? dispatch_slot[0+:SLOT_BITS]:current[SLOT_BITS-1:0];
  end
  for(genvar r=0;r<32;r=r+1) begin: map_rows
    logic pending_bit_q;
    logic [SLOT_BITS-1:0] slot_q;
    assign pending_q[r]=pending_bit_q;
    assign tag_q[r]=slot_q;
    wire write0=r!=0 && dispatch_valid[0] && dispatch_rd[4:0]==5'(r);
    wire write1=r!=0 && dispatch_valid[1] && dispatch_rd[9:5]==5'(r);
    wire [SLOT_BITS-1:0] after0=write0 ? dispatch_slot[0+:SLOT_BITS]:slot_q;
    wire [SLOT_BITS-1:0] after1=write1 ? dispatch_slot[SLOT_BITS+:SLOT_BITS]:after0;
    wire pending0=write0 || pending_bit_q;
    wire pending1=write1 || pending0;
    wire [SLOT_BITS-1:0] save_tag=save_after_lane ? after1:after0;
    wire save_pending=save_after_lane ? pending1:pending0;
    wire [SLOT_BITS-1:0] next_tag=restore_valid ? checkpoint_tag[restore_index][r]:after1;
    wire next_pending=restore_valid ? checkpoint_pending[restore_index][r]:pending1;
    wire commit0=commit_valid[0] && commit_rd[4:0]==5'(r);
    wire commit1=commit_valid[1] && commit_rd[9:5]==5'(r);
    wire clear_next=(commit0 && next_tag==commit_slot[0+:SLOT_BITS]) ||
                    (commit1 && next_tag==commit_slot[SLOT_BITS+:SLOT_BITS]);
    wire clear_save=(commit0 && save_tag==commit_slot[0+:SLOT_BITS]) ||
                    (commit1 && save_tag==commit_slot[SLOT_BITS+:SLOT_BITS]);
    wire pending_commit0=checkpoint_commit_valid[0] && checkpoint_commit_rd[4:0]==5'(r);
    wire pending_commit1=checkpoint_commit_valid[1] && checkpoint_commit_rd[9:5]==5'(r);
    // A restored snapshot also sees the commit that is being cleared from
    // checkpoint storage on this edge. Newly saved snapshots use the already
    // current active map and must retain any newly reused producer tag.
    wire clear_restore=restore_valid &&
      ((pending_commit0 && next_tag==checkpoint_commit_slot[0+:SLOT_BITS]) ||
       (pending_commit1 && next_tag==checkpoint_commit_slot[SLOT_BITS+:SLOT_BITS]));
    always_ff @(posedge clk) begin
      if(rst || r==0) pending_bit_q<=0;
      else pending_bit_q<=next_pending && !clear_next && !clear_restore;
      slot_q<=next_tag;
    end
    for(genvar cp=0;cp<CHECKPOINTS;cp=cp+1) begin: snapshot
      logic snapshot_pending_q;
      logic [SLOT_BITS-1:0] snapshot_slot_q;
      assign checkpoint_pending[cp][r]=snapshot_pending_q;
      assign checkpoint_tag[cp][r]=snapshot_slot_q;
      // The core may prepare only an unowned checkpoint. Reading a restore
      // snapshot and preparing its now-free slot on the same edge is safe:
      // the active map captures the old registered snapshot before writes.
      wire capture_snapshot=(PREPARE_SNAPSHOTS!=0 ? prepare_save:(save_valid && !restore_valid)) &&
                            save_index==CHECKPOINT_BITS'(cp);
      wire clear_old=(pending_commit0 && snapshot_slot_q==checkpoint_commit_slot[0+:SLOT_BITS]) ||
                     (pending_commit1 && snapshot_slot_q==checkpoint_commit_slot[SLOT_BITS+:SLOT_BITS]);
      always_ff @(posedge clk) begin
        if(rst || r==0) snapshot_pending_q<=0;
        else begin
          if(clear_old) snapshot_pending_q<=0;
          if(capture_snapshot)
            snapshot_pending_q<=save_pending && !clear_save;
        end
        if(!rst && capture_snapshot)
          snapshot_slot_q<=save_tag;
      end
    end
  end
endmodule
