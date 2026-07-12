#!/usr/bin/env python3
# gen_hud.py -- generate eos_serve_hud.v : a maximized, project-unique LPC serve
# dashboard on the 160x45 colour cell grid.
#
# Panels: title / BOOT-LINK (rev, D0, LFRAME aborts) / SERVE (bank, rate, last) /
# FLASH ENGINE / I2C ENGINE / SDRAM preload bar / ADDRESS-SPACE SERVE MAP
# (live cursor+heat) / SERVE LOG (8) / STABILITY.
# attr: 0 norm 1 hdr(white/purple) 2 purple 3 green 4 amber 5 red 7 dim.
# One cell written per vclk by a scan FSM.
#
# ---------------------------------------------------------------------------
# CHANGELOG
# ---------------------------------------------------------------------------
# * I2C ENGINE panel (rows 6-9, col 82+) RESTORED. It had been hand-added to
#   eos_serve_hud.v and never back-ported here, so this generator was 62 cells
#   and 9 module ports behind the shipped RTL. Regenerating from the old script
#   produced a module eos_hdmi_top could not elaborate against. Do not let that
#   happen again: if you edit the .v, edit this file.
#
# * Width fixes (were EX3791 warnings in GowinSynthesis):
#     - log0a <= addr[19:0]     addr is 21b, log0a is 20b. A20 was always being
#                               dropped; the HUD only prints 5 nibbles anyway.
#     - pctv  = prog100[24:18]  instead of (prog100 >> 18). Same value; prog100
#                               maxes at 0x1900000 so the slice is exact.
#     - pd_t/pd_o via 7-bit intermediates, then sliced to 4b. pr1 <= 99.
#
# * `always @(negedge lreset_n)` is GONE. It made GowinSynthesis
#   infer a CLOCK on lpc_lreset_n -- an unconstrained, bouncing, asynchronous pin
#   driving a 12-bit counter and a capture register, and the source of three
#   CK3000 warnings. On a warm reset LRESET can ring, so `resets` counted ring
#   pulses and `faila` could latch a half-shifted log0a. Now lreset_n is
#   synchronised into lclk with a 3-FF chain and edge-detected. Do NOT put it
#   back. Consequence: the reset count needs LCLK running to register, which is
#   true on a warm reset and false on a power-down. That is the right trade.
#
# * Removed the unused `mem_valid` input port (declared, connected by
#   eos_hdmi_top, read nowhere) and the `failb` register (latched on reset, never
#   displayed). If you re-add either, wire it to something.
#
# Usage:  python3 gen_hud.py [output_path]
#         default output: ./eos_serve_hud.v

import sys

COLS = 160
cells = []   # (row, col, kind, arg, attr)

def T(r, c, s, at=0):                       # static text
    for i, ch in enumerate(s):
        cells.append((r, c + i, 't', ord(ch), at))

def HX(r, c, sig, hi, lo, at=0):            # hex nibbles, MSB first
    for k in range(hi, lo - 1, -1):
        cells.append((r, c + (hi - k), 'h', (sig, k), at))

def CELL(r, c, expr_ch, expr_at):           # raw expression cell
    cells.append((r, c, 'x', (expr_ch, expr_at), 0))

# ---- layout ---------------------------------------------------------------
T(0, 1, " EOS  LPC BIOS SERVER ", 1)
T(0, 24, " Team Resurgent / Darkone83 ", 2)

# --- BOOT / LINK ---
T(2, 1, "BOOT / LINK", 2)
T(3, 1, "REV"); T(3, 7, "1.", 2); CELL(3, 9, 'mode16_s?"6":"5"', 'mode16_s?A_WARN:A_OK')
T(4, 1, "D0");  T(4, 7, "      ")
for i, _ in enumerate("FORCED"):
    CELL(4, 7 + i, 'd0w[%d]' % i, 'd0a')
T(5, 1, "LFRAME ABORTS"); HX(5, 15, 'abort_count', 3, 0, 4); CELL(5, 20, 'aborting_s?"*":" "', 'A_FAIL')
T(6, 1, "LCLK");   T(6, 7, "[ OK ]", 3)
T(7, 1, "LRESET")
for i in range(5):
    CELL(7, 7 + i, 'lrw[%d]' % i, 'lra')

