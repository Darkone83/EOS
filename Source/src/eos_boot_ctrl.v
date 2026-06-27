// eos_boot_ctrl.v -- D0 / LFRAME# boot control (1.0-1.5 D0 + 1.6 LFRAME abort).
// =====================================================================
// Owns the two "make the box boot US, not the onboard flash" signals. Both are
// OPEN-DRAIN: we pull LOW or release (Hi-Z). We NEVER drive high, so on the
// current test rig (D0 hard-grounded externally) pulling low is redundant and
// releasing leaves it grounded -- behaviour is unchanged ("same ole same ole").
//
//   1.0-1.5 : D0.  Pull D0 low to disable the onboard TSOP and force LPC boot.
//             Release (Hi-Z) to let the box boot stock/onboard.
//   1.6     : the onboard flash sits behind the Xyclops, which answers the
//             MCPX's boot memory-reads and fights an external LPC peripheral.
//             We don't ground LFRAME# forever; we issue a spec-legal LPC ABORT
//             (Intel LPC 1.1 sec 4.3.1.13: LFRAME# low >= 4 clocks) to make the
//             Xyclops back off, then serve from our backend.
//
// mode_16 selects the mechanism per revision; enable releases everything for a
// stock boot. abort_req is the trigger (wire to the LPC mem-read detect at the
// top; the EXACT trigger condition + ABORT_CLKS are bench-tuned against a 1.6
// LPC capture). Diagnostics (abort_count / *_active) feed the serve HUD.
// =====================================================================
module eos_boot_ctrl #(
    parameter integer ABORT_CLKS = 4        // LFRAME# low duration; >= 4 per LPC spec
)(
    input  wire        clk,                  // lclk (Xbox LPC clock domain)
    input  wire        resetn,

    // straps / config (board pads; default = active 1.5, matching the test rig)
    input  wire        mode_16,              // 1 = Xbox 1.6 (LFRAME abort), 0 = 1.0-1.5 (D0)
    input  wire        enable,               // 1 = modchip active, 0 = release for stock boot

    // abort trigger -- a memory-read cycle the Xyclops would answer (1.6 only)
    input  wire        abort_req,            // level or pulse; rising edge fires one abort

    // open-drain controls: OE=1 -> pull pin LOW; OE=0 -> release (Hi-Z). Data is
    // always 0, so the top does:  assign pin = oe ? 1'b0 : 1'bz;
    output wire        d0_oe,
    output wire        lframe_oe,

    // diagnostics (serve HUD)
    output reg  [15:0] abort_count,
    output wire        d0_active,            // currently pulling D0 low
    output wire        abort_active          // currently pulling LFRAME# low
);
    // ---- D0 : 1.0-1.5 mechanism --------------------------------------------
    // Pull D0 low while active on a non-1.6 box. On 1.6 the mechanism is the
    // LFRAME abort instead, so D0 is released.
    assign d0_oe     = enable & ~mode_16;
    assign d0_active = d0_oe;

    // ---- LFRAME# abort : 1.6 mechanism -------------------------------------
    wire abort_en = enable & mode_16;

    // one abort per rising edge of abort_req (don't re-fire while it's held)
    reg abort_req_d;
    always @(posedge clk or negedge resetn)
        if (!resetn) abort_req_d <= 1'b0;
        else         abort_req_d <= abort_req;
    wire abort_req_edge = abort_req & ~abort_req_d;

    reg [7:0] acnt;        // wide enough for any small ABORT_CLKS
    reg       aborting;

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            acnt <= 8'd0; aborting <= 1'b0; abort_count <= 16'd0;
        end else begin
            if (aborting) begin
                if (acnt >= (ABORT_CLKS-1)) aborting <= 1'b0;
                else                        acnt     <= acnt + 1'b1;
            end else if (abort_en & abort_req_edge) begin
                aborting    <= 1'b1;
                acnt        <= 8'd0;
                abort_count <= abort_count + 1'b1;
            end
        end
    end

    assign lframe_oe    = aborting;
    assign abort_active = aborting;
endmodule