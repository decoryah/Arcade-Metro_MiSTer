// Frozen-state video bench top for rtl/metro_vdp.sv (driven by tb_metro_vdp.cpp).
//
// Adapted from searchsolved/Arcade-HyperDuel_MiSTer sim/tb/tb_vdp.sv (7f154f1, GPL-3.0-or-later).  This SystemVerilog part holds the DUT
// and the clocked GFX ROM server; the C++ driver does reset, the CPU-bus writes that load the dumped state, and the frame capture.
// (The original used --timing; the g++ 9 in this WSL has no C++ coroutines, so, like taitol-mister's benches, this one is C++-driven.)
//
// METRO: IRQ model 1 (Metro / MAME 0.289: vblank at line 224, tick every 32 lines); GFX ROM is read from a flat binary (+GFX=<file>, $fread) instead of a hex file; P_SPR_BUFFERED = 0 (Dharma does not buffer
//        sprite RAM); the render-time probes the original kept in the testbench are exported as outputs.

`timescale 1ns/1ps

module tb_metro_vdp_top #(
  parameter int PIXDIV = 32,      // system clocks per dot: 32 gives the renderer headroom, 16 with HTOT = 392 is the hardware (6272 clocks per line)
  parameter int HTOT = 424,
  parameter int VLAST = 260,      // 262 = the hardware raster (263 lines)
  parameter bit VLOG = 1'b0       // 1 = the frame-synchronous layer RAM (metro_vdp.sv P_VLOG)
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        cs,
    input  logic [18:0] addr,
    input  logic        rnw,
    input  logic [1:0]  be,
    input  logic [15:0] wdata,
    input  logic [31:0] gfx_size,
    input  logic        rz_we,           // family F replay: MAME's writes to the 053936 (tile map RAM 0x400000.., line RAM 0x500000.., control 0x600000..), absolute addresses
    input  logic [23:0] rz_wa,
    input  logic [15:0] rz_wd,
    input  logic  [1:0] rz_wm,
    input  logic        vlog_en,         // P_VLOG: the driver keeps it 0 while it loads a scene (3 x 64K words through the bus), then 1
    input  logic        i4300_en,        // the I4300's own register map (family D): 0 while the driver loads a scene (internal addresses), 1 for a replay of MAME's native writes
    output logic        ack,
    output logic        ce_pix,
    output logic        de,
    output logic        vs,
    output logic [4:0]  r5, g5, b5,
    output logic        rnd_start,
    output logic        rnd_done,
    output logic [7:0]  rnd_line,
    output logic        rnd_overrun,
    output logic [15:0] rdata,
    output logic        irq,
    output logic [8:0]  vcnt,
    output logic [8:0]  hcnt_o,
    output logic        blit_done_o
);
`ifdef F64
  localparam int GFX_AW = 25;
`else
  localparam int GFX_AW = 24;
`endif

  logic [7:0] gfxrom [0:(1<<(GFX_AW+1))-1];                 // the graphics, then (+GFX2=, at +GFX2BASE=, default 0x1220000) family F's 053936 tile ROM
  initial begin : load_gfx
    string p;
    int fd, n;
    if ($value$plusargs("GFX=%s", p)) begin
      fd = $fopen(p, "rb");
      if (fd == 0) $fatal(1, "cannot open %s", p);
      n = $fread(gfxrom, fd);
      $fclose(fd);
      $display("tb_metro_vdp_top: gfx rom %0d bytes read", n);
    end
  end

  int rprio;
  initial if (!$value$plusargs("ROZPRIO=%d", rprio)) rprio = 0;
  logic        hs, vbl;
  logic              rom_req;
  logic [GFX_AW:0]   rom_addr;
  logic [6:0]        rom_len;
  logic [15:0]       rom_data;
  logic              rom_valid;

  // P_PIXDIV 32 gives the renderer simulation headroom (the real core runs fewer system clocks per pixel).
  logic [3:0] tmap_dx;                       // +TMAPDX=n: the board's tilemap X offset (2 on Daitoride / Puzzli)
  initial if (!$value$plusargs("TMAPDX=%d", tmap_dx)) tmap_dx = 4'd0;
  logic [3:0] tmap_dx1;                      // +TMAPDX1=n: layer 1's own extra offset (Grand Striker 2: 8)
  initial if (!$value$plusargs("TMAPDX1=%d", tmap_dx1)) tmap_dx1 = 4'd0;
  int gfxlat;                                // +GFXLAT=n: extra clocks of latency per ROM request (the SDRAM path of the real core: ~10-20), default 0
  initial if (!$value$plusargs("GFXLAT=%d", gfxlat)) gfxlat = 0;
  int palp, earlyp, winp, widep, w384p, w304p, tallp, i4100p;   // +PALLATCH=0|1 (default 1), +SPREARLY=0|1 (default 0), +WINMAME=0|1 (default 0), +WIDE=1 (360 px), +TALL=1 (240 lines), +I4100=1
  initial begin
    if (!$value$plusargs("WIDE=%d", widep)) widep = 0;
    if (!$value$plusargs("W384=%d", w384p)) w384p = 0;
    if (!$value$plusargs("W304=%d", w304p)) w304p = 0;
    if (!$value$plusargs("TALL=%d", tallp)) tallp = 0;
    if (!$value$plusargs("I4100=%d", i4100p)) i4100p = 0;
    if (!$value$plusargs("PALLATCH=%d", palp)) palp = 1;
    if (!$value$plusargs("SPREARLY=%d", earlyp)) earlyp = 0;
    if (!$value$plusargs("WINMAME=%d", winp)) winp = 0;
  end
  logic   noplane;
  initial noplane = $test$plusargs("NOPLANE");
  metro_vdp #(.GFX_AW(GFX_AW), .P_PIXDIV(PIXDIV), .P_H_TOTAL(HTOT), .P_VLAST(VLAST), .P_SPR_BUFFERED(1'b0), .P_IRQ_MODEL(1), .P_VBL_LINE(224), .P_TICK_LINES(32), .P_VLOG(VLOG)) dut (
    .i_compat60(1'b0), .i_win_mame(winp != 0), .i_flip_force(1'b0), .i_pal_latch(palp != 0), .i_spr_early(earlyp != 0), .i_w304(w304p != 0), .i_w384(w384p != 0), .i_wide(widep != 0), .i_tall(tallp != 0), .i_i4100(i4100p != 0), .i_ext5(1'b0), .i_tmap_dx(tmap_dx), .i_tmap_dx1(tmap_dx1), .i_scan_irq(1'b0), .i_i4300(i4300_en), .i_vbl_bit(3'd1), .i_blit_bit(3'd3), .i_irq0_pulse(1'b0), .i_vec_idx(3'd0), .o_irq_lvl(), .o_vec(), .i_irq_line_mask(8'hFF),
    .clk(clk), .rst_n(rst_n),
    .i_tim_rst(1'b0), .o_tim_evt(),
    .i_cs(cs), .i_addr(addr), .i_rnw(rnw), .i_be(be),
    .i_wdata(wdata), .o_rdata(rdata), .o_ack(ack),
    .o_hs(hs), .o_vs(vs), .o_de(de), .o_ce_pix(ce_pix),
    .o_hblank(), .o_vblank(),
    .o_r(r5), .o_g(g5), .o_b(b5),
    .o_irq(irq), .o_vbl_pulse(vbl),
    .o_rom_req(rom_req), .o_rom_addr(rom_addr), .o_rom_len(rom_len),
    .i_rom_data(rom_data), .i_rom_valid(rom_valid),
    .i_gfx_size(gfx_size),
    .i_roz_en(rz_loaded), .i_vlog_en(vlog_en), .i_roz_prio(rprio != 0), .i_no_hold(1'b0), .o_roz_frame(rz_frame), .o_roz_used(rz_used), .i_roz_done(rz_done), .o_roz_bank(rz_bank), .o_roz_x(rz_x), .i_roz_pen(rz_pen), .i_roz_op(rz_op && !noplane),
    .i_roz_req(rz_rq_req), .i_roz_addr(rz_rq_addr), .i_roz_len(rz_rq_len), .o_roz_wr(rz_wr), .o_roz_idx(rz_idx), .o_roz_data(rz_data), .o_roz_ack(rz_ack),
    .o_dbg_vdp_write(), .o_dbg_line_start(),
    .o_dbg_rnd_done(), .o_dbg_lb_nonzero(), .o_dbg_palw(), .o_dbg_ovr(),
    .o_dbg_rend_sx2_0(), .o_dbg_rend_sx2_1(), .o_dbg_rend_sx2_2(),
    .o_dbg_disp_sx2_0(), .o_dbg_disp_sx2_1(), .o_dbg_disp_sx2_2(),
    .o_dbg_topflags(),
    .o_st(vdp_st)
  );
  // +BLITLOG: every blit (clock and chip line of the start, clocks until the blitter is idle again)
  longint bl_clk = 0, bl_t0 = 0;
  int bl_line = 0;
  logic bl_run = 1'b0, bl_seen = 1'b0, bl_log;
  initial bl_log = $test$plusargs("BLITLOG");
  always_ff @(posedge clk) begin
    bl_clk <= bl_clk + 1;
    if (bl_log) begin
      if (dut.bl_start_go) begin bl_t0 <= bl_clk; bl_line <= int'(dut.vcnt); bl_run <= 1'b1; bl_seen <= 1'b0; end
      if (bl_run && dut.bl_busy) bl_seen <= 1'b1;
      if (bl_run && bl_seen && !dut.bl_busy && !dut.bl_start_go) begin
        $display("BLIT clk %0d line %0d: %0d clocks (%0d lines)", bl_t0, bl_line, bl_clk - bl_t0, (bl_clk - bl_t0) / 6272);
        bl_run <= 1'b0;
      end
    end
  end
  logic [255:0] vdp_st, roz_st;

  // ---- family F: the 053936 plane with the state of a MAME frame (+ROZ=<file.roz> from tools/lua/vstate.lua VS_ROZ=1, +GFX2=<2 MB tile ROM>)
  logic [15:0] rz_ram  [0:131071];
  logic [15:0] rz_line [0:2047];
  logic [15:0] rz_ctrl [16];
  logic        rz_loaded;
  int          gfx2_base, map_base;
  logic        bt_mode;                       // +BT=1: Blazing Tornado's plane (8 x 8 tiles, 256 x 512, offsets (-77, -21))
  initial begin int bt; if (!$value$plusargs("BT=%d", bt)) bt = 0; bt_mode = (bt != 0); end
  initial begin : load_roz
    string p;
    int fd, n, btl;
    logic [7:0] b [0:32 + 4096 + 262144 - 1];
    rz_loaded = 1'b0;
    if (!$value$plusargs("BT=%d", btl)) btl = 0;
    if (!$value$plusargs("GFX2BASE=%d", gfx2_base)) gfx2_base = 32'h1220000;
    map_base = gfx2_base + 32'h200000;           // the tile map RAM follows the tile ROM in this model's graphics space (the core: metro_main.sv rz_map_base)
    if ($value$plusargs("GFX2=%s", p)) begin
      fd = $fopen(p, "rb"); if (fd == 0) $fatal(1, "cannot open %s", p);
      for (int i = 0; i < 2097152; i++) begin
        n = $fgetc(fd);
        // Grand Striker 2's tile ROM is stored with the tile rows in raster order (metro_loader.sv): offset bits {7, 6, 5:3, 2:0} -> {7, 5:3, 6, 2:0}
        if (btl == 0) gfxrom[gfx2_base + {i[31:8], i[7], i[5:3], i[6], i[2:0]}] = n[7:0];
        else          gfxrom[gfx2_base + i] = n[7:0];
      end
      $fclose(fd);
    end
    if ($value$plusargs("ROZ=%s", p)) begin
      fd = $fopen(p, "rb"); if (fd == 0) $fatal(1, "cannot open %s", p);
      n = $fread(b, fd); $fclose(fd);
      for (int i = 0; i < 16; i++) rz_ctrl[i] = {b[i*2], b[i*2+1]};
      for (int i = 0; i < 2048; i++) rz_line[i] = {b[32 + i*2], b[32 + i*2+1]};
      for (int i = 0; i < 131072; i++) rz_ram[i] = {b[32 + 4096 + i*2], b[32 + 4096 + i*2+1]};
      for (int i = 0; i < 131072; i++) begin gfxrom[map_base + 2*i] = b[32 + 4096 + i*2]; gfxrom[map_base + 2*i + 1] = b[32 + 4096 + i*2 + 1]; end
      rz_loaded = 1'b1;
      $display("tb_metro_vdp_top: 053936 state read, %0d bytes", n);
    end
  end
  always_ff @(posedge clk) if (rz_we) begin
    if (rz_wa[23:20] == 4'h4) begin
      if (rz_wm[1]) begin rz_ram[rz_wa[17:1]][15:8] <= rz_wd[15:8]; gfxrom[map_base + {rz_wa[17:1], 1'b0}] <= rz_wd[15:8]; end
      if (rz_wm[0]) begin rz_ram[rz_wa[17:1]][7:0]  <= rz_wd[7:0];  gfxrom[map_base + {rz_wa[17:1], 1'b1}] <= rz_wd[7:0];  end
    end else if (rz_wa[23:12] == 12'h500) begin
      if (rz_wm[1]) rz_line[rz_wa[11:1]][15:8] <= rz_wd[15:8];
      if (rz_wm[0]) rz_line[rz_wa[11:1]][7:0]  <= rz_wd[7:0];
    end else if (rz_wa[23:5] == 19'h30000) begin
      if (rz_wm[1]) rz_ctrl[rz_wa[4:1]][15:8] <= rz_wd[15:8];
      if (rz_wm[0]) rz_ctrl[rz_wa[4:1]][7:0]  <= rz_wd[7:0];
    end
  end
  logic        rz_frame, rz_rq_req, rz_wr, rz_ack, rz_op;
  logic [GFX_AW:0] rz_rq_addr;
  logic  [6:0] rz_rq_len;
  logic [15:0] rz_data, rz_li_q;
  logic  [4:0] rz_idx;
  logic [10:0] rz_li_addr;
  logic  [8:0] rz_used, rz_done, rz_x;
  logic  [2:0] rz_bank;
  logic [11:0] rz_pen;
  logic        rz_par;
  always_ff @(posedge clk) begin
    rz_li_q    <= rz_line[rz_li_addr];
  end
  metro_roz #(.XOFF(-77), .YOFF(-19), .VIS_W(304), .VIS_H(240), .AW(GFX_AW + 1)) u_roz (
    .clk(clk), .reset(!rst_n), .i_en(rz_loaded), .i_bt(bt_mode), .i_frame(rz_frame), .i_ctrl(rz_ctrl),
    .o_li_addr(rz_li_addr), .i_li_q(rz_li_q),
    .o_rq_req(rz_rq_req), .o_rq_addr(rz_rq_addr), .o_rq_len(rz_rq_len), .i_rq_wr(rz_wr), .i_rq_idx(rz_idx), .i_rq_data(rz_data), .i_rq_ack(rz_ack),
    .i_map_base((GFX_AW+1)'(map_base)), .i_gfx2_base((GFX_AW+1)'(gfx2_base)),
    .i_inval(rz_we && rz_wa[23:20] == 4'h4), .i_inval_addr(rz_wa[17:1]), .i_rows_used(rz_used), .o_rows_done(rz_done), .o_par(rz_par),
    .i_rd_bank(rz_bank), .i_rd_x(rz_x), .o_pen(rz_pen), .o_op(rz_op), .o_st(roz_st));
  // the hardware test overlay's measurements, one clock after the frame pulse
  logic rz_frame_d = 1'b0;
  always_ff @(posedge clk) begin
    rz_frame_d <= rz_frame;
    if (rz_frame_d)
      $display("HUDST S: stale=%0d first=%0d last=%0d ovr=%0d | bmax=%0d bsum64=%0d kwait64=%0d kfmax=%0d | rows_done=%0d used=%0d | grr64=%0d grz64=%0d grc64=%0d spr=%0d lines=%0d", vdp_st[15:0], vdp_st[31:16], vdp_st[47:32], vdp_st[63:48], vdp_st[79:64], vdp_st[95:80], vdp_st[111:96], vdp_st[127:112], vdp_st[143:128], vdp_st[159:144], vdp_st[175:160], vdp_st[191:176], vdp_st[207:192], vdp_st[223:208], vdp_st[239:224]);
    if (rz_frame_d)
      $display("HUDST R: win=%0d line=%0d rlines_max=%0d wclk_max=%0d wsum64=%0d pwait64=%0d winwait64=%0d allocwait64=%0d latmax=%0d latsum64=%0d lw2_0=%04x lw3_0=%04x lw2_m=%04x lw3_m=%04x lw2_e=%04x lw3_e=%04x", roz_st[15:0], roz_st[31:16], roz_st[47:32], roz_st[63:48], roz_st[79:64], roz_st[95:80], roz_st[111:96], roz_st[127:112], roz_st[143:128], roz_st[159:144], roz_st[175:160], roz_st[191:176], roz_st[207:192], roz_st[223:208], roz_st[239:224], roz_st[255:240]);
  end

  // +PLANEDBG: the plane's window requests and the 68000's map writes with the clock count and the beam line (debugging the replay)
  longint dbg_clk = 0;
  logic   dbg_on;
  initial dbg_on = $test$plusargs("PLANEDBG");
  logic   rz_rq_d = 1'b0;
  always_ff @(posedge clk) begin
    dbg_clk <= dbg_clk + 1;
    rz_rq_d <= rz_rq_req;
    if (dbg_on) begin
      if (rz_we && rz_wa[23:20] == 4'h4) $display("PD W clk=%0d line=%0d a=%06x d=%04x m=%0d", dbg_clk, dut.vcnt, rz_wa, rz_wd, rz_wm);
      if (rz_rq_req && !rz_rq_d)         $display("PD Q clk=%0d line=%0d addr=%0d len=%0d wrow=%0d st=%0d", dbg_clk, dut.vcnt, rz_rq_addr, rz_rq_len, u_roz.wrow, u_roz.st);
      if (rz_frame)                      $display("PD F clk=%0d line=%0d", dbg_clk, dut.vcnt);
      if (dut.u_render.lay_we && dut.u_render.line_r == 9'd14 && dut.u_render.lay_waddr >= 9'd16 && dut.u_render.lay_waddr <= 9'd26 && dut.u_render.lay_wdata[14])
        $display("PD T clk=%0d line=%0d layer=%0d x=%0d data=%04x cvalid=%0d csolid=%0d topq=%0d tpen=%03x cpen=%03x oor=%0d pfv=%0d st=%0d", dbg_clk, dut.u_render.line_r, dut.u_render.layer, dut.u_render.lay_waddr, dut.u_render.lay_wdata,
                 dut.u_render.cache_valid, dut.u_render.cache_solid, dut.u_render.tile_opaque, dut.u_render.tile_pen, dut.u_render.cache_solid_pen, dut.u_render.cache_oor, dut.u_render.pf_valid, dut.u_render.st);
      if (u_roz.st == 5'd18 && {gfxrom[map_base + 2*u_roz.moff], gfxrom[map_base + 2*u_roz.moff + 1]} != u_roz.wr_q)
        $display("PD S clk=%0d line=%0d wrow=%0d moff=%0d cached=%04x sdram=%04x", dbg_clk, dut.vcnt, u_roz.wrow, u_roz.moff, u_roz.wr_q, {gfxrom[map_base + 2*u_roz.moff], gfxrom[map_base + 2*u_roz.moff + 1]});
      if (dut.u_render.o_lb_we && dut.rnd_line >= 13 && dut.rnd_line <= 15 && dut.u_render.o_lb_x >= 18 && dut.u_render.o_lb_x <= 25 && dut.u_render.o_lb_pen != 12'd0)
        $display("PD L clk=%0d rline=%0d x=%0d pen=%03x  spr_q=%010x lay_q=%04x st=%0d", dbg_clk, dut.rnd_line, dut.u_render.o_lb_x, dut.u_render.o_lb_pen, dut.u_render.spr_q, dut.u_render.lay_q, dut.u_render.st);
    end
  end

  assign rnd_start   = dut.rnd_start;
  assign rnd_done    = dut.rnd_done;
  assign rnd_line    = dut.rnd_line;
  assign rnd_overrun = dut.rnd_overrun;
  assign vcnt        = dut.vcnt;
  assign hcnt_o      = dut.hcnt;
  assign blit_done_o = dut.blit_done;

  // plane engine timing probe: per frame, the clock at which each row was finished (relative to the frame pulse) against the real-time pace of one row per line
  longint rzt_pc = 0, rzt_last = 0, rzt_worst = 0;
  logic [8:0] rzt_prev = 9'd0;
  int rzt_row_worst = 0;
  always_ff @(posedge clk) begin
    rzt_pc <= rzt_pc + 1;
    if (rz_frame) begin
      $display("ROZT frame: rows_done=%0d last_row_clk=%0d (a frame is %0d clk) worst_lateness_vs_1row_per_line=%0d at row %0d vfirst_q=%0d vfirst=%0d crtc_v=%04x unlock=%0d winmame=%0d", rz_done, rzt_last, 6272*263, rzt_worst, rzt_row_worst, dut.crtc_vfirst_q, dut.crtc_vfirst, dut.r_crtc_v, dut.r_crtc_unlock, dut.i_win_mame);
      rzt_pc <= 0; rzt_last <= 0; rzt_worst <= -100000000; rzt_prev <= 9'd0; rzt_row_worst <= 0;
    end else if (rz_done != rzt_prev) begin
      rzt_prev <= rz_done; rzt_last <= rzt_pc;
      if (longint'(rzt_pc) - longint'(rz_done) * 6272 > rzt_worst) begin rzt_worst <= longint'(rzt_pc) - longint'(rz_done) * 6272; rzt_row_worst <= int'(rz_done); end
    end
  end

  // ROM stream server (pulse req -> latency -> len bytes with a gap)
  logic [GFX_AW:0]   srv_addr;
  logic [6:0]        srv_left;
  int                srv_wait;
  logic              srv_active;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      srv_active <= 1'b0;
      rom_valid  <= 1'b0;
    end else begin
      rom_valid <= 1'b0;
      if (!srv_active) begin
        if (rom_req) begin
          srv_active <= 1'b1;
          srv_addr   <= rom_addr;
          srv_left   <= rom_len;
          srv_wait   <= int'(rom_addr[1:0]) + 1 + gfxlat;
        end
      end else if (srv_wait > 0) begin
        srv_wait <= srv_wait - 1;
      end else if (!srv_addr[0] && !srv_left[0]) begin
        // word-mode request (renderer / CPU window): 2 bytes per valid, even byte in [15:8]
        rom_valid <= 1'b1;
        rom_data  <= {gfxrom[srv_addr], gfxrom[srv_addr + 1]};
        srv_addr  <= srv_addr + 25'd2;
        if (srv_left == 7'd2) srv_active <= 1'b0;
        else begin
          srv_left <= srv_left - 7'd2;
          if (srv_addr[3:0] == 4'd4) srv_wait <= 2;
        end
      end else begin
        // byte-mode request (blitter): one byte per valid in [7:0]
        rom_valid <= 1'b1;
        rom_data  <= {8'd0, gfxrom[srv_addr]};
        srv_addr  <= srv_addr + 1'b1;
        if (srv_left == 7'd1) srv_active <= 1'b0;
        else begin
          srv_left <= srv_left - 7'd1;
          if (srv_addr[2:0] == 3'd4) srv_wait <= 2;
        end
      end
    end
  end
endmodule
