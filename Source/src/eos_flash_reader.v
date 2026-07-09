// eos_flash_reader.v -- robust standard-SPI (0x03) reader, RESTARTABLE.
// A 'start' pulse aborts any in-flight read and begins a fresh one at 'addr'.
// On (re)start CS is deasserted for a few cycles (PRECS) so the flash terminates
// the prior operation and accepts a new command -- without this, an abort with CS
// held low just continues the old stream and returns wrong bytes.
// SCK divided by SCK_DIV; MISO sampled at end of SCK-high for clean alignment.
//
// -----------------------------------------------------------------------------
// PHASE 4: 'stall' -- backpressure for multi-byte bursts.
// -----------------------------------------------------------------------------
// With len > 1 the reader emits a byte every 8*PERIOD clocks whether or not the
// sink is ready. 'stall' lets the sink hold the burst:
//
//   * Honoured ONLY in DATA, and ONLY at pc == 0 (a bit boundary).
//   * pc == 0 is the one point where sck_lvl == 0, so flash_clk parks LOW --
//     which is what SPI mode 0 requires of an idle clock.
//   * CS# stays asserted. The burst is PAUSED, not aborted.
//   * SPI NOR is a fully static interface: no minimum SCK frequency, no maximum
//     CS-low time. The clock may stop indefinitely between bits.
//
// ZERO-SLOP GUARANTEE: a byte is emitted at pc_last (pc == PERIOD-1). If the sink
// raises 'stall' on that same edge, the reader sees it at pc == 0 on the very next
// clock and holds. The next byte cannot complete for another 7*PERIOD clocks.
// Therefore AT MOST ZERO further bytes are produced after stall asserts, and a
// one-entry sink buffer can never overflow. No FIFO is required.
//
// Tie stall = 1'b0 to restore the pre-Phase-4 behaviour exactly.
// -----------------------------------------------------------------------------
module eos_flash_reader #(
    parameter         FLASH_BASE = 24'h200000,
    parameter integer SCK_DIV    = 2,
    parameter integer CSH_CYCLES = 8
)(
    input  wire        clk, rstn, start,
    input  wire        stall,            // 1 = hold the burst at a bit boundary
    input  wire [23:0] addr,
    input  wire [8:0]  len,
    output reg         busy, done, dvalid,
    output reg  [7:0]  dout,
    output reg         flash_cs_n, flash_clk,
    output reg         flash_mosi,
    input  wire        flash_miso
);
    localparam integer PERIOD = 2*SCK_DIV;
    localparam IDLE=0, PRECS=1, CMD=2, DATA=3, FIN=4;
    reg [2:0]  st;
    reg [31:0] sh;
    reg [5:0]  obits;
    reg [7:0]  rx;
    reg [2:0]  rbits;
    reg [8:0]  bytes_left;
    reg [15:0] pc;
    reg [3:0]  csh;
    reg [23:0] paddr; reg [8:0] plen;
    wire pc_last = (pc == PERIOD-1);
    wire sck_lvl = (pc >= SCK_DIV);

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            st<=IDLE; busy<=0; done<=0; dvalid<=0; flash_cs_n<=1; flash_clk<=0;
            flash_mosi<=0; pc<=0; csh<=0;
        end else begin
            dvalid<=0; done<=0;
            if (start) begin                       // (re)start: deassert CS first
                paddr<=addr; plen<=len;
                flash_cs_n<=1; flash_clk<=0; busy<=1; pc<=0; csh<=0; st<=PRECS;
            end else begin
                case (st)
                    IDLE: begin flash_clk<=0; flash_cs_n<=1; pc<=0; end
                    PRECS: begin                   // hold CS high tCSH, then issue command
                        flash_cs_n<=1; flash_clk<=0;
                        if (csh==CSH_CYCLES-1) begin
                            sh<={8'h03,FLASH_BASE+paddr}; obits<=6'd32;
                            bytes_left<=plen; rbits<=0; flash_mosi<=1'b0;
                            flash_cs_n<=0; pc<=0; st<=CMD;
                        end else csh<=csh+1'b1;
                    end
                    CMD: begin
                        flash_clk<=sck_lvl;
                        if (pc==0) flash_mosi <= sh[31];
                        if (pc_last) begin
                            pc<=0; sh<={sh[30:0],1'b0}; obits<=obits-1'b1;
                            if (obits==1) begin st<=DATA; pc<=0; rbits<=0; end
                        end else pc<=pc+1'b1;
                    end
                    DATA: begin
                        flash_clk<=sck_lvl;
                        if (stall && pc==0) begin
                            // Hold at a bit boundary. sck_lvl==0 here, so the
                            // registered flash_clk goes low and stays low. CS#
                            // remains asserted; nothing else advances.
                        end else if (pc_last) begin
                            pc<=0;
                            if (rbits==3'd7) begin
                                dout<={rx[6:0],flash_miso}; dvalid<=1'b1; rbits<=0;
                                if (bytes_left==1) st<=FIN; else bytes_left<=bytes_left-1'b1;
                            end else begin rx<={rx[6:0],flash_miso}; rbits<=rbits+1'b1; end
                        end else pc<=pc+1'b1;
                    end
                    FIN: begin flash_cs_n<=1; flash_clk<=0; pc<=0; busy<=0; done<=1; st<=IDLE; end
                endcase
            end
        end
    end
endmodule