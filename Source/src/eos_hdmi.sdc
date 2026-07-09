// eos_hdmi.sdc
//
// Clocks in this design:
//
//   sys_clk      27.00 MHz   board oscillator (port)
//   serial_clk  371.25 MHz   Gowin_rPLL  -> u_hpll/rpll_inst/CLKOUT   (27*55/4)
//   pix_clk      74.25 MHz   CLKDIV /5 of serial_clk -> u_clkdiv/CLKOUT
//   clk_sd       64.80 MHz   eos_sdram_pll -> u_spll/u_pll/CLKOUT     (27*12/5)
//   clk_sdp      64.80 MHz   eos_sdram_pll -> u_spll/u_pll/CLKOUTP    (180 deg)
//   lpc_lclk     33.33 MHz   Xbox LPC clock (port); the loader runs DIRECTLY on it
//
// lpc_lreset_n used to appear here as a phantom clock: eos_serve_hud contained
// `always @(negedge lreset_n)`, so GowinSynthesis built a clock net on an
// unconstrained, bouncing async pin. That block now synchronises into lclk and
// edge-detects (Phase 6 / F1), so the three CK3000 warnings are gone. If they
// come back, someone reintroduced a negedge-of-a-reset always block.
//
// Keep sys_clk at LVCMOS33 in the CST because SDRAM/bank VCCIO requires 3.3 V.
//
// NOTE ON PIN PATHS:
//   The PLL wrappers are one level deep, so the clock source is the rPLL
//   primitive's pin, NOT the wrapper port:
//       eos_sdram_pll -> rPLL u_pll     => u_spll/u_pll/CLKOUT
//       Gowin_rPLL    -> rPLL rpll_inst => u_hpll/rpll_inst/CLKOUT
//   Using the wrapper port (u_spll/clkout) yields:
//       ERROR (TA2003) Can't set timing constraint to object

// ---------------------------------------------------------------------------
// Primary (port) clocks
// ---------------------------------------------------------------------------
create_clock -name sys_clk  -period 37.037 -waveform {0 18.518} [get_ports {sys_clk}]

// Xbox LPC is 33.333 MHz -> 30.000 ns. The previous 30.303 ns (33.0 MHz) handed
// the analyzer ~1% of slack that does not exist on the most critical domain.
create_clock -name lpc_lclk -period 30.000 -waveform {0 15.000} [get_ports {lpc_lclk}]

// ---------------------------------------------------------------------------
// PLL / divider outputs
// ---------------------------------------------------------------------------
create_clock -name serial_clk -period 2.694  -waveform {0 1.347}  [get_pins {u_hpll/rpll_inst/CLKOUT}]
create_clock -name pix_clk    -period 13.468 -waveform {0 6.734}  [get_pins {u_clkdiv/CLKOUT}]
create_clock -name clk_sd     -period 15.432 -waveform {0 7.716}  [get_pins {u_spll/u_pll/CLKOUT}]

// clk_sdp (u_spll/u_pll/CLKOUTP) is deliberately NOT declared. It has no capture
// logic -- sdram.v only does `assign SDRAM_CLK = clk_sdram`. Declaring it buys
// nothing until an output-delay constraint exists on the SDRAM_* pads.

// ---------------------------------------------------------------------------
// Asynchronous clock groups
// Gowin SDC: MUST be one physical line. Backslash continuation -> TA2000.
// ---------------------------------------------------------------------------
//
//   group 1: sys_clk                  LED, WS2812, POR, raw LPC visibility
//   group 2: serial_clk + pix_clk     TMDS + HUD render -- KEEP TOGETHER,
//                                     DVI_TX_Top crosses these synchronously
//   group 3: clk_sd                   SDRAM ctrl, flash engine, CRC, I2C
//   group 4: lpc_lclk                 LPC loader + boot ctrl
//
// Every path between groups is crossed by an explicit 2FF synchroniser or a
// toggle pulse-sync. Timing them as related clocks pollutes WNS and misdirects
// P&R effort onto paths that do not exist.
//
set_clock_groups -asynchronous -group [get_clocks {sys_clk}] -group [get_clocks {serial_clk pix_clk}] -group [get_clocks {clk_sd}] -group [get_clocks {lpc_lclk}]

// ---------------------------------------------------------------------------
// IF THE LINE ABOVE ERRORS
// ---------------------------------------------------------------------------
//
// Open the timing report's clock summary and read the exact names the analyzer
// created. Two likely deviations:
//
//   1. If a create_clock above is rejected, Gowin auto-derives the PLL output
//      instead and names it "<pin>.default_gen_clk", e.g.
//          u_spll/u_pll/CLKOUT.default_gen_clk
//      Delete the failing create_clock and use the auto name in the group list.
//
//   2. CK3000 warnings naming "<pin>.default_gen_clk" are emitted by
//      GowinSynthesis BEFORE this file is parsed. They do NOT indicate that a
//      create_clock above failed. Only TA2003 / TA2004 mean that.
//
// Pairwise fallback if set_clock_groups misbehaves entirely:
//   set_false_path -from [get_clocks {lpc_lclk}] -to [get_clocks {clk_sd}]
//   set_false_path -from [get_clocks {clk_sd}]   -to [get_clocks {lpc_lclk}]
//   set_false_path -from [get_clocks {lpc_lclk}] -to [get_clocks {pix_clk}]
//   set_false_path -from [get_clocks {clk_sd}]   -to [get_clocks {sys_clk}]
//   set_false_path -from [get_clocks {lpc_lclk}] -to [get_clocks {sys_clk}]

// ---------------------------------------------------------------------------
// LPC pad timing (TODO -- bench-derived, not yet applied)
// ---------------------------------------------------------------------------
//
// lpc_lad / lpc_lframe_n have no input/output delay, so the pad-to-reg and
// reg-to-pad legs of the LPC path are unconstrained; only the internal
// reg-to-reg leg is checked. Once MCPX Tco/Tsu are confirmed on the scope:
//
//   set_input_delay  -clock lpc_lclk -max <t_co_max> [get_ports {lpc_lad[*]}]
//   set_input_delay  -clock lpc_lclk -min <t_co_min> [get_ports {lpc_lad[*]}]
//   set_output_delay -clock lpc_lclk -max <t_su>     [get_ports {lpc_lad[*]}]
//   set_output_delay -clock lpc_lclk -min <-t_h>     [get_ports {lpc_lad[*]}]
//
// Do not add guessed numbers. Leaving these out is the current, working state.
