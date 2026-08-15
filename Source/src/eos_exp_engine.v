// ===========================================================================
//  eos_exp_engine.v  —  EOS expansion engine (control plane, one file)
// ===========================================================================
//  Grows section-by-section per the gateware plan. M0 delivers the lexer.
//  Later milestones add symtab / layout / exec / mailbox / volatile / pinmux
//  as further modules in THIS file.
// ===========================================================================
`include "eos_exp_pkg.vh"

// Compact exact token IDs. The lexer recognizes reserved words serially as
// characters arrive; downstream logic compares 6-bit tags instead of 64-bit
// strings. tok_word is retained only for user DEF/DATA symbol names.
`define EOS_T_NONE     6'd0
`define EOS_T_NOP      6'd1
`define EOS_T_SET      6'd2
`define EOS_T_GET      6'd3
`define EOS_T_DELAY    6'd4
`define EOS_T_PWM      6'd5
`define EOS_T_WS       6'd6
`define EOS_T_I2CW     6'd7
`define EOS_T_I2CR     6'd8
`define EOS_T_GETMAIL  6'd9
`define EOS_T_SETMAIL  6'd10
`define EOS_T_LOOP     6'd11
`define EOS_T_ENDLOOP  6'd12
`define EOS_T_IFMAIL   6'd13
`define EOS_T_END      6'd14
`define EOS_T_TARGET   6'd15
`define EOS_T_USES     6'd16
`define EOS_T_REG      6'd17
`define EOS_T_I2CADDR  6'd18
`define EOS_T_DEF      6'd19
`define EOS_T_DATA     6'd20
`define EOS_T_AS       6'd21
`define EOS_T_WIDTH    6'd22
`define EOS_T_INIT     6'd23
`define EOS_T_SAFE     6'd24
`define EOS_T_COUNT    6'd25
`define EOS_T_GPIO_IN  6'd26
`define EOS_T_GPIO_OUT 6'd27
`define EOS_T_WS2812   6'd28
`define EOS_T_I2C      6'd29
`define EOS_T_VOL      6'd30
`define EOS_T_EQ       6'd31
`define EOS_T_NE       6'd32
`define EOS_T_LT       6'd33
`define EOS_T_GT       6'd34
`define EOS_T_GE       6'd35
`define EOS_T_LE       6'd36
`define EOS_T_EXP1     6'd37
`define EOS_T_EXP2     6'd38
`define EOS_T_EXP3     6'd39
`define EOS_T_EXP4     6'd40
`define EOS_T_EXP5     6'd41
`define EOS_T_EXP6     6'd42
`define EOS_T_EXP7     6'd43
`define EOS_T_EXP8     6'd44
`define EOS_T_R0       6'd45
`define EOS_T_R1       6'd46
`define EOS_T_R2       6'd47
`define EOS_T_R3       6'd48
`define EOS_T_R4       6'd49
`define EOS_T_R5       6'd50
`define EOS_T_R6       6'd51
`define EOS_T_R7       6'd52


