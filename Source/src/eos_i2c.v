// eos_i2c.v -- Darkone / Eos SMBus (I2C) slave engine.
// =====================================================================
// A register-file slave on the Xbox SMBus (SDA/SCL). Standard SMBus register
// access: the master writes a command (index) byte, then reads data bytes
// (auto-incrementing index) or writes data bytes.
//
//   write:  START  addr+W  [A]  index  [A]  data0 [A] data1 [A] ... STOP
//   read :  START  addr+W  [A]  index  [A]  Sr addr+R [A] d0 [mA] d1 [mN] STOP
//   (a read with no leading index continues from the last index)
//
// Device address = DEV_ADDR (7-bit, default 0x6E -> 8-bit 0xDC write / 0xDD read,
// "DC" = Darkone Customs). Change via the parameter if SmBusScan finds a clash.
//
// Register map:
//   0x00 MAGIC     (R) 0xD8   Darkone signature
//   0x01 VER_MAJOR (R) 1
//   0x02 VER_MINOR (R) 0
//   0x03 VER_PATCH (R) 0      -> base firmware 1.0.0
//   0x04 STATUS    (R) {live status bits from the top}
//   0x10 CMD       (W) latched opcode; pulses cmd_stb
//   0x11..0x14 ARG0..3 (W) latched command args
//
// SDA is open-drain: sda_oe=1 pulls the line LOW, sda_oe=0 releases (Hi-Z). SCL
// is input only (no clock stretching). Runs on a fast sample clock (>= ~16x SCL;
// the serve/sys clock is fine).
// =====================================================================
module eos_i2c #(
    parameter [6:0] DEV_ADDR  = 7'h6E,     // 7-bit SMBus address the scanner sees (0x6E; 0x6F alt)
    parameter [7:0] MAGIC     = 8'hD8,     // Darkone signature
    parameter [7:0] VER_MAJOR = 8'd1,
    parameter [7:0] VER_MINOR = 8'd0,
    parameter [7:0] VER_PATCH = 8'd0
)(
    input  wire        clk,
    input  wire        resetn,

    input  wire        sda_in,
    input  wire        scl_in,
    output reg         sda_oe,       // 1 = pull SDA low, 0 = release

    input  wire [7:0]  status_in,    // reported at register 0x04

    output reg  [7:0]  cmd,
    output reg  [7:0]  arg0, arg1, arg2, arg3,
    output reg         cmd_stb,      // 1-clk pulse when 0x10 (CMD) is written

    output reg  [7:0]  rx_count,     // write-addressed transactions to us
    output reg         selected,     // 1 while our address owns the bus

    // ---- CRC32 unit (VALIDATE) ----
    output reg         crc_go,
    output reg  [20:0] crc_len,
    input  wire        crc_busy,
    input  wire        crc_done,
    input  wire [31:0] crc_result,
    // ---- commit engine (eos_bank_ctrl) ----
    output reg         commit_go,
    output reg  [3:0]  commit_bank,
    output reg  [12:0] commit_pages,
    input  wire        commit_busy,
    input  wire        commit_done,
    input  wire        commit_err,
    // ---- auxiliary latched controls (loader/top consume) ----
    output reg         scr_clear,    // pulse on CLEAR/ABORT
    output reg  [3:0]  sel_bank,     // SELECT (0x30)
    output reg  [1:0]  boot_mode,    // BOOTMODE (0x36)
    output reg  [15:0] lock_mask     // locked-bank bitmask (boot+recovery default)
);
    // ---- line sync + edge / start-stop detect --------------------------------
    reg [2:0] sda_ss = 3'b111, scl_ss = 3'b111;
    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin sda_ss <= 3'b111; scl_ss <= 3'b111; end
        else        begin sda_ss <= {sda_ss[1:0], sda_in}; scl_ss <= {scl_ss[1:0], scl_in}; end
    end
    wire sda_q    = sda_ss[2];
    wire scl_q    = scl_ss[2];
    wire scl_rise = (scl_ss[2:1] == 2'b01);
    wire scl_fall = (scl_ss[2:1] == 2'b10);
    wire start_c  = scl_q & (sda_ss[2:1] == 2'b10);   // SDA falls while SCL high
    wire stop_c   = scl_q & (sda_ss[2:1] == 2'b01);   // SDA rises while SCL high

    // ===== update command engine state ==========================================
    localparam [3:0] R_LOADER = 4'h1, R_XBDIAG = 4'h2, R_BANK = 4'h3;
    localparam [3:0] LOADER_BANK = 4'hE, XBDIAG_BANK = 4'hD;   // full-image commit targets (base 0 / slot1)
    localparam [15:0] LOCK_DEFAULT = 16'h0402;                 // boot(1)+recovery(10) locked
    reg        armed, crc_set, staged_valid, err_flag, eng_busy, commit_ok;
    reg [3:0]  armed_region;
    reg [20:0] image_len;
    reg [31:0] expected_crc;
    reg        val_wait, com_wait;
    wire [12:0] len_pages = image_len[20:8] + {12'b0, (|image_len[7:0])};

    // ---- register read mux ---------------------------------------------------
    function [7:0] readmux; input [7:0] i; begin
        case (i)
            8'h00:   readmux = MAGIC;
            8'h01:   readmux = VER_MAJOR;
            8'h02:   readmux = VER_MINOR;
            8'h03:   readmux = VER_PATCH;
            8'h04:   readmux = status_in;
            8'h10:   readmux = cmd;
            8'h11:   readmux = arg0;
            8'h12:   readmux = arg1;
            8'h13:   readmux = arg2;
            8'h14:   readmux = arg3;
            8'h05:   readmux = {2'b0, commit_ok, err_flag, eng_busy, staged_valid, crc_set, armed};
            8'h06:   readmux = {commit_bank, armed_region};
            8'h07:   readmux = crc_result[7:0];
            8'h08:   readmux = crc_result[15:8];
            8'h09:   readmux = crc_result[23:16];
            8'h0A:   readmux = crc_result[31:24];
            8'h0B:   readmux = lock_mask[7:0];
            8'h0C:   readmux = lock_mask[15:8];
            default: readmux = 8'h00;
        endcase
    end endfunction

    reg [7:0] index = 8'd0;                       // register pointer
    wire [7:0] rd_cur = readmux(index);           // data at the current index
    wire [7:0] rd_nxt = readmux(index + 8'd1);    // data at the next index

    // ---- slave FSM -----------------------------------------------------------
    localparam ST_IDLE = 3'd0,
               ST_ADDR = 3'd1,
               ST_AACK = 3'd2,
               ST_WR   = 3'd3,
               ST_WACK = 3'd4,
               ST_RD   = 3'd5,
               ST_RACK = 3'd6;

    reg [2:0] st     = ST_IDLE;
    reg [2:0] bcnt   = 3'd0;
    reg [7:0] sh     = 8'd0;
    reg       rw     = 1'b0;
    reg       idxset = 1'b0;
    reg       acked  = 1'b0;

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            st<=ST_IDLE; bcnt<=0; sh<=0; rw<=0; index<=0; idxset<=0; acked<=0;
            sda_oe<=0; selected<=0; cmd_stb<=0; rx_count<=0;
            cmd<=0; arg0<=0; arg1<=0; arg2<=0; arg3<=0;
        end else begin
            cmd_stb <= 1'b0;

            if (start_c) begin
                st<=ST_ADDR; bcnt<=0; sh<=0; acked<=0; sda_oe<=0;
            end
            else if (stop_c) begin
                st<=ST_IDLE; sda_oe<=0; selected<=0; idxset<=0; acked<=0;
            end
            else begin
                case (st)
                ST_ADDR: if (scl_rise) begin
                    sh <= {sh[6:0], sda_q};
                    if (bcnt==3'd7) begin st<=ST_AACK; bcnt<=0; acked<=0; end
                    else bcnt <= bcnt + 3'd1;
                end

                ST_AACK: if (scl_fall) begin
                    if (!acked) begin
                        if (sh[7:1]==DEV_ADDR) begin
                            sda_oe<=1'b1;
                            selected<=1'b1; rw<=sh[0];
                            if (!sh[0]) rx_count<=rx_count+8'd1;
                        end else begin
                            sda_oe<=1'b0; st<=ST_IDLE; selected<=1'b0;
                        end
                        acked<=1'b1;
                    end else begin
                        acked<=1'b0;
                        if (rw) begin
                            sh<=rd_cur; sda_oe<=~rd_cur[7];
                            st<=ST_RD; bcnt<=0;
                        end else begin
                            sda_oe<=1'b0; st<=ST_WR; bcnt<=0;
                        end
                    end
                end

                ST_WR: if (scl_rise) begin
                    sh <= {sh[6:0], sda_q};
                    if (bcnt==3'd7) begin st<=ST_WACK; bcnt<=0; acked<=0; end
                    else bcnt <= bcnt + 3'd1;
                end

                ST_WACK: if (scl_fall) begin
                    if (!acked) begin
                        sda_oe<=1'b1;
                        if (!idxset) begin index<=sh; idxset<=1'b1; end
                        else begin
                            case (index)
                                8'h10: begin cmd<=sh; cmd_stb<=1'b1; end
                                8'h11: arg0<=sh;
                                8'h12: arg1<=sh;
                                8'h13: arg2<=sh;
                                8'h14: arg3<=sh;
                                default: ;
                            endcase
                            index<=index+8'd1;
                        end
                        acked<=1'b1;
                    end else begin
                        acked<=1'b0; sda_oe<=1'b0; st<=ST_WR; bcnt<=0;
                    end
                end

                ST_RD: if (scl_fall) begin
                    if (bcnt==3'd7) begin
                        sda_oe<=1'b0;
                        st<=ST_RACK; bcnt<=0; acked<=0;
                    end else begin
                        bcnt<=bcnt+3'd1;
                        sda_oe<=~sh[6-bcnt];
                    end
                end

                ST_RACK: begin
                    if (scl_rise) begin
                        if (sda_q) selected<=1'b0;
                    end
                    if (scl_fall) begin
                        if (!acked) acked<=1'b1;
                        else begin
                            acked<=1'b0;
                            if (selected) begin
                                index<=index+8'd1;
                                sh<=rd_nxt; sda_oe<=~rd_nxt[7];
                                st<=ST_RD; bcnt<=0;
                            end else begin
                                sda_oe<=1'b0; st<=ST_IDLE;
                            end
                        end
                    end
                end

                default: st<=ST_IDLE;
                endcase
            end
        end
    end
    // =======================================================================
    // Update command engine -- the single auditable gate. Acts on cmd_stb; all
    // enforcement lives here and only DERIVED targets reach the engines below.
    //   region-lock : armed_region latched at ARM; every op's high nibble must
    //                 match or it is refused (a region-1 tool cannot commit a
    //                 region-3 bank).
    //   validate    : COMMIT refused unless staged_valid (whole-image CRC == the
    //                 host's SETCRC value).
    //   locked      : a region-3 COMMIT to a lock_mask bank is refused.
    // =======================================================================
    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            armed<=1'b0; armed_region<=4'd0; image_len<=21'd0; expected_crc<=32'd0;
            crc_set<=1'b0; staged_valid<=1'b0; err_flag<=1'b0; eng_busy<=1'b0;
            commit_ok<=1'b0; val_wait<=1'b0; com_wait<=1'b0;
            crc_go<=1'b0; crc_len<=21'd0; commit_go<=1'b0; commit_bank<=4'd0;
            commit_pages<=13'd0; scr_clear<=1'b0; sel_bank<=4'd0; boot_mode<=2'd0;
            lock_mask<=LOCK_DEFAULT;
        end else begin
            crc_go    <= 1'b0;
            commit_go <= 1'b0;
            scr_clear <= 1'b0;

            if (cmd_stb) begin
                if (cmd == 8'h01) begin
                    // PING -- liveness, no state change
                end else if (cmd == 8'h02 || cmd == 8'h03) begin
                    // ABORT / CLEAR -- disarm + invalidate (logical flush). A later
                    // op must re-ARM + re-stage + re-VALIDATE, so no stale image can
                    // commit. scr_clear pulses for an optional physical wipe.
                    armed<=1'b0; armed_region<=4'd0; crc_set<=1'b0; staged_valid<=1'b0;
                    image_len<=21'd0; eng_busy<=1'b0; err_flag<=1'b0; scr_clear<=1'b1;
                end else if (cmd == 8'h30) begin
                    sel_bank <= arg0[3:0];                    // SELECT
                end else if (cmd == 8'h36) begin
                    boot_mode <= arg0[1:0];                   // BOOTMODE
                end else if (cmd == 8'h37) begin
                    lock_mask[arg0[3:0]] <= arg1[0];          // SETLOCK
                end else begin
                    case (cmd[3:0])
                        4'h0: begin                           // ARM
                            armed<=1'b1; armed_region<=cmd[7:4];
                            crc_set<=1'b0; staged_valid<=1'b0; commit_ok<=1'b0; err_flag<=1'b0;
                            if (cmd[7:4]==R_BANK) begin
                                commit_bank<=arg0[3:0];
                                image_len<={arg3[4:0], arg2, arg1};
                            end else begin
                                commit_bank<=(cmd[7:4]==R_LOADER)?LOADER_BANK:XBDIAG_BANK;
                                image_len<={arg2[4:0], arg1, arg0};
                            end
                        end
                        4'h1: begin                           // SETCRC
                            if (armed && cmd[7:4]==armed_region) begin
                                expected_crc<={arg3,arg2,arg1,arg0}; crc_set<=1'b1; err_flag<=1'b0;
                            end else err_flag<=1'b1;
                        end
                        4'h3: begin                           // VALIDATE
                            if (armed && crc_set && cmd[7:4]==armed_region && !eng_busy) begin
                                crc_go<=1'b1; crc_len<=image_len;
                                eng_busy<=1'b1; val_wait<=1'b1; staged_valid<=1'b0; err_flag<=1'b0;
                            end else err_flag<=1'b1;
                        end
                        4'h4: begin                           // COMMIT
                            if (staged_valid && cmd[7:4]==armed_region && !eng_busy &&
                                !(armed_region==R_BANK && lock_mask[commit_bank])) begin
                                commit_go<=1'b1; commit_pages<=len_pages;
                                eng_busy<=1'b1; com_wait<=1'b1; err_flag<=1'b0;
                            end else err_flag<=1'b1;
                        end
                        default: ; // ACTIVATE(_5)/PRESENT -> reserved (no-op)
                    endcase
                end
            end

            // ---- async completions ----
            if (val_wait && crc_done) begin
                val_wait<=1'b0; eng_busy<=1'b0;
                if (crc_result==expected_crc) staged_valid<=1'b1;
                else begin staged_valid<=1'b0; err_flag<=1'b1; end
            end
            if (com_wait && commit_done) begin
                com_wait<=1'b0; eng_busy<=1'b0;
                if (commit_err) err_flag<=1'b1; else commit_ok<=1'b1;
            end
        end
    end

endmodule