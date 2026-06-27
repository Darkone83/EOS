// eos_lpc_probe.v -- Phase 1 LPC bus reader. Runs on LCLK (33 MHz from the Xbox).
// Proves the bus is readable: counts LCLK (heartbeat), counts LFRAME# transactions,
// latches live LAD, tracks LRESET#. Continuously writes a hex status line to the
// display via the char-buffer write port (wr_clk = LCLK; dual-port handles CDC).
//
// Static labels for this line live in eos_screen.hex (row 9):
//   "LCLK:____ FRAME:____ LAD:_ RST:_"
// This module only overwrites the underscore cells with live hex.
module eos_lpc_probe #(
    parameter COLS    = 160,
    parameter STAT_ROW = 9
)(
    input  wire        lclk,        // LPC 33 MHz bus clock
    input  wire        lframe_n,    // LPC frame, active low
    input  wire [3:0]  lad,         // LPC mux'd addr/data
    input  wire        lreset_n,    // LPC reset, active low
    // char-buffer write port (to eos_text_render)
    output reg         wr_en,
    output reg  [12:0] wr_addr,
    output reg  [7:0]  wr_data
);
    // ---- capture (all LCLK-synchronous per LPC spec) ----
    reg [31:0] heartbeat = 0;
    reg [15:0] frame_cnt = 0;
    reg [3:0]  lad_cur   = 0;
    reg        lframe_d  = 1'b1;
    always @(posedge lclk) begin
        heartbeat <= heartbeat + 1'b1;
        lad_cur   <= lad;
        lframe_d  <= lframe_n;
        if (lframe_d & ~lframe_n)      // LFRAME# falling edge = transaction start
            frame_cnt <= frame_cnt + 1'b1;
    end

    // ---- nibble -> ASCII hex ----
    function [7:0] hex; input [3:0] n;
        hex = (n < 4'd10) ? (8'h30 + n) : (8'h37 + n);  // 0-9, A-F
    endfunction

    localparam [12:0] BASE = STAT_ROW*COLS;   // row 9 start cell

    // ---- refresh FSM: walk the 10 variable cells, one write per LCLK ----
    reg [3:0] idx = 0;
    reg [6:0] col;       // column of the cell to write
    reg [7:0] ch;        // character to write
    always @(*) begin
        case (idx)
            4'd0: begin col=7'd7;  ch=hex(heartbeat[31:28]); end
            4'd1: begin col=7'd8;  ch=hex(heartbeat[27:24]); end
            4'd2: begin col=7'd9;  ch=hex(heartbeat[23:20]); end
            4'd3: begin col=7'd10; ch=hex(heartbeat[19:16]); end
            4'd4: begin col=7'd18; ch=hex(frame_cnt[15:12]); end
            4'd5: begin col=7'd19; ch=hex(frame_cnt[11:8]);  end
            4'd6: begin col=7'd20; ch=hex(frame_cnt[7:4]);   end
            4'd7: begin col=7'd21; ch=hex(frame_cnt[3:0]);   end
            4'd8: begin col=7'd27; ch=hex(lad_cur);          end
            default: begin col=7'd33; ch=lreset_n ? 8'h31:8'h30; end // '1'/'0'
        endcase
    end
    always @(posedge lclk) begin
        wr_addr <= BASE + col;
        wr_data <= ch;
        wr_en   <= 1'b1;
        idx     <= (idx == 4'd9) ? 4'd0 : idx + 1'b1;
    end
endmodule