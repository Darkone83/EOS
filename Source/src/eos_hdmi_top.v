// eos_hdmi_top.v -- Eos LPC BIOS server, SDRAM-backed.
//
// DIRECT-LCLK TEST BUILD:
// - LPC loader and backend loader-side now run directly from lpc_lclk.
// - This removes the ~371 MHz HDMI serial clock from the LPC critical path.
// - D0 left externally grounded (FPGA does NOT drive it; pin 75 was a config pin).
//   a hard-grounded test rig is unaffected. LFRAME# is open-drain for the 1.6 abort.

module eos_hdmi_top (
    input              sys_clk,
    input              rst_btn,

    input              lpc_lclk,
    inout              lpc_lframe_n,    // 1.6: driven low to abort; else released (input)
    output             lpc_d0,          // low = force LPC boot, Hi-Z = TSOP/stock
    input              lpc_lreset_n,
    inout      [3:0]   lpc_lad,
    inout              i2c_sda,       // Xbox SMBus SDA (open-drain) -- SLAVE only
    inout              i2c_scl,       // Xbox SMBus SCL (open-drain) -- SLAVE only
                                        // (eos_i2c.v answers 0x6E + 0x69 here;
                                        // NOTHING masters this bus anymore --
                                        // the HD/ADV master moved to adv_* below)
    inout              adv_sda,       // PRIVATE ADV7511 I2C SDA (EXP1) -- EOS is
                                        // sole master; open-drain via RTL Hi-Z +
                                        // external pull-up. NOT the Xbox SMBus.
    inout              adv_scl,       // PRIVATE ADV7511 I2C SCL (EXP2)
    inout              adv_int,       // ADV7511 INT / EXP3 when TARGET NOHD
    inout              exp4,          // EXP4 (idx3)  user GPIO/PWM/WS2812/I2C  TODO[board]: .cst IO_LOC
    inout              exp5,          // EXP5 (idx4)
    inout              exp6,          // EXP6 (idx5)
    inout              exp7,          // EXP7 (idx6)
    inout              exp8,          // EXP8 (idx7)
    output              hd_led_green,  // on-board HD status LED (GPIO
                                        // 30/31) -- self-contained in
                                        // eos_hd.v, no path through
                                        // eos_bank_led.v
    output              hd_led_blue,
    input              mode16_n,      // 1.6 strap (pin 77): open=pre-1.6, GND=1.6 (active-low)

    // ---- boot control: LFRAME# abort (1.6) only. D0 stays externally grounded
    //      until a CONFIRMED user-GPIO pin is chosen (pin 75 was a config pin). ----

    output     [5:0]   led,

    output             tmds_clk_p,
    output             tmds_clk_n,
    output      [2:0]  tmds_d_p,
    output      [2:0]  tmds_d_n,

    output             flash_cs_n,
    output             flash_clk,
    output             flash_mosi,
    input              flash_miso,

    output             ws2812,
    output             ws2812_bank,

    // ---- onboard microSD slot, SPI mode (eos_sd_spi.v) ----
    output             card_sck,
    output             card_mosi,
    input              card_miso,
    output             card_cs_n,

    // ---- on-chip SDRAM: magic names, leave OUT of the .cst ----
    output             O_sdram_clk,
    output             O_sdram_cke,
    output             O_sdram_cs_n,
    output             O_sdram_cas_n,
    output             O_sdram_ras_n,
    output             O_sdram_wen_n,
    inout      [31:0]  IO_sdram_dq,
    output     [10:0]  O_sdram_addr,
    output     [1:0]   O_sdram_ba,
    output     [3:0]   O_sdram_dqm
);

    // rst_btn is a real pad in the CST but nothing uses it. Tie it off rather
    // than removing the port (which would also mean editing the .cst).
    wire _unused_rst_btn = rst_btn;

    // -------------------------------------------------------------------------
    // HDMI clocks
    // -------------------------------------------------------------------------

    wire serial_clk;
    wire pix_clk;
    wire hpll_lock;

    Gowin_rPLL u_hpll (
        .clkin  (sys_clk),
        .clkout (serial_clk),
        .lock   (hpll_lock)
    );

    reg [7:0] por = 8'd0;

    always @(posedge sys_clk) begin
        if (!hpll_lock)
            por <= 8'd0;
        else if (~&por)
            por <= por + 1'b1;
    end

    wire hdmi_rst_n = &por;

    CLKDIV u_clkdiv (
        .RESETN (hdmi_rst_n),
        .HCLKIN (serial_clk),
        .CLKOUT (pix_clk),
        .CALIB  (1'b1)
    );

    defparam u_clkdiv.DIV_MODE = "5";
    defparam u_clkdiv.GSREN    = "false";

    // -------------------------------------------------------------------------
    // SDRAM clocks
    // -------------------------------------------------------------------------

    wire clk_sd;
    wire clk_sdp;
    wire spll_lock;

    eos_sdram_pll u_spll (
        .clkin   (sys_clk),
        .clkout  (clk_sd),
        .clkoutp (clk_sdp),
        .lock    (spll_lock)
    );

    reg [9:0] spor = 10'd0;

    always @(posedge clk_sd) begin
        if (!spll_lock)
            spor <= 10'd0;
        else if (~&spor)
            spor <= spor + 1'b1;
    end

    wire sd_rstn = &spor;

    // -------------------------------------------------------------------------
    // LPC clock
    // -------------------------------------------------------------------------
    //
    // DIRECT-LCLK TEST:
    // Use Xbox LPC clock directly for loader-side logic.
    // This avoids the 371 MHz serial_clk timing risk.
    //
    // Backend already CDCs from lclk-domain to sclk-domain internally.

    wire clk_lpc = lpc_lclk;

    // -------------------------------------------------------------------------
    // LPC loader
    // -------------------------------------------------------------------------

    wire        mem_req;
    wire        serving_mem_w;   // 1.6 LFRAME abort window (from loader)
    wire        mem_valid;
    wire [20:0] mem_addr;
    wire        ef_wr;
    wire [7:0]  ef_data;
    wire [7:0]  mem_data;

    // Flash command path (loader <-> bridge <-> engine).
    wire        io_wr_stb_l;       // clk_lpc: generic I/O write strobe from loader
    wire [15:0] io_wr_addr_l;
    wire [7:0]  io_wr_data_l;
    wire        io_rd_stb_l;       // clk_lpc: generic I/O read strobe from loader
    wire [15:0] io_rd_addr_l;
    wire [7:0]  cmd_rd_data_l;     // clk_lpc: status/pbuf byte synced back to loader

    wire [3:0]  lst;
    wire        lad_oe_c;
    wire [3:0]  lad_out_c;

    eos_lpc_loader u_loader (
        .clk          (clk_lpc),
        .lreset_n     (lpc_lreset_n),

        .lclk_pin     (lpc_lclk),
        .lframe_n_pin (lpc_lframe_n),
        .lad_pin      (lpc_lad),

        .lad_out      (lad_out_c),
        .lad_oe       (lad_oe_c),

        .mem_req      (mem_req),
        .mem_addr     (mem_addr),
        .mem_valid    (mem_valid),
        .mem_data     (mem_data),

        .ef_wr        (ef_wr),
        .ef_data      (ef_data),

        .io_wr_stb    (io_wr_stb_l),
        .io_wr_addr   (io_wr_addr_l),
        .io_wr_data   (io_wr_data_l),
        .io_rd_stb    (io_rd_stb_l),
        .io_rd_addr   (io_rd_addr_l),
        .cmd_rd_data  (cmd_rd_data_l),

        .state        (lst),
        .serving_mem  (serving_mem_w)
    );

    assign lpc_lad = lad_oe_c ? lad_out_c : 4'bzzzz;

    // -------------------------------------------------------------------------
    // D0 / LFRAME# boot control
    //   1.0-1.5 : pull D0 low to disable the onboard TSOP and force LPC boot.
    //   1.6     : issue a spec-legal LPC abort (LFRAME# low) so the Xyclops
    //             stops answering the MCPX boot reads, then we serve.
    // Both open-drain: low-or-release, never high -> a hard-grounded D0 test rig
    // is unaffected. D0 is combinational so it is asserted at FPGA config, well
    // before the Xbox's first boot read. abort_req = mem_req is a STARTING point
    // for the 1.6 trigger; the exact condition + ABORT_CLKS are bench-tuned.
    // -------------------------------------------------------------------------
    // mode_16 from the pin-77 strap (active-low, internal pull-up):
    //   open = high = mode16_n 1 -> mode_16 0  (Xbox 1.0-1.5)
    //   GND  = low  = mode16_n 0 -> mode_16 1  (Xbox 1.6)
    // boot_en stays tied active; promote to a pad later if a disable is wanted.
    wire        mode_16 = ~mode16_n;
    wire        boot_en = 1'b1;   // 1 = modchip active

    wire        lframe_oe_b, abort_active_b;
    wire        stock_boot;      // IDX_BOOT(0x08) from loader: 1 = release D0 for TSOP
    wire [15:0] abort_count_b;

    // D0 is externally grounded on this build; report it active on 1.0-1.5.
    wire        d0_active_b = boot_en & ~mode_16 & ~stock_boot;
    // D0: always grounded while active; released only for a TSOP/stock boot.
    assign lpc_d0 = d0_active_b ? 1'b0 : 1'bz;

    // 1.6 LFRAME# abort: hold LFRAME# low for the served mem-read cycle.
    // On 1.0-1.5 (mode_16=0) lframe_oe_b stays 0 and LFRAME# is released.
    assign lpc_lframe_n = lframe_oe_b ? 1'b0 : 1'bz;   // open-drain

    eos_boot_ctrl u_boot (
        .clk          (clk_lpc),
        .resetn       (lpc_lreset_n),
        .mode_16      (mode_16),
        .serving_mem  (serving_mem_w),
        .lframe_oe    (lframe_oe_b),
        .abort_count  (abort_count_b),
        .abort_active (abort_active_b)
    );


    // -------------------------------------------------------------------------
    // SDRAM-backed BIOS server
    // -------------------------------------------------------------------------

    wire        sd_rd;
    wire        sd_wr;
    wire        sd_refresh;
    wire [22:0] sd_addr;
    wire [7:0]  sd_din;
    wire [7:0]  sd_dout;
    wire        sd_dr;
    wire        sd_busy;
    wire        preload_done;
    wire        dbg_script_ready;
    wire        slot1_ready;      // XbDiag slot-1 window resident (clk_sd)
    wire [22:0] dbg_filled_lo;
    wire [3:0]  dbg_bank;          // live served/selected bank (lclk)
    wire        dbg_reload;        // reload in progress (clk_sd)
    wire        dbg_newrgn_ready;  // ext-region resident in SDRAM
    wire [3:0]  ext_anchor;       // per user-slot: oversized anchor (desc)
    wire [7:0]  ext_szc;          // per user-slot: size code (2b each)
    wire [95:0] ext_base;         // per user-slot: phys base rel FLOOR (24b each)

    // ---- SD precache (eos_sd_precache.v -> eos_sdram_backend NRGN_SD fill port) ----
    wire        sdp_nr_wr;
    wire [19:0] sdp_nr_waddr;
    wire [7:0]  sdp_nr_wdata;
    wire        sdp_nr_busy;
    wire        sdp_nr_fill_start;
    wire        sdp_nr_fill_done;
    wire [1:0]  fc_nr_szc;             // NR_SZC holding reg, from eos_flash_cmd
    wire [31:0] fc_sd_lba;             // SD_LBA0-3
    wire [11:0] fc_sd_blkcnt;          // SD_BLKLO/HI
    wire        fc_sd_go;              // SD_GO pulse
    wire        sdp_busy, sdp_done, sdp_err;
    wire [3:0]  sdp_err_code;
    wire        sdp_sd_start;
    wire [31:0] sdp_sd_lba;
    wire        sdp_sd_stall;
    wire        sds_busy, sds_done, sds_dvalid;
    wire [7:0]  sds_dout;
    wire        sds_card_ready, sds_card_err;
    wire [3:0]  sds_err_code;
    // ---- SD browse-read (single sector, FAT32 driver support) ----
    wire [31:0] fc_sd_br_lba;
    wire        fc_sd_br_go;
    wire [8:0]  fc_sd_br_raddr;
    wire [7:0]  sdp_br_rdata;
    wire        sdp_br_busy, sdp_br_done, sdp_br_err;
    wire [3:0]  sdp_br_err_code;
    // ---- SD single-sector write (FatFs/WebUI support) ----
    wire [31:0] fc_sd_bw_lba;
    wire        fc_sd_bw_go;
    wire        fc_sd_bw_we;
    wire [8:0]  fc_sd_bw_waddr;
    wire [7:0]  fc_sd_bw_wdata;
    wire        sdp_bw_busy, sdp_bw_done, sdp_bw_err;
    wire [3:0]  sdp_bw_err_code;
    wire        sdp_sd_write_start;
    wire [8:0]  sds_waddr;
    wire [7:0]  sdp_sd_wdata;

    // Flash SPI bus, muxed between the backend reader (preload, default owner)
    // and the flash engine (bank erase/program). One driver at a time, selected
    // by bus_grant; both sample the shared MISO.
    wire        be_flash_cs_n, be_flash_clk, be_flash_mosi;   // backend reader
    wire        eng_flash_cs_n, eng_flash_clk, eng_flash_mosi; // flash engine
    wire        eng_bus_req;
    reg         bus_grant;        // clk_sd: 1 = engine owns the flash bus
    wire        refresh_req; wire [23:0] refresh_base, refresh_len; // engine -> backend reload

    // ---- updater datapath nets (STAGE / VALIDATE / COMMIT) ----------------
    wire        stg_scr_wr;    wire [20:0] stg_scr_waddr;  wire [7:0] stg_scr_wdata;
    wire        be_scr_rd, be_scr_rvalid, be_scr_busy;
    wire [20:0] be_scr_raddr;  wire [7:0] be_scr_rdata;
    wire        crc_scr_rd;    wire [20:0] crc_scr_raddr;
    wire        bank_scr_rd;   wire [20:0] bank_scr_raddr;
    wire        crc_go, crc_busy, crc_done;  wire [20:0] crc_len;  wire [31:0] crc_result;
    wire        i2c_commit_go; wire [3:0] i2c_commit_bank;  wire [12:0] i2c_commit_pages;
    wire        bank_commit_busy, bank_commit_done, bank_commit_err;
    // RESERVED: driven by eos_i2c, consumed by nothing yet. Left connected so the
    // SMBus register map stays stable for the updater. Wire them up or delete the
    // eos_i2c outputs -- do not silently drop them.
    wire        i2c_scr_clear; wire [3:0] i2c_sel_bank;  wire [1:0] i2c_boot_mode;
    wire [15:0] i2c_lock_mask;
    wire [1:0]  i2c_led_mode;   // LEDMODE (0x38): 1 = rainbow (updater active)
    wire        i2c_desc_reload; // DESCRELOAD (0x39, updater SMBus): re-read descriptor
    // SETBANKCOLOR (0x3A): staged bank+RGB pulse from the loader. Consumed by the
    // LEDCFG color-commit path (finished alongside the loader work). Wired now so
    // the i2c outputs are not silently dropped.
    wire [23:0] bl_c1, bl_c2, bl_c3, bl_c4;   // bank LED colors from bank_ctrl
    wire [2:0]  i2c_set_color_bank;
    wire [23:0] i2c_set_color_rgb;
    wire        i2c_set_color_stb;
    wire        ldr_desc_reload; // IDX_DESCRELOAD (0x0D, loader flash port): re-read
    wire        ldr_blk_erase;   // IDX_ERASEBLK (0x0E): next erase = single 64K block
    wire        any_desc_reload = i2c_desc_reload | ldr_desc_reload;

    // scratch READ port: CRC owns it during VALIDATE, bank_ctrl during COMMIT
    // (i2c sequences them, never simultaneous).
    // (be_scr arbiter extended to 3-way inside the EXP ENGINE block below)

    eos_sdram_backend u_be (
        .lclk          (clk_lpc),
        .lresetn       (lpc_lreset_n),

        .mem_req       (mem_req),
        .mem_addr      (mem_addr),
        .ext_anchor    (ext_anchor),
        .ext_szc       (ext_szc),
        .ext_base      (ext_base),
        .ef_wr         (ef_wr),
        .ef_data       (ef_data),
        .mem_valid     (mem_valid),
        .mem_data      (mem_data),

        .sclk          (clk_sd),
        .sresetn       (sd_rstn),

        .sd_rd         (sd_rd),
        .sd_wr         (sd_wr),
        .sd_refresh    (sd_refresh),
        .sd_addr       (sd_addr),
        .sd_din        (sd_din),
        .sd_dout       (sd_dout),
        .sd_data_ready (sd_dr),
        .sd_busy       (sd_busy),

        .flash_cs_n    (be_flash_cs_n),
        .flash_clk     (be_flash_clk),
        .flash_mosi    (be_flash_mosi),
        .flash_miso    (flash_miso),

        .reload_req    (refresh_req),
        .reload_base   (refresh_base),
        .reload_len    (refresh_len),
        .flash_free    (~bus_grant),

        .preload_done  (preload_done),
        .slot1_ready   (slot1_ready),
        .dbg_filled_lo (dbg_filled_lo),
        .dbg_bank      (dbg_bank),
        .dbg_reload    (dbg_reload),
        .dbg_newrgn_ready (dbg_newrgn_ready),
        .script_ready  (dbg_script_ready),
        .scr_wr        (stg_scr_wr),      // STAGE writes from flash_cmd
        .scr_waddr     (stg_scr_waddr),
        .scr_wdata     (stg_scr_wdata),
        .scr_rd        (be_scr_rd),       // muxed read (CRC / commit)
        .scr_raddr     (be_scr_raddr),
        .scr_rdata     (be_scr_rdata),
        .scr_rvalid    (be_scr_rvalid),
        .scr_busy      (be_scr_busy),

        .nr_wr         (sdp_nr_wr),       // SD precache -> NRGN_SD (eos_sd_precache.v)
        .nr_waddr      (sdp_nr_waddr),
        .nr_wdata      (sdp_nr_wdata),
        .nr_busy       (sdp_nr_busy),
        .nr_fill_start (sdp_nr_fill_start),
        .nr_fill_done  (sdp_nr_fill_done),
        .nr_szc        (fc_nr_szc)
    );

    // -------------------------------------------------------------------------
    // SD card: raw block reader + NRGN_SD precache sequencer. Both live on
    // clk_sd/sd_rstn -- same domain as eos_sdram_backend, so the nr_wr port
    // connects directly with no CDC (same pattern as scr_wr from flash_cmd).
    // -------------------------------------------------------------------------
    eos_sd_spi u_sdspi (
        .clk         (clk_sd), .rstn (sd_rstn),
        .start       (sdp_sd_start),
        .write_start (sdp_sd_write_start),
        .lba         (sdp_sd_lba), .stall (sdp_sd_stall),
        .busy        (sds_busy), .done (sds_done),
        .dvalid      (sds_dvalid), .dout (sds_dout),
        .waddr       (sds_waddr), .wdata (sdp_sd_wdata),
        .card_ready  (sds_card_ready), .card_err (sds_card_err), .err_code (sds_err_code),
        .card_sck    (card_sck), .card_mosi (card_mosi),
        .card_miso   (card_miso), .card_cs_n (card_cs_n)
    );

    eos_sd_precache u_sdprecache (
        .clk (clk_sd), .rstn (sd_rstn),
        .start       (fc_sd_go),
        .lba         (fc_sd_lba),
        .blkcnt      (fc_sd_blkcnt),
        .busy        (sdp_busy),
        .done_sticky (sdp_done),
        .err         (sdp_err),
        .err_code    (sdp_err_code),

        .nr_wr         (sdp_nr_wr),
        .nr_waddr      (sdp_nr_waddr),
        .nr_wdata      (sdp_nr_wdata),
        .nr_busy       (sdp_nr_busy),
        .nr_fill_start (sdp_nr_fill_start),
        .nr_fill_done  (sdp_nr_fill_done),

        .sd_start      (sdp_sd_start),
        .sd_lba        (sdp_sd_lba),
        .sd_stall      (sdp_sd_stall),
        .sd_busy       (sds_busy),
        .sd_done       (sds_done),
        .sd_dvalid     (sds_dvalid),
        .sd_dout       (sds_dout),
        .sd_card_ready (sds_card_ready),
        .sd_card_err   (sds_card_err),
        .sd_err_code   (sds_err_code),

        .browse_go        (fc_sd_br_go),
        .browse_lba       (fc_sd_br_lba),
        .browse_busy      (sdp_br_busy),
        .browse_done      (sdp_br_done),
        .browse_err       (sdp_br_err),
        .browse_err_code  (sdp_br_err_code),
        .browse_raddr     (fc_sd_br_raddr),
        .browse_rdata     (sdp_br_rdata),

        .write_buf_we     (fc_sd_bw_we),
        .write_buf_addr   (fc_sd_bw_waddr),
        .write_buf_data   (fc_sd_bw_wdata),
        .write_go         (fc_sd_bw_go),
        .write_lba        (fc_sd_bw_lba),
        .write_busy       (sdp_bw_busy),
        .write_done       (sdp_bw_done),
        .write_err        (sdp_bw_err),
        .write_err_code   (sdp_bw_err_code),

        .sd_write_start   (sdp_sd_write_start),
        .sd_waddr         (sds_waddr),
        .sd_wdata         (sdp_sd_wdata)
    );

    // -------------------------------------------------------------------------
    // Flash command path: loader (clk_lpc) -> [CDC] -> bridge + engine (clk_sd).
    // The only clock crossing in the flash control plane is here: the loader's
    // generic I/O write strobe + addr/data into clk_sd, and the status byte
    // back. The crossing sits at the I/O-write boundary (one strobe per LPC
    // transaction, microseconds apart) so a simple toggle pulse-sync is robust.
    // -------------------------------------------------------------------------

    // --- clk_lpc side: toggle on each I/O write, hold addr/data ---
    reg        iow_tog_l;
    reg [15:0] iow_addr_hold;
    reg [7:0]  iow_data_hold;
    always @(posedge clk_lpc or negedge lpc_lreset_n) begin
        if (!lpc_lreset_n) begin
            iow_tog_l <= 1'b0; iow_addr_hold <= 16'd0; iow_data_hold <= 8'd0;
        end else if (io_wr_stb_l) begin
            iow_tog_l     <= ~iow_tog_l;
            iow_addr_hold <= io_wr_addr_l;
            iow_data_hold <= io_wr_data_l;
        end
    end

    // --- clk_sd side: sync the toggle, regenerate a 1-cycle strobe ---
    reg [2:0]  iow_tog_s;
    reg [15:0] iow_addr_s;
    reg [7:0]  iow_data_s;
    always @(posedge clk_sd or negedge sd_rstn) begin
        if (!sd_rstn) begin
            iow_tog_s <= 3'd0; iow_addr_s <= 16'd0; iow_data_s <= 8'd0;
        end else begin
            iow_tog_s  <= {iow_tog_s[1:0], iow_tog_l};
            iow_addr_s <= iow_addr_hold;   // stable (held in clk_lpc) by strobe time
            iow_data_s <= iow_data_hold;
        end
    end
    wire io_wr_stb_s = iow_tog_s[2] ^ iow_tog_s[1];

    // --- read-strobe CDC (same toggle-sync pattern) for pbuf streaming ---
    reg        ior_tog_l; reg [15:0] ior_addr_hold;
    always @(posedge clk_lpc or negedge lpc_lreset_n) begin
        if (!lpc_lreset_n) begin ior_tog_l <= 1'b0; ior_addr_hold <= 16'd0; end
        else if (io_rd_stb_l) begin ior_tog_l <= ~ior_tog_l; ior_addr_hold <= io_rd_addr_l; end
    end
    reg [2:0] ior_tog_s; reg [15:0] ior_addr_s;
    always @(posedge clk_sd or negedge sd_rstn) begin
        if (!sd_rstn) begin ior_tog_s <= 3'd0; ior_addr_s <= 16'd0; end
        else begin ior_tog_s <= {ior_tog_s[1:0], ior_tog_l}; ior_addr_s <= ior_addr_hold; end
    end
    wire io_rd_stb_s = ior_tog_s[2] ^ ior_tog_s[1];

    // --- bridge (clk_sd): 0xEC/0xED index/data -> engine command interface ---
    wire [7:0]  bridge_cmd_rd_data;
    wire        cmd_stb; wire [1:0] cmd_op; wire [3:0] cmd_bank; wire [12:0] cmd_page;
    wire        pb_wr; wire [7:0] pb_addr; wire [7:0] pb_din;
    wire [7:0]  pb_raddr, pb_rdata;
    wire        eng_busy, eng_done, eng_refused; wire [7:0] eng_last_status;

    wire [2:0]  fc_led_mode;   // LED show mode from loader (clk_sd)
    wire [23:0] fc_led_rgb;    // LED show color from loader (clk_sd)
    eos_flash_cmd u_fcmd (
        .clk          (clk_sd),
        .cold_rstn    (sd_rstn),
        .io_wr_stb    (io_wr_stb_s),
        .io_wr_addr   (iow_addr_s),
        .io_wr_data   (iow_data_s),
        .io_rd_stb    (io_rd_stb_s),
        .io_rd_addr   (ior_addr_s),
        .cmd_rd_data  (bridge_cmd_rd_data),
        .cmd_stb      (cmd_stb),
        .cmd_op       (cmd_op),
        .cmd_bank     (cmd_bank),
        .cmd_page     (cmd_page),
        .pb_wr        (pb_wr),
        .pb_addr      (pb_addr),
        .pb_din       (pb_din),
        .pb_raddr     (pb_raddr),
        .pb_rdata     (pb_rdata),
        .eng_busy     (eng_busy),
        .eng_done     (eng_done),
        .eng_refused  (eng_refused),
        .eng_last_status (eng_last_status),
        .stock_boot   (stock_boot),
        .desc_reload  (ldr_desc_reload),
        .led_show_mode(fc_led_mode),
        .led_show_rgb (fc_led_rgb),
        .blk_erase    (ldr_blk_erase),
        .eng_reload   (dbg_reload),       // SDRAM reload-in-progress -> STATUS bit3
        .scr_wr       (stg_scr_wr),
        .scr_waddr    (stg_scr_waddr),
        .scr_wdata    (stg_scr_wdata),
        .scr_busy     (be_scr_busy),
        .newrgn_ready (dbg_newrgn_ready),

        .nr_szc             (fc_nr_szc),
        .sd_lba             (fc_sd_lba),
        .sd_blkcnt          (fc_sd_blkcnt),
        .sd_precache_stb    (fc_sd_go),
        .sd_eng_busy        (sdp_busy),
        .sd_eng_done_sticky (sdp_done),
        .sd_eng_err         (sdp_err),
        .sd_eng_err_code    (sdp_err_code),

        .sd_br_lba      (fc_sd_br_lba),
        .sd_br_stb      (fc_sd_br_go),
        .sd_br_raddr    (fc_sd_br_raddr),
        .sd_br_rdata    (sdp_br_rdata),
        .sd_br_busy     (sdp_br_busy),
        .sd_br_done     (sdp_br_done),
        .sd_br_err      (sdp_br_err),
        .sd_br_err_code (sdp_br_err_code),

        .sd_bw_lba      (fc_sd_bw_lba),
        .sd_bw_stb      (fc_sd_bw_go),
        .sd_bw_we       (fc_sd_bw_we),
        .sd_bw_waddr    (fc_sd_bw_waddr),
        .sd_bw_wdata    (fc_sd_bw_wdata),
        .sd_bw_busy     (sdp_bw_busy),
        .sd_bw_done     (sdp_bw_done),
        .sd_bw_err      (sdp_bw_err),
        .sd_bw_err_code (sdp_bw_err_code)
    );

    // --- engine (clk_sd): floor-guarded erase/program/poll ---
    eos_bank_ctrl #(.SCK_DIV(2)) u_bankctrl (
        .clk          (clk_sd),
        .cold_rstn    (sd_rstn),
        .cmd_stb      (cmd_stb),
        .cmd_op       (cmd_op),
        .cmd_bank     (cmd_bank),
        .cmd_page     (cmd_page),
        .pb_wr        (pb_wr),
        .pb_addr      (pb_addr),
        .pb_din       (pb_din),
        .pb_raddr     (pb_raddr),
        .pb_rdata     (pb_rdata),
        .busy         (eng_busy),
        .done         (eng_done),
        .refused      (eng_refused),
        .last_status  (eng_last_status),
        .refresh_req  (refresh_req),     // consumed by backend refresh copy (next pass)
        .refresh_base (refresh_base),
        .refresh_len  (refresh_len),
        .ext_anchor   (ext_anchor),
        .ext_szc      (ext_szc),
        .ext_base     (ext_base),
        .bank1_rgb    (bl_c1),
        .bank2_rgb    (bl_c2),
        .bank3_rgb    (bl_c3),
        .bank4_rgb    (bl_c4),
        .bus_req      (eng_bus_req),
        .bus_gnt      (bus_grant),
        .flash_cs_n   (eng_flash_cs_n),
        .flash_clk    (eng_flash_clk),
        .flash_mosi   (eng_flash_mosi),
        .flash_miso   (flash_miso),
        .commit_go    (i2c_commit_go),
        .desc_reload  (any_desc_reload),
        .blk_erase    (ldr_blk_erase),
        .commit_bank  (i2c_commit_bank),
        .commit_pages (i2c_commit_pages),
        .commit_busy  (bank_commit_busy),
        .commit_done  (bank_commit_done),
        .commit_err   (bank_commit_err),
        .scr_rd       (bank_scr_rd),
        .scr_raddr    (bank_scr_raddr),
        .scr_rdata    (be_scr_rdata),
        .scr_rvalid   (be_scr_rvalid),
        .scr_busy     (be_scr_busy)
    );

    // --- status byte back to loader (clk_sd -> clk_lpc), 2-FF sync ---
    reg [7:0] crd_l1, crd_l2;
    always @(posedge clk_lpc or negedge lpc_lreset_n) begin
        if (!lpc_lreset_n) begin crd_l1 <= 8'd0; crd_l2 <= 8'd0; end
        else begin crd_l1 <= bridge_cmd_rd_data; crd_l2 <= crd_l1; end
    end
    assign cmd_rd_data_l = crd_l2;

    // --- arbiter (clk_sd): engine gets the bus only once preload is done
    //     (reader idle) AND no reload is in flight -- otherwise a settings/flash
    //     write could seize the SPI bus mid-reload and corrupt both the copy and
    //     the in-progress write. Default owner is the backend reader. ---
    always @(posedge clk_sd or negedge sd_rstn) begin
        if (!sd_rstn)
            bus_grant <= 1'b0;
        else if (!bus_grant && eng_bus_req && preload_done && !dbg_reload)
            bus_grant <= 1'b1;
        else if (bus_grant && !eng_bus_req)
            bus_grant <= 1'b0;
    end

    // --- SPI pin mux: engine when granted, else backend reader ---
    assign flash_cs_n = bus_grant ? eng_flash_cs_n : be_flash_cs_n;
    assign flash_clk  = bus_grant ? eng_flash_clk  : be_flash_clk;
    assign flash_mosi = bus_grant ? eng_flash_mosi : be_flash_mosi;

    // --- flash-op status (clk_sd) for the HUD + LED ---
    //   0=IDLE 1=ERASE(delete) 2=WRITE(program) 3=READ(verify) 4=SYNC(reload)
    wire [2:0] fop_sd = eng_busy ? (cmd_op==2'd0 ? 3'd1 :
                                    cmd_op==2'd1 ? 3'd2 : 3'd3)
                      : dbg_reload ? 3'd4 : 3'd0;
    reg [2:0] fop_lc1, fop_lc2;          // -> lclk (HUD)
    always @(posedge clk_lpc) begin fop_lc1 <= fop_sd; fop_lc2 <= fop_lc1; end
    reg [2:0] fop_sy1, fop_sy2;          // -> sys_clk (LED)
    always @(posedge sys_clk) begin fop_sy1 <= fop_sd; fop_sy2 <= fop_sy1; end
    reg [3:0] bank_sy1, bank_sy2;        // live bank -> sys_clk (LED 'load')
    always @(posedge sys_clk) begin bank_sy1 <= dbg_bank; bank_sy2 <= bank_sy1; end
    wire [2:0] fop_hud = fop_lc2;        // flash-op for HUD (lclk)
    wire [2:0] fop_led = fop_sy2;        // flash-op for LED (sys_clk)


    sdram #(
        .FREQ(64_800_000)
    ) u_sdram (
        .clk        (clk_sd),
        .clk_sdram  (clk_sdp),
        .resetn     (sd_rstn),

        .addr       (sd_addr),
        .rd         (sd_rd),
        .wr         (sd_wr),
        .refresh    (sd_refresh),

        .din        (sd_din),
        .dout       (sd_dout),
        .dout32     (),
        .data_ready (sd_dr),
        .busy       (sd_busy),

        .SDRAM_DQ   (IO_sdram_dq),
        .SDRAM_A    (O_sdram_addr),
        .SDRAM_BA   (O_sdram_ba),
        .SDRAM_nCS  (O_sdram_cs_n),
        .SDRAM_nWE  (O_sdram_wen_n),
        .SDRAM_nRAS (O_sdram_ras_n),
        .SDRAM_nCAS (O_sdram_cas_n),
        .SDRAM_CLK  (O_sdram_clk),
        .SDRAM_CKE  (O_sdram_cke),
        .SDRAM_DQM  (O_sdram_dqm)
    );

    // -------------------------------------------------------------------------
    // HDMI HUD
    // -------------------------------------------------------------------------

    wire        wr_en;
    wire [12:0] wr_addr;
    wire [7:0]  wr_data;
    wire [2:0]  wr_attr;

    // ---- Darkone I2C (SMBus slave) engine --------------------------------
    wire       i2c_sda_oe, i2c_scl_oe, i2c_cmd_stb, i2c_sel;
    wire [7:0] i2c_cmd, i2c_a0, i2c_a1, i2c_a2, i2c_a3, i2c_rxcnt;
    // HD transport enable -- now driven for real by eos_hd.v's own
    // hd_addr_en OUTPUT (raised when ADV init completes; the old collision
    // guard is gone), not tied to 0.
    wire       hd_transport_en;
    // eos_hd.v's HD/ADV master now drives a SEPARATE, private bus (adv_sda/
    // adv_scl on EXP1/EXP2), NOT the Xbox SMBus. This is the whole fix: the
    // ADV master and the console's own SMBus master are no longer on the same
    // wire, so there is nothing to collide with -- video bring-up can't be
    // NAKed/blocked and the console can't be fragged by our traffic.
    wire       hd_sda_oe, hd_scl_oe;

    // Xbox SMBus: SLAVE drive only (eos_i2c.v). No HD master term anymore.
    assign i2c_sda = i2c_sda_oe ? 1'b0 : 1'bz;   // open-drain: low or release
    assign i2c_scl = i2c_scl_oe ? 1'b0 : 1'bz;   // (slave clock-stretch only)

    // Private ADV bus: EOS is the sole master; open-drain via Hi-Z + ext pull-up.
    assign adv_sda = hd_sda_oe ? 1'b0 : 1'bz;
    assign adv_scl = hd_scl_oe ? 1'b0 : 1'bz;

    // eos_i2c.v <-> eos_hd.v relay interface (see eos_i2c.v's dual-address
    // note) -- real wires now, eos_hd.v is both ends' other side.
    wire        hd_addr_match, hd_byte_valid, hd_byte_first;
    wire [7:0]  hd_byte;
    wire [7:0]  hd_read_data;
    wire        hd_read_ready;

    // eos_hd.v -> serve HUD status (see gen_hud.py's HD STATUS panel)
    wire [3:0]  hd_encoder_status;
    wire        hd_pll_lock_status, hd_bios_active_status, hd_guard_blocked_status;
    wire [5:0]  hd_brst_status;
    wire [2:0]  hd_disable_reason_status;

    wire [7:0] i2c_ver_major, i2c_ver_minor, i2c_ver_patch;
    eos_i2c u_i2c (
        .clk      (clk_sd),  .resetn (sd_rstn),
        .sda_in   (i2c_sda), .scl_in (i2c_scl), .sda_oe (i2c_sda_oe), .scl_oe (i2c_scl_oe),
        .status_in({3'b0, slot1_ready, abort_active_b, d0_active_b, mode_16, preload_done}),
        .ver_major_out(i2c_ver_major), .ver_minor_out(i2c_ver_minor), .ver_patch_out(i2c_ver_patch),

        // HD relay interface -- eos_hd.v is now the other end of all of
        // these (was tied off before it existed).
        .hd_addr_en(hd_transport_en), .hd_addr_match(hd_addr_match),
        .hd_byte_valid(hd_byte_valid), .hd_byte(hd_byte), .hd_byte_first(hd_byte_first),
        .hd_read_data(hd_read_data), .hd_read_ready(hd_read_ready),

        .cmd      (i2c_cmd), .arg0(i2c_a0), .arg1(i2c_a1), .arg2(i2c_a2), .arg3(i2c_a3),
        .cmd_stb  (i2c_cmd_stb), .rx_count(i2c_rxcnt), .selected(i2c_sel),
        .crc_go(crc_go), .crc_len(crc_len), .crc_busy(crc_busy), .crc_done(crc_done), .crc_result(crc_result),
        .commit_go(i2c_commit_go), .commit_bank(i2c_commit_bank), .commit_pages(i2c_commit_pages),
        .commit_busy(bank_commit_busy), .commit_done(bank_commit_done), .commit_err(bank_commit_err),
        .scr_clear(i2c_scr_clear), .sel_bank(i2c_sel_bank), .boot_mode(i2c_boot_mode), .lock_mask(i2c_lock_mask),
        .led_mode(i2c_led_mode),
        .desc_reload(i2c_desc_reload),
        .set_color_bank(i2c_set_color_bank),
        .set_color_rgb(i2c_set_color_rgb),
        .set_color_stb(i2c_set_color_stb),
        .mbx_rd_index(mbx_rd_index), .mbx_rd_data(mbx_rd_data),
        .mbx_wr_stb  (mbx_wr_stb),   .mbx_wr_index(mbx_wr_index), .mbx_wr_data(mbx_wr_data)
    );

    // ---- EOS-native HD (ADV7511) controller -------------------------------
    // See eos_hd_integration_spec.md. Masters the ADV on the PRIVATE adv_*
    // bus (EXP1/EXP2): ADV presence check, full base init, encoder tweak,
    // standalone (pre-BIOS) video bring-up. The existing physical 1.6 strap
    // selects Xcalibur at boot; otherwise the validated Conexant branch starts
    // and only a BIOS 0xD4 report may transition it to Focus. There is no
    // runtime Xcalibur detection or active encoder probe.
    eos_hd u_hd (
        .clk (clk_sd), .resetn (sd_rstn),
        .xbox_16_mode (mode_16),
        .adv_sda_in (adv_sda), .adv_scl_in (adv_scl),
        .adv_sda_oe (hd_sda_oe), .adv_scl_oe (hd_scl_oe),
        .adv_int (adv_int),
        .hd_addr_en (hd_transport_en), .hd_addr_match (hd_addr_match),
        .hd_byte_valid (hd_byte_valid), .hd_byte (hd_byte), .hd_byte_first (hd_byte_first),
        .hd_read_data (hd_read_data), .hd_read_ready (hd_read_ready),
        .led_green (hd_led_green), .led_blue (hd_led_blue),
        .hd_encoder_out (hd_encoder_status), .hd_pll_lock_out (hd_pll_lock_status),
        .hd_bios_active_out (hd_bios_active_status), .hd_guard_blocked_out (hd_guard_blocked_status),
        .hd_brst_out (hd_brst_status),
        .hd_disable_reason_out (hd_disable_reason_status)
    );

    // ---- CRC32 over scratch (drives VALIDATE) ----
    eos_crc32 u_crc (
        .clk(clk_sd), .resetn(sd_rstn),
        .go(crc_go), .len(crc_len), .busy(crc_busy), .done(crc_done), .crc(crc_result),
        .scr_rd(crc_scr_rd), .scr_raddr(crc_scr_raddr),
        .scr_rdata(be_scr_rdata), .scr_rvalid(be_scr_rvalid), .scr_busy(be_scr_busy)
    );

    eos_serve_hud u_hud (
        .lclk         (clk_lpc),
        .lreset_n     (lpc_lreset_n),
        .vclk         (pix_clk),

        .state        (lst),
        .mem_addr     (mem_addr),
        .lad          (lpc_lad),

        .sd_ready     (sd_rstn),
        .preload_done (preload_done),
        .filled_lo    (dbg_filled_lo),
        .bank_sel     (dbg_bank),
        .flash_op     (fop_hud),

        // boot-control diagnostics
        .mode_16      (mode_16),
        .d0_active    (d0_active_b),
        .abort_active (abort_active_b),
        .abort_count  (abort_count_b),

        // I2C engine -> HUD panel (version now the REAL eos_i2c output, not a
        // separately-hardcoded copy -- that's what let this drift to 1.0.0
        // while eos_i2c.v itself was already at 1.0.1)
        .i2c_addr     (8'hDC), .i2c_vmaj(i2c_ver_major), .i2c_vmin(i2c_ver_minor), .i2c_vpat(i2c_ver_patch),
        .i2c_cmd      (i2c_cmd), .i2c_a0(i2c_a0), .i2c_a1(i2c_a1),
        .i2c_rx       (i2c_rxcnt), .i2c_sel(i2c_sel),

        // HD controller status -- all real now (eos_hd.v exists).
        .hd_encoder       (hd_encoder_status),
        .hd_pll_lock      (hd_pll_lock_status),
        .hd_bios_active   (hd_bios_active_status),
        .hd_guard_blocked (hd_guard_blocked_status),
        .hd_transport_en  (hd_transport_en),
        .hd_brst          ({2'b00, hd_brst_status}),
        .hd_dr            ({5'b00000, hd_disable_reason_status}),

        .wr_en        (wr_en),
        .wr_addr      (wr_addr),
        .wr_data      (wr_data),
        .wr_attr      (wr_attr)
    );

    wire       vs_t;
    wire       hs_t;
    wire       de_t;
    eos_video_timing u_vtg (
        .I_pxl_clk  (pix_clk),
        .I_rst_n    (hdmi_rst_n),

        .I_h_total  (12'd1650),
        .I_h_sync   (12'd40),
        .I_h_bporch (12'd220),
        .I_h_res    (12'd1280),

        .I_v_total  (12'd750),
        .I_v_sync   (12'd5),
        .I_v_bporch (12'd20),
        .I_v_res    (12'd720),

        .I_hs_pol   (1'b1),
        .I_vs_pol   (1'b1),

        .O_de       (de_t),
        .O_hs       (hs_t),
        .O_vs       (vs_t)
    );

    wire       vs_o;
    wire       hs_o;
    wire       de_o;
    wire [7:0] r;
    wire [7:0] g;
    wire [7:0] b;

    eos_text_render u_render (
        .pclk    (pix_clk),
        .rst_n   (hdmi_rst_n),

        .de_in   (de_t),
        .hs_in   (hs_t),
        .vs_in   (vs_t),

        .wr_clk  (pix_clk),
        .wr_en   (wr_en),
        .wr_addr (wr_addr),
        .wr_data (wr_data),
        .wr_attr (wr_attr),

        .de_o    (de_o),
        .hs_o    (hs_o),
        .vs_o    (vs_o),
        .r_o     (r),
        .g_o     (g),
        .b_o     (b)
    );

    DVI_TX_Top u_dvi (
        .I_rst_n       (hdmi_rst_n),
        .I_serial_clk  (serial_clk),
        .I_rgb_clk     (pix_clk),

        .I_rgb_vs      (vs_o),
        .I_rgb_hs      (hs_o),
        .I_rgb_de      (de_o),
        .I_rgb_r       (r),
        .I_rgb_g       (g),
        .I_rgb_b       (b),

        .O_tmds_clk_p  (tmds_clk_p),
        .O_tmds_clk_n  (tmds_clk_n),
        .O_tmds_data_p (tmds_d_p),
        .O_tmds_data_n (tmds_d_n)
    );

      // -------------------------------------------------------------------------
    // Status LEDs + WS2812 boot-status mode
    // -------------------------------------------------------------------------
    //
    // Post-breakthrough meaning:
    //
    // WS2812:
    //   Red pulse      = LPC reset not released
    //   Yellow pulse   = no LPC clock seen
    //   Amber          = BIOS preload not complete
    //   Blue heartbeat = BIOS resident / ready / idle
    //   Green blink    = LPC BIOS read served
    //   Cyan heartbeat = sustained boot/read activity
    //
    // Tang Nano 20K onboard LEDs are active-low:
    //   led[5] = preload done
    //   led[4] = LPC reset high seen
    //   led[3] = LCLK edge seen
    //   led[2] = LAD START seen
    //   led[1] = loader drove LAD
    //   led[0] = byte served

    function [23:0] RGB_TO_GRB;
        input [7:0] rr;
        input [7:0] gg;
        input [7:0] bb;
        begin
            RGB_TO_GRB = {gg, rr, bb};
        end
    endfunction

    // -------------------------------------------------------------------------
    // preload_done into sys_clk domain
    // -------------------------------------------------------------------------

    reg [2:0] pd_s = 3'b000;

    always @(posedge sys_clk) begin
        pd_s <= {pd_s[1:0], preload_done};
    end

    wire pdone = pd_s[2];

    // -------------------------------------------------------------------------
    // Raw LPC visibility in sys_clk domain
    // -------------------------------------------------------------------------

    reg [2:0] lreset_s = 3'b000;
    reg [2:0] lclk_s   = 3'b000;

    reg [3:0] lad_a_sys = 4'hF;
    reg [3:0] lad_b_sys = 4'hF;

    always @(posedge sys_clk) begin
        lreset_s <= {lreset_s[1:0], lpc_lreset_n};
        lclk_s   <= {lclk_s[1:0],   lpc_lclk};

        lad_a_sys <= lpc_lad;
        lad_b_sys <= lad_a_sys;
    end

    wire raw_reset_high = lreset_s[2];
    wire raw_lclk_edge  = lclk_s[2] ^ lclk_s[1];
    wire raw_lad_zero   = (lad_b_sys == 4'h0);

    reg seen_reset_high = 1'b0;
    reg seen_lclk_edge  = 1'b0;
    reg seen_lad_zero   = 1'b0;

    always @(posedge sys_clk) begin
        if (raw_reset_high)
            seen_reset_high <= 1'b1;

        if (raw_lclk_edge)
            seen_lclk_edge <= 1'b1;

        if (raw_lad_zero)
            seen_lad_zero <= 1'b1;
    end

    // -------------------------------------------------------------------------
    // Loader-domain sticky/activity flags
    // -------------------------------------------------------------------------

    // b_start (lst != 0) and b_sync (lst == SYNC_COMPLETE) were assigned here and
    // read nowhere. Removed. b_drive and b_serv feed the LED bank below.
    reg b_drive  = 1'b0;
    reg b_serv   = 1'b0;
    reg serv_tog = 1'b0;

    always @(posedge clk_lpc or negedge lpc_lreset_n) begin
        if (!lpc_lreset_n) begin
            b_drive  <= 1'b0;
            b_serv   <= 1'b0;
            serv_tog <= 1'b0;
        end else begin
            if (lad_oe_c)
                b_drive <= 1'b1;

            if (mem_valid) begin
                b_serv   <= 1'b1;
                serv_tog <= ~serv_tog;
            end
        end
    end

    assign led = ~{
        pdone,
        seen_reset_high,
        seen_lclk_edge,
        seen_lad_zero,
        b_drive,
        b_serv
    };

    // -------------------------------------------------------------------------
    // WS2812 cold-start delay
    // -------------------------------------------------------------------------

    reg [18:0] ws_por = 19'd0;

    always @(posedge sys_clk) begin
        if (ws_por != 19'd270000)
            ws_por <= ws_por + 1'b1;
    end

    wire ws_rst_n = (ws_por == 19'd270000);

    // -------------------------------------------------------------------------
    // Heartbeat
    // -------------------------------------------------------------------------

    reg [24:0] hb = 25'd0;

    always @(posedge sys_clk) begin
        hb <= hb + 1'b1;
    end

    // -------------------------------------------------------------------------
    // Rainbow hue generator (LED rainbow mode while the updater is active).
    //
    // WAS: a 32-bit free-running counter with hue = hue_phase[31:24]. That steps
    // the hue once every 2^24 sys_clk ticks = 0.62 s, so a full 256-step wheel
    // took 159 SECONDS -- the comment claimed 1-2 s and the LED looked static.
    // Worse, the hue fed h[7:5] (EIGHT sectors) into a SIX-arm case, so segments
    // 6 and 7 hit the default arm: 25% of the wheel was a flat red hold.
    //
    // NOW: the hue counts 0..191 = exactly 6 sectors x 32 steps, so every arm of
    // the wheel is used and none is reachable by the default. Stepped once per
    // 2^18 ticks -> 192 * 2^18 / 27 MHz = 1.86 s per full wheel.
    // -------------------------------------------------------------------------
    reg [17:0] hue_pre = 18'd0;
    reg [7:0]  hue     = 8'd0;               // 0..191
    always @(posedge sys_clk) begin
        hue_pre <= hue_pre + 1'b1;
        if (hue_pre == 18'd0)
            hue <= (hue == 8'd191) ? 8'd0 : hue + 1'b1;
    end

    // hue -> RGB (full saturation/value), classic 6-sector wheel. Scaled down to
    // a gentle brightness so it matches the other LED states (~0x40 peak).
    function [23:0] HUE_TO_GRB;
        input [7:0] h;
        reg [7:0] seg; reg [7:0] t; reg [7:0] r; reg [7:0] g; reg [7:0] b;
        reg [7:0] up; reg [7:0] dn;
        begin
            seg = h[7:5];              // h is 0..191, so seg is 0..5: all arms used
            t   = {h[4:0], 3'b000};    // position within sector, 0..248
            up  = t;                   // rising ramp
            dn  = 8'hFF - t;           // falling ramp
            case (seg)
                3'd0: begin r=8'hFF; g=up;    b=8'h00; end
                3'd1: begin r=dn;    g=8'hFF; b=8'h00; end
                3'd2: begin r=8'h00; g=8'hFF; b=up;    end
                3'd3: begin r=8'h00; g=dn;    b=8'hFF; end
                3'd4: begin r=up;    g=8'h00; b=8'hFF; end
                3'd5: begin r=8'hFF; g=8'h00; b=dn;    end
                default: begin r=8'hFF; g=8'h00; b=8'h00; end   // unreachable: h <= 191
            endcase
            // scale to gentle brightness (>>2 ~= 0x40 peak) and pack GRB
            HUE_TO_GRB = { g[7:2], 2'b00, r[7:2], 2'b00, b[7:2], 2'b00 };
        end
    endfunction

    wire [23:0] rainbow_grb = HUE_TO_GRB(hue);

    // -------------------------------------------------------------------------
    // Serve activity pulse and sustained boot activity window
    // -------------------------------------------------------------------------

    reg [2:0] tog_s = 3'b000;

    always @(posedge sys_clk) begin
        tog_s <= {tog_s[1:0], serv_tog};
    end

    wire serve_evt = tog_s[2] ^ tog_s[1];

    // Short green blink on each visible serve burst.
    reg [20:0] serve_pulse = 21'd0;

    always @(posedge sys_clk) begin
        if (serve_evt)
            serve_pulse <= 21'd540000;       // ~20 ms at 27 MHz
        else if (serve_pulse != 0)
            serve_pulse <= serve_pulse - 1'b1;
    end

    // Longer activity window. If reads keep happening, this stays nonzero.
    // This lets a successful boot/activity phase show cyan instead of falling
    // back to red/idle between green pulses.
    reg [24:0] boot_activity = 25'd0;

    always @(posedge sys_clk) begin
        if (serve_evt)
            boot_activity <= 25'd13500000;   // ~500 ms at 27 MHz
        else if (boot_activity != 0)
            boot_activity <= boot_activity - 1'b1;
    end

    // -------------------------------------------------------------------------
    // WS2812 boot-status color logic
    // -------------------------------------------------------------------------

    reg [23:0] color;

    always @(posedge sys_clk) begin
        if (fop_led == 3'd1) begin
            color <= RGB_TO_GRB(8'h40, 8'h00, 8'h00);             // DELETE (erase): red
        end else if (fop_led == 3'd2) begin
            color <= RGB_TO_GRB(8'h2A, 8'h15, 8'h3D);             // WRITE (program): accent purple
        end else if (fop_led == 3'd3) begin
            color <= RGB_TO_GRB(8'h00, 8'h20, 8'h20);             // VERIFY (read): cyan
        end else if (fop_led == 3'd4) begin
            color <= hb[23] ? RGB_TO_GRB(8'h2A, 8'h15, 8'h3D)
                            : RGB_TO_GRB(8'h08, 8'h04, 8'h0C);    // SYNC (reload): purple pulse
        end else if (i2c_led_mode == 2'd1) begin
            // Rainbow mode: the updater sets this on entry (LEDMODE 0x38 = 1) and
            // clears it on exit. It overrides only the IDLE state -- the flash-op
            // statuses above (erase/write/verify/sync) still show through so the
            // user sees real activity while the update app is running.
            color <= rainbow_grb;
        end else if (!seen_reset_high) begin
            // Xbox LPC reset not released / not seen.
            color <= hb[23] ? RGB_TO_GRB(8'h30, 8'h00, 8'h00)
                            : RGB_TO_GRB(8'h04, 8'h00, 8'h00);   // red pulse
        end else if (!seen_lclk_edge) begin
            // LPC reset is high, but no LPC clock detected.
            color <= hb[23] ? RGB_TO_GRB(8'h30, 8'h20, 8'h00)
                            : RGB_TO_GRB(8'h04, 8'h03, 8'h00);   // yellow/orange pulse
        end else if (!pdone) begin
            // BIOS still preloading from flash to SDRAM.
            color <= RGB_TO_GRB(8'h30, 8'h18, 8'h00);             // amber
        end else if (bank_sy2 != 4'h1) begin
            // a launched user bank is being served (not the boot/loader bank)
            color <= hb[24] ? RGB_TO_GRB(8'h00, 8'h30, 8'h00)
                            : RGB_TO_GRB(8'h00, 8'h08, 8'h00);    // LOAD: green
        end else if (serve_pulse != 0) begin
            // Active LPC byte serve.
            color <= RGB_TO_GRB(8'h00, 8'h40, 8'h00);             // green blink
        end else if (boot_activity != 0) begin
            // Sustained boot activity / healthy ongoing reads.
            color <= hb[24] ? RGB_TO_GRB(8'h00, 8'h20, 8'h20)
                            : RGB_TO_GRB(8'h00, 8'h06, 8'h06);   // cyan heartbeat
        end else if (!seen_lad_zero) begin
            // Ready and clocked, but no START observed yet.
            color <= hb[24] ? RGB_TO_GRB(8'h00, 8'h00, 8'h20)
                            : RGB_TO_GRB(8'h00, 8'h00, 8'h04);   // blue heartbeat
        end else if (b_drive || b_serv) begin
            // Known-good idle after successful bus activity.
            // This used to be dim red; make it blue so success doesn't look like fault.
            color <= hb[24] ? RGB_TO_GRB(8'h00, 8'h00, 8'h20)
                            : RGB_TO_GRB(8'h00, 8'h00, 8'h04);   // blue heartbeat
        end else begin
            // Resident and waiting.
            color <= hb[24] ? RGB_TO_GRB(8'h00, 8'h00, 8'h18)
                            : RGB_TO_GRB(8'h00, 8'h00, 8'h03);   // dim blue
        end
    end

    eos_ws2812 #(
        .CLK_HZ(27_000_000)
    ) u_ws (
        .clk    (sys_clk),
        .rstn   (ws_rst_n),
        .grb    (color),
        .ws_out (ws2812)
    );

    // ==== Bank-selection status LED (external WS2812 on pin 29) =========
    // The loader drives what the bank LED shows, via the flash-cmd LED-show
    // register (fc_led_mode / fc_led_rgb, clk_sd). Sync into sys_clk; these
    // change only on menu navigation so a 2-flop sync is sufficient.
    reg [2:0]  led_mode_s1, led_mode_s2;
    reg [23:0] led_rgb_s1, led_rgb_s2;
    always @(posedge sys_clk) begin
        led_mode_s1<=fc_led_mode; led_mode_s2<=led_mode_s1;
        led_rgb_s1 <=fc_led_rgb;  led_rgb_s2 <=led_rgb_s1;
    end

    wire [23:0] bank_led_grb;
    eos_bank_led #(
        .CLK_HZ(27_000_000)
    ) u_bank_led (
        .clk       (sys_clk),
        .rstn      (ws_rst_n),
        .show_mode (led_mode_s2),
        .show_rgb  (led_rgb_s2),
        .grb       (bank_led_grb)
    );

    eos_ws2812 #(
        .CLK_HZ(27_000_000)
    ) u_ws_bank (
        .clk    (sys_clk),
        .rstn   (ws_rst_n),
        .grb    (bank_led_grb),
        .ws_out (ws2812_bank)
    );



    // =====================================================================
    //  EXP EXPANSION ENGINE  (spec: eos_expansion_spec.md)  --  clk_sd domain
    //  Inlined subsystem: header reader + framechk + lexer + layout + volatile
    //  + mailbox + exec + pinmux(PWM/WS2812) + soft-I2C master + loader, plus a
    //  dedicated eos_crc32 (u_exp_crc). Presents ONE scratch reader, arbitrated
    //  behind the updater (crc/bank) on the be_scr port.
    //  TODO[board] items are marked -- confirm against the real NOR/pins.
    // =====================================================================
    // §6: the .eos validity frame is resident at the base of the scratch window,
    // which the SDRAM backend pages from the persistent flash script region
    // (EOS_SCRIPT_FL = 0x800000) once after preload. Frame @ base, text @ +16.
    localparam [20:0] EXP_FRAME_BASE = 21'h00_0000;    // scratch base == flash 0x800000 mirror
    localparam [20:0] EXP_TEXT_BASE  = EXP_FRAME_BASE + 21'd16;
    wire clk = clk_sd;  wire resetn = sd_rstn;
    // Keep the original, proven target source.  The completed 128K script preload
    // now delays validation long enough that we no longer validate against empty
    // scratch at boot, without introducing a second HD-presence state machine.
    wire exp_sys_target = hd_transport_en;             // HD transport active -> EXP1-3 reserved
    wire exp_boot_ready = dbg_script_ready;
    // boot gate: first served BIOS byte (mem_req @clk_lpc) -> sticky -> 2FF -> clk_sd
    reg  exp_served_lclk = 1'b0;
    always @(posedge clk_lpc or negedge lpc_lreset_n)
        if (!lpc_lreset_n) exp_served_lclk<=1'b0; else if (mem_req) exp_served_lclk<=1'b1;
    reg [1:0] exp_fbb = 2'b00;
    always @(posedge clk_sd or negedge sd_rstn)
        if (!sd_rstn) exp_fbb<=2'b00; else exp_fbb<={exp_fbb[0], exp_served_lclk};
    wire exp_first_bios = exp_fbb[1];
    // §6c live replacement: hold the expansion engine in its ordered stop
    // (halt -> SAFE -> release I2C -> mailbox reset -> erase permit) whenever the
    // flash engine is programming/erasing OR a scratch re-page is in flight, then
    // revalidate once both clear (MAGIC re-checked -> run, blank -> idle). This is
    // conservative: it also stops during unrelated bank flashes, which is safe --
    // the engine simply re-reads its resident .eos and restarts from instr 0.
    wire exp_reload_req     = eng_busy | bank_commit_busy | dbg_reload;
    wire exp_reload_disable = 1'b0;    // SAFE hold; an erased/blank region -> Hi-Z via revalidation (§5.5)
    wire exp_erase_permit;             // -> gate your .eos erase/program until this is high
    wire exp_scr_rd; wire [20:0] exp_scr_raddr;
    wire upd_scr_active = crc_busy | bank_scr_rd;      // updater owns the scratch port
    wire [7:0] exp_scr_rdata  = be_scr_rdata;
    wire       exp_scr_rvalid = be_scr_rvalid & ~upd_scr_active;
    wire       exp_scr_busy   = be_scr_busy   | upd_scr_active;
    wire [7:0] mbx_rd_index, mbx_rd_data, mbx_wr_index, mbx_wr_data; wire mbx_wr_stb;
    wire [7:0] exp_out, exp_oe;
    wire [7:0] exp_in = {exp8, exp7, exp6, exp5, exp4, adv_int, adv_scl, adv_sda}; // idx7..0
    wire exp_st_running, exp_st_fault, exp_st_image_valid, exp_st_gate, exp_st_busy;


        // ---- shared CRC (framechk drives it) --------------------------------
    wire        exp_crc_go, exp_crc_busy, exp_crc_done; wire [20:0] exp_crc_len; wire [31:0] exp_crc_result;
    wire        exp_crc_scr_rd; wire [20:0] exp_crc_scr_raddr;
    eos_crc32 u_exp_crc(.clk(clk),.resetn(resetn),.go(exp_crc_go),.len(exp_crc_len),
        .busy(exp_crc_busy),.done(exp_crc_done),.crc(exp_crc_result),
        .scr_rd(exp_crc_scr_rd),.scr_raddr(exp_crc_scr_raddr),
        .scr_rdata(exp_scr_rdata),.scr_rvalid(exp_scr_rvalid),.scr_busy(exp_scr_busy));

    // ---- framechk -------------------------------------------------------
    reg         fc_start_i; wire fc_done_c, fc_valid_c; wire [2:0] fc_reason;
    reg  [31:0] h_tlen, h_crc; reg [7:0] h_tgt;
    eos_exp_framechk u_fc(.clk(clk),.resetn(resetn),.start(fc_start_i),
        .text_len(h_tlen[20:0]),.expected_crc(h_crc),.frame_target(h_tgt[0]),.sys_target(exp_sys_target),
        .crc_go(exp_crc_go),.crc_len(exp_crc_len),.crc_busy(exp_crc_busy),.crc_done(exp_crc_done),.crc_result(exp_crc_result),
        .done(fc_done_c),.valid(fc_valid_c),.reason(fc_reason));

    // ---- header reader (frame @ EXP_FRAME_BASE -> h_tlen/h_crc/h_tgt) --------
    localparam HR_IDLE=3'd0, HR_ISS=3'd1, HR_CON=3'd2, HR_CHK=3'd3, HR_WFC=3'd4, HR_BAD=3'd5;
    reg  [2:0]  hr_st; reg [4:0] hr_idx; reg hr_rd; reg [20:0] hr_raddr;
    reg  [31:0] h_magic; reg [7:0] h_fmt;
    reg         hr_done_p;                 // 1-cyc "invalid frame" done pulse
    wire        hdr_ok = (h_magic==32'h454F5358) && (h_fmt==8'd1);   // 'EOSX', FMT_VER 1
    wire        ldr_fc_start;
    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin hr_st<=HR_IDLE; hr_idx<=5'd0; hr_rd<=1'b0; fc_start_i<=1'b0; hr_done_p<=1'b0; end
        else begin
            fc_start_i<=1'b0; hr_done_p<=1'b0; hr_rd<=1'b0;
            case (hr_st)
            HR_IDLE: if (ldr_fc_start) begin hr_idx<=5'd0; hr_st<=HR_ISS; end
            HR_ISS:  begin hr_rd<=1'b1; hr_raddr<=EXP_FRAME_BASE + {16'd0,hr_idx}; hr_st<=HR_CON; end
            HR_CON:  if (exp_scr_rvalid) begin
                        case (hr_idx)
                          5'd0: h_magic[31:24]<=exp_scr_rdata; 5'd1: h_magic[23:16]<=exp_scr_rdata;
                          5'd2: h_magic[15:8]<=exp_scr_rdata;  5'd3: h_magic[7:0]<=exp_scr_rdata;
                          5'd4: h_fmt<=exp_scr_rdata;          5'd5: h_tgt<=exp_scr_rdata;
                          5'd8: h_tlen[7:0]<=exp_scr_rdata;    5'd9: h_tlen[15:8]<=exp_scr_rdata;
                          5'd10:h_tlen[23:16]<=exp_scr_rdata;  5'd11:h_tlen[31:24]<=exp_scr_rdata;
                          5'd12:h_crc[7:0]<=exp_scr_rdata;     5'd13:h_crc[15:8]<=exp_scr_rdata;
                          5'd14:h_crc[23:16]<=exp_scr_rdata;   5'd15:h_crc[31:24]<=exp_scr_rdata;
                          default: ;
                        endcase
                        if (hr_idx==5'd15) hr_st<=HR_CHK; else begin hr_idx<=hr_idx+5'd1; hr_st<=HR_ISS; end
                     end
            HR_CHK:  if (hdr_ok) begin fc_start_i<=1'b1; hr_st<=HR_WFC; end   // MAGIC/FMT ok -> CRC/target/len check
                     else        begin hr_done_p<=1'b1; hr_st<=HR_BAD; end    // blank/invalid frame
            HR_WFC:  if (fc_done_c) hr_st<=HR_IDLE;
            HR_BAD:  hr_st<=HR_IDLE;
            default: hr_st<=HR_IDLE;
            endcase
        end
    end
    // to loader: done from framechk OR bad-frame pulse; valid only if framechk ran and passed
    wire fc_done_ldr  = fc_done_c | hr_done_p;
    wire fc_valid_ldr = hdr_ok ? fc_valid_c : 1'b0;

    // ---- lexer ----------------------------------------------------------
    wire        lex_scr_rd; wire [20:0] lex_scr_raddr;
    wire        tok_stb,tok_first,line_stb,lex_done,lbusy,lheld; wire [20:0] tok_off,line_off;
    wire [15:0] tok_len,ord,tcount,lno,icount,lcount; wire [1:0] kcl; wire [7:0] kcode;
    wire [127:0] tword; wire [5:0] ttag; wire [31:0] tnum; wire tisnum;
    wire        e_lxs,e_lxack; wire [20:0] e_lxoff; wire [15:0] e_lxord;
    wire [3:0]  ldr_dbg;
    wire        pass2 = (ldr_dbg==4'd5)||(ldr_dbg==4'd6)||(ldr_dbg==4'd7)||(ldr_dbg==4'd8);
    wire        ldr_lay_start;
    wire        lx_start = pass2 ? e_lxs   : ldr_lay_start;
    wire [20:0] lx_off   = pass2 ? e_lxoff : 21'd0;
    wire [15:0] lx_ord   = pass2 ? e_lxord : 16'd0;
    wire        lx_ack   = pass2 ? e_lxack : 1'b1;
    eos_exp_lex u_lex(.clk(clk),.rst_n(resetn),.start(lx_start),.text_base(21'd0),.text_len(h_tlen[20:0]),
        .start_off(lx_off),.start_ord(lx_ord),.lx_ack(lx_ack),.held(lheld),
        .scr_rd(lex_scr_rd),.scr_raddr(lex_scr_raddr),.scr_rdata(exp_scr_rdata),.scr_rvalid(exp_scr_rvalid),.scr_busy(exp_scr_busy),
        .tok_stb(tok_stb),.tok_off(tok_off),.tok_len(tok_len),.tok_is_first(tok_first),
        .tok_word(tword),.tok_tag(ttag),.tok_num(tnum),.tok_isnum(tisnum),
        .line_stb(line_stb),.kw_class(kcl),.kw_code(kcode),.instr_ordinal(ord),.tok_count(tcount),
        .line_off(line_off),.line_no(lno),.done(lex_done),.instr_count(icount),.line_count(lcount),.busy(lbusy));

    // ---- layout ---------------------------------------------------------
    wire        lay_done,lay_ok; wire [2:0] lerr; wire [3:0] pdc; wire [7:0] volu;
    wire [7:0]  q_bo,q_do; wire [63:0] ptf,pif,psf;
    wire [2:0]  cnt_sel; wire [15:0] cnt_val; wire [2:0] i2c_sclp,i2c_sdap; wire i2c_pres;
    wire [6:0]  def_ridx,def_cnt; wire [127:0] def_rword; wire [31:0] def_rval;
    wire [5:0]  dat_ridx,dat_cnt; wire [127:0] dat_rword; wire [20:0] dat_rdoff; wire [31:0] dat_rdlen;
    wire [3:0]  q_sel_mbx; wire [63:0] db_off_flat;
    wire [9:0] desc_raddr, desc_len; wire [7:0] desc_rdata;
    eos_exp_layout u_lay(.clk(clk),.resetn(resetn),.start(ldr_lay_start),
        .tok_stb(tok_stb),.tok_off(tok_off),.tok_len(tok_len),.tok_is_first(tok_first),
        .tok_word(tword),.tok_tag(ttag),.tok_num(tnum),.tok_isnum(tisnum),
        .line_stb(line_stb),.kw_class(kcl),.kw_code(kcode),.lex_done(lex_done),
        .frame_target(h_tgt[0]),.instr_count(icount),
        .done(lay_done),.ok(lay_ok),.err(lerr),.pindef_count(pdc),.volatile_used(volu),
        .q_sel(q_sel_mbx),.q_bankoff(q_bo),.q_dboff(q_do),.db_off_flat(db_off_flat),
        .desc_raddr(desc_raddr),.desc_rdata(desc_rdata),.desc_len(desc_len),
        .pin_type_flat(ptf),.pin_init_flat(pif),.pin_safe_flat(psf),
        .cnt_sel(cnt_sel),.cnt_val(cnt_val),.i2c_scl_pin(i2c_sclp),.i2c_sda_pin(i2c_sdap),.i2c_present(i2c_pres),
        .def_ridx(def_ridx),.def_rword(def_rword),.def_rval(def_rval),.def_cnt(def_cnt),
        .dat_ridx(dat_ridx),.dat_rword(dat_rword),.dat_rdoff(dat_rdoff),.dat_rdlen(dat_rdlen),.dat_cnt(dat_cnt));

    // ---- volatile (host=mailbox, script=exec) ---------------------------
    wire        v_zero,v_zbusy;
    wire        mv_wr; wire [7:0] mv_waddr,mv_wdata,mv_raddr,mv_rdata;
    wire        se_wr; wire [7:0] se_raddr,se_rdata,se_waddr,se_wdata;
    eos_exp_volatile u_vol(.clk(clk),.resetn(resetn),.zero(v_zero),.zbusy(v_zbusy),
        .h_wr(mv_wr),.h_waddr(mv_waddr),.h_wdata(mv_wdata),.h_raddr(mv_raddr),.h_rdata(mv_rdata),
        .s_wr(se_wr),.s_waddr(se_waddr),.s_wdata(se_wdata),.s_raddr(se_raddr),.s_rdata(se_rdata));

    // ---- mailbox (0x6E 0x40-0x6F) ---------------------------------------
    wire mbx_clr;
    eos_exp_mailbox u_mbx(.clk(clk),.resetn(resetn),
        .st_running(exp_st_running),.st_fault(exp_st_fault),.st_image_valid(exp_st_image_valid),
        .st_boot_gate(exp_st_gate),.st_busy(exp_st_busy),.mbx_clr(mbx_clr),
        .fault_code(fcode),.pc(pc),.pindef_count(pdc),
        .rd_index(mbx_rd_index),.rd_data(mbx_rd_data),
        .wr_stb(mbx_wr_stb),.wr_index(mbx_wr_index),.wr_data(mbx_wr_data),
        .q_sel(q_sel_mbx),.q_bankoff(q_bo),.q_dboff(q_do),.db_off_flat(db_off_flat),
        .desc_raddr(desc_raddr),.desc_rdata(desc_rdata),.desc_len(desc_len),
        .script_wr(se_wr),.script_waddr(se_waddr),.script_wdata(se_wdata),
        .v_wr(mv_wr),.v_waddr(mv_waddr),.v_wdata(mv_wdata),.v_raddr(mv_raddr),.v_rdata(mv_rdata));

    // ---- exec -----------------------------------------------------------
    wire        exec_start,exec_halt,exec_running,exec_fault; wire [7:0] fcode; wire [15:0] pc;
    wire        p_start; wire [7:0] p_op,p_result,p_a0; wire [2:0] p_pin3; wire [16:0] p_a1; wire p_done;
    wire        ws_wr; wire [11:0] ws_waddr; wire [7:0] ws_wdata; wire ws_send; wire [12:0] ws_len; wire ws_zero; wire [2:0] ws_pin; wire ws_busy;
    wire        iw_wr; wire [8:0] iw_waddr; wire [7:0] iw_wdata; wire i2c_go,i2c_read; wire [6:0] i2c_addr; wire [8:0] i2c_len,ir_raddr; wire [7:0] ir_rdata;
    wire        i2c_busy,i2c_done; wire [2:0] i2c_result;
    wire        x_scr_rd; wire [20:0] x_scr_raddr;
    eos_exp_exec #(.CYCLES_PER_MS(32'd64800),.WATCHDOG_CYC(32'd32400000)) u_exe(.clk(clk),.resetn(resetn),
        .start(exec_start),.halt(exec_halt),.text_len(h_tlen[20:0]),
        .pin_type_flat(ptf),.i2c_present(i2c_pres),
        .line_stb(line_stb),.kw_class(kcl),.kw_code(kcode),.line_off(line_off),.instr_ordinal(ord),
        .tok_stb(tok_stb),.tok_len(tok_len),.tok_is_first(tok_first),.tok_word(tword),.tok_tag(ttag),.tok_num(tnum),.tok_isnum(tisnum),
        .lex_held(lheld),.lex_done(lex_done),
        .lx_start(e_lxs),.lx_off(e_lxoff),.lx_ord(e_lxord),.lx_ack(e_lxack),
        .s_raddr(se_raddr),.s_rdata(se_rdata),.s_wr(se_wr),.s_waddr(se_waddr),.s_wdata(se_wdata),
        .v_zero(v_zero),.v_zbusy(v_zbusy),
        .p_start(p_start),.p_op(p_op),.p_pin(p_pin3),.p_arg0(p_a0),.p_arg1(p_a1),
        .p_busy(1'b0),.p_done(p_done),.p_result(p_result),
        .ws_wr(ws_wr),.ws_waddr(ws_waddr),.ws_wdata(ws_wdata),.ws_send(ws_send),.ws_len(ws_len),
        .ws_zero(ws_zero),.ws_pin(ws_pin),.ws_busy(ws_busy),.cnt_sel(cnt_sel),.cnt_val(cnt_val),
        .iw_wr(iw_wr),.iw_waddr(iw_waddr),.iw_wdata(iw_wdata),.i2c_go(i2c_go),.i2c_read(i2c_read),
        .i2c_addr(i2c_addr),.i2c_len(i2c_len),.ir_raddr(ir_raddr),.ir_rdata(ir_rdata),
        .i2c_busy(i2c_busy),.i2c_done(i2c_done),.i2c_result(i2c_result),
        .def_ridx(def_ridx),.def_rword(def_rword),.def_rval(def_rval),.def_cnt(def_cnt),
        .dat_ridx(dat_ridx),.dat_rword(dat_rword),.dat_rdoff(dat_rdoff),.dat_rdlen(dat_rdlen),.dat_cnt(dat_cnt),
        .x_scr_rd(x_scr_rd),.x_scr_raddr(x_scr_raddr),.x_scr_rdata(exp_scr_rdata),.x_scr_rvalid(exp_scr_rvalid),.x_scr_busy(exp_scr_busy),
        .running(exec_running),.fault(exec_fault),.fault_code(fcode),.pc(pc));

    // ---- pins (pinmux + PWM + WS2812) -----------------------------------
    wire        pins_active,safe_out;
    wire        i2c_m_scl_oe,i2c_m_sda_oe,i2c_m_scl_in,i2c_m_sda_in;
    eos_exp_pins #(.CLK_HZ(32'd64800000)) u_pins(.clk(clk),.resetn(resetn),.boot_gate(pins_active),.safe_mode(safe_out),
        .pin_type_flat(ptf),.pin_init_flat(pif),.pin_safe_flat(psf),
        .p_start(p_start),.p_op(p_op),.p_pin(p_pin3),.p_val0(p_a0),.p_val1(p_a1),
        .p_done(p_done),.p_result(p_result),
        .ws_wr(ws_wr),.ws_waddr(ws_waddr),.ws_wdata(ws_wdata),.ws_send(ws_send),.ws_len(ws_len),
        .ws_zero(ws_zero),.ws_pin(ws_pin),.ws_busy(ws_busy),
        .i2c_scl_pin(i2c_sclp),.i2c_sda_pin(i2c_sdap),.i2c_present(i2c_pres),
        .i2c_scl_oe(i2c_m_scl_oe),.i2c_sda_oe(i2c_m_sda_oe),.i2c_scl_in(i2c_m_scl_in),.i2c_sda_in(i2c_m_sda_in),
        .exp_out(exp_out),.exp_oe(exp_oe),.exp_in(exp_in));

    // ---- soft I2C master (script I2CW/I2CR) -----------------------------
    eos_exp_i2c #(.SCL_LOW_CYCLES(324),.SCL_HIGH_CYCLES(324)) u_i2cm(.clk(clk),.resetn(resetn),
        .sda_in(i2c_m_sda_in),.scl_in(i2c_m_scl_in),.sda_oe(i2c_m_sda_oe),.scl_oe(i2c_m_scl_oe),
        .iw_wr(iw_wr),.iw_waddr(iw_waddr),.iw_wdata(iw_wdata),.ir_raddr(ir_raddr),.ir_rdata(ir_rdata),
        .i2c_go(i2c_go),.i2c_read(i2c_read),.i2c_addr(i2c_addr),.i2c_len(i2c_len),
        .i2c_busy(i2c_busy),.i2c_done(i2c_done),.i2c_result(i2c_result));

    // ---- loader (lifecycle orchestrator) --------------------------------
    eos_exp_loader u_ldr(.clk(clk),.resetn(resetn),
        .first_bios_byte(exp_first_bios & exp_boot_ready),.reload_req(exp_reload_req),.reload_disable(exp_reload_disable),
        .fc_done(fc_done_ldr),.fc_valid(fc_valid_ldr),.lay_done(lay_done),.lay_ok(lay_ok),
        .exec_running(exec_running),.exec_fault(exec_fault),
        .fc_start(ldr_fc_start),.lay_start(ldr_lay_start),.exec_start(exec_start),.exec_halt(exec_halt),
        .pins_active(pins_active),.safe_out(safe_out),.mbx_reset(mbx_clr),.erase_permit(exp_erase_permit),
        .st_running(exp_st_running),.st_fault(exp_st_fault),.st_image_valid(exp_st_image_valid),
        .st_gate_open(exp_st_gate),.st_busy(exp_st_busy),.dbg_state(ldr_dbg));

    // ---- scratch READ arbiter (hdr > crc > exec-x > lexer; EXP_TEXT_BASE add)
    assign exp_scr_rd    = hr_rd ? 1'b1 : exp_crc_scr_rd ? 1'b1 : x_scr_rd ? 1'b1 : lex_scr_rd;
    assign exp_scr_raddr = hr_rd     ? hr_raddr :
                       exp_crc_scr_rd ? (EXP_TEXT_BASE + exp_crc_scr_raddr) :
                       x_scr_rd   ? (EXP_TEXT_BASE + x_scr_raddr) :
                                    (EXP_TEXT_BASE + lex_scr_raddr);

    // ---- scratch arbiter: updater (crc VALIDATE / bank COMMIT) first, EXP behind ----
    assign be_scr_rd    = crc_busy ? crc_scr_rd    : bank_scr_rd ? bank_scr_rd    : exp_scr_rd;
    assign be_scr_raddr = crc_busy ? crc_scr_raddr : bank_scr_rd ? bank_scr_raddr : exp_scr_raddr;
    // ---- EXP4..EXP8 open-drain (idx3..7). EXP1..3 (idx0..2)=ADV bus, reserved under HD ----
    // Under NOHD the editor/spec exposes all eight EXP pins. The ADV private
    // bus remains authoritative under HD; expansion only adds a driver when
    // hd_transport_en is false.
    assign adv_sda = (!hd_transport_en && exp_oe[0]) ? exp_out[0] : 1'bz; // EXP1
    assign adv_scl = (!hd_transport_en && exp_oe[1]) ? exp_out[1] : 1'bz; // EXP2
    assign adv_int = (!hd_transport_en && exp_oe[2]) ? exp_out[2] : 1'bz; // EXP3
    assign exp4 = exp_oe[3] ? exp_out[3] : 1'bz;
    assign exp5 = exp_oe[4] ? exp_out[4] : 1'bz;
    assign exp6 = exp_oe[5] ? exp_out[5] : 1'bz;
    assign exp7 = exp_oe[6] ? exp_out[6] : 1'bz;
    assign exp8 = exp_oe[7] ? exp_out[7] : 1'bz;
endmodule