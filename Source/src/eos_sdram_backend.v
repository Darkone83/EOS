// eos_sdram_backend.v -- flash->SDRAM preloader + LPC server.
//
// SAFE TEST VERSION:
// - Reads SPI flash one byte at a time during preload.
// - Writes one byte to SDRAM before requesting the next flash byte.
// - Slower, but avoids burst-stream overwrite/corruption during preload.
// - Good for proving BIOS-in-flash -> SDRAM -> LPC serving correctness.
//
// Expected flow:
//   flash BIOS @ FLASH_OFF
//   -> preload 256K into SDRAM
//   -> preload_done = 1
//   -> LPC reads served from SDRAM

module eos_sdram_backend #(
    parameter integer FREQ      = 64_800_000,
    parameter [22:0]  BIOS_BASE = 23'h00_0000,
    parameter [23:0]  FLASH_OFF = 24'h20_0000,
    parameter integer LENGTH    = 1835008,       // 0x1C0000: skip empty top; kernel/boot region fills first
    parameter [23:0]  SLOT1_FL  = 24'h50_0000,   // XbDiag window flash base (slot1 0x400000 + img 0x100000)
    parameter [22:0]  SLOT1_SD  = 23'h30_0000,   // XbDiag window SDRAM base (slot1 0x200000 + img 0x100000)
    parameter integer SLOT1_LEN = 24'h0C_0000,   // 768K: XBE+kernel contiguous window
    parameter [23:0]  SLOT1_SIG = 24'h50_000B,   // flash addr of 'XBEH' magic in slot1
    parameter integer CHUNK     = 256
)(
    input  wire        lclk,
    input  wire        lresetn,

    input  wire        mem_req,
    input  wire [20:0] mem_addr,        // raw Xbox LPC address (pre-translate)
    input  wire        ef_wr,           // 0xEF write strobe (bank select)
    input  wire [7:0]  ef_data,         // 0xEF value (low nibble = bank)
    output reg         mem_valid,
    output reg  [7:0]  mem_data,

    input  wire        sclk,
    input  wire        sresetn,

    output reg         sd_rd,
    output reg         sd_wr,
    output reg         sd_refresh,
    output reg  [22:0] sd_addr,
    output reg  [7:0]  sd_din,
    input  wire [7:0]  sd_dout,
    input  wire        sd_data_ready,
    input  wire        sd_busy,

    output wire        flash_cs_n,
    output wire        flash_clk,
    output wire        flash_mosi,
    input  wire        flash_miso,

    // Post-flash reload: re-read a freshly-flashed region from flash into SDRAM
    // so the new bytes are served without a cold boot. Driven by the flash
    // engine (same sclk domain). reload_base/len are PHYSICAL flash addresses;
    // SDRAM target = base - FLASH_OFF. flash_free = engine has released the bus.
    input  wire        reload_req,
    input  wire [23:0] reload_base,
    input  wire [23:0] reload_len,
    input  wire        flash_free,

    // ---- SDRAM scratch access (update staging: 0x600000..0x7FFFFF, 2MB) ----
    input  wire        scr_wr,          // strobe: write scr_wdata -> scratch[scr_waddr]
    input  wire [20:0] scr_waddr,       // byte offset within scratch (0..0x1FFFFF)
    input  wire [7:0]  scr_wdata,
    input  wire        scr_rd,          // strobe: read scratch[scr_raddr]
    input  wire [20:0] scr_raddr,
    output reg  [7:0]  scr_rdata,
    output reg         scr_rvalid,      // 1-cycle pulse when scr_rdata valid
    output wire        scr_busy,        // 1 while a scratch op is queued/in flight

    output reg         preload_done,
    output reg         slot1_ready,     // XbDiag slot-1 window resident in SDRAM
    output wire [22:0] dbg_filled_lo,
    output wire [3:0]  dbg_bank,        // live bank_l (served/selected bank)
    output wire        dbg_reload       // reload (flash->SDRAM) in progress
);

    // -------------------------------------------------------------------------
    // SPI flash reader
    // -------------------------------------------------------------------------
    //
    // This backend intentionally requests exactly one byte at a time.
    // Do not change fr_len back to 256 until we add a FIFO or backpressure.

    reg         fr_start;
    reg [23:0] fr_addr;
    reg [8:0]  fr_len;

    wire        fr_busy;
    wire        fr_done;
    wire        fr_dvalid;
    wire [7:0]  fr_dout;

    eos_flash_reader #(
        .FLASH_BASE(24'h000000),
        .SCK_DIV(2)        // 4x faster preload (on-board flash, 0x03 read)
    ) u_rd (
        .clk        (sclk),
        .rstn       (sresetn),
        .start      (fr_start),
        .addr       (fr_addr),
        .len        (fr_len),
        .busy       (fr_busy),
        .done       (fr_done),
        .dvalid     (fr_dvalid),
        .dout       (fr_dout),
        .flash_cs_n (flash_cs_n),
        .flash_clk  (flash_clk),
        .flash_mosi (flash_mosi),
        .flash_miso (flash_miso)
    );

    // -------------------------------------------------------------------------
    // SDRAM refresh timer
    // -------------------------------------------------------------------------

    localparam integer RCNT = FREQ / 1000000 * 15;

    reg [11:0] rtmr;
    reg        refresh_due;

    always @(posedge sclk or negedge sresetn) begin
        if (!sresetn) begin
            rtmr        <= 12'd0;
            refresh_due <= 1'b0;
        end else begin
            if (rtmr >= RCNT[11:0]) begin
                refresh_due <= 1'b1;
                rtmr        <= 12'd0;
            end else begin
                rtmr <= rtmr + 1'b1;
            end

            if (sd_refresh)
                refresh_due <= 1'b0;
        end
    end

    // -------------------------------------------------------------------------
    // Request CDC: LPC clock domain -> SDRAM clock domain
    // -------------------------------------------------------------------------

    reg req_tog = 1'b0;

    always @(posedge lclk or negedge lresetn) begin
        if (!lresetn)
            req_tog <= 1'b0;
        else if (mem_req)
            req_tog <= ~req_tog;
    end

    reg [2:0] rqs = 3'b000;

    always @(posedge sclk or negedge sresetn) begin
        if (!sresetn)
            rqs <= 3'b000;
        else
            rqs <= {rqs[1:0], req_tog};
    end

    wire req_edge = rqs[2] ^ rqs[1];

    // ---- 0xEF bank register (lclk). Default = 0001 = kernel bank @ virtual
    //      0x180000 (the Xenium power-on boot bank). Kernel writes 0xEF=0010 to
    //      reach the XBE @ virtual 0x100000. ----
    localparam [3:0] BANK_BOOT = 4'b0001;
    // PERSISTENCE: bank_l must survive a warm reset so the bank chosen by
    // "Launch Bank" is still selected when the Xbox reboots into it. A real
    // Xbox warm reset is an electrical transient that can briefly drop a PLL
    // lock and pulse ANY runtime reset (sresetn/lresetn) -- which would wipe the
    // selection back to the boot bank. So bank_l takes NO runtime reset at all:
    // it initialises to the boot bank at FPGA CONFIGURATION (cold power-on) via
    // its init value and only changes on a 0xEF write. A warm reset leaves the
    // FPGA configured, so bank_l holds. Only a true cold power-on (which
    // reconfigures the FPGA) returns it to the boot bank.
    reg [3:0] bank_l = BANK_BOOT;
    // SLOT latch: selecting 0xD boots the SECOND 2MB image slot. The packed
    // image bank-switches internally (kernel 0x1 -> XBE 0x2 via 0xEF), and
    // those selects must stay inside the same slot -- so the slot is sticky
    // across every subsequent select until slot 0 is chosen explicitly by a
    // non-0xD select from the LOADER (i.e. after a power-down / boot-bank
    // revert). Same no-runtime-reset persistence rules as bank_l.
    reg       slot_l = 1'b0;
    always @(posedge lclk) begin
        if (ef_wr) begin
            if (ef_data[3:0] == 4'hD) begin
                slot_l <= 1'b1;              // enter slot 1...
                bank_l <= 4'h1;              // ...and boot it like bank 0x1
            end else if (!slot_l || pwrc_l) begin
                slot_l <= 1'b0;              // loader select after power-down: slot 0
                bank_l <= ef_data[3:0];      // slot 0: selects behave as always
            end else begin
                bank_l <= ef_data[3:0];      // slot 1: image's own 0xEF switches
            end                              //   (kernel->XBE) stay in-slot
        end
    end
    // sync bank into sclk domain for the serve path
    // sync bank into the sclk serve domain. Init-only (no runtime reset) so a
    // reset glitch can't momentarily force the boot bank during the post-warm-
    // reset boot-vector read; it simply tracks the persistent bank_l.
    reg [3:0] bank_s0 = BANK_BOOT, bank_s = BANK_BOOT;
    reg       slot_s0 = 1'b0,     slot_s = 1'b0;
    always @(posedge sclk) begin
        bank_s0 <= bank_l;   slot_s0 <= slot_l;
        bank_s  <= bank_s0;  slot_s  <= slot_s0;
    end

    // ---- Xbox power-down detector (externally-powered fix) ------------------
    // bank_l only reverts to the boot bank at FPGA configuration. When the chip
    // is externally powered the FPGA never reconfigures, so after a launch the
    // last bank is held forever -- a hot boot then comes up in that bank instead
    // of the loader. We distinguish a real power-down from a launch warm reset by
    // how long LRESET stays asserted: a warm reset is a brief pulse, a power-down
    // holds it for a long time. This MUST run on sclk (the FPGA's own 64.8 MHz
    // domain), because the Xbox's LPC clock stops when it is off -- an lclk-based
    // timer would freeze exactly when we need to measure.
    //
    // On a long assertion we latch pwr_cycled, which forces the served bank back
    // to the boot bank so the next power-up lands in the loader. The latch clears
    // on the next 0xEF write (the loader picking/arming a bank to launch), so a
    // genuine launch warm reset that follows still serves the chosen bank.
    localparam [23:0] PWRDN_TICKS = 24'd9_720_000;   // ~150 ms @ 64.8 MHz (>> warm-reset pulse, << power-cycle)

    reg [1:0] lr_ss = 2'b11;
    always @(posedge sclk) lr_ss <= {lr_ss[0], lresetn};
    wire lr_asserted = ~lr_ss[1];

    // ef_wr (lclk pulse) -> sclk edge, so the latch can clear on a bank selection.
    reg ef_tog = 1'b0;
    always @(posedge lclk) if (ef_wr) ef_tog <= ~ef_tog;
    reg [2:0] ef_sy = 3'b000;
    always @(posedge sclk) ef_sy <= {ef_sy[1:0], ef_tog};
    wire ef_seen = ef_sy[2] ^ ef_sy[1];

    reg [23:0] lr_cnt     = 24'd0;
    reg        pwr_cycled = 1'b0;
    always @(posedge sclk) begin
        if (!lr_asserted)               lr_cnt <= 24'd0;            // Xbox running
        else if (lr_cnt < PWRDN_TICKS)  lr_cnt <= lr_cnt + 24'd1;   // counting reset time

        if (lr_asserted && lr_cnt >= PWRDN_TICKS) pwr_cycled <= 1'b1;  // long reset = power-down
        else if (ef_seen)                          pwr_cycled <= 1'b0;  // bank armed for launch
    end

    // Effective served bank: boot bank after a power-down until a bank is armed.
    wire [3:0] bank_eff = pwr_cycled ? BANK_BOOT : bank_s;
    wire       slot_eff = pwr_cycled ? 1'b0      : slot_s;
    // pwr_cycled (sclk) -> lclk so the next 0xEF write also clears slot_l
    reg pwrc_l0 = 1'b0, pwrc_l = 1'b0;
    always @(posedge lclk) begin pwrc_l0 <= pwr_cycled; pwrc_l <= pwrc_l0; end

    // Rising-edge one-shot on pwr_cycled: fire a single flash->SDRAM reload of the
    // boot bank so the loader is served FRESH on the next power-up. With external
    // power the SDRAM never gets a cold preload to refresh it, so reverting the
    // bank alone isn't enough -- the boot-bank image must be re-asserted.
    reg  pwr_cycled_d = 1'b0;
    always @(posedge sclk) pwr_cycled_d <= pwr_cycled;
    wire pwr_reload = pwr_cycled & ~pwr_cycled_d;

    // OpenXenium virtual translation: force the high bits per bank, pass low LPC
    // bits. virtual = base(bank) | lpc[low]. (physical = 0x200000 + virtual is
    // applied to the FLASH read; SDRAM holds the image 1:1 with virtual.)
    function [21:0] xlate; input [3:0] b; input [20:0] a; begin
        case (b)
            4'b0001: xlate = {3'b110, a[17:0]};   // 0x180000  kernel (BOOT)
            4'b0010: xlate = {2'b10,  a[18:0]};   // 0x100000  XeniumOS / XBE
            4'b0011: xlate = {3'b000, a[17:0]};   // 0x000000  user 256K
            4'b0100: xlate = {3'b001, a[17:0]};   // 0x040000
            4'b0101: xlate = {3'b010, a[17:0]};   // 0x080000
            4'b0110: xlate = {3'b011, a[17:0]};   // 0x0C0000
            4'b0111: xlate = {2'b00,  a[18:0]};   // 0x000000  512K
            4'b1000: xlate = {2'b01,  a[18:0]};   // 0x080000  512K
            4'b1001: xlate = {1'b0,   a[19:0]};   // 0x000000  1MB
            4'b1010: xlate = {3'b111, a[17:0]};   // 0x1C0000  recovery
            default: xlate = {3'b110, a[17:0]};   // safe -> boot bank
        endcase
    end endfunction

    // capture the TRANSLATED virtual address (21-bit) for the serve.
    reg [21:0] req_addr_s;
    always @(posedge sclk or negedge sresetn) begin
        if (!sresetn) req_addr_s <= 22'd0;
        else          req_addr_s <= {1'b0, xlate(bank_eff, mem_addr)} | {slot_eff, 21'd0};
    end

    reg req_pending;

    // -------------------------------------------------------------------------
    // Result CDC: SDRAM clock domain -> LPC clock domain
    // -------------------------------------------------------------------------

    reg       done_tog = 1'b0;
    reg [7:0] result   = 8'd0;

    reg [2:0] dns = 3'b000;

    always @(posedge lclk or negedge lresetn) begin
        if (!lresetn)
            dns <= 3'b000;
        else
            dns <= {dns[1:0], done_tog};
    end

    wire done_edge = dns[2] ^ dns[1];

    always @(posedge lclk or negedge lresetn) begin
        if (!lresetn) begin
            mem_valid <= 1'b0;
            mem_data  <= 8'd0;
        end else begin
            mem_valid <= done_edge;

            if (done_edge)
                mem_data <= result;
        end
    end

    // -------------------------------------------------------------------------
    // Main preload/server FSM
    // -------------------------------------------------------------------------

    localparam S_INIT       = 4'd0;
    localparam S_PRE        = 4'd1;
    localparam S_FLASH_REQ  = 4'd2;
    localparam S_FLASH_WAIT = 4'd3;
    localparam S_WRITE      = 4'd4;
    localparam S_RD         = 4'd5;
    localparam S_SERVE      = 4'd6;
    localparam S_RL_REQ     = 4'd7;   // reload: request one flash byte
    localparam S_RL_WAIT    = 4'd8;   // reload: wait for capture
    localparam S_RL_WRITE   = 4'd9;
    localparam S_SCR_WR     = 4'd10;
    localparam S_SCR_RD_REQ = 4'd11;
    localparam S_SCR_RD_WAIT= 4'd12;   // reload: write byte to SDRAM
    localparam S_S1_PROBE   = 4'd13;   // slot1: request one 'XBEH' magic byte
    localparam S_S1_PWAIT   = 4'd14;   // slot1: check captured magic byte
    localparam S_S1_FILL    = 4'd15;   // slot1: run the 768K window reload

    reg [3:0] st;

    reg        scr_wr_pend, scr_rd_pend;
    reg [20:0] scr_waddr_r, scr_raddr_r;
    reg [7:0]  scr_wdata_r;

    // Post-flash reload bookkeeping
    parameter [22:0] SCRATCH_BASE = 23'h60_0000;   // SDRAM serve ceiling (6MB managed)
    reg         reload_pending;
    reg [23:0]  rl_fl_base;     // physical flash base
    reg [22:0]  rl_sd_base;     // SDRAM base = flash base - FLASH_OFF
    reg [23:0]  rl_len;
    reg [23:0]  rl_idx;
    // XbDiag slot-1 presence probe + gated second-region preload
    reg [1:0]   sig_i;         // which of the 4 'XBEH' bytes we're checking
    reg         sig_ok;        // all 4 magic bytes matched so far
    reg         slot1_done;    // second-region preload finished (latched)
    reg         s1_filling;    // the active reload is the slot-1 window fill
    // does the just-captured probe byte match its expected 'XBEH' position?
    wire        byte_ok = (sig_i == 2'd0) ? (wbyte == 8'h58) :
                          (sig_i == 2'd1) ? (wbyte == 8'h42) :
                          (sig_i == 2'd2) ? (wbyte == 8'h45) :
                                            (wbyte == 8'h48);

    reg [22:0] chunk_base;
    reg [22:0] filled_lo;
    reg [8:0]  got;

    reg        wpend;
    reg [7:0]  wbyte;

    reg        ret_serve;
    reg        op_lock;
    reg        seen_busy;
    reg        sdram_ready;

    wire [22:0] req23      = {1'b0, req_addr_s};
    wire        req_filled = (req23 >= filled_lo);

    assign dbg_filled_lo = filled_lo;
    assign dbg_bank      = bank_l;
    assign dbg_reload    = reload_pending;
    assign scr_busy      = scr_wr_pend | scr_rd_pend |
                           (st == S_SCR_WR) | (st == S_SCR_RD_REQ) | (st == S_SCR_RD_WAIT);

    always @(posedge sclk or negedge sresetn) begin
        if (!sresetn) begin
            st            <= S_INIT;

            sd_rd         <= 1'b0;
            sd_wr         <= 1'b0;
            sd_refresh    <= 1'b0;
            sd_addr       <= 23'd0;
            sd_din        <= 8'd0;

            fr_start      <= 1'b0;
            fr_addr       <= 24'd0;
            fr_len        <= 9'd1;

            preload_done  <= 1'b0;

            chunk_base    <= LENGTH - CHUNK;
            filled_lo     <= LENGTH[22:0];
            got           <= 9'd0;

            wpend         <= 1'b0;
            wbyte         <= 8'd0;

            done_tog      <= 1'b0;
            result        <= 8'd0;

            req_pending   <= 1'b0;
            ret_serve     <= 1'b0;
            op_lock       <= 1'b0;
            seen_busy     <= 1'b0;
            sdram_ready   <= 1'b0;

            reload_pending <= 1'b0;
            scr_wr_pend    <= 1'b0;
            scr_rd_pend    <= 1'b0;
            scr_rvalid     <= 1'b0;
            scr_rdata      <= 8'd0;
            scr_waddr_r    <= 21'd0;
            scr_raddr_r    <= 21'd0;
            scr_wdata_r    <= 8'd0;
            rl_fl_base     <= 24'd0;
            rl_sd_base     <= 23'd0;
            rl_len         <= 24'd0;
            rl_idx         <= 24'd0;
            slot1_ready    <= 1'b0;
            slot1_done     <= 1'b0;
            sig_i          <= 2'd0;
            sig_ok         <= 1'b1;
            s1_filling     <= 1'b0;
        end else begin
            sd_rd      <= 1'b0;
            sd_wr      <= 1'b0;
            sd_refresh <= 1'b0;
            fr_start   <= 1'b0;
            scr_rvalid <= 1'b0;

            if (scr_wr && !scr_wr_pend && !scr_rd_pend) begin
                scr_wr_pend <= 1'b1; scr_waddr_r <= scr_waddr; scr_wdata_r <= scr_wdata;
            end
            if (scr_rd && !scr_wr_pend && !scr_rd_pend) begin
                scr_rd_pend <= 1'b1; scr_raddr_r <= scr_raddr;
            end

            // Clear op_lock once controller accepts the operation and goes busy.
            if (sd_busy)
                op_lock <= 1'b0;

            // SDRAM init detection: wait until busy has been seen and then goes low.
            if (sd_busy)
                seen_busy <= 1'b1;

            if (seen_busy && !sd_busy)
                sdram_ready <= 1'b1;

            // Capture LPC read request.
            if (req_edge)
                req_pending <= 1'b1;

            // Capture exactly one flash byte.
            if (fr_dvalid) begin
                wbyte <= fr_dout;
                wpend <= 1'b1;
            end

            // Latch a post-flash reload request (engine, same sclk domain).
            // Accept only in-range physical regions, and only when no reload is
            // already in flight -- a second request mid-reload would otherwise
            // overwrite rl_* and corrupt the copy in progress.
            if (reload_req && !reload_pending && (reload_base >= FLASH_OFF) &&
                ((reload_base - FLASH_OFF) < {1'b0, SCRATCH_BASE})) begin
                reload_pending <= 1'b1;
                rl_fl_base     <= reload_base;
                rl_sd_base     <= (reload_base - FLASH_OFF);
                rl_len         <= reload_len;
            end else if (pwr_reload && !reload_pending) begin
                // Power-down detected: re-assert the boot bank flash -> SDRAM so
                // the loader is fresh when the Xbox comes back up.
                reload_pending <= 1'b1;
                rl_fl_base     <= FLASH_OFF + 24'h18_0000;   // boot bank physical (0x380000)
                rl_sd_base     <= 23'h18_0000;               // boot bank SDRAM/virtual
                rl_len         <= 24'h04_0000;               // 256K
            end

            case (st)

                // -------------------------------------------------------------
                // Wait for SDRAM controller to finish init.
                // -------------------------------------------------------------
                S_INIT: begin
                    if (sdram_ready)
                        st <= S_PRE;
                end

                // -------------------------------------------------------------
                // Preload state.
                // During preload, we may serve LPC reads only if the requested
                // address is already inside the filled upper region.
                // -------------------------------------------------------------
                S_PRE: begin
                    if (!sd_busy && !op_lock) begin
                        if (refresh_due) begin
                            sd_refresh <= 1'b1;
                            op_lock    <= 1'b1;
                        end else if (req_pending && req_filled) begin
                            sd_addr     <= BIOS_BASE + req23;
                            sd_rd       <= 1'b1;
                            op_lock     <= 1'b1;
                            req_pending <= 1'b0;
                            ret_serve   <= 1'b0;
                            st          <= S_RD;
                        end else begin
                            st <= S_FLASH_REQ;
                        end
                    end
                end

                // -------------------------------------------------------------
                // Request one byte from flash.
                // -------------------------------------------------------------
                S_FLASH_REQ: begin
                    if (!fr_busy && !wpend) begin
                        fr_addr  <= FLASH_OFF + chunk_base + got;
                        fr_len   <= 9'd1;
                        fr_start <= 1'b1;
                        st       <= S_FLASH_WAIT;
                    end
                end

                // -------------------------------------------------------------
                // Wait until that one byte is captured.
                // -------------------------------------------------------------
                S_FLASH_WAIT: begin
                    if (wpend)
                        st <= S_WRITE;
                end

                // -------------------------------------------------------------
                // Write one captured byte to SDRAM.
                // -------------------------------------------------------------
                S_WRITE: begin
                    if (!sd_busy && !op_lock) begin
                        if (refresh_due) begin
                            sd_refresh <= 1'b1;
                            op_lock    <= 1'b1;
                        end else begin
                            sd_addr <= BIOS_BASE + chunk_base + got;
                            sd_din  <= wbyte;
                            sd_wr   <= 1'b1;
                            op_lock <= 1'b1;
                            wpend   <= 1'b0;

                            if (got == CHUNK - 1) begin
                                got       <= 9'd0;
                                filled_lo <= chunk_base;

                                if (chunk_base == 0) begin
                                    preload_done <= 1'b1;
                                    st           <= S_SERVE;
                                end else begin
                                    chunk_base <= chunk_base - CHUNK;
                                    st         <= S_PRE;
                                end
                            end else begin
                                got <= got + 1'b1;
                                st  <= S_PRE;
                            end
                        end
                    end
                end

                // -------------------------------------------------------------
                // SDRAM read completion.
                // -------------------------------------------------------------
                S_RD: begin
                    if (sd_data_ready) begin
                        result   <= sd_dout;
                        done_tog <= ~done_tog;
                        st       <= ret_serve ? S_SERVE : S_PRE;
                    end
                end

                // -------------------------------------------------------------
                // Fully resident. Serve LPC requests from SDRAM.
                // -------------------------------------------------------------
                S_SERVE: begin
                    if (!sd_busy && !op_lock) begin
                        if (refresh_due) begin
                            sd_refresh <= 1'b1;
                            op_lock    <= 1'b1;
                        end else if (preload_done && !slot1_done && flash_free
                                     && !reload_pending) begin
                            // One-shot after slot-0 preload: probe flash slot 1 for
                            // the 'XBEH' magic; if present, page the 768K XbDiag
                            // window into SDRAM so it launches like a resident bank.
                            sig_i  <= 2'd0;
                            sig_ok <= 1'b1;
                            st     <= S_S1_PROBE;
                        end else if (reload_pending && flash_free) begin
                            // freshly-flashed region: re-read flash -> SDRAM in
                            // place so it serves without a cold boot. Only once
                            // the engine has released the flash bus.
                            rl_idx <= 24'd0;
                            st     <= S_RL_REQ;
                        end else if (req_pending) begin
                            sd_addr     <= BIOS_BASE + req23;
                            sd_rd       <= 1'b1;
                            op_lock     <= 1'b1;
                            req_pending <= 1'b0;
                            ret_serve   <= 1'b1;
                            st          <= S_RD;
                        end else if (scr_wr_pend) begin
                            st <= S_SCR_WR;
                        end else if (scr_rd_pend) begin
                            st <= S_SCR_RD_REQ;
                        end
                    end
                end

                // -------------------------------------------------------------
                // Reload: copy a flashed region flash -> SDRAM, one byte at a
                // time, mirroring the preload path. Clamped to the serve ceiling.
                // -------------------------------------------------------------
                S_RL_REQ: begin
                    if (rl_idx >= rl_len ||
                        (rl_sd_base + rl_idx[22:0]) >= SCRATCH_BASE) begin
                        if (s1_filling) begin
                            slot1_ready <= 1'b1;   // XbDiag window now resident
                            s1_filling  <= 1'b0;
                        end else begin
                            reload_pending <= 1'b0;
                        end
                        st             <= S_SERVE;
                    end else if (!fr_busy && !wpend) begin
                        fr_addr  <= rl_fl_base + rl_idx;
                        fr_len   <= 9'd1;
                        fr_start <= 1'b1;
                        st       <= S_RL_WAIT;
                    end
                end

                S_RL_WAIT: begin
                    if (wpend)
                        st <= S_RL_WRITE;
                end

                S_RL_WRITE: begin
                    if (!sd_busy && !op_lock) begin
                        if (refresh_due) begin
                            sd_refresh <= 1'b1;
                            op_lock    <= 1'b1;
                        end else begin
                            sd_addr <= BIOS_BASE + rl_sd_base + rl_idx[22:0];
                            sd_din  <= wbyte;
                            sd_wr   <= 1'b1;
                            op_lock <= 1'b1;
                            wpend   <= 1'b0;
                            rl_idx  <= rl_idx + 1'b1;
                            st      <= S_RL_REQ;
                        end
                    end
                end

                // -------------------------------------------------------------
                // Slot-1 (XbDiag) presence probe: read the 4 'XBEH' magic bytes
                // at SLOT1_SIG. If all match, page in the 768K window; else leave
                // slot 1 cold. Latches slot1_done either way so it runs once.
                // -------------------------------------------------------------
                S_S1_PROBE: begin
                    if (!fr_busy && !wpend) begin
                        fr_addr  <= SLOT1_SIG + {22'd0, sig_i};
                        fr_len   <= 9'd1;
                        fr_start <= 1'b1;
                        st       <= S_S1_PWAIT;
                    end
                end

                S_S1_PWAIT: begin
                    if (wpend) begin
                        wpend <= 1'b0;
                        // 'XBEH' = 0x58 0x42 0x45 0x48. byte_ok = does THIS byte
                        // match the expected magic char for its position?
                        if (!byte_ok) sig_ok <= 1'b0;   // sticky-clear on any miss
                        if (sig_i == 2'd3) begin
                            slot1_done <= 1'b1;          // probe complete (runs once)
                            // final decision uses sig_ok AND this byte's match, so
                            // the 4th byte is included without an NBA race.
                            if (sig_ok && byte_ok) begin
                                rl_fl_base <= SLOT1_FL;  // magic present -> page window
                                rl_sd_base <= SLOT1_SD;
                                rl_len     <= SLOT1_LEN;
                                rl_idx     <= 24'd0;
                                st         <= S_S1_FILL;
                            end else begin
                                st <= S_SERVE;           // no XbDiag -> stay cold
                            end
                        end else begin
                            sig_i <= sig_i + 1'b1;
                            st    <= S_S1_PROBE;
                        end
                    end
                end

                // Fill the slot-1 window by reusing the reload byte loop. We drive
                // rl_* and bounce through S_RL_REQ; when it finishes (rl_idx>=len)
                // it returns to S_SERVE with reload_pending clear -- but we came in
                // via S_S1_FILL so we latch slot1_ready on entry to the loop and let
                // the standard reload path carry it to completion.
                S_S1_FILL: begin
                    // hand off to the shared reload loop; s1_filling tells the
                    // loop's exit (in S_RL_REQ) to raise slot1_ready when it drains.
                    slot1_ready <= 1'b0;   // not ready until the loop drains
                    s1_filling  <= 1'b1;
                    st          <= S_RL_REQ;
                end

                S_SCR_WR: begin
                    if (!sd_busy && !op_lock) begin
                        if (refresh_due) begin
                            sd_refresh <= 1'b1; op_lock <= 1'b1;
                        end else begin
                            sd_addr     <= SCRATCH_BASE + {2'b0, scr_waddr_r};
                            sd_din      <= scr_wdata_r;
                            sd_wr       <= 1'b1; op_lock <= 1'b1;
                            scr_wr_pend <= 1'b0; st <= S_SERVE;
                        end
                    end
                end

                S_SCR_RD_REQ: begin
                    if (!sd_busy && !op_lock) begin
                        if (refresh_due) begin
                            sd_refresh <= 1'b1; op_lock <= 1'b1;
                        end else begin
                            sd_addr     <= SCRATCH_BASE + {2'b0, scr_raddr_r};
                            sd_rd       <= 1'b1; op_lock <= 1'b1;
                            scr_rd_pend <= 1'b0; st <= S_SCR_RD_WAIT;
                        end
                    end
                end

                S_SCR_RD_WAIT: begin
                    if (sd_data_ready) begin
                        scr_rdata  <= sd_dout; scr_rvalid <= 1'b1; st <= S_SERVE;
                    end
                end

                default: begin
                    st <= S_INIT;
                end

            endcase
        end
    end

endmodule