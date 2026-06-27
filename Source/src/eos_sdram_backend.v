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

    output reg         preload_done,
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
    always @(posedge lclk) begin
        if (ef_wr) bank_l <= ef_data[3:0];
    end
    // sync bank into sclk domain for the serve path
    // sync bank into the sclk serve domain. Init-only (no runtime reset) so a
    // reset glitch can't momentarily force the boot bank during the post-warm-
    // reset boot-vector read; it simply tracks the persistent bank_l.
    reg [3:0] bank_s0 = BANK_BOOT, bank_s = BANK_BOOT;
    always @(posedge sclk) begin
        bank_s0 <= bank_l;
        bank_s  <= bank_s0;
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
    function [20:0] xlate; input [3:0] b; input [20:0] a; begin
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
    reg [20:0] req_addr_s;
    always @(posedge sclk or negedge sresetn) begin
        if (!sresetn) req_addr_s <= 21'd0;
        else          req_addr_s <= xlate(bank_eff, mem_addr);
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
    localparam S_RL_WRITE   = 4'd9;   // reload: write byte to SDRAM

    reg [3:0] st;

    // Post-flash reload bookkeeping
    parameter [22:0] SCRATCH_BASE = 23'h60_0000;   // SDRAM serve ceiling (6MB managed)
    reg         reload_pending;
    reg [23:0]  rl_fl_base;     // physical flash base
    reg [22:0]  rl_sd_base;     // SDRAM base = flash base - FLASH_OFF
    reg [23:0]  rl_len;
    reg [23:0]  rl_idx;

    reg [22:0] chunk_base;
    reg [22:0] filled_lo;
    reg [8:0]  got;

    reg        wpend;
    reg [7:0]  wbyte;

    reg        ret_serve;
    reg        op_lock;
    reg        seen_busy;
    reg        sdram_ready;

    wire [22:0] req23      = {2'b0, req_addr_s};
    wire        req_filled = (req23 >= filled_lo);

    assign dbg_filled_lo = filled_lo;
    assign dbg_bank      = bank_l;
    assign dbg_reload    = reload_pending;

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
            rl_fl_base     <= 24'd0;
            rl_sd_base     <= 23'd0;
            rl_len         <= 24'd0;
            rl_idx         <= 24'd0;
        end else begin
            sd_rd      <= 1'b0;
            sd_wr      <= 1'b0;
            sd_refresh <= 1'b0;
            fr_start   <= 1'b0;

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
                        reload_pending <= 1'b0;
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

                default: begin
                    st <= S_INIT;
                end

            endcase
        end
    end

endmodule