// eos_font_rom.v -- 8x16 1bpp font, synchronous read (infers BSRAM/pROM).
// addr = {char_code[7:0], py[3:0]}; data bit7 = leftmost pixel.
module eos_font_rom (
    input  wire        clk,
    input  wire [11:0] addr,
    output reg  [7:0]  data
);
    reg [7:0] mem [0:4095];
    initial $readmemh("eos_font.hex", mem);   // place eos_font.hex in src/
    always @(posedge clk) data <= mem[addr];
endmodule