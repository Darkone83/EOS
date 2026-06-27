// eos_sdram_pll.v -- clock source for the on-chip SDRAM.
//   27 MHz sys_clk -> 64.8 MHz (x12 / 5) on CLKOUT, plus a 180-degree phase-shifted
//   copy on CLKOUTP for the controller's clk_sdram capture clock.
//   VCO = 64.8 * ODIV(8) = 518.4 MHz (in range). PSDA_SEL="1000" = 180 deg.
//
// These params mirror what the Gowin IP Core Generator emits for this device. If the
// PLL fails to lock or SDRAM reads come back dirty, regenerate via IDE > IP Core
// Generator > rPLL (CLKIN 27 MHz, CLKOUT 64.8 MHz, enable CLKOUTP @ 180 deg) and drop
// the generated wrapper in here -- the phase is the one hardware-tunable knob.
module eos_sdram_pll (
    input  clkin,      // 27 MHz sys_clk
    output clkout,     // 64.8 MHz  -> sdram.clk and backend.sclk
    output clkoutp,    // 64.8 MHz, 180 deg -> sdram.clk_sdram
    output lock
);
    rPLL u_pll (
        .CLKOUT(clkout), .CLKOUTP(clkoutp), .LOCK(lock),
        .CLKOUTD(), .CLKOUTD3(),
        .CLKIN(clkin), .CLKFB(1'b0),
        .RESET(1'b0), .RESET_P(1'b0),
        .FBDSEL(6'b0), .IDSEL(6'b0), .ODSEL(6'b0),
        .PSDA(4'b0), .DUTYDA(4'b0), .FDLY(4'b0)
    );
    defparam u_pll.FCLKIN          = "27";
    defparam u_pll.DYN_IDIV_SEL    = "false";
    defparam u_pll.IDIV_SEL        = 4;        // /5
    defparam u_pll.DYN_FBDIV_SEL   = "false";
    defparam u_pll.FBDIV_SEL       = 11;       // x12  -> 27*12/5 = 64.8 MHz
    defparam u_pll.DYN_ODIV_SEL    = "false";
    defparam u_pll.ODIV_SEL        = 8;        // VCO = 518.4 MHz
    defparam u_pll.PSDA_SEL        = "1000";   // CLKOUTP shifted 180 deg
    defparam u_pll.DYN_DA_EN       = "false";
    defparam u_pll.DUTYDA_SEL      = "1000";
    defparam u_pll.CLKOUT_FT_DIR   = 1'b1;
    defparam u_pll.CLKOUTP_FT_DIR  = 1'b1;
    defparam u_pll.CLKOUT_DLY_STEP = 0;
    defparam u_pll.CLKOUTP_DLY_STEP= 0;
    defparam u_pll.CLKFB_SEL       = "internal";
    defparam u_pll.CLKOUT_BYPASS   = "false";
    defparam u_pll.CLKOUTP_BYPASS  = "false";
    defparam u_pll.CLKOUTD_BYPASS  = "false";
    defparam u_pll.DYN_SDIV_SEL    = 2;
    defparam u_pll.CLKOUTD_SRC     = "CLKOUT";
    defparam u_pll.CLKOUTD3_SRC    = "CLKOUT";
    defparam u_pll.DEVICE          = "GW2AR-18C";
endmodule