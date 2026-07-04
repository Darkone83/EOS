// eos_flash_cmd.v -- Eos flash command interface (0xEC index / 0xED data).
// =====================================================================
// Bridges the loader's generic LPC I/O writes to eos_bank_ctrl. Keeps 0xEF
// (bank / serve register) untouched. An index/data register file so the whole
// flash control plane costs exactly TWO I/O ports:
//
//   write 0xEC = index ; then write/read 0xED = that register's data.
//
//   idx 0x00 OP       (W) op[1:0]    0=ERASE_BANK 1=PROGRAM_PAGE
//   idx 0x01 BANK     (W) bank[3:0]
//   idx 0x02 PAGE_LO  (W) page[7:0]
//   idx 0x03 PAGE_HI  (W) page[12:8]  (5 bits: image is 7168 pages, needs 13-bit)
//   idx 0x04 PBUF     (W) select resets the byte pointer; each 0xED write
//                         pushes one byte into the engine page buffer (auto-inc)
//   idx 0x05 GO       (W) pulse cmd_stb with current OP/BANK/PAGE
//   idx 0x06 STATUS   (R) {4'b0, reload, refused, done_sticky, busy}
//                         bit0 busy, bit1 done(sticky), bit2 refused, bit3 SDRAM reload
//   idx 0x07 LASTSTAT (R) flash status register from the last poll
//   idx 0x0D DESCRELOAD (W) any write pulses a descriptor re-read in bank_ctrl
//   idx 0x0E ERASEBLK  (W) bit0=block-erase mode for the NEXT erase; block
//                          index comes from PAGE_LO/HI (64K block within bank)
//   idx 0x08 BOOT     (RW) bit0 stock_boot: 1 = release D0 (stock/TSOP boot on
//                          the NEXT warm reset), 0 = assert D0 (Eos LPC boot).
//                          In the cold_rstn domain -> survives a warm reset;
//                          cleared only by cold power / FPGA reconfig.
//
// OP/BANK/PAGE are driven CONTINUOUSLY from their holding registers, so they
// are valid on (and before) the GO strobe -- satisfying eos_bank_ctrl's
// operands-valid-before-strobe contract. done_sticky latches the engine's
// 1-cycle done pulse and clears on the next GO, so the loader can poll for
// completion without racing the pulse.
// =====================================================================
module eos_flash_cmd #(
    parameter [15:0] PORT_INDEX = 16'h00EC,
    parameter [15:0] PORT_DATA  = 16'h00ED
)(
    input  wire        clk,
    input  wire        cold_rstn,

    // ---- generic LPC I/O write strobe from the loader ----
    input  wire        io_wr_stb,        // 1-cycle pulse on any committed I/O write
    input  wire [15:0] io_wr_addr,
    input  wire [7:0]  io_wr_data,

    // ---- generic LPC I/O read strobe (1-cycle pulse on any committed I/O read).
    //      Used to auto-advance the page-buffer read pointer while streaming. ----
    input  wire        io_rd_stb,
    input  wire [15:0] io_rd_addr,

    // ---- read data for a 0xED read (loader muxes this into its read_buffer
    //      when the decoded I/O read address == PORT_DATA) ----
    output reg  [7:0]  cmd_rd_data,

    // ---- persistent boot-mode bit (cold_rstn domain: survives warm reset) ----
    output reg         stock_boot,       // 1 = release D0 for stock/TSOP boot
    output reg         desc_reload,      // pulse: loader wrote descriptor -> re-read
    output reg         blk_erase,        // 1 = next ERASE is a single 64K block (page=block)

    // ---- engine command interface (to eos_bank_ctrl) ----
    output wire        cmd_stb,
    output wire [1:0]  cmd_op,
    output wire [3:0]  cmd_bank,
    output wire [12:0] cmd_page,
    output reg         pb_wr,
    output reg  [7:0]  pb_addr,
    output reg  [7:0]  pb_din,
    output wire [7:0]  pb_raddr,         // engine page-buffer read address
    input  wire [7:0]  pb_rdata,         // engine page-buffer read data

    // ---- engine status (from eos_bank_ctrl) ----
    input  wire        eng_busy,
    input  wire        eng_done,
    input  wire        eng_refused,
    input  wire [7:0]  eng_last_status,
    input  wire        eng_reload,         // SDRAM reload in progress (post-flash)

    // ---- SDRAM scratch write (update staging: loader streams image here) ----
    output reg         scr_wr,             // 1-cycle pulse per staged byte
    output reg  [20:0] scr_waddr,          // auto-incrementing scratch offset
    output reg  [7:0]  scr_wdata,
    input  wire        scr_busy,           // backend scratch port busy (poll via STATUS bit4)
    input  wire        newrgn_ready        // ext-region resident in SDRAM (poll via STATUS bit5)
);
    localparam [7:0] IDX_OP=8'd0, IDX_BANK=8'd1, IDX_PAGELO=8'd2, IDX_PAGEHI=8'd3,
                     IDX_PBUF=8'd4, IDX_GO=8'd5, IDX_STATUS=8'd6, IDX_LASTSTAT=8'd7,
                     IDX_BOOT=8'd8,
                     IDX_SCR_ALO=8'd9, IDX_SCR_AMID=8'd10, IDX_SCR_AHI=8'd11,
                     IDX_SCR_DATA=8'd12,
                     IDX_DESCRELOAD=8'd13, IDX_ERASEBLK=8'd14;

    reg [7:0]  index;
    reg [1:0]  op_r;
    reg [3:0]  bank_r;
    reg [12:0] page_r;
    reg [7:0]  pba;            // page-buffer pointer (shared write-fill / read-stream)
    reg        done_sticky;
    reg        go_pulse;
    reg [20:0] scr_addr;       // scratch write pointer (auto-increments per byte)

    // OP/BANK/PAGE continuously reflect the holding registers (always valid).
    assign cmd_op   = op_r;
    assign cmd_bank = bank_r;
    assign cmd_page = page_r;
    assign cmd_stb  = go_pulse;
    assign pb_raddr = pba;     // read the engine pbuf byte at the current pointer

    wire wr_index = io_wr_stb && (io_wr_addr == PORT_INDEX);
    wire wr_data  = io_wr_stb && (io_wr_addr == PORT_DATA);
    wire rd_data  = io_rd_stb && (io_rd_addr == PORT_DATA);


    // combinational read value for the currently-selected index
    always @(*) begin
        case (index)
            IDX_STATUS:   cmd_rd_data = {2'b0, newrgn_ready, scr_busy, eng_reload, eng_refused, done_sticky, eng_busy};
            IDX_SCR_ALO:  cmd_rd_data = scr_addr[7:0];
            IDX_SCR_AMID: cmd_rd_data = scr_addr[15:8];
            IDX_SCR_AHI:  cmd_rd_data = {3'b0, scr_addr[20:16]};
            IDX_LASTSTAT: cmd_rd_data = eng_last_status;
            IDX_OP:       cmd_rd_data = {6'b0, op_r};
            IDX_BANK:     cmd_rd_data = {4'b0, bank_r};
            IDX_PAGELO:   cmd_rd_data = page_r[7:0];
            IDX_PAGEHI:   cmd_rd_data = {3'b0, page_r[12:8]};
            IDX_PBUF:     cmd_rd_data = pb_rdata;   // stream engine page buffer
            IDX_BOOT:     cmd_rd_data = {7'b0, stock_boot};
            default:      cmd_rd_data = 8'h00;
        endcase
    end

    always @(posedge clk or negedge cold_rstn) begin
        if (!cold_rstn) begin
            index<=8'd0; op_r<=2'd0; bank_r<=4'd0; page_r<=13'd0; pba<=8'd0;
            done_sticky<=1'b0; go_pulse<=1'b0; pb_wr<=1'b0; pb_addr<=8'd0; pb_din<=8'd0;
            stock_boot<=1'b0; desc_reload<=1'b0; blk_erase<=1'b0;
            scr_wr<=1'b0; scr_waddr<=21'd0; scr_wdata<=8'd0; scr_addr<=21'd0;
        end else begin
            go_pulse <= 1'b0; desc_reload <= 1'b0;
            pb_wr    <= 1'b0;
            scr_wr   <= 1'b0;
            if (eng_done) done_sticky <= 1'b1;

            if (wr_index) begin
                index <= io_wr_data;
                if (io_wr_data == IDX_PBUF) pba <= 8'd0;   // arm page-buffer fill
            end else if (wr_data) begin
                case (index)
                    IDX_OP:     op_r        <= io_wr_data[1:0];
                    IDX_BANK:   bank_r      <= io_wr_data[3:0];
                    IDX_PAGELO: page_r[7:0] <= io_wr_data;
                    IDX_PAGEHI: page_r[12:8]<= io_wr_data[4:0];
                    IDX_PBUF: begin
                        pb_wr   <= 1'b1;
                        pb_addr <= pba;
                        pb_din  <= io_wr_data;
                        pba     <= pba + 1'b1;
                    end
                    IDX_DESCRELOAD: desc_reload <= 1'b1;   // re-read descriptor
                    IDX_ERASEBLK:   blk_erase <= io_wr_data[0];  // arm block-erase for next ERASE
                    IDX_GO: begin
                        go_pulse    <= 1'b1;       // operands already stable
                        done_sticky <= 1'b0;       // clear stale completion
                    end
                    IDX_SCR_ALO:  scr_addr[7:0]   <= io_wr_data;
                    IDX_SCR_AMID: scr_addr[15:8]  <= io_wr_data;
                    IDX_SCR_AHI:  scr_addr[20:16] <= io_wr_data[4:0];
                    IDX_SCR_DATA: begin
                        scr_wr    <= 1'b1;
                        scr_waddr <= scr_addr;
                        scr_wdata <= io_wr_data;
                        scr_addr  <= scr_addr + 1'b1;   // stream: auto-advance
                    end
                    IDX_BOOT: stock_boot <= io_wr_data[0];
                    default: ; // STATUS / LASTSTAT are read-only
                endcase
            end

            // Streaming read-back: each 0xED read while index==PBUF returns the
            // current pbuf byte (combinationally above) then advances the pointer.
            if (rd_data && (index == IDX_PBUF))
                pba <= pba + 1'b1;
        end
    end
endmodule