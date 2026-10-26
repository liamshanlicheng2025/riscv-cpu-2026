// Pipelined two-client arbiter. RAM accepts one request per cycle and returns
// responses in acceptance order; the owner FIFO routes each response correctly.
module memory_controller #(
    parameter integer MAX_MEM_OUTSTANDING = 64
) (
    input  logic clk, rst,
    input  logic [1:0] s_req_valid,
    output logic [1:0] s_req_ready,
    input  logic [1:0] s_req_write,
    input  logic [63:0] s_req_addr, s_req_wdata,
    input  logic [7:0] s_req_wstrb,
    output logic [1:0] s_rsp_valid,
    input  logic [1:0] s_rsp_ready,
    output logic [63:0] s_rsp_rdata,
    output logic [1:0] s_rsp_error,
    output logic mem_req_valid,
    input  logic mem_req_ready,
    output logic mem_req_write,
    output logic [31:0] mem_req_addr, mem_req_wdata,
    output logic [3:0] mem_req_wstrb,
    input  logic mem_rsp_valid,
    output logic mem_rsp_ready,
    input  logic [31:0] mem_rsp_rdata,
    input  logic mem_rsp_error,
    output logic idle
);
    localparam integer PW = MAX_MEM_OUTSTANDING > 1 ? $clog2(MAX_MEM_OUTSTANDING) : 1;
    localparam integer CW = $clog2(MAX_MEM_OUTSTANDING+1);
    logic owners [MAX_MEM_OUTSTANDING];
    logic [PW-1:0] head, tail;
    logic [CW-1:0] count;
    logic request_valid, request_owner, next_owner, selected;
    logic skid_valid,skid_owner,skid_write;
    logic [31:0] skid_addr,skid_wdata;
    logic [3:0] skid_wstrb;
    logic request_fire, response_fire, input_fire, space;
    logic response_owner;
    wire [PW-1:0] following_head=int'(head)==MAX_MEM_OUTSTANDING-1 ? PW'(0):head+1'b1;

    always_comb begin
        s_rsp_valid = 2'b00;
        // Payload is meaningful only with the owning client's valid bit.
        // Broadcasting it avoids putting the owner FIFO read and response
        // validity decode in front of every returned data bit.
        s_rsp_rdata = {2{mem_rsp_rdata}};
        s_rsp_error = {2{mem_rsp_error}};
        mem_rsp_ready = 1'b0;
        if (!rst && count != 0) begin
            s_rsp_valid[response_owner] = mem_rsp_valid;
            mem_rsp_ready = s_rsp_ready[response_owner];
        end
    end
    assign response_fire = mem_rsp_valid && mem_rsp_ready;
    assign space = int'(count) < MAX_MEM_OUTSTANDING || response_fire;
    assign mem_req_valid = !rst && request_valid && space;
    assign request_fire = mem_req_valid && mem_req_ready;
    assign selected = s_req_valid[next_owner] ? next_owner : !next_owner;
    assign input_fire = s_req_valid[selected] && s_req_ready[selected];
    assign idle = count == 0 && !request_valid && !skid_valid && !(|s_req_valid);
    always_comb begin
        s_req_ready = 2'b00;
        // The second slot absorbs a request when the head becomes blocked.
        // Input credit depends only on registered occupancy, so downstream
        // backpressure does not propagate into both cache controllers.
        if (!rst && !skid_valid && s_req_valid[selected])
            s_req_ready[selected] = 1'b1;
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            head <= '0;
            tail <= '0;
            count <= '0;
            request_valid <= 1'b0;
            skid_valid <= 1'b0;
            request_owner <= 1'b0;
            next_owner <= 1'b0;
            response_owner <= 1'b0;
            mem_req_write <= 1'b0;
            mem_req_addr <= '0;
            mem_req_wdata <= '0;
            mem_req_wstrb <= '0;
            for (integer n = 0; n < MAX_MEM_OUTSTANDING; n = n+1) owners[n] <= 1'b0;
        end else begin
            // Cache the FIFO head's owner. A new request supplies the head
            // directly when the queue was empty or its last response drains.
            if (request_fire && (count==0 || (response_fire && count==1)))
                response_owner <= request_owner;
            else if (response_fire)
                response_owner <= owners[following_head];
            case ({request_fire, response_fire})
                2'b10: count <= count + 1'b1;
                2'b01: count <= count - 1'b1;
                default: begin end
            endcase
            if (request_fire) begin
                owners[tail] <= request_owner;
                tail <= int'(tail) == MAX_MEM_OUTSTANDING-1 ? '0 : tail + 1'b1;
                request_valid <= skid_valid;
                skid_valid <= 1'b0;
                if(skid_valid) begin
                    request_owner <= skid_owner;
                    mem_req_write <= skid_write;
                    mem_req_addr <= skid_addr;
                    mem_req_wdata <= skid_wdata;
                    mem_req_wstrb <= skid_wstrb;
                end
            end
            if (response_fire)
                head <= following_head;
            if (input_fire) begin
                next_owner <= !selected;
                if(!request_valid || request_fire) begin
                    request_valid <= 1'b1;
                    request_owner <= selected;
                    mem_req_write <= s_req_write[selected];
                    mem_req_addr <= s_req_addr[32*selected +: 32];
                    mem_req_wdata <= s_req_wdata[32*selected +: 32];
                    mem_req_wstrb <= s_req_wstrb[4*selected +: 4];
                end else begin
                    skid_valid <= 1'b1;
                    skid_owner <= selected;
                    skid_write <= s_req_write[selected];
                    skid_addr <= s_req_addr[32*selected +: 32];
                    skid_wdata <= s_req_wdata[32*selected +: 32];
                    skid_wstrb <= s_req_wstrb[4*selected +: 4];
                end
            end
        end
    end
`ifndef SYNTHESIS
    always_ff @(posedge clk) if(!rst) begin
        assert(!skid_valid || request_valid) else $fatal(1,"request skid has no head");
        assert(!(skid_valid && input_fire)) else $fatal(1,"request skid overflow");
    end
    always_ff @(posedge clk) if(!rst && count!=0)
        assert(response_owner==owners[head]) else $fatal(1,"memory response owner mismatch");
`endif
    initial if (MAX_MEM_OUTSTANDING < 1) $fatal(1, "invalid memory owner FIFO capacity");
endmodule
