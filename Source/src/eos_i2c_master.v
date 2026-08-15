// eos_i2c_master.v -- generic I2C/SMBus MASTER byte engine.
// Built for eos_hd.v to talk outbound to the ADV7511 (0x72) on its own
// dedicated two-wire bus. There was no existing master primitive anywhere in
// the gateware (eos_i2c.v is slave-only), so this is genuinely new, unlike
// the transport-layer reuse on the slave side.
//
// BUS TOPOLOGY (current EOS design): the ADV7511 lives on a PRIVATE bus
// (EXP1/EXP2 -- adv_sda/adv_scl at the top level), where EOS is the SOLE
// master. This is NOT the Xbox SMBus, and this engine no longer probes 0x69
// or touches the console bus at all -- the old HD collision guard is gone
// (see eos_hd.v's BR_RESET and eos_hd_integration_spec.md). Nothing else
// arbitrates on the ADV bus, so the yielding behavior below is never actually
// exercised in normal operation.
//
// SHARED-BUS ARBITRATION / YIELDING (retained defensive capability):
// The multi-master logic is deliberately kept even though the ADV bus is
// private, so the engine stays correct if it is ever placed on a contended
// bus. Gated by WAIT_BUS_FREE / SINGLE_MASTER: it requires a continuous
// bus-free window before START and checks SDA during transmitted '1' bits. If
// another master drives SDA low, EOS releases both lines, reports arbitration
// loss, and the caller retries the whole register operation after backoff. No
// STOP is emitted after an arbitration loss (a competing master would own the
// bus). On the private ADV bus these paths simply never trigger -- the bus is
// always free and never contended -- but they cost nothing to keep.
//
// CLOCK STRETCHING (as master, respecting a slave that stretches): every bit
// clock releases SCL (scl_oe<=0) and then WAITS for scl_in to actually read
// high before treating the clock as risen -- a real wait, not a fixed
// counter standing in for one. Bounded by STRETCH_TIMEOUT so a stuck/absent
// slave can't hang this engine forever; reports back via wr_timeout/rd_timeout.
//
// Byte-level interface: the caller (eos_hd.v) sequences transactions itself
// (start, write addr+bytes, [repeated start], read bytes, stop) by pulsing
// the individual ops below and waiting for each op's done pulse, same shape
// as eos_sd_spi.v's card interface elsewhere in this project.
module eos_i2c_master #(
    // X-HD uses STM32 timing register 0x00303D5B with an 8 MHz I2C
    // kernel clock. Decoding that register gives approximately:
    //   SCL low  = (0x5B + 1) / 8 MHz = 11.50 us
    //   SCL high = (0x3D + 1) / 8 MHz =  7.75 us
    // or about 52 kHz before filter/rise-time effects.
    //
    // At EOS's 64.8 MHz clock these are 745 and 502 cycles. Separate
    // low/high periods are used instead of the former symmetric 100 kHz
    // approximation.
    parameter integer SCL_LOW_CYCLES  = 745,
    parameter integer SCL_HIGH_CYCLES = 502,
    parameter integer STRETCH_TIMEOUT = 32'd6_480_000, // ~100ms at 64.8MHz --
                                            // generous; a real stretch is
                                            // microseconds, this only exists
                                            // to catch a genuinely stuck bus.
    parameter integer IDLE_WAIT_TIMEOUT = 32'd194_400_000, // ~3s total wait at 64.8MHz
    parameter integer BUS_FREE_CYCLES = 32'd324,
    parameter SINGLE_MASTER = 1'b1,
    parameter WAIT_BUS_FREE = 1'b1,
    parameter HONOR_CLOCK_STRETCH = 1'b1
)(
    input  wire        clk,
    input  wire        resetn,

    // physical bus (open-drain, OR-combined with eos_i2c.v's slave drive at
    // the top level -- see eos_hdmi_top.v)
    input  wire         sda_in,
    input  wire         scl_in,
    output reg          sda_oe,   // 1 = pull low, 0 = release
    output reg          scl_oe,   // 1 = pull low, 0 = release

    // ---- byte-level command interface ----
    input  wire         start_go,     // pulse: issue START (or repeated START)
    output reg           start_done,  // pulse: bus was idle (or timeout), see start_timeout
    output reg            start_timeout, // valid at start_done: 1 = bus never went idle

    input  wire         wr_go,        // pulse: clock out wr_byte
    input  wire [7:0]    wr_byte,
    output reg            wr_done,    // pulse
    output reg             wr_ack,    // valid at wr_done: 1 = slave ACKed
    output reg              wr_timeout, // valid at wr_done: 1 = timeout/arbitration failure
    output reg              wr_arb_lost, // valid at wr_done: lost multi-master arbitration

    input  wire         rd_go,        // pulse: clock in a byte
    input  wire          rd_send_ack, // 1 = we ACK (want more), 0 = NACK (last byte)
    output reg            rd_done,    // pulse
    output reg  [7:0]      rd_byte,   // valid at rd_done
    output reg              rd_timeout, // valid at rd_done: 1 = stretch timeout hit

    input  wire         stop_go,      // pulse: issue STOP
    output reg            stop_done,  // pulse

    output wire          busy
);
    localparam [3:0]
        S_IDLE       = 4'd0,
        S_WAIT_IDLE  = 4'd1,
        S_START_A    = 4'd2,
        S_START_B    = 4'd3,
        S_BIT_SETUP  = 4'd4,
        S_BIT_RISE   = 4'd5,
        S_BIT_HIGH   = 4'd6,
        S_BIT_FALL   = 4'd7,
        S_ACK_SETUP  = 4'd8,
        S_ACK_RISE   = 4'd9,
        S_ACK_HIGH   = 4'd10,
        S_ACK_FALL   = 4'd11,
        S_STOP_A     = 4'd12,
        S_STOP_B     = 4'd13,
        S_RSTART_WAIT= 4'd14,  // repeated start: full ACK->tLOW, then SCL-high setup
        S_RSTART_HOLD= 4'd15;  // repeated start: SDA high->low while SCL is high

    reg [3:0]   st;
    reg [7:0]   sh;
    reg [2:0]   bit_ix;
    reg [15:0]  pc;
    reg [31:0]  stretch_ctr;
    reg [31:0]  idle_high_ctr;
    reg         cur_is_write;     // which byte-op is in flight (for the shared BIT/ACK phases)
    reg         timed_out;
    reg [1:0]   rstart_phase;
    reg         bus_owned;        // 1 once a START has completed, until STOP -- gates
                                   // whether the next start_go is a fresh START (needs
                                   // the idle-check) or a repeated one (doesn't; we
                                   // already own the bus from the prior byte's ACK)

    // The SMBus pins are asynchronous to clk_sd. Two-stage synchronization
    // avoids sampling ACK/data/idle transitions directly on the FPGA clock.
    reg sda_meta, sda_sync, scl_meta, scl_sync;
    wire sda_bus = sda_sync;
    wire scl_bus = scl_sync;

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            sda_meta<=1'b1; sda_sync<=1'b1;
            scl_meta<=1'b1; scl_sync<=1'b1;
        end else begin
            sda_meta<=sda_in; sda_sync<=sda_meta;
            scl_meta<=scl_in; scl_sync<=scl_meta;
        end
    end

    assign busy = (st != S_IDLE);

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            st<=S_IDLE; sda_oe<=1'b0; scl_oe<=1'b0; sh<=8'd0; bit_ix<=3'd0; pc<=16'd0;
            stretch_ctr<=32'd0; idle_high_ctr<=32'd0;
            cur_is_write<=1'b0; timed_out<=1'b0;
            rstart_phase<=2'd0; bus_owned<=1'b0;
            start_done<=1'b0; wr_done<=1'b0; wr_ack<=1'b0; wr_timeout<=1'b0; wr_arb_lost<=1'b0; start_timeout<=1'b0;
            rd_done<=1'b0; rd_byte<=8'd0; rd_timeout<=1'b0; stop_done<=1'b0;
        end else begin
            start_done<=1'b0; wr_done<=1'b0; rd_done<=1'b0; stop_done<=1'b0;

            case (st)
                S_IDLE: begin
                    if (start_go) begin
                        start_timeout<=1'b0;
                        if (bus_owned) begin
                            // Repeated START after the register-address ACK.
                            //
                            // Keep SCL LOW first and release SDA. The prior
                            // implementation released SCL immediately, only
                            // about two clk_sd cycles after ACK_FALL. That
                            // omitted X-HD's complete SCLL interval and could
                            // make the ADV7511 see a malformed restart or a
                            // STOP/START pair before the register pointer was
                            // accepted.
                            scl_oe<=1'b1;
                            sda_oe<=1'b0;
                            pc<=16'd0;
                            stretch_ctr<=32'd0;
                            rstart_phase<=2'd0;
                            st<=S_RSTART_WAIT;
                        end else if (!WAIT_BUS_FREE) begin
                            sda_oe<=1'b1; pc<=16'd0; st<=S_START_A;
                        end else begin
                            stretch_ctr<=32'd0; idle_high_ctr<=32'd0;
                            st<=S_WAIT_IDLE;
                        end
                    end
                    else if (wr_go) begin
                        wr_timeout<=1'b0; wr_ack<=1'b0; wr_arb_lost<=1'b0;
                        sh<=wr_byte; bit_ix<=3'd0; cur_is_write<=1'b1; timed_out<=1'b0;
                        st<=S_BIT_SETUP;
                    end
                    else if (rd_go) begin
                        rd_timeout<=1'b0;
                        bit_ix<=3'd0; cur_is_write<=1'b0; timed_out<=1'b0;
                        st<=S_BIT_SETUP;
                    end
                    else if (stop_go) begin
                        sda_oe<=1'b1; scl_oe<=1'b1; pc<=16'd0; st<=S_STOP_A;
                    end
                end

                // ---- bus-idle check + fresh START ----
                // Previously had NO timeout at all -- a genuine hard stop if
                // the bus never read idle. On the private ADV bus this is not
                // expected (EOS is the sole master), but the bound is retained
                // as a safety net; it also mattered historically, back when
                // this master shared the Xbox SMBus and could be started
                // before the console's boot/POST-time SMBus activity settled.
                // Now bounded by IDLE_WAIT_TIMEOUT, reported via
                // start_timeout so the caller's existing retry/timeout
                // handling picks this up the same way it already handles
                // every other kind of failure -- not a new failure mode to
                // special-case, just closing the one gap that had none.
                S_WAIT_IDLE: begin
                    // Wait for a short, protocol-scale bus-free interval.
                    //
                    // IMPORTANT: stretch_ctr is a TOTAL elapsed-time counter
                    // for this state. The previous implementation reset it
                    // whenever the bus was briefly idle. That livelocked back
                    // when this master shared a periodically active Xbox
                    // SMBus: the bus could be idle too briefly to satisfy the
                    // old 1ms quiet-window requirement, while each short idle
                    // gap also reset the timeout, so neither counter could
                    // ever finish. The private ADV bus never sees that
                    // contention, but the total-elapsed counter is kept.
                    if (stretch_ctr >= IDLE_WAIT_TIMEOUT-1) begin
                        sda_oe<=1'b0; scl_oe<=1'b0; bus_owned<=1'b0;
                        idle_high_ctr<=32'd0;
                        start_done<=1'b1; start_timeout<=1'b1; st<=S_IDLE;
                    end else begin
                        stretch_ctr<=stretch_ctr+32'd1;
                        if (sda_bus && scl_bus) begin
                            if (idle_high_ctr >= BUS_FREE_CYCLES-1) begin
                                // Generate START: SDA falls while SCL remains high.
                                sda_oe<=1'b1; pc<=16'd0;
                                idle_high_ctr<=32'd0; st<=S_START_A;
                            end else begin
                                idle_high_ctr<=idle_high_ctr+32'd1;
                            end
                        end else begin
                            idle_high_ctr<=32'd0;
                        end
                    end
                end
                S_RSTART_WAIT: begin
                    case (rstart_phase)
                        2'd0: begin
                            // Phase 0: ACK falling edge -> full tLOW.
                            //
                            // SDA is released while SCL remains actively low.
                            // Wait the complete X-HD SCLL period (0x5B + 1
                            // ticks at 8 MHz = 11.50 us). At the end, also
                            // require SDA to have genuinely returned high
                            // before raising SCL.
                            scl_oe<=1'b1;
                            sda_oe<=1'b0;

                            if (pc < SCL_LOW_CYCLES-1) begin
                                pc<=pc+16'd1;
                            end else if (!sda_bus) begin
                                stretch_ctr<=stretch_ctr+32'd1;
                                if (stretch_ctr >= STRETCH_TIMEOUT) begin
                                    sda_oe<=1'b0; scl_oe<=1'b0;
                                    bus_owned<=1'b0;
                                    start_done<=1'b1;
                                    start_timeout<=1'b1;
                                    st<=S_IDLE;
                                end
                            end else begin
                                // SDA is high while SCL is still low. Now
                                // release SCL and begin the high/setup phase.
                                scl_oe<=1'b0;
                                pc<=16'd0;
                                stretch_ctr<=32'd0;
                                rstart_phase<=2'd1;
                            end
                        end

                        2'd1: begin
                            // Phase 1: wait for the physical SCL line to rise,
                            // then hold the complete X-HD SCLH interval
                            // (0x3D + 1 ticks at 8 MHz = 7.75 us).
                            sda_oe<=1'b0;

                            if (HONOR_CLOCK_STRETCH && !scl_bus) begin
                                pc<=16'd0;
                                stretch_ctr<=stretch_ctr+32'd1;
                                if (stretch_ctr >= STRETCH_TIMEOUT) begin
                                    sda_oe<=1'b0; scl_oe<=1'b0;
                                    bus_owned<=1'b0;
                                    start_done<=1'b1;
                                    start_timeout<=1'b1;
                                    st<=S_IDLE;
                                end
                            end else if (pc < SCL_HIGH_CYCLES-1) begin
                                pc<=pc+16'd1;
                            end else begin
                                pc<=16'd0;
                                stretch_ctr<=32'd0;
                                st<=S_RSTART_HOLD;
                            end
                        end

                        default: begin
                            rstart_phase<=2'd0;
                            pc<=16'd0;
                        end
                    endcase
                end
                S_RSTART_HOLD: begin
                    // Generate the repeated START edge only after both the
                    // complete ACK-to-restart tLOW and SCL-high setup phases:
                    // SDA high -> low while the physical SCL line is high.
                    sda_oe<=1'b1;
                    pc<=pc+16'd1;
                    if (pc >= SCL_HIGH_CYCLES-1) begin
                        pc<=16'd0;
                        scl_oe<=1'b1;
                        st<=S_START_B;
                    end
                end
                S_START_A: begin
                    // Fresh START already pulled SDA low while SCL was high.
                    pc<=pc+16'd1;
                    if (pc >= SCL_HIGH_CYCLES-1) begin
                        pc<=16'd0; scl_oe<=1'b1; st<=S_START_B;
                    end
                end
                S_START_B: begin
                    pc<=pc+16'd1;
                    if (pc >= SCL_LOW_CYCLES-1) begin
                        start_done<=1'b1; start_timeout<=1'b0;
                        bus_owned<=1'b1; pc<=16'd0; st<=S_IDLE;
                    end
                end

                // ---- one bit, shared by write and read ----
                // write: SDA carries sh[7] (MSB first, shifted after);  read: SDA released, sampled at HIGH
                S_BIT_SETUP: begin
                    sda_oe <= cur_is_write ? ~sh[7] : 1'b0;
                    pc<=16'd0; st<=S_BIT_RISE;
                end
                S_BIT_RISE: begin
                    // hold SCL low for one setup period before releasing, so
                    // SDA is stable before the rising edge
                    if (pc < SCL_LOW_CYCLES-1) begin
                        pc<=pc+16'd1;
                    end else begin
                        scl_oe<=1'b0; pc<=16'd0;
                        stretch_ctr<=32'd0; st<=S_BIT_HIGH;
                    end
                end
                S_BIT_HIGH: begin
                    if (!HONOR_CLOCK_STRETCH) begin
                        if (pc < SCL_HIGH_CYCLES-1) begin
                            pc<=pc+16'd1;
                        end else begin
                            if (!cur_is_write)
                                sh<={sh[6:0],sda_bus};
                            pc<=16'd0; st<=S_BIT_FALL;
                        end
                    end else if (!scl_bus) begin
                        // Wait for the physical line, not merely our released
                        // output. Reset the high-period counter while stretched.
                        pc<=16'd0;
                        stretch_ctr<=stretch_ctr+32'd1;
                        if (stretch_ctr >= STRETCH_TIMEOUT) begin
                            timed_out<=1'b1; scl_oe<=1'b0; sda_oe<=1'b0;
                            bus_owned<=1'b0; st<=S_IDLE;
                            if (cur_is_write) begin
                                wr_done<=1'b1; wr_timeout<=1'b1;
                                wr_ack<=1'b0; wr_arb_lost<=1'b0;
                            end else begin
                                rd_done<=1'b1; rd_timeout<=1'b1;
                                rd_byte<=sh;
                            end
                        end
                    end else if (!SINGLE_MASTER && cur_is_write &&
                                 sh[7] && !sda_bus) begin
                        sda_oe<=1'b0; scl_oe<=1'b0; bus_owned<=1'b0;
                        wr_done<=1'b1; wr_ack<=1'b0; wr_timeout<=1'b1;
                        wr_arb_lost<=1'b1; st<=S_IDLE;
                    end else if (pc < SCL_HIGH_CYCLES-1) begin
                        // The previous implementation sampled SDA on the first
                        // synchronized SCL-high observation. Hold the complete
                        // high period and sample at its end, like the STM I2C
                        // peripheral.
                        pc<=pc+16'd1;
                    end else begin
                        if (!cur_is_write)
                            sh<={sh[6:0],sda_bus};
                        pc<=16'd0; st<=S_BIT_FALL;
                    end
                end
                S_BIT_FALL: begin
                    // S_BIT_HIGH already held the complete high period and
                    // sampled at its end. Pull SCL low immediately; the next
                    // S_BIT_RISE/S_ACK_RISE state supplies the complete low
                    // period.
                    scl_oe<=1'b1;
                    sh<=cur_is_write ? (sh<<1) : sh;
                    pc<=16'd0;
                    if (bit_ix==3'd7)
                        st<=S_ACK_SETUP;
                    else begin
                        bit_ix<=bit_ix+3'd1;
                        st<=S_BIT_SETUP;
                    end
                end

                // ---- ACK/NACK bit, shared by write (sample slave's ACK)
                // and read (drive our own ACK/NACK) ----
                S_ACK_SETUP: begin
                    sda_oe <= cur_is_write ? 1'b0 : rd_send_ack;
                    pc<=16'd0; st<=S_ACK_RISE;
                end
                S_ACK_RISE: begin
                    if (pc < SCL_LOW_CYCLES-1) begin
                        pc<=pc+16'd1;
                    end else begin
                        scl_oe<=1'b0; pc<=16'd0;
                        stretch_ctr<=32'd0; st<=S_ACK_HIGH;
                    end
                end
                S_ACK_HIGH: begin
                    if (!HONOR_CLOCK_STRETCH) begin
                        if (pc < SCL_HIGH_CYCLES-1) begin
                            pc<=pc+16'd1;
                        end else begin
                            if (cur_is_write)
                                wr_ack<=~sda_bus;
                            pc<=16'd0; st<=S_ACK_FALL;
                        end
                    end else if (!scl_bus) begin
                        pc<=16'd0;
                        stretch_ctr<=stretch_ctr+32'd1;
                        if (stretch_ctr >= STRETCH_TIMEOUT) begin
                            timed_out<=1'b1; scl_oe<=1'b0; sda_oe<=1'b0;
                            bus_owned<=1'b0; st<=S_IDLE;
                            if (cur_is_write) begin
                                wr_done<=1'b1; wr_timeout<=1'b1;
                                wr_ack<=1'b0; wr_arb_lost<=1'b0;
                            end else begin
                                rd_done<=1'b1; rd_timeout<=1'b1;
                                rd_byte<=sh;
                            end
                        end
                    end else if (pc < SCL_HIGH_CYCLES-1) begin
                        pc<=pc+16'd1;
                    end else begin
                        if (cur_is_write)
                            wr_ack<=~sda_bus;
                        pc<=16'd0; st<=S_ACK_FALL;
                    end
                end
                S_ACK_FALL: begin
                    // S_ACK_HIGH already held the complete high period. Pull
                    // SCL low immediately and release SDA. Releasing SDA while
                    // SCL is low is required before a repeated START.
                    scl_oe<=1'b1; sda_oe<=1'b0; pc<=16'd0; st<=S_IDLE;
                    if (cur_is_write) begin
                        wr_done<=1'b1; wr_timeout<=1'b0;
                        wr_arb_lost<=1'b0;
                    end else begin
                        rd_done<=1'b1; rd_byte<=sh; rd_timeout<=1'b0;
                    end
                end

                // ---- STOP: SCL low+SDA low (already true entering here) -> SCL high -> SDA high ----
                S_STOP_A: begin
                    pc<=pc+16'd1;
                    if (pc >= SCL_LOW_CYCLES-1) begin
                        pc<=16'd0; stretch_ctr<=32'd0;
                        scl_oe<=1'b0; st<=S_STOP_B;
                    end
                end
                S_STOP_B: begin
                    // wait for SCL to genuinely read high before releasing SDA.
                    // If the bus remains wedged, release our outputs and return
                    // completion so the caller can take its bounded failure path.
                    if (!HONOR_CLOCK_STRETCH) begin
                        // fixed-rate STOP: SCL is high once released.
                        // Hold one period, then release SDA = STOP. No readback.
                        pc<=pc+16'd1;
                        if (pc >= SCL_HIGH_CYCLES-1) begin
                            sda_oe<=1'b0; stop_done<=1'b1; bus_owned<=1'b0; st<=S_IDLE; pc<=16'd0;
                        end
                    end else if (scl_bus) begin
                        pc<=pc+16'd1;
                        if (pc >= SCL_HIGH_CYCLES-1) begin
                            sda_oe<=1'b0; stop_done<=1'b1; bus_owned<=1'b0; st<=S_IDLE; pc<=16'd0;
                        end
                    end else begin
                        stretch_ctr<=stretch_ctr+32'd1;
                        if (stretch_ctr >= STRETCH_TIMEOUT) begin
                            sda_oe<=1'b0; scl_oe<=1'b0; stop_done<=1'b1;
                            bus_owned<=1'b0; st<=S_IDLE; pc<=16'd0;
                        end
                    end
                end

                default: st<=S_IDLE;
            endcase
        end
    end
endmodule