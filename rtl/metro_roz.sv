// Konami 053936 ("PSAC2") rotate / zoom plane of Blazing Tornado and Grand Striker 2 (metro.cpp 0.289 family F), drawn as MAME draws it: k053936_device::zoom_draw into
// tilemap_t::draw_roz without wrap-around (blzntrnd_state::screen_update), the I4220's layers and sprites on top of it (the video chip's resolve pass takes this plane's
// pen where nothing else was drawn).  tools/metro_roz.py is the executable specification; MAME's own frames are reproduced by it pixel for pixel.
//
//   plane      2048 x 4096 dots: Grand Striker 2's 16 x 16 tiles, 128 x 256, scanned by tilemap_scan_gstrik2 from the 68000's RAM at 0x400000 (a word = tile << 2 | 2 bits),
//              8 bpp, colour 0xE (palette entry 0xE00 + pen).  Blazing Tornado (i_bt): 8 x 8 tiles, 256 x 512, scanned row by row (word = row * 256 + col), the code is the
//              word & 0x7fff, offsets (-77, -21).
//   simple     (ctrl[7] bit 6 clear) one transform for the frame: start (ctrl 0, 1), per row (2, 3), per dot (4, 5), ctrl[6] bits 14 / 6: x256
//   super_m      (bit 6 set) a start and a dot step per row from the line RAM (4 words a row at (row - YOFF) & 0x1FF), ctrl[6] bits 15 / 7: x256
//   32 bit modular like MAME's u32; a dot whose position is outside the plane is not drawn (the video chip's background pen shows).
//
// THE ENGINE (v3, 20261011d2).  v1 fetched a whole tile at every tile change; v2 (a walker, 32 slots of tile rows, a dot queue and a painter) fetched only the row of the tile
// that was needed but held 32 tile rows: a plane that is turned (Grand Striker 2's pitch seen across, the line RAM's per-dot step is in y: every dot is another row of a tile and
// a picture row has ~130 different {tile, row} lines) missed on nearly every dot, ~300 fetches of ~33 clocks, 10,000 clocks against the 6,272 of a line: from the second row
// on the picture was the background pen (the brown fill after a goal, hardware test of 20261011d; Blazing Tornado's black planes are the same thing when the memory is
// busy).  v3 keeps what the picture needs from one row to the next:
//
//   line cache   128 groups of 64 bytes of the tile ROM (4 rows of a tile of Grand Striker 2, 8 rows = a whole tile of Blazing Tornado's), direct mapped on {tile code, row
//                group}, MLABs; the ROM never changes.  A miss fetches the group in one burst (~52 clocks for 4 or 8 rows, the single row of v2 took 33).
//   map cache    64 windows of 32 words of the tile map RAM, direct mapped on the window number, MLABs; the 68000's writes to the map drop their window (i_inval).
//   walker       one dot at a time: position -> tile (map cache) -> line (line cache; a miss fetches the line through the video chip's graphics stream) -> byte -> the row's
//                line buffer: 4 clocks a dot (7 at a tile change) plus the misses, ~2,400 clocks a row of the turned pitch (v2: 10,000).
`default_nettype none
module metro_roz #(
    parameter int VIS_H = 240,
    parameter int XOFF  = -77,              // k053936 set_offsets(-77, -19) of Grand Striker 2 (Blazing Tornado: -77, -21)
    parameter int YOFF  = -19,
    parameter int VIS_W = 304,
    parameter int AW    = 25,               // width of the graphics stream's byte address (GFX_AW + 1)
    parameter int GG_GS = 1,                // a line miss fetches 2^GG rows of the tile at once: Grand Striker 2 (16 bytes a row)
    parameter int GG_BT = 2                 // Blazing Tornado (8 bytes a row)
) (
    input  logic        clk,
    input  logic        reset,
    input  logic        i_en,
    input  logic        i_bt,               // Blazing Tornado: 8 x 8 tiles, 256 x 512, offsets (-77, -21)
    input  logic        i_frame,            // pulse: a frame starts (row 0 next; the control registers are taken now)
    input  logic [15:0] i_ctrl [16],
    // line RAM (2048 words, registered read)
    output logic [10:0] o_li_addr,
    input  logic [15:0] i_li_q,
    // requests to the video chip's graphics stream, one at a time: o_rq_req is held up until i_rq_ack (and dropped for a clock between two requests); the words come as
    // i_rq_wr / i_rq_idx / i_rq_data (word index 0.. in the request), the last one is accompanied by i_rq_ack
    output logic        o_rq_req,
    output logic [AW-1:0] o_rq_addr,        // byte address in the graphics stream's space
    output logic  [6:0] o_rq_len,           // bytes: 64 (a window of the map RAM), 16 / 8 (a tile row)
    input  logic        i_rq_wr,
    input  logic  [4:0] i_rq_idx,
    input  logic [15:0] i_rq_data,
    input  logic        i_rq_ack,
    input  logic [AW-1:0] i_map_base,       // the tile map RAM's byte address in that space
    input  logic [AW-1:0] i_gfx2_base,      // the tile ROM's
    // the 68000's writes to the tile map RAM (the SDRAM word at i_inval_addr has just been written): the cached window of it is dropped
    input  logic        i_inval,
    input  logic [16:0] i_inval_addr,
    // pacing with the renderer
    input  logic  [8:0] i_rows_used,        // the row the renderer wants next (the plane runs up to six rows ahead of it)
    output logic  [8:0] o_rows_done,        // rows finished (row r is ready when r < o_rows_done)
    output logic        o_par,              // toggles at every i_frame
    // line buffer read, registered (the renderer's resolve pass: bank = row[2:0])
    input  logic  [2:0] i_rd_bank,
    input  logic  [8:0] i_rd_x,
    output logic [11:0] o_pen,
    output logic        o_op,
    // measurements of the last frame (the hardware test overlay, metro_hud.sv): 16 words, published at every i_frame
    output logic [255:0] o_st
);
    localparam int NBANK = 8, STRIDE = 384;

    function automatic logic [11:0] bank_base(input logic [2:0] b);
        return {1'b0, b, 8'd0} + {2'b0, b, 7'd0};             // b * 384
    endfunction
    function automatic logic signed [31:0] s16x(input logic [15:0] v);
        return {{16{v[15]}}, v};
    endfunction
    function automatic logic [5:0] wfold(input logic [11:0] w);
        return w[5:0] ^ w[11:6];
    endfunction

    // ------------------------------------------------------------ line buffers (the renderer reads them)
    logic [8:0]  lbuf [NBANK * STRIDE];                        // {drawn, pen}
    logic [8:0]  lb_q;
    logic [11:0] lb_wa;
    logic        lb_we;
    logic [8:0]  lb_wd;
    always_ff @(posedge clk) begin
        if (lb_we) lbuf[lb_wa] <= lb_wd;
        lb_q <= lbuf[bank_base(i_rd_bank) + 12'(i_rd_x)];
    end
    assign o_pen = {4'hE, lb_q[7:0]};
    assign o_op  = lb_q[8] && i_en;

    // ------------------------------------------------------------ line cache: 512 lines of 8 words (Blazing Tornado: 4 used); tags {valid, 9 bits}
    (* ramstyle = "MLAB" *) logic [15:0] lram [0:4095];
    (* ramstyle = "MLAB" *) logic  [9:0] ltag [0:255];
    logic [15:0] lr_q;
    logic  [9:0] lt_q;
    logic [11:0] lr_wa;
    logic        lr_we;
    logic [15:0] lr_wd;
    logic  [7:0] lt_wa;
    logic  [9:0] lt_wd;
    logic        lt_we;
    logic  [9:0] lidx;                                         // the row of the tile being looked up (registered): {code, row}; the RAMs read it at the clock edge
    logic  [3:0] xin, yin;
    wire   [3:0] gsh   = i_bt ? 4'(GG_BT) : 4'(GG_GS);          // log2 of the rows in a group
    wire   [7:0] gidx  = 8'(lidx >> gsh);                      // the group's tag
    wire  [11:0] lr_ra = i_bt ? {lidx, xin[2:1]} : {lidx[8:0], xin[3:1]};
    always_ff @(posedge clk) begin
        if (lr_we) lram[lr_wa] <= lr_wd;
        lr_q <= lram[lr_ra];
        if (lt_we) ltag[lt_wa] <= lt_wd;
        lt_q <= ltag[gidx];
    end

    // ------------------------------------------------------------ map cache: 64 windows of 32 words
    (* ramstyle = "MLAB" *) logic [15:0] wram [0:2047];
    logic [15:0] wr_q;
    logic [10:0] wr_wa;
    logic        wr_we;
    logic [15:0] wr_wd;
    logic [16:0] moff;                                         // the word offset in the map RAM being looked up (registered)
    logic  [5:0] widx;
    logic [11:0] wid;
    wire  [10:0] wr_ra = {widx, moff[4:0]};
    always_ff @(posedge clk) begin
        if (wr_we) wram[wr_wa] <= wr_wd;
        wr_q <= wram[wr_ra];
    end
    logic [63:0] wvalid;
    logic [11:0] wtag [0:63];

    // ------------------------------------------------------------ walker state
    logic [15:0] c [8];                                        // the control block as it was at the frame start
    logic        super_m;
    logic signed [31:0] incxx, incxy, incyx, incyy;
    logic [31:0] row_sx, row_sy;                               // simple mode: this row's start (<<5 applied)
    logic [31:0] cx, cy, sinc_x, sinc_y;
    logic  [8:0] wrow, wdot;
    logic signed [31:0] t0, t1, mx, my;
    logic [15:0] lw [4];
    logic  [1:0] lk;
    logic        inb;
    logic [16:0] tp, cur_tp;                                   // {row[8:0], col[7:0]} (Grand Striker 2: {0, row[7:0], 0, col[6:0]})
    logic        cur_ok;
    logic [14:0] cur_code;
    logic  [8:0] ltg;

    // tilemap_scan_gstrik2: (col, row) -> word offset in the RAM = ((row & 0x40) >> 6) | (col << 1) | ((row & 0x80) << 1) | ((row & 0x3f) << 9)
    wire [6:0]  t_col  = tp[6:0];
    wire [7:0]  t_row  = tp[15:8];
    wire [16:0] map_off = i_bt ? tp : {2'b00, t_row[5:0], t_row[7], t_col, t_row[6]};     // Blazing Tornado: TILEMAP_SCAN_ROWS, row * 256 + col

    // the group index and tag of a tile code and a row in the tile
    function automatic logic [9:0] f_lidx(input logic [14:0] code, input logic [3:0] y, input logic bt);
        return bt ? {code[6:0], y[2:0]} : {1'b0, code[4:0], y[3:0]};
    endfunction
    function automatic logic [8:0] f_ltg(input logic [14:0] code, input logic bt);
        return bt ? {1'b0, code[14:7]} : {1'b0, code[12:5]};
    endfunction

    typedef enum logic [4:0] {
        S_IDLE, S_PAR0, S_PAR1, S_PAR1X, S_PAR1B, S_PAR2, S_PAR3,
        S_ROW, S_LI0, S_LI1, S_LI2, S_LI2B, S_LI3, S_LI4,
        S_D0, S_D1, S_M0, S_MW, S_MU, S_WIN, S_LW, S_LU, S_LF, S_LF2
    } st_e;
    st_e st;

    // ------------------------------------------------------------ requests (one at a time)
    logic        rq_busy, rq_is_map, drain, rq_done, rq_issued, fill_bad;
    logic  [9:0] rq_lidx;
    logic  [5:0] rq_widx;
    logic [11:0] rq_base;                                      // the group's first word in the line RAM
    logic  [7:0] swp;                                          // clears the line tags while the engine is held in reset

    // ------------------------------------------------------------ measurements (observation only: nothing here feeds the engine)
    logic [15:0] m_win, m_line, m_rlines, m_rlines_max, m_wclk_max, m_lat_max, m_wclk, m_lat;
    logic [23:0] m_wsum, m_psum, m_wwin, m_walloc, m_lat_sum;
    logic        m_lat_open;
    logic [15:0] m_lw2_0, m_lw3_0, m_lw2_m, m_lw3_m, m_lw2_e, m_lw3_e;
    logic [255:0] st_r;
    assign o_st = st_r;
    function automatic logic [15:0] sat16(input logic [23:0] v);
        return (v[23:16] != 8'd0) ? 16'hFFFF : v[15:0];
    endfunction

    wire inval_hits_fill = i_inval && (st == S_WIN) && (wtag[rq_widx] == i_inval_addr[16:5]);

    always_ff @(posedge clk) begin
        logic dot_done, m_rowend;
        dot_done = 1'b0;
        lb_we <= 1'b0;
        lr_we <= 1'b0;
        lt_we <= 1'b0;
        wr_we <= 1'b0;
        rq_done <= 1'b0;
        if (reset || !i_en) begin
            st <= S_IDLE; o_rq_req <= 1'b0; rq_busy <= 1'b0; drain <= 1'b0; rq_issued <= 1'b0; fill_bad <= 1'b0;
            wvalid <= '0;
            o_rows_done <= '0; wrow <= '0; wdot <= '0; o_par <= 1'b0; cur_ok <= 1'b0;
            swp <= swp + 8'd1; lt_we <= 1'b1; lt_wa <= swp; lt_wd <= 10'd0;     // one tag a clock for as long as the engine is held
        end else begin
            // -------------------------------------------------- the fetcher: words into the caches, the end of a request
            if (rq_busy) begin
                if (i_rq_wr && !drain) begin
                    if (rq_is_map) begin wr_we <= 1'b1; wr_wa <= {rq_widx, i_rq_idx[4:0]}; wr_wd <= i_rq_data; end
                    else begin lr_we <= 1'b1; lr_wa <= rq_base + 12'(i_rq_idx); lr_wd <= i_rq_data; end
                end
                if (i_rq_ack) begin
                    rq_busy <= 1'b0; o_rq_req <= 1'b0; drain <= 1'b0;
                    if (!drain) rq_done <= 1'b1;
                end
            end
            // the 68000's write to the tile map: its window leaves the cache, and a fill of it in flight is not to be trusted
            if (i_inval) begin
                if (wvalid[wfold(i_inval_addr[16:5])] && wtag[wfold(i_inval_addr[16:5])] == i_inval_addr[16:5]) wvalid[wfold(i_inval_addr[16:5])] <= 1'b0;
                if (rq_busy && rq_is_map && wtag[rq_widx] == i_inval_addr[16:5]) fill_bad <= 1'b1;
            end

            // -------------------------------------------------- the walker
            case (st)
                S_IDLE: if (wrow < 9'(VIS_H) && wrow < i_rows_used + 9'd6) st <= S_ROW;

                // frame parameters: the steps (with the x256 modes), then the start with the plane's offsets, <<5 as MAME's draw_roz arguments
                S_PAR0: begin
                    incxx <= c[6][6]  ? (s16x(c[4]) <<< 8) : s16x(c[4]);
                    incxy <= c[6][6]  ? (s16x(c[5]) <<< 8) : s16x(c[5]);
                    incyx <= c[6][14] ? (s16x(c[2]) <<< 8) : s16x(c[2]);
                    incyy <= c[6][14] ? (s16x(c[3]) <<< 8) : s16x(c[3]);
                    st <= S_PAR1;
                end
                S_PAR1: begin
                    mx <= YOFF * incyx;
                    my <= YOFF * incyy;
                    st <= S_PAR1X;
                end
                S_PAR1X: begin                                  // Blazing Tornado: YOFF = -21 = -19 - 2
                    if (i_bt) begin
                        mx <= mx - (incyx <<< 1);
                        my <= my - (incyy <<< 1);
                    end
                    st <= S_PAR1B;
                end
                S_PAR1B: begin
                    t0 <= (s16x(c[0]) <<< 8) - mx;
                    t1 <= (s16x(c[1]) <<< 8) - my;
                    mx <= XOFF * incxx;
                    my <= XOFF * incxy;
                    st <= S_PAR2;
                end
                S_PAR2: begin
                    row_sx <= (t0 - mx) <<< 5;
                    row_sy <= (t1 - my) <<< 5;
                    sinc_x <= incxx <<< 5;                      // simple mode's dot step (super_m mode loads its own per row)
                    sinc_y <= incxy <<< 5;
                    st <= S_PAR3;
                end
                S_PAR3: begin
                    incyx <= incyx <<< 5;                       // the row step
                    incyy <= incyy <<< 5;
                    st <= S_IDLE;
                end

                // a row
                S_ROW: begin
                    wdot <= 9'd0;
                    if (super_m) begin
                        o_li_addr <= {wrow + (i_bt ? 9'd21 : 9'(-YOFF)), 2'b00};   // (y - YOFF) & 0x1ff, four words
                        lk <= 2'd0;
                        st <= S_LI0;
                    end else begin
                        cx <= row_sx; cy <= row_sy;
                        st <= S_D0;
                    end
                end
                S_LI0: st <= S_LI1;                                    // the registered RAM answers a clock later
                S_LI1: begin
                    lw[lk] <= i_li_q;
                    if (lk == 2'd3) st <= S_LI2;
                    else begin lk <= lk + 2'd1; o_li_addr <= {o_li_addr[10:2], lk + 2'd1}; st <= S_LI0; end
                end
                S_LI2: begin
                    incxx <= c[6][15] ? (s16x(lw[2]) <<< 8) : s16x(lw[2]);
                    incxy <= c[6][7]  ? (s16x(lw[3]) <<< 8) : s16x(lw[3]);
                    t0 <= s16x(lw[0] + c[0]) <<< 8;                    // 256 * (int16)(w0 + ctrl[0])
                    t1 <= s16x(lw[1] + c[1]) <<< 8;
                    st <= S_LI2B;
                end
                S_LI2B: begin
                    mx <= XOFF * incxx;
                    my <= XOFF * incxy;
                    sinc_x <= incxx <<< 5;
                    sinc_y <= incxy <<< 5;
                    st <= S_LI3;
                end
                S_LI3: begin
                    t0 <= t0 - mx;
                    t1 <= t1 - my;
                    st <= S_LI4;
                end
                S_LI4: begin
                    cx <= t0 <<< 5; cy <= t1 <<< 5;
                    st <= S_D0;
                end

                // a dot: position -> tile and the row inside it
                S_D0: begin
                    inb <= (cx[31:27] == 5'd0) && (cy[31:28] == 4'd0);
                    if (i_bt) begin
                        tp  <= {cy[27:19], cx[26:19]};                 // 8 x 8 tiles: row = y >> 3 (9 bits), col = x >> 3 (8 bits)
                        xin <= {1'b0, cx[18:16]};
                        yin <= {1'b0, cy[18:16]};
                    end else begin
                        tp  <= {1'b0, cy[27:20], 1'b0, cx[26:20]};     // 16 x 16 tiles: {row[7:0], col[6:0]}
                        xin <= cx[19:16];
                        yin <= cy[19:16];
                    end
                    cx <= cx + sinc_x;
                    cy <= cy + sinc_y;
                    st <= S_D1;
                end
                S_D1: begin
                    if (!inb) begin                                    // outside the plane: not drawn
                        lb_we <= 1'b1; lb_wa <= bank_base(wrow[2:0]) + 12'(wdot); lb_wd <= 9'd0;
                        dot_done = 1'b1;
                    end else if (cur_ok && tp == cur_tp) begin         // the same tile as the dot before: its code is known
                        lidx <= f_lidx(cur_code, yin, i_bt);
                        ltg  <= f_ltg(cur_code, i_bt);
                        st <= S_LW;
                    end else begin
                        moff <= map_off;
                        st <= S_M0;
                    end
                end
                // the tile's code from the map cache
                S_M0: begin
                    wid  <= moff[16:5];
                    widx <= wfold(moff[16:5]);
                    st <= S_MW;
                end
                S_MW: begin                                            // the window RAM reads {widx, moff[4:0]} at the end of this clock
                    if (wvalid[widx] && wtag[widx] == wid) st <= S_MU;
                    else begin rq_widx <= widx; st <= S_WIN; end
                end
                S_MU: begin
                    cur_code <= i_bt ? wr_q[14:0] : {2'b00, wr_q[14:2]};   // word & 0x7fff, (word & 0x7fff) >> 2 (Grand Striker 2)
                    cur_tp   <= tp; cur_ok <= 1'b1;
                    lidx <= f_lidx(i_bt ? wr_q[14:0] : {2'b00, wr_q[14:2]}, yin, i_bt);
                    ltg  <= f_ltg(i_bt ? wr_q[14:0] : {2'b00, wr_q[14:2]}, i_bt);
                    st <= S_LW;
                end
                S_WIN: begin
                    if (rq_done) begin
                        if (!fill_bad && !inval_hits_fill) begin wvalid[rq_widx] <= 1'b1; wtag[rq_widx] <= wid; end
                        rq_issued <= 1'b0;
                        st <= S_M0;                                    // look it up again (hits, or misses again when the 68000 wrote it meanwhile)
                    end else if (!rq_busy && !rq_issued && !i_frame) begin
                        rq_busy <= 1'b1; rq_is_map <= 1'b1; o_rq_req <= 1'b1; rq_issued <= 1'b1; fill_bad <= 1'b0;
                        wvalid[rq_widx] <= 1'b0; wtag[rq_widx] <= wid;
                        o_rq_addr <= i_map_base + AW'({wid, 6'd0});
                        o_rq_len  <= 7'd64;
                    end
                end
                // the line {code, row in the tile}: both line RAMs read lidx at the end of this clock
                S_LW: st <= S_LU;
                S_LU: begin
                    if (lt_q[9] && lt_q[8:0] == ltg) begin
                        lb_we <= 1'b1; lb_wa <= bank_base(wrow[2:0]) + 12'(wdot);
                        lb_wd <= {1'b1, xin[0] ? lr_q[7:0] : lr_q[15:8]};
                        dot_done = 1'b1;
                    end else begin
                        rq_lidx <= lidx;
                        st <= S_LF;
                    end
                end
                S_LF: begin
                    if (rq_done) begin
                        lt_we <= 1'b1; lt_wa <= 8'(rq_lidx >> gsh); lt_wd <= {1'b1, ltg};
                        rq_issued <= 1'b0;
                        st <= S_LF2;                                   // (the tag write lands at the end of the next clock)
                    end else if (!rq_busy && !rq_issued && !i_frame) begin
                        rq_busy <= 1'b1; rq_is_map <= 1'b0; o_rq_req <= 1'b1; rq_issued <= 1'b1;
                        lt_we <= 1'b1; lt_wa <= 8'(rq_lidx >> gsh); lt_wd <= 10'd0;     // not a hit while it is half there
                        rq_base <= i_bt ? {(rq_lidx >> gsh) << gsh, 2'b00} : {((rq_lidx >> gsh) << gsh) & 10'h1FF, 3'b000};
                        o_rq_addr <= i_gfx2_base + (i_bt ? AW'({cur_code[14:0], yin[2:0]} >> GG_BT << GG_BT) << 3
                                                         : AW'({cur_code[12:0], yin[3:0]} >> GG_GS << GG_GS) << 4);
                        o_rq_len  <= i_bt ? 7'(8 << GG_BT) : 7'(16 << GG_GS);
                    end
                end
                S_LF2: st <= S_LW;                                     // read it again (hits)
                default: st <= S_IDLE;
            endcase
            if (dot_done) begin
                wdot <= wdot + 9'd1;
                if (wdot == 9'(VIS_W - 1)) begin
                    wrow <= wrow + 9'd1; o_rows_done <= wrow + 9'd1;
                    row_sx <= row_sx + incyx; row_sy <= row_sy + incyy;
                    st <= S_IDLE;
                end else st <= S_D0;
            end

            // -------------------------------------------------- measurements
            m_rowend = dot_done && (wdot == 9'(VIS_W - 1));
            if (st == S_ROW) m_wclk <= 16'd1;
            else if (st != S_IDLE && st != S_PAR0 && st != S_PAR1 && st != S_PAR1X && st != S_PAR1B && st != S_PAR2 && st != S_PAR3 && m_wclk != 16'hFFFF) m_wclk <= m_wclk + 16'd1;
            if (st == S_ROW) m_rlines <= 16'd0;
            else if (st == S_LF && !rq_issued && !rq_busy && m_rlines != 16'hFFFF) m_rlines <= m_rlines + 16'd1;
            if (m_rowend) begin
                if (m_wclk > m_wclk_max) m_wclk_max <= m_wclk;
                m_wsum <= m_wsum + {8'd0, m_wclk};
                if (m_rlines > m_rlines_max) m_rlines_max <= m_rlines;
            end
            if (st == S_WIN && m_wwin != 24'hFFFFFF) m_wwin <= m_wwin + 24'd1;
            if (st == S_LF && m_psum != 24'hFFFFFF) m_psum <= m_psum + 24'd1;
            if (st == S_IDLE && wrow < 9'(VIS_H) && m_walloc != 24'hFFFFFF) m_walloc <= m_walloc + 24'd1;     // waiting for the renderer (the plane is ahead)
            if (st == S_WIN && !rq_issued && !rq_busy && !i_frame) m_win <= m_win + 16'd1;
            if (st == S_LF && !rq_issued && !rq_busy && !i_frame) m_line <= m_line + 16'd1;
            // clocks from a request to its first word
            if (!rq_busy) begin
                m_lat <= 16'd0; m_lat_open <= 1'b0;
            end else if (!m_lat_open) begin
                if (i_rq_wr) begin
                    m_lat_open <= 1'b1;
                    if (m_lat + 16'd1 > m_lat_max) m_lat_max <= m_lat + 16'd1;
                    m_lat_sum <= m_lat_sum + {8'd0, m_lat} + 24'd1;
                end else if (m_lat != 16'hFFFF) m_lat <= m_lat + 16'd1;
            end
            // zoom steps of three rows (line RAM words 2 and 3 of the row, as the walker loaded them)
            if (st == S_LI2) begin
                if (wrow == 9'd0)   begin m_lw2_0 <= lw[2]; m_lw3_0 <= lw[3]; end
                if (wrow == 9'd120) begin m_lw2_m <= lw[2]; m_lw3_m <= lw[3]; end
                if (wrow == 9'd220) begin m_lw2_e <= lw[2]; m_lw3_e <= lw[3]; end
            end

            // -------------------------------------------------- a new frame (overrides the above)
            if (i_frame) begin
                st_r <= {m_lw3_e, m_lw2_e, m_lw3_m, m_lw2_m, m_lw3_0, m_lw2_0,
                         sat16(m_lat_sum >> 6), m_lat_max, sat16(m_walloc >> 6), sat16(m_wwin >> 6), sat16(m_psum >> 6), sat16(m_wsum >> 6),
                         m_wclk_max, m_rlines_max, m_line, m_win};
                m_win <= 16'd0; m_line <= 16'd0; m_rlines_max <= 16'd0; m_wclk_max <= 16'd0; m_wsum <= 24'd0; m_psum <= 24'd0; m_wwin <= 24'd0; m_walloc <= 24'd0;
                m_lat_max <= 16'd0; m_lat_sum <= 24'd0;
                for (int i = 0; i < 8; i++) c[i] <= i_ctrl[i];
                super_m <= i_ctrl[7][6];
                wrow <= 9'd0; wdot <= 9'd0; o_rows_done <= 9'd0; o_par <= ~o_par;
                lb_we <= 1'b0;
                rq_issued <= 1'b0; cur_ok <= 1'b0;
                if (rq_busy && !i_rq_ack) drain <= 1'b1;       // the video chip still delivers it: let it finish
                st <= S_PAR0;
            end
        end
    end
endmodule
`default_nettype wire
