// eos_sdram_backend.v -- flash->SDRAM preloader + LPC server.
//
// Reads SPI flash in 256-byte BURSTS with hardware backpressure.
//
// PHASE 4: the reader's 'stall' input is tied to wpend -- the backend's existing
// one-byte holding register's full flag. When a byte is waiting to be written to
// SDRAM the reader parks at a bit boundary with SCK low and CS# still asserted.
// A byte cannot complete for another 7 bit-periods after stall asserts, so wpend
// can never be overwritten and NO FIFO IS NEEDED. See eos_flash_reader.v.
//
// Cost per byte drops from ~176 sclk (2.72 us) to ~40 sclk (0.61 us): only 8 of
// the old 40 SPI bits carried payload, the rest was per-byte command overhead.
//
// CRITICAL: fr_start must pulse ONCE PER BURST, never mid-burst. A mid-burst
// start drops CS#, re-issues 0x03, and streams from the wrong address. burst_active
// exists solely to enforce that. Burst lengths are clamped so a burst always ends
// exactly at a chunk / region / SCRATCH_BASE boundary -- the reader is therefore
// never left busy across a state change, which would deadlock the !fr_busy guards.
//
// Flow:
//   flash image @ FLASH_OFF
//     -> preload the fast-boot region (LENGTH) into SDRAM, top-down
//     -> preload_done = 1
//     -> probe flash slot 1 for 'XBEH'; if present, page in the 768K window
//     -> page in the 1MB ext region (oversized banks)
//   LPC reads are served from SDRAM throughout.
//
// =============================================================================
// PHASE 2 -- THE STALL CLASS
// =============================================================================
//
// (A) LPC reads are now served DURING the fill loops.
//     S_PRE and S_SERVE always serviced req_pending, but S_RL_REQ (the shared
//     reload/slot1/ext byte loop) and S_S1_PROBE did not. Those loops run for
//     SECONDS -- 768K + 1MB of single-byte SPI reads -- and they run AFTER
//     preload_done, i.e. exactly while the Xbox is booting. Any LPC read that
//     landed in that window was never answered, and the loader hung in SYNCING
//     with LFRAME# low.
//
//     Both loops now check for a pending, in-range request at the top of each
//     byte iteration and divert through S_RD to serve it. Max added latency is
//     one flash byte (~2.6 us). S_RD returns to whichever state dispatched it
//     via rd_ret, which replaces the old 1-bit ret_serve.
//
// (B) A request that cannot be served is DROPPED, not left pending.
//     eos_lpc_loader now abandons a cycle after SYNC_TIMEOUT (~61.4 us). If
//     this backend later answered that abandoned request, mem_valid would
//     arrive ORPHANED inside a subsequent, unrelated LPC transaction and the
//     wrong byte would be served. So req_pending is aged out after REQ_TIMEOUT
//     sclk (~15.8 us) and silently discarded -- ~45 us BEFORE the loader gives
//     up, versus a ~0.2 us serve-to-mem_valid path. The two timeouts cannot
//     race. If you change one, recompute the other.
//
//     This fires in exactly one legitimate case today: a read of an oversized
//     bank (ext region) before newrgn_ready. The host sees a SYNC error and
//     retries; once the fill completes the retry is served.

