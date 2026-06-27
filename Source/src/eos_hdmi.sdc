// eos_hdmi.sdc
//
// Direct-LCLK test constraints.
// Keep sys_clk at LVCMOS33 in the CST because SDRAM/bank VCCIO requires 3.3 V.

create_clock -name sys_clk  -period 37.040 -waveform {0 18.520} [get_ports {sys_clk}]
create_clock -name pix_clk  -period 13.468 -waveform {0 6.734}  [get_pins {u_clkdiv/CLKOUT}]
create_clock -name lpc_lclk -period 30.303 -waveform {0 15.151} [get_ports {lpc_lclk}]