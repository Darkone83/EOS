// eos_char_buffer.v -- text grid storage. Write port = logic/LPC domain,
// read port = pixel domain. 160x45 = 7200 cells, 1 byte each.
// Power-on contents come from eos_screen.hex (banner + static labels).
module eos_char_buffer #(
    parameter AW    = 13,
    parameter DEPTH = 7200
)(
    input  wire           wr_clk,
    input  wire           wr_en,
    input  wire [AW-1:0]  wr_addr,
    input  wire [7:0]     wr_data,
    input  wire           rd_clk,
    input  wire [AW-1:0]  rd_addr,
    output reg  [7:0]     rd_data
);
    reg [7:0] mem [0:DEPTH-1];
    initial $readmemh("eos_screen.hex", mem);   // place in src/ alongside eos_font.hex
    always @(posedge wr_clk) if (wr_en) mem[wr_addr] <= wr_data;
    always @(posedge rd_clk) rd_data <= mem[rd_addr];
endmodule