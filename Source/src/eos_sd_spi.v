// eos_sd_spi.v -- raw microSD single-block reader/writer, SPI mode 0.
//
// Existing read behavior is preserved (CMD17).  The write extension adds one
// buffered single-block command (CMD24); the caller presents the 512-byte
// sector through waddr/wdata.  No CMD18/CMD25 multi-block path is needed.
module eos_sd_spi #(
    parameter integer SCK_DIV_INIT = 83,
    parameter integer SCK_DIV_FAST = 2,
    parameter integer POLL_TIMEOUT = 24'h3FFFFF
)(
    input  wire        clk,
    input  wire        rstn,

    // single-block read
    input  wire        start,
    // single-block write
    input  wire        write_start,
    // address shared by the selected command
    input  wire [31:0] lba,

    input  wire        stall,
    output reg         busy,
    output reg         done,
    output reg         dvalid,
    output reg  [7:0]  dout,

    // write-buffer read port. waddr is valid before each data byte is launched.
    output wire [8:0]  waddr,
    input  wire [7:0]  wdata,

    output reg         card_ready,
    output reg         card_err,
    // 0 none; 1 cmd0; 2 cmd8; 3 acmd41 timeout; 4 cmd58; 5 cmd16;
    // 6 cmd17 R1; 7 read token timeout; 8 legacy card;
    // 9 cmd24 R1; 10 write rejected; 11 write-busy timeout.
    output reg  [3:0]  err_code,

    output reg         card_sck,
    output reg         card_mosi,
    input  wire        card_miso,
    output reg         card_cs_n
);
    // ---------------------------------------------------------------------
    // byte engine
    // ---------------------------------------------------------------------
    reg [7:0]  tx_byte;
    reg        byte_go;
    wire [7:0] rx_byte;
    reg        byte_done_r;
    reg [7:0]  sh_tx;
    reg [7:0]  sh_rx;
    reg [2:0]  bbit;
    reg [15:0] bpc;
    reg [7:0]  sck_div;
    wire       bperiod_last = (bpc == (16'd2*sck_div - 16'd1));
    wire       bsck_lvl     = (bpc >= sck_div);
    reg        b_busy;
    reg        b_state;
    localparam B_IDLE = 1'b0, B_RUN = 1'b1;

    assign rx_byte = sh_rx;

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
                        sh_rx <= {sh_rx[6:0], card_miso};
                        if (bbit == 3'd7) begin
                            b_busy <= 1'b0; b_state <= B_IDLE; byte_done_r <= 1'b1;
                        end else begin
                            bbit <= bbit + 3'd1;
                            sh_tx <= {sh_tx[6:0], 1'b1};
                            card_mosi <= sh_tx[6];
                        end
                    end else begin
                        bpc <= bpc + 16'd1;
                    end
                end
            endcase
        end
    end

    // ---------------------------------------------------------------------
    // protocol FSM
    // ---------------------------------------------------------------------
    localparam
        ST_RESET        = 6'd0,
        ST_PWRUP        = 6'd1,
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
        ST_SEND_CMD     = 6'd30,
        ST_POLL_R1      = 6'd31,
        ST_READ_BYTES   = 6'd32,
        ST_WR_CMD24     = 6'd33,
        ST_WR_CMD24W    = 6'd34,
        ST_WR_GAP       = 6'd35,
        ST_WR_TOKEN     = 6'd36,
        ST_WR_DATA      = 6'd37,
        ST_WR_CRC       = 6'd38,
        ST_WR_RESP      = 6'd39,
        ST_WR_BUSY      = 6'd40,
        ST_WR_DONE      = 6'd41,
        ST_ERROR        = 6'd63;

    reg [5:0]  st, ret_st, ret_st2;
    reg [7:0]  cmdbuf [0:5];
    reg [2:0]  cmdidx;
    reg [23:0] wait_ctr;
    reg [9:0]  byte_cnt;
    reg [7:0]  r1;
    reg [31:0] r7_ocr;
    reg        card_hc;
    reg [31:0] cur_lba;
    reg [8:0]  wr_idx;

    assign waddr = wr_idx;

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
            cur_lba <= 32'd0; wr_idx <= 9'd0; r1 <= 8'hFF; r7_ocr <= 32'd0;
        end else begin
            done <= 1'b0; dvalid <= 1'b0; byte_go <= 1'b0;
            case (st)
                ST_RESET: begin
                    card_cs_n <= 1'b1; sck_div <= SCK_DIV_INIT[7:0];
                    byte_cnt <= 10'd10; st <= ST_PWRUP;
                end
                ST_PWRUP: begin
                    if (!byte_go && !b_busy && !byte_done_r) begin tx_byte <= 8'hFF; byte_go <= 1'b1; end
                    if (byte_done_r) begin
                        if (byte_cnt == 10'd1) begin
                            card_cs_n <= 1'b0;
                            load_cmd(8'd0, 32'h0, 8'h95);
                            cmdidx <= 3'd0; ret_st <= ST_CMD0_WAIT; st <= ST_SEND_CMD;
                        end else byte_cnt <= byte_cnt - 10'd1;
                    end
                end
                ST_CMD0_WAIT: begin wait_ctr <= 24'd0; ret_st2 <= ST_CMD8_GO; st <= ST_POLL_R1; end
                ST_CMD8_GO: begin
                    if (r1 != 8'h01) begin err_code <= 4'd1; st <= ST_ERROR; end
                    else begin load_cmd(8'd8,32'h0000_01AA,8'h87); cmdidx<=3'd0; ret_st<=ST_CMD8_WAIT; st<=ST_SEND_CMD; end
                end
                ST_CMD8_WAIT: begin wait_ctr<=24'd0; ret_st2<=ST_CMD8_R7; st<=ST_POLL_R1; end
                ST_CMD8_R7: begin
                    if (r1[2]) begin err_code<=4'd8; st<=ST_ERROR; end
                    else if (r1 != 8'h01) begin err_code<=4'd2; st<=ST_ERROR; end
                    else begin byte_cnt<=10'd4; ret_st<=ST_ACMD_CMD55; st<=ST_READ_BYTES; end
                end
                ST_ACMD_CMD55: begin
                    if (r7_ocr[11:0] != 12'h1AA) begin err_code<=4'd2; st<=ST_ERROR; end
                    else begin load_cmd(8'd55,32'h0,8'h01); cmdidx<=3'd0; ret_st<=ST_ACMD_CMD55W; st<=ST_SEND_CMD; wait_ctr<=24'd0; end
                end
                ST_ACMD_CMD55W: begin ret_st2<=ST_ACMD41; st<=ST_POLL_R1; end
                ST_ACMD41: begin load_cmd(8'd41,32'h4000_0000,8'h01); cmdidx<=3'd0; ret_st<=ST_ACMD41_WAIT; st<=ST_SEND_CMD; end
                ST_ACMD41_WAIT: begin ret_st2<=ST_CMD58_GO; st<=ST_POLL_R1; end
                ST_CMD58_GO: begin
                    if (r1 == 8'h00) begin load_cmd(8'd58,32'h0,8'h01); cmdidx<=3'd0; ret_st<=ST_CMD58_WAIT; st<=ST_SEND_CMD; end
                    else if (r1 == 8'h01) begin
                        if (wait_ctr == POLL_TIMEOUT) begin err_code<=4'd3; st<=ST_ERROR; end
                        else begin wait_ctr<=wait_ctr+24'd1; load_cmd(8'd55,32'h0,8'h01); cmdidx<=3'd0; ret_st<=ST_ACMD_CMD55W; st<=ST_SEND_CMD; end
                    end else begin err_code<=4'd3; st<=ST_ERROR; end
                end
                ST_CMD58_WAIT: begin wait_ctr<=24'd0; ret_st2<=ST_CMD58_OCR; st<=ST_POLL_R1; end
                ST_CMD58_OCR: begin
                    if (r1 != 8'h00) begin err_code<=4'd4; st<=ST_ERROR; end
                    else begin byte_cnt<=10'd4; ret_st<=ST_INIT_DONE; st<=ST_READ_BYTES; end
                end
                ST_INIT_DONE: begin
                    card_hc<=r7_ocr[30]; sck_div<=SCK_DIV_FAST[7:0]; card_cs_n<=1'b1; card_ready<=1'b1; st<=ST_READY;
                end

                ST_READY: begin
                    card_cs_n <= 1'b1;
                    if (write_start) begin
                        cur_lba<=lba; card_err<=1'b0; err_code<=4'd0; busy<=1'b1; wr_idx<=9'd0;
                        card_cs_n<=1'b0; st<=ST_WR_CMD24;
                    end else if (start) begin
                        cur_lba<=lba; card_err<=1'b0; err_code<=4'd0; busy<=1'b1;
                        card_cs_n<=1'b0; st<=ST_RD_CMD17;
                    end
                end

                // ---- CMD17 single block read ----
                ST_RD_CMD17: begin
                    load_cmd(8'd17, card_hc ? cur_lba : (cur_lba << 9), 8'h01);
                    cmdidx<=3'd0; ret_st<=ST_RD_CMD17W; st<=ST_SEND_CMD;
                end
                ST_RD_CMD17W: begin wait_ctr<=24'd0; ret_st2<=ST_RD_TOKEN; st<=ST_POLL_R1; end
                ST_RD_TOKEN: begin
                    if (r1 != 8'h00) begin err_code<=4'd6; card_cs_n<=1'b1; busy<=1'b0; card_err<=1'b1; done<=1'b1; st<=ST_READY; end
                    else if (!byte_go && !b_busy && !byte_done_r) begin
                        tx_byte<=8'hFF; byte_go<=1'b1; wait_ctr<=wait_ctr+24'd1;
                        if (wait_ctr == POLL_TIMEOUT) begin err_code<=4'd7; card_cs_n<=1'b1; busy<=1'b0; card_err<=1'b1; done<=1'b1; st<=ST_READY; end
                    end else if (byte_done_r) begin
                        if (rx_byte == 8'hFE) begin byte_cnt<=10'd512; st<=ST_RD_DATA; end
                    end
                end
                ST_RD_DATA: begin
                    if (!byte_go && !b_busy && !byte_done_r && !stall) begin tx_byte<=8'hFF; byte_go<=1'b1; end
                    if (byte_done_r) begin
                        dout<=rx_byte; dvalid<=1'b1;
                        if (byte_cnt == 10'd1) begin byte_cnt<=10'd2; st<=ST_RD_CRC; end
                        else byte_cnt<=byte_cnt-10'd1;
                    end
                end
                ST_RD_CRC: begin
                    if (!byte_go && !b_busy && !byte_done_r && !stall) begin tx_byte<=8'hFF; byte_go<=1'b1; end
                    if (byte_done_r) begin if (byte_cnt==10'd1) st<=ST_RD_DONE; else byte_cnt<=byte_cnt-10'd1; end
                end
                ST_RD_DONE: begin card_cs_n<=1'b1; busy<=1'b0; done<=1'b1; st<=ST_READY; end

                // ---- CMD24 single block write ----
                ST_WR_CMD24: begin
                    load_cmd(8'd24, card_hc ? cur_lba : (cur_lba << 9), 8'h01);
                    cmdidx<=3'd0; ret_st<=ST_WR_CMD24W; st<=ST_SEND_CMD;
                end
                ST_WR_CMD24W: begin wait_ctr<=24'd0; ret_st2<=ST_WR_GAP; st<=ST_POLL_R1; end
                ST_WR_GAP: begin
                    if (r1 != 8'h00) begin err_code<=4'd9; card_cs_n<=1'b1; busy<=1'b0; card_err<=1'b1; done<=1'b1; st<=ST_READY; end
                    else if (!byte_go && !b_busy && !byte_done_r) begin tx_byte<=8'hFF; byte_go<=1'b1; end
                    else if (byte_done_r) st<=ST_WR_TOKEN;
                end
                ST_WR_TOKEN: begin
                    if (!byte_go && !b_busy && !byte_done_r) begin tx_byte<=8'hFE; byte_go<=1'b1; end
                    if (byte_done_r) begin wr_idx<=9'd0; byte_cnt<=10'd512; st<=ST_WR_DATA; end
                end
                ST_WR_DATA: begin
                    if (!byte_go && !b_busy && !byte_done_r) begin tx_byte<=wdata; byte_go<=1'b1; end
                    if (byte_done_r) begin
                        if (byte_cnt == 10'd1) begin byte_cnt<=10'd2; st<=ST_WR_CRC; end
                        else begin byte_cnt<=byte_cnt-10'd1; wr_idx<=wr_idx+9'd1; end
                    end
                end
                ST_WR_CRC: begin
                    if (!byte_go && !b_busy && !byte_done_r) begin tx_byte<=8'hFF; byte_go<=1'b1; end
                    if (byte_done_r) begin
                        if (byte_cnt == 10'd1) begin wait_ctr<=24'd0; st<=ST_WR_RESP; end
                        else byte_cnt<=byte_cnt-10'd1;
                    end
                end
                ST_WR_RESP: begin
                    // Data-response may be preceded by idle 0xFF clocks. Poll until
                    // the card presents a response token instead of assuming it is
                    // valid on the very first byte after CRC.
                    if (!byte_go && !b_busy && !byte_done_r) begin tx_byte<=8'hFF; byte_go<=1'b1; end
                    if (byte_done_r) begin
                        if ((rx_byte & 8'h1F) == 8'h05) begin
                            wait_ctr<=24'd0; st<=ST_WR_BUSY;
                        end else if ((rx_byte == 8'hFF) && (wait_ctr != POLL_TIMEOUT)) begin
                            wait_ctr<=wait_ctr+24'd1;
                        end else begin
                            err_code<=4'd10; card_cs_n<=1'b1; busy<=1'b0; card_err<=1'b1; done<=1'b1; st<=ST_READY;
                        end
                    end
                end
                ST_WR_BUSY: begin
                    if (!byte_go && !b_busy && !byte_done_r) begin tx_byte<=8'hFF; byte_go<=1'b1; end
                    if (byte_done_r) begin
                        if (rx_byte == 8'hFF) st<=ST_WR_DONE;
                        else if (wait_ctr == POLL_TIMEOUT) begin
                            err_code<=4'd11; card_cs_n<=1'b1; busy<=1'b0; card_err<=1'b1; done<=1'b1; st<=ST_READY;
                        end else wait_ctr<=wait_ctr+24'd1;
                    end
                end
                ST_WR_DONE: begin card_cs_n<=1'b1; busy<=1'b0; done<=1'b1; st<=ST_READY; end

                // ---- shared command helpers ----
                ST_SEND_CMD: begin
                    if (!byte_go && !b_busy && !byte_done_r) begin tx_byte<=cmdbuf[cmdidx]; byte_go<=1'b1; end
                    if (byte_done_r) begin if (cmdidx==3'd5) st<=ret_st; else cmdidx<=cmdidx+3'd1; end
                end
                ST_POLL_R1: begin
                    if (!byte_go && !b_busy && !byte_done_r) begin tx_byte<=8'hFF; byte_go<=1'b1; end
                    if (byte_done_r) begin
                        if (!rx_byte[7]) begin r1<=rx_byte; st<=ret_st2; end
                        else if (wait_ctr == POLL_TIMEOUT) begin r1<=8'hFF; st<=ret_st2; end
                        else wait_ctr<=wait_ctr+24'd1;
                    end
                end
                ST_READ_BYTES: begin
                    if (!byte_go && !b_busy && !byte_done_r) begin tx_byte<=8'hFF; byte_go<=1'b1; end
                    if (byte_done_r) begin
                        r7_ocr<={r7_ocr[23:0],rx_byte};
                        if (byte_cnt==10'd1) st<=ret_st; else byte_cnt<=byte_cnt-10'd1;
                    end
                end

                ST_ERROR: begin card_cs_n<=1'b1; busy<=1'b0; card_ready<=1'b0; card_err<=1'b1; end
                default: st<=ST_ERROR;
            endcase
        end
    end
endmodule
