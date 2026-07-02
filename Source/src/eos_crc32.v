// eos_crc32.v -- streaming CRC-32 over the SDRAM scratch region.
// =====================================================================
// Given a byte length, streams scratch[0 .. len-1] through the backend's scratch
// read port and produces the standard CRC-32 (IEEE 802.3 / zlib / PNG):
//   polynomial 0xEDB88320 (reflected), init 0xFFFFFFFF, final XOR 0xFFFFFFFF.
// This MUST match the loader's host-side CRC so VALIDATE compares like-for-like.
//
// The scratch read port here is muxed to eos_sdram_backend in the top, shared
// with eos_bank_ctrl's commit reads -- i2c sequences VALIDATE (this unit) before
// COMMIT (bank_ctrl), so they never drive the port at the same time.
//
// Runs in the clk_sd domain (same as the backend scratch port).
// =====================================================================
module eos_crc32 (
    input  wire        clk,
    input  wire        resetn,

    input  wire        go,           // pulse: start CRC over scratch[0 .. len-1]
    input  wire [20:0] len,          // byte count
    output reg         busy,
    output reg         done,         // 1-cycle pulse when crc is valid
    output reg  [31:0] crc,          // final CRC (post-complement)

    // scratch read (muxed to the backend in the top)
    output reg         scr_rd,
    output reg  [20:0] scr_raddr,
    input  wire [7:0]  scr_rdata,
    input  wire        scr_rvalid,
    input  wire        scr_busy
);
    // one-byte reflected CRC-32 update
    function [31:0] crc_byte;
        input [31:0] c;
        input [7:0]  d;
        integer i;
        reg [31:0] x;
        begin
            x = c ^ {24'b0, d};
            for (i = 0; i < 8; i = i + 1)
                x = x[0] ? ((x >> 1) ^ 32'hEDB88320) : (x >> 1);
            crc_byte = x;
        end
    endfunction

    localparam S_IDLE = 2'd0,
               S_READ = 2'd1,   // issue a scratch read
               S_WAIT = 2'd2,   // accumulate the returned byte
               S_DONE = 2'd3;

    reg [1:0]  st;
    reg [20:0] idx;
    reg [20:0] nbytes;
    reg [31:0] acc;

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            st<=S_IDLE; busy<=1'b0; done<=1'b0; crc<=32'd0;
            scr_rd<=1'b0; scr_raddr<=21'd0; idx<=21'd0; nbytes<=21'd0; acc<=32'hFFFFFFFF;
        end else begin
            done   <= 1'b0;
            scr_rd <= 1'b0;
            case (st)
                S_IDLE: begin
                    busy <= 1'b0;
                    if (go) begin
                        if (len == 21'd0) begin
                            crc  <= 32'hFFFFFFFF ^ 32'hFFFFFFFF;   // empty -> 0x00000000
                            done <= 1'b1;
                        end else begin
                            busy   <= 1'b1;
                            idx    <= 21'd0;
                            nbytes <= len;
                            acc    <= 32'hFFFFFFFF;
                            st     <= S_READ;
                        end
                    end
                end

                S_READ: begin
                    if (!scr_busy) begin
                        scr_rd    <= 1'b1;
                        scr_raddr <= idx;
                        st        <= S_WAIT;
                    end
                end

                S_WAIT: begin
                    if (scr_rvalid) begin
                        acc <= crc_byte(acc, scr_rdata);
                        if (idx == nbytes - 21'd1) st <= S_DONE;
                        else begin idx <= idx + 21'd1; st <= S_READ; end
                    end
                end

                S_DONE: begin
                    crc  <= acc ^ 32'hFFFFFFFF;   // final complement
                    done <= 1'b1;
                    busy <= 1'b0;
                    st   <= S_IDLE;
                end

                default: st <= S_IDLE;
            endcase
        end
    end
endmodule