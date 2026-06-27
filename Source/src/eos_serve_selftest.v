// eos_serve_selftest.v -- DIAGNOSTIC backend. Drop-in replacement for the SDRAM
// backend's loader-facing port. Serves byte = mem_addr[7:0] with one-cycle latency,
// NO SDRAM, NO flash, NO CDC. Purpose: isolate the LPC delivery path on real silicon.
//
// USE: in eos_hdmi_top.v, comment out the eos_sdram_backend instance and instantiate
// this in its place (same mem_req/mem_addr/mem_valid/mem_data wires). Rebuild, boot the
// Xbox, and capture LAD[3:0]+LFRAME#+LCLK on a logic analyzer.
//   * Each MEM_READ at address A must read back data byte == A[7:0], lower nibble first.
//   * Clean pattern on every read  -> LPC DELIVERY is good; the frag is the SDRAM serve
//     path (PLL phase / port map / preload-done) OR onboard-TSOP contention on LAD.
//   * Garbled/contended nibbles     -> delivery/timing or two devices driving LAD.
// (The Xbox will NOT boot from this -- it's not a real BIOS. We're reading the wire.)
module eos_serve_selftest (
    input  wire        lclk,
    input  wire        lreset_n,
    input  wire        mem_req,
    input  wire [17:0] mem_addr,
    output reg         mem_valid,
    output reg  [7:0]  mem_data
);
    always @(posedge lclk or negedge lreset_n) begin
        if (!lreset_n) begin
            mem_valid <= 1'b0; mem_data <= 8'h00;
        end else begin
            mem_valid <= mem_req;            // 1-cycle pulse, mirrors the real backend
            if (mem_req) mem_data <= mem_addr[7:0];
        end
    end
endmodule