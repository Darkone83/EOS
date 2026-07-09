// eos_text_render.v -- COLOUR text renderer + EOS logo overlay.
// Per-cell 3-bit colour attribute selects FG/BG from a palette (unchanged), with
// the EOS splash composited on the right side at 2x (256x256). Logo read parallels
// the char/attr path and is muxed in at S4; transparent index shows text underneath.
module eos_text_render #(
    parameter COLS = 160,
    parameter ROWS = 45
)(
    input  wire        pclk,
    input  wire        rst_n,
    input  wire        de_in,
    input  wire        hs_in,
    input  wire        vs_in,
    input  wire        wr_clk,
    input  wire        wr_en,
    input  wire [12:0] wr_addr,
    input  wire [7:0]  wr_data,  // char code
    input  wire [2:0]  wr_attr,  // colour attribute
    output reg         de_o,
    output reg         hs_o,
    output reg         vs_o,
    output reg  [7:0]  r_o,
    output reg  [7:0]  g_o,
    output reg  [7:0]  b_o
);
    // ---------------- attribute palette ----------------
    function [23:0] pal_fg; input [2:0] a; begin
        case(a)
            3'd0: pal_fg=24'hE6E6E6; 3'd1: pal_fg=24'hFFFFFF;
            3'd2: pal_fg=24'hA855F7; 3'd3: pal_fg=24'h3CDC5A;
            3'd4: pal_fg=24'hF0B428; 3'd5: pal_fg=24'hF03C3C;
            3'd6: pal_fg=24'hA855F7; default: pal_fg=24'h5A5A66;
        endcase end endfunction
    function [23:0] pal_bg; input [2:0] a; begin
        case(a)
            3'd1: pal_bg=24'hA855F7; 3'd6: pal_bg=24'hA855F7;
            3'd7: pal_bg=24'h2A2A33; default: pal_bg=24'h08080C;
        endcase end endfunction
    localparam [23:0] TITLE_FG=24'hFFFFFF, TITLE_BG=24'hA855F7;

    // ---------------- EOS logo palette (15 colours, idx0=transparent) ----------
    function [23:0] pal_logo; input [3:0] i; begin
        case(i)
            4'd1: pal_logo=24'hFEFB86;
            4'd2: pal_logo=24'hF9DE61;
            4'd3: pal_logo=24'hFFB615;
            4'd4: pal_logo=24'hEEB735;
            4'd5: pal_logo=24'hFD9D0C;
            4'd6: pal_logo=24'hDF971C;
            4'd7: pal_logo=24'hE47208;
            4'd8: pal_logo=24'h995F1A;
            4'd9: pal_logo=24'hA42C06;
            4'd10: pal_logo=24'h5E2508;
            4'd11: pal_logo=24'h2B1309;
            4'd12: pal_logo=24'h140203;
            4'd13: pal_logo=24'h000005;
            4'd14: pal_logo=24'h000100;
            4'd15: pal_logo=24'h000000;
            default: pal_logo=24'h000000;
        endcase end endfunction
    // logo: 256x256 display box (2x of 128x128 ROM), right side, clear of text.
    localparam [11:0] LOGO_X = 12'd980, LOGO_Y = 12'd232, LOGO_W = 12'd256;

    // ---- S0 ----
    reg [11:0] ax, ay; reg de_d, vs_d;
    always @(posedge pclk or negedge rst_n)
        if (!rst_n) begin ax<=0; ay<=0; de_d<=0; vs_d<=0; end
        else begin
            de_d <= de_in; vs_d <= vs_in;
            ax <= de_in ? (ax + 1'b1) : 12'd0;
            if      (vs_in & ~vs_d)  ay <= 12'd0;
            else if (de_d  & ~de_in) ay <= ay + 1'b1;
        end
    wire [5:0] row = ay[9:4];
    wire [7:0] col = ax[10:3];
    wire [11:0] xrel = ax - LOGO_X;
    wire [11:0] yrel = ay - LOGO_Y;
    wire in_logo_c = (ax>=LOGO_X)&&(ax<LOGO_X+LOGO_W)&&(ay>=LOGO_Y)&&(ay<LOGO_Y+LOGO_W);
    wire [13:0] logo_addr_c = {yrel[7:1], xrel[7:1]};
    // row*COLS + col, COLS=160=128+32 -> two shifts + add, no multiplier.
    // row<=44, col<=159 => max 7199, fits 13 bits.
    wire [13:0] caddr1_sum = {row, 7'b0} + {2'b0, row, 5'b0} + {6'b0, col};
    wire [12:0] caddr1_c   = caddr1_sum[12:0];

    // ---- S1 ----
    reg [12:0] caddr1; reg [2:0] px1; reg [3:0] py1; reg title1; reg de1, hs1, vs1;
    reg [13:0] logo_addr1; reg il1;
    always @(posedge pclk or negedge rst_n)
        if (!rst_n) begin caddr1<=0; px1<=0; py1<=0; title1<=0; de1<=0; hs1<=0; vs1<=0; logo_addr1<=0; il1<=0; end
        else begin
            caddr1 <= caddr1_c;
            px1<=ax[2:0]; py1<=ay[3:0]; title1<=(row<6'd2);
            de1<=de_in; hs1<=hs_in; vs1<=vs_in;
            logo_addr1<=logo_addr_c; il1<=in_logo_c;
        end

    // ---- S2: char + attr + logo read ----
    wire [7:0] char_code; wire [2:0] attr_code; wire [3:0] logo_idx;
    eos_char_buffer u_chars (
        .wr_clk(wr_clk),.wr_en(wr_en),.wr_addr(wr_addr),.wr_data(wr_data),
        .rd_clk(pclk),.rd_addr(caddr1),.rd_data(char_code));
    eos_attr_buffer u_attrs (
        .wr_clk(wr_clk),.wr_en(wr_en),.wr_addr(wr_addr),.wr_data(wr_attr),
        .rd_clk(pclk),.rd_addr(caddr1),.rd_data(attr_code));
    eos_logo_rom u_logo (.clk(pclk),.addr(logo_addr1),.data(logo_idx));
    reg [2:0] px2; reg [3:0] py2; reg title2; reg de2,hs2,vs2; reg il2;
    always @(posedge pclk or negedge rst_n)
        if(!rst_n) begin px2<=0;py2<=0;title2<=0;de2<=0;hs2<=0;vs2<=0;il2<=0; end
        else begin px2<=px1;py2<=py1;title2<=title1;de2<=de1;hs2<=hs1;vs2<=vs1;il2<=il1; end

    // ---- S3: font read ----
    wire [7:0] font_row;
    eos_font_rom u_font(.clk(pclk),.addr({char_code,py2}),.data(font_row));
    reg [2:0] px3; reg [2:0] attr3; reg title3; reg de3,hs3,vs3; reg il3; reg [3:0] logo_idx3;
    always @(posedge pclk or negedge rst_n)
        if(!rst_n) begin px3<=0;attr3<=0;title3<=0;de3<=0;hs3<=0;vs3<=0;il3<=0;logo_idx3<=0; end
        else begin px3<=px2;attr3<=attr_code;title3<=title2;de3<=de2;hs3<=hs2;vs3<=vs2;il3<=il2;logo_idx3<=logo_idx; end

    // ---- S4: pixel mux + output ----
    wire bit_on = font_row[3'd7 - px3];
    wire [23:0] fg = title3 ? TITLE_FG : pal_fg(attr3);
    wire [23:0] bg = title3 ? TITLE_BG : pal_bg(attr3);
    wire show_logo = il3 & (logo_idx3 != 4'd0);
    wire [23:0] px = show_logo ? pal_logo(logo_idx3) : (bit_on ? fg : bg);
    always @(posedge pclk or negedge rst_n)
        if(!rst_n) begin de_o<=0;hs_o<=0;vs_o<=0;r_o<=0;g_o<=0;b_o<=0; end
        else begin
            de_o<=de3; hs_o<=hs3; vs_o<=vs3;
            if(!de3) begin r_o<=0;g_o<=0;b_o<=0; end
            else begin r_o<=px[23:16]; g_o<=px[15:8]; b_o<=px[7:0]; end
        end
endmodule