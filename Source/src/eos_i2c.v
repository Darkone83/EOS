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
// DUAL-ADDRESS (added for HD/X-HD, see eos_hd_integration_spec.md): this
// engine also answers HD_ADDR (0x69) -- but ONLY once hd_addr_en is raised
// (eos_hd.v's collision guard must clear FIRST; the address doesn't come
// live at reset). The bit-level protocol (START/STOP/ACK/clock-stretch) is
// entirely shared between the two personas; ONLY the byte-level MEANING
// differs. Deliberately kept that way: eos_i2c.v stays a dumb transport for
// HD traffic (relay bytes in via hd_byte/hd_byte_valid, take response bytes
// from hd_read_data) -- it does NOT interpret a single HD command byte
// itself. All HD protocol semantics (READ_CONFIG, WRITE_CONFIG_APPLY, etc.)
// live entirely in eos_hd.v, same as HD status stays entirely in eos_hd.v.
// The updater persona (DEV_ADDR, 0x6E) below is completely unmodified by
// this -- every existing register/command/state-machine path for it is
// untouched; the HD paths are new parallel branches, not edits to it.
//
// Register map (read side, DEV_ADDR/updater persona only):
//   0x00 MAGIC      (R) 0xD8   Darkone signature
//   0x01 VER_MAJOR  (R) 1
//   0x02 VER_MINOR  (R) 0
//   0x03 VER_PATCH  (R) 3      -> base firmware 1.0.3
//   0x04 STATUS     (R) live bits from the top, low->high:
//                       preload_done, mode_16, d0_active, abort_active,
//                       slot1_ready; top 3 bits 0.
//   0x05 ENGINE     (R) update-engine flags: armed, staged_valid, crc_set,
//                       eng_busy, err_flag, commit_ok
//   0x06 COMMIT     (R) {commit_bank[3:0], armed_region[3:0]}
//   0x07..0x0A CRC32 (R) streaming CRC-32 result, low byte first
//   0x0B..0x0C LOCK  (R) lock-mask, low byte first (default 0x0402)
//   0x10 CMD        (R) reads back the last opcode
//   0x11..0x14 ARG0..3 (R) read back the last command args
//
// Command opcodes (write to 0x10, args in 0x11..0x14):
//   0x01 PING              liveness, no state change
//   0x02 / 0x03 ABORT/CLEAR disarm + invalidate the staged image
//   0x38 LEDMODE          arg0: 0 normal, 1 rainbow
//   0x39 DESCRELOAD       re-read the descriptor block
//   0x3A SETBANKCOLOR     arg0=bank(1..4) arg1=R arg2=G arg3=B -> stage a color,
//                         pulse set_color_stb (top commits to the LEDCFG block)
//   0xN0/0xN1/0xN4 ARM/SETCRC/COMMIT  update flow for region N
//                       (region 1 = loader, 2 = XbDiag)
//
// KNOWN OPCODE ISSUES (see the firmware README's Active Notes):
//   * SELECT (0x30), BOOTMODE (0x36), SETLOCK (0x37) latch cleanly but their
//     outputs are not consumed by anything on the FPGA yet.
//   * SELECT (0x30) is decoded before the generic ARM case, so ARM for an
//     arbitrary bank (region 3 -> opcode 0x30) can never run. The updater only
//     arms regions 1 and 2, so this does not affect it.
//
// SDA is open-drain: sda_oe=1 pulls the line LOW, sda_oe=0 releases (Hi-Z). SCL
// is input for the updater persona (never stretches -- its reads are always
// immediately available). scl_oe (new) lets the HD persona stretch: held low
// only when hd_addr_match && !hd_read_ready, so the updater path's timing is
// completely unaffected. Runs on a fast sample clock (>= ~16x SCL; the
// serve/sys clock is fine).
// =====================================================================
module eos_i2c #(
    parameter [6:0] DEV_ADDR  = 7'h6E,     // 7-bit SMBus address the scanner sees (0x6E; 0x6F alt)
    parameter [6:0] HD_ADDR   = 7'h69,     // HD/X-HD address -- see dual-address note above
    parameter [7:0] MAGIC     = 8'hD8,     // Darkone signature
    parameter [7:0] VER_MAJOR = 8'd1,
    parameter [7:0] VER_MINOR = 8'd0,
    parameter [7:0] VER_PATCH = 8'd4
)(
    input  wire        clk,
    input  wire        resetn,

    input  wire        sda_in,
    input  wire        scl_in,
    output reg         sda_oe,       // 1 = pull SDA low, 0 = release
    output reg         scl_oe,       // 1 = pull SCL low (HD clock-stretch only)

    input  wire [7:0]  status_in,    // reported at register 0x04

    // ---- HD relay interface (see dual-address note above) ----------------
    input  wire         hd_addr_en,     // gate: HD_ADDR only answers once this is 1
    output reg           hd_addr_match, // 1 while an HD-addressed transaction owns the bus
    output reg            hd_byte_valid, // 1-cycle strobe: hd_byte just arrived (write dir)
    output reg  [7:0]      hd_byte,
    output reg              hd_byte_first, // 1 = this is the transaction's command byte
    input  wire [7:0]        hd_read_data,  // byte to return on a read turnaround
    input  wire                hd_read_ready, // 0 = stretch SCL and wait; 1 = proceed

    // Version, exposed as real outputs (not just readmux'd internally) so
    // anything else on the FPGA -- the serve HUD, in particular -- has ONE
    // true source instead of a second hardcoded copy that can silently drift
    // out of sync with this one (which is exactly what had happened: the HUD
    // instantiation hardcoded 1.0.0 as literals, untouched by any version
    // bump made here). Purely combinational, always valid.
    output wire [7:0]  ver_major_out,
    output wire [7:0]  ver_minor_out,
    output wire [7:0]  ver_patch_out,

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
    output reg  [15:0] lock_mask,    // locked-bank bitmask (boot+recovery default)
    output reg  [1:0]  led_mode,     // LEDMODE (0x38): 0=normal, 1=rainbow
    output reg         desc_reload,  // DESCRELOAD (0x39): 1-clk pulse -> FPGA re-reads descriptor
    output reg  [2:0]  set_color_bank, // SETBANKCOLOR (0x3A): target bank 1..4
    output reg  [23:0] set_color_rgb,  // packed {R,G,B}
    output reg         set_color_stb,  // 1-clk pulse when 0x3A is issued
    // ---- EXP expansion mailbox (regs 0x40-0x6F -> eos_exp_mailbox, top-level wire) ----
    output wire [7:0]  mbx_rd_index,   // = current read command (rcmd)
    input  wire [7:0]  mbx_rd_data,    // mailbox's combinational read data for rd_index
    output reg         mbx_wr_stb,     // 1-clk pulse on a 0x40-0x6F write
    output reg  [7:0]  mbx_wr_index,   // = wsub (0x40-0x6F)
    output reg  [7:0]  mbx_wr_data     // = written byte
);
    assign ver_major_out = VER_MAJOR;
    assign ver_minor_out = VER_MINOR;
    assign ver_patch_out = VER_PATCH;

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

    // Command-decode model: the first write byte of a transaction is the
    // command; a read transaction then returns readmux(command) as ITS single
    // response byte. No shared/persistent index across transactions -- rcmd is
    // latched per-transaction and the response is that command's byte. This is
    // what removes the readback race / version-misread on the contended bus.
    reg  [7:0] rcmd    = 8'h00;                    // command for THIS transaction
    reg        have_cmd= 1'b0;                     // command byte captured?
    assign     mbx_rd_index = rcmd;               // mailbox read pointer follows the transaction command
    wire [7:0] rd_cur  = (rcmd>=8'h40 && rcmd<=8'h6F) ? mbx_rd_data
                                                      : readmux(rcmd);   // 0x40-0x6F -> EXP mailbox
    wire [7:0] resp_byte = hd_addr_match ? hd_read_data : rd_cur;  // whichever persona is live

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
    reg [7:0] wsub   = 8'h00;   // write sub-pointer within a block write
    reg [7:0] sh     = 8'd0;
    reg       rw     = 1'b0;
    reg       acked  = 1'b0;
    reg       hd_first_pending = 1'b0;  // internal: primed by ST_AACK, captured
                                       // into hd_byte_first on relay (not cleared
                                       // directly -- see ST_WACK)
    reg       hd_stretching = 1'b0;   // frozen here (SCL held low by us) until
                                       // hd_read_ready -- see the top-priority
                                       // branch below. No scl_rise/scl_fall will
                                       // fire while this is set (we're the ones
                                       // holding the line low), so this can't be
                                       // driven from the normal edge-gated case
                                       // logic -- it has to be checked every cycle.

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            st<=ST_IDLE; bcnt<=0; sh<=0; rw<=0; rcmd<=8'h00; have_cmd<=1'b0; acked<=0;
            mbx_wr_stb<=1'b0; mbx_wr_index<=8'h00; mbx_wr_data<=8'h00;
            sda_oe<=0; scl_oe<=0; selected<=0; cmd_stb<=0; rx_count<=0;
            cmd<=0; arg0<=0; arg1<=0; arg2<=0; arg3<=0;
            hd_addr_match<=0; hd_byte_valid<=0; hd_byte<=0; hd_byte_first<=0;
            hd_first_pending<=0; hd_stretching<=0;
        end else begin
            cmd_stb <= 1'b0;
            mbx_wr_stb <= 1'b0;   // 1-cycle strobe, default low
            hd_byte_valid <= 1'b0;   // 1-cycle strobe, default low every cycle

            if (hd_stretching) begin
                // Top priority, bypasses everything else below. We are
                // physically holding SCL low (scl_oe=1) so the master cannot
                // progress the bus at all from here -- no START, no STOP, no
                // more clock edges -- until we release it. Just poll.
                if (hd_read_ready) begin
                    hd_stretching<=1'b0; scl_oe<=1'b0;
                    sh<=hd_read_data; sda_oe<=~hd_read_data[7];
                    st<=ST_RD; bcnt<=0;
                end
                // else: keep holding, nothing else to do this cycle.
            end
            else if (start_c) begin
                st<=ST_ADDR; bcnt<=0; sh<=0; acked<=0; sda_oe<=0;
            end
            else if (stop_c) begin
                st<=ST_IDLE; sda_oe<=0; selected<=0; hd_addr_match<=0;
                have_cmd<=1'b0; acked<=0;
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
                            selected<=1'b1; hd_addr_match<=1'b0; rw<=sh[0];
                            // On an addr+WRITE match, the byte that follows is
                            // ALWAYS this transaction's command/register selector.
                            // Clear have_cmd HERE (keyed off the cleanly-clocked
                            // address byte, not a START/STOP edge that the sync
                            // stage can miss) so the command latch can never stick
                            // across transactions -- the failure that made every
                            // register read return the same value (e.g. 1.1.1).
                            // A read-byte's addr+READ turnaround does NOT clear it,
                            // so rcmd from the preceding write phase is preserved.
                            if (!sh[0]) begin rx_count<=rx_count+8'd1; have_cmd<=1'b0; end
                        end else if (hd_addr_en && sh[7:1]==HD_ADDR) begin
                            // HD persona -- see the dual-address note at the top
                            // of this file. 'selected' is deliberately NOT set
                            // here; hd_addr_match is the HD equivalent of it, and
                            // the two personas are never both live in the same
                            // transaction (a single address byte matches at most
                            // one of them).
                            sda_oe<=1'b1;
                            hd_addr_match<=1'b1; rw<=sh[0];
                            if (!sh[0]) hd_first_pending<=1'b1;  // next write byte is HD's command byte
                        end else begin
                            sda_oe<=1'b0; st<=ST_IDLE; selected<=1'b0; hd_addr_match<=1'b0;
                        end
                        acked<=1'b1;
                    end else begin
                        acked<=1'b0;
                        if (rw) begin
                            if (hd_addr_match && !hd_read_ready) begin
                                scl_oe<=1'b1; hd_stretching<=1'b1;  // not ready yet -- stretch
                            end else begin
                                sh    <= resp_byte;
                                sda_oe<= ~resp_byte[7];
                                st<=ST_RD; bcnt<=0;
                            end
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
                        sda_oe<=1'b1;                     // ACK the byte
                        if (hd_addr_match) begin
                            // Dumb relay only -- eos_hd.v owns all HD protocol
                            // meaning. hd_first_pending was primed in ST_AACK for
                            // byte 0 of this transaction; CAPTURE it into
                            // hd_byte_first here (not clear it directly -- that
                            // would stomp the very value this byte needs to
                            // output, since both would land on the same edge)
                            // and only THEN clear the pending latch for the
                            // byte after this one.
                            hd_byte_valid<=1'b1; hd_byte<=sh;
                            hd_byte_first<=hd_first_pending; hd_first_pending<=1'b0;
                        end else if (!have_cmd) begin
                            // FIRST write byte = command/register selector for
                            // this transaction. Latch it; a following read will
                            // return readmux(rcmd). For a write transaction, the
                            // subsequent data bytes land in the arg/cmd file via
                            // wsub below. have_cmd resets on STOP so nothing is
                            // carried across transactions.
                            rcmd     <= sh;
                            have_cmd <= 1'b1;
                            wsub     <= sh;              // write sub-pointer starts at cmd code
                        end else begin
                            // subsequent write bytes: register file, addressed by
                            // wsub which auto-advances WITHIN this one transaction
                            // (block write of CMD + ARGs), then STOP clears it.
                            case (wsub)
                                8'h10: begin cmd<=sh; cmd_stb<=1'b1; end
                                8'h11: arg0<=sh;
                                8'h12: arg1<=sh;
                                8'h13: arg2<=sh;
                                8'h14: arg3<=sh;
                                default: if (wsub>=8'h40 && wsub<=8'h6F) begin  // EXP mailbox window
                                    mbx_wr_stb<=1'b1; mbx_wr_index<=wsub; mbx_wr_data<=sh;
                                end
                            endcase
                            wsub <= wsub + 8'd1;
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
                        // master NACK = last byte, for whichever persona is live
                        if (sda_q) begin selected<=1'b0; hd_addr_match<=1'b0; end
                    end
                    if (scl_fall) begin
                        if (!acked) acked<=1'b1;
                        else begin
                            acked<=1'b0;
                            // Single-byte-per-command model. If the master ACKs
                            // for another byte, return the SAME command's byte
                            // again (no stale index walk). Normally it NACKs and
                            // we go idle. HD mirrors this, through the same
                            // stretch path if a second byte isn't ready yet.
                            if (selected) begin
                                sh<=rd_cur; sda_oe<=~rd_cur[7];
                                st<=ST_RD; bcnt<=0;
                            end else if (hd_addr_match) begin
                                if (hd_read_ready) begin
                                    sh<=hd_read_data; sda_oe<=~hd_read_data[7];
                                    st<=ST_RD; bcnt<=0;
                                end else begin
                                    scl_oe<=1'b1; hd_stretching<=1'b1;
                                end
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
            lock_mask<=LOCK_DEFAULT; led_mode<=2'd0; desc_reload<=1'b0;
            set_color_bank<=3'd0; set_color_rgb<=24'd0; set_color_stb<=1'b0;
        end else begin
            crc_go    <= 1'b0;
            commit_go <= 1'b0;
            scr_clear <= 1'b0;
            desc_reload <= 1'b0;
            set_color_stb <= 1'b0;

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
                end else if (cmd == 8'h38) begin
                    led_mode <= arg0[1:0];                    // LEDMODE (0=normal,1=rainbow)
                end else if (cmd == 8'h39) begin
                    desc_reload <= 1'b1;                      // DESCRELOAD: pulse re-read
                end else if (cmd == 8'h3A) begin
                    // SETBANKCOLOR: stage bank+RGB and pulse. Only banks 1..4 are
                    // user-colorable; other values are ignored by the consumer.
                    set_color_bank <= arg0[2:0];
                    set_color_rgb  <= {arg1, arg2, arg3};     // R,G,B
                    set_color_stb  <= 1'b1;
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