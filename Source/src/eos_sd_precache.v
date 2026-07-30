// eos_sd_precache.v -- SD card sequencer: bulk NRGN_SD precache + single-
// sector browse readback. Sole owner of the one eos_sd_spi instance (one
// physical SD bus, one reader) -- the two commands below are mutually
// exclusive in time, never concurrent, and this module enforces that by
// simply ignoring a 'start'/'browse_go' pulse that arrives while busy with
// the other. That's a real, deliberate contract, not an oversight: the
// loader browses the card (many single-sector reads) BEFORE ever kicking a
// precache, and never needs to do both at once.
//
// ---- Command 1: bulk precache (unchanged from before) ----
// Pages a chosen BIOS image off the SD card directly into the SAME ext-region
// SDRAM lane (NRGN_SD) that oversized flash banks already use, via
// eos_sdram_backend.v's existing nr_wr/nr_waddr/nr_wdata + nr_fill_start/
// nr_fill_done hooks. NEVER TOUCHES FLASH -- the image stages in SDRAM for
// one boot and nothing is written to on-board flash.
//
// After a precache completes, the loader launches it EXACTLY like XbDiag:
//   out 0xEF, 0x0              ; select bank 0x0 (already a working, live-served
//                               ; bank -- see eos_sdram_backend.v's bank0_is_nr
//                               ; path, sized by nr_szc)
//   SMC warm reset
// No new EF nibble, no gateware serve-path changes -- 0x0 already does exactly
// this for flash-sourced large banks (Flash_SyncNewRegion). This module is
// just a second, SD-sourced way to fill the same lane.
//
// One card read = one 512-byte SD sector = one byte-for-byte copy into
// nr_waddr. blkcnt sectors are read back-to-back, LBA incrementing by 1 each
// time (eos_sd_spi's CMD17 is single-block only -- no CMD18 multi-block read
// in this first cut; fine for a one-time BIOS precache, revisit only if the
// per-sector command overhead is ever actually a problem on hardware).
//
// ---- Command 2: browse read (NEW) ----
// Reads exactly one arbitrary 512-byte sector off the card into an on-chip
// buffer, which the loader then streams out over LPC one byte at a time via
// eos_flash_cmd's SD_BR_BUF register (same auto-increment streaming-read
// shape as the existing engine page-buffer/IDX_PBUF path). This is what the
// (not-yet-built) FAT32 driver uses to read the root directory, FAT table,
// and cluster-chain entries in software -- the gateware has zero filesystem
// knowledge, purely raw sector-in/bytes-out. READ ONLY: there is no write
// command anywhere in this path or in eos_sd_spi.v (CMD24 was never built,
// not disabled) -- the card is written from a PC, never by this project.
// The 512-byte buffer is plain on-chip storage (BSRAM-inferred); reading it
// never touches the card again until the next browse_go.

