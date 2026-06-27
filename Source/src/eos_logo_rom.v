// eos_logo_rom.v -- 128x128 4bpp indexed EOS splash (idx0=transparent).
// BSRAM ROM, ~64Kbit. Inits from eos_logo.hex (place in src/).
module eos_logo_rom (
    input  wire        clk,
    input  wire [13:0] addr,    // 128*128 = 16384
    output reg  [3:0]  data
);
    reg [3:0] mem [0:16383];
    initial $readmemh("eos_logo.hex", mem);
    always @(posedge clk) data <= mem[addr];
endmodule