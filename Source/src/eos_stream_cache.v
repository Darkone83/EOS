// eos_stream_cache.v -- chunked flash->RAM->LPC, 2 aligned BLK-byte buffers.
// Invariant: the two buffers hold [current block, next block in the read direction].
// Flash is read ONLY as clean forward bursts (the case that gave green). Only the
// buffer the read has already PASSED is ever refilled, so the block being read and the
// one about to be read are never evicted. Descending (2BL) and ascending (kernel) are
// the same mechanism; the MCPX's first reads are covered by a power-on head-start that
// loads the top two blocks before it reads.
module eos_stream_cache #(
    parameter integer BLKBITS = 8               // 256B blocks (fits 9-bit reader len), 512B RAM
)(
    input  wire        clk, rstn,
    input  wire        mem_req,
    input  wire [17:0] mem_addr,
    output reg  [7:0]  mem_data,
    output reg         mem_valid,
    output reg         fr_start,
    output reg  [23:0] fr_addr,
    output reg  [8:0]  fr_len,
    input  wire        fr_busy, fr_done, fr_dvalid,
    input  wire [7:0]  fr_dout,
    output wire        prefetching
);
    localparam integer BLK = (1<<BLKBITS);
    localparam [17-BLKBITS:0] TOPBLK = 18'h3FFFF >> BLKBITS;

    reg [7:0]          cbuf  [0:2*BLK-1];
    reg [17-BLKBITS:0] cbase [0:1];
    reg [BLKBITS:0]    cfill [0:1];
    reg                cvld  [0:1];

    reg dir; reg have_last; reg [17:0] last_addr;
    reg rq; reg [17:0] rq_addr;
    wire [17-BLKBITS:0] rq_blk = rq_addr[17:BLKBITS];
    wire [BLKBITS-1:0]  rq_off = rq_addr[BLKBITS-1:0];
    wire h0 = cvld[0] && cbase[0]==rq_blk && ({1'b0,rq_off} < cfill[0]);
    wire h1 = cvld[1] && cbase[1]==rq_blk && ({1'b0,rq_off} < cfill[1]);

    wire [17-BLKBITS:0] cur_blk = have_last ? last_addr[17:BLKBITS] : TOPBLK;
    wire [17-BLKBITS:0] nxt_blk = dir ? cur_blk + 1'b1 : cur_blk - 1'b1;

    wire cur_in0 = cvld[0] && cbase[0]==cur_blk;
    wire cur_in1 = cvld[1] && cbase[1]==cur_blk;
    wire nxt_in0 = cvld[0] && cbase[0]==nxt_blk;
    wire nxt_in1 = cvld[1] && cbase[1]==nxt_blk;
    wire cur_have = cur_in0 | cur_in1;
    wire nxt_have = nxt_in0 | nxt_in1;

    localparam F_IDLE=0, F_RUN=1;
    reg fstate; reg fbank; reg [BLKBITS:0] fcnt;
    assign prefetching = (fstate!=F_IDLE);

    // victim that KEEPS block `keep`: use the buffer not holding keep
    function vic(input [17-BLKBITS:0] keep);
        vic = (cvld[0] && cbase[0]==keep) ? 1'b1 : 1'b0;
    endfunction

    task startload(input [17-BLKBITS:0] blk, input b);
        begin
            fbank<=b; cvld[b]<=0; cfill[b]<=0; cbase[b]<=blk;
            fr_addr<={ {(24-18){1'b0}}, blk, {BLKBITS{1'b0}} };
            fr_len<=BLK[8:0]; fr_start<=1; fcnt<=0; fstate<=F_RUN;
        end
    endtask

    always @(posedge clk or negedge rstn) begin
        if(!rstn) begin
            mem_valid<=0; fr_start<=0; fstate<=F_IDLE; rq<=0; have_last<=0; dir<=0;
            cvld[0]<=0; cvld[1]<=0; cfill[0]<=0; cfill[1]<=0; cbase[0]<=~0; cbase[1]<=~0; fbank<=0;
        end else begin
            mem_valid<=0; fr_start<=0;
            if (mem_req) begin
                rq<=1; rq_addr<=mem_addr;
                if (have_last) dir <= (mem_addr > last_addr);
                last_addr<=mem_addr; have_last<=1;
            end
            if (rq) begin
                if (h0) begin mem_data<=cbuf[{1'b0,rq_off}]; mem_valid<=1; rq<=0; end
                else if (h1) begin mem_data<=cbuf[{1'b1,rq_off}]; mem_valid<=1; rq<=0; end
            end
            case (fstate)
              F_IDLE:
                if (!cur_have)       startload(cur_blk, vic(nxt_blk));  // load current (miss/head-start)
                else if (!nxt_have)  startload(nxt_blk, vic(cur_blk));  // prefetch next-in-direction
              F_RUN: begin
                if (fr_dvalid) begin
                    cbuf[{fbank,fcnt[BLKBITS-1:0]}]<=fr_dout;
                    cfill[fbank]<=fcnt+1'b1; fcnt<=fcnt+1'b1;
                end
                if (fr_done) begin cvld[fbank]<=1; fstate<=F_IDLE; end
              end
            endcase
        end
    end
endmodule