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
    inout              i2c_sda,       // SMBus SDA (open-drain)
    input              i2c_scl,       // SMBus SCL
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
    wire        slot1_ready;      // XbDiag slot-1 window resident (clk_sd)
    wire [22:0] dbg_filled_lo;
    wire [3:0]  dbg_bank;          // live served/selected bank (lclk)
    wire        dbg_reload;        // reload in progress (clk_sd)
    wire        dbg_newrgn_ready;  // ext-region resident in SDRAM
    wire [3:0]  ext_anchor;       // per user-slot: oversized anchor (desc)
    wire [7:0]  ext_szc;          // per user-slot: size code (2b each)
    wire [95:0] ext_base;         // per user-slot: phys base rel FLOOR (24b each)

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
    wire        i2c_scr_clear; wire [3:0] i2c_sel_bank;  wire [1:0] i2c_boot_mode;
    wire [15:0] i2c_lock_mask;
    wire [1:0]  i2c_led_mode;   // LEDMODE (0x38): 1 = rainbow (updater active)
    wire        i2c_desc_reload; // DESCRELOAD (0x39, updater SMBus): re-read descriptor
    wire        ldr_desc_reload; // IDX_DESCRELOAD (0x0D, loader flash port): re-read
    wire        ldr_blk_erase;   // IDX_ERASEBLK (0x0E): next erase = single 64K block
    wire        any_desc_reload = i2c_desc_reload | ldr_desc_reload;

    // scratch READ port: CRC owns it during VALIDATE, bank_ctrl during COMMIT
    // (i2c sequences them, never simultaneous).
    assign be_scr_rd    = crc_busy ? crc_scr_rd    : bank_scr_rd;
    assign be_scr_raddr = crc_busy ? crc_scr_raddr : bank_scr_raddr;

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
        .scr_wr        (stg_scr_wr),      // STAGE writes from flash_cmd
        .scr_waddr     (stg_scr_waddr),
        .scr_wdata     (stg_scr_wdata),
        .scr_rd        (be_scr_rd),       // muxed read (CRC / commit)
        .scr_raddr     (be_scr_raddr),
        .scr_rdata     (be_scr_rdata),
        .scr_rvalid    (be_scr_rvalid),
        .scr_busy      (be_scr_busy)
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
        .blk_erase    (ldr_blk_erase),
        .eng_reload   (dbg_reload),       // SDRAM reload-in-progress -> STATUS bit3
        .scr_wr       (stg_scr_wr),
        .scr_waddr    (stg_scr_waddr),
        .scr_wdata    (stg_scr_wdata),
        .scr_busy     (be_scr_busy),
        .newrgn_ready (dbg_newrgn_ready)
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
    wire       i2c_sda_oe, i2c_cmd_stb, i2c_sel;
    wire [7:0] i2c_cmd, i2c_a0, i2c_a1, i2c_a2, i2c_a3, i2c_rxcnt;
    assign i2c_sda = i2c_sda_oe ? 1'b0 : 1'bz;   // open-drain: low or release

    eos_i2c u_i2c (
        .clk      (clk_sd),  .resetn (sd_rstn),
        .sda_in   (i2c_sda), .scl_in (i2c_scl), .sda_oe (i2c_sda_oe),
        .status_in({3'b0, slot1_ready, abort_active_b, d0_active_b, mode_16, preload_done}),
        .cmd      (i2c_cmd), .arg0(i2c_a0), .arg1(i2c_a1), .arg2(i2c_a2), .arg3(i2c_a3),
        .cmd_stb  (i2c_cmd_stb), .rx_count(i2c_rxcnt), .selected(i2c_sel),
        .crc_go(crc_go), .crc_len(crc_len), .crc_busy(crc_busy), .crc_done(crc_done), .crc_result(crc_result),
        .commit_go(i2c_commit_go), .commit_bank(i2c_commit_bank), .commit_pages(i2c_commit_pages),
        .commit_busy(bank_commit_busy), .commit_done(bank_commit_done), .commit_err(bank_commit_err),
        .scr_clear(i2c_scr_clear), .sel_bank(i2c_sel_bank), .boot_mode(i2c_boot_mode), .lock_mask(i2c_lock_mask),
        .led_mode(i2c_led_mode),
        .desc_reload(i2c_desc_reload)
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

        .mem_valid    (mem_valid),
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

        // I2C engine -> HUD panel
        .i2c_addr     (8'hDC), .i2c_vmaj(8'd1), .i2c_vmin(8'd0), .i2c_vpat(8'd0),
        .i2c_cmd      (i2c_cmd), .i2c_a0(i2c_a0), .i2c_a1(i2c_a1),
        .i2c_rx       (i2c_rxcnt), .i2c_sel(i2c_sel),

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

    reg b_start  = 1'b0;
    reg b_drive  = 1'b0;
    reg b_sync   = 1'b0;
    reg b_serv   = 1'b0;
    reg serv_tog = 1'b0;

    always @(posedge clk_lpc or negedge lpc_lreset_n) begin
        if (!lpc_lreset_n) begin
            b_start  <= 1'b0;
            b_drive  <= 1'b0;
            b_sync   <= 1'b0;
            b_serv   <= 1'b0;
            serv_tog <= 1'b0;
        end else begin
            if (lst != 4'd0)
                b_start <= 1'b1;

            if (lad_oe_c)
                b_drive <= 1'b1;

            if (lst == 4'd6)
                b_sync <= 1'b1;

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
    // Rainbow hue generator (for LED rainbow mode while the updater is active).
    // A free-running phase; the top byte is a 0..255 hue swept through a 6-segment
    // color wheel. hue_phase[23] pace gives a pleasant ~1-2s full cycle at 27MHz.
    // -------------------------------------------------------------------------
    reg [31:0] hue_phase = 32'd0;
    always @(posedge sys_clk) hue_phase <= hue_phase + 32'd1;
    wire [7:0] hue = hue_phase[31:24];        // 0..255 sweeping hue

    // hue -> RGB (full saturation/value), classic 6-sector wheel. Scaled down to
    // a gentle brightness so it matches the other LED states (~0x40 peak).
    function [23:0] HUE_TO_GRB;
        input [7:0] h;
        reg [7:0] seg; reg [7:0] t; reg [7:0] r; reg [7:0] g; reg [7:0] b;
        reg [7:0] up; reg [7:0] dn;
        begin
            seg = h[7:5];              // which of 8 sectors (approx 6-sector wheel)
            t   = {h[4:0], 3'b000};    // position within sector, 0..255
            up  = t;                   // rising ramp
            dn  = 8'hFF - t;           // falling ramp
            case (seg)
                3'd0: begin r=8'hFF; g=up;    b=8'h00; end
                3'd1: begin r=dn;    g=8'hFF; b=8'h00; end
                3'd2: begin r=8'h00; g=8'hFF; b=up;    end
                3'd3: begin r=8'h00; g=dn;    b=8'hFF; end
                3'd4: begin r=up;    g=8'h00; b=8'hFF; end
                3'd5: begin r=8'hFF; g=8'h00; b=dn;    end
                default: begin r=8'hFF; g=8'h00; b=8'h00; end
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

    // Optional crude serve counter. Useful if you later want to expose this to HUD.
    reg [15:0] serve_count = 16'd0;

    always @(posedge sys_clk) begin
        if (serve_evt)
            serve_count <= serve_count + 1'b1;
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

endmodule