# --- SERVE ---
T(2, 40, "SERVE", 2)
T(3, 40, "BANK");  HX(3, 46, 'bank_load', 0, 0, 3); T(3, 47, "/"); HX(3, 48, 'bank_sel', 0, 0, 1)
T(4, 40, "STATE"); HX(4, 46, 'state', 0, 0, 0)
T(5, 40, "READS"); HX(5, 46, 'rdcnt', 3, 0, 0)
T(6, 40, "RATE");  HX(6, 46, 'rate', 3, 0, 3)
T(7, 40, "LAST");  HX(7, 46, 'addr', 4, 0, 2); T(7, 51, ":"); HX(7, 52, 'sbyte', 1, 0, 1)

# --- FLASH ENGINE ---
T(2, 82, "FLASH ENGINE", 2)
T(3, 82, "OP")
for i in range(5):
    CELL(3, 88 + i, 'fopw[%d]' % i, 'fopa')
T(4, 82, "BUSY"); CELL(4, 88, 'fbusy?"Y":"-"', 'fbusy?A_WARN:7')

# --- I2C ENGINE (SMBus slave, addr 0xDC) ---
# All fields here are sampled in the VCLK domain (see i2c_*_s in the template),
# not lclk -- they come straight from eos_i2c on clk_sd.
T(6, 82, "I2C ENGINE", 2)
T(6, 100, "SEL"); CELL(6, 104, 'i2c_sel_s ? "*" : "-"', 'i2c_sel_s ? A_OK : 3\'d7')
T(7, 82, "ADDR 0x"); HX(7, 89, 'i2c_addr_s', 1, 0, 0)
T(7, 94, "VER ")
CELL(7, 98, "8'h30+i2c_vmaj_s", '0'); T(7, 99, ".")
CELL(7, 100, "8'h30+i2c_vmin_s", '0'); T(7, 101, ".")
CELL(7, 102, "8'h30+i2c_vpat_s", '0')
T(8, 82, "CMD 0x");  HX(8, 88, 'i2c_cmd_s', 1, 0, 3)
T(8, 92, "A0 0x");   HX(8, 97, 'i2c_a0_s', 1, 0, 0)
T(9, 82, "RX  0x");  HX(9, 88, 'i2c_rx_s', 1, 0, 0)
T(9, 92, "A1 0x");   HX(9, 97, 'i2c_a1_s', 1, 0, 0)

# --- SDRAM PRELOAD ---
T(9, 1, "SDRAM PRELOAD", 2)
T(10, 1, "[")
for i in range(32):                          # 32-cell bar
    CELL(10, 2 + i, '(%d < bar32) ? "#" : "."' % i, '(%d < bar32) ? A_OK : 3\'d7' % i)
T(10, 34, "]")
T(10, 36, "PCT"); HX(10, 40, 'pctd', 2, 0, 1)
T(11, 1, "FILL FRONT 0x"); HX(11, 14, 'filled24', 5, 0, 0)
T(11, 24, "SDRAM")
for i in range(5):
    CELL(11, 30 + i, 'sdw[%d]' % i, 'sda')

# --- ADDRESS-SPACE SERVE MAP (unique) ---
T(13, 1, "ADDRESS-SPACE SERVE MAP", 2)
T(13, 30, "> read  # served  . idle", 7)
T(14, 1, "0x000000")
T(14, 56, "0x1FFFFF")
T(15, 1, "[")
for i in range(64):                          # 64 chunks over the 2MB serve space
    CELL(15, 2 + i, 'mapch(%d)' % i, 'mapat(%d)' % i)
T(15, 66, "]")
T(16, 2, "BOOT", 7); T(16, 18, "BANKS", 7); T(16, 50, "RSV", 7)

# --- SERVE LOG (8 deep) ---
T(18, 1, "SERVE LOG", 2); T(18, 14, "addr : byte", 7)
for e in range(8):
    HX(19 + e, 1, 'log%da' % e, 4, 0, 0); T(19 + e, 6, ":"); HX(19 + e, 7, 'log%db' % e, 1, 0, 3)

# --- STABILITY ---
T(18, 40, "STABILITY", 2)
T(19, 40, "RESETS"); HX(19, 47, 'resets', 2, 0, 0)
T(20, 40, "STATE")
for i in range(6):
    CELL(20, 47 + i, 'fch(%d)' % i, 'fat')
T(21, 40, "LAST FAULT 0x"); HX(21, 53, 'faila', 4, 0, 5)

# ---- sanity checks --------------------------------------------------------
# Out-of-grid is fatal. Overlaps are only a warning: the D0 field deliberately
# paints 6 blanks and then overwrites them with d0w[] later in the same scan,
# which costs 6 scan slots per pass but is harmless. Keep the warning so a NEW
# overlap (a real layout bug) is visible.
seen = {}
overlaps = []
for (r, c, k, a, at) in cells:
    if not (0 <= r < 45 and 0 <= c < COLS):
        raise SystemExit("ERROR: cell out of grid at row %d col %d" % (r, c))
    if (r, c) in seen:
        overlaps.append((r, c))
    seen[(r, c)] = True
