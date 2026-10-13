// Video re-timing of the 360-pixel boards (Pang Pom's, Sky Alert, Last Fortress, Poitto) for a CRT.
//
// The video chip scans a 392 x 263 raster at a 6.0 MHz dot clock (16 clocks of the 96 MHz machine clock per dot; that is what keeps the game's own timing = MAME's).
// A 320-pixel picture leaves 72 dots (12 us) of that line for the blanking, but a 360-pixel picture only 32 dots (5.3 us), with a sync pulse 4 dots from the picture on
// both sides.  A CRT's horizontal flyback needs 9 to 11 us: the picture was clipped at both edges and the monitor's sync / deflection was upset (CRT test of 20261008c: the
// four 360-pixel games had an unstable picture on a Sony monitor, the RT4K coped; with this module the four games are perfect, 20261008d).
//
// Here the line goes through a one-line buffer and comes out at 14 clocks per dot (6.857 MHz, the real boards' 6.667 MHz is 14.4): the same 6272 clocks per line (15.31 kHz, so
// the frame is exactly as long as before), 448 dots of which 360 are the picture: 22 dots front porch, a 32 dot (4.7 us) sync pulse, 34 dots back porch = 12.8 us of blanking
// and the picture 52.5 us wide (a 4:3 tube's width: 52.6 us).  The picture starts DLY clocks after the chip's line did, because it comes out faster than it goes in.
// i_narrow: 12 clocks per dot (8.0 MHz), 522 dots + one held blank dot (6272 = 522 x 12 + 8): the picture is 45 us wide with margins of 3.8 us on both sides, so the tiles at the
// edges of Last Fortress (Mah-Jong) are not lost to a monitor's overscan; sync pulse 4.7 us, 7.0 us before it and 8.6 us after it.
// The vertical sync pulse is passed on (the framework samples it at the start of the line's horizontal sync anyway, arcade_video.v).
//
// i_wide = 0 passes the signals through untouched.
`default_nettype none
module metro_vout (
    input  logic        clk,
    input  logic        i_wide,
    input  logic        i_narrow,
    input  logic        i_w384,           // the picture is 384 dots wide (Doukyuusei Special): always 12 clocks a dot, 48 us, whatever i_narrow says
    input  logic        i_ce, i_hblank, i_vblank, i_hs, i_vs,
    input  logic [14:0] i_rgb,
    output logic        o_ce, o_hblank, o_vblank, o_hs, o_vs,
    output logic [14:0] o_rgb,
    output logic [4:0]  o_pdot            // clocks of the machine clock per dot of the output: 16 untouched, 14 re-timed (12 when n12)
);
    // the timings (dots of the output line); DLY = clocks from the start of the chip's line to the first dot of the picture: more than ACT * (16 - PDIV)
    wire         n12  = i_narrow || i_w384;                 // 12 clocks a dot (8.0 MHz): 522 dots + one held blank dot (6272 = 522 x 12 + 8)
    wire  [9:0]  act  = i_w384 ? 10'd384 : 10'd360;         // dots of picture
    wire  [3:0]  pdiv = n12 ? 4'd12 : 4'd14;
    wire  [9:0]  tot  = n12 ? 10'd522 : 10'd448;            // dots per line (the 12-clock line then holds one blank dot for the last 8 clocks)
    wire  [9:0]  hs0  = i_w384 ? 10'd429 : i_narrow ? 10'd416 : 10'd382;       // first dot of the sync pulse (384: 45 dots of front porch, 37 of sync, 56 of back porch)
    wire  [9:0]  hs1  = i_w384 ? 10'd466 : i_narrow ? 10'd453 : 10'd414;       // first dot after it
    wire  [9:0]  vse  = i_w384 ? 10'd500 : i_narrow ? 10'd490 : 10'd442;       // dot of the line at which the vertical sync level of the next line is taken over (well away from the horizontal sync)
    wire  [12:0] dly  = i_w384 ? 13'd1600 : i_narrow ? 13'd1500 : 13'd800;

    // ---- write side: the chip's picture dots of one line, at its own pace
    (* ramstyle = "M10K, no_rw_check" *) logic [14:0] lram [0:511];
    logic [8:0]  wx;
    logic        hb_q, vb_l, vs_l;
    wire         ln_start = i_ce && hb_q && !i_hblank;     // the first dot of the picture of a line (the chip's blanking is the horizontal one only)

    always_ff @(posedge clk) begin
        if (i_ce) begin
            hb_q <= i_hblank;
            if (i_hblank) wx <= '0;
            else begin
                lram[wx] <= i_rgb;
                wx <= wx + 9'd1;
            end
        end
        if (ln_start) begin
            vb_l <= i_vblank;
            vs_l <= i_vs;
        end
    end

    // ---- timeline: the output line starts DLY clocks after the chip's, then `tot` dots of PDIV clocks
    logic [12:0] dc;
    logic [3:0]  pc;
    logic [9:0]  slot;
    always_ff @(posedge clk) begin
        if (ln_start) dc <= '0;
        else if (dc != 13'h1FFF) dc <= dc + 13'd1;

        if (dc == dly - 13'd1) begin
            pc   <= '0;
            slot <= '0;
        end else if (pc == pdiv - 4'd1) begin
            pc <= '0;
            if (slot == tot - 10'd1)  slot <= n12 ? tot : 10'd0;
            else if (slot != tot)     slot <= slot + 10'd1;
        end else
            pc <= pc + 4'd1;
    end

    // ---- read side
    logic [14:0] rd_q;
    logic        vb_o, vs_o;
    logic        w_ce, w_hblank, w_hs;
    logic [14:0] w_rgb;
    always_ff @(posedge clk) begin
        rd_q <= lram[slot[8:0]];
        w_ce <= (pc == 4'd1);
        if (pc == 4'd1) begin
            w_hblank <= (slot >= act);
            w_hs     <= (slot >= hs0) && (slot < hs1);
            w_rgb    <= (slot < act) ? rd_q : 15'd0;
            if (slot == 10'd0)  vb_o <= vb_l;
            if (slot == vse)    vs_o <= vs_l;
        end
    end

    assign o_ce     = i_wide ? w_ce     : i_ce;
    assign o_hblank = i_wide ? w_hblank : i_hblank;
    assign o_vblank = i_wide ? vb_o     : i_vblank;
    assign o_hs     = i_wide ? w_hs     : i_hs;
    assign o_vs     = i_wide ? vs_o     : i_vs;
    assign o_rgb    = i_wide ? w_rgb    : i_rgb;
    assign o_pdot   = i_wide ? {1'b0, pdiv} : 5'd16;

endmodule
`default_nettype wire
