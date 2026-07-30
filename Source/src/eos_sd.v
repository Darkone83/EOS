// eos_sd_spi.v -- raw microSD block reader, SD SPI mode (mode 0), bit-banged.
// Piece 1 of the SD support spec (eos_sd_support_spec.md): "raw SD access."
// This module ONLY does card bring-up + 512-byte block reads. It knows nothing
// about FAT, BIOS images, or the ext-region SDRAM precache -- that sequencer is
// a separate piece (loader-triggered, touches eos_sdram_backend.v / flash_cmd)
// and is intentionally NOT in this file.
//
// Ports on the onboard microSD slot (Tang Nano 20K), per board schematic:
//   card_sck  -> PIN83 SDIO_CLK
//   card_mosi -> PIN82 SDIO_CMD
//   card_miso <- PIN84 SDIO_D0
//   card_cs_n -> PIN81 SDIO_D3   (D3 doubles as SPI-mode CS; D1/D2 unused,
//                                 leave as plain inputs with PULL_MODE=UP in
//                                 the .cst -- the card expects them idle-high)
// Deliberately named card_* (NOT sd_*) -- eos_sdram_backend.v already uses
// sd_busy/sd_refresh/NRGN_SD for the unrelated SDRAM refresh state machine.
// Reusing "sd_" here would be a real collision risk reading that file later.
//
// Card support: modern SD v2 cards only (SDHC/SDXC, block-addressed), which is
// what any current microSD card identifies as. CMD8 is required to succeed;
// if a card doesn't answer CMD8 (pre-2006 SDSC) this module reports card_err
// and stops -- no legacy byte-addressed fallback in this first cut.
// No CRC checking in either direction (SPI-mode default: CRC off). This is a
// raw reader, not a filesystem or integrity layer -- acceptable for a BIOS
// image precache read off a card that was just written moments earlier by the
// same user; revisit if corruption is ever actually observed on hardware.
//
// Clocking: this module's 'clk' is expected to be the existing 64.8 MHz sclk
// domain (see eos_sdram_pll.v). SCK_DIV_INIT/SCK_DIV_FAST below assume that;
// retune if fed from elsewhere. SD spec requires <=400 kHz during card
// identification (power-up through ACMD41/CMD58) -- SCK_DIV_INIT=83 gives
// 64.8MHz/(2*83) = 390 kHz. After bring-up the module switches itself to
// SCK_DIV_FAST=2 -> 16.2 MHz for block reads (comfortably inside the ~20-25
// MHz most SD cards accept in default speed SPI mode).

