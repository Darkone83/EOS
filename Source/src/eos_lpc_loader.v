// eos_lpc_loader.v -- Direct-LCLK LPC responder.
//
// PUSH-BUFFER TEST BUILD:
//
// Goal:
// - Keep the known-good OpenXenium-style timing that stopped FRAG.
// - Once a byte is available, latch it into read_buffer.
// - Then push READY/DATA/TAR with a fixed deterministic sequence.
// - Keep MEM_READ, MEM_WRITE, IO_READ, IO_WRITE handling.
//
// Timing:
//   TAR1          Hi-Z
//   TAR2          1111
//   SYNCING       0101 until read/write is ready
//   SYNC_COMPLETE 0000
//   READ_DATA0    low nibble
//   READ_DATA1    high nibble
//   TAR_EXIT      1111
//
// D0 is assumed physically grounded for this test.

module eos_lpc_loader #(
    parameter integer SYNC = 3
)(
    input  wire        clk,                 // DIRECT: Xbox LPC LCLK
    input  wire        lreset_n,

    input  wire        lclk_pin,            // unused in direct-LCLK mode
    input  wire        lframe_n_pin,        // accepted, not used to gate START
    input  wire [3:0]  lad_pin,

    output reg  [3:0]  lad_out,
    output wire        lad_oe,

    output reg         mem_req,
    output wire [20:0] mem_addr,        // widened: full 2MB logical (A20:A0), no 256K wrap
    input  wire        mem_valid,
    input  wire [7:0]  mem_data,

    // Bank register exposure (0xEF). Lets the bank controller see selections
    // without re-decoding LPC. ef_wr pulses 1 cycle on a 0xEF write.
    output reg         ef_wr,
    output reg  [7:0]  ef_data,          // value written to 0xEF (low nibble = bank)

    // Generic I/O write exposure for the flash command bridge (0xEC/0xED).
    // io_wr_stb pulses 1 cycle on ANY committed I/O write; the bridge filters
    // for its own ports. cmd_rd_data feeds the read path for a 0xED read.
    output reg         io_wr_stb,
    output reg  [15:0] io_wr_addr,
    output reg  [7:0]  io_wr_data,
    output reg         io_rd_stb,        // 1-cycle pulse on a committed I/O read
    output reg  [15:0] io_rd_addr,
    input  wire [7:0]  cmd_rd_data,

    output reg  [3:0]  state
);

    // Keep the original HUD-friendly state numbering.
    localparam WAIT_START    = 4'd0;
    localparam CYCTYPE       = 4'd1;
    localparam ADDRESS       = 4'd2;
    localparam TAR1          = 4'd3;
    localparam TAR2          = 4'd4;
    localparam SYNCING       = 4'd5;
    localparam SYNC_COMPLETE = 4'd6;
    localparam READ_DATA0    = 4'd7;
    localparam READ_DATA1    = 4'd8;
    localparam TAR_EXIT      = 4'd9;
    localparam WRITE_DATA0   = 4'd10;
    localparam WRITE_DATA1   = 4'd11;

    localparam [1:0] CYC_IO_READ   = 2'd0;
    localparam [1:0] CYC_IO_WRITE  = 2'd1;
    localparam [1:0] CYC_MEM_READ  = 2'd2;
    localparam [1:0] CYC_MEM_WRITE = 2'd3;

    // Known-good path used a short sync delay. Keep it.
    localparam [2:0] MIN_SYNC_WAIT = 3'd3;

    // Avoid unused warnings.
    wire _unused_lclk   = lclk_pin;
    wire _unused_sync   = |SYNC;

    wire [3:0] lad_in = lad_pin;
    wire _unused_lframe = lframe_n_pin;

    // -------------------------------------------------------------------------
    // Transaction state
    // -------------------------------------------------------------------------

    reg [1:0]  cycle_type;

    reg [20:0] lpc_addr;
    reg [20:0] mem_addr_r;

    reg [3:0]  count;

    // read_buffer is the pushed LPC response byte.
    // Once loaded, SYNC_COMPLETE/DATA0/DATA1/TAR_EXIT are deterministic.
    reg [7:0]  read_buffer;
    reg [7:0]  write_data;

    reg        byte_ready;
    reg        response_armed;

    reg [2:0]  sync_wait;

    // Minimal Xenium-compatible registers.
    reg [7:0] reg_00ee_write;
    reg [7:0] reg_00ef_write;

    wire [7:0] reg_00ee_read = 8'h55;
    wire [7:0] reg_00ef_read = reg_00ef_write;   // echo last write so SW can verify the 0xEF path

    assign mem_addr = mem_addr_r;

    // -------------------------------------------------------------------------
    // LAD output ownership
    // -------------------------------------------------------------------------
    //
    // Target drives only during target-owned response phases.
    // TAR1 and host WRITE_DATA phases remain Hi-Z.

    assign lad_oe = (state == TAR2)          ||
                    (state == SYNCING)       ||
                    (state == SYNC_COMPLETE) ||
                    (state == READ_DATA0)    ||
                    (state == READ_DATA1)    ||
                    (state == TAR_EXIT);

    always @(*) begin
        case (state)
            TAR2:          lad_out = 4'b1111;             // target turnaround
            SYNCING:       lad_out = 4'b0101;             // wait sync
            SYNC_COMPLETE: lad_out = 4'b0000;             // ready
            READ_DATA0:    lad_out = read_buffer[3:0];    // low nibble first
            READ_DATA1:    lad_out = read_buffer[7:4];    // high nibble second
            TAR_EXIT:      lad_out = 4'b1111;             // peripheral-to-host turnaround
            default:       lad_out = 4'b1111;
        endcase
    end

    // -------------------------------------------------------------------------
    // Main LPC FSM
    // -------------------------------------------------------------------------

    always @(posedge clk or negedge lreset_n) begin
        if (!lreset_n) begin
            state          <= WAIT_START;

            cycle_type     <= CYC_IO_READ;

            lpc_addr       <= 21'd0;
            mem_addr_r     <= 21'd0;

            count          <= 4'd0;

            read_buffer    <= 8'd0;
            write_data     <= 8'd0;

            byte_ready     <= 1'b0;
            response_armed <= 1'b0;
            sync_wait      <= 3'd0;

            reg_00ee_write <= 8'h01;
            reg_00ef_write <= 8'h01;

            mem_req        <= 1'b0;
            ef_wr          <= 1'b0;
            ef_data        <= 8'd0;

            io_wr_stb      <= 1'b0;
            io_wr_addr     <= 16'd0;
            io_wr_data     <= 8'd0;
            io_rd_stb      <= 1'b0;
            io_rd_addr     <= 16'd0;
        end else begin
            mem_req <= 1'b0;
            ef_wr   <= 1'b0;
            io_wr_stb <= 1'b0;
            io_rd_stb <= 1'b0;

            // MEM_READ backend result.
            //
            // Important:
            // Once mem_valid arrives, immediately latch into read_buffer.
            // From that point the outgoing LPC response no longer depends on
            // mem_data changing or CDC timing.
            if (mem_valid) begin
                read_buffer <= mem_data;
                byte_ready  <= 1'b1;
            end

            case (state)

                // -------------------------------------------------------------
                // LPC START.
                // START field is 0000.
                // LFRAME# is intentionally not required in this build.
                // -------------------------------------------------------------
                WAIT_START: begin
                    lpc_addr       <= 21'd0;
                    count          <= 4'd0;
                    byte_ready     <= 1'b0;
                    response_armed <= 1'b0;
                    sync_wait      <= 3'd0;

                    if (lad_in == 4'h0)
                        state <= CYCTYPE;
                end

                // -------------------------------------------------------------
                // Cycle type.
                //
                // LPC encodings:
                //   000x = IO read
                //   001x = IO write
                //   010x = memory read
                //   011x = memory write
                // -------------------------------------------------------------
                CYCTYPE: begin
                    lpc_addr       <= 21'd0;
                    byte_ready     <= 1'b0;
                    response_armed <= 1'b0;
                    sync_wait      <= 3'd0;

                    if (lad_in[3:1] == 3'b000) begin
                        cycle_type <= CYC_IO_READ;
                        count      <= 4'd3;
                        state      <= ADDRESS;
                    end else if (lad_in[3:1] == 3'b001) begin
                        cycle_type <= CYC_IO_WRITE;
                        count      <= 4'd3;
                        state      <= ADDRESS;
                    end else if (lad_in[3:1] == 3'b010) begin
                        cycle_type <= CYC_MEM_READ;
                        count      <= 4'd7;
                        state      <= ADDRESS;
                    end else if (lad_in[3:1] == 3'b011) begin
                        cycle_type <= CYC_MEM_WRITE;
                        count      <= 4'd7;
                        state      <= ADDRESS;
                    end else begin
                        state <= WAIT_START;
                    end
                end

                // -------------------------------------------------------------
                // Address capture.
                //
                // Memory cycles:
                //   count 7 : ignored high address nibble
                //   count 6 : ignored high address nibble
                //   count 5 : captures A20 from LAD[0]
                //   count 4 : captures A19:A16
                //   count 3 : captures A15:A12
                //   count 2 : captures A11:A8
                //   count 1 : captures A7:A4
                //   count 0 : captures A3:A0
                //
                // IO cycles:
                //   count 3 : A15:A12
                //   count 2 : A11:A8
                //   count 1 : A7:A4
                //   count 0 : A3:A0
                // -------------------------------------------------------------
                ADDRESS: begin
                    if (cycle_type == CYC_MEM_READ || cycle_type == CYC_MEM_WRITE) begin
                        if (count == 4'd5) begin
                            lpc_addr[20] <= lad_in[0];
                        end else if (count == 4'd4) begin
                            lpc_addr[19:16] <= lad_in;
                        end else if (count == 4'd3) begin
                            lpc_addr[15:12] <= lad_in;
                        end else if (count == 4'd2) begin
                            lpc_addr[11:8] <= lad_in;
                        end else if (count == 4'd1) begin
                            lpc_addr[7:4] <= lad_in;
                        end else if (count == 4'd0) begin
                            lpc_addr[3:0] <= lad_in;

                            // Final wrapped 256 KB BIOS offset.
                            mem_addr_r <= {
                                lpc_addr[20:4],
                                lad_in
                            };

                            if (cycle_type == CYC_MEM_READ) begin
                                // Request byte from SDRAM backend.
                                mem_req        <= 1'b1;
                                byte_ready     <= 1'b0;
                                response_armed <= 1'b0;
                                state          <= TAR1;
                            end else begin
                                // MEM_WRITE: consume two host data nibbles, then ACK.
                                write_data <= 8'd0;
                                state      <= WRITE_DATA0;
                            end
                        end
                    end else begin
                        // IO address collection: A15..A0.
                        if (count == 4'd3) begin
                            lpc_addr[15:12] <= lad_in;
                        end else if (count == 4'd2) begin
                            lpc_addr[11:8] <= lad_in;
                        end else if (count == 4'd1) begin
                            lpc_addr[7:4] <= lad_in;
                        end else if (count == 4'd0) begin
                            lpc_addr[3:0] <= lad_in;

                            // 0x00EC..0x00EF support: EC/ED = flash command
                            // bridge (index/data), EE/EF = LED/bank registers.
                            if (lpc_addr[7:4] == 4'hE && lad_in[3:2] == 2'b11) begin
                                if (cycle_type == CYC_IO_READ) begin
                                    case (lad_in[1:0])
                                        2'b10:   read_buffer <= reg_00ee_read;  // 0xEE
                                        2'b11:   read_buffer <= reg_00ef_read;  // 0xEF
                                        default: read_buffer <= cmd_rd_data;    // 0xEC/0xED
                                    endcase

                                    // generic read strobe (bridge advances its
                                    // page-buffer pointer on a 0xED read)
                                    io_rd_stb  <= 1'b1;
                                    io_rd_addr <= {lpc_addr[15:4], lad_in};

                                    byte_ready     <= 1'b1;
                                    response_armed <= 1'b0;
                                    state          <= TAR1;
                                end else begin
                                    write_data <= 8'd0;
                                    state      <= WRITE_DATA0;
                                end
                            end else begin
                                // Unsupported IO cycle: ignore and release.
                                state <= WAIT_START;
                            end
                        end
                    end

                    if (count != 4'd0)
                        count <= count - 1'b1;
                end

                // -------------------------------------------------------------
                // Write data phase.
                // Host supplies low nibble first, then high nibble.
                // FPGA remains Hi-Z here.
                // -------------------------------------------------------------
                WRITE_DATA0: begin
                    write_data[3:0] <= lad_in;
                    state           <= WRITE_DATA1;
                end

                WRITE_DATA1: begin
                    write_data[7:4] <= lad_in;

                    // Commit minimal IO writes.
                    // MEM_WRITE is consumed and ACKed, but not written to SDRAM.
                    if (cycle_type == CYC_IO_WRITE) begin
                        // Generic strobe: the flash command bridge consumes
                        // 0xEC/0xED; EE/EF are also pulsed but the bridge ignores
                        // them (it matches only its own two ports).
                        io_wr_stb  <= 1'b1;
                        io_wr_addr <= lpc_addr[15:0];
                        io_wr_data <= {lad_in, write_data[3:0]};

                        case (lpc_addr[1:0])
                            2'b10: reg_00ee_write <= {lad_in, write_data[3:0]}; // 0xEE
                            2'b11: begin                                        // 0xEF
                                reg_00ef_write <= {lad_in, write_data[3:0]};
                                ef_wr          <= 1'b1;
                                ef_data        <= {lad_in, write_data[3:0]};
                            end
                            default: ; // 0xEC/0xED: bridge handles via io_wr_stb
                        endcase
                    end

                    byte_ready     <= 1'b1;
                    response_armed <= 1'b0;
                    state          <= TAR1;
                end

                // -------------------------------------------------------------
                // Host-to-target turnaround.
                // Hi-Z for one LPC clock.
                // -------------------------------------------------------------
                TAR1: begin
                    state <= TAR2;
                end

                // -------------------------------------------------------------
                // Target turnaround.
                // Drive 1111 for one LPC clock.
                // This phase is part of the known-good no-FRAG path.
                // -------------------------------------------------------------
                TAR2: begin
                    sync_wait      <= MIN_SYNC_WAIT;
                    response_armed <= 1'b0;
                    state          <= SYNCING;
                end

                // -------------------------------------------------------------
                // Wait-sync.
                //
                // Drive 0101 until:
                //   - minimum wait expires
                //   - response byte/ACK is ready
                //
                // Once both are true, arm the fixed push sequence.
                // -------------------------------------------------------------
                SYNCING: begin
                    if (sync_wait != 3'd0) begin
                        sync_wait <= sync_wait - 1'b1;
                    end else if (byte_ready) begin
                        response_armed <= 1'b1;
                        state          <= SYNC_COMPLETE;
                    end
                end

                // -------------------------------------------------------------
                // Fixed push sequence begins here.
                // Do not modify read_buffer after this point for the transaction.
                // -------------------------------------------------------------
                SYNC_COMPLETE: begin
                    if (cycle_type == CYC_MEM_READ || cycle_type == CYC_IO_READ)
                        state <= READ_DATA0;
                    else
                        state <= TAR_EXIT;
                end

                READ_DATA0: begin
                    state <= READ_DATA1;
                end

                READ_DATA1: begin
                    state <= TAR_EXIT;
                end

                TAR_EXIT: begin
                    cycle_type     <= CYC_IO_READ;
                    response_armed <= 1'b0;
                    state          <= WAIT_START;
                end

                default: begin
                    state <= WAIT_START;
                end

            endcase
        end
    end

endmodule