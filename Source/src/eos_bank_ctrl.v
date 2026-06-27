// eos_bank_ctrl.v -- Eos bank-management controller (flash erase/program/poll).
// =====================================================================
// Loader flash CONTROL PLANE. Does NOT duplicate the serve path: the 0xEF bank
// register and the logical->physical SERVE translation live in
// eos_sdram_backend.v (hardware-validated). This module owns what the backend
// does not -- writing the flash:
//   * ERASE a bank   (loop 64K block-erase 0xD8 over the bank's size)
//   * PROGRAM a page (0x02, a 256-byte page from the page buffer)
//   * real STATUS poll (0x05, wait WIP bit0 clear after every erase/program)
//   * HARD floor guard: every physical target is FLOOR + bank_base + offset, so
//     it is impossible to address below FLOOR. Chip-erase is not implemented.
// VARIABLE BIOS SIZE: a bank's size comes from its number (256K / 512K / 1MB),
// matching the backend xlate map. ERASE walks (size/64K) blocks; PROGRAM walks
// (size/256) pages. Expansion banks are a later map extension -- the geometry
// functions below are the single place to grow.
// SPI BUS shared with the reader (idle post-preload); taken via bus_req/bus_gnt.
// After a flash, refresh_* hands the region to the backend for SDRAM reload.
// =====================================================================
module eos_bank_ctrl #(
    parameter [23:0]  FLOOR    = 24'h200000,
    parameter integer SCK_DIV  = 2,
    parameter [7:0]   CMD_WREN = 8'h06,
    parameter [7:0]   CMD_PP   = 8'h02,
    parameter [7:0]   CMD_BE   = 8'hD8,
    parameter [7:0]   CMD_RDSR = 8'h05,
    parameter [7:0]   CMD_READ = 8'h03
)(
    input  wire        clk,
    input  wire        cold_rstn,
    // CONTRACT: cmd_bank/cmd_op/cmd_page must be VALID AND STABLE on the cycle
    // before cmd_stb pulses (operands-valid-before-strobe). The loader's LPC
    // decode registers naturally satisfy this; do not derive cmd_stb and cmd_bank
    // from the same combinational decode in the same cycle.
    input  wire        cmd_stb,
    input  wire [1:0]  cmd_op,        // 0=ERASE_BANK 1=PROGRAM_PAGE 2=READ_PAGE
    input  wire [3:0]  cmd_bank,
    input  wire [11:0] cmd_page,
    input  wire        pb_wr,
    input  wire [7:0]  pb_addr,
    input  wire [7:0]  pb_din,
    input  wire [7:0]  pb_raddr,      // page-buffer read address (host read-back)
    output wire [7:0]  pb_rdata,      // page-buffer read data
    output reg         busy,
    output reg         done,
    output reg         refused,
    output reg  [7:0]  last_status,
    output reg         refresh_req,
    output reg  [23:0] refresh_base,
    output reg  [23:0] refresh_len,
    output reg         bus_req,
    input  wire        bus_gnt,
    output reg         flash_cs_n,
    output reg         flash_clk,
    output reg         flash_mosi,
    input  wire        flash_miso
);
    // bank_base is now 24-bit so a config bank can live above the 2MB Xenium
    // range (engine-reachable for erase/program/read; NOT served -- the serve
    // xlate in eos_sdram_backend stays 21-bit / 2MB). Config bank 0xB sits at
    // the top of the managed region, clear of BIOS (0x000000-0x400000) and the
    // XbDiag reserve below it.
    function [23:0] bank_base; input [3:0] b; begin
        case (b)
            4'h1: bank_base = 24'h180000; 4'h2: bank_base = 24'h100000;
            4'h3: bank_base = 24'h000000; 4'h4: bank_base = 24'h040000;
            4'h5: bank_base = 24'h080000; 4'h6: bank_base = 24'h0C0000;
            4'h7: bank_base = 24'h000000; 4'h8: bank_base = 24'h080000;
            4'h9: bank_base = 24'h000000; 4'hA: bank_base = 24'h1C0000;
            4'hB: bank_base = 24'h5F0000;            // CONFIG banks-table (phys 0x7F0000)
            4'hC: bank_base = 24'h5E0000;            // CONFIG settings   (phys 0x7E0000)
            default: bank_base = 24'h000000;
        endcase
    end endfunction
    function [23:0] bank_size; input [3:0] b; begin
        case (b)
            4'h2,4'h7,4'h8: bank_size = 24'h080000;  // 512K
            4'h9:           bank_size = 24'h100000;  // 1MB
            4'hB,4'hC:      bank_size = 24'h010000;  // CONFIG: one 64K block each
            default:        bank_size = 24'h040000;  // 256K
        endcase
    end endfunction

    wire [23:0] sel_phys_base = FLOOR + bank_base(cmd_bank);
    wire [23:0] sel_size      = bank_size(cmd_bank);
    wire [8:0]  n_blocks      = sel_size[23:16];   // size / 64K
    wire        op_below_floor = (sel_phys_base < FLOOR);

    reg [7:0] pbuf [0:255];
    // External fill (program) writes via pb_wr; internal fill (read-back) writes
    // captured flash bytes via rd_we. The two never overlap (fill precedes GO;
    // read-capture happens during a READ op). pb_rdata streams the buffer back.
    reg        rd_we; reg [7:0] rd_waddr, rd_wdata;
    always @(posedge clk) begin
        if (pb_wr)      pbuf[pb_addr]  <= pb_din;
        else if (rd_we) pbuf[rd_waddr] <= rd_wdata;
    end
    assign pb_rdata = pbuf[pb_raddr];

    localparam integer PERIOD = 2*SCK_DIV;
    reg  [15:0] pc; reg [3:0] bit_i; reg [7:0] tx_byte, rx_byte, sh;
    reg         shift_go, shift_busy, shift_done;
    wire        pc_last = (pc == PERIOD-1);
    wire        sck_hi  = (pc >= SCK_DIV);

    always @(posedge clk or negedge cold_rstn) begin
        if (!cold_rstn) begin
            pc<=0; bit_i<=0; shift_busy<=0; shift_done<=0; flash_clk<=0; flash_mosi<=0; rx_byte<=0; sh<=0;
        end else begin
            shift_done <= 1'b0;
            if (shift_go && !shift_busy) begin
                shift_busy<=1'b1; sh<=tx_byte; bit_i<=4'd0; pc<=0; flash_mosi<=tx_byte[7]; flash_clk<=1'b0;
            end else if (shift_busy) begin
                flash_clk <= sck_hi;
                if (pc==0) flash_mosi <= sh[7];
                if (pc==SCK_DIV) rx_byte <= {rx_byte[6:0], flash_miso};
                if (pc_last) begin
                    pc<=0; sh<={sh[6:0],1'b0};
                    if (bit_i==4'd7) begin shift_busy<=0; shift_done<=1; flash_clk<=0; end
                    else bit_i<=bit_i+1'b1;
                end else pc<=pc+1'b1;
            end
        end
    end

    localparam OP_ERASE = 2'd0, OP_PROG = 2'd1, OP_READ = 2'd2, OP_SYNC = 2'd3;
    localparam S_IDLE=5'd0,S_REQ=5'd1,S_WREN=5'd2,S_WREN2=5'd3,S_CMD=5'd4,
               S_A2=5'd5,S_A1=5'd6,S_A0=5'd7,S_PDATA=5'd8,S_CSUP=5'd9,
               S_POLL0=5'd10,S_POLL1=5'd11,S_POLLC=5'd12,S_NEXT=5'd13,
               S_DONE=5'd14,S_REFUSE=5'd15,S_KICK=5'd16,
               S_RCMD=5'd17,S_RA2=5'd18,S_RA1=5'd19,S_RA0=5'd20,
               S_RDATA=5'd21,S_RCAP=5'd22,S_RCSUP=5'd23;

    reg [4:0]  st, ret; reg [1:0] op_l;
    reg [23:0] addr_l; reg [8:0] blocks_left; reg [8:0] pbyte;
    reg [23:0] flashed_base, flashed_len;
    reg [8:0]  rd_idx;     // read-back byte counter (0..256)

    always @(posedge clk or negedge cold_rstn) begin
        if (!cold_rstn) begin
            st<=S_IDLE; busy<=0; done<=0; refused<=0; last_status<=8'hFF;
            flash_cs_n<=1; bus_req<=0; shift_go<=0; refresh_req<=0; refresh_base<=0; refresh_len<=0;
            addr_l<=0; blocks_left<=0; pbyte<=0; op_l<=0; flashed_base<=0; flashed_len<=0; ret<=S_IDLE;
            rd_we<=0; rd_waddr<=0; rd_wdata<=0; rd_idx<=0;
        end else begin
            done<=1'b0; refresh_req<=1'b0; shift_go<=1'b0; rd_we<=1'b0;
            case (st)
                S_IDLE: begin
                    busy<=1'b0; flash_cs_n<=1'b1; bus_req<=1'b0;
                    if (cmd_stb) begin
                        if (op_below_floor ||
                            (cmd_op!=OP_ERASE && cmd_op!=OP_PROG && cmd_op!=OP_READ && cmd_op!=OP_SYNC)) st<=S_REFUSE;
                        else begin
                            busy<=1'b1; op_l<=cmd_op; refused<=1'b0;
                            if (cmd_op==OP_SYNC) begin
                                // no flash access -- hand the WHOLE selected bank to the
                                // backend for one SDRAM reload (the loader calls this once
                                // after a multi-page WriteImage so the served copy matches
                                // flash; per-page reloads can't keep up and get dropped).
                                flashed_base<=sel_phys_base; flashed_len<=sel_size;
                                st<=S_DONE;
                            end else if (cmd_op==OP_ERASE) begin
                                addr_l<=sel_phys_base; blocks_left<=n_blocks;
                                flashed_base<=sel_phys_base; flashed_len<=sel_size;
                                st<=S_REQ;
                            end else begin   // PROGRAM or READ: single page address
                                addr_l<=sel_phys_base + {4'd0,cmd_page,8'd0};
                                flashed_base<=sel_phys_base + {4'd0,cmd_page,8'd0}; flashed_len<=24'd256;
                                st<=S_REQ;
                            end
                        end
                    end
                end
                S_REQ:  begin bus_req<=1'b1; if (bus_gnt) st<=(op_l==OP_READ)?S_RCMD:S_WREN; end
                S_WREN: begin flash_cs_n<=1'b0; tx_byte<=CMD_WREN; ret<=S_WREN2; st<=S_KICK; end
                S_WREN2:begin flash_cs_n<=1'b1; st<=S_CMD; end
                S_CMD:  begin flash_cs_n<=1'b0; tx_byte<=(op_l==OP_ERASE)?CMD_BE:CMD_PP; ret<=S_A2; st<=S_KICK; end
                S_A2:   begin tx_byte<=addr_l[23:16]; ret<=S_A1; st<=S_KICK; end
                S_A1:   begin tx_byte<=addr_l[15:8];  ret<=S_A0; st<=S_KICK; end
                S_A0:   begin
                    tx_byte<=addr_l[7:0];
                    if (op_l==OP_ERASE) ret<=S_CSUP;
                    else begin pbyte<=9'd0; ret<=S_PDATA; end
                    st<=S_KICK;
                end
                S_PDATA: begin
                    if (pbyte==9'd256) st<=S_CSUP;
                    else begin tx_byte<=pbuf[pbyte[7:0]]; ret<=S_PDATA; pbyte<=pbyte+1'b1; st<=S_KICK; end
                end
                S_CSUP:  begin flash_cs_n<=1'b1; st<=S_POLL0; end
                S_POLL0: begin flash_cs_n<=1'b0; tx_byte<=CMD_RDSR; ret<=S_POLL1; st<=S_KICK; end
                S_POLL1: begin tx_byte<=8'h00; ret<=S_POLLC; st<=S_KICK; end
                S_POLLC: begin
                    last_status<=rx_byte;
                    if (rx_byte[0]) begin tx_byte<=8'h00; ret<=S_POLLC; st<=S_KICK; end
                    else begin flash_cs_n<=1'b1; st<=S_NEXT; end
                end
                S_NEXT: begin
                    if (op_l==OP_ERASE && blocks_left>9'd1) begin
                        blocks_left<=blocks_left-1'b1; addr_l<=addr_l+24'h010000; st<=S_WREN;
                    end else st<=S_DONE;
                end
                S_DONE: begin
                    bus_req<=1'b0; busy<=1'b0; done<=1'b1;
                    // ONLY the explicit SYNC reloads SDRAM. ERASE must not -- its
                    // reload races the page-program ops that immediately follow it
                    // (bus contention + a still-pending erase reload makes the final
                    // SYNC's request get dropped by the in-flight guard, leaving the
                    // served copy stale -> warm-reset launch frags while cold boot,
                    // which re-preloads everything, works). WriteImage ends with one
                    // SYNC over the finished image; a deleted bank isn't served so it
                    // needs no reload.
                    if (op_l == OP_SYNC) begin
                        refresh_req<=1'b1; refresh_base<=flashed_base; refresh_len<=flashed_len;
                    end
                    st<=S_IDLE;
                end
                S_REFUSE: begin refused<=1'b1; done<=1'b1; busy<=1'b0; st<=S_IDLE; end
                S_KICK: begin
                    if (!shift_busy && !shift_done) shift_go<=1'b1;
                    if (shift_done) st<=ret;
                end

                // --- READ_PAGE: 0x03 + 24-bit addr, clock 256 bytes into pbuf ---
                S_RCMD: begin flash_cs_n<=1'b0; tx_byte<=CMD_READ; rd_idx<=9'd0; ret<=S_RA2; st<=S_KICK; end
                S_RA2:  begin tx_byte<=addr_l[23:16]; ret<=S_RA1; st<=S_KICK; end
                S_RA1:  begin tx_byte<=addr_l[15:8];  ret<=S_RA0; st<=S_KICK; end
                S_RA0:  begin tx_byte<=addr_l[7:0];   ret<=S_RDATA; st<=S_KICK; end
                S_RDATA: begin
                    if (rd_idx==9'd256) st<=S_RCSUP;
                    else begin tx_byte<=8'h00; ret<=S_RCAP; st<=S_KICK; end
                end
                S_RCAP: begin   // rx_byte holds the byte just clocked in
                    rd_we<=1'b1; rd_waddr<=rd_idx[7:0]; rd_wdata<=rx_byte;
                    rd_idx<=rd_idx+1'b1; st<=S_RDATA;
                end
                S_RCSUP: begin flash_cs_n<=1'b1; st<=S_DONE; end

                default: st<=S_IDLE;
            endcase
        end
    end
endmodule