// ---------------------------------------------------------------------------
//  eos_exp_lex  —  flash byte-fetch -> line/token stream (spec 3, 4.1)
//
//  Streams the script text body from flash, strips '#'-to-EOL comments and
//  whitespace, case-folds, splits into whitespace-separated tokens, classifies
//  the first token (directive / command / unknown), and maintains the running
//  instruction ordinal (the fault PC).  Counting rule matches the IDE linter:
//  a non-empty line whose first token is NOT a directive is an instruction.
// ---------------------------------------------------------------------------
module eos_exp_lex (
    input               clk,
    input               rst_n,

    input               start,        // pulse to begin / restart (seekable)
    input  [20:0]       text_base,    // scratch byte offset of text body
    input  [20:0]       text_len,     // text length in bytes
    input  [20:0]       start_off,    // restart byte offset (relative to text_base)
    input  [15:0]       start_ord,    // instruction ordinal to resume counting from
    input               lx_ack,       // exec ready for next line (flow control)
    output              held,         // lexer paused at a line boundary

    // SDRAM scratch read port (clk_sd) -- muxed to eos_sdram_backend in the
    // top, the same handshake eos_crc32 / eos_bank_ctrl use.
    output reg          scr_rd,
    output reg [20:0]   scr_raddr,
    input  [7:0]        scr_rdata,
    input               scr_rvalid,
    input               scr_busy,

    // per-token stream (spans; content stays in flash)
    output reg          tok_stb,
    output reg [20:0]   tok_off,
    output reg [15:0]   tok_len,
    output reg          tok_is_first,
    output reg [127:0]  tok_word,     // up to 16 case-folded chars (editor/spec MAX_NAME_LEN)
    output reg [5:0]    tok_tag,      // exact compact tag for reserved words / EXPn / Rn
    output reg [31:0]   tok_num,      // parsed decimal / 0x-hex value
    output reg          tok_isnum,

    // per-line stream
    output reg          line_stb,
    output reg [1:0]    kw_class,     // 0 unknown / 1 directive / 2 command
    output reg [7:0]    kw_code,      // opcode (command) or directive id
    output reg [15:0]   instr_ordinal,// valid when the line is an instruction
    output reg [15:0]   tok_count,
    output reg [20:0]   line_off,
    output reg [15:0]   line_no,

    output reg          done,
    output reg [15:0]   instr_count,  // running instructions
    output reg [15:0]   line_count,   // running non-empty lines
    output reg          busy
);

    // ---- states ----
    localparam S_IDLE = 3'd0, S_REQ = 3'd1, S_RCV = 3'd2,
               S_PROC = 3'd3, S_EOF = 3'd4, S_DONE = 3'd5, S_HELD = 3'd6;
    reg [2:0] state;
    reg pending_hold, at_eof;
    assign held = (state == S_HELD);

    reg [20:0] byte_idx;
    reg [7:0]  cur_byte;

    // tokenizer state
    reg        in_comment;
    reg        in_token;
    reg        cur_tok_is_first;
    reg [20:0] tok_start;
    reg [15:0] tok_len_acc;
    reg        first_seen;      // first token of this line has begun
    reg        line_has_tok;
    reg [20:0] line_start_off;
    reg [5:0]  first_tag_saved; // first token after it has closed
    reg [6:0]  tag_state;       // reserved-word trie state for current token
    reg [127:0] curword; reg [4:0] curcnt;  // current token word capture (symbols only downstream)
    reg [31:0] curnum;  reg curisnum, curhex, cursaw0;
    reg [15:0] tcnt;            // running token count for the current line

    // char classes of cur_byte
    wire [7:0] cb   = cur_byte;
    wire [7:0] fold = (cb >= 8'h61 && cb <= 8'h7A) ? (cb - 8'h20) : cb;
    wire is_lf   = (cb == 8'h0A);
    wire is_hash = (cb == 8'h23);
    wire is_ws   = (cb == 8'h20) || (cb == 8'h09) || (cb == 8'h0D);
    wire is_tok  = ~is_lf & ~is_hash & ~is_ws;
    wire is_digit = (cb >= 8'h30 && cb <= 8'h39);
    wire is_hexU  = (fold >= 8'h41 && fold <= 8'h46);
    wire is_xchar = (cb == 8'h78 || cb == 8'h58);
    wire [3:0] dig  = cb - 8'h30;
    wire [3:0] hexv = is_digit ? (cb - 8'h30) : (fold - 8'h41 + 4'd10);

    // Exact reserved-word recognizer as a compact binary trie/DFA. Terminal
    // states are deliberately numbered exactly like EOS_T_* (1..52), so the
    // recognized token tag is the state itself; prefix-only states occupy
    // 53..126 and 127 is DEAD. This removes all 64-bit string comparisons.
    localparam [6:0] TAG_DEAD = 7'd127;
    function [6:0] tag_next;
        input [6:0] s; input [7:0] c;
        begin
            tag_next = TAG_DEAD;
            case (s)
            7'd0: case (c)
                8'h41: tag_next = 7'd101;
                8'h43: tag_next = 7'd109;
                8'h44: tag_next = 7'd58;
                8'h45: tag_next = 7'd76;
                8'h47: tag_next = 7'd57;
                8'h49: tag_next = 7'd65;
                8'h4C: tag_next = 7'd73;
                8'h4E: tag_next = 7'd53;
                8'h50: tag_next = 7'd62;
                8'h52: tag_next = 7'd93;
                8'h53: tag_next = 7'd55;
                8'h54: tag_next = 7'd85;
                8'h55: tag_next = 7'd90;
                8'h56: tag_next = 7'd123;
                8'h57: tag_next = 7'd64;
                default: tag_next = TAG_DEAD;
            endcase
            7'd53: case (c)
                8'h45: tag_next = 7'd32;
                8'h4F: tag_next = 7'd54;
                default: tag_next = TAG_DEAD;
            endcase
            7'd54: case (c)
                8'h50: tag_next = 7'd1;
                default: tag_next = TAG_DEAD;
            endcase
            7'd55: case (c)
                8'h41: tag_next = 7'd107;
                8'h45: tag_next = 7'd56;
                default: tag_next = TAG_DEAD;
            endcase
            7'd56: case (c)
                8'h54: tag_next = 7'd2;
                default: tag_next = TAG_DEAD;
            endcase
            7'd2: case (c)
                8'h4D: tag_next = 7'd70;
                default: tag_next = TAG_DEAD;
            endcase
            7'd57: case (c)
                8'h45: tag_next = 7'd35;
                8'h50: tag_next = 7'd113;
                8'h54: tag_next = 7'd34;
                default: tag_next = TAG_DEAD;
            endcase
            7'd35: case (c)
                8'h54: tag_next = 7'd3;
                default: tag_next = TAG_DEAD;
            endcase
            7'd3: case (c)
                8'h4D: tag_next = 7'd67;
                default: tag_next = TAG_DEAD;
            endcase
            7'd58: case (c)
                8'h41: tag_next = 7'd99;
                8'h45: tag_next = 7'd59;
                default: tag_next = TAG_DEAD;
            endcase
            7'd59: case (c)
                8'h46: tag_next = 7'd19;
                8'h4C: tag_next = 7'd60;
                default: tag_next = TAG_DEAD;
            endcase
            7'd60: case (c)
                8'h41: tag_next = 7'd61;
                default: tag_next = TAG_DEAD;
            endcase
            7'd61: case (c)
                8'h59: tag_next = 7'd4;
                default: tag_next = TAG_DEAD;
            endcase
            7'd62: case (c)
                8'h57: tag_next = 7'd63;
                default: tag_next = TAG_DEAD;
            endcase
            7'd63: case (c)
                8'h4D: tag_next = 7'd5;
                default: tag_next = TAG_DEAD;
            endcase
            7'd64: case (c)
                8'h49: tag_next = 7'd102;
                8'h53: tag_next = 7'd6;
                default: tag_next = TAG_DEAD;
            endcase
            7'd6: case (c)
                8'h32: tag_next = 7'd120;
                default: tag_next = TAG_DEAD;
            endcase
            7'd65: case (c)
                8'h32: tag_next = 7'd66;
                8'h46: tag_next = 7'd81;
                8'h4E: tag_next = 7'd105;
                default: tag_next = TAG_DEAD;
            endcase
            7'd66: case (c)
                8'h43: tag_next = 7'd29;
                default: tag_next = TAG_DEAD;
            endcase
            7'd29: case (c)
                8'h52: tag_next = 7'd8;
                8'h57: tag_next = 7'd7;
                8'h5F: tag_next = 7'd95;
                default: tag_next = TAG_DEAD;
            endcase
            7'd67: case (c)
                8'h41: tag_next = 7'd68;
                default: tag_next = TAG_DEAD;
            endcase
            7'd68: case (c)
                8'h49: tag_next = 7'd69;
                default: tag_next = TAG_DEAD;
            endcase
            7'd69: case (c)
                8'h4C: tag_next = 7'd9;
                default: tag_next = TAG_DEAD;
            endcase
            7'd70: case (c)
                8'h41: tag_next = 7'd71;
                default: tag_next = TAG_DEAD;
            endcase
            7'd71: case (c)
                8'h49: tag_next = 7'd72;
                default: tag_next = TAG_DEAD;
            endcase
            7'd72: case (c)
                8'h4C: tag_next = 7'd10;
                default: tag_next = TAG_DEAD;
            endcase
            7'd73: case (c)
                8'h45: tag_next = 7'd36;
                8'h4F: tag_next = 7'd74;
                8'h54: tag_next = 7'd33;
                default: tag_next = TAG_DEAD;
            endcase
            7'd74: case (c)
                8'h4F: tag_next = 7'd75;
                default: tag_next = TAG_DEAD;
            endcase
            7'd75: case (c)
                8'h50: tag_next = 7'd11;
                default: tag_next = TAG_DEAD;
            endcase
            7'd76: case (c)
                8'h4E: tag_next = 7'd77;
                8'h51: tag_next = 7'd31;
                8'h58: tag_next = 7'd125;
                default: tag_next = TAG_DEAD;
            endcase
            7'd77: case (c)
                8'h44: tag_next = 7'd14;
                default: tag_next = TAG_DEAD;
            endcase
            7'd14: case (c)
                8'h4C: tag_next = 7'd78;
                default: tag_next = TAG_DEAD;
            endcase
            7'd78: case (c)
                8'h4F: tag_next = 7'd79;
                default: tag_next = TAG_DEAD;
            endcase
            7'd79: case (c)
                8'h4F: tag_next = 7'd80;
                default: tag_next = TAG_DEAD;
            endcase
            7'd80: case (c)
                8'h50: tag_next = 7'd12;
                default: tag_next = TAG_DEAD;
            endcase
            7'd81: case (c)
                8'h4D: tag_next = 7'd82;
                default: tag_next = TAG_DEAD;
            endcase
            7'd82: case (c)
                8'h41: tag_next = 7'd83;
                default: tag_next = TAG_DEAD;
            endcase
            7'd83: case (c)
                8'h49: tag_next = 7'd84;
                default: tag_next = TAG_DEAD;
            endcase
            7'd84: case (c)
                8'h4C: tag_next = 7'd13;
                default: tag_next = TAG_DEAD;
            endcase
            7'd85: case (c)
                8'h41: tag_next = 7'd86;
                default: tag_next = TAG_DEAD;
            endcase
            7'd86: case (c)
                8'h52: tag_next = 7'd87;
                default: tag_next = TAG_DEAD;
            endcase
            7'd87: case (c)
                8'h47: tag_next = 7'd88;
                default: tag_next = TAG_DEAD;
            endcase
            7'd88: case (c)
                8'h45: tag_next = 7'd89;
                default: tag_next = TAG_DEAD;
            endcase
            7'd89: case (c)
                8'h54: tag_next = 7'd15;
                default: tag_next = TAG_DEAD;
            endcase
            7'd90: case (c)
                8'h53: tag_next = 7'd91;
                default: tag_next = TAG_DEAD;
            endcase
            7'd91: case (c)
                8'h45: tag_next = 7'd92;
                default: tag_next = TAG_DEAD;
            endcase
            7'd92: case (c)
                8'h53: tag_next = 7'd16;
                default: tag_next = TAG_DEAD;
            endcase
            7'd93: case (c)
                8'h30: tag_next = 7'd45;
                8'h31: tag_next = 7'd46;
                8'h32: tag_next = 7'd47;
                8'h33: tag_next = 7'd48;
                8'h34: tag_next = 7'd49;
                8'h35: tag_next = 7'd50;
                8'h36: tag_next = 7'd51;
                8'h37: tag_next = 7'd52;
                8'h45: tag_next = 7'd94;
                default: tag_next = TAG_DEAD;
            endcase
            7'd94: case (c)
                8'h47: tag_next = 7'd17;
                default: tag_next = TAG_DEAD;
            endcase
            7'd95: case (c)
                8'h41: tag_next = 7'd96;
                default: tag_next = TAG_DEAD;
            endcase
            7'd96: case (c)
                8'h44: tag_next = 7'd97;
                default: tag_next = TAG_DEAD;
            endcase
            7'd97: case (c)
                8'h44: tag_next = 7'd98;
                default: tag_next = TAG_DEAD;
            endcase
            7'd98: case (c)
                8'h52: tag_next = 7'd18;
                default: tag_next = TAG_DEAD;
            endcase
            7'd99: case (c)
                8'h54: tag_next = 7'd100;
                default: tag_next = TAG_DEAD;
            endcase
            7'd100: case (c)
                8'h41: tag_next = 7'd20;
                default: tag_next = TAG_DEAD;
            endcase
            7'd101: case (c)
                8'h53: tag_next = 7'd21;
                default: tag_next = TAG_DEAD;
            endcase
            7'd102: case (c)
                8'h44: tag_next = 7'd103;
                default: tag_next = TAG_DEAD;
            endcase
            7'd103: case (c)
                8'h54: tag_next = 7'd104;
                default: tag_next = TAG_DEAD;
            endcase
            7'd104: case (c)
                8'h48: tag_next = 7'd22;
                default: tag_next = TAG_DEAD;
            endcase
            7'd105: case (c)
                8'h49: tag_next = 7'd106;
                default: tag_next = TAG_DEAD;
            endcase
            7'd106: case (c)
                8'h54: tag_next = 7'd23;
                default: tag_next = TAG_DEAD;
            endcase
            7'd107: case (c)
                8'h46: tag_next = 7'd108;
                default: tag_next = TAG_DEAD;
            endcase
            7'd108: case (c)
                8'h45: tag_next = 7'd24;
                default: tag_next = TAG_DEAD;
            endcase
            7'd109: case (c)
                8'h4F: tag_next = 7'd110;
                default: tag_next = TAG_DEAD;
            endcase
            7'd110: case (c)
                8'h55: tag_next = 7'd111;
                default: tag_next = TAG_DEAD;
            endcase
            7'd111: case (c)
                8'h4E: tag_next = 7'd112;
                default: tag_next = TAG_DEAD;
            endcase
            7'd112: case (c)
                8'h54: tag_next = 7'd25;
                default: tag_next = TAG_DEAD;
            endcase
            7'd113: case (c)
                8'h49: tag_next = 7'd114;
                default: tag_next = TAG_DEAD;
            endcase
            7'd114: case (c)
                8'h4F: tag_next = 7'd115;
                default: tag_next = TAG_DEAD;
            endcase
            7'd115: case (c)
                8'h5F: tag_next = 7'd116;
                default: tag_next = TAG_DEAD;
            endcase
            7'd116: case (c)
                8'h49: tag_next = 7'd117;
                8'h4F: tag_next = 7'd118;
                default: tag_next = TAG_DEAD;
            endcase
            7'd117: case (c)
                8'h4E: tag_next = 7'd26;
                default: tag_next = TAG_DEAD;
            endcase
            7'd118: case (c)
                8'h55: tag_next = 7'd119;
                default: tag_next = TAG_DEAD;
            endcase
            7'd119: case (c)
                8'h54: tag_next = 7'd27;
                default: tag_next = TAG_DEAD;
            endcase
            7'd120: case (c)
                8'h38: tag_next = 7'd121;
                default: tag_next = TAG_DEAD;
            endcase
            7'd121: case (c)
                8'h31: tag_next = 7'd122;
                default: tag_next = TAG_DEAD;
            endcase
            7'd122: case (c)
                8'h32: tag_next = 7'd28;
                default: tag_next = TAG_DEAD;
            endcase
            7'd123: case (c)
                8'h4F: tag_next = 7'd124;
                default: tag_next = TAG_DEAD;
            endcase
            7'd124: case (c)
                8'h4C: tag_next = 7'd30;
                default: tag_next = TAG_DEAD;
            endcase
            7'd125: case (c)
                8'h50: tag_next = 7'd126;
                default: tag_next = TAG_DEAD;
            endcase
            7'd126: case (c)
                8'h31: tag_next = 7'd37;
                8'h32: tag_next = 7'd38;
                8'h33: tag_next = 7'd39;
                8'h34: tag_next = 7'd40;
                8'h35: tag_next = 7'd41;
                8'h36: tag_next = 7'd42;
                8'h37: tag_next = 7'd43;
                8'h38: tag_next = 7'd44;
                default: tag_next = TAG_DEAD;
            endcase
            default: tag_next = TAG_DEAD;
            endcase
        end
    endfunction

    function [5:0] tag_terminal;
        input [6:0] s; begin
            if (s>=7'd1 && s<=7'd52) tag_terminal=s[5:0];
            else tag_terminal=`EOS_T_NONE;
        end
    endfunction
    function [9:0] kw_from_tag;
        input [5:0] t; begin
            kw_from_tag = {`EOS_KW_UNKNOWN,8'h00};
            case (t)
            `EOS_T_NOP: kw_from_tag = {`EOS_KW_COMMAND, `EOS_OP_NOP};
            `EOS_T_SET: kw_from_tag = {`EOS_KW_COMMAND, `EOS_OP_SET};
            `EOS_T_GET: kw_from_tag = {`EOS_KW_COMMAND, `EOS_OP_GET};
            `EOS_T_DELAY: kw_from_tag = {`EOS_KW_COMMAND, `EOS_OP_DELAY};
            `EOS_T_PWM: kw_from_tag = {`EOS_KW_COMMAND, `EOS_OP_PWM};
            `EOS_T_WS: kw_from_tag = {`EOS_KW_COMMAND, `EOS_OP_WS};
            `EOS_T_I2CW: kw_from_tag = {`EOS_KW_COMMAND, `EOS_OP_I2CW};
            `EOS_T_I2CR: kw_from_tag = {`EOS_KW_COMMAND, `EOS_OP_I2CR};
            `EOS_T_GETMAIL: kw_from_tag = {`EOS_KW_COMMAND, `EOS_OP_GETMAIL};
            `EOS_T_SETMAIL: kw_from_tag = {`EOS_KW_COMMAND, `EOS_OP_SETMAIL};
            `EOS_T_LOOP: kw_from_tag = {`EOS_KW_COMMAND, `EOS_OP_LOOP};
            `EOS_T_ENDLOOP: kw_from_tag = {`EOS_KW_COMMAND, `EOS_OP_ENDLOOP};
            `EOS_T_IFMAIL: kw_from_tag = {`EOS_KW_COMMAND, `EOS_OP_IFMAIL};
            `EOS_T_END: kw_from_tag = {`EOS_KW_COMMAND, `EOS_OP_END};
            `EOS_T_TARGET: kw_from_tag = {`EOS_KW_DIRECTIVE, `EOS_DIR_TARGET};
            `EOS_T_USES: kw_from_tag = {`EOS_KW_DIRECTIVE, `EOS_DIR_USES};
            `EOS_T_REG: kw_from_tag = {`EOS_KW_DIRECTIVE, `EOS_DIR_REG};
            `EOS_T_I2CADDR: kw_from_tag = {`EOS_KW_DIRECTIVE, `EOS_DIR_I2CADDR};
            `EOS_T_DEF: kw_from_tag = {`EOS_KW_DIRECTIVE, `EOS_DIR_DEF};
            `EOS_T_DATA: kw_from_tag = {`EOS_KW_DIRECTIVE, `EOS_DIR_DATA};
            default: ;
            endcase
        end
    endfunction

    wire [5:0] first_tag_now = (in_token && cur_tok_is_first)
                               ? tag_terminal(tag_state) : first_tag_saved;
    wire [9:0] cls_now = kw_from_tag(first_tag_now);

    // ---- FSM ----
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE; busy <= 1'b0; done <= 1'b0;
            scr_rd <= 1'b0; scr_raddr <= 21'd0;
            tok_stb <= 1'b0; line_stb <= 1'b0;
            instr_count <= 16'd0; line_count <= 16'd0;
            byte_idx <= 21'd0; line_no <= 16'd1; pending_hold<=1'b0; at_eof<=1'b0;
            in_comment <= 1'b0; in_token <= 1'b0; cur_tok_is_first <= 1'b0;
            tok_start <= 18'd0; tok_len_acc <= 16'd0; first_seen <= 1'b0;
            line_has_tok <= 1'b0; line_start_off <= 18'd0;
            first_tag_saved<=`EOS_T_NONE; tag_state<=TAG_DEAD; tok_tag<=`EOS_T_NONE;
            tok_count <= 16'd0; tcnt <= 16'd0;
            curword <= 128'd0; curcnt <= 5'd0; curnum <= 32'd0;
            curisnum <= 1'b0; curhex <= 1'b0; cursaw0 <= 1'b0;
        end else begin
            // default single-cycle strobes
            scr_rd   <= 1'b0;
            tok_stb  <= 1'b0;
            line_stb <= 1'b0;
            done     <= 1'b0;

            if (start) begin        // top-level: begin OR seek-restart from any state
                byte_idx <= start_off; line_no <= 16'd1;
                instr_count <= start_ord; line_count <= 16'd0;
                in_comment <= 1'b0; in_token <= 1'b0; cur_tok_is_first <= 1'b0;
                first_seen <= 1'b0; line_has_tok <= 1'b0;
                first_tag_saved<=`EOS_T_NONE; tag_state<=TAG_DEAD; tok_tag<=`EOS_T_NONE;
                tcnt <= 16'd0; tok_count <= 16'd0; line_start_off <= start_off;
                curword <= 128'd0; curcnt <= 5'd0; curnum <= 32'd0;
                curisnum <= 1'b0; curhex <= 1'b0; cursaw0 <= 1'b0;
                pending_hold <= 1'b0; at_eof <= 1'b0;
                busy <= 1'b1;
                state <= S_REQ;
            end else
            case (state)
            // -----------------------------------------------------------
            S_IDLE: ;   // idle; a start pulse (handled above) begins/seeks
            // -----------------------------------------------------------
            S_REQ: begin
                if (pending_hold) begin pending_hold <= 1'b0; state <= S_HELD; end
                else if (byte_idx >= text_len) begin state <= S_EOF; end
                else if (!scr_busy) begin
                    scr_rd    <= 1'b1;
                    scr_raddr <= text_base + byte_idx;
                    state     <= S_RCV;
                end
            end
            S_HELD: if (lx_ack) state <= (at_eof ? S_DONE : S_REQ);
            // -----------------------------------------------------------
            S_RCV: begin
                if (scr_rvalid) begin
                    cur_byte <= scr_rdata;
                    state    <= S_PROC;
                end
            end
            // -----------------------------------------------------------
            S_PROC: begin
                if (in_comment) begin
                    if (is_lf) begin
                        // finalize the (already-tokenized) line
                        if (line_has_tok) begin
                            kw_class      <= cls_now[9:8];
                            kw_code       <= cls_now[7:0];
                            line_off      <= line_start_off;
                            tok_count <= tcnt + (in_token ? 16'd1 : 16'd0);
                            line_stb      <= 1'b1; pending_hold <= 1'b1;
                            line_count    <= line_count + 16'd1;
                            if (cls_now[9:8] != `EOS_KW_DIRECTIVE) begin
                                instr_ordinal <= instr_count;
                                instr_count   <= instr_count + 16'd1;
                            end
                        end
                        // reset line
                        in_comment <= 1'b0; in_token <= 1'b0;
                        first_seen <= 1'b0; line_has_tok <= 1'b0;
                        cur_tok_is_first <= 1'b0;
                        first_tag_saved<=`EOS_T_NONE; tag_state<=TAG_DEAD;
                        tcnt <= 16'd0;
                        line_no <= line_no + 16'd1;
                    end
                end else begin
                    if (is_hash) begin
                        if (in_token) begin
                            tok_stb <= 1'b1; tok_off <= tok_start;
                            tok_len <= tok_len_acc; tok_is_first <= cur_tok_is_first;
                            tok_word <= curword; tok_tag<=tag_terminal(tag_state); tok_num <= curnum; tok_isnum <= curisnum;
                            tcnt <= tcnt + 16'd1;
                            if (cur_tok_is_first) first_tag_saved<=tag_terminal(tag_state);
                            in_token <= 1'b0;
                        end
                        in_comment <= 1'b1;
                    end else if (is_lf) begin
                        if (in_token) begin
                            tok_stb <= 1'b1; tok_off <= tok_start;
                            tok_len <= tok_len_acc; tok_is_first <= cur_tok_is_first;
                            tok_word <= curword; tok_tag<=tag_terminal(tag_state); tok_num <= curnum; tok_isnum <= curisnum;
                            tcnt <= tcnt + 16'd1;
                            if (cur_tok_is_first) first_tag_saved<=tag_terminal(tag_state);
                            in_token <= 1'b0;
                        end
                        if (line_has_tok) begin
                            kw_class   <= cls_now[9:8];
                            kw_code    <= cls_now[7:0];
                            line_off   <= line_start_off;
                            tok_count <= tcnt + (in_token ? 16'd1 : 16'd0);
                            line_stb   <= 1'b1; pending_hold <= 1'b1;
                            line_count <= line_count + 16'd1;
                            if (cls_now[9:8] != `EOS_KW_DIRECTIVE) begin
                                instr_ordinal <= instr_count;
                                instr_count   <= instr_count + 16'd1;
                            end
                        end
                        // reset line
                        in_token <= 1'b0; first_seen <= 1'b0; line_has_tok <= 1'b0;
                        cur_tok_is_first <= 1'b0;
                        first_tag_saved<=`EOS_T_NONE; tag_state<=TAG_DEAD;
                        tcnt <= 16'd0;
                        line_no <= line_no + 16'd1;
                    end else if (is_ws) begin
                        if (in_token) begin
                            tok_stb <= 1'b1; tok_off <= tok_start;
                            tok_len <= tok_len_acc; tok_is_first <= cur_tok_is_first;
                            tok_word <= curword; tok_tag<=tag_terminal(tag_state); tok_num <= curnum; tok_isnum <= curisnum;
                            tcnt <= tcnt + 16'd1;
                            if (cur_tok_is_first) first_tag_saved<=tag_terminal(tag_state);
                            in_token <= 1'b0;
                        end
                    end else begin // is_tok
                        if (!in_token) begin
                            in_token         <= 1'b1;
                            tok_start        <= byte_idx;
                            tok_len_acc      <= 16'd1;
                            cur_tok_is_first <= ~first_seen;
                            curword          <= {120'd0, fold};
                            curcnt           <= 5'd1;
                            tag_state        <= tag_next(7'd0, fold);
                            curhex           <= 1'b0;
                            cursaw0          <= (cb == 8'h30);
                            if (is_digit) begin curisnum <= 1'b1; curnum <= {28'd0, dig}; end
                            else          begin curisnum <= 1'b0; curnum <= 32'd0;        end
                            if (!first_seen) begin
                                first_seen     <= 1'b1;
                                line_has_tok   <= 1'b1;
                                line_start_off <= byte_idx;
                            end
                        end else begin
                            tok_len_acc <= tok_len_acc + 16'd1;
                            tag_state <= tag_next(tag_state, fold);
                            if (curcnt < 5'd16) begin
                                curword <= {curword[119:0], fold};
                                curcnt  <= curcnt + 5'd1;
                            end
                            if (curisnum) begin
                                if (curhex) begin
                                    if (is_digit || is_hexU) curnum <= (curnum << 4) | {28'd0, hexv};
                                    else curisnum <= 1'b0;
                                end else if (curcnt == 5'd1 && cursaw0 && is_xchar) begin
                                    curhex <= 1'b1; curnum <= 32'd0;
                                end else if (is_digit) begin
                                    curnum <= (curnum << 3) + (curnum << 1) + {28'd0, dig};
                                end else curisnum <= 1'b0;
                            end
                        end
                    end
                end
                byte_idx <= byte_idx + 21'd1;
                state    <= S_REQ;
            end
            // -----------------------------------------------------------
            S_EOF: begin
                // flush a pending token / line with no trailing newline
                if (in_token) begin
                    tok_stb <= 1'b1; tok_off <= tok_start;
                    tok_len <= tok_len_acc; tok_is_first <= cur_tok_is_first;
                    tok_word <= curword; tok_tag<=tag_terminal(tag_state); tok_num <= curnum; tok_isnum <= curisnum;
                    if (cur_tok_is_first) first_tag_saved<=tag_terminal(tag_state);
                    tcnt <= tcnt + 16'd1;
                end
                if (line_has_tok) begin
                    kw_class   <= cls_now[9:8];
                    kw_code    <= cls_now[7:0];
                    line_off   <= line_start_off;
                    tok_count <= tcnt + (in_token ? 16'd1 : 16'd0);
                    line_stb   <= 1'b1; pending_hold <= 1'b1;
                    line_count <= line_count + 16'd1;
                    if (cls_now[9:8] != `EOS_KW_DIRECTIVE) begin
                        instr_ordinal <= instr_count;
                        instr_count   <= instr_count + 16'd1;
                    end
                    at_eof <= 1'b1;
                    state  <= S_REQ;   // -> S_HELD (via pending_hold) -> S_DONE after ack
                end else begin
                    state <= S_DONE;   // nothing to flush
                end
            end
            // -----------------------------------------------------------
            S_DONE: begin
                busy <= 1'b0;
                done <= 1'b1;
                state <= S_IDLE;
            end
            endcase
        end
    end
endmodule
// ---------------------------------------------------------------------------
//  eos_exp_framechk  —  script validity check (spec 4.4 / 5.5)  [M1a]
//
//  Validates a script staged in SDRAM scratch by DRIVING the top's single
//  shared eos_crc32 (CRC over scratch[0 .. text_len-1]) and comparing to the
//  host-computed CRC, plus the running-mode TARGET match and the TEXT_LEN
//  bound. Header fields (text_len / expected_crc / frame_target) come from the
//  loader's header parse, where MAGIC/FMT_VER are checked. Never instantiates a
//  second CRC; runs in clk_sd.
// ---------------------------------------------------------------------------
module eos_exp_framechk (
    input               clk,
    input               resetn,
    input               start,
    input  [20:0]       text_len,       // scratch[0 .. text_len-1] is the text
    input  [31:0]       expected_crc,   // host-computed CRC over the text
    input               frame_target,   // 0 = NOHD, 1 = HD
    input               sys_target,     // running console mode

    // drive the shared eos_crc32 (muxed in the top)
    output reg          crc_go,
    output reg  [20:0]  crc_len,
    input               crc_busy,
    input               crc_done,
    input  [31:0]       crc_result,

    output reg          done,
    output reg          valid,
    output reg  [2:0]   reason          // 0 OK / 1 TARGET / 2 LEN / 3 CRC
);
    localparam R_OK=3'd0, R_TARGET=3'd1, R_LEN=3'd2, R_CRC=3'd3;
    localparam S_IDLE=2'd0, S_GO=2'd1, S_WAIT=2'd2, S_DONE=2'd3;
    reg [1:0] state;

    wire target_ok = (frame_target == sys_target);
    wire len_ok    = (text_len != 21'd0) && (text_len <= `EOS_MAX_TEXT_LEN);

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            state<=S_IDLE; done<=1'b0; valid<=1'b0; reason<=R_OK;
            crc_go<=1'b0; crc_len<=21'd0;
        end else begin
            done<=1'b0; crc_go<=1'b0;
            case (state)
            S_IDLE: if (start) begin
                        valid<=1'b0; reason<=R_OK;
                        if (!target_ok)   begin reason<=R_TARGET; state<=S_DONE; end
                        else if (!len_ok) begin reason<=R_LEN;    state<=S_DONE; end
                        else begin crc_len<=text_len; crc_go<=1'b1; state<=S_GO; end
                    end
            S_GO:   state<=S_WAIT;                 // crc_go pulsed; crc asserts busy
            S_WAIT: if (crc_done) begin
                        if (crc_result==expected_crc) begin valid<=1'b1; reason<=R_OK; end
                        else begin valid<=1'b0; reason<=R_CRC; end
                        state<=S_DONE;
                    end
            S_DONE: begin done<=1'b1; state<=S_IDLE; end
            endcase
        end
    end
endmodule

// ---------------------------------------------------------------------------
//  eos_exp_layout  —  PASS 1: symbol tables + volatile layout + descriptor [M1]
//
//  Consumes the lexer's enriched (token,line) stream and builds the DEF/DATA
//  span tables and the exact capability descriptor (spec 5.4). Deterministic
//  bank layout: banks packed from volatile offset 0 in declaration order,
//  BANK_OFF=CMD_OFF, DOORBELL=+1, first REG_OFF=2, BANK_LEN=2+sum(widths),
//  REG_FLAGS fixed 0x03. Names/payloads kept as scratch spans (offset,len).
//  Runs in clk_sd; performs no scratch reads of its own.
// ---------------------------------------------------------------------------
// ---------------------------------------------------------------------------
//  eos_exp_sdp_ram  —  synchronous simple-dual-port storage helper
//
//  Kept deliberately inference-friendly for Gowin BSRAM: one clocked write port
//  and one registered read port, with no asynchronous read or memory reset.
// ---------------------------------------------------------------------------
module eos_exp_sdp_ram #(
    parameter integer WIDTH = 8,
    parameter integer ADDR_W = 6
)(
    input                       clk,
    input                       we,
    input      [ADDR_W-1:0]     waddr,
    input      [WIDTH-1:0]      wdata,
    input      [ADDR_W-1:0]     raddr,
    output     [WIDTH-1:0]      rdata
);
    // Use Gowin's native BSRAM primitives explicitly.  The prior inference
    // hint still left these shallow parser memories in SSRAM on GW2AR, where
    // every reported SSRAM costs six RP units.  SDP is an exact match for
    // this helper: one synchronous write port + one independent read port.
    generate
        if (WIDTH == 8) begin : G_BRAM8
            wire [10:0] wa_full = {{(11-ADDR_W){1'b0}},waddr};
            wire [10:0] ra_full = {{(11-ADDR_W){1'b0}},raddr};
            wire [31:0] q;
            SDP u_bram (
                .DO(q), .CLKA(clk), .CEA(1'b1), .RESETA(1'b0), .WREA(we),
                .CLKB(clk), .CEB(1'b1), .RESETB(1'b0), .WREB(1'b0),
                .OCE(1'b1), .BLKSEL(3'b000),
                .ADA({wa_full,3'b000}), .DI({24'd0,wdata}),
                .ADB({ra_full,3'b000})
            );
            defparam u_bram.READ_MODE   = 1'b0;
            defparam u_bram.BIT_WIDTH_0 = 8;
            defparam u_bram.BIT_WIDTH_1 = 8;
            defparam u_bram.BLK_SEL     = 3'b000;
            defparam u_bram.RESET_MODE  = "SYNC";
            assign rdata = q[7:0];
        end else if (WIDTH == 32) begin : G_BRAM32
            wire [8:0] wa_full = {{(9-ADDR_W){1'b0}},waddr};
            wire [8:0] ra_full = {{(9-ADDR_W){1'b0}},raddr};
            wire [31:0] q;
            SDP u_bram (
                .DO(q), .CLKA(clk), .CEA(1'b1), .RESETA(1'b0), .WREA(we),
                .CLKB(clk), .CEB(1'b1), .RESETB(1'b0), .WREB(1'b0),
                .OCE(1'b1), .BLKSEL(3'b000),
                // In 32-bit mode AD[3:0] are byte enables.  Write all bytes.
                .ADA({wa_full,1'b0,4'b1111}), .DI(wdata),
                .ADB({ra_full,5'b00000})
            );
            defparam u_bram.READ_MODE   = 1'b0;
            defparam u_bram.BIT_WIDTH_0 = 32;
            defparam u_bram.BIT_WIDTH_1 = 32;
            defparam u_bram.BLK_SEL     = 3'b000;
            defparam u_bram.RESET_MODE  = "SYNC";
            assign rdata = q;
        end else if (WIDTH == 36) begin : G_BRAM36
            wire [8:0] wa_full = {{(9-ADDR_W){1'b0}},waddr};
            wire [8:0] ra_full = {{(9-ADDR_W){1'b0}},raddr};
            wire [35:0] q;
            SDPX9 u_bram (
                .DO(q), .CLKA(clk), .CEA(1'b1), .RESETA(1'b0), .WREA(we),
                .CLKB(clk), .CEB(1'b1), .RESETB(1'b0), .WREB(1'b0),
                .OCE(1'b1), .BLKSEL(3'b000),
                .ADA({wa_full,1'b0,4'b1111}), .DI(wdata),
                .ADB({ra_full,5'b00000})
            );
            defparam u_bram.READ_MODE   = 1'b0;
            defparam u_bram.BIT_WIDTH_0 = 36;
            defparam u_bram.BIT_WIDTH_1 = 36;
            defparam u_bram.BLK_SEL     = 3'b000;
            defparam u_bram.RESET_MODE  = "SYNC";
            assign rdata = q;
        end else if (WIDTH == 128) begin : G_BRAM128
            // Four native 32-bit BSRAMs preserve the original 128-bit,
            // one-cycle operand-word interface without a wide LUT/SSRAM RAM.
            wire [8:0] wa_full = {{(9-ADDR_W){1'b0}},waddr};
            wire [8:0] ra_full = {{(9-ADDR_W){1'b0}},raddr};
            wire [31:0] q0,q1,q2,q3;
            SDP u_bram0 (.DO(q0),.CLKA(clk),.CEA(1'b1),.RESETA(1'b0),.WREA(we),.CLKB(clk),.CEB(1'b1),.RESETB(1'b0),.WREB(1'b0),.OCE(1'b1),.BLKSEL(3'b000),.ADA({wa_full,1'b0,4'b1111}),.DI(wdata[31:0]),  .ADB({ra_full,5'b00000}));
            SDP u_bram1 (.DO(q1),.CLKA(clk),.CEA(1'b1),.RESETA(1'b0),.WREA(we),.CLKB(clk),.CEB(1'b1),.RESETB(1'b0),.WREB(1'b0),.OCE(1'b1),.BLKSEL(3'b000),.ADA({wa_full,1'b0,4'b1111}),.DI(wdata[63:32]), .ADB({ra_full,5'b00000}));
            SDP u_bram2 (.DO(q2),.CLKA(clk),.CEA(1'b1),.RESETA(1'b0),.WREA(we),.CLKB(clk),.CEB(1'b1),.RESETB(1'b0),.WREB(1'b0),.OCE(1'b1),.BLKSEL(3'b000),.ADA({wa_full,1'b0,4'b1111}),.DI(wdata[95:64]), .ADB({ra_full,5'b00000}));
            SDP u_bram3 (.DO(q3),.CLKA(clk),.CEA(1'b1),.RESETA(1'b0),.WREA(we),.CLKB(clk),.CEB(1'b1),.RESETB(1'b0),.WREB(1'b0),.OCE(1'b1),.BLKSEL(3'b000),.ADA({wa_full,1'b0,4'b1111}),.DI(wdata[127:96]),.ADB({ra_full,5'b00000}));
            defparam u_bram0.READ_MODE=1'b0; defparam u_bram0.BIT_WIDTH_0=32; defparam u_bram0.BIT_WIDTH_1=32; defparam u_bram0.BLK_SEL=3'b000; defparam u_bram0.RESET_MODE="SYNC";
            defparam u_bram1.READ_MODE=1'b0; defparam u_bram1.BIT_WIDTH_0=32; defparam u_bram1.BIT_WIDTH_1=32; defparam u_bram1.BLK_SEL=3'b000; defparam u_bram1.RESET_MODE="SYNC";
            defparam u_bram2.READ_MODE=1'b0; defparam u_bram2.BIT_WIDTH_0=32; defparam u_bram2.BIT_WIDTH_1=32; defparam u_bram2.BLK_SEL=3'b000; defparam u_bram2.RESET_MODE="SYNC";
            defparam u_bram3.READ_MODE=1'b0; defparam u_bram3.BIT_WIDTH_0=32; defparam u_bram3.BIT_WIDTH_1=32; defparam u_bram3.BLK_SEL=3'b000; defparam u_bram3.RESET_MODE="SYNC";
            assign rdata = {q3,q2,q1,q0};
        end else begin : G_FALLBACK
            // Unused by EOS V1; retained so the helper remains generic.
            (* syn_ramstyle = "block_ram" *) reg [WIDTH-1:0] mem [0:(1<<ADDR_W)-1];
            reg [WIDTH-1:0] q;
            always @(posedge clk) begin
                if (we) mem[waddr] <= wdata;
                q <= mem[raddr];
            end
            assign rdata = q;
        end
    endgenerate
endmodule

module eos_exp_layout (
    input               clk,
    input               resetn,
    input               start,

    input               tok_stb,
    input  [20:0]       tok_off,
    input  [15:0]       tok_len,
    input               tok_is_first,
    input  [127:0]      tok_word,
    input  [5:0]        tok_tag,
    input  [31:0]       tok_num,
    input               tok_isnum,
    input               line_stb,
    input  [1:0]        kw_class,
    input  [7:0]        kw_code,
    input               lex_done,
    input               frame_target,
    input  [15:0]       instr_count,

    output reg          done,
    output reg          ok,
    output reg [2:0]    err,            // 0 OK/1 PINDEF/2 BANK/3 DEF/4 DATA/5 REG/6 TYPE
    output reg [3:0]    pindef_count,
    output reg [7:0]    volatile_used,

    // per-physical-pin maps (for eos_exp_pinmux / drivers, M4+)
    output [63:0]       pin_type_flat,   // {pin7..pin0} type, 0xFF = unclaimed
    output [63:0]       pin_init_flat,   // INIT value per pin (GPIO_OUT/PWM)
    output [63:0]       pin_safe_flat,   // SAFE value per pin
    input  [2:0]        cnt_sel,         // per-pin COUNT read (WS2812 length check)
    output [15:0]       cnt_val,
    output [2:0]        i2c_scl_pin,     // I2C bus pin assignment (one bus)
    output [2:0]        i2c_sda_pin,
    output              i2c_present,
    // DEF / DATA name-resolution read ports (exec scans by tok_word)
    input  [6:0]        def_ridx,
    output [127:0]      def_rword,
    output [31:0]       def_rval,
    output [6:0]        def_cnt,
    input  [5:0]        dat_ridx,
    output [127:0]      dat_rword,
    output [20:0]       dat_rdoff,
    output [31:0]       dat_rdlen,
    output [5:0]        dat_cnt,

    // Selected BANK_OFF is all the mailbox control path needs; the full
    // capability descriptor is served from the compact BSRAM below.
    input      [3:0]    q_sel,
    output reg [7:0]    q_bankoff, q_dboff,
    output     [63:0]   db_off_flat,

    // ABI v1 capability descriptor, built once during pass 1 and served from BSRAM.
    input      [9:0]    desc_raddr,
    output     [7:0]    desc_rdata,
    output reg [9:0]    desc_len
);
    assign pin_type_flat = pin_type_r;
    assign pin_init_flat = pin_init_r;
    assign pin_safe_flat = pin_safe_r;
    function [10:0] count_for_pin; input [2:0] idx; begin
        case (idx)
          3'd0: count_for_pin=pin_count_r[10:0];
          3'd1: count_for_pin=pin_count_r[21:11];
          3'd2: count_for_pin=pin_count_r[32:22];
          3'd3: count_for_pin=pin_count_r[43:33];
          3'd4: count_for_pin=pin_count_r[54:44];
          3'd5: count_for_pin=pin_count_r[65:55];
          3'd6: count_for_pin=pin_count_r[76:66];
          default: count_for_pin=pin_count_r[87:77];
        endcase
    end endfunction
    assign cnt_val = {5'd0,count_for_pin(cnt_sel)};
    assign i2c_scl_pin = i2c_scl_r; assign i2c_sda_pin = i2c_sda_r; assign i2c_present = i2c_pres_r;
    assign def_cnt = def_count;
    assign dat_cnt = dat_count;
    // Compact retained pin metadata.  The editor declaration grammar is
    // sequential (USES followed by its REG lines), so BANK_LEN/REG_COUNT and
    // descriptor base only need scalar state for the current pin-def.
    reg [63:0] pin_type_r, pin_init_r, pin_safe_r;
    reg [87:0] pin_count_r;
    reg [2:0]  cur_p0, cur_p1; reg [3:0] cur_np;   // ordered EXP pins + count this line
    reg [2:0]  i2c_scl_r, i2c_sda_r; reg i2c_pres_r;
    reg [63:0] db_off_r;
    reg [7:0]  cur_banklen, cur_regcnt;
    reg [9:0]  cur_descbase;

    // Descriptor writer. The editor/ABI expects one global stream:
    // [ABI_VER,PINDEF_COUNT], then each 8-byte pin-def record followed by
    // that pin-def's 4-byte REG records.  Build it incrementally while the
    // lexer is already spending many clocks on each text line.
    reg        desc_we;
    reg [9:0]  desc_waddr, desc_cursor;
    reg [7:0]  desc_wdata;
    reg [3:0]  dj_kind;       // 0 idle, 1 header, 2 USES record, 3 REG patch+record
    reg [3:0]  dj_step;
    reg [3:0]  dj_pd;
    reg [7:0]  dj_type, dj_phys, dj_bankoff, dj_banklen, dj_regcnt, dj_regoff, dj_regwidth;
    reg [9:0]  dj_base, dj_regbase;
    eos_exp_sdp_ram #(.WIDTH(8),.ADDR_W(10)) u_desc_ram (
        .clk(clk),.we(desc_we),.waddr(desc_waddr),.wdata(desc_wdata),
        .raddr(desc_raddr),.rdata(desc_rdata));

    // ABI v1 fixes DOORBELL_OFF = BANK_OFF + 1, so retaining both arrays is
    // redundant.  Keep only the eight doorbell offsets and derive BANK_OFF.
    wire [7:0] q_db_sel = db_off_r[{q_sel[2:0],3'b000} +: 8];
    always @(posedge clk) begin q_dboff <= q_db_sel; q_bankoff <= q_db_sel - 8'd1; end
    assign db_off_flat = db_off_r;

    reg [6:0] def_count; reg [5:0] dat_count; reg [7:0] reg_total;

    reg [3:0] pdi;              // pin-defs created
    reg [8:0] vol_top;          // running volatile bytes used (detect >248 without wrap)
    reg       busy;

    // per-line parse
    reg [2:0] dmode;            // 0 other/1 uses/2 reg/3 def/4 data/5 target
    reg       expect_type, expect_width, expect_init, expect_safe, expect_count;
    reg       seen_init, seen_safe, seen_count, width_seen, def_val_seen;
    reg       line_bad, name_bad, data_bad;
    reg [7:0] cur_type, cur_phys, cur_width, cur_init, cur_safe;
    reg [15:0] cur_count;
    reg [31:0] n2_val; reg [127:0] n1_word;
    reg [20:0] d_off;  reg [14:0] d_bytes; reg d_ovf; reg d_started; reg [15:0] opn;
    reg        line_pend, finishing; reg [7:0] kwc_r; reg [1:0] kcl_r;
    reg        target_seen, text_target, target_bad;
    reg [7:0]  used_pins;
    reg [3:0]  used_count;
    reg [14:0] payload_total;

    // REG metadata is emitted directly into the capability descriptor BSRAM;
    // no second register-record RAM is required.

    // DEF / DATA lookup records. Keep every inferred BSRAM port at a native
    // Gowin-friendly width (<=36 bits). Very-wide shallow inferred memories
    // tend to spill into SSRAM on GW2AR even with a block_ram hint.
    // DEF = 128-bit exact name + 32-bit value, split across five 32-bit banks.
    // DATA = 128-bit exact name + {text_off[20:0],byte_len[14:0]} (36-bit meta).
    wire [31:0] def_w3, def_w2, def_w1, def_w0, def_v;
    wire [31:0] dat_w3, dat_w2, dat_w1, dat_w0;
    wire [35:0] dat_meta;
    wire         def_commit = busy && line_pend && (kcl_r==2'd1) && (kwc_r==8'h05) && (def_count<7'd64);
    wire         dat_commit = busy && line_pend && (kcl_r==2'd1) && (kwc_r==8'h06) && (dat_count<6'd32);

    eos_exp_sdp_ram #(.WIDTH(32),.ADDR_W(6)) u_def_n3(.clk(clk),.we(def_commit),.waddr(def_count[5:0]),.wdata(n1_word[127:96]),.raddr(def_ridx[5:0]),.rdata(def_w3));
    eos_exp_sdp_ram #(.WIDTH(32),.ADDR_W(6)) u_def_n2(.clk(clk),.we(def_commit),.waddr(def_count[5:0]),.wdata(n1_word[95:64]), .raddr(def_ridx[5:0]),.rdata(def_w2));
    eos_exp_sdp_ram #(.WIDTH(32),.ADDR_W(6)) u_def_n1(.clk(clk),.we(def_commit),.waddr(def_count[5:0]),.wdata(n1_word[63:32]), .raddr(def_ridx[5:0]),.rdata(def_w1));
    eos_exp_sdp_ram #(.WIDTH(32),.ADDR_W(6)) u_def_n0(.clk(clk),.we(def_commit),.waddr(def_count[5:0]),.wdata(n1_word[31:0]),  .raddr(def_ridx[5:0]),.rdata(def_w0));
    eos_exp_sdp_ram #(.WIDTH(32),.ADDR_W(6)) u_def_val(.clk(clk),.we(def_commit),.waddr(def_count[5:0]),.wdata(n2_val),         .raddr(def_ridx[5:0]),.rdata(def_v));

    eos_exp_sdp_ram #(.WIDTH(32),.ADDR_W(5)) u_dat_n3(.clk(clk),.we(dat_commit),.waddr(dat_count[4:0]),.wdata(n1_word[127:96]),.raddr(dat_ridx[4:0]),.rdata(dat_w3));
    eos_exp_sdp_ram #(.WIDTH(32),.ADDR_W(5)) u_dat_n2(.clk(clk),.we(dat_commit),.waddr(dat_count[4:0]),.wdata(n1_word[95:64]), .raddr(dat_ridx[4:0]),.rdata(dat_w2));
    eos_exp_sdp_ram #(.WIDTH(32),.ADDR_W(5)) u_dat_n1(.clk(clk),.we(dat_commit),.waddr(dat_count[4:0]),.wdata(n1_word[63:32]), .raddr(dat_ridx[4:0]),.rdata(dat_w1));
    eos_exp_sdp_ram #(.WIDTH(32),.ADDR_W(5)) u_dat_n0(.clk(clk),.we(dat_commit),.waddr(dat_count[4:0]),.wdata(n1_word[31:0]),  .raddr(dat_ridx[4:0]),.rdata(dat_w0));
    eos_exp_sdp_ram #(.WIDTH(36),.ADDR_W(5)) u_dat_meta(.clk(clk),.we(dat_commit),.waddr(dat_count[4:0]),.wdata({d_off,d_bytes}),.raddr(dat_ridx[4:0]),.rdata(dat_meta));

    assign def_rword = {def_w3,def_w2,def_w1,def_w0};
    assign def_rval  = def_v;
    assign dat_rword = {dat_w3,dat_w2,dat_w1,dat_w0};
    assign dat_rdoff = dat_meta[35:15];
    assign dat_rdlen = {17'd0,dat_meta[14:0]};

    wire is_exp = (tok_tag>=`EOS_T_EXP1) && (tok_tag<=`EOS_T_EXP8);
    wire [2:0] exp_bit = tok_tag - `EOS_T_EXP1;
    wire [8:0] reg_new_len = {1'b0,cur_banklen} + {1'b0,cur_width};
    wire [7:0] reg_new_cnt = cur_regcnt + 8'd1;
    wire [15:0] payload_new = {1'b0,payload_total} + {1'b0,d_bytes};
    wire [15:0] data_byte_new = {1'b0,d_bytes} + {1'b0,tok_len[15:1]};

    function [7:0] type_code_tag; input [5:0] t; begin
        case (t)
            `EOS_T_GPIO_IN:  type_code_tag=`EOS_TYPE_GPIO_IN;
            `EOS_T_GPIO_OUT: type_code_tag=`EOS_TYPE_GPIO_OUT;
            `EOS_T_PWM:      type_code_tag=`EOS_TYPE_PWM;
            `EOS_T_WS2812:   type_code_tag=`EOS_TYPE_WS2812;
            `EOS_T_I2C:      type_code_tag=`EOS_TYPE_I2C;
            default:         type_code_tag=8'hFF;
        endcase
    end endfunction

    integer k;
    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            done<=1'b0; ok<=1'b0; err<=3'd0; busy<=1'b0;
            pindef_count<=4'd0; volatile_used<=8'd0;
            pdi<=4'd0; vol_top<=9'd0; cur_banklen<=8'd0; cur_regcnt<=8'd0; cur_descbase<=10'd0;
            def_count<=7'd0; dat_count<=6'd0; reg_total<=8'd0; dmode<=3'd0;
            line_pend<=1'b0; finishing<=1'b0; d_ovf<=1'b0;
            target_seen<=1'b0; text_target<=1'b0; target_bad<=1'b0;
            used_pins<=8'd0; used_count<=4'd0; payload_total<=15'd0;
            desc_we<=1'b0; desc_waddr<=10'd0; desc_wdata<=8'd0; desc_cursor<=10'd2; desc_len<=10'd2;
            dj_kind<=4'd0; dj_step<=4'd0; dj_pd<=4'd0; dj_base<=10'd0; dj_regbase<=10'd0;
            pin_type_r<={8{8'hFF}}; pin_init_r<=64'd0; pin_safe_r<=64'd0; pin_count_r<=88'd0; db_off_r<=64'd0;
            i2c_pres_r<=1'b0; i2c_scl_r<=3'd0; i2c_sda_r<=3'd0;
        end else begin
            done<=1'b0;
            desc_we<=1'b0;

            // Background capability-descriptor byte writer.  Jobs are shorter
            // than the shortest legal declaration line, so the single-byte
            // BSRAM port is free before the next declaration commit.
            if (dj_kind!=4'd0) begin
                desc_we<=1'b1;
                case (dj_kind)
                4'd1: begin // header ABI_VER then provisional PINDEF_COUNT=0
                    desc_waddr<=dj_step[0] ? 10'd1 : 10'd0;
                    desc_wdata<=dj_step[0] ? 8'd0 : 8'd1;
                    if (dj_step==4'd1) begin dj_kind<=4'd0; dj_step<=4'd0; end
                    else dj_step<=dj_step+4'd1;
                end
                4'd2: begin // 8-byte pin-def record
                    desc_waddr<=dj_base+dj_step;
                    case (dj_step)
                      4'd0: desc_wdata<={4'd0,dj_pd};
                      4'd1: desc_wdata<=dj_type;
                      4'd2: desc_wdata<=dj_phys;
                      4'd3: desc_wdata<=dj_bankoff;
                      4'd4: desc_wdata<=dj_bankoff+8'd1;
                      4'd5: desc_wdata<=dj_bankoff;
                      4'd6: desc_wdata<=dj_banklen;
                      default: desc_wdata<=dj_regcnt;
                    endcase
                    if (dj_step==4'd7) begin dj_kind<=4'd0; dj_step<=4'd0; end
                    else dj_step<=dj_step+4'd1;
                end
                4'd3: begin // patch BANK_LEN/REG_COUNT, append one REG record
                    case (dj_step)
                      4'd0: begin desc_waddr<=dj_base+10'd6; desc_wdata<=dj_banklen; end
                      4'd1: begin desc_waddr<=dj_base+10'd7; desc_wdata<=dj_regcnt; end
                      4'd2: begin desc_waddr<=dj_regbase;     desc_wdata<=dj_regcnt-8'd1; end
                      4'd3: begin desc_waddr<=dj_regbase+10'd1; desc_wdata<=dj_regoff; end
                      4'd4: begin desc_waddr<=dj_regbase+10'd2; desc_wdata<=dj_regwidth; end
                      default: begin desc_waddr<=dj_regbase+10'd3; desc_wdata<=8'h03; end
                    endcase
                    if (dj_step==4'd5) begin dj_kind<=4'd0; dj_step<=4'd0; end
                    else dj_step<=dj_step+4'd1;
                end
                4'd4: begin // final header PINDEF_COUNT
                    desc_waddr<=10'd1; desc_wdata<={4'd0,pdi}; dj_kind<=4'd0; dj_step<=4'd0;
                end
                default: begin dj_kind<=4'd0; dj_step<=4'd0; desc_we<=1'b0; end
                endcase
            end

            if (start) begin
                busy<=1'b1; ok<=1'b0; err<=3'd0;
                pdi<=4'd0; vol_top<=9'd0; cur_banklen<=8'd0; cur_regcnt<=8'd0; cur_descbase<=10'd0;
                def_count<=7'd0; dat_count<=6'd0; reg_total<=8'd0; dmode<=3'd0;
                line_pend<=1'b0; finishing<=1'b0;
                target_seen<=1'b0; text_target<=1'b0; target_bad<=1'b0;
                used_pins<=8'd0; used_count<=4'd0; payload_total<=15'd0;
                desc_cursor<=10'd2; desc_len<=10'd2; dj_kind<=4'd1; dj_step<=4'd0;
                pin_type_r<={8{8'hFF}}; pin_init_r<=64'd0; pin_safe_r<=64'd0; pin_count_r<=88'd0; db_off_r<=64'd0;
                i2c_pres_r<=1'b0; i2c_scl_r<=3'd0; i2c_sda_r<=3'd0;
            end else if (busy) begin
                // ---------------- tokens ----------------
                if (tok_stb) begin
                    if (tok_is_first) begin
                        opn<=16'd0; expect_type<=1'b0; expect_width<=1'b0;
                        expect_init<=1'b0; expect_safe<=1'b0; expect_count<=1'b0;
                        seen_init<=1'b0; seen_safe<=1'b0; seen_count<=1'b0;
                        width_seen<=1'b0; def_val_seen<=1'b0; line_bad<=1'b0; name_bad<=1'b0; data_bad<=1'b0;
                        cur_init<=8'd0; cur_safe<=8'd0; cur_count<=16'd0; cur_width<=8'd0;
                        cur_np<=4'd0; cur_p0<=3'd0; cur_p1<=3'd0;
                        cur_phys<=8'd0; cur_type<=8'hFF; d_started<=1'b0; d_bytes<=15'd0; d_ovf<=1'b0;
                        case (tok_tag)
                            `EOS_T_USES:  dmode<=3'd1;
                            `EOS_T_REG:   dmode<=3'd2;
                            `EOS_T_DEF:   dmode<=3'd3;
                            `EOS_T_DATA:  dmode<=3'd4;
                            `EOS_T_TARGET:begin if (target_seen) target_bad<=1'b1; dmode<=3'd5; end
                            default:      dmode<=3'd0;
                        endcase
                    end else begin
                        opn <= opn + 16'd1;
                        // name = first operand for REG/DEF/DATA
                        if (opn==16'd0 && (dmode==3'd2 || dmode==3'd3 || dmode==3'd4)) begin
                            n1_word<=tok_word;
                            if (tok_len==16'd0 || tok_len>16'd16) name_bad<=1'b1;
                        end
                        case (dmode)
                        3'd1: begin // USES
                            if (expect_type) begin
                                cur_type<=type_code_tag(tok_tag); expect_type<=1'b0;
                                if (type_code_tag(tok_tag)==8'hFF) line_bad<=1'b1;
                            end else if (expect_init) begin
                                expect_init<=1'b0; seen_init<=1'b1;
                                if (!tok_isnum || |tok_num[31:8]) line_bad<=1'b1;
                                else cur_init<=tok_num[7:0];
                            end else if (expect_safe) begin
                                expect_safe<=1'b0; seen_safe<=1'b1;
                                if (!tok_isnum || |tok_num[31:8]) line_bad<=1'b1;
                                else cur_safe<=tok_num[7:0];
                            end else if (expect_count) begin
                                expect_count<=1'b0; seen_count<=1'b1;
                                if (!tok_isnum || |tok_num[31:16]) line_bad<=1'b1;
                                else cur_count<=tok_num[15:0];
                            end else if (is_exp) begin
                                cur_phys <= cur_phys | (8'd1<<exp_bit);
                                if (cur_np==4'd0) cur_p0<=exp_bit;
                                else if (cur_np==4'd1) cur_p1<=exp_bit;
                                cur_np <= cur_np + 4'd1;
                            end else if (tok_tag==`EOS_T_AS)       expect_type<=1'b1;
                            else if (tok_tag==`EOS_T_INIT)         expect_init<=1'b1;
                            else if (tok_tag==`EOS_T_SAFE)         expect_safe<=1'b1;
                            else if (tok_tag==`EOS_T_COUNT)        expect_count<=1'b1;
                            else line_bad<=1'b1;
                        end
                        3'd2: begin // REG name WIDTH n
                            if (opn==16'd1 && tok_tag==`EOS_T_WIDTH) expect_width<=1'b1;
                            else if (expect_width) begin
                                expect_width<=1'b0; width_seen<=1'b1;
                                if (!tok_isnum || tok_num==32'd0 || |tok_num[31:8]) line_bad<=1'b1;
                                else cur_width<=tok_num[7:0];
                            end else if (opn!=16'd0) line_bad<=1'b1;
                        end
                        3'd3: begin // DEF name value
                            if (opn==16'd1) begin
                                def_val_seen<=tok_isnum;
                                if (tok_isnum) n2_val<=tok_num; else line_bad<=1'b1;
                            end else if (opn>16'd1) line_bad<=1'b1;
                        end
                        3'd4: begin // DATA name hex...
                            if (opn>=16'd1) begin
                                if (!d_started) begin d_off<=tok_off; d_started<=1'b1; end
                                if (tok_len[0]) data_bad<=1'b1;
                                if (data_byte_new[15]) begin d_bytes<=15'h7FFF; d_ovf<=1'b1; end
                                else d_bytes <= data_byte_new[14:0];
                            end
                        end
                        3'd5: begin // TARGET HD|NOHD
                            if (opn==16'd0) begin
                                target_seen<=1'b1;
                                if (tok_len==16'd2 && tok_word[15:0]==16'h4844) text_target<=1'b1;       // HD
                                else if (tok_len==16'd4 && tok_word[31:0]==32'h4E4F4844) text_target<=1'b0; // NOHD
                                else target_bad<=1'b1;
                            end else target_bad<=1'b1;
                        end
                        default: ;
                        endcase
                    end
                end
                // ------- line capture: defer commit one cycle so a line-final
                //         token's cur_* (type / width) is latched first -------
                if (line_stb) begin line_pend<=1'b1; kwc_r<=kw_code; kcl_r<=kw_class; end
                if (line_pend) begin
                    line_pend<=1'b0;
                    if (kcl_r==2'd1) begin
                        case (kwc_r)
                        8'h02: begin // USES
                            if (pdi>=4'd8 || line_bad || cur_type==8'hFF ||
                                (cur_type==`EOS_TYPE_I2C ? (cur_np!=4'd2) : (cur_np!=4'd1)) ||
                                ((used_pins & cur_phys)!=8'd0) ||
                                (cur_type==`EOS_TYPE_I2C && i2c_pres_r) ||
                                ((cur_type==`EOS_TYPE_GPIO_OUT || cur_type==`EOS_TYPE_PWM) && (!seen_init || !seen_safe)) ||
                                (cur_type==`EOS_TYPE_GPIO_OUT && (cur_init>8'd1 || cur_safe>8'd1)) ||
                                (cur_type==`EOS_TYPE_WS2812 && (!seen_count || cur_count<16'd1 || cur_count>16'd1365))) begin
                                ok<=1'b0; err<=3'd1;
                            end else begin
                                db_off_r[{pdi[2:0],3'b000} +: 8] <= vol_top[7:0] + 8'd1;
                                cur_banklen<=8'd2; cur_regcnt<=8'd0; cur_descbase<=desc_cursor;
                                dj_kind<=4'd2; dj_step<=4'd0; dj_pd<=pdi; dj_base<=desc_cursor;
                                dj_type<=cur_type; dj_phys<=cur_phys; dj_bankoff<=vol_top[7:0];
                                dj_banklen<=8'd2; dj_regcnt<=8'd0;
                                desc_cursor<=desc_cursor+10'd8; desc_len<=desc_cursor+10'd8;
                                for (k=0;k<8;k=k+1) if (cur_phys[k]) begin
                                    pin_type_r[k*8 +: 8] <= cur_type; pin_init_r[k*8 +: 8] <= cur_init;
                                    pin_safe_r[k*8 +: 8] <= cur_safe; pin_count_r[k*11 +: 11] <= cur_count[10:0];
                                end
                                if (cur_type==`EOS_TYPE_I2C) begin
                                    i2c_scl_r<=cur_p0; i2c_sda_r<=cur_p1; i2c_pres_r<=1'b1;
                                end
                                used_pins<=used_pins|cur_phys; used_count<=used_count+cur_np;
                                pdi<=pdi+4'd1; vol_top<=vol_top+9'd2;
                            end
                        end
                        8'h03: begin // REG
                            if (pdi==4'd0 || line_bad || name_bad || !width_seen ||
                                reg_total>=8'd128 || cur_regcnt>=8'd16 ||
                                reg_new_len>9'd32) begin
                                ok<=1'b0; err<=3'd5;
                            end else begin
                                cur_banklen<=reg_new_len[7:0];
                                cur_regcnt<=reg_new_cnt;
                                dj_kind<=4'd3; dj_step<=4'd0; dj_base<=cur_descbase;
                                dj_regbase<=desc_cursor; dj_banklen<=reg_new_len[7:0];
                                dj_regcnt<=reg_new_cnt; dj_regoff<=cur_banklen; dj_regwidth<=cur_width;
                                desc_cursor<=desc_cursor+10'd4; desc_len<=desc_cursor+10'd4;
                                reg_total<=reg_total+8'd1; vol_top<=vol_top+{1'b0,cur_width};
                            end
                        end
                        8'h05: begin // DEF (record itself is written by u_def_ram)
                            if (def_count>=7'd64 || line_bad || name_bad || !def_val_seen) begin
                                ok<=1'b0; err<=3'd3;
                            end else def_count<=def_count+7'd1;
                        end
                        8'h06: begin // DATA (record itself is written by u_dat_ram)
                            if (dat_count>=6'd32 || line_bad || name_bad || data_bad || d_ovf || !d_started ||
                                payload_new>16'd16384) begin
                                ok<=1'b0; err<=3'd4;
                            end else begin
                                dat_count<=dat_count+6'd1;
                                payload_total<=payload_new[14:0];
                            end
                        end
                        default: ;
                        endcase
                    end
                end
                // ------- end of pass (one cycle after the last line commit) --
                if (lex_done) finishing<=1'b1;
                else if (finishing) begin
                    finishing<=1'b0; busy<=1'b0; done<=1'b1;
                    desc_len<=10'd2;  // invalid image exposes only ABI header + zero count
                    pindef_count<=4'd0; volatile_used<=8'd0;
                    if (err!=3'd0) ok<=1'b0;
                    else if (!target_seen || target_bad || (text_target!=frame_target)) begin ok<=1'b0; err<=3'd6; end
                    else if ((|instr_count[15:13]) || (instr_count[12] && |instr_count[11:0])) begin ok<=1'b0; err<=3'd6; end
                    else if (vol_top[8] || ((&vol_top[7:3]) && |vol_top[2:0])) begin ok<=1'b0; err<=3'd2; end
                    else if ((text_target && ((used_pins & 8'h07)!=8'd0 || used_count>4'd5)) ||
                             (!text_target && used_count>4'd8)) begin ok<=1'b0; err<=3'd1; end
                    else if (payload_total[14] && |payload_total[13:0]) begin ok<=1'b0; err<=3'd4; end
                    else begin ok<=1'b1; pindef_count<=pdi; volatile_used<=vol_top[7:0]; dj_kind<=4'd4; dj_step<=4'd0; desc_len<=desc_cursor; end
                end
            end
        end
    end
endmodule

// ---------------------------------------------------------------------------
//  eos_exp_volatile  —  256 B volatile RAM (spec 5.2)  [M2]
//
//  Async-read register array (so the mailbox read stays combinational, matching
//  eos_i2c's readmux). Two write ports: host (mailbox) and script (exec, M3).
//  Reserved 0xF8..0xFF: host writes ignored; the script may write RESULT (0xFF).
//  zero-on-run clears all 256 bytes.
// ---------------------------------------------------------------------------
module eos_exp_volatile (
    input             clk,
    input             resetn,
    input             zero,
    output reg        zbusy,

    input             h_wr,  input [7:0] h_waddr, input [7:0] h_wdata,
    input      [7:0]  h_raddr, output [7:0] h_rdata,
    input             s_wr,  input [7:0] s_waddr, input [7:0] s_wdata,
    input      [7:0]  s_raddr, output [7:0] s_rdata
);
    // Two replicated synchronous SDP copies deliberately trade two plentiful
    // BSRAM blocks for zero SSRAM read-mux fabric. Both copies receive the same
    // serialized write stream; each serves one independent registered read.
    reg [8:0] zi;
    reg       hpending;
    reg [7:0] hp_addr, hp_data;
    wire s_valid = s_wr && (s_waddr < 8'hF8 || s_waddr==8'hFF);
    wire h_valid = h_wr && (h_waddr < 8'hF8);
    wire mem_we = zbusy || s_valid || hpending || h_valid;
    wire [7:0] mem_wa = zbusy ? zi[7:0] :
                         s_valid ? s_waddr :
                         hpending ? hp_addr : h_waddr;
    wire [7:0] mem_wd = zbusy ? 8'h00 :
                         s_valid ? s_wdata :
                         hpending ? hp_data : h_wdata;

    eos_exp_sdp_ram #(.WIDTH(8),.ADDR_W(8)) u_vol_h(
        .clk(clk),.we(mem_we),.waddr(mem_wa),.wdata(mem_wd),.raddr(h_raddr),.rdata(h_rdata));
    eos_exp_sdp_ram #(.WIDTH(8),.ADDR_W(8)) u_vol_s(
        .clk(clk),.we(mem_we),.waddr(mem_wa),.wdata(mem_wd),.raddr(s_raddr),.rdata(s_rdata));

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            zbusy<=1'b0; zi<=9'd0; hpending<=1'b0; hp_addr<=8'd0; hp_data<=8'd0;
        end else begin
            if (zero) begin
                zbusy<=1'b1; zi<=9'd0; hpending<=1'b0;
            end else if (zbusy) begin
                if (zi==9'd255) zbusy<=1'b0;
                zi<=zi+9'd1;
            end else begin
                // Script owns the immediate write slot. A coincident host write
                // is deferred one clock rather than dropped. SMBus byte spacing
                // is far longer than this one-entry skid buffer.
                if (hpending) begin
                    if (!s_valid) begin
                        if (h_valid) begin hp_addr<=h_waddr; hp_data<=h_wdata; hpending<=1'b1; end
                        else hpending<=1'b0;
                    end
                end else if (s_valid && h_valid) begin
                    hp_addr<=h_waddr; hp_data<=h_wdata; hpending<=1'b1;
                end
            end
        end
    end
endmodule

// ---------------------------------------------------------------------------
//  eos_exp_mailbox  —  0x6E register window 0x40..0x6F (spec 5.3/5.6/5.7) [M2]
//
//  Plugs into eos_i2c's single-byte-per-command model: rd_data is a purely
//  combinational function of rd_index (extend readmux with it for 0x40..0x6F);
//  wr_stb/wr_index/wr_data take a write dispatched from the wsub path.
//  Serves STATUS/FAULT/PC/ABI/PINDEF_COUNT/SEL/PAGE/WINKIND/DOORBELL/CMD/RESULT
//  and the 32-byte window (WINKIND=0 descriptor from eos_exp_layout, WINKIND=1
//  volatile). Implements the doorbell FSM + write-protection checker: host may
//  drive PENDING-from-IDLE and IDLE-from-READY only; illegal rings raise a
//  sticky per-pin-def OVERRUN; CMD/window(reg) bytes are bank-locked while that
//  pin-def's doorbell != IDLE; 0xF8..0xFF ignored. Runs in clk_sd.
// ---------------------------------------------------------------------------
module eos_exp_mailbox (
    input               clk,
    input               resetn,

    // status inputs (from framechk / exec; stubbed until M3)
    input               st_running, st_fault, st_image_valid,
    input               st_boot_gate, st_busy,
    input               mbx_clr,        // §6c reload: clear sticky OVERRUN (doorbells/CMD re-zeroed via volatile zero-on-run)
    input       [7:0]   fault_code,
    input       [15:0]  pc,
    input       [3:0]   pindef_count,

    // eos_i2c delegation for indices 0x40..0x6F
    input       [7:0]   rd_index,
    output reg  [7:0]   rd_data,
    input               wr_stb,
    input       [7:0]   wr_index,
    input       [7:0]   wr_data,

    // selected pin-def bank base + global descriptor stream
    output reg  [3:0]   q_sel,
    input       [7:0]   q_bankoff, q_dboff,
    input       [63:0]  db_off_flat,
    output reg  [9:0]   desc_raddr,
    input       [7:0]   desc_rdata,
    input       [9:0]   desc_len,

    // observe script volatile writes so the compact doorbell shadow follows
    // BUSY/READY transitions without requiring an async RAM read port
    input               script_wr,
    input       [7:0]   script_waddr, script_wdata,

    // volatile host port (to eos_exp_volatile)
    output reg          v_wr,
    output reg  [7:0]   v_waddr, v_wdata,
    output reg  [7:0]   v_raddr,
    input       [7:0]   v_rdata
);
    reg [7:0] sel, page, winkind;
    reg [7:0] overrun;                  // per-pin-def sticky OVERRUN (bit i)

    // Script doorbell writes are rare and the SMBus host is orders of magnitude
    // slower than clk_sd.  Scan the 8 pin-def doorbell offsets over 8 clocks
    // instead of instantiating eight parallel 8-bit address comparators.  This
    // preserves the host-visible shadow while materially reducing LUT pressure.
    reg       dbscan_busy;
    reg [2:0] dbscan_idx;
    reg [7:0] dbscan_addr, dbscan_data;
    wire [7:0] dbscan_off = db_off_flat[{dbscan_idx,3'b000} +: 8];

    wire [7:0] db_off  = q_dboff;                 // DOORBELL_OFF for SEL
    wire [7:0] cmd_off = q_bankoff;             // CMD_OFF for SEL
    reg [15:0] db_shadow_r;
    wire [1:0] db_state = db_shadow_r[{sel[2:0],1'b0} +: 2];

    // linear descriptor address for the window
    wire [12:0] desc_lin = {page,rd_index[5],rd_index[3:0]};

    // ---- combinational READ (single byte for rd_index) ----
    // v_raddr / q_sel / descriptor address are driven combinationally for the byte.
    always @(*) begin
        q_sel    = sel[3:0];
        desc_raddr = desc_lin[9:0];
        v_raddr  = 8'h00;
        rd_data  = 8'h00;
        case (rd_index)
            8'h40: rd_data = {3'd0, st_busy, st_boot_gate, st_image_valid, st_fault, st_running};
            8'h41: rd_data = fault_code;
            8'h42: rd_data = pc[7:0];
            8'h43: rd_data = pc[15:8];
            8'h44: rd_data = 8'h01;                       // ABI_VER
            8'h45: rd_data = {4'd0, pindef_count};
            8'h46: rd_data = sel;
            8'h47: rd_data = page;
            8'h48: rd_data = winkind;
            8'h49: rd_data = {overrun[sel[2:0]], 5'd0, db_state}; // DOORBELL
            8'h4A: begin v_raddr = cmd_off; rd_data = v_rdata; end   // CMD
            8'h4B: begin v_raddr = 8'hFF;   rd_data = v_rdata; end   // RESULT (mirror 0xFF)
            default: begin
                if (rd_index >= 8'h50 && rd_index <= 8'h6F) begin
                    if (winkind == 8'h00) begin
                        // Global ABI-v1 capability stream built by eos_exp_layout.
                        // Header [ABI_VER,PINDEF_COUNT] is followed by every
                        // pin-def and its register records exactly as the editor
                        // command-map/export code documents it.
                        if (desc_lin < {3'd0,desc_len}) rd_data = desc_rdata;
                        else rd_data = 8'h00;
                    end else begin
                        // volatile window: byte (page*32 + offset)
                        v_raddr = {page[2:0],rd_index[5],rd_index[3:0]};
                        rd_data = v_rdata;
                    end
                end
            end
        endcase
    end

    // ---- WRITE handling + doorbell FSM / write-protection ----
    integer w;
    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            sel<=8'd0; page<=8'd0; winkind<=8'd0; overrun<=8'd0;
            v_wr<=1'b0; v_waddr<=8'd0; v_wdata<=8'd0;
            dbscan_busy<=1'b0; dbscan_idx<=3'd0; dbscan_addr<=8'd0; dbscan_data<=8'd0;
            db_shadow_r<=16'd0;
        end else begin
            v_wr<=1'b0;
            if (mbx_clr) begin
                overrun<=8'd0; dbscan_busy<=1'b0;
                db_shadow_r<=16'd0;
            end

            // Script owns BUSY/READY.  Serialize the reverse doorbell lookup;
            // a complete scan is only 8 clk_sd cycles (~124 ns at 64.8 MHz).
            if (!dbscan_busy && script_wr &&
                (script_wdata[1:0]==2'd2 || script_wdata[1:0]==2'd3)) begin
                dbscan_busy<=1'b1; dbscan_idx<=3'd0;
                dbscan_addr<=script_waddr; dbscan_data<=script_wdata;
            end else if (dbscan_busy) begin
                if (dbscan_addr == dbscan_off) begin
                    db_shadow_r[{dbscan_idx,1'b0} +: 2] <= dbscan_data[1:0];
                    dbscan_busy<=1'b0;
                end else if (dbscan_idx==3'd7) begin
                    dbscan_busy<=1'b0;
                end else begin
                    dbscan_idx<=dbscan_idx+3'd1;
                end
            end

            if (wr_stb) begin
                case (wr_index)
                8'h46: sel     <= wr_data;
                8'h47: page    <= wr_data;
                8'h48: winkind <= wr_data;
                8'h49: begin  // DOORBELL transition request / OVERRUN-clear
                    if (wr_data[7]) overrun[sel[2:0]] <= 1'b0;      // b7=1: clear OVERRUN only
                    else begin
                        // host may write PENDING-from-IDLE or IDLE-from-READY only
                        if (wr_data[1:0]==2'd1 && db_state==2'd0) begin
                            v_wr<=1'b1; v_waddr<=q_dboff; v_wdata<=8'd1; db_shadow_r[{sel[2:0],1'b0} +: 2]<=2'd1; // -> PENDING
                        end else if (wr_data[1:0]==2'd0 && db_state==2'd3) begin
                            v_wr<=1'b1; v_waddr<=q_dboff; v_wdata<=8'd0; db_shadow_r[{sel[2:0],1'b0} +: 2]<=2'd0; // -> IDLE
                        end else overrun[sel[2:0]] <= 1'b1;         // illegal ring -> sticky
                    end
                end
                8'h4A: begin  // CMD: bank-locked while doorbell != IDLE
                    if (db_state==2'd0) begin v_wr<=1'b1; v_waddr<=q_bankoff; v_wdata<=wr_data; end
                end
                default: begin
                    if (wr_index>=8'h50 && wr_index<=8'h6F && winkind!=8'h00) begin
                        // volatile window write (host): reserved + bank-lock aware
                        v_wr<=1'b1;
                        v_waddr<={page[2:0],wr_index[5],wr_index[3:0]};
                        v_wdata<=wr_data;
                    end
                end
                endcase
            end
        end
    end

endmodule

// ---------------------------------------------------------------------------
//  eos_exp_exec  —  PASS 2 interpreter (control + mailbox opcodes)  [M3]
//
//  Drives the (seekable, flow-controlled) lexer and dispatches by opcode:
//  NOP, DELAY, LOOP/ENDLOOP (4-deep stack, back-jump via lexer seek),
//  IFMAIL (compare volatile, skip-if-false), END (wrap to offset 0),
//  GETMAIL/SETMAIL (registers R0-R7 <-> volatile). Pin/peripheral opcodes
//  (SET/GET/PWM/WS/I2CW/I2CR) are dispatched to a peripheral-command bus for
//  the M4-M6 drivers; here they complete via p_done. Faults: BAD_CMD (0x01),
//  LOOP_STACK (0x03), ARG_RANGE (0x04), TIMEOUT (0x05) -- terminal, latch PC.
//  Runs in clk_sd.
// ---------------------------------------------------------------------------
module eos_exp_exec #(
    parameter [31:0] CYCLES_PER_MS = 32'd8,     // sim-scaled; set for clk_sd in the top
    parameter [31:0] WATCHDOG_CYC  = 32'd1000000 // ~ per-op limit (non-DELAY)
)(
    input               clk,
    input               resetn,
    input               start,
    input               halt,          // loader freeze (reload stop-seq / §6c)
    input  [20:0]       text_len,
    input  [63:0]       pin_type_flat, // resolved declaration map for BAD_PIN/type checks
    input               i2c_present,

    // lexer stream
    input               line_stb,
    input       [1:0]   kw_class,
    input       [7:0]   kw_code,
    input       [20:0]  line_off,
    input       [15:0]  instr_ordinal,
    input               tok_stb,
    input       [15:0]  tok_len,
    input               tok_is_first,
    input       [127:0] tok_word,
    input       [5:0]   tok_tag,
    input       [31:0]  tok_num,
    input               tok_isnum,
    input               lex_held,
    input               lex_done,

    // lexer control (seek + flow control)
    output reg          lx_start,
    output reg  [20:0]  lx_off,
    output reg  [15:0]  lx_ord,
    output reg          lx_ack,

    // volatile script port
    output reg  [7:0]   s_raddr,
    input       [7:0]   s_rdata,
    output reg          s_wr,
    output reg  [7:0]   s_waddr, s_wdata,
    output reg          v_zero,
    input               v_zbusy,

    // peripheral-command bus (M4-M6 drivers)
    output reg          p_start,
    output reg  [7:0]   p_op,
    output reg  [2:0]   p_pin,       // decoded EXP pin index (EXP1=0)
    output reg  [7:0]   p_arg0,
    output reg  [16:0]  p_arg1,

    // WS2812 frame path
    output reg          ws_wr,
    output reg  [11:0]  ws_waddr,
    output reg  [7:0]   ws_wdata,
    output reg          ws_send,
    output reg  [12:0]  ws_len,
    output reg          ws_zero,
    output reg  [2:0]   ws_pin,
    input               ws_busy,
    output reg  [2:0]   cnt_sel,     // per-pin COUNT read (layout)
    input       [15:0]  cnt_val,

    // I2C transaction path (eos_exp_i2c)
    output reg          iw_wr,
    output reg  [8:0]   iw_waddr,
    output reg  [7:0]   iw_wdata,
    output reg          i2c_go,
    output reg          i2c_read,
    output reg  [6:0]   i2c_addr,
    output reg  [8:0]   i2c_len,
    output reg  [8:0]   ir_raddr,
    input       [7:0]   ir_rdata,
    input               i2c_busy,
    input               i2c_done,
    input       [2:0]   i2c_result,

    // DEF/DATA name resolution (scan layout tables by tok_word)
    output reg  [6:0]   def_ridx,
    input       [127:0] def_rword,
    input       [31:0]  def_rval,
    input       [6:0]   def_cnt,
    output reg  [5:0]   dat_ridx,
    input       [127:0] dat_rword,
    input       [20:0]  dat_rdoff,
    input       [31:0]  dat_rdlen,
    input       [5:0]   dat_cnt,
    // scratch read port (in-file DATA payload; lexer is held while used)
    output reg          x_scr_rd,
    output reg  [20:0]  x_scr_raddr,
    input       [7:0]   x_scr_rdata,
    input               x_scr_rvalid,
    input               x_scr_busy,
    input               p_busy, p_done,
    input       [7:0]   p_result,

    // status
    output reg          running,
    output reg          fault,
    output reg  [7:0]   fault_code,
    output reg  [15:0]  pc
);
    localparam F_BADCMD=8'h01, F_BADPIN=8'h02, F_LOOP=8'h03, F_ARG=8'h04, F_TIMEOUT=8'h05;

    // registers
    reg [7:0] R0,R1,R2,R3,R4,R5,R6,R7;
    // loop stack (4 deep)
    reg [20:0] ls_off  [0:3];
    reg [15:0] ls_ord  [0:3];
    reg [31:0] ls_rem  [0:3];
    reg [2:0]  sp;                     // 0..4
    reg [11:0] skip_cnt;

    // Operand capture. Numeric literals/registers are resolved immediately;
    // DEF-backed numeric operands are resolved through one shared sequential
    // table scan before dispatch. Full 16-character operand spellings live in
    // a tiny BSRAM-backed line cache so editor-valid names remain exact without
    // building wide LUT muxes.
    reg [2:0]   opn;
    reg [5:0]   op_tag0, op_tag1;
    reg [31:0]  op_num0, op_num1, op_num2, op_num3;
    reg [3:0]   op_ready, op_has;     // ready = literal or Rn (or DEF after scan)
    reg [2:0]   op_reg0, op_reg1;
    reg         op_unit_us, op_unit_seen;
    reg [1:0]   res_pos;
    reg [1:0]   ow_raddr;
    wire [127:0] ow_rdata;
    wire        ow_we = tok_stb && !tok_is_first && (opn < 3'd4);
    eos_exp_sdp_ram #(.WIDTH(128),.ADDR_W(2)) u_operand_words (
        .clk(clk),.we(ow_we),.waddr(opn[1:0]),.wdata(tok_word),
        .raddr(ow_raddr),.rdata(ow_rdata));

    wire is_reg_tok = (tok_tag>=`EOS_T_R0) && (tok_tag<=`EOS_T_R7);
    wire [2:0] reg_idx_tok = tok_tag - `EOS_T_R0;

    // latched line for delayed dispatch
    reg        disp_pend;
    reg [7:0]  cmd_code; reg [1:0] cmd_class; reg [15:0] cmd_ord; reg [20:0] cmd_off;
    reg        loop_arm; reg [31:0] loop_arm_cnt;

    // delay timer + watchdog. US is an editor-visible V1 unit; rounded cycles
    // preserve it without a 32-bit runtime multiply.
    reg [15:0] delay_units, delay_tick; reg delay_us; reg [24:0] wdog;
    localparam [15:0] DELAY_MS_TICKS = CYCLES_PER_MS[15:0];
    localparam [15:0] DELAY_US_TICKS = ((CYCLES_PER_MS + 32'd500) / 32'd1000);
    localparam [24:0] WATCHDOG_LOAD = WATCHDOG_CYC[24:0];

    localparam E_IDLE=4'd0, E_ZERO=4'd1, E_KICK=4'd2, E_RUN=4'd3, E_DISP=4'd4,
               E_DELAY=4'd5, E_PWAIT=4'd6, E_SETW=4'd7, E_FAULT=4'd8, E_MREAD=4'd9,
               E_WSRD=4'd11, E_WSWR=4'd12, E_WSSND=4'd13, E_WSWAIT=4'd14,
               E_ZWAIT=4'd10,
               E_IWFILL=5'd15, E_IWFILL2=5'd16, E_IWGO=5'd17, E_IWWAIT=5'd18,
               E_IRGO=5'd19, E_IRWAIT=5'd20, E_IRDRAIN=5'd21, E_IRDRAIN2=5'd22, E_IRESULT=5'd23,
               E_IADDR=5'd24, E_DEFSCAN=5'd25, E_IFORM=5'd26, E_DATSCAN=5'd27, E_DHEXF=5'd28, E_DHEXW=5'd29,
               E_VWAIT=5'd30, E_RESOLVE=5'd31;
    reg [4:0] st;
    reg       ldone_l;
    reg       mrd_get;          // 0 = IFMAIL, 1 = GETMAIL
    reg [2:0] mrd_reg;
    reg       pget; reg [2:0] pget_reg;   // pending GET -> register load
    reg [12:0] ws_fi, ws_blen; reg [7:0] ws_off;   // WS VOL fill cursor
    reg [8:0]  i_fi, i_len; reg [7:0] i_off, i_dst; reg [6:0] i_addr; reg [2:0] i_res;
    reg [7:0]  i_op; reg i_dest;                    // DATA dest: 0=WS, 1=I2C
    reg [20:0] hexptr; reg [12:0] dcnt, dlen; reg [3:0] nib_hi; reg nib_hi_v;
    reg        sym_wait;                            // one-cycle latency for BSRAM symbol reads
    reg [4:0]  vnext;                               // consumer after synchronous RAM prefetch

    // IFMAIL compare uses the lexer's compact exact token tag.
    function cmp_true; input [7:0] m; input [7:0] v; input [5:0] t; begin
        case (t)
            `EOS_T_EQ: cmp_true = (m==v);
            `EOS_T_NE: cmp_true = (m!=v);
            `EOS_T_LT: cmp_true = (m< v);
            `EOS_T_GT: cmp_true = (m> v);
            `EOS_T_GE: cmp_true = (m>=v);
            `EOS_T_LE: cmp_true = (m<=v);
            default:   cmp_true = 1'b0;
        endcase
    end endfunction

    function [7:0] rread; input [2:0] n; begin
        case(n)
            3'd0:rread=R0; 3'd1:rread=R1; 3'd2:rread=R2; 3'd3:rread=R3;
            3'd4:rread=R4; 3'd5:rread=R5; 3'd6:rread=R6; default:rread=R7;
        endcase
    end endfunction

    function [7:0] exec_ptype; input [2:0] n; begin
        exec_ptype = pin_type_flat[n*8 +: 8];
    end endfunction
    wire       op_pin_valid = (op_tag0>=`EOS_T_EXP1) && (op_tag0<=`EOS_T_EXP8);
    wire [2:0] op_pin_idx   = op_tag0 - `EOS_T_EXP1;
    wire [7:0] op_pin_type  = exec_ptype(op_pin_idx);
    wire [7:0] op_need_type = (cmd_code==`EOS_OP_SET) ? `EOS_TYPE_GPIO_OUT :
                              (cmd_code==`EOS_OP_GET) ? `EOS_TYPE_GPIO_IN : `EOS_TYPE_PWM;


    // Numeric operand positions accepted by the editor. Anything in one of
    // these positions that is neither a literal nor Rn is a DEF name and is
    // resolved by the single sequential table scanner below.
    reg [3:0] need_mask;
    wire [3:0] unresolved_mask = need_mask & op_has & ~op_ready;
    // Width-aware validity predicates avoid 32-bit magnitude comparators for
    // fields whose editor/spec ranges are byte/word sized.
    wire op0_u8  = ~|op_num0[31:8];
    wire op1_u8  = ~|op_num1[31:8];
    wire op2_u8  = ~|op_num2[31:8];
    wire op3_u8  = ~|op_num3[31:8];
    wire op0_u16 = ~|op_num0[31:16];
    wire op0_u7  = ~|op_num0[31:7];
    wire [8:0] vol_sum23 = {1'b0,op_num2[7:0]} + {1'b0,op_num3[7:0]};
    wire [8:0] vol_sum21 = {1'b0,op_num2[7:0]} + {1'b0,op_num1[7:0]};
    wire [15:0] ws_expect_len = {cnt_val[14:0],1'b0} + cnt_val;
    wire freq_ok = (op_num2[31:17]==15'd0) && (op_num2[16:0]!=17'd0) && (op_num2[16:0]<=17'd100000);
    always @(*) begin
        need_mask = 4'b0000;
        case (cmd_code)
            `EOS_OP_SET:      need_mask = 4'b0010; // value
            `EOS_OP_DELAY:    need_mask = 4'b0001; // count
            `EOS_OP_PWM:      need_mask = 4'b0110; // duty, freq
            `EOS_OP_WS:       if (op_tag1==`EOS_T_VOL) need_mask = 4'b1100; // off,len
            `EOS_OP_I2CW: begin
                need_mask[0] = 1'b1;             // address
                if (op_tag1==`EOS_T_VOL) need_mask[3:2] = 2'b11; // off,len
            end
            `EOS_OP_I2CR:     need_mask = 4'b0111; // addr,len,dstoff
            `EOS_OP_GETMAIL:  need_mask = 4'b0001; // idx
            `EOS_OP_SETMAIL:  need_mask = 4'b0011; // idx,value
            `EOS_OP_LOOP:     need_mask = op_has[0] ? 4'b0001 : 4'b0000;
            `EOS_OP_IFMAIL:   need_mask = 4'b1101; // idx,val,skip
            default:          need_mask = 4'b0000;
        endcase
    end

    function ishex; input [7:0] c; begin
        ishex=(c>=8'h30&&c<=8'h39)||(c>=8'h41&&c<=8'h46)||(c>=8'h61&&c<=8'h66); end endfunction
    function isws;  input [7:0] c; begin
        isws=(c==8'h20)||(c==8'h09)||(c==8'h0A)||(c==8'h0D); end endfunction
    function [3:0] hexv; input [7:0] c; begin
        if (c<=8'h39) hexv=c-8'h30;
        else if (c<=8'h46) hexv=c-8'h41+4'd10;
        else hexv=c-8'h61+4'd10; end endfunction
    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            st<=E_IDLE; running<=1'b0; fault<=1'b0; fault_code<=8'd0; pc<=16'd0;
            lx_start<=1'b0; lx_ack<=1'b0; lx_off<=21'd0; lx_ord<=16'd0;
            s_wr<=1'b0; s_raddr<=8'd0; s_waddr<=8'd0; s_wdata<=8'd0; v_zero<=1'b0;
            p_start<=1'b0; sp<=3'd0; skip_cnt<=12'd0; disp_pend<=1'b0; loop_arm<=1'b0; ldone_l<=1'b0; pget<=1'b0;
            ws_wr<=1'b0; ws_send<=1'b0; ws_zero<=1'b0;
            iw_wr<=1'b0; i2c_go<=1'b0; i2c_read<=1'b0; x_scr_rd<=1'b0; def_ridx<=7'd0; dat_ridx<=6'd0; nib_hi_v<=1'b0; sym_wait<=1'b0;
            opn<=3'd0; op_tag0<=`EOS_T_NONE; op_tag1<=`EOS_T_NONE;
            op_num0<=32'd0; op_num1<=32'd0; op_num2<=32'd0; op_num3<=32'd0;
            op_ready<=4'd0; op_has<=4'd0; op_reg0<=3'd0; op_reg1<=3'd0;
            op_unit_us<=1'b0; op_unit_seen<=1'b0; res_pos<=2'd0; ow_raddr<=2'd0; delay_us<=1'b0; wdog<=25'd0;
            R0<=8'd0;R1<=8'd0;R2<=8'd0;R3<=8'd0;R4<=8'd0;R5<=8'd0;R6<=8'd0;R7<=8'd0;
        end else begin
            // default 1-cycle strobes
            lx_start<=1'b0; lx_ack<=1'b0; s_wr<=1'b0; v_zero<=1'b0; p_start<=1'b0; i2c_go<=1'b0; iw_wr<=1'b0; ws_wr<=1'b0; x_scr_rd<=1'b0;
            if (lex_done) ldone_l<=1'b1;

            // ---- operand capture (whenever tokens stream) ----
            if (tok_stb) begin
                if (tok_is_first) begin
                    opn<=3'd0; op_tag0<=`EOS_T_NONE; op_tag1<=`EOS_T_NONE;
                    op_num0<=32'd0; op_num1<=32'd0; op_num2<=32'd0; op_num3<=32'd0;
                    op_ready<=4'd0; op_has<=4'd0; op_reg0<=3'd0; op_reg1<=3'd0;
                    op_unit_us<=1'b0; op_unit_seen<=1'b0;
                end else begin
                    case (opn)
                    3'd0: begin
                        op_tag0<=tok_tag; op_has[0]<=1'b1; op_ready[0]<=tok_isnum|is_reg_tok;
                        op_num0<=is_reg_tok?{24'd0,rread(reg_idx_tok)}:tok_num; op_reg0<=reg_idx_tok;
                    end
                    3'd1: begin
                        op_tag1<=tok_tag; op_has[1]<=1'b1; op_ready[1]<=tok_isnum|is_reg_tok;
                        op_num1<=is_reg_tok?{24'd0,rread(reg_idx_tok)}:tok_num; op_reg1<=reg_idx_tok;
                        // DELAY's optional unit is the only editor grammar use
                        // of a free-standing MS/US operand; detect it cheaply.
                        if (tok_len==16'd2 && tok_word[15:0]==16'h5553) begin op_unit_us<=1'b1; op_unit_seen<=1'b1; end // US
                        else if (tok_len==16'd2 && tok_word[15:0]==16'h4D53) begin op_unit_us<=1'b0; op_unit_seen<=1'b1; end // MS
                    end
                    3'd2: begin
                        op_has[2]<=1'b1; op_ready[2]<=tok_isnum|is_reg_tok;
                        op_num2<=is_reg_tok?{24'd0,rread(reg_idx_tok)}:tok_num;
                    end
                    3'd3: begin
                        op_has[3]<=1'b1; op_ready[3]<=tok_isnum|is_reg_tok;
                        op_num3<=is_reg_tok?{24'd0,rread(reg_idx_tok)}:tok_num;
                    end
                    default: ;
                    endcase
                    if (opn!=3'd7) opn<=opn+3'd1;
                end
            end

            case (st)
            E_IDLE: if (start) begin
                        running<=1'b1; fault<=1'b0; fault_code<=8'd0; pc<=16'd0;
                        sp<=3'd0; skip_cnt<=12'd0; loop_arm<=1'b0; wdog<=25'd0;
                        R0<=8'd0;R1<=8'd0;R2<=8'd0;R3<=8'd0;R4<=8'd0;R5<=8'd0;R6<=8'd0;R7<=8'd0;
                        v_zero<=1'b1; ldone_l<=1'b0; st<=E_ZERO;
                    end
            E_ZERO:  if (v_zbusy) st<=E_ZWAIT;              // wait for zero-on-run to start
            E_ZWAIT: if (!v_zbusy) begin                   // ...then finish
                        lx_start<=1'b1; lx_off<=21'd0; lx_ord<=16'd0; st<=E_KICK;
                    end
            E_KICK: st<=E_RUN;                 // let the lexer start
            E_RUN: begin
                if (line_stb) begin
                    cmd_code<=kw_code; cmd_class<=kw_class;
                    cmd_ord<=instr_ordinal; cmd_off<=line_off;
                    disp_pend<=1'b1; st<=E_DISP;
                end else if (ldone_l) begin
                    // END is optional: EOF behaves as an implicit END.
                    ldone_l<=1'b0; lx_start<=1'b1; lx_off<=21'd0; lx_ord<=16'd0; st<=E_RUN;
                end
            end
            E_DISP: begin
                disp_pend<=1'b0; pc<=cmd_ord;
                // arm loop body capture: this instruction is the loop body start
                if (loop_arm) begin
                    if (sp>=3'd4) begin fault<=1'b1; fault_code<=F_LOOP; st<=E_FAULT; end
                    else begin
                        ls_off[sp]<=cmd_off; ls_ord[sp]<=cmd_ord; ls_rem[sp]<=loop_arm_cnt;
                        sp<=sp+3'd1; loop_arm<=1'b0;
                    end
                end
                if (fault) ; // already faulting
                else if (skip_cnt!=12'd0) begin
                    skip_cnt<=skip_cnt-12'd1; lx_ack<=1'b1; st<=E_RUN;   // skip this instruction
                end else if (cmd_class==2'd1) begin
                    lx_ack<=1'b1; st<=E_RUN;                            // directive: pass-1 only, skip
                end else if (cmd_class!=2'd2) begin
                    fault<=1'b1; fault_code<=F_BADCMD; st<=E_FAULT;      // unknown command line
                end else if (unresolved_mask!=4'b0000) begin
                    // Resolve one DEF-backed numeric operand at a time using
                    // one exact comparator and one sequential table scan.
                    if (unresolved_mask[0]) begin res_pos<=2'd0; ow_raddr<=2'd0; end
                    else if (unresolved_mask[1]) begin res_pos<=2'd1; ow_raddr<=2'd1; end
                    else if (unresolved_mask[2]) begin res_pos<=2'd2; ow_raddr<=2'd2; end
                    else begin res_pos<=2'd3; ow_raddr<=2'd3; end
                    def_ridx<=7'd0; sym_wait<=1'b0; st<=E_RESOLVE;
                end else begin
                    case (cmd_code)
                    8'h00: begin lx_ack<=1'b1; st<=E_RUN; end            // NOP
                    8'h03: begin                                        // DELAY <count> [MS|US]
                        if (!op0_u16 || (op_has[1] && !op_unit_seen)) begin
                            fault<=1'b1; fault_code<=F_ARG; st<=E_FAULT;
                        end else begin
                            delay_units<=op_num0[15:0]; delay_us<=op_unit_us;
                            if (op_unit_us)
                                delay_tick<=(DELAY_US_TICKS==16'd0)?16'd0:DELAY_US_TICKS-16'd1;
                            else
                                delay_tick<=(DELAY_MS_TICKS==16'd0)?16'd0:DELAY_MS_TICKS-16'd1;
                            st<=E_DELAY;
                        end
                    end
                    8'h50: begin                                        // LOOP [n], 0/omitted = forever
                        loop_arm<=1'b1; loop_arm_cnt<=op_has[0]?op_num0:32'd0;
                        lx_ack<=1'b1; st<=E_RUN;
                    end
                    8'h51: begin                                        // ENDLOOP
                        if (sp==3'd0) begin fault<=1'b1; fault_code<=F_LOOP; st<=E_FAULT; end
                        else if (ls_rem[sp-3'd1] == 32'd0) begin       // forever
                            lx_start<=1'b1; lx_off<=ls_off[sp-3'd1]; lx_ord<=ls_ord[sp-3'd1];
                            st<=E_RUN;
                        end else if (ls_rem[sp-3'd1] != 32'd1) begin
                            ls_rem[sp-3'd1] <= ls_rem[sp-3'd1]-32'd1;
                            lx_start<=1'b1; lx_off<=ls_off[sp-3'd1]; lx_ord<=ls_ord[sp-3'd1];
                            st<=E_RUN;
                        end else begin sp<=sp-3'd1; lx_ack<=1'b1; st<=E_RUN; end
                    end
                    8'h52: begin                                        // IFMAIL idx cmp val skip
                        if (!op0_u8 || !op2_u8 || (|op_num3[31:12]) ||
                            !(op_tag1==`EOS_T_EQ || op_tag1==`EOS_T_NE || op_tag1==`EOS_T_LT || op_tag1==`EOS_T_GT)) begin
                            fault<=1'b1; fault_code<=F_ARG; st<=E_FAULT;
                        end else begin
                            s_raddr<=op_num0[7:0]; mrd_get<=1'b0; vnext<=E_MREAD; st<=E_VWAIT;
                        end
                    end
                    8'h5F: begin lx_start<=1'b1; lx_off<=21'd0; lx_ord<=16'd0; st<=E_RUN; end // END wrap
                    8'h40: begin                                        // GETMAIL <idx> <Rn>
                        if (!op0_u8 || !(op_tag1>=`EOS_T_R0 && op_tag1<=`EOS_T_R7)) begin
                            fault<=1'b1; fault_code<=F_ARG; st<=E_FAULT;
                        end else begin
                            s_raddr<=op_num0[7:0]; mrd_get<=1'b1; mrd_reg<=op_reg1; vnext<=E_MREAD; st<=E_VWAIT;
                        end
                    end
                    8'h41: begin                                        // SETMAIL idx val
                        if (!op0_u8 || !op1_u8) begin
                            fault<=1'b1; fault_code<=F_ARG; st<=E_FAULT;
                        end else if (&op_num0[7:3]) begin
                            // 0xF8..0xFF are engine-reserved.  SETMAIL remains
                            // syntactically valid (as in the editor) but the write
                            // is ignored; GETMAIL/IFMAIL may still read RESULT 0xFF.
                            lx_ack<=1'b1; st<=E_RUN;
                        end else begin
                            s_wr<=1'b1; s_waddr<=op_num0[7:0]; s_wdata<=op_num1[7:0]; st<=E_SETW;
                        end
                    end
                    8'h10: begin                                        // WS <pin> ...
                        if (!op_pin_valid || op_pin_type!=`EOS_TYPE_WS2812) begin
                            fault<=1'b1; fault_code<=F_BADPIN; st<=E_FAULT;
                        end else begin
                            cnt_sel <= op_pin_idx;
                            if (op_tag1==`EOS_T_VOL) begin                  // VOL off len
                                if (!op2_u8 || !op3_u8 || vol_sum23>9'd248) begin
                                    fault<=1'b1; fault_code<=F_ARG; st<=E_FAULT;
                                end else begin
                                    ws_pin <= op_pin_idx;
                                    ws_off <= op_num2[7:0];
                                    ws_blen<= op_num3[12:0];
                                    ws_fi  <= 13'd0;
                                    st<=E_WSRD;                            // COUNT check after cnt_val settles
                                end
                            end else begin                                 // in-file DATA form
                                ws_pin <= op_pin_idx;
                                i_dest <= 1'b0; i_op <= 8'h10; dat_ridx<=6'd0;
                                ow_raddr<=2'd1; sym_wait<=1'b0; st<=E_IADDR;
                            end
                        end
                    end
                    8'h20: begin // I2CW
                        if (!i2c_present) begin fault<=1'b1; fault_code<=F_BADPIN; st<=E_FAULT; end
                        else if (!op0_u7) begin fault<=1'b1; fault_code<=F_ARG; st<=E_FAULT; end
                        else begin i_op<=8'h20; i_addr<=op_num0[6:0]; st<=E_IFORM; end
                    end
                    8'h21: begin // I2CR
                        if (!i2c_present) begin fault<=1'b1; fault_code<=F_BADPIN; st<=E_FAULT; end
                        else if (!op0_u7) begin fault<=1'b1; fault_code<=F_ARG; st<=E_FAULT; end
                        else begin i_op<=8'h21; i_addr<=op_num0[6:0]; st<=E_IFORM; end
                    end
                    8'h30,8'h31,8'h32: begin fault<=1'b1; fault_code<=F_BADCMD; st<=E_FAULT; end // OW reserved
                    `EOS_OP_SET,`EOS_OP_GET,`EOS_OP_PWM: begin
                        if (!op_pin_valid) begin
                            fault<=1'b1; fault_code<=F_BADPIN; st<=E_FAULT;
                        end else if (op_pin_type!=op_need_type) begin
                            fault<=1'b1; fault_code<=F_BADPIN; st<=E_FAULT;
                        end else if ((cmd_code==`EOS_OP_SET && |op_num1[31:1]) ||
                                     (cmd_code==`EOS_OP_PWM && (!op1_u8 || !freq_ok))) begin
                            fault<=1'b1; fault_code<=F_ARG; st<=E_FAULT;
                        end else begin
                            p_start<=1'b1; p_op<=cmd_code;
                            p_pin<=op_pin_idx;
                            p_arg0<=op_num1[7:0]; p_arg1<=op_num2[16:0];
                            pget<=(cmd_code==`EOS_OP_GET); pget_reg<=op_reg1;
                            wdog<=WATCHDOG_LOAD; st<=E_PWAIT;
                        end
                    end
                    default: begin fault<=1'b1; fault_code<=F_BADCMD; st<=E_FAULT; end
                    endcase
                end
            end
            E_DELAY: begin
                if (delay_units==16'd0 ||
                    (delay_us ? (DELAY_US_TICKS==16'd0) : (DELAY_MS_TICKS==16'd0))) begin
                    lx_ack<=1'b1; st<=E_RUN;
                end else if (delay_tick==16'd0) begin
                    delay_units<=delay_units-16'd1;
                    delay_tick<=delay_us ? DELAY_US_TICKS-16'd1 : DELAY_MS_TICKS-16'd1;
                end else delay_tick<=delay_tick-16'd1;
            end
            E_SETW:  begin lx_ack<=1'b1; st<=E_RUN; end                 // volatile write settled
            E_WSRD: begin                                              // validate length, then stream volatile -> buffer
                ws_wr<=1'b0;
                if (ws_fi==13'd0 && (ws_blen != ws_expect_len)) begin
                    fault<=1'b1; fault_code<=F_ARG; pc<=cmd_ord; st<=E_FAULT;   // len != COUNT*3
                end else begin
                    s_raddr <= ws_off + ws_fi[7:0]; vnext<=E_WSWR; st<=E_VWAIT; // sync volatile prefetch
                end
            end
            E_WSWR: begin
                ws_wr<=1'b1; ws_waddr<=ws_fi[11:0]; ws_wdata<=s_rdata;  // s_rdata now valid
                if (ws_fi >= ws_blen-13'd1) st<=E_WSSND;
                else begin ws_fi<=ws_fi+13'd1; st<=E_WSRD; end
            end
            E_WSSND: begin
                ws_wr<=1'b0; ws_send<=1'b1; ws_len<=ws_blen; ws_zero<=1'b0; wdog<=WATCHDOG_LOAD; st<=E_WSWAIT;
            end
            E_WSWAIT: begin
                ws_send<=1'b0;
                if (wdog==25'd0) begin fault<=1'b1; fault_code<=F_TIMEOUT; pc<=cmd_ord; st<=E_FAULT; end
                else begin wdog<=wdog-25'd1; if (!ws_send && !ws_busy) begin lx_ack<=1'b1; st<=E_RUN; end end
            end
            E_IWFILL: begin                                            // I2CW: stream volatile -> write buffer
                iw_wr<=1'b0;
                if (i_len==9'd0) st<=E_IWGO;
                else begin s_raddr <= i_off + i_fi[7:0]; vnext<=E_IWFILL2; st<=E_VWAIT; end
            end
            E_IWFILL2: begin
                iw_wr<=1'b1; iw_waddr<=i_fi; iw_wdata<=s_rdata;
                if (i_fi >= i_len-9'd1) st<=E_IWGO;
                else begin i_fi<=i_fi+9'd1; st<=E_IWFILL; end
            end
            E_IWGO: begin
                iw_wr<=1'b0; i2c_go<=1'b1; i2c_read<=1'b0; i2c_addr<=i_addr; i2c_len<=i_len; wdog<=WATCHDOG_LOAD; st<=E_IWWAIT;
            end
            E_IWWAIT: begin
                i2c_go<=1'b0;
                if (wdog==25'd0) begin fault<=1'b1; fault_code<=F_TIMEOUT; pc<=cmd_ord; st<=E_FAULT; end
                else begin wdog<=wdog-25'd1; if (i2c_done) begin i_res<=i2c_result; st<=E_IRESULT; end end
            end
            E_IRGO: begin
                i2c_go<=1'b1; i2c_read<=1'b1; i2c_addr<=i_addr; i2c_len<=i_len; wdog<=WATCHDOG_LOAD; st<=E_IRWAIT;
            end
            E_IRWAIT: begin
                i2c_go<=1'b0;
                if (wdog==25'd0) begin fault<=1'b1; fault_code<=F_TIMEOUT; pc<=cmd_ord; st<=E_FAULT; end
                else begin wdog<=wdog-25'd1; if (i2c_done) begin i_res<=i2c_result; i_fi<=9'd0; st<=(i_len==9'd0)?E_IRESULT:E_IRDRAIN; end end
            end
            E_IRDRAIN: begin ir_raddr<=i_fi; vnext<=E_IRDRAIN2; st<=E_VWAIT; end // sync read buffer
            E_IRDRAIN2: begin
                s_wr<=1'b1; s_waddr<=i_dst + i_fi[7:0]; s_wdata<=ir_rdata;
                if (i_fi >= i_len-9'd1) st<=E_IRESULT;
                else begin i_fi<=i_fi+9'd1; st<=E_IRDRAIN; end
            end
            E_RESOLVE: begin                                           // operand-word + DEF[0] BSRAM settle
                sym_wait<=1'b1; st<=E_DEFSCAN;
            end
            E_DEFSCAN: begin                                           // shared exact 16-char DEF resolver
                if (def_cnt==7'd0) begin fault<=1'b1; fault_code<=F_ARG; pc<=cmd_ord; st<=E_FAULT; end
                else if (!sym_wait) sym_wait<=1'b1;
                else if (def_rword==ow_rdata) begin
                    case (res_pos)
                        2'd0: op_num0<=def_rval;
                        2'd1: op_num1<=def_rval;
                        2'd2: op_num2<=def_rval;
                        default: op_num3<=def_rval;
                    endcase
                    op_ready[res_pos]<=1'b1; sym_wait<=1'b0; st<=E_DISP;
                end else if (def_ridx>=def_cnt-7'd1) begin
                    sym_wait<=1'b0; fault<=1'b1; fault_code<=F_ARG; pc<=cmd_ord; st<=E_FAULT;
                end else begin
                    def_ridx<=def_ridx+7'd1; sym_wait<=1'b0;
                end
            end
            E_IADDR: begin                                             // DATA operand-word + DATA[0] BSRAM settle
                sym_wait<=1'b1; st<=E_DATSCAN;
            end
            E_IFORM: begin
                if (i_op==8'h21) begin                                 // I2CR addr len dstoff
                    if (!op1_u8 || op_num1[7:0]==8'd0 || op_num1[7:0]>8'd64 || !op2_u8 || vol_sum21>9'd248) begin
                        fault<=1'b1; fault_code<=F_ARG; pc<=cmd_ord; st<=E_FAULT;
                    end else begin
                        i_len<=op_num1[8:0]; i_dst<=op_num2[7:0]; st<=E_IRGO;
                    end
                end else begin                                         // I2CW
                    if (op_tag1==`EOS_T_VOL) begin                      // VOL off len
                        if (!op2_u8 || !op3_u8 || vol_sum23>9'd248) begin
                            fault<=1'b1; fault_code<=F_ARG; pc<=cmd_ord; st<=E_FAULT;
                        end else begin
                            i_off<=op_num2[7:0]; i_len<=op_num3[8:0]; i_fi<=9'd0; st<=E_IWFILL;
                        end
                    end else begin
                        i_dest<=1'b1; dat_ridx<=6'd0; ow_raddr<=2'd1; sym_wait<=1'b0; st<=E_IADDR;
                    end
                end
            end
            E_DATSCAN: begin                                           // resolve DATA name (op_word1); WS uses op_word1 too
                if (dat_cnt==6'd0) begin fault<=1'b1; fault_code<=F_BADCMD; pc<=cmd_ord; st<=E_FAULT; end
                else if (!sym_wait) sym_wait<=1'b1;                 // allow synchronous RAM read to settle
                else if (dat_rword==ow_rdata) begin
                    sym_wait<=1'b0;
                    if ((i_dest==1'b0 && (dat_rdlen[14:0]==15'd0 || |dat_rdlen[14:12])) ||
                        (i_dest==1'b1 && (|dat_rdlen[14:9] || (dat_rdlen[8] && |dat_rdlen[7:0])))) begin
                        fault<=1'b1; fault_code<=F_ARG; pc<=cmd_ord; st<=E_FAULT;
                    end else begin
                        hexptr<=dat_rdoff; dlen<=dat_rdlen[12:0]; dcnt<=13'd0; nib_hi_v<=1'b0; st<=E_DHEXF;
                    end
                end
                else if (dat_ridx>=dat_cnt-6'd1) begin sym_wait<=1'b0; fault<=1'b1; fault_code<=F_BADCMD; pc<=cmd_ord; st<=E_FAULT; end
                else begin dat_ridx<=dat_ridx+6'd1; sym_wait<=1'b0; end
            end
            E_DHEXF: begin x_scr_rd<=1'b1; x_scr_raddr<=hexptr; st<=E_DHEXW; end  // issue 1 read (stable addr)
            E_DHEXW: begin                                             // consume: decode compact hex -> buffer
                if (x_scr_rvalid) begin
                    hexptr<=hexptr+21'd1;
                    if (ishex(x_scr_rdata)) begin
                        if (!nib_hi_v) begin nib_hi<=hexv(x_scr_rdata); nib_hi_v<=1'b1; st<=E_DHEXF; end
                        else begin
                            nib_hi_v<=1'b0;
                            if (i_dest==1'b0) begin ws_wr<=1'b1; ws_waddr<=dcnt[11:0]; ws_wdata<={nib_hi,hexv(x_scr_rdata)}; end
                            else              begin iw_wr<=1'b1; iw_waddr<=dcnt[8:0];  iw_wdata<={nib_hi,hexv(x_scr_rdata)}; end
                            if (dcnt>=dlen-13'd1) begin
                                if (i_dest==1'b0) begin
                                    if (dlen != ws_expect_len) begin fault<=1'b1; fault_code<=F_ARG; pc<=cmd_ord; st<=E_FAULT; end
                                    else begin ws_blen<=dlen; st<=E_WSSND; end
                                end else begin i_len<=dlen[8:0]; st<=E_IWGO; end
                            end else begin dcnt<=dcnt+13'd1; st<=E_DHEXF; end
                        end
                    end else st<=E_DHEXF;                              // whitespace/other: skip, next char
                end
            end
            E_IRESULT: begin s_wr<=1'b1; s_waddr<=8'hFF; s_wdata<={5'd0,i_res}; st<=E_SETW; end
            E_MREAD: begin                                             // synchronous volatile data is now valid
                if (mrd_get) begin
                    case(mrd_reg)
                    3'd0:R0<=s_rdata; 3'd1:R1<=s_rdata; 3'd2:R2<=s_rdata; 3'd3:R3<=s_rdata;
                    3'd4:R4<=s_rdata; 3'd5:R5<=s_rdata; 3'd6:R6<=s_rdata; default:R7<=s_rdata;
                    endcase
                end else if (!cmp_true(s_rdata, op_num2[7:0], op_tag1))
                    skip_cnt <= op_num3[11:0];
                lx_ack<=1'b1; st<=E_RUN;
            end
            E_VWAIT: st<=vnext;                                       // one cycle for BSRAM registered read
            E_PWAIT: begin
                if (wdog==25'd0) begin fault<=1'b1; fault_code<=F_TIMEOUT; pc<=cmd_ord; st<=E_FAULT; end
                else begin wdog<=wdog-25'd1; if (p_done) begin
                    if (pget) begin
                        case(pget_reg)
                        3'd0:R0<=p_result; 3'd1:R1<=p_result; 3'd2:R2<=p_result; 3'd3:R3<=p_result;
                        3'd4:R4<=p_result; 3'd5:R5<=p_result; 3'd6:R6<=p_result; default:R7<=p_result;
                        endcase
                    end
                    lx_ack<=1'b1; st<=E_RUN;
                end end
            end
            E_FAULT: begin running<=1'b0; end                           // terminal
            endcase
            if (halt) begin running<=1'b0; st<=E_IDLE; lx_start<=1'b0; end  // loader freeze; restart is from 0 (no resume)

        end
    end
endmodule

// ---------------------------------------------------------------------------
//  eos_exp_pwm  —  8-channel PWM driver (spec 6.3)  [M4]
//
//  One channel per physical EXP pin. Config from the exec peripheral path:
//  pwm_set pulses with ch/duty/freq; a 32-cycle divider computes the period in
//  clk cycles (CLK_HZ/freq) and the high time ((period*duty)>>8). Channels free-
//  run; out=high while cnt<high_cyc. duty 0 disables (steady low). clk_sd domain.
// ---------------------------------------------------------------------------
module eos_exp_pwm #(
    parameter [31:0] CLK_HZ = 32'd27000000
)(
    input             clk,
    input             resetn,
    input             pwm_set,
    input      [2:0]  pwm_ch,
    input      [7:0]  pwm_duty,
    input      [16:0] pwm_freq,
    output reg        pwm_busy,
    output     [7:0]  pwm_out
);
    // 64.8 MHz needs only 26 bits to represent a 1-Hz period. Narrowing every
    // channel removes 48 counter/comparator bits. Duty multiplication is then
    // performed serially instead of as a wide combinational multiplier.
    reg        en [0:7];
    // Store terminal counts (period-1/high-1). Equality terminal detection is
    // substantially cheaper on GW2AR than eight pairs of 26-bit magnitude
    // comparators, while producing the same free-running PWM waveform.
    reg [25:0] period_last[0:7], high_last[0:7], cnt[0:7];
    reg [7:0]  pwm_out_r;
    reg [25:0] den, dividend, quo, rem;
    reg [4:0]  bidx;
    reg [2:0]  cfg_ch; reg [7:0] cfg_duty;
    reg [33:0] mul_a; reg [7:0] mul_b; reg [33:0] mul_acc; reg [3:0] mul_n;
    reg [1:0]  phase; // 0 idle, 1 divide, 2 multiply
    integer i;

    assign pwm_out = pwm_out_r;

    // One restoring-division bit per cycle. Keep the original divide behavior
    // but at the mathematically sufficient width.
    wire [26:0] rem_shift = {rem, dividend[25]};
    wire        div_bit   = (rem_shift >= {1'b0,den});
    wire [26:0] rem_next  = div_bit ? (rem_shift-{1'b0,den}) : rem_shift;
    wire [25:0] quo_next  = {quo[24:0],div_bit};
    wire [25:0] div_result= quo_next;
    wire [33:0] mul_add   = mul_b[0] ? (mul_acc + mul_a) : mul_acc;

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            pwm_busy<=1'b0; phase<=2'd0; pwm_out_r<=8'd0;
            for (i=0;i<8;i=i+1) begin
                en[i]<=1'b0; period_last[i]<=26'd0; high_last[i]<=26'd0; cnt[i]<=26'd0;
            end
        end else begin
            for (i=0;i<8;i=i+1) begin
                if (!en[i]) begin
                    cnt[i] <= 26'd0;
                    pwm_out_r[i] <= 1'b0;
                end else if (cnt[i] == period_last[i]) begin
                    cnt[i] <= 26'd0;
                    pwm_out_r[i] <= 1'b1;
                end else begin
                    cnt[i] <= cnt[i] + 26'd1;
                    if (cnt[i] == high_last[i]) pwm_out_r[i] <= 1'b0;
                end
            end

            case (phase)
            2'd0: if (pwm_set) begin
                cfg_ch<=pwm_ch; cfg_duty<=pwm_duty; den<={9'd0,pwm_freq};
                dividend<=CLK_HZ[25:0]; quo<=26'd0; rem<=26'd0; bidx<=5'd25;
                pwm_busy<=1'b1; phase<=2'd1;
            end
            2'd1: begin
                rem<=rem_next[25:0]; dividend<={dividend[24:0],1'b0}; quo<=quo_next;
                if (bidx==5'd0) begin
                    mul_a <= {8'd0,((div_result==26'd0)?26'd1:div_result)};
                    mul_b <= cfg_duty; mul_acc<=34'd0; mul_n<=4'd0; phase<=2'd2;
                end else bidx<=bidx-5'd1;
            end
            2'd2: begin
                mul_acc<=mul_add; mul_a<=mul_a<<1; mul_b<=mul_b>>1;
                if (mul_n==4'd7) begin
                    // Terminal-count representation: N cycles => terminal N-1.
                    period_last[cfg_ch] <= ((quo==26'd0)?26'd1:quo) - 26'd1;
                    high_last[cfg_ch]   <= (mul_add[33:8]==26'd0) ? 26'd0 : (mul_add[33:8]-26'd1);
                    en[cfg_ch]          <= (cfg_duty!=8'd0) && (mul_add[33:8]!=26'd0);
                    pwm_out_r[cfg_ch]   <= (cfg_duty!=8'd0) && (mul_add[33:8]!=26'd0);
                    cnt[cfg_ch]         <= 26'd0;
                    pwm_busy<=1'b0; phase<=2'd0;
                end else mul_n<=mul_n+4'd1;
            end
            default: phase<=2'd0;
            endcase
        end
    end
endmodule

// ---------------------------------------------------------------------------
//  eos_exp_pins  —  pinmux + GPIO + boot gate + INIT/SAFE (spec 6.1/6.2)  [M4]
//
//  Owns the 8 physical EXP pins as tri-states (exp_out/exp_oe, exp_in sampled).
//  Routes each pin by its pin-def type (from the layout maps): GPIO_OUT/PWM drive,
//  GPIO_IN/I2C/unclaimed float. Until boot_gate opens (or while safe_mode), output
//  pins are held at their SAFE level; at boot_gate rising, GPIO_OUT pins load INIT.
//  Serves the exec peripheral path: SET writes a GPIO bit, GET samples a pin into
//  p_result, PWM forwards to eos_exp_pwm. clk_sd domain.
// ---------------------------------------------------------------------------
module eos_exp_pins #(
    parameter [31:0] CLK_HZ = 32'd27000000
)(
    input             clk,
    input             resetn,
    input             boot_gate,       // 1 = engine live (pins active)
    input             safe_mode,       // 1 = force SAFE (fault/reload)

    input      [63:0] pin_type_flat,
    input      [63:0] pin_init_flat,
    input      [63:0] pin_safe_flat,

    // exec peripheral path
    input             p_start,
    input      [7:0]  p_op,
    input      [2:0]  p_pin,
    input      [7:0]  p_val0,          // SET value / PWM duty
    input      [16:0] p_val1,          // PWM freq (1..100000 Hz)
    output reg        p_done,
    output reg [7:0]  p_result,

    // WS2812 path (frame buffer fill + send, driven by exec)
    input             ws_wr,
    input      [11:0] ws_waddr,
    input      [7:0]  ws_wdata,
    input             ws_send,
    input      [12:0] ws_len,
    input             ws_zero,
    input      [2:0]  ws_pin,
    output            ws_busy,

    // I2C open-drain routing (bus pins from layout, oe from eos_exp_i2c)
    input      [2:0]  i2c_scl_pin,
    input      [2:0]  i2c_sda_pin,
    input             i2c_present,
    input             i2c_scl_oe,
    input             i2c_sda_oe,
    output            i2c_scl_in,
    output            i2c_sda_in,

    // physical
    output reg [7:0]  exp_out,
    output reg [7:0]  exp_oe,
    input      [7:0]  exp_in
);
    reg [7:0] gpio_out;
    reg       boot_d;
    wire      boot_rise = boot_gate & ~boot_d;

    // PWM driver
    reg        pwm_set; reg [2:0] pwm_ch; reg [7:0] pwm_duty; reg [16:0] pwm_freq;
    wire       pwm_busy; wire [7:0] pwm_out;
    eos_exp_pwm #(.CLK_HZ(CLK_HZ)) u_pwm (.clk(clk),.resetn(resetn),
        .pwm_set(pwm_set),.pwm_ch(pwm_ch),.pwm_duty(pwm_duty),.pwm_freq(pwm_freq),
        .pwm_busy(pwm_busy),.pwm_out(pwm_out));

    // WS2812 driver (single channel, routed to the active WS pin)
    wire ws_drv_out;
    reg [2:0] ws_active;
    eos_exp_ws2812 #(.CLK_HZ(CLK_HZ)) u_ws (.clk(clk),.resetn(resetn),
        .ws_wr(ws_wr),.ws_waddr(ws_waddr),.ws_wdata(ws_wdata),
        .ws_send(ws_send),.ws_len(ws_len),.ws_zero(ws_zero),
        .ws_busy(ws_busy),.ws_out(ws_drv_out));
    always @(posedge clk or negedge resetn)
        if (!resetn) ws_active<=3'd0; else if (ws_send) ws_active<=ws_pin;

    assign i2c_scl_in = exp_in[i2c_scl_pin];
    assign i2c_sda_in = exp_in[i2c_sda_pin];

    function [7:0] ptype; input [2:0] i; begin ptype = pin_type_flat[i*8 +: 8]; end endfunction
    function [7:0] pinit; input [2:0] i; begin pinit = pin_init_flat[i*8 +: 8]; end endfunction
    function [7:0] psafe; input [2:0] i; begin psafe = pin_safe_flat[i*8 +: 8]; end endfunction

    integer i;
    reg pwait;
    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            gpio_out<=8'd0; boot_d<=1'b0; p_done<=1'b0; p_result<=8'd0;
            pwm_set<=1'b0; pwait<=1'b0;
        end else begin
            boot_d<=boot_gate; pwm_set<=1'b0; p_done<=1'b0;

            // load INIT into GPIO_OUT pins when the boot gate opens
            if (boot_rise)
                for (i=0;i<8;i=i+1)
                    if (ptype(i[2:0])==`EOS_TYPE_GPIO_OUT) gpio_out[i] <= (pinit(i[2:0]) != 8'd0);

            // exec peripheral commands
            if (p_start) begin
                case (p_op)
                `EOS_OP_SET: begin gpio_out[p_pin] <= p_val0[0]; p_done<=1'b1; end
                `EOS_OP_GET: begin p_result <= {7'd0, exp_in[p_pin]}; p_done<=1'b1; end
                `EOS_OP_PWM: begin pwm_set<=1'b1; pwm_ch<=p_pin; pwm_duty<=p_val0; pwm_freq<=p_val1; pwait<=1'b1; end
                default:     p_done<=1'b1;
                endcase
            end else if (pwait && !pwm_busy && !pwm_set) begin
                pwait<=1'b0; p_done<=1'b1;
            end
        end
    end

    // combinational tri-state mux
    always @(boot_gate or safe_mode or pin_type_flat or pin_safe_flat or gpio_out or pwm_out or ws_drv_out or ws_active or i2c_scl_oe or i2c_sda_oe or i2c_scl_pin or i2c_sda_pin) begin
        for (i=0;i<8;i=i+1) begin
            exp_out[i] = 1'b0; exp_oe[i] = 1'b0;
            if (!boot_gate) begin
                exp_out[i] = 1'b0; exp_oe[i] = 1'b0;          // §6b pre-gate / blank: Hi-Z (all released)
            end else if (safe_mode) begin
                if (ptype(i[2:0])==`EOS_TYPE_GPIO_OUT || ptype(i[2:0])==`EOS_TYPE_PWM) begin
                    exp_out[i] = (psafe(i[2:0]) != 8'd0); exp_oe[i] = 1'b1;   // §6b fault/reload: SAFE value
                end else if (ptype(i[2:0])==`EOS_TYPE_WS2812) begin
                    exp_out[i] = 1'b0; exp_oe[i] = 1'b1;      // WS SAFE = all-off frame (send via ws_zero sequencer, deferred); line idle low
                end                                            // I2C / GPIO_IN: released (oe=0 default)
            end else begin
                case (ptype(i[2:0]))
                `EOS_TYPE_GPIO_OUT: begin exp_out[i]=gpio_out[i]; exp_oe[i]=1'b1; end
                `EOS_TYPE_PWM:      begin exp_out[i]=pwm_out[i];  exp_oe[i]=1'b1; end
                `EOS_TYPE_WS2812:   begin exp_out[i]=(i[2:0]==ws_active)?ws_drv_out:1'b0; exp_oe[i]=1'b1; end
                `EOS_TYPE_I2C: begin exp_out[i]=1'b0;                        // open-drain: pull low or release
                    exp_oe[i] = (i[2:0]==i2c_scl_pin) ? i2c_scl_oe :
                                (i[2:0]==i2c_sda_pin) ? i2c_sda_oe : 1'b0; end
                default:            begin exp_oe[i]=1'b0; end   // GPIO_IN / unclaimed
                endcase
            end
        end
    end
endmodule

// ---------------------------------------------------------------------------
//  eos_exp_ws2812  —  buffered WS2812/SK6812 serial driver (spec 4.2/6)  [M5]
//
//  Single channel. exec fills the frame buffer (ws_wr/ws_waddr/ws_wdata) then
//  pulses ws_send with the byte length (= COUNT*3). ws_zero synthesises the
//  all-off INIT/SAFE frame (ws_len zero bytes, no payload stored). Bytes shift
//  out MSB-first as GRB; each bit is a fixed high pulse (T1H/T0H) then low
//  (T1L/T0L); the frame ends with a >50us reset-low latch. All timing is
//  re-derived from CLK_HZ (clk_sd = 64.8 MHz), per the WS2812 datasheet.
// ---------------------------------------------------------------------------
module eos_exp_ws2812 #(
    parameter [31:0] CLK_HZ = 32'd64800000
)(
    input             clk,
    input             resetn,
    // frame buffer fill port
    input             ws_wr,
    input      [11:0] ws_waddr,
    input      [7:0]  ws_wdata,
    // transmit request
    input             ws_send,
    input      [12:0] ws_len,        // bytes to send (COUNT*3), <= 4095
    input             ws_zero,       // 1 = send ws_len zero bytes (all-off)
    output reg        ws_busy,
    output reg        ws_out
);
    // datasheet timing -> cycles at CLK_HZ  (400/850/800/450 ns, 60 us latch)
    localparam [15:0] T0H = (CLK_HZ/1000)*400 /1000000;
    localparam [15:0] T0L = (CLK_HZ/1000)*850 /1000000;
    localparam [15:0] T1H = (CLK_HZ/1000)*800 /1000000;
    localparam [15:0] T1L = (CLK_HZ/1000)*450 /1000000;
    localparam [15:0] TRST= (CLK_HZ/1000)*60000/1000000;   // ~60 us reset/latch

    (* syn_ramstyle = "block_ram" *) reg [7:0] fbuf [0:4095];
    always @(posedge clk) if (ws_wr) fbuf[ws_waddr] <= ws_wdata;

    localparam S_IDLE=3'd0, S_LOAD=3'd1, S_LOADW=3'd2, S_HIGH=3'd3, S_LOW=3'd4, S_RST=3'd5;
    reg [2:0]  st;
    reg [7:0]  sh;
    reg [3:0]  bn;
    reg [12:0] bidx, len_l;
    reg        zero_l, curbit;
    reg [15:0] dur, tick;

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            st<=S_IDLE; ws_busy<=1'b0; ws_out<=1'b0;
            bidx<=13'd0; len_l<=13'd0; tick<=16'd0;
        end else begin
            case (st)
            S_IDLE: begin
                ws_out<=1'b0;
                if (ws_send) begin
                    len_l<=ws_len; zero_l<=ws_zero; bidx<=13'd0;
                    ws_busy<=1'b1;
                    st <= (ws_len==13'd0) ? S_RST : S_LOAD;
                    tick<=16'd0; dur<=TRST;
                end
            end
            S_LOAD: begin                                   // issue registered buffer read
                sh <= zero_l ? 8'd0 : fbuf[bidx];
                st <= S_LOADW;
            end
            S_LOADW: begin                                  // sh valid; launch bit 7 high phase
                bn<=4'd7; curbit<=sh[7];
                dur <= sh[7] ? T1H : T0H;
                tick<=16'd0; ws_out<=1'b1; st<=S_HIGH;
            end
            S_HIGH: begin
                if (tick>=dur-16'd1) begin
                    ws_out<=1'b0; tick<=16'd0;
                    dur <= curbit ? T1L : T0L; st<=S_LOW;
                end else tick<=tick+16'd1;
            end
            S_LOW: begin
                if (tick>=dur-16'd1) begin
                    tick<=16'd0;
                    if (bn==4'd0) begin                     // byte done
                        if (bidx>=len_l-13'd1) begin
                            dur<=TRST; ws_out<=1'b0; st<=S_RST;   // frame done -> latch
                        end else begin
                            bidx<=bidx+13'd1; st<=S_LOAD;
                        end
                    end else begin                          // next bit (MSB-first shift)
                        sh<=sh<<1; bn<=bn-4'd1; curbit<=sh[6];
                        dur <= sh[6] ? T1H : T0H; ws_out<=1'b1; st<=S_HIGH;
                    end
                end else tick<=tick+16'd1;
            end
            S_RST: begin
                ws_out<=1'b0;
                if (tick>=dur-16'd1) begin ws_busy<=1'b0; st<=S_IDLE; end
                else tick<=tick+16'd1;
            end
            default: st<=S_IDLE;
            endcase
        end
    end
endmodule

// ---------------------------------------------------------------------------
//  eos_exp_i2c  —  soft I2C master, transaction sequencer (spec 6)  [M6]
//
//  Wraps the proven eos_i2c_master.v byte engine (reused from the HD/ADV7511
//  path, GPLv3) with a transaction layer + buffers, so the interpreter issues
//  whole transfers instead of bit-banging. One bus (SCL/SDA on two EXP pins,
//  open-drain via the pinmux). exec fills the write buffer (iw_*) then pulses
//  i2c_go with i2c_read=0; for reads (i2c_read=1) the received bytes land in
//  the read buffer, drained afterwards via ir_*. Sequence per transfer:
//  START -> addr<<1|R/W -> data/read bytes (ACK all but the last read) -> STOP.
//  A NACK or bus timeout latches i2c_err. Timing (100 kHz) from CLK params.
// ---------------------------------------------------------------------------
module eos_exp_i2c #(
    parameter integer SCL_LOW_CYCLES  = 343,     // ~100 kHz at 64.8 MHz
    parameter integer SCL_HIGH_CYCLES = 305
)(
    input             clk,
    input             resetn,
    // physical open-drain bus (to pinmux)
    input             sda_in,
    input             scl_in,
    output            sda_oe,
    output            scl_oe,
    // write-buffer fill (exec -> here), read-buffer drain (here -> exec)
    input             iw_wr,
    input      [8:0]  iw_waddr,
    input      [7:0]  iw_wdata,
    input      [8:0]  ir_raddr,
    output     [7:0]  ir_rdata,
    // transaction request
    input             i2c_go,
    input             i2c_read,      // 1 = read (I2CR), 0 = write (I2CW)
    input      [6:0]  i2c_addr,
    input      [8:0]  i2c_len,
    output reg        i2c_busy,
    output reg        i2c_done,      // pulse
    output reg  [2:0] i2c_result     // valid at i2c_done: 0 OK,1 NACK_ADDR,2 NACK_DATA,3 TIMEOUT,4 STUCK/ARB
);
    // buffers
    (* syn_ramstyle = "block_ram" *) reg [7:0] wbuf [0:255];
    (* syn_ramstyle = "block_ram" *) reg [7:0] rbuf [0:63];
    reg [7:0] ir_rdata_r;
    assign ir_rdata = ir_rdata_r;
    always @(posedge clk) begin
        if (iw_wr) wbuf[iw_waddr[7:0]] <= iw_wdata;
        ir_rdata_r <= rbuf[ir_raddr[5:0]];
    end

    // byte engine
    reg        start_go, wr_go, rd_go, rd_send_ack, stop_go; reg [7:0] wr_byte;
    wire       start_done, start_timeout, wr_done, wr_ack, wr_timeout, wr_arb_lost;
    wire       rd_done, rd_timeout, stop_done, m_busy; wire [7:0] rd_byte;
    eos_i2c_master #(.SCL_LOW_CYCLES(SCL_LOW_CYCLES), .SCL_HIGH_CYCLES(SCL_HIGH_CYCLES))
      u_m (.clk(clk),.resetn(resetn),
        .sda_in(sda_in),.scl_in(scl_in),.sda_oe(sda_oe),.scl_oe(scl_oe),
        .start_go(start_go),.start_done(start_done),.start_timeout(start_timeout),
        .wr_go(wr_go),.wr_byte(wr_byte),.wr_done(wr_done),.wr_ack(wr_ack),
        .wr_timeout(wr_timeout),.wr_arb_lost(wr_arb_lost),
        .rd_go(rd_go),.rd_send_ack(rd_send_ack),.rd_done(rd_done),.rd_byte(rd_byte),.rd_timeout(rd_timeout),
        .stop_go(stop_go),.stop_done(stop_done),.busy(m_busy));

    localparam T_IDLE=4'd0, T_STARTW=4'd1, T_ADDR=4'd2, T_ADDRW=4'd3,
               T_WR=4'd4, T_WRW=4'd5, T_RD=4'd6, T_RDW=4'd7,
               T_STOP=4'd8, T_STOPW=4'd9, T_DONE=4'd10;
    reg [3:0]  ts;
    reg        rd_l; reg [6:0] addr_l; reg [8:0] len_l, bidx;

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            ts<=T_IDLE; i2c_busy<=1'b0; i2c_done<=1'b0; i2c_result<=3'd0;
            start_go<=1'b0; wr_go<=1'b0; rd_go<=1'b0; stop_go<=1'b0; rd_send_ack<=1'b0;
        end else begin
            start_go<=1'b0; wr_go<=1'b0; rd_go<=1'b0; stop_go<=1'b0; i2c_done<=1'b0;
            case (ts)
            T_IDLE: if (i2c_go) begin
                rd_l<=i2c_read; addr_l<=i2c_addr; len_l<=i2c_len; bidx<=9'd0;
                i2c_result<=3'd0; i2c_busy<=1'b1; start_go<=1'b1; ts<=T_STARTW;
            end
            T_STARTW: if (start_done) begin
                if (start_timeout) begin i2c_result<=3'd3; stop_go<=1'b1; ts<=T_STOPW; end
                else ts<=T_ADDR;
            end
            T_ADDR: begin wr_byte<={addr_l, rd_l}; wr_go<=1'b1; ts<=T_ADDRW; end
            T_ADDRW: if (wr_done) begin
                if (wr_arb_lost)      begin i2c_result<=3'd4; stop_go<=1'b1; ts<=T_STOPW; end
                else if (wr_timeout)  begin i2c_result<=3'd3; stop_go<=1'b1; ts<=T_STOPW; end
                else if (!wr_ack)     begin i2c_result<=3'd1; stop_go<=1'b1; ts<=T_STOPW; end  // NACK_ADDR
                else ts <= rd_l ? T_RD : T_WR;
            end
            T_WR: if (bidx>=len_l) begin stop_go<=1'b1; ts<=T_STOPW; end
                  else begin wr_byte<=wbuf[bidx[7:0]]; wr_go<=1'b1; ts<=T_WRW; end
            T_WRW: if (wr_done) begin
                if (wr_arb_lost)      begin i2c_result<=3'd4; stop_go<=1'b1; ts<=T_STOPW; end
                else if (wr_timeout)  begin i2c_result<=3'd3; stop_go<=1'b1; ts<=T_STOPW; end
                else if (!wr_ack)     begin i2c_result<=3'd2; stop_go<=1'b1; ts<=T_STOPW; end  // NACK_DATA
                else begin bidx<=bidx+9'd1; ts<=T_WR; end
            end
            T_RD: if (bidx>=len_l) begin stop_go<=1'b1; ts<=T_STOPW; end
                  else begin rd_send_ack<=(bidx < len_l-9'd1); rd_go<=1'b1; ts<=T_RDW; end
            T_RDW: if (rd_done) begin
                rbuf[bidx[5:0]]<=rd_byte;
                if (rd_timeout) i2c_result<=3'd3;
                bidx<=bidx+9'd1; ts<=T_RD;
            end
            T_STOPW: if (stop_done) ts<=T_DONE;
            T_DONE: begin i2c_done<=1'b1; i2c_busy<=1'b0; ts<=T_IDLE; end
            default: ts<=T_IDLE;
            endcase
        end
    end
endmodule

// ---------------------------------------------------------------------------
//  eos_exp_loader  —  engine lifecycle orchestrator (spec 6, 6a, 6c)  [M7]
//
//  The single controller that sequences the whole engine: it holds everything
//  in the pre-gate Hi-Z posture until EOS has served the first BIOS byte over
//  LPC (§6a boot gate), then validates the flash image (framechk), lays it out
//  (layout pass 1), and starts the interpreter (exec) from instruction 0.
//
//  It also owns the §6c reload stop-sequence: on an erase/program request from
//  the host flash-staging channel it performs the ordered stop — freeze exec,
//  drive outputs SAFE (or Hi-Z for a disable/erase-to-blank), reset the mailbox
//  transaction state, and permit the erase — then re-validates after the host
//  finishes. Because revalidation reads the region fresh, one path covers both
//  outcomes: a committed MAGIC re-runs; an erased/blank region stays idle
//  (§5.5). A terminal fault clears only through this same path (re-flash / cold
//  boot). The loader does NOT program flash itself — that is the existing
//  eos_flash_cmd staging channel; the loader is the interlock around it.
// ---------------------------------------------------------------------------
module eos_exp_loader (
    input             clk,
    input             resetn,
    // events (top level / host flash-staging channel)
    input             first_bios_byte,  // §6a: 1 once LPC has served the first BIOS byte
    input             reload_req,        // 1 while an erase/program is in progress
    input             reload_disable,    // 1 = disable/erase-to-blank (Hi-Z); 0 = program/replace (SAFE hold)
    // from framechk / layout / exec
    input             fc_done,
    input             fc_valid,
    input             lay_done,
    input             lay_ok,
    input             exec_running,
    input             exec_fault,
    // control out
    output reg        fc_start,          // → framechk.start
    output reg        lay_start,         // → layout.start (pass 1)
    output reg        exec_start,        // → exec.start (run from instr 0; re-zeros vol + R0-R7)
    output reg        exec_halt,         // → exec.halt
    output reg        pins_active,       // → pins.boot_gate (pins driven only with a valid image)
    output reg        safe_out,          // → pins.safe_mode (fault / reload hold)
    output reg        mbx_reset,         // → mailbox transaction reset (§6c step 4)
    output reg        erase_permit,      // → flash channel: OK to erase/program now
    // STATUS bits (§5.5 0x40)
    output            st_running,
    output            st_fault,
    output            st_image_valid,
    output            st_gate_open,
    output            st_busy,
    output     [3:0]  dbg_state
);
    localparam L_IDLE=4'd0, L_VAL=4'd1, L_VWAIT=4'd2, L_LAY=4'd3, L_LWAIT=4'd4,
               L_START=4'd5, L_RUN=4'd6, L_FAULT=4'd7, L_STOP=4'd8, L_BLANK=4'd9;
    reg [3:0] state;
    reg       gate_open, image_valid;

    assign dbg_state      = state;
    assign st_gate_open   = gate_open;
    assign st_image_valid = image_valid;
    assign st_running     = exec_running && (state==L_RUN);
    assign st_fault       = (state==L_FAULT);
    assign st_busy        = (state==L_VAL)||(state==L_VWAIT)||(state==L_LAY)||
                            (state==L_LWAIT)||(state==L_STOP);

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            state<=L_IDLE; gate_open<=1'b0; image_valid<=1'b0;
            fc_start<=1'b0; lay_start<=1'b0; exec_start<=1'b0; exec_halt<=1'b0;
            pins_active<=1'b0; safe_out<=1'b0; mbx_reset<=1'b0; erase_permit<=1'b0;
        end else begin
            fc_start<=1'b0; lay_start<=1'b0; exec_start<=1'b0; mbx_reset<=1'b0;  // 1-cycle strobes
            case (state)
            L_IDLE: begin                                  // pre-gate: Hi-Z, idle
                pins_active<=1'b0; safe_out<=1'b0; image_valid<=1'b0;
                exec_halt<=1'b0; erase_permit<=1'b0;
                if (first_bios_byte) begin gate_open<=1'b1; state<=L_VAL; end
            end
            L_VAL:   begin fc_start<=1'b1; state<=L_VWAIT; end
            L_VWAIT: if (fc_done) state <= fc_valid ? L_LAY : L_BLANK;
            L_LAY:   begin lay_start<=1'b1; state<=L_LWAIT; end
            L_LWAIT: if (lay_done) state <= lay_ok ? L_START : L_BLANK;
            L_START: begin                                 // valid image: go live from instr 0
                image_valid<=1'b1; pins_active<=1'b1; safe_out<=1'b0;
                exec_halt<=1'b0; exec_start<=1'b1; state<=L_RUN;
            end
            L_RUN: begin
                if (reload_req)        state<=L_STOP;
                else if (exec_fault)   state<=L_FAULT;
            end
            L_FAULT: begin                                 // §4.7 terminal: SAFE, wait for re-flash/cold boot
                safe_out<=1'b1; pins_active<=1'b1;
                if (reload_req) state<=L_STOP;
            end
            L_STOP: begin                                  // §6c reload stop-sequence
                exec_halt<=1'b1; mbx_reset<=1'b1; erase_permit<=1'b1;
                if (reload_disable) begin pins_active<=1'b0; safe_out<=1'b0; image_valid<=1'b0; end // Hi-Z
                else                begin pins_active<=1'b1; safe_out<=1'b1; end                     // SAFE hold
                if (!reload_req) begin                     // host finished erase/program
                    erase_permit<=1'b0; exec_halt<=1'b0; state<=L_VAL;   // revalidate (blank -> idle, MAGIC -> run)
                end
            end
            L_BLANK: begin                                 // §5.5 no valid image: Hi-Z, idle
                image_valid<=1'b0; pins_active<=1'b0; safe_out<=1'b0; exec_halt<=1'b0;
                if (reload_req) state<=L_STOP;
            end
            default: state<=L_IDLE;
            endcase
        end
    end
endmodule