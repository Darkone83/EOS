// eos_flash_cmd.v -- Eos 0xEC index / 0xED data command bridge.
// Includes flash, scratch, LED, SD precache, SD browse read, and SD single-
// sector write registers. Existing indices 0x00..0x24 are unchanged.
module eos_flash_cmd #(
    parameter [15:0] PORT_INDEX = 16'h00EC,
    parameter [15:0] PORT_DATA  = 16'h00ED
)(
    input  wire        clk,
    input  wire        cold_rstn,
    input  wire        io_wr_stb,
    input  wire [15:0] io_wr_addr,
    input  wire [7:0]  io_wr_data,
    input  wire        io_rd_stb,
    input  wire [15:0] io_rd_addr,
    output reg  [7:0]  cmd_rd_data,

    output reg         stock_boot,
    output reg         desc_reload,
    output reg  [2:0]  led_show_mode,
    output reg  [23:0] led_show_rgb,
    output reg         blk_erase,

    output wire        cmd_stb,
    output wire [1:0]  cmd_op,
    output wire [3:0]  cmd_bank,
    output wire [12:0] cmd_page,
    output reg         pb_wr,
    output reg  [7:0]  pb_addr,
    output reg  [7:0]  pb_din,
    output wire [7:0]  pb_raddr,
    input  wire [7:0]  pb_rdata,
    input  wire        eng_busy,
    input  wire        eng_done,
    input  wire        eng_refused,
    input  wire [7:0]  eng_last_status,
    input  wire        eng_reload,

    output reg         scr_wr,
    output reg  [20:0] scr_waddr,
    output reg  [7:0]  scr_wdata,
    input  wire        scr_busy,
    input  wire        newrgn_ready,

    output wire [1:0]  nr_szc,
    output wire [31:0] sd_lba,
    output wire [11:0] sd_blkcnt,
    output wire        sd_precache_stb,
    input  wire        sd_eng_busy,
    input  wire        sd_eng_done_sticky,
    input  wire        sd_eng_err,
    input  wire [3:0]  sd_eng_err_code,

    output wire [31:0] sd_br_lba,
    output wire        sd_br_stb,
    output wire [8:0]  sd_br_raddr,
    input  wire [7:0]  sd_br_rdata,
    input  wire        sd_br_busy,
    input  wire        sd_br_done,
    input  wire        sd_br_err,
    input  wire [3:0]  sd_br_err_code,

    // SD single-sector write: host fills 512B through SD_BW_BUF then GO.
    output wire [31:0] sd_bw_lba,
    output wire        sd_bw_stb,
    output reg         sd_bw_we,
    output reg  [8:0]  sd_bw_waddr,
    output reg  [7:0]  sd_bw_wdata,
    input  wire        sd_bw_busy,
    input  wire        sd_bw_done,
    input  wire        sd_bw_err,
    input  wire [3:0]  sd_bw_err_code
);
    localparam [7:0]
        IDX_OP=8'd0, IDX_BANK=8'd1, IDX_PAGELO=8'd2, IDX_PAGEHI=8'd3,
        IDX_PBUF=8'd4, IDX_GO=8'd5, IDX_STATUS=8'd6, IDX_LASTSTAT=8'd7,
        IDX_BOOT=8'd8, IDX_SCR_ALO=8'd9, IDX_SCR_AMID=8'd10, IDX_SCR_AHI=8'd11,
        IDX_SCR_DATA=8'd12, IDX_DESCRELOAD=8'd13, IDX_ERASEBLK=8'd14,
        IDX_LEDMODE=8'd15, IDX_LEDR=8'd16, IDX_LEDG=8'd17, IDX_LEDB=8'd18,
        IDX_NR_SZC=8'd19,
        IDX_SD_LBA0=8'd20, IDX_SD_LBA1=8'd21, IDX_SD_LBA2=8'd22, IDX_SD_LBA3=8'd23,
        IDX_SD_BLKLO=8'd24, IDX_SD_BLKHI=8'd25, IDX_SD_GO=8'd26,
        IDX_SD_STATUS=8'd27, IDX_SD_STATUS2=8'd28,
        IDX_SD_BR_LBA0=8'd29, IDX_SD_BR_LBA1=8'd30, IDX_SD_BR_LBA2=8'd31, IDX_SD_BR_LBA3=8'd32,
        IDX_SD_BR_GO=8'd33, IDX_SD_BR_BUF=8'd34, IDX_SD_BR_STATUS=8'd35, IDX_SD_BR_STATUS2=8'd36,
        IDX_SD_BW_LBA0=8'd37, IDX_SD_BW_LBA1=8'd38, IDX_SD_BW_LBA2=8'd39, IDX_SD_BW_LBA3=8'd40,
        IDX_SD_BW_BUF=8'd41, IDX_SD_BW_GO=8'd42, IDX_SD_BW_STATUS=8'd43, IDX_SD_BW_STATUS2=8'd44;

    reg [7:0]  index;
    reg [1:0]  op_r;
    reg [3:0]  bank_r;
    reg [12:0] page_r;
    reg [7:0]  pba;
    reg        done_sticky;
    reg        go_pulse;
    reg [20:0] scr_addr;
    reg [1:0]  nr_szc_r;
    reg [31:0] sd_lba_r;
    reg [11:0] sd_blkcnt_r;
    reg        sd_go_pulse;
    reg [31:0] sd_br_lba_r;
    reg        sd_br_go_pulse;
    reg [8:0]  br_ptr;
    reg [31:0] sd_bw_lba_r;
    reg        sd_bw_go_pulse;
    reg [8:0]  bw_ptr;

    assign nr_szc=nr_szc_r;
    assign sd_lba=sd_lba_r;
    assign sd_blkcnt=sd_blkcnt_r;
    assign sd_precache_stb=sd_go_pulse;
    assign sd_br_lba=sd_br_lba_r;
    assign sd_br_stb=sd_br_go_pulse;
    assign sd_br_raddr=br_ptr;
    assign sd_bw_lba=sd_bw_lba_r;
    assign sd_bw_stb=sd_bw_go_pulse;
    assign cmd_op=op_r;
    assign cmd_bank=bank_r;
    assign cmd_page=page_r;
    assign cmd_stb=go_pulse;
    assign pb_raddr=pba;

    wire wr_index = io_wr_stb && (io_wr_addr == PORT_INDEX);
    wire wr_data  = io_wr_stb && (io_wr_addr == PORT_DATA);
    wire rd_data  = io_rd_stb && (io_rd_addr == PORT_DATA);

    always @(*) begin
        case (index)
            IDX_STATUS: cmd_rd_data={2'b0,newrgn_ready,scr_busy,eng_reload,eng_refused,done_sticky,eng_busy};
            IDX_SCR_ALO: cmd_rd_data=scr_addr[7:0];
            IDX_SCR_AMID: cmd_rd_data=scr_addr[15:8];
            IDX_SCR_AHI: cmd_rd_data={3'b0,scr_addr[20:16]};
            IDX_LASTSTAT: cmd_rd_data=eng_last_status;
            IDX_OP: cmd_rd_data={6'b0,op_r};
            IDX_BANK: cmd_rd_data={4'b0,bank_r};
            IDX_PAGELO: cmd_rd_data=page_r[7:0];
            IDX_PAGEHI: cmd_rd_data={3'b0,page_r[12:8]};
            IDX_PBUF: cmd_rd_data=pb_rdata;
            IDX_BOOT: cmd_rd_data={7'b0,stock_boot};
            IDX_LEDMODE: cmd_rd_data={5'b0,led_show_mode};
            IDX_LEDR: cmd_rd_data=led_show_rgb[23:16];
            IDX_LEDG: cmd_rd_data=led_show_rgb[15:8];
            IDX_LEDB: cmd_rd_data=led_show_rgb[7:0];
            IDX_NR_SZC: cmd_rd_data={6'b0,nr_szc_r};
            IDX_SD_LBA0: cmd_rd_data=sd_lba_r[7:0];
            IDX_SD_LBA1: cmd_rd_data=sd_lba_r[15:8];
            IDX_SD_LBA2: cmd_rd_data=sd_lba_r[23:16];
            IDX_SD_LBA3: cmd_rd_data=sd_lba_r[31:24];
            IDX_SD_BLKLO: cmd_rd_data=sd_blkcnt_r[7:0];
            IDX_SD_BLKHI: cmd_rd_data={4'b0,sd_blkcnt_r[11:8]};
            IDX_SD_STATUS: cmd_rd_data={4'b0,sd_eng_err_code};
            IDX_SD_STATUS2: cmd_rd_data={5'b0,sd_eng_err,sd_eng_done_sticky,sd_eng_busy};
            IDX_SD_BR_LBA0: cmd_rd_data=sd_br_lba_r[7:0];
            IDX_SD_BR_LBA1: cmd_rd_data=sd_br_lba_r[15:8];
            IDX_SD_BR_LBA2: cmd_rd_data=sd_br_lba_r[23:16];
            IDX_SD_BR_LBA3: cmd_rd_data=sd_br_lba_r[31:24];
            IDX_SD_BR_BUF: cmd_rd_data=sd_br_rdata;
            IDX_SD_BR_STATUS: cmd_rd_data={4'b0,sd_br_err_code};
            IDX_SD_BR_STATUS2: cmd_rd_data={5'b0,sd_br_err,sd_br_done,sd_br_busy};
            IDX_SD_BW_LBA0: cmd_rd_data=sd_bw_lba_r[7:0];
            IDX_SD_BW_LBA1: cmd_rd_data=sd_bw_lba_r[15:8];
            IDX_SD_BW_LBA2: cmd_rd_data=sd_bw_lba_r[23:16];
            IDX_SD_BW_LBA3: cmd_rd_data=sd_bw_lba_r[31:24];
            IDX_SD_BW_STATUS: cmd_rd_data={4'b0,sd_bw_err_code};
            IDX_SD_BW_STATUS2: cmd_rd_data={5'b0,sd_bw_err,sd_bw_done,sd_bw_busy};
            default: cmd_rd_data=8'h00;
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
            sd_bw_lba_r<=32'd0; sd_bw_go_pulse<=1'b0; bw_ptr<=9'd0;
            sd_bw_we<=1'b0; sd_bw_waddr<=9'd0; sd_bw_wdata<=8'd0;
        end else begin
            go_pulse<=1'b0; desc_reload<=1'b0; pb_wr<=1'b0; scr_wr<=1'b0;
            sd_go_pulse<=1'b0; sd_br_go_pulse<=1'b0; sd_bw_go_pulse<=1'b0; sd_bw_we<=1'b0;
            if (eng_done) done_sticky<=1'b1;

            if (wr_index) begin
                index<=io_wr_data;
                if (io_wr_data==IDX_PBUF) pba<=8'd0;
                if (io_wr_data==IDX_SD_BR_BUF) br_ptr<=9'd0;
                if (io_wr_data==IDX_SD_BW_BUF) bw_ptr<=9'd0;
            end else if (wr_data) begin
                case (index)
                    IDX_OP: op_r<=io_wr_data[1:0];
                    IDX_BANK: bank_r<=io_wr_data[3:0];
                    IDX_PAGELO: page_r[7:0]<=io_wr_data;
                    IDX_PAGEHI: page_r[12:8]<=io_wr_data[4:0];
                    IDX_PBUF: begin pb_wr<=1'b1; pb_addr<=pba; pb_din<=io_wr_data; pba<=pba+1'b1; end
                    IDX_DESCRELOAD: desc_reload<=1'b1;
                    IDX_ERASEBLK: blk_erase<=io_wr_data[0];
                    IDX_GO: begin go_pulse<=1'b1; done_sticky<=1'b0; end
                    IDX_SCR_ALO: scr_addr[7:0]<=io_wr_data;
                    IDX_SCR_AMID: scr_addr[15:8]<=io_wr_data;
                    IDX_SCR_AHI: scr_addr[20:16]<=io_wr_data[4:0];
                    IDX_SCR_DATA: begin scr_wr<=1'b1; scr_waddr<=scr_addr; scr_wdata<=io_wr_data; scr_addr<=scr_addr+1'b1; end
                    IDX_BOOT: stock_boot<=io_wr_data[0];
                    IDX_LEDMODE: led_show_mode<=io_wr_data[2:0];
                    IDX_LEDR: led_show_rgb[23:16]<=io_wr_data;
                    IDX_LEDG: led_show_rgb[15:8]<=io_wr_data;
                    IDX_LEDB: led_show_rgb[7:0]<=io_wr_data;
                    IDX_NR_SZC: nr_szc_r<=io_wr_data[1:0];
                    IDX_SD_LBA0: sd_lba_r[7:0]<=io_wr_data;
                    IDX_SD_LBA1: sd_lba_r[15:8]<=io_wr_data;
                    IDX_SD_LBA2: sd_lba_r[23:16]<=io_wr_data;
                    IDX_SD_LBA3: sd_lba_r[31:24]<=io_wr_data;
                    IDX_SD_BLKLO: sd_blkcnt_r[7:0]<=io_wr_data;
                    IDX_SD_BLKHI: sd_blkcnt_r[11:8]<=io_wr_data[3:0];
                    IDX_SD_GO: sd_go_pulse<=1'b1;
                    IDX_SD_BR_LBA0: sd_br_lba_r[7:0]<=io_wr_data;
                    IDX_SD_BR_LBA1: sd_br_lba_r[15:8]<=io_wr_data;
                    IDX_SD_BR_LBA2: sd_br_lba_r[23:16]<=io_wr_data;
                    IDX_SD_BR_LBA3: sd_br_lba_r[31:24]<=io_wr_data;
                    IDX_SD_BR_GO: sd_br_go_pulse<=1'b1;
                    IDX_SD_BW_LBA0: sd_bw_lba_r[7:0]<=io_wr_data;
                    IDX_SD_BW_LBA1: sd_bw_lba_r[15:8]<=io_wr_data;
                    IDX_SD_BW_LBA2: sd_bw_lba_r[23:16]<=io_wr_data;
                    IDX_SD_BW_LBA3: sd_bw_lba_r[31:24]<=io_wr_data;
                    IDX_SD_BW_BUF: begin
                        sd_bw_we<=1'b1; sd_bw_waddr<=bw_ptr; sd_bw_wdata<=io_wr_data; bw_ptr<=bw_ptr+9'd1;
                    end
                    IDX_SD_BW_GO: sd_bw_go_pulse<=1'b1;
                    default: ;
                endcase
            end

            if (rd_data && index==IDX_PBUF) pba<=pba+1'b1;
            if (rd_data && index==IDX_SD_BR_BUF) br_ptr<=br_ptr+9'd1;
        end
    end
endmodule