if overlaps:
    import sys as _s
    print("note: %d overwritten cell(s): %s" % (len(overlaps), overlaps), file=_s.stderr)

# ---- emit -----------------------------------------------------------------
def chexpr(kind, arg):
    if kind == 't': return "8'h%02X" % arg
    if kind == 'h':
        sig, nib = arg
        return "hx(%s[%d:%d])" % (sig, nib * 4 + 3, nib * 4)
    if kind == 'x': return arg[0]
    return "8'h20"

def atexpr(kind, arg, at):
    if kind == 'x': return "(%s)" % arg[1]
    return "3'd%d" % at

arms = []
for idx, (r, c, k, a, at) in enumerate(cells):
    wa = r * COLS + c
    ce = chexpr(k, a)
    ae = atexpr(k, a, at)
    arms.append("            13'd%d: begin wa=13'd%d; ch=%s; at=%s; end" % (idx, wa, ce, ae))
N = len(cells)

TEMPLATE = r'''// eos_serve_hud.v -- GENERATED by gen_hud.py.  Maximized colour serve dashboard.
// Panels: title / BOOT-LINK / SERVE / FLASH ENGINE / SDRAM preload /
//         ADDRESS-SPACE SERVE MAP (live) / SERVE LOG x8 / STABILITY.
// __NCELLS__ active cells on a 160x45 grid.  attr: 0 norm 1 hdr 2 purple 3 grn 4 amb 5 red 7 dim.
//
// DO NOT EDIT THIS FILE. Edit gen_hud.py and regenerate.
module eos_serve_hud (
    input  wire        lclk, lreset_n, vclk,
    input  wire [3:0]  state,
    input  wire [20:0] mem_addr,
    input  wire [3:0]  lad,
    input  wire        sd_ready,
    input  wire        preload_done,
    input  wire [22:0] filled_lo,
    input  wire [3:0]  bank_sel,
    input  wire [2:0]  flash_op,      // 0 IDLE 1 ERASE 2 WRITE 3 READ 4 SYNC
    // boot-control diagnostics
    input  wire        mode_16,       // 1 = Xbox 1.6
    input  wire        d0_active,     // D0 being pulled low
    input  wire        abort_active,  // LFRAME# abort in progress
    input  wire [15:0] abort_count,
    // Darkone I2C (SMBus slave) engine
    input  wire [7:0]  i2c_addr,      // 8-bit device address (e.g. 0xDC)
    input  wire [7:0]  i2c_vmaj, i2c_vmin, i2c_vpat,   // firmware version
    input  wire [7:0]  i2c_cmd, i2c_a0, i2c_a1,        // last command + args
    input  wire [7:0]  i2c_rx,        // transactions addressed to us
    input  wire        i2c_sel,
    output reg         wr_en,
    output reg  [12:0] wr_addr,
    output reg  [7:0]  wr_data,
    output reg  [2:0]  wr_attr
);
    localparam [2:0] A_OK=3'd3, A_WARN=3'd4, A_FAIL=3'd5;
    localparam READ_DATA0=4'd7, READ_DATA1=4'd8, TAR_EXIT=4'd9, SYNCING=4'd5;
    function [7:0] hx; input [3:0] n; hx=(n<10)?(8'h30+n):(8'h37+n); endfunction
    function [12:0] i32; input integer i; i32=i[12:0]; endfunction

    // ---- sync the async straps/flags into lclk ----
    reg [1:0] m16_s=0, d0_s=0, ab_s=0;
    reg [1:0] sdr_s=0, pld_s=0; reg [4:0] fl_s0=0, fl_s1=0;
    always @(posedge lclk) begin
        m16_s<={m16_s[0],mode_16}; d0_s<={d0_s[0],d0_active}; ab_s<={ab_s[0],abort_active};
        sdr_s<={sdr_s[0],sd_ready}; pld_s<={pld_s[0],preload_done};
        fl_s0<=filled_lo[18:14]; fl_s1<=fl_s0;
    end
    wire mode16_s = m16_s[1], d0on_s = d0_s[1], aborting_s = ab_s[1];
    wire sd_rdy = sdr_s[1], pld = pld_s[1];

    // I2C engine signals -> sync into the VCLK (display) domain.
    reg [7:0] iaddr=0, ivmaj=0, ivmin=0, ivpat=0, icmd=0, ia0=0, ia1=0, irx=0;
    reg [1:0] isel=0;
    always @(posedge vclk) begin
        iaddr<=i2c_addr; ivmaj<=i2c_vmaj; ivmin<=i2c_vmin; ivpat<=i2c_vpat;
        icmd<=i2c_cmd; ia0<=i2c_a0; ia1<=i2c_a1; irx<=i2c_rx;
        isel<={isel[0],i2c_sel};
    end
    wire [7:0] i2c_addr_s=iaddr, i2c_vmaj_s=ivmaj, i2c_vmin_s=ivmin, i2c_vpat_s=ivpat;
    wire [7:0] i2c_cmd_s=icmd, i2c_a0_s=ia0, i2c_a1_s=ia1, i2c_rx_s=irx;
    wire i2c_sel_s=isel[1];

    // ---- serve status capture (lclk) ----
    reg [3:0] prev_state=0, lo_nib=0; reg [7:0] sbyte=0; reg [15:0] rdcnt=0;
    reg [20:0] addr=0; reg [3:0] bank_load=4'h1; reg loaded_cap=0;
    reg [19:0] log0a=0,log1a=0,log2a=0,log3a=0,log4a=0,log5a=0,log6a=0,log7a=0;
    reg [7:0]  log0b=0,log1b=0,log2b=0,log3b=0,log4b=0,log5b=0,log6b=0,log7b=0;
    reg [19:0] faila=0; reg [11:0] resets=0;
    // serve-rate window: reads since the last ~0.06 s tick
    reg [20:0] wtick=0; reg [15:0] rate=0, rdcnt_prev=0;
    // address-space serve heat: 64 chunks of 32 KB over the 2 MB serve window
    reg [63:0] visited=64'd0; wire [5:0] cur_chunk = addr[20:15];

    always @(posedge lclk) begin
        if (!loaded_cap) begin bank_load<=bank_sel; loaded_cap<=1'b1; end
        prev_state<=state;
        if (state==SYNCING)    addr<=mem_addr;
        if (state==READ_DATA0) lo_nib<=lad;
        if (state==READ_DATA1) sbyte<={lad,lo_nib};
        if (prev_state==READ_DATA1 && state==TAR_EXIT) begin
            rdcnt<=rdcnt+1'b1;
            log7a<=log6a;log6a<=log5a;log5a<=log4a;log4a<=log3a;
            log3a<=log2a;log2a<=log1a;log1a<=log0a;log0a<=addr[19:0];  // HUD prints 5 nibbles; A20 not shown
            log7b<=log6b;log6b<=log5b;log5b<=log4b;log4b<=log3b;
            log3b<=log2b;log2b<=log1b;log1b<=log0b;log0b<=sbyte;
        end
        if (!lreset_n)                                              // serve-heat: one driver
            visited<=64'd0;
        else if (prev_state==READ_DATA1 && state==TAR_EXIT)
            visited[cur_chunk]<=1'b1;
        wtick<=wtick+1'b1;
        if (&wtick) begin rate<=rdcnt-rdcnt_prev; rdcnt_prev<=rdcnt; end
    end
    // ---- LRESET fall detector, in the lclk domain -------------------------
    // This was `always @(negedge lreset_n)`, which synthesised lpc_lreset_n as a
    // clock net: unconstrained, asynchronous, and prone to ringing on a warm
    // reset. Synchronise and edge-detect on lclk instead. faila/resets are the
    // only registers this block drives, so there is exactly one driver each.
    reg [2:0] lr_sy = 3'b111;
    always @(posedge lclk) lr_sy <= {lr_sy[1:0], lreset_n};
    wire lr_fall = lr_sy[2] & ~lr_sy[1];
    always @(posedge lclk) if (lr_fall) begin
        faila  <= log0a;
        resets <= resets + 1'b1;
    end

    // ---- preload bar (32 cells) + percent ----
    wire [23:0] filled24 = {1'b0,filled_lo};
    wire [18:0] filled_val = {fl_s1,14'd0};
    wire [18:0] prog = pld ? 19'h40000 : (19'h40000 - filled_val);
    wire [5:0]  bar32 = pld ? 6'd32 : {1'b0,prog[17:13]};
    wire [25:0] prog100 = prog * 26'd100;
    wire [6:0]  pctv = pld ? 7'd100 : prog100[24:18];   // == (prog100 >> 18), max 100
    wire [3:0]  pd_h = (pctv>=7'd100)?4'd1:4'd0;
    wire [6:0]  pr1 = (pctv>=7'd100)?(pctv-7'd100):pctv;
    wire [6:0]  pd_t7 = pr1 / 7'd10;
    wire [6:0]  pd_o7 = pr1 % 7'd10;
    wire [3:0]  pd_t = pd_t7[3:0], pd_o = pd_o7[3:0];   // pr1 <= 99 -> both 0..9
    wire [11:0] pctd = {pd_h,pd_t,pd_o};

    // ---- named-value strings ----
    wire [7:0] d0w   [0:5];                  // "FORCED" / "REL   "
    assign d0w[0]=d0on_s?"F":"R"; assign d0w[1]=d0on_s?"O":"E"; assign d0w[2]=d0on_s?"R":"L";
    assign d0w[3]=d0on_s?"C":" "; assign d0w[4]=d0on_s?"E":" "; assign d0w[5]=d0on_s?"D":" ";
    wire [2:0] d0a = d0on_s?A_OK:7;
    wire [7:0] lrw  [0:4];                    // "RUN  " / "RST  "
    assign lrw[0]=lreset_n?"R":"R"; assign lrw[1]=lreset_n?"U":"S"; assign lrw[2]=lreset_n?"N":"T";
    assign lrw[3]=" "; assign lrw[4]=" ";
    wire [2:0] lra = lreset_n?A_OK:A_FAIL;
    wire [7:0] sdw  [0:4];                    // "RDY  " / "WAIT "
    assign sdw[0]=sd_rdy?"R":"W"; assign sdw[1]=sd_rdy?"D":"A"; assign sdw[2]=sd_rdy?"Y":"I";
    assign sdw[3]=sd_rdy?" ":"T"; assign sdw[4]=" ";
    wire [2:0] sda = sd_rdy?A_OK:A_WARN;
    // flash op name (5 chars) + colour
    reg [39:0] fops; reg [2:0] fopa; reg fbusy;
    always @(*) begin
        case (flash_op)
            3'd1: begin fops="ERASE"; fopa=A_WARN; fbusy=1; end
            3'd2: begin fops="WRITE"; fopa=A_WARN; fbusy=1; end
            3'd3: begin fops="READ "; fopa=A_OK;   fbusy=1; end
            3'd4: begin fops="SYNC "; fopa=2;      fbusy=1; end
            default: begin fops="IDLE "; fopa=7;   fbusy=0; end
        endcase
    end
    wire [7:0] fopw [0:4];
    assign fopw[0]=fops[39:32]; assign fopw[1]=fops[31:24]; assign fopw[2]=fops[23:16];
    assign fopw[3]=fops[15:8];  assign fopw[4]=fops[7:0];

    // ---- fault word ----
    wire [2:0] fat = (resets>=12'd3)?A_FAIL:(resets!=12'd0)?A_WARN:A_OK;
    function [7:0] fch; input integer p; reg [47:0] s; begin
        if      (resets>=12'd3) s=48'h465241473F20;  // FRAG?
        else if (resets!=12'd0) s=48'h524554525920;  // RETRY
        else                    s=48'h535441424C45;  // STABLE
        fch = s[47-8*p -: 8];
    end endfunction

    // ---- address-space serve map cell helpers ----
    function [7:0] mapch; input integer i; begin
        if (i[5:0]==cur_chunk) mapch=">";
        else if (visited[i[5:0]]) mapch="#";
        else mapch=".";
    end endfunction
    function [2:0] mapat; input integer i; begin
        if (i[5:0]==cur_chunk) mapat=3'd4;       // cursor: amber FG, dark bg
        else if (visited[i[5:0]]) mapat=A_OK;    // served: green FG, dark bg
        else mapat=3'd2;                          // idle:   purple FG, dark bg
    end endfunction

    // ---- cell scan FSM: one cell per vclk ----
    reg [12:0] idx=0, wa; reg [7:0] ch; reg [2:0] at;
    always @(posedge vclk) begin
        wr_en<=1'b1;
        case (idx)
__ARMS__
            default: begin wa=13'd0; ch=8'h20; at=3'd0; end
        endcase
        wr_addr<=wa; wr_data<=ch; wr_attr<=at;
        idx <= (idx==13'd__LAST__) ? 13'd0 : idx+1'b1;
    end
endmodule
'''
TEMPLATE = (TEMPLATE.replace('__NCELLS__', str(N))
                   .replace('__ARMS__', "\n".join(arms))
                   .replace('__LAST__', str(max(N - 1, 0))))

out = sys.argv[1] if len(sys.argv) > 1 else "eos_serve_hud.v"
# The RTL tree uses CRLF; match it so diffs stay clean.
with open(out, "w", newline="\r\n") as f:
    f.write(TEMPLATE)
print("generated %s : %d cells" % (out, N))