// eos_ws2812.v -- Tang Nano 20K onboard WS2812 driver.
// Input color is GRB order: {G[7:0], R[7:0], B[7:0]}.
//
// Conservative timing for debug:
// - BIT period: 34 ticks at 27MHz ~= 1.259us
// - T0H: 11 ticks ~= 407ns
// - T1H: 21 ticks ~= 778ns
// - Reset/latch low: ~300us
module eos_ws2812 #(
    parameter CLK_HZ = 27_000_000
)(
    input  wire        clk,
    input  wire        rstn,
    input  wire [23:0] grb,
    output reg         ws_out
);

    localparam integer BIT_TICKS   = 34;
    localparam integer T0H_TICKS   = 11;
    localparam integer T1H_TICKS   = 21;
    localparam integer RESET_TICKS = 8100;

    localparam [1:0] S_RESET = 2'd0;
    localparam [1:0] S_SEND  = 2'd1;

    reg [1:0]  state  = S_RESET;
    reg [15:0] tick   = 16'd0;
    reg [4:0]  bitidx = 5'd0;
    reg [23:0] sh     = 24'd0;

    always @(posedge clk or negedge rstn) begin
        if (!rstn) begin
            state  <= S_RESET;
            tick   <= 16'd0;
            bitidx <= 5'd0;
            sh     <= 24'd0;
            ws_out <= 1'b0;
        end else begin
            case (state)

                S_RESET: begin
                    ws_out <= 1'b0;

                    if (tick >= RESET_TICKS[15:0]) begin
                        tick   <= 16'd0;
                        bitidx <= 5'd0;
                        sh     <= grb;
                        state  <= S_SEND;
                    end else begin
                        tick <= tick + 1'b1;
                    end
                end

                S_SEND: begin
                    ws_out <= (tick < (sh[23] ? T1H_TICKS[15:0] : T0H_TICKS[15:0]));

                    if (tick >= BIT_TICKS[15:0] - 1'b1) begin
                        tick <= 16'd0;
                        sh   <= {sh[22:0], 1'b0};

                        if (bitidx == 5'd23) begin
                            bitidx <= 5'd0;
                            state  <= S_RESET;
                        end else begin
                            bitidx <= bitidx + 1'b1;
                        end
                    end else begin
                        tick <= tick + 1'b1;
                    end
                end

                default: begin
                    state  <= S_RESET;
                    tick   <= 16'd0;
                    bitidx <= 5'd0;
                    sh     <= 24'd0;
                    ws_out <= 1'b0;
                end

            endcase
        end
    end

endmodule