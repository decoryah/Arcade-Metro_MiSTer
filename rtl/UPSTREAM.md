# Files in this directory derived from other projects

| File | Upstream | Licence | Changes for Metro |
|---|---|---|---|
| `metro_vdp.sv` | searchsolved/Arcade-HyperDuel_MiSTer `rtl/i4220_vdp.sv` at 7f154f1e856ce5863f962821f2b330d1e8a85727 | GPL-3.0-or-later (`../LICENSE`) | renamed; unbuffered sprite RAM (frame-start copy); IRQ model parameters `P_IRQ_MODEL`, `P_VBL_LINE`, `P_TICK_LINES`; raster totals and sync positions as parameters (`P_H_TOTAL`, `P_VLAST`, `P_HS_*`, `P_VS_*`); input `i_win_mame` (force MAME's chip lines 0..223 instead of the CRTC window); **screen flip** (frame-latched `flip_q`: kick lines in reverse display order, scroll +72/+39, the window forced to 0..223) |
| `metro_render.sv` | `rtl/i4220_render.sv`, same commit | same | renamed; input `i_flip` (sprite offsets 318-x / 222-y, per-sprite rounding correction, X mirror at the line-buffer write, wider prescan slack); **bug fix** (below) |
| `metro_blitter.sv` | `rtl/i4220_blitter.sv`, same commit | same | renamed only |
| `metro_dpram.sv` | `rtl/hd_dpram.sv`, same commit | same | renamed; `SLICED` option (each byte stored as a 5-bit and a 3-bit memory, `metro_dpram_raw` in the same file, `maximum_depth = 2048` on the 5-bit slices) so the three 64Kx16 VRAMs and the work RAM fit the M10K budget |
| `metro_tdpram.sv` | `rtl/hd_tdpram.sv`, same commit | same | renamed only |
| `metro_sdram.sv` | `rtl/hyprduel_sdram.sv`, same commit | same | renamed; 96 MHz timing (refresh period 750, power-up wait 9600 clocks with a 14-bit counter -- upstream's 13-bit counter cannot count that far), region bases for the Metro image layout, optional extra read-capture cycle (`i_rd_late`), unused sound-ROM client tied off |

Every change from upstream is marked `METRO:` in the file. To compare with upstream, diff against `ref/Arcade-HyperDuel_MiSTer/rtl/` after
undoing the renames (`i4220_vdp`->`metro_vdp`, `i4220_render`->`metro_render`, `i4220_blitter`->`metro_blitter`, `hd_dpram`->`metro_dpram`,
`hd_tdpram`->`metro_tdpram`). Known deviations from MAME that are inherited from upstream are listed in `../../docs/status.md`.
The testbench files in `../sim/` are adapted from the same project's `sim/tb/tb_vdp.sv`.

Written for this core (not derived): `metro_main.sv` (the Metro board: fx68k, memory map, I/O, RAM, glue; bus-cycle structure after
mcatadv-mister's `mcatadv_main.sv`) and `metro_cen.sv` (clock enables, after `mcatadv_cen.sv`). Also written for this core: `metro_loader.sv` (MRA download: config bytes, GFX descramble at download time), `metro_romif.sv`
(program-ROM read adapter with a 512-word cache and next-word prefetch, see `../docs/status.md` Phase 6). The 68000 core is vendored in `../modules/cpu-fx68k`
(`../modules/VENDOR.md`).

## Bug fixed in upstream's renderer (worth reporting to its author)

**A sprite whose last emitted pair word is screen word 0 draws the wrong pixel at screen column 0.** It happens to x-flipped sprites that reach column 0 (their
walk is right to left, so word 0 comes last) and to any sprite clipped to columns 0-1 on the left. In `ST_S_OVL` the last word is written by `spr_we` one cycle
after the emit; the state machine leaves for `ST_RESOLVE` at once, and resolve's first read of word 0 is registered at the same clock edge as that write, so it
returns the old word. Pixel 0 loses the sprite (pixel 1 reads a cycle later and is right). Fix (`metro_render.sv`, marked `METRO:`): do not leave `ST_S_OVL`
while `spr_we` is set (`emit_done && s_fill_done && f_parked && !spr_we`). Found with `tools/metro_edgescan.py`; 9 of 100 randomised scenes differed in column 0
before, 0 after. Hyper Duel's own sprites are flipped often, so it can show there too whenever the last sprite on a line reaches the left edge.

## Open: a sprite pixel lost in one dense randomised scene (known issue C, not fixed)

`work/fuzz/f.93` (randomised, no screen flip, heavy zoom and overlap): the RTL draws the layer pixel instead of a sprite pixel at x = 280 on rows 156 and 158
(2 pixels; the reference renderer and MAME agree with each other). 1 scene of 192 randomised non-flip scenes shows it, none of 79 real game frames does. Not
caused by this core's changes that were checked (reverting the sprite cull change leaves it), so it is probably in the inherited renderer: the pattern (single
column, alternate rows) looks like a read-modify-write of a line-buffer word racing the previous sprite's last write, as the column-0 bug above does.
Found 2026-10-07 when the non-flip half of `work/fuzz/f` was first run through the RTL bench (before, only `work/fuzz2` and the flipped half were).

## Changes made for the Daitoride / Pururun family (2026-10-07)

`metro_vdp.sv`: `i_tmap_dx` (tilemap X offset 2 on the Daitoride and Puzzli boards, added to every layer's X scroll flipped and not), `i_scan_irq` (Puzzli's interrupt
model: scanline 224 raises causes 4 + 0, every earlier scanline raises cause 1 while enable bit 1 is clear), `P_TICK_CLKS` (the periodic bit-4 tick as an exact clock
count, 200000 at 96 MHz = MAME's 480 Hz, instead of 32 lines which drifts 0.3 %), `FLIP_MAME_SHIFT = 0` (layers mirror about the visible area when flipped).
`metro_render.sv`: the sprite cull test compares registered end positions (`sxe_q`, `sye_q`, computed in the first COVER2 pass), which took a comparator chain out of the
worst path at 96 MHz.

## Changes after the hardware test of 20261007c (2026-10-07 night)

`metro_vdp.sv`: `vbl_line = P_VBL_LINE + crtc_vfirst_q` and `spr_copy_line` (registered): the vblank interrupt (cause 0, and 4 in the scan model) and the sprite copy of the unbuffered
Metro mode follow the CRTC display window instead of MAME's fixed line 224 / last line (with vfirst 0, i.e. `i_win_mame` or flip, they are exactly as before); `i_flip_force`
(OSD / DIP flip, ORed into the frame latch of the flip and of the window). Upstream (Hyper Duel) keeps its interrupt at the MAME line with a window that starts at line 2; the 11-line
offset of the Metro boards (CRTC parameter 7 = 11) made the difference visible: the vblank routine's scroll / palette writes landed in the bottom 11 rows (`docs/status.md`).
`metro_sound.sv`: `mix >>> 3` on the YM2151 boards. `Metro.sv`: OSD `Flip screen`, the Flip Screen DIP (bit 6 of DSW0) drives `flip_force`.
