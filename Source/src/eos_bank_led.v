// eos_bank_led.v -- Bank status LED (external WS2812 on its own pin).
//
// The LOADER tells the gateware what to show (eos_flash_cmd: show_mode/show_rgb):
//   mode 0 = OFF
//   mode 1 = SOLID  (show_rgb, packed {R,G,B}; FF,FF,FF also = off)
//   mode 2 = BREATHE WHITE   (recovery)
//   mode 3 = BREATHE PURPLE  (XbDiag; accent 168,85,247)
//   mode 4 = BREATHE MAGENTA (SD Card staging; neon pink 255,20,147 -- kept
//            visually distinct from XbDiag's purple, not a reuse of it)
//
// BREATHE = smooth triangle brightness ramp (0..full..0), NOT a two-level blink.
// Output `grb` is WS2812 GRB order.
module eos_bank_led #(
    parameter integer CLK_HZ = 27_000_000
)(
    input  wire        clk,
    input  wire        rstn,          // interface parity; not gated (free-running)
    input  wire [2:0]  show_mode,
    input  wire [23:0] show_rgb,      // packed {R,G,B}
    output reg  [23:0] grb            // WS2812 GRB
);
    // ---- breathing ramp ----------------------------------------------------
    // 25-bit phase; bit24 selects rising/falling half, bits[23:16] are the ramp
    // position, giving a smooth 0..255..0 triangle over ~1.24 s at 27 MHz.
    reg [24:0] phase = 25'd0;
    always @(posedge clk) phase <= phase + 25'd1;
    wire [7:0] ramp = phase[24] ? (8'd255 - phase[23:16]) : phase[23:16];
    // small floor so the breathe never fully blacks out at the trough
    wire [7:0] lvl = (ramp < 8'd16) ? 8'd16 : ramp;

    // scale an 8-bit channel by lvl (c * lvl / 256)
    function [7:0] dim; input [7:0] c; input [7:0] l; reg [15:0] p;
        begin p = c * l; dim = p[15:8]; end
    endfunction

    // pack {R,G,B} -> GRB; FF,FF,FF => off
    function [23:0] rgb_to_grb_or_off; input [23:0] rgb;
        begin
            if (rgb[23:16]==8'hFF && rgb[15:8]==8'hFF && rgb[7:0]==8'hFF)
                rgb_to_grb_or_off = 24'h000000;
            else
                rgb_to_grb_or_off = {rgb[15:8], rgb[23:16], rgb[7:0]};
        end
    endfunction

    // breathing white: scale a white peak by lvl -> GRB (equal channels)
    wire [7:0] wv = dim(8'h40, lvl);                       // ~0x40 peak, gentle
    // breathing purple RGB(168,85,247): scale each channel, output GRB
    wire [7:0] pr = dim(8'd168, lvl);   // R
    wire [7:0] pg = dim(8'd85,  lvl);   // G
    wire [7:0] pb = dim(8'd247, lvl);   // B
    // breathing magenta/neon pink RGB(255,20,147): scale each channel, output GRB
    wire [7:0] mr = dim(8'd255, lvl);   // R
    wire [7:0] mg = dim(8'd20,  lvl);   // G
    wire [7:0] mb = dim(8'd147, lvl);   // B

    // free-running (no reset gate) -- mirrors the working onboard color block
    always @(posedge clk) begin
        case (show_mode)
            3'd1: grb <= rgb_to_grb_or_off(show_rgb);   // SOLID user color
            3'd2: grb <= {wv, wv, wv};                  // BREATHE WHITE (GRB, equal)
            3'd3: grb <= {pg, pr, pb};                  // BREATHE PURPLE (GRB)
            3'd4: grb <= {mg, mr, mb};                  // BREATHE MAGENTA (GRB)
            default: grb <= 24'h000000;                 // OFF
        endcase
    end
endmodule