module eos_sdram_backend #(
    parameter integer FREQ      = 64_800_000,
    parameter [22:0]  BIOS_BASE = 23'h00_0000,
    parameter [23:0]  FLASH_OFF = 24'h20_0000,
    parameter integer LENGTH    = 1835008,       // 0x1C0000: fast boot region (kernel/boot fills first)
    parameter [23:0]  SLOT1_FL  = 24'h50_0000,   // XbDiag window flash base (slot1 0x400000 + img 0x100000)
    parameter [22:0]  SLOT1_SD  = 23'h30_0000,   // XbDiag window SDRAM base (slot1 0x200000 + img 0x100000)
    parameter integer SLOT1_LEN = 24'h0C_0000,   // 768K: XBE+kernel contiguous window
    parameter [23:0]  NRGN_FL   = 24'h5C_0000,   // NEW REGION flash base (oversized banks)
    parameter [22:0]  NRGN_SD   = 23'h3C_0000,   // EXT region SDRAM base = flash 0x5C0000 in the contiguous mirror (0x5C0000-FLASH_OFF)
    parameter integer NRGN_LEN  = 24'h10_0000,   // 1MB new region
    parameter [23:0]  SLOT1_SIG = 24'h50_000B,   // flash addr of 'XBEH' magic in slot1
    parameter integer CHUNK     = 256
)(
    input  wire        lclk,
    input  wire        lresetn,

    input  wire        mem_req,
    input  wire [20:0] mem_addr,        // raw Xbox LPC address (pre-translate)

    // Per-user-slot ext-anchor info from bank_ctrl (descriptor). Index maps to EF
    // nibbles 0x3..0x6. When a launched user bank is an oversized anchor, the serve
    // path redirects to the ext-region SDRAM copy instead of the normal 256K slot.
    input  wire [3:0]  ext_anchor,      // bit i: EF (0x3+i) is an oversized anchor
    input  wire [7:0]  ext_szc,         // 2b/slot: size code (1=512K, 2=1MB)
    input  wire [95:0] ext_base,        // 24b/slot: phys base rel FLOOR

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
    output wire        dbg_reload,      // reload (flash->SDRAM) in progress
    output wire        dbg_newrgn_ready // ext-region resident in SDRAM
);

    // Width-clean derived constants (no behavioural change; these exist purely so
    // the truncations are explicit in the source instead of implicit in synthesis).
    localparam [22:0] PRELOAD_TOP = (LENGTH - CHUNK);   // first (highest) chunk base

    // -------------------------------------------------------------------------
    // SPI flash reader
    // -------------------------------------------------------------------------
    //
    // This backend intentionally requests exactly one byte at a time.
    // Do not change fr_len back to 256 until we add a FIFO or backpressure.

    // Declared here (not with the other FSM regs) because wpend feeds the
    // reader's stall input at the instantiation below.
    reg        wpend;      // 1 = a flash byte is waiting to be written to SDRAM
    reg [7:0]  wbyte;
    reg        burst_active;   // 1 while a multi-byte SPI burst is streaming

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
        .stall      (wpend),        // PHASE 4 backpressure: hold while a byte waits
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

    // capture the TRANSLATED virtual address for the serve.
    // 23-bit so oversized banks (0x7/0x8/0x9) can reach the new-region SDRAM home
    // at NRGN_SD (0x400000), which is above the 22-bit {slot,xlate} serve space.
    // Ext-anchor redirect: a user bank (EF 0x3..0x6) that the descriptor marks as
    // an oversized ANCHOR is served from the resident ext-region SDRAM copy
    // (NRGN_SD) instead of its normal 256K slot. The loader launches these banks
    // NORMALLY (plain 0xEF nibble) -- the redirect lives entirely here.
    //   ext index i = bank_eff - 3 (EF 0x3->0 .. 0x6->3)
    wire        eff_is_user  = (bank_eff >= 4'h3) && (bank_eff <= 4'h6);
    wire [3:0]  eff_ix4      = bank_eff - 4'd3;        // 0x3->0,0x4->1,0x5->2,0x6->3
    wire [1:0]  eff_ix       = eff_ix4[1:0];           // gated by eff_is_user below
    wire        eff_anchor   = eff_is_user && ext_anchor[eff_ix];
    wire [1:0]  eff_szc      = ext_szc [eff_ix*2 +: 2];
    wire [23:0] eff_base     = ext_base[eff_ix*24 +: 24];   // rel FLOOR
    // ext-region SDRAM base for this anchor: NRGN_SD + (base - EOS_NEWRGN_BASE).
    // EOS_NEWRGN_BASE = 0x3C0000 rel FLOOR. half0 base 0x3C0000 -> +0;
    // half1 base 0x4C0000 -> +0x80000; 1MB base 0x3C0000 -> +0.
    localparam [23:0] NEWRGN_REL = 24'h3C0000;
    wire [23:0] ext_off      = eff_base - NEWRGN_REL;         // 0 or 0x80000
    wire [22:0] ext_sd_base  = NRGN_SD + ext_off[22:0];

    reg [22:0] req_addr_s;
    always @(posedge sclk or negedge sresetn) begin
        if (!sresetn) req_addr_s <= 23'd0;
        else if (eff_anchor) begin
            // 512K uses a 19-bit offset (wraps within 512K); 1MB uses 20-bit.
            if (eff_szc == 2'd2) req_addr_s <= ext_sd_base + {3'b0, mem_addr[19:0]}; // 1MB
            else                 req_addr_s <= ext_sd_base + {4'b0, mem_addr[18:0]}; // 512K
        end else begin
            req_addr_s <= {1'b0, xlate(bank_eff, mem_addr)} | {slot_eff, 21'd0};
        end
    end

    reg req_pending;

    // ---- stale-request ageing (see note (B) in the header) ----
    // 1024 sclk @ 64.8 MHz = 15.8 us. Worst legitimate serve latency is one
    // flash byte plus an SDRAM write plus a refresh, ~183 sclk (2.8 us), so
    // this is ~5.6x margin. It MUST remain well below eos_lpc_loader's
    // SYNC_TIMEOUT (2048 lclk = 61.4 us) in wall-clock terms.
    localparam integer REQ_TIMEOUT = 1024;
    reg [10:0] req_age;

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

    reg [4:0] st;

    reg        scr_wr_pend, scr_rd_pend;
    reg [20:0] scr_waddr_r, scr_raddr_r;
    reg [7:0]  scr_wdata_r;

    // Post-flash reload bookkeeping
    localparam [22:0] SCRATCH_BASE = 23'h60_0000;  // SDRAM serve ceiling (6MB managed)
    wire [23:0] rl_sd_next = reload_base - FLASH_OFF;   // 24b; [23] provably 0, see use
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
    reg         newrgn_done;   // new-region preload STARTED (runs once)
    reg         newrgn_ready;  // new-region data RESIDENT in SDRAM (fill done)
    reg         nr_filling;    // the active reload is the new-region fill
    // does the just-captured probe byte match its expected 'XBEH' position?
    wire        byte_ok = (sig_i == 2'd0) ? (wbyte == 8'h58) :
                          (sig_i == 2'd1) ? (wbyte == 8'h42) :
                          (sig_i == 2'd2) ? (wbyte == 8'h45) :
                                            (wbyte == 8'h48);

    reg [22:0] chunk_base;
    reg [22:0] filled_lo;
    reg [8:0]  got;

    // ---- reload burst sizing -------------------------------------------------
    // A burst must end exactly at the region end OR the SCRATCH_BASE clamp, never
    // past either. If a burst could overshoot we would have to abort the reader
    // mid-stream; fr_busy would then stay high and every !fr_busy guard in the
    // FSM (S_S1_PROBE, S_FLASH_REQ) would deadlock. Clamping is what makes
    // burst_active safe to clear on the last byte.
    reg [8:0]  rl_burst_left;                 // bytes remaining in the active burst
    wire [23:0] rl_remain = rl_len - rl_idx;                       // to region end
    wire [23:0] rl_room   = {1'b0, SCRATCH_BASE} - ({1'b0, rl_sd_base} + rl_idx);
    wire [23:0] rl_cap    = (rl_remain < rl_room) ? rl_remain : rl_room;
    wire [8:0]  rl_blen   = (rl_cap >= 24'd256) ? 9'd256 : rl_cap[8:0];

    reg [4:0]  rd_ret;        // state to return to when S_RD completes
    reg        op_lock;
    reg        seen_busy;
    reg        sdram_ready;

    wire [22:0] req23      = req_addr_s;
    // Main-region requests are gated on preload progress (filled_lo). New-region
    // requests (>= NRGN_SD) are instead gated on the new-region fill completing
    // (newrgn_done), since they live above the main preload window.
    // The EXT region is a second-phase fill (after the fast boot region), landing
    // at NRGN_SD (0x3C0000). Ext reads gate on newrgn_ready; everything else on
    // the main preload progress (filled_lo).
    wire        in_newrgn  = (req23 >= NRGN_SD) && (req23 < (NRGN_SD + NRGN_LEN[22:0]));
    wire        req_filled = in_newrgn ? newrgn_ready : (req23 >= filled_lo);

    assign dbg_filled_lo = filled_lo;
    assign dbg_bank      = bank_l;
    assign dbg_reload    = reload_pending;
    assign dbg_newrgn_ready = newrgn_ready;
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

            chunk_base    <= PRELOAD_TOP;
            filled_lo     <= LENGTH[22:0];
            got           <= 9'd0;

            wpend         <= 1'b0;
            wbyte         <= 8'd0;
            burst_active  <= 1'b0;
            rl_burst_left <= 9'd0;

            done_tog      <= 1'b0;
            result        <= 8'd0;

            req_pending   <= 1'b0;
            req_age       <= 11'd0;
            rd_ret        <= S_PRE;
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
            newrgn_done    <= 1'b0;
            newrgn_ready   <= 1'b0;
            nr_filling     <= 1'b0;
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

            // Capture LPC read request, and age out one we cannot serve.
            // A dropped request is never answered; the loader's SYNC timeout
            // handles the host side. Serve branches below clear req_pending
            // later in this same always block, so they win over the ageing.
            if (req_edge) begin
                req_pending <= 1'b1;
                req_age     <= 11'd0;
            end else if (req_pending) begin
                if (req_age == REQ_TIMEOUT[10:0] - 11'd1)
                    req_pending <= 1'b0;          // stale: discard, stay silent
                else
                    req_age <= req_age + 11'd1;
            end

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
                // The NEW REGION (flash NRGN_FL) is served from SDRAM NRGN_SD, which
                // is NOT the generic flash-FLASH_OFF address. Map it explicitly so a
                // post-flash sync lands where the oversized-bank serve path reads.
                if (reload_base == NRGN_FL) begin
                    rl_sd_base <= NRGN_SD;
                    nr_filling <= 1'b1;           // completion sets newrgn_ready
                end else begin
                    // reload_base >= FLASH_OFF is checked by the guard above, and
                    // the difference is < SCRATCH_BASE, so bit 23 is always 0.
                    rl_sd_base <= rl_sd_next[22:0];
                end
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
                            rd_ret      <= S_PRE;
                            st          <= S_RD;
                        end else begin
                            st <= S_FLASH_REQ;
                        end
                    end
                end

                // -------------------------------------------------------------
                // Start a CHUNK-byte burst at the base of this chunk, or -- if one
                // is already streaming -- simply go wait for the next byte.
                // fr_start must NEVER pulse mid-burst.
                //
                // got walks 0..CHUNK-1 within a chunk and CHUNK == the burst size,
                // so a burst maps exactly onto a chunk. burst_active is cleared by
                // S_WRITE on the last byte, which is also when the reader reaches
                // FIN and drops fr_busy.
                // -------------------------------------------------------------
                S_FLASH_REQ: begin
                    if (burst_active) begin
                        st <= S_FLASH_WAIT;
                    end else if (!fr_busy && !wpend) begin
                        fr_addr      <= FLASH_OFF + chunk_base;   // burst base, not +got
                        fr_len       <= CHUNK[8:0];
                        fr_start     <= 1'b1;
                        burst_active <= 1'b1;
                        st           <= S_FLASH_WAIT;
                    end
                end

                // -------------------------------------------------------------
                // Wait for the next byte of the burst. The SDRAM is completely
                // idle here, so LPC reads are served for free.
                //
                // This matters most at the START of a burst, where the reader is
                // still clocking out PRECS + the 0x03 command + 24 address bits
                // (~168 sclk). A request landing in that window used to wait the
                // whole header out. Serving here makes it wait for nothing.
                //
                // No blocking guard needed (unlike S_RL_REQ / S_PRE): nothing here
                // competes for the SDRAM, so a plain conditional cannot starve.
                // -------------------------------------------------------------
                S_FLASH_WAIT: begin
                    if (wpend) begin
                        st <= S_WRITE;
                    end else if (!sd_busy && !op_lock && req_pending && req_filled) begin
                        sd_addr     <= BIOS_BASE + req23;
                        sd_rd       <= 1'b1;
                        op_lock     <= 1'b1;
                        req_pending <= 1'b0;
                        rd_ret      <= S_FLASH_WAIT;
                        st          <= S_RD;
                    end
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
                                got          <= 9'd0;
                                filled_lo    <= chunk_base;
                                burst_active <= 1'b0;   // burst drained exactly here

                                if (chunk_base == 0) begin
                                    preload_done <= 1'b1;
                                    st           <= S_SERVE;
                                end else begin
                                    chunk_base <= chunk_base - CHUNK[22:0];
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
                // Shared SDRAM-read completion. rd_ret says who asked.
                S_RD: begin
                    if (sd_data_ready) begin
                        result   <= sd_dout;
                        done_tog <= ~done_tog;
                        st       <= rd_ret;
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
                        end else if (preload_done && slot1_done && !newrgn_done
                                     && flash_free && !reload_pending) begin
                            // Second phase after the fast boot preload + XbDiag:
                            // page the 1MB ext region (flash NRGN_FL) into SDRAM
                            // at NRGN_SD (0x3C0000) so oversized banks are resident.
                            newrgn_done  <= 1'b1;
                            rl_fl_base   <= NRGN_FL;
                            rl_sd_base   <= NRGN_SD;
                            rl_len       <= NRGN_LEN;
                            rl_idx       <= 24'd0;
                            nr_filling   <= 1'b1;
                            burst_active <= 1'b0;
                            st           <= S_RL_REQ;
                        end else if (reload_pending && flash_free) begin
                            // freshly-flashed region: re-read flash -> SDRAM in
                            // place so it serves without a cold boot. Only once
                            // the engine has released the flash bus.
                            rl_idx       <= 24'd0;
                            burst_active <= 1'b0;
                            st           <= S_RL_REQ;
                        end else if (req_pending && req_filled) begin
                            sd_addr     <= BIOS_BASE + req23;
                            sd_rd       <= 1'b1;
                            op_lock     <= 1'b1;
                            req_pending <= 1'b0;
                            rd_ret      <= S_SERVE;
                            st          <= S_RD;
                        // if req_pending && !req_filled: a new-region read arrived
                        // before its SDRAM fill finished. Do nothing -- hold the
                        // pending request in S_SERVE; the fill runs from this loop
                        // and once newrgn_ready is set the branch above serves it.
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
                // Top of the byte loop. This is the ONLY place in the reload
                // path where the SPI reader is idle and the SDRAM is free, so it
                // is where an LPC read gets serviced. Without this the loader
                // sits in SYNCING for the entire multi-second fill. Priority:
                // completion > refresh > LPC serve > next flash byte.
                S_RL_REQ: begin
                    if (rl_idx >= rl_len ||
                        (rl_sd_base + rl_idx[22:0]) >= SCRATCH_BASE) begin
                        if (s1_filling) begin
                            slot1_ready <= 1'b1;   // XbDiag window now resident
                            s1_filling  <= 1'b0;
                        end else if (nr_filling) begin
                            nr_filling     <= 1'b0;   // new region now resident
                            newrgn_ready   <= 1'b1;
                            reload_pending <= 1'b0;   // also clear if this came via a sync
                        end else begin
                            reload_pending <= 1'b0;
                        end
                        st             <= S_SERVE;
                    end else if (!sd_busy && !op_lock && refresh_due) begin
                        sd_refresh <= 1'b1;
                        op_lock    <= 1'b1;
                    end else if (req_pending && req_filled) begin
                        // A pending LPC read BLOCKS the next flash byte. It is not
                        // enough to merely offer the serve as a same-priority
                        // alternative: S_RL_WRITE leaves op_lock set for a cycle,
                        // so a serve guarded on (!sd_busy && !op_lock) would lose
                        // the race to the flash branch on every single iteration
                        // and never fire. Stall here until the SDRAM is free.
                        if (!sd_busy && !op_lock) begin
                            sd_addr     <= BIOS_BASE + req23;
                            sd_rd       <= 1'b1;
                            op_lock     <= 1'b1;
                            req_pending <= 1'b0;
                            rd_ret      <= S_RL_REQ;
                            st          <= S_RD;
                        end
                    end else if (burst_active) begin
                        st <= S_RL_WAIT;                  // burst already streaming
                    end else if (!fr_busy && !wpend) begin
                        // rl_blen is clamped to the region end and the SCRATCH_BASE
                        // ceiling, so this burst always terminates on a boundary.
                        fr_addr       <= rl_fl_base + rl_idx;
                        fr_len        <= rl_blen;
                        fr_start      <= 1'b1;
                        burst_active  <= 1'b1;
                        rl_burst_left <= rl_blen;
                        st            <= S_RL_WAIT;
                    end
                end

                // Same as S_FLASH_WAIT: the SDRAM is idle while the reader shifts
                // bits, so serve LPC here rather than making the request wait out
                // a burst header.
                S_RL_WAIT: begin
                    if (wpend) begin
                        st <= S_RL_WRITE;
                    end else if (!sd_busy && !op_lock && req_pending && req_filled) begin
                        sd_addr     <= BIOS_BASE + req23;
                        sd_rd       <= 1'b1;
                        op_lock     <= 1'b1;
                        req_pending <= 1'b0;
                        rd_ret      <= S_RL_WAIT;
                        st          <= S_RD;
                    end
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
                            rl_burst_left <= rl_burst_left - 9'd1;
                            if (rl_burst_left == 9'd1)
                                burst_active <= 1'b0;   // burst drained exactly here
                            st      <= S_RL_REQ;
                        end
                    end
                end

                // -------------------------------------------------------------
                // Slot-1 (XbDiag) presence probe: read the 4 'XBEH' magic bytes
                // at SLOT1_SIG. If all match, page in the 768K window; else leave
                // slot 1 cold. Latches slot1_done either way so it runs once.
                // -------------------------------------------------------------
                // Same rule as S_RL_REQ: the probe loop must not starve LPC.
                // Four single-byte reads is ~10 us, well past the 2.8 us serve
                // budget, so it gets a serve branch too.
                // Four bytes, ~10 us. Deliberately left at fr_len = 1: with
                // stall = wpend the single-byte path is unchanged and there is
                // nothing to gain from bursting it.
                S_S1_PROBE: begin
                    if (!sd_busy && !op_lock && refresh_due) begin
                        sd_refresh <= 1'b1;
                        op_lock    <= 1'b1;
                    end else if (req_pending && req_filled) begin
                        // Pending serve blocks the next probe byte -- same
                        // priority rule as S_RL_REQ above.
                        if (!sd_busy && !op_lock) begin
                            sd_addr     <= BIOS_BASE + req23;
                            sd_rd       <= 1'b1;
                            op_lock     <= 1'b1;
                            req_pending <= 1'b0;
                            rd_ret      <= S_S1_PROBE;
                            st          <= S_RD;
                        end
                    end else if (!fr_busy && !wpend) begin
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
                    slot1_ready  <= 1'b0;   // not ready until the loop drains
                    s1_filling   <= 1'b1;
                    burst_active <= 1'b0;
                    st           <= S_RL_REQ;
                end

                // -------------------------------------------------------------
                // Scratch write (update staging). The comment that used to sit
                // here described a NEW REGION probe that does not exist in this
                // state -- the ext-region fill is dispatched from S_SERVE.
                // -------------------------------------------------------------
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