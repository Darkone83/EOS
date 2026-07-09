// eos_lpc_loader.v -- Direct-LCLK LPC responder.
//
// Runs directly on the Xbox LPC clock (lpc_lclk). Serves MEM_READ from the
// SDRAM backend, consumes MEM_WRITE, and implements the Xenium-compatible
// I/O ports 0xEC..0xEF.
//
// Phase sequence (one LPC clock per state):
//   TAR1          Hi-Z
//   TAR2          1111
//   SYNCING       0101 until byte_ready, or SYNC_TIMEOUT expires
//   SYNC_COMPLETE 0000
//   READ_DATA0    low nibble
//   READ_DATA1    high nibble
//   TAR_EXIT      1111
//   SYNC_ABORT    1010   (timeout only)
//
// =============================================================================
// PHASE 2 -- THE STALL CLASS. Read this before touching any of it.
// =============================================================================
//
// (1) SYNCING now has a timeout.
//     It used to spin on byte_ready forever. If the backend never answered (it
//     cannot serve LPC reads while running a multi-second flash->SDRAM fill),
//     the loader parked driving 0101 on LAD and -- because serving_mem keys off
//     the registered cycle_type, cleared only at TAR_EXIT -- also held LFRAME#
//     LOW indefinitely on a 1.6 board. Bus wedge.
//
//     On timeout it drives SYNC=1010 (LPC "error") for one clock, then TAR_EXIT
//     (1111), then releases. The host is free to retry.
//
// (2) The unconditional mem_valid latch is GONE, and that is NOT optional.
//     (1) creates a hazard that did not previously exist: once the loader can
//     walk away from a cycle, a late mem_valid from the abandoned request
//     arrives ORPHANED during some later, unrelated transaction. The old
//     unconditional latch would overwrite read_buffer with it and serve the
//     wrong byte. Silent corruption is worse than a hang.
//
//     mem_valid is now accepted ONLY when ALL of:
//         cycle_type == CYC_MEM_READ    (a memory read is in flight)
//         !byte_ready                   (nothing captured yet)
//         state in {TAR1, TAR2, SYNCING} (inside the response window)
//
//     eos_sdram_backend independently DROPS a request it could not serve within
//     REQ_TIMEOUT sclk (~15.8 us), sized to land ~45 us BEFORE this module's
//     SYNC_TIMEOUT (~61.4 us). An orphan therefore cannot be generated at all.
//     The gate here is the second line of defence. KEEP BOTH.
//
// =============================================================================
// PHASE 3 -- I/O PORT DECODE
// =============================================================================
//
//     The I/O decode used to be:
//         lpc_addr[7:4] == 4'hE  &&  lad_in[3:2] == 2'b11
//     with lpc_addr[15:8] never examined. That matches 1024 distinct 16-bit I/O
//     ports, not 4: 0x00EC, 0x01EC, 0x02EC, ... 0xFFEF. Eos drove SYNC on every
//     one of them -- it answered I/O cycles belonging to other LPC devices.
//
//     Worse, WRITE_DATA1 then switched on lpc_addr[1:0] alone, so a foreign I/O
//     write to (say) 0x02EF would pulse ef_wr and CHANGE THE SERVED BANK.
//
//     No known retail-Xbox LPC consumer sits at an alias, which is why this
//     never bit. It is still wrong. The decode is now an exact 16-bit match:
//         io_port[15:2] == 14'h003B      (0x00EC >> 2)
//     covering exactly 0x00EC / 0x00ED / 0x00EE / 0x00EF, and WRITE_DATA1
//     compares the full 16-bit address for 0xEF.
//
//     NOT fixed (would need LFRAME#, which this build ignores): after declining
//     an unsupported I/O cycle the loader returns to WAIT_START while the host is
//     still driving that cycle's remaining nibbles. A 0000 data nibble can
//     therefore look like a START. The nibble after it is a TAR (1111), which
//     fails the CYCTYPE decode and drops straight back to WAIT_START, so it is
//     self-correcting -- but it is why WAIT_START must stay cheap.
//
// =============================================================================
//
// (3) Dead logic removed (provably unreachable / never read):
//         response_armed   -- written six times, read nowhere
//         sync_wait        -- MIN_SYNC_WAIT was 0, the countdown never ran
//         reg_00ee_write   -- written, never read back; 0xEE reads return 0x55
//         parameter SYNC   -- unused
//     External behaviour is unchanged: a write to 0xEE is still consumed and
//     ACKed, it just no longer lands in a register nothing reads.
//
// =============================================================================
// KNOWN BEHAVIOUR / DELIBERATE DEVIATIONS
// =============================================================================
//
//   * LFRAME# is NOT used to gate START. WAIT_START triggers on any 0000 nibble
//     on LAD. lframe_n_pin is accepted and ignored.
//
//   * Memory address decode ignores A31:A21 and captures only A20:A0. Eos
//     answers a memory read at ANY 4 GB address whose low 21 bits match. This
//     matches OpenXenium and is safe on a real console.
//
//   * I/O decode is an exact 16-bit match on 0x00EC..0x00EF. It used to test
//     only lpc_addr[7:4]==0xE and the low two bits, which claimed 1024 ports
//     (0x01EC, 0x02EF, 0x80EE, ...) rather than 4. See PHASE 3 below.
//
//   * D0 is externally grounded on this build; the FPGA does not drive it.

