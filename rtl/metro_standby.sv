// A blank raster of the video chip's own timing (16 clocks a dot, 392 dots a line, 263 lines: 15.3 kHz / 58.2 Hz, 304 x 224 picture) for the time the machine is held in reset
// (the ROM image streaming in, the OSD's Reset).  The MiSTer framework draws its native "Loading" progress pop-up as part of the OSD, which needs a video signal with sync to sit
// on; the core's own raster does not run while the video chip is in reset, so without this the screen is dead for the five seconds a 20 - 36 MB image takes.
`default_nettype none
module metro_standby (
    input  wire clk,
    output reg  o_ce,
    output reg  o_hblank,
    output reg  o_vblank,
    output reg  o_hs,
    output reg  o_vs
);
    reg [3:0] dv = 4'd0;
    reg [8:0] hc = 9'd0, vc = 9'd0;
    initial begin o_ce = 1'b0; o_hblank = 1'b1; o_vblank = 1'b1; o_hs = 1'b0; o_vs = 1'b0; end
    always @(posedge clk) begin
        o_ce <= 1'b0;
        dv   <= dv + 4'd1;
        if (dv == 4'd15) begin
            o_ce <= 1'b1;
            if (hc == 9'd391) begin
                hc <= 9'd0;
                vc <= (vc == 9'd262) ? 9'd0 : vc + 9'd1;
            end else
                hc <= hc + 9'd1;
            o_hblank <= (hc >= 9'd303) && (hc != 9'd391);      // registered with the next dot: the picture is dots 0 - 303
            o_hs     <= (hc >= 9'd319) && (hc < 9'd351);
            o_vblank <= (vc >= 9'd224);
            o_vs     <= (vc >= 9'd232) && (vc < 9'd235);
        end
    end
endmodule
`default_nettype wire