module eos_sd_spi #(
    parameter integer SCK_DIV_INIT = 83,   // ~390 kHz during identification
    parameter integer SCK_DIV_FAST = 2,    // ~16.2 MHz for block reads
    parameter integer POLL_TIMEOUT = 24'h3FFFFF // shared poll/token timeout (cycles of the byte engine)
)(
    input  wire        clk,
    input  wire        rstn,

    // ---- command interface ----
    input  wire        start,        // pulse: begin a single-block read at 'lba'
    input  wire [31:0]  lba,          // 512-byte block/sector number
    output reg         busy,
    output reg         done,         // one-cycle pulse, block complete (see card_err for status)
    output reg         dvalid,       // one-cycle pulse alongside dout, 512 per block
    output reg  [7:0]  dout,

    // ---- status ----
    output reg         card_ready,   // init complete, card accepted, reads may be issued
    output reg         card_err,     // init failed OR last read failed -- see err_code
    output reg  [3:0]  err_code,     // 0=none 1=cmd0 2=cmd8 3=acmd41_timeout 4=cmd58
                                     // 5=cmd16 6=cmd17(R1) 7=token_timeout 8=legacy_card

    // ---- physical SPI pins ----
    output reg         card_sck,
    output reg         card_mosi,
    input  wire        card_miso,
    output reg         card_cs_n
);

    // =========================================================================
    // Byte engine -- full-duplex, 8 bits, MSB first, SPI mode 0 (idle clk low,
    // sample MISO on the rising edge / drive MOSI on the falling edge -- same
    // convention as eos_flash_reader.v's CMD/DATA states).
    // Call it by loading tx_byte + byte_go<=1; it raises byte_done for one
    // cycle when rx_byte is valid. The outer FSM below drives byte_go and reads
    // byte_done combinationally against its own state, so no handshake races.
    // =========================================================================
    reg [7:0]  tx_byte;
    reg        byte_go;
    wire [7:0] rx_byte;
    reg        byte_done_r;          // one-cycle pulse: rx_byte valid, engine idle again

    reg [7:0]  sh_tx;
    reg [7:0]  sh_rx;
    reg [2:0]  bbit;
    reg [15:0] bpc;
    reg [7:0]  sck_div;               // runtime divider (init-slow, then fast)
    wire       bperiod_last = (bpc == (16'd2*sck_div - 16'd1));
    wire       bsck_lvl     = (bpc >= sck_div);
    reg        b_busy;

    assign rx_byte = sh_rx;

    localparam B_IDLE = 1'b0, B_RUN = 1'b1;
    reg b_state;

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            b_state <= B_IDLE; b_busy <= 1'b0; bpc <= 16'd0; bbit <= 3'd0;
            card_sck <= 1'b0; card_mosi <= 1'b1; byte_done_r <= 1'b0;
            sh_tx <= 8'hFF; sh_rx <= 8'h00;
        end else begin
            byte_done_r <= 1'b0;
            case (b_state)
                B_IDLE: begin
                    card_sck <= 1'b0;
                    if (byte_go) begin
                        sh_tx <= tx_byte; bbit <= 3'd0; bpc <= 16'd0;
                        card_mosi <= tx_byte[7];
                        b_busy <= 1'b1; b_state <= B_RUN;
                    end
                end
                B_RUN: begin
                    card_sck <= bsck_lvl;
                    if (bperiod_last) begin
                        bpc <= 16'd0;
                        // sample MISO at the end of the high phase (matches
                        // eos_flash_reader's "MISO sampled at end of SCK-high")
                        sh_rx <= {sh_rx[6:0], card_miso};
                        if (bbit == 3'd7) begin
                            b_busy <= 1'b0; b_state <= B_IDLE; byte_done_r <= 1'b1;
                        end else begin
                            bbit   <= bbit + 3'd1;
                            sh_tx  <= {sh_tx[6:0], 1'b1};
                            card_mosi <= sh_tx[6];
                        end
                    end else begin
                        bpc <= bpc + 16'd1;
                    end
                end
            endcase
        end
    end

    // =========================================================================
    // Outer protocol FSM
    // =========================================================================
    localparam
        ST_RESET        = 6'd0,
        ST_PWRUP        = 6'd1,   // 10x 0xFF with CS high (>=74 clocks)
        ST_CMD0_GO      = 6'd2,
        ST_CMD0_WAIT    = 6'd3,
        ST_CMD8_GO      = 6'd4,
        ST_CMD8_WAIT    = 6'd5,
        ST_CMD8_R7      = 6'd6,
        ST_ACMD_CMD55   = 6'd7,
        ST_ACMD_CMD55W  = 6'd8,
        ST_ACMD41       = 6'd9,
        ST_ACMD41_WAIT  = 6'd10,
        ST_CMD58_GO     = 6'd11,
        ST_CMD58_WAIT   = 6'd12,
        ST_CMD58_OCR    = 6'd13,
        ST_INIT_DONE    = 6'd14,
        ST_READY        = 6'd15,
        ST_RD_CMD17     = 6'd16,
        ST_RD_CMD17W    = 6'd17,
        ST_RD_TOKEN     = 6'd18,
        ST_RD_DATA      = 6'd19,
        ST_RD_CRC       = 6'd20,
        ST_RD_DONE      = 6'd21,
        ST_SEND_CMD     = 6'd30,  // shared subroutine: clock out cmdbuf[0..5]
        ST_POLL_R1      = 6'd31,  // shared subroutine: clock 0xFF until MSB=0
        ST_READ_BYTES   = 6'd32,  // shared subroutine: clock 'nbytes' of 0xFF, capturing each
        ST_ERROR        = 6'd63;

    reg [5:0]  st, ret_st, ret_st2;
    reg [7:0]  cmdbuf [0:5];
    reg [2:0]  cmdidx;
    reg [23:0] wait_ctr;
    reg [9:0]  byte_cnt;             // general-purpose remaining-byte counter
    reg [7:0]  r1;                   // last R1 response
    reg [31:0] r7_ocr;               // scratch for R7 echo / OCR capture
    reg        card_hc;              // 1 = SDHC/SDXC (block addr), 0 = SDSC (byte addr)
    reg [31:0] cur_lba;

    task automatic load_cmd(input [7:0] idx, input [31:0] arg, input [7:0] crc);
        begin
            cmdbuf[0] = {2'b01, idx[5:0]};
            cmdbuf[1] = arg[31:24];
            cmdbuf[2] = arg[23:16];
            cmdbuf[3] = arg[15:8];
            cmdbuf[4] = arg[7:0];
            cmdbuf[5] = crc;
        end
    endtask

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            st <= ST_RESET; busy <= 1'b0; done <= 1'b0; dvalid <= 1'b0; dout <= 8'h00;
            card_ready <= 1'b0; card_err <= 1'b0; err_code <= 4'd0;
            card_cs_n <= 1'b1; byte_go <= 1'b0; sck_div <= SCK_DIV_INIT[7:0];
            card_hc <= 1'b0; cmdidx <= 3'd0; wait_ctr <= 24'd0; byte_cnt <= 10'd0;
        end else begin
            done <= 1'b0; dvalid <= 1'b0; byte_go <= 1'b0;

            case (st)
                // ---------------- power-up ----------------
                ST_RESET: begin
                    card_cs_n <= 1'b1; sck_div <= SCK_DIV_INIT[7:0];
                    byte_cnt <= 10'd10; st <= ST_PWRUP;
                end
                ST_PWRUP: begin
                    if (!byte_go && !b_busy && !byte_done_r) begin
                        tx_byte <= 8'hFF; byte_go <= 1'b1;
                    end
                    if (byte_done_r) begin
                        if (byte_cnt == 10'd1) begin
                            card_cs_n <= 1'b0;             // now select the card
                            load_cmd(8'd0, 32'h0, 8'h95);   // CMD0, fixed CRC
                            cmdidx <= 3'd0; ret_st <= ST_CMD0_WAIT; st <= ST_SEND_CMD;
                        end else byte_cnt <= byte_cnt - 10'd1;
                    end
                end

                // ---------------- CMD0: GO_IDLE_STATE ----------------
                ST_CMD0_WAIT: begin
                    wait_ctr <= 24'd0; ret_st2 <= ST_CMD8_GO; st <= ST_POLL_R1;
                end
                ST_CMD8_GO: begin
                    if (r1 != 8'h01) begin err_code <= 4'd1; st <= ST_ERROR; end
                    else begin
                        load_cmd(8'd8, 32'h0000_01AA, 8'h87);  // CMD8, fixed CRC
                        cmdidx <= 3'd0; ret_st <= ST_CMD8_WAIT; st <= ST_SEND_CMD;
                    end
                end

                // ---------------- CMD8: SEND_IF_COND ----------------
                ST_CMD8_WAIT: begin
                    wait_ctr <= 24'd0; ret_st2 <= ST_CMD8_R7; st <= ST_POLL_R1;
                end
                ST_CMD8_R7: begin
                    if (r1[2]) begin
                        // illegal command -- pre-CMD8 (legacy) card, unsupported here
                        err_code <= 4'd8; st <= ST_ERROR;
                    end else if (r1 != 8'h01) begin
                        err_code <= 4'd2; st <= ST_ERROR;
                    end else begin
                        byte_cnt <= 10'd4; ret_st <= ST_ACMD_CMD55; st <= ST_READ_BYTES;
                    end
                end

                // ---------------- ACMD41 loop (CMD55 + CMD41, HCS=1) --------
                ST_ACMD_CMD55: begin
                    if (r7_ocr[11:0] != 12'h1AA) begin
                        err_code <= 4'd2; st <= ST_ERROR;   // voltage/pattern mismatch
                    end else begin
                        load_cmd(8'd55, 32'h0, 8'h01);
                        cmdidx <= 3'd0; ret_st <= ST_ACMD_CMD55W; st <= ST_SEND_CMD;
                        wait_ctr <= 24'd0;
                    end
                end
                ST_ACMD_CMD55W: begin
                    ret_st2 <= ST_ACMD41; st <= ST_POLL_R1;
                end
                ST_ACMD41: begin
                    load_cmd(8'd41, 32'h4000_0000, 8'h01);   // HCS=1 (request SDHC/SDXC)
                    cmdidx <= 3'd0; ret_st <= ST_ACMD41_WAIT; st <= ST_SEND_CMD;
                end
                ST_ACMD41_WAIT: begin
                    ret_st2 <= ST_CMD58_GO; st <= ST_POLL_R1;   // reuse POLL_R1 to fetch R1 into r1
                end
                ST_CMD58_GO: begin
                    if (r1 == 8'h00) begin
                        load_cmd(8'd58, 32'h0, 8'h01);
                        cmdidx <= 3'd0; ret_st <= ST_CMD58_WAIT; st <= ST_SEND_CMD;
                    end else if (r1 == 8'h01) begin
                        if (wait_ctr == POLL_TIMEOUT) begin
                            err_code <= 4'd3; st <= ST_ERROR;
                        end else begin
                            wait_ctr <= wait_ctr + 24'd1;
                            load_cmd(8'd55, 32'h0, 8'h01);
                            cmdidx <= 3'd0; ret_st <= ST_ACMD_CMD55W; st <= ST_SEND_CMD;
                        end
                    end else begin
                        err_code <= 4'd3; st <= ST_ERROR;
                    end
                end

                // ---------------- CMD58: READ_OCR (get CCS bit) --------------
                ST_CMD58_WAIT: begin
                    wait_ctr <= 24'd0; ret_st2 <= ST_CMD58_OCR; st <= ST_POLL_R1;
                end
                ST_CMD58_OCR: begin
                    if (r1 != 8'h00) begin err_code <= 4'd4; st <= ST_ERROR; end
                    else begin byte_cnt <= 10'd4; ret_st <= ST_INIT_DONE; st <= ST_READ_BYTES; end
                end

                // ---------------- bring-up complete --------------------------
                ST_INIT_DONE: begin
                    card_hc    <= r7_ocr[30];   // CCS bit
                    sck_div    <= SCK_DIV_FAST[7:0];
                    card_cs_n  <= 1'b1;
                    card_ready <= 1'b1;
                    st <= ST_READY;
                end

                // ---------------- idle, wait for a read request ---------------
                ST_READY: begin
                    card_cs_n <= 1'b1;
                    if (start) begin
                        cur_lba <= lba; card_err <= 1'b0; err_code <= 4'd0; busy <= 1'b1;
                        card_cs_n <= 1'b0;
                        st <= ST_RD_CMD17;
                    end
                end

                // ---------------- CMD17: READ_SINGLE_BLOCK -------------------
                ST_RD_CMD17: begin
                    // card_hc: address is the LBA directly. Non-HC (SDSC, legacy,
                    // not expected here but harmless to keep correct): byte address.
                    load_cmd(8'd17, card_hc ? cur_lba : (cur_lba << 9), 8'h01);
                    cmdidx <= 3'd0; ret_st <= ST_RD_CMD17W; st <= ST_SEND_CMD;
                end
                ST_RD_CMD17W: begin
                    wait_ctr <= 24'd0; ret_st2 <= ST_RD_TOKEN; st <= ST_POLL_R1;
                end
                ST_RD_TOKEN: begin
                    if (r1 != 8'h00) begin
                        err_code <= 4'd6; card_cs_n <= 1'b1; busy <= 1'b0; card_err <= 1'b1;
                        done <= 1'b1; st <= ST_READY;
                    end else if (!byte_go && !b_busy && !byte_done_r) begin
                        tx_byte <= 8'hFF; byte_go <= 1'b1;
                        wait_ctr <= wait_ctr + 24'd1;
                        if (wait_ctr == POLL_TIMEOUT) begin
                            err_code <= 4'd7; card_cs_n <= 1'b1; busy <= 1'b0; card_err <= 1'b1;
                            done <= 1'b1; st <= ST_READY;
                        end
                    end else if (byte_done_r) begin
                        if (rx_byte == 8'hFE) begin
                            byte_cnt <= 10'd512; st <= ST_RD_DATA;
                        end
                        // else: not the token yet, loop (next 0xFF issued above)
                    end
                end
                ST_RD_DATA: begin
                    if (!byte_go && !b_busy && !byte_done_r) begin
                        tx_byte <= 8'hFF; byte_go <= 1'b1;
                    end
                    if (byte_done_r) begin
                        dout <= rx_byte; dvalid <= 1'b1;
                        if (byte_cnt == 10'd1) begin byte_cnt <= 10'd2; st <= ST_RD_CRC; end
                        else byte_cnt <= byte_cnt - 10'd1;
                    end
                end
                ST_RD_CRC: begin
                    // discard 2 CRC bytes -- CRC checking not implemented (see header note)
                    if (!byte_go && !b_busy && !byte_done_r) begin
                        tx_byte <= 8'hFF; byte_go <= 1'b1;
                    end
                    if (byte_done_r) begin
                        if (byte_cnt == 10'd1) st <= ST_RD_DONE; else byte_cnt <= byte_cnt - 10'd1;
                    end
                end
                ST_RD_DONE: begin
                    card_cs_n <= 1'b1; busy <= 1'b0; done <= 1'b1; st <= ST_READY;
                end

                // =========================================================
                // shared subroutines
                // =========================================================
                ST_SEND_CMD: begin
                    if (!byte_go && !b_busy && !byte_done_r) begin
                        tx_byte <= cmdbuf[cmdidx]; byte_go <= 1'b1;
                    end
                    if (byte_done_r) begin
                        if (cmdidx == 3'd5) st <= ret_st;
                        else cmdidx <= cmdidx + 3'd1;
                    end
                end
                ST_POLL_R1: begin
                    if (!byte_go && !b_busy && !byte_done_r) begin
                        tx_byte <= 8'hFF; byte_go <= 1'b1;
                    end
                    if (byte_done_r) begin
                        if (!rx_byte[7]) begin r1 <= rx_byte; st <= ret_st2; end
                        else if (wait_ctr == POLL_TIMEOUT) begin
                            r1 <= 8'hFF; st <= ret_st2;   // let the caller's r1 check fail cleanly
                        end else wait_ctr <= wait_ctr + 24'd1;
                    end
                end
                ST_READ_BYTES: begin
                    // captures 'byte_cnt' bytes MSB-first into r7_ocr (reused for
                    // both the CMD8 R7 echo and the CMD58 OCR -- both are 4 bytes)
                    if (!byte_go && !b_busy && !byte_done_r) begin
                        tx_byte <= 8'hFF; byte_go <= 1'b1;
                    end
                    if (byte_done_r) begin
                        r7_ocr <= {r7_ocr[23:0], rx_byte};
                        if (byte_cnt == 10'd1) st <= ret_st; else byte_cnt <= byte_cnt - 10'd1;
                    end
                end

                ST_ERROR: begin
                    card_cs_n <= 1'b1; busy <= 1'b0; card_ready <= 1'b0; card_err <= 1'b1;
                end
                default: st <= ST_ERROR;
            endcase
        end
    end

endmodule