module eos_lpc_loader #(
    // LPC clocks to wait in SYNCING before abandoning the cycle.
    // 2048 @ 33.33 MHz = 61.4 us. Worst legitimate serve latency is ~2.8 us
    // (a request landing just after the backend starts a single-byte SPI read
    // at SCK_DIV=2), so this is ~22x margin and cannot fire in normal use.
    // MUST be comfortably greater, in wall-clock terms, than the backend's
    // REQ_TIMEOUT -- see note (2).
    parameter integer SYNC_TIMEOUT = 2048
)(
    input  wire        clk,                 // DIRECT: Xbox LPC LCLK
    input  wire        lreset_n,

    input  wire        lclk_pin,            // unused in direct-LCLK mode
    input  wire        lframe_n_pin,        // accepted, not used to gate START
    input  wire [3:0]  lad_pin,

    output reg  [3:0]  lad_out,
    output wire        lad_oe,

    output reg         mem_req,
    output wire [20:0] mem_addr,        // full 2MB logical address (A20:A0), no 256K wrap
    input  wire        mem_valid,
    input  wire [7:0]  mem_data,

    // Bank register exposure (0xEF). Lets the bank controller see selections
    // without re-decoding LPC. ef_wr pulses 1 cycle on a 0xEF write.
    output reg         ef_wr,
    output reg  [7:0]  ef_data,          // value written to 0xEF (low nibble = bank)

    // Generic I/O write exposure for the flash command bridge (0xEC/0xED).
    // io_wr_stb pulses 1 cycle on ANY committed I/O write; the bridge filters
    // for its own ports. cmd_rd_data feeds the read path for a 0xED read.
    output reg         io_wr_stb,
    output reg  [15:0] io_wr_addr,
    output reg  [7:0]  io_wr_data,
    output reg         io_rd_stb,        // 1-cycle pulse on a committed I/O read
    output reg  [15:0] io_rd_addr,
    input  wire [7:0]  cmd_rd_data,

    output reg  [3:0]  state,
    // 1.6 LFRAME abort window. See the serving_mem assign below for the exact
    // (and only) statement of what this signal does.
    output wire        serving_mem
);

    // Keep the original HUD-friendly state numbering.
    localparam WAIT_START    = 4'd0;
    localparam CYCTYPE       = 4'd1;
    localparam ADDRESS       = 4'd2;
    localparam TAR1          = 4'd3;
    localparam TAR2          = 4'd4;
    localparam SYNCING       = 4'd5;
    localparam SYNC_COMPLETE = 4'd6;
    localparam READ_DATA0    = 4'd7;
    localparam READ_DATA1    = 4'd8;
    localparam TAR_EXIT      = 4'd9;
    localparam WRITE_DATA0   = 4'd10;
    localparam WRITE_DATA1   = 4'd11;
    localparam SYNC_ABORT    = 4'd12;   // NEW: timeout -> drive SYNC error

    localparam [1:0] CYC_IO_READ   = 2'd0;
    localparam [1:0] CYC_IO_WRITE  = 2'd1;
    localparam [1:0] CYC_MEM_READ  = 2'd2;
    localparam [1:0] CYC_MEM_WRITE = 2'd3;

    // I/O port block: 0x00EC..0x00EF. One 14-bit compare on the upper bits of
    // the full 16-bit address covers all four and nothing else.
    //   0x00EC >> 2 == 14'h003B
    localparam [13:0] IO_PORT_BLK = 14'h003B;
    localparam [15:0] PORT_00EF   = 16'h00EF;

    // LPC SYNC field encodings driven by the target.
    localparam [3:0] SYNC_READY = 4'b0000;   // ready, data follows
    localparam [3:0] SYNC_WAIT  = 4'b0101;   // short wait
    localparam [3:0] SYNC_ERR   = 4'b1010;   // error, no data

    // Avoid unused warnings.
    wire _unused_lclk   = lclk_pin;

    wire [3:0] lad_in = lad_pin;
    wire _unused_lframe = lframe_n_pin;

    // -------------------------------------------------------------------------
    // Transaction state
    // -------------------------------------------------------------------------

    reg [1:0]  cycle_type;

    reg [20:0] lpc_addr;
    reg [20:0] mem_addr_r;

    reg [3:0]  count;

    // read_buffer is the pushed LPC response byte.
    reg [7:0]  read_buffer;
    reg [7:0]  write_data;

    reg        byte_ready;

    // SYNCING watchdog.
    localparam integer SYNC_CNT_W = 16;
    reg [SYNC_CNT_W-1:0] sync_cnt;

    // Minimal Xenium-compatible register.
    reg [7:0] reg_00ef_write;

    wire [7:0] reg_00ee_read = 8'h55;
    wire [7:0] reg_00ef_read = reg_00ef_write;   // echo last write so SW can verify the 0xEF path

    assign mem_addr = mem_addr_r;

    // -------------------------------------------------------------------------
    // LAD output ownership
    // -------------------------------------------------------------------------
    //
    // Target drives only during target-owned response phases.
    // TAR1 and host WRITE_DATA phases remain Hi-Z.

    assign lad_oe = (state == TAR2)          ||
                    (state == SYNCING)       ||
                    (state == SYNC_COMPLETE) ||
                    (state == SYNC_ABORT)    ||
                    (state == READ_DATA0)    ||
                    (state == READ_DATA1)    ||
                    (state == TAR_EXIT);

    // -------------------------------------------------------------------------
    // serving_mem -- the 1.6 LFRAME# abort window
    // -------------------------------------------------------------------------
    //
    // WHAT THIS ACTUALLY DOES (verified against the RTL, 1.6 boots with it):
    //
    //   serving_mem is high whenever the REGISTERED cycle_type is a memory
    //   cycle (read or write). cycle_type is assigned at the CYCTYPE decode and
    //   takes effect on entry to ADDRESS; it is cleared back to CYC_IO_READ in
    //   TAR_EXIT.
    //
    //   So the window is:  ADDRESS -> ... -> TAR_EXIT (inclusive).
    //   It is LOW during CYCTYPE (the cycle right after START) and LOW again in
    //   WAIT_START. LFRAME# therefore DOES lift in the gap between consecutive
    //   boot mem-reads. It is a per-cycle held window, not a continuous hold
    //   across a burst.
    //
    //   Asserting LFRAME# during CYCTYPE would read as a new frame-start to the
    //   MCPX and abort the cycle before the loader can serve it -- hence the
    //   one-clock delay is load-bearing, not incidental.
    //
    //   MEM_WRITE is included, as OpenXenium does.
    //
    //   A SYNCING timeout routes through SYNC_ABORT -> TAR_EXIT, so cycle_type
    //   is cleared and LFRAME# released on exactly the same edge as a normal
    //   cycle. The window is now provably bounded by SYNC_TIMEOUT + 3 clocks.
    //
    assign serving_mem = (cycle_type == CYC_MEM_READ) ||
                         (cycle_type == CYC_MEM_WRITE);

    // -------------------------------------------------------------------------
    // Response acceptance window for mem_valid.
    // -------------------------------------------------------------------------
    //
    // mem_req pulses in ADDRESS(count==0) and state goes to TAR1 on that same
    // edge, so the earliest a response can be observed is TAR1. It must be
    // consumed no later than SYNCING, the only state that waits on it. Anything
    // outside this window is an orphan from an abandoned cycle.
    // Full 16-bit I/O address during the final ADDRESS nibble: the upper 12 bits
    // were registered on earlier nibbles, the last 4 are live on LAD this cycle.
    wire [15:0] io_port = {lpc_addr[15:4], lad_in};

    wire mem_resp_window = (state == TAR1) || (state == TAR2) || (state == SYNCING);
    wire mem_accept      = mem_valid && (cycle_type == CYC_MEM_READ)
                                     && !byte_ready
                                     && mem_resp_window;

    always @(*) begin
        case (state)
            TAR2:          lad_out = 4'b1111;             // target turnaround
            SYNCING:       lad_out = SYNC_WAIT;           // 0101 wait sync
            SYNC_COMPLETE: lad_out = SYNC_READY;          // 0000 ready
            SYNC_ABORT:    lad_out = SYNC_ERR;            // 1010 error, no data
            READ_DATA0:    lad_out = read_buffer[3:0];    // low nibble first
            READ_DATA1:    lad_out = read_buffer[7:4];    // high nibble second
            TAR_EXIT:      lad_out = 4'b1111;             // peripheral-to-host turnaround
            default:       lad_out = 4'b1111;
        endcase
    end

    // -------------------------------------------------------------------------
    // Main LPC FSM
    // -------------------------------------------------------------------------

    always @(posedge clk or negedge lreset_n) begin
        if (!lreset_n) begin
            state          <= WAIT_START;

            cycle_type     <= CYC_IO_READ;

            lpc_addr       <= 21'd0;
            mem_addr_r     <= 21'd0;

            count          <= 4'd0;

            read_buffer    <= 8'd0;
            write_data     <= 8'd0;

            byte_ready     <= 1'b0;
            sync_cnt       <= {SYNC_CNT_W{1'b0}};

            reg_00ef_write <= 8'h01;

            mem_req        <= 1'b0;
            ef_wr          <= 1'b0;
            ef_data        <= 8'd0;

            io_wr_stb      <= 1'b0;
            io_wr_addr     <= 16'd0;
            io_wr_data     <= 8'd0;
            io_rd_stb      <= 1'b0;
            io_rd_addr     <= 16'd0;
        end else begin
            mem_req <= 1'b0;
            ef_wr   <= 1'b0;
            io_wr_stb <= 1'b0;
            io_rd_stb <= 1'b0;

            // MEM_READ backend result.
            //
            // Gated: only a memory read, only before a byte has been captured,
            // and only inside TAR1..SYNCING. See note (2) in the header. Do NOT
            // relax this back to an unconditional latch -- with the SYNCING
            // timeout in place, that reintroduces orphaned-response corruption.
            if (mem_accept) begin
                read_buffer <= mem_data;
                byte_ready  <= 1'b1;
            end

            case (state)

                // -------------------------------------------------------------
                // LPC START.
                // START field is 0000.
                // LFRAME# is intentionally not required in this build.
                // -------------------------------------------------------------
                WAIT_START: begin
                    lpc_addr       <= 21'd0;
                    count          <= 4'd0;
                    byte_ready     <= 1'b0;

                    if (lad_in == 4'h0)
                        state <= CYCTYPE;
                end

                // -------------------------------------------------------------
                // Cycle type.
                //
                // LPC encodings:
                //   000x = IO read
                //   001x = IO write
                //   010x = memory read
                //   011x = memory write
                //
                // cycle_type assigned here becomes visible (and raises
                // serving_mem) on entry to ADDRESS, one clock later.
                // -------------------------------------------------------------
                CYCTYPE: begin
                    lpc_addr       <= 21'd0;
                    byte_ready     <= 1'b0;

                    if (lad_in[3:1] == 3'b000) begin
                        cycle_type <= CYC_IO_READ;
                        count      <= 4'd3;
                        state      <= ADDRESS;
                    end else if (lad_in[3:1] == 3'b001) begin
                        cycle_type <= CYC_IO_WRITE;
                        count      <= 4'd3;
                        state      <= ADDRESS;
                    end else if (lad_in[3:1] == 3'b010) begin
                        cycle_type <= CYC_MEM_READ;
                        count      <= 4'd7;
                        state      <= ADDRESS;
                    end else if (lad_in[3:1] == 3'b011) begin
                        cycle_type <= CYC_MEM_WRITE;
                        count      <= 4'd7;
                        state      <= ADDRESS;
                    end else begin
                        state <= WAIT_START;
                    end
                end

                // -------------------------------------------------------------
                // Address capture.
                //
                // Memory cycles (8 nibbles, A31:A0):
                //   count 7 : A31:A28  -- DISCARDED
                //   count 6 : A27:A24  -- DISCARDED
                //   count 5 : A23:A20  -- only LAD[0] kept (A20); A23:A21 discarded
                //   count 4 : captures A19:A16
                //   count 3 : captures A15:A12
                //   count 2 : captures A11:A8
                //   count 1 : captures A7:A4
                //   count 0 : captures A3:A0
                //
                // Consequence: the module answers any memory read whose low 21
                // bits match, regardless of A31:A21. Matches OpenXenium.
                //
                // IO cycles (4 nibbles, A15:A0):
                //   count 3 : A15:A12
                //   count 2 : A11:A8
                //   count 1 : A7:A4
                //   count 0 : A3:A0
                //
                // The I/O port decode is an EXACT 16-bit match (see PHASE 3 in
                // the header). io_port is the full address: the upper 12 bits are
                // already registered in lpc_addr, the last nibble is live on LAD.
                // -------------------------------------------------------------
                ADDRESS: begin
                    if (cycle_type == CYC_MEM_READ || cycle_type == CYC_MEM_WRITE) begin
                        if (count == 4'd5) begin
                            lpc_addr[20] <= lad_in[0];
                        end else if (count == 4'd4) begin
                            lpc_addr[19:16] <= lad_in;
                        end else if (count == 4'd3) begin
                            lpc_addr[15:12] <= lad_in;
                        end else if (count == 4'd2) begin
                            lpc_addr[11:8] <= lad_in;
                        end else if (count == 4'd1) begin
                            lpc_addr[7:4] <= lad_in;
                        end else if (count == 4'd0) begin
                            lpc_addr[3:0] <= lad_in;

                            // Full 21-bit logical address (A20:A0) handed to the
                            // backend, which applies the per-bank xlate.
                            mem_addr_r <= {
                                lpc_addr[20:4],
                                lad_in
                            };

                            if (cycle_type == CYC_MEM_READ) begin
                                // Request byte from SDRAM backend.
                                mem_req    <= 1'b1;
                                byte_ready <= 1'b0;
                                state      <= TAR1;
                            end else begin
                                // MEM_WRITE: consume two host data nibbles, then ACK.
                                write_data <= 8'd0;
                                state      <= WRITE_DATA0;
                            end
                        end
                    end else begin
                        // IO address collection: A15..A0.
                        if (count == 4'd3) begin
                            lpc_addr[15:12] <= lad_in;
                        end else if (count == 4'd2) begin
                            lpc_addr[11:8] <= lad_in;
                        end else if (count == 4'd1) begin
                            lpc_addr[7:4] <= lad_in;
                        end else if (count == 4'd0) begin
                            lpc_addr[3:0] <= lad_in;

                            // Exactly 0x00EC..0x00EF, nothing else:
                            //   EC/ED = flash command bridge (index/data)
                            //   EE    = LED register (read returns constant 0x55)
                            //   EF    = bank register
                            if (io_port[15:2] == IO_PORT_BLK) begin
                                if (cycle_type == CYC_IO_READ) begin
                                    case (lad_in[1:0])
                                        2'b10:   read_buffer <= reg_00ee_read;  // 0xEE
                                        2'b11:   read_buffer <= reg_00ef_read;  // 0xEF
                                        default: read_buffer <= cmd_rd_data;    // 0xEC/0xED
                                    endcase

                                    // generic read strobe (bridge advances its
                                    // page-buffer pointer on a 0xED read)
                                    io_rd_stb  <= 1'b1;
                                    io_rd_addr <= {lpc_addr[15:4], lad_in};

                                    byte_ready <= 1'b1;
                                    state      <= TAR1;
                                end else begin
                                    write_data <= 8'd0;
                                    state      <= WRITE_DATA0;
                                end
                            end else begin
                                // Unsupported IO cycle: ignore and release.
                                state <= WAIT_START;
                            end
                        end
                    end

                    if (count != 4'd0)
                        count <= count - 1'b1;
                end

                // -------------------------------------------------------------
                // Write data phase.
                // Host supplies low nibble first, then high nibble.
                // FPGA remains Hi-Z here.
                // -------------------------------------------------------------
                WRITE_DATA0: begin
                    write_data[3:0] <= lad_in;
                    state           <= WRITE_DATA1;
                end

                WRITE_DATA1: begin
                    write_data[7:4] <= lad_in;

                    // Commit minimal IO writes.
                    // MEM_WRITE is consumed and ACKed, but not written to SDRAM.
                    if (cycle_type == CYC_IO_WRITE) begin
                        // Generic strobe: the flash command bridge consumes
                        // 0xEC/0xED and matches the full 16-bit address itself.
                        // Reaching here at all already required an exact
                        // 0x00EC..0x00EF match back in ADDRESS.
                        io_wr_stb  <= 1'b1;
                        io_wr_addr <= lpc_addr[15:0];
                        io_wr_data <= {lad_in, write_data[3:0]};

                        // Full 16-bit compare, not lpc_addr[1:0]. 0xEE is
                        // consumed and ACKed but not stored: nothing ever read
                        // the old reg_00ee_write, and 0xEE reads return 0x55.
                        if (lpc_addr[15:0] == PORT_00EF) begin
                            reg_00ef_write <= {lad_in, write_data[3:0]};
                            ef_wr          <= 1'b1;
                            ef_data        <= {lad_in, write_data[3:0]};
                        end
                    end

                    byte_ready <= 1'b1;
                    state      <= TAR1;
                end

                // -------------------------------------------------------------
                // Host-to-target turnaround.
                // Hi-Z for one LPC clock.
                // -------------------------------------------------------------
                TAR1: begin
                    state <= TAR2;
                end

                // -------------------------------------------------------------
                // Target turnaround.
                // Drive 1111 for one LPC clock.
                // -------------------------------------------------------------
                TAR2: begin
                    sync_cnt <= {SYNC_CNT_W{1'b0}};
                    state    <= SYNCING;
                end

                // -------------------------------------------------------------
                // Wait-sync. Drive 0101 until byte_ready, or give up.
                //
                // byte_ready is already set on entry for I/O reads and for all
                // write ACKs, so this costs exactly one clock for those. Only a
                // MEM_READ can actually wait here.
                // -------------------------------------------------------------
                SYNCING: begin
                    if (byte_ready) begin
                        state <= SYNC_COMPLETE;
                    end else if (sync_cnt == SYNC_TIMEOUT[SYNC_CNT_W-1:0] - 1'b1) begin
                        // Backend never answered. Abandon the cycle cleanly
                        // rather than hanging LAD and LFRAME# forever.
                        state <= SYNC_ABORT;
                    end else begin
                        sync_cnt <= sync_cnt + 1'b1;
                    end
                end

                // -------------------------------------------------------------
                // Timeout exit: drive SYNC=1010 (error) for one clock, then the
                // normal turnaround. No data phase. cycle_type is cleared in
                // TAR_EXIT, releasing LFRAME# on the usual edge.
                // -------------------------------------------------------------
                SYNC_ABORT: begin
                    state <= TAR_EXIT;
                end

                // -------------------------------------------------------------
                // Fixed push sequence begins here.
                //
                // read_buffer is stable from this point: mem_accept requires
                // mem_resp_window, which excludes every state below.
                // -------------------------------------------------------------
                SYNC_COMPLETE: begin
                    if (cycle_type == CYC_MEM_READ || cycle_type == CYC_IO_READ)
                        state <= READ_DATA0;
                    else
                        state <= TAR_EXIT;
                end

                READ_DATA0: begin
                    state <= READ_DATA1;
                end

                READ_DATA1: begin
                    state <= TAR_EXIT;
                end

                // Clearing cycle_type here is what drops serving_mem (and thus
                // LFRAME#) at the end of every served OR abandoned cycle.
                TAR_EXIT: begin
                    cycle_type <= CYC_IO_READ;
                    state      <= WAIT_START;
                end

                default: begin
                    state <= WAIT_START;
                end

            endcase
        end
    end

endmodule