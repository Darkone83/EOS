// eos_attr_buffer.v -- per-cell 3-bit colour attribute store, parallel to the
// char buffer. Write port = HUD/LPC domain, read port = pixel domain.
// 160x45 = 7200 cells. Power-on contents from eos_attr.hex (all 0 = NORMAL).
module eos_attr_buffer #(
    parameter AW    = 13,
    parameter DEPTH = 7200
)(
    input  wire           wr_clk,
    input  wire           wr_en,
    input  wire [AW-1:0]  wr_addr,
    input  wire [2:0]     wr_data,
    input  wire           rd_clk,
    input  wire [AW-1:0]  rd_addr,
    output reg  [2:0]     rd_data
);
    reg [2:0] mem [0:DEPTH-1];
    initial $readmemh("eos_attr.hex", mem);   // place in src/ alongside eos_font.hex
    always @(posedge wr_clk) if (wr_en) mem[wr_addr] <= wr_data;
    always @(posedge rd_clk) rd_data <= mem[rd_addr];
endmodule