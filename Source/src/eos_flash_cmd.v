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
//   idx 0x06 STATUS   (R) {2'b0, newrgn_ready, scr_busy, reload, refused, done_sticky, busy}
//                         bit0 busy, bit1 done(sticky), bit2 refused, bit3 SDRAM reload,
//                         bit4 scr_busy, bit5 newrgn_ready. bits 6-7 are 0.
//   idx 0x07 LASTSTAT (R) flash status register from the last poll
//   idx 0x08 BOOT     (RW) bit0 stock_boot: 1 = release D0 (stock/TSOP boot on
//                          the NEXT warm reset), 0 = assert D0 (Eos LPC boot).
//                          In the cold_rstn domain -> survives a warm reset;
//                          cleared only by cold power / FPGA reconfig.
//   idx 0x09 SCR_ALO  (RW) scratch address bits [7:0]
//   idx 0x0A SCR_AMID (RW) scratch address bits [15:8]
//   idx 0x0B SCR_AHI  (RW) scratch address bits [20:16] (5 bits)
//   idx 0x0C SCR_DATA (W)  push one byte to the scratch-staging path (auto-inc)
//   idx 0x0D DESCRELOAD (W) any write pulses a descriptor re-read in bank_ctrl
//   idx 0x0E ERASEBLK  (W) bit0=block-erase mode for the NEXT erase; block
//                          index comes from PAGE_LO/HI (64K block within bank)
//   idx 0x0F-0x12 LEDMODE/R/G/B -- bank-select WS2812 (unrelated to SD)
//   idx 0x13 NR_SZC    (RW) size class of whatever is resident in the NRGN_SD
//                          lane: 0=256K 1=512K 2=1MB. Read by the serve-side
//                          bank_eff==0 redirect in eos_sdram_backend.v.
//                          General-purpose -- set this before EITHER a flash
//                          SYNC of bank 0x0 OR an SD precache into it.
//   idx 0x14-0x17 SD_LBA0-3 (W) starting SD block/sector number, 32-bit
//                          little-endian (LBA0=bits7:0 .. LBA3=bits31:24)
//   idx 0x18 SD_BLKLO  (W) block count [7:0] (count of 512B blocks to read)
//   idx 0x19 SD_BLKHI  (W) block count [11:8]
//   idx 0x1A SD_GO     (W) any write pulses the SD precache start (see
//                          eos_sd_precache.v). LBA/BLK must already be valid.
//   idx 0x1B SD_STATUS (R) {4'b0, sd_err_code[3:0]} low nibble; see idx 0x1C
//   idx 0x1C SD_STATUS2(R) {5'b0, sd_err, sd_done_sticky, sd_busy}
//                          sd_done_sticky clears on the next SD_GO, same
//                          pattern as the flash engine's done_sticky.
//   idx 0x1D-0x20 SD_BR_LBA0-3 (W) sector to browse-read, 32-bit little-endian
//                          (same layout as SD_LBA0-3). Shares the ONE
//                          eos_sd_spi instance with the precache path above --
//                          they are mutually exclusive; issuing one while the
//                          other is busy is refused (see err_code 13).
//   idx 0x21 SD_BR_GO  (W) any write pulses a single-sector browse read (see
//                          eos_sd_precache.v's browse_go). SD_BR_LBA must
//                          already be valid. NEVER writes to the card --
//                          read-only, no write command exists anywhere in
//                          this path (the card is written from a PC only).
//   idx 0x22 SD_BR_BUF (R) select resets the read pointer to 0; each 0xED
//                          read streams the next byte of the 512B buffer
//                          filled by the last SD_BR_GO (auto-inc, same shape
//                          as IDX_PBUF above).
//   idx 0x23 SD_BR_STATUS (R) {4'b0, sd_br_err_code[3:0]}; see idx 0x24
//   idx 0x24 SD_BR_STATUS2(R) {5'b0, sd_br_err, sd_br_done, sd_br_busy}
//                          sd_br_done clears on the next SD_BR_GO.
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
    // LED SHOW: loader tells the gateware exactly what the bank LED displays.
    // mode: 0=off, 1=solid(use led_show_rgb), 2=pulse white, 3=pulse purple,
    // 4=pulse magenta/neon pink (SD Card staging).
    output reg  [2:0]  led_show_mode,
    output reg  [23:0] led_show_rgb,
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
    input  wire        newrgn_ready,       // ext-region resident in SDRAM (poll via STATUS bit5)

    // ---- SD precache command interface (to eos_sd_precache) ----
    output wire [1:0]  nr_szc,             // NR_SZC: size class resident in NRGN_SD
    output wire [31:0] sd_lba,             // SD_LBA0-3
    output wire [11:0] sd_blkcnt,          // SD_BLKLO/HI
    output wire        sd_precache_stb,    // SD_GO pulse
    input  wire        sd_eng_busy,
    input  wire        sd_eng_done_sticky, // sd_precache's own sticky done (see there)
    input  wire        sd_eng_err,
    input  wire [3:0]  sd_eng_err_code,

    // ---- SD browse-read command interface (to eos_sd_precache) ----
    // One arbitrary sector -> on-chip buffer -> streamed back over LPC via
    // SD_BR_BUF, same auto-increment shape as IDX_PBUF below. Used by the
    // (loader-side, not-yet-built) FAT32 driver to read the root directory,
    // FAT table, and cluster chain -- gateware has no filesystem knowledge.
    output wire [31:0] sd_br_lba,          // SD_BR_LBA0-3
    output wire        sd_br_stb,          // SD_BR_GO pulse
    output wire [8:0]  sd_br_raddr,        // SD_BR_BUF streaming read pointer
    input  wire [7:0]  sd_br_rdata,        // byte at sd_br_raddr (from eos_sd_precache)
    input  wire        sd_br_busy,
    input  wire        sd_br_done,         // eos_sd_precache's own sticky done
    input  wire        sd_br_err,
    input  wire [3:0]  sd_br_err_code
);
    localparam [7:0] IDX_OP=8'd0, IDX_BANK=8'd1, IDX_PAGELO=8'd2, IDX_PAGEHI=8'd3,
                     IDX_PBUF=8'd4, IDX_GO=8'd5, IDX_STATUS=8'd6, IDX_LASTSTAT=8'd7,
                     IDX_BOOT=8'd8,
                     IDX_SCR_ALO=8'd9, IDX_SCR_AMID=8'd10, IDX_SCR_AHI=8'd11,
                     IDX_SCR_DATA=8'd12,
                     IDX_DESCRELOAD=8'd13, IDX_ERASEBLK=8'd14,
                     IDX_LEDMODE=8'd15, IDX_LEDR=8'd16, IDX_LEDG=8'd17, IDX_LEDB=8'd18,
                     IDX_NR_SZC=8'd19,
                     IDX_SD_LBA0=8'd20, IDX_SD_LBA1=8'd21, IDX_SD_LBA2=8'd22, IDX_SD_LBA3=8'd23,
                     IDX_SD_BLKLO=8'd24, IDX_SD_BLKHI=8'd25,
                     IDX_SD_GO=8'd26, IDX_SD_STATUS=8'd27, IDX_SD_STATUS2=8'd28,
                     IDX_SD_BR_LBA0=8'd29, IDX_SD_BR_LBA1=8'd30,
                     IDX_SD_BR_LBA2=8'd31, IDX_SD_BR_LBA3=8'd32,
                     IDX_SD_BR_GO=8'd33, IDX_SD_BR_BUF=8'd34,
                     IDX_SD_BR_STATUS=8'd35, IDX_SD_BR_STATUS2=8'd36;

    reg [7:0]  index;
    reg [1:0]  op_r;
    reg [3:0]  bank_r;
    reg [12:0] page_r;
    reg [7:0]  pba;            // page-buffer pointer (shared write-fill / read-stream)
    reg        done_sticky;
    reg        go_pulse;
    reg [20:0] scr_addr;       // scratch write pointer (auto-increments per byte)
    reg [1:0]  nr_szc_r;
    reg [31:0] sd_lba_r;
    reg [11:0] sd_blkcnt_r;
    reg        sd_go_pulse;
    reg [31:0] sd_br_lba_r;
    reg        sd_br_go_pulse;
    reg [8:0]  br_ptr;         // SD_BR_BUF streaming read pointer (mirrors pba)

    assign nr_szc          = nr_szc_r;
    assign sd_lba           = sd_lba_r;
    assign sd_blkcnt        = sd_blkcnt_r;
    assign sd_precache_stb  = sd_go_pulse;
    assign sd_br_lba        = sd_br_lba_r;
    assign sd_br_stb        = sd_br_go_pulse;
    assign sd_br_raddr      = br_ptr;

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
            IDX_LEDMODE:  cmd_rd_data = {5'b0, led_show_mode};
            IDX_LEDR:     cmd_rd_data = led_show_rgb[23:16];
            IDX_LEDG:     cmd_rd_data = led_show_rgb[15:8];
            IDX_LEDB:     cmd_rd_data = led_show_rgb[7:0];
            IDX_NR_SZC:   cmd_rd_data = {6'b0, nr_szc_r};
            IDX_SD_LBA0:  cmd_rd_data = sd_lba_r[7:0];
            IDX_SD_LBA1:  cmd_rd_data = sd_lba_r[15:8];
            IDX_SD_LBA2:  cmd_rd_data = sd_lba_r[23:16];
            IDX_SD_LBA3:  cmd_rd_data = sd_lba_r[31:24];
            IDX_SD_BLKLO: cmd_rd_data = sd_blkcnt_r[7:0];
            IDX_SD_BLKHI: cmd_rd_data = {4'b0, sd_blkcnt_r[11:8]};
            IDX_SD_STATUS:  cmd_rd_data = {4'b0, sd_eng_err_code};
            IDX_SD_STATUS2: cmd_rd_data = {5'b0, sd_eng_err, sd_eng_done_sticky, sd_eng_busy};
            IDX_SD_BR_LBA0: cmd_rd_data = sd_br_lba_r[7:0];
            IDX_SD_BR_LBA1: cmd_rd_data = sd_br_lba_r[15:8];
            IDX_SD_BR_LBA2: cmd_rd_data = sd_br_lba_r[23:16];
            IDX_SD_BR_LBA3: cmd_rd_data = sd_br_lba_r[31:24];
            IDX_SD_BR_BUF:  cmd_rd_data = sd_br_rdata;   // stream the 512B browse buffer
            IDX_SD_BR_STATUS:  cmd_rd_data = {4'b0, sd_br_err_code};
            IDX_SD_BR_STATUS2: cmd_rd_data = {5'b0, sd_br_err, sd_br_done, sd_br_busy};
            default:      cmd_rd_data = 8'h00;
        endcase
    end

    always @(posedge clk or negedge cold_rstn) begin
        if (!cold_rstn) begin
            index<=8'd0; op_r<=2'd0; bank_r<=4'd0; page_r<=13'd0; pba<=8'd0;
            done_sticky<=1'b0; go_pulse<=1'b0; pb_wr<=1'b0; pb_addr<=8'd0; pb_din<=8'd0;
            stock_boot<=1'b0; desc_reload<=1'b0; blk_erase<=1'b0;
            led_show_mode<=3'd0; led_show_rgb<=24'd0;
            scr_wr<=1'b0; scr_waddr<=21'd0; scr_wdata<=8'd0; scr_addr<=21'd0;
            nr_szc_r<=2'd0; sd_lba_r<=32'd0; sd_blkcnt_r<=12'd0; sd_go_pulse<=1'b0;
            sd_br_lba_r<=32'd0; sd_br_go_pulse<=1'b0; br_ptr<=9'd0;
        end else begin
            go_pulse <= 1'b0; desc_reload <= 1'b0;
            pb_wr    <= 1'b0;
            scr_wr   <= 1'b0;
            sd_go_pulse <= 1'b0;
            sd_br_go_pulse <= 1'b0;
            if (eng_done) done_sticky <= 1'b1;

            if (wr_index) begin
                index <= io_wr_data;
                if (io_wr_data == IDX_PBUF) pba <= 8'd0;   // arm page-buffer fill
                if (io_wr_data == IDX_SD_BR_BUF) br_ptr <= 9'd0;  // arm browse-buffer stream
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
                    IDX_LEDMODE: led_show_mode      <= io_wr_data[2:0];
                    IDX_LEDR:    led_show_rgb[23:16] <= io_wr_data;
                    IDX_LEDG:    led_show_rgb[15:8]  <= io_wr_data;
                    IDX_LEDB:    led_show_rgb[7:0]   <= io_wr_data;
                    IDX_NR_SZC:    nr_szc_r          <= io_wr_data[1:0];
                    IDX_SD_LBA0:   sd_lba_r[7:0]     <= io_wr_data;
                    IDX_SD_LBA1:   sd_lba_r[15:8]    <= io_wr_data;
                    IDX_SD_LBA2:   sd_lba_r[23:16]   <= io_wr_data;
                    IDX_SD_LBA3:   sd_lba_r[31:24]   <= io_wr_data;
                    IDX_SD_BLKLO:  sd_blkcnt_r[7:0]  <= io_wr_data;
                    IDX_SD_BLKHI:  sd_blkcnt_r[11:8] <= io_wr_data[3:0];
                    IDX_SD_GO:     sd_go_pulse       <= 1'b1;   // lba/blkcnt already stable
                    IDX_SD_BR_LBA0: sd_br_lba_r[7:0]   <= io_wr_data;
                    IDX_SD_BR_LBA1: sd_br_lba_r[15:8]  <= io_wr_data;
                    IDX_SD_BR_LBA2: sd_br_lba_r[23:16] <= io_wr_data;
                    IDX_SD_BR_LBA3: sd_br_lba_r[31:24] <= io_wr_data;
                    IDX_SD_BR_GO:   sd_br_go_pulse     <= 1'b1;  // sd_br_lba already stable
                    default: ; // STATUS / LASTSTAT are read-only
                endcase
            end

            // Streaming read-back: each 0xED read while index==PBUF returns the
            // current pbuf byte (combinationally above) then advances the pointer.
            if (rd_data && (index == IDX_PBUF))
                pba <= pba + 1'b1;
            if (rd_data && (index == IDX_SD_BR_BUF))
                br_ptr <= br_ptr + 9'd1;
        end
    end
endmodule