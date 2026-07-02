// eos_boot_ctrl.v -- 1.6 LFRAME# abort (clean, mode16_n path ONLY).
// =====================================================================
// ONE job: on a 1.6 Xbox, hold LFRAME# LOW for the DURATION of each served
// memory-read cycle so the Xyclops stays out and the FPGA's LPC backend serves.
// NO D0 logic here (D0 is owned by the top).
//
// This is the ModXo model, which is the known-good reference on the target rig:
// ModXo's PIO asserts LFRAME (side 0) the instant it decodes a memory-read
// cycle-type it will serve, HOLDS it through the address nibbles AND the data it
// drives back, and releases (side 1) only at the end of the transaction. It is a
// HELD WINDOW, not a fixed-width pulse -- a short pulse lets the Xyclops re-engage
// mid-cycle and fight the serve. serving_mem (from eos_lpc_loader) is exactly that
// window: high from cycle-type decode through TAR_EXIT, mem-read only.
//
//     lframe_oe = mode_16 & serving_mem
//
//   1.0-1.5 : mode_16=0 -> lframe_oe always 0, LFRAME# released (input as before).
//   1.6     : LFRAME# low for exactly the served cycle, then released.
//
// LFRAME# is OPEN-DRAIN at the pad: the top does
//     assign lpc_lframe_n = lframe_oe ? 1'b0 : 1'bz;
// =====================================================================
module eos_boot_ctrl (
    input  wire        clk,          // lclk (Xbox LPC clock domain)
    input  wire        resetn,

    input  wire        mode_16,      // 1 = 1.6 (arm abort), 0 = 1.0-1.5 (idle)
    input  wire        serving_mem,  // loader: high for the served mem-read window

    output wire        lframe_oe,    // 1 = pull LFRAME# low, 0 = release
    output reg  [15:0] abort_count,  // diagnostics -> serve HUD (one per served cycle)
    output wire        abort_active  // 1 while holding LFRAME# low
);
    // Hold LFRAME# low for exactly the served mem-read window, 1.6 only.
    assign lframe_oe    = mode_16 & serving_mem;
    assign abort_active = lframe_oe;

    // count one abort per served cycle (rising edge of the window) for the HUD
    reg sm_d;
    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            sm_d <= 1'b0; abort_count <= 16'd0;
        end else begin
            sm_d <= serving_mem;
            if (mode_16 & serving_mem & ~sm_d) abort_count <= abort_count + 1'b1;
        end
    end
endmodule