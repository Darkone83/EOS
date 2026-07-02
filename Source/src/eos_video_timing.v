// ---------------------------------------------------------------------
// eos_video_timing.v -- video timing generator (DE / HS / VS)
//
// Stripped from the Gowin/Sipeed DVI sample "testpattern" (Caojie, 2009):
// all test-pattern RGB generation (color bar / net grid / gray / single
// color) has been removed. Only the DE/HS/VS timing remains -- the counters
// and the N-deep delay pipeline that keeps the three mutually aligned. This
// feeds eos_text_render -> DVI_TX_Top. Behaviour of the surviving timing
// outputs is bit-identical to the original module.
// ---------------------------------------------------------------------

module eos_video_timing
(
    input              I_pxl_clk  ,// pixel clock
    input              I_rst_n    ,// low active
    input      [11:0]  I_h_total  ,// hor total time
    input      [11:0]  I_h_sync   ,// hor sync time
    input      [11:0]  I_h_bporch ,// hor back porch
    input      [11:0]  I_h_res    ,// hor resolution
    input      [11:0]  I_v_total  ,// ver total time
    input      [11:0]  I_v_sync   ,// ver sync time
    input      [11:0]  I_v_bporch ,// ver back porch
    input      [11:0]  I_v_res    ,// ver resolution
    input              I_hs_pol   ,// HS polarity
    input              I_vs_pol   ,// VS polarity
    output             O_de       ,
    output reg         O_hs       ,
    output reg         O_vs
);

localparam N = 5; // delay N clocks (keeps DE/HS/VS mutually aligned)

reg  [11:0]  V_cnt;
reg  [11:0]  H_cnt;

wire         Pout_de_w;
wire         Pout_hs_w;
wire         Pout_vs_w;

reg  [N-1:0] Pout_de_dn;
reg  [N-1:0] Pout_hs_dn;
reg  [N-1:0] Pout_vs_dn;

//==============================================================================
// Generate HS, VS, DE
always @(posedge I_pxl_clk or negedge I_rst_n)
begin
    if(!I_rst_n)
        V_cnt <= 12'd0;
    else begin
        if((V_cnt >= (I_v_total-1'b1)) && (H_cnt >= (I_h_total-1'b1)))
            V_cnt <= 12'd0;
        else if(H_cnt >= (I_h_total-1'b1))
            V_cnt <= V_cnt + 1'b1;
        else
            V_cnt <= V_cnt;
    end
end

always @(posedge I_pxl_clk or negedge I_rst_n)
begin
    if(!I_rst_n)
        H_cnt <= 12'd0;
    else if(H_cnt >= (I_h_total-1'b1))
        H_cnt <= 12'd0;
    else
        H_cnt <= H_cnt + 1'b1;
end

assign Pout_de_w = ((H_cnt>=(I_h_sync+I_h_bporch))&(H_cnt<=(I_h_sync+I_h_bporch+I_h_res-1'b1))) &
                   ((V_cnt>=(I_v_sync+I_v_bporch))&(V_cnt<=(I_v_sync+I_v_bporch+I_v_res-1'b1))) ;
assign Pout_hs_w = ~((H_cnt>=12'd0) & (H_cnt<=(I_h_sync-1'b1))) ;
assign Pout_vs_w = ~((V_cnt>=12'd0) & (V_cnt<=(I_v_sync-1'b1))) ;

always @(posedge I_pxl_clk or negedge I_rst_n)
begin
    if(!I_rst_n) begin
        Pout_de_dn <= {N{1'b0}};
        Pout_hs_dn <= {N{1'b1}};
        Pout_vs_dn <= {N{1'b1}};
    end else begin
        Pout_de_dn <= {Pout_de_dn[N-2:0],Pout_de_w};
        Pout_hs_dn <= {Pout_hs_dn[N-2:0],Pout_hs_w};
        Pout_vs_dn <= {Pout_vs_dn[N-2:0],Pout_vs_w};
    end
end

assign O_de = Pout_de_dn[4];

always @(posedge I_pxl_clk or negedge I_rst_n)
begin
    if(!I_rst_n) begin
        O_hs <= 1'b1;
        O_vs <= 1'b1;
    end else begin
        O_hs <= I_hs_pol ? ~Pout_hs_dn[3] : Pout_hs_dn[3];
        O_vs <= I_vs_pol ? ~Pout_vs_dn[3] : Pout_vs_dn[3];
    end
end

endmodule