module eos_sd_precache (
    input  wire        clk,     // clk_sd domain -- same as eos_sd_spi and
    input  wire        rstn,    // eos_sdram_backend's sclk/sresetn

    // ---- command interface: bulk precache (from eos_flash_cmd) ----
    input  wire        start,        // pulse: begin (lba/blkcnt must already be valid)
    input  wire [31:0] lba,          // starting SD sector (LBA)
    input  wire [11:0] blkcnt,       // sector count: 256K=512, 512K=1024, 1MB=2048
    output reg         busy,
    output reg         done_sticky,  // cleared by the next 'start'
    output reg         err,
    output reg  [3:0]  err_code,     // 0=none; 1-8 = passthrough from eos_sd_spi
                                     // (see its err_code); 13=refused, a browse
                                     // read was in progress; 14=card not ready
                                     // at 'start' (init still running or failed
                                     // before this run began)

    // ---- command interface: browse read, ONE sector (from eos_flash_cmd) ----
    input  wire        browse_go,        // pulse: read 'browse_lba' into the buffer
    input  wire [31:0] browse_lba,
    output reg         browse_busy,
    output reg         browse_done,      // sticky, cleared by the next browse_go
    output reg         browse_err,
    output reg  [3:0]  browse_err_code,  // 0=none; 1-8 = passthrough from
                                         // eos_sd_spi; 13=refused, a precache
                                         // run was in progress; 14=card not
                                         // ready
    // streaming readback of the 512-byte buffer -- mirrors eos_flash_cmd's
    // existing pb_raddr/pb_rdata (engine page-buffer) pattern exactly.
    input  wire [8:0]  browse_raddr,
    output wire [7:0]  browse_rdata,

    // ---- NRGN_SD fill port (to eos_sdram_backend, verbatim mirror of scr_wr) ----
    output reg         nr_wr,
    output reg  [19:0] nr_waddr,
    output reg  [7:0]  nr_wdata,
    input  wire        nr_busy,
    output reg         nr_fill_start,
    output reg         nr_fill_done,

    // ---- eos_sd_spi (raw card reader) ----
    output reg         sd_start,
    output reg  [31:0] sd_lba,
    output wire        sd_stall,     // backpressure -- see pend_valid below
    input  wire        sd_busy,
    input  wire        sd_done,
    input  wire        sd_dvalid,
    input  wire [7:0]  sd_dout,
    input  wire        sd_card_ready,
    input  wire        sd_card_err,
    input  wire [3:0]  sd_err_code
);
    localparam
        S_IDLE      = 4'd0,
        S_KICK      = 4'd1,   // pulse sd_start for the current sector
        S_WAIT_BUSY = 4'd2,   // wait for eos_sd_spi to actually go busy
        S_STREAM    = 4'd3,   // capture sd_dvalid bytes, drain into nr_wr
        S_BLOCK_DONE= 4'd4,   // sd_done seen; advance LBA / decrement blkcnt
        S_FINISH    = 4'd5,   // all sectors in -- pulse nr_fill_done
        S_ERROR     = 4'd6,
        S_BR_KICK   = 4'd7,   // browse: pulse sd_start for browse_lba
        S_BR_WAIT   = 4'd8,   // browse: wait for eos_sd_spi to go busy
        S_BR_STREAM = 4'd9,   // browse: capture the 512 bytes into sector_buf
        S_BR_DONE   = 4'd10,
        S_BR_ERROR  = 4'd11;

    reg [3:0]  st;
    reg [31:0] cur_lba;
    reg [11:0] blocks_left;
    reg [19:0] waddr;         // running byte offset into the NRGN_SD lane
    reg [8:0]  byte_in_block; // 0..511 (kept for readability/debug; not required for control flow)

    // ---- browse-read single-sector buffer (BSRAM-inferred, 512 bytes) ----
    reg [7:0] sector_buf [0:511];
    reg [8:0] br_idx;   // 0..511 write pointer while streaming a browse read in
    assign browse_rdata = sector_buf[browse_raddr];   // pure combinational read-out

    // one-entry pending-write buffer -- decouples sd_dvalid's byte rate from
    // nr_wr's accept latency, same shape as eos_flash_reader.v's stall
    // guarantee elsewhere in this project (one byte in flight, never two).
    reg        pend_valid;
    reg [7:0]  pend_byte;
    reg [19:0] pend_addr;

    // Real backpressure, not a hope: eos_sd_spi's byte_go is gated by !stall
    // in its ST_RD_DATA/ST_RD_CRC states, so holding sd_stall while a byte is
    // already waiting on NRGN_SD makes a second dvalid before the first
    // drains structurally impossible, not just usually-doesn't-happen. LPC
    // read contention in eos_sdram_backend's S_SERVE can genuinely push the
    // nr_wr accept latency past one SD byte period, so this isn't optional.
    assign sd_stall = pend_valid;

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            st <= S_IDLE; busy <= 1'b0; done_sticky <= 1'b0; err <= 1'b0; err_code <= 4'd0;
            browse_busy <= 1'b0; browse_done <= 1'b0; browse_err <= 1'b0; browse_err_code <= 4'd0;
            br_idx <= 9'd0;
            nr_wr <= 1'b0; nr_waddr <= 20'd0; nr_wdata <= 8'd0;
            nr_fill_start <= 1'b0; nr_fill_done <= 1'b0;
            sd_start <= 1'b0; sd_lba <= 32'd0;
            cur_lba <= 32'd0; blocks_left <= 12'd0; waddr <= 20'd0; byte_in_block <= 9'd0;
            pend_valid <= 1'b0; pend_byte <= 8'd0; pend_addr <= 20'd0;
        end else begin
            nr_fill_start <= 1'b0;   // both are 1-cycle pulses; default low each cycle
            nr_fill_done  <= 1'b0;
            sd_start      <= 1'b0;

            // ---- mutual-exclusion rejection: the two commands share the one
            // eos_sd_spi instance and can't run concurrently. A 'start' or
            // 'browse_go' that arrives while the OTHER operation owns the
            // reader is refused (not queued) -- the loader is expected to
            // serialize these (browse, then eventually one precache), and
            // this just makes a violation of that visible instead of silently
            // racing sd_start/sd_lba between two would-be owners. ----
            if (start && (st != S_IDLE)) begin
                err <= 1'b1; err_code <= 4'd13; done_sticky <= 1'b1;
            end
            if (browse_go && (st != S_IDLE)) begin
                browse_err <= 1'b1; browse_err_code <= 4'd13; browse_done <= 1'b1;
            end

            // ---- pending-byte dispatcher: runs regardless of st, so a byte
            // captured during S_STREAM keeps draining even if we've already
            // moved on to S_BLOCK_DONE while the last write finishes. ----
            if (nr_wr) begin
                nr_wr <= 1'b0;                 // one-cycle pulse per accepted byte
            end else if (pend_valid && !nr_busy) begin
                nr_wr     <= 1'b1;
                nr_waddr  <= pend_addr;
                nr_wdata  <= pend_byte;
                pend_valid<= 1'b0;
            end

            case (st)
                S_IDLE: begin
                    if (start) begin
                        if (!sd_card_ready) begin
                            err <= 1'b1; err_code <= 4'd14; done_sticky <= 1'b1;
                        end else begin
                            done_sticky <= 1'b0; err <= 1'b0; err_code <= 4'd0;
                            cur_lba <= lba; blocks_left <= blkcnt;
                            waddr <= 20'd0; byte_in_block <= 9'd0;
                            busy <= 1'b1;
                            nr_fill_start <= 1'b1;   // clear newrgn_ready NOW, up front
                            st <= S_KICK;
                        end
                    end else if (browse_go) begin
                        if (!sd_card_ready) begin
                            browse_err <= 1'b1; browse_err_code <= 4'd14; browse_done <= 1'b1;
                        end else begin
                            browse_done <= 1'b0; browse_err <= 1'b0; browse_err_code <= 4'd0;
                            br_idx <= 9'd0;
                            browse_busy <= 1'b1;
                            st <= S_BR_KICK;
                        end
                    end
                end

                S_KICK: begin
                    sd_lba <= cur_lba; sd_start <= 1'b1;
                    byte_in_block <= 9'd0;
                    st <= S_WAIT_BUSY;
                end
                S_WAIT_BUSY: begin
                    if (sd_card_err) begin err_code <= sd_err_code; st <= S_ERROR; end
                    else if (sd_busy) st <= S_STREAM;
                end
                S_STREAM: begin
                    // sd_dvalid can only ever arrive with pend_valid already
                    // clear -- sd_stall (= pend_valid) holds eos_sd_spi's byte
                    // engine idle at the boundary until this drains, so there
                    // is no double-capture case left to guard against.
                    if (sd_card_err) begin
                        err_code <= sd_err_code; st <= S_ERROR;
                    end else if (sd_dvalid) begin
                        pend_valid <= 1'b1; pend_byte <= sd_dout; pend_addr <= waddr;
                        waddr <= waddr + 20'd1; byte_in_block <= byte_in_block + 9'd1;
                    end else if (sd_done) begin
                        st <= S_BLOCK_DONE;
                    end
                end
                S_BLOCK_DONE: begin
                    if (blocks_left == 12'd1) begin
                        st <= S_FINISH;
                    end else begin
                        cur_lba     <= cur_lba + 32'd1;
                        blocks_left <= blocks_left - 12'd1;
                        st <= S_KICK;
                    end
                end
                S_FINISH: begin
                    // Don't declare done while a byte is still draining into
                    // NRGN_SD -- wait for the pending-write dispatcher to empty.
                    if (!pend_valid && !nr_wr && !nr_busy) begin
                        nr_fill_done <= 1'b1;
                        busy <= 1'b0; done_sticky <= 1'b1;
                        st <= S_IDLE;
                    end
                end
                S_ERROR: begin
                    busy <= 1'b0; err <= 1'b1; done_sticky <= 1'b1; st <= S_IDLE;
                end

                // ---------------- browse: one arbitrary sector -> sector_buf ----
                S_BR_KICK: begin
                    sd_lba <= browse_lba; sd_start <= 1'b1;
                    br_idx <= 9'd0;
                    st <= S_BR_WAIT;
                end
                S_BR_WAIT: begin
                    if (sd_card_err) begin
                        browse_err_code <= sd_err_code; st <= S_BR_ERROR;
                    end else if (sd_busy) st <= S_BR_STREAM;
                end
                S_BR_STREAM: begin
                    // No backpressure needed here -- sector_buf is a plain
                    // local register write, always ready in the same cycle a
                    // byte arrives, so sd_stall (tied to pend_valid, which
                    // this path never touches) simply never asserts and
                    // eos_sd_spi streams the whole sector unstalled.
                    if (sd_card_err) begin
                        browse_err_code <= sd_err_code; st <= S_BR_ERROR;
                    end else if (sd_dvalid) begin
                        sector_buf[br_idx] <= sd_dout;
                        br_idx <= br_idx + 9'd1;
                    end else if (sd_done) begin
                        st <= S_BR_DONE;
                    end
                end
                S_BR_DONE: begin
                    browse_busy <= 1'b0; browse_done <= 1'b1; st <= S_IDLE;
                end
                S_BR_ERROR: begin
                    browse_busy <= 1'b0; browse_err <= 1'b1; browse_done <= 1'b1; st <= S_IDLE;
                end
                default: st <= S_IDLE;
            endcase
        end
    end
endmodule