// Hardware test overlay (family F): the plane engine's and the video chip's measurements of the last frame, drawn as hexadecimal text over the picture (OSD "Debug overlay").
// Observation only: nothing of the machine reads this module.  Each row is "<id>:AAAA BBBB CCCC", the ids and what they mean are in docs/hardware.md (section "Debug overlay").
//
//   i_st[255:0]    the video chip's 16 words (S0 .. S15), i_st[511:256] the plane's 16 words (R0 .. R15), valid at the clock of i_frame (a pulse once a frame)
//   i_mode         0 off (the maxima are cleared), 1 all rows with 8 x 8 characters, 2 rows 1 .. 6 with 16 x 16 characters
`default_nettype none
module metro_hud (
    input  logic         clk,
    input  logic   [1:0] i_mode,
    input  logic         i_ce,
    input  logic         i_hblank,
    input  logic         i_vblank,
    input  logic  [14:0] i_rgb,
    input  logic         i_frame,
    input  logic [511:0] i_st,
    input  logic  [95:0] i_sdr,           // the SDRAM controller's {busy / 64, graphics, samples, shared RAM, program ROM, download} of the last 2^21 clocks
    output logic  [14:0] o_rgb
);
    // ------------------------------------------------------------ the frame's values and the running maxima
    logic [255:0] s_q, r_q;
    logic [15:0] mx_s0 = 16'd0, mx_s4 = 16'd0, mx_r8 = 16'd0, mx_r1 = 16'd0, mx_r2 = 16'd0, mx_r3 = 16'd0, mn_s8 = 16'hFFFF, stale_frames = 16'd0, frames = 16'd0;
    logic        on_d, fr_d;
    wire  [15:0] in_s0 = i_st[0 +: 16], in_s4 = i_st[64 +: 16], in_s8 = i_st[128 +: 16];
    wire  [15:0] in_r1 = i_st[256 + 16 +: 16], in_r2 = i_st[256 + 32 +: 16], in_r3 = i_st[256 + 48 +: 16], in_r8 = i_st[256 + 128 +: 16];
    always_ff @(posedge clk) begin
        on_d <= (i_mode != 2'd0);
        fr_d <= i_frame;                      // the words are registered at the clock of i_frame: they are there one clock later
        if (i_mode == 2'd0) begin
            mx_s0 <= 16'd0; mx_s4 <= 16'd0; mx_r8 <= 16'd0; mx_r1 <= 16'd0; mx_r2 <= 16'd0; mx_r3 <= 16'd0; mn_s8 <= 16'hFFFF; stale_frames <= 16'd0; frames <= 16'd0;
        end else if (fr_d) begin
            s_q <= i_st[255:0];
            r_q <= i_st[511:256];
            frames <= frames + 16'd1;
            if (in_s0 != 16'd0 && stale_frames != 16'hFFFF) stale_frames <= stale_frames + 16'd1;
            if (in_s0 > mx_s0) mx_s0 <= in_s0;
            if (in_s4 > mx_s4) mx_s4 <= in_s4;
            if (in_r8 > mx_r8) mx_r8 <= in_r8;
            if (in_r1 > mx_r1) mx_r1 <= in_r1;
            if (in_r2 > mx_r2) mx_r2 <= in_r2;
            if (in_r3 > mx_r3) mx_r3 <= in_r3;
            if (frames > 16'd64 && in_s8 < mn_s8) mn_s8 <= in_s8;
        end
    end

    function automatic logic [15:0] S(input int i); return s_q[16*i +: 16]; endfunction
    function automatic logic [15:0] R(input int i); return r_q[16*i +: 16]; endfunction

    // the rows: 3 values each, row-major in one flat vector (index 3 * row + column)
    logic [15*3*16-1:0] vv;
    always_comb begin
        vv = '0;
        vv[16*(3*0+0) +: 16] = S(0);  vv[16*(3*0+1) +: 16] = mx_s0;  vv[16*(3*0+2) +: 16] = stale_frames;
        vv[16*(3*1+0) +: 16] = S(1);  vv[16*(3*1+1) +: 16] = S(2);   vv[16*(3*1+2) +: 16] = frames;
        vv[16*(3*2+0) +: 16] = S(4);  vv[16*(3*2+1) +: 16] = mx_s4;  vv[16*(3*2+2) +: 16] = S(5);
        vv[16*(3*3+0) +: 16] = S(6);  vv[16*(3*3+1) +: 16] = S(7);   vv[16*(3*3+2) +: 16] = S(3);
        vv[16*(3*4+0) +: 16] = S(8);  vv[16*(3*4+1) +: 16] = mn_s8;  vv[16*(3*4+2) +: 16] = S(9);
        vv[16*(3*5+0) +: 16] = R(8);  vv[16*(3*5+1) +: 16] = mx_r8;  vv[16*(3*5+2) +: 16] = R(9);
        vv[16*(3*6+0) +: 16] = R(1);  vv[16*(3*6+1) +: 16] = mx_r1;  vv[16*(3*6+2) +: 16] = R(0);
        vv[16*(3*7+0) +: 16] = R(2);  vv[16*(3*7+1) +: 16] = mx_r2;  vv[16*(3*7+2) +: 16] = R(3);
        vv[16*(3*8+0) +: 16] = R(4);  vv[16*(3*8+1) +: 16] = R(5);   vv[16*(3*8+2) +: 16] = R(6);
        vv[16*(3*9+0) +: 16] = R(7);  vv[16*(3*9+1) +: 16] = mx_r3;  vv[16*(3*9+2) +: 16] = S(14);
        vv[16*(3*10+0) +: 16] = S(10); vv[16*(3*10+1) +: 16] = S(11); vv[16*(3*10+2) +: 16] = S(12);
        vv[16*(3*11+0) +: 16] = R(10); vv[16*(3*11+1) +: 16] = R(11); vv[16*(3*11+2) +: 16] = S(13);
        vv[16*(3*12+0) +: 16] = R(12); vv[16*(3*12+1) +: 16] = R(13); vv[16*(3*12+2) +: 16] = R(14);
        vv[16*(3*13+0) +: 16] = i_sdr[31:16];                     // program ROM accesses (the 68000's and the Z80's) in 21.8 ms
        vv[16*(3*13+1) +: 16] = i_sdr[63:48];                     // YM2610 sample accesses
        vv[16*(3*13+2) +: 16] = i_sdr[47:32];                     // tile map RAM accesses (the 68000's)
        vv[16*(3*14+0) +: 16] = S(15);
        vv[16*(3*14+1) +: 16] = i_sdr[79:64];                     // graphics accesses (bursts)
        vv[16*(3*14+2) +: 16] = i_sdr[95:80];                     // the controller's busy clocks / 64 of the 32,768 of that window
    end

    // ------------------------------------------------------------ the raster position
    logic [9:0] x, y;
    logic       hb_d;
    always_ff @(posedge clk) if (i_ce) begin
        hb_d <= i_hblank;
        if (i_hblank) x <= 10'd0; else x <= x + 10'd1;
        if (i_vblank) y <= 10'd0;
        else if (!hb_d && i_hblank) y <= y + 10'd1;
    end

    // ------------------------------------------------------------ the character at the pixel (pipelined: x and y change once per i_ce, a dot is 14+ clocks)
    wire        big  = (i_mode == 2'd2);
    wire  [5:0] col  = big ? {2'd0, x[9:4]} : x[9:3];            // character column
    wire  [5:0] row  = big ? {2'd0, y[9:4]} : y[9:3];
    wire  [2:0] gx   = big ? x[3:1] : x[2:0];
    wire  [2:0] gy   = big ? y[3:1] : y[2:0];
    wire  [5:0] nrow = big ? 6'd6 : 6'd15;
    wire        inbox = (col < 6'd16) && (row < nrow);

    function automatic logic [3:0] pick_nib(input logic [15:0] w, input logic [1:0] k);
        case (k)
            2'd0: return w[15:12];
            2'd1: return w[11:8];
            2'd2: return w[7:4];
            default: return w[3:0];
        endcase
    endfunction
    function automatic logic [4:0] glyph(input logic [4:0] ch, input logic [2:0] ry);      // ch: 0..15 hex digit, 16 ':'
        logic [34:0] g;
        case (ch)
            5'h0: g = {5'b01110, 5'b10001, 5'b10011, 5'b10101, 5'b11001, 5'b10001, 5'b01110};
            5'h1: g = {5'b00100, 5'b01100, 5'b00100, 5'b00100, 5'b00100, 5'b00100, 5'b01110};
            5'h2: g = {5'b01110, 5'b10001, 5'b00001, 5'b00010, 5'b00100, 5'b01000, 5'b11111};
            5'h3: g = {5'b11111, 5'b00010, 5'b00100, 5'b00010, 5'b00001, 5'b10001, 5'b01110};
            5'h4: g = {5'b00010, 5'b00110, 5'b01010, 5'b10010, 5'b11111, 5'b00010, 5'b00010};
            5'h5: g = {5'b11111, 5'b10000, 5'b11110, 5'b00001, 5'b00001, 5'b10001, 5'b01110};
            5'h6: g = {5'b00110, 5'b01000, 5'b10000, 5'b11110, 5'b10001, 5'b10001, 5'b01110};
            5'h7: g = {5'b11111, 5'b00001, 5'b00010, 5'b00100, 5'b01000, 5'b01000, 5'b01000};
            5'h8: g = {5'b01110, 5'b10001, 5'b10001, 5'b01110, 5'b10001, 5'b10001, 5'b01110};
            5'h9: g = {5'b01110, 5'b10001, 5'b10001, 5'b01111, 5'b00001, 5'b00010, 5'b01100};
            5'hA: g = {5'b01110, 5'b10001, 5'b10001, 5'b11111, 5'b10001, 5'b10001, 5'b10001};
            5'hB: g = {5'b11110, 5'b10001, 5'b10001, 5'b11110, 5'b10001, 5'b10001, 5'b11110};
            5'hC: g = {5'b01110, 5'b10001, 5'b10000, 5'b10000, 5'b10000, 5'b10001, 5'b01110};
            5'hD: g = {5'b11110, 5'b10001, 5'b10001, 5'b10001, 5'b10001, 5'b10001, 5'b11110};
            5'hE: g = {5'b11111, 5'b10000, 5'b10000, 5'b11110, 5'b10000, 5'b10000, 5'b11111};
            5'hF: g = {5'b11111, 5'b10000, 5'b10000, 5'b11110, 5'b10000, 5'b10000, 5'b10000};
            5'h10: g = {5'b00000, 5'b00100, 5'b00100, 5'b00000, 5'b00100, 5'b00100, 5'b00000};
            default: g = 35'd0;
        endcase
        case (ry)
            3'd0: return g[34:30];
            3'd1: return g[29:25];
            3'd2: return g[24:20];
            3'd3: return g[19:15];
            3'd4: return g[14:10];
            3'd5: return g[9:5];
            3'd6: return g[4:0];
            default: return 5'd0;
        endcase
    endfunction

    logic [4:0]  ch_q;
    logic        blank_q;
    logic [4:0]  gl_q;
    logic        pix_q;
    logic        in_q;
    always_ff @(posedge clk) begin
        logic [15:0] w;
        logic [1:0]  vi;
        in_q <= inbox;
        // stage 1: which character
        blank_q <= 1'b0;
        ch_q    <= 5'h10;
        if (col == 6'd0) begin
            ch_q <= 5'(row + 6'd1);                                    // the row's id: 1 .. 9, A .. E
        end else if (col == 6'd1) begin
            ch_q <= 5'h10;
        end else if (col == 6'd6 || col == 6'd11) begin
            blank_q <= 1'b1;
        end else begin
            vi = (col < 6'd6) ? 2'd0 : (col < 6'd11) ? 2'd1 : 2'd2;
            w  = vv[16*(3*row[3:0] + 6'(vi)) +: 16];
            ch_q <= {1'b0, pick_nib(w, (col < 6'd6) ? 2'(col - 6'd2) : (col < 6'd11) ? 2'(col - 6'd7) : 2'(col - 6'd12))};
        end
        // stage 2: the glyph row
        gl_q <= blank_q ? 5'd0 : glyph(ch_q, gy);
        // stage 3: the dot (5 columns of the glyph, a gap)
        pix_q <= (gx < 3'd5) && gl_q[3'd4 - gx];
    end

    // combinational: the downstream stage samples the pixel and the blanking at the same i_ce edge (x, y are those of the pixel before that edge)
    assign o_rgb = (on_d && in_q) ? (pix_q ? 15'h7FFF : 15'h0000) : i_rgb;
endmodule
`default_nettype wire
