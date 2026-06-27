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
    input              lpc_lframe_n,    // pure input. For 1.6: re-make inout + restore abort driver
    input              lpc_lreset_n,
    inout      [3:0]   lpc_lad,

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

        .state        (lst)
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
    // straps tied internally for the 1.5 test build. To bench 1.6, promote these
    // back to top-level input pads (mode_16 pull-down, boot_en pull-up) in the .cst.
    wire        mode_16 = 1'b0;   // 0 = Xbox 1.0-1.5
    wire        boot_en = 1'b1;   // 1 = modchip active

    wire        d0_oe_b, lframe_oe_b;
    wire        d0_active_b, abort_active_b;
    wire [15:0] abort_count_b;

//    eos_boot_ctrl #(.ABORT_CLKS(4)) u_boot (
//        .clk          (clk_lpc),
//        .resetn       (lpc_lreset_n),
//        .mode_16      (mode_16),
//        .enable       (boot_en),
//        .abort_req    (mem_req),
//        .d0_oe        (d0_oe_b),
//        .lframe_oe    (lframe_oe_b),
//        .abort_count  (abort_count_b),
//        .d0_active    (d0_active_b),
//        .abort_active (abort_active_b)
//    );


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
    wire [22:0] dbg_filled_lo;
    wire [3:0]  dbg_bank;          // live served/selected bank (lclk)
    wire        dbg_reload;        // reload in progress (clk_sd)

    // Flash SPI bus, muxed between the backend reader (preload, default owner)
    // and the flash engine (bank erase/program). One driver at a time, selected
    // by bus_grant; both sample the shared MISO.
    wire        be_flash_cs_n, be_flash_clk, be_flash_mosi;   // backend reader
    wire        eng_flash_cs_n, eng_flash_clk, eng_flash_mosi; // flash engine
    wire        eng_bus_req;
    reg         bus_grant;        // clk_sd: 1 = engine owns the flash bus
    wire        refresh_req; wire [23:0] refresh_base, refresh_len; // engine -> backend reload

    eos_sdram_backend u_be (
        .lclk          (clk_lpc),
        .lresetn       (lpc_lreset_n),

        .mem_req       (mem_req),
        .mem_addr      (mem_addr),
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
        .dbg_filled_lo (dbg_filled_lo),
        .dbg_bank      (dbg_bank),
        .dbg_reload    (dbg_reload)
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
    wire        cmd_stb; wire [1:0] cmd_op; wire [3:0] cmd_bank; wire [11:0] cmd_page;
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
        .eng_reload   (dbg_reload)        // SDRAM reload-in-progress -> STATUS bit3
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
        .bus_req      (eng_bus_req),
        .bus_gnt      (bus_grant),
        .flash_cs_n   (eng_flash_cs_n),
        .flash_clk    (eng_flash_clk),
        .flash_mosi   (eng_flash_mosi),
        .flash_miso   (flash_miso)
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

        .wr_en        (wr_en),
        .wr_addr      (wr_addr),
        .wr_data      (wr_data),
        .wr_attr      (wr_attr)
    );

    wire       vs_t;
    wire       hs_t;
    wire       de_t;
    wire [7:0] ur;
    wire [7:0] ug;
    wire [7:0] ub;

    testpattern u_pat (
        .I_pxl_clk  (pix_clk),
        .I_rst_n    (hdmi_rst_n),
        .I_mode     (3'd0),

        .I_single_r (8'd0),
        .I_single_g (8'd255),
        .I_single_b (8'd0),

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
        .O_vs       (vs_t),
        .O_data_r   (ur),
        .O_data_g   (ug),
        .O_data_b   (ub)
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
        if (!seen_reset_high) begin
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
        end else if (fop_led == 3'd1) begin
            color <= RGB_TO_GRB(8'h40, 8'h00, 8'h00);             // DELETE (erase): red
        end else if (fop_led == 3'd2) begin
            color <= RGB_TO_GRB(8'h2A, 8'h15, 8'h3D);             // WRITE (program): accent purple
        end else if (fop_led == 3'd3) begin
            color <= RGB_TO_GRB(8'h00, 8'h20, 8'h20);             // VERIFY (read): cyan
        end else if (fop_led == 3'd4) begin
            color <= hb[23] ? RGB_TO_GRB(8'h2A, 8'h15, 8'h3D)
                            : RGB_TO_GRB(8'h08, 8'h04, 8'h0C);    // SYNC (reload): purple pulse
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