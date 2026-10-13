// Derived from searchsolved/Arcade-HyperDuel_MiSTer rtl/i4220_vdp.sv at 7f154f1e856ce5863f962821f2b330d1e8a85727 (GPL-3.0-or-later, see ../LICENSE).
// Renamed i4220_vdp -> metro_vdp for the Metro core; any functional change from upstream is listed below in a "METRO:" note.
// I4220 VDP top (M3).
//
// Binds the verified scanline renderer (metro_render) and blitter
// (metro_blitter) to the CPU-visible v2 address map (docs/i4220_spec.md
// sec 2), with internal VRAM/palette/sprite/tiletable BRAMs, register
// file, IRQ controller, video timing, sprite double-buffering, and a
// 3-client GFX ROM arbiter (renderer > CPU window > blitter).
//
// CPU bus: hold i_cs with stable addr/rnw/be/wdata; o_ack rises when the
// operation completes (rdata valid) and stays high until i_cs drops.
//
// External GFX ROM port: same stream protocol as metro_render (1-cycle
// req pulse with addr+len, then len valid pulses; no new request before
// the stream completes).
//
// IRQ model follows the hyprduel driver's observed behaviour (spec sec
// 10): line 0 sets cause bits 0 and 5 (bit 5 auto-clears after
// P_BIT5_CYCLES), every other line sets bits 1 and 4; write-1 acks clear
// bits 4:0 only; enable register masks with 1 = disabled. o_vbl_pulse
// fires at line 0 for the board-level main-CPU IPL2 wiring.

module metro_vdp #(
    parameter int GFX_AW = 24,
    parameter int P_PIXDIV = 12,          // sys clocks per pixel
    parameter int P_BIT5_CYCLES = 200000, // ~2.5 ms at 80 MHz
    parameter bit P_SPR_BUFFERED = 1'b1,
    // METRO: IRQ cause model.  0 = Hyper Duel as upstream (line 0: bits 0 and 5, every other line: bits 1 and 4).
    //        1 = Metro as MAME 0.289 drives it: bit 0 (vblank) at the start of line P_VBL_LINE, bit 2 (blitter done) as upstream,
    //            bit 4 every P_TICK_LINES lines (MAME: the 68000's periodic interrupt at 8 x 60 Hz = every ~32 lines).
    //        In model 1 nothing else sets cause bits.  Dharma only needs at least one bit-4 tick between its re-arm and the next vblank
    //        (docs/hardware.md section 4a).
    // METRO: raster totals as parameters (upstream hard-wired Hyper Duel's measured 424 x 261: H_TOTAL 424, vlast 260).
    //        MAME's timing for the Metro boards is 392 x 263 (6.0 MHz dot clock = 24 MHz / 4 -> 58.2328 Hz, i.e. P_H_TOTAL = 392, P_VLAST = 262).
    //        i_compat60 still adds one line (vlast + 1).  Sync positions only matter for the real video output.
    parameter int P_H_TOTAL = 424,
    parameter int P_VLAST = 260,
    parameter int P_HS_BEG = 352,
    parameter int P_HS_END = 384,
    parameter int P_VS_BEG = 232,
    parameter int P_VS_END = 236,
    parameter int P_IRQ_MODEL = 0,
    parameter int P_VBL_LINE = 224,
    parameter int P_TICK_LINES = 32,
    parameter int P_TICK_CLKS  = 0,        // METRO model: > 0 = the periodic tick (bit 4) every this many clocks (MAME: 8 x 60 Hz = 200000 at 96 MHz), 0 = every P_TICK_LINES lines
    // Which cause bits can drive the IRQ output line. Hyper Duel's board
    // only responds to hblank (bit 1) on IPL3; everything else is polled.
    // (MAME encodes the same fact by forcing the enable register OR 0xFD.)
    parameter logic [7:0] P_IRQ_LINE_MASK = 8'hFF,
    // 1 (MiSTer shell): the raster counters run from power-on and keep sync
    // going while the core is held in reset (ROM download), with black RGB;
    // i_tim_rst reloads their power-on state (line 0) once a frame and
    // hyprduel_sys releases the core on the clock after that reload, so the
    // game starts exactly as from a plain reset release.
    // 0 (simulation default): counters reset with rst_n.
    parameter bit FREE_TIMING = 1'b0,
    // METRO (family F): 1 = the frame-synchronous layer RAM (see "P_VLOG" below the CPU bus decode): the 68000's writes to the three tile layers and the tile table are kept in a log
    // and applied at the instant the sprite list and the scroll registers are copied, so a frame is drawn from one state, as MAME draws it.  0 = live RAM as before (no logic).
    parameter bit P_VLOG = 1'b0
) (
    input  logic clk,
    input  logic rst_n,
    input  logic i_tim_rst,      // FREE_TIMING: synchronous raster reload
    output logic o_tim_evt,      // FREE_TIMING: the next pixel starts line 0

    // CPU slave bus (byte addr within the 512 KB region)
    input  logic        i_cs,
    input  logic [18:0] i_addr,
    input  logic        i_rnw,
    input  logic [1:0]  i_be,      // [1] = high byte (UDS), [0] = low (LDS)
    input  logic [15:0] i_wdata,
    output logic [15:0] o_rdata,
    output logic        o_ack,

    // video out (RGB555, GRB palette decoded here)
    output logic       o_hs,
    output logic       o_vs,
    output logic       o_de,
    output logic       o_hblank,   // separate blanks for the MiSTer
    output logic       o_vblank,   // framework (arcade_video)
    output logic       o_ce_pix,
    output logic [4:0] o_r, o_g, o_b,

    // interrupts
    output logic o_irq,        // level: |(cause & ~enable) -> main IPL3
    output logic o_vbl_pulse,  // 1 sys clock at line 0 -> main IPL2

    // GFX ROM master. Stream data is WORD-mode for even-addr/even-len
    // requests (renderer, CPU window): [15:8] = even byte, [7:0] = odd,
    // two bytes per valid. Byte-mode (blitter, len 1): one byte in [7:0].
    output logic              o_rom_req,
    output logic [GFX_AW:0]   o_rom_addr,          // METRO: one bit more than the graphics space (family F's tile ROM sits above it)
    output logic [6:0]        o_rom_len,
    input  logic [15:0]       i_rom_data,
    input  logic              i_rom_valid,
    input  logic [31:0]       i_gfx_size,

    // Video timing: 0 = measured 261-line frame (60.2408 Hz, hardware
    // -verified), 1 = legacy MAME 262-line frame (60.011 Hz) for
    // displays that reject 60.24 Hz in sync-locked HDMI modes.
    input  logic i_compat60,
    // METRO: 1 = ignore the CRTC first-visible-line and show chip lines 0..223 as MAME does (0 = follow the game's CRTC programming, which for
    // Dharma is line 11).  Which one the real hardware shows is open (docs/status.md); this is an OSD option in the core.
    input  logic i_win_mame,
    input  logic i_flip_force,             // METRO: 1 = flip the picture whatever the game's own screen control says (the Flip Screen DIP; the chip does the flip, the game only sets bit 0)
    input  logic i_pal_latch,              // METRO: 1 = the picture uses the palette as it was at the start of the frame (see u_palette_sh), 0 = the live palette
    input  logic i_spr_early,              // METRO: 1 = copy the sprite RAM at line P_VBL_LINE instead of the last line (Puzzli: its blinking text sprites are written in lines 3-7 and wiped in 227-230)
    input  logic [3:0] i_tmap_dx,          // METRO: tilemap X offset of the board (see flip_dx)
    // METRO (family F): the 053936 plane (rtl/metro_roz.sv, in metro_main).  The chip gives it the frame start and the number of rows the renderer has started, holds the
    // renderer's kick of a row until the plane has drawn that row, hands the renderer the plane's pen, and carries the plane's tile ROM reads on its graphics stream
    input  logic        i_roz_en,
    input  logic        i_tick_slow,        // METRO (family C, Mouse Shooter GoGo): the periodic interrupt (cause bit 4) every 8th tick: 60 Hz instead of 8 x 60 Hz
    input  logic        i_vlog_en,          // P_VLOG: 1 = the layer RAM writes go through the log (OSD "Tile RAM frame sync"), 0 = live
    input  logic        i_roz_prio,         // hardware test switch (OSD "Plane fetch priority"): the plane's tile ROM reads ahead of the renderer's, the CPU window's and the blitter's
    input  logic        i_no_hold,          // hardware test switch (OSD "CPU sprite write hold"): 1 = the 68000's sprite RAM writes do not wait for the list copy
    output logic        o_roz_frame,
    output wire   [8:0] o_roz_used,
    input  logic  [8:0] i_roz_done,
    output logic  [2:0] o_roz_bank,
    output logic  [8:0] o_roz_x,
    input  logic [11:0] i_roz_pen,
    input  logic        i_roz_op,
    input  logic        i_roz_req,          // METRO (family F): the plane's request for a burst of the graphics stream (level until o_roz_ack), its address, length in bytes
    input  logic [GFX_AW:0] i_roz_addr,
    input  logic  [6:0] i_roz_len,          // 64 (a window of the tile map RAM), 16 / 8 (a row of a tile)
    output logic        o_roz_wr,
    output logic  [4:0] o_roz_idx,          // word index in the burst
    output logic [15:0] o_roz_data,
    output logic        o_roz_ack,
    input  logic [3:0] i_tmap_dx1,         // METRO (family F): layer 1's own extra X offset (Grand Striker 2: set_tmap_xoffsets(0, 8, 0))
    input  logic i_w304,                   // METRO: 1 = 304 pixels wide picture (MAME's i4220_config_304x224: Varia Metal)
    input  logic i_w384,                   // METRO: 1 = 384 pixels wide picture (MAME's i4300_config_384x224: Mahjong Doukyuusei Special)
    input  logic i_wide,                   // METRO: 1 = 360 pixels wide picture (the I4100 boards of MAME's i4100_config_360x224), 0 = 320
    input  logic i_tall,                   // METRO: 1 = 240 lines (Karate Tournament, Lady Killer, Sankokushi: MAME's visible area 0..239), the vblank interrupt then comes at line 240; 0 = 224
    input  logic i_ext5,                   // METRO: 1 = external vblank interrupt (cause bit 5): Karate Tournament, Lady Killer, Last Fortress VG460, Sankokushi (metro.cpp karatour_vblank_irq)
    input  logic i_i4100,                  // METRO: 1 = Imagetek I4100 (no 8bpp / 16x16 tiles; the sprite priority register is at 0x78802), 0 = I4220 / I4300
    input  logic i_scan_irq,               // METRO: Puzzli's interrupt model (metro.cpp bangball_scanline): no periodic tick; at line 224 causes 4 + 0, on every line before it cause 1 while enable bit 1 is clear
    input  logic i_i4300,                  // METRO: 1 = Imagetek I4300 (family D): its own register map (v3_map, folded onto the I4220's layout below), a level and a vector per cause bit, no periodic tick
    input  logic [2:0] i_vbl_bit,          // I4300: the cause bit the vblank sets (MAME's set_vblank_irq_level, 1)
    input  logic [2:0] i_blit_bit,         // I4300: the cause bit the blitter's end sets (set_blit_irq_level, 2 or 3)
    input  logic i_irq0_pulse,             // one clock: set cause bit 0 (Mouja's programmable timer interrupt)
    input  logic [2:0] i_vec_idx,          // I4300: the level of the interrupt acknowledge cycle (address bits 3:1)
    output logic [2:0] o_irq_lvl,          // I4300: the highest level among the pending, unmasked causes (0 = none)
    output logic [7:0] o_vec,              // I4300: the vector of level i_vec_idx (irq_vector_r)

    // Runtime IRQ line mask, ANDed with P_IRQ_LINE_MASK. The board glue
    // picks it per game (Hyper Duel 0x02, Magical Error 0x01); tie to
    // 8'hFF where the parameter alone should apply.
    input  logic [7:0] i_irq_line_mask,

    // DEBUG: diagnostic flags for hardware bring-up
    output logic o_dbg_vdp_write,    // CPU ever wrote to VDP
    output logic o_dbg_line_start,   // line_start ever fired
    output logic o_dbg_rnd_done,     // renderer ever completed a line
    output logic o_dbg_lb_nonzero,   // linebuf ever had a nonzero pixel
    output logic [15:0] o_dbg_palw,  // count of nonzero palette writes
    output logic [15:0] o_dbg_ovr,   // count of dropped render kicks (overrun)

    // DEBUG: top-lines provenance (displaced-strip investigation).
    // rend = layer-2 X view (scroll-window) the renderer's tilemap pass
    // ACTUALLY CONSUMED for the line (tapped inside metro_render on the
    // first pass cycle, so it reflects the line-1 prediction mux);
    // disp = the same view at the line's own scanout (h160). A nonzero
    // rend/disp delta is the expected on-screen displacement of that
    // line in pixels. topflags = previous frame's {stale[2:0],
    // tagbad[2:0]} for lines 2..0.
    output logic [15:0] o_dbg_rend_sx2_0,
    output logic [15:0] o_dbg_rend_sx2_1,
    output logic [15:0] o_dbg_rend_sx2_2,
    output logic [15:0] o_dbg_disp_sx2_0,
    output logic [15:0] o_dbg_disp_sx2_1,
    output logic [15:0] o_dbg_disp_sx2_2,
    output logic [15:0] o_dbg_topflags,
    // measurements of the last frame for the hardware test overlay (metro_hud.sv): 16 words, valid at the clock of o_roz_frame
    output logic [255:0] o_st
);

  localparam int H_TOTAL = P_H_TOTAL;
  // METRO: the visible size is the board's (MAME i4100_config_360x224 / i4220_config_320x240 ...): static, registered.  The horizontal sync pulse moves behind a 360 pixel picture (it
  // would overlap the last 24 pixels at P_HS_BEG = 336), the vertical one stays 8 lines behind the picture.
  logic [8:0] h_vis, v_vis, hs_beg, hs_end, vs_beg, vs_end;
  // METRO: the tile table copy below is for the tall I4100 boards only (Karate Tournament, Lady Killer, Moeyo Gonta: board 7); the 360-pixel I4100 games (Pang Pom's, Sky Alert,
  // Last Fortress, Poitto) look right as they are and are left alone.
  // METRO: the tile table copy (below) is also used on the I4300 boards (Doukyuusei, Mouja, Doukyuusei Special): their games change the whole picture by rewriting the 1024-word
  // table between lines 79 and 137 while the beam is drawing (MAME shows the table as it was at line 224), and they load a palette bank in the same breath
  wire fix_tall = (i_i4100 && i_tall) || i_i4300;
  always_ff @(posedge clk) begin
    h_vis  <= i_w384 ? 9'd384 : i_w304 ? 9'd304 : i_wide ? 9'd360 : 9'd320;
    v_vis  <= i_tall ? 9'd240 : 9'd224;
    hs_beg <= i_wide ? 9'(P_HS_BEG + 28) : 9'(P_HS_BEG);
    hs_end <= i_wide ? 9'(P_HS_END + 20) : 9'(P_HS_END);
    vs_beg <= (i_tall ? 9'd240 : 9'd224) + 9'd8;
    vs_end <= (i_tall ? 9'd240 : 9'd224) + 9'd12;
  end

  // ------------------------------------------------------------------
  // memories
  // ------------------------------------------------------------------
  // VRAM: explicit dual-port RAM wrappers (Verilator = inferred array,
  // Quartus = altsyncram) to avoid the 50GB elaboration balloon from
  // Quartus 17 inferring three 64Kx16 memories through its front end.
  // Port A = CPU/blitter (read/write), Port B = renderer (read-only).
  logic [15:0] vr_a_addr, vr_a_d;
  logic        vr_a_we [3];
  logic [1:0]  vr_a_be;
  logic [15:0] q_vram0, q_vram1, q_vram2;

  // Pipeline register on the VRAM port-B address: breaks the long
  // combinational path from the renderer's tileoffs computation into
  // the BRAM address register (the worst timing path at -2.195 ns).
  // The renderer's VR wait states are extended by one cycle to match.
  logic [15:0] rnd_vram_addr_r;
  always_ff @(posedge clk) rnd_vram_addr_r <= rnd_vram_addr;

  metro_dpram #(.AW(16), .DW(16), .SLICED(1)) u_vram0 (
    .clk(clk),
    .addr_a(vr_a_addr), .d_a(vr_a_d), .we_a(vr_a_we[0]), .be_a(vr_a_be), .q_a(q_vram0),
    .addr_b(rnd_vram_addr_r), .q_b(rnd_vram_q[0])
  );
  metro_dpram #(.AW(16), .DW(16), .SLICED(1)) u_vram1 (
    .clk(clk),
    .addr_a(vr_a_addr), .d_a(vr_a_d), .we_a(vr_a_we[1]), .be_a(vr_a_be), .q_a(q_vram1),
    .addr_b(rnd_vram_addr_r), .q_b(rnd_vram_q[1])
  );
  metro_dpram #(.AW(16), .DW(16), .SLICED(1)) u_vram2 (
    .clk(clk),
    .addr_a(vr_a_addr), .d_a(vr_a_d), .we_a(vr_a_we[2]), .be_a(vr_a_be), .q_a(q_vram2),
    .addr_b(rnd_vram_addr_r), .q_b(rnd_vram_q[2])
  );
  // tiletable: port A = CPU r/w, port B = renderer read
  logic [15:0] tt_q_a;
  logic [9:0]  tt_cpu_addr;
  logic        tt_we;
  logic [15:0] tt_a_d;
  logic [1:0]  tt_a_be;
  logic [15:0] tt_rnd_q;
  // METRO (I4100 boards): the renderer reads a copy of the tile table that is taken once per frame (tts_*, below); port B of the live table then only serves that copy
  logic [9:0]  tts_ra, tts_wa_q;
  logic        tts_we_q;
  logic [15:0] tts_q;
  metro_dpram #(.AW(10), .DW(16), .NUMWORDS(1024)) u_tiletable (
    .clk(clk),
    .addr_a(tt_cpu_addr), .d_a(tt_a_d), .we_a(tt_we), .be_a(tt_a_be), .q_a(tt_q_a),
    .addr_b(fix_tall ? tts_ra : rnd_tt_addr), .q_b(tt_rnd_q)
  );
  metro_dpram #(.AW(10), .DW(16), .NUMWORDS(1024)) u_tiletable_copy (
    .clk(clk),
    .addr_a(tts_wa_q), .d_a(tt_rnd_q), .we_a(tts_we_q), .be_a(2'b11), .q_a(),
    .addr_b(rnd_tt_addr), .q_b(tts_q)
  );

  // palette: port A = CPU r/w, port B = scan-out read
  logic [15:0] pal_q_a;
  logic [11:0] pal_cpu_addr;
  logic        pal_we;
  logic [11:0] so_pen;
  logic [15:0] pal_scanout_q;
  // METRO: i_pal_latch = 1: the scan-out reads a SHADOW palette that is copied from the live one once per frame (pal_cp_* below), so a palette rewritten in the middle of a frame (the games'
  // fades: Puzzli's Banpresto screen writes ~1,200 entries in the visible lines of every frame, Gun Master's fades hundreds) changes colour at a frame boundary instead of leaving a
  // moving band where the beam was when the writes passed.  MAME draws a frame from the palette as it is at the end of the frame, never half-way.  i_pal_latch = 0: live palette as before.
  logic        pal_cp_run;
  logic [12:0] pal_cp_cnt;
  logic [15:0] pal_cp_q;
  logic [15:0] pal_sh_q;
  wire  [11:0] pal_b_addr = i_pal_latch ? pal_cp_cnt[11:0] : so_pen;
  metro_dpram #(.AW(12), .DW(16), .NUMWORDS(4096)) u_palette (
    .clk(clk),
    .addr_a(pal_cpu_addr), .d_a(i_wdata), .we_a(pal_we), .be_a(i_be), .q_a(pal_q_a),
    .addr_b(pal_b_addr), .q_b(pal_scanout_q)
  );
`ifdef F_BUILD
  logic [15:0] pal_sh_qa_unused;
  metro_dpram #(.AW(12), .DW(16), .NUMWORDS(4096)) u_palette_sh (
    .clk(clk),
    .addr_a(pal_cp_cnt[11:0] - 12'd2), .d_a(pal_cp_q), .we_a(pal_cp_run && pal_cp_cnt >= 13'd2 && pal_cp_cnt <= 13'd4097), .be_a(2'b11), .q_a(pal_sh_qa_unused),
    .addr_b(so_pen), .q_b(pal_sh_q)
  );
`else
  // METRO: TWO shadow palettes, the picture reads one while the next is copied into the other at MAME's own instant (line v_vis, the start of the vblank), and the two swap
  // after the last displayed line.  With one shadow copied after the last displayed line (line 238 with the game's window of 11) a game that starts clearing a palette bank at
  // line ~238 - 239 of every sixth frame (Doukyuusei Special's portraits, MAME's trace: zeros from line 239.4 to 54, the colours to 80) was caught by the copy half way: the
  // whole-machine sim shows the black frames of the hardware videos (frames 861 / 873 of the portrait scene).  The words are 15 bits (bit 0 of the palette word is unused).
  logic        pal_bank;                     // 0: the picture reads u_palette_sh, 1: u_palette_sh2 (the copy goes to the other)
  wire         pal_cp_we = pal_cp_run && pal_cp_cnt >= 13'd2 && pal_cp_cnt <= 13'd4097;
  logic [14:0] pal_sh_qa_unused, pal_sh_qa2_unused, pal_shA_q, pal_shB_q;
  metro_dpram_raw #(.AW(12), .DW(15), .NUMWORDS(4096), .MAXDEPTH(2048)) u_palette_sh (
    .clk(clk),
    .addr_a(pal_cp_cnt[11:0] - 12'd2), .d_a(pal_cp_q[15:1]), .we_a(pal_cp_we && pal_bank), .q_a(pal_sh_qa_unused),
    .addr_b(so_pen), .q_b(pal_shA_q)
  );
  metro_dpram_raw #(.AW(12), .DW(15), .NUMWORDS(4096), .MAXDEPTH(2048)) u_palette_sh2 (
    .clk(clk),
    .addr_a(pal_cp_cnt[11:0] - 12'd2), .d_a(pal_cp_q[15:1]), .we_a(pal_cp_we && !pal_bank), .q_a(pal_sh_qa2_unused),
    .addr_b(so_pen), .q_b(pal_shB_q)
  );
  assign pal_sh_q = {pal_bank ? pal_shB_q : pal_shA_q, 1'b0};
`endif

  // scratch: port A = CPU r/w, port B = unused
  logic [15:0] scr_q_a;
  logic [11:0] scr_cpu_addr;
  logic        scr_we;
  metro_dpram #(.AW(12), .DW(16), .NUMWORDS(4096)) u_scratch (
    .clk(clk),
    .addr_a(scr_cpu_addr), .d_a(i_wdata), .we_a(scr_we), .be_a(i_be), .q_a(scr_q_a),
    .addr_b(12'd0), .q_b()
  );

  // spr_live: port A = CPU r/w, port B = vblank copy read
  logic [15:0] spr_live_q_a;
  logic [10:0] spr_live_cpu_addr;
  logic        spr_live_we;
  logic [10:0] spr_live_b_addr;
  logic [15:0] spr_live_b_q;
  metro_dpram #(.AW(11), .DW(16), .NUMWORDS(2048)) u_spr_live (
    .clk(clk),
    .addr_a(spr_live_cpu_addr), .d_a(i_wdata), .we_a(spr_live_we), .be_a(i_be), .q_a(spr_live_q_a),
    .addr_b(spr_live_b_addr), .q_b(spr_live_b_q)
  );

  // spr_buf: port A = vblank copy write, port B = renderer read
  logic [10:0] spr_buf_a_addr;
  logic [15:0] spr_buf_a_d;
  logic        spr_buf_a_we;
  logic [15:0] spr_buf_q;
  metro_dpram #(.AW(11), .DW(16), .NUMWORDS(2048)) u_spr_buf (
    .clk(clk),
    .addr_a(spr_buf_a_addr), .d_a(spr_buf_a_d), .we_a(spr_buf_a_we), .be_a(2'b11), .q_a(),
    .addr_b(rnd_spr_addr), .q_b(spr_buf_q)
  );

  // sprite prescan table: port A = vblank copy snoop write, port B =
  // renderer read. One entry per sprite: {dis, y_end[10:0], y[9:0]}
  logic [8:0]  pst_waddr;
  logic [23:0] pst_wdata;
  logic        pst_we;
  logic        pst_valid;   // set once the first full copy refreshed the table
  logic [8:0]  rnd_pst_addr;
  logic [23:0] pst_rnd_q;
  metro_dpram #(.AW(9), .DW(24), .NUMWORDS(512)) u_spr_pst (
    .clk(clk),
    .addr_a(pst_waddr), .d_a(pst_wdata), .we_a(pst_we), .be_a(3'b111), .q_a(),
    .addr_b(rnd_pst_addr), .q_b(pst_rnd_q)
  );

  // linebuf: port A = renderer write, port B = scan-out read
  // padded to 16 bits wide so metro_dpram byte-enable logic covers all bits
  logic [15:0] lb_rq_wide;
  wire  [11:0] lb_rq = lb_rq_wide[11:0];
  logic [10:0] lb_scan_addr;   // assigned below vsrc (v15 window shift)
  metro_dpram #(.AW(11), .DW(16), .NUMWORDS(2048)) u_linebuf (
    .clk(clk),
    .addr_a({lb_bank, lb_x}), .d_a({4'd0, lb_pen}), .we_a(lb_we),
    .be_a(2'b11), .q_a(),
    .addr_b(lb_scan_addr), .q_b(lb_rq_wide)
  );

  // ------------------------------------------------------------------
  // registers
  // ------------------------------------------------------------------
  logic [15:0] r_spr_count, r_spr_pri, r_spr_yoff, r_spr_xoff, r_spr_color;
  logic [15:0] spr_count_q;     // the sprite count as it was when the sprite RAM copy was taken: the renderer draws the copy, so it must use the count that belongs to it
  logic [5:0]  r_layer_pri;
  logic [11:0] r_bg;
  logic [15:0] r_scr_xoff, r_scr_yoff;
  logic [15:0] r_window [6];   // y0,x0,y1,x1,y2,x2
  logic [15:0] r_scroll [6];
  // METRO (20261009e): the window and scroll registers as they were when the sprite RAM copy started, and what the renderer uses (except on Puzzli's board, which draws raster effects
  // from live values).  Karate Tournament and Lady Killer rewrite the window registers in the middle of the picture every frame (lines 87-120 in MAME's timeline), Doukyuusei the scroll
  // registers; MAME draws a frame from the finished values, the live registers tore the picture at the write line (rectangular patches of a layer's wrapped content).
  logic [15:0] r_window_q [6];
  logic [15:0] r_scroll_q [6];
  logic [15:0] r_ctrl;
  logic [15:0] r_rombank;
  logic [7:0]  r_irq_cause, r_irq_enable;
  logic [2:0]  r_irq_lvl [8];          // I4300: the level of each cause bit (irq_level_w) and the vector of each level (irq_vector_w)
  logic [7:0]  r_irq_vec [8];
  initial for (int i = 0; i < 8; i++) begin r_irq_lvl[i] = 3'd0; r_irq_vec[i] = 8'd0; end
  always_comb begin
    logic [7:0] act;
    act = r_irq_cause & ~r_irq_enable;
    o_irq_lvl = 3'd0;
    for (int i = 0; i < 8; i++)
      if (act[i] && r_irq_lvl[i] > o_irq_lvl) o_irq_lvl = r_irq_lvl[i];
  end
  assign o_vec = r_irq_vec[i_vec_idx];
  logic        r_crtc_unlock;
  logic [15:0] r_crtc_h, r_crtc_v;
  logic [15:0] blit_regs [7];

  assign o_irq = |(r_irq_cause & ~r_irq_enable & P_IRQ_LINE_MASK & i_irq_line_mask);

  // renderer register views
  logic [15:0] rs_window_x [3];
  logic [15:0] rs_window_y [3];
  // The scroll view is a registered copy (one clk behind r_scroll): a
  // combinational view with any added muxing sits between the scroll
  // registers and the renderer's resx/resy adders and breaks timing on
  // the layer->lay_waddr cone (measured -0.19 to -0.32 across four
  // fitter seeds, 2026-07-15, with a predictor mux there). The
  // renderer consumes rnd_sw_* (registers loaded from the kick-FIFO
  // snapshot at pop), so the adder cone sees a plain register - no
  // added mux depth. Timing history that matters here: the game's
  // once-per-frame scroll block (sx0/sy1/sx1/sx2) lands at h180-320 of
  // line 0, and the per-line raster values land at h36-100 of the line
  // before the one they affect; the v9 own-line h0 kick samples after
  // both, which is what the deleted prediction/latch machinery was
  // approximating.
  logic [15:0] rs_sw_x [3];
  logic [15:0] rs_sw_y [3];
  // v9 (2026-07-17, after PCB footage disproved every line-ahead
  // mitigation): rs_sw_* is the LIVE registered view; each line's
  // render consumes a SNAPSHOT of it taken at h0 of that line (see the
  // kick FIFO below), and scan-out displays each line one line later.
  // Every line therefore renders from exactly the register state the
  // real chip's beam would have seen at its line start - no detectors,
  // predictors or latches.
  always_ff @(posedge clk) begin
    for (int l = 0; l < 3; l++) begin
      // pre-registered (scroll - window): keeps the renderer's per-pixel
      // resx/resy adders 2-term (identical result in the low 16 bits,
      // which is all the <=12-bit window masks ever consume)
      rs_sw_y[l] <= (i_scan_irq ? r_scroll[l*2 + 0] : r_scroll_q[l*2 + 0]) - (i_scan_irq ? r_window[l*2 + 0] : r_window_q[l*2 + 0]);
      rs_sw_x[l] <= (i_scan_irq ? r_scroll[l*2 + 1] : r_scroll_q[l*2 + 1]) - (i_scan_irq ? r_window[l*2 + 1] : r_window_q[l*2 + 1]);
    end
  end
  always_comb begin
    for (int l = 0; l < 3; l++) begin
      rs_window_y[l] = i_scan_irq ? r_window[l*2 + 0] : r_window_q[l*2 + 0];
      rs_window_x[l] = i_scan_irq ? r_window[l*2 + 1] : r_window_q[l*2 + 1];
    end
  end

  // ------------------------------------------------------------------
  // video timing
  // ------------------------------------------------------------------
  logic [$clog2(P_PIXDIV)-1:0] pixdiv;
  logic [8:0] hcnt;   // 0..423
  logic [8:0] vcnt;   // 0..261
  wire ce_pix = (pixdiv == 0);
  assign o_ce_pix = ce_pix;

  wire tim_rst = FREE_TIMING ? i_tim_rst : !rst_n;
  always_ff @(posedge clk) begin
    if (tim_rst) begin
      pixdiv <= '0;
      hcnt <= '0;
      vcnt <= '0;
    end else begin
      pixdiv <= (32'(pixdiv) == P_PIXDIV - 1) ? '0 : pixdiv + 1'b1;
      if (ce_pix) begin
        if (32'(hcnt) == H_TOTAL - 1) begin
          hcnt <= '0;
          vcnt <= (vcnt == vlast) ? '0 : vcnt + 1'b1;
        end else
          hcnt <= hcnt + 1'b1;
      end
    end
  end

  // Frame total: MEASURED at 261 lines (60.2408 Hz with the 424-dot
  // line at 6.6665 MHz) from two PCB recordings by three agreeing
  // methods (docs/plan_refresh_measurement.md, ACCURACY.md 3.6); the
  // game itself only ever programs 261 raster lines. i_compat60
  // selects the legacy MAME-assumed 262-line frame (60.011 Hz) for
  // displays that reject 60.24 Hz in sync-locked HDMI modes.
  wire [8:0] vlast = i_compat60 ? 9'(P_VLAST + 1) : 9'(P_VLAST);
  wire line_start   = ce_pix && (32'(hcnt) == H_TOTAL - 1);
  wire [8:0] next_v = (vcnt == vlast) ? 9'd0 : vcnt + 9'd1;
  // FREE_TIMING: the pixel enable that ends the last line (line 0 follows)
  assign o_tim_evt = ce_pix && (32'(hcnt) == H_TOTAL - 1) && (vcnt == vlast);

  // v12 display line: scan-out runs behind the game timeline
  // (invisible). Measured on silicon (ladder probe, 2026-07-18): the
  // game parks a scratch accumulator in the scroll registers across
  // vblank and its frame-top write flurry lands during line 1, by
  // (1,h160) - later than any simulation shows, because the SDRAM-fed
  // 68000 runs the flurry slower than a PCB's zero-wait ROMs (MAME's
  // CPU timing is late the same way, which is why it shows the same
  // top-line artefact). Lines 0/1 therefore sample at (1,h200), past
  // the measured landing; lines 2+ sample at their own h170. Output
  // sync generation uses vdisp throughout; game-facing timing (vcnt,
  // IRQs) is unchanged.
  //
  // v15 CRTC vertical window: the game programs the chip's vertical
  // timing through 78880 as INDEXED writes ({param[15:8], val[7:0]},
  // unlock-gated): param0=223 active span, param2=233 vsync start,
  // param4=240 vsync end, param7=2 FIRST VISIBLE LINE. A real monitor
  // therefore shows chip lines 2..225; lines 0/1 are a hidden work
  // area (the scratch accumulator and the boss-zone outlier live
  // there), which is why a PCB's top of screen is clean while MAME -
  // which latches these registers but ignores them ("many CRTC
  // writes" TODO) and hardcodes visible = 0..223 - shows the game's
  // scratch.
  //
  // Formulation: the SOURCE-line schedule is mode-independent - chip
  // line S always scans out at vcnt S+3, so every line keeps the
  // proven v12 render margin and the 4-bank rotation never collides
  // (a fixed 5-line lag at vfirst=0 lapped the banks - caught in
  // smoke sim, frames 0-102 fully stale). The RASTER window (vdisp,
  // which drives de/vsync) sits vfirst lines later, so raster row R
  // shows chip line R + vfirst; total display lag = 3 + vfirst lines
  // (317us at vfirst=2, invisible). Kicks cover [2, 224+vfirst).
  logic [7:0] crtc_vfirst;     // param 7 live (register write block)
  logic [7:0] crtc_vfirst_q;   // frame-latched copy (all consumers)
  wire [8:0] vsrc  = (vcnt >= 9'd3) ? vcnt - 9'd3 : vcnt + vlast - 9'd2;
  wire [8:0] vdisp = (vsrc >= 9'(crtc_vfirst_q))
                   ? vsrc - 9'(crtc_vfirst_q)
                   : vsrc + vlast + 9'd1 - 9'(crtc_vfirst_q);
  assign lb_scan_addr = {vsrc[1:0], hcnt[8:0]};

  // METRO: P_VBL_FOLLOWS_WINDOW = 1 moves the vblank interrupt and the sprite copy with the displayed window.  The game's CRTC window starts at chip line crtc_vfirst_q (11 on
  // every Metro board so far), so the last displayed chip line is 223 + vfirst and the renderer kicks lines up to there, while MAME's vblank interrupt (and the default
  // here) is at line 224: 11 lines before the end of the picture, so the 68000's vblank routine (scroll registers, palette fades, hundreds of writes) lands in the bottom 11 rows.
  // Build 20261007d did that move and the hardware test did not get better (tearing and flashes stayed), and MAME's write trace argues against it: the games do their per-frame
  // tile / sprite work in chip lines 0-10 (bucket A of work/b2/whenwr.lua; Dharma 36 tile words, Daitoride's cloud scroll) = exactly the lines the window of 11 hides, which only
  // fits an interrupt at 224; moved to 235 that work lands in visible lines 11-21.  So the default is 0 (MAME's timeline).  (Registered: crtc_vfirst_q changes once per frame.)
  localparam bit P_VBL_FOLLOWS_WINDOW = 1'b0;
  logic [8:0] vbl_line, spr_copy_line;
  always_ff @(posedge clk) begin
    vbl_line      <= P_VBL_FOLLOWS_WINDOW ? 9'(P_VBL_LINE) + 9'(crtc_vfirst_q) : (i_tall ? 9'd240 : 9'(P_VBL_LINE));
    // i_spr_early (Puzzli, MAME trace work/b2/sprlog.lua): the game writes the DEMO PLAY letters (8 sprites at sprite RAM 0x600) in lines 3-7 and wipes sprite RAM 0x600-0x7f8 in lines
    // 227-230 (all 64 entries, f8f8), so the copy at the last line (262) never saw them valid (letters came and went with the 68000's timing).  Copy at 224: everything the game wrote
    // for the frame (lines 3-83) is in, nothing of the wipe.  The renderer is still drawing the bottom lines (kicks up to 3 lines ahead of the window end 234) during the copy, so the
    // last rows (from about 226 on) may mix the old and the new list: Puzzli has only the DEAD LINE tile strip there.
    // METRO: the 240-line boards (i_tall: Karate Tournament, Lady Killer, ...) take the vblank interrupt at line 240, so the game's per-frame sprite work is not finished at the last
    // line (262): MAME's write trace of Karate's explosion has the sprite list at lines 248-269 and the sprite COUNT at lines 262-271 (it runs on into lines 0-9 of the next frame).
    // The copy at 262 took the new list with the OLD count (the sprites the new count adds are missing for a frame: the black rectangles of the explosion at every step of the
    // count: whole-machine sim frames 1190 / 1195; replay with the writes at their true lines: ~10,700 pixels off at each step, none with this).  These boards copy at
    // crtc_vfirst of the next frame instead (line 11 with the game's window): the copy takes 2,050 clocks, the renderer kicks chip line crtc_vfirst at hcnt 170 of that line
    // (2,720 clocks) and the lines before it are rendered but not displayed.  (MAME's own timeline lands the last count write at line 271.1 = 9.1 of the next frame.)
    // METRO (family F, i_roz_en): MAME's sprite RAM of these boards is BUFFERED (set_spriteram_buffered(true): the list is copied at the start of the vblank, line 224) and the games
    // write the next frame's list through the whole frame (Grand Striker 2's intro: 404 words a frame spread over lines 0-262).  A copy at the last line (262) sees a half-written new
    // list: the blocks / shards of the hardware video (replay of MAME frames 1160-1360: 53 of 100 pictures more than 500 pixels off, 7 with the copy at 224).  The copy is taken as
    // soon as the renderer has kicked the last displayed line (v_vis + crtc_vfirst: 224 with MAME's window, 235 with the game's CRTC window of 11).
    spr_copy_line <= i_spr_early ? 9'(P_VBL_LINE)
`ifdef F_COPY224
                   : i_roz_en ? 9'(P_VBL_LINE)
`else
                   : i_roz_en ? (v_vis + 9'(crtc_vfirst_q))
`endif
                   : (((!P_VBL_FOLLOWS_WINDOW && !i_tall) || crtc_vfirst_q == 8'd0) ? vlast : (i_tall ? 9'(crtc_vfirst_q) : 9'(crtc_vfirst_q) - 9'd1));
  end
  // METRO (I4100 boards): the tile table copy.  Lady Killer and Karate Tournament rewrite the whole 2 KB tile table with the 68000 every frame (tile definitions read from the graphics
  // ROM through the CPU window with the bank register toggled 26 times; MAME's trace: 2048 writes between lines 54 and 140, at a line that moves with the game's loop, MAME draws a
  // frame from the finished table) and the table passes through intermediate states (the whole-machine sim's mid-frame dumps: up to 780 of 1024 words differ from the final table at
  // lines 40-88).  Rendered live, the lines drawn while that happens show tiles of the wrong definitions: the strip of scrambled tiles at the top of Lady Killer's title picture (hardware
  // photo, sim frames 300-420), the torn / flashing explosion of Karate Tournament and the translucent panel of Lady Killer's instruction screens.  The copy is taken just after the last
  // line the renderer draws (v_vis + vfirst + 2), one word a clock through the live table's idle port B (1026 clocks, the renderer is idle then); the picture then uses the table as it
  // was at the end of the frame before (a frame older than MAME's, but every line from the same table).
  logic [10:0] tts_i;
  logic        tts_busy;
  wire  [8:0]  tts_line = v_vis + 9'(crtc_vfirst_q) + 9'd2;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      tts_busy <= 1'b0;
      tts_i    <= '0;
    end else if (line_start && next_v == tts_line && !tts_busy) begin
      tts_busy <= 1'b1;
      tts_i    <= '0;
    end else if (tts_busy) begin
      tts_i <= tts_i + 11'd1;
      if (tts_i == 11'd1025) tts_busy <= 1'b0;
    end
    tts_we_q <= tts_busy && (tts_i < 11'd1024);
    tts_wa_q <= tts_i[9:0];
  end
  assign tts_ra = tts_i[9:0];


  // METRO: palette latch.  Copy the live palette into the shadow (one word a clock, ~4100 clocks, well inside a line) just after the last displayed row (see pal_latch_line below):
  // the next frame is drawn from it.  The live palette's scan-out port serves the copy (the scan-out reads the shadow while latched).  Read data lags the address by 2 clocks (registered RAM q, pal_cp_q).
  logic [8:0] pal_latch_line;
  logic [8:0] pal_swap_line;
  always_ff @(posedge clk) begin
    // METRO (20261009e): copy right after the last displayed line (the display lags the line counter by 3 lines) instead of at the start of the next frame.  A game that clears and
    // reloads a palette bank across the vblank and the first lines of a frame (Doukyuusei Special's portraits: zeros written from line 239 of one frame to line 81 of the next, every
    // sixth frame) showed a black frame with the start-of-frame copy; MAME draws a frame at line 224 with the palette of that moment, which is what this snapshot is (one frame later).
`ifdef F_BUILD
    pal_latch_line <= v_vis + 9'(crtc_vfirst_q) + 9'd3;
`else
    pal_latch_line <= v_vis;                                     // MAME's render instant: the copy goes to the shadow the picture is not reading
    pal_swap_line  <= v_vis + 9'(crtc_vfirst_q) + 9'd4;         // after the last displayed line (the display lags the counter by 3)
    if (!rst_n)                                        pal_bank <= 1'b0;
    else if (line_start && next_v == pal_swap_line)    pal_bank <= ~pal_bank;
`endif
    if (!rst_n || !i_pal_latch) begin
      pal_cp_run <= 1'b0;
      pal_cp_cnt <= '0;
    end else if (line_start && next_v == pal_latch_line && !pal_cp_run) begin
      pal_cp_run <= 1'b1;
      pal_cp_cnt <= '0;
    end else if (pal_cp_run) begin
      pal_cp_cnt <= pal_cp_cnt + 13'd1;
      if (pal_cp_cnt == 13'd4097) pal_cp_run <= 1'b0;
    end
    pal_cp_q <= pal_scanout_q;
  end

  // ------------------------------------------------------------------
  // IRQ cause events
  // ------------------------------------------------------------------
  logic [31:0] bit5_timer;
  logic [5:0]  tick_cnt;     // METRO model: lines since the last periodic bit-4 tick
  // METRO: MAME's periodic interrupt is exactly 480 Hz; a line count (32 lines = 2.0894 ms, 2.0833 ms wanted) drifts 0.3 % and put a tick-driven fade of Pururun
  // one step off MAME's at frame 250.  With P_TICK_CLKS the tick is a clock count of its own (it restarts at reset, like MAME's device time).
  logic [17:0] tick_clk;
  wire         tick_fire = (P_TICK_CLKS != 0) ? (32'(tick_clk) == P_TICK_CLKS - 1) : (line_start && 32'(tick_cnt) == P_TICK_LINES - 1);
  logic  [2:0] tick_div;
  always_ff @(posedge clk) if (!rst_n) tick_div <= 3'd0; else if (tick_fire) tick_div <= tick_div + 3'd1;
  wire         tick_ev   = tick_fire && (!i_tick_slow || tick_div == 3'd7);
  always_ff @(posedge clk)
    if (!rst_n || P_TICK_CLKS == 0) tick_clk <= '0;
    else tick_clk <= (32'(tick_clk) == P_TICK_CLKS - 1) ? '0 : tick_clk + 1'b1;
  logic        irq_ack_w;
  logic [7:0]  irq_ack_data;
  logic        irq_en_w;
  logic [7:0]  irq_en_data;
  logic        blit_done;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      r_irq_cause  <= 8'h00;
      tick_cnt     <= '0;
      r_irq_enable <= 8'hFF;
      bit5_timer   <= 0;
      o_vbl_pulse  <= 1'b0;
    end else begin
      o_vbl_pulse <= 1'b0;
      // hardware set events
      if (P_IRQ_MODEL == 0) begin
        if (line_start) begin
          if (next_v == 9'd0) begin
            r_irq_cause[0] <= 1'b1;                 // vblank
            r_irq_cause[5] <= 1'b1;                 // vblank-window flag
            bit5_timer <= P_BIT5_CYCLES;
            o_vbl_pulse <= 1'b1;
          end else begin
            r_irq_cause[1] <= 1'b1;                 // hblank
            r_irq_cause[4] <= 1'b1;                 // per-line flag
          end
        end
      end else begin
        // METRO model (MAME 0.289)
        if (!i_scan_irq && !i_i4300 && P_TICK_CLKS != 0 && tick_ev) r_irq_cause[4] <= 1'b1;   // periodic tick (clock count)
        if (i_irq0_pulse) r_irq_cause[0] <= 1'b1;
        if (line_start) begin
          tick_cnt <= (32'(tick_cnt) == P_TICK_LINES - 1) ? '0 : tick_cnt + 1'b1;
          if (next_v == vbl_line) begin
            r_irq_cause[i_i4300 ? i_vbl_bit : 3'd0] <= 1'b1;   // vblank
            o_vbl_pulse <= 1'b1;
            // METRO: karatour_vblank_irq: at the start of the vblank the external interrupt (cause bit 5) is raised when the game has enabled it (screen control bit 8) and taken
            // back 1500 us later (the screen's vblank time), not by the CPU's acknowledge (the chip has no control over bits 5-7: only 4:0 clear)
            if (i_ext5 && r_ctrl[8]) begin
              r_irq_cause[5] <= 1'b1;
              bit5_timer <= 32'd144000;
            end
          end
          if (!i_scan_irq && !i_i4300 && P_TICK_CLKS == 0 && tick_ev) r_irq_cause[4] <= 1'b1;   // periodic tick (line count)
          if (i_scan_irq) begin
            if (next_v == vbl_line) r_irq_cause[4] <= 1'b1;                          // scanline 224: set_irq(4) with the vblank
            else if (next_v < 9'(P_VBL_LINE) && !r_irq_enable[1]) r_irq_cause[1] <= 1'b1;  // "hblank", every line while unmasked
          end
        end
      end
      if (blit_done) r_irq_cause[i_i4300 ? i_blit_bit : 3'd2] <= 1'b1;      // blitter done
      if (bit5_timer != 0) begin
        bit5_timer <= bit5_timer - 1;
        if (bit5_timer == 1) r_irq_cause[5] <= 1'b0;
      end
      // CPU acknowledge (clears bits 4:0 only); keep simultaneous hw sets
      if (irq_ack_w)
        r_irq_cause <= (r_irq_cause & ~(irq_ack_data & 8'h1F))
                       | (P_IRQ_MODEL == 0
                            ? (line_start ? (next_v == 9'd0 ? 8'h21 : 8'h12) : 8'h00)
                            : ((line_start && next_v == vbl_line ? (i_i4300 ? 8'(8'd1 << i_vbl_bit) : 8'h01) : 8'h00)
                               | (line_start && next_v == vbl_line && i_ext5 && r_ctrl[8] ? 8'h20 : 8'h00)
                               | (!i_scan_irq && !i_i4300 && tick_ev ? 8'h10 : 8'h00)
                               | (i_irq0_pulse ? 8'h01 : 8'h00)
                               | (line_start && i_scan_irq && next_v == vbl_line ? 8'h10 : 8'h00)
                               | (line_start && i_scan_irq && next_v < 9'(P_VBL_LINE) && !r_irq_enable[1] ? 8'h02 : 8'h00)))
                       | (blit_done ? (i_i4300 ? 8'(8'd1 << i_blit_bit) : 8'h04) : 8'h00);
      if (irq_en_w) r_irq_enable <= irq_en_data;
    end
  end

  // ------------------------------------------------------------------
  // renderer
  // ------------------------------------------------------------------
  logic        rnd_start;
  logic [7:0]  rnd_line;     // chip line the renderer works on
  logic [7:0]  rnd_row;      // METRO: display row the line is for (= rnd_line, or 223 - rnd_line when flipped)
  logic        rnd_flip;
  // scroll-window snapshot consumed by the current render (loaded from
  // the kick FIFO at pop; stable for the whole line even if the render
  // starts late under backlog or the CPU writes scroll mid-render)
  logic [15:0] rnd_sw_x [3];
  logic [15:0] rnd_sw_y [3];
  logic        rnd_busy, rnd_done;
  logic [15:0] rnd_vram_addr;
  logic [15:0] rnd_vram_q [3];
  logic [9:0]  rnd_tt_addr;
  logic [15:0] rnd_tt_q;
  logic [10:0] rnd_spr_addr;
  logic [15:0] rnd_spr_q;
  logic              rnd_rom_req;
  logic [GFX_AW-1:0] rnd_rom_addr;
  logic [6:0]        rnd_rom_len;
  logic              rnd_rom_valid;
  logic        lb_we;
  logic [8:0]  lb_x;
  logic [11:0] lb_pen;
  logic [1:0]  lb_bank;      // bank being written
  logic        rnd_overrun;  // debug: kick FIFO overflowed

  metro_render #(.GFX_AW(GFX_AW)) u_render (
    .clk(clk), .rst_n(rst_n),
    .i_start(rnd_start), .i_line(rnd_line), .i_flip(rnd_flip),
    .i_width(h_vis), .i_height(v_vis), .i_ext_tiles(!i_i4100),
    .o_pst_addr(rnd_pst_addr), .i_pst_data(pst_rnd_q),
    .i_pst_valid(pst_valid),
    .o_busy(rnd_busy), .o_done(rnd_done),
    .i_layer_pri(r_layer_pri),
    .i_bg_color(r_bg), .i_roz_pen(i_roz_pen), .i_roz_op(i_roz_op), .o_roz_addr(o_roz_x),
    .i_screen_ctrl(r_ctrl),
    .i_window_x(rs_window_x), .i_window_y(rs_window_y),
    .i_sw_x(rnd_sw_x), .i_sw_y(rnd_sw_y),
    .i_spr_count(spr_count_q), .i_spr_pri(r_spr_pri),
    .i_spr_xoff(r_spr_xoff), .i_spr_yoff(r_spr_yoff),
    .i_spr_color(r_spr_color),
    .i_screen_xoff(r_scr_xoff), .i_screen_yoff(r_scr_yoff),
    .i_gfx_size(i_gfx_size),
    .o_vram_addr(rnd_vram_addr), .i_vram_data(rnd_vram_q),
    .o_tt_addr(rnd_tt_addr), .i_tt_data(rnd_tt_q),
    .o_spr_addr(rnd_spr_addr), .i_spr_data(rnd_spr_q),
    .o_rom_req(rnd_rom_req), .o_rom_addr(rnd_rom_addr), .o_rom_len(rnd_rom_len),
    .i_rom_data(i_rom_data), .i_rom_valid(rnd_rom_valid),
    .o_lb_we(lb_we), .o_lb_x(lb_x), .o_lb_pen(lb_pen),
    .o_dbg_used_sx2_0(o_dbg_rend_sx2_0),
    .o_dbg_used_sx2_1(o_dbg_rend_sx2_1),
    .o_dbg_used_sx2_2(o_dbg_rend_sx2_2)
  );

  // v9 kick: line N is queued at h0 of game line N with a SNAPSHOT of
  // the scroll-window registers taken at that instant. Every CPU write
  // made through the end of line N-1 - including the game's per-line
  // raster slot at h36-100 of N-1 and the vblank parks - is in the
  // snapshot; nothing later can leak in (the renderer consumes the
  // snapshot, not the live registers). The beam displays line N during
  // game line N+1 (vdisp above), so the render lead is a full line
  // (5088 cycles), the same margin as the soak-proven h0 kick of the
  // line-ahead era. Elastic kick with a 4-deep FIFO and 4 line-buffer
  // banks: bursts of slow (sprite-dense) lines borrow time from cheap
  // neighbours and the vblank gap. Banks are line[1:0], display reads
  // bank vdisp[1:0].
  // Frame parity rides through the kick FIFO so completed lines can be
  // tagged with the frame they belong to (scan-out blanking below).
  // Toggled at vlast-1, two lines before line 0's kick is queued.
  logic       frame_par;
  logic       cur_par;       // parity of the line currently rendering
  // METRO: screen flip (screen control bit 0), latched per frame like the CRTC window. Flipped, display row S shows chip line 223 - S
  // (the FIFO carries the display row; the line is reversed at the pop), mirrored in X by the renderer. The window is MAME's 0..223
  // while flipped. MAME's flip mirrors the whole 392 x 263 raster, so unaided the layer scroll gets +72 (X) / +39 (Y) = raster minus
  // visible size (tools/metro_flipcheck.py) and the 72 columns / 39 rows of off-screen margin come into view (garbage tiles on a real
  // board). MAME's own flip offsets (set_tmap_flip_x/yoffsets, set for Varia Metal as raster minus visible size, "aligned properly")
  // cancel exactly that shift: the layers mirror about the visible area like the sprites do. FLIP_MAME_SHIFT = 1 gives MAME's default.
  localparam FLIP_MAME_SHIFT = 0;
  logic       flip_q;
  // METRO: the Flip Screen DIP (i_flip_force) flips at once, and switching it off must unflip at once as well, but a game that read the DIP while it was on (Sky Alert does, at its start)
  // keeps writing the flip bit (screen control bit 0) = 1 from its own RAM until it reads the DIP again.  So when the DIP goes off, the game's flip bit is ignored until the game writes
  // a 0 there itself (a game that sets it for another reason sets it again after that).
  logic       flip_force_q, flip_stale;
  wire        flip_game = r_ctrl[0] && !flip_stale;
  // METRO: i_tmap_dx = the board's tilemap X offset (MAME set_tmap_xoffsets, 2 on Daitoride / Puzzli; MAME sets the flip offset to its negative,
  // so the layers' X scroll gets +i_tmap_dx flipped and not).
  wire [15:0] flip_dx = {12'd0, i_tmap_dx} + ((flip_q && FLIP_MAME_SHIFT != 0) ? 16'd72 : 16'd0);
  wire [15:0] flip_dy = (flip_q && FLIP_MAME_SHIFT != 0) ? 16'd39 : 16'd0;
  // Snapshot rides INSIDE the FIFO word: {par, line[8:0], y2,x2,y1,x1,y0,x0}.
  // v9 used separate 2-D unpacked arrays (kick_sw_x[0:3][3]) and Quartus
  // 17.0 mis-synthesized them - hardware delivered another register's
  // value to the line-0/1 renders (measured via the overlay telemetry,
  // 2026-07-18) while Verilator matched the RTL. A 1-D array of one
  // packed word is the same construct the FIFO itself already proves.
  logic [106:0] kick_fifo [0:7];     // {flip, par, row[8:0], y2, x2, y1, x1, y0, x0}
  logic [106:0] pop_word;        // two-stage pop staging (see pop below)
  logic         pop_pend;
  logic [2:0] kf_wr, kf_rd;
  logic [3:0] kf_cnt;
  // METRO (family F): a row is kicked to the renderer once the 053936 plane has drawn it (rows of the frame before are not held)
  // The plane may run up to six rows ahead of "the row the renderer wants next": the row after the one it started last, or, when kicks are queued, the row of the kick at the
  // head of the FIFO.  (A count of the rows started was the first version: after the kick FIFO overflowed and dropped some kicks, the later ones named rows far ahead of the
  // count, the plane stopped six rows after it and the renderer waited for rows the plane would not make until the next frame: whole frames of the background pen, the brown
  // fill after a goal, hardware test of 20261011d.)
  logic [8:0] roz_used_q;
  wire        head_cur = (kf_cnt != 4'd0) && (kick_fifo[kf_rd][105] == frame_par);
  wire  [8:0] head_row = {1'b0, kick_fifo[kf_rd][96 +: 8]};
  assign o_roz_used = (head_cur && head_row > roz_used_q) ? head_row : roz_used_q;
  wire        roz_ok = !i_roz_en || (kick_fifo[kf_rd][105] != frame_par) || ({1'b0, kick_fifo[kf_rd][96 +: 8]} < i_roz_done);
  // v12.2: no re-kick (v12.1's re-render doubled renderer load exactly
  // in the heaviest frames on silicon - the late writes cluster where
  // load peaks - and caused tearing). Instead every line samples ONCE,
  // late in its own line (h170), past the measured slip window. On
  // schedule that consumes the just-in-time value written during the
  // line itself (the PCB shows that value for most of the line's
  // pixels anyway); under load it still catches writes up to ~1.4
  // lines late. Single render per line - same load as v12.
  //
  // v14: the game runs TWO write disciplines (measured in sim and
  // with the silicon write-landing histogram, 2026-07-19). sy0/sy2
  // are per-line ladder registers, rewritten every line at h34-76 and
  // on schedule even on silicon; sx0/sx1/sx2/sy1 arrive in a
  // once-per-frame block during line 0 (h185-270 in sim, landing as
  // late as (1,h160) on silicon). Sampling lines 0/1 wholly at
  // (1,h200/208) catches the late block (the v12 clouds fix) but
  // hands line 0 the sy ladder write meant for line 1 - harmless on a
  // smooth ramp (<=2px), but the stage-2 boss tail writes a per-frame
  // sy outlier at (1,h~44) jumping up to 191px, so line 0 painted the
  // boss zone a full line early for the last ~5s of the scene. Fix:
  // sy0/sy2 for EVERY line come from that line's own h170 view
  // (stashed at (0,h170)/(1,h170) for the two early kicks); only the
  // block class keeps the (1,h200/208) view on lines 0/1.
  logic [15:0] lad_y0_l0, lad_y2_l0;   // sy0/sy2 view at (0,h170)
  logic [15:0] lad_y0_l1, lad_y2_l1;   // sy0/sy2 view at (1,h170)
  always_ff @(posedge clk) begin
    logic kf_push, kf_pop;
    kf_push = 1'b0; kf_pop = 1'b0;
    if (!rst_n) begin
      rnd_start <= 1'b0;
      rnd_overrun <= 1'b0;
      o_roz_frame <= 1'b0;
      roz_used_q <= '0;
      o_dbg_ovr <= '0;
      kf_wr <= '0;
      kf_rd <= '0;
      kf_cnt <= '0;
      pop_pend <= 1'b0;
      frame_par <= 1'b0;
      crtc_vfirst_q <= 8'd0;
      flip_q <= 1'b0;
    end else begin
      rnd_start <= 1'b0;
      o_roz_frame <= 1'b0;
      if (ce_pix && hcnt == 9'd0 && vcnt == vlast - 9'd1) begin
        frame_par <= ~frame_par;
        o_roz_frame <= 1'b1;
        roz_used_q <= 9'd0;
        crtc_vfirst_q <= (i_win_mame || flip_game || i_flip_force) ? 8'd0 : crtc_vfirst;   // window stable per frame (METRO: i_win_mame forces MAME's 0..223)
        flip_q <= flip_game || i_flip_force;
      end
      // queue lines 2..223 at their own h170 (past the measured write
      // slip); lines 0 and 1 queue at (1,h200)/(1,h208), after the
      // measured frame-top landing
      // v14 ladder-class stash: sy0/sy2 as each top line's own beam
      // would have seen them (their writes land h34-76, always on time)
      if (ce_pix && hcnt == 9'd170 && vcnt == 9'd0) begin
        lad_y0_l0 <= rs_sw_y[0];
        lad_y2_l0 <= rs_sw_y[2];
      end
      if (ce_pix && hcnt == 9'd170 && vcnt == 9'd1) begin
        lad_y0_l1 <= rs_sw_y[0];
        lad_y2_l1 <= rs_sw_y[2];
      end
      begin
        logic       do_push;
        logic [8:0] push_line;
        logic [15:0] push_y0, push_y2;
        do_push = 1'b0; push_line = vcnt;
        push_y0 = rs_sw_y[0]; push_y2 = rs_sw_y[2];
        if (ce_pix) begin
          // v15: kick range covers the shifted window [2, 224+vfirst)
          if (hcnt == 9'd170 && 32'(vcnt) >= 2 &&
              32'(vcnt) < 32'(v_vis) + 32'(crtc_vfirst_q))
            do_push = 1'b1;
          if (vcnt == 9'd1) begin
            if (hcnt == 9'd200) begin
              do_push = 1'b1; push_line = 9'd0;
              push_y0 = lad_y0_l0; push_y2 = lad_y2_l0;
            end
            if (hcnt == 9'd208) begin
              do_push = 1'b1; push_line = 9'd1;
              push_y0 = lad_y0_l1; push_y2 = lad_y2_l1;
            end
          end
        end
        if (do_push) begin
          if (kf_cnt == 4'd8) begin
            rnd_overrun <= 1'b1;                   // hopelessly behind
            o_dbg_ovr <= o_dbg_ovr + 16'd1;
          end else begin
            kick_fifo[kf_wr] <= {flip_q, frame_par, push_line,
                                 push_y2 + flip_dy, rs_sw_x[2] + flip_dx,
                                 rs_sw_y[1] + flip_dy, rs_sw_x[1] + flip_dx + {12'd0, i_tmap_dx1},
                                 push_y0 + flip_dy, rs_sw_x[0] + flip_dx};
            kf_wr <= kf_wr + 3'd1;
            kf_push = 1'b1;
          end
        end
      end
      // Two-stage pop: latch the FIFO word first, hand it to the
      // renderer a cycle later. The FIFO-mux read and every consumer
      // load are thereby separated into reg->reg moves (1 extra clk of
      // kick latency against a 5088-clk budget).
      if (kf_cnt != 0 && !rnd_busy && !rnd_start && !pop_pend && roz_ok) begin
        pop_word <= kick_fifo[kf_rd];
        pop_pend <= 1'b1;
        kf_rd <= kf_rd + 3'd1;
        kf_pop = 1'b1;
      end
      if (pop_pend) begin
        pop_pend  <= 1'b0;
        rnd_start <= 1'b1;
        if (pop_word[105] == frame_par) roz_used_q <= {1'b0, pop_word[96 +: 8]} + 9'd1;
        rnd_row   <= pop_word[96 +: 8];
        rnd_line  <= pop_word[106] ? (8'd223 - pop_word[96 +: 8]) : pop_word[96 +: 8];
        rnd_flip  <= pop_word[106];
        lb_bank   <= pop_word[96 +: 2];        // banks follow the display row
        cur_par   <= pop_word[105];
        {rnd_sw_y[2], rnd_sw_x[2],
         rnd_sw_y[1], rnd_sw_x[1],
         rnd_sw_y[0], rnd_sw_x[0]} <= pop_word[95:0];
      end
      // single counter update: a same-edge push+pop must net ZERO. The
      // old two-assignment form lost the push (last write won), so the
      // count drifted low during saturated sections until pops stalled
      // with entries queued, the write pointer lapped the read pointer,
      // and the renderer was fed stale line numbers forever - the
      // permanent post-demo blackout found in the 5200-frame soak.
      unique case ({kf_push, kf_pop})
        2'b10:   kf_cnt <= kf_cnt + 3'd1;
        2'b01:   kf_cnt <= kf_cnt - 3'd1;
        default: ;
      endcase
    end
  end

  // linebuf and tiletable reads handled by BRAM wrappers above

  // renderer-side memory ports (vram port B wired in instances above)
  assign rnd_tt_q = fix_tall ? tts_q : tt_rnd_q;

  // sprite RAM renderer port: always the copy (P_SPR_BUFFERED=1: copied at vblank start; 0: copied at the start of the last line, see METRO note below)
  assign rnd_spr_q = spr_buf_q;

  // ------------------------------------------------------------------
  // sprite buffer copy at vblank start (line V_VIS, after last visible)
  // ------------------------------------------------------------------
  logic        cp_run;
  logic [11:0] cp_cnt;
  logic [15:0] cp_q;

  // read data lags cp_cnt by TWO cycles (registered BRAM q, then cp_q),
  // so the write address must lag by two as well: source word k is read
  // at cnt k, in spr_live_b_q at k+1, in cp_q at k+2, written at cnt k+2
  assign spr_live_b_addr = cp_cnt[10:0];
  assign spr_buf_a_addr  = 11'(cp_cnt - 12'd2);
  assign spr_buf_a_d     = cp_q;
  assign spr_buf_a_we    = cp_run && (cp_cnt >= 12'd2);

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      cp_run <= 1'b0;
      cp_cnt <= '0;
      spr_count_q <= '0;
      for (int i = 0; i < 6; i++) begin r_window_q[i] <= '0; r_scroll_q[i] <= '0; end
    end else begin
      // METRO: upstream only had the buffered path (copy at vblank start, so sprites show one frame late; Hyper Duel's MAME model).
      // Metro boards use MAME's UNBUFFERED sprite RAM (live at render time).  This architecture renders from the copy, so for
      // P_SPR_BUFFERED = 0 the copy is taken at the start of the LAST line of the frame (vcnt = vlast): it finishes (~2050 clocks,
      // less than a line) before line 0's render kick, and the frame shows the sprite RAM as the game left it for that frame.
      // This equals live sprite RAM whenever the game finishes its sprite updates before the visible area starts.
      if (line_start && ((P_SPR_BUFFERED && next_v == v_vis) || (!P_SPR_BUFFERED && next_v == spr_copy_line))) begin
        cp_run <= 1'b1;
        cp_cnt <= '0;
        spr_count_q <= r_spr_count;
        for (int i = 0; i < 6; i++) begin r_window_q[i] <= r_window[i]; r_scroll_q[i] <= r_scroll[i]; end
      end else if (cp_run) begin
        cp_q <= spr_live_b_q;
        if (cp_cnt == 12'd2049) cp_run <= 1'b0;
        cp_cnt <= cp_cnt + 12'd1;
      end
    end
  end

  // ------------------------------------------------------------------
  // sprite prescan snoop: as sprite words stream through cp_q, compute
  // each sprite's raw y extent (bit-identical ohv arithmetic to the
  // renderer's ST_S_ZOOM/COVER stages, sprite words only - screen
  // offsets are applied live in the renderer) and write one table entry
  // per sprite. Entry k is written after words 4k..4k+3 have landed in
  // spr_buf, so table and buffer stay consistent.
  // ------------------------------------------------------------------
  // sprite zoom table copy (spec sec 7.1), comb ROM
  function automatic logic [11:0] ztab_of(input logic [5:0] z);
    unique case (z)
      6'd0:  ztab_of = 12'hAAC; 6'd1:  ztab_of = 12'h800;
      6'd2:  ztab_of = 12'h668; 6'd3:  ztab_of = 12'h554;
      6'd4:  ztab_of = 12'h494; 6'd5:  ztab_of = 12'h400;
      6'd6:  ztab_of = 12'h390; 6'd7:  ztab_of = 12'h334;
      6'd8:  ztab_of = 12'h2E8; 6'd9:  ztab_of = 12'h2AC;
      6'd10: ztab_of = 12'h278; 6'd11: ztab_of = 12'h248;
      6'd12: ztab_of = 12'h224; 6'd13: ztab_of = 12'h200;
      6'd14: ztab_of = 12'h1E0; 6'd15: ztab_of = 12'h1C8;
      6'd16: ztab_of = 12'h1B0; 6'd17: ztab_of = 12'h198;
      6'd18: ztab_of = 12'h188; 6'd19: ztab_of = 12'h174;
      6'd20: ztab_of = 12'h164; 6'd21: ztab_of = 12'h154;
      6'd22: ztab_of = 12'h148; 6'd23: ztab_of = 12'h13C;
      6'd24: ztab_of = 12'h130; 6'd25: ztab_of = 12'h124;
      6'd26: ztab_of = 12'h11C; 6'd27: ztab_of = 12'h110;
      6'd28: ztab_of = 12'h108; 6'd29: ztab_of = 12'h100;
      6'd30: ztab_of = 12'h0F8; 6'd31: ztab_of = 12'h0F0;
      6'd32: ztab_of = 12'h0EC; 6'd33: ztab_of = 12'h0E4;
      6'd34: ztab_of = 12'h0DC; 6'd35: ztab_of = 12'h0D8;
      6'd36: ztab_of = 12'h0D4; 6'd37: ztab_of = 12'h0CC;
      6'd38: ztab_of = 12'h0C8; 6'd39: ztab_of = 12'h0C4;
      6'd40: ztab_of = 12'h0C0; 6'd41: ztab_of = 12'h0BC;
      6'd42: ztab_of = 12'h0B8; 6'd43: ztab_of = 12'h0B4;
      6'd44: ztab_of = 12'h0B0; 6'd45: ztab_of = 12'h0AC;
      6'd46: ztab_of = 12'h0A8; 6'd47: ztab_of = 12'h0A4;
      6'd48: ztab_of = 12'h0A0; 6'd49: ztab_of = 12'h09C;
      6'd50: ztab_of = 12'h098; 6'd51: ztab_of = 12'h094;
      6'd52: ztab_of = 12'h090; 6'd53: ztab_of = 12'h08C;
      6'd54: ztab_of = 12'h088; 6'd55: ztab_of = 12'h080;
      6'd56: ztab_of = 12'h078; 6'd57: ztab_of = 12'h070;
      6'd58: ztab_of = 12'h068; 6'd59: ztab_of = 12'h060;
      6'd60: ztab_of = 12'h058; 6'd61: ztab_of = 12'h050;
      6'd62: ztab_of = 12'h048; default: ztab_of = 12'h040;
    endcase
  endfunction

  // cp_q holds word w = cp_cnt-2; sprite k's words w = 4k..4k+3.
  // w%4==0 -> dis, w%4==1 -> y/zoom, w%4==2 -> h, w%4==3 -> multiply and
  // arm the write; the write itself fires one cycle later (past cp_run
  // for the last sprite, hence the registered strobe).
  logic        ps_dis;
  logic [9:0]  ps_y;
  logic [11:0] ps_zoom;
  logic [6:0]  ps_h;
  logic [30:0] ps_ohf;
  wire  [11:0] ps_w = cp_cnt - 12'd2;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      pst_we    <= 1'b0;
      pst_valid <= 1'b0;
    end else begin
      pst_we <= 1'b0;
      if (cp_run && cp_cnt >= 12'd2) begin
        unique case (ps_w[1:0])
          2'd0: ps_dis <= (cp_q[15:11] == 5'h1F);
          2'd1: begin
            ps_y    <= cp_q[9:0];
            ps_zoom <= ztab_of(cp_q[15:10]);
          end
          2'd2: ps_h <= (7'(cp_q[10:8]) + 7'd1) << 3;
          default: begin
            ps_ohf    <= 31'({ps_zoom, 8'd0}) * 31'(ps_h) + 31'h8000;
            pst_we    <= 1'b1;
            pst_waddr <= ps_w[10:2];
          end
        endcase
      end
      // renderer may use the table only once a full copy has refreshed it
      if (pst_we && pst_waddr == 9'd511) pst_valid <= 1'b1;
    end
  end

  // y_end = y + ohv; ohv <= 683 (max zoom x max height), so 11 bits hold it
  assign pst_wdata = {2'b00, ps_dis,
                      11'(ps_y) + 11'(ps_ohf[27:16]), ps_y};

  // ------------------------------------------------------------------
  // blitter
  // ------------------------------------------------------------------
  logic        bl_start;
  logic        bl_start_h;                   // P_VLOG: the blitter's start is held until the layer RAM log is applied (its writes go to the RAM directly)
  logic        bl_start_go;
  // METRO (I4300 boards): the blitter is held while the renderer reads the tile RAM (chip lines crtc_vfirst .. v_vis + crtc_vfirst, each kicked at its own line).  The portrait
  // animations of Doukyuusei / Doukyuusei Special / Mouja are blits into the tile RAM that the game starts at line ~137 (MAME's trace: the blitter registers at 136.8 - 145) while the
  // picture is drawn; MAME shows the finished state, the live renderer showed a band of old rows over new ones for a frame: the blinking line of the hardware videos.  The start is
  // accepted at once (the registers are latched), the blit runs and finishes outside the window, the done interrupt follows it.
  wire         bl_hold = i_i4300 && (vcnt >= 9'(crtc_vfirst_q)) && (vcnt <= v_vis + 9'(crtc_vfirst_q));
  // METRO (I4300 boards, 20261014): the blit queue below feeds the blitter (bq_go + bq_h_*) and raises the done interrupt like MAME's 500 us timer.
  logic        bq_go;                        // pulse: the blitter starts from bq_h_*
  logic [1:0]  bq_h_tmap;
  logic [31:0] bq_h_src;
  logic [23:0] bq_h_dst;
  logic        bq_force;                     // run the queued blits now (the 68000 wants the tile RAM, or the queue is full)
  logic        bl_done_raw;
  logic              bl_rom_rd;
  logic [GFX_AW-1:0] bl_rom_addr;
  logic [15:0]       bl_rom_data;
  logic              bl_rom_valid;
  logic        bl_we;
  logic [1:0]  bl_layer;
  logic [15:0] bl_addr, bl_wdata, bl_wmask;
  logic        bl_busy;

  metro_blitter #(.GFX_AW(GFX_AW)) u_blit (
    .clk(clk), .rst_n(rst_n),
    .i_start(i_i4300 ? bq_go : bl_start_go), .i_hold(bl_hold && !bq_force),
    .i_tmap(i_i4300 ? {30'd0, bq_h_tmap} : {blit_regs[0], blit_regs[1]}),
    .i_src (i_i4300 ? bq_h_src           : {blit_regs[2], blit_regs[3]}),
    .i_dst (i_i4300 ? {8'd0, bq_h_dst}   : {blit_regs[4], blit_regs[5]}),
    .o_rom_rd(bl_rom_rd), .o_rom_addr(bl_rom_addr),
    .i_rom_data(bl_rom_data), .i_rom_valid(bl_rom_valid),
    .o_vram_we(bl_we), .o_vram_layer(bl_layer), .o_vram_addr(bl_addr),
    .o_vram_wdata(bl_wdata), .o_vram_wmask(bl_wmask),
    .o_busy(bl_busy), .o_done(bl_done_raw)
  );
  assign bl_rom_data = i_rom_data;        // METRO: the blitter reads 16 aligned bytes at a time (8 words)

  // ------------------------------------------------------------------
  // GFX ROM arbiter: renderer > CPU window > blitter > the 053936 plane's tile blocks (METRO: family F)
  // ------------------------------------------------------------------
  typedef enum logic [2:0] {GR_NONE, GR_RND, GR_CPU, GR_BLT, GR_ROZ} grant_e;
  grant_e      gr;
  logic [6:0]  gr_left;

  // pending latches
  logic              rp_pend;
  logic [GFX_AW-1:0] rp_addr;
  logic [6:0]        rp_len;
  logic              cp_pend;        // CPU window read pending
  logic [GFX_AW-1:0] cpw_addr;
  logic              bl_rd_d;
  logic              bp_pend;
  logic [GFX_AW-1:0] bp_addr;

  logic        cpu_gfx_req;          // pulse from bus FSM
  logic [GFX_AW-1:0] cpu_gfx_addr;
  logic [15:0] cpu_gfx_data;
  logic        cpu_gfx_done;
  logic [1:0]  cpu_gfx_cnt;
  // sequential-read prefetch: the word after the requested one
  logic [15:0] cpu_pf_data;
  logic [GFX_AW-1:0] cpu_pf_tag;
  logic        cpu_pf_valid;

  // the plane engine's burst (metro_roz.sv v2: a 64-byte window of the tile map RAM, a 16 / 8-byte tile row): one word-mode request; o_roz_wr / idx / data carry the
  // words, o_roz_ack the end (with the last word)
  logic              rz_req_q, rz_pend;
  logic [GFX_AW:0]   rz_addr;
  logic  [6:0]       rz_len;
  logic  [4:0]       rz_w;
  assign o_roz_bank = rnd_row[2:0];
  assign rnd_rom_valid = i_rom_valid && (gr == GR_RND);
  assign bl_rom_valid  = i_rom_valid && (gr == GR_BLT);

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      gr <= GR_NONE;
      rp_pend <= 1'b0;
      cp_pend <= 1'b0;
      bp_pend <= 1'b0;
      bl_rd_d <= 1'b0;
      o_rom_req <= 1'b0;
      cpu_gfx_done <= 1'b0;
      cpu_pf_valid <= 1'b0;
      rz_req_q <= 1'b0; rz_pend <= 1'b0; rz_w <= 5'd0;
      o_roz_wr <= 1'b0; o_roz_ack <= 1'b0;
    end else begin
      o_rom_req <= 1'b0;
      cpu_gfx_done <= 1'b0;
      bl_rd_d <= bl_rom_rd;
      o_roz_wr <= 1'b0; o_roz_ack <= 1'b0;
      rz_req_q <= i_roz_req;
      if (i_roz_req && !rz_req_q && !rz_pend) begin rz_pend <= 1'b1; rz_addr <= i_roz_addr; rz_len <= i_roz_len; rz_w <= 5'd0; end

      if (rnd_rom_req) begin
        rp_pend <= 1'b1;
        rp_addr <= rnd_rom_addr;
        rp_len  <= rnd_rom_len;
      end
      if (cpu_gfx_req) begin
        cp_pend <= 1'b1;
        cpw_addr <= cpu_gfx_addr;
        cpu_gfx_cnt <= 2'd0;
      end
      if (bl_rom_rd && !bl_rd_d) begin
        bp_pend <= 1'b1;
        bp_addr <= bl_rom_addr;
      end

      // gr_left counts VALID PULSES: word-mode requests (renderer, CPU
      // window - always even addr/len) get len/2 pulses of 2 bytes each;
      // the blitter's 1-byte reads get 1 pulse.
      if (gr == GR_NONE) begin
        if (i_roz_prio && rz_pend) begin
          gr <= GR_ROZ;
          o_rom_req  <= 1'b1;
          o_rom_addr <= rz_addr;
          o_rom_len  <= rz_len;
          gr_left    <= rz_len >> 1;
        end else if (rp_pend || rnd_rom_req) begin
          gr <= GR_RND;
          o_rom_req  <= 1'b1;
          o_rom_addr <= rnd_rom_req ? rnd_rom_addr : rp_addr;
          o_rom_len  <= rnd_rom_req ? rnd_rom_len : rp_len;
          gr_left    <= (rnd_rom_req ? rnd_rom_len : rp_len) >> 1;
          rp_pend <= 1'b0;
        end else if (cp_pend || cpu_gfx_req) begin
          gr <= GR_CPU;
          o_rom_req  <= 1'b1;
          o_rom_addr <= cpu_gfx_req ? cpu_gfx_addr : cpw_addr;
          if (cpu_gfx_req) cpw_addr <= cpu_gfx_addr;
          o_rom_len  <= 7'd4;        // word + prefetch of the next word
          gr_left    <= 7'd2;        // 2 word pulses
          cp_pend <= 1'b0;
          cpu_gfx_cnt <= 2'd0;
        end else if (bp_pend || (bl_rom_rd && !bl_rd_d)) begin
          gr <= GR_BLT;
          o_rom_req  <= 1'b1;
          o_rom_addr <= (bl_rom_rd && !bl_rd_d) ? bl_rom_addr : bp_addr;
          o_rom_len  <= 7'd16;
          gr_left    <= 7'd8;
          bp_pend <= 1'b0;
        end else if (rz_pend) begin
          gr <= GR_ROZ;
          o_rom_req  <= 1'b1;
          o_rom_addr <= rz_addr;
          o_rom_len  <= rz_len;
          gr_left    <= rz_len >> 1;
        end
      end else if (i_rom_valid) begin
        if (gr == GR_CPU) begin
          if (cpu_gfx_cnt == 2'd0) begin
            cpu_gfx_data <= i_rom_data;
            cpu_gfx_done <= 1'b1;
          end else begin
            cpu_pf_data  <= i_rom_data;
            cpu_pf_tag   <= GFX_AW'(32'(cpw_addr) + 2);
            cpu_pf_valid <= 1'b1;
          end
          cpu_gfx_cnt <= cpu_gfx_cnt + 2'd1;
        end
        if (gr == GR_ROZ) begin
          o_roz_wr   <= 1'b1;
          o_roz_idx  <= rz_w;
          o_roz_data <= i_rom_data;
          rz_w       <= rz_w + 5'd1;
          if (gr_left == 7'd1) begin
            rz_w <= 5'd0;
            rz_pend <= 1'b0; o_roz_ack <= 1'b1;
          end
        end
        if (gr_left == 7'd1) gr <= GR_NONE;
        else gr_left <= gr_left - 7'd1;
      end
    end
  end

`ifdef ROZ_PROBE
  // simulation only: clocks from the plane engine's request to its first word, per frame (count, mean, max)
  longint zp_n = 0, zp_sum = 0, zp_max = 0, zp_t = 0, zp_rd = 0;
  logic   zp_wait = 1'b0;
  always_ff @(posedge clk) begin
    zp_t <= zp_t + 1;
    if (i_roz_req && !rz_req_q && !rz_pend) begin zp_wait <= 1'b1; zp_rd <= zp_t; end
    if (zp_wait && gr == GR_ROZ && i_rom_valid) begin
      zp_wait <= 1'b0; zp_n <= zp_n + 1; zp_sum <= zp_sum + (zp_t - zp_rd); if ((zp_t - zp_rd) > zp_max) zp_max <= zp_t - zp_rd;
    end
    if (o_roz_frame) begin
      $display("ROZP frame: %0d requests, mean %0d clk, max %0d clk to the first word", zp_n, zp_n ? zp_sum / zp_n : 0, zp_max);
      zp_n <= 0; zp_sum <= 0; zp_max <= 0;
    end
  end
`endif

  // ------------------------------------------------------------------
  // CPU bus interface
  // ------------------------------------------------------------------
  typedef enum logic [2:0] {B_IDLE, B_RD1, B_RD2, B_GFX, B_ACK} bst_e;
  bst_e bst;

  // decode
  wire in_vram    = (i_addr < 19'h60000);
  wire [1:0] vlyr = i_addr[18:17];
  wire in_gfxwin  = (i_addr[18:16] == 3'b110);            // 0x60000-0x6FFFF
  wire in_scratch = (i_addr[18:13] == 6'b111000);          // 0x70000-0x71FFF
  wire in_pal     = (i_addr[18:13] == 6'b111001);          // 0x72000-0x73FFF
  wire in_spr     = (i_addr[18:12] == 7'b1110100);         // 0x74000-0x74FFF
  wire in_rmw     = (i_addr >= 19'h75000 && i_addr < 19'h78000);

  // ------------------------------------------------------------------
  // I4300 blit queue (METRO, 20261014)
  // ------------------------------------------------------------------
  // MAME runs a blit the moment its trigger register (0x7884C) is written, and renders a frame at line v_vis: the picture holds every blit started before that line and none
  // after it, whole.  The games do not wait for the done interrupt (Gakuensai writes no acknowledge; it paces its blits, hi / lo byte lane of one picture and a few small
  // patches, 8 lines apart by a software delay), so a blit that ran at once, or was held and queued one deep (20261010c), either changed the tile RAM under the beam (the
  // two lanes of a picture or of the mouth patch half done: scrambled blocks for a frame) or, behind a held blit, was dropped (the mouth patch stayed old).  The queue keeps every
  // started blit (registers captured at the trigger) and releases them at the palette snapshot's instant (line v_vis): those start once the beam has left the picture
  // (lines after v_vis + crtc_vfirst) and run in order, so a picture shows all the blits of a frame or none, with the palette that goes with them.  A 68000 access to the tile RAM, or a
  // trigger with the queue full, runs the queue at once (order kept; that picture tears as before).  The done interrupt follows the trigger by 500 us, as MAME's timer does
  // (a trigger within the 500 us re-arms it).  Other boards are untouched.
  localparam int BQ_DEPTH = 8;
  (* ramstyle = "MLAB" *) logic [57:0] bq_mem [0:BQ_DEPTH-1];
  logic [2:0]  bq_wp, bq_rp;
  logic [3:0]  bq_cnt, bq_rel;
  logic [15:0] bq_irq_cnt;
  logic        bq_irq;
  wire         bq_tmap_ok = ({blit_regs[0], blit_regs[1]} >= 32'd1) && ({blit_regs[0], blit_regs[1]} <= 32'd3);
  wire         bq_push = i_i4300 && bl_start && bq_tmap_ok;
  wire         bq_pend = i_i4300 && (bq_cnt != 4'd0 || bq_go);
  wire         bq_full = (bq_cnt == 4'(BQ_DEPTH));
  wire         bq_trig = i_i4300 && i_cs && !i_rnw && ((i_addr & 19'h7FFFE) == 19'h7884C);   // the trigger write the 68000 is making
  wire         bq_cpu  = i_i4300 && i_cs && (in_vram || in_rmw);
  assign       bq_force = (bq_cpu && bq_pend) || (bq_trig && bq_full);
  wire         bq_pop  = i_i4300 && (bq_cnt != 4'd0) && !bl_busy && !bq_go && ((bq_rel != 4'd0 && !bl_hold) || bq_force);
  wire         bq_t    = line_start && (next_v == v_vis);                                  // MAME's render instant (the palette snapshot's line)
  wire  [3:0]  bq_cnt_n = bq_cnt + 4'(bq_push) - 4'(bq_pop);
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      bq_wp <= '0; bq_rp <= '0; bq_cnt <= '0; bq_rel <= '0; bq_go <= 1'b0; bq_irq_cnt <= '0; bq_irq <= 1'b0;
    end else begin
      bq_go  <= bq_pop;
      bq_irq <= (bq_irq_cnt == 16'd1);
      if (bq_push)               bq_irq_cnt <= 16'd48000;
      else if (bq_irq_cnt != 16'd0) bq_irq_cnt <= bq_irq_cnt - 16'd1;
      if (bq_push) begin
        bq_mem[bq_wp] <= {blit_regs[1][1:0], blit_regs[2], blit_regs[3], blit_regs[4][7:0], blit_regs[5]};
        bq_wp <= bq_wp + 3'd1;
      end
      if (bq_pop) begin
        {bq_h_tmap, bq_h_src, bq_h_dst} <= bq_mem[bq_rp];
        bq_rp <= bq_rp + 3'd1;
      end
      bq_cnt <= bq_cnt_n;
      if (bq_t)                          bq_rel <= bq_cnt_n;
      else if (bq_pop && bq_rel != 4'd0) bq_rel <= bq_rel - 4'd1;
    end
  end
  assign blit_done = i_i4300 ? bq_irq : bl_done_raw;
  wire in_tt      = (i_addr >= 19'h78000 && i_addr < 19'h78800);
  wire [1:0] rmw_lyr = 2'((i_addr - 19'h75000) >> 12);
  wire [10:0] rmw_o  = i_addr[11:1];
  // (o & 0x3F) | ((o >> 6) << 8)   (spec sec 2.1)
  wire [15:0] rmw_word = {3'b000, rmw_o[10:6], 2'b00, rmw_o[5:0]};

  // cpu-side memory address (word index within the selected RAM)
  wire [15:0] cpu_vword = in_rmw ? rmw_word : i_addr[16:1];

  // CPU-side reads come from port A of the BRAM wrappers (registered)
  wire [15:0] q_tt  = tt_q_a;
  wire [15:0] q_pal = pal_q_a;
  wire [15:0] q_spr = spr_live_q_a;
  wire [15:0] q_scr = scr_q_a;

  // drive BRAM port A addresses continuously from the CPU bus
  logic        lg_mode, lg_hold, lg_acc, lg_quiet;      // P_VLOG: see the block below
  logic        dir_ok;                                   // P_VLOG: the log is off and empty: the 68000's layer RAM / tile table write goes to the RAM at once (registered)
  logic        ap_we_v;                                  // the log being applied: one word to the layer RAM / tile table this clock
  logic [1:0]  ap_a_sel, ap_a_be;
  logic [15:0] ap_a_addr, ap_a_data;
  wire         ap_tt = ap_we_v && (ap_a_sel == 2'd3);
  assign tt_cpu_addr       = ap_tt ? ap_a_addr[9:0] : i_addr[10:1];
  assign tt_a_d            = ap_tt ? ap_a_data : i_wdata;
  assign tt_a_be           = ap_tt ? ap_a_be : i_be;
  assign pal_cpu_addr      = i_addr[12:1];
  assign spr_live_cpu_addr = i_addr[11:1];
  assign scr_cpu_addr      = i_addr[12:1];

  wire [15:0] wmask_be = {{8{i_be[1]}}, {8{i_be[0]}}};

  // vram port A drive logic (combinational -> metro_dpram instances)
  wire [1:0] cpu_wr_lyr = in_rmw ? rmw_lyr : vlyr;
  wire cpu_vram_wr = (bst == B_IDLE) && i_cs && !i_rnw
                   && (in_vram || in_rmw) && !bl_busy && !bl_start_h && !bq_pend && dir_ok;

  // the log being applied (P_VLOG) and the blitter never write together with the 68000 (the log is empty while the blitter runs): they are merged first, from registers
  wire         x_we  = ap_we_v || bl_we;
  wire [15:0]  x_addr = ap_we_v ? ap_a_addr : bl_addr;
  wire [15:0]  x_d    = ap_we_v ? ap_a_data : bl_wdata;
  wire [1:0]   x_be   = ap_we_v ? ap_a_be   : {bl_wmask[15], bl_wmask[0]};
  wire [1:0]   x_lyr  = ap_we_v ? ap_a_sel  : bl_layer;
  always_comb begin
    vr_a_we = '{default: 1'b0};
    if (x_we) begin
      vr_a_addr = x_addr;
      vr_a_d    = x_d;
      vr_a_be   = x_be;
      if (x_lyr != 2'd3) vr_a_we[x_lyr] = 1'b1;
    end else if (cpu_vram_wr) begin
      vr_a_addr = cpu_vword;
      vr_a_d    = i_wdata;
      vr_a_be   = i_be;
      vr_a_we[cpu_wr_lyr] = 1'b1;
    end else begin
      vr_a_addr = cpu_vword;
      vr_a_d    = '0;
      vr_a_be   = 2'b11;
    end
  end

  // BRAM write enables (combinational, active on the CPU write commit cycle)
  wire cpu_wr_commit = (bst == B_IDLE) && i_cs && !i_rnw;
  assign scr_we      = cpu_wr_commit && in_scratch;
  assign pal_we      = cpu_wr_commit && in_pal;
  // METRO (family F): MAME copies the sprite RAM at one instant (line 224); this chip's copy takes 2,050 clocks (cp_run) and the game keeps writing its list through the
  // frame: a word written during the copy reaches the copy if it lies ahead of the copy's pointer, so one sprite could mix words of two frames (one stray 8 x 8 piece of
  // the title logo's green "2" blinking next to the text, hardware test of 20261010).  A write to the sprite RAM waits until the copy is done (the 68000 holds its cycle,
  // at most 21 us once a frame).
`ifdef NO_SPR_HOLD
  wire spr_wr_hold = 1'b0;                       // simulation A / B: the copy racing the 68000's writes
`else
  wire spr_wr_hold = i_roz_en && in_spr && cp_run && !i_no_hold;
`endif
  assign spr_live_we = cpu_wr_commit && in_spr && !spr_wr_hold;
  assign tt_we       = (cpu_wr_commit && in_tt && dir_ok) || ap_tt;

  // ------------------------------------------------------------------
  // METRO (family F, P_VLOG): frame-synchronous layer RAM
  //
  // The renderer reads the three tile layers and the tile table live, a line at a time, while the 68000 keeps writing them.  MAME draws a frame once, at the end of the frame,
  // from whatever the RAM holds then.  A game that rewrites a layer during the visible lines (Blazing Tornado's continue screen: 3,980 words of the tile table and layers 1 and 2
  // in one frame, one word every ~180 clocks, a band where the beam is; Grand Striker 2's title: the top rows) therefore shows a mix of two states on this chip and never in MAME.
  // The sprite list and the scroll / window registers already come from a copy taken at one instant (cp_run, spr_copy_line); the palette likewise.  Here the layer RAM does too:
  // the 68000's writes are kept in a log and written to the RAM after that same copy instant, once the renderer has finished the last line of the frame (its kick FIFO holds
  // nothing of the frame and it is idle), so every line of a frame sees the state of the instant MAME's frame is drawn at, and the picture one frame later shows the writes of the
  // frame before, as the sprites do.
  //
  // The log is a list of 20-bit slots: ADDR (layer, word address: the start of a run of consecutive words), DATA (one word and its byte enables, at the next address), RUN (n more
  // words at the next addresses, each the same as the word before or one more than it, same byte enables).  Blazing Tornado's continue screen is 3,980 writes and 4,051 slots with
  // ADDR / DATA only, 871 with the runs (tile codes counting up), Grand Striker 2's 6,300-word scene 434 (fills); the log holds 4,096 slots.  A write that does not fit is
  // not lost: the 68000 waits while the whole log is applied (that frame is drawn as before, from the live RAM).
  //
  // The 68000 never sees the difference: a read of the layer RAM waits until the log is applied (a few clocks a slot), then goes to the RAM as before; this only costs the
  // instant when it happens.  The blitter (not used by family F's games) writes the RAM directly after the log is empty; its start waits for that.
  // ------------------------------------------------------------------
  localparam int LG_AW = 12;                                   // 4096 slots of 20 bits (MLAB: the M10K blocks are all used)
  localparam int LG_N  = LG_AW + 1;                            // pointer width (one lap bit)
  logic [15:0] ovl_val, ovl_m;                                 // a read of the layer RAM while the log holds writes: the words (and their byte lanes) the log would have written there
  logic [15:0] lg_st_w;                                        // the telemetry word for the overlay: {reads answered through the log, writes that found it full, groups applied at the deadline, peak occupancy / 256}, running totals
  generate if (P_VLOG) begin : g_vlog
    logic [LG_N-1:0] lg_wp, lg_rp, lg_cut;
    logic [19:0]     lg_q;
    logic            lg_we;
    logic [19:0]     lg_wd;
    (* ramstyle = "MLAB, no_rw_check" *) logic [19:0] lg_mem [0:(1 << LG_AW) - 1];
    logic [LG_N-1:0] sc_p;
    typedef enum logic [2:0] {S_IDLE, S_ISSUE, S_WAIT, S_DEC, S_DONE} sst_e;
    sst_e            s_st;
    wire  [LG_AW-1:0] lg_ra = (s_st != S_IDLE) ? sc_p[LG_AW-1:0] : lg_rp[LG_AW-1:0];        // the RAM's read port: the apply side's slot or the scan's (registered into ra_q)
    always_ff @(posedge clk) ra_q <= lg_ra;
    logic [LG_AW-1:0] ra_q;                                     // the read address, registered (one clock before the RAM is read): the 128-way read mux is the longest path of the block
    always_ff @(posedge clk) begin
      if (lg_we) lg_mem[lg_wp[LG_AW-1:0]] <= lg_wd;
      lg_q <= lg_mem[ra_q];
    end

    // ---- push side: the accepted CPU write (registered), the run it extends or one to three slots
    logic        pq_v, pf_v, pq_again, pd_v, lw_v, ro_v, ro_step, pf_seq, pf_same, pf_inc;
    logic [1:0]  pq_sel, pq_be, lw_sel;
    logic [1:0]  lw_be;
    logic [15:0] pq_addr, pq_data, lw_addr, lw_data, ro_n;
    logic [19:0] pd_slot;
    wire         pq_go = pf_v || pq_again;                    // the write is compared with the one before (registered flags), then acted on
    wire         pq_busy = pq_v || pf_v || pq_again || pd_v;
    wire         seq   = pf_seq;
    wire         same  = pf_same;
    wire         inc   = pf_inc;
    wire         ext   = pq_go && ro_v && seq && (ro_step ? inc : same) && (ro_n != 16'hFFFF);
    wire         opn   = pq_go && !ro_v && seq && (same || inc);
    wire         dat   = pq_go && !ro_v && seq && !same && !inc;
    wire         adr   = pq_go && !ro_v && !seq;
    wire         clos  = pq_go && ro_v && !ext;
    wire  [LG_N-1:0] lg_used = lg_wp - lg_rp;
    wire             lg_full2 = full_q;                                           // fewer than 4 free slots: a write needs up to 3 (the open run, ADDR, DATA)
    assign lg_we = ext || opn || dat || adr || pd_v;
    assign lg_wd = pd_v ? pd_slot
                 : (ext || opn) ? {2'b01, 1'b0, (ext ? ro_step : !same), (ext ? ro_n + 16'd1 : 16'd1)}
                 : dat ? {2'b00, pq_be, pq_data}
                 :       {2'b10, pq_sel, pq_addr};

    // ---- apply side (one slot at a time: IDLE -> DEC [-> RUN ...])
    typedef enum logic [1:0] {A_IDLE, A_WAIT, A_DEC, A_RUN} ast_e;
    ast_e        a_st;
    logic [1:0]  ap_sel, ap_be;
    logic [15:0] ap_cur, ap_d, x_n;
    logic        x_step;
    logic        ap_pend, ap_rel, cut_pend, cut_par, cut_par_q;
    wire lg_quiet_c = (lg_wp == lg_rp) && (a_st == A_IDLE) && !ap_we_v && !pq_busy && !ro_v;
    logic quiet_q, mode_q, full_q;
    wire  mode_c = i_roz_en && i_vlog_en && !bl_busy && !bl_start_h;
    always_ff @(posedge clk) begin                                            // registered: they decide the 68000's access, which must not wait for a compare of the pointers
      quiet_q <= lg_quiet_c;
      mode_q  <= mode_c;
      full_q  <= (lg_used >= LG_N'((1 << LG_AW) - 4));
      dir_ok  <= !mode_c && lg_quiet_c;
    end
    assign lg_quiet = quiet_q;

    wire cpu_vl_sel  = in_vram || in_rmw || in_tt;
    wire cpu_wants   = cpu_vl_sel && i_cs && (bst == B_IDLE);
    assign lg_mode   = mode_q;
    // the log is off (OSD / blitter): an access waits until it is empty.  On: a write waits only for room; a read is answered from the RAM and the log (the scan below).
    logic        ovl_ok;                                                      // the scan of the pending read is done: ovl_val / ovl_m are its words
    wire need_quiet  = !lg_mode;
    wire scan_req    = lg_mode && cpu_wants && i_rnw && (s_st == S_IDLE) && !ovl_ok;
    assign lg_hold   = cpu_wants && (!lg_mode ? !lg_quiet : (i_rnw ? !ovl_ok : (lg_full2 || pq_busy)));
    assign lg_acc    = lg_mode && cpu_wants && !i_rnw && !lg_hold;
    wire [1:0]  w_sel  = in_tt ? 2'd3 : cpu_wr_lyr;
    wire [15:0] w_addr = in_tt ? {6'd0, i_addr[10:1]} : cpu_vword;

    // ---- blitter: its start waits for an empty log
    assign bl_start_go = bl_start_h && lg_quiet;
    always_ff @(posedge clk) begin
      if (!rst_n)                       bl_start_h <= 1'b0;
      else if (bl_start)                bl_start_h <= 1'b1;
      else if (bl_start_h && lg_quiet)  bl_start_h <= 1'b0;
    end

    // ---- the instant of the copy (same condition as cp_run's start), the renderer being done with the frame, the deadline
    wire        cut_ev   = line_start && ((P_SPR_BUFFERED && next_v == v_vis) || (!P_SPR_BUFFERED && next_v == spr_copy_line));
    wire [8:0]  dl_line  = (crtc_vfirst_q >= 8'd4) ? 9'(crtc_vfirst_q) - 9'd3 : 9'd0;   // before the first displayed line is kicked: apply whatever is left
    wire        dl_ev    = line_start && (next_v == dl_line);
    wire        head_par = kick_fifo[kf_rd][105];
    wire        ren_done = (kf_cnt == 4'd0 || head_par != cut_par) && !rnd_busy && !rnd_start && !pop_pend;
    wire        force_all = (cpu_wants && (need_quiet || (!i_rnw && lg_full2))) || bl_start_h;
    wire [LG_N-1:0] tgt  = force_all ? lg_wp : lg_cut;
    wire        more     = (lg_rp != tgt);
    wire        drain    = (a_st == A_IDLE) && (ap_rel || force_all) && more && !scan_req && (s_st == S_IDLE);
    // an open run is closed (it becomes a slot the apply side and the scan may read) when the log has to be consumed or looked into
    wire        close_now = ro_v && !pq_busy && (cut_pend || force_all || scan_req);
    wire        scan_start = scan_req && (a_st == A_IDLE) && !ap_we_v && !pq_busy && !ro_v;

    // telemetry (running totals since reset, 15 = 15 or more): how often the 68000's access forced the log out early (tears the frame as before), how often the log was full,
    // how often a frame's group was applied at the deadline instead of when the renderer was done, the largest occupancy in 256-slot steps
    logic [3:0]  tl_rd, tl_full, tl_late;
    logic [LG_N-1:0] pk_max;
    logic        fh_q;
    // ---- scan: the words the log holds for the address of a pending read, in the order they were written, from the apply side's state at the read pointer
    logic [1:0]  sc_sel, sc_be, t_sel;
    logic [15:0] sc_cur, sc_d, t_addr;
    wire  [1:0]  r_sel  = in_tt ? 2'd3 : cpu_wr_lyr;
    wire  [15:0] r_addr = in_tt ? {6'd0, i_addr[10:1]} : cpu_vword;
    wire  [15:0] sc_off = t_addr - sc_cur;                                    // RUN: the target is word sc_off of the run (1 .. n)
    wire  [15:0] sc_nw  = sc_cur + 16'd1;
    wire  [15:0] sc_run_d = sc_d + (lg_q[16] ? sc_off : 16'd0);
    wire  [15:0] sc_dm  = {{8{lg_q[17]}}, {8{lg_q[16]}}};                     // DATA: byte lanes of its enables
    wire  [15:0] sc_rm  = {{8{sc_be[1]}}, {8{sc_be[0]}}};                     // RUN: byte lanes of the enables of the word before
    always_ff @(posedge clk) begin
      if (!rst_n) begin
        lg_wp <= '0; lg_rp <= '0; lg_cut <= '0;
        pq_v <= 1'b0; pf_v <= 1'b0; pq_again <= 1'b0; pd_v <= 1'b0; lw_v <= 1'b0; ro_v <= 1'b0; ro_step <= 1'b0; ro_n <= 16'd0;
        pf_seq <= 1'b0; pf_same <= 1'b0; pf_inc <= 1'b0;
        a_st <= A_IDLE; ap_we_v <= 1'b0; ap_pend <= 1'b0; ap_rel <= 1'b0; cut_pend <= 1'b0;
        cut_par <= 1'b0; cut_par_q <= 1'b0; ap_sel <= 2'd0; ap_be <= 2'd3; ap_cur <= 16'd0; ap_d <= 16'd0; x_n <= 16'd0; x_step <= 1'b0;
        tl_rd <= '0; tl_full <= '0; tl_late <= '0; pk_max <= '0; lg_st_w <= '0; fh_q <= 1'b0;
        s_st <= S_IDLE; sc_p <= '0; ovl_ok <= 1'b0; ovl_val <= 16'd0; ovl_m <= 16'd0;
        sc_sel <= 2'd0; sc_be <= 2'd3; t_sel <= 2'd0; sc_cur <= 16'd0; sc_d <= 16'd0; t_addr <= 16'd0;
      end else begin
        // ---- push
        pq_v <= lg_acc;
        if (lg_acc) begin pq_sel <= w_sel; pq_addr <= w_addr; pq_be <= i_be; pq_data <= i_wdata; end
        pf_v <= pq_v;
        if (pq_v) begin
          pf_seq  <= lw_v && (pq_sel == lw_sel) && (pq_addr == lw_addr + 16'd1) && (pq_be == lw_be);
          pf_same <= (pq_data == lw_data);
          pf_inc  <= (pq_data == lw_data + 16'd1);
        end
        pq_again <= clos;
        if (pd_v) begin
          lg_wp <= lg_wp + 1'b1;                                     // the DATA slot after an ADDR slot
          pd_v <= 1'b0;
        end
        if (ext) begin
          ro_n <= ro_n + 16'd1; lw_addr <= pq_addr; lw_data <= pq_data;
        end
        if (opn) begin
          ro_v <= 1'b1; ro_step <= !same; ro_n <= 16'd1; lw_addr <= pq_addr; lw_data <= pq_data;
        end
        if (dat) begin
          lg_wp <= lg_wp + 1'b1; lw_addr <= pq_addr; lw_data <= pq_data;
        end
        if (adr) begin
          lg_wp <= lg_wp + 1'b1; pd_v <= 1'b1; pd_slot <= {2'b00, pq_be, pq_data};
          lw_v <= 1'b1; lw_sel <= pq_sel; lw_be <= pq_be; lw_addr <= pq_addr; lw_data <= pq_data;
        end
        if (clos || close_now) begin
          lg_wp <= lg_wp + 1'b1; ro_v <= 1'b0;
        end
        // ---- the group of the frame: cut at the copy instant (after a write in flight), released when the renderer is done
        if (cut_ev) begin cut_pend <= 1'b1; cut_par_q <= frame_par; end
        if (cut_pend && !pq_busy) begin
          lg_cut <= lg_wp + {{(LG_N-1){1'b0}}, ro_v};
          cut_pend <= 1'b0; ap_pend <= 1'b1; ap_rel <= 1'b0; cut_par <= cut_par_q;
        end else begin
          if (ap_pend && (ren_done || dl_ev)) begin
            ap_pend <= 1'b0; ap_rel <= 1'b1;
            if (!ren_done && tl_late != 4'hF) tl_late <= tl_late + 4'd1;
          end
          if (ap_rel && !more) ap_rel <= 1'b0;
        end
        // ---- apply
        ap_we_v <= 1'b0;
        case (a_st)
          A_IDLE: if (drain) begin
            lg_rp <= lg_rp + 1'b1;
            if (lg_rp == lg_cut && !(cut_pend && !pq_busy)) lg_cut <= lg_cut + 1'b1;   // forced past the cut: the cut follows
            a_st <= A_WAIT;
          end
          A_WAIT: a_st <= A_DEC;                                         // the address is registered (ra_q), then the RAM is read
          A_DEC: begin
            a_st <= A_IDLE;
            case (lg_q[19:18])
              2'b10: begin ap_sel <= lg_q[17:16]; ap_cur <= lg_q[15:0] - 16'd1; end
              2'b00: begin
                ap_cur <= ap_cur + 16'd1; ap_d <= lg_q[15:0]; ap_be <= lg_q[17:16];
                ap_a_sel <= ap_sel; ap_a_addr <= ap_cur + 16'd1; ap_a_data <= lg_q[15:0]; ap_a_be <= lg_q[17:16]; ap_we_v <= 1'b1;
              end
              2'b01: begin x_n <= lg_q[15:0]; x_step <= lg_q[16]; if (lg_q[15:0] != 16'd0) a_st <= A_RUN; end
              default: ;
            endcase
          end
          default: begin                                             // A_RUN
            ap_cur <= ap_cur + 16'd1; ap_d <= ap_d + {15'd0, x_step};
            ap_a_sel <= ap_sel; ap_a_addr <= ap_cur + 16'd1; ap_a_data <= ap_d + {15'd0, x_step}; ap_a_be <= ap_be; ap_we_v <= 1'b1;
            x_n <= x_n - 16'd1;
            if (x_n == 16'd1) a_st <= A_IDLE;
          end
        endcase
        // ---- scan (a read of the layer RAM): the log's words for its address, applied in order over empty lanes; the bus FSM merges them over the RAM's word
        case (s_st)
          S_IDLE: if (scan_start) begin
            t_sel <= r_sel; t_addr <= r_addr;
            sc_p <= lg_rp; sc_sel <= ap_sel; sc_cur <= ap_cur; sc_d <= ap_d; sc_be <= ap_be;
            ovl_val <= 16'd0; ovl_m <= 16'd0;
            s_st <= S_ISSUE;
            if (lg_wp != lg_rp && tl_rd != 4'hF) tl_rd <= tl_rd + 4'd1;
          end
          S_ISSUE: begin
            if (sc_p == lg_wp) begin s_st <= S_DONE; ovl_ok <= 1'b1; end
            else begin sc_p <= sc_p + 1'b1; s_st <= S_WAIT; end
          end
          S_WAIT: s_st <= S_DEC;
          S_DEC: begin
            s_st <= S_ISSUE;
            case (lg_q[19:18])
              2'b10: begin sc_sel <= lg_q[17:16]; sc_cur <= lg_q[15:0] - 16'd1; end
              2'b00: begin
                sc_cur <= sc_nw; sc_d <= lg_q[15:0]; sc_be <= lg_q[17:16];
                if (sc_sel == t_sel && sc_nw == t_addr) begin
                  ovl_m   <= ovl_m | sc_dm;
                  ovl_val <= (ovl_val & ~sc_dm) | (lg_q[15:0] & sc_dm);
                end
              end
              2'b01: begin
                if (sc_sel == t_sel && sc_off != 16'd0 && sc_off <= lg_q[15:0]) begin
                  ovl_m   <= ovl_m | sc_rm;
                  ovl_val <= (ovl_val & ~sc_rm) | (sc_run_d & sc_rm);
                end
                sc_cur <= sc_cur + lg_q[15:0];
                sc_d   <= sc_d + (lg_q[16] ? lg_q[15:0] : 16'd0);
              end
              default: ;
            endcase
          end
          default: begin                                                 // S_DONE: held until the read has been answered
            if (bst == B_ACK || !i_cs) begin s_st <= S_IDLE; ovl_ok <= 1'b0; end
          end
        endcase
        // ---- telemetry
        fh_q <= lg_hold;
        if (lg_hold && !fh_q && lg_mode && !i_rnw && lg_full2 && tl_full != 4'hF) tl_full <= tl_full + 4'd1;
        if (lg_used > pk_max) pk_max <= lg_used;
        if (o_roz_frame)                                              // running totals since reset (saturating): a photo of the overlay shows whether it ever happened
          lg_st_w <= {tl_rd, tl_full, tl_late, (pk_max[LG_N-1:8] > 5'd15) ? 4'hF : pk_max[11:8]};
      end
    end
  end else begin : g_nolog
    assign lg_mode = 1'b0;
    assign dir_ok  = 1'b1;
    assign lg_hold = 1'b0;
    assign lg_acc  = 1'b0;
    assign lg_quiet = 1'b1;
    assign ap_we_v = 1'b0;
    assign ap_a_sel = 2'd0;
    assign ap_a_addr = 16'd0;
    assign ap_a_data = 16'd0;
    assign ap_a_be = 2'd0;
    assign bl_start_go = bl_start;
    assign bl_start_h = 1'b0;
    assign lg_st_w = 16'd0;
    assign ovl_val = 16'd0;
    assign ovl_m   = 16'd0;
  end endgenerate

  logic reg_w;   // pulse: commit register write this cycle

  // register file write/read
  function automatic logic [15:0] comb16(input logic [15:0] old);
    comb16 = (old & ~wmask_be) | (i_wdata & wmask_be);
  endfunction

  wire  [15:0] ctrl_next = comb16(r_ctrl);

  logic [15:0] reg_rdata;
  logic        reg_hit;

  // The I4300's register map (imagetek_i4100.cpp v3_map) folded onto the I4220's: `ra` is the register address the decode below sees.  The levels / vectors
  // (0x78810.., 0x78820..) are decoded on the raw address; the I4300 has nothing else in 0x78800..0x788FF (and no sprite / layer registers below 0x79700).
  wire [18:0] ra_raw = i_addr & 19'h7FFFE;
  function automatic logic [18:0] v3map(input logic [18:0] a);
    case (a)
      19'h78800: v3map = 19'h788A0;      // crtc unlock
      19'h78802: v3map = 19'h78890;      // crtc horizontal
      19'h78804: v3map = 19'h78880;      // crtc vertical
      19'h78808: v3map = 19'h78852;      // screen x offset
      19'h7880A: v3map = 19'h78850;      // screen y offset
      19'h7880E: v3map = 19'h788AC;      // screen control
      19'h78830: v3map = 19'h788A4;      // irq enable (the byte at 0x78831)
      19'h78832: v3map = 19'h788A2;      // irq cause (the byte at 0x78833)
      19'h78870: v3map = 19'h788AA;      // rom bank
      default:
        if (a >= 19'h78850 && a < 19'h7885C)      v3map = a + 19'h20;      // the six scroll words
        else if (a >= 19'h78860 && a < 19'h7886C) v3map = a;                // window
        else if (a >= 19'h78840 && a < 19'h7884E) v3map = a;                // blitter
        else if (a >= 19'h78800 && a < 19'h78900) v3map = 19'h7FFFE;        // not a register of the I4300
        else                                      v3map = a;
    endcase
  endfunction
  // registered (the CPU's address is stable for several clocks before the register file looks at it): keeps the address -> map -> read mux path out of the 96 MHz critical path
  logic [18:0] ra;
  always_ff @(posedge clk) ra <= i_i4300 ? v3map(ra_raw) : ra_raw;

  always_comb begin
    reg_hit = 1'b0;
    reg_rdata = 16'h0000;
    case (ra)
      19'h79700: begin reg_rdata = r_spr_count;  reg_hit = 1'b1; end
      19'h79702: begin reg_rdata = r_spr_pri;    reg_hit = 1'b1; end
      19'h79704: begin reg_rdata = r_spr_yoff;   reg_hit = 1'b1; end
      19'h79706: begin reg_rdata = r_spr_xoff;   reg_hit = 1'b1; end
      19'h79708: begin reg_rdata = r_spr_color;  reg_hit = 1'b1; end
      19'h79710: begin reg_rdata = {10'd0, r_layer_pri}; reg_hit = 1'b1; end
      19'h79712: begin reg_rdata = {4'd0, r_bg}; reg_hit = 1'b1; end
      // 0x788xx mirror (no sprite priority at 0x78802)
      19'h78800: begin reg_rdata = r_spr_count;  reg_hit = 1'b1; end
      19'h78802: if (i_i4100) begin reg_rdata = r_spr_pri; reg_hit = 1'b1; end   // I4100's own address of the sprite priority
      19'h78804: begin reg_rdata = r_spr_yoff;   reg_hit = 1'b1; end
      19'h78806: begin reg_rdata = r_spr_xoff;   reg_hit = 1'b1; end
      19'h78808: begin reg_rdata = r_spr_color;  reg_hit = 1'b1; end
      19'h78810: begin reg_rdata = {10'd0, r_layer_pri}; reg_hit = 1'b1; end
      19'h78812: begin reg_rdata = {4'd0, r_bg}; reg_hit = 1'b1; end
      19'h78850: begin reg_rdata = r_scr_yoff;   reg_hit = 1'b1; end
      19'h78852: begin reg_rdata = r_scr_xoff;   reg_hit = 1'b1; end
      19'h788A2: begin reg_rdata = {8'd0, r_irq_cause}; reg_hit = 1'b1; end
      default: begin
        if (ra >= 19'h78860 && ra < 19'h7886C) begin
          reg_rdata = r_window[3'((ra - 19'h78860) >> 1)];
          reg_hit = 1'b1;
        end else if (ra >= 19'h78870 && ra < 19'h7887C) begin
          reg_rdata = r_scroll[3'((ra - 19'h78870) >> 1)];
          reg_hit = 1'b1;
        end
      end
    endcase
  end

  assign irq_ack_data = i_wdata[7:0];
  assign irq_en_data  = i_wdata[7:0];

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      r_spr_count <= '0; r_spr_pri <= '0;
      r_spr_xoff <= '0; r_spr_yoff <= '0; r_spr_color <= '0;
      r_layer_pri <= '0; r_bg <= '0;
      r_scr_xoff <= '0; r_scr_yoff <= '0;
      r_ctrl <= '0; r_rombank <= '0;
      flip_stale <= 1'b0; flip_force_q <= i_flip_force;
      r_crtc_unlock <= 1'b0;
      crtc_vfirst <= 8'd0;
      bl_start <= 1'b0;
      for (int i = 0; i < 6; i++) begin
        r_window[i] <= '0;
        r_scroll[i] <= '0;
      end
    end else begin
      bl_start <= 1'b0;
      flip_force_q <= i_flip_force;
      if (flip_force_q && !i_flip_force) flip_stale <= 1'b1;
      if (reg_w) begin
        if (i_i4300 && i_be[0] && ra_raw >= 19'h78810 && ra_raw < 19'h78820) r_irq_lvl[ra_raw[3:1]] <= i_wdata[2:0];
        if (i_i4300 && i_be[0] && ra_raw >= 19'h78820 && ra_raw < 19'h78830) r_irq_vec[ra_raw[3:1]] <= i_wdata[7:0];
        case (ra)
          19'h79700, 19'h78800: r_spr_count <= comb16(r_spr_count);
          19'h79702:            r_spr_pri   <= comb16(r_spr_pri);
          19'h78802:            if (i_i4100) r_spr_pri <= comb16(r_spr_pri);
          19'h79704, 19'h78804: r_spr_yoff  <= comb16(r_spr_yoff);
          19'h79706, 19'h78806: r_spr_xoff  <= comb16(r_spr_xoff);
          19'h79708, 19'h78808: r_spr_color <= comb16(r_spr_color);
          19'h79710, 19'h78810: r_layer_pri <= 6'(comb16({10'd0, r_layer_pri}));
          19'h79712, 19'h78812: r_bg        <= 12'(comb16({4'd0, r_bg}));
          19'h78850: r_scr_yoff <= comb16(r_scr_yoff);
          19'h78852: r_scr_xoff <= comb16(r_scr_xoff);
          19'h78880: if (r_crtc_unlock) begin
            r_crtc_v <= comb16(r_crtc_v);
            // v15: indexed vertical-timing write; param 7 = first
            // visible line (game programs 2 - see vdisp comment).
            // Clamp to a sane range so a stray value cannot push the
            // window off the rendered line range.
            if (comb16(r_crtc_v) >= 16'h0700 && comb16(r_crtc_v) <= 16'h070F)
              crtc_vfirst <= 8'(comb16(r_crtc_v) & 16'h000F);
          end
          19'h78890: if (r_crtc_unlock) r_crtc_h <= comb16(r_crtc_h);
          19'h788A0: r_crtc_unlock <= i_wdata[0];
          19'h788AA: r_rombank <= comb16(r_rombank);
          19'h788AC: begin
            r_ctrl <= ctrl_next;
            if (!ctrl_next[0]) flip_stale <= 1'b0;
          end
          default: begin
            if (ra >= 19'h78860 && ra < 19'h7886C)
              r_window[3'((ra - 19'h78860) >> 1)]
                <= comb16(r_window[3'((ra - 19'h78860) >> 1)]);
            else if (ra >= 19'h78870 && ra < 19'h7887C)
              r_scroll[3'((ra - 19'h78870) >> 1)]
                <= comb16(r_scroll[3'((ra - 19'h78870) >> 1)]);
            else if (ra >= 19'h78840 && ra < 19'h7884E) begin
              blit_regs[3'((ra - 19'h78840) >> 1)]
                <= comb16(blit_regs[3'((ra - 19'h78840) >> 1)]);
              if (((ra - 19'h78840) >> 1) == 6) bl_start <= 1'b1;
            end
          end
        endcase
      end
    end
  end

  // bus FSM
  wire [GFX_AW-1:0] gfx_addr_c = GFX_AW'((32'(r_rombank) << 16)
                                         + 32'(i_addr[15:1]) * 2);
  wire cpu_pf_valid_bus = cpu_pf_valid;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      bst <= B_IDLE;
      o_ack <= 1'b0;
      reg_w <= 1'b0;
      irq_ack_w <= 1'b0;
      irq_en_w <= 1'b0;
      cpu_gfx_req <= 1'b0;
    end else begin
      reg_w <= 1'b0;
      irq_ack_w <= 1'b0;
      irq_en_w <= 1'b0;
      cpu_gfx_req <= 1'b0;

      case (bst)
        B_IDLE: begin
          o_ack <= 1'b0;
          if (i_cs) begin
            if ((in_vram || in_rmw) && (bl_busy || bl_start_h || bq_pend)) begin
              // stall until blitter releases VRAM
            end else if (bq_trig && bq_full) begin
              // METRO (I4300): the blit queue is full: the trigger waits for room (the queue is run at once meanwhile)
            end else if (!i_rnw && spr_wr_hold) begin
              // METRO (family F): stall until the sprite list copy is done
            end else if (lg_hold) begin
              // METRO (family F, P_VLOG): the layer RAM log is being applied (a read) or is full (a write)
            end else if (i_rnw) begin
              if (in_gfxwin) begin
                if (cpu_pf_valid_bus &&
                    gfx_addr_c == cpu_pf_tag) begin
                  o_rdata <= (32'(gfx_addr_c) < 32'(i_gfx_size))
                             ? cpu_pf_data : 16'hFFFF;
                  bst <= B_ACK;
                end else begin
                  cpu_gfx_req <= 1'b1;
                  cpu_gfx_addr <= gfx_addr_c;
                  bst <= B_GFX;
                end
              end else begin
                bst <= B_RD1;   // registered RAM/regs read path
              end
            end else begin
              // writes commit this cycle in the memory processes above
              reg_w <= 1'b1;
              if (ra == 19'h788A2 && i_be[0]) irq_ack_w <= 1'b1;
              if (ra == 19'h788A4 && i_be[0]) irq_en_w <= 1'b1;
              bst <= B_ACK;
            end
          end
        end

        B_RD1: bst <= B_RD2;    // wait registered read

        B_RD2: begin
          if (in_vram || in_rmw) begin
            unique case (in_rmw ? rmw_lyr : vlyr)
              2'd0: o_rdata <= (q_vram0 & ~ovl_m) | (ovl_val & ovl_m);
              2'd1: o_rdata <= (q_vram1 & ~ovl_m) | (ovl_val & ovl_m);
              default: o_rdata <= (q_vram2 & ~ovl_m) | (ovl_val & ovl_m);
            endcase
          end else if (in_tt)      o_rdata <= (q_tt & ~ovl_m) | (ovl_val & ovl_m);
          else if (in_pal)         o_rdata <= q_pal;
          else if (in_spr)         o_rdata <= q_spr;
          else if (in_scratch)     o_rdata <= q_scr;
          else if (reg_hit)        o_rdata <= reg_rdata;
          else                     o_rdata <= 16'h0000;
          bst <= B_ACK;
        end

        B_GFX: begin
          if (cpu_gfx_done) begin
            o_rdata <= (32'(cpu_gfx_addr) < 32'(i_gfx_size))
                       ? cpu_gfx_data : 16'hFFFF;
            bst <= B_ACK;
          end
        end

        B_ACK: begin
          o_ack <= 1'b1;
          if (!i_cs) begin
            o_ack <= 1'b0;
            bst <= B_IDLE;
          end
        end

        default: bst <= B_IDLE;
      endcase
    end
  end

  // ------------------------------------------------------------------
  // scan-out: linebuf -> palette -> GRB555 decode (2 ce_pix pipeline)
  // ------------------------------------------------------------------
  // Scan-out blanking: each linebuffer bank is tagged with {frame parity,
  // line} when the renderer COMPLETES a line into it. The beam shows a
  // line only if its bank holds this frame's copy of this line; otherwise
  // the background pen is substituted. Per-bank tags are immune to renders
  // that straddle the frame boundary (a late tail line only blanks itself,
  // as does a dropped kick - no frame-wide counter to poison). Read-side
  // only - no logic is added to the linebuffer write path.
  logic [8:0] bank_tag [0:3];   // {par, line[7:0]} last completed per bank
  logic       so_stale;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      // init to line 255: matches no visible vcnt, so everything blanks
      // until the renderer has actually delivered a line
      bank_tag[0] <= 9'h1FF;
      bank_tag[1] <= 9'h1FF;
      bank_tag[2] <= 9'h1FF;
      bank_tag[3] <= 9'h1FF;
      so_stale <= 1'b1;
    end else begin
      if (rnd_done)
        bank_tag[rnd_row[1:0]] <= {cur_par, rnd_row};
      so_stale <= (bank_tag[vsrc[1:0]] != {frame_par, vsrc[7:0]});
    end
  end

  // ------------------------------------------------------------------
  // DEBUG: top-lines provenance latches (see port comment). Pure
  // registered captures off existing signals; nothing feeds back into
  // the render or scanout paths.
  // ------------------------------------------------------------------
  logic [2:0] dbg_tagbad, dbg_stale;      // accumulate over the frame
  logic [2:0] dbg_tagbad_q, dbg_stale_q;  // previous frame, snapshot-stable
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      dbg_tagbad <= '0;   dbg_stale <= '0;
      dbg_tagbad_q <= '0; dbg_stale_q <= '0;
    end else begin
      // rend values come from the renderer's own first-pass tap; disp
      // rows latch the live view at each top line's scan-out h160
      if (ce_pix && vdisp < 9'd3 && hcnt == 9'd160) begin
        case (vdisp[1:0])
          2'd0: o_dbg_disp_sx2_0 <= rs_sw_x[2];
          2'd1: o_dbg_disp_sx2_1 <= rs_sw_x[2];
          default: o_dbg_disp_sx2_2 <= rs_sw_x[2];
        endcase
        if (bank_tag[vdisp[1:0]] != {frame_par, vdisp[7:0]})
          dbg_tagbad[vdisp[1:0]] <= 1'b1;
        if (so_stale)
          dbg_stale[vdisp[1:0]] <= 1'b1;
      end
      // frame boundary: publish last frame's flags, clear accumulators
      // (h0 of line 0 is before this frame's h160 captures)
      if (ce_pix && vcnt == 9'd0 && hcnt == 9'd0) begin
        dbg_tagbad_q <= dbg_tagbad;
        dbg_stale_q  <= dbg_stale;
        dbg_tagbad   <= '0;
        dbg_stale    <= '0;
      end
    end
  end
  assign o_dbg_topflags = {5'b0, dbg_stale_q, 5'b0, dbg_tagbad_q};

  // ------------------------------------------------------------------
  // measurements for the hardware test overlay (metro_hud.sv): observation only, published at every frame start (o_roz_frame, one clock after the frame edge)
  // ------------------------------------------------------------------
  logic [15:0] ms_stale, ms_first, ms_last, ms_bmax, ms_bcur, ms_kfmax, ms_lines;
  logic [23:0] ms_bsum, ms_kwait, ms_grr, ms_grz, ms_grc;
  logic [255:0] st_v;
  assign o_st = st_v;
  logic [20:0] ms_per, ms_per_q;
  always_ff @(posedge clk) begin
    if (!rst_n) begin ms_per <= '0; ms_per_q <= '0; end
    else if (o_roz_frame) begin ms_per <= 21'd1; ms_per_q <= ms_per; end
    else ms_per <= ms_per + 21'd1;
  end
  function automatic logic [15:0] sat24(input logic [23:0] v);
    return (v[23:16] != 8'd0) ? 16'hFFFF : v[15:0];
  endfunction
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      ms_stale <= '0; ms_first <= '0; ms_last <= '0; ms_bmax <= '0; ms_bcur <= '0; ms_kfmax <= '0; ms_lines <= '0;
      ms_bsum <= '0; ms_kwait <= '0; ms_grr <= '0; ms_grz <= '0; ms_grc <= '0;
      st_v <= '0;
    end else begin
      // lines shown from the background pen (the line was not complete when the beam reached it)
      if (ce_pix && hcnt == 9'd160 && vdisp < v_vis && so_stale) begin
        if (ms_stale != 16'hFFFF) ms_stale <= ms_stale + 16'd1;
        if (ms_stale == 16'd0) ms_first <= {7'd0, vdisp};
        ms_last <= {7'd0, vdisp};
      end
      // the renderer's time per line
      if (rnd_busy) begin
        if (ms_bcur != 16'hFFFF) ms_bcur <= ms_bcur + 16'd1;
        if (ms_bsum != 24'hFFFFFF) ms_bsum <= ms_bsum + 24'd1;
      end else if (ms_bcur != 16'd0) begin
        if (ms_bcur > ms_bmax) ms_bmax <= ms_bcur;
        ms_bcur <= 16'd0;
        ms_lines <= ms_lines + 16'd1;
      end
      // a kick waits for the plane's row
      if (kf_cnt != 4'd0 && !rnd_busy && !rnd_start && !pop_pend && !roz_ok && ms_kwait != 24'hFFFFFF) ms_kwait <= ms_kwait + 24'd1;
      if ({12'd0, kf_cnt} > ms_kfmax) ms_kfmax <= {12'd0, kf_cnt};
      // the graphics stream's time by user
      if (gr == GR_RND && ms_grr != 24'hFFFFFF) ms_grr <= ms_grr + 24'd1;
      if (gr == GR_ROZ && ms_grz != 24'hFFFFFF) ms_grz <= ms_grz + 24'd1;
      if ((gr == GR_CPU || gr == GR_BLT) && ms_grc != 24'hFFFFFF) ms_grc <= ms_grc + 24'd1;
      if (o_roz_frame) begin
        st_v <= {ms_per_q[20:5], ms_lines, spr_count_q[15:0],
                 sat24(ms_grc >> 6), sat24(ms_grz >> 6), sat24(ms_grr >> 6),
                 (P_VLOG ? lg_st_w : {crtc_vfirst_q, v_vis[7:0]}), {7'd0, i_roz_done},
                 ms_kfmax, sat24(ms_kwait >> 6), sat24(ms_bsum >> 6), ms_bmax,
                 o_dbg_ovr, ms_last, ms_first, ms_stale};
        ms_stale <= '0; ms_first <= '0; ms_last <= '0; ms_bmax <= '0; ms_kfmax <= '0; ms_lines <= '0;
        ms_bsum <= '0; ms_kwait <= '0; ms_grr <= '0; ms_grz <= '0; ms_grc <= '0;
      end
    end
  end

  // so_pen declared at u_palette instantiation
  logic [15:0] so_pal;
  logic        de0, de1;
  logic        hb0, hb1, vb0, vb1;

  always_ff @(posedge clk) begin
    if (ce_pix) begin
      // stage 0: pen fetch for current hcnt (bank = line vdisp, rendered
      // during the previous game line). All vertical output timing uses
      // vdisp so vsync and the active window shift together.
      de0 <= (hcnt < h_vis) && (vdisp < v_vis);
      hb0 <= !(hcnt < h_vis);
      vb0 <= !(vdisp < v_vis);
      so_pen <= (hcnt >= h_vis) ? 12'd0
              : so_stale              ? r_bg
              :                         lb_rq;
      // stage 1: palette lookup
      de1 <= de0;
      hb1 <= hb0;
      vb1 <= vb0;
      so_pal <= i_pal_latch ? pal_sh_q : pal_scanout_q;
      // stage 2: RGB out, aligned with de1 -> o_de
      // black while the core is held in reset (FREE_TIMING keeps sync running)
      o_r <= (rst_n || !FREE_TIMING) ? so_pal[10:6]  : 5'd0;
      o_g <= (rst_n || !FREE_TIMING) ? so_pal[15:11] : 5'd0;
      o_b <= (rst_n || !FREE_TIMING) ? so_pal[5:1]   : 5'd0;
      o_de <= de1;
      o_hblank <= hb1;
      o_vblank <= vb1;
      o_hs <= (hcnt >= hs_beg && hcnt < hs_end);
      o_vs <= (vdisp >= vs_beg && vdisp < vs_end);
    end
  end

  // ------------------------------------------------------------------
  // DEBUG: sticky diagnostic flags (latch on first occurrence, never clear)
  // ------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      o_dbg_vdp_write  <= 1'b0;
      o_dbg_line_start <= 1'b0;
      o_dbg_rnd_done   <= 1'b0;
      o_dbg_lb_nonzero <= 1'b0;
    end else begin
      if (cpu_wr_commit)  o_dbg_vdp_write  <= 1'b1;
      if (line_start)     o_dbg_line_start <= 1'b1;
      if (rnd_done)       o_dbg_rnd_done   <= 1'b1;
      if (lb_we && lb_pen != 12'd0)
                          o_dbg_lb_nonzero <= 1'b1;
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) o_dbg_palw <= '0;
    else if (pal_we && i_wdata != 16'd0) o_dbg_palw <= o_dbg_palw + 16'd1;
  end

`ifdef VLOG_CHECK
  // simulation only: a mirror of the layer RAM and the tile table as the 68000 sees them (updated at the clock a write is accepted, whether it goes to the log or to the RAM);
  // every read of them is compared with it when it is answered.  Only words written at least once are compared (the RAM's power-up contents are not defined).
  logic [15:0] chk_mem [0:4*65536-1];
  logic        chk_v   [0:4*65536-1];
  longint      chk_n = 0, chk_err = 0;
  wire  [1:0]  chk_sel  = in_tt ? 2'd3 : (in_rmw ? rmw_lyr : vlyr);
  wire  [15:0] chk_addr = in_tt ? {6'd0, i_addr[10:1]} : cpu_vword;
  wire         chk_cw   = lg_acc || cpu_vram_wr || (cpu_wr_commit && in_tt && dir_ok);
  always_ff @(posedge clk) if (rst_n) begin
    if (chk_cw) begin
      chk_mem[{chk_sel, chk_addr}] <= (chk_mem[{chk_sel, chk_addr}] & ~wmask_be) | (i_wdata & wmask_be);
      chk_v[{chk_sel, chk_addr}] <= chk_v[{chk_sel, chk_addr}] | (i_be == 2'b11);       // a byte write alone does not make a word's value known
    end
    if (bl_we) begin
      chk_mem[{bl_layer, bl_addr}] <= (chk_mem[{bl_layer, bl_addr}] & ~{{8{bl_wmask[15]}}, {8{bl_wmask[0]}}}) | (bl_wdata & {{8{bl_wmask[15]}}, {8{bl_wmask[0]}}});
      chk_v[{bl_layer, bl_addr}] <= chk_v[{bl_layer, bl_addr}] | (bl_wmask[15] && bl_wmask[0]);
    end
    if (bst == B_ACK && !o_ack && i_rnw && i_cs && (in_vram || in_rmw || in_tt)) begin
      chk_n <= chk_n + 1;
      if (chk_v[{chk_sel, chk_addr}] && chk_mem[{chk_sel, chk_addr}] !== o_rdata) begin
        chk_err <= chk_err + 1;
        if (chk_err < 20) $display("VLCHK MISMATCH sel=%0d addr=%04x read=%04x mirror=%04x (reads so far %0d)", chk_sel, chk_addr, o_rdata, chk_mem[{chk_sel, chk_addr}], chk_n);
      end
    end
    if (o_roz_frame && (chk_n != 0)) $display("VLCHK frame: %0d reads checked, %0d mismatches", chk_n, chk_err);
  end
`endif

endmodule
