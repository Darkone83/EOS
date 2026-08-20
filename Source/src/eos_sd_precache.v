// eos_sd_precache.v -- sole owner/arbitrator of the physical SD engine.
// Supports bulk read-to-SDRAM, one-sector browse read, and one-sector buffered
// write.  Browse read and write share the same 512-byte on-chip sector buffer.
module eos_sd_precache (
    input  wire        clk,
    input  wire        rstn,

    input  wire        start,
    input  wire [31:0] lba,
    input  wire [11:0] blkcnt,
    output reg         busy,
    output reg         done_sticky,
    output reg         err,
    output reg  [3:0]  err_code,

    input  wire        browse_go,
    input  wire [31:0] browse_lba,
    output reg         browse_busy,
    output reg         browse_done,
    output reg         browse_err,
    output reg  [3:0]  browse_err_code,
    input  wire [8:0]  browse_raddr,
    output wire [7:0]  browse_rdata,

    // host fill port for the same 512-byte sector buffer
    input  wire        write_buf_we,
    input  wire [8:0]  write_buf_addr,
    input  wire [7:0]  write_buf_data,
    input  wire        write_go,
    input  wire [31:0] write_lba,
    output reg         write_busy,
    output reg         write_done,
    output reg         write_err,
    output reg  [3:0]  write_err_code,

    output reg         nr_wr,
    output reg  [19:0] nr_waddr,
    output reg  [7:0]  nr_wdata,
    input  wire        nr_busy,
    output reg         nr_fill_start,
    output reg         nr_fill_done,

    // raw SD engine
    output reg         sd_start,
    output reg         sd_write_start,
    output reg  [31:0] sd_lba,
    output wire        sd_stall,
    input  wire        sd_busy,
    input  wire        sd_done,
    input  wire        sd_dvalid,
    input  wire [7:0]  sd_dout,
    input  wire [8:0]  sd_waddr,
    output wire [7:0]  sd_wdata,
    input  wire        sd_card_ready,
    input  wire        sd_card_err,
    input  wire [3:0]  sd_err_code
);
    localparam
        S_IDLE       = 5'd0,
        S_KICK       = 5'd1,
        S_WAIT_BUSY  = 5'd2,
        S_STREAM     = 5'd3,
        S_BLOCK_DONE = 5'd4,
        S_FINISH     = 5'd5,
        S_ERROR      = 5'd6,
        S_BR_KICK    = 5'd7,
        S_BR_WAIT    = 5'd8,
        S_BR_STREAM  = 5'd9,
        S_BR_DONE    = 5'd10,
        S_BR_ERROR   = 5'd11,
        S_BW_KICK    = 5'd12,
        S_BW_WAIT    = 5'd13,
        S_BW_RUN     = 5'd14,
        S_BW_DONE    = 5'd15,
        S_BW_ERROR   = 5'd16;

    reg [4:0]  st;
    reg [31:0] cur_lba;
    reg [11:0] blocks_left;
    reg [19:0] waddr;
    reg [8:0]  byte_in_block;

    reg [7:0] sector_buf [0:511];
    reg [8:0] br_idx;
    assign browse_rdata = sector_buf[browse_raddr];
    assign sd_wdata = sector_buf[sd_waddr];

    reg        pend_valid;
    reg [7:0]  pend_byte;
    reg [19:0] pend_addr;
    assign sd_stall = pend_valid;

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            st<=S_IDLE; busy<=1'b0; done_sticky<=1'b0; err<=1'b0; err_code<=4'd0;
            browse_busy<=1'b0; browse_done<=1'b0; browse_err<=1'b0; browse_err_code<=4'd0;
            write_busy<=1'b0; write_done<=1'b0; write_err<=1'b0; write_err_code<=4'd0;
            br_idx<=9'd0;
            nr_wr<=1'b0; nr_waddr<=20'd0; nr_wdata<=8'd0; nr_fill_start<=1'b0; nr_fill_done<=1'b0;
            sd_start<=1'b0; sd_write_start<=1'b0; sd_lba<=32'd0;
            cur_lba<=32'd0; blocks_left<=12'd0; waddr<=20'd0; byte_in_block<=9'd0;
            pend_valid<=1'b0; pend_byte<=8'd0; pend_addr<=20'd0;
        end else begin
            nr_fill_start <= 1'b0;
            nr_fill_done  <= 1'b0;
            sd_start      <= 1'b0;
            sd_write_start<= 1'b0;

            // LPC writes may fill the staging buffer only while the SD engine
            // is idle.  The host always completes all 512 writes before GO.
            if (write_buf_we && st == S_IDLE)
                sector_buf[write_buf_addr] <= write_buf_data;

            if (start && st != S_IDLE) begin err<=1'b1; err_code<=4'd13; done_sticky<=1'b1; end
            if (browse_go && st != S_IDLE) begin browse_err<=1'b1; browse_err_code<=4'd13; browse_done<=1'b1; end
            if (write_go && st != S_IDLE) begin write_err<=1'b1; write_err_code<=4'd13; write_done<=1'b1; end

            if (nr_wr) begin
                nr_wr <= 1'b0;
            end else if (pend_valid && !nr_busy) begin
                nr_wr<=1'b1; nr_waddr<=pend_addr; nr_wdata<=pend_byte; pend_valid<=1'b0;
            end

            case (st)
                S_IDLE: begin
                    if (start) begin
                        if (!sd_card_ready) begin err<=1'b1; err_code<=4'd14; done_sticky<=1'b1; end
                        else begin
                            done_sticky<=1'b0; err<=1'b0; err_code<=4'd0;
                            cur_lba<=lba; blocks_left<=blkcnt; waddr<=20'd0; byte_in_block<=9'd0;
                            busy<=1'b1; nr_fill_start<=1'b1; st<=S_KICK;
                        end
                    end else if (browse_go) begin
                        if (!sd_card_ready) begin browse_err<=1'b1; browse_err_code<=4'd14; browse_done<=1'b1; end
                        else begin
                            browse_done<=1'b0; browse_err<=1'b0; browse_err_code<=4'd0;
                            br_idx<=9'd0; browse_busy<=1'b1; st<=S_BR_KICK;
                        end
                    end else if (write_go) begin
                        if (!sd_card_ready) begin write_err<=1'b1; write_err_code<=4'd14; write_done<=1'b1; end
                        else begin
                            write_done<=1'b0; write_err<=1'b0; write_err_code<=4'd0;
                            write_busy<=1'b1; sd_lba<=write_lba; st<=S_BW_KICK;
                        end
                    end
                end

                // bulk precache read
                S_KICK: begin sd_lba<=cur_lba; sd_start<=1'b1; byte_in_block<=9'd0; st<=S_WAIT_BUSY; end
                S_WAIT_BUSY: begin
                    if (sd_card_err) begin err_code<=sd_err_code; st<=S_ERROR; end
                    else if (sd_busy) st<=S_STREAM;
                end
                S_STREAM: begin
                    if (sd_card_err) begin err_code<=sd_err_code; st<=S_ERROR; end
                    else if (sd_dvalid) begin
                        pend_valid<=1'b1; pend_byte<=sd_dout; pend_addr<=waddr;
                        waddr<=waddr+20'd1; byte_in_block<=byte_in_block+9'd1;
                    end else if (sd_done) st<=S_BLOCK_DONE;
                end
                S_BLOCK_DONE: begin
                    if (blocks_left==12'd1) st<=S_FINISH;
                    else begin cur_lba<=cur_lba+32'd1; blocks_left<=blocks_left-12'd1; st<=S_KICK; end
                end
                S_FINISH: begin
                    if (!pend_valid && !nr_wr && !nr_busy) begin nr_fill_done<=1'b1; busy<=1'b0; done_sticky<=1'b1; st<=S_IDLE; end
                end
                S_ERROR: begin busy<=1'b0; err<=1'b1; done_sticky<=1'b1; st<=S_IDLE; end

                // one-sector browse read
                S_BR_KICK: begin sd_lba<=browse_lba; sd_start<=1'b1; br_idx<=9'd0; st<=S_BR_WAIT; end
                S_BR_WAIT: begin
                    if (sd_card_err) begin browse_err_code<=sd_err_code; st<=S_BR_ERROR; end
                    else if (sd_busy) st<=S_BR_STREAM;
                end
                S_BR_STREAM: begin
                    if (sd_card_err) begin browse_err_code<=sd_err_code; st<=S_BR_ERROR; end
                    else if (sd_dvalid) begin sector_buf[br_idx]<=sd_dout; br_idx<=br_idx+9'd1; end
                    else if (sd_done) st<=S_BR_DONE;
                end
                S_BR_DONE: begin browse_busy<=1'b0; browse_done<=1'b1; st<=S_IDLE; end
                S_BR_ERROR: begin browse_busy<=1'b0; browse_err<=1'b1; browse_done<=1'b1; st<=S_IDLE; end

                // one-sector buffered write
                S_BW_KICK: begin sd_lba<=write_lba; sd_write_start<=1'b1; st<=S_BW_WAIT; end
                S_BW_WAIT: begin
                    // Wait until eos_sd_spi has accepted write_start. It clears
                    // any sticky error from the previous transaction as part of
                    // that accept, so do not sample card_err before busy rises.
                    if (sd_busy) st<=S_BW_RUN;
                end
                S_BW_RUN: begin
                    if (sd_card_err) begin write_err_code<=sd_err_code; st<=S_BW_ERROR; end
                    else if (sd_done) st<=S_BW_DONE;
                end
                S_BW_DONE: begin write_busy<=1'b0; write_done<=1'b1; st<=S_IDLE; end
                S_BW_ERROR: begin write_busy<=1'b0; write_err<=1'b1; write_done<=1'b1; st<=S_IDLE; end
                default: st<=S_IDLE;
            endcase
        end
    end
endmodule
