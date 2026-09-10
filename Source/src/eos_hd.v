// eos_hd.v -- EOS-native HD (ADV7511) controller. Replaces the role of an
// STM-based X-HD/HD+ device on boards with no onboard STM32. See
// eos_hd_integration_spec.md for the full design; this file implements it.
//
// Implements the active X-HD application behavior in FPGA logic: ADV7511
// initialization, encoder-specific setup, standalone VIC following, the BIOS
// SMBus settings protocol, and the complete BIOS
// table-driven mode applicator.
//
// X-HD APPLICATION CONFORMANCE:
//   - 1.6 selects the X-HD Xcalibur init profile before init_adv().
//   - Pre-1.6 uses XHD_PRE16_FOCUS to select the X-HD Conexant or Focus build
//     profile before init_adv().
//   - BIOS-reported encoder changes run init_adv_encoder_specific() exactly at
//     the same point as X-HD's bios_loop().
//   - FORCE_STANDALONE is diagnostic-only; normal compatibility uses 0.
//
// HD status (LED, GPIO 30/31) is entirely self-contained here -- no path
// through eos_bank_led.v or eos_flash_cmd.v's LED_SHOW mechanism. Two
// separate LED systems, zero shared mechanism, by design (see
// eos_hd_integration_spec.md §7.1).
module eos_hd #(
    parameter [6:0] ADV_ADDR = 7'h39,   // 7-bit form (0x72 8-bit write-address
                                          // >> 1). op_target_addr feeds
                                          // {op_target_addr, rw} in the master
                                          // engine, which builds the real
                                          // 8-bit address+R/W byte itself --
                                          // passing the already-8-bit 0x72
                                          // here would double-shift, sending
                                          // 0xE4/0xE5 instead of the real
                                          // 0x72/0x73. This exact mistake was
                                          // caught only by external review;
                                          // it hid from every simulation in
                                          // this project because the fake ADV
                                          // slave in every testbench modeled
                                          // its own address off this same
                                          // (wrong) parameter instead of the
                                          // real hardware value -- matching
                                          // the bug instead of catching it.
    parameter [23:0] DLY_30MS = 24'd1_944_000,   // 30ms @ 64.8MHz -- override
                                                   // for fast simulation
    parameter [23:0] DLY_50MS = 24'd3_240_000,    // 50ms @ 64.8MHz -- override
                                                   // for fast simulation
    parameter [23:0] DLY_10MS = 24'd648_000,      // X-HD WRITE_SET_MODE waits
                                                   // 10ms before NVIC_SystemReset().
    parameter integer MASTER_SCL_LOW_CYCLES  = 745,
    parameter integer MASTER_SCL_HIGH_CYCLES = 502,
                                                   // X-HD V0.1.8 STM32F0 I2C1 timing:
                                                   // 8 MHz HSI, TIMINGR=0x00303D5B
                                                   // -> 11.50 us low / 7.75 us high,
                                                   // about 51.95 kHz on the wire.
    // STM32F0 master START/STOP timings are generated from SCLL/SCLH too:
    //   SCLL -> tBUF and tSU:STA
    //   SCLH -> tHD:STA and tSU:STO
    // Keep those relationships literal for X-HD V0.1.8 TIMINGR=0x00303D5B.
    parameter integer MASTER_START_SETUP_CYCLES   = MASTER_SCL_HIGH_CYCLES, // tHD:STA
    parameter integer MASTER_RESTART_SETUP_CYCLES = MASTER_SCL_LOW_CYCLES,  // tSU:STA
    parameter integer MASTER_STOP_SETUP_CYCLES    = MASTER_SCL_HIGH_CYCLES, // tSU:STO
    parameter MASTER_INPUT_DEGLITCH = 1'b1,        // ADV-only approximation of the
                                                   // STM32F0 analog input filter.
    parameter integer MASTER_STRETCH_TIMEOUT = 32'd6_480_000,  // eos_i2c_master --
                                                   // override for fast timeout
                                                   // testing (see tb_eos_hd.v)
    parameter integer MASTER_IDLE_WAIT_TIMEOUT = 32'd194_400_000, // bounds S_WAIT_IDLE
                                                   // while EOS itself remains released
    parameter integer MASTER_BUS_FREE_CYCLES = MASTER_SCL_LOW_CYCLES, // STM tBUF uses SCLL
                                                   // for this timing register: ~11.50 us.
    parameter FORCE_STANDALONE = 1'b0,             // diagnostic only; normal X-HD behavior is 0
    parameter XHD_PRE16_FOCUS = 1'b0                // X-HD build-profile equivalent for pre-1.6:
                                                   // 0 = BUILD_CONEXANT, 1 = BUILD_FOCUS.
                                                   // Xbox 1.6 still selects BUILD_XCALIBUR
                                                   // before init_adv(), matching the physical board.
)(
    input  wire        clk,      // clk_sd domain, same as eos_i2c.v / eos_i2c_master.v
    input  wire        resetn,

    // Stable physical boot strap, already normalized by eos_hdmi_top.v.
    // 1 selects X-HD's Xcalibur application profile before init_adv(); 0 uses
    // the pre-1.6 build profile selected by XHD_PRE16_FOCUS.
    input  wire        xbox_16_mode,

    // ---- PRIVATE ADV7511 I2C bus (EXP1/EXP2), EOS is the SOLE master ------
    // This is NOT the Xbox SMBus. On HD+ boards the ADV's SCL/SDA are free to
    // route, so they live on their own two-wire bus that only EOS touches --
    // exactly what X-HD's STM does (ADV on a dedicated I2C1/PB6-PB7, never the
    // Xbox SMBus). Mastering a private bus is collision-free: nothing else
    // arbitrates here, so ADV bring-up ("video no matter what") can never be
    // blocked, NAKed, or fragged by the console's own SMBus traffic. The Xbox
    // SMBus is handled entirely by eos_i2c.v as a SLAVE (0x6E + 0x69); this
    // module no longer drives it at all.
    input  wire         adv_sda_in,
    input  wire         adv_scl_in,
    output wire          adv_sda_oe,
    output wire           adv_scl_oe,

    // Physical ADV7511 INT output. Keep it synchronized for EOS diagnostics.
    // In the exact V0.1.8 tag PF7 is configured as EXTI7, but the application
    // enables EXTI0_1_IRQn and never provides the EXTI4_15 vector entry, so the
    // tagged build does not feed this pin into encoder.interrupt functionally.
    input  wire          adv_int,

    // ---- eos_i2c.v's HD relay interface (dual-address slave transport) ----
    output wire         hd_addr_en,     // gates HD_ADDR (0x69) live -- raised
                                         // once ADV init completes (BR_ENABLE_
                                         // VIDEO); the old collision guard is
                                         // gone, so init completion is the gate
    input  wire          hd_addr_match,
    input  wire           hd_byte_valid,
    input  wire  [7:0]     hd_byte,
    input  wire              hd_byte_first,
    input  wire               hd_txn_done,
    input  wire               hd_txn_abort,
    output reg   [7:0]        hd_read_data,
    output reg                 hd_read_ready,

    // ---- X-HD private SDRAM lane -----------------------------------------
    // 0x0000..0xFFFF: 64 KB virtual STM flash backing.
    // The X-HD 1 KB staging RAM is local block RAM; using the FPGA BSRAM for
    // the actual MCU RAM avoids a second SDRAM transaction per READ_PAGE byte.
    // Physical virtual-flash placement (0x5C0000+) is owned by eos_sdram_backend.v.
    output reg                 xhd_mem_rd,
    output reg                 xhd_mem_wr,
    output reg  [15:0]         xhd_mem_addr,
    output reg  [7:0]          xhd_mem_wdata,
    input  wire [7:0]          xhd_mem_rdata,
    input  wire                xhd_mem_rvalid,
    input  wire                xhd_mem_busy,

    // ---- native EOS diagnostic bridge (0x6E control plane) ---------------
    // Read-only access to the ADV7511 register map for the Xbox diagnostic app.
    // A request is latched and serviced only from BR_READY, between complete
    // X-HD loop iterations, so it never interrupts an in-flight ADV transaction.
    input  wire                diag_adv_req,
    input  wire [7:0]          diag_adv_reg,
    // Transaction-trace readback uses the same native 0x6E result registers.
    // Command 0x3C supplies ARG0=logical trace index, ARG1=field selector.
    input  wire                diag_trace_req,
    input  wire [7:0]          diag_trace_index,
    input  wire [2:0]          diag_trace_field,
    output reg                 diag_adv_busy,
    output reg                 diag_adv_valid,
    output reg                 diag_adv_nack,
    output reg  [7:0]          diag_adv_data,
    output reg  [7:0]          diag_adv_reg_echo,

    // ---- on-board HD status LED (GPIO 30/31) -- self-contained ----
    output reg          led_green,
    output reg           led_blue,

    // ---- serve HUD status (matches the already-reserved panel ports) ----
    output wire [3:0]   hd_encoder_out,
    output wire          hd_pll_lock_out,
    output wire           hd_bios_active_out,
    output wire            hd_guard_blocked_out,
    output wire [5:0]       hd_brst_out,  // raw bring-up state number, for
                                            // real diagnostic resolution --
                                            // the flags above can't tell
                                            // "stuck early" from "stuck late"
    output wire [2:0]        hd_disable_reason_out, // retained HUD port; 0 in normal X-HD path
    output wire [7:0]        hd_diag_out, // Patch 5 runtime diagnostic byte:
                                            // [7] ADV timeout seen, [6] ADV NACK seen,
                                            // [5] Xbox-side HD txn abort seen,
                                            // [4] reserved (0 in conformant path),
                                            // [3:0] live ADV op sequencer state
    output wire              hd_target_known, // HD target ownership is established
    output wire              hd_target_hd     // stable expansion target: 1=HD, 0=NOHD
);

    // =========================================================================
    // I2C master engine -- talks outbound to the ADV @ ADV_ADDR on the PRIVATE
    // EXP bus ONLY. It no longer probes the Xbox SMBus for anything (the old
    // encoder probe and 0x69 collision guard are gone -- see BR_RESET). Sole
    // owner of the private bus; nothing else needs master capability.
    // =========================================================================
    reg         m_start_go, m_wr_go, m_rd_go, m_rd_send_ack, m_stop_go;
    reg  [7:0]  m_wr_byte;
    wire        m_start_done, m_start_timeout, m_wr_done, m_wr_ack, m_wr_timeout, m_wr_arb_lost;
    wire        m_rd_done, m_rd_timeout;
    wire [7:0]  m_rd_byte;
    wire        m_busy;
    wire        m_stop_done;

    // X-HD's ADV helpers issue one blocking HAL_I2C_Mem_Read/Write call and
    // ignore the returned HAL status.  EOS therefore performs exactly one
    // physical register transaction per source-level call. EOS performs one
    // pre-application ADV presence check solely to decide whether the optional
    // X-HD hardware is installed. Once present, the X-HD application path has
    // no presence probes, retry/backoff, or higher-level recovery policy.
    //
    // The X-HD instance also uses unbounded physical wait semantics, matching
    // HAL_MAX_DELAY. NACK/arbitration-style completed failures still return from
    // the helper exactly once: a failed READ leaves 0, and a failed WRITE has no
    // side effect. A genuinely held SCL/bus does not trigger an EOS recovery.
    reg        adv_timeout_sticky;
    reg        adv_nack_sticky;
    reg        hd_abort_sticky;
    reg        xhd_soft_reset_pulse;
    // NVIC_SystemReset() resets the STM application and its I2C peripherals
    // together. Mirror that boundary: WRITE_SET_MODE's soft-reset pulse also
    // resets/releases the private ADV master instead of leaving it mid-transfer.
    wire       master_resetn = resetn && !xhd_soft_reset_pulse;

    eos_i2c_master #(
        .SCL_LOW_CYCLES(MASTER_SCL_LOW_CYCLES),
        .SCL_HIGH_CYCLES(MASTER_SCL_HIGH_CYCLES),
        .START_SETUP_CYCLES(MASTER_START_SETUP_CYCLES),
        .RESTART_SETUP_CYCLES(MASTER_RESTART_SETUP_CYCLES),
        .STOP_SETUP_CYCLES(MASTER_STOP_SETUP_CYCLES),
        .INPUT_DEGLITCH(MASTER_INPUT_DEGLITCH),
        .STRETCH_TIMEOUT(MASTER_STRETCH_TIMEOUT),
        .IDLE_WAIT_TIMEOUT(MASTER_IDLE_WAIT_TIMEOUT),
        .BUS_FREE_CYCLES(MASTER_BUS_FREE_CYCLES),
        // X-HD's HAL_I2C_Mem_Read/Write use HAL_MAX_DELAY.  Keep the ADV
        // instance unbounded and retain arbitration detection just like the
        // STM32 peripheral; the private bus should never exercise ARLO normally.
        .BOUNDED_WAITS(1'b0),
        .SINGLE_MASTER(1'b0),
        .WAIT_BUS_FREE(1'b1),
        .HONOR_CLOCK_STRETCH(1'b1)
    ) u_master (
        .clk(clk), .resetn(master_resetn),
        .sda_in(adv_sda_in), .scl_in(adv_scl_in), .sda_oe(adv_sda_oe), .scl_oe(adv_scl_oe),
        .start_go(m_start_go), .start_done(m_start_done), .start_timeout(m_start_timeout),
        .wr_go(m_wr_go), .wr_byte(m_wr_byte), .wr_done(m_wr_done), .wr_ack(m_wr_ack),
        .wr_timeout(m_wr_timeout), .wr_arb_lost(m_wr_arb_lost),
        .rd_go(m_rd_go), .rd_send_ack(m_rd_send_ack), .rd_done(m_rd_done), .rd_byte(m_rd_byte), .rd_timeout(m_rd_timeout),
        .stop_go(m_stop_go), .stop_done(m_stop_done), .busy(m_busy)
    );

    // =========================================================================
    // ADV7511 register read/write helpers.  One op_go is one X-HD
    // adv7511_read_register()/adv7511_write_register() call.
    // =========================================================================
    localparam [2:0]
        OP_NONE  = 3'd0,
        OP_WRITE = 3'd1,
        OP_READ  = 3'd2;

    reg  [2:0] op_kind;
    reg        op_go;
    reg  [6:0] op_target_addr;
    reg  [7:0] adv_waddr, adv_wdata;
    reg  [7:0] adv_rdata;
    reg        op_done;
    reg        op_nack;
    reg        op_timeout;

    reg  [2:0] op_exec_kind;
    reg  [6:0] op_exec_target_addr;
    reg  [7:0] op_exec_waddr;
    reg  [7:0] op_exec_wdata;

    localparam [3:0]
        OPS_IDLE    = 4'd0,
        OPS_START   = 4'd1,
        OPS_ADDR_W  = 4'd2,
        OPS_REG     = 4'd3,
        OPS_DATA_W  = 4'd4,
        OPS_RSTART  = 4'd5,
        OPS_ADDR_R  = 4'd6,
        OPS_DATA_R  = 4'd7,
        OPS_STOP    = 4'd8,
        OPS_DONE    = 4'd9;

    reg [3:0] ops_st;

    // X-HD WRITE_SET_MODE always delays 10 ms and resets the STM. EOS retains
    // the requested application/bootloader persona across this X-HD-local soft
    // reset so the observable 0x69 application and bootloader contracts follow
    // the V0.1.8 split-image behavior.
    reg        set_mode_reset_pending;
    reg [23:0] set_mode_delay_ctr;
    reg [7:0]  set_mode_requested;

    always @(posedge clk or negedge resetn) begin
        if (!resetn || xhd_soft_reset_pulse) begin
            ops_st<=OPS_IDLE; op_done<=1'b0; op_nack<=1'b0; op_timeout<=1'b0;
            adv_rdata<=8'h00;
            op_exec_kind<=OP_NONE; op_exec_target_addr<=7'd0;
            op_exec_waddr<=8'd0; op_exec_wdata<=8'd0;
            adv_timeout_sticky<=1'b0; adv_nack_sticky<=1'b0; hd_abort_sticky<=1'b0;
            m_start_go<=1'b0; m_wr_go<=1'b0; m_rd_go<=1'b0;
            m_rd_send_ack<=1'b0; m_stop_go<=1'b0; m_wr_byte<=8'd0;
        end else begin
            m_start_go<=1'b0; m_wr_go<=1'b0; m_rd_go<=1'b0;
            m_stop_go<=1'b0; op_done<=1'b0;

            if (op_done && op_timeout) adv_timeout_sticky<=1'b1;
            if (op_done && op_nack)    adv_nack_sticky<=1'b1;
            if (hd_txn_abort)          hd_abort_sticky<=1'b1;

            case (ops_st)
                OPS_IDLE: begin
                    if (op_go) begin
                        op_nack<=1'b0; op_timeout<=1'b0;
                        op_exec_kind<=op_kind;
                        op_exec_target_addr<=op_target_addr;
                        op_exec_waddr<=adv_waddr;
                        op_exec_wdata<=adv_wdata;
                        // X-HD read helper initializes its return byte to zero.
                        if (op_kind==OP_READ)
                            adv_rdata<=8'h00;
                        m_start_go<=1'b1;
                        ops_st<=OPS_START;
                    end
                end

                OPS_START: if (m_start_done) begin
                    if (m_start_timeout) begin
                        op_nack<=1'b1; op_timeout<=1'b1;
                        ops_st<=OPS_DONE;
                    end else begin
                        m_wr_byte<={op_exec_target_addr,1'b0};
                        m_wr_go<=1'b1;
                        ops_st<=OPS_ADDR_W;
                    end
                end

                OPS_ADDR_W: if (m_wr_done) begin
                    if (m_wr_arb_lost) begin
                        op_nack<=1'b1; op_timeout<=1'b0;
                        ops_st<=OPS_DONE;       // HAL call failed; do not retry
                    end else if (m_wr_timeout || !m_wr_ack) begin
                        op_nack<=1'b1; op_timeout<=m_wr_timeout;
                        m_stop_go<=1'b1; ops_st<=OPS_STOP;
                    end else begin
                        m_wr_byte<=op_exec_waddr;
                        m_wr_go<=1'b1;
                        ops_st<=OPS_REG;
                    end
                end

                OPS_REG: if (m_wr_done) begin
                    if (m_wr_arb_lost) begin
                        op_nack<=1'b1; op_timeout<=1'b0;
                        ops_st<=OPS_DONE;
                    end else if (m_wr_timeout || !m_wr_ack) begin
                        op_nack<=1'b1; op_timeout<=m_wr_timeout;
                        m_stop_go<=1'b1; ops_st<=OPS_STOP;
                    end else if (op_exec_kind==OP_WRITE) begin
                        m_wr_byte<=op_exec_wdata;
                        m_wr_go<=1'b1;
                        ops_st<=OPS_DATA_W;
                    end else begin
                        m_start_go<=1'b1;
                        ops_st<=OPS_RSTART;
                    end
                end

                OPS_DATA_W: if (m_wr_done) begin
                    op_nack<=m_wr_arb_lost || m_wr_timeout || !m_wr_ack;
                    op_timeout<=m_wr_timeout;
                    if (m_wr_arb_lost)
                        ops_st<=OPS_DONE;
                    else begin
                        m_stop_go<=1'b1;
                        ops_st<=OPS_STOP;
                    end
                end

                OPS_RSTART: if (m_start_done) begin
                    if (m_start_timeout) begin
                        op_nack<=1'b1; op_timeout<=1'b1;
                        ops_st<=OPS_DONE;
                    end else begin
                        m_wr_byte<={op_exec_target_addr,1'b1};
                        m_wr_go<=1'b1;
                        ops_st<=OPS_ADDR_R;
                    end
                end

                OPS_ADDR_R: if (m_wr_done) begin
                    if (m_wr_arb_lost) begin
                        op_nack<=1'b1; op_timeout<=1'b0;
                        ops_st<=OPS_DONE;
                    end else if (m_wr_timeout || !m_wr_ack) begin
                        op_nack<=1'b1; op_timeout<=m_wr_timeout;
                        m_stop_go<=1'b1; ops_st<=OPS_STOP;
                    end else begin
                        // HAL_I2C_Mem_Read(..., 1 byte): receive one byte and NACK.
                        m_rd_send_ack<=1'b0;
                        m_rd_go<=1'b1;
                        ops_st<=OPS_DATA_R;
                    end
                end

                OPS_DATA_R: if (m_rd_done) begin
                    if (!m_rd_timeout)
                        adv_rdata<=m_rd_byte;
                    // on failure adv_rdata deliberately remains 0
                    op_nack<=m_rd_timeout;
                    op_timeout<=m_rd_timeout;
                    m_stop_go<=1'b1;
                    ops_st<=OPS_STOP;
                end

                OPS_STOP: if (m_stop_done)
                    ops_st<=OPS_DONE;

                OPS_DONE: begin
                    op_done<=1'b1;
                    ops_st<=OPS_IDLE;
                end

                default: ops_st<=OPS_IDLE;
            endcase
        end
    end

    // =========================================================================
    // Internal encoder IDs. The BIOS wire values remain X-HD's native enum:
    //   Conexant=0x8A, Focus=0xD4, Xcalibur=0xE0.
    // These compact IDs select the exact X-HD register and timing branches.
    // =========================================================================
    localparam [1:0]
        ENC_CONEXANT = 2'd0,
        ENC_FOCUS    = 2'd1,
        ENC_XCALIBUR = 2'd2;

    // =========================================================================
    // Encoder-specific tweak values (§4.2) -- indexed by the compact ID.
    // Literal X-HD V0.1.8 bring-up: 0x48 and 0xBA are UPDATE ops, followed by
    // one 0xD0 UPDATE touching only [3:2]. The remaining init_adv() operations
    // are executed below in the same source order and transaction shape.
    // =========================================================================
    function [7:0] enc_0x48_val; input [1:0] enc; begin
        case (enc)
            ENC_CONEXANT: enc_0x48_val = 8'b01000000;  // Conexant
            ENC_FOCUS: enc_0x48_val = 8'b01000000;  // Focus (same as Conexant)
            ENC_XCALIBUR: enc_0x48_val = 8'b00100000;  // Xcalibur
            default: enc_0x48_val = 8'b01000000;
        endcase
    end endfunction
    function [7:0] enc_0xba_val; input [1:0] enc; begin
        case (enc)
            ENC_CONEXANT: enc_0xba_val = 8'b01100000;  // X-HD Conexant: no clock delay
            ENC_FOCUS: enc_0xba_val = 8'b01000000;  // X-HD Focus: -0.4 ns
            ENC_XCALIBUR: enc_0xba_val = 8'b00100000;  // Xcalibur: -0.8ns
            default: enc_0xba_val = 8'b01100000;
        endcase
    end endfunction

    // =========================================================================
    // Standalone (pre-BIOS) video bring-up -- EOS_HD_First_Video_Bringup_Plan.md
    // §3-4. This is the DEFAULT initial video state for every launched BIOS
    // bank, not just an emergency fallback -- gives a real picture before any
    // BIOS handshake, then hands off cleanly once one arrives. Ported from
    // X-HD's own xbox_video_standalone.c behavior (auto-VIC-sense), using the
    // plan doc's confirmed timing rows. 5 modes: VGA, 480p 4:3, 480p 16:9,
    // 720p, 1080i. Across all 5, only hs_delay actually differs between the
    // Conexant/Focus family and Xcalibur -- vs_delay/h_active/v_active are
    // identical for both, confirmed by direct comparison of the plan doc's
    // two tables, not assumed.
    // =========================================================================
    localparam [2:0] SA_VGA=3'd0, SA_480P_4_3=3'd1, SA_480P_16_9=3'd2, SA_720P=3'd3, SA_1080I=3'd4;

    function [9:0] sa_hs_delay; input [2:0] mode; input xcal; begin
        case (mode)
            SA_VGA:       sa_hs_delay = 10'd119;
            SA_480P_4_3:  sa_hs_delay = xcal ? 10'd96  : 10'd118;
            SA_480P_16_9: sa_hs_delay = xcal ? 10'd96  : 10'd118;
            SA_720P:      sa_hs_delay = xcal ? 10'd259 : 10'd299;
            SA_1080I:     sa_hs_delay = xcal ? 10'd185 : 10'd233;
            default:      sa_hs_delay = 10'd119;
        endcase
    end endfunction
    function [7:0] sa_vs_delay; input [2:0] mode; begin
        case (mode)
            SA_VGA, SA_480P_4_3, SA_480P_16_9: sa_vs_delay = 8'd36;
            SA_720P:  sa_vs_delay = 8'd25;
            SA_1080I: sa_vs_delay = 8'd22;
            default:  sa_vs_delay = 8'd36;
        endcase
    end endfunction
    function [15:0] sa_h_active; input [2:0] mode; begin
        case (mode)
            SA_VGA:       sa_h_active = 16'd640;
            SA_480P_4_3:  sa_h_active = 16'd720;
            SA_480P_16_9: sa_h_active = 16'd720;
            SA_720P:      sa_h_active = 16'd1280;
            SA_1080I:     sa_h_active = 16'd1920;
            default:      sa_h_active = 16'd640;
        endcase
    end endfunction
    function [15:0] sa_v_active; input [2:0] mode; begin
        case (mode)
            SA_VGA, SA_480P_4_3, SA_480P_16_9: sa_v_active = 16'd480;
            SA_720P:  sa_v_active = 16'd720;
            SA_1080I: sa_v_active = 16'd540;   // already halved for interlace,
                                                 // matches the plan doc's row
                                                 // directly -- no further
                                                 // halving needed at apply time
            default:  sa_v_active = 16'd480;
        endcase
    end endfunction
    function [5:0] sa_out_vic; input [2:0] mode; begin   // VIC_01..VIC_05
        case (mode)
            SA_VGA: sa_out_vic = 6'd1; SA_480P_4_3: sa_out_vic = 6'd2;
            SA_480P_16_9: sa_out_vic = 6'd3; SA_720P: sa_out_vic = 6'd4;
            SA_1080I: sa_out_vic = 6'd5; default: sa_out_vic = 6'd1;
        endcase
    end endfunction
    function sa_widescreen; input [2:0] mode; begin
        sa_widescreen = (mode==SA_480P_16_9 || mode==SA_720P || mode==SA_1080I);
    end endfunction

    // Exact xbox_video_standalone.c dispatch. No VIC 6/7 or generalized
    // unsupported-mode fallback is invented here. X-HD's sole 480p fallback
    // is the explicit VIC 0 / unavailable branch.
    function [3:0] vic_to_mode; input [5:0] vic; begin   // {valid, mode}
        case (vic)
            6'd1:       vic_to_mode = {1'b1, SA_VGA};
            6'd0, 6'd2: vic_to_mode = {1'b1, SA_480P_4_3};
            6'd3:       vic_to_mode = {1'b1, SA_480P_16_9};
            6'd4:       vic_to_mode = {1'b1, SA_720P};
            6'd5:       vic_to_mode = {1'b1, SA_1080I};
            default:    vic_to_mode = 4'b0000;
        endcase
    end endfunction

    wire [3:0] xhd_vic_map = vic_to_mode(adv_rdata[7:2]);

    // =========================================================================
    // Exact X-HD V0.1.8 version bytes exposed on the 0x69 path.
    // Kept as four independent bytes to preserve the upstream command ABI.
    // =========================================================================
    localparam [7:0] HD_VER1 = 8'd0, HD_VER2 = 8'd1, HD_VER3 = 8'd8, HD_VER4 = 8'd0;

    // =========================================================================
    // SMBusSettings scratch/live storage (§5.3) -- 14 bytes: encoder(1),
    // region(1), mode(4), titleid(4), avinfo(4). bank/index addressing per
    // §5.1 is implemented faithfully (both are real registers, matching the
    // protocol), but only index[3:0] actually addresses the 14-entry array --
    // there is only ever one real config bank in practice (the Xbox BIOS
    // never uses more than one), so bank is tracked for protocol correctness
    // without a second dimension of real storage behind it.
    // =========================================================================
    reg [7:0]  cfg_scratch [0:13];
    reg [7:0]  cfg_live    [0:13];
    reg [15:0] cfg_bank, cfg_index;
    wire [15:0] cfg_offset = ({cfg_bank[7:0],8'h00} | cfg_index);
    reg       cfg_pending;        // X-HD video_mode_update_pending: single boolean
    reg       bios_took_over;     // one-way latch, see §5.4 / §7.1

    // X-HD application RAM/flash protocol state from smbus_i2c.c.
    // The STM has a real 1 KB RAM staging buffer plus 64 KB flash. Keep the
    // staging buffer in one FPGA block RAM (cheap dedicated memory resource)
    // and keep the 64 KB virtual flash backing in EOS SDRAM. This retains the
    // SDRAM-backed page model while avoiding a read+write SDRAM round trip for
    // every READ_PAGE byte.
    localparam integer XHD_RAM_BUFFER_SIZE = 1024;
    (* syn_ramstyle = "block_ram" *) reg [7:0] ram_buffer [0:XHD_RAM_BUFFER_SIZE-1];
    // Single write port + single registered read port (SDP) so ram_buffer
    // infers as BSRAM. The FSM drives rb_we/rb_waddr/rb_wdata via a
    // combinational decode and consumes the registered read data rb_q.
    reg        rb_we;
    reg  [9:0] rb_waddr;
    reg  [7:0] rb_wdata;
    reg  [7:0] rb_q;      // BSRAM read output (replaces xmem_read_data/xmem_hold)
    reg [15:0] ram_buffer_bank;
    reg [15:0] ram_buffer_index;
    wire [15:0] ram_buffer_offset =
        ({ram_buffer_bank[7:0],8'h00} | ram_buffer_index);
    reg [31:0] ram_buffer_crc;

    // Untouched SDRAM virtual-flash pages behave like erased STM flash (FF).
    // The validity map survives X-HD soft resets exactly as flash contents do.
    reg [63:0] xhd_flash_page_valid;

    localparam [2:0] XMEM_NONE       = 3'd0,
                     XMEM_READ_RAM   = 3'd1,
                     XMEM_WRITE_RAM  = 3'd2,
                     XMEM_READ_PAGE  = 3'd3,
                     XMEM_APPLY_PAGE = 3'd4,
                     XMEM_FLAG_PAGE  = 3'd5;  // bootloader APP_FLASH_MODE: page 63 erase / invalid flag
    localparam [2:0] XM_IDLE         = 3'd0,
                     XM_RAM_RD_WAIT  = 3'd1,
                     XM_VF_RD_ISSUE  = 3'd2,
                     XM_VF_RD_WAIT   = 3'd3,
                     XM_CRC_BIT      = 3'd4,
                     XM_VF_WR_ISSUE  = 3'd5,
                     XM_VF_WR_WAIT   = 3'd6,
                     XM_FILL_FF      = 3'd7;

    reg [2:0] xmem_job_req_kind;
    reg [9:0] xmem_job_req_offset;
    reg [7:0] xmem_job_req_page;
    reg [7:0] xmem_job_req_wdata;
    reg       xmem_job_go;

    reg [2:0] xmem_state, xmem_active_job;
    reg [9:0] xmem_index;
    reg [5:0] xmem_page;
    reg [31:0] xmem_crc_work;
    reg [2:0]  xmem_crc_bit;
    reg        xmem_init_pending;
    reg        xmem_write_seen_busy;
    reg        xmem_read_valid;
    reg        xmem_flag_set;
    reg [7:0]  xmem_page63_byte1022;
    reg        xmem_app_flag_update;
    reg        xmem_app_flag_value;
    wire       xmem_job_busy = xmem_init_pending || (xmem_active_job != XMEM_NONE);

    // X-HD does not re-arm HAL_I2C_EnableListen_IT() until its completed-write
    // callback returns. READ_PAGE / RAM_APPLY are blocking flash operations in
    // that callback, and WRITE_SET_MODE blocks for 10 ms before reset. EOS runs
    // the flash copies asynchronously, so gate only those equivalent callback
    // windows from the Xbox-facing 0x69 address. READ_RAM is intentionally NOT
    // included: it prepares a response before the normal repeated-START read.
    reg        hd_addr_ready;
    // Literal application-source quirk: WRITE_RAM_APPLY to protected pages
    // 20..63 returns directly from HAL_I2C_ListenCpltCallback(), before the
    // state reset / HAL_I2C_EnableListen_IT() tail. The STM therefore stops
    // listening until reset. Preserve that externally visible behavior.
    reg        xhd_protected_apply_stall;
    wire       xhd_listener_blocked = xhd_soft_reset_pulse ||
                                      xmem_init_pending ||
                                      set_mode_reset_pending ||
                                      xhd_protected_apply_stall ||
                                      ((xmem_job_go) &&
                                       ((xmem_job_req_kind == XMEM_READ_PAGE) ||
                                        (xmem_job_req_kind == XMEM_APPLY_PAGE) ||
                                        (xmem_job_req_kind == XMEM_FLAG_PAGE))) ||
                                      (xmem_active_job == XMEM_READ_PAGE) ||
                                      (xmem_active_job == XMEM_APPLY_PAGE) ||
                                      (xmem_active_job == XMEM_FLAG_PAGE);
    assign hd_addr_en = hd_addr_ready && !xhd_listener_blocked;
    wire [31:0] xmem_crc_step = xmem_crc_work[0]
                                  ? ((xmem_crc_work >> 1) ^ 32'hEDB88320)
                                  :  (xmem_crc_work >> 1);

    // ---- ram_buffer as inferrable single-port (SDP) BSRAM ------------------
    // Read address follows xmem_index and is registered into rb_q (one-cycle
    // synchronous read, exactly as the FSM already assumed). The write port is
    // decoded combinationally from the SAME registered FSM state the sequential
    // block acts on, so every write lands on the identical clock edge it did
    // when ram_buffer was written inline -- cycle-for-cycle equivalent, but now
    // in a reset-free posedge-only block that Gowin maps to BSRAM, not LUT-RAM.
    always @(posedge clk) begin
        if (rb_we) ram_buffer[rb_waddr] <= rb_wdata;
        rb_q <= ram_buffer[xmem_index];
    end

    // Faithful mirror of the four original inline write sites' guards.
    always @* begin
        rb_we    = 1'b0;
        rb_waddr = xmem_index;
        rb_wdata = 8'h00;
        if (resetn && !xhd_soft_reset_pulse) begin
            case (xmem_state)
                XM_IDLE:
                    if (xmem_init_pending) begin
                        rb_we = 1'b1; rb_waddr = xmem_index;          rb_wdata = 8'h00;
                    end else if (xmem_job_go && xmem_active_job==XMEM_NONE &&
                                 xmem_job_req_kind==XMEM_WRITE_RAM) begin
                        rb_we = 1'b1; rb_waddr = xmem_job_req_offset; rb_wdata = xmem_job_req_wdata;
                    end
                XM_VF_RD_WAIT:
                    if (xhd_mem_rvalid) begin
                        rb_we = 1'b1; rb_waddr = xmem_index;          rb_wdata = xhd_mem_rdata;
                    end
                XM_FILL_FF: begin
                        rb_we = 1'b1; rb_waddr = xmem_index;          rb_wdata = 8'hFF;
                    end
                default: ;
            endcase
        end
    end

    // SDRAM-backed virtual-flash engine + one local BSRAM staging page. CRC is
    // folded one BIT per clk to avoid the previous eight-round combinational
    // network. 8192 CRC clocks/page is only ~126 us at 64.8 MHz.
    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            xhd_mem_rd<=1'b0; xhd_mem_wr<=1'b0; xhd_mem_addr<=16'd0; xhd_mem_wdata<=8'd0;
            xmem_state<=XM_IDLE; xmem_active_job<=XMEM_NONE; xmem_index<=10'd0;
            xmem_page<=6'd0; xmem_crc_work<=32'hFFFFFFFF; xmem_crc_bit<=3'd0;
            xmem_init_pending<=1'b1; xmem_write_seen_busy<=1'b0;
            xmem_read_valid<=1'b0; xmem_flag_set<=1'b0;
            xmem_page63_byte1022<=8'hFF; xmem_app_flag_update<=1'b0; xmem_app_flag_value<=1'b0;
            ram_buffer_crc<=32'd0; xhd_flash_page_valid<=64'd0;
        end else begin
            xhd_mem_rd<=1'b0; xhd_mem_wr<=1'b0; xmem_read_valid<=1'b0;
            xmem_app_flag_update<=1'b0;

            if (xhd_soft_reset_pulse) begin
                // C startup clears RAM/BSS. Virtual flash/page-valid state survives.
                xmem_state<=XM_IDLE; xmem_active_job<=XMEM_NONE; xmem_index<=10'd0;
                xmem_page<=6'd0; xmem_crc_work<=32'hFFFFFFFF; xmem_crc_bit<=3'd0;
                xmem_init_pending<=1'b1; xmem_write_seen_busy<=1'b0; ram_buffer_crc<=32'd0;
                xmem_flag_set<=1'b0; xmem_page63_byte1022<=8'hFF;
            end else begin
                case (xmem_state)
                    XM_IDLE: begin
                        // Sequential BSS clear is block-RAM friendly and completes
                        // long before normal X-HD application traffic matters.
                        if (xmem_init_pending) begin
                            if (xmem_index == 10'd1023) begin
                                xmem_index<=10'd0; xmem_init_pending<=1'b0;
                            end else begin
                                xmem_index<=xmem_index+10'd1;
                            end
                        end else if (xmem_job_go && xmem_active_job==XMEM_NONE) begin
                            case (xmem_job_req_kind)
                                XMEM_READ_RAM: begin
                                    xmem_active_job<=XMEM_READ_RAM;
                                    xmem_index<=xmem_job_req_offset;
                                    xmem_state<=XM_RAM_RD_WAIT;
                                end
                                XMEM_WRITE_RAM: begin
                                    // Single local-RAM write completes here (via rb_we decode).
                                    xmem_active_job<=XMEM_NONE;
                                end
                                XMEM_READ_PAGE: begin
                                    xmem_active_job<=XMEM_READ_PAGE; xmem_index<=10'd0;
                                    xmem_page<=xmem_job_req_page[5:0]; xmem_crc_work<=32'hFFFFFFFF;
                                    if (xmem_job_req_page < 8'd64 &&
                                        xhd_flash_page_valid[xmem_job_req_page[5:0]]) begin
                                        xmem_state<=XM_VF_RD_ISSUE;
                                    end else begin
                                        // Entire erased page has a known CRC; fill local
                                        // RAM directly instead of running the CRC engine.
                                        xmem_state<=XM_FILL_FF;
                                    end
                                end
                                XMEM_APPLY_PAGE: begin
                                    // Caller/source already rejects protected/out-of-range
                                    // pages. Latch the real 6-bit STM page number.
                                    xmem_active_job<=XMEM_APPLY_PAGE; xmem_index<=10'd0;
                                    xmem_page<=xmem_job_req_page[5:0];
                                    xmem_page63_byte1022<=8'hFF;
                                    xmem_state<=XM_RAM_RD_WAIT;
                                end
                                XMEM_FLAG_PAGE: begin
                                    // flash_remove_flag()/flash_set_flag() both erase
                                    // page 63. SET then programs 0x5A5A at offsets
                                    // 1022/1023; REMOVE leaves the page erased (FF).
                                    xmem_active_job<=XMEM_FLAG_PAGE; xmem_index<=10'd0;
                                    xmem_page<=6'd63; xmem_flag_set<=|xmem_job_req_wdata;
                                    xmem_state<=XM_VF_WR_ISSUE;
                                end
                                default: begin
                                    xmem_active_job<=XMEM_NONE; xmem_state<=XM_IDLE;
                                end
                            endcase
                        end
                    end

                    XM_RAM_RD_WAIT: begin
                        // Synchronous BSRAM read. The index was registered on the
                        // previous cycle before entering this state.
                        if (xmem_active_job==XMEM_READ_RAM) begin
                            xmem_read_valid<=1'b1;
                            xmem_active_job<=XMEM_NONE; xmem_state<=XM_IDLE;
                        end else if (xmem_active_job==XMEM_APPLY_PAGE) begin
                            xmem_state<=XM_VF_WR_ISSUE;
                        end else begin
                            xmem_active_job<=XMEM_NONE; xmem_state<=XM_IDLE;
                        end
                    end

                    XM_VF_RD_ISSUE: begin
                        if (!xhd_mem_busy) begin
                            xhd_mem_rd<=1'b1;
                            xhd_mem_addr<={xmem_page,xmem_index}; // 64 x 1KB = 64KB
                            xmem_state<=XM_VF_RD_WAIT;
                        end
                    end

                    XM_VF_RD_WAIT: begin
                        if (xhd_mem_rvalid) begin
                            xmem_crc_work<=xmem_crc_work ^ {24'd0,xhd_mem_rdata};
                            xmem_crc_bit<=3'd0;
                            xmem_state<=XM_CRC_BIT;
                        end
                    end

                    XM_CRC_BIT: begin
                        xmem_crc_work<=xmem_crc_step;
                        if (xmem_crc_bit==3'd7) begin
                            xmem_crc_bit<=3'd0;
                            if (xmem_index==10'd1023) begin
                                ram_buffer_crc<=xmem_crc_step ^ 32'hFFFFFFFF;
                                xmem_active_job<=XMEM_NONE; xmem_state<=XM_IDLE;
                            end else begin
                                xmem_index<=xmem_index+10'd1;
                                xmem_state<=XM_VF_RD_ISSUE;
                            end
                        end else begin
                            xmem_crc_bit<=xmem_crc_bit+3'd1;
                        end
                    end

                    XM_FILL_FF: begin
                        if (xmem_index==10'd1023) begin
                            // CRC32(1024 bytes of FF), reflected EDB88320 form.
                            ram_buffer_crc<=32'hB83AFFF4;
                            xmem_active_job<=XMEM_NONE; xmem_state<=XM_IDLE;
                        end else begin
                            xmem_index<=xmem_index+10'd1;
                        end
                    end

                    XM_VF_WR_ISSUE: begin
                        if (!xhd_mem_busy) begin
                            xhd_mem_wr<=1'b1; xhd_mem_addr<={xmem_page,xmem_index};
                            if (xmem_active_job==XMEM_FLAG_PAGE)
                                xhd_mem_wdata<=((xmem_index>=10'd1022) && xmem_flag_set) ? 8'h5A : 8'hFF;
                            else
                                xhd_mem_wdata<=rb_q;
                            if (xmem_active_job==XMEM_APPLY_PAGE && xmem_page==6'd63 && xmem_index==10'd1022)
                                xmem_page63_byte1022<=rb_q;
                            xmem_write_seen_busy<=1'b0;
                            xmem_state<=XM_VF_WR_WAIT;
                        end
                    end

                    XM_VF_WR_WAIT: begin
                        if (xhd_mem_busy) begin
                            xmem_write_seen_busy<=1'b1;
                        end else if (xmem_write_seen_busy) begin
                            xmem_write_seen_busy<=1'b0;
                            if (xmem_index==10'd1023) begin
                                xhd_flash_page_valid[xmem_page]<=1'b1;
                                if (xmem_active_job==XMEM_FLAG_PAGE) begin
                                    xmem_app_flag_value<=xmem_flag_set;
                                    xmem_app_flag_update<=1'b1;
                                end else if (xmem_active_job==XMEM_APPLY_PAGE && xmem_page==6'd63) begin
                                    // can_launch_application() checks the half-word at
                                    // APP_INVALID_FLAG_ADDRESS for exactly 0x5A5A.
                                    xmem_app_flag_value<=((xmem_page63_byte1022==8'h5A) && (rb_q==8'h5A));
                                    xmem_app_flag_update<=1'b1;
                                end
                                xmem_active_job<=XMEM_NONE; xmem_state<=XM_IDLE;
                            end else begin
                                xmem_index<=xmem_index+10'd1;
                                xmem_state<=(xmem_active_job==XMEM_FLAG_PAGE) ? XM_VF_WR_ISSUE : XM_RAM_RD_WAIT;
                            end
                        end
                    end

                    default: begin
                        xmem_state<=XM_IDLE; xmem_active_job<=XMEM_NONE;
                    end
                endcase
            end
        end
    end

    // BIOS-reported encoder from X-HD's packed SMBusSettings.encoder.
    // Detection is deliberately narrow: only 0xD4 can change a pre-1.6 boot
    // from its validated Conexant default to Focus. Unknown values never
    // silently alias Conexant, and the physical 1.6 branch is never overridden.
    wire live_encoder_is_conexant = (cfg_live[0] == 8'h8A);
    wire live_encoder_is_focus    = (cfg_live[0] == 8'hD4);
    wire live_encoder_is_xcalibur = (cfg_live[0] == 8'hE0);
    wire live_encoder_valid = live_encoder_is_conexant ||
                              live_encoder_is_focus ||
                              live_encoder_is_xcalibur;
    wire [1:0] live_encoder_apply_id = live_encoder_is_xcalibur ? ENC_XCALIBUR :
                                       live_encoder_is_focus    ? ENC_FOCUS    :
                                                                  ENC_CONEXANT;
    // Raw xbox_encoder value used by X-HD's bios_loop() comparison. Keep the
    // wire value, not only EOS's compact internal encoder id, so even an
    // unexpected BIOS value has the same "encoder changed" semantics.
    reg [7:0] bios_encoder_value;

    // =========================================================================
    // SMBus command dispatch -- consumes eos_i2c.v's relay interface. Pure
    // command interpretation; the actual bus I/O for base-init/encoder-tweak/
    // (eventually) per-mode reconfig happens in the bring-up/apply FSM below,
    // triggered by cfg_pending.
    // =========================================================================
    localparam [7:0]
        CMD_READ_CONFIG          = 8'd0,
        CMD_READ_VERSION1        = 8'd1,
        CMD_READ_VERSION2        = 8'd2,
        CMD_READ_VERSION3        = 8'd3,
        CMD_READ_VERSION4        = 8'd4,
        CMD_READ_MODE            = 8'd5,
        CMD_READ_RAM             = 8'd6,
        CMD_READ_RAM_PAGE_CRC1   = 8'd7,
        CMD_READ_RAM_PAGE_CRC2   = 8'd8,
        CMD_READ_RAM_PAGE_CRC3   = 8'd9,
        CMD_READ_RAM_PAGE_CRC4   = 8'd10,
        CMD_WRITE_CONFIG         = 8'd128,
        CMD_WRITE_CONFIG_BANK    = 8'd129,
        CMD_WRITE_CONFIG_INDEX   = 8'd130,
        CMD_WRITE_CONFIG_APPLY   = 8'd131,
        CMD_WRITE_SET_MODE       = 8'd132,
        CMD_WRITE_READ_PAGE      = 8'd133,
        CMD_WRITE_RAM            = 8'd134,
        CMD_WRITE_RAM_BANK       = 8'd135,
        CMD_WRITE_RAM_INDEX      = 8'd136,
        CMD_WRITE_RAM_APPLY      = 8'd137,
        CMD_WRITE_APP_FLASH_MODE = 8'd138;

    reg [7:0] cur_cmd;
    reg       have_cmd;
    // X-HD applies write side effects only after the complete SMBus write
    // transaction finishes. Stage the single data byte here and commit it on
    // hd_txn_done (STOP); discard it on transport recovery/abort.
    reg [7:0] staged_write_cmd;
    reg [7:0] staged_write_data;
    reg       staged_write_valid;

    // V0.1.8 runs a real bootloader before the application. The RAM magic flag
    // survives NVIC_SystemReset(), so keep persona-selection state outside the
    // application/BSS reset below. Normal EOS boot begins in the valid application.
    localparam [1:0] XHD_PERSONA_APP      = 2'd0,
                     XHD_PERSONA_BOOT_FW  = 2'd1,
                     XHD_PERSONA_BOOT_REC = 2'd2;
    reg [1:0] xhd_persona;
    reg       xhd_bootloader_magic;
    reg       xhd_app_invalid;
    wire      xhd_is_application = (xhd_persona == XHD_PERSONA_APP);
    wire      xhd_is_boot_fw     = (xhd_persona == XHD_PERSONA_BOOT_FW);
    wire      xhd_is_boot_rec    = (xhd_persona == XHD_PERSONA_BOOT_REC);

    integer   cfg_copy_i;   // loop var for the scratch->live copy below --
                             // must be declared here, not inside a nested
                             // unnamed begin/end (iverilog accepts that,
                             // Gowin's synthesizer does not: EX3620)
    reg       cfg_ack;      // pulsed by the bring-up FSM (below) to clear
                             // X-HD's single cfg_pending/video-update flag.
                             // cfg_pending itself remains owned exclusively by
                             // this always block to avoid multiple HDL drivers.

    // Persistent bootloader/application selection. SET_MODE updates the
    // reserved-RAM magic immediately when its completed write callback runs;
    // the actual persona changes only at the following 10 ms NVIC reset. The
    // application-invalid flag mirrors bootloader APP_FLASH_MODE and page-63
    // programming so can_launch_application() makes the same decision.
    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            xhd_persona<=XHD_PERSONA_APP;
            xhd_bootloader_magic<=1'b0;
            xhd_app_invalid<=1'b0;
        end else begin
            if (hd_txn_done && staged_write_valid && staged_write_cmd==CMD_WRITE_SET_MODE) begin
                if (staged_write_data==8'd1) xhd_bootloader_magic<=1'b1;
                else if (staged_write_data==8'd2) xhd_bootloader_magic<=1'b0;
            end
            // APP_FLASH_MODE and page-63 writes update the application-valid
            // decision only when the emulated flash operation itself completes,
            // matching the blocking V0.1.8 bootloader callback.
            if (xmem_app_flag_update)
                xhd_app_invalid<=xmem_app_flag_value;

            if (xhd_soft_reset_pulse) begin
                if (xhd_bootloader_magic)
                    xhd_persona<=XHD_PERSONA_BOOT_FW;
                else if (xhd_app_invalid)
                    xhd_persona<=XHD_PERSONA_BOOT_REC;
                else
                    xhd_persona<=XHD_PERSONA_APP;

                // Bootloader main() snapshots BOOTLOADER_FLAG_ADDRESS and then
                // clears it immediately before choosing FW/recovery/application.
                // Keep the retained magic one-shot across exactly one reset.
                xhd_bootloader_magic<=1'b0;
            end
        end
    end

    always @(posedge clk or negedge resetn) begin
        if (!resetn || xhd_soft_reset_pulse) begin
            cur_cmd<=8'd0; have_cmd<=1'b0; cfg_bank<=16'd0; cfg_index<=16'd0;
            staged_write_cmd<=8'd0; staged_write_data<=8'd0; staged_write_valid<=1'b0;
            cfg_pending<=1'b0; bios_took_over<=1'b0;
            hd_read_data<=8'h42; hd_read_ready<=1'b1;

            ram_buffer_bank<=16'd0; ram_buffer_index<=16'd0;
            xmem_job_req_kind<=XMEM_NONE; xmem_job_req_offset<=10'd0;
            xmem_job_req_page<=8'd0; xmem_job_req_wdata<=8'd0; xmem_job_go<=1'b0;

            xhd_soft_reset_pulse<=1'b0;
            set_mode_reset_pending<=1'b0;
            set_mode_delay_ctr<=24'd0;
            set_mode_requested<=8'd0;
            xhd_protected_apply_stall<=1'b0;
            for (cfg_copy_i=0;cfg_copy_i<14;cfg_copy_i=cfg_copy_i+1) begin
                cfg_scratch[cfg_copy_i] <= 8'd0;
                cfg_live[cfg_copy_i]    <= 8'd0;
            end
        end else begin
            // One-cycle defaults. WRITE_SET_MODE raises the reset pulse only when
            // its 10 ms delay expires; X-HD memory requests are posted for one cycle.
            xhd_soft_reset_pulse <= 1'b0;
            xmem_job_go <= 1'b0;

            // READ_RAM completes asynchronously from the command interpreter but
            // still well before a normal repeated-start read at SMBus speeds.
            if (xmem_read_valid) begin
                hd_read_data <= rb_q;
                hd_read_ready <= 1'b1;
            end

            // X-HD's SET_MODE callback blocks for HAL_Delay(10) and then resets
            // regardless of the command value. EOS mirrors that reset timing.
            if (set_mode_reset_pending) begin
                if (set_mode_delay_ctr >= (DLY_10MS - 24'd1)) begin
                    set_mode_delay_ctr <= 24'd0;
                    set_mode_reset_pending <= 1'b0;
                    xhd_soft_reset_pulse <= 1'b1;
                end else begin
                    set_mode_delay_ctr <= set_mode_delay_ctr + 24'd1;
                end
            end

            // relay bytes only ever arrive while hd_addr_match is live; a
            // STOP (which eos_i2c.v surfaces by simply deasserting
            // hd_addr_match) ends the "current command" the same way
            // eos_i2c.v's own have_cmd model works for the updater persona.
            if (!hd_addr_match) have_cmd<=1'b0;

            if (hd_txn_abort) begin
                // Match X-HD's I2C error recovery: an incomplete transaction
                // has no protocol side effects. Keep the last read command/data
                // harmlessly latched, but discard any uncommitted write byte.
                staged_write_valid <= 1'b0;
                have_cmd <= 1'b0;
                hd_read_ready <= 1'b1;
            end

            if (hd_byte_valid) begin
                if (hd_byte_first) begin
                    cur_cmd<=hd_byte; have_cmd<=1'b1;
                    staged_write_valid<=1'b0;
                    // Bootloader SlaveRxCpltCallback resets responseByte to FF
                    // for every new command before decoding the supported subset.
                    if (!xhd_is_application) hd_read_data<=8'hFF;

                    // READ_RAM prepares one response byte and post-increments
                    // bank:index exactly when the command byte is received. SDRAM
                    // latency is hidden with hd_read_ready/clock stretching.
                    if (hd_byte == CMD_READ_RAM) begin
                        if (ram_buffer_offset < XHD_RAM_BUFFER_SIZE && !xmem_job_busy) begin
                            xmem_job_req_kind <= XMEM_READ_RAM;
                            xmem_job_req_offset <= ram_buffer_offset[9:0];
                            xmem_job_req_page <= 8'd0; xmem_job_req_wdata <= 8'd0;
                            xmem_job_go <= 1'b1; hd_read_ready <= 1'b0;
                            if (ram_buffer_index == 16'h00FF) begin
                                ram_buffer_index <= 16'd0; ram_buffer_bank <= ram_buffer_bank + 16'd1;
                            end else ram_buffer_index <= ram_buffer_index + 16'd1;
                        end
                        // Out-of-range matches X-HD's `break`: responseByte and
                        // bank:index remain unchanged.
                    end
                end else begin
                    // X-HD write commands are one data byte. Do not mutate
                    // config/takeover state here: stage the completed byte and
                    // wait for eos_i2c.v to report the clean STOP boundary.
                    staged_write_cmd   <= cur_cmd;
                    staged_write_data  <= hd_byte;
                    staged_write_valid <= 1'b1;
                end
            end

            if (hd_txn_done && staged_write_valid) begin
                if (xhd_is_application) begin
                    case (staged_write_cmd)
                        CMD_WRITE_CONFIG: begin
                            if (cfg_offset < 16'd14) begin
                                cfg_scratch[cfg_offset[3:0]] <= staged_write_data;
                                if (cfg_index == 16'h00FF) begin
                                    cfg_index <= 16'd0;
                                    cfg_bank <= cfg_bank + 16'd1;
                                end else cfg_index <= cfg_index + 16'd1;
                            end
                        end
                        CMD_WRITE_CONFIG_BANK: begin
                            cfg_bank <= {8'd0,staged_write_data}; cfg_index <= 16'd0;
                        end
                        CMD_WRITE_CONFIG_INDEX: cfg_index <= {8'd0,staged_write_data};
                        CMD_WRITE_CONFIG_APPLY: begin
                            bios_took_over <= 1'b1;
                            if (staged_write_data == 8'h01) begin
                                for (cfg_copy_i=0;cfg_copy_i<14;cfg_copy_i=cfg_copy_i+1)
                                    cfg_live[cfg_copy_i] <= cfg_scratch[cfg_copy_i];
                                cfg_pending <= 1'b1;
                            end
                        end
                        CMD_WRITE_SET_MODE: begin
                            set_mode_requested <= staged_write_data;
                            set_mode_delay_ctr <= 24'd0;
                            set_mode_reset_pending <= 1'b1;
                        end
                        CMD_WRITE_READ_PAGE: begin
                            if (!xmem_job_busy) begin
                                xmem_job_req_kind<=XMEM_READ_PAGE; xmem_job_req_page<=staged_write_data;
                                xmem_job_req_offset<=10'd0; xmem_job_req_wdata<=8'd0; xmem_job_go<=1'b1;
                            end
                        end
                        CMD_WRITE_RAM: begin
                            if (ram_buffer_offset < XHD_RAM_BUFFER_SIZE && !xmem_job_busy) begin
                                xmem_job_req_kind<=XMEM_WRITE_RAM;
                                xmem_job_req_offset<=ram_buffer_offset[9:0];
                                xmem_job_req_page<=8'd0; xmem_job_req_wdata<=staged_write_data; xmem_job_go<=1'b1;
                                if (ram_buffer_index == 16'h00FF) begin
                                    ram_buffer_index <= 16'd0; ram_buffer_bank <= ram_buffer_bank + 16'd1;
                                end else ram_buffer_index <= ram_buffer_index + 16'd1;
                            end
                        end
                        CMD_WRITE_RAM_BANK: begin
                            ram_buffer_bank <= {8'd0,staged_write_data}; ram_buffer_index <= 16'd0;
                        end
                        CMD_WRITE_RAM_INDEX: ram_buffer_index <= {8'd0,staged_write_data};
                        CMD_WRITE_RAM_APPLY: begin
                            // Application protects bootloader pages 20..63 with a
                            // literal early return that skips listener re-arm.
                            if (staged_write_data >= 8'd20 && staged_write_data < 8'd64)
                                xhd_protected_apply_stall<=1'b1;
                            else if (!xmem_job_busy && staged_write_data < 8'd20) begin
                                xmem_job_req_kind<=XMEM_APPLY_PAGE; xmem_job_req_page<=staged_write_data;
                                xmem_job_req_offset<=10'd0; xmem_job_req_wdata<=8'd0; xmem_job_go<=1'b1;
                            end
                        end
                        // APP_FLASH_MODE is defined but absent from the V0.1.8
                        // application switch: explicit no-op.
                        CMD_WRITE_APP_FLASH_MODE: ;
                        default: ;
                    endcase
                end else begin
                    // V0.1.8 bootloader command set. CONFIG/version/application
                    // ownership commands are intentionally absent here.
                    case (staged_write_cmd)
                        CMD_WRITE_SET_MODE: begin
                            set_mode_requested <= staged_write_data;
                            set_mode_delay_ctr <= 24'd0;
                            set_mode_reset_pending <= 1'b1;
                        end
                        CMD_WRITE_READ_PAGE: begin
                            if (!xmem_job_busy) begin
                                xmem_job_req_kind<=XMEM_READ_PAGE; xmem_job_req_page<=staged_write_data;
                                xmem_job_req_offset<=10'd0; xmem_job_req_wdata<=8'd0; xmem_job_go<=1'b1;
                            end
                        end
                        CMD_WRITE_RAM: begin
                            if (ram_buffer_offset < XHD_RAM_BUFFER_SIZE && !xmem_job_busy) begin
                                xmem_job_req_kind<=XMEM_WRITE_RAM;
                                xmem_job_req_offset<=ram_buffer_offset[9:0];
                                xmem_job_req_page<=8'd0; xmem_job_req_wdata<=staged_write_data; xmem_job_go<=1'b1;
                                if (ram_buffer_index == 16'h00FF) begin
                                    ram_buffer_index <= 16'd0; ram_buffer_bank <= ram_buffer_bank + 16'd1;
                                end else ram_buffer_index <= ram_buffer_index + 16'd1;
                            end
                        end
                        CMD_WRITE_RAM_BANK: begin
                            ram_buffer_bank <= {8'd0,staged_write_data}; ram_buffer_index <= 16'd0;
                        end
                        CMD_WRITE_RAM_INDEX: ram_buffer_index <= {8'd0,staged_write_data};
                        CMD_WRITE_RAM_APPLY: begin
                            // Bootloader is the inverse protection boundary: pages
                            // below 20 are rejected; application pages 20..63 write.
                            if (!xmem_job_busy && staged_write_data >= 8'd20 && staged_write_data < 8'd64) begin
                                xmem_job_req_kind<=XMEM_APPLY_PAGE; xmem_job_req_page<=staged_write_data;
                                xmem_job_req_offset<=10'd0; xmem_job_req_wdata<=8'd0; xmem_job_go<=1'b1;
                            end
                        end
                        CMD_WRITE_APP_FLASH_MODE: begin
                            if (!xmem_job_busy) begin
                                xmem_job_req_kind<=XMEM_FLAG_PAGE; xmem_job_req_page<=8'd63;
                                xmem_job_req_offset<=10'd0; xmem_job_req_wdata<=staged_write_data; xmem_job_go<=1'b1;
                            end
                        end
                        default: ;
                    endcase
                end
                staged_write_valid <= 1'b0;
            end

            // ---- read-side response, always kept current (no stretching needed) ----
            // READ_CONFIG is latched when its command byte arrives so the
            // X-HD post-increment cannot advance the response before the
            // master's repeated-start read.
            if (xhd_is_application) begin
                case (cur_cmd)
                    CMD_READ_CONFIG:        ; // held from command arrival
                    CMD_READ_VERSION1:      hd_read_data <= HD_VER1;
                    CMD_READ_VERSION2:      hd_read_data <= HD_VER2;
                    CMD_READ_VERSION3:      hd_read_data <= HD_VER3;
                    CMD_READ_VERSION4:      hd_read_data <= HD_VER4;
                    CMD_READ_MODE:          hd_read_data <= 8'h02;
                    CMD_READ_RAM:           ; // asynchronous local-RAM response
                    CMD_READ_RAM_PAGE_CRC1: hd_read_data <= ram_buffer_crc[31:24];
                    CMD_READ_RAM_PAGE_CRC2: hd_read_data <= ram_buffer_crc[23:16];
                    CMD_READ_RAM_PAGE_CRC3: hd_read_data <= ram_buffer_crc[15:8];
                    CMD_READ_RAM_PAGE_CRC4: hd_read_data <= ram_buffer_crc[7:0];
                    default:                hd_read_data <= 8'hFF;
                endcase
            end else begin
                // Bootloader SlaveRxCpltCallback supports only MODE, RAM and CRC
                // reads; responseByte was reset to FF on command receipt.
                case (cur_cmd)
                    CMD_READ_MODE:          hd_read_data <= 8'h01;
                    CMD_READ_RAM:           ;
                    CMD_READ_RAM_PAGE_CRC1: hd_read_data <= ram_buffer_crc[31:24];
                    CMD_READ_RAM_PAGE_CRC2: hd_read_data <= ram_buffer_crc[23:16];
                    CMD_READ_RAM_PAGE_CRC3: hd_read_data <= ram_buffer_crc[15:8];
                    CMD_READ_RAM_PAGE_CRC4: hd_read_data <= ram_buffer_crc[7:0];
                    default:                ; // preserve the per-command FF default
                endcase
            end

            // X-HD READ_CONFIG returns the byte at bank:index and then
            // post-increments the combined 16-bit offset.
            if (xhd_is_application && hd_byte_valid && hd_byte_first &&
                hd_byte == CMD_READ_CONFIG &&
                cfg_offset < 16'd14) begin
                hd_read_data <= cfg_live[cfg_offset[3:0]];
                if (cfg_index == 16'h00FF) begin
                    cfg_index <= 16'd0;
                    cfg_bank <= cfg_bank + 16'd1;
                end else begin
                    cfg_index <= cfg_index + 16'd1;
                end
            end

            // ack_video_mode_update() is the final action of X-HD bios_loop().
            // Give that end-of-call clear priority over an APPLY that completed
            // while this BIOS call was still in progress; X-HD has only this
            // single boolean and does not queue a second generation.
            if (cfg_ack)
                cfg_pending <= 1'b0;
        end
    end

    // =========================================================================
    // Bring-up + apply/reconfigure FSM.
    //
    // Active bring-up and mode programming follow X-HD V0.1.8 source order.
    // EOS retains only its encoder-profile selection, 0x69 integration and
    // observational diagnostics around that source-equivalent path.
    //
    //   write 0xD6=0b11010000            (HPD/TMDS/gating, full write, FIRST)
    //   power_up: 0x41=0x10/delay/0x00/delay/0x10/delay (30/30/50ms)
    //   disable_video: update 0xD6 mask=0x01 val=0x01
    //   write 0x15=0b00100101            (input format)
    //   write 0x16=0b00111011            (output format)
    //   encoder tweak: update 0x48, update 0xBA, update 0xD0 mask=0x0C val=0x0C
    //   update 0x17 mask=0x01 val=0x01   (DE gen enable)
    //   disable_csc: update 0x18 mask=0x80 val=0
    //   write 0xAF=0b00000110            (HDMI mode, HDCP off)
    //   update 0x40 mask=0x80 val=0x80   (GCP enable)
    //   audio: write 0x01=0x00, 0x02=0x18, 0x03=0x00,
    //          update 0x0A mask=0x70 val=0x10 (SPDIF source),
    //          update 0x0B mask=0x80 val=0x80 (SPDIF enable)
    //   enable_video: update 0xD6 mask=0x01 val=0
    //
    // Sequence: sample physical boot strap -> push the selected X-HD init
    // branch -> run standalone -> accept BIOS config. On a pre-1.6 boot only,
    // a valid 0xD4 report may apply the exact Focus-specific branch once.
    // =========================================================================
    localparam [5:0]
        BR_RESET             = 6'd0,
        BR_XHD_IRQ_HANDLER   = 6'd1,
        BR_ENCODER_REPORT    = 6'd2,
        BR_BIOS_APPLY        = 6'd3,
        BR_BOOT_FW_IDLE      = 6'd4,
        BR_BOOT_REC_DELAY    = 6'd7,
        BR_BOOT_REC_VIC      = 6'd8,

        // init_adv()
        BR_INIT_HPD_FULL     = 6'd11,
        BR_POWERUP_A         = 6'd12,
        BR_POWERUP_A_WAIT    = 6'd13,
        BR_POWERUP_A_DELAY   = 6'd14,
        BR_POWERUP_B_WAIT    = 6'd15,
        BR_POWERUP_B_DELAY   = 6'd16,
        BR_POWERUP_C_WAIT    = 6'd17,
        BR_POWERUP_C_DELAY   = 6'd18,
        BR_DISABLE_VIDEO     = 6'd19,
        BR_WRITE_15          = 6'd20,
        BR_WRITE_16          = 6'd21,
        BR_ENC_TWEAK_GO      = 6'd22,
        BR_ENC_TWEAK_WT      = 6'd23,
        BR_DE_GEN            = 6'd24,
        BR_DISABLE_CSC       = 6'd25,
        BR_WRITE_AF          = 6'd26,
        BR_GCP_ENABLE        = 6'd27,
        BR_AUDIO_01          = 6'd28,
        BR_AUDIO_02          = 6'd29,
        BR_AUDIO_03          = 6'd30,
        BR_SPDIF_SRC         = 6'd31,
        BR_SPDIF_ENABLE      = 6'd32,
        BR_ENABLE_VIDEO      = 6'd33,

        BR_READY             = 6'd34,
        BR_DIAG_ADV_WAIT     = 6'd35,  // read-only updater diagnostic request

        // Diagnostic A/B: reassert X-HD's literal input-format writes after
        // the rest of init_adv() has completed. An earlier live dump on the
        // same general path read back 0x15=0x05 / 0x16=0x0B instead of the
        // source values 0x25 / 0x3B. These states change no other register.
        BR_REASSERT_15_WAIT  = 6'd36,
        BR_REASSERT_16_WAIT  = 6'd37,

        // X-HD set_video_mode_vic() 1080i-only tail operations.
        BR_SA_INT_37              = 6'd5,
        BR_SA_INT_DC              = 6'd6,

        // stand_alone_loop()/set_video_mode_vic()
        BR_STANDALONE_CSC_DISABLE = 6'd42,
        BR_STANDALONE_WR_35       = 6'd43,
        BR_STANDALONE_WR_36       = 6'd44,
        BR_STANDALONE_WR_37       = 6'd45,
        BR_STANDALONE_WR_38       = 6'd46,
        BR_STANDALONE_WR_39       = 6'd47,
        BR_STANDALONE_WR_3A       = 6'd48,
        // X-HD set_video_mode_vic() tail added to standalone (§4 cleanup):
        BR_SA_41                  = 6'd49,
        BR_SA_D0                  = 6'd50,
        BR_SA_3C                  = 6'd51,
        BR_SA_AVI_4A_SET          = 6'd53,
        BR_SA_AVI_55              = 6'd54,
        BR_SA_AVI_56              = 6'd55,
        BR_SA_AVI_57              = 6'd56,
        BR_SA_AVI_58              = 6'd57,
        BR_SA_AVI_59              = 6'd58,
        BR_SA_AVI_4A_CLR          = 6'd59,
        BR_XHD_VIC_REREAD_WAIT     = 6'd62,
        BR_XHD_MODE_FINISH         = 6'd63;

    reg [5:0]  br_st;

    // BIOS-owned X-HD mode applicator. br_st remains six bits for the existing
    // HUD; the detailed operation is carried by this private sub-state.
    localparam [5:0]
        BIOS_IDLE             = 6'd0,
        BIOS_TMDS_DN_RD_WAIT  = 6'd1,
        BIOS_TMDS_DN_WR_WAIT  = 6'd2,
        BIOS_CSC_DIS_RD_WAIT  = 6'd3,
        BIOS_CSC_DIS_WR_WAIT  = 6'd4,
        BIOS_CSC_WRITE_WAIT   = 6'd5,
        BIOS_WR35_WAIT        = 6'd6,
        BIOS_WR36_WAIT        = 6'd7,
        BIOS_RD37_WAIT        = 6'd8,
        BIOS_WR37_WAIT        = 6'd9,
        BIOS_WR38_WAIT        = 6'd10,
        BIOS_WR39_WAIT        = 6'd11,
        BIOS_WR3A_WAIT        = 6'd12,
        BIOS_WRD7_WAIT        = 6'd13,
        BIOS_WRD8_WAIT        = 6'd14,
        BIOS_WRD9_WAIT        = 6'd15,
        BIOS_WRDA_WAIT        = 6'd16,
        BIOS_WRDB_WAIT        = 6'd17,
        BIOS_RD41_WAIT        = 6'd18,
        BIOS_WR41_WAIT        = 6'd19,
        BIOS_WRDC_WAIT        = 6'd20,
        BIOS_RDD0_WAIT        = 6'd21,
        BIOS_WRD0_WAIT        = 6'd22,
        BIOS_WR3C_WAIT        = 6'd23,
        BIOS_AVI_RD4A_SET     = 6'd24,
        BIOS_AVI_WR4A_SET     = 6'd25,
        BIOS_AVI_RD55         = 6'd26,
        BIOS_AVI_WR55         = 6'd27,
        BIOS_AVI_WR56         = 6'd28,
        BIOS_AVI_WR57         = 6'd29,
        BIOS_AVI_WR58         = 6'd30,
        BIOS_AVI_WR59         = 6'd31,
        BIOS_AVI_RD4A_CLR     = 6'd32,
        BIOS_AVI_WR4A_CLR     = 6'd33,
        BIOS_TMDS_UP_RD_WAIT  = 6'd34,
        BIOS_TMDS_UP_WR_WAIT  = 6'd35;

    reg [5:0]  bios_st;
    reg [4:0]  bios_csc_idx;

    // -------------------------------------------------------------------------
    // Temporary transaction-history trace for EOS/X-HD diagnostics.
    //
    // The buffer is intentionally observational: it does not gate, delay, or
    // modify either I2C bus. Routine steady-state 0x9E/0x3E polling and native
    // ADV register-dump reads are omitted so the 64-entry ring retains the
    // meaningful init/mode/0x69 history leading up to a failure or reboot.
    // It survives X-HD soft resets and is cleared only by the FPGA resetn.
    //
    // Entry layout: {event[3:0], br_st[5:0], bios_st[5:0], reg/cmd[7:0], data[7:0]}
    // Readback fields: 0=event, 1=br_st, 2=bios_st, 3=reg/cmd, 4=data.
    // -------------------------------------------------------------------------
    localparam [3:0]
        TRACE_ADV_WRITE_OK = 4'h1,
        TRACE_ADV_READ_OK  = 4'h2,
        TRACE_ADV_WRITE_ER = 4'h3,
        TRACE_ADV_READ_ER  = 4'h4,
        TRACE_HD_CMD       = 4'h5,
        TRACE_HD_DATA      = 4'h6,
        TRACE_HD_DONE      = 4'h7,
        TRACE_HD_ABORT     = 4'h8,
        TRACE_SOFT_RESET   = 4'h9,
        TRACE_BIOS_OWNER   = 4'hA;

    // Small diagnostic ring intentionally uses an asynchronous read so the
    // native 0x6E control-plane query can return a field immediately. Keep it
    // as distributed storage; forcing block RAM would make this read style invalid.
    reg [31:0] trace_mem [0:63];
    reg [5:0] trace_wr_ptr;
    reg [6:0] trace_count;
    reg       trace_prev_bios_took_over;
    reg [31:0] trace_event_word;
    reg        trace_event_valid;

    wire trace_adv_poll = (op_exec_kind==OP_READ) &&
                          ((op_exec_waddr==8'h9E) || (op_exec_waddr==8'h3E));
    wire trace_adv_diag = (br_st==BR_DIAG_ADV_WAIT);
    wire [5:0] trace_read_phys = (trace_count==7'd64)
                               ? (trace_wr_ptr + diag_trace_index[5:0])
                               : diag_trace_index[5:0];
    wire [31:0] trace_read_word = trace_mem[trace_read_phys];

    always @* begin
        trace_event_valid = 1'b0;
        trace_event_word  = 32'd0;

        if (xhd_soft_reset_pulse) begin
            trace_event_valid = 1'b1;
            trace_event_word  = {TRACE_SOFT_RESET, br_st, bios_st,
                                 set_mode_requested, 8'h00};
        end else if (hd_byte_valid) begin
            trace_event_valid = 1'b1;
            if (hd_byte_first)
                trace_event_word = {TRACE_HD_CMD, br_st, bios_st, hd_byte, 8'h00};
            else
                trace_event_word = {TRACE_HD_DATA, br_st, bios_st, cur_cmd, hd_byte};
        end else if (hd_txn_done) begin
            trace_event_valid = 1'b1;
            trace_event_word  = {TRACE_HD_DONE, br_st, bios_st,
                                 staged_write_cmd, staged_write_data};
        end else if (hd_txn_abort) begin
            trace_event_valid = 1'b1;
            trace_event_word  = {TRACE_HD_ABORT, br_st, bios_st, cur_cmd, 8'h00};
        end else if (bios_took_over != trace_prev_bios_took_over) begin
            trace_event_valid = 1'b1;
            trace_event_word  = {TRACE_BIOS_OWNER, br_st, bios_st,
                                 CMD_WRITE_CONFIG_APPLY,
                                 {7'b0,bios_took_over}};
        end else if (op_done && !trace_adv_poll && !trace_adv_diag) begin
            trace_event_valid = 1'b1;
            if (op_nack || op_timeout) begin
                if (op_exec_kind==OP_WRITE)
                    trace_event_word = {TRACE_ADV_WRITE_ER, br_st, bios_st,
                                        op_exec_waddr,
                                        {6'b0,op_timeout,op_nack}};
                else
                    trace_event_word = {TRACE_ADV_READ_ER, br_st, bios_st,
                                        op_exec_waddr,
                                        {6'b0,op_timeout,op_nack}};
            end else if (op_exec_kind==OP_WRITE) begin
                trace_event_word = {TRACE_ADV_WRITE_OK, br_st, bios_st,
                                    op_exec_waddr, op_exec_wdata};
            end else if (op_exec_kind==OP_READ) begin
                trace_event_word = {TRACE_ADV_READ_OK, br_st, bios_st,
                                    op_exec_waddr, adv_rdata};
            end else begin
                trace_event_valid = 1'b0;
            end
        end
    end

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            trace_wr_ptr <= 6'd0;
            trace_count <= 7'd0;
            trace_prev_bios_took_over <= 1'b0;
        end else begin
            trace_prev_bios_took_over <= bios_took_over;
            if (trace_event_valid) begin
                trace_mem[trace_wr_ptr] <= trace_event_word;
                trace_wr_ptr <= trace_wr_ptr + 6'd1;
                if (trace_count < 7'd64)
                    trace_count <= trace_count + 7'd1;
            end
        end
    end
    // X-HD has TWO independent static mode/AVINFO pairs:
    //   bios_loop()::current_* and set_video_mode_bios()::current_*.
    // Keep both literally instead of collapsing them into one pair.
    reg [31:0] bios_current_mode;
    reg [31:0] bios_current_avinfo;
    reg [31:0] bios_set_current_mode;
    reg [31:0] bios_set_current_avinfo;
    reg [31:0] bios_pending_mode;
    reg [31:0] bios_pending_avinfo;
    reg        bios_skip_program;  // X-HD still cycles TMDS if table lookup rejects mode/encoder
    reg [15:0] bios_adv_delay_hs;
    reg [15:0] bios_vs_delay;
    reg [15:0] bios_h_active;
    reg [15:0] bios_v_active;
    reg [15:0] bios_hsync_placement;
    reg [15:0] bios_hsync_duration;
    reg [15:0] bios_vsync_placement;
    reg [15:0] bios_vsync_duration;
    reg [2:0]  bios_interlaced_offset;
    reg [5:0]  bios_vic;
    reg        bios_rgb;
    reg        bios_use_709;
    reg        bios_ws_infoframe;
    // No EOS-level ADV failure/recovery classifier is present in the
    // X-HD application path.  adv7511_read/write semantics are handled only
    // by the one-call/one-transaction helper above.
    reg [1:0]  boot_encoder_id;    // selected before init_adv(), like X-HD build profile
    reg [1:0]  enc_apply_id;       // branch currently being applied by shared
                                    // 0x48/0xBA/0xD0 states
    reg [1:0]  last_encoder_id;    // branch successfully programmed into ADV
    reg [5:0]  enc_tweak_return_st;   // where BR_ENC_TWEAK_WT goes once done --
                                        // BR_DE_GEN for the initial pass,
                                        // BR_READY for the one-way Focus transition
    reg [23:0] delay_ctr;         // covers X-HD's 30/30/50ms power-up delays
    // =========================================================================
    // X-HD BIOS-owned mode tables and helpers.
    //
    // The rows below are the exact 18-entry X-HD tables from
    // xbox_video_bios.h.  The initial profile is chosen before init_adv(),
    // matching X-HD's build-time encoder selection; BIOS settings remain
    // authoritative later exactly as in bios_loop().
    //
    // Values are packed losslessly into the 64-bit ROM below; mode validity is
    // derived from the exact X-HD 1..18 table-index range.
    // =========================================================================
    // X-HD BIOS timing table ROM. The previous 54-way 161-bit combinational
    // case was exact but expensive in LUT fabric. EOS already uses Gowin's
    // documented synchronous readmemh/block-RAM ROM form for the HUD; use the
    // same representation here. Every source value is stored directly, with no compensating bias.
    //
    // Address = {encoder_id[1:0], mode_index[4:0]}:
    //   0x00..0x1F Conexant, 0x20..0x3F Focus, 0x40..0x5F Xcalibur.
    //
    // Packed 64-bit row:
    //   [63:55] hs_delay             (9 bits)
    //   [54:49] vs_delay             (6 bits)
    //   [48:38] h_active            (11 bits)
    //   [37:27] v_active            (11 bits)
    //   [26:20] hsync_placement      (7 bits)
    //   [19:13] hsync_duration       (7 bits)
    //   [12:8]  vsync_placement      (5 bits)
    //   [7:4]   vsync_duration       (4 bits)
    //   [3:1]   interlaced_offset    (3 bits)
    //   [0]     reserved (0) -- upstream VideoMode has no extra field
    //
    // Widths are lossless for the exact X-HD tables (max values mechanically
    // checked when this ROM image was generated). Invalid entries are zero.
    (* syn_romstyle = "block_rom" *) reg [63:0] bios_mode_rom [0:127];
    initial begin
        $readmemh("eos_xhd_bios_modes.hex", bios_mode_rom);
    end

    reg [6:0]  bios_rom_addr = 7'd0;
    reg [63:0] bios_row_q = 64'd0;

    // Exact X-HD CSC payloads written to ADV7511 registers 0x18-0x2F.
    function [7:0] bios_csc_byte;
        input       use_709;
        input [4:0] idx;
        begin
            case (idx)
            5'd0: bios_csc_byte = 8'h87;
            5'd1: bios_csc_byte = 8'h06;
            5'd2: bios_csc_byte = (use_709 ? 8'h19 : 8'h1A);
            5'd3: bios_csc_byte = (use_709 ? 8'h9E : 8'h1E);
            5'd4: bios_csc_byte = (use_709 ? 8'h1F : 8'h1E);
            5'd5: bios_csc_byte = (use_709 ? 8'h5D : 8'hDE);
            5'd6: bios_csc_byte = 8'h08;
            5'd7: bios_csc_byte = 8'h00;
            5'd8: bios_csc_byte = (use_709 ? 8'h02 : 8'h04);
            5'd9: bios_csc_byte = (use_709 ? 8'hED : 8'h1C);
            5'd10: bios_csc_byte = (use_709 ? 8'h09 : 8'h08);
            5'd11: bios_csc_byte = (use_709 ? 8'hD2 : 8'h10);
            5'd12: bios_csc_byte = (use_709 ? 8'h00 : 8'h01);
            5'd13: bios_csc_byte = (use_709 ? 8'hFD : 8'h91);
            5'd14: bios_csc_byte = 8'h01;
            5'd15: bios_csc_byte = 8'h00;
            5'd16: bios_csc_byte = (use_709 ? 8'h1E : 8'h1D);
            5'd17: bios_csc_byte = (use_709 ? 8'h63 : 8'hA2);
            5'd18: bios_csc_byte = (use_709 ? 8'h1A : 8'h1B);
            5'd19: bios_csc_byte = (use_709 ? 8'h98 : 8'h59);
            5'd20: bios_csc_byte = 8'h07;
            5'd21: bios_csc_byte = 8'h06;
            5'd22: bios_csc_byte = 8'h08;
            5'd23: bios_csc_byte = 8'h00;
                default: bios_csc_byte = 8'h00;
            endcase
        end
    endfunction

    // Exact get_vic_from_video_mode() mapping from xbox_video_bios.c.
    function [5:0] bios_vic_from_dims;
        input [15:0] h_active;
        input [15:0] v_active;
        input        widescreen;
        begin
            case (h_active)
                16'd640, 16'd720:
                    bios_vic_from_dims = (v_active == 16'd576)
                                       ? (widescreen ? 6'd18 : 6'd17)
                                       : (widescreen ? 6'd3  : 6'd2);
                16'd1280: bios_vic_from_dims = 6'd4;
                16'd1920: bios_vic_from_dims = 6'd5;
                default:  bios_vic_from_dims = 6'd0;
            endcase
        end
    endfunction

    // Packed X-HD SMBusSettings fields (little-endian uint32_t members).
    wire [31:0] live_mode   = {cfg_live[5],  cfg_live[4],  cfg_live[3],  cfg_live[2]};
    wire [31:0] live_avinfo = {cfg_live[13], cfg_live[12], cfg_live[11], cfg_live[10]};
    wire [7:0]  live_mode_index = live_mode[23:16];

    // Gowin synchronous ROM pipeline, same proven form used by the EOS HUD.
    // X-HD bios_loop() stores the BIOS-reported encoder BEFORE it calls
    // set_video_mode_bios(), so the table lookup must follow cfg_live[0]
    // immediately. Using last_encoder_id here can expose one stale row after a
    // Conexant<->Focus/Xcalibur transition because the ROM is synchronous.
    always @(posedge clk) begin
        bios_row_q <= bios_mode_rom[bios_rom_addr];
        bios_rom_addr <= {live_encoder_apply_id, live_mode_index[4:0]};
    end

    // cfg_live is stable throughout an APPLY and live_encoder_valid rejects an
    // unknown BIOS encoder even though live_encoder_apply_id falls back to the
    // Conexant helper branch, matching X-HD's table-switch/default behavior.
    wire         bios_row_valid = live_encoder_valid &&
                                  (live_mode_index >= 8'd1) &&
                                  (live_mode_index <= 8'd18);
    wire [15:0]  bios_row_hs_delay = {7'd0,  bios_row_q[63:55]};
    wire [15:0]  bios_row_vs_delay = {10'd0, bios_row_q[54:49]};
    wire [15:0]  bios_row_h_active = {5'd0,  bios_row_q[48:38]};
    wire [15:0]  bios_row_v_active = {5'd0,  bios_row_q[37:27]};
    wire [15:0]  bios_row_hsync_placement = {9'd0,  bios_row_q[26:20]};
    wire [15:0]  bios_row_hsync_duration  = {9'd0,  bios_row_q[19:13]};
    wire [15:0]  bios_row_vsync_placement = {11'd0, bios_row_q[12:8]};
    wire [15:0]  bios_row_vsync_duration  = {12'd0, bios_row_q[7:4]};
    wire [2:0]   bios_row_interlaced_offset = bios_row_q[3:1];

    // X-HD currently hardcodes only table rows 0x0D/0x0E as interlaced.
    wire bios_live_interlaced = (live_mode_index == 8'h0D) ||
                                (live_mode_index == 8'h0E);
    wire [15:0] bios_row_vs_adjusted = bios_live_interlaced
                                     ? (bios_row_vs_delay >> 1)
                                     : bios_row_vs_delay;
    wire [15:0] bios_row_v_adjusted  = bios_live_interlaced
                                     ? (bios_row_v_active >> 1)
                                     : bios_row_v_active;
    wire        bios_live_widescreen = live_mode[28];
    wire        bios_live_rgb        = live_mode[29];
    wire [5:0]  bios_live_vic =
        bios_vic_from_dims(bios_row_h_active,
                           bios_row_v_adjusted,
                           bios_live_widescreen);
    wire bios_live_ws_infoframe = bios_live_widescreen ||
                                  (bios_live_vic == 6'd3) ||
                                  (bios_live_vic == 6'd4) ||
                                  (bios_live_vic == 6'd5);
    // DLY_30MS/DLY_50MS are module parameters (see port list above),
    // overridable for fast simulation.

    reg pll_lock_r;
    // Countdown timers are deliberately independent. The previous free-running
    // counters started at zero together, so PLL polling always won the priority
    // chain and the VIC poll was starved forever.
    // EOS's ADV bus is now dedicated/private, exactly like X-HD's, so
    // continuous polling would be harmless. These reloads are kept only as a
    // sensible cadence (they no longer exist to spare a shared Xbox SMBus --
    // there is no SMC/temperature traffic to leave unimpeded on this bus).
    reg [2:0]  standalone_target_mode; // mode currently being applied
    reg [5:0]  xhd_encoder_vic;        // adv7511_struct_init(): encoder->vic=0
    // latched row values for the mode currently being applied -- computed
    // once when a change is detected, held stable through the whole
    // applicator sequence
    reg [9:0]  sa_hs_latched;
    reg [7:0]  sa_vs_latched;
    reg [15:0] sa_h_latched, sa_v_latched;
    reg [5:0]  sa_vic_latched;
    reg        sa_ws_latched;

    // X-HD V0.1.8 ADV runtime state. The handler FSM remains source-shaped,
    // but the exact tag's PF7/vector mismatch means encoder.interrupt is never
    // asserted by the physical INT pin in the shipped/tagged application.
    reg        xhd_hpd;
    reg        xhd_monitor_sense;
    reg        adv_irq_pending;
    reg [7:0]  xhd_irq_flags;
    reg [3:0]  xhd_irq_phase;
    reg [5:0]  xhd_detected_vic;
    reg [1:0]  mode_finish_phase;
    reg        standalone_return_boot_rec;
    reg        mode_applied_ok;

    localparam [3:0]
        IRQ_WAIT_FLAGS       = 4'd0,
        IRQ_WAIT_HPD_STATUS  = 4'd1,
        IRQ_WAIT_MS_STATUS   = 4'd2,
        IRQ_DECIDE_POWER     = 4'd3,
        IRQ_POWER_A_WAIT     = 4'd4,
        IRQ_POWER_A_DELAY    = 4'd5,
        IRQ_POWER_B_WAIT     = 4'd6,
        IRQ_POWER_B_DELAY    = 4'd7,
        IRQ_POWER_C_WAIT     = 4'd8,
        IRQ_POWER_C_DELAY    = 4'd9,
        IRQ_CLEAR_READ_WAIT  = 4'd10,
        IRQ_CLEAR_WRITE_WAIT = 4'd11;

    // PF7 is asynchronous to clk_sd. X-HD requests both-edge GPIO interrupts;
    // detect either synchronized transition. The arm pipeline prevents reset
    // release from manufacturing an event from the static idle level.
    reg       adv_int_meta;
    reg       adv_int_sync;
    reg       adv_int_prev;
    reg [1:0] adv_int_arm;
    always @(posedge clk or negedge resetn) begin
        if (!resetn || xhd_soft_reset_pulse) begin
            adv_int_meta<=1'b0; adv_int_sync<=1'b0; adv_int_prev<=1'b0;
            adv_int_arm<=2'b00;
        end else begin
            adv_int_meta<=adv_int;
            adv_int_sync<=adv_int_meta;
            adv_int_arm<={adv_int_arm[0],1'b1};
            adv_int_prev<=adv_int_sync;
        end
    end
    wire adv_int_edge = adv_int_arm[1] && (adv_int_sync != adv_int_prev);

    // Encoder-branch HUD. With first picture established, ENC now reports
    // the branch actually programmed into the ADV: 0=Conexant, 1=Focus,
    // 2=Xcalibur. RS reports the detected input VIC low bits in standalone.
    assign hd_encoder_out        = {2'b0,last_encoder_id};
    assign hd_brst_out           = br_st;
    assign hd_disable_reason_out = FORCE_STANDALONE
                                 ? xhd_detected_vic[2:0]
                                 : 3'd0;
    assign hd_diag_out           = {adv_timeout_sticky, adv_nack_sticky,
                                    hd_abort_sticky, 1'b0,
                                    ops_st};
    assign hd_pll_lock_out       = pll_lock_r;
    assign hd_bios_active_out    = FORCE_STANDALONE
                                 ? mode_applied_ok
                                 : bios_took_over;
    assign hd_guard_blocked_out  = xhd_hpd && xhd_monitor_sense;

    // Native 0x6E diagnostic request latch. The Xbox app issues one request at
    // a time and polls diag_adv_valid; valid remains sticky until the next
    // request so the slow Xbox SMBus cannot miss a one-clock completion pulse.
    reg       diag_adv_pending;
    reg [7:0] diag_adv_reg_latched;

    // This HD build follows X-HD directly and assumes the ADV7511 target is
    // present. Expansion TARGET therefore becomes known/HD at BR_RESET while
    // hd_addr_ready still waits for completion of init_adv(); hd_addr_en
    // is additionally gated during source-blocking callback/reset windows.
    reg adv_presence_known_r;
    reg adv_present_r;
    assign hd_target_known = adv_presence_known_r;
    assign hd_target_hd    = adv_present_r;


    always @(posedge clk or negedge resetn) begin
        if (!resetn || xhd_soft_reset_pulse) begin
            br_st<=BR_RESET; hd_addr_ready<=1'b0; op_go<=1'b0; op_kind<=OP_NONE;
            adv_presence_known_r<=1'b0; adv_present_r<=1'b0;
            op_target_addr<=7'd0; adv_waddr<=8'd0; adv_wdata<=8'd0;
            delay_ctr<=24'd0;
            boot_encoder_id<=ENC_CONEXANT;
            bios_encoder_value<=8'h8A;
            enc_apply_id<=ENC_CONEXANT;
            last_encoder_id<=ENC_CONEXANT;
            enc_tweak_return_st<=6'd0;
            led_green<=1'b0; led_blue<=1'b0; pll_lock_r<=1'b0; mode_applied_ok<=1'b0;
            standalone_target_mode<=SA_480P_4_3; xhd_encoder_vic<=6'd0;
            xhd_hpd<=1'b0; xhd_monitor_sense<=1'b0; adv_irq_pending<=1'b0;
            xhd_irq_flags<=8'd0; xhd_irq_phase<=IRQ_WAIT_FLAGS;
            xhd_detected_vic<=6'd0; mode_finish_phase<=2'd0;
            standalone_return_boot_rec<=1'b0;
            bios_st<=BIOS_IDLE; bios_csc_idx<=5'd0;
            bios_current_mode<=32'd0; bios_current_avinfo<=32'd0;
            bios_set_current_mode<=32'd0; bios_set_current_avinfo<=32'd0;
            bios_pending_mode<=32'd0; bios_pending_avinfo<=32'd0;
            bios_skip_program<=1'b0;
            bios_adv_delay_hs<=16'd0; bios_vs_delay<=16'd0;
            bios_h_active<=16'd0; bios_v_active<=16'd0;
            bios_hsync_placement<=16'd0; bios_hsync_duration<=16'd0;
            bios_vsync_placement<=16'd0; bios_vsync_duration<=16'd0;
            bios_interlaced_offset<=3'd0; bios_vic<=6'd0;
            bios_rgb<=1'b0; bios_use_709<=1'b0;
            bios_ws_infoframe<=1'b0;
            cfg_ack<=1'b0;
            diag_adv_pending<=1'b0;
            diag_adv_reg_latched<=8'h00;
            diag_adv_busy<=1'b0;
            diag_adv_valid<=1'b0;
            diag_adv_nack<=1'b0;
            diag_adv_data<=8'h00;
            diag_adv_reg_echo<=8'h00;
        end else begin
            op_go<=1'b0;
            cfg_ack<=1'b0;   // pulse -- see the explicit sets below

            // The V0.1.8 application configures PF7 for EXTI7, but enables
            // EXTI0_1_IRQn and provides ADV_IRQ_HANDLER() rather than the
            // EXTI4_15 vector entry. Consequently the tagged build never sets
            // encoder.interrupt from PF7. Keep adv_int synchronized for EOS
            // diagnostics only; do not feed the functional X-HD IRQ state.

            // Transaction trace readback is immediate and never touches the ADV bus.
            // It reuses the existing ADVSTAT/ADVDATA/ADVREG native registers so
            // the Xbox-side diagnostic path needs no additional SMBus register map.
            if (diag_trace_req && !diag_adv_busy) begin
                diag_adv_reg_echo <= diag_trace_index;
                diag_adv_busy     <= 1'b0;
                diag_adv_valid    <= 1'b1;
                diag_adv_nack     <= 1'b0;

                if (diag_trace_index == 8'hFF) begin
                    case (diag_trace_field)
                        3'd0: diag_adv_data <= {1'b0,trace_count};
                        3'd1: diag_adv_data <= {2'b00,trace_wr_ptr};
                        3'd2: diag_adv_data <= {4'b0000,set_mode_reset_pending,
                                                hd_addr_en,bios_took_over,
                                                (trace_count==7'd64)};
                        3'd3: diag_adv_data <= 8'h01; // trace format version
                        3'd4: diag_adv_data <= {2'b00,br_st};
                        3'd5: diag_adv_data <= {2'b00,bios_st};
                        3'd6: diag_adv_data <= {2'b00,xhd_detected_vic};
                        3'd7: diag_adv_data <= {6'b000000,last_encoder_id};
                        default: begin diag_adv_data<=8'h00; diag_adv_nack<=1'b1; end
                    endcase
                end else if ((diag_trace_index < trace_count) &&
                             (diag_trace_field <= 3'd4)) begin
                    case (diag_trace_field)
                        3'd0: diag_adv_data <= {4'b0000,trace_read_word[31:28]};
                        3'd1: diag_adv_data <= {2'b00,trace_read_word[27:22]};
                        3'd2: diag_adv_data <= {2'b00,trace_read_word[21:16]};
                        3'd3: diag_adv_data <= trace_read_word[15:8];
                        3'd4: diag_adv_data <= trace_read_word[7:0];
                        default: begin diag_adv_data<=8'h00; diag_adv_nack<=1'b1; end
                    endcase
                end else begin
                    diag_adv_data <= 8'h00;
                    diag_adv_nack <= 1'b1;
                end
            end
            // Latch a read-only ADV register request from the native EOS
            // control plane. Never abort/restart X-HD work: BR_READY services
            // this after the current source-faithful loop call has completed.
            else if (diag_adv_req && !diag_adv_busy) begin
                diag_adv_reg_latched <= diag_adv_reg;
                diag_adv_reg_echo    <= diag_adv_reg;
                diag_adv_pending     <= 1'b1;
                diag_adv_busy        <= 1'b1;
                diag_adv_valid       <= 1'b0;
                diag_adv_nack        <= 1'b0;
            end

            // ---- LED, always kept current from live status (§7.1) ----
            led_green <= pll_lock_r;
            led_blue  <= FORCE_STANDALONE ? mode_applied_ok : bios_took_over;

            // The private ADV bus follows the shipped X-HD V0.1.8 loop:
            // PLL status -> standalone VIC or BIOS table engine.
            // No shared-bus pacing is required on the dedicated ADV bus.

            // X-HD ignores ADV HAL return codes. The helper above already maps
            // a failed read to 0 and a failed write to no side effect, so the
            // source-order state machine never diverts into an EOS recovery path.
            //
            // Literal X-HD V0.1.8 ownership semantics: main.c chooses either
            // stand_alone_loop() or bios_loop() once per loop iteration. If a
            // CONFIG_APPLY arrives while set_video_mode_vic() is already running,
            // that C call finishes completely. BIOS ownership is observed only
            // after returning to BR_READY for the next main-loop iteration.
            case (br_st)
                BR_RESET: begin
                    // X-HD order:
                    //   adv7511_i2c_init()
                    //   adv7511_struct_init()
                    //   init_adv(..., boot-selected encoder)
                    //
                    // The FPGA pin and private I2C block are already present,
                    // so this state performs the source-equivalent struct/profile
                    // initialization immediately before the first D6 write.
                    delay_ctr<=24'd0;

                    // X-HD chooses its initial encoder profile before init_adv().
                    // EOS maps the physical 1.6 path to BUILD_XCALIBUR and uses
                    // XHD_PRE16_FOCUS as the build-profile choice for older boards.
                    // This guarantees the encoder-specific 0x48/0xBA/0xD0 writes
                    // occur at the same point in init_adv(), before SMBus is enabled.
                    boot_encoder_id<=xbox_16_mode ? ENC_XCALIBUR
                                                  : (XHD_PRE16_FOCUS ? ENC_FOCUS
                                                                     : ENC_CONEXANT);
                    bios_encoder_value<=xbox_16_mode ? 8'hE0
                                                     : (XHD_PRE16_FOCUS ? 8'hD4
                                                                        : 8'h8A);
                    enc_apply_id<=xbox_16_mode ? ENC_XCALIBUR
                                               : (XHD_PRE16_FOCUS ? ENC_FOCUS
                                                                  : ENC_CONEXANT);
                    last_encoder_id<=xbox_16_mode ? ENC_XCALIBUR
                                                  : (XHD_PRE16_FOCUS ? ENC_FOCUS
                                                                     : ENC_CONEXANT);
                    hd_addr_ready<=1'b0;
                    xhd_encoder_vic<=6'd0;
                    xhd_detected_vic<=6'd0;
                    mode_applied_ok<=1'b0;

                    adv_presence_known_r<=1'b1;
                    adv_present_r<=1'b1;
                    if (xhd_is_boot_fw) begin
                        // Bootloader magic path: enter_bootloader_mode_fw() does
                        // NOT initialize or touch the ADV; it initializes only
                        // the 0x69 bootloader listener and then idles.
                        hd_addr_ready<=1'b1;
                        br_st<=BR_BOOT_FW_IDLE;
                    end else begin
                        // Application and bootloader recovery both call init_adv().
                        // D6=0xD0 is the first ADV transaction.
                        br_st<=BR_INIT_HPD_FULL;
                    end
                end

                BR_BOOT_FW_IDLE: begin
                    // enter_bootloader_mode_fw(): no ADV traffic. 0x69 runs from
                    // eos_i2c.v asynchronously; the MCU loop itself only delays.
                    hd_addr_ready<=1'b1;
                end

                BR_BOOT_REC_DELAY: begin
                    // enter_bootloader_mode(): HAL_Delay(10), then
                    // adv_handle_interrupts(), then stand_alone_loop().
                    if (delay_ctr < DLY_10MS) delay_ctr<=delay_ctr+24'd1;
                    else begin
                        delay_ctr<=24'd0;
                        standalone_return_boot_rec<=1'b1;
                        if (adv_irq_pending) begin
                            op_kind<=OP_READ; op_target_addr<=ADV_ADDR;
                            adv_waddr<=8'h96; op_go<=1'b1;
                            xhd_irq_phase<=IRQ_WAIT_FLAGS;
                            br_st<=BR_XHD_IRQ_HANDLER;
                        end else begin
                            op_kind<=OP_READ; op_target_addr<=ADV_ADDR;
                            adv_waddr<=8'h3E; op_go<=1'b1;
                            br_st<=BR_BOOT_REC_VIC;
                        end
                    end
                end

                BR_BOOT_REC_VIC: if (op_done && op_kind==OP_READ && adv_waddr==8'h3E) begin
                    xhd_detected_vic<=adv_rdata[7:2];
                    if (adv_rdata[7:2] != {2'b00,xhd_encoder_vic[3:0]}) begin
                        op_kind<=OP_READ; op_target_addr<=ADV_ADDR;
                        adv_waddr<=8'h3E; op_go<=1'b1;
                        br_st<=BR_XHD_VIC_REREAD_WAIT;
                    end else begin
                        delay_ctr<=24'd0;
                        br_st<=BR_BOOT_REC_DELAY;
                    end
                end

                // =========================================================
                // init_adv() from here down -- X-HD source order. From this
                // point onward there are no EOS presence checks or retries.
                // =========================================================

                // write 0xD6 = 0b11010000 -- FIRST real register write,
                // before power-up even. [7:6] HPD forced high, [4] TMDS
                // clock soft turn-on, [0] AV gating off (0, NOT gated here).
                BR_INIT_HPD_FULL: begin
                    // Exact X-HD order: write D6, then enter
                    // adv7511_power_up(). X-HD does not read D6 here.
                    op_kind<=OP_WRITE; op_target_addr<=ADV_ADDR;
                    adv_waddr<=8'hD6; adv_wdata<=8'hD0;
                    op_go<=1'b1; br_st<=BR_POWERUP_A;
                end

                // adv7511_power_up(): 0x41=0x10/delay30/0x41=0x00/delay30/0x41=0x10/delay50.
                // Each step is a genuine two-phase state: wait for the
                // write's op_done (fires once), THEN count the delay every
                // cycle unconditionally -- gating a free-running counter
                // behind op_done hangs forever the moment it's re-entered
                // (found and fixed earlier; noting the shape so it isn't
                // reintroduced if this is ever touched again).
                BR_POWERUP_A: if (op_done) begin
                    op_kind<=OP_WRITE; op_target_addr<=ADV_ADDR; adv_waddr<=8'h41; adv_wdata<=8'h10;
                    op_go<=1'b1; br_st<=BR_POWERUP_A_WAIT;
                end
                BR_POWERUP_A_WAIT: if (op_done) begin
                    delay_ctr<=24'd0; br_st<=BR_POWERUP_A_DELAY;
                end
                BR_POWERUP_A_DELAY: begin
                    if (delay_ctr < DLY_30MS) delay_ctr<=delay_ctr+24'd1;
                    else begin
                        op_kind<=OP_WRITE; op_target_addr<=ADV_ADDR; adv_waddr<=8'h41; adv_wdata<=8'h00;
                        op_go<=1'b1; br_st<=BR_POWERUP_B_WAIT;
                    end
                end
                BR_POWERUP_B_WAIT: if (op_done) begin
                    delay_ctr<=24'd0; br_st<=BR_POWERUP_B_DELAY;
                end
                BR_POWERUP_B_DELAY: begin
                    if (delay_ctr < DLY_30MS) delay_ctr<=delay_ctr+24'd1;
                    else begin
                        op_kind<=OP_WRITE; op_target_addr<=ADV_ADDR; adv_waddr<=8'h41; adv_wdata<=8'h10;
                        op_go<=1'b1; br_st<=BR_POWERUP_C_WAIT;
                    end
                end
                BR_POWERUP_C_WAIT: if (op_done) begin
                    delay_ctr<=24'd0; br_st<=BR_POWERUP_C_DELAY;
                end
                BR_POWERUP_C_DELAY: begin
                    if (delay_ctr < DLY_50MS) delay_ctr<=delay_ctr+24'd1;
                    else begin
                        // Literal X-HD V0.1.8 init_adv(): after the final 50 ms
                        // power-up delay, immediately enter disable_video().
                        op_kind<=OP_READ; op_target_addr<=ADV_ADDR; adv_waddr<=8'hD6;
                        op_go<=1'b1; br_st<=BR_DISABLE_VIDEO;
                    end
                end

                // disable_video(): update_register(0xD6,0x01,0x01).
                // X-HD does not validate the read value or the HAL status.
                BR_DISABLE_VIDEO: begin
                    if (!op_go && ops_st==OPS_IDLE && op_kind==OP_READ) begin
                        op_kind<=OP_WRITE;
                        op_target_addr<=ADV_ADDR;
                        adv_waddr<=8'hD6;
                        adv_wdata<=(adv_rdata | 8'h01);
                        op_go<=1'b1;
                    end else if (op_done && op_kind==OP_WRITE) begin
                        br_st<=BR_WRITE_15;
                    end
                end

                // Literal X-HD V0.1.8 full write: 0x15 = 0x25.
                BR_WRITE_15: begin
                    if (op_done && op_kind==OP_WRITE && adv_waddr==8'h15) begin
                        br_st<=BR_WRITE_16;
                    end else if (!op_go && ops_st==OPS_IDLE) begin
                        op_kind<=OP_WRITE; op_target_addr<=ADV_ADDR; adv_waddr<=8'h15;
                        adv_wdata<=8'h25; op_go<=1'b1;
                    end
                end

                // Literal X-HD V0.1.8 full write: 0x16 = 0x3B.
                BR_WRITE_16: begin
                    if (op_done && op_kind==OP_WRITE) begin
                        enc_apply_id<=boot_encoder_id;
                        enc_tweak_return_st<=BR_DE_GEN;
                        br_st<=BR_ENC_TWEAK_GO;
                    end else if (!op_go && ops_st==OPS_IDLE) begin
                        op_kind<=OP_WRITE; op_target_addr<=ADV_ADDR; adv_waddr<=8'h16;
                        adv_wdata<=8'h3B; op_go<=1'b1;
                    end
                end

                // encoder-specific tweak (§4.2), INLINE here matching source
                // order exactly -- this is the fix: was deferred to BR_READY
                // before, waiting for the BIOS; now applied immediately with
                // the boot-selected value, same as X-HD applies immediately
                // with its compile-time value. The same states are reused by
                // the one later Focus transition so the source branch is not
                // duplicated or allowed to drift.
                BR_ENC_TWEAK_GO: begin
                    if (!op_go && ops_st==OPS_IDLE) begin
                        op_kind<=OP_READ; op_target_addr<=ADV_ADDR; adv_waddr<=8'h48; op_go<=1'b1;
                        br_st<=BR_ENC_TWEAK_WT;
                    end
                end
                BR_ENC_TWEAK_WT: begin
                    if (op_done && adv_waddr == 8'h48 && op_kind==OP_READ) begin
                        op_kind<=OP_WRITE; op_target_addr<=ADV_ADDR; adv_waddr<=8'h48;
                        adv_wdata<=((adv_rdata & ~8'h60) | enc_0x48_val(enc_apply_id));
                        op_go<=1'b1;
                    end else if (op_done && adv_waddr == 8'h48 && op_kind==OP_WRITE) begin
                        op_kind<=OP_READ; op_target_addr<=ADV_ADDR; adv_waddr<=8'hBA; op_go<=1'b1;
                    end else if (op_done && adv_waddr == 8'hBA && op_kind==OP_READ) begin
                        op_kind<=OP_WRITE; op_target_addr<=ADV_ADDR; adv_waddr<=8'hBA;
                        adv_wdata<=((adv_rdata & ~8'hE0) | enc_0xba_val(enc_apply_id));
                        op_go<=1'b1;
                    end else if (op_done && adv_waddr == 8'hBA && op_kind==OP_WRITE) begin
                        op_kind<=OP_READ; op_target_addr<=ADV_ADDR; adv_waddr<=8'hD0; op_go<=1'b1;
                    end else if (op_done && adv_waddr == 8'hD0 && op_kind==OP_READ) begin
                        // Literal X-HD V0.1.8 init_adv_encoder_specific():
                        // one update_register(0xD0, 0x0C, 0x0C) for every encoder.
                        op_kind<=OP_WRITE; op_target_addr<=ADV_ADDR; adv_waddr<=8'hD0;
                        adv_wdata<=(adv_rdata & ~8'h0C) | 8'h0C;
                        op_go<=1'b1;
                    end else if (op_done && adv_waddr == 8'hD0 && op_kind==OP_WRITE) begin
                        last_encoder_id<=enc_apply_id;
                        if (enc_tweak_return_st == BR_READY)
                            cfg_ack<=1'b1;
                        br_st<=enc_tweak_return_st;
                    end
                end

                // update 0x17 mask=0x01 val=0x01 (DE gen enable)
                BR_DE_GEN: begin
                    if (!op_go && ops_st==OPS_IDLE && adv_waddr != 8'h17) begin
                        op_kind<=OP_READ; op_target_addr<=ADV_ADDR; adv_waddr<=8'h17; op_go<=1'b1;
                    end else if (op_done && op_kind==OP_READ) begin
                        op_kind<=OP_WRITE; op_target_addr<=ADV_ADDR; adv_waddr<=8'h17;
                        adv_wdata<=(adv_rdata | 8'h01);
                        op_go<=1'b1;
                    end else if (op_done && op_kind==OP_WRITE) begin
                        br_st<=BR_DISABLE_CSC;
                    end
                end

                // Literal X-HD V0.1.8 adv7511_disable_csc():
                // update_register(0x18, 0x80, 0x00).
                BR_DISABLE_CSC: begin
                    if (op_done && op_kind==OP_READ) begin
                        op_kind<=OP_WRITE; op_target_addr<=ADV_ADDR; adv_waddr<=8'h18;
                        adv_wdata<=adv_rdata & ~8'h80;
                        op_go<=1'b1;
                    end else if (op_done && op_kind==OP_WRITE) begin
                        br_st<=BR_WRITE_AF;
                    end else if (!op_go && ops_st==OPS_IDLE) begin
                        op_kind<=OP_READ; op_target_addr<=ADV_ADDR; adv_waddr<=8'h18; op_go<=1'b1;
                    end
                end

                // Literal X-HD V0.1.8 full write: 0xAF = 0x06.
                BR_WRITE_AF: begin
                    if (op_done && op_kind==OP_WRITE && adv_waddr==8'hAF) begin
                        br_st<=BR_GCP_ENABLE;
                    end else if (!op_go && ops_st==OPS_IDLE) begin
                        op_kind<=OP_WRITE; op_target_addr<=ADV_ADDR; adv_waddr<=8'hAF;
                        adv_wdata<=8'h06; op_go<=1'b1;
                    end
                end

                // GCP enable: update 0x40 mask=0x80 val=0x80
                BR_GCP_ENABLE: begin
                    if (!op_go && ops_st==OPS_IDLE && adv_waddr != 8'h40) begin
                        op_kind<=OP_READ; op_target_addr<=ADV_ADDR; adv_waddr<=8'h40; op_go<=1'b1;
                    end else if (op_done && op_kind==OP_READ) begin
                        op_kind<=OP_WRITE; op_target_addr<=ADV_ADDR; adv_waddr<=8'h40;
                        adv_wdata<=(adv_rdata | 8'h80);
                        op_go<=1'b1;
                    end else if (op_done && op_kind==OP_WRITE) begin
                        br_st<=BR_AUDIO_01;
                    end
                end

                // init_adv_audio(): write 0x01=0x00, 0x02=0x18, 0x03=0x00
                BR_AUDIO_01: if (!op_go && ops_st==OPS_IDLE) begin
                    op_kind<=OP_WRITE; op_target_addr<=ADV_ADDR; adv_waddr<=8'h01; adv_wdata<=8'h00;
                    op_go<=1'b1; br_st<=BR_AUDIO_02;
                end
                BR_AUDIO_02: if (op_done) begin
                    op_kind<=OP_WRITE; op_target_addr<=ADV_ADDR; adv_waddr<=8'h02; adv_wdata<=8'h18;
                    op_go<=1'b1; br_st<=BR_AUDIO_03;
                end
                BR_AUDIO_03: if (op_done) begin
                    op_kind<=OP_WRITE; op_target_addr<=ADV_ADDR; adv_waddr<=8'h03; adv_wdata<=8'h00;
                    op_go<=1'b1; br_st<=BR_SPDIF_SRC;
                end

                // SPDIF source: update 0x0A mask=0x70 val=0x10
                BR_SPDIF_SRC: begin
                    if (!op_go && ops_st==OPS_IDLE && adv_waddr != 8'h0A) begin
                        op_kind<=OP_READ; op_target_addr<=ADV_ADDR; adv_waddr<=8'h0A; op_go<=1'b1;
                    end else if (op_done && op_kind==OP_READ) begin
                        op_kind<=OP_WRITE; op_target_addr<=ADV_ADDR; adv_waddr<=8'h0A;
                        adv_wdata<=((adv_rdata & ~8'b01110000) | 8'b00010000);
                        op_go<=1'b1;
                    end else if (op_done && op_kind==OP_WRITE) begin
                        br_st<=BR_SPDIF_ENABLE;
                    end
                end

                // SPDIF enable: update 0x0B mask=0x80 val=0x80
                BR_SPDIF_ENABLE: begin
                    if (!op_go && ops_st==OPS_IDLE && adv_waddr != 8'h0B) begin
                        op_kind<=OP_READ; op_target_addr<=ADV_ADDR; adv_waddr<=8'h0B; op_go<=1'b1;
                    end else if (op_done && op_kind==OP_READ) begin
                        op_kind<=OP_WRITE; op_target_addr<=ADV_ADDR; adv_waddr<=8'h0B;
                        adv_wdata<=(adv_rdata | 8'h80);
                        op_go<=1'b1;
                    end else if (op_done && op_kind==OP_WRITE) begin
                        // X-HD V0.1.8 enables video immediately after init_adv_audio().
                        br_st<=BR_ENABLE_VIDEO;
                    end
                end

                // Final video enable. Keep X-HD's explicit output gate around the
                // merged initialization, but perform its documented bit-0 RMW.
                BR_ENABLE_VIDEO: begin
                    if (!op_go && ops_st==OPS_IDLE && adv_waddr != 8'hD6) begin
                        op_kind<=OP_READ; op_target_addr<=ADV_ADDR;
                        adv_waddr<=8'hD6; op_go<=1'b1;
                    end else if (op_done && op_kind==OP_READ) begin
                        op_kind<=OP_WRITE; op_target_addr<=ADV_ADDR;
                        adv_waddr<=8'hD6;
                        adv_wdata<=adv_rdata & ~8'h01;
                        op_go<=1'b1;
                    end else if (op_done && op_kind==OP_WRITE) begin
                        last_encoder_id<=enc_apply_id;
                        // The BIOS settings responder is safe to expose now
                        // that init is complete. FORCE_STANDALONE gates full
                        // mode ownership, not the Focus-detection packet path.
                        hd_addr_ready<=1'b1;

                        // A/B test only: an earlier live register dump on this
                        // code path showed 0x15=0x05 and 0x16=0x0B even though
                        // X-HD writes 0x25/0x3B near the start of init_adv().
                        // Reassert those two full-register source values here,
                        // after every later init_adv() operation, and change
                        // absolutely nothing else.
                        op_kind<=OP_WRITE; op_target_addr<=ADV_ADDR;
                        adv_waddr<=8'h15; adv_wdata<=8'h25;
                        op_go<=1'b1; br_st<=BR_REASSERT_15_WAIT;
                    end
                end

                BR_REASSERT_15_WAIT: if (op_done && op_kind==OP_WRITE && adv_waddr==8'h15) begin
                    op_kind<=OP_WRITE; op_target_addr<=ADV_ADDR;
                    adv_waddr<=8'h16; adv_wdata<=8'h3B;
                    op_go<=1'b1; br_st<=BR_REASSERT_16_WAIT;
                end

                BR_REASSERT_16_WAIT: if (op_done && op_kind==OP_WRITE && adv_waddr==8'h16) begin
                    // Resume exactly where BR_ENABLE_VIDEO previously returned.
                    if (xhd_is_boot_rec) begin
                        delay_ctr<=24'd0;
                        standalone_return_boot_rec<=1'b1;
                        br_st<=BR_BOOT_REC_DELAY;
                    end else begin
                        standalone_return_boot_rec<=1'b0;
                        br_st<=BR_READY;
                    end
                end

                // ---- steady state: X-HD main.c source order ----
                //   1. read PLL status from 0x9E
                //   2. adv_handle_interrupts(&encoder)
                //   3. execute bios_loop()/stand_alone_loop()
                BR_READY: begin
                    // Preserve X-HD's loop ownership semantics: after the PLL
                    // read, choose exactly one of bios_loop()/stand_alone_loop()
                    // for this iteration.
                    // A BIOS APPLY that arrives after standalone was selected
                    // cannot abort that already-started C call.
                    if (op_done && op_kind==OP_READ && adv_waddr==8'h9E) begin
                        pll_lock_r<=adv_rdata[4];
                        // Normal merged runtime remains active; the earlier soak-only
                        // automatic ADV bus parking experiment is intentionally disabled.
            
                        if (adv_irq_pending) begin
                            // adv_handle_interrupts(): first operation is read(0x96).
                            op_kind<=OP_READ; op_target_addr<=ADV_ADDR;
                            adv_waddr<=8'h96; op_go<=1'b1;
                            xhd_irq_phase<=IRQ_WAIT_FLAGS;
                            br_st<=BR_XHD_IRQ_HANDLER;
                        end else if (diag_adv_pending) begin
                            // EOS diagnostic-only read, inserted between source calls.
                            op_kind<=OP_READ; op_target_addr<=ADV_ADDR;
                            adv_waddr<=diag_adv_reg_latched; op_go<=1'b1;
                            diag_adv_pending<=1'b0;
                            br_st<=BR_DIAG_ADV_WAIT;
                        end else if (!FORCE_STANDALONE && bios_took_over) begin
                            if (cfg_pending && !cfg_ack)
                                br_st<=BR_ENCODER_REPORT;
                            else begin
                                op_kind<=OP_READ; op_target_addr<=ADV_ADDR;
                                adv_waddr<=8'h9E; op_go<=1'b1;
                            end
                        end else begin
                            op_kind<=OP_READ; op_target_addr<=ADV_ADDR;
                            adv_waddr<=8'h3E; op_go<=1'b1;
                        end
                    end else if (op_done && op_kind==OP_READ &&
                                 adv_waddr==8'h3E) begin
                        xhd_detected_vic<=adv_rdata[7:2];

                        // stand_alone_loop() first read/change detector.
                        if (adv_rdata[7:2] != {2'b00,xhd_encoder_vic[3:0]}) begin
                            op_kind<=OP_READ; op_target_addr<=ADV_ADDR;
                            adv_waddr<=8'h3E; op_go<=1'b1;
                            br_st<=BR_XHD_VIC_REREAD_WAIT;
                        end else begin
                            // stand_alone_loop() returned; begin the next main()
                            // iteration with the PLL read. Do not jump directly
                            // into bios_loop() even if APPLY arrived mid-call.
                            op_kind<=OP_READ; op_target_addr<=ADV_ADDR;
                            adv_waddr<=8'h9E; op_go<=1'b1;
                        end
                    end else if (!op_go && ops_st==OPS_IDLE) begin
                        op_kind<=OP_READ; op_target_addr<=ADV_ADDR;
                        adv_waddr<=8'h9E; op_go<=1'b1;
                    end
                end

                BR_DIAG_ADV_WAIT: if (op_done) begin
                    diag_adv_data  <= adv_rdata;
                    diag_adv_nack  <= op_nack;
                    diag_adv_busy  <= 1'b0;
                    diag_adv_valid <= 1'b1;

                    // Resume the literal X-HD loop at its normal first operation:
                    // PLL status read from 0x9E.
                    op_kind<=OP_READ; op_target_addr<=ADV_ADDR;
                    adv_waddr<=8'h9E; op_go<=1'b1;
                    br_st<=BR_READY;
                end

                // X-HD bios_loop() encoder behavior: the BIOS-reported packed
                // SMBusSettings.encoder byte is authoritative. If it differs
                // from the current xbox_encoder value, X-HD stores it first and
                // immediately calls init_adv_encoder_specific(). Unknown values
                // therefore take that helper's Conexant fallback register branch
                // but remain invalid for the later mode-table switch.
                BR_ENCODER_REPORT: begin
                    // X-HD uses only one video_mode_update_pending flag; there
                    // is no APPLY queue/generation state to snapshot here.
                    if (bios_encoder_value != cfg_live[0]) begin
                        bios_encoder_value<=cfg_live[0];
                        enc_apply_id<=live_encoder_apply_id;
                        enc_tweak_return_st<=FORCE_STANDALONE
                                           ? BR_READY : BR_BIOS_APPLY;
                        bios_st<=BIOS_IDLE;
                        op_kind<=OP_READ; op_target_addr<=ADV_ADDR;
                        adv_waddr<=8'h48; op_go<=1'b1;
                        br_st<=BR_ENC_TWEAK_WT;
                    end else if (FORCE_STANDALONE) begin
                        cfg_ack<=1'b1;
                        br_st<=BR_READY;
                    end else begin
                        bios_st<=BIOS_IDLE;
                        br_st<=BR_BIOS_APPLY;
                    end
                end


                // =========================================================
                // X-HD BIOS-owned mode applicator.
                //
                // This is entered only when FORCE_STANDALONE=0. In BIOS mode
                // cfg_live[0] is authoritative exactly like X-HD's xbox_encoder
                // variable; this engine then ports xbox_video_bios.c.
                // =========================================================
                BR_BIOS_APPLY: begin
                    case (bios_st)
                        BIOS_IDLE: begin
                            // X-HD bios_loop() changes the ADV only when mode
                            // or avinfo changed. Encoder changes were handled
                            // immediately before entering this state.
                            if ((live_mode == bios_current_mode) &&
                                (live_avinfo == bios_current_avinfo)) begin
                                cfg_ack<=1'b1;
                                op_kind<=OP_READ; op_target_addr<=ADV_ADDR;
                                adv_waddr<=8'h9E; op_go<=1'b1;
                                br_st<=BR_READY;
                            end else begin
                                // X-HD's outer bios_loop() powers TMDS down/up
                                // whenever mode/avinfo changes. set_video_mode_bios()
                                // may then reject an invalid encoder/table row, but
                                // that rejection happens inside the TMDS cycle.
                                bios_pending_mode<=live_mode;
                                bios_pending_avinfo<=live_avinfo;
                                bios_skip_program<=!bios_row_valid;
                                bios_adv_delay_hs<=bios_row_hs_delay;
                                bios_vs_delay<=bios_row_vs_adjusted;
                                bios_h_active<=bios_row_h_active;
                                bios_v_active<=bios_row_v_adjusted;
                                bios_hsync_placement<=bios_row_hsync_placement;
                                bios_hsync_duration<=bios_row_hsync_duration;
                                bios_vsync_placement<=bios_row_vsync_placement;
                                bios_vsync_duration<=bios_row_vsync_duration;
                                bios_interlaced_offset<=bios_row_interlaced_offset;
                                bios_rgb<=bios_live_rgb;
                                bios_use_709<=(bios_row_h_active >= 16'd1280);
                                bios_vic<=bios_live_vic;
                                bios_ws_infoframe<=bios_live_ws_infoframe;
                                bios_csc_idx<=5'd0;
                                mode_applied_ok<=1'b0;

                                // adv7511_power_down_tmds(): update A1[5:2]=1.
                                op_kind<=OP_READ; op_target_addr<=ADV_ADDR;
                                adv_waddr<=8'hA1; op_go<=1'b1;
                                bios_st<=BIOS_TMDS_DN_RD_WAIT;
                            end
                        end

                        BIOS_TMDS_DN_RD_WAIT: if (op_done) begin
                            op_kind<=OP_WRITE; op_target_addr<=ADV_ADDR;
                            adv_waddr<=8'hA1;
                            adv_wdata<=adv_rdata | 8'h3C;
                            op_go<=1'b1;
                            bios_st<=BIOS_TMDS_DN_WR_WAIT;
                        end

                        BIOS_TMDS_DN_WR_WAIT: if (op_done) begin
                            // Enter set_video_mode_bios(). It has its own static
                            // current_mode/current_avinfo pair and bails before
                            // table selection when that inner pair already matches.
                            if ((bios_pending_mode == bios_set_current_mode) &&
                                (bios_pending_avinfo == bios_set_current_avinfo)) begin
                                op_kind<=OP_READ; op_target_addr<=ADV_ADDR;
                                adv_waddr<=8'hA1; op_go<=1'b1;
                                bios_st<=BIOS_TMDS_UP_RD_WAIT;
                            end else begin
                                // Source updates the inner static pair BEFORE
                                // validating encoder/table index.
                                bios_set_current_mode<=bios_pending_mode;
                                bios_set_current_avinfo<=bios_pending_avinfo;
                                if (bios_skip_program) begin
                                    // Invalid encoder/table row returns from
                                    // set_video_mode_bios(); outer bios_loop()
                                    // still executes power_up_tmds().
                                    op_kind<=OP_READ; op_target_addr<=ADV_ADDR;
                                    adv_waddr<=8'hA1; op_go<=1'b1;
                                    bios_st<=BIOS_TMDS_UP_RD_WAIT;
                                end else if (bios_rgb) begin
                                    // adv7511_apply_csc(): full writes 0x18-0x2F.
                                    bios_csc_idx<=5'd0;
                                    op_kind<=OP_WRITE; op_target_addr<=ADV_ADDR;
                                    adv_waddr<=8'h18;
                                    adv_wdata<=bios_csc_byte(bios_use_709,5'd0);
                                    op_go<=1'b1;
                                    bios_st<=BIOS_CSC_WRITE_WAIT;
                                end else begin
                                    // adv7511_disable_csc(): clear 0x18[7].
                                    op_kind<=OP_READ; op_target_addr<=ADV_ADDR;
                                    adv_waddr<=8'h18; op_go<=1'b1;
                                    bios_st<=BIOS_CSC_DIS_RD_WAIT;
                                end
                            end
                        end

                        BIOS_CSC_DIS_RD_WAIT: if (op_done) begin
                            op_kind<=OP_WRITE; op_target_addr<=ADV_ADDR;
                            adv_waddr<=8'h18;
                            adv_wdata<=adv_rdata & ~8'h80;
                            op_go<=1'b1;
                            bios_st<=BIOS_CSC_DIS_WR_WAIT;
                        end

                        BIOS_CSC_DIS_WR_WAIT: if (op_done) begin
                            // Continue directly to geometry.
                            op_kind<=OP_WRITE; op_target_addr<=ADV_ADDR;
                            adv_waddr<=8'h35; adv_wdata<=bios_adv_delay_hs[9:2];
                            op_go<=1'b1; bios_st<=BIOS_WR35_WAIT;
                        end

                        BIOS_CSC_WRITE_WAIT: if (op_done) begin
                            if (bios_csc_idx == 5'd23) begin
                                op_kind<=OP_WRITE; op_target_addr<=ADV_ADDR;
                                adv_waddr<=8'h35; adv_wdata<=bios_adv_delay_hs[9:2];
                                op_go<=1'b1; bios_st<=BIOS_WR35_WAIT;
                            end else begin
                                bios_csc_idx<=bios_csc_idx+5'd1;
                                op_kind<=OP_WRITE; op_target_addr<=ADV_ADDR;
                                adv_waddr<=8'h19 + {3'b000,bios_csc_idx};
                                adv_wdata<=bios_csc_byte(
                                    bios_use_709,bios_csc_idx+5'd1);
                                op_go<=1'b1;
                            end
                        end

                        BIOS_WR35_WAIT: if (op_done) begin
                            op_kind<=OP_WRITE; op_target_addr<=ADV_ADDR;
                            adv_waddr<=8'h36;
                            adv_wdata<={bios_adv_delay_hs[1:0],
                                       bios_vs_delay[5:0]};
                            op_go<=1'b1;
                            bios_st<=BIOS_WR36_WAIT;
                        end

                        BIOS_WR36_WAIT: if (op_done) begin
                            op_kind<=OP_READ; op_target_addr<=ADV_ADDR;
                            adv_waddr<=8'h37; op_go<=1'b1;
                            bios_st<=BIOS_RD37_WAIT;
                        end

                        BIOS_RD37_WAIT: if (op_done) begin
                            op_kind<=OP_WRITE; op_target_addr<=ADV_ADDR;
                            adv_waddr<=8'h37;
                            adv_wdata<=((adv_rdata & 8'hE0) |
                                       {3'b000,bios_h_active[11:7]});
                            op_go<=1'b1;
                            bios_st<=BIOS_WR37_WAIT;
                        end

                        BIOS_WR37_WAIT: if (op_done) begin
                            op_kind<=OP_WRITE; op_target_addr<=ADV_ADDR;
                            adv_waddr<=8'h38;
                            adv_wdata<={bios_h_active[6:0],1'b0};
                            op_go<=1'b1;
                            bios_st<=BIOS_WR38_WAIT;
                        end

                        BIOS_WR38_WAIT: if (op_done) begin
                            op_kind<=OP_WRITE; op_target_addr<=ADV_ADDR;
                            adv_waddr<=8'h39;
                            adv_wdata<=bios_v_active[11:4];
                            op_go<=1'b1;
                            bios_st<=BIOS_WR39_WAIT;
                        end

                        BIOS_WR39_WAIT: if (op_done) begin
                            op_kind<=OP_WRITE; op_target_addr<=ADV_ADDR;
                            adv_waddr<=8'h3A;
                            adv_wdata<={bios_v_active[3:0],4'b0000};
                            op_go<=1'b1;
                            bios_st<=BIOS_WR3A_WAIT;
                        end

                        BIOS_WR3A_WAIT: if (op_done) begin
                            // X-HD V0.1.8 always programs D7-DC in BIOS mode.
                            op_kind<=OP_WRITE; op_target_addr<=ADV_ADDR;
                            adv_waddr<=8'hD7;
                            adv_wdata<=bios_hsync_placement[9:2];
                            op_go<=1'b1;
                            bios_st<=BIOS_WRD7_WAIT;
                        end

                        BIOS_WRD7_WAIT: if (op_done) begin
                            op_kind<=OP_WRITE; op_target_addr<=ADV_ADDR;
                            adv_waddr<=8'hD8;
                            adv_wdata<={bios_hsync_placement[1:0],
                                       bios_hsync_duration[9:4]};
                            op_go<=1'b1;
                            bios_st<=BIOS_WRD8_WAIT;
                        end

                        BIOS_WRD8_WAIT: if (op_done) begin
                            op_kind<=OP_WRITE; op_target_addr<=ADV_ADDR;
                            adv_waddr<=8'hD9;
                            adv_wdata<={bios_hsync_duration[3:0],
                                       bios_vsync_placement[9:6]};
                            op_go<=1'b1;
                            bios_st<=BIOS_WRD9_WAIT;
                        end

                        BIOS_WRD9_WAIT: if (op_done) begin
                            op_kind<=OP_WRITE; op_target_addr<=ADV_ADDR;
                            adv_waddr<=8'hDA;
                            adv_wdata<={bios_vsync_placement[5:0],
                                       bios_vsync_duration[9:8]};
                            op_go<=1'b1;
                            bios_st<=BIOS_WRDA_WAIT;
                        end

                        BIOS_WRDA_WAIT: if (op_done) begin
                            op_kind<=OP_WRITE; op_target_addr<=ADV_ADDR;
                            adv_waddr<=8'hDB;
                            adv_wdata<=bios_vsync_duration[7:0];
                            op_go<=1'b1;
                            bios_st<=BIOS_WRDB_WAIT;
                        end

                        // X-HD V0.1.8 release order is DB -> DC -> RMW 41.
                        // Current master moved DC after 0x41, but the release
                        // firmware we are matching writes the complete sync
                        // adjustment register set before enabling it via 41[1].
                        BIOS_WRDB_WAIT: if (op_done) begin
                            op_kind<=OP_WRITE; op_target_addr<=ADV_ADDR;
                            adv_waddr<=8'hDC;
                            adv_wdata<={bios_interlaced_offset,5'b00000};
                            op_go<=1'b1;
                            bios_st<=BIOS_WRDC_WAIT;
                        end

                        BIOS_WRDC_WAIT: if (op_done) begin
                            op_kind<=OP_READ; op_target_addr<=ADV_ADDR;
                            adv_waddr<=8'h41; op_go<=1'b1;
                            bios_st<=BIOS_RD41_WAIT;
                        end

                        BIOS_RD41_WAIT: if (op_done) begin
                            // X-HD V0.1.8 BIOS path unconditionally enables manual sync.
                            op_kind<=OP_WRITE; op_target_addr<=ADV_ADDR;
                            adv_waddr<=8'h41;
                            adv_wdata<=adv_rdata | 8'h02;
                            op_go<=1'b1;
                            bios_st<=BIOS_WR41_WAIT;
                        end

                        BIOS_WR41_WAIT: if (op_done) begin
                            op_kind<=OP_READ; op_target_addr<=ADV_ADDR;
                            adv_waddr<=8'hD0; op_go<=1'b1;
                            bios_st<=BIOS_RDD0_WAIT;
                        end

                        BIOS_RDD0_WAIT: if (op_done) begin
                            op_kind<=OP_WRITE; op_target_addr<=ADV_ADDR;
                            adv_waddr<=8'hD0;
                            adv_wdata<=adv_rdata | 8'h02;
                            op_go<=1'b1;
                            bios_st<=BIOS_WRD0_WAIT;
                        end

                        BIOS_WRD0_WAIT: if (op_done) begin
                            op_kind<=OP_WRITE; op_target_addr<=ADV_ADDR;
                            adv_waddr<=8'h3C;
                            adv_wdata<={2'b00,bios_vic};
                            op_go<=1'b1;
                            bios_st<=BIOS_WR3C_WAIT;
                        end

                        BIOS_WR3C_WAIT: if (op_done) begin
                            op_kind<=OP_READ; op_target_addr<=ADV_ADDR;
                            adv_waddr<=8'h4A; op_go<=1'b1;
                            bios_st<=BIOS_AVI_RD4A_SET;
                        end

                        BIOS_AVI_RD4A_SET: if (op_done) begin
                            op_kind<=OP_WRITE; op_target_addr<=ADV_ADDR;
                            adv_waddr<=8'h4A;
                            adv_wdata<=adv_rdata | 8'h40;
                            op_go<=1'b1;
                            bios_st<=BIOS_AVI_WR4A_SET;
                        end

                        BIOS_AVI_WR4A_SET: if (op_done) begin
                            op_kind<=OP_READ; op_target_addr<=ADV_ADDR;
                            adv_waddr<=8'h55; op_go<=1'b1;
                            bios_st<=BIOS_AVI_RD55;
                        end

                        BIOS_AVI_RD55: if (op_done) begin
                            op_kind<=OP_WRITE; op_target_addr<=ADV_ADDR;
                            adv_waddr<=8'h55;
                            // CSC always presents YCbCr to the ADV output path.
                            adv_wdata<=((adv_rdata & ~8'h73) | 8'h52);
                            op_go<=1'b1;
                            bios_st<=BIOS_AVI_WR55;
                        end

                        BIOS_AVI_WR55: if (op_done) begin
                            op_kind<=OP_WRITE; op_target_addr<=ADV_ADDR;
                            adv_waddr<=8'h56;
                            adv_wdata<=((bios_vic==6'd4 || bios_vic==6'd5)
                                      ? 8'h80 : 8'h40) |
                                      (bios_ws_infoframe ? 8'h28 : 8'h18);
                            op_go<=1'b1;
                            bios_st<=BIOS_AVI_WR56;
                        end

                        BIOS_AVI_WR56: if (op_done) begin
                            op_kind<=OP_WRITE; op_target_addr<=ADV_ADDR;
                            adv_waddr<=8'h57; adv_wdata<=8'h80;
                            op_go<=1'b1;
                            bios_st<=BIOS_AVI_WR57;
                        end

                        BIOS_AVI_WR57: if (op_done) begin
                            op_kind<=OP_WRITE; op_target_addr<=ADV_ADDR;
                            adv_waddr<=8'h58;
                            adv_wdata<={2'b00,bios_vic};
                            op_go<=1'b1;
                            bios_st<=BIOS_AVI_WR58;
                        end

                        BIOS_AVI_WR58: if (op_done) begin
                            op_kind<=OP_WRITE; op_target_addr<=ADV_ADDR;
                            adv_waddr<=8'h59; adv_wdata<=8'h30;
                            op_go<=1'b1;
                            bios_st<=BIOS_AVI_WR59;
                        end

                        BIOS_AVI_WR59: if (op_done) begin
                            op_kind<=OP_READ; op_target_addr<=ADV_ADDR;
                            adv_waddr<=8'h4A; op_go<=1'b1;
                            bios_st<=BIOS_AVI_RD4A_CLR;
                        end

                        BIOS_AVI_RD4A_CLR: if (op_done) begin
                            op_kind<=OP_WRITE; op_target_addr<=ADV_ADDR;
                            adv_waddr<=8'h4A;
                            adv_wdata<=adv_rdata & ~8'h40;
                            op_go<=1'b1;
                            bios_st<=BIOS_AVI_WR4A_CLR;
                        end

                        BIOS_AVI_WR4A_CLR: if (op_done) begin
                            // set_adv_video_mode_bios() is complete here.
                            // bios_loop() immediately powers TMDS back up.
                            op_kind<=OP_READ; op_target_addr<=ADV_ADDR;
                            adv_waddr<=8'hA1; op_go<=1'b1;
                            bios_st<=BIOS_TMDS_UP_RD_WAIT;
                        end

                        BIOS_TMDS_UP_RD_WAIT: if (op_done) begin
                            op_kind<=OP_WRITE; op_target_addr<=ADV_ADDR;
                            adv_waddr<=8'hA1;
                            adv_wdata<=adv_rdata & ~8'h3C;
                            op_go<=1'b1;
                            bios_st<=BIOS_TMDS_UP_WR_WAIT;
                        end

                        BIOS_TMDS_UP_WR_WAIT: if (op_done) begin
                            bios_current_mode<=bios_pending_mode;
                            bios_current_avinfo<=bios_pending_avinfo;
                            if (!bios_skip_program) begin
                                mode_applied_ok<=1'b1;
                            end
                            cfg_ack<=1'b1;
                            bios_st<=BIOS_IDLE;
                            op_kind<=OP_READ; op_target_addr<=ADV_ADDR;
                            adv_waddr<=8'h9E; op_go<=1'b1;
                            br_st<=BR_READY;
                        end

                        default: bios_st<=BIOS_IDLE;
                    endcase
                end

                // adv_handle_interrupts() from X-HD V0.1.8. HAL return values
                // are intentionally not used to change control flow: failed reads
                // already return 0 through the source-equivalent register helper.
                BR_XHD_IRQ_HANDLER: begin
                    case (xhd_irq_phase)
                        IRQ_WAIT_FLAGS: if (op_done) begin
                            xhd_irq_flags<=adv_rdata;
                            if (adv_rdata[7]) begin
                                op_kind<=OP_READ; op_target_addr<=ADV_ADDR;
                                adv_waddr<=8'h42; op_go<=1'b1;
                                xhd_irq_phase<=IRQ_WAIT_HPD_STATUS;
                            end else if (adv_rdata[6]) begin
                                op_kind<=OP_READ; op_target_addr<=ADV_ADDR;
                                adv_waddr<=8'h42; op_go<=1'b1;
                                xhd_irq_phase<=IRQ_WAIT_MS_STATUS;
                            end else begin
                                xhd_irq_phase<=IRQ_DECIDE_POWER;
                            end
                        end

                        IRQ_WAIT_HPD_STATUS: if (op_done) begin
                            xhd_hpd<=adv_rdata[6];
                            if (xhd_irq_flags[6]) begin
                                // Source performs a second, independent 0x42 read.
                                op_kind<=OP_READ; op_target_addr<=ADV_ADDR;
                                adv_waddr<=8'h42; op_go<=1'b1;
                                xhd_irq_phase<=IRQ_WAIT_MS_STATUS;
                            end else begin
                                xhd_irq_phase<=IRQ_DECIDE_POWER;
                            end
                        end

                        IRQ_WAIT_MS_STATUS: if (op_done) begin
                            xhd_monitor_sense<=adv_rdata[5];
                            xhd_irq_phase<=IRQ_DECIDE_POWER;
                        end

                        IRQ_DECIDE_POWER: begin
                            if (xhd_hpd && xhd_monitor_sense) begin
                                // adv7511_power_up(): 41=10, 30ms, 00, 30ms, 10, 50ms.
                                op_kind<=OP_WRITE; op_target_addr<=ADV_ADDR;
                                adv_waddr<=8'h41; adv_wdata<=8'h10; op_go<=1'b1;
                                xhd_irq_phase<=IRQ_POWER_A_WAIT;
                            end else begin
                                // encoder.interrupt = 0 immediately before
                                // update_register(0x96, 0xC0, 0xC0).
                                if (!adv_int_edge) adv_irq_pending<=1'b0;
                                op_kind<=OP_READ; op_target_addr<=ADV_ADDR;
                                adv_waddr<=8'h96; op_go<=1'b1;
                                xhd_irq_phase<=IRQ_CLEAR_READ_WAIT;
                            end
                        end

                        IRQ_POWER_A_WAIT: if (op_done) begin
                            delay_ctr<=24'd0; xhd_irq_phase<=IRQ_POWER_A_DELAY;
                        end
                        IRQ_POWER_A_DELAY: begin
                            if (delay_ctr < DLY_30MS) delay_ctr<=delay_ctr+24'd1;
                            else begin
                                op_kind<=OP_WRITE; op_target_addr<=ADV_ADDR;
                                adv_waddr<=8'h41; adv_wdata<=8'h00; op_go<=1'b1;
                                xhd_irq_phase<=IRQ_POWER_B_WAIT;
                            end
                        end
                        IRQ_POWER_B_WAIT: if (op_done) begin
                            delay_ctr<=24'd0; xhd_irq_phase<=IRQ_POWER_B_DELAY;
                        end
                        IRQ_POWER_B_DELAY: begin
                            if (delay_ctr < DLY_30MS) delay_ctr<=delay_ctr+24'd1;
                            else begin
                                op_kind<=OP_WRITE; op_target_addr<=ADV_ADDR;
                                adv_waddr<=8'h41; adv_wdata<=8'h10; op_go<=1'b1;
                                xhd_irq_phase<=IRQ_POWER_C_WAIT;
                            end
                        end
                        IRQ_POWER_C_WAIT: if (op_done) begin
                            delay_ctr<=24'd0; xhd_irq_phase<=IRQ_POWER_C_DELAY;
                        end
                        IRQ_POWER_C_DELAY: begin
                            if (delay_ctr < DLY_50MS) delay_ctr<=delay_ctr+24'd1;
                            else begin
                                // encoder.interrupt = 0, then update_register(0x96,...).
                                if (!adv_int_edge) adv_irq_pending<=1'b0;
                                op_kind<=OP_READ; op_target_addr<=ADV_ADDR;
                                adv_waddr<=8'h96; op_go<=1'b1;
                                xhd_irq_phase<=IRQ_CLEAR_READ_WAIT;
                            end
                        end

                        IRQ_CLEAR_READ_WAIT: if (op_done) begin
                            op_kind<=OP_WRITE; op_target_addr<=ADV_ADDR;
                            adv_waddr<=8'h96;
                            adv_wdata<=((adv_rdata & ~8'hC0) | 8'hC0);
                            op_go<=1'b1;
                            xhd_irq_phase<=IRQ_CLEAR_WRITE_WAIT;
                        end

                        IRQ_CLEAR_WRITE_WAIT: if (op_done) begin
                            xhd_irq_flags<=8'd0;
                            // Continue the same source loop after
                            // adv_handle_interrupts(). Bootloader recovery goes
                            // straight to stand_alone_loop(); application selects
                            // bios_loop()/stand_alone_loop() after its PLL read.
                            if (xhd_is_boot_rec) begin
                                standalone_return_boot_rec<=1'b1;
                                op_kind<=OP_READ; op_target_addr<=ADV_ADDR;
                                adv_waddr<=8'h3E; op_go<=1'b1;
                                br_st<=BR_BOOT_REC_VIC;
                            end else if (!FORCE_STANDALONE && bios_took_over) begin
                                if (cfg_pending && !cfg_ack)
                                    br_st<=BR_ENCODER_REPORT;
                                else begin
                                    op_kind<=OP_READ; op_target_addr<=ADV_ADDR;
                                    adv_waddr<=8'h9E; op_go<=1'b1;
                                    br_st<=BR_READY;
                                end
                            end else begin
                                standalone_return_boot_rec<=1'b0;
                                op_kind<=OP_READ; op_target_addr<=ADV_ADDR;
                                adv_waddr<=8'h3E; op_go<=1'b1;
                                br_st<=BR_READY;
                            end
                        end

                        default: begin
                            xhd_irq_phase<=IRQ_WAIT_FLAGS;
                            xhd_irq_flags<=8'd0;
                            if (xhd_is_boot_rec) begin
                                delay_ctr<=24'd0; br_st<=BR_BOOT_REC_DELAY;
                            end else br_st<=BR_READY;
                        end
                    endcase
                end

                BR_XHD_VIC_REREAD_WAIT: if (op_done) begin
                    xhd_detected_vic<=adv_rdata[7:2];
                    xhd_encoder_vic<=adv_rdata[7:2];

                    if (xhd_vic_map[3]) begin
                        standalone_target_mode<=xhd_vic_map[2:0];
                        sa_hs_latched<=sa_hs_delay(
                            xhd_vic_map[2:0],
                            last_encoder_id==ENC_XCALIBUR);
                        sa_vs_latched<=sa_vs_delay(xhd_vic_map[2:0]);
                        sa_h_latched<=sa_h_active(xhd_vic_map[2:0]);
                        sa_v_latched<=sa_v_active(xhd_vic_map[2:0]);
                        sa_vic_latched<=sa_out_vic(xhd_vic_map[2:0]);
                        sa_ws_latched<=sa_widescreen(xhd_vic_map[2:0]);
                        mode_applied_ok<=1'b0;
                        br_st<=BR_STANDALONE_CSC_DISABLE;
                    end else if (standalone_return_boot_rec) begin
                        delay_ctr<=24'd0;
                        br_st<=BR_BOOT_REC_DELAY;
                    end else begin
                        op_kind<=OP_READ; op_target_addr<=ADV_ADDR;
                        adv_waddr<=8'h9E; op_go<=1'b1;
                        br_st<=BR_READY;
                    end
                end

                // =========================================================
                // Standalone ADV mode applicator (X-HD set_video_mode_vic()).
                //
                // Performs the complete X-HD mode transaction:
                // CSC policy, 35..3A geometry, AVI InfoFrame, 0x41[1],
                // 0xD0[1], and VIC->0x3C. The X-HD standalone timing rows
                // (distinct VGA /
                // 480p 4:3 / 480p 16:9 / 720p / 1080i) are retained unchanged.
                // =========================================================

                // adv7511_disable_csc(): clear 0x18[7]. Standalone presents YCbCr,
                // so the RGB coefficient block is not loaded; per-mode aspect is
                // carried by the AVI InfoFrame tail, not an 0x56/0x16 RMW prelude.
                BR_STANDALONE_CSC_DISABLE: begin
                    if (op_done && op_kind==OP_READ) begin
                        op_kind<=OP_WRITE; op_target_addr<=ADV_ADDR; adv_waddr<=8'h18;
                        adv_wdata<=adv_rdata & ~8'h80; op_go<=1'b1;
                    end else if (op_done && op_kind==OP_WRITE) begin
                        br_st<=BR_STANDALONE_WR_35;
                    end else if (!op_go && ops_st==OPS_IDLE) begin
                        op_kind<=OP_READ; op_target_addr<=ADV_ADDR; adv_waddr<=8'h18; op_go<=1'b1;
                    end
                end

                // adv7511_write_register(0x35, hs_delay >> 2).
                BR_STANDALONE_WR_35: begin
                    if (op_done && op_kind==OP_WRITE) begin
                        br_st<=BR_STANDALONE_WR_36;
                    end else if (!op_go && ops_st==OPS_IDLE) begin
                        op_kind<=OP_WRITE; op_target_addr<=ADV_ADDR; adv_waddr<=8'h35;
                        adv_wdata<=sa_hs_latched[9:2]; op_go<=1'b1;
                    end
                end

                // adv7511_write_register(0x36, (vs & 0x3F) | (hs << 6)).
                BR_STANDALONE_WR_36: begin
                    if (op_done && op_kind==OP_WRITE) begin
                        br_st<=BR_STANDALONE_WR_37;
                    end else if (!op_go && ops_st==OPS_IDLE) begin
                        op_kind<=OP_WRITE; op_target_addr<=ADV_ADDR; adv_waddr<=8'h36;
                        adv_wdata<={sa_hs_latched[1:0],sa_vs_latched[5:0]}; op_go<=1'b1;
                    end
                end

                // adv7511_update_register(0x37,0x1F,active_w>>7).
                BR_STANDALONE_WR_37: begin
                    if (op_done && op_kind==OP_READ) begin
                        op_kind<=OP_WRITE; op_target_addr<=ADV_ADDR; adv_waddr<=8'h37;
                        adv_wdata<=((adv_rdata & ~8'h1F) | {3'b000,sa_h_latched[11:7]}); op_go<=1'b1;
                    end else if (op_done && op_kind==OP_WRITE) begin
                        br_st<=BR_STANDALONE_WR_38;
                    end else if (!op_go && ops_st==OPS_IDLE) begin
                        op_kind<=OP_READ; op_target_addr<=ADV_ADDR; adv_waddr<=8'h37; op_go<=1'b1;
                    end
                end

                // adv7511_write_register(0x38, active_w << 1).
                BR_STANDALONE_WR_38: begin
                    if (op_done && op_kind==OP_WRITE) begin
                        br_st<=BR_STANDALONE_WR_39;
                    end else if (!op_go && ops_st==OPS_IDLE) begin
                        op_kind<=OP_WRITE; op_target_addr<=ADV_ADDR; adv_waddr<=8'h38;
                        adv_wdata<={sa_h_latched[6:0],1'b0}; op_go<=1'b1;
                    end
                end

                // adv7511_write_register(0x39, active_h >> 4).
                BR_STANDALONE_WR_39: begin
                    if (op_done && op_kind==OP_WRITE) begin
                        br_st<=BR_STANDALONE_WR_3A;
                    end else if (!op_go && ops_st==OPS_IDLE) begin
                        op_kind<=OP_WRITE; op_target_addr<=ADV_ADDR; adv_waddr<=8'h39;
                        adv_wdata<=sa_v_latched[11:4]; op_go<=1'b1;
                    end
                end

                // adv7511_write_register(0x3A, active_h << 4).
                BR_STANDALONE_WR_3A: begin
                    if (op_done && op_kind==OP_WRITE) begin
                        // X-HD calls update_avi_infoframe() immediately after 35..3A.
                        br_st<=BR_SA_AVI_4A_SET;
                    end else if (!op_go && ops_st==OPS_IDLE) begin
                        op_kind<=OP_WRITE; op_target_addr<=ADV_ADDR; adv_waddr<=8'h3A;
                        adv_wdata<={sa_v_latched[3:0],4'b0000}; op_go<=1'b1;
                    end
                end

                // update_avi_infoframe(widescreen, false, vic), source order.
                BR_SA_AVI_4A_SET: begin
                    if (op_done && op_kind==OP_READ) begin
                        op_kind<=OP_WRITE; op_target_addr<=ADV_ADDR; adv_waddr<=8'h4A;
                        adv_wdata<=adv_rdata | 8'h40; op_go<=1'b1;
                    end else if (op_done && op_kind==OP_WRITE) begin
                        br_st<=BR_SA_AVI_55;
                    end else if (!op_go && ops_st==OPS_IDLE) begin
                        op_kind<=OP_READ; op_target_addr<=ADV_ADDR; adv_waddr<=8'h4A; op_go<=1'b1;
                    end
                end
                BR_SA_AVI_55: begin
                    if (op_done && op_kind==OP_READ) begin
                        op_kind<=OP_WRITE; op_target_addr<=ADV_ADDR; adv_waddr<=8'h55;
                        adv_wdata<=(adv_rdata & ~8'h73) | 8'h52; op_go<=1'b1;
                    end else if (op_done && op_kind==OP_WRITE) begin
                        br_st<=BR_SA_AVI_56;
                    end else if (!op_go && ops_st==OPS_IDLE) begin
                        op_kind<=OP_READ; op_target_addr<=ADV_ADDR; adv_waddr<=8'h55; op_go<=1'b1;
                    end
                end
                BR_SA_AVI_56: begin
                    if (op_done && op_kind==OP_WRITE) begin
                        br_st<=BR_SA_AVI_57;
                    end else if (!op_go && ops_st==OPS_IDLE) begin
                        op_kind<=OP_WRITE; op_target_addr<=ADV_ADDR; adv_waddr<=8'h56;
                        adv_wdata<=((sa_vic_latched==6'd4 || sa_vic_latched==6'd5) ? 8'h80 : 8'h40)
                                 | (sa_ws_latched ? 8'h28 : 8'h18);
                        op_go<=1'b1;
                    end
                end
                BR_SA_AVI_57: begin
                    if (op_done && op_kind==OP_WRITE) begin
                        br_st<=BR_SA_AVI_58;
                    end else if (!op_go && ops_st==OPS_IDLE) begin
                        op_kind<=OP_WRITE; op_target_addr<=ADV_ADDR; adv_waddr<=8'h57;
                        adv_wdata<=8'h80; op_go<=1'b1;
                    end
                end
                BR_SA_AVI_58: begin
                    if (op_done && op_kind==OP_WRITE) begin
                        br_st<=BR_SA_AVI_59;
                    end else if (!op_go && ops_st==OPS_IDLE) begin
                        op_kind<=OP_WRITE; op_target_addr<=ADV_ADDR; adv_waddr<=8'h58;
                        adv_wdata<={2'b00,sa_vic_latched}; op_go<=1'b1;
                    end
                end
                BR_SA_AVI_59: begin
                    if (op_done && op_kind==OP_WRITE) begin
                        br_st<=BR_SA_AVI_4A_CLR;
                    end else if (!op_go && ops_st==OPS_IDLE) begin
                        op_kind<=OP_WRITE; op_target_addr<=ADV_ADDR; adv_waddr<=8'h59;
                        adv_wdata<=8'h30; op_go<=1'b1;
                    end
                end
                BR_SA_AVI_4A_CLR: begin
                    if (op_done && op_kind==OP_READ) begin
                        op_kind<=OP_WRITE; op_target_addr<=ADV_ADDR; adv_waddr<=8'h4A;
                        adv_wdata<=adv_rdata & ~8'h40; op_go<=1'b1;
                    end else if (op_done && op_kind==OP_WRITE) begin
                        br_st <= (standalone_target_mode==SA_1080I) ? BR_SA_INT_37 : BR_SA_41;
                    end else if (!op_go && ops_st==OPS_IDLE) begin
                        op_kind<=OP_READ; op_target_addr<=ADV_ADDR; adv_waddr<=8'h4A; op_go<=1'b1;
                    end
                end

                // X-HD 1080i-only operations after AVI update:
                // update 37[E0]=0, write DC=0, then set 41[1].
                BR_SA_INT_37: begin
                    if (op_done && op_kind==OP_READ) begin
                        op_kind<=OP_WRITE; op_target_addr<=ADV_ADDR; adv_waddr<=8'h37;
                        adv_wdata<=adv_rdata & ~8'hE0; op_go<=1'b1;
                    end else if (op_done && op_kind==OP_WRITE) begin
                        br_st<=BR_SA_INT_DC;
                    end else if (!op_go && ops_st==OPS_IDLE) begin
                        op_kind<=OP_READ; op_target_addr<=ADV_ADDR; adv_waddr<=8'h37; op_go<=1'b1;
                    end
                end
                BR_SA_INT_DC: begin
                    if (op_done && op_kind==OP_WRITE) begin
                        br_st<=BR_SA_41;
                    end else if (!op_go && ops_st==OPS_IDLE) begin
                        op_kind<=OP_WRITE; op_target_addr<=ADV_ADDR; adv_waddr<=8'hDC;
                        adv_wdata<=8'h00; op_go<=1'b1;
                    end
                end

                // Progressive: clear manual sync. 1080i: enable manual sync.
                BR_SA_41: begin
                    if (op_done && op_kind==OP_READ) begin
                        op_kind<=OP_WRITE; op_target_addr<=ADV_ADDR; adv_waddr<=8'h41;
                        adv_wdata <= (standalone_target_mode==SA_1080I)
                                   ? (adv_rdata | 8'h02)
                                   : (adv_rdata & ~8'h02);
                        op_go<=1'b1;
                    end else if (op_done && op_kind==OP_WRITE) begin
                        br_st<=BR_SA_D0;
                    end else if (!op_go && ops_st==OPS_IDLE) begin
                        op_kind<=OP_READ; op_target_addr<=ADV_ADDR; adv_waddr<=8'h41; op_go<=1'b1;
                    end
                end

                // adv7511_update_register(0xD0,0x02,0x02).
                BR_SA_D0: begin
                    if (op_done && op_kind==OP_READ) begin
                        op_kind<=OP_WRITE; op_target_addr<=ADV_ADDR; adv_waddr<=8'hD0;
                        adv_wdata<=adv_rdata | 8'h02; op_go<=1'b1;
                    end else if (op_done && op_kind==OP_WRITE) begin
                        br_st<=BR_SA_3C;
                    end else if (!op_go && ops_st==OPS_IDLE) begin
                        op_kind<=OP_READ; op_target_addr<=ADV_ADDR; adv_waddr<=8'hD0; op_go<=1'b1;
                    end
                end

                // adv7511_write_register(0x3C, vic), then the two debug reads of 0x3D.
                BR_SA_3C: begin
                    if (op_done && op_kind==OP_WRITE) begin
                        mode_finish_phase<=2'd0;
                        br_st<=BR_XHD_MODE_FINISH;
                    end else if (!op_go && ops_st==OPS_IDLE) begin
                        op_kind<=OP_WRITE; op_target_addr<=ADV_ADDR; adv_waddr<=8'h3C;
                        adv_wdata<={2'b00,sa_vic_latched}; op_go<=1'b1;
                    end
                end

                // X-HD performs two 0x3D reads for its debug output:
                // pixel repetition first, then actual transmitted VIC.
                BR_XHD_MODE_FINISH: begin
                    case (mode_finish_phase)
                        2'd0: if (!op_go && ops_st==OPS_IDLE) begin
                            op_kind<=OP_READ; op_target_addr<=ADV_ADDR;
                            adv_waddr<=8'h3D; op_go<=1'b1;
                            mode_finish_phase<=2'd1;
                        end
                        2'd1: if (op_done) begin
                            op_kind<=OP_READ; op_target_addr<=ADV_ADDR;
                            adv_waddr<=8'h3D; op_go<=1'b1;
                            mode_finish_phase<=2'd2;
                        end
                        2'd2: if (op_done) begin
                            mode_applied_ok<=(adv_rdata[4:0] == sa_vic_latched[4:0]);
                            if (standalone_return_boot_rec) begin
                                delay_ctr<=24'd0;
                                br_st<=BR_BOOT_REC_DELAY;
                            end else begin
                                op_kind<=OP_READ; op_target_addr<=ADV_ADDR;
                                adv_waddr<=8'h9E; op_go<=1'b1;
                                br_st<=BR_READY;
                            end
                        end
                        default: mode_finish_phase<=2'd0;
                    endcase
                end

                default: br_st<=BR_RESET;
            endcase

            // FORCE_STANDALONE keeps the standalone video engine in control,
            // but the Xbox-facing 0x69 responder remains available so the BIOS
            // encoder byte can identify Focus.
        end
    end

endmodule