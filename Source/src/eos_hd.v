// eos_hd.v -- EOS-native HD (ADV7511) controller. Replaces the role of an
// STM-based X-HD/HD+ device on boards with no onboard STM32. See
// eos_hd_integration_spec.md for the full design; this file implements it.
//
// Implements the active X-HD application behavior in FPGA logic: ADV7511
// initialization, encoder-specific setup, HPD/monitor interrupts, standalone
// VIC following, the BIOS SMBus settings protocol, and the complete BIOS
// table-driven mode applicator.
//
// EOS ENCODER SELECTION:
//   - The physical 1.6 enable strap is sampled at the beginning of BR_RESET.
//     A strapped 1.6 boots directly into the exact X-HD Xcalibur profile.
//   - An unstrapped/pre-1.6 console boots through the validated Conexant
//     profile. A BIOS encoder byte of 0xD4 may make one one-way transition to
//     the exact Focus profile.
//   - X-HD's compile-time encoder build selection is intentionally replaced by
//     this EOS-native mechanism; all register values and timing rows remain
//     source-derived.
//   - FORCE_STANDALONE preserves the validated VIC-following path as a build
//     override. With it cleared, a valid BIOS APPLY switches to the complete
//     X-HD BIOS mode engine after initial video is established.
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
    parameter [23:0] DLY_RETRY = 24'd324_000,     // ~5ms @ 64.8MHz short pause
                                                   // between retry attempts --
                                                   // override for fast simulation
    parameter integer MASTER_SCL_LOW_CYCLES  = 745,
    parameter integer MASTER_SCL_HIGH_CYCLES = 502,
                                                   // X-HD STM timing
                                                   // 0x00303D5B @ 8 MHz:
                                                   // 11.50 us low / 7.75 us high
    parameter integer MASTER_STRETCH_TIMEOUT = 32'd6_480_000,  // eos_i2c_master --
                                                   // override for fast timeout
                                                   // testing (see tb_eos_hd.v)
    parameter integer MASTER_IDLE_WAIT_TIMEOUT = 32'd194_400_000, // bounds S_WAIT_IDLE
                                                   // while EOS itself remains released
    parameter integer MASTER_BUS_FREE_CYCLES = 32'd324, // ~5us continuous bus-free time
                                                   // before EOS starts a master transaction.
                                                   // The prior 1ms requirement could never
                                                   // complete once normal Xbox/SMC SMBus
                                                   // traffic began, leaving the bring-up FSM
                                                   // parked at ST 22 while waiting to start
                                                   // the 0x16 register write.
    parameter [23:0] DLY_BOOT_SETTLE = 24'd0, // X-HD calls init_adv()
                                                   // immediately after GPIO/EXTI
                                                   // initialization. Retained only
                                                   // as an override hook.
    parameter [23:0] DLY_ENC_RESCAN = 24'd3_240_000,  // retained compatibility
                                                   // hook; no active probe is used
    parameter FORCE_STANDALONE = 1'b0              // validated compatibility default.
                                                   // 1 = keep EOS VIC-following active.
                                                   // 0 = initial standalone video, then
                                                   //     exact X-HD BIOS-table takeover.
)(
    input  wire        clk,      // clk_sd domain, same as eos_i2c.v / eos_i2c_master.v
    input  wire        resetn,

    // Stable physical boot strap, already normalized by eos_hdmi_top.v:
    //   0 = Xbox 1.0-1.5 path (validated Conexant default; Focus detectable)
    //   1 = Xbox 1.6 path (direct Xcalibur; Focus detection disabled)
    // It is sampled once in BR_RESET and never consulted again this boot.
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

    // Physical ADV7511 INT output. X-HD configures this input for both rising
    // and falling edges, so EOS mirrors that behavior and does not assume a
    // polarity here.
    input  wire          adv_int,

    // ---- eos_i2c.v's HD relay interface (dual-address slave transport) ----
    output reg          hd_addr_en,     // gates HD_ADDR (0x69) live -- raised
                                         // once ADV init completes (BR_ENABLE_
                                         // VIDEO); the old collision guard is
                                         // gone, so init completion is the gate
    input  wire          hd_addr_match,
    input  wire           hd_byte_valid,
    input  wire  [7:0]     hd_byte,
    input  wire              hd_byte_first,
    output reg   [7:0]        hd_read_data,
    output reg                 hd_read_ready,

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
    output wire [2:0]        hd_disable_reason_out, // WHY BR_HD_DISABLED was
                                            // reached -- ST alone can't tell
                                            // apart the 4 different exhausted-
                                            // retry paths that land there
    output wire              hd_target_known, // ADV presence probe has completed
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

    eos_i2c_master #(
        .SCL_LOW_CYCLES(MASTER_SCL_LOW_CYCLES),
        .SCL_HIGH_CYCLES(MASTER_SCL_HIGH_CYCLES),
        .STRETCH_TIMEOUT(MASTER_STRETCH_TIMEOUT),
        .IDLE_WAIT_TIMEOUT(MASTER_IDLE_WAIT_TIMEOUT),
        .BUS_FREE_CYCLES(MASTER_BUS_FREE_CYCLES),
        .SINGLE_MASTER(1'b1),
        .WAIT_BUS_FREE(1'b1),
        .HONOR_CLOCK_STRETCH(1'b1)
    ) u_master (
        .clk(clk), .resetn(resetn),
        .sda_in(adv_sda_in), .scl_in(adv_scl_in), .sda_oe(adv_sda_oe), .scl_oe(adv_scl_oe),
        .start_go(m_start_go), .start_done(m_start_done), .start_timeout(m_start_timeout),
        .wr_go(m_wr_go), .wr_byte(m_wr_byte), .wr_done(m_wr_done), .wr_ack(m_wr_ack),
        .wr_timeout(m_wr_timeout), .wr_arb_lost(m_wr_arb_lost),
        .rd_go(m_rd_go), .rd_send_ack(m_rd_send_ack), .rd_done(m_rd_done), .rd_byte(m_rd_byte), .rd_timeout(m_rd_timeout),
        .stop_go(m_stop_go), .stop_done(m_stop_done), .busy(m_busy)
    );
    wire m_stop_done;

    // =========================================================================
    // ADV7511 register read/write/update helpers -- a small reusable
    // sub-sequencer, called by the bring-up FSM below via a request/ack
    // handshake (op_go/op_done), since Verilog has no blocking subroutine
    // call across clock cycles -- same "shared subroutine via return-state"
    // idiom used elsewhere in this project (e.g. eos_sd_spi.v's SEND_CMD).
    // =========================================================================
    localparam [2:0]
        OP_NONE  = 3'd0,
        OP_WRITE = 3'd1,   // adv_wdata -> adv_waddr
        OP_READ  = 3'd2,   // adv_waddr -> adv_rdata
        OP_PROBE = 3'd3;   // like OP_READ but reports presence via op_nack instead of failing

    reg  [2:0] op_kind;
    reg        op_go;
    reg  [6:0] op_target_addr;   // which I2C address this op is against (always the ADV now; the old collision-guard probe target is gone)
    reg  [7:0] adv_waddr, adv_wdata;
    reg  [7:0] adv_rdata;
    reg        op_done;
    reg        op_nack;          // 1 = address or register write was NACKed (used for presence probes)
    reg        op_timeout;

    // Snapshot every source-level ADV call. X-HD's C helpers pass these
    // arguments by value into a blocking HAL transaction.
    reg  [2:0] op_exec_kind;
    reg  [6:0] op_exec_target_addr;
    reg  [7:0] op_exec_waddr;
    reg  [7:0] op_exec_wdata;
    reg  [2:0] op_bus_retry_cnt;
    localparam [2:0] OP_MAX_BUS_RETRIES = 3'd5;

    localparam [3:0]
        OPS_IDLE       = 4'd0,
        OPS_START      = 4'd1,
        OPS_ADDR_W     = 4'd2,
        OPS_REG        = 4'd3,
        OPS_DATA_W     = 4'd4,
        OPS_RSTART     = 4'd5,
        OPS_ADDR_R     = 4'd6,
        OPS_DATA_R     = 4'd7,
        OPS_STOP       = 4'd8,
        OPS_DONE       = 4'd9,
        OPS_ARB_BACKOFF= 4'd10;

    reg [3:0] ops_st;
    reg [1:0] ops_arb_retry_cnt;
    reg [23:0] ops_arb_backoff_ctr;
    localparam [1:0] OPS_MAX_ARB_RETRIES = 2'd3;

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            ops_st<=OPS_IDLE; op_done<=1'b0; op_nack<=1'b0; op_timeout<=1'b0; adv_rdata<=8'd0;
            op_exec_kind<=OP_NONE; op_exec_target_addr<=7'd0;
            op_exec_waddr<=8'd0; op_exec_wdata<=8'd0; op_bus_retry_cnt<=3'd0;
            ops_arb_retry_cnt<=2'd0; ops_arb_backoff_ctr<=24'd0;
            m_start_go<=1'b0; m_wr_go<=1'b0; m_rd_go<=1'b0; m_rd_send_ack<=1'b0; m_stop_go<=1'b0; m_wr_byte<=8'd0;
        end else begin
            m_start_go<=1'b0; m_wr_go<=1'b0; m_rd_go<=1'b0; m_stop_go<=1'b0; op_done<=1'b0;

            case (ops_st)
                OPS_IDLE: begin
                    if (op_go) begin
                        op_nack<=1'b0; op_timeout<=1'b0;
                        op_exec_kind<=op_kind;
                        op_exec_target_addr<=op_target_addr;
                        op_exec_waddr<=adv_waddr;
                        op_exec_wdata<=adv_wdata;
                        op_bus_retry_cnt<=3'd0;
                        ops_arb_retry_cnt<=2'd0; ops_arb_backoff_ctr<=24'd0;
                        m_start_go<=1'b1; ops_st<=OPS_START;
                    end
                end
                OPS_START: if (m_start_done) begin
                    if (m_start_timeout) begin
                        // One-shot, exactly like X-HD's blocking HAL: no
                        // transaction opened, so report and finish. No retry --
                        // the ADV bus is private, there is no other master to
                        // lose delivery to.
                        op_nack<=1'b1; op_timeout<=1'b1;
                        ops_st<=OPS_DONE;
                    end else begin
                        m_wr_byte<={op_exec_target_addr, 1'b0}; m_wr_go<=1'b1; ops_st<=OPS_ADDR_W;
                    end
                end
                OPS_ADDR_W: if (m_wr_done) begin
                    if (m_wr_arb_lost) begin
                        if (ops_arb_retry_cnt < OPS_MAX_ARB_RETRIES) begin
                            ops_arb_retry_cnt<=ops_arb_retry_cnt+2'd1;
                            ops_arb_backoff_ctr<=24'd0; ops_st<=OPS_ARB_BACKOFF;
                        end else begin
                            op_nack<=1'b1; op_timeout<=1'b1; ops_st<=OPS_DONE;
                        end
                    end else if (m_wr_timeout || !m_wr_ack) begin
                        op_nack<=1'b1; op_timeout<=m_wr_timeout;
                        m_stop_go<=1'b1; ops_st<=OPS_STOP;
                    end else begin
                        m_wr_byte<=op_exec_waddr; m_wr_go<=1'b1; ops_st<=OPS_REG;
                    end
                end
                OPS_REG: if (m_wr_done) begin
                    if (m_wr_arb_lost) begin
                        if (ops_arb_retry_cnt < OPS_MAX_ARB_RETRIES) begin
                            ops_arb_retry_cnt<=ops_arb_retry_cnt+2'd1;
                            ops_arb_backoff_ctr<=24'd0; ops_st<=OPS_ARB_BACKOFF;
                        end else begin
                            op_nack<=1'b1; op_timeout<=1'b1; ops_st<=OPS_DONE;
                        end
                    end else if (m_wr_timeout || !m_wr_ack) begin
                        op_nack<=1'b1; op_timeout<=m_wr_timeout;
                        m_stop_go<=1'b1; ops_st<=OPS_STOP;
                    end else if (op_exec_kind == OP_WRITE) begin
                        m_wr_byte<=op_exec_wdata; m_wr_go<=1'b1; ops_st<=OPS_DATA_W;
                    end else begin
                        // READ or PROBE: repeated start into a read
                        m_start_go<=1'b1; ops_st<=OPS_RSTART;
                    end
                end
                OPS_DATA_W: if (m_wr_done) begin
                    if (m_wr_arb_lost) begin
                        if (ops_arb_retry_cnt < OPS_MAX_ARB_RETRIES) begin
                            ops_arb_retry_cnt<=ops_arb_retry_cnt+2'd1;
                            ops_arb_backoff_ctr<=24'd0; ops_st<=OPS_ARB_BACKOFF;
                        end else begin
                            op_nack<=1'b1; op_timeout<=1'b1; ops_st<=OPS_DONE;
                        end
                    end else begin
                        op_nack<=(m_wr_timeout || !m_wr_ack); op_timeout<=m_wr_timeout;
                        m_stop_go<=1'b1; ops_st<=OPS_STOP;
                    end
                end
                OPS_RSTART: if (m_start_done) begin
                    if (m_start_timeout) begin
                        op_nack<=1'b1; op_timeout<=1'b1;
                        ops_st<=OPS_DONE;   // one-shot: no retry
                    end else begin
                        m_wr_byte<={op_exec_target_addr, 1'b1}; m_wr_go<=1'b1; ops_st<=OPS_ADDR_R;
                    end
                end
                OPS_ADDR_R: if (m_wr_done) begin
                    if (m_wr_arb_lost) begin
                        if (ops_arb_retry_cnt < OPS_MAX_ARB_RETRIES) begin
                            ops_arb_retry_cnt<=ops_arb_retry_cnt+2'd1;
                            ops_arb_backoff_ctr<=24'd0; ops_st<=OPS_ARB_BACKOFF;
                        end else begin
                            op_nack<=1'b1; op_timeout<=1'b1; ops_st<=OPS_DONE;
                        end
                    end else if (m_wr_timeout || !m_wr_ack) begin
                        op_nack<=1'b1; op_timeout<=m_wr_timeout;
                        m_stop_go<=1'b1; ops_st<=OPS_STOP;
                    end else begin
                        m_rd_send_ack<=1'b0; m_rd_go<=1'b1; ops_st<=OPS_DATA_R;  // single byte, NACK it
                    end
                end
                OPS_DATA_R: if (m_rd_done) begin
                    adv_rdata<=m_rd_byte;
                    op_timeout<=m_rd_timeout;
                    op_nack<=m_rd_timeout;  // a timed-out read is never a valid ACKed response
                    m_stop_go<=1'b1; ops_st<=OPS_STOP;
                end
                OPS_STOP: if (m_stop_done) begin
                    // One-shot per op, exactly like X-HD's blocking HAL_I2C_Mem_*
                    // on its dedicated ADV bus: run the transaction once and
                    // report the result (op_nack reflects a NAK; the init states
                    // ignore it, same as X-HD ignoring the void HAL return). The
                    // old retry existed ONLY to paper over SHARED-bus delivery
                    // failures -- the ADV bus is no longer shared, so it's gone.
                    ops_st<=OPS_DONE;
                end
                OPS_DONE: begin
                    op_done<=1'b1; ops_st<=OPS_IDLE;
                end
                OPS_ARB_BACKOFF: begin
                    // Retained defensive path (arbitration is not expected on
                    // the private ADV bus, where EOS is sole master). If it
                    // ever did lose arbitration to another master, do not emit
                    // STOP -- the winning master owns the transaction. Yield,
                    // then restart the whole ADV register operation.
                    if (ops_arb_backoff_ctr < DLY_RETRY) begin
                        ops_arb_backoff_ctr<=ops_arb_backoff_ctr+24'd1;
                    end else begin
                        op_nack<=1'b0; op_timeout<=1'b0;
                        m_start_go<=1'b1; ops_st<=OPS_START;
                    end
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
    // Both are UPDATE ops (read-modify-write): 0x48 mask 0b01100000,
    // 0xBA mask 0b11100000. The remaining base-init steps (power-up, 0xD6,
    // 0x15/0x16, 0x17, disable_csc, 0xAF, GCP enable, audio, enable_video)
    // are explicit states below, in the EXACT order adv7511_xbox.c's
    // init_adv() calls them -- this is a straight port, not a redesign; the
    // only actual difference from X-HD is WHERE the encoder id comes from:
    // EOS samples the physical 1.6 strap for Xcalibur, otherwise starts from
    // Conexant and permits only a BIOS-confirmed transition to Focus.
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
            ENC_CONEXANT: enc_0xba_val = 8'b01100000;  // Conexant: 0ns
            ENC_FOCUS: enc_0xba_val = 8'b01000000;  // Focus: -0.4ns
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
            SA_VGA:       sa_hs_delay = 10'd120;
            SA_480P_4_3:  sa_hs_delay = xcal ? 10'd97  : 10'd119;
            SA_480P_16_9: sa_hs_delay = xcal ? 10'd97  : 10'd119;
            SA_720P:      sa_hs_delay = xcal ? 10'd260 : 10'd300;
            SA_1080I:     sa_hs_delay = xcal ? 10'd186 : 10'd234;
            default:      sa_hs_delay = 10'd120;
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
            SA_VGA, SA_480P_4_3: sa_h_active = 16'd640;
            SA_480P_16_9: sa_h_active = 16'd720;
            SA_720P:  sa_h_active = 16'd1280;
            SA_1080I: sa_h_active = 16'd1920;
            default:  sa_h_active = 16'd640;
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
    function sa_is_hd; input [2:0] mode; begin   // matches update_avi_infoframe's
                                                    // own is_hd = (vic==4||vic==5)
        sa_is_hd = (mode==SA_720P || mode==SA_1080I);
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
    // EOS HD-controller version bytes (READ_VERSION1-4) -- deliberately
    // DISTINCT from X-HD's own scheme (which starts {0,1,8,0}) so tools like
    // XbDiag can tell EOS-native HD apart from a real X-HD STM. VERSION1's
    // 0xE0 ("Eos") leading byte alone already guarantees no collision; 2-4
    // mirror the real firmware version for traceability.
    // =========================================================================
    localparam [7:0] HD_VER1 = 8'd69, HD_VER2 = 8'd1, HD_VER3 = 8'd0, HD_VER4 = 8'd3;

    // =========================================================================
    // SMBusSettings scratch/live storage (§5.3) -- 14 bytes: encoder(1),
    // region(1), mode(4), titleid(4), avinfo(4). bank/index addressing per
    // §5.1 is implemented faithfully (both are real registers, matching the
    // protocol), but only index[3:0] actually addresses the 14-entry array --
    // there is only ever one real config bank in practice (the Xbox BIOS
    // never uses more than one), so bank is tracked for protocol correctness
    // without a second dimension of real storage behind it.
    // =========================================================================
    reg [7:0] cfg_scratch [0:13];
    reg [7:0] cfg_live    [0:13];
    reg [7:0] cfg_bank, cfg_index;
    reg       cfg_pending;        // WRITE_CONFIG_APPLY seen, not yet reconfigured
    reg       bios_took_over;     // one-way latch, see §5.4 / §7.1

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

    // =========================================================================
    // SMBus command dispatch -- consumes eos_i2c.v's relay interface. Pure
    // command interpretation; the actual bus I/O for base-init/encoder-tweak/
    // (eventually) per-mode reconfig happens in the bring-up/apply FSM below,
    // triggered by cfg_pending.
    // =========================================================================
    localparam [7:0]
        CMD_READ_CONFIG   = 8'd0,
        CMD_READ_VERSION1 = 8'd1,
        CMD_READ_VERSION2 = 8'd2,
        CMD_READ_VERSION3 = 8'd3,
        CMD_READ_VERSION4 = 8'd4,
        CMD_READ_MODE     = 8'd5,
        CMD_WRITE_CONFIG        = 8'd128,
        CMD_WRITE_CONFIG_BANK   = 8'd129,
        CMD_WRITE_CONFIG_INDEX  = 8'd130,
        CMD_WRITE_CONFIG_APPLY  = 8'd131;

    reg [7:0] cur_cmd;
    reg       have_cmd;
    integer   cfg_copy_i;   // loop var for the scratch->live copy below --
                             // must be declared here, not inside a nested
                             // unnamed begin/end (iverilog accepts that,
                             // Gowin's synthesizer does not: EX3620)
    reg       cfg_ack;      // pulsed by the bring-up FSM (below) to request
                             // cfg_pending be cleared -- cfg_pending itself
                             // is owned EXCLUSIVELY by this always block
                             // (Gowin correctly rejects two procedural
                             // drivers for the same reg: EX2000/EX1999).
                             // The bring-up FSM used to write cfg_pending
                             // directly from its own always block; this
                             // request/ack pulse replaces that.

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            cur_cmd<=8'd0; have_cmd<=1'b0; cfg_bank<=8'd0; cfg_index<=8'd0;
            cfg_pending<=1'b0; bios_took_over<=1'b0;
            hd_read_data<=8'd0; hd_read_ready<=1'b1;
        end else begin
            // relay bytes only ever arrive while hd_addr_match is live; a
            // STOP (which eos_i2c.v surfaces by simply deasserting
            // hd_addr_match) ends the "current command" the same way
            // eos_i2c.v's own have_cmd model works for the updater persona.
            if (!hd_addr_match) have_cmd<=1'b0;

            // cfg_pending: set on a real WRITE_CONFIG_APPLY (below), cleared
            // on the bring-up FSM's ack -- ack takes priority if somehow
            // both land the same cycle, since a fresh apply arriving in the
            // exact cycle the FSM finishes the previous one should still be
            // seen (it'll just re-set next cycle from the case block below
            // in the extremely unlikely event both are true at once; ack
            // alone here just means "don't leave it stuck set with nothing
            // pending").
            if (cfg_ack) cfg_pending <= 1'b0;

            if (hd_byte_valid) begin
                if (hd_byte_first) begin
                    cur_cmd<=hd_byte; have_cmd<=1'b1;
                    // A read command's response must be ready essentially
                    // immediately (no ADV round-trip needed for any of
                    // READ_CONFIG/VERSION/MODE -- all pure local state), so
                    // hd_read_ready can just stay 1 throughout; no stretching
                    // needed for this command set.
                end else begin
                    // subsequent write-direction bytes, dispatched by cur_cmd
                    case (cur_cmd)
                        CMD_WRITE_CONFIG: begin
                            if ({cfg_bank,cfg_index} < 16'd14) begin
                                cfg_scratch[cfg_index[3:0]] <= hd_byte;
                                if (cfg_index == 8'hFF) begin
                                    cfg_index <= 8'd0;
                                    cfg_bank <= cfg_bank + 8'd1;
                                end else begin
                                    cfg_index <= cfg_index + 8'd1;
                                end
                            end
                        end
                        CMD_WRITE_CONFIG_BANK: begin
                            cfg_bank <= hd_byte;
                            cfg_index <= 8'd0;
                        end
                        CMD_WRITE_CONFIG_INDEX: cfg_index <= hd_byte;
                        CMD_WRITE_CONFIG_APPLY: begin
                            // The config packet is always accepted. That keeps
                            // Focus detection available even in standalone
                            // bring-up mode. Only BIOS ownership of the video
                            // mode path remains gated by FORCE_STANDALONE.
                            if (!FORCE_STANDALONE)
                                bios_took_over <= 1'b1;

                            if (hd_byte == 8'h01) begin
                                for (cfg_copy_i=0;cfg_copy_i<14;cfg_copy_i=cfg_copy_i+1)
                                    cfg_live[cfg_copy_i] <= cfg_scratch[cfg_copy_i];
                                cfg_pending <= 1'b1;
                            end
                        end
                        // WRITE_CONFIG_BANK also resets index to 0 per §5.1 --
                        // applied as a second effect of the same command byte,
                        // not a separate data byte (it's a single-byte command
                        // with no argument beyond the command itself in the
                        // real protocol... but keeping this here as a data-byte
                        // case is harmless/inert since the BIOS never sends a
                        // trailing byte for it in practice).
                        default: ;
                    endcase
                end
            end

            // WRITE_CONFIG_BANK's "index -> 0" effect: apply the instant the
            // command byte itself arrives (it's the command, not a following
            // data byte, that carries this meaning per §5.1).
            if (hd_byte_valid && hd_byte_first && hd_byte == CMD_WRITE_CONFIG_BANK) begin
                cfg_index <= 8'd0;
            end

            // ---- read-side response, always kept current (no stretching needed) ----
            // READ_CONFIG is latched when its command byte arrives so the
            // X-HD post-increment cannot advance the response before the
            // master's repeated-start read.
            case (cur_cmd)
                CMD_READ_CONFIG:   ; // held from the command-arrival block below
                CMD_READ_VERSION1: hd_read_data <= HD_VER1;
                CMD_READ_VERSION2: hd_read_data <= HD_VER2;
                CMD_READ_VERSION3: hd_read_data <= HD_VER3;
                CMD_READ_VERSION4: hd_read_data <= HD_VER4;
                CMD_READ_MODE:     hd_read_data <= 8'h02;   // Application -- also our own presence signature
                default:           hd_read_data <= 8'hFF;   // STM-reflash-path commands: ignored, per §5.2
            endcase

            // X-HD READ_CONFIG returns the byte at bank:index and then
            // post-increments the combined 16-bit offset.
            if (hd_byte_valid && hd_byte_first &&
                hd_byte == CMD_READ_CONFIG &&
                {cfg_bank,cfg_index} < 16'd14) begin
                hd_read_data <= cfg_live[cfg_index[3:0]];
                if (cfg_index == 8'hFF) begin
                    cfg_index <= 8'd0;
                    cfg_bank <= cfg_bank + 8'd1;
                end else begin
                    cfg_index <= cfg_index + 8'd1;
                end
            end

            // clear the one-shot pending flag once the apply/reconfigure FSM
            // below has picked it up (that FSM sets it back to 0)
        end
    end

    // =========================================================================
    // Bring-up + apply/reconfigure FSM.
    //
    // This is a STRAIGHT PORT of adv7511_xbox.c's init_adv() -- same calls,
    // same order, same register values. The ONLY difference from X-HD is
    // WHERE the boot encoder id comes from: X-HD uses a compile-time
    // -DBUILD_CONEXANT/FOCUS/XCALIBUR constant. EOS uses the physical 1.6
    // strap for Xcalibur and the validated Conexant profile otherwise; only a
    // later BIOS 0xD4 report can move that pre-1.6 path to Focus. Every other
    // register write,
    // in every other state below, matches source exactly:
    //
    //   write 0xD6=0b11010000            (HPD/TMDS/gating, full write, FIRST)
    //   power_up: 0x41=0x10/delay/0x00/delay/0x10/delay (30/30/50ms)
    //   disable_video: update 0xD6 mask=0x01 val=0x01
    //   write 0x15=0b00100101            (input format)
    //   write 0x16=0b00111011            (output format)
    //   encoder tweak: update 0x48, update 0xBA, update 0xD0  <- selected here
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
        BR_XHD_IRQ_HANDLER   = 6'd1,  // physical-INT-gated adv_handle_interrupts()

        // Encoder report decision state. It runs only after a complete
        // X-HD settings packet has been committed to cfg_live.
        BR_ENCODER_REPORT    = 6'd2,
        BR_BIOS_APPLY        = 6'd3,  // detailed state is in bios_st below
        // 4..5 remain reserved for future diagnostics.

        // Transport failure decode states. The HUD prints ST in hexadecimal.
        BR_TRANSPORT_TIMEOUT    = 6'h06,
        BR_TRANSPORT_NACK       = 6'h07,

        BR_ADV_PROBE_GO         = 6'd8,
        BR_ADV_PROBE_WT      = 6'd9,
        BR_ADV_ABSENT        = 6'd10,  // terminal -- no ADV7511 present, stay off forever

        // ---- init_adv(), exact source order from here down ----
        BR_INIT_HPD_FULL     = 6'd11,  // write 0xD6=0b11010000 (FIRST real init write)
        BR_POWERUP_A         = 6'd12,
        BR_POWERUP_A_WAIT    = 6'd13,
        BR_POWERUP_A_DELAY   = 6'd14,
        BR_POWERUP_B_WAIT    = 6'd15,
        BR_POWERUP_B_DELAY   = 6'd16,
        BR_POWERUP_C_WAIT    = 6'd17,
        BR_POWERUP_C_DELAY   = 6'd18,
        BR_DISABLE_VIDEO     = 6'd19,  // update 0xD6 mask=1 val=1 (disable_video)
        BR_WRITE_15          = 6'd20,  // write 0x15
        BR_WRITE_16          = 6'd21,  // write 0x16
        BR_ENC_TWEAK_GO      = 6'd22,  // shared: initial pass (enc_apply_id=boot-selected) AND
        BR_ENC_TWEAK_WT      = 6'd23,  //         later Focus transition (enc_apply_id=Focus)
        BR_DE_GEN            = 6'd24,  // update 0x17 mask=1 val=1
        BR_DISABLE_CSC       = 6'd25,  // update 0x18 mask=0x80 val=0
        BR_WRITE_AF          = 6'd26,  // write 0xAF
        BR_GCP_ENABLE        = 6'd27,  // update 0x40 mask=0x80 val=0x80
        BR_AUDIO_01          = 6'd28,  // write 0x01=0x00
        BR_AUDIO_02          = 6'd29,  // write 0x02=0x18
        BR_AUDIO_03          = 6'd30,  // write 0x03=0x00
        BR_SPDIF_SRC         = 6'd31,  // update 0x0A mask=0x70 val=0x10
        BR_SPDIF_ENABLE      = 6'd32,  // update 0x0B mask=0x80 val=0x80
        BR_ENABLE_VIDEO      = 6'd33,  // update 0xD6 mask=1 val=0 (enable_video) -- last init step

        BR_READY             = 6'd34,  // 0x22: normal X-HD main-loop state

        // ---- retry/failure handling, per eos_hd_integration_spec.md's
        // hardening requirements -- see the header comment block above each
        // usage site below for the exact behavior at each one. ----
        // Reuse the retired 35..37 slots for semantic readback failures.
        BR_TRANSPORT_D6_BAD          = 6'h23,
        BR_TRANSPORT_15_BAD          = 6'h24,
        BR_TRANSPORT_INTERNAL        = 6'h25,

        BR_ADV_PROBE_RETRY_DLY       = 6'd38,
        BR_INIT_FAILED               = 6'd39,  // any init-sequence op NACKed/timed out
        BR_INIT_RETRY_DLY            = 6'd40,
        BR_HD_DISABLED               = 6'd41,  // terminal -- gave up after
                                                 // exhausting retries somewhere;
                                                 // EOS itself is unaffected,
                                                 // this module just goes inert

        // ---- standalone (pre-BIOS) mode applicator, §3-4 of the plan doc --
        // triggered from BR_READY when the polled input VIC changes; runs to
        // completion as one atomic sequence (even if bios_took_over latches
        // mid-sequence -- "allow any active ADV transaction to finish" per
        // §6), then returns to BR_READY. ----
        BR_STANDALONE_CSC_DISABLE = 6'd42,
        BR_STANDALONE_WR_35       = 6'd43,
        BR_STANDALONE_WR_36       = 6'd44,
        BR_STANDALONE_WR_37       = 6'd45,
        BR_STANDALONE_WR_38       = 6'd46,
        BR_STANDALONE_WR_39       = 6'd47,
        BR_STANDALONE_WR_3A       = 6'd48,
        BR_STANDALONE_WR_DC       = 6'd49,
        BR_STANDALONE_D0_UPDATE   = 6'd50,
        BR_STANDALONE_WR_VIC_3C   = 6'd51,
        BR_STANDALONE_AVI_START   = 6'd52,
        BR_STANDALONE_WR_55       = 6'd53,
        BR_STANDALONE_WR_56       = 6'd54,
        BR_STANDALONE_WR_57       = 6'd55,
        BR_STANDALONE_WR_58       = 6'd56,
        BR_STANDALONE_WR_59       = 6'd57,
        BR_STANDALONE_AVI_END     = 6'd58,


        // exact standalone sync-mode update from X-HD's
        // set_video_mode_vic(): 0x41[1] set for 1080i, cleared otherwise
        BR_STANDALONE_SYNC_MODE    = 6'd60,
        BR_STANDALONE_INTERLACE_37 = 6'd61,

        // X-HD stand_alone_loop() performs a second 0x3E read after
        // detecting a change, then commits encoder->vic.
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
        BIOS_TMDS_UP_WR_WAIT  = 6'd35,
        BIOS_RECOVER_RD       = 6'd36,
        BIOS_RECOVER_RD_WAIT  = 6'd37,
        BIOS_RECOVER_WR_WAIT  = 6'd38;

    reg [5:0]  bios_st;
    reg [4:0]  bios_csc_idx;
    reg [31:0] bios_current_mode;
    reg [31:0] bios_current_avinfo;
    reg [31:0] bios_pending_mode;
    reg [31:0] bios_pending_avinfo;
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
    reg        bios_sync_adjust;
    reg        bios_rgb;
    reg        bios_use_709;
    reg        bios_ws_infoframe;
    // True for every state that's part of init_adv() (BR_INIT_HPD_FULL
    // through BR_ENABLE_VIDEO, inclusive) -- used by the single, centralized
    // failure check below rather than adding a per-state NACK/timeout check
    // to all ~20 of those states individually. One point of control for a
    // cross-cutting concern, not duplicated logic.
    wire in_transport_verify = 1'b0;
    wire in_init_seq =
        (br_st >= BR_INIT_HPD_FULL) && (br_st <= BR_ENABLE_VIDEO);
    // Standalone applicator failures get a DELIBERATELY lighter response
    // than in_init_seq's: this runs continuously during normal operation
    // (not a one-time boot gate), so a transient bus hiccup mid-apply
    // aborts back to BR_READY and clears standalone_mode_valid (so the next
    // poll cycle retries naturally) rather than disabling the whole HD
    // subsystem the way a boot-time init failure does. Judgment call, not
    // explicitly specified in the plan doc -- documented here since it's a
    // real design decision, not an obvious default.
    wire in_standalone_apply =
        ((br_st >= BR_STANDALONE_CSC_DISABLE) &&
         (br_st <= BR_STANDALONE_INTERLACE_37)) ||
        (br_st == BR_XHD_MODE_FINISH);
    wire in_bios_apply_main =
        (br_st == BR_BIOS_APPLY) && (bios_st < BIOS_RECOVER_RD);
    reg [1:0]  boot_encoder_id;    // sampled once in BR_RESET from xbox_16_mode
    reg        boot_xcalibur;      // latched physical branch; never changes this boot
    reg        focus_detected;     // one-way pre-1.6 Conexant -> Focus transition
    reg        encoder_report_invalid;
    reg        encoder_report_mismatch;
    reg [1:0]  enc_apply_id;       // branch currently being applied by shared
                                    // 0x48/0xBA/0xD0 states
    reg [1:0]  last_encoder_id;    // branch successfully programmed into ADV
    reg [5:0]  enc_tweak_return_st;   // where BR_ENC_TWEAK_WT goes once done --
                                        // BR_DE_GEN for the initial pass,
                                        // BR_READY for the one-way Focus transition
    reg [23:0] delay_ctr;         // generous, covers the 30/30/50ms power-up delays;
                                    // also reused for the short inter-retry
                                    // delays below (never overlaps in time
                                    // with the power-up sequence's own use)
    reg [1:0]  adv_probe_retry_cnt;
    reg        init_retry_used;       // the WHOLE init_adv() sequence gets
                                        // exactly one retry from scratch;
                                        // this is that one-shot flag
    // BR_HD_DISABLED is reachable from the ADV-absent and init-failed-twice
    // paths; disable_reason records WHICH one so the HUD can answer "why did
    // it give up" instead of guessing. 0 = not disabled / reset value.
    // (DR_ENC_CNXT/DR_ENC_FOCUS/DR_GUARD/DR_ENC_NOT_FOUND kept in the enum for
    //  HUD-decode stability, but no longer assigned -- probe/guard are gone.)
    localparam [2:0] DR_NONE=3'd0, DR_ENC_CNXT=3'd1, DR_ENC_FOCUS=3'd2,
                      DR_GUARD=3'd3, DR_INIT=3'd4, DR_ENC_NOT_FOUND=3'd5;
    reg [2:0]  disable_reason;

    // =========================================================================
    // X-HD BIOS-owned mode tables and helpers.
    //
    // EOS keeps its own encoder-selection mechanism: the physical 1.6 strap
    // selects Xcalibur, pre-1.6 starts Conexant, and only a BIOS-confirmed 0xD4
    // report may transition that path to Focus. Once selected, the rows below
    // are the exact 18-entry X-HD tables from xbox_video_bios.h.
    //
    // Packed row layout:
    //   [160]     valid
    //   [159:144] hs_delay
    //   [143:128] vs_delay
    //   [127:112] h_active
    //   [111:96]  v_active
    //   [95:80]   hsync_placement
    //   [79:64]   hsync_duration
    //   [63:48]   vsync_placement
    //   [47:32]   vsync_duration
    //   [31:16]   interlaced_offset
    //   [15:0]    sync_adjust_enabled
    // =========================================================================
    function [160:0] bios_mode_row;
        input [1:0] enc;
        input [4:0] idx;
        begin
            case ({enc,idx})
            {ENC_CONEXANT,5'd1}: bios_mode_row = {1'b1, 16'd123, 16'd34, 16'd640, 16'd480, 16'd13, 16'd32, 16'd10, 16'd3, 16'd0, 16'd1};
            {ENC_CONEXANT,5'd2}: bios_mode_row = {1'b1, 16'd135, 16'd34, 16'd720, 16'd480, 16'd15, 16'd32, 16'd10, 16'd3, 16'd0, 16'd1};
            {ENC_CONEXANT,5'd3}: bios_mode_row = {1'b1, 16'd255, 16'd36, 16'd640, 16'd480, 16'd55, 16'd32, 16'd8, 16'd3, 16'd0, 16'd1};
            {ENC_CONEXANT,5'd4}: bios_mode_row = {1'b1, 16'd271, 16'd36, 16'd720, 16'd480, 16'd59, 16'd32, 16'd8, 16'd3, 16'd0, 16'd1};
            {ENC_CONEXANT,5'd5}: bios_mode_row = {1'b1, 16'd133, 16'd39, 16'd640, 16'd576, 16'd15, 16'd32, 16'd9, 16'd3, 16'd0, 16'd1};
            {ENC_CONEXANT,5'd6}: bios_mode_row = {1'b1, 16'd149, 16'd39, 16'd720, 16'd576, 16'd17, 16'd33, 16'd9, 16'd3, 16'd0, 16'd1};
            {ENC_CONEXANT,5'd7}: bios_mode_row = {1'b1, 16'd120, 16'd36, 16'd720, 16'd480, 16'd17, 16'd63, 16'd8, 16'd6, 16'd0, 16'd1};
            {ENC_CONEXANT,5'd8}: bios_mode_row = {1'b1, 16'd120, 16'd36, 16'd720, 16'd480, 16'd17, 16'd63, 16'd8, 16'd6, 16'd0, 16'd1};
            {ENC_CONEXANT,5'd9}: bios_mode_row = {1'b1, 16'd301, 16'd25, 16'd960, 16'd720, 16'd69, 16'd80, 16'd4, 16'd5, 16'd0, 16'd1};
            {ENC_CONEXANT,5'd10}: bios_mode_row = {1'b1, 16'd300, 16'd25, 16'd1280, 16'd720, 16'd69, 16'd80, 16'd4, 16'd5, 16'd0, 16'd1};
            {ENC_CONEXANT,5'd11}: bios_mode_row = {1'b1, 16'd300, 16'd25, 16'd1280, 16'd720, 16'd69, 16'd80, 16'd4, 16'd5, 16'd0, 16'd1};
            {ENC_CONEXANT,5'd12}: bios_mode_row = {1'b1, 16'd237, 16'd40, 16'd1440, 16'd1080, 16'd43, 16'd88, 16'd4, 16'd10, 16'd0, 16'd1};
            {ENC_CONEXANT,5'd13}: bios_mode_row = {1'b1, 16'd237, 16'd40, 16'd1920, 16'd1080, 16'd43, 16'd88, 16'd4, 16'd10, 16'd0, 16'd1};
            {ENC_CONEXANT,5'd14}: bios_mode_row = {1'b1, 16'd236, 16'd41, 16'd1920, 16'd1080, 16'd44, 16'd88, 16'd3, 16'd10, 16'd0, 16'd1};
            {ENC_CONEXANT,5'd15}: bios_mode_row = {1'b1, 16'd166, 16'd34, 16'd640, 16'd480, 16'd48, 16'd32, 16'd10, 16'd3, 16'd0, 16'd1};
            {ENC_CONEXANT,5'd16}: bios_mode_row = {1'b1, 16'd319, 16'd34, 16'd640, 16'd480, 16'd91, 16'd32, 16'd10, 16'd3, 16'd0, 16'd1};
            {ENC_CONEXANT,5'd17}: bios_mode_row = {1'b1, 16'd121, 16'd36, 16'd720, 16'd480, 16'd17, 16'd63, 16'd8, 16'd6, 16'd0, 16'd1};
            {ENC_CONEXANT,5'd18}: bios_mode_row = {1'b1, 16'd180, 16'd39, 16'd640, 16'd576, 16'd48, 16'd32, 16'd9, 16'd3, 16'd0, 16'd1};
            {ENC_FOCUS,5'd1}: bios_mode_row = {1'b1, 16'd180, 16'd26, 16'd640, 16'd480, 16'd115, 16'd64, 16'd18, 16'd2, 16'd0, 16'd1};
            {ENC_FOCUS,5'd2}: bios_mode_row = {1'b1, 16'd140, 16'd26, 16'd720, 16'd480, 16'd75, 16'd64, 16'd18, 16'd2, 16'd0, 16'd1};
            {ENC_FOCUS,5'd3}: bios_mode_row = {1'b1, 16'd144, 16'd24, 16'd640, 16'd480, 16'd79, 16'd64, 16'd20, 16'd2, 16'd0, 16'd1};
            {ENC_FOCUS,5'd4}: bios_mode_row = {1'b1, 16'd104, 16'd24, 16'd720, 16'd480, 16'd59, 16'd64, 16'd20, 16'd2, 16'd0, 16'd1};
            {ENC_FOCUS,5'd5}: bios_mode_row = {1'b1, 16'd144, 16'd26, 16'd640, 16'd576, 16'd79, 16'd64, 16'd22, 16'd2, 16'd0, 16'd1};
            {ENC_FOCUS,5'd6}: bios_mode_row = {1'b1, 16'd104, 16'd26, 16'd720, 16'd576, 16'd59, 16'd64, 16'd22, 16'd2, 16'd0, 16'd1};
            {ENC_FOCUS,5'd7}: bios_mode_row = {1'b1, 16'd120, 16'd38, 16'd720, 16'd480, 16'd17, 16'd63, 16'd8, 16'd6, 16'd0, 16'd1};
            {ENC_FOCUS,5'd8}: bios_mode_row = {1'b1, 16'd120, 16'd38, 16'd720, 16'd480, 16'd17, 16'd63, 16'd8, 16'd6, 16'd0, 16'd1};
            {ENC_FOCUS,5'd9}: bios_mode_row = {1'b1, 16'd300, 16'd25, 16'd960, 16'd720, 16'd69, 16'd80, 16'd4, 16'd5, 16'd0, 16'd1};
            {ENC_FOCUS,5'd10}: bios_mode_row = {1'b1, 16'd300, 16'd25, 16'd1280, 16'd720, 16'd69, 16'd80, 16'd4, 16'd5, 16'd0, 16'd1};
            {ENC_FOCUS,5'd11}: bios_mode_row = {1'b1, 16'd300, 16'd27, 16'd1280, 16'd720, 16'd69, 16'd80, 16'd4, 16'd5, 16'd0, 16'd1};
            {ENC_FOCUS,5'd12}: bios_mode_row = {1'b1, 16'd237, 16'd40, 16'd1440, 16'd1080, 16'd43, 16'd88, 16'd4, 16'd10, 16'd0, 16'd1};
            {ENC_FOCUS,5'd13}: bios_mode_row = {1'b1, 16'd237, 16'd40, 16'd1920, 16'd1080, 16'd43, 16'd88, 16'd4, 16'd10, 16'd0, 16'd1};
            {ENC_FOCUS,5'd14}: bios_mode_row = {1'b1, 16'd236, 16'd41, 16'd1920, 16'd1080, 16'd44, 16'd88, 16'd3, 16'd10, 16'd0, 16'd1};
            {ENC_FOCUS,5'd15}: bios_mode_row = {1'b1, 16'd180, 16'd26, 16'd640, 16'd480, 16'd115, 16'd64, 16'd18, 16'd2, 16'd0, 16'd1};
            {ENC_FOCUS,5'd16}: bios_mode_row = {1'b1, 16'd144, 16'd24, 16'd640, 16'd480, 16'd79, 16'd64, 16'd20, 16'd2, 16'd0, 16'd1};
            {ENC_FOCUS,5'd17}: bios_mode_row = {1'b1, 16'd120, 16'd36, 16'd720, 16'd480, 16'd17, 16'd63, 16'd8, 16'd6, 16'd0, 16'd1};
            {ENC_FOCUS,5'd18}: bios_mode_row = {1'b1, 16'd144, 16'd26, 16'd640, 16'd576, 16'd79, 16'd64, 16'd22, 16'd2, 16'd0, 16'd1};
            {ENC_XCALIBUR,5'd1}: bios_mode_row = {1'b1, 16'd96, 16'd37, 16'd640, 16'd480, 16'd43, 16'd2, 16'd7, 16'd2, 16'd0, 16'd1};
            {ENC_XCALIBUR,5'd2}: bios_mode_row = {1'b1, 16'd96, 16'd37, 16'd720, 16'd480, 16'd41, 16'd6, 16'd7, 16'd6, 16'd0, 16'd1};
            {ENC_XCALIBUR,5'd3}: bios_mode_row = {1'b1, 16'd96, 16'd38, 16'd640, 16'd480, 16'd63, 16'd24, 16'd1, 16'd10, 16'd0, 16'd1};
            {ENC_XCALIBUR,5'd4}: bios_mode_row = {1'b1, 16'd138, 16'd38, 16'd720, 16'd480, 16'd41, 16'd50, 16'd1, 16'd10, 16'd0, 16'd1};
            {ENC_XCALIBUR,5'd5}: bios_mode_row = {1'b1, 16'd143, 16'd41, 16'd640, 16'd576, 16'd127, 16'd47, 16'd6, 16'd6, 16'd0, 16'd1};
            {ENC_XCALIBUR,5'd6}: bios_mode_row = {1'b1, 16'd138, 16'd42, 16'd720, 16'd576, 16'd5, 16'd45, 16'd6, 16'd6, 16'd0, 16'd1};
            {ENC_XCALIBUR,5'd7}: bios_mode_row = {1'b1, 16'd96, 16'd36, 16'd640, 16'd480, 16'd43, 16'd2, 16'd8, 16'd5, 16'd0, 16'd1};
            {ENC_XCALIBUR,5'd8}: bios_mode_row = {1'b1, 16'd96, 16'd36, 16'd720, 16'd480, 16'd41, 16'd6, 16'd8, 16'd5, 16'd0, 16'd1};
            {ENC_XCALIBUR,5'd9}: bios_mode_row = {1'b1, 16'd301, 16'd25, 16'd960, 16'd720, 16'd69, 16'd80, 16'd4, 16'd5, 16'd0, 16'd1};
            {ENC_XCALIBUR,5'd10}: bios_mode_row = {1'b1, 16'd260, 16'd25, 16'd1280, 16'd720, 16'd110, 16'd40, 16'd5, 16'd5, 16'd0, 16'd1};
            {ENC_XCALIBUR,5'd11}: bios_mode_row = {1'b1, 16'd260, 16'd25, 16'd1280, 16'd720, 16'd110, 16'd40, 16'd5, 16'd5, 16'd0, 16'd1};
            {ENC_XCALIBUR,5'd12}: bios_mode_row = {1'b1, 16'd237, 16'd40, 16'd1440, 16'd1080, 16'd43, 16'd88, 16'd4, 16'd10, 16'd0, 16'd1};
            {ENC_XCALIBUR,5'd13}: bios_mode_row = {1'b1, 16'd237, 16'd40, 16'd1920, 16'd1080, 16'd43, 16'd88, 16'd4, 16'd10, 16'd0, 16'd1};
            {ENC_XCALIBUR,5'd14}: bios_mode_row = {1'b1, 16'd188, 16'd41, 16'd1920, 16'd1080, 16'd92, 16'd40, 16'd3, 16'd10, 16'd0, 16'd1};
            {ENC_XCALIBUR,5'd15}: bios_mode_row = {1'b1, 16'd137, 16'd37, 16'd640, 16'd480, 16'd81, 16'd1, 16'd7, 16'd6, 16'd0, 16'd1};
            {ENC_XCALIBUR,5'd16}: bios_mode_row = {1'b1, 16'd178, 16'd38, 16'd640, 16'd480, 16'd81, 16'd42, 16'd1, 16'd10, 16'd0, 16'd1};
            {ENC_XCALIBUR,5'd17}: bios_mode_row = {1'b1, 16'd95, 16'd36, 16'd720, 16'd480, 16'd41, 16'd6, 16'd8, 16'd5, 16'd0, 16'd1};
            {ENC_XCALIBUR,5'd18}: bios_mode_row = {1'b1, 16'd143, 16'd41, 16'd640, 16'd576, 16'd87, 16'd7, 16'd6, 16'd6, 16'd0, 16'd1};
                default: bios_mode_row = 161'd0;
            endcase
        end
    endfunction

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

    wire [160:0] bios_row_wire =
        bios_mode_row(last_encoder_id, live_mode_index[4:0]);
    wire         bios_row_valid = bios_row_wire[160] &&
                                  (live_mode_index >= 8'd1) &&
                                  (live_mode_index <= 8'd18);
    wire [15:0]  bios_row_hs_delay = bios_row_wire[159:144];
    wire [15:0]  bios_row_vs_delay = bios_row_wire[143:128];
    wire [15:0]  bios_row_h_active = bios_row_wire[127:112];
    wire [15:0]  bios_row_v_active = bios_row_wire[111:96];
    wire [15:0]  bios_row_hsync_placement = bios_row_wire[95:80];
    wire [15:0]  bios_row_hsync_duration  = bios_row_wire[79:64];
    wire [15:0]  bios_row_vsync_placement = bios_row_wire[63:48];
    wire [15:0]  bios_row_vsync_duration  = bios_row_wire[47:32];
    wire [2:0]   bios_row_interlaced_offset = bios_row_wire[18:16];
    wire         bios_row_sync_adjust = bios_row_wire[0];

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
    localparam MAX_ADV_PROBE_RETRIES = 2'd3;   // "two or three times" -- picked
                                                 // the more thorough end
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
    localparam [24:0] PLL_POLL_RELOAD        = 25'd16_199_999; // ~250 ms
    localparam [24:0] STANDALONE_POLL_RELOAD = 25'd6_479_999;  // ~100 ms
    reg [24:0] pll_poll_ctr;
    reg [24:0] standalone_poll_ctr;
    reg        standalone_mode_valid;  // 0 until a complete mode apply finishes
    reg [2:0]  standalone_cur_mode;    // last successfully applied mode
    reg [2:0]  standalone_target_mode; // mode currently being applied
    reg [5:0]  xhd_encoder_vic;        // adv7511_struct_init(): encoder->vic=0
    // latched row values for the mode currently being applied -- computed
    // once when a change is detected, held stable through the whole
    // applicator sequence
    reg [9:0]  sa_hs_latched;
    reg [7:0]  sa_vs_latched;
    reg [15:0] sa_h_latched, sa_v_latched;
    reg [5:0]  sa_vic_latched;
    reg        sa_ws_latched, sa_hd_latched;
    reg [9:0]  sa_delay_hs;   // = sa_hs_latched - 1, computed once entering the applicator

    // X-HD runtime state. ADV INT is routed to FPGA pin 49 and converted
    // into the same sticky software event that X-HD's EXTI ISR creates.
    reg        xhd_hpd;
    reg        xhd_monitor_sense;
    reg        adv_irq_pending;
    reg [7:0]  xhd_irq_flags;
    reg [3:0]  xhd_irq_phase;
    reg [5:0]  xhd_detected_vic;
    reg [4:0]  xhd_sent_vic;
    reg [1:0]  xhd_pixel_repeat;
    reg [1:0]  mode_finish_phase;
    reg        mode_applied_ok;
    reg        bringup_i2c_error;

    // Raw transport evidence. These are latched only from successful
    // register reads, allowing the HUD to show the complete byte rather than
    // interpreting selected bits from a potentially released SDA line.
    reg [7:0]  diag_d6_raw;
    reg [7:0]  diag_15_raw;
    reg [7:0]  diag_42_raw;
    reg [7:0]  diag_3e_raw;
    reg [7:0]  diag_3d_raw;
    reg [7:0]  diag_9e_raw;
    reg        transport_verified;
    reg [2:0]  transport_error_code;

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

    // Encoder-branch HUD. With first picture established, ENC now reports
    // the branch actually programmed into the ADV: 0=Conexant, 1=Focus,
    // 2=Xcalibur. RS reports the detected input VIC low bits in standalone.
    assign hd_encoder_out        = {2'b0,last_encoder_id};
    assign hd_brst_out           = br_st;
    assign hd_disable_reason_out = FORCE_STANDALONE
                                 ? xhd_detected_vic[2:0]
                                 : disable_reason;
    assign hd_pll_lock_out       = pll_lock_r;
    assign hd_bios_active_out    = FORCE_STANDALONE
                                 ? mode_applied_ok
                                 : bios_took_over;
    assign hd_guard_blocked_out  = xhd_hpd && xhd_monitor_sense;

    // Expansion TARGET must be based on stable physical ADV presence, not
    // hd_addr_en. hd_addr_en intentionally stays low until the full ADV init
    // completes and is therefore a transient runtime signal that can reject a
    // valid TARGET HD script during boot. These latches become valid as soon
    // as the presence probe resolves and remain stable for the rest of boot.
    reg adv_presence_known_r;
    reg adv_present_r;
    assign hd_target_known = adv_presence_known_r;
    assign hd_target_hd    = adv_present_r;

    // ADV INT crosses into clk_sd asynchronously. X-HD uses both-edge EXTI,
    // so detect either synchronized transition. The arming pipeline prevents
    // reset release from manufacturing a fake edge solely because the idle
    // pin level happens to be high.
    reg       adv_int_meta;
    reg       adv_int_sync;
    reg       adv_int_prev;
    reg [1:0] adv_int_arm;

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            adv_int_meta<=1'b0;
            adv_int_sync<=1'b0;
            adv_int_prev<=1'b0;
            adv_int_arm<=2'b00;
        end else begin
            adv_int_meta<=adv_int;
            adv_int_sync<=adv_int_meta;
            adv_int_arm<={adv_int_arm[0],1'b1};
            adv_int_prev<=adv_int_sync;
        end
    end

    wire adv_int_edge = adv_int_arm[1] &&
                        (adv_int_sync != adv_int_prev);

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            br_st<=BR_RESET; hd_addr_en<=1'b0; op_go<=1'b0; op_kind<=OP_NONE;
            adv_presence_known_r<=1'b0; adv_present_r<=1'b0;
            op_target_addr<=7'd0; adv_waddr<=8'd0; adv_wdata<=8'd0;
            delay_ctr<=24'd0;
            boot_encoder_id<=ENC_CONEXANT;
            boot_xcalibur<=1'b0;
            focus_detected<=1'b0;
            encoder_report_invalid<=1'b0;
            encoder_report_mismatch<=1'b0;
            enc_apply_id<=ENC_CONEXANT;
            last_encoder_id<=ENC_CONEXANT;
            enc_tweak_return_st<=6'd0;
            adv_probe_retry_cnt<=2'd0;
            init_retry_used<=1'b0; disable_reason<=DR_NONE;
            led_green<=1'b0; led_blue<=1'b0; pll_lock_r<=1'b0;
            pll_poll_ctr<=PLL_POLL_RELOAD; standalone_poll_ctr<=25'd0;
            standalone_mode_valid<=1'b0; standalone_cur_mode<=SA_480P_4_3;
            standalone_target_mode<=SA_480P_4_3; xhd_encoder_vic<=6'd0;
            xhd_hpd<=1'b0; xhd_monitor_sense<=1'b0;
            adv_irq_pending<=1'b0;
            xhd_irq_flags<=8'd0; xhd_irq_phase<=IRQ_WAIT_FLAGS;
            xhd_detected_vic<=6'd0; xhd_sent_vic<=5'd0;
            xhd_pixel_repeat<=2'd0; mode_finish_phase<=2'd0;
            mode_applied_ok<=1'b0; bringup_i2c_error<=1'b0;
            diag_d6_raw<=8'h00; diag_15_raw<=8'h00;
            diag_42_raw<=8'h00; diag_3e_raw<=8'h00;
            diag_3d_raw<=8'h00; diag_9e_raw<=8'h00;
            transport_verified<=1'b0;
            transport_error_code<=3'd0;
            bios_st<=BIOS_IDLE; bios_csc_idx<=5'd0;
            bios_current_mode<=32'd0; bios_current_avinfo<=32'd0;
            bios_pending_mode<=32'd0; bios_pending_avinfo<=32'd0;
            bios_adv_delay_hs<=16'd0; bios_vs_delay<=16'd0;
            bios_h_active<=16'd0; bios_v_active<=16'd0;
            bios_hsync_placement<=16'd0; bios_hsync_duration<=16'd0;
            bios_vsync_placement<=16'd0; bios_vsync_duration<=16'd0;
            bios_interlaced_offset<=3'd0; bios_vic<=6'd0;
            bios_sync_adjust<=1'b0;
            bios_rgb<=1'b0; bios_use_709<=1'b0;
            bios_ws_infoframe<=1'b0;
            cfg_ack<=1'b0;
        end else begin
            op_go<=1'b0;
            cfg_ack<=1'b0;   // pulse -- see the explicit sets below

            // Exact software equivalent of X-HD's ADV_IRQ_HANDLER():
            // encoder.interrupt = 1. The event stays pending until the main
            // loop consumes it after the PLL read.
            if (adv_int_edge)
                adv_irq_pending<=1'b1;

            // ---- LED, always kept current from live status (§7.1) ----
            led_green <= pll_lock_r;
            led_blue  <= FORCE_STANDALONE ? mode_applied_ok : bios_took_over;

            // The private ADV bus follows X-HD's source-order loop directly:
            // PLL -> interrupt handler -> standalone VIC or BIOS table engine.
            // No shared-bus pacing is required on the dedicated ADV bus.

            // ---- source-call transport behavior ----
            // X-HD's ADV helpers are synchronous HAL calls. EOS snapshots
            // each call and retries transient delivery failures before
            // returning op_done to this source-order FSM.

            // X-HD's C helpers ignore HAL return values, but EOS must not
            // silently consume a released-bus byte and continue through every
            // read-modify-write. Fail closed during verification/init and
            // abort a runtime mode apply so it can retry from BR_READY.
            if (op_done && (op_nack || op_timeout) &&
                in_transport_verify) begin
                bringup_i2c_error<=1'b1;
                if (op_timeout) begin
                    transport_error_code<=3'd1;
                    br_st<=BR_TRANSPORT_TIMEOUT;
                end else begin
                    transport_error_code<=3'd2;
                    br_st<=BR_TRANSPORT_NACK;
                end
            end else if (op_done && (op_nack || op_timeout) &&
                         in_init_seq) begin
                bringup_i2c_error<=1'b1;
                transport_error_code<=op_timeout ? 3'd3 : 3'd4;
                br_st<=BR_INIT_FAILED;
            end else if (op_done && (op_nack || op_timeout) &&
                         in_standalone_apply) begin
                bringup_i2c_error<=1'b1;
                mode_applied_ok<=1'b0;
                standalone_mode_valid<=1'b0;
                op_kind<=OP_READ; op_target_addr<=ADV_ADDR;
                adv_waddr<=8'h9E; op_go<=1'b1;
                br_st<=BR_READY;
            end else if (op_done && (op_nack || op_timeout) &&
                         in_bios_apply_main) begin
                // Do not let a failed read feed stale data into the next
                // BIOS read-modify-write. Attempt to restore TMDS, then
                // acknowledge this update and retain the last known-good mode.
                bringup_i2c_error<=1'b1;
                mode_applied_ok<=1'b0;
                bios_st<=BIOS_RECOVER_RD;
            end else begin
            case (br_st)
                BR_RESET: begin
                    // X-HD order:
                    //   init_gpio/EXTI
                    //   adv7511_i2c_init()
                    //   adv7511_struct_init()
                    //   init_adv(..., boot-selected encoder)
                    //
                    // The FPGA pin and private I2C block are already present,
                    // so this state performs the exact struct initialization
                    // immediately before the first D6 write. Clearing the
                    // interrupt HERE is important: X-HD does not carry an HPD
                    // edge captured long before init_adv() into its first loop.
                    delay_ctr<=24'd0;

                    // The switch is stable before boot. Sample it here, once,
                    // before the first ADV encoder-specific write. No runtime
                    // monitoring or Xcalibur detection path exists.
                    boot_xcalibur<=xbox_16_mode;
                    boot_encoder_id<=xbox_16_mode ? ENC_XCALIBUR
                                                  : ENC_CONEXANT;
                    enc_apply_id<=xbox_16_mode ? ENC_XCALIBUR
                                               : ENC_CONEXANT;
                    last_encoder_id<=ENC_CONEXANT;
                    focus_detected<=1'b0;
                    encoder_report_invalid<=1'b0;
                    encoder_report_mismatch<=1'b0;
                    hd_addr_en<=1'b0;

                    xhd_hpd<=1'b0;
                    xhd_monitor_sense<=1'b0;
                    adv_irq_pending<=1'b0;
                    xhd_encoder_vic<=6'd0;
                    xhd_detected_vic<=6'd0;
                    xhd_irq_flags<=8'd0;
                    xhd_irq_phase<=IRQ_WAIT_FLAGS;
                    standalone_mode_valid<=1'b0;
                    mode_applied_ok<=1'b0;
                    bringup_i2c_error<=1'b0;
                    transport_verified<=1'b0;
                    transport_error_code<=3'd0;
                    diag_d6_raw<=8'h00;
                    diag_15_raw<=8'h00;
                    diag_42_raw<=8'h00;
                    diag_3e_raw<=8'h00;
                    diag_3d_raw<=8'h00;
                    diag_9e_raw<=8'h00;

                    br_st<=BR_INIT_HPD_FULL;
                end

                // Terminal transport failures. ST 23 now specifically means
                // the natural post-power disable_video() D6 read returned FF.
                BR_TRANSPORT_TIMEOUT,
                BR_TRANSPORT_NACK,
                BR_TRANSPORT_D6_BAD,
                BR_TRANSPORT_15_BAD,
                BR_TRANSPORT_INTERNAL: begin
                    hd_addr_en<=1'b0;
                    pll_lock_r<=1'b0;
                    mode_applied_ok<=1'b0;
                end

                // ---- ADV7511 presence check: does anything ACK at 0x72? ----
                BR_ADV_PROBE_GO: begin
                    op_kind<=OP_PROBE; op_target_addr<=ADV_ADDR; adv_waddr<=8'h41; // power reg, harmless to read
                    op_go<=1'b1; br_st<=BR_ADV_PROBE_WT;
                end
                BR_ADV_PROBE_WT: if (op_done) begin
                    if (!op_nack) begin
                        adv_presence_known_r<=1'b1; adv_present_r<=1'b1;
                        hd_addr_en<=1'b0;   // NOT yet -- ADV is present, but not
                                              // initialized. Raised for real once
                                              // init_adv() actually completes, at
                                              // BR_ENABLE_VIDEO's own completion
                                              // below (was wrongly raised here
                                              // before -- would have let a
                                              // partially-configured ADV accept
                                              // BIOS traffic).
                        br_st<=BR_INIT_HPD_FULL;
                    end else if (adv_probe_retry_cnt < MAX_ADV_PROBE_RETRIES) begin
                        adv_probe_retry_cnt<=adv_probe_retry_cnt+2'd1;
                        delay_ctr<=24'd0; br_st<=BR_ADV_PROBE_RETRY_DLY;
                    end else begin
                        adv_presence_known_r<=1'b1; adv_present_r<=1'b0;
                        br_st<=BR_ADV_ABSENT;
                    end
                end
                BR_ADV_PROBE_RETRY_DLY: begin
                    if (delay_ctr < DLY_RETRY) delay_ctr<=delay_ctr+24'd1;
                    else br_st<=BR_ADV_PROBE_GO;
                end
                // Terminal: no ADV7511 answered even after retries. Leave
                // hd_addr_en low, clear PLL/status, stay inert -- EOS itself
                // continues normally, this module just has nothing to do.
                // (The bus is already cleanly released -- every op_done here
                // was reached via the ops sequencer's own STOP phase, so
                // there's nothing left mid-transaction to clean up.)
                BR_ADV_ABSENT: begin
                    hd_addr_en<=1'b0; pll_lock_r<=1'b0;
                end

                // =========================================================
                // init_adv() from here down -- exact source order.
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
                        op_kind<=OP_READ; op_target_addr<=ADV_ADDR; adv_waddr<=8'hD6;
                        op_go<=1'b1; br_st<=BR_DISABLE_VIDEO;   // read-modify-write continues there
                    end
                end

                // disable_video(): update 0xD6 mask=0x01 val=0x01 (gate output)
                BR_DISABLE_VIDEO: begin
                    if (!op_go && ops_st==OPS_IDLE && op_kind==OP_READ) begin
                        // This is X-HD's first natural register read:
                        // adv7511_disable_video() after power_up().
                        diag_d6_raw<=adv_rdata;

                        // 0xFF here is still diagnostic evidence of a failed
                        // read path. Unlike the previous test, this read occurs
                        // at the same point and power state as the X-HD source.
                        if (adv_rdata == 8'hFF) begin
                            bringup_i2c_error<=1'b1;
                            transport_error_code<=3'd5;
                            br_st<=BR_TRANSPORT_D6_BAD;
                        end else begin
                            transport_verified<=1'b1;
                            op_kind<=OP_WRITE;
                            op_target_addr<=ADV_ADDR;
                            adv_waddr<=8'hD6;
                            adv_wdata<=(adv_rdata | 8'h01);
                            op_go<=1'b1;
                        end
                    end else if (op_done && op_kind==OP_WRITE) begin
                        br_st<=BR_WRITE_15;
                    end
                end

                // Exact X-HD sequence: write 0x15, then write 0x16.
                // The previous 0x15 readback was diagnostic code that X-HD
                // never performs, so it is removed.
                BR_WRITE_15: if (!op_go && ops_st==OPS_IDLE) begin
                    op_kind<=OP_WRITE; op_target_addr<=ADV_ADDR;
                    adv_waddr<=8'h15; adv_wdata<=8'h25;
                    op_go<=1'b1; br_st<=BR_WRITE_16;
                end

                // write 0x16 = 0b00111011 (output format)
                BR_WRITE_16: if (op_done) begin
                    op_kind<=OP_WRITE; op_target_addr<=ADV_ADDR;
                    adv_waddr<=8'h16; adv_wdata<=8'h3B;
                    op_go<=1'b1;
                    enc_apply_id<=boot_encoder_id;
                    enc_tweak_return_st<=BR_DE_GEN;
                    br_st<=BR_ENC_TWEAK_GO;
                end

                // encoder-specific tweak (§4.2), INLINE here matching source
                // order exactly -- this is the fix: was deferred to BR_READY
                // before, waiting for the BIOS; now applied immediately with
                // the boot-selected value, same as X-HD applies immediately
                // with its compile-time value. The same states are reused by
                // the one later Focus transition so the source branch is not
                // duplicated or allowed to drift.
                BR_ENC_TWEAK_GO: if (op_done) begin
                    op_kind<=OP_READ; op_target_addr<=ADV_ADDR; adv_waddr<=8'h48; op_go<=1'b1;
                    br_st<=BR_ENC_TWEAK_WT;
                end
                BR_ENC_TWEAK_WT: if (op_done) begin
                    if (adv_waddr == 8'h48 && op_kind==OP_READ) begin
                        op_kind<=OP_WRITE; op_target_addr<=ADV_ADDR; adv_waddr<=8'h48;
                        adv_wdata<=((adv_rdata & ~8'b01100000) | enc_0x48_val(enc_apply_id));
                        op_go<=1'b1;
                    end else if (adv_waddr == 8'h48 && op_kind==OP_WRITE) begin
                        op_kind<=OP_READ; op_target_addr<=ADV_ADDR; adv_waddr<=8'hBA; op_go<=1'b1;
                    end else if (adv_waddr == 8'hBA && op_kind==OP_READ) begin
                        op_kind<=OP_WRITE; op_target_addr<=ADV_ADDR; adv_waddr<=8'hBA;
                        adv_wdata<=((adv_rdata & ~8'b11100000) | enc_0xba_val(enc_apply_id));
                        op_go<=1'b1;
                    end else if (adv_waddr == 8'hBA && op_kind==OP_WRITE) begin
                        op_kind<=OP_READ; op_target_addr<=ADV_ADDR; adv_waddr<=8'hD0; op_go<=1'b1;
                    end else if (adv_waddr == 8'hD0 && op_kind==OP_READ) begin
                        op_kind<=OP_WRITE; op_target_addr<=ADV_ADDR; adv_waddr<=8'hD0;
                        adv_wdata<=(adv_rdata | 8'b00001100);
                        op_go<=1'b1;
                    end else begin
                        last_encoder_id<=enc_apply_id;
                        if (!boot_xcalibur && enc_apply_id==ENC_FOCUS)
                            focus_detected<=1'b1;
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

                // disable_csc(): update 0x18 mask=0x80 val=0
                BR_DISABLE_CSC: begin
                    if (!op_go && ops_st==OPS_IDLE && adv_waddr != 8'h18) begin
                        op_kind<=OP_READ; op_target_addr<=ADV_ADDR; adv_waddr<=8'h18; op_go<=1'b1;
                    end else if (op_done && op_kind==OP_READ) begin
                        op_kind<=OP_WRITE; op_target_addr<=ADV_ADDR; adv_waddr<=8'h18;
                        adv_wdata<=(adv_rdata & ~8'h80);
                        op_go<=1'b1;
                    end else if (op_done && op_kind==OP_WRITE) begin
                        br_st<=BR_WRITE_AF;
                    end
                end

                // write 0xAF = 0b00000110 (HDMI mode, HDCP off)
                BR_WRITE_AF: if (!op_go && ops_st==OPS_IDLE) begin
                    op_kind<=OP_WRITE; op_target_addr<=ADV_ADDR; adv_waddr<=8'hAF; adv_wdata<=8'b00000110;
                    op_go<=1'b1; br_st<=BR_GCP_ENABLE;
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
                        br_st<=BR_ENABLE_VIDEO;
                    end
                end

                // enable_video(): final X-HD init_adv() call.
                BR_ENABLE_VIDEO: begin
                    if (!op_go && ops_st==OPS_IDLE && adv_waddr != 8'hD6) begin
                        op_kind<=OP_READ; op_target_addr<=ADV_ADDR;
                        adv_waddr<=8'hD6; op_go<=1'b1;
                    end else if (op_done && op_kind==OP_READ) begin
                        op_kind<=OP_WRITE; op_target_addr<=ADV_ADDR;
                        adv_waddr<=8'hD6;
                        adv_wdata<=(adv_rdata & ~8'h01);
                        op_go<=1'b1;
                    end else if (op_done && op_kind==OP_WRITE) begin
                        last_encoder_id<=enc_apply_id;
                        // The BIOS settings responder is safe to expose now
                        // that init is complete. FORCE_STANDALONE gates full
                        // mode ownership, not the Focus-detection packet path.
                        hd_addr_en<=1'b1;

                        // adv7511_struct_init() already ran immediately before
                        // init_adv(). Do not clear the runtime fields here:
                        // an INT edge that occurs during init must remain pending
                        // for the first adv_handle_interrupts() call.
                        br_st<=BR_READY;
                    end
                end

                // ---- steady state: X-HD main.c source order ----
                //   1. read PLL status from 0x9E
                //   2. call adv_handle_interrupts(); it is a no-op unless the
                //      physical INT ISR has set encoder.interrupt
                //   3. execute stand_alone_loop()
                BR_READY: begin
                    if (op_done && op_kind==OP_READ && adv_waddr==8'h9E) begin
                        if (!op_nack && !op_timeout) begin
                            diag_9e_raw<=adv_rdata;
                            pll_lock_r<=adv_rdata[4];
                        end
                        else
                            bringup_i2c_error<=1'b1;

                        if (adv_irq_pending) begin
                            op_kind<=OP_READ; op_target_addr<=ADV_ADDR;
                            adv_waddr<=8'h96; op_go<=1'b1;
                            xhd_irq_phase<=IRQ_WAIT_FLAGS;
                            br_st<=BR_XHD_IRQ_HANDLER;
                        end else if (!FORCE_STANDALONE && bios_took_over) begin
                            // X-HD main.c calls bios_loop() here instead of
                            // stand_alone_loop() after one-way takeover.
                            if (cfg_pending && !cfg_ack) begin
                                br_st<=BR_ENCODER_REPORT;
                            end else begin
                                op_kind<=OP_READ; op_target_addr<=ADV_ADDR;
                                adv_waddr<=8'h9E; op_go<=1'b1;
                            end
                        end else begin
                            // adv_handle_interrupts() returned immediately.
                            op_kind<=OP_READ; op_target_addr<=ADV_ADDR;
                            adv_waddr<=8'h3E; op_go<=1'b1;
                        end
                    end else if (!FORCE_STANDALONE && bios_took_over) begin
                        // BIOS ownership stops the standalone 0x3E applicator.
                        // Any already-active transaction is allowed to finish;
                        // subsequent work comes only from BIOS APPLY packets.
                        if (cfg_pending && !cfg_ack &&
                            !op_go && ops_st==OPS_IDLE) begin
                            br_st<=BR_ENCODER_REPORT;
                        end else if (!op_go && ops_st==OPS_IDLE) begin
                            op_kind<=OP_READ; op_target_addr<=ADV_ADDR;
                            adv_waddr<=8'h9E; op_go<=1'b1;
                        end
                    end else if (op_done && op_kind==OP_READ &&
                                 adv_waddr==8'h3E) begin
                        if (!op_nack && !op_timeout) begin
                            diag_3e_raw<=adv_rdata;
                            xhd_detected_vic<=adv_rdata[7:2];
                        end
                        else
                            bringup_i2c_error<=1'b1;

                        // Exact stand_alone_loop() change detector:
                        // (read(0x3E)>>2) != (encoder->vic & 0x0F)
                        if (!op_nack && !op_timeout &&
                            adv_rdata[7:2] !=
                            {2'b00,xhd_encoder_vic[3:0]}) begin
                            op_kind<=OP_READ; op_target_addr<=ADV_ADDR;
                            adv_waddr<=8'h3E; op_go<=1'b1;
                            br_st<=BR_XHD_VIC_REREAD_WAIT;
                        end else if (cfg_pending && !cfg_ack) begin
                            br_st<=BR_ENCODER_REPORT;
                        end else begin
                            op_kind<=OP_READ; op_target_addr<=ADV_ADDR;
                            adv_waddr<=8'h9E; op_go<=1'b1;
                        end
                    end else if (cfg_pending && !cfg_ack &&
                                 !op_go && ops_st==OPS_IDLE) begin
                        br_st<=BR_ENCODER_REPORT;
                    end else if (!op_go && ops_st==OPS_IDLE) begin
                        op_kind<=OP_READ; op_target_addr<=ADV_ADDR;
                        adv_waddr<=8'h9E; op_go<=1'b1;
                    end
                end

                // Thin EOS detection layer around the proven X-HD branches.
                // EOS's physical/detected encoder remains authoritative; after
                // that decision, FORCE_STANDALONE selects either the existing
                // VIC-following path or the complete X-HD BIOS applicator.
                BR_ENCODER_REPORT: begin
                    if (boot_xcalibur) begin
                        if (!live_encoder_is_xcalibur)
                            encoder_report_mismatch<=1'b1;
                        if (!live_encoder_valid)
                            encoder_report_invalid<=1'b1;

                        if (FORCE_STANDALONE) begin
                            cfg_ack<=1'b1;
                            br_st<=BR_READY;
                        end else begin
                            bios_st<=BIOS_IDLE;
                            br_st<=BR_BIOS_APPLY;
                        end
                    end else if (focus_detected) begin
                        if (!live_encoder_is_focus) begin
                            if (live_encoder_valid)
                                encoder_report_mismatch<=1'b1;
                            else
                                encoder_report_invalid<=1'b1;
                        end

                        if (FORCE_STANDALONE) begin
                            cfg_ack<=1'b1;
                            br_st<=BR_READY;
                        end else begin
                            bios_st<=BIOS_IDLE;
                            br_st<=BR_BIOS_APPLY;
                        end
                    end else if (live_encoder_is_focus) begin
                        enc_apply_id<=ENC_FOCUS;
                        enc_tweak_return_st<=FORCE_STANDALONE
                                           ? BR_READY : BR_BIOS_APPLY;
                        bios_st<=BIOS_IDLE;
                        op_kind<=OP_READ; op_target_addr<=ADV_ADDR;
                        adv_waddr<=8'h48; op_go<=1'b1;
                        br_st<=BR_ENC_TWEAK_WT;
                    end else begin
                        if (live_encoder_is_xcalibur)
                            encoder_report_mismatch<=1'b1;
                        if (!live_encoder_valid)
                            encoder_report_invalid<=1'b1;

                        if (FORCE_STANDALONE) begin
                            cfg_ack<=1'b1;
                            br_st<=BR_READY;
                        end else begin
                            bios_st<=BIOS_IDLE;
                            br_st<=BR_BIOS_APPLY;
                        end
                    end
                end


                // =========================================================
                // X-HD BIOS-owned mode applicator.
                //
                // This is entered only when FORCE_STANDALONE=0. The default
                // validated standalone path is therefore unchanged. EOS's
                // own encoder selection remains authoritative; this engine
                // ports xbox_video_bios.c after encoder selection.
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
                            end else if (!bios_row_valid) begin
                                // X-HD records the new mode/avinfo before it
                                // discovers that the table row is absent, then
                                // leaves the current output untouched.
                                bios_current_mode<=live_mode;
                                bios_current_avinfo<=live_avinfo;
                                cfg_ack<=1'b1;
                                op_kind<=OP_READ; op_target_addr<=ADV_ADDR;
                                adv_waddr<=8'h9E; op_go<=1'b1;
                                br_st<=BR_READY;
                            end else begin
                                bios_pending_mode<=live_mode;
                                bios_pending_avinfo<=live_avinfo;
                                bios_adv_delay_hs<=bios_row_hs_delay-16'd1;
                                bios_vs_delay<=bios_row_vs_adjusted;
                                bios_h_active<=bios_row_h_active;
                                bios_v_active<=bios_row_v_adjusted;
                                bios_hsync_placement<=bios_row_hsync_placement;
                                bios_hsync_duration<=bios_row_hsync_duration;
                                bios_vsync_placement<=bios_row_vsync_placement;
                                bios_vsync_duration<=bios_row_vsync_duration;
                                bios_interlaced_offset<=bios_row_interlaced_offset;
                                bios_sync_adjust<=bios_row_sync_adjust;
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
                            if (bios_rgb) begin
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

                        BIOS_CSC_DIS_RD_WAIT: if (op_done) begin
                            op_kind<=OP_WRITE; op_target_addr<=ADV_ADDR;
                            adv_waddr<=8'h18;
                            adv_wdata<=adv_rdata & ~8'h80;
                            op_go<=1'b1;
                            bios_st<=BIOS_CSC_DIS_WR_WAIT;
                        end

                        BIOS_CSC_DIS_WR_WAIT: if (op_done) begin
                            op_kind<=OP_WRITE; op_target_addr<=ADV_ADDR;
                            adv_waddr<=8'h35;
                            adv_wdata<=bios_adv_delay_hs[9:2];
                            op_go<=1'b1;
                            bios_st<=BIOS_WR35_WAIT;
                        end

                        BIOS_CSC_WRITE_WAIT: if (op_done) begin
                            if (bios_csc_idx == 5'd23) begin
                                op_kind<=OP_WRITE; op_target_addr<=ADV_ADDR;
                                adv_waddr<=8'h35;
                                adv_wdata<=bios_adv_delay_hs[9:2];
                                op_go<=1'b1;
                                bios_st<=BIOS_WR35_WAIT;
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
                            if (bios_sync_adjust) begin
                                op_kind<=OP_WRITE; op_target_addr<=ADV_ADDR;
                                adv_waddr<=8'hD7;
                                adv_wdata<=bios_hsync_placement[9:2];
                                op_go<=1'b1;
                                bios_st<=BIOS_WRD7_WAIT;
                            end else begin
                                op_kind<=OP_READ; op_target_addr<=ADV_ADDR;
                                adv_waddr<=8'h41; op_go<=1'b1;
                                bios_st<=BIOS_RD41_WAIT;
                            end
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

                        BIOS_WRDB_WAIT: if (op_done) begin
                            op_kind<=OP_READ; op_target_addr<=ADV_ADDR;
                            adv_waddr<=8'h41; op_go<=1'b1;
                            bios_st<=BIOS_RD41_WAIT;
                        end

                        BIOS_RD41_WAIT: if (op_done) begin
                            op_kind<=OP_WRITE; op_target_addr<=ADV_ADDR;
                            adv_waddr<=8'h41;
                            adv_wdata<=bios_sync_adjust
                                     ? (adv_rdata | 8'h02)
                                     : (adv_rdata & ~8'h02);
                            op_go<=1'b1;
                            bios_st<=BIOS_WR41_WAIT;
                        end

                        BIOS_WR41_WAIT: if (op_done) begin
                            op_kind<=OP_WRITE; op_target_addr<=ADV_ADDR;
                            adv_waddr<=8'hDC;
                            adv_wdata<={bios_interlaced_offset,5'b00000};
                            op_go<=1'b1;
                            bios_st<=BIOS_WRDC_WAIT;
                        end

                        BIOS_WRDC_WAIT: if (op_done) begin
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
                            // adv7511_power_up_tmds(): update A1[5:2]=0.
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
                            mode_applied_ok<=1'b1;
                            xhd_sent_vic<=bios_vic[4:0];
                            cfg_ack<=1'b1;
                            bios_st<=BIOS_IDLE;
                            op_kind<=OP_READ; op_target_addr<=ADV_ADDR;
                            adv_waddr<=8'h9E; op_go<=1'b1;
                            br_st<=BR_READY;
                        end

                        // Runtime transport failure recovery: best-effort
                        // re-enable TMDS, acknowledge this packet, and leave
                        // the previous mode as the last known-good state.
                        BIOS_RECOVER_RD: begin
                            if (!op_go && ops_st==OPS_IDLE) begin
                                op_kind<=OP_READ; op_target_addr<=ADV_ADDR;
                                adv_waddr<=8'hA1; op_go<=1'b1;
                                bios_st<=BIOS_RECOVER_RD_WAIT;
                            end
                        end

                        BIOS_RECOVER_RD_WAIT: if (op_done) begin
                            if (!op_nack && !op_timeout) begin
                                op_kind<=OP_WRITE; op_target_addr<=ADV_ADDR;
                                adv_waddr<=8'hA1;
                                adv_wdata<=adv_rdata & ~8'h3C;
                                op_go<=1'b1;
                                bios_st<=BIOS_RECOVER_WR_WAIT;
                            end else begin
                                cfg_ack<=1'b1;
                                bios_st<=BIOS_IDLE;
                                op_kind<=OP_READ; op_target_addr<=ADV_ADDR;
                                adv_waddr<=8'h9E; op_go<=1'b1;
                                br_st<=BR_READY;
                            end
                        end

                        BIOS_RECOVER_WR_WAIT: if (op_done) begin
                            cfg_ack<=1'b1;
                            bios_st<=BIOS_IDLE;
                            op_kind<=OP_READ; op_target_addr<=ADV_ADDR;
                            adv_waddr<=8'h9E; op_go<=1'b1;
                            br_st<=BR_READY;
                        end

                        default: bios_st<=BIOS_IDLE;
                    endcase
                end

                // Physical-INT-gated port of adv_handle_interrupts().
                BR_XHD_IRQ_HANDLER: begin
                    case (xhd_irq_phase)
                        // uint8_t interrupt_register = read(0x96);
                        IRQ_WAIT_FLAGS: if (op_done) begin
                            if (op_nack || op_timeout) begin
                                bringup_i2c_error<=1'b1;
                                if (!FORCE_STANDALONE && bios_took_over) begin
                                    br_st<=BR_READY;
                                end else begin
                                    op_kind<=OP_READ; op_target_addr<=ADV_ADDR;
                                    adv_waddr<=8'h3E; op_go<=1'b1;
                                    br_st<=BR_READY;
                                end
                            end else begin
                                xhd_irq_flags<=adv_rdata;

                                if (adv_rdata[7]) begin
                                    // Dedicated source-equivalent 0x42 HPD read.
                                    op_kind<=OP_READ;
                                    op_target_addr<=ADV_ADDR;
                                    adv_waddr<=8'h42;
                                    op_go<=1'b1;
                                    xhd_irq_phase<=IRQ_WAIT_HPD_STATUS;
                                end else if (adv_rdata[6]) begin
                                    // Separate source-equivalent 0x42 MS read.
                                    op_kind<=OP_READ;
                                    op_target_addr<=ADV_ADDR;
                                    adv_waddr<=8'h42;
                                    op_go<=1'b1;
                                    xhd_irq_phase<=IRQ_WAIT_MS_STATUS;
                                end else begin
                                    xhd_irq_phase<=IRQ_DECIDE_POWER;
                                end
                            end
                        end

                        IRQ_WAIT_HPD_STATUS: if (op_done) begin
                            if (!op_nack && !op_timeout) begin
                                diag_42_raw<=adv_rdata;
                                xhd_hpd<=adv_rdata[6];
                            end
                            else
                                bringup_i2c_error<=1'b1;

                            if (xhd_irq_flags[6]) begin
                                op_kind<=OP_READ;
                                op_target_addr<=ADV_ADDR;
                                adv_waddr<=8'h42;
                                op_go<=1'b1;
                                xhd_irq_phase<=IRQ_WAIT_MS_STATUS;
                            end else begin
                                xhd_irq_phase<=IRQ_DECIDE_POWER;
                            end
                        end

                        IRQ_WAIT_MS_STATUS: if (op_done) begin
                            if (!op_nack && !op_timeout) begin
                                diag_42_raw<=adv_rdata;
                                xhd_monitor_sense<=adv_rdata[5];
                            end
                            else
                                bringup_i2c_error<=1'b1;
                            xhd_irq_phase<=IRQ_DECIDE_POWER;
                        end

                        IRQ_DECIDE_POWER: begin
                            if (xhd_hpd && xhd_monitor_sense) begin
                                op_kind<=OP_WRITE;
                                op_target_addr<=ADV_ADDR;
                                adv_waddr<=8'h41;
                                adv_wdata<=8'h10;
                                op_go<=1'b1;
                                xhd_irq_phase<=IRQ_POWER_A_WAIT;
                            end else begin
                                // encoder.interrupt = 0; then
                                // update_register(0x96,0xC0,0xC0)
                                op_kind<=OP_READ;
                                op_target_addr<=ADV_ADDR;
                                adv_waddr<=8'h96;
                                op_go<=1'b1;
                                xhd_irq_phase<=IRQ_CLEAR_READ_WAIT;
                            end
                        end

                        IRQ_POWER_A_WAIT: if (op_done) begin
                            if (op_nack || op_timeout)
                                bringup_i2c_error<=1'b1;
                            delay_ctr<=24'd0;
                            xhd_irq_phase<=IRQ_POWER_A_DELAY;
                        end
                        IRQ_POWER_A_DELAY: begin
                            if (delay_ctr < DLY_30MS)
                                delay_ctr<=delay_ctr+24'd1;
                            else begin
                                op_kind<=OP_WRITE;
                                op_target_addr<=ADV_ADDR;
                                adv_waddr<=8'h41;
                                adv_wdata<=8'h00;
                                op_go<=1'b1;
                                xhd_irq_phase<=IRQ_POWER_B_WAIT;
                            end
                        end
                        IRQ_POWER_B_WAIT: if (op_done) begin
                            if (op_nack || op_timeout)
                                bringup_i2c_error<=1'b1;
                            delay_ctr<=24'd0;
                            xhd_irq_phase<=IRQ_POWER_B_DELAY;
                        end
                        IRQ_POWER_B_DELAY: begin
                            if (delay_ctr < DLY_30MS)
                                delay_ctr<=delay_ctr+24'd1;
                            else begin
                                op_kind<=OP_WRITE;
                                op_target_addr<=ADV_ADDR;
                                adv_waddr<=8'h41;
                                adv_wdata<=8'h10;
                                op_go<=1'b1;
                                xhd_irq_phase<=IRQ_POWER_C_WAIT;
                            end
                        end
                        IRQ_POWER_C_WAIT: if (op_done) begin
                            if (op_nack || op_timeout)
                                bringup_i2c_error<=1'b1;
                            delay_ctr<=24'd0;
                            xhd_irq_phase<=IRQ_POWER_C_DELAY;
                        end
                        IRQ_POWER_C_DELAY: begin
                            if (delay_ctr < DLY_50MS)
                                delay_ctr<=delay_ctr+24'd1;
                            else begin
                                op_kind<=OP_READ;
                                op_target_addr<=ADV_ADDR;
                                adv_waddr<=8'h96;
                                op_go<=1'b1;
                                xhd_irq_phase<=IRQ_CLEAR_READ_WAIT;
                            end
                        end

                        // adv7511_update_register(0x96,0xC0,0xC0)
                        IRQ_CLEAR_READ_WAIT: if (op_done) begin
                            // encoder.interrupt = 0, immediately before X-HD's
                            // update_register(0x96,0xC0,0xC0).
                            if (!adv_int_edge)
                                adv_irq_pending<=1'b0;
                            if (op_nack || op_timeout) begin
                                bringup_i2c_error<=1'b1;
                                if (!FORCE_STANDALONE && bios_took_over) begin
                                    br_st<=BR_READY;
                                end else begin
                                    op_kind<=OP_READ;
                                    op_target_addr<=ADV_ADDR;
                                    adv_waddr<=8'h3E;
                                    op_go<=1'b1;
                                    br_st<=BR_READY;
                                end
                            end else begin
                                op_kind<=OP_WRITE;
                                op_target_addr<=ADV_ADDR;
                                adv_waddr<=8'h96;
                                adv_wdata<=((adv_rdata & ~8'hC0) | 8'hC0);
                                op_go<=1'b1;
                                xhd_irq_phase<=IRQ_CLEAR_WRITE_WAIT;
                            end
                        end
                        IRQ_CLEAR_WRITE_WAIT: if (op_done) begin
                            if (op_nack || op_timeout)
                                bringup_i2c_error<=1'b1;
                            xhd_irq_flags<=8'd0;
                            if (!FORCE_STANDALONE && bios_took_over) begin
                                br_st<=BR_READY;
                            end else begin
                                op_kind<=OP_READ;
                                op_target_addr<=ADV_ADDR;
                                adv_waddr<=8'h3E;
                                op_go<=1'b1;
                                br_st<=BR_READY;
                            end
                        end

                        default: begin
                            xhd_irq_phase<=IRQ_WAIT_FLAGS;
                            xhd_irq_flags<=8'd0;
                            if (!FORCE_STANDALONE && bios_took_over) begin
                                br_st<=BR_READY;
                            end else begin
                                op_kind<=OP_READ;
                                op_target_addr<=ADV_ADDR;
                                adv_waddr<=8'h3E;
                                op_go<=1'b1;
                                br_st<=BR_READY;
                            end
                        end
                    endcase
                end

                BR_XHD_VIC_REREAD_WAIT: if (op_done) begin
                    if (!op_nack && !op_timeout) begin
                        diag_3e_raw<=adv_rdata;
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
                            sa_hd_latched<=sa_is_hd(xhd_vic_map[2:0]);
                            mode_applied_ok<=1'b0;
                            br_st<=BR_STANDALONE_CSC_DISABLE;
                        end else begin
                            op_kind<=OP_READ; op_target_addr<=ADV_ADDR;
                            adv_waddr<=8'h9E; op_go<=1'b1;
                            br_st<=BR_READY;
                        end
                    end else begin
                        bringup_i2c_error<=1'b1;
                        op_kind<=OP_READ; op_target_addr<=ADV_ADDR;
                        adv_waddr<=8'h9E; op_go<=1'b1;
                        br_st<=BR_READY;
                    end
                end

                // =========================================================
                // Standalone mode applicator -- exact X-HD set_video_mode_vic()
                // register order, translated one operation at a time.
                // =========================================================

                // if (!rgb) adv7511_disable_csc();
                BR_STANDALONE_CSC_DISABLE: begin
                    if (!op_go && ops_st==OPS_IDLE && adv_waddr != 8'h18) begin
                        op_kind<=OP_READ; op_target_addr<=ADV_ADDR; adv_waddr<=8'h18; op_go<=1'b1;
                    end else if (op_done && op_kind==OP_READ) begin
                        op_kind<=OP_WRITE; op_target_addr<=ADV_ADDR; adv_waddr<=8'h18;
                        adv_wdata<=(adv_rdata & ~8'h80); op_go<=1'b1;
                    end else if (op_done && op_kind==OP_WRITE) begin
                        sa_delay_hs<=sa_hs_latched-10'd1;
                        br_st<=BR_STANDALONE_WR_35;
                    end
                end

                BR_STANDALONE_WR_35: if (!op_go && ops_st==OPS_IDLE) begin
                    op_kind<=OP_WRITE; op_target_addr<=ADV_ADDR; adv_waddr<=8'h35;
                    adv_wdata<=sa_delay_hs[9:2]; op_go<=1'b1; br_st<=BR_STANDALONE_WR_36;
                end
                BR_STANDALONE_WR_36: if (op_done) begin
                    op_kind<=OP_WRITE; op_target_addr<=ADV_ADDR; adv_waddr<=8'h36;
                    adv_wdata<={sa_delay_hs[1:0],sa_vs_latched[5:0]};
                    op_go<=1'b1; br_st<=BR_STANDALONE_WR_37;
                end

                // X-HD uses update_register(0x37,0x1F,active_w>>7), not a
                // full overwrite. Preserve the interlace bits exactly.
                BR_STANDALONE_WR_37: begin
                    if (!op_go && ops_st==OPS_IDLE && adv_waddr != 8'h37) begin
                        op_kind<=OP_READ; op_target_addr<=ADV_ADDR; adv_waddr<=8'h37; op_go<=1'b1;
                    end else if (op_done && op_kind==OP_READ) begin
                        op_kind<=OP_WRITE; op_target_addr<=ADV_ADDR; adv_waddr<=8'h37;
                        adv_wdata<=((adv_rdata & 8'hE0) | {3'b000,sa_h_latched[11:7]});
                        op_go<=1'b1;
                    end else if (op_done && op_kind==OP_WRITE) begin
                        br_st<=BR_STANDALONE_WR_38;
                    end
                end
                BR_STANDALONE_WR_38: if (!op_go && ops_st==OPS_IDLE) begin
                    op_kind<=OP_WRITE; op_target_addr<=ADV_ADDR; adv_waddr<=8'h38;
                    adv_wdata<={sa_h_latched[6:0],1'b0}; op_go<=1'b1; br_st<=BR_STANDALONE_WR_39;
                end
                BR_STANDALONE_WR_39: if (op_done) begin
                    op_kind<=OP_WRITE; op_target_addr<=ADV_ADDR; adv_waddr<=8'h39;
                    adv_wdata<=sa_v_latched[11:4]; op_go<=1'b1; br_st<=BR_STANDALONE_WR_3A;
                end
                BR_STANDALONE_WR_3A: if (op_done) begin
                    op_kind<=OP_WRITE; op_target_addr<=ADV_ADDR; adv_waddr<=8'h3A;
                    adv_wdata<={sa_v_latched[3:0],4'b0000}; op_go<=1'b1;
                    br_st<=BR_STANDALONE_AVI_START;
                end

                // update_avi_infoframe(widescreen,false,vic) -- exact X-HD order
                BR_STANDALONE_AVI_START: if (op_done) begin
                    op_kind<=OP_READ; op_target_addr<=ADV_ADDR; adv_waddr<=8'h4A; op_go<=1'b1;
                    br_st<=BR_STANDALONE_WR_55;
                end
                BR_STANDALONE_WR_55: begin
                    if (op_done && op_kind==OP_READ && adv_waddr==8'h4A) begin
                        op_kind<=OP_WRITE; op_target_addr<=ADV_ADDR; adv_waddr<=8'h4A;
                        adv_wdata<=(adv_rdata|8'h40); op_go<=1'b1;
                    end else if (op_done && op_kind==OP_WRITE && adv_waddr==8'h4A) begin
                        op_kind<=OP_READ; op_target_addr<=ADV_ADDR; adv_waddr<=8'h55; op_go<=1'b1;
                    end else if (op_done && op_kind==OP_READ && adv_waddr==8'h55) begin
                        op_kind<=OP_WRITE; op_target_addr<=ADV_ADDR; adv_waddr<=8'h55;
                        adv_wdata<=((adv_rdata & ~8'h73)|8'h52); op_go<=1'b1;
                    end else if (op_done && op_kind==OP_WRITE && adv_waddr==8'h55) begin
                        br_st<=BR_STANDALONE_WR_56;
                    end
                end
                BR_STANDALONE_WR_56: if (!op_go && ops_st==OPS_IDLE) begin
                    op_kind<=OP_WRITE; op_target_addr<=ADV_ADDR; adv_waddr<=8'h56;
                    adv_wdata<=(sa_hd_latched?8'h80:8'h40)|(sa_ws_latched?8'h28:8'h18);
                    op_go<=1'b1; br_st<=BR_STANDALONE_WR_57;
                end
                BR_STANDALONE_WR_57: if (op_done) begin
                    op_kind<=OP_WRITE; op_target_addr<=ADV_ADDR; adv_waddr<=8'h57;
                    adv_wdata<=8'h80; op_go<=1'b1; br_st<=BR_STANDALONE_WR_58;
                end
                BR_STANDALONE_WR_58: if (op_done) begin
                    op_kind<=OP_WRITE; op_target_addr<=ADV_ADDR; adv_waddr<=8'h58;
                    adv_wdata<={2'b00,sa_vic_latched}; op_go<=1'b1; br_st<=BR_STANDALONE_WR_59;
                end
                BR_STANDALONE_WR_59: if (op_done) begin
                    op_kind<=OP_WRITE; op_target_addr<=ADV_ADDR; adv_waddr<=8'h59;
                    adv_wdata<=8'h30; op_go<=1'b1; br_st<=BR_STANDALONE_AVI_END;
                end
                BR_STANDALONE_AVI_END: begin
                    if (!op_go && ops_st==OPS_IDLE && adv_waddr==8'h59) begin
                        op_kind<=OP_READ; op_target_addr<=ADV_ADDR; adv_waddr<=8'h4A; op_go<=1'b1;
                    end else if (op_done && op_kind==OP_READ && adv_waddr==8'h4A) begin
                        op_kind<=OP_WRITE; op_target_addr<=ADV_ADDR; adv_waddr<=8'h4A;
                        adv_wdata<=(adv_rdata & ~8'h40); op_go<=1'b1;
                    end else if (op_done && op_kind==OP_WRITE && adv_waddr==8'h4A) begin
                        br_st <= (sa_vic_latched==6'd5)
                               ? BR_STANDALONE_INTERLACE_37
                               : BR_STANDALONE_SYNC_MODE;
                    end
                end

                // X-HD interlaced branch: update 0x37[7:5], write 0xDC,
                // then update 0x41[1]. Progressive skips 0x37/0xDC.
                BR_STANDALONE_INTERLACE_37: begin
                    if (!op_go && ops_st==OPS_IDLE && adv_waddr != 8'h37) begin
                        op_kind<=OP_READ; op_target_addr<=ADV_ADDR; adv_waddr<=8'h37; op_go<=1'b1;
                    end else if (op_done && op_kind==OP_READ) begin
                        op_kind<=OP_WRITE; op_target_addr<=ADV_ADDR; adv_waddr<=8'h37;
                        adv_wdata<=(adv_rdata & 8'h1F); op_go<=1'b1;
                    end else if (op_done && op_kind==OP_WRITE) begin
                        br_st<=BR_STANDALONE_WR_DC;
                    end
                end
                BR_STANDALONE_WR_DC: if (!op_go && ops_st==OPS_IDLE) begin
                    op_kind<=OP_WRITE; op_target_addr<=ADV_ADDR; adv_waddr<=8'hDC;
                    adv_wdata<=8'h00; op_go<=1'b1; br_st<=BR_STANDALONE_SYNC_MODE;
                end
                BR_STANDALONE_SYNC_MODE: begin
                    if (!op_go && ops_st==OPS_IDLE && adv_waddr != 8'h41) begin
                        op_kind<=OP_READ; op_target_addr<=ADV_ADDR; adv_waddr<=8'h41; op_go<=1'b1;
                    end else if (op_done && op_kind==OP_READ) begin
                        op_kind<=OP_WRITE; op_target_addr<=ADV_ADDR; adv_waddr<=8'h41;
                        adv_wdata <= (sa_vic_latched==6'd5)
                                   ? (adv_rdata|8'h02) : (adv_rdata & ~8'h02);
                        op_go<=1'b1;
                    end else if (op_done && op_kind==OP_WRITE) begin
                        br_st<=BR_STANDALONE_D0_UPDATE;
                    end
                end
                BR_STANDALONE_D0_UPDATE: begin
                    if (!op_go && ops_st==OPS_IDLE && adv_waddr != 8'hD0) begin
                        op_kind<=OP_READ; op_target_addr<=ADV_ADDR; adv_waddr<=8'hD0; op_go<=1'b1;
                    end else if (op_done && op_kind==OP_READ) begin
                        op_kind<=OP_WRITE; op_target_addr<=ADV_ADDR; adv_waddr<=8'hD0;
                        adv_wdata<=(adv_rdata|8'h02); op_go<=1'b1;
                    end else if (op_done && op_kind==OP_WRITE) begin
                        br_st<=BR_STANDALONE_WR_VIC_3C;
                    end
                end
                BR_STANDALONE_WR_VIC_3C: if (!op_go && ops_st==OPS_IDLE) begin
                    // Final functional X-HD set_video_mode_vic() operation.
                    op_kind<=OP_WRITE; op_target_addr<=ADV_ADDR;
                    adv_waddr<=8'h3C; adv_wdata<={2'b00,sa_vic_latched};
                    op_go<=1'b1;
                    mode_finish_phase<=2'd0;
                    br_st<=BR_XHD_MODE_FINISH;
                end

                // X-HD performs two 0x3D reads for its debug output:
                // pixel repetition first, then actual transmitted VIC.
                BR_XHD_MODE_FINISH: begin
                    case (mode_finish_phase)
                        2'd0: if (op_done) begin
                            if (op_nack || op_timeout)
                                bringup_i2c_error<=1'b1;
                            op_kind<=OP_READ; op_target_addr<=ADV_ADDR;
                            adv_waddr<=8'h3D; op_go<=1'b1;
                            mode_finish_phase<=2'd1;
                        end
                        2'd1: if (op_done) begin
                            if (!op_nack && !op_timeout) begin
                                diag_3d_raw<=adv_rdata;
                                xhd_pixel_repeat<=adv_rdata[7:6];
                            end
                            else
                                bringup_i2c_error<=1'b1;
                            op_kind<=OP_READ; op_target_addr<=ADV_ADDR;
                            adv_waddr<=8'h3D; op_go<=1'b1;
                            mode_finish_phase<=2'd2;
                        end
                        2'd2: if (op_done) begin
                            if (!op_nack && !op_timeout) begin
                                diag_3d_raw<=adv_rdata;
                                xhd_sent_vic<=adv_rdata[4:0];
                                mode_applied_ok<=
                                    (adv_rdata[4:0] ==
                                     sa_vic_latched[4:0]);
                            end else begin
                                bringup_i2c_error<=1'b1;
                                mode_applied_ok<=1'b0;
                            end
                            standalone_cur_mode<=standalone_target_mode;
                            standalone_mode_valid<=1'b1;
                            op_kind<=OP_READ; op_target_addr<=ADV_ADDR;
                            adv_waddr<=8'h9E; op_go<=1'b1;
                            br_st<=BR_READY;
                        end
                        default: mode_finish_phase<=2'd0;
                    endcase
                end

                // ---- init failure (requirement 4) --------------------
                // Reached only via the centralized check above (any NACK/
                // timeout while in_init_seq). Whatever was in progress is
                // already aborted -- the bus was already cleanly released
                // via the ops sequencer's own STOP phase before op_done
                // ever pulsed, and video is still gated (enable_video is the
                // LAST step of the sequence; nothing before it can leave
                // 0xD6 un-gated). Retry the WHOLE sequence exactly once; if
                // it fails again, disable HD for this boot rather than
                // continue with a partially-configured ADV7511.
                BR_INIT_FAILED: begin
                    if (!init_retry_used) begin
                        init_retry_used<=1'b1;
                        transport_verified<=1'b0;
                        delay_ctr<=24'd0; br_st<=BR_INIT_RETRY_DLY;
                    end else begin
                        disable_reason<=DR_INIT; br_st<=BR_HD_DISABLED;
                    end
                end
                BR_INIT_RETRY_DLY: begin
                    if (delay_ctr < DLY_RETRY) delay_ctr<=delay_ctr+24'd1;
                    else br_st<=BR_INIT_HPD_FULL;   // retry the WHOLE init_adv() from the top
                end

                // Terminal: gave up after exhausting retries somewhere
                // (ADV presence or init itself; the old encoder probe and
                // collision guard no longer exist as failure sources).
                // hd_addr_en stays/goes low, PLL status clears,
                // stays inert for the rest of this power cycle. EOS itself
                // is completely unaffected -- this module going inert
                // doesn't touch or block anything else in the design.
                BR_HD_DISABLED: begin
                    hd_addr_en<=1'b0; pll_lock_r<=1'b0;
                end

                default: br_st<=BR_RESET;
            endcase
            end

            // FORCE_STANDALONE keeps the standalone video engine in control,
            // but the Xbox-facing 0x69 responder remains available so the BIOS
            // encoder byte can identify Focus.
        end
    end

endmodule