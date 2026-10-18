# Status and measured results

## Oracle setup (2026-10-05)

- MAME: `C:\repos\taitol-mister\mister\tools\mame\mame.exe` (located by `tools/paths.py`; `METRO_MAME` overrides), `-version` = `0.289 (mame0289)`.
- ROMs: `R:\Games\Arcade\MAME 0.289 ROMs (merged)`; `-verifyroms` good for `dharma`, `dharmag`, `dharmaj`, `dharmak`.
- Run from `work/mame/` so `cfg/`, `nvram/`, `snap/` land there (gitignored).
- Reproduce the register trace:

```
cd work/mame
MT_OUT=$PWD/mtrace_dharma.txt MT_BASE=800000 MT_CAP=25 MT_COIN=300 MT_START=420 \
  mame.exe dharma -rompath "R:\Games\Arcade\MAME 0.289 ROMs (merged)" -cfg_directory cfg -nvram_directory nvram \
  -snapshot_directory snap -video none -sound none -nothrottle -skip_gameinfo \
  -autoboot_script ../../mister/tools/lua/mtrace.lua -seconds_to_run 45
```

## MAME 0.289 Lua pitfalls found while writing `tools/lua/mtrace.lua` (cost real time; keep)

1. **Tap handles are garbage-collected.** `install_write_tap` / `install_read_tap` return a handle; if nothing references it after the
   script body finishes, MAME silently drops the tap. Symptom: counters that stop moving after some frames while the game keeps running.
   An early reading of "the game stops servicing interrupts after frame 200" was **wrong** for this reason. Keep handles in a global.
   The same applies to the subscription returned by `emu.add_machine_stop_notifier`.
2. **Stop hook name:** `emu.add_machine_stop_notifier(cb)`; there is no `emu.register_stop`.
3. **No `screen:vpos()` / `hpos()` in 0.289.** `frame_period` and `scan_period` are *properties* (numbers), `time_until_pos(0)` returns seconds
   as a number. `vpos = floor((frame_period - time_until_pos(0)) / scan_period)` (implemented in the script; the beam line is approximate).
4. Callback `offset` is the **byte address**; on the 16-bit bus the reported address is word-aligned and `mask` says which byte lane
   (so a byte write to 0x788A3 shows up as address 0x788A2, mask 0x00FF).
5. Errors inside a tap callback are swallowed silently. The script wraps them in `pcall` and prints the first one.
6. `-seconds_to_run` also writes a snapshot of the last frame into the snapshot directory.

## Dharma Doujou (`dharma`) boot, MAME 0.289

- Boots to the title screen (hand-checked screenshot: だるま道場 logo, 320x224). The title **waits for a coin**: with no input the 68000 idles in
  the loop at 0x0634-0x0644 polling RAM `$40E000` bit 7 and `$40E04D`. A coin at frame 300 sets `$40E000` to 0x80 and the game leaves the loop
  (PC 0x13EC). This is normal attract behaviour, not a stall.
- Trace of 2620 frames (about 45 s emulated), coin at 300, start at 420. Writes (W) and reads (R) by VDP-relative address:

| Register | Accesses | Notes |
|---|---|---|
| 0x78840-0x7884C blitter | 7264 writes each | 7264 blits |
| 0x78850 / 0x78852 screen Y / X offset | 1 / 6 | |
| 0x78860-0x7886A window | 6 each | |
| 0x78870-0x7887A scroll | 2565 each | about once per frame |
| 0x78880 CRTC vertical | 4 | one bracket at frame 37: 0x00DF 0x02F1 0x04F9 0x070B |
| 0x78890 CRTC horizontal | 327685 | boot-time counting sweep 0x017F..., never a programming bracket |
| 0x788A0 CRTC unlock | 4 | |
| 0x788A2/3 IRQ cause | 83269 W, 132805 R | histogram below |
| 0x788A4/5 IRQ enable | **1** | 0x0A at frame 56 (bits 1, 3 masked) |
| 0x788A8/9 sound latch | 53 | |
| 0x788AA ROM bank | 632898 | the game thrashes it |
| 0x788AC screen control | 2529 | values in the logged sample: 0x0700 (most), 0x0702, 0x0002, 0x0000; not yet decoded |
| 0x79700-0x79712 sprite/layer regs | 1-4 each | spr_pri 0x8000, spr_color 0x000F, layer_pri 0x0024, bg_color 0x0FFE |

IRQ cause byte (0x788A3), value histogram over the whole run:

| Value | Reads | Writes (acks) |
|---|---|---|
| 0x00 | | 52290 |
| 0x01 (vblank) | 2521 | 2579 |
| 0x04 (blitter) | 14329 | 7264 |
| 0x10 | 115689 | 21136 |
| 0x11 / 0x14 / 0x15 | 66 / 199 / 1 | |

Reading: vblank about once per frame; one blitter ack per blit; **bit 4 acknowledged about 8 times per frame** (21136 / 2620), i.e. the handler
runs at MAME's guessed 480 Hz. The real source of bit 4 is not known.

## ROM path (done for the Dharma sets, 2026-10-05)

Python for the tools: **3.8** (`C:\Python38\python.exe`; the `python` on this shell's PATH is 3.5 and cannot run `mra_build.py`).

- `tools/metro_rom.py`: parses all 50 `ROM_START`s of the 0.289 `metro.cpp`, builds regions the way MAME's loader does (including
  `ROM_LOAD64_WORD/64_BYTE/32_WORD/16_BYTE/16_WORD_SWAP`) and the driver inits (`init_dharmak`, `init_balcube`), and builds the flat image
  (layout and config block in the file header; 0x500020 bytes: maincpu 0x000000 / audiocpu 0x080000 / oki 0x0A0000 / gfx 0x100000 / config 0x500000).
- **Check against MAME** (`tools/lua/regions.lua` dumps MAME's regions after its init, `metro_rom.py check`): `dharma`, `dharmaj`, `dharmak`,
  `dharmag` x `maincpu` / `audiocpu` / `vdp2` / `oki` = **16 of 16 regions byte-identical**. The test is not vacuous: `init_dharmak`
  changes 436021 bytes of `dharma`'s GFX and none of `dharmaj`'s. This also confirms the `ROM_LOAD64_WORD` byte order and the bitswap reading.
- `tools/make_mra.py` writes `mister/mra/*.mra` from the same parse (DIP switches from `mame -listxml`, 16-bit port `DSW0`);
  `tools/mra_verify.py` assembles each MRA through `tools/mra_build.py` (MiSTer-style interpreter) and compares with the independent image:
  **4 of 4 identical**. `tools/mra_build.py` is `taitol-mister`'s copy unchanged (GPL-3.0, from plasticbugs/analogue-pocket-gaiapolis).
- Reproduce: `py -3.8 tools/make_mra.py && py -3.8 tools/mra_verify.py`; the MAME comparison needs the dump first
  (`MR_OUT=... mame.exe <set> ... -autoboot_script tools/lua/regions.lua -seconds_to_run 2`, then `metro_rom.py check <set> <prefix>`).
- Not decided yet: where the core applies the GFX descramble (config byte 2 selects it; `init_dharmak` permutes bytes 1 and 3 of every 4).

## Reference renderer (done, 2026-10-05): `tools/metro_ref.py`

Pure-Python re-implementation of MAME 0.289's `imagetek_i4100.cpp` `screen_update` (3 tilemap layers with window/scroll, tile-table lookup,
4/8-bit and 8x8/16x16 tiles, solid-colour tiles, zooming/flipping sprites with 4/8-bit pixels, layer and sprite priorities, screen flip, blank),
run on a frozen state dumped from MAME (`tools/lua/vstate.lua`: VRAM x3, palette, sprite RAM, tile table, shadowed write-only registers, plus
MAME's own snapshot) and compared pixel for pixel with MAME's snapshot of that frame.

| Test set | Frames | Mismatches | What it exercises |
|---|---|---|---|
| real play + attract, `work/states` | 9 | **0** | 4bpp 8x8 tiles, solid tiles, 87 sprite draws (zoom 1.0 only) |
| real play + attract, `work/states2` (every 120 frames to 14400, coin/start repeated, pseudo-random joystick) | 119 | **0** | the above plus scrolling (24 frames) and 2891 sprite draws; still zoom 1.0 only, no flips, no 8bpp, no 16x16, no windows, layer priority always 0,1,2 |
| randomised scenes, `work/fuzz` (`tools/lua/vfuzz.lua`, seed 7) | 150 | **0** | blank (17), screen flip (58), 16x16 layers (131), windows (146), scroll (150), ~64 layer-priority permutations, ~150 distinct sprite-priority register values, all 64 zoom values, sprite flips x/y (~3900 each), 8bpp sprites (1497) and 8bpp tiles (149k), tile flips, solid tiles, clipped sprites, out-of-range tiles |

- **Negative tests** (deliberately broken model, same frames): dropping sprites, a +1 sprite X offset, a +1 layer scroll or a single palette bit
  all give hundreds to thousands of differing pixels, so the comparison can fail. (Swapping layers 0/1 gives 0 differences where they do not overlap.)
- **What Dharma itself uses:** only the first row of that table. Dharma never uses zoom, flips, 8bpp, 16x16, windows or non-default layer priority,
  so the Dharma core's video does not need them; the other Metro games do, and the renderer covers them against MAME already.
- **Still only transcribed, not compared against MAME:** per-game tilemap offsets (`set_tmap_xoffsets`, non-zero for the Daitoride/Pururun/Puzzli/Gun
  Master group), the I4100 (no 8bpp/16x16) and I4300 variants, buffered sprite RAM, and gfx ROMs larger than Dharma's. Test them with those games' dumps.
- How the fuzz works: the 68000 is parked in `bra.s *` in RAM with interrupts masked, a random state is written through the CPU address space
  (taps still see the writes), MAME renders, and the state and snapshot are dumped like a real frame.
- Reproduce: `py -3.8 tools/metro_cov.py work/fuzz/f` (needs the dumps: `VF_OUT=... VF_N=150 VF_SEED=7 mame.exe dharma ... -autoboot_script tools/lua/vfuzz.lua`).
  Speed: about 0.7 s per frame in pure Python.

**Open: which chip lines does the real display show?** MAME displays chip lines 0-223. Dharma's CRTC programs first visible line 11 (active 224, so
lines 11-234). Rendering lines 0-239 (`Renderer.h = 240`) shows the game's artwork **continues to about line 234** (the orange wave border at the
bottom is cut off in MAME's picture, 5 or so plain lines follow), exactly where the CRTC window ends. That coincidence suggests the hardware
shows lines 11-234 and MAME crops the bottom 11 lines of art and shows 11 lines of what may be hidden work area at the top. This is circumstantial.
It could be settled by comparing a real-board capture: with the 11-line window the "TIME" label would sit about 11 lines closer to the top edge than in MAME.
Design consequence: make the displayed window an option (CRTC window vs MAME's 0-223) the way Hyper Duel does, and decide the default once someone compares footage.

## VDP RTL and frozen-state bench (Phase 4, 2026-10-05)

**RTL.** `mister/rtl/metro_{vdp,render,blitter,dpram,tdpram}.sv` are copies of searchsolved/Arcade-HyperDuel_MiSTer `rtl/` at 7f154f1
(GPL-3.0-or-later, `mister/LICENSE`), renamed, with attribution headers. Two functional changes, both marked `METRO:` in the code:
1. **Unbuffered sprite RAM** (`P_SPR_BUFFERED = 0`). Upstream only had the buffered path (copy at vblank start, sprites a frame late); with 0 the
   sprite buffer was never filled and no sprites appeared. Now the copy is taken at the start of the last line of the frame, finishing before
   line 0 renders, so the frame shows the sprite RAM as the game left it. Equals MAME's live sprite RAM when the game finishes its sprite
   updates before the visible area (not proven for every game; revisit with the system bench).
2. **IRQ model parameter** (`P_IRQ_MODEL = 1`, `P_VBL_LINE`, `P_TICK_LINES`): bit 0 at the start of line `P_VBL_LINE` (default 224, MAME),
   bit 2 blitter done (upstream: when the blit really finishes, not MAME's fixed 500 us), bit 4 every `P_TICK_LINES` (32) lines. Model 0 is
   upstream's Hyper Duel behaviour, unchanged. `mister/sim/run_irq.sh`: 6 frames, exactly 1 vblank per frame always on line 224, 8-9 ticks per
   frame, nothing spurious, enable mask 0x0A respected.

**Bench.** `mister/sim/tb_metro_vdp_top.sv` (DUT + clocked GFX ROM server) driven by `mister/sim/tb_metro_vdp.cpp` (reset, loads a dumped state
through the CPU bus, captures a frame as PPM), built and run in WSL by `mister/sim/run_vdp.sh`; `tools/vtest.sh <set> <prefix> <frame>...` converts
a dump with `tools/metro_scene.py`, runs it and compares with MAME's snapshot (`tools/metro_cmp.py`). It is C++-driven because the WSL g++ 9
has no C++ coroutines, so Verilator `--timing` benches (the original `tb_vdp.sv`) cannot build there, which is also why the Taito L benches are C++.
One run is about 12 s after the build.

| Test | Scenes | Pixel-identical to MAME | Notes |
|---|---|---|---|
| real Dharma frames (`work/states`) | 9 | **9** | peak render 5021 cycles/line (frame 700) |
| randomised, no screen flip (`work/fuzz2`, seed 11) | 100 | **91** | the other 9 differ in column 0 only, 4-14 pixels each (known issue B) |
| randomised with screen flip (`work/fuzz`, scenes 0-19; 16 ran, 4 hit a build failure while I edited the driver) | 16 | 13 | the 3 that differ (4, 13, 14) are exactly the ones with the flip bit set and not blank: the RTL ignores flip (known issue A) |

**Known RTL deviations from MAME** (both are in the upstream Hyper Duel RTL; Dharma's own graphics never trigger either):
**Both are fixed (2026-10-07): see "Screen flip and the column-0 fix" below.** The text that follows is how they were found.
- **A. Screen flip (screen control bit 0) is not implemented.** Proof: with flip disabled in the model, the model reproduces the RTL's picture of a
  flip scene exactly (0 differing pixels). Dharma has a Flip Screen DIP, so it will be needed. **Verified recipe** (`tools/metro_flipcheck.py`, 49 of
  49 flipped scenes equal MAME): flip equals the *unflipped* scene rendered with (1) layer scroll X + 72 and Y + 39 (392 - 320 and 263 - 224),
  (2) sprite screen offsets replaced by 318 - x_off and 222 - y_off as unbounded signed values, (3) a per-sprite position correction of
  `round(w*zoom) - floor(w*zoom)` (0 or 1 pixel; for y likewise), sprite flip bits unchanged, then mirrored in X and Y. For the RTL: kick lines
  in reverse order (display row v renders chip line 223 - v), mirror the line-buffer X at resolve, and apply the three adjustments. For Dharma's
  own offsets (0x9F / 0x6F) the sprite offset adjustment is the identity.
- **B. FlipX sprites that cover screen column 0 draw the wrong pixel at column 0** (only). `tools/metro_edgescan.py` on 8x8 sprites at zoom 1.0:
  non-flipped sprites are correct at every left overhang; flipX sprites are wrong at column 0 for x = -5..0 (at least 3 visible pixels); same at
  zoom 1.39x. Cause not located (the flipX path reads sprite pairs in decreasing order, `wcur - 1`, in `ST_S_OVL`). Worth reporting to the
  Hyper Duel author.

**Render budget.** The bench uses 32 system clocks per pixel (13568 cycles per line). At the hardware ratio of 12 (80 MHz, 424-dot line) the
budget is 5088 cycles per line; **real Dharma frame 700 peaks at 5021**, essentially at the limit (the renderer is elastic: a 4-deep kick FIFO
lets busy lines borrow from quiet ones), and dense random scenes reach 6613. A higher clock-per-pixel ratio gives margin; the sprite engine
cost is what scales. Decide the system clock together with the pixel clock (6.0 MHz at 96 MHz = 16 clocks per pixel = 6784 per line).

**Process notes (each cost time).** Python text-mode writes on Windows turn LF into CRLF and WSL's bash then fails with `set: -` / `cd: ...\r`:
write with `newline=''`, or check with `tr -cd '\r' < file | wc -c`. WSL does not forward Git-Bash environment variables: pass them with
`wsl -e env VAR=1 bash ...`. A running batch and an edit of its build or scripts do not mix: use `BUILD_DIR` for a separate build.

## System bench (Phase 5, 2026-10-05): the board runs Dharma from reset, state identical to MAME

**RTL.** `mister/rtl/metro_main.sv` is the board: fx68k (12 MHz), the 256 KB program ROM port, 64 KB work RAM mirrored through 0x4FFFFF, `metro_vdp`
(IRQ model 1, level 2 autovector), the I/O ports at 0xC00000 (IN0 bit 7 = sound busy), and the sound-command byte at 0x8788A9 (overlays the VDP
window), laid out as `docs/hardware.md` sections 3-5 and following the bus-cycle structure of `mcatadv_main.sv`. `mister/rtl/metro_cen.sv`: 96 MHz
machine clock, 68000 phase enables /8 = exactly 12 MHz. `metro_vdp` now takes its raster totals as parameters: with 96 MHz, `P_PIXDIV = 16`
(6.0 MHz dots), 392 x 263, **the frame is exactly 1,649,536 clocks = MAME's 58.2328 Hz with the same 206k CPU cycles per frame**, the closest
possible timing to the oracle. fx68k is vendored from `mcatadv-mister` (`mister/modules/VENDOR.md`).

**Bench.** `mister/sim/tb_metro_sys_top.sv` (board + behavioural program/GFX ROMs + a stand-in for the sound CPU's busy flag, 60 us after a command write +
a dump task) driven by `mister/sim/tb_metro_sys.cpp` (reset, scripted coin for 2 frames and 1P start for 6 frames at given frames, dumps VDP memories and
registers at chosen frames in the MAME `.mem` order); `mister/sim/run_sys.sh` builds and runs it in WSL (`WINMAME=1` forces MAME's window);
`tools/metro_syscmp.py` compares with a MAME dump of the same frame. Frame k = the k-th vblank since reset, matching `vstate.lua`'s `frame_number()`.
Speed: about 0.2 MHz of simulated clock (5 s per frame; 510 frames took about an hour). Verilator's own `OPT_FAST` default is `-Os` and overrides
`-CFLAGS -O3`; `-MAKEFLAGS "OPT_FAST=-O3 OPT_SLOW=-O1"` gives about twice the speed.

**Result: from a cold reset, running Dharma's real program, the whole VDP state is identical to MAME at every frame compared.**

| Frame | Situation | VRAM x3, palette, sprite RAM, tile table, registers | Image |
|---|---|---|---|
| 100, 150, 250, 270 | boot, self-test screen ("ROM OK / RAM OK") | identical | identical to the model through the CRTC window (below) |
| 390 | after a coin at frame 300 | identical | identical |
| 420 | after 1P start at frame 400 (menu) | identical | identical |
| 510 | menu | identical | (not checked, see below) |

This covers the 68000 running the boot code, the blitter on Dharma's real command streams (VRAM is built by it), the interrupt model (vblank, blitter
chaining, the bit-4 tick), IN0/IN1/DSW0/IN2 reads, the coin input, and the sound-command write plus busy handshake (stand-in).

**The displayed window.** The VDP follows the CRTC the game programs (first visible line 11 for Dharma), as Hyper Duel's author designed it, so its
picture is chip lines 11-234. MAME shows 0-223. At frame 100/150 (self-test text on black) the RTL image therefore differs from MAME's PNG by 1062
pixels: the text sits 11 lines higher. This is **not a bug**: `metro_syscmp.py --window 11` renders MAME's own state dump through the same window with
the reference model and the RTL image matches it exactly (0 of 71680 pixels, at 100, 150, 250, 270, 390 and 420). `i_win_mame` (RTL input, `WINMAME=1`
in the bench) forces MAME's window instead; with it the RTL's image equals **MAME's own PNG snapshot** (0 of 71680 pixels at frames 100 and 150, no model in between). Which one the real board shows is still open (see "Open: which chip lines..." above); make it an OSD option.

**Not covered yet.** Gameplay with joystick input (the `work/states` dumps after frame 520), the real uPD78C10 and sound, screen flip (known gap A), the
Flip Screen / Service DIP paths, long runs for drift against MAME (the bit-4 tick is MAME's guessed rate), a real SDRAM-fed ROM (done in Phase 6, below), and the render budget at the real clock (the bench uses 16 clocks per dot = 6272 cycles per line, which is above the
5021-cycle peak seen on real frames). Harness bug found and fixed: after the last frame the driver kept the dump flag set, re-dumping every tick.

## MiSTer shell, real SDRAM path, Quartus fit (Phase 6, 2026-10-06/07)

**Files.** `mister/Metro.sv` (emu top: PLL 96 MHz + shifted SDRAM clock, `hps_io`, MRA config/ROM download through `metro_loader`, `metro_sdram`, `metro_romif`,
`arcade_video` + `video_freak`, silent audio, sound-busy stand-in), `Metro.qpf/.qsf`, `files.qip`, `Metro.sdc`, `sys/`, `rtl/pll*`. The ROM image layout is in
`tools/metro_rom.py` (config bytes first, program ROM at 0x010000, GFX at 0x100000 descrambled by the loader at download time).

**Three bugs the hardware flow found that the benches could not (keep this list; each was invisible in simulation):**

1. *SDRAM power-up counter 13 bits wide, wait 9600 (100 us at 96 MHz).* The counter can never reach 9600, the controller never left init, `mem_ready` stayed
   0, the machine stayed in reset and Quartus removed the CPU and the VDP as dead logic ("synthesis successful", 455 kbit of block RAM, `SDRAM_nRAS` stuck high).
   The benches ran the controller with `P_SHORT_INIT=1` (32 clocks), which hid it. **Fixed** (14 bits) and the system bench now runs the real 9600-clock wait.
   *Check after every synthesis: `metro_main` (about 7000 LCs) must be in the hierarchy, and block memory must be about 4.4 Mbit.*
2. *Fit: 565 M10K blocks needed, 553 available* (logic only 36%). A 16-bit word wastes a fifth of every M10K and the fitter maps a deep x5 memory as 5 x 8Kx1.
   `metro_dpram` now has `SLICED=1` (used by the three 64Kx16 VRAMs and the work RAM): each byte is stored as a 5-bit and a 3-bit memory
   (`metro_dpram_raw`), the byte enables become the slices' write enables, and the 5-bit slices carry `maximum_depth = 2048`, which forces the 2Kx5 block mode
   (experiment in a throwaway project: 64Kx5 true dual port = 40 blocks as is, 32 with `maximum_depth`; 64Kx3 = 24; 64Kx10 = 80, 64 with `maximum_depth = 1024`).
   Expected saving 56 blocks (565 -> about 509). The slices are plain RTL in the Verilator branch too, so the bench exercises the same structure (frame 100
   state identical to MAME and to the unsliced run, same cycle count). Quartus 17 Lite needs an explicit `generate ... endgenerate` around a module-level `if`.
3. *Program ROM from the SDRAM cost one wait state per ROM cycle.* An SDRAM read answers about 13 clocks after AS, just after the 68000 samples DTACK, so every
   ROM cycle took 40 clocks instead of 32 although AS stayed low only 28 (invisible in a histogram of AS-low widths; the period between AS falls shows it):
   48,614 bus cycles per frame in the bench with a plain ROM, **40,927 through the SDRAM (-16%)**. Visible as a software palette fade at frame 250 lagging MAME
   (453 palette entries differ, everything else identical; frames 100, 150, 390, 420 match because the screens are static). `metro_romif` now holds a 512-word
   direct-mapped cache with next-word prefetch (tags cleared while the machine is in reset): **48,614 bus cycles per frame again, mean ROM wait 2 clocks,
   periods after ROM cycles at 32 clocks except about 4% (cache misses = jumps, 1 wait state).** Board and real ROM have no wait states, so this is the
   faithful behaviour.

**Bench additions.** `tb_metro_sys_top.sv` prints, at the end of a run, the ROM wait histogram, the bus-cycle (AS-low) histogram, the AS-fall period histogram
per kind of cycle and (per vblank, lines starting `FS vblank`) the bus cycles per frame; `tb_metro_sys.cpp` calls `final()` for that. The SDRAM-path run
(`SDR=1`) matches MAME at frame 100 with the full init wait (and with sliced memories) and, before the ROM cache, at 100/150/390/420.

**Result with everything on the real path (full 100 us SDRAM init, image streamed through loader and SDRAM controller, sliced VRAM/RAM, cached ROM):**
from a cold reset to frame 420 (coin at 300, 1P start at 400) the VDP state is identical to MAME at **100, 150, 250, 390 and 420**: all six memories, the
registers and the image (0 of 71680 pixels through the window at chip line 11); frame 250, the fade that lagged without the ROM cache, now matches too.
No GFX overrun, CPU never halted. Bus cycles per frame equal the plain-ROM bench (48,614). In the 420-frame run 99.99% of the bus cycles last at most
28 clocks with AS low; the rest are the few jumps that miss the ROM cache and the occasional SDRAM refresh/GFX-burst collision (longest waits about 76 clocks).

**Quartus 17.0.2 Lite, Cyclone V 5CSEBA6U23I7, first full compile (sliced memories, before the ROM cache):** fit succeeds; 507 / 553 M10K (92%), 14,134 / 41,910 ALMs
(34%), 19,677 registers, 43 DSP blocks, 3 PLLs; timing met in every domain: the 96 MHz machine clock setup slack +0.729 ns, hold +0.241 ns, TNS 0 (the framework's HDMI clock
is the tightest at +0.039 ns); no critical warnings; `Metro.rbf` generated (reports in `work/q/first/`).

**Second compile, with the ROM cache (the one to test): 509 / 553 M10K (92%), 14,155 ALMs (34%), 19,793 registers; machine clock (96 MHz) setup slack +0.852 ns,
hold +0.254 ns, no negative slack anywhere, no critical warnings; `mister/releases/metro_20261007.rbf` (3,816,244 bytes; reports in `work/q/cached/`).** Not yet
run on hardware.

## Sound CPU: uPD78C10 (Phase 7, 2026-10-07)

**Oracle.** MAME 0.289's own uPD7810 code (BSD-3-Clause, fetched from the `mame0289` tag into `ref/mame/src/devices/cpu/upd7810/`) is compiled standalone:
`sim/upd78c10/gen_model.py` copies the instruction handlers, the opcode tables and the macros unchanged and cuts the core of `upd7810.cpp` (ports,
interrupts, timers, serial, the run loop) out function by function; `model.cpp` is the Metro sound-CPU environment of `metro.cpp` (ROM banking by port C,
2 KB RAM, port A latch, port B strobes to the YM2413 / OKI, the RXD shift latch for the command). It runs 40 s of sound-CPU time in under a second and
prints one line per instruction (T, PC, opcode, A V EA BC DE HL SP PSW IFF IRR) plus the board events. The model itself was checked against MAME's
debugger trace of the real game: the PC sequences are identical (MAME's `trace` suppresses an instruction whose PC is already twice in the last 64 --
`work/atrace/cmp_pc.py` applies the same rule), 20,082 compared instructions including timer interrupts. MAME's trace `tracelog` action printed nothing
in 0.289, hence no register trace from MAME itself.

**The Dharma sound program** (128 KB, 64 KB reachable with port C bits 5:4): 80 mnemonics / 221 operand forms in 15 million executed instructions of a
40 s play session (`tools/lua/ainput.lua`: coin, start, random play; 148 sound commands); peripherals used: timer 0 chained with timer 1 (TMM = 0x63, INTT1 the
only unmasked timer interrupt), the serial receiver in synchronous mode with the internal clock (SMH = 0x2A, SML = 0x0C) for the command byte, ports A/B/C
(PC1 = RXD), the A/D converter running idle; the event timer, TO/CO outputs and the serial transmitter are unused.

**RTL.** `rtl/upd78c10.sv`: the instruction handlers are **generated from MAME's source** by `sim/upd78c10/gen_rtl.py` (975 of 983 handlers; the 7 `PRE_xx`
prefix dispatchers are the engine's fetch/decode and `STOP` is not used): C++ bodies are parsed (a small recursive-descent parser for the subset MAME
uses) and emitted as steps of blocking assignments with C's 32-bit expression semantics, split at every memory access (`RDOPARG`/`RM`/`WM`), with the
overlay opcodes (`MVI A`, `MVI L`, `LXI H`: NOP if the previous instruction set L0/L1) as a conditional first step. The shell is hand-transcribed from
`upd7810.cpp`: fetch/decode with the skip flag, `take_irq` priority chain, timers 0/1, the synchronous serial receiver, the A/D scan, RP/WP port logic
with MAME's callback values. Timing is MAME's: an instruction takes its table's state count (one state = 3 clocks of the 12 MHz crystal) and the peripherals
advance by that count before it executes; the engine steps on a quarter-rate enable and is paced to the state count by a 4 MHz enable (a bus access
that is slower only makes the instruction late). Engineering notes: `before`/`after` are SystemVerilog keywords (task argument names); a part-select of an
expression is illegal (temporaries); Quartus 17 needs `generate` around a module-level `if`; a serial sample has to wait for the board's latch to shift
(two samples within a few engine ticks read the same bit).

**Result (lock-step, `sim/upd78c10/run_lockstep.sh`): the RTL equals MAME's code instruction for instruction** -- state before every instruction (T, PC,
opcode, A, V, EA, BC, DE, HL, SP, PSW, IFF, IRR) and every board event (YM2413 register/data writes, OKI writes/reads, busy clear, command) -- over the
whole recorded session: **160,000,000 states (40 s), 15,274,465 instructions, 0 differences**, with the real commands (serial receive, NMI, timer interrupts,
music engine); the run takes about 11 minutes with the Verilator bench (`tb_upd78c10_top.sv`, same board environment as `model.cpp`).

## Sound board integration (Phase 8, 2026-10-07)

**Files.** `rtl/metro_sound.sv` (uPD78C10 + 2 KB RAM + the glue of `metro_upd7810_state`: command latch with NMI, the serial command shift on RXD, port A bus,
port B strobes to the YM2413 (CS/WR held 40 clocks so that IKAOPLL's enable-sampled interface sees it) and the OKI, busy flag back to IN0 bit 7, port C ROM bank),
IKAOPLL (YM2413) and jt6295 (OKI M6295 at 1.2 MHz, pin 7 high) vendored in `modules/`, `rtl/metro_mrom_arb.sv` (two requesters, the 68000's `metro_romif` and the
sound CPU, share the SDRAM controller's main-ROM client; its word address is 19 bits now because the sound program sits at image 0x90000), the OKI reads through
the controller's OKI client. `Metro.sv`: the stand-in is gone, `AUDIO_L/R` = the board's mono sound, OSD `Volume` (+12 dB default / +6 dB / MAME level / +18 dB).

**Sound bench** (`sim/run_sound.sh`, `tb_metro_sound_top.sv`, `tb_metro_sound.cpp`): the MRA image goes through loader + SDRAM controller + SDRAM model, the real
session's sound commands are replayed, the board's mono output is written as a WAV (`<out>.wav`; `<out>.wav.stems.wav` = YM2413 and OKI unmixed). Three bench
bugs cost time and are NOT RTL bugs: (1) the download must honour `dl_busy` (dropped words made the CPU run garbage); (2) the commands of a session must be
replayed with **exact simulated times** (`tools/lua/ainput.lua` logs them; the 68000 writes bursts of commands microseconds apart and a frame-granular replay merges
them into one NMI -- with exact times the model takes its NMIs at the same instruction indices as MAME's debugger trace, 375,189 / 384,541 / 1,008,629 ..., and the
code after each is identical); (3) MAME's `trace` with `noloop` prints every iteration, without it a loop is suppressed after two passes.

**Calibration against MAME's audio** (`tools/audio_fit.py`, 14 s of the Dharma session, MAME recorded with `-wavwrite`): the two chips' waveforms are not
sample-correlated with MAME's (different implementations), so the gains are fitted on per-half-second energy, E_mame = a^2 E_ym + b^2 E_oki: **a = 6.35**
(YM2413 accumulator), **b = 1.59** (OKI 14-bit output); with them the board's level follows MAME's in every window to within a few percent (170 / 169, 205 / 205,
185 / 184, 1268 / 1267 ... RMS) and the sound starts and stops where MAME's does (2.5 s, silence at 6.5 s, ...). MAME's level is quiet (RMS 200-1200 of 32767), so the
OSD default is +12 dB; Hyper Duel's author found MAME's OKI route about 3x too quiet against the real board, so the balance is the thing to judge by ear.

**Check of the final RTL against MAME (same 14 s session, exact command times, `tools/audio_cmp.py`):** overall RMS 400.7 (board) against 400.0 (MAME); every
half-second window within about +-10% (most within +-3%: 171/176, 205/206, 186/185, 1250/1253, 938/942, 597/597 ...); the sound starts, stops and bursts where MAME's does.
Not covered: a full-system run (68000 + VDP + sound together) -- the 68000's command write and the busy flag go through the paths of `metro_main` that the
earlier system bench exercised with the stand-in; and hearing it.

**Timing (Quartus 17.0.2).** (1) `Metro.sdc` had never been read: `files.qip` lacked `SDC_FILE Metro.sdc`, so the SDRAM clock constraint and every multicycle path were
missing from all earlier "timing met" results; fixed. (2) The first sound build failed at -24.8 ns inside the CPU: the C++ `EA / A` and `EA % A` of DIV A/B/C is a combinational
16 / 8 divider; the generator now emits a restoring division of one bit per engine step (`DivGen` in `gen_rtl.py`; lock-step identical over 6 million instructions with
thousands of DIVs). (3) With the SDC applied the machine clock misses by 0.785 ns in the Hyper Duel renderer (`metro_render`: layer mux -> two adders -> compare -> the
`pf_data` enable); higher fitter effort in `Metro.qsf` (`PHYSICAL_SYNTHESIS_EFFORT EXTRA`, router `MAXIMUM`, placement x2) closes it.

**Final build with sound (`mister/releases/metro_20261007_snd.rbf`, 4,175,880 bytes; reports in `work/q/snd2/`):** 24,758 / 41,910 ALMs (59%), 517 / 553 M10K (93%), 22,585 registers;
with `Metro.sdc` applied for the first time every clock domain meets timing: the 96 MHz machine clock setup +0.206 ns, hold +0.251 ns, the HDMI clock +0.676 ns,
no negative slack, no critical warnings. (The earlier video-only `metro_20261007.rbf` was built without the SDC; it ran on hardware.)

## Timing at 96 MHz: the build of 2026-10-07 (`releases/metro_20261007b.rbf`)

Final numbers (`work/q/flip5/`, summaries next to the RBF): 24,932 / 41,910 ALMs (59 %), 517 / 553 M10K (93 %), 22,517 registers, `Metro.sdc` read; **setup slack +0.211 ns on
the 96 MHz machine clock, hold +0.250 ns, +0.544 ns on the HDMI clock, no negative slack on any clock, no critical warnings.**
**The fit is sensitive.** Four builds in a row, each with a small unrelated change, failed by -0.48, -0.70, -0.48 and -0.23 ns on a different path each time, because the
renderer inherited from Hyper Duel (tuned there for 80 MHz) has several one-clock cones that sit at about 10 ns and the placement moves them by 0.5 ns either way. What
closed it for good (not luck): (1) the sprite ROM row address was split into a multiply stage (`ST_S_GROW`) and the base add; (2) the tilemap pass keeps the source column of the
current and the next pixel and the source row in REGISTERS (`srcc_q`, `srcc_nx_q`, `srcl_q`, loaded in the new `ST_L_LAY0` at each pass start), so the layer mux and two adders
no longer sit in front of the tile-boundary compare and the row-cache lookup (about 4 ns off both worst paths); (3) the sprite ROM bounds check (26-bit add and compare) is registered
in the first of two `ST_S_COVER2` passes; (4) the framework's HQ2x blender (registers on the pixel-rate enable, 4 clocks apart) got a 2-clock multicycle in `Metro.sdc`.
Cost: about one clock per sprite that passes the prescan, 3 per line for the layer passes; the worst real Dharma line is 5295 of 6272 clocks (it was 5021). Each of these was checked
against the 172 frozen-state scenes (all identical to MAME) and, for the last RTL, whole-machine runs of Dharma and Toride II. If a later change breaks timing again, run
`quartus_sta` with `report_timing -setup -npaths 40` and look at the endpoints before changing anything: the paths move.

## Hardware results and the controls bug (2026-10-07)

Video-only build: picture perfect, OSD CRTC/MAME window works. Sound build: music and effects good, the Volume option works. **Controls did not work.**
Cause (found by reading the whole input path; the benches drive `in0`/`in1` directly and never see MiSTer's joystick word): the MRAs declared
`<buttons names="Button 1,Start,Coin">`. MiSTer builds the joystick word from the MRA's button list (bit 4 = first name), so Start arrived on bit 5 and Coin on
bit 6, while `Metro.sv` reads button 2 = bit 5, Start = bit 6, Coin = bit 7: the Coin button acted as Start (no credit, no game), Start as button 2.
Fixed in the MRAs and in `tools/make_mra.py` (regeneration is byte-identical): `names="Button 1,Button 2,Start,Coin" default="A,B,Start,Select"`, the
same layout as `Metro.sv`'s `J1,...` line and as taitol-mister's MRAs. No bitstream change. A button map saved for the old layout lives in
`/media/fat/config/inputs/` (`Metro_input_*.map`); delete it or redo "Define Metro buttons" in the OSD. The keyboard (1/2 start, 5/6 coin, 9 service) never
depended on the MRA.
**Confirmed on hardware after the MRA fix:** coin, start and joystick work; the OSD now offers button 2 as well. Button 2 is IN1 bit 5, which `metro.cpp` leaves unbound for
`dharma` (comment: "BUTTON2 and BUTTON3 in test mode only"), so it should do nothing in normal play. Dharma is complete on hardware: picture, sound, controls.
Lesson: anything that crosses the framework boundary (MRA, hps_io words) needs a check against the framework's convention, not only the RTL benches.

## Screen flip and the column-0 fix (2026-10-07)

**Flip (known issue A), implemented from the verified recipe.** Frame-latched `flip_q` (screen control bit 0, taken at the start of the last line like the CRTC window)
in `metro_vdp.sv`; while it is set: (1) the kick FIFO carries the display row S and the line is reversed at the pop (`rnd_line = 223 - S`; the line-buffer banks and the
scan-out tags stay keyed by the display row, `rnd_row`), (2) the layer scroll snapshots get +72 (X) / +39 (Y), (3) the window is forced to MAME's 0..223 (a CRTC window
would show chip lines 224/225 as lines -1/-2 of the mirror; no real-board measurement exists to say what the hardware shows). `metro_render.sv`: input `i_flip`;
sprite screen offsets 318 - x / 222 - y; one extra cycle per sprite (flip only) subtracts the rounding correction `round(w*zoom) - floor(w*zoom)` (bit 15 of the 16.16
product) from the sprite's x and y; the prescan's lower bound gets one line of slack for it; the X mirror is applied at the line-buffer write (`o_lb_x = 319 - x`).
Results: **all 49 flipped randomised scenes pixel-identical to MAME** (they differed on about 71,000 pixels each before); **6 of 6 real Dharma frames recorded with the
Flip Screen DIP on** (`vstate.lua` `VS_FLIPDIP=1`, frames 100-1400) identical; worst line render 5036 cycles against 5021 unflipped (frame 700).

**Flip in the whole machine** (`sim/run_sys.sh`, `DSW0=FFBF` = Flip Screen DIP on, the real SDRAM path, from reset, coin at 300 and start at 400; MAME recorded the same
way with `VS_FLIPDIP=1`): the game flips itself, and at frames 100, 250 and 420 all VDP memories and registers equal MAME's; the image is identical at frame 100 and differs
by 1456 pixels at 250 and 26 at 420, in a few rows only. **Not the flip logic:** the same run without the DIP is identical to MAME at 100, 250 and 420 (images included);
the sprite copy the renderer used equals MAME's sprite RAM; the frozen-state bench renders these very frames pixel-identically; and the differing pixels have colours that
are in NO entry of the end-of-frame palette (frame 250: e.g. RTL (181,132,0) where the final palette has (189,132,0)), so the palette held other values while those rows were
scanned out. The game writes palette entries during the visible part of the frame (a fade); MAME draws the whole frame with the final palette, the RTL scans out in time as the chip
does. Flipped, the affected objects sit in the rows scanned before that write; unflipped they are below it. (Explained by elimination, the palette writes were not traced.)

**Flip on hardware (user test of 20261007b, Toride II with the Flip Screen DIP): "garbage pattern at the left and top of the screen".** The core was right and MAME was
the problem. MAME's flip mirrors the whole 392 x 263 raster (`bitmap.width()` in `draw_tilemap`) and then crops the visible 320 x 224, so the layers show the 72 columns and
39 rows of off-screen margin that the game never fills (blank tiles on Dharma, repeating tile 0 patterns on Toride II); `imagetek_i4100.cpp`'s header lists "Unemulated/Unverified
scrolling in flip screen". MAME's own snapshot of flipped Toride II shows the same pattern (`work/states_t2flip/t2.250.png`), and the core reproduces it with 0 differing pixels on
6 of 6 real flipped Toride II frames (which is how the earlier "verified" claim went wrong: Dharma only, and I had counted pixels without looking at the picture; Dharma's flipped
frames have the same black bands, `docs/flip_dharma_as_mame_draws_it.png`). The one game whose flip someone aligned against a real board, Varia Metal
(`set_tmap_flip_xoffsets(88,88,88)`, `set_tmap_flip_yoffsets(39,39,39)`, "aligned properly"), uses exactly raster minus visible size (392 - 304, 263 - 224), which cancels the
margin: the layers then mirror about the visible area, as the sprites already do. **Fix (source, build after 20261007b):** `FLIP_MAME_SHIFT = 0` in `metro_vdp.sv` drops the
+72 / +39 layer shift, i.e. the same as MAME with flip offsets 72 / 39 (`metro_ref.py --flipoffs 72,39`). Verified against the reference with those offsets: **70 of 70 frozen-state
scenes identical** (58 randomised flipped scenes, 6 real flipped Dharma frames, 6 real flipped Toride II frames; expected images in `work/flipfix/`, made by `work/flipfix/mk.py`).
Pictures: `work/flipfix/t2.250.png`, `t2.1000.png`, `dh.1000.png` (clean 180-degree turn, sprites on their backgrounds). Not an oracle result (MAME with offsets 72 / 39 was not run:
those offsets are set in the driver source, so it would need a MAME build); the evidence for it is Varia Metal's values and the picture.

**FlipX column 0 (known issue B): found and fixed.** Not the flip path itself. In `ST_S_OVL` the last emitted pair word is written one clock after the emit (`spr_we`),
and the state machine left for `ST_RESOLVE` at once: resolve's first read of word 0 is registered at the same edge as that write and returns the OLD word, so
pixel 0 lost the sprite (pixel 1 reads a cycle later and is right). Only sprites whose last word is word 0 can show it: x-flipped sprites reaching column 0 (the
walk runs right to left) and any sprite clipped to columns 0-1. Fix: `emit_done && s_fill_done && f_parked && !spr_we`. Randomised scenes without flip, 100:
**91 identical before, 100 identical after**; the 9 real Dharma frames still identical. Upstream (Hyper Duel) has the same bug: `rtl/UPSTREAM.md` has the write-up.

## Toride II (`toride2g`, 2026-10-07): the second board of family B

Same board family as Dharma (MTR5260-A), five sets; the differences are in `docs/hardware.md` section 10: 512 KB program ROM, the I/O ports at 0x800000 and the video chip
at 0xC00000 (swapped against Dharma), the sound command at 0xC788A9, and, in build 20261007b only, a wrong OKI sample-rate pin (low, /165; MAME's toride2g is PIN7_HIGH, /132 like Dharma: I had read Sky Alert's line, which sits just above it in `metro.cpp`; fixed the same day, the OKI samples ran 20 % slow and low in that build). The machine config is otherwise `dharma`'s.
Done: `metro_main` takes the board from the image's config byte 0 (`i_board`, board 2), `metro_romif` addresses 512 KB (18-bit word address, 10-bit tags),
`metro_sound` has `i_oki_ss` (`jt6295` `ss` = pin 7), `tools/metro_rom.py` BOARDS, nine MRAs (`tools/make_mra.py`; all nine build the simulated image, `tools/mra_verify.py`).
Verification against MAME 0.289 (recorded with `vstate.lua`, `VS_BASE=c00000`, coin at 300, start at 400, random play from 560):
* ROM regions: the image builder's four regions equal MAME's in-memory regions byte for byte (`regions.lua`, `metro_rom.py check`).
* Frozen-state VDP bench, real frames 100, 250, 420, 700, 1000, 1400, 1800, 2200: **8 of 8 pixel-identical** (worst line render 4463 cycles).
* Whole machine from reset (`run_sys.sh` with the Toride II image, SDRAM path, 68000 running the real program through the new map): at frames 100, 250 and 420 **all VDP memories
  and registers equal MAME's**; the image is identical at 100 and 250 and differs by 3 pixels at 420 (one row, one shade off; the sprite copy equals MAME's sprite RAM and the
  frozen bench renders the frame identically, so it is a palette change during the scan, as for the flip run above).
* Sound CPU on Toride II's own program (`ainput.lua` with `AI_SNDADDR=c788a8` records the 330 commands of a 40 s session with exact times; `run_lockstep.sh` against
  the standalone compile of MAME's uPD7810 code): **identical over 3,819,298 instructions** (40 M states, commands replayed at their times, 0 illegal opcodes).
Not covered: the audio itself on this board (no gain fit against MAME's audio was made for it), hardware.

## Family B2 (YM2151): Gun Master, Pururun x2, Daitoride, Puzzli x2 (2026-10-07; in the build after 20261007b, not on hardware)

The same board family with a YM2151 instead of the YM2413 (`docs/hardware.md` section 11): four memory maps (`metro_main`: RAM / VDP / I/O quadrants chosen by the board id),
a 16 MHz 68000 for Daitoride and Puzzli (`metro_cen` `fast`: phases 3 clocks apart), the tilemap X offset 2 of those two boards (`i_tmap_dx`), Puzzli's per-scanline interrupt model
(`i_scan_irq`), Button 3 (Gun Master), `daitorid_portb_w` and the YM2151 (`jt51`, vendored, GPL-3.0) with its IRQ on the sound CPU's INTF2 (`upd78c10.sv` `intf2`: a rising edge
sets IRR 0x10, port C bit 3 reads the inverted line; all 8 ROM banks). Six sets; the MRAs are in `mra/` (Gun Master, Pururun (+ set 2), Daitoride, Puzzli (+ rev A)).

Verified against MAME 0.289 (`vstate.lua`, coin 300, start 400, play from 560; frames 100-2200):
* ROM regions: the image builder equals MAME's regions byte for byte for all six sets (`metro_rom.py check`).
* Reference renderer: 32 of 32 real frames identical for Gun Master, Pururun, Daitoride and Puzzli rev B (**Daitoride and Puzzli need the tilemap X offset 2**: without it every frame
  differs, as MAME's config says); Puzzli rev A 7 of 8 (frame 2200: 681 pixels, near the water line).
* Video chip RTL bench (after the renderer change below): **39 of 40 identical**; the one is that same Puzzli rev A frame 2200 with the same 681 pixels as the reference, i.e. MAME's
  per-scanline drawing (`VIDEO_UPDATE_SCANLINE`, the water effect, which the snapshot method cannot reproduce), not a difference between RTL and model.
* Whole machine from reset (`run_sys.sh`, SDRAM path, the real 68000 program): **frame 100: all five tested games (Pururun, Daitoride, Gun Master, Puzzli, + Dharma, Toride II) identical in every video
  memory, every register and the image.** Frame 250: Daitoride, Puzzli, Dharma and Toride II identical (image included); Gun Master's memories identical and 735 image pixels differ in 13 rows
  (599 of them have colours that are in NO entry of the final palette: the same mid-scan palette effect as before); **Pururun's state at its frame 250 equals MAME's frame 252 exactly (0 words differ)**:
  the simulated machine is two frames ahead in an animated fade, and at frame 420 Pururun / Gun Master show scroll registers one or two steps off. The sound CPU in these runs is a stand-in
  (busy for a fixed time after a command), so the phase of animated scenes cannot be expected to match MAME's to the frame; the identical frame-100 and frame-250 static scenes are the evidence.
  At frame 420 Daitoride and Puzzli are *behind* MAME (still in the boot ROM check, which MAME has finished): the 68000 gets 77-94 % of the bus cycles it could at 16 MHz (92 % at 12 MHz) through the
  SDRAM ROM path (the `FS vblank` lines of the logs: 47.6 k of 51.5 k per frame at 12 MHz), so ROM-bound loops run 8-23 % slower than on a real board; game play is not CPU-bound but this is a limit.
* Sound CPU, lock-step against MAME's uPD7810 code (`sim/upd78c10`, `YM2151=1`, events may hold `irq2` lines): **identical over 2,096,591 instructions of Daitoride's program** with 1,860 INTF2 pulses
  at random times, the session's commands, bank switching and every YM / OKI / busy event, and **over 2,438,816 instructions of Pururun's program** with timer-rate INTF2 pulses (this found that the model's
  header numbers INTF2 as 2, MAME's own `#define` as 1: my first run raised INTF1 in the model).
* Audio (`sim/run_sound.sh`: CPU + jt51 + OKI through the real memory path; `tools/audio_fit.py` against MAME's `-wavwrite` of the same session): **the bench must be closed-loop.** Replayed open-loop at
  MAME's command times the board was silent: the three bytes of a command come 0.3 ms apart because the 68000 waits for the busy flag, and a sound CPU a little slower than MAME's in some phase (jt51 vs
  ymfm busy / timer timing; the interrupt routine runs 1.1 ms with interrupts off) misses the next byte and the command parser (state in RAM 0x83BB) desynchronises for ever. Real hardware is closed-loop
  (the game waits for busy), so this is a bench artefact; `tb_metro_sound.cpp` now writes a command only when busy is low. Then Pururun's per-half-second level follows MAME's within about 5 % in most windows
  (model 3578 / MAME 3523, 2801 / 2903, 2947 / 2867, 2432 / 2372, 2597 / 2610, 884 / 921, 3046 / 3145 RMS), Gun Master's start where MAME's do. Puzzli's two audible seconds are OKI-only in both (a sound effect: no YM2151): 6.36 x the board's OKI level gives 1577 and 3262 RMS against MAME's 1591 and 3232 (within 1 %). Fitted gains: **YM2151 a = 1.52**
  (jt51 mono = (xleft + xright) / 2; Pururun's YM-only windows 1.516, all windows 1.54), **OKI b = 6.36** = 4 x Dharma's 1.59 (MAME's routes: OKI 0.40 here, 0.10 on Dharma; Gun Master's OKI-only windows give 6.2, Puzzli's 6.3).
  Not matched: Daitoride's command 0x2f at 7.0 s is a short YM effect (RMS 386, peak 3100) in the board simulation and silence in MAME's recording (MAME is silent until 13.7 s); unexplained.
  Only the first 9 s of each session were run (the bench needs about 30 minutes per 14 s).

Two findings that cost time and are NOT RTL bugs: (1) the stand-in busy time of the whole-machine bench was 60 us, the real sound CPU takes about 150 us for the usual command (601 states in the lock-step
trace; now 150 us), which did not change the Pururun result; (2) the periodic interrupt was a count of 32 lines (0.3 % slow against MAME's exact 480 Hz); it is now a clock count (`P_TICK_CLKS` = 200000),
which did not change any frame either and keeps Dharma / Toride II identical at 100 / 250 / 420.

**Changes of the same round that are not specific to the family:** the Toride II OKI pin and the screen flip (sections above), the sprite cull test compares registered end positions (`sxe_q` / `sye_q`; the
worst path of the first YM2151 fit, -0.011 ns, was the old comparator chain), the memory-map selects of `metro_main` are registered, jt51 has a multicycle constraint in `Metro.sdc`. The regression of the video
chip after these changes: 70 of 70 flipped scenes (58 randomised + 6 + 6 real) against the reference with flip offsets 72 / 39, **100 of 100** randomised no-flip scenes (`work/fuzz2`), 29 of 29 real frames
(9 Dharma, 8 Toride II, 6 + 6 flipped), and 91 of 92 of the no-flip scenes of `work/fuzz` that had never been run through the RTL: `f.93` loses a sprite pixel at x = 280 on two rows (known issue C,
`rtl/UPSTREAM.md`; reverting the cull change does not fix it).

**Timing and fit of the build `releases/metro_20261007c.rbf` (Quartus 17.0.2, 96 MHz):** the first YM2151 build missed by 0.011 ns (the sprite cull comparator chain, and the 68000 address into the video RAM
= the new map decode); after the two structural changes above the machine clock has **+0.420 ns setup, +0.252 ns hold, every other clock positive (worst +0.189)**. 62 % of the ALMs (25,871), 79 % of the block
memory bits, **95 % of the RAM blocks (524 of 553)**, 54 of 112 DSP blocks. Build time 50 minutes.

## Hardware test of 20261007c and the build after it, 20261007d (2026-10-07 night)

**User report (hardware):** Dharma and Toride II still fine, their flip works. Daitoride: tearing on the moving title, green pattern at the left, much louder than the first two games, flip does not turn the
picture at once. Pururun: much louder, flip not at once, quick flashes at scene changes. Puzzli: plays, horizontal lines crossing the Banpresto screen a few times at the start, glitches in the attract
demo, flashes (less than Pururun), flip works. Gun Master: flashes, flip not at once, some slowdown, the title comes in slowly and jerkily, louder, maybe scratchy. (The flip complaint is "not immediately like
Dharma / Toride II"; no Reset was involved. My first reading, "does not flip at all", sent me to MAME and the simulation, where all three flip with the DIP on from start-up.)

**Sound level (fixed).** MAME's own output (`-wavwrite`, MAME level = x1): peaks Dharma 3.3 k, Daitoride 12.4 k, Gun Master 15.2 k, Puzzli 17.5 k, Pururun 24.6 k; RMS over the seconds where something plays
Dharma 410, Daitoride 1,401, Gun Master 2,450, Puzzli 2,380, Pururun 3,680 (`work/flipb2/wavstat.py`, `wavact.py`). The OSD default was x4 on every board: Dharma x4 = RMS 1,640, peak 13 k; the YM2151 games x4 =
RMS 5.6-14.7 k and peaks of 50-98 k, i.e. clipped at 32,767 (the "scratchy"). `metro_sound.sv`: on YM2151 boards `mix >>> 3` before the OSD steps, so the default is x0.5 of MAME's level (RMS 0.7-1.8 k, about
Dharma's); the OSD list is now `Normal, -6 dB, -12 dB, +6 dB` (Normal = x4 on the YM2413 boards, x0.5 on the YM2151 boards). The sound bench (`tb_metro_sound_top.sv`) uses `i_gain` 3 for the YM2151 boards so
`audio_fit.py` still compares at MAME's level.

**Vblank against the display window (the probable cause of the tearing / flashes / bands; found by looking at WHEN the games write, not what).** Every bench of this project ran with `WINMAME=1`
(`i_win_mame`: the picture is chip lines 0-223 like MAME, `crtc_vfirst` forced to 0), because MAME's snapshots only compare in that mode. The core on hardware runs the default, the game's CRTC window: all seven sets
program CRTC vertical parameter 7 = 11 (`78880 070b`), so the picture is chip lines 11-234, the renderer kicks lines up to 234, and the vblank interrupt was still at line 224 (`P_VBL_LINE`) = 11 lines before the picture
ends. `work/b2/whenwr.lua` (MAME, beam line of every 68000 write to palette / tile RAM / sprite RAM / scroll registers, buckets 0-10 / 11-223 / 224-234 / 235-262): every game writes its 6 scroll registers in
224-234 each frame (the vblank routine), Gun Master 40-112 palette entries there in fade frames (and ~300 in 235-262), Pururun 40-100, Daitoride 50-80, Puzzli ~46; Dharma writes sprite RAM, palette and VRAM in the
visible lines. So in the default window the handler's scroll / palette / sprite writes landed in the bottom 11 rows of the picture while they were drawn: tearing in scrolling scenes and half-faded colours in the
last rows during fades. Dharma and Toride II hardly scroll or fade in the handler, which is why they looked perfect. **Change (`metro_vdp.sv`):** `vbl_line = P_VBL_LINE + crtc_vfirst_q` (registered): the vblank
interrupt (cause 0, and 4 in Puzzli's model) comes at 224 + vfirst, the sprite copy (`spr_copy_line`) at the start of line vfirst - 1 of the next frame instead of the last line (the handler keeps the same 38 lines);
Puzzli's per-line interrupts keep MAME's lines 0-223. `i_win_mame` / flip: vfirst 0, nothing changes (the whole-machine runs in that mode are bit-identical to before). **Whether the real chip raises its vblank at
the end of its programmed window is an assumption** (the Hyper Duel author's measurement of that game's window start, ACCURACY.md section 3.3, does not say where its interrupt is). Checks: frozen-state video bench
after the change, Dharma 6 of 6, Toride II 5 of 5, Gun Master / Pururun / Daitoride / Puzzli 32 of 32 frames identical to MAME; whole machine in the game's CRTC window (`work/flipb2/run_crtc.sh`): Dharma
at frames 100, 250 and 420 and Toride II at 100 and 250 have rows 0-212 of the picture identical to rows 11-223 of the MAME-window run (Toride II frame 420: 305 px, an animated scene).

**Gun Master in the game's CRTC window, before and after** (`work/flipb2/run_crtc.sh`, `before_after.py`, frames 395-470, title fade and the flash before the enemy-select screen): rows 0-212 are identical in 75 of 76 frames (the exception,
frame 467, is the black / white flash frame: the 0.7 ms later vblank moves that one frame across the boundary), and the bottom 11
rows (chip lines 224-234) differ in every second frame of the fade (frames 395-440) by 58-1,333 pixels, in none after it: the fade steps the game writes every second frame landed in those rows while they were drawn (the before build shows the last
rows one fade step off the rest of the picture in half of the frames, a flicker band), and are gone after the change. It is subtle here (one step of a slow fade, `work/flipb2/gm404_before_after.png`) and the
scroll writes act the same way, so this is a real defect of the old default but it explains the reported tearing only in part; the rest of the flashes are the games' own fades (below).

**Flashes at scene changes are largely the games.** MAME's frame-by-frame images (`work/mamef/`, `flipb2/scan_frames.py`) show Gun Master fading in from white (frame 303: mean luminance 255), black then white at
frames 467-468 (enemy select), two-frame fade steps; Pururun: black frames 302-304 between title and demo and a 90-frame fade-in from 192; Puzzli: the Banpresto screen is a fade through white in which the palette is
rewritten **inside the visible lines** (1,188 writes in lines 11-223 per frame at frame 420). The simulation, run frame by frame from reset through the SDRAM path (`run_allframes.sh`; MAME window), matches MAME's frames
within +-6 frames of animation phase for Pururun frames 60-357 and Gun Master 60-372 (every frame has a MAME frame within 280 pixels except the white-flash frame 302), so what MAME shows the core shows. A palette
rewritten in the middle of the picture shows as a band at every step of a fade on a live display; MAME's snapshot hides it.

**Flip.** All six games write the flip bit (788ac bit 0 = 0x0701) from start-up in MAME with the Flip Screen DIP on and keep it through play (frames 500-3000, random play from 560); the core does the same in simulation
(Pururun, Daitoride, Gun Master: `work/flipb2/sys_*`, 788ac = 0701, the picture turned). When the DIP is switched at run time no game rewrites the register after its start-up phase in MAME (the DSW0 read
returns the new value to the 68000: `linewr.lua` `LW_DSWADDR`; no screen-control write follows in any of the six sets, Dharma and Toride II included), so how Dharma / Toride II turn the picture at once on hardware
is not explained by the traces (Dharma's code rewrites the register from a RAM copy of the DIP, `$40e042`, in its main loop and vblank routine at 0x664 / 0x696, probably when its state machine passes through it).
**Change (`Metro.sv`):** `flip_force = board <= 6 && !sw[0][6]` (20261007d also had an OSD `Flip screen: Forced`, status[10], removed again at the user's request after the test): the video chip flips whenever
the Flip Screen DIP (bit 6 of DSW0 on all six boards) is On, regardless of the game (`metro_vdp.sv` `i_flip_force`, ORed into the frame latch of the flip and of the window). Same result as the game's own flip,
immediately. **Tested on hardware: works.**

**Not reproduced.** The Gun Master slowdown: in the SDRAM-fed whole-machine run 99.9 % of the 68000's ROM reads are answered within 8 clocks at 12 MHz (bus cycles per frame 47.6 k of 51.5 k), the title scene
follows MAME frame for frame. The Daitoride "green pattern at the left" during the title: MAME's own frames 520-600 show the METRO logo being revealed letter by letter in green-yellow from the left, and
the checkerboard background fades in from green at frame 840; the vblank change may be all there is to it. Open for the next hardware test.

**Process lessons.** (1) A bench that always runs in one display mode cannot see a bug of the other: the hardware default (the game's CRTC window) was never run in the whole-machine bench; run the default too.
(2) Snapshot oracles (MAME draws at the end of the frame) hide everything that depends on WHEN the CPU writes; trace write times against the beam line. (3) Editing a script that a running bash is executing
(`sim/run_sys.sh`) makes it fail at the end (`error reading input file`); the results are fine, but do not edit running scripts. (4) My first run-time DIP test in MAME set the field's `user_value`
mid-run and saw no screen-control write in any game, Dharma included, which contradicted the hardware report; a read override on DSW0 (`install_read_tap`) gave the same, so the test method is probably not the
reason, and the hardware behaviour of Dharma / Toride II remains unexplained by MAME's traces.

**Build `releases/metro_20261007d.rbf` (Quartus 17.0.2, 96 MHz, 36 min):** timing met on the first try, **machine clock +0.478 ns setup, +0.242 ns hold, every other clock positive** (lowest +0.491 on the
HDMI PLL); 26,148 ALMs (62 %), 23,935 registers, 4.48 Mbit block memory (79 %), 524 / 553 RAM blocks (95 %), 54 / 112 DSP. Package `dist/Metro_MiSTer_20261007d.zip` (15 MRAs + the core), notes
`dist/RELEASE_NOTES_20261007d.md`. 20261007c (the hardware-tested one) is in `releases/test/`. Built from: the YM2151-board output level, OSD `Flip screen` (`status[10]`) and the DIP-driven flip,
`vbl_line` / `spr_copy_line`. Not on hardware.

### Hardware test of 20261007d (user report + five phone videos, 2026-10-07 late)

Volume "quite ok now"; Flip Screen works from the DIP and from the OSD option (the user wants the OSD option removed: done, only the DIP flips); tearing and flashes "still there", videos attached
(`IMG_7927.MOV` Daitoride title, `IMG_7928` Daitoride attract, `IMG_7929` Gun Master attract, `IMG_7930` Puzzli, `IMG_7931` Pururun; frames extracted with ffmpeg into `work/videos/`). The user's hint:
**Pururun's Banpresto logo does not show the scrolling lines that Puzzli's does.**

What the videos show (30 fps camera, 58 Hz game; compared with MAME's frame-by-frame images, `work/mamef/`):
* **Puzzli Banpresto fade (7930):** a horizontal brightness boundary in the fade-in of the logo, from frame to frame at another height. MAME's own write trace explains the hint: Puzzli's fade routine rewrites
  the palette in the visible lines of every frame (1,188 writes between lines 11 and 223 at frame 420, `work/b2/whenwr.lua`), Pururun's fade writes in the vblank (`pal=27/115/62/239`: mostly lines 224-262). A
  display that reads the palette live shows the boundary where the beam was when the write sweep passed; replaying MAME's palette-write times over MAME's frames (`work/flipb2/live_replay.py`,
  `palwr.lua`) reproduces faint moving lines for Puzzli. MAME never shows them: it colours a frame with the palette as it is at the END of the frame.
* **Scene changes through white (7928 Daitoride tutorial -> demo, 7929 Gun Master, 7931 Pururun):** the games fade to white, hold, load the next scene and fade in. MAME's images show the same thing,
  including a single frame in which the next scene appears in its true colours between two white frames (Daitoride frame 4081: brown demo screen, score bar, one frame; `work/flipb2/daitorid_white2_sheet.png`);
  on the hardware that frame is partly white (bands at the top and bottom of the picture), the same effect of palette words rewritten during the frame.
* **Daitoride cloud scroll (7927):** one frame of 292 has the top 34 and bottom 63 picture rows filled with wrong 16 x 16 tiles (pieces of the clouds and of font glyphs): stale tile-map rows displayed while the
  game rewrites them. It is rare (once in the clip, i.e. in about 1 of 20 row updates) and not reproduced in simulation yet (the scene is at frame ~2350, 2 hours of simulation).
  MAME's write trace shows the game writes ONE tile row of 41 words every 15 frames, at varying beam lines (bucket A for the first scene, bucket B = visible lines in this one: the row is outside the
  window at that moment, so a live display shows nothing). Not explained.
* The thin green dotted column at the left edge of the Daitoride logo scene is in MAME's own picture (frame 2500: a green dotted column at both the left and the right edge); it is the tile
  layer's wrap-around column, not a core defect. The sky looks lighter in the video than in MAME only because of the camera exposure (blacks of the pillar-box bars are lifted the same way).

**Second Daitoride video, `IMG_7933.MOV` (60 fps, the title rising from the bottom):** every other frame has a **single scanline** replaced over the right 70 % of the picture by the bright yellow
of the logo that lies behind the rocks (a few dark rock pixels stay, so it is the row of the front layer that is missing, not a stale-line black); the row jumps between chip lines ~141 and ~168
from frame to frame. MAME shows nothing like it (no thin bright rows in its frames 2860-2900) and in this scene nothing in VRAM, palette or sprite RAM changes from frame to frame (only layer 2's Y scroll,
written at line 224; the 41 words of tile row and the two blitter runs per frame, at lines ~260 and ~6, rewrite identical data). Findings so far, none of them proven to be the cause:
* The heaviest lines of this scene are exactly chip lines 161-169 (80 separate gfx requests each): 4.6-4.8 thousand clocks with an instant ROM, **5.4 / 6.1 / 6.7 / 8.0 thousand with 8 / 16 / 24 / 40 clocks
  of extra latency per request** (bench `+GFXLAT`, hardware line time `PIXDIV=16 HTOT=392`; the line is 6272 clocks). The old line buffer (3 lines of lag, 4 banks) stays clean up to a latency of ~40 and shows black
  stale lines (the background pen over the whole line, in a band of ~40 lines) from ~56; eight banks with seven lines of lag (patch `work/metro_vdp_lag7.diff`, **not in the build**, +4 RAM blocks) stay clean
  up to ~56 and fail at 72. A late render makes a whole BLACK line here, not a partial yellow one, so this is probably not the glitch, but the margin is thin.
* What would match a partial row of the front layer being transparent: a gfx read whose data did not arrive or arrived wrong for a stretch of one row (SDRAM capture timing / refresh interplay on the
  real module). Not testable in simulation; asked the user to try `SDRAM read capture: Late` and to say whether other games show it.

**User: "this kind of glitch never shows in Puzzli, Gun Master or Pururun" (only Daitoride).** Two more facts from MAME's timeline (`work/b2/lastwr.lua`, beam line of the 68000's writes per frame):
* In the cloud scene the game's per-frame work (the 41-word tile row and ~320-360 sprite words) ends at beam line 2-4 in most frames (just before the window's first line 11), but **in every 15th frame
  it starts about 35 lines late** (frames 2362, 2377, ...: tile row at line 38-39, sprites 77..122), i.e. in MAME's OWN timeline those writes land in visible lines. A chip that reads its
  tile RAM live would show the partly updated row above line ~40 in those frames (a top band of wrong tiles: the clip's garbage band is 34 rows tall); MAME's end-of-frame snapshot hides it. Whether the real chip
  buffers, or the real board's timeline differs, I cannot say. (Not reproduced in simulation yet: the scene is 2 hours in; `daitorid_d_cloud` is still running.)
* The rocks scene has two idempotent blitter runs per frame (src 0xE2D10 / 0xE2F80, ~620 bytes each, lines ~260 and ~6) and 6 scroll writes at line 224; nothing else changes. The core's blitter takes
  about 3.5 lines per run (a ROM byte per ~35 clocks), MAME's is instant with the done interrupt 500 us later (8 lines).
* **Palette latch confirmed in the whole machine:** Puzzli run from reset through the SDRAM path in the hardware's window mode, frames 440-560 (`work/frames_crtc/puzzli_e_live`, `puzzli_e_lat`, `flipb2/band_metric.py`):
  with the live palette 25 frames have a brightness step of 5-9 levels in a strip at the left edge, **moving up the picture by about 2 rows a frame (row 73 at frame 440, row 29 at 465)**: the scrolling
  lines of the hardware test; with the per-frame palette latch none of the frames has one.

**Build `releases/metro_20261007e.rbf` (Quartus 17.0.2, 96 MHz, 54 min):** timing met first time, **machine clock +0.551 ns setup, +0.254 ns hold, every clock positive (lowest +0.143 on the HDMI PLL)**; 26,265 ALMs (63 %),
24,735 registers, 4.54 Mbit block memory (80 %), **532 / 553 RAM blocks (96 %)**, 54 DSP. Package `dist/Metro_MiSTer_20261007e.zip` (15 MRAs + the core), notes `dist/RELEASE_NOTES_20261007e.md`; 20261007c / d in
`releases/test/`. Regression of this RTL: frozen-state video bench Dharma 6 of 6, Daitoride 8 of 8 identical to MAME with the palette latch; Puzzli whole machine as above. Not on hardware.

**Decisions after this test:** (1) The vblank-follows-the-window move of 20261007d is **reverted** (`P_VBL_FOLLOWS_WINDOW = 0`): it did not cure the tearing, and MAME's write trace argues against it: the
games do their per-frame tile / sprite work in chip lines 0-10 (bucket A: Dharma's 36 tile words, the cloud scene) = exactly the lines the CRTC window of 11 hides, which only fits an interrupt at line 224; with the
interrupt at 235 that work lands in visible lines 11-21 (and may be what put the garbage bands into the Daitoride clip). The Gun Master check of 20261007d (bottom 11 rows) stays valid as a description of
what the old default did, and the effect it fixed is now handled by (2). (2) **Palette latch** (`metro_vdp.sv` `i_pal_latch`, `u_palette_sh`, OSD `Palette: Per frame / Live`, default per frame): the
scan-out reads a shadow copy of the palette that is refreshed from the live one once a frame (4,098 clocks, at the start of chip line vfirst + 1), so fades and palette-write sweeps change colour at frame
boundaries, like MAME's snapshot, instead of leaving moving bands. A palette word written in the visible lines reaches the picture one frame later. Costs 8 RAM blocks. (3) OSD `Flip screen` removed (the
DIP flips the picture by itself).

### Hardware test of 20261007e (2026-10-08): Puzzli's blinking text, scene-change flash, the rocks of Daitoride

User report (video IMG_7935 of Puzzli, then follow-ups): the per-frame palette fixed the scrolling lines of the Banpresto screen, wanted as a Puzzli-only setting without an OSD entry; the **DEMO PLAY text flickers letter by
letter** instead of blinking as a whole; a scrambled flash between the attract scenes; the `SDRAM read capture: Late` option changed nothing on the Daitoride rocks. Later the user ran MAME themselves: the flash between
scenes is in MAME too (frame 3786 of `puzzli` is exactly that picture), the Daitoride rocks have no line tearing in MAME.

**New tool: the timed-write replay bench** (`sim/run_replay.sh`, `tb_metro_vdp.cpp +REPLAY`, `work/b2/vdpwr.lua` + `mkreplay.py` + `rp_sheet.py` / `linediff.py` / `textcount.py`). `vdpwr.lua` logs every 68000 write to the
video chip with MAME's time (and the frame_done times, i.e. the beam at line 224); `vstate.lua` (same run) dumps the chip's state at one frame_done. The bench loads that state, aligns the raster to line 224, plays the writes at their
times (each MAME frame stretched to exactly one core frame of 263 x 6272 clocks, no drift) with the hardware raster (16 clocks a dot, 392 x 263, `+GFXLAT` extra ROM latency) and writes every picture as a .ppm. Picture n = MAME's
frame (dump frame + n). It is the 68000-less version of the whole-machine run: MAME decides when the game writes, the RTL decides what the chip does with it. Checked first on Daitoride's rocks scene (frames 2860-2899): **0 differing rows
in 40 frames against MAME's own pictures** for ROM latencies 0 to 40 clocks.

**1. DEMO PLAY (Puzzli).** MAME write trace (`work/b2/sprlog.lua`, per-frame area counts `areawr.lua`): in the demo the game writes the text as 8 sprites at sprite RAM 0x600 in **lines 3-7** of every frame and wipes
sprite RAM 0x600-0x7f8 (f8f8, all 64 entries) in **lines 227-230**; Puzzli draws per scanline in MAME (VIDEO_UPDATE_SCANLINE), so the letters show from line ~8 to the end of the picture. The core copies the sprite RAM once
a frame at the start of the LAST line (262) - after the wipe - so the letters were never in the copy (they showed only when the 68000's timing made some of them land before line 262: letter by letter, at random). Replay of
frames 3897-3956 (30 frames on, 30 off in MAME): with the old copy line the text pixels stay at the "off" level in the "on" period; with the copy at line 224 (`i_spr_early`, Puzzli boards only) they follow MAME's blink
(340/358 against 146-173 pixels of the text colour, on at the right frames, one frame of latency at most). Cost: the renderer is still drawing the last rows while the copy runs, so rows from ~226 on may mix two lists (Puzzli has
only the DEAD LINE tile strip there). The other games' sprite timing: bucket counts of sprite-RAM writes per frame (A = lines 0-10, B = 11-223, C = 224-234, D = 235-262): Puzzli 87/131/4/37, Daitoride 20/170/18/106, Pururun 19/254/25/22,
Gun Master 27/72/1/172, Toride II 45/42/0/168, Dharma 83/150/2/64: every game writes sprites in visible lines, the copy at 262 sees them one frame late; not changed for them.

**2. Palette: Puzzli only.** The OSD option is gone; `metro_main`'s `pal_latch` input is driven by `cfg_board == 5 || 6` in `Metro.sv`.

**3. Scene-change flash (Puzzli, title -> demo).** MAME frames 3779-3781: the game writes the whole palette black (4,096 words a frame), 3786: 5,680 palette writes while the new scene's tiles are loaded (CPU writes + 30 blits
of 161-1,271 script bytes, 8 lines apart as MAME's 500 us done interrupt paces them), 3787-3788 black, 3789+ fade-in (1,700 + 1,200 palette words per two frames). MAME's own picture of frame 3786 is the garbage band the user pointed at.
Replay with the live palette and MAME's window reproduces that frame in the right place; with the per-frame palette (the Puzzli setting) the frame shows only the tile strip with the red/yellow pillars and DEAD LINE on black. So the core
shows what the game does; **the flash is the game's, not a core bug** (the user agrees after checking MAME). No change.

**4. Daitoride rocks.** The tearing is not in MAME and not in the replay at realistic latencies. Replay with more ROM latency: clean up to 40 clocks per request; at 48 a black stub on the left part of 3 rows (rows 182-184, the heaviest lines:
the line completes while the beam is already scanning it, so the first part is the background pen); at 56 whole rows 171-184 black, at 64-80 more of them. The deeper line buffer (`work/metro_vdp_lag7.diff`: lag 7, 8 banks) moves the limit
only a little (still bad at 64). The real first-beat latency of the graphics stream in the whole-machine sim (probe in `tb_metro_sys_top.sv`, first 100 frames = boot and ROM check, the CPU flat out): mean 10.0 clocks, max 23. So the average
delay is far from 48: if the real core tears, something adds stalls on the heaviest lines that neither MAME's write times nor the average delay show; leads: the 480 Hz tick (the row follows the tick's phase, +8 lines a frame), the
68000's own traffic (work RAM and program ROM outrank the graphics stream in the SDRAM arbiter; `cpu_last` fairness tried), blit timing differences (the core's blitter is slower than MAME's instant one, the game waits for the done interrupt).
Experiments in progress: whole machine to the rocks scene (frame ~3000 in the sim) with a stale-line probe, three RTL variants (current, fairer arbiter, fairer arbiter + deeper buffer).
**Result (2026-10-08 03:15): not reproduced.** The three whole-machine runs (default CRTC window, DIPs 0xFFFF, the real SDRAM path; `work/lat3`) went through boot, attract, the rocks / title rise (sim frames ~2500-2850: the sim is ahead of MAME's timeline
because its DIPs differ from MAME's defaults and skip the start-up test) and on to frame 3090+ with **zero late lines** (`STALE picture` never printed) in the current RTL, with the fairer arbiter and with the fairer arbiter + deeper buffer. The glitch on the user's
hardware (a single line, front layer missing over its right part, the row following the 480 Hz tick phase) is therefore not a late-render effect of anything the simulation models; what differs on the hardware is the SDRAM chip / module, the framework's video path and the
real display. Untested ideas: a marginal SDRAM capture that drops one burst (the LED blinks fast on a dropped render kick, `gfx_overrun`: ask whether it blinks during the glitch), the framework's scaler. The experiment RTL is kept in `work/rtl_arb` (a 3-line change in `metro_sdram.sv`).
**SDRAM timing check (2026-10-08 06:00):** `sim/sdram_model.sv` now also checks tRC, tRRD, tRP (auto precharge starts after the read and not before tRAS), tRFC and the refresh gap (`+SDRCHK=1` prints each finding, a summary at the end of every run); Daitoride from reset to
frame 300: 4,997,761 ACTs, **no tRRD / tRFC / tRAS findings; every ACT pair on one bank is at least 6 cycles (62.5 ns, the datasheets say 60-63 ns) apart except 4,096 pairs 5 cycles apart, all in the 53 frames of the game's boot-time ROM check (the 68000 reading the graphics ROM through the
chip's window across a 512-word row boundary: the renderer's bursts are 32-byte aligned and never cross a row); 518 more ACTs come one cycle before tRP after the auto precharge when tRAS is counted (again 62.5 ns), and 34,782 of the 678k refreshes follow a read within tRAS + tRP; the longest gap between two refreshes is 15.7 us.** Nothing there points
at the rocks' scanline, and the controller was left as it is (a margin of one clock at 62.5 ns against a 63 ns part is the worst of it).

**Build `releases/metro_20261008a.rbf` (Quartus 17.0.2, 96 MHz, 39 min):** timing met, machine clock +0.319 ns setup, +0.248 ns hold, every clock positive; 26,167 ALMs (62 %), 532 / 553 RAM blocks. Package `dist/Metro_MiSTer_20261008a.zip`, notes `dist/RELEASE_NOTES_20261008a.md`; 20261007e moved to `releases/test/`. Contents: Puzzli sprite copy at line 224 (`i_spr_early`), Puzzli-only palette latch, OSD `Palette` removed. **Hardware (user, 2026-10-08): Puzzli's DEMO PLAY blinks perfectly, the Banpresto lines stay away without the OSD option, the other games work as before.**

## Family A (Imagetek I4100) and Sankokushi: build 20261008b (2026-10-08, not on hardware yet)

Sets and boards: `docs/hardware.md` section 12 (board ids 7-13 in `tools/metro_rom.py`, decoded from the image's config byte 0 in `rtl/metro_main.sv`; `Metro.sv` picks flip DIP bits, OKI pin 7 and the controls per board).
**Video:** `rtl/metro_vdp.sv` / `metro_render.sv` take `i_i4100`, `i_wide` (360 px), `i_tall` (240 lines), `i_ext_tiles`, `i_ext5` (the karatour vblank irq 5); 56 frozen MAME frames of the I4100 boards and 7 of Sankokushi are pixel-identical (`tools/vtest.sh`,
`WIDE=1 TALL=1 I4100=1`). **Whole machine** (`sim/run_sys.sh`, SDR path, coin 300 / start 400, `tools/metro_syscmp.py` against `tools/lua/vstate.lua` dumps): at frame 100 Poitto, Pang Pom's, Last Fortress (VG420 and VG460) and Sky Alert
are pixel-identical and all memories / registers equal; Sankokushi 100: memories equal (3023 px of animation differ), 250: identical picture; Karate Tournament's intro explosion and ranking screen show the same content a few animation frames apart;
Lady Killer equals MAME's memories at 100 and 250 but a few lines of the raster-scrolled picture differ; Last Fortress at 250 is one fade step (2 of 31) behind MAME in 302 palette entries. A run on an older sim build (before the irq 5 RTL) of Pang Pom's sat with
zero bus cycles per frame; with the current RTL it boots (the stale build predates the board table: not investigated further). MAME's snapshot of Lady Killer is not rotated, the comparison is by memories.
**Rotation:** `Metro.sv` instantiates the framework's `screen_rotate` (`sys/arcade_video.v`), `MISTER_FB=1` in `Metro.qsf` (the FB_* ports; DDRAM_* come from it), OSD `H1O[2],Rotate screen,On,Off` (hidden when `cfg_rot` is 0 or 2),
`rotate_ccw = (cfg_rot == 3)` (ROT90 = clockwise = ccw 0: from the module's addressing, not tried), `video_freak` ARX/ARY 3:4 when rotating. Synthesis keeps it (204 ALMs). **Checked in Verilator with Metro's raster** (`sim/run_rot.sh`, `sim/tb_screen_rotate.cpp`): a 360 x 224 frame comes out as 224 x 360 (`FB_WIDTH` 224, `FB_HEIGHT` 360, stride 896 = 224 x 4 bytes, all 80,640 pixels written); `rotate_ccw` 0 puts source top-left at the framebuffer's top-right and bottom-left at top-left (a turn of 90 degrees clockwise = MAME's ROT90), `rotate_ccw` 1 the opposite (ROT270), as `Metro.sv` assumes. **MRAs:** `make_mra.py` SUPPORTED + both DIP ports (DSW1 in bytes 2-3, `Metro.sv`
`sw[0..3]`), Windows-safe file names (no colon: it made an NTFS stream "Last Fortress - Toride" on the first try). **Build:** `releases/metro_20261008b.rbf` (4,221,660 bytes): machine clock +0.233 ns setup / +0.245 ns hold, all other clocks met, 26,365 ALMs (63 %),
532 / 553 M10K (96 %).

## Family D (Imagetek I4300): Mouja and Mahjong Doukyuusei, build 20261008c (2026-10-08, not on hardware yet)

`docs/hardware.md` section 13.  **Infrastructure for big ROMs:** `GFX_AW` 22 -> 24 (16 MB), the GFX size is a 32-bit config value (bytes 3:6, `metro_loader`), `metro_sdram` takes `i_gfx_addr[23:0]`, `i_oki_addr[21:0]` and a base register `i_oki_wbase` (the OKI samples sit after the GFX ROM
on family D: `Metro.sv` `oki_wbase`), `tools/metro_rom.py` `layout_for` (D: maincpu 0x10000, gfx 0x100000, oki after it; MRAs and images 6 / 10 MB). **I4300 chip** (`metro_vdp.sv`): `v3map` folds the v3 register map onto the I4220 layout (registered `ra`: the first fit with the combinational
translation failed the 96 MHz machine clock by 0.19 ns on 68000 address -> read mux, the registered one gives +0.638 ns), per-cause-bit levels / per-level vectors, vblank cause bit 1, blitter bit 2 / 3, no 480 Hz tick, `o_irq_lvl` / `o_vec`. **Board** (`metro_main.sv`, ids 14 dokyusei, 15 mouja): IPL = the chip's level,
vectored interrupt acknowledge (VPAn high, DTACK with the vector), the ports inside the VDP window, the mahjong matrix (`gakusai_state::input_r`), YM2413 / OKI writes handed to `metro_sound` (`i_direct`: the uPD78C10 held in reset), OKI bank registers and address expansion, Mouja's programmable timer
(a 256-entry table of clocks), the OKI clock per board (1.056 MHz Doukyuusei, 2.0625 MHz Mouja, accumulator in `metro_sound`).
**Evidence:** frozen VDP frames Doukyuusei 7/7, Mouja 7/7 identical (the vtest dumps use `VS_I4300=1` in `tools/lua/vstate.lua` to fold MAME's v3 writes onto the canonical register layout); whole machine (`sim/run_sys.sh`, SDR, MAME's DIP defaults: **Doukyuusei DSW0 FF00 / DSW1 EF00 -- with the bench default
0xFFFF its "Self Test" DIP is on and it sits in the CG ROM test for ever**; Mouja F7F7): **Mouja identical to MAME at frames 100, 250, 420, 700**, Doukyuusei identical at 100 and 250; at 420 Doukyuusei's bench shows the next scene early because the bench ties the OKI status to 0 while MAME's game polls it for the
episode voice to finish (`sim/run_sys.sh SOUND=1` instantiates the real sound module, status included: with it Doukyuusei is identical to MAME at 250 and 420 and its audio level (`+AUDFILE`, `work/tools/txt2wav.py`, `tools/audio_cmp.py` against MAME's `-wavwrite` of the same 9 s) follows MAME's within ~5 % per half second, overall RMS 1151 against 1134; Mouja is silent in both for those 9 s; its first sound comes at 12 s and over 27.6 s the per-second RMS equals MAME's within 1 % (overall 782 against 795), OKI at 2.0625 MHz included). The 68000's YM2413 / OKI writes equal MAME's bytes and order (first 112 events, `+SNDLOG`, `work/dbg/sndtap.lua`), the OKI bank values the games use (dokyusei 0..3, mouja 0 / 1 / 7) fit the address maps.
Older games re-checked with this RTL at frame 100 (whole machine: Dharma, Gun Master, Pururun, Daitoride, Puzzli identical to MAME; frozen frames: Dharma, Last Fortress, Karate Tournament, Daitoride identical). **Build:** `releases/metro_20261008c.rbf` (4,233,528 bytes), machine clock +0.638 ns setup / +0.250 ns hold,
26,914 ALMs (64 %), 534 / 553 M10K (97 %). Not done: `dokyusp` (384 px, EEPROM), `gakusai` / `gakusai2` (32 MB GFX).

## CRT test of 20261008c and the re-timed 360-pixel video, build 20261008d (2026-10-08 evening)

**Report** (one phone video of a Sony HR Trinitron monitor, RT4K fine): "weird sync issues on CRT" with exactly four games: Last Fortress, Poitto, Pang Pom's, Sky Alert. These are the only 360-pixel-wide boards
(`i_wide`, boards 8-12; Karate Tournament, Lady Killer, Moeyo Gonta, Sankokushi are 320 wide and were fine, as were all older games). The video: the picture is wider than the tube (the POITTO logo is cut at both edges)
and jumps / doubles vertically from frame to frame (part of that is the camera: 59.94 fps against 58.2 Hz).

**Cause (by elimination, not proven on a monitor):** the vertical timing is the same on all boards; only the horizontal line differs. The chip's raster is 392 dots x 16 clocks (6.0 MHz dots, MAME's timing), so a 360-dot picture leaves
32 dots = **5.3 us** of horizontal blanking, with the sync pulse (P_HS_BEG 336 + 28 .. 368 + 20) 4 dots = 0.67 us from the picture on both sides. A CRT's flyback needs 9 to 11 us. A 320-dot picture leaves 12 us.
The framework side is not the cause: arcade_video.v samples VSync only at the start of HSync, and the framework's `csync` module puts the serrations right.

**Boards (photos, 2026-10-08):** the VG420 has one crystal fitted, XTAL2 = **24.000 MHz** oscillator (read from the photo: "XTAL OSC MC08100 24.000 MHz SCC"), XTAL1 about 3.58 MHz (YM2413), XTAL3 an empty footprint. So its dot clock
is 24 / 4 = 6.0 MHz as in MAME; the 26.666 MHz / 424 x 270 idea (15.72 kHz, 58.233 Hz) is for the I4220 boards, not the VG420. The line total of the real board is still **unmeasured**, so the real board may well have the same short
blanking; the re-timing below is deliberately a CRT-friendly signal, not a copy. The VG460-(B) photo (Lady Killer, TMP68HC000P-16) has three crystal positions; the markings were not legible. **A VG460-(A) photo has two oscillators fitted next to the video chip's side of the board: XTAL2 20.000 MHz and XTAL3 24.000 MHz** (KSS cans; the 20.000 is blurry but fairly clear), XTAL1 (sound) not read. So the I4100 of the VG460 may run from 20 MHz: 20 / 3 = 6.667 MHz, the same dot clock as Hyper Duel's I4220 (26.666 / 4); and a 360-dot picture only fits a 15 kHz tube at 7 MHz or more, so the VG420 (24 MHz only) probably dots at 24 / 3 = 8 MHz, not MAME's 6.0 MHz. Circumstantial: nothing is measured.
(The arcade-projects thread on the VG420 multi has nothing on timing; Cloudflare blocks fetching it.)

**Change:** `rtl/metro_vout.sv`, between the chip and `arcade_video` (Metro.sv): for the wide boards one line goes through a 360 x 15 bit buffer and comes out at **14 clocks per dot** (6.857 MHz) instead of 16, starting
800 clocks after the chip's line did (the output is faster than the input). The line stays 6272 clocks (15.31 kHz, the frame period and everything in the machine are unchanged), 448 dots: picture 360 (52.5 us, a 4:3 tube's width),
front porch 22 dots (3.4 us), sync pulse 32 dots (4.67 us), back porch 34 dots (5.0 us) = 12.8 us of blanking. Vertical sync is passed on (the level of the next line is taken over at dot 442, away from HSync). 320-wide boards: untouched
(pass-through). OSD `360 px picture for CRT`: `Re-timed` (default) / `As MAME` (the old signal, for comparing), shown only on the four games (menu mask bit 2).

**Evidence (simulation, whole machine, real SDRAM path, `sim/run_sys.sh` with `VOUT=1`, the checker in `tb_metro_sys_top.sv`):** all four games, 197 frames each, measured in steady state (3.6 frames after reset): line 6272 clocks (min = max),
HSync width 448 clocks, 360 dots per picture line, dot spacing 14 clocks, front porch 322 clocks, back porch 476 clocks, vsync 4 lines, 263 lines per frame except **one** frame per run (frame 37: 274 lines = the game programs the CRTC window
`crtc_vfirst` 0 -> 11 there; the raster shifts once; the old signal has the same step). Poitto frames 60 and 110 are **pixel-identical** with and without the re-timing (the picture content is untouched); the four games' frame 190 (ROM / RAM check) shows the text.
Not seen: a real monitor. **To check on the CRT:** is the picture stable, centred and complete in `Re-timed`; does `As MAME` show the old problem.
**Build:** `releases/metro_20261008d.rbf` (4,249,016 bytes; 20261008c moved to `releases/test/`), `dist/Metro_MiSTer_20261008d.zip` (33 MRAs). Fit: all clocks met, but the machine clock's setup slack is only **+0.037 ns** (hold +0.243 ns; 20261008c had +0.638 ns): the new module is not on that path as far as I looked, the fit just came out tighter; 26,711 ALMs (64 %), 535 / 553 M10K (97 %, the line buffer is one block).

## CRT result of 20261008d, Lady Killer / Karate Tournament glitches, Doukyuusei Special (2026-10-09 night; build 20261009a)

**Hardware report (20261008d):** the four 360-pixel games are perfect on the CRT with `Re-timed`. Last Fortress (Mah-Jong): a few tiles at the picture's edge are off the tube (they sit at the very edge of the 360 pixels in MAME's picture too: monitor overscan;
the monitor's UNDERSCAN works, the new OSD value `Narrow` (12 clocks a dot, 45 us picture, margins) shows all 360 pixels). Mouja perfect, Sankokushi nearly. Sky Alert: the Flip Screen DIP flipped at once when switched on and not when switched off:
the game reads the DIP once (in MAME its screen-control writes do not change when the DIP is toggled mid-run) and keeps writing "flipped" from its own RAM; `metro_vdp.sv` `flip_stale`: when the DIP goes off the game's flip bit is ignored until the game writes a 0 there itself.
Lady Killer: a strip of scrambled tiles at the top of the title picture (photo), the white instruction panel (sprites) missing in single frames in the attract (video). Karate Tournament: the title explosion torn / flashing. Display window MAME / Game's CRTC: no change.

**Lady Killer title strip, found and fixed in simulation.** Reproduced in the whole machine (frames 300-420, `work/lk`), not in the frozen-state bench with the same memories (0 pixels differ): all VDP memories and registers at the frame ends equal MAME's. Mid-frame state dumps
(`+MIDF/+MIDL`, `work/lk/mid.*`): vram, palette, sprite RAM are stable through the frame, **the tile table (0x78000, 2 KB) is not**: the game rewrites all of it with the 68000 every frame (tile definitions read through the CPU window of the graphics ROM, the bank register 0x788AA
toggled 26 times; MAME: 2048 table writes between lines 54 and 140, the blitter 6-12 times a frame 8 lines apart = MAME's 500 us blitter-done interrupt, the core's blits take 25-150 us) and it holds up to 780 of 1024 words different from the final table at lines 40-88; the renderer reads it live
(tile code -> table entry -> graphics address), so the lines drawn meanwhile use the wrong definitions. MAME draws a frame from the finished table. Fix (board 7 only, `fix_tall`): a second copy of the table is taken once a frame just after the last picture line (`tts_*`, 1026 clocks through the live table's idle
port B) and the renderer reads the copy (a frame older than MAME's, every line from the same table). Whole machine frames 300 and 330: the strip is gone. (Tried and **no effect** on the strip / the panel, so not in the build: a per-frame latch of the layer window and screen-control registers (the game writes them from its main loop, MAME trace
`work/b2/linehist.lua`), the sprite list copy at the vblank line instead of the last line, a 500 us blitter-done delay like MAME's; the per-line scroll values the renderer uses in the strip lines are constant (`+KICK0`), the blitter and sprite timing probes `+BLIT0` `+LH0` are in the bench.)

**The panel / Karate explosion (the text below is the first, wrong, analysis; the cause was found on 2026-10-09, see "Sprite count latch" under it).** Lady Killer sim frames 830, 831, 835, 853 (of 828-856) have the 34-sprite group of the panel missing: at those frames the game's own sprite count register (0x79700) is 0x48 / 0x45 instead of 0x6A and its sprite RAM differs from the frame before
in 24-30 words (the panel sprites are the list's tail); MAME frames 780-1000 never miss the group. The picture of those frames is identical in all RTL variants above (the game's logic state, not a raster effect). Working theory: the 68000 is slower than MAME's (the sim's bus statistics: 19.5 % of the program-ROM cycles wait,
13 % for two wait states, +VDP accesses: about 12 % of the CPU's time) so the game's multi-frame rebuilds spill across a vblank; the program-ROM cache was enlarged from 512 to 2048 words (`metro_romif.sv`, IDX) to take that back. Karate's frame 1260 (a white explosion shape with a hard rectangular cut) is the same in all variants.
**Sprite count latch (2026-10-09 morning): the cause of Lady Killer's panel dropouts, found and fixed in simulation.** The renderer draws the sprites from a copy of the sprite RAM that is taken once a frame (the start of the last line), but it read the sprite **count** register (`r_spr_count`, 0x79700 / I4100 alias 0x78800) live, row by row. Lady Killer writes the count in the middle of the frame, after the new sprite list (MAME `work/lk/mm/mame_regw.txt`: one write a frame at beam line 75-126), and changes it when a scene changes (0x6A -> 0x45 at frame 828, 0x45 -> 0x44 at 832): the rows below the write line were drawn with the NEW count and the OLD list, so the end of the list (the panel's sprites) dropped out for a frame. The 64-frame period is the game's scene cycle, not a counter in the core, and not CPU speed. My earlier conclusions (game state differs from MAME; CPU too slow) were wrong: the per-frame histograms of the 68000's sprite RAM writes (beam lines, counts) are **identical** in MAME and the whole-machine sim for frames 800-900 (`work/lk/hist2.txt` vs `work/lk/mm/mame_hist.txt`); what differed was the register value the renderer saw at the time.
Proof with the replay bench (MAME's own write times, `work/lk/rp`: dump at frame 824, 7806 writes, 20 pictures, white pixels of the picture = 18325 before the scene change and 17980 after in MAME): the live count gives 7237 (frame 828) and 16443 (frame 832) - the two dropouts, exactly at the frames where the count changes - and with the count latched at the sprite RAM copy (`spr_count_q` in `metro_vdp.sv`) every frame has MAME's number (the scene change shows one frame later, the copy's one-frame delay). Karate Tournament's title explosion: (a) MAME frames 1030-1059 (`work/kt/rp`, count 0 -> 8 -> 30 -> 40 -> 54 ...): the live count draws a mixed picture at frame 1033 (8,447 pixels off), the latched count none; (b) **the artifact of the whole-machine sim (frame 1260: a white explosion shape cut as a hard rectangle in the lower right, `work/kt/sheet_kt.png`) is MAME frame 1264, where the count goes 0 -> 0x3e** (`work/kt/rp2`, dump at 1260, 8,560 writes, 20 pictures): old RTL 21,869 pixels off MAME's picture (the rectangle), latched count 2,759, all in the bottom 16 rows (the "INSERT COIN" text, one frame late); rows 0-223 identical. So the Karate explosion artifact is the same defect and is fixed. Regression of the change: frozen-state video bench 0 pixels differ for Dharma, Karate Tournament, Lady Killer (4 frames), Last Fortress, Pang Pom's, Doukyuusei, Doukyuusei Special, Mouja, Gun Master, Pururun, Puzzli and Daitoride (the last two with the tilemap offset), whole machine at frame 100: see the build notes. Build **20261009c** (`releases/metro_20261009c.rbf`, zip `dist/Metro_MiSTer_20261009c.zip`, notes `dist/RELEASE_NOTES_20261009c.md`; clean copy `work/build_c`): machine clock setup +0.424 ns, hold +0.247 ns, all clocks positive, 28,969 ALMs (69 %), 542 / 553 RAM blocks; 20261009b moved to `releases/test/`. Whole machine at frame 100 with the latch: Dharma, Lady Killer, Mouja, Daitoride, Doukyuusei Special identical to MAME (every memory, register and pixel). A whole-machine Lady Killer run through frames 780-860 with the latch (`work/lk/run17.sh`, pictures `work/lk/nl.*.ppm`) was started to confirm the dropouts are gone outside the replay bench.
**CPU-speed test (2026-10-09 morning, `work/lk/run16.sh`, `+FASTCPU` in the bench = the 68000 at 16 MHz instead of 12): the panel still drops out.** In sim frames 780-900 the white-pixel count falls to 4,735 / 5,048 (median 18,213) at frames 817 and 881 - again 64 frames apart (12 MHz: 830, 894), only the phase moved. So a 33 % faster CPU does not remove it
and the working theory above (CPU too slow) is not supported; the real cause is the live sprite count described under "Sprite count latch" (written afterwards, same morning).

**Doukyuusei Special (board 16, `dokyusp`), new:** I4300, 16 MHz, **384 x 224** picture (`i4300_config_384x224`), map: ROM 256 KB, video chip at 0x200000 (inputs at VDP + 0x78880 like Doukyuusei, mahjong matrix, IN0 = coin / service only, no DIPs), OKI bank 0x500001 (one register, 8 banks of 256 KB, 2 MB of samples), YM2413 0x600000, OKI 0x700001 at 2.112 MHz,
**93C46 EEPROM**: 0xC00001 = chip select, 0xD00001 = data (a write gives DI plus one clock edge, a read one clock edge and returns DO), `rtl/metro_eeprom.sv` (written from the data sheet; the 128 bytes of MAME's `eeprom` region are in the image at 0x100 and loaded into it, not saved). 16 MB of graphics + 2 MB OKI = a 19.9 MB image (fits 32 MB SDRAM).
Video: `i_w384` in the chip (picture 384), `metro_vout` always re-times it (12 clocks a dot, 48 us, 522 dots a line; the chip's own sync has 8 dots of blanking). Evidence: frozen frames 7 of 7 pixel-identical (`W384=1 tools/vtest.sh dokyusp work/dsp/dsp ...`), whole machine from reset (real SDRAM path, MAME's window): frames 100, 420, 600 identical in every memory, register and pixel; frame 250 one sprite offset register one step off (2573 pixels, the usual
animation phase). Not checked: the sound's write order (running), the EEPROM's writes on a real save, the keyboard.

## Varia Metal (board 17, `vmetal` / `vmetaln`), 2026-10-09 (in build 20261009b: setup +0.439 ns, hold +0.251 ns, 28,782 ALMs, 542 / 553 RAM blocks; not on hardware)

Excellent System's board on the Imagetek I4220: 68000 at 16 MHz, **304 x 224**, ROT90, **1 MB program ROM**, no sound CPU; the 68000 drives an OKI M6295 (1 MHz) and an **ES8712 + MSM6585** pair; the video chip's interrupt is level 1, the ES8712's level 3.
Map (metro.cpp `vmetal_state::main_map`): ROM 0..FFFFF; video chip 0x100000; P1_P2 (word) 0x200000, SYSTEM 0x200002, the control register is the byte 0x200001 (bit 4 = the ES8712's sample ROM bank, bit 6 = the gate of its interrupt, bits 0-3 coin counters / lockouts);
0x300000..0x31FFFF: the DIP switches, **one bit a read** (`balcube_dsw_r`: every address bit b that is 0 puts bit b of DSW0 on data bit 6 and bit b of the second bank "IN2" on data bit 7); OKI 0x400001 (read / write) and 0x400003 (write); the ES8712 at 0x500000..D (odd bytes: start / end address and go; a write of the even byte 0x500000 resets it); RAM 0xF00000 mirrored.
**ES8712** (`rtl/metro_es8712.sv`, after MAME's es8712.cpp / msm5205.cpp, unit-tested against a C++ transcription of MAME's code, `sim/run_es8712.sh`, 6000 sample ticks, 0 mismatches): a programmable address counter that streams the 2 MB sample ROM (two banks of 1 MB) a nibble per VCK of the MSM6585 (640 kHz / 40 = 16 kHz) and raises its interrupt at the end;
the MSM6585 decodes 4-bit ADPCM (the 49-step table, 12 bits). Its sample bytes come through the OKI's SDRAM client (`rtl/metro_okimux.sv`: the ES8712's one byte every 6000 clocks steals the port for one read, the byte is latched).
Image (`tools/metro_rom.py`): graphics at 0x100000 (8 MB), the program after them (the SDRAM controller's main-ROM base is an input now, `i_mrom_wbase`), then the OKI's 512 KB and the ES8712's 2 MB: 12.5 MB. The program ROM cache is 1 MB addressed (`metro_romif.sv`). The second DIP bank is MAME's port "IN2" (`make_mra.py`: bytes 2 and 3 of the MRA's switches).
**Evidence:** frozen frames 7 of 7 pixel-identical (`W304=1 tools/vtest.sh vmetal work/vm/vm ...`); whole machine from reset (real SDRAM path, MAME's DIP defaults `DSW0=00FF DSW1=00FF`, coin at 300, start at 500): frames 100, 250, 420, 600 identical to MAME in every memory, register and pixel.
Inputs: P1 / P2 joysticks and 3 buttons, Start 1 / 2, Coin 1 / 2 (SYSTEM bits 0 / 1), service = the keyboard's service key; the Flip Screen DIP (DSW0 bit 4) forces the flip.
**Sound (checked in simulation, 2026-10-09; `work/vm/`).** The write sequences to the OKI and the ES8712 are identical to MAME's (all 41 writes of the first 840 frames, `SNDLOG`). **The ES8712 hands over the HIGH nibble of a byte first**
(my first version took the low one: the decoded wave had the right loudness and the wrong shape; found by decoding the sample ROM in Python (`work/vm/esmodel.py`) and correlating it with MAME's own recording `work/vm/mame.wav`: low nibble first 0.50, high nibble first 0.94, mean level -8232 against -8235,
AC rms 1313 against 1325). After the fix the whole-machine sim's audio is the Python decoder's output to 1.000 (and 0.941 against MAME, the rest being MAME's 640 kHz to 48 kHz filtering; the sim starts the sample 39 ms later, the game's timing). Levels: the ES8712 is x8 in MAME's file, the core's output is MAME's / 8 like the YM2151 boards (`i_loud`);
the OKI's effect at 8.6 s measures 0.7-0.9 of MAME's in the same ratio (the ES8712's start state differs a little in the comparison). Not heard on hardware.

## Hardware test of 20261009c, the palette latch for every board, CRT Adjust (2026-10-09 evening; build 20261009d)

**User report (hardware, 20261009c):** Lady Killer fixed (title screen garbage and the flashing panel of the controller demo); Sky Alert's Flip Screen off works; Varia Metal "works really well but sound a bit low"; **Karate Tournament not better**; Doukyuusei Special and Doukyuusei **flash** "right after the title screen where there is a little animation of some girl" and in the scenes where things move (it stops when the girl that comes from the left stops), and both take "5+ seconds to start"; the `Narrow` setting "isn't very good", implement https://github.com/rmonic79/MiSTer-CRT-Adjust instead, "it could be useful for every game of the system".

**The bench had been hiding the palette problem.** `sim/tb_metro_sys.cpp` sets `pal_latch` to 1 for every board (`+PALLIVE=1` for the live palette) and the frozen-state / replay benches default to the latched palette (`PALLATCH=1`), while `Metro.sv` latched the palette only on Puzzli (boards 5 / 6, the user's wish at the time). Every "identical to MAME" result of the whole machine and of the video benches was therefore a result of the latched palette; the hardware showed the live one (the lesson of [[verify with the real flow]] again: the benches must run the hardware's own configuration).
* **Doukyuusei Special's flashing = the live palette.** MAME's write trace (`work/dsp/fl/vdpwr.txt`, base 0x200000): in the fade of the portrait scene (MAME frames 973-992) the game rewrites 768 palette words **spread over lines 0-261 of every second frame**. Replay bench (new: `+I4300=1` / `+W384=1` in `sim/run_replay.sh`, scene = MAME's dump at frame 970, 8,547 of MAME's own writes at MAME's times, `work/dsp/rp`): with the live palette every second frame (977, 979, ... 991) is **27,000-31,000 pixels off MAME's picture** (the band the beam has passed after the writes, 1/3 of the 86,016 pixels); with the per-frame palette those frames are MAME's previous picture exactly (the fade steps one frame later) and no band remains.
* **Karate Tournament's explosion = the same.** MAME writes **16 palette words in the middle of the picture (lines 95-113) every 6 frames** (the fire's colour ramp, `work/kt/lh_k.txt`): the live palette shows the old colours above line ~100 and the new ones below (frames 1262, 1268, 1274: 17,800-23,500 pixels off MAME's picture in the replay with the live palette, `work/kt/rp2` `newlive`); with the per-frame palette the frame is a clean one. (The sprite-count latch of 20261009c was a real defect too - the white rectangle - but it was not what the user saw.) Karate's game also runs a chain of blits during the visible lines (blits every 8-9 lines from line 6, `rw_k.txt`); in the replay with MAME's timing the background changes one frame later than MAME's at every sixth frame (`work/kt/rp2/sheet_1262.png`): unchanged.
* **Fix: `.pal_latch(1'b1)` in `Metro.sv`: every board draws a frame from the palette as it was at the start of the frame** (copy at chip line vfirst + 1, `u_palette` shadow, already in the core since 20261007e; no extra RAM). Same as MAME's end-of-frame draw, one frame later.

**Doukyuusei's "5+ seconds to start" is the load, not the game:** the image of Doukyuusei is 10 MB and Doukyuusei Special's 19.9 MB (the GFX regions are 8 / 16 MB), MiSTer reads, unzips and sends it at a few MB/s; in MAME's own timeline (and the whole-machine sim, which equals it at frames 100 / 420 / 600) the first picture is there after 1-2 s of emulated time. Nothing to fix in the core; a bigger image takes longer.

**Varia Metal's level:** `i_loud` boards (Varia Metal only) are now mixed at MAME's own level (`mix >>> 2`, was `>>> 3` = 6 dB lower); the YM2151 boards keep `>>> 3`. The OSD steps (Normal / -6 / -12 / +6 dB) start from there.

**CRT Adjust (replaces the `Wide picture for CRT` option; the 360 / 384-pixel boards are always re-timed now, `As MAME` and `Narrow` are gone).** `modules/crt_adjust/crt_adjust.sv` (rmonic79, GPL-3.0-or-later, commit c682de9, one fix: see below), glue `rtl/metro_crtadj.sv`, OSD page `CRT Adjust` (`status[101]` On/Off, `[100:96]` H-Size -16..+15 quarters of a clock per dot, `[85:79]` H-Position index 0..96 = 0..+48, -48..-1 dots, `[78:74]` V-Shift -16..+15 lines; the amounts hidden while Off, menu-mask bit 3). It sits between `metro_vout` and `arcade_video`; the OSD's window (`o_de_osd`) is anchored to the native picture as the upstream's `docs/core-side-integration.md` prescribes. `metro_vout` reports its dot length (`o_pdot` 16 / 14 / 12) so one H-Size step is a quarter of a clock for every board. 1024 x 24 bits of line buffer (3 M10K).
* **Upstream bug found by the unit bench:** in `HPOS_CONTENTSHIFT` the expression `$signed(hoffset)` inside a `?:` with an unsigned operand is zero-extended, so a **negative H-Position pushed the picture 512 - N dots right and out of the window** (a black screen on its content). Fixed in the vendored copy (explicit sign extension, marked `METRO`); worth reporting to the author.
* **Second change: two picture lines were lost.** The module gates the picture with `vb_active`, the vertical blank sampled one line before the line it emits, and hands `vb_in_q` (undelayed) on as the vertical blank; with Metro's stream (the vertical blank of a line changes before that line's horizontal sync) that blanked the first and the last picture line of a frame (**222 of 224 lines**, `CRTDBG=1 sim/run_crtadj.sh` prints the source lines shown: 1..222). Now both use `vb_line`, the blank as it was at the start of the read line: 224 of 224, the frame still 263 lines of 6272 clocks.
* **Ranges are the blanking around the picture** (`HPOS_MODE` is a compile-time choice; the content-shift mode was chosen because the 360 / 384 pictures are centred): the native 320-pixel boards have 32 dots to the right of the picture and 8 on the left (the chip's sync pulse sits at dots 352-384 of 392), the 360-pixel boards 22 / 34, Doukyuusei Special 45 / 56; a positive H-Size needs room on the right (+6 at most on the native boards, +3 on the 360-pixel ones, +5 on Doukyuusei Special), a negative one is free.
* **Verification** (`sim/run_crtadj.sh`, `tb_crtadj.cpp`, 22 checks, all ok): off = bit-exact pass-through; on at 0 / 0 / 0: every dot once and in order, one line later, line length 6272 clocks, sync 512 clocks; H-Size +4 / -8 / -16 give dots of 17 / 14 / 12 clocks and the picture starts the same number of dots after the sync; H-Position +16 / +30 / -4 / -8 move it exactly that many dots and the OSD window stays; V-Shift +5 / +15 / -5 / -16 move the vertical sync that many lines; pdot 14 / 12 give 14 / 12 clocks. **Build `releases/metro_20261009d.rbf` (Quartus 17.0.2, seed 2, `work/build_f2`):** machine clock setup +0.423 ns, hold +0.253 ns, every clock positive, 28,971 ALMs (69 %), 544 / 553 RAM blocks; 20261009c moved to `releases/test/`; zip `dist/Metro_MiSTer_20261009d.zip`, notes `dist/RELEASE_NOTES_20261009d.md`. Seed 1 (`work/build_f`) missed by 0.036 ns in the framework's `yc_out` chroma LUT (the first compile, `work/build_e`, before the module fixes: 0.014 ns in the CPU address -> VRAM path): placement noise, seeds 2 and 3 meet it (+0.423 / +0.142). `Metro.qsf` now carries SEED 2.
  The whole-machine chain (`CRTON=1 CRTH= CRTP= CRTV= VOUT=1 run_sys.sh`, `work/crt`, Poitto and Doukyuusei Special): the line stays 6272 clocks, the picture 360 / 384 dots, the sync 437-441 clocks (the sync is re-sampled at the dot rate), the picture's margins move as set. (The checker's `lines per frame` read 262 with the vertical sync coincident with the horizontal one; fixed to count that line as the first of the next frame.)

## Hardware test of 20261009d, Doukyuusei Special's black frames, Karate's rectangles (2026-10-10; build 20261009e)

**User report (hardware, 20261009d):** the flashing of Doukyuusei Special / Doukyuusei and Karate Tournament's explosion "still same"; attached IMG_7940 (photo of Karate: rectangular patches with sharp horizontal / vertical edges, a different, yellow-green colour inside the orange fire), IMG_7942 / 7943 / 7944 (Doukyuusei Special, "there is different flashing in every one of them"; "those dark soft-edged bars in that attract scene is the flashing I mean", "it's not my camera"); CRT Adjust works on the CRT; on the RT4K V-Shift "created some quick vertical tearing to game picture and OSD".

**The three videos (HLG HEVC: tone-mapped with ffmpeg `zscale` / `tonemap`; the per-frame mean brightness from `scale=1:76,format=gray` raw profiles, `work/videos/prof_794{2,3,4}.raw`, `mksheet.py`).** Same sequence in every one: the cast, the fade to white, **one completely black frame**, the title, then the portrait animation with **a dark dip every sixth frame**; how many portrait cycles it runs differs per boot (5 / 3 / 16: the game's own behaviour).
* **Cause: the palette copy's timing, not the live palette any more.** The game clears a palette bank and loads the new colours across the frame boundary (zeros written from line 239 of one frame to line 81 of the next, every sixth frame in the portrait scene). 20261009d took its once-a-frame copy at chip line `vfirst + 1` (the start of the next frame), i.e. between the clear and the load: a black frame. MAME draws a frame at line 224 with the palette of that moment.
* **Fix (`metro_vdp.sv`, `pal_latch_line`): the copy starts at `v_vis + vfirst + 3`, right after the last displayed line** (the display lags the counter by 3 lines; ~4,100 clocks, well inside a line), the frame is drawn from it one frame later.
* **Replay evidence (MAME's own writes at MAME's own times, `work/dsp/rp2`, `rp3`; `run_replay.sh`, W384 + I4300, hardware timing 16 clocks a dot):** MAME frames 860-887: frames 866 and 872 (every sixth) with the 20261009d code are **86,008 / 86,016 of 86,016 pixels wrong (fully black)**; with the new timing 10,837 / 10,780 px differ from MAME's picture, 4,282 / 4,627 from the previous one: no black frame (the remainder: the game changes the picture while it is drawn, a patch around line 137). MAME frames 600-627 (cast to title): the old timing shows one frame of brightness 0 right after the white fade (frame 609 of MAME's 225), the new timing none (226, MAME's own dip 189 .. 225). Whole-machine frame-100 regressions of the final RTL: below.
* The "5+ s start" of both games is the ROM load, see the previous section.

**Karate Tournament: the rectangles are NOT reproduced; the cause is unknown.** The window / scroll registers are now latched once a frame together with the sprite count (`r_window_q`, `r_scroll_q`; Puzzli, `i_scan_irq`, keeps the live values for its raster effects): MAME draws a frame from the registers' end-of-frame values and the game writes window registers at lines 87-120 of every frame, so each frame the core drew the layers' upper part with the old and the lower part with the new values. This is a hypothesis that matches the look (sharp-edged rectangles of another part of the picture), not a proven cause:
* The replay of MAME's writes (`work/kt/rp2`, MAME frames 1260-1279) is pixel-identical to MAME's frames in 9 of 20 frames, within 18 .. 1,256 px in 8 (in the one examined, frame 1276, lines 224-239 only: the sprite list) and one frame behind in 3 (the game's blit-chain pacing, seen since 20261009c), **with GFXLAT=0 and with GFXLAT=12 (the SDRAM path's latency) and with the live window registers**: the video chip alone, with MAME's write pattern, does not make rectangles.
* So the difference is in what the replay does not contain: the game running on the core's own CPU (its write order and timing relative to the beam, the SDRAM contention of the CPU's work RAM / program ROM fetches with the graphics stream: "work RAM and program ROM outrank the graphics stream in the SDRAM arbiter"). `work/kt/run_hw2.sh` (whole machine, `SDR=1`, Karate through frames 1190-1300, ~10 s a frame) is the test; result below if it was read.
* Honest status: **unverified**; the user's next video / photo decides.

**RT4K V-Shift tearing.** The module delays the vertical sync by whole lines: the native sync sits 8 lines behind the picture (224 picture lines, sync at line 232), so V-Shift below -8 lines moved the sync pulse into the picture (the d range was -16..+15). The range is now -8..+23 (OSD index 0..23 = +0..+23, 24..31 = -8..-1; `rtl/metro_crtadj.sv`, `Metro.sv`); the room after the picture is 27 lines. Also inherent: the frame in which the value changes has a different length (a CRT follows, a scaler re-locks and tears one or two frames). If the tearing persists with a fixed value it is something else and the user should say which value.

**Methods and lessons.**
* The replay bench ran correctly but the question was the wrong one for the d fix: the replay at frames 970-992 (fade of the portrait scene, every second frame) was fixed in d, the dips at the frame boundary (860-887, 600-627) needed the second look: **replay every scene of every video, not the one that looks like the problem**.
* The whole-machine run through Karate's explosion takes hours (~10 s a frame at 16 clocks a dot with the SDRAM model); start it earlier next time.

## Family F hardware test of 20261010 (metrof64_20261010a) and the plane engine v2 (2026-10-10 / 11; build 20261011a)

**Report (three phone videos + an audio memo):** Grand Striker 2's sound is fine; its picture has horizontal bands that grow from the top of the pitch down (about 3 s) and
can fill the whole screen with ONE colour (the beige / orange of the pitch's background), and a green dash blinks next to the title's "PRESS 1P START BUTTON" text.
Blazing Tornado: music ok but loud noises / buzzing between, and horizontal bands that sometimes make the whole screen black (in the 72 s video: 22 s of black, the screen
zoomed out after a fall, then the winner's picture).

**The bands (found by making the failure reproduce):** scan-out blanks a line to the background pen (`so_stale`, `r_bg`) when the renderer has not finished it, and the
renderer waits for the plane (`roz_ok`).  The 053936 engine of 20261010 and before (v1, a dot every 5 clocks, a 256-byte tile fetched on every tile change through two
requests, a 16-entry FIFO cache) took 160 - 300 clocks a tile change; the pitch in perspective changes tile up to 112 times in a row (MAME frames of a random-play session,
`work/gs2m`: 8,500 tile changes a frame, 71 rows over 40) and a row's cache working set is 112 tiles, so the FIFO cache missed every time.  The frozen-state bench
(`work/gs2m/run_lat.sh`, the video chip + plane, the graphics stream with `+GFXLAT=n` clocks of extra latency) reproduced it: with n = 0 the engine finishes the last row
at 1.38 M of the frame's 1.65 M clocks (84 %), with n = 20 rows 5 .. 16 of frame 5400 were beige (9,175 px off MAME, none with n = 10), with n = 40 53 rows.  Blazing Tornado's
zoomed-out ring (the KO / fall scenes: 2x, 76 tile changes a row, all distinct tiles) overran the same way (the black phase).

**Build 20261011a (`metrof64_20261011a`): machine clock setup +0.263 ns, hold +0.247 ns, HDMI +0.614 ns, 21,909 ALMs (52 %), 553 / 553 RAM blocks, seed 1.**  **v2 engine** (`rtl/metro_roz.sv`, see `docs/hardware.md` section 15): walker / fetcher / painter, 32 line slots, map windows of 32 words, 16-byte (Grand Striker 2, tile rows
in raster order through `metro_loader.sv`) / 8-byte (Blazing Tornado) tile row requests.  Evidence: unit bench (`sim/run_roz.sh`, `tb_roz.cpp`, 25 clocks of latency): **0 of 68,096
dots differ from `tools/metro_roz.py`** on 10 Grand Striker 2 match frames, 4 Blazing Tornado match frames and 12 rotated / zoomed synthetic transforms (`work/rotv`), 850 - 1,000
clocks a row (v1: 4,000 - 8,000), Blazing Tornado's 2x ring 2,400; the video chip + plane at hardware timing (`work/gs2m/run_lat.sh`, `work/btm/run_lat.sh`): the same frames
identical to the reference, never late up to 40 clocks of stream latency (BT's ring up to ~55; the whole machine measures 12 clocks mean, 21 max: `ROZ_PROBE`), the Blazing Tornado
whole machine frame 100 identical to MAME.

**The green dash (title):** not reproduced by the frozen-state bench (frames 480 .. 680 of a title with a credit, latency 0 / 40: 0 px off).  Probable cause: a 68000 write to
the sprite RAM during the chip's 2,050-clock sprite list copy (MAME copies at one instant): a word ahead of the copy pointer reaches the copy, one sprite mixes two frames
(a piece of the logo's green "2" at another sprite's place).  Writes to the sprite RAM are held while the copy runs on family F (`spr_wr_hold`; the main core is unchanged).
**Not verified**, it is a hypothesis that fits.

**Sound (Blazing Tornado):** MAME's HUM-002 is stereo (SSG 0.75 both sides, FM + ADPCM left 1.0 / right 1.0), Grand Striker 2's mono (SSG 0.75, FM 0.25 + 0.25).  `metro_sndf.sv`
had the mono weights for both: FM / ADPCM 12 dB low against the SSG.  Bench (24 s of a session, 937 commands from MAME, `-wavwrite` of MAME): RMS within 1 %, waveforms 0.8 - 0.97.
The audio memo's wide-band bursts (32.2 s, 41.4 - 42.5 s) are later than the 24 s benched.

**Build notes:** the SDRAM graphics address is 26 bits (`GAW`: F32 25 + 1, F64 26 for the stream's byte 59 MB), the map RAM is read through the graphics stream (no sr3 sharing with
the plane any more); `tb_metro_vdp_top.sv` puts the map RAM and the (permuted) tile ROM into the stream's model; `ROZ_PROBE` (`sim/run_sys.sh`) prints the request latency per frame.

## Hardware test of metrof64_20261011a (2026-10-11): what the new engine fixed and what it did not

**Report:** Grand Striker 2 "got better" (the bands are gone); a brown plane filled the screen for a moment once, right after the user's goal in a real game (not in play, not in the demo
loop); the green blinking garbage at the top of the title near the INSERT COIN texts is still there (two new videos, 20 s of the title); Blazing Tornado: the sound has the same symptoms
(noise / buzzing between the music) and black planes are frequent while playing.

**Title dashes, from the videos (`work/fb3`):** frame by frame (60 fps) the INSERT COIN text blinks off for ~8 frames; during the off phase 5 px x 1 row green dashes appear at the text row,
at x positions that step by about a character width, a different one every frame (in the on phase only at the right end of the right text).  MAME's own frames of the same blink (60
consecutive frames from 1380, `work/gs2b`) have none: the text fades orange -> dark red -> gone, and the only green in rows 0 .. 19 is the logo's tip at x 223 .. 232 (constant).
**Not reproduced in simulation:** the replay of MAME's own writes of frames 1400 - 1445 at hardware timing with the game's CRTC window (11) is 0 pixels off MAME on every picture (rows 0 - 212
against MAME's 11 .. 223), with the sprite list copied at line 235 (build 20261011a) and at 224 (`F_COPY224`), and with the writes stretched in time by 1.3 / 1.6 / 2.0 (a game CPU
slower than MAME's: `work/gs2c`).  So the sprite copy line and the writes' timing are not what makes the dashes.  Whole machine (the core's own CPU through the SDRAM model, frame 480,
`work/gs2t`): identical to MAME, with and without the write hold.

**Blazing Tornado black planes, not reproduced:** a replay of 56 pictures of a real fight (MAME's writes incl. ~1,000 map words a frame, frames 3600 - 3656, hardware timing, window 0, 12 clocks
of extra stream latency, write timing x1.0 / 1.5 / 2.0): every picture within 0 - 1,900 px of MAME's (the sprites' buffering), no late plane row (`work/btr`).  (Pitfall found on the way:
`rozwr.lua` + `vstate.lua` in one MAME run leaves the `.regs` dump empty; take the scene from a run of `vstate.lua` alone.  And: replay events closer than a bus cycle are lost; space injected
CRTC writes by 100+ clocks.)

**The one hardware-only difference found: SDRAM row-cycle timing.**  `sim/sdram_model.sv`'s checker counts ACT -> ACT to one bank in 6 clocks (62.5 ns at 96 MHz; -7 parts need 63 ns, some
modules 66 ns) and refresh commands inside the precharge of a short access: 19 million tRC / tRP violations in 24 s of Blazing Tornado's sound board alone (the Z80's two-word wait loop
fetched from the SDRAM at every instruction: one word cache), 3,457 in 150 frames of the whole machine.  Cannot be seen in an ideal-timing simulation; on a module with a slow tRC it can give
sporadic wrong reads: noise in the samples, a wrong tile code (black), a wrong byte of a sprite row (a dash).  **Unproven as the cause of anything the user sees.**  Changes (20261011b):
`metro_sdram.sv` one more clock after a 1 .. 3 word access (`req_short`) and after writes, three after the first part of a row-crossing burst, the refresh command one clock later
(`idle_d`); `metro_sndf.sv` an 8-word direct-mapped code cache.  Bench (BT sound board, 4 s): tRC6 / tRC7 / tRRD / tRP / tRFC / tRAS **0 of 21.8 million ACTs** (20261011a's controller:
tRC7 ~8 million and tRP ~6.5 million in 8 s).  The map window is also read again for every row (it practically was).  **The OSD's "SDRAM read capture: Late" is the user's quick test**
for the same class of problem (not tried yet as of this note).

**THE BUG (found from the user's next videos, 2026-10-11): the plane engine stopped at row 224 while the video chip needs chip lines up to 234 with the game's CRTC window.**  Every
closed-loop simulation had forced MAME's window (`WINMAME=1`, vfirst 0), so it never showed: on the hardware the game programs the CRTC vertical word 0x070b (window 11: chip lines
11 .. 234; Grand Striker 2 and Blazing Tornado both, `t.*.regs` 78880).  The renderer kicks chip lines 2 .. v_vis + vfirst - 1 = 234 and holds each kick until the plane has the row
(`roz_ok`: row < i_roz_done); the engine made 224 rows (VIS_H), so rows 224 .. 234 were never ready: they waited until the next frame's pulse released them, were rendered in front of
the new frame's rows 0 .. 10 (the kick FIFO overran, `fifo overrun=1` in the bench: `work/gs2m/run_win.sh`, `tb_metro_vdp.cpp +CRTCV=070b`) and the bottom 11 picture rows showed the
background pen (beige on the pitch, black on Blazing Tornado).  With a heavy scene (a goal, the ring zoom) the 11 late rows push the whole frame past its display lines: **bands from the
top, rows 0 / 1 only (a thin red line of the HOW TO PLAY banner), whole screens of the background pen for seconds (`IMG_7985`: 6 s of beige after a goal; `IMG_7983`: Blazing
Tornado's HOW TO PLAY black with a line), partly drawn top rows (the green dashes of the title: the first rows of the frame are displayed before they are rendered).**  Fix:
`metro_roz` VIS_H 240 (rows up to 238 are needed with vfirst 15): bench with the window 11: rows_done 240, overrun 0, the bottom rows have the plane.  Not seen earlier because the
benches ran window 0; **from now on the benches that matter run the game's window** (`CRTCV=070b`, or `WINMAME=0` whole machine).

**Plane of the whole machine (closed loop) vs the reference:** `dump_roz` in `tb_metro_sys_top.sv` writes the 053936's control block, line RAM and the tile map RAM (the SDRAM model's shared-RAM
words) of the whole machine itself; `tools/metro_roz.py` rendered from that state is **0 pixels off the whole machine's own picture** at frames 580 and 600 of Grand Striker 2 (the real SDRAM
path, the loader's tile-row permutation, the CPU's map writes through the shared-RAM client: `work/gs2/wc.*`).  The whole machine's pitch differs from MAME's frame 600 only because the
game's own timeline is a few frames off MAME's (the grass noise sits at another phase; the far corners show the match pitch's diamond shading where MAME's tutorial frame has plain
grass): a game-state difference, not the engine's.

## Hardware test of metrof64_20261011b (2026-10-11): nothing changed on the real machine; build 20261011c measures it; Blazing Tornado's sound cause found

**Report:** "same bugs happening for both games"; the OSD's "SDRAM read capture: Late" did not help.  So the VIS_H = 224 bug was real (bench-reproduced, fixed) but it is **not** what the hardware shows; every simulation
(frozen frames, replay of MAME's writes at the game's CRTC window, whole machine, SDRAM model with 12 - 40 clocks of extra latency) passes.  What is known about the frames
(`work/fb3/band_sheet.png`): the beige region starts below the first ~8 lines (the top lines and the "PRESS 2P START BUTTON" text are drawn), grows down the picture over seconds (a band, then the whole
picture) and shrinks again from the top; the HUD sprites are faintly there in the all-beige frames (lines alternate between drawn and blank from frame to frame).  Not a palette fade.

**Build 20261011c = diagnostic** (`metrof64_20261011c`, `docs/hardware.md` section 15 "Debug overlay"): OSD "Debug overlay" (hex rows over the picture: stale lines, first / last stale line, renderer line time,
kick wait, plane rows done, request latency, work per row, graphics stream use per client, zoom words, frame length), and three A / B switches (plane fetch priority, CPU sprite write hold, sound board off).
Overlay checked in `sim/run_hud.sh` (text) and in the vdp / whole-machine benches (`HUDST` lines: `+HUDST` in `tb_metro_sys_top.sv`, always in `tb_metro_vdp_top.sv`).  Candidates the overlay can separate:
the plane starved at the lowest priority of the video chip's graphics arbiter (renderer > CPU window > blitter > plane), request latency on the real memory far above the bench's 12 - 21 clocks, extreme zoom-out
rows (cost ~ distinct tile rows in a row x request latency; the engine has one request outstanding), the sound board's memory use.  Also noted: Quartus 17.0 mis-synthesized 2-D unpacked arrays in this video
chip once (comment at the kick FIFO); the new code uses flat packed vectors.

**Blazing Tornado's sound: cause found (the next build, 20261011d, has the fix).**  Lock-step against MAME (`work/bt/snd2`): the Z80's YM2610 write sequence is identical for 19.5587 s, then MAME writes
an ADPCM-A key-off (reg 0 = 0x81 ..) that the core's Z80 never does.  `ymlog_s.lua` (the status port read back after every write): **MAME's YM2610 (ymfm) sets the ADPCM-B end-of-sample flag, status port 2 bit 7,
at the write of reg 0x10 = 0x01 (RESET) to a PLAYING channel** (`10=80` start, later `10=01` reset: `S2 20 -> a0` at that very write; a reset of a channel that was stopped sets nothing); the driver
polls bit 7 and then runs its end-of-sample bookkeeping (ADPCM-A key-offs, flag clears with reg 0x1C, the next sample).  jt10 only sets the flag when the address reaches the end address, so the driver
never saw the end of the ADPCM-B samples it had reset and its channel bookkeeping drifted from the first reset on.  Fix `modules/jt10/jt10_adpcmb_cnt.v`: `if (clr && chon) set_flag <= 1`.  Bench
(`work/bt/snd2/run_ym5.sh`, 21 s): the write sequence equals MAME's over **all 14,556 writes** (before: 8,588) and the status port 2 changes (20, a0, 20, a0 ... 21, a1, 21) match in order up to 20.9 s.
Not yet checked: past 21 s (the 70 s session), the audio itself next to MAME's (levels equal, correlation 0.75 - 0.98 by section, as before).

**The SDRAM "violations" of that bench are an artifact of the checker, not of the controller** (tRP 47,855 and tRFC 12 in the 21 s run; 0 in the 20 s run before the jt10 fix): `sim/sdram_model.sv` kept its
clock count in a 32 bit `int`, which wraps at 2^31 clocks = 22.4 s of simulated time (the 21 s of sound plus the 1.2 s download); every check made after the wrap fails (`SDRCHK t=-2147483613`).
The counts are `longint` now.  Runs of more than ~21 s before that fix had meaningless check results.

**The Z80's program fetches were 0.85 million words a second (build 20261011d).**  `ZR reads` in the sound bench (`tb_sndf_top.sv`): Blazing Tornado's sound driver with the 8-word code cache fetched
3,409,823 words from the SDRAM in 4 s of its session (~6 % of the memory's time, at a priority above the graphics stream, next to the 68000's ROM fetches and the samples); a 512-word direct-mapped cache
(`metro_sndf.sv`, MLABs, tags cleared by a sweep while the board is held in reset) fetches **45,806** (74 times fewer) and the Z80's write sequence to the YM2610 is identical (1,478 writes, `work/bt/snd2/run_ymA.sh
old|new 4`).  Whether this matters for the picture on the real machine is for the overlay to show (rows 4, 6, B).

**Build 20261011d (released 2026-10-11 08:30, `metrof64_20261011d`)**: 20261011c + the jt10 fix + the 512-word Z80 cache.  Lock-step (jt10 fix with the first, asynchronous-read version of the cache, killed
at 23.5 s): **25,459 of 25,459 writes equal MAME's** (`work/bt/snd2/ym_rtl8.txt`; the Z80's time lags MAME's by 3.5 ms about every 2 s: 10 ms at 23 s).  The first fit of that version failed timing (setup
-0.649 ns, 43,325 registers): Quartus 17 reports "RAM logic is uninferred due to unsupported read-during-write behavior" for an array read asynchronously next to a write and builds flip-flops; the
released version reads through registers (`c_idx_q`, `c_tq`, `c_dq`, a two clock hold after a fill) and fits as MLABs: setup +0.405 ns, hold +0.247 ns, 23,221 ALMs.  Open: the overlay's numbers from the
real machine, the user's report on the sound; a 46 s lock-step of the released RTL; the main core's SDRAM hardening build; `metrof` (F32) rebuild.

## Hardware test of metrof64_20261011d with the Debug overlay (2026-10-11 afternoon): the brown fill is a plane that is too slow for a turned pitch; build 20261011e

**Report (+ ten photos, `work/fb5/zip8`):** Blazing Tornado: the noise between the music is still there (the ring announcer's "and then in the right corner ...", then a screech, then the crowd cheers
clear); with "Sound board: Off" the black planes were gone.  Grand Striker 2: none of the three new switches changed anything; the brown fill comes after the user's own goal, when the new screen where
play restarts loads (the goal scene and the scorer's celebration are perfect; the opponent's goal gives no fill).

**The overlay numbers of the brown fill (GS2, `IMG_7991 / 7992`):** stale lines 217 of 224 (first 7, last 223), 148 frames; plane rows done 37 (normal play: 230 = 224 + the 6 rows of lead); the
plane's request latency normal (17 - 21 clocks mean, 79 max: **the memory is not slow**); line fetches 10,838 a frame = **~293 distinct tile rows in one picture row** (the longest 303 of 304 dots);
the walker waited for a free slot 90 % of the frame; the renderer waited for the plane 94 %; the kick FIFO full, 6,438 kicks dropped; zoom words: row 0 `lw2 = 0, lw3 = 0xEB4E`, rows 120 / 220
`lw2 = 0x05C6 / 0x038C, lw3 = 0` (the normal pitch has `lw2 != 0, lw3 = 0` in every row).

**Reproduced in the simulation, found in the MAME session `work/gs2r` (`rozscan.lua`, 11,647 samples of a played Grand Striker 2 session, `rozscan.txt`):** 4,570 samples of the line RAM are
'y' (`lw2 = 0, lw3 != 0` in every row: the pitch turned a quarter), 1,700 are mixed (rows that have been rewritten and rows that have not: the game switches between the two modes over a few
frames), 5,363 'x'.  The plane engine v2 on 'y' frames (`work/gs2r/st/g.9524 / 10000 / 12120`): **7,500 - 10,000 clocks a row** in the unit bench (12 clocks of memory latency), and in the whole
video chip bench (`work/gs2r/run_win_gp.sh 9524 070b 12`): rows done 29, stale 224, kick wait 24,677 x 64, 408 kicks dropped, 303 lines in the longest row, the walker's slot wait 23,285 x 64:
**the overlay of the hardware to the digit**.  Why a count of rows: a turned plane misses on every dot (a picture row has ~130 different {tile, row in the tile} lines; v2 held 32); 300 requests of
~33 clocks is 10,000 clocks against the line's 6,272, so from the second row on every row is late: the background pen.  And a second bug made it permanent: the plane's pace was `rows_used + 6` with
`rows_used` a COUNT of the rows the renderer had started; after the kick FIFO overflowed and dropped kicks, the kicks that were left named rows far ahead of the count, the plane stopped six rows
after it and the renderer waited for rows the plane would not make until the next frame (29 rows done instead of ~153 at full tilt).

**Fixes (build 20261011e):** (1) `metro_vdp.sv`: the plane runs up to six rows ahead of the row the renderer WANTS (the head of the kick FIFO), not of a count.  (2) `metro_roz.sv` v3: a line
cache (256 groups of two rows (GS2) / four rows (BT) of the tile ROM) and a map cache (64 windows of 32 words, dropped by the 68000's map writes) and a walker that draws a dot in 4 clocks;
the turned pitch costs ~1,970 clocks a row.  **0 of 68,096 dots differ from the reference on 12 + 4 Grand Striker 2 frames (normal and turned) and 8 Blazing Tornado frames**, the whole video chip
(game window 11) on the turned frames: stale 0, rows done 240, no kick dropped, the picture within 1 - 3 % of MAME's pixels (sprite buffering), frame 3000 identical to v2's.

**Blazing Tornado (not solved by the above alone):** the overlay of the black planes (`IMG_7993 / 7994`, in play `7995`): the same dead plane (rows done 33, 13,366 kicks dropped), but with
**the plane's request latency 160 - 190 clocks on average, 800 at most** (Grand Striker 2: 21) and the renderer's longest line 12,600 clocks; the user's observation that the board off removes it
says the sound board's memory traffic is what tips it.  What the sound board asks of the SDRAM was measured in the bench: the Z80's code fetches (0.85 million words a second with the 8-word
cache; 74 times fewer with the 512-word cache of 20261011d), the samples (one read per slot of the YM2610's address bus when the address changes).  v3 asks the memory for ~3,200 groups of 32 bytes a
frame instead of 8,100 rows of 8 bytes in Blazing Tornado's fights (and a pace that cannot stall); whether that is enough at 160 clocks of latency is for the overlay of the next test.

**Build 20261011e (released 2026-10-11 15:27, `metrof64_20261011e`):** all clocks met at 96 MHz: machine clock setup +0.727 ns / hold +0.250, HDMI PLL +0.397 / +0.237 (seed 1), 26,633 ALMs (64 %,
20261011d: 23,221), 31,531 registers, block RAM 553 / 553; the fit took 1 h 52 min (three simulations ran beside it).  Whole machine in the simulation (`work/gs2r/run_w3.sh`, 501 frames of the
Grand Striker 2 attract with the real SDRAM path): the picture complete at frames 480 / 500, SDRAM checker 15,987,530 activations, 0 violations.  Blazing Tornado whole machine with the sound
board (`work/btw/run_btw.sh`) does ~4 frames a minute: stopped at frame 229 (attract start: 0 stale, 240 rows done, memory 1.5 % busy), it does not reach a fight.  The build id the OSD shows
is the date only (`sys/build_id.tcl` rewrites `build_id.v` at every compile, so the letters named in the notes of c / d were never displayed); the build directory of f patches the script.

**The YM2610's sample port reads the memory ten times more than needed (found 2026-10-11 with the 24 s bench, `work/bt/snd2/run_ym9.sh`):** `OKI reads` 23,036,796 in 24 s = 960,000 a second;
the samples need ADPCM-A 6 channels x 9.26 kB/s + ADPCM-B <= 28 kB/s.  `metro_ympcm` read a byte whenever the port's address differed from the last served one; the six ADPCM-A channels take the
bus in turn (one per 1.5 us slot, each with its own address), so the address changes at every slot, though a channel moves to another byte only every second turn.  At a priority above the
graphics that is ~8 % of the controller's time.  Fix (build 20261011f): an 8-entry FIFO cache of A's bytes by address (cleared in reset); expected reads ~60,000 a second.  The Z80's reads in the
same bench: 641,874 in 24 s (27,000 a second, with the 512-word cache).  Audio of the first 24 s against MAME's (`snd2/mame.wav`, `rtl_ym9.wav`, 0.1 s windows): the level ratio 0.92 - 1.06; the
old core (`rtl.wav`) is 2 - 3 times too loud from 46 s on (the fight of the session) -- the 70 s run of the new core (`run_ym10.sh`) is the real test.

**Build 20261011f (released 2026-10-11 16:40, `metrof64_20261011f`)** = e + the ADPCM-A byte cache: `OKI reads` in the same 8 s of the session 2,427,405 -> 76,037; the controller's accounting
(`SDST` lines of `tb_sndf_top.sv`, `work/bt/snd2/run_st.sh`): busy 2,241 x 64 clocks per 21.8 ms (6.8 %, 19,420 reads of 7.4 clocks each) -> 421 x 64 (1.3 %); the YM log and the 864,000 audio samples
are identical to the build without the cache.  Timing met: machine clock +0.304 / hold +0.225, HDMI +0.174 / +0.225, 27,462 ALMs (66 %), 31,994 registers, DSP 64 (the cache's `c_wp * 22` index
took a multiplier; harmless), the fit 1 h 11 min.  The build id carries the letter (`build_fbt11/sys/build_id.tcl`: only writes `build_id.v` when it is empty).

**Blazing Tornado's gfx-latency cliff (2026-10-11, `work/bt/run_vl2.sh 1800 12 40 80 120`, e's RTL, frame 1800 of the session, heavy sprites):** gfx latency 12: stale 0, renderer longest line 3,533 clocks,
busy 41 %; 40: 0, 5,464, 61 %; 80: 133 stale, 8,223, 83 %; 120: 215 stale (172 lines shown), 10,983, 88 %; 170 (`run_vl.sh`): 222 stale, 14,433.  Hardware (IMG_7993 - 7996): normal play stale 0, the
renderer's longest line 6,393, the plane's latency mean ~75 clocks (latsum64 x 64 / (line misses + windows)), 508 at most; black frame: longest line 11,229, latency mean ~161.  The whole-machine
Blazing Tornado run (`work/btw`, real SDRAM + sound board) manages 4 frames a minute: it does not reach a fight (stopped at frame 229).

**ROOT CAUSE of Blazing Tornado's noise and black planes (2026-10-11 17:50, found with the 70 s bench of build f, `work/bt/snd2/run_ym10.sh`, `env_cmp.py`):** `metro_sdram.sv` held the OKI client's
served / in-flight address in 22 bits (`oki_served`, `oki_fly`) while the YM2610 port presents 23 (`metro_ympcm`: ADPCM-A at +2 MB of the region, up to 6 MB).  Blazing Tornado's ADPCM-A ROM is 4 MB and
its announcer / crowd samples sit at the top (`A 0x3DB400 - 0x3E18FF`, key-on at 42.47 s of the session): a request with bit 22 set never equals the truncated served address, so `o_oki_ok` stays low
(the chip never gets the byte: silence, or the byte before it repeated = the screech) and `oki_want` stays true: the byte is re-read back to back, at a priority above the graphics (the grant takes the
sample client before the gfx stream; the gfx stream gets every other slot at best).  Evidence: OKI reads in the 70 s bench 310,891,943 (24 s: 23,036,796; the 46 s after the first high sample: 288 M =
6.3 M a second = one read every 15 clocks, the controller 100 % busy); the audio silent at 42.5 - 45.5 s where MAME plays the announcer, 2 - 5 times too loud from 47 s on; the Z80's write rate per
second equal to MAME's (7,618 / 7,618 at 32 s) so the driver was fine.  The gfx latency of 160 - 190 clocks, the black planes only with the sound board on, the 12,600-clock renderer lines: all this.
Grand Striker 2's samples fit in 4 MB (no bit 22).  Fix (build 20261011g): `oki_served` / `oki_fly` 23 bits.  The build 20261011a - f all have it.
**Build 20261011g (released 2026-10-11 18:50, `metrof64_20261011g`)** = f + the 23-bit fix.  Timing met: machine clock +0.048 / hold +0.150, HDMI +0.449 / +0.177, 27,254 ALMs (65 %), 31,906 registers, fit 34 min.
Bench `work/bt/snd2/run_ym12.sh 52` (`rtl_ym12.wav` vs `mame.wav`, 0.5 s RMS windows): the announcer at 42.5 s and 45 - 46 s plays (0.91 - 0.99 of MAME's; f: 0.02 / 0.01), from 47 s 0.85 - 0.94
(f: up to 4.4), 18 loud windows from 41 s median 0.93 (f 0.77); SDST max 5,112 sample reads per 21.8 ms window (was ~140,000), controller 3 % busy; 4.47 M sample reads in 52 s; 0 SDRAM violations.
The bench's Z80 lags MAME's by ~14 ms at 26 s (program fetch waits: MAME's has none), so the write sequence is equal only to 25.8 s (37,575 writes) and equal in rate after.  Not on hardware.

## Hardware test of metrof64_20261011g (2026-10-11 evening): Blazing Tornado fixed; two videos (`work/fb6`, `IMG_8087` / `IMG_8088`)

**Report:** all the noise / black-plane problems of Blazing Tornado are gone on the board (the 22-bit OKI address bug).  New: a flickering band in Blazing Tornado's continue screen; Grand
Striker 2: the brown fills are gone, specks around the title's INSERT COIN and the P2 sign remain, and one flat yellow screen after winning.

**Blazing Tornado's continue band** (replay of MAME's own writes, `work/bt/cont`, `rzwr.lua` + `mkreplay.py` + `run_replay.sh`): the crowd is drawn by the tile layers, not the plane.  Every
4th frame the game rewrites the tile table (362 words, lines 25 - 84 after 224) and both tile maps (vram1 1812 words, lines 28 - 138; vram2 1792 words, lines 84 - 137), a burst that begins
before the picture and runs ~90 lines into it; the band is where the beam crosses the rewrite (new table, old map).  MAME draws the frame after the burst.  The replay shows it with MAME's
exact write times, so a chip that reads RAM live shows it too.  Tried: a tile table snapshot for the I4220 boards (frame 29: 36,105 px off MAME instead of 11,110: worse, reverted); a faster
68000 (event times x 0.5 / 0.7: the whole picture breaks: the game depends on the order of its writes).  Kept: posted writes to the map RAM (`metro_main.sv`: the 68000's map writes end at
once, a 16-deep queue drains to the SDRAM; a whole-machine Blazing Tornado run of 111 frames: frame 110 identical, the map clear 5 % faster).

**Grand Striker 2's specks:** the title rewrites 180 words of vram0 at chip lines ~12 - 18 (picture rows 1 - 7); with the game's writes 30 % later than MAME's the replay shows a 4-pixel green
dash at row 3 (`work/gs2r/tt`).  The dashed streaks in the top rows of the post-win scene are in MAME's own picture (the plane's far rows), not a core artefact.

**The flat yellow screen after a win is the game's own** (MAME driven to a win: the score bytes are 0xF08B6F (left team) and 0xF08BAF (right team); poking 3 into the left one gives
"WIN 3 - 1", `work/gs2r/gswin2.lua`, `gswin4.lua`): the tilted stadium strip on a flat colour, 24 frames, between a black period and the ball.  MAME's colours: flat (198,132,33); the video's
(232,200,48) = the same through a power curve of ~0.37 on R and G (camera auto exposure after the dark period: the first 6 frames of the scene are white, then 6 frames of settling).
The core's timeline equals MAME's: black 20 / 23 frames, strip scene 24 / 24 frames (MAME 21795 - 21818, video 498 - 521), the ball's fade-in from black alike; the 100,000 map words of the
scene load inside the black period on the board as in MAME.  The replay of MAME's writes shows the palette arriving in one frame (no slow fade in the VDP).  "Slow palette fade" = not found.

## Family C: Mouse Shooter GoGo, Bal Cube, Daitoride (YMF278B), Bang Bang Ball, Battle Bubble, and the 64 MB build of Mahjong Gakuensai 1 / 2 (2026-10-12, builds 20261012b / c; simulation only)

**Games.**  `msgogo` (board 22), `balcube` (23), `daitorida` (24), `bangball` (25), `batlbubl` (26, build c): 68000 at 16 MHz, I4220, YMF278B (OPL4) on the 68000's bus; map and interrupts in `docs/hardware.md` section 16.
`bangball` has no periodic interrupt: a scanline timer sets the video chip's cause 1 on every visible line while its mask bit 1 is clear and cause 4 + vblank at line 224 (MAME's `bangball_scanline`
= the model Puzzli already had here: `i_scan_irq`), and MAME runs it at 60 Hz (the core: 58.2).  `batlbubl` is the same board with a 1 MB program (Varia Metal's image layout: the program after the 8 MB of graphics, then the wave ROM; its own input order IN1 / DSW0 / IN0 / IN2 at 0x200000).
Not done: `puzzlet` / `metabee` (do not run in MAME 0.289), `poittoc` (a ROM is missing from the user's set).  Mahjong Gakuensai 1 / 2 are in the same core file (`metrod64`, 64 MB addressing, no ROZ plane).

**Chip.**  srg320's YMF278B PCM engine (`rtl/ymf278b.sv`, from Arcade-PsikyoSH2_MiSTer) did not play MAME's sound at first.  Method: ymfm (MAME 0.289's code, BSD) driven by the writes MAME made in 30 s of Bal
Cube (`work/gk/ymflog_balcube.txt`, `work/ymfm_ref/drv.cpp`; `drv_dbg.cpp` prints one channel's state per sample) against the engine in the Verilator bench (`sim/run_ymf.sh`), **one voice at a time**
(`work/gk/filter_ch.py` keeps the PCM writes of listed channels and all FM-port writes; without the FM writes NEW2 never gets set and the PCM registers are dead).  Findings, each by a mismatch of a single
voice: (1) the total-level fade ran away from its target (wrapping the 7 bits) whenever the game's level-direct bit is 0 (always, in Bal Cube); (2) output level 1.0 of the wave instead of ymfm's
8168/32768; (3) the 12-bit sample's nibbles in the other order; (4) pan 0xA .. 0xF one step short; (5) wave numbers from 384 up read their header at the wave header bank (reg 0x02 bits 4:2 x 512 KB),
Bal Cube plays 406 - 410; (6) the header's LFO / rate / AM bytes, loaded 7 - 11 samples after the wave number write, overwrote what the game had written right after the wave number (MAME loads
the header AT the write: `LD_OVR`); (7) a register write that met a header load of another slot in OP3 was dropped (now retried); (8) the wave RAMs were M10K (MLAB now, the M10K blocks are
all used).  After this one voice is within 1 - 3 % RMS of ymfm, the whole 3 s mix within 5 - 20 % per 100 ms (before: 3 x too loud).  The rest: Bal Cube's driver writes key-off, TL, pitch,
key-on 15 us apart on a playing channel; ymfm (as MAME) merges the pair when both writes fall into one 22.7 us sample bucket (34 %), the chip re-triggers when its slot visit falls between.

**Whole machine** (`work/gk/run_c.sh <game> <tag> [frames]`, real SDRAM path, MAME dumps `bc.* mg.* dt.*` with coin at frame 120 / start 220 as the bench does):
* Bal Cube frame 150 / 300: all memories and registers equal MAME's (vram0 12 / 65,536 words differ at 300: text animating); Mouse Shooter GoGo frame 150: palette 4 / 4,096 words, frame 300 equal; Daitoride
  frame 150 equal, frame 300 equal except one scroll register (6 pixels: an animation 1 - 2 frames apart); Bang Bang Ball frame 150: vram0 57 words, 300: palette 93 / 4,096 and 2 sprite words (MAME's 60 Hz
  against the core's 58.2: MAME frame N is 3 % earlier in time); Battle Bubble frame 150 equal, 300 the same 93 palette + 2 sprite words.
* The 68000's writes to the chip: Mouse Shooter GoGo's first 926 writes are the same bytes in the same order as MAME's (`work/gk/c_msgogo_a.ymflog.txt`, `ymflog_msgogo.txt`); the game starts 0.27 s later
  than MAME (the 68000 gets 77 - 94 % of its bus cycles through the SDRAM program path, as on the other boards).

* Bal Cube's own notes (`work/gk/run_cx.sh balcube L 1000 '' balcube_ymf.bin`, final RTL, 1,000 frames): the first key-on is at 16.0 s (MAME 12.1 s: the game runs 32 % slower, the 68000 gets
  its bus cycles through the SDRAM program path), **every one of 1,198,712 wave ROM bytes the engine sampled equals the ROM** (`+YMFCHK`), and aligned on the first key-on the output equals MAME's
  recording within 1 - 5 % RMS per 200 ms (correlation 0.75 - 0.86 at lags of 6 - 36 samples).

**Bugs the sound check found** (the first whole-machine audio of Mouse Shooter GoGo was silent for the first 3.4 s, then noise of the right level): the **loader's init permutation** (`metro_loader.sv`, `GFX_END`
fixed at the 4 MB slot end) ran over the wave ROM of a 2 MB-graphics set, bit-reversing every even byte of Mouse Shooter GoGo's and Daitoride's wave ROM (Bal Cube has 4 MB of graphics: untouched).  Found with
`+YMFCHK` (the testbench compares every byte the engine samples with the ROM file: 126 of 292 differed, all even addresses, all bit-reversed).  The permutation now ends at the GFX size of the header.
Also changed for the chip: the SDRAM OKI client keeps the whole 16-bit word and answers both of its bytes (the engine reads a, a+1, a, a+1 for every voice and sample: four accesses became one), and the
wrapper holds WR_N / RD_N until the engine has had four enables with them low (the enable is held back while a byte is awaited; the old 24-clock pulse could pass between two enables, and while a write
was presented the hold was released: a byte not yet arrived was sampled).

## Frame-synchronous tile RAM, build 20261012a (2026-10-12): the continue band and the title dashes

**Why.**  The renderer reads the three tile layers and the tile table live, a line at a time.  A game that rewrites them while the beam is drawing (Blazing Tornado's continue screen:
3,980 words every 4th frame, one word per ~180 clocks, a band where the beam crosses the rewrite; Grand Striker 2's title: 180 words of vram0 in picture rows 1 - 7) shows a mix of two
states on this chip; MAME draws once, at the end of the frame.  The sprite list, the scroll / window registers and the palette were already copied at one instant; the layer RAM was
the part that was still live (`work/bt/cont`: the replay of MAME's own writes reproduces the band, so it is not a timing error of this core).

**What.**  `metro_vdp.sv` `P_VLOG` (F builds: `F_VLOG` in `Metro.qsf`; OSD "Tile RAM frame sync" On / Off): the 68000's writes to vram0/1/2 (also through the 0x75000 window) and the
tile table go to a log instead of the RAM; the log is applied (two clocks a slot, a run one word a clock) after the sprite list copy instant (`spr_copy_line`, line 235 with the game's
window) once the renderer is done with the frame (kick FIFO holds nothing of it, renderer idle); `dl_line` (3 lines before the first displayed line is kicked) is the deadline.  A frame is
then drawn from one state and the picture shows the writes of the frame before, as the sprites do (one frame later than the live RAM: replay offset -2 instead of -1 against MAME's frames).
* Log format: 20-bit slots ADDR (layer, word address) / DATA (word, byte enables) / RUN (n words, each the same as the word before or +1: tile codes counting up, fills); 4,096 slots in
  MLABs (the M10K blocks are all used: 553 / 553; an 8,192 x 20 log in M10K needed 16 more and the fit failed with error 170048).  The largest bursts of MAME's traces: Blazing Tornado's
  continue screen 3,980 words = 4,051 slots with ADDR / DATA only, **871 with runs**; Grand Striker 2's winning scene 6,294 words = 6,442 slots, **434 with runs**.
* The 68000 sees the RAM as if the writes had been made: **a read of the layer RAM is answered from the RAM and the log** (a scan of the log from the apply pointer, the words in the order
  they were written, merged over the RAM's word by byte lanes: `S_ISSUE / S_DEC`, `ovl_val / ovl_m` in the bus FSM's read state).  The first version drained the log before every read: the
  whole-machine Grand Striker 2 run showed the game reading the layer RAM 15 or more times in every frame of its select / play screens, which would have made every such frame a live one.
* A write to a full log waits while the whole log is applied (that frame is drawn as before).  The blitter (not used by family F) starts after the log is empty and writes directly.
* Timing: the first fit (log with the 68000's access gated by the pointer compare) missed 96 MHz by 0.137 ns (path `lg_rp` -> `lg_used` -> `lg_hold` -> VRAM write enable); the access
  flags are registered now (`mode_q`, `quiet_q`, `full_q`, `dir_ok`) and the write port A sources other than the 68000 (the log being applied, the blitter) are merged from registers first,
  so the 68000's path to the RAM is as short as in 20261011g.
* Telemetry: overlay row 5, column C = `{reads answered through the log, writes that found it full, frames applied at the deadline, largest occupancy / 256}`, running totals since reset
  (F = 15 or more).

**Verified in simulation.**
* Replay of MAME's writes into the whole video chip + plane (`work/bt/cont/run_vl.sh`, `minoff.py`; a picture counts as torn when it equals none of MAME's frames n-4 .. n+1 within 3,000 px
  of the 1,960 px baseline of the 11 rows the CRTC window hides): live RAM 10 torn pictures of 115 (6,800 - 11,300 px off, frames 29, 37, 49, 61 ...: every 4th, as in the video); the log:
  **0 torn**, every picture equal to a MAME frame within the baseline (the log's pictures match MAME's frame n-2 where the live ones match n-1).  The log with runs gives byte-identical
  pictures to the log without them and to the final design (140 / 140 pictures of the continue screen, 100 / 100 of the title, 90 / 90 of the winning scene).
* Whole machine, Grand Striker 2, real SDRAM path (`work/gs2r/run_wm.sh`, `VLOG_CHECK=1`: a mirror of the layer RAM as the 68000 sees it, every read compared with it): 260 frames
  (coin 120, start 170, through the select screens into play), **7,676 reads checked, 0 mismatches**; 0 writes found the log full, 0 frames applied at the deadline, largest occupancy
  2,048 - 2,303 slots; 0 SDRAM timing violations.
* Grand Striker 2's title and winning scene against MAME: the same as the live chip beyond the one frame (`work/gs2r/tt`, `wrz`).

**Not verified.**  Anything on the board.  Not reproduced in simulation: the title's green dashes (the replay shows them only for some write timings of the game and the live chip did
not show them with 1.15 / 1.3 / 1.5 x times either, so the title cannot be a test of this change).  Not changed: the 053936 plane's own RAM (map RAM in the SDRAM, line RAM, control
block) is still read live; a burst that is not finished when the copy instant arrives (a game slower than one frame) is drawn in two steps, each consistent.
* Timing / fit (build 20261012a, `work/build_fbt13`, seed 1): setup **+0.378 ns**, hold +0.218 ns, 29,858 ALMs, 553 / 553 RAM blocks, 64 DSPs.  The first fit missed by 0.407 ns on the path
  loader `cfg[0]` (board id, static) -> `i_board == 18` compare -> the ROZ line RAM's address mux (2,048 loads: the RAM is in MLABs because all M10K blocks are used) -> `dataout_reg`;
  `bt_r`, `early_r`, `scan_r`, `ext5_r`, `tdx_r`, `tdx1_r` (board flags of the chip and the plane) are registers in `metro_main.sv` now.  The release's sources: `work/release_f_src_20261012a`.
  `Metro.sdc` of the dev trees also has `set_false_path -from emu|u_loader|cfg[*][*]` (image header bytes: static during a run); the 20261012a fit did not need it.


### Hardware result of `metrof64_20261012a` (2026-10-12, the user)
Blazing Tornado (continue screen) and Grand Striker 2 (title dashes) are fixed on the board: the frame-synchronous tile RAM removed the tearing. No regressions reported.

## Hardware results of `metrod64_20261012c` (2026-10-12, the user, 64 MB board)
* Mouse Shooter GoGo, Bal Cube (Japan), Daitoride (YMF278B version), Bang Bang Ball (v1.05), Battle Bubble (v2.00), Mahjong Gakuensai (set 2): work, sound good. Daitoride's YMF278B version does not show the cliff-line tear of the other Daitoride set (this build has no frame-synchronous tile RAM: the cause is not the frame sync).
* Open: Mouse Shooter GoGo has small quirks (to be described), Mahjong Gakuensai set 1 and Gakuensai 2 have a few small graphical glitches (parked by the user), Gakuensai EEPROM save, 60 Hz for bangball / batlbubl.

## Disassembly (MAME's `unidasm.exe`, in `C:\repos\taitol-mister\mister\tools\mame\`)

`unidasm.exe <file.bin> -arch m68000 -basepc 0 -skip <offset> -count <bytes>`; with `-skip` the printed addresses restart at 0, so add the skip
offset. Dump regions first (`regions.lua`). **`-arch upd7810` is supported**, so the sound CPU's 128 KB program can be disassembled the same way when
the 78C10 work starts. Output used for `docs/hardware.md` section 4a (`work/dharma_main.asm`).

## Release 20261013a: the family F and family D / C trees merged, three core files (2026-10-13)

**What.**  Until 2026-10-12 the work lived in three trees: the main tree (the 32 MB core, 20261010c), the family F tree (Blazing Tornado, Grand Striker 2, frame-synchronous tile
RAM) and the family D / C tree (Mahjong Gakuensai, Mouse Shooter GoGo and the YMF278B games, 64 MB).  They are one source tree now, with three Quartus revisions
(`Metro.qsf` = `metro`, `Metro_D64.qsf` = `metrod64`, `Metro_F64.qsf` = `metrof64`, derived by `tools/make_revisions.py`).  The device cannot hold everything: a fit of all families in one
core needed 48,811 ALMs, 116 % of the 41,910 (`work/build_all`, 2026-10-12; 110 % without the frame-synchronous log).

**Build switches** (`VERILOG_MACRO`): `D_BUILD` (no 053936 plane, no Z80 / YM2610 board), `F_BUILD` (no uPD78C10 board, ES8712 or OKI sound board), `F64` (64 MB addressing),
`F_VLOG` (family F's frame-synchronous tile RAM), `NO_YMF` (no YMF278B), `METRO_DEBUG` (the hardware test switches in the OSD), `F_POSTW` (posted writes to the plane's map RAM, off).

| Core file | Macros | Seed | Setup (96 MHz) | Hold | HDMI clock setup | ALMs | RAM blocks | DSP |
|---|---|---|---|---|---|---|---|---|
| `metro_20261013a` | `D_BUILD NO_YMF` | 4 | **+0.175 ns** | +0.245 ns | +0.686 ns | 29,665 (71 %) | 548 / 553 | 59 |
| `metrod64_20261013a` | `D_BUILD F64` | 3 | **+0.125 ns** | +0.245 ns | +0.355 ns | 30,617 (73 %) | 549 / 553 | 66 |
| `metrof64_20261013a` | `F_BUILD F64 F_VLOG NO_YMF` | 1 | **+0.363 ns** | +0.235 ns | +0.350 ns | 29,429 (70 %) | 553 / 553 | 64 |

Every first fit met timing (no seed sweep); the wall time of a fit was 2 - 3 hours with the three running side by side.  Build id `261013a` (OSD, last line).

**Merge rules.**  The D tree was the base (it had the family F sources too).  Added from the F tree: the log's read-address pipeline (`ra_q`, `S_WAIT` / `A_WAIT`: the fix of the
20261012a fit) in `metro_vdp.sv`, and the registered board flags (`bt_r`, `early_r`, `scan_r`, `ext5_r`, `tdx_r`, `tdx1_r`) in `metro_main.sv`.  Kept out of the F build exactly as released:
the YMF278B (`NO_YMF`), the YMF word client of the SDRAM's OKI port (the byte client stays under `F_BUILD`), and the **posted map writes** that were in the dev tree but not in
20261012a (`F_POSTW`, off).  The two checks: (1) a preprocessor-aware line diff of the RTL (`work/merge_tools/ppdiff.py`): the merged tree with `F_BUILD F64 F_VLOG` against the
20261012a sources differs only by the family C / Gakuensai additions that are inert in family F (board table entries, the YMF278B bus port, `i_tick_slow`, the loader's GFX end,
`mid13`, `i_ym_hi`); with `D_BUILD F64` against the 20261012c sources only by the registered flags (the log is not built there); (2) the whole-machine regression below.

**OSD.**  The six hardware test switches (SDRAM read capture, Debug overlay, Plane fetch priority, CPU sprite write hold, Sound board, Tile RAM frame sync) are behind
`METRO_DEBUG`; a release build has each at the tested setting, with the overlay logic not built.  An OSD setting saved by an older build for those bits is ignored.

**Regression: the main tree (20261010c sources) against the merged tree built as the 32 MB core** (Verilator, the games' images through the SDRAM model; frame, picture, VDP memory
dump, registers and sprite list compared byte for byte):

```
game        coin / start  dumped frames  picture  tile RAMs (hex)  registers  sprite list
dharma      120 / 160     100, 250       same     same             same       same
toride2g    120 / 160     100, 250       same     same             same       same
pururun     120 / 160     100, 250       same     same             same       same
daitorid     60 /  90     100, 180       same     same             same       same
puzzli       60 /  90     100, 180       same     same             same       same
karatour     60 /  90     100, 180       same     same             same       same
pangpoms     60 /  90     100, 180       same     same             same       same
skyalert     60 /  90     100, 180       same     same             same       same
lastfort     60 /  90     100, 180       same     same             same       same
poitto       60 /  90     100, 180       same     same             same       same
3kokushi     60 /  90     100, 180       same     same             same       same
dokyusei     60 /  90     100, 180       same     same             same       same
dokyusp      60 /  90     100, 180       same     same             same       same
mouja        60 /  90     100, 180       same     same             same       same
gunmast      60 /  90     100, 180       same     same             same       same
ladykill     60 /  90     100, 180       same     same             same       same
16 games, 0 differences.  **What the frames show:** Dharma, Toride II, Pururun, The Karate Tournament, Sankokushi, Doukyuusei Special and Lady Killer are in their title / attract / play
screens; for the other nine (Daitoride, Puzzli, Pang Pom's, Sky Alert, Last Fortress, Poitto!, Doukyuusei, Mouja, Gun Master) frames 100 and 180 are still the ROM / RAM test, so for
them this covers the boot and the test screens only (a self-test takes several seconds of machine time; a run to the title takes 3 - 4 times the frames and hours of simulation).
The other sets are clones of these boards; Varia Metal had no image at hand.
```

Also in this release: `tools/make_mra.py` names `metrof64` for Grand Striker 2 (the dev trees named the unbuilt `metrof`); one `tools/package.py` writes the zip of all three.

**To test on a board** (the binaries are new builds of the merged sources: what changed against the hardware-tested ones is the registered flags, the removed OSD entries and the
merged-in tree, not the games' logic): one game of each core: `metro` an older game (Dharma, Puzzli, Doukyuusei, Varia Metal), `metrod64` Mouse Shooter GoGo or Bal Cube,
`metrof64` Blazing Tornado (the continue screen) or Grand Striker 2 (the title).

## Release 20261014a: the blit queue of the I4300 boards (2026-10-14; `metro` and `metrod64` only, simulation only)

**Why.**  The hardware videos of 2026-10-13 (flashing lines at the third girl of Mahjong Gakuensai, flashing blocks on every girl of Gakuensai 2) were first put down to the 68000
being slow on the SDRAM path.  That was wrong: the whole-machine simulation with a write log (`+VDPWLOG`, `work/gk/an_wl.py`) puts the core's palette rewrite of the logo fade at
694 + 74 writes in two frames against MAME's 696 + 72 (0.3 %); ROM reads wait 2 clocks on average and 99.9 % finish within 8 (the "quarter slower" figure of 20261012 was bus
utilisation, not speed).

**What it is.**  The games start *groups* of blits: Gakuensai writes a whole picture's tile map as two blits (the high and the low byte lane of every tile word) and the mouth patch as
two more, one blit every ~8 lines (a software delay: the game never acknowledges the done interrupt, there are no writes to 0x788A2).  MAME runs each blit the moment the trigger
register (0x7884C) is written and renders a frame at line `v_vis`, so a frame holds every blit started before that line, whole.  The core of 20261013a ran a blit at once when it was
started outside the displayed window and held it (plus one queued start, the rest dropped) when it was started inside:

* a group that straddled the first displayed line (blits at lines 255, 0, 8 outside; the fourth at 16 inside) showed the high byte lanes of a new picture over the low lanes of the old one:
  scrambled blocks for one picture, every animation step;
* a group started inside the window (lines 102 - 126) lost its third and fourth blit behind the held one: the mouth patch stayed old or showed wrong tiles for five frames.

**Found with the VDP replay bench** (MAME's own writes at MAME's times, the game's CRTC window, closed-loop blitter; `work/gkrp/`: `run_mame.sh` -> `mkreplay.py` -> `metro_scene.py` ->
`run_rp.sh`, then `cmp.py` against MAME's snapshot of every frame): the replay of Gakuensai frames 3600 - 3700 reproduced the garbled mouth blocks (with MAME's display window, line 0 on, the whole picture is scrambled for one picture: 38,038 pixels); the tile RAM read back after 30
pictures differed from MAME's dump in exactly the 7 words of the dropped patch.  New bench options: `+TALL=1` aligns the replay at line 240, `+BLITLOG` prints every blit,
`+VRAMDUMP=<file>` reads the video memories back through the CPU port (the layout of `tools/lua/vstate.lua`'s `.mem`).

**The change** (`rtl/metro_vdp.sv`, `i_i4300` boards only: Mouja, Doukyuusei, Doukyuusei Special, Gakuensai 1 / 2): an 8-deep blit queue.

* A trigger with a valid tilemap (1 - 3) pushes the three register pairs; the 68000 is not delayed.
* At line `v_vis` (the line of the palette snapshot) the entries present are *released*; they start once the beam has left the picture (lines after `v_vis + crtc_vfirst`) and run in
  order.  A picture therefore shows all the blits of a frame or none, and with the palette that goes with them (the snapshot taken at `v_vis` is swapped in at line
  `v_vis + crtc_vfirst + 4`).  The display is one frame behind MAME for blit and palette alike.
* A 68000 access to the tile RAM while blits are queued, or a trigger with the queue full, runs the queue at once (order kept; that picture may tear as before).
* The done interrupt follows the trigger by 500 us (48,000 clocks), as MAME's `m_blit_done_timer`; a trigger within the 500 us re-arms it.  Before, it followed the blit's end.

Other boards (I4100 / I4220 / family F) are untouched.

**Replays against MAME (pictures that differ from MAME's frame, 20261013a sources -> new)**:

```
game / frames                          pictures   differing before (largest)   after
Gakuensai    3600 - 3700                  100          49 (505 px: the mouth patch)    0
Gakuensai    4000 - 4100                  100           0                              0
Gakuensai 2  3500 - 3600                  100           0                              0
Gakuensai 2  3700 - 4100                  400          15 (19,074 px: a scrambled picture)   0
Doukyuusei Special 4800 - 5000            200          82 (29,015 px: half the picture)    1 (20,179 px: a palette fade frame, 4889; unchanged)
Doukyuusei   3000 - 3200                  200           0                              0
Mouja        4000 - 4200                  200           0                              0
```

Whole machine (committed tree against the new one, hardware CRTC window, the real SDRAM path; picture, tile RAMs, registers and sprite list byte for byte): Gakuensai, Doukyuusei,
Doukyuusei Special and Mouja at frames 110 and 220: identical (the boot screens, so this checks that nothing hangs, not the blit groups).

| Core file | Macros | Seed | Setup (96 MHz) | Hold | HDMI clock setup | ALMs | RAM blocks | DSP |
|---|---|---|---|---|---|---|---|---|
| `metro_20261014a` | `D_BUILD NO_YMF` | 4 | **+0.130 ns** | +0.247 ns | +0.504 ns | 29,731 (71 %) | 548 / 553 | 59 |
| `metrod64_20261014a` | `D_BUILD F64` | 3 | **+0.495 ns** | +0.252 ns | +0.841 ns | 31,031 (74 %) | 549 / 553 | 66 |

`metrof64` is unchanged (it has no I4300 board); `metrof64_20261013a` stays current.  Build id `261014a`.

**Hardware result (the user, 2026-10-14, 64 MB board): the bugs reported for Mahjong Gakuensai 1 / 2 are fixed.**  The release zip `Metro_MiSTer_20261014a.zip` carries the two new
core files and `metrof64_20261013a.rbf` unchanged (its sources differ from the tree only by the queue, which does nothing when `i_i4300` is 0: the plane, the log and the I4220 blitter
paths are as built).

**Mouse Shooter GoGo** (I4220 board, not touched by the queue): replays of MAME's writes at the frames of the heavy scenes (2270 - 2330: >1,700 tile RAM writes a frame in the visible
lines) and of the title (780 - 960) match MAME's frames exactly except for bands of up to ~700 pixels in the top five rows and a 60 x 15 block (frames 2300 - 2325) and a 3 - 4 %
shimmer of the title logo's colours every fourth picture (the palette cycling straddles the snapshot).  The title's scroll-in is exact.  A faster ROM path would not help (see
above).  The whole-machine write log of the title (`work/gk/wl_msgogo_wl.txt`) is to be compared with MAME's for the CPU's timing.

**Tools.**  `tools/lua/vdpwr.lua` (every 68000 write to the video chip with its time) and `tools/mkreplay.py` (events for the bench) are the replay recipe's two halves.

## Release 20261014b: frame-synchronous I4300 boards (2026-10-14; `metro` and `metrod64` only; confirmed on the boards with 20261014d)

**Why.**  Two videos of 2026-10-14 (`IMG_8100` Mahjong Doukyuusei: flashing on the intro; `IMG_8099` Mahjong Gakuensai: flashing on the left of the tutorial's speech bubbles).

**Gakuensai's speech bubbles.**  The tutorial's bubbles are sprites, and the game rewrites the whole sprite list from line ~250 of one frame to line ~46 of the next, while MAME draws
the frame at line 240 with the finished list.  The core copied the list at `crtc_vfirst` of the next frame, in the middle of that rewrite: holes in the bubbles, the HUD icons missing
for a frame.  Replay of MAME frames 6700 - 6900: 20 of 200 pictures off; of the play segment 11700 - 11900: 11 of 200; with the copy at `v_vis`: 0 and 0.

**Doukyuusei's intro** (MAME frames 385 -> 386 and 567 -> 568, `work/gkrp` replay `dk300`).  In the frame of the change the game writes 6,144 same-value words of tile layer 2
(`0x800f`), the 1,024 words of the tile table, two blits, 423 sprite words and, in the vblank, the sprite colour offset (0x79708) and the background pen (0x79712): no palette
writes.  Replays with parts of that frame removed (`work/gkrp/ev_noT/noB/noS/noTB.txt`, `evsum.py`) showed two separate causes:

* the live fill blanks one whole picture (the black flash of the video: the renderer reads the layer RAM line by line while the 68000 fills it);
* the renderer's sprite colour offset, background pen, layer priority, sprite offsets and screen offsets were read live, so a vblank-handler write reached the picture a frame
  before MAME shows it (the figure turned into a black silhouette over the old background).

**The change** (`rtl/metro_vdp.sv`, `i_i4300` boards only: Mouja, Doukyuusei, Doukyuusei Special, Gakuensai 1 / 2):

* the family F frame-synchronous tile RAM (the log, `P_VLOG`) is built into the D builds too (`D_VLOG`, 2,048 slots, `P_LG_AW`; family F keeps 4,096) and active only on those
  boards (`mode_c`).  The log's run encoding keeps the 7,168-word burst at 1,313 slots (`work/gkrp/slots.py`; the largest frame of every I4300 scene tried).  A frame that does not
  fit is drawn live as before;
* the log's cut is the line `v_vis` (MAME's render line); the apply waits until the renderer has been kicked for the last displayed line (`kicks_done`, `v_vis + crtc_vfirst`) and is
  done.  Writes of the window between the two (11 lines on Mouja's / Doukyuusei Special's CRTC: "INSERT COIN" blinked a frame early with the cut at `v_vis + vfirst`) belong to the
  next picture;
* the sprite list is copied at `v_vis` for every I4300 board (before: `vlast` of the frame, or `crtc_vfirst` of the next one on the 240-line boards) and the registers above are
  copied with it (`r_*_q`, `rg_snap`; not with the raster-IRQ mode `i_scan_irq`);
* blits: a blit queue pop waits for the log up to the cut (`lg_pre_ok`) instead of forcing it out; `mode_c` stays on while the queue runs.

The display of these boards is one frame later than in 20261014a (the picture is MAME's frame; the replay index is `D + n - 1`, as for family F).

**Replays against MAME** (pictures that differ from MAME's frame; baselines: 20261013a sources for the first four rows, 20261014a for Gakuensai):

```
game / frames                    pictures   before                                   20261014b
Doukyuusei    300 - 700             400      3 (the two changes, one 94 px)           0
Doukyuusei   3000 - 3200            200      0                                        0
Mouja        4000 - 4200            200      0                                        0
Doukyuusei Special 4800 - 5000      200      82 (29,015 px)                           0
Gakuensai    6700 - 6900 (tutorial) 200      20 (21,098 px)                           0
Gakuensai   11700 - 11900 (play)    200      11 (1,749 px)                            0
```

Whole machine (committed tree against the new one, the real SDRAM path, picture / VDP memories byte for byte): Gakuensai and Mouse Shooter GoGo at frames 110 and 220 identical
(boot screens: nothing hangs, the log does not disturb the boot).

| Core file | Macros | Seed | Setup (96 MHz) | Hold | HDMI clock setup | ALMs | RAM blocks |
|---|---|---|---|---|---|---|---|
| `metro_20261014b` | `D_BUILD D_VLOG NO_YMF` | 4 | **+0.103 ns** | +0.243 ns | +0.650 ns | 31,240 (75 %) | 548 / 553 |
| `metrod64_20261014b` | `D_BUILD D_VLOG F64` | 4 | **+0.096 ns** | +0.158 ns | +0.394 ns | 32,363 (77 %) | 549 / 553 |

(`metrod64` with seed 3 missed by 0.108 ns.)  Build id `261014b`.  `metrof64_20261013a` stays current.

**Mouse Shooter GoGo** (I4220, not touched): the whole-machine write log of the title (`work/gk/wl_msgogo_wl.txt`, 880 frames) has the same cadence as MAME's (the sprite list every
second frame, the blit group every fourth, 266 tile words per update in the scene before, the core's frame = MAME's + 22), and the whole-machine picture of core frame 880 equals
MAME's frame 858 pixel for pixel (shift 11 lines).  A register snapshot (`rg_snap` for every board) changes none of the 280 replay pictures.  The "choppy title" may simply be the
game's own 30 Hz sprite update; the flashing lines and the theatre flash are not explained.

**Tools.**  `work/gkrp/run_reg2.sh <variant>` + `regcmp2.py` (replay of every I4300 scene with a prebuilt binary and the comparison table), `evsum.py` (a write burst by kind and
line), `slots.py` (log slots a frame needs).

## Releases 20261014c / 20261014d: fast loading, Scale, CRT Adjust under the scandoubler (2026-10-14; all three cores; 20261014d confirmed on the boards)

Ported from the Metamorphic Force core (`C:\repos\metamrph-mister`, `docs/mister-memory.md`); CRT Adjust (rmonic79's module) was already in this core.

* **Fast load** (`rtl/metro_fastload.sv`, `rtl/metro_ddr.sv`, `Metro.sv` `fast_dl`).  `address="0x32000000"` on the MRA's index-0 `<rom>` makes a recent Main_MiSTer copy the assembled
  image into the DDR3 at once and end a download that has no data bytes and a start `ioctl_addr` = the image's length; the core stays in reset until `metro_fastload` has read it
  back (256-byte bursts) and played it into `metro_loader` as the byte strobe / address / data the HPS port would have produced (held by `o_dl_busy`).  The loader, the
  descramble, the EEPROM contents and the SDRAM write path are those of a streamed load.  An older Main_MiSTer ignores the attribute and streams as before.  The DDR3 port is
  shared with `screen_rotate` (the framework's rotated frame buffer for the vertical games, which never looks at `DDRAM_BUSY`): `metro_ddr` queues its writes (64-deep MLAB FIFO)
  and puts the fast load's reads between them (the Metamorphic Force core's `ddr_arb` without the Flip Screen channel).  `tools/make_mra.py` writes the attribute;
  `tools/package.py <date> noaddr` leaves it out for a release whose cores do not have the fast load.  The first build had the 32 x 64-bit block buffer written inside the state
  machine's reset branch: Quartus made 2,048 flip-flops of it (+1,000 ALMs, failed timing on the way); a plain registered-read MLAB is 4 MLABs.
* **Scale** (`status[34:32]`, hidden while the picture is rotated through the framebuffer): the framework's `video_freak` integer scaling with the same mapping and Full Screen
  rule as the Metamorphic Force core (the menu's order is the user's; video_freak's SCALE counts 0 Normal, 1 V, 2 narrower HV, 3 HV+, 4 HV).  For the rotated games
  `video_freak` would measure the unrotated picture and size the framebuffer wrongly: Scale stays Normal for them.
* **CRT Adjust** does nothing while `Scandoubler Fx` or the framework's forced scandoubler is on (`ca_on`).

**Bench** (`sim/emu/run_emu.sh`, `sim/emu/tb_emu.cpp`: `Metro.sv`'s `emu` with `hps_io` and the PLL stubbed, the project's real file list from `files.qip`, `sim/sdram_model.sv`
and an Avalon DDR3 model `sim/ddr_model.sv`; env FAST, STRIDE, SCALE, AR, HW / HH, FX, FSD, CRT, SDRDUMP):

```
Dharma Doujou image (5 MB), streamed / fast:    SDRAM chip contents byte for byte identical; 23.77 M clocks both (the SDRAM write path is the limit: 0.25 s at 96 MHz)
Mahjong Gakuensai image (38.8 MB), streamed / fast:   identical; 175.9 M clocks (1.83 s)
Dharma from the fast load, 130 frames:           "ROM OK / RAM OK" on screen, 20,480 DDR reads = 5 MB / 256 B, 0 protocol errors
Lady Killer (vertical) from the fast load, 80 frames:  6.85 M rotate-buffer writes through the arbiter, 0 protocol errors, Scale 2 asked: ratio 3:4 (Normal)
Scale 1..4 x Aspect Original / Full Screen, 1080p / 720p / 768p:   12 runs, the asked size equals the rule in all (e.g. 1080p Original: V 1194 x 896, HV 1280 x 896, narrower 960 x 896)
CRT Adjust on with Scandoubler Fx 2 / forced scandoubler: 448 rows x 320 as without (CRT Adjust alone: 312 pixels wide with H-Size +5)
```

Whole machine, family F (Grand Striker 2, F64 + log, the real SDRAM path, the 20261013a-era tree against the 20261014c sources): the picture, the VDP memories, registers and sprite list at frames 420 and 600 are byte for byte identical (`work/gkrp/run_fregress.sh`; the shared video chip changes of 20261014b are gated on `i_i4300`).

| Core file | Macros | Seed | Setup (96 MHz) | Hold | ALMs | RAM blocks |
|---|---|---|---|---|---|---|
| `metro_20261014c` | `D_BUILD D_VLOG NO_YMF` | 4 | **+0.072 ns** | +0.065 ns | 31,867 (76 %) | 548 / 553 |
| `metrod64_20261014c` | `D_BUILD D_VLOG F64` | 2 | **+0.005 ns** | +0.106 ns | 32,930 (79 %) | 549 / 553 |
| `metrof64_20261014c` | `F_BUILD F64 F_VLOG NO_YMF` | 3 | **+0.300 ns** | +0.106 ns | 30,119 (72 %) | 553 / 553 |

Seeds tried: `metro` 4 (+0.072), 5 (-0.238); `metrod64` 1 (-0.458), 2 (+0.005), 4 (-0.254), 5 (-0.583), 6 (-0.006); `metrof64` 1 (setup +0.381 but hold -0.071 on the log
memory's address register), 2 (+0.329 / +0.057), 3 (+0.300 / +0.106).  The worst paths of the failing seeds are the 68000's read-data mux (`aob` -> `Equal32` ->
`sel_io` -> `iEdb`, 11 levels: the read at `cnt == 3` is a four-clock path that the SDC leaves single-cycle on purpose), unchanged by this release: it is placement noise of a
design at 76 - 79 % of the ALMs.  Registering the selects of that mux (they are stable three clocks before the read) is the clean way to buy margin and is not done yet.

**20261014d** is 20261014c with the 68000's read-data selects registered (`rtl/metro_main.sv`: `r_sel_ram` ... `r_ee`, one register stage on the decode of the address; the read
mux at `cnt == 3` used the combinational decode: `aob` -> `Equal32` -> `sel_io` -> eleven levels -> `iEdb`, a path of four clocks the SDC leaves single-cycle).  Behaviour is
the same (the address is stable from AS on); the margin moved by about +0.1 to +0.5 ns on the seeds tried:

| Core file | Seed | Setup (96 MHz) | Hold | ALMs | RAM blocks | Seeds tried (setup) |
|---|---|---|---|---|---|---|
| `metro_20261014d` | 4 | **+0.148 ns** | +0.065 ns | 31,577 (75 %) | 548 / 553 | 4 +0.148, 5 +0.318 |
| `metrod64_20261014d` | 2 | **+0.129 ns** | +0.156 ns | 32,915 (79 %) | 549 / 553 | 2 +0.129, 4 +0.014 |
| `metrof64` | (3 of 20261014c: the file stays `metrof64_20261014c.rbf`) | +0.300 ns | +0.106 ns | 30,119 (72 %) | 553 / 553 | d seed 3: setup +0.183, hold -0.122 (the log memory's address register again) |

`metrof64` seeds of 20261014d (1, 2, 4) are fitting: if one closes the file will be renamed.  The family D / C whole-machine regression of the registered selects
(`work/gkrp/run_dreg.sh`: 16 games, `tree_head` against the working tree, frames 100 and 250, picture + VDP memories + registers + sprite list) was running at the time of
writing: Dharma Doujou, Daitoride, Toride II and Pururun byte for byte identical (all 16 were, see below).

**Hardware result (the user, 2026-10-14, `Metro_MiSTer_20261014d.zip`):** fast loading works; the video fixes (Mahjong Doukyuusei's intro, Gakuensai's speech bubbles) work; Scale,
CRT Adjust under the scandoubler and the other items OK; every game of the three cores was started and works.  `metrof64` ran as `metrof64_20261014c.rbf` (the same logic without
the registered read selects; +0.300 ns), which is what stays in the release.

**Regressions run after the release** (`work/gkrp`): family D / C whole machine (`run_dreg.sh`, 16 games, the 20261013a-era tree against the working tree with `D_VLOG` and the
registered selects, frames 100 and 250: picture, VDP memories, registers, sprite list): all 16 byte for byte identical.  Family F (`run_fregress.sh`, Grand Striker 2, frames 420
and 600): identical.  `metrof64` seeds of the 20261014d sources: 1 setup -0.131 / hold -0.051, 2 +0.420 / +0.091, 4 +0.436 / +0.106, 3 +0.183 / hold -0.122; `Metro_F64.qsf` now
carries seed 4 (the shipped `metrof64_20261014c.rbf` was fitted from the sources one register stage earlier, seed 3).

## Releases 20261015a / 20261018a: Sankokushi and Mouse Shooter GoGo built the way MAME builds a frame (2026-10-15 / 18; `metro` and `metrod64`; confirmed on the boards)

**Why.**  Videos of 2026-10-15: `IMG_8104` Sankokushi (glitching rows at the top of the picture while the lying woman slides in), `IMG_8095` Mouse Shooter GoGo (the theatre's
screens do not change as smoothly as MAME's).  Mahjong Gakuensai's fifth girl (`IMG_8103`) is the game's own ghost frame (MAME shows the same; replay 0 px) and Blazing Tornado's
yellow glyphs (`IMG_8105`) are the power-on RAM test's patterns: nothing to do for those two.

**Cause.**  Both games rewrite the tile RAM with the blitter while the beam draws (Sankokushi: a blit every ~8.6 lines, ~28 a frame, ~10,000 words a frame while a picture slides;
Mouse Shooter GoGo: the whole new scene of a theatre change, several thousand words in one frame) and rewrite the palette across the frame.  MAME runs a blit at its trigger and
renders the frame once at line `v_vis`, so every row of its picture is from the same instant; the core drew the live RAM with the palette snapshot of the frame before, so a scene
change showed one picture of the new tiles in the old palette (a full-colour flash of the new scene; MAME's picture there is black) and Sankokushi's rows above a blit showed the old
picture.  Replays of MAME's own writes (`work/gkrp`: `mg_prep.sh`, `sk_prep.sh`, `run_mg.sh`, `cmpsum.py`) reproduced both: Mouse Shooter GoGo frames 1090 - 1170 (title -> theatre)
9 of 80 pictures off, the other three changes (frames 1295, 1460, 1755) one picture each of 4,000 - 23,000 pixels; Sankokushi's intro (frames 1690 - 1726) 16 of 36 pictures off.

**The change** (`rtl/metro_vdp.sv`, `rtl/metro_blitter.sv`, `rtl/metro_main.sv`).  The frame-synchronous tile RAM of the I4300 boards (the log, `P_VLOG`) is now also used by two
I4220 boards (`i_fsync`: board 13 Sankokushi, board 22 Mouse Shooter GoGo) with the blitter writing through it:

* the blit's words go into the log in order (`bl_log_we`), one word every 4 - 5 clocks: the log's write pipeline takes one write at a time, so the blitter waits for `pq_busy` and
  for its own strobe (the first version let two writes overlap and lost words: black tiles in the picture).  The 68000's tile writes wait for the blit in progress (`lg_hold`);
* the cut (`v_vis`) waits for the blit in progress and the one queued behind it (`bl_pend`, a new output of `metro_blitter`): a blit is whole in one picture, as MAME's is;
* a frame that has more words than the log holds (`fdr`): the log is emptied completely and kept empty while the blit or the 68000 keeps writing (that frame is drawn live, as
  before).  Forcing one slot at a time left the log full and its words 2,000 - 4,000 slots behind the RAM (Sankokushi: a hollow region in the picture);
* the tile table copy of the tall boards waits until the frame's writes are in the RAM (`tts_arm`, `lg_pre_ok`; no change for the boards without the log);
* the sprite list, the registers (`rg_snap`) and the palette are copied at `v_vis` as on the I4300 boards; the picture is one frame later than before (MAME's frame, replay
  index `D + n - 1`);
* the log is 4,096 slots in `metrod64` (`F64`: about 640 more ALMs) and 2,048 in `metro` (an I4300 frame needs 1,313 at most).  Mouse Shooter GoGo's scene changes need more than
  2,048: three of the four theatre changes show one live-drawn picture with 2,048, none with 4,096.  The blit-done interrupt is still the blitter's own end.

**Replays against MAME** (pictures that differ from MAME's frame; `mister/rtl` tree, shift 11 lines; "live" is 20261014d):

```
Mouse Shooter GoGo   frames       pictures   live                         20261015a (4,096)   (2,048)
  title -> theatre   1090 - 1170      80     9 (44,000 px)                0                   0
  theatre change     1295 - 1345      50     4 (23,918 px)                0                   1 (21,648 px)
  theatre change     1460 - 1530      70     1 (4,152 px)                 0                   1 (11,280 px)
  theatre change     1755 - 1845      90     4 (22,014 px)                0                   1 (30,520 px)
  title scroll       780 - 860 / 860 - 960  80 / 100  0 / 0               0 / 0               0 / 0
  rule board         2270 - 2370     100     1 (988 px)                   0                   0
  rule board         2700 - 2780      80     60 (29,157 px, ~400 each)    0                   0
Sankokushi           1690 - 1726      36     16 (55,333 px)               6 (10,615 px)       1 (11,324 px: a scene load)
                     2000 - 2050      50     6 (17,823 px)                0                   0
                     2250 - 2300      50     0                            0                   0
                     3100 - 3170      70     2 (17,415 px)                0                   0
                     4100 - 4160      60     1 (131 px)                   0                   0
I4300 boards         dk300 400, dk3000 200, mj4000 200, dp4800 200, gt6700 200, gp11700 200 pictures:  0 differ in all, both log sizes (as in 20261014d)
```

(Sankokushi with 4,096 slots shows five pictures of 5 - 8 pixels more than with 2,048: not used, `metro` keeps 2,048.)

**20261015a was withdrawn for Mouse Shooter GoGo** (sent, then found in the whole-machine bench before a hardware test): with the real 68000 the game stopped after its first blit
chain (frame 71 of the sim) and never loaded a palette: black screen.  The game's interrupt handler and its main loop both program the blitter (the handler starts the next blit of a
chain on the done interrupt, the main loop starts chains); a blit through the log takes 4 - 5 clocks a word instead of ~2, the done interrupt came after the next 480 Hz tick, the main
loop was interrupted half-way through writing a blit's registers, the handler programmed and started the same blit, the main loop then wrote the rest and started it a second time,
and the chain ran off its table (two triggers with tilemap 0).  The VDP write logs of the committed tree and of the new one (`+VDPWLOG`, `work/wm/run_wl.sh`) are identical up to that
point.  **20261015b / 20261018a**: on the `i_fsync` boards the done interrupt is MAME's timer, 500 us after the trigger (re-armed by each trigger), as on the I4300 boards (`bq_irq_set`,
`blit_done = fs_en ? bq_irq : bl_done_raw`): the game's own flow is then MAME's, which is also what the replays play.  The replays above do not model the interrupt and are unchanged.

**Whole machine** (the real 68000 and SDRAM path, `work/wm`, `sim/run_sys.sh` with `SDR=1 DBUILD=1 DVLOG=1`, 20261015b tree; 20261018a draws the same, see below):

```
Sankokushi, frames 1690 - 1740 (the intro's sliding pictures), core frame n = MAME frame n - 14:     51 frames, 44 identical, 5 of 533 - 637 px, 2 scene-load frames (7,910 / 11,141 px)
Mouse Shooter GoGo attract (no coin), frames 1105 - 1190 (title -> theatre), core n = MAME n - 25:  86 frames, 67 identical; the frame of MAME's garbage mosaic (1129) is the
    bubbles picture again in the core (62,728 px: no flash, one clean frame instead of MAME's garbage); after the change 18 frames of 600 - 1,500 px (the mice's animation phase)
Mouse Shooter GoGo with coin (120) and start (220): boots, palette and pictures at frames 100 - 300 (20261015a: black from frame 71 on)
```

**Timing (20261018a).**  `metrod64` with the 4,096-slot log (81 % of the ALMs) failed timing on every seed of 20261015b (seeds 1 - 5: -0.57 to -0.08 ns).  The worst
paths were all older logic: the renderer's 16 x 16 tile flag (`r_ctrl` -> the layer mux -> `big` -> the prefetch compare -> the tile data enable), its sprite emit
(texel -> opaque test -> the enable of the line buffer's address / data registers) and the video chip's CPU read mux (`ra` -> the 0x788xx / 0x797xx compares -> the region
priority -> `o_rdata`).  Each got one register stage, none changes behaviour: `big_r` (`rtl/metro_render.sv`, the control register's tile size flags of the four layers,
one clock later), the emit loads `spr_waddr` / `spr_wdata` on every cycle and only `spr_we` depends on the texels, and the read's region decode and register value
(`rd_*_q`, `reg_hit_q`, `reg_rdata_q`, `rtl/metro_vdp.sv`) are taken in B_RD1 and used in B_RD2.  Checks: every replay of this section and of the I4300 boards (2,086 pictures)
byte for byte identical to the 20261015b tree's; whole machine (`work/gkrp/run_dreg2.sh`, `run_creg.sh`: the committed tree against the working tree, frames 100 and 250,
picture + VDP memories + registers + sprite list): 21 of the 22 games byte for byte identical (Mouse Shooter GoGo and Gakuensai among them: their frames 100 / 250 are
boot screens); Sankokushi differs as it should (frame 100: the same picture, the palette / sprite RAM a fade step apart; frame 250: the title's scrolling tiles one frame
apart), the pictures are clean.

**Fits** (Quartus 17, build id `261018a`):

| Core file | Macros | Seed | Setup (96 MHz) | Hold | ALMs | RAM blocks |
|---|---|---|---|---|---|---|
| `metro_20261018a` | `D_BUILD D_VLOG NO_YMF` | 5 | **+0.142 ns** (HDMI clock +0.151) | +0.104 ns | 31,946 (76 %) | 548 / 553 |
| `metrod64_20261018a` | `D_BUILD D_VLOG F64` | 4 | **+0.092 ns** (HDMI clock +0.367) | +0.062 ns | 34,128 (81 %) | 549 / 553 |
| `metrof64` | (unchanged: `metrof64_20261014c.rbf`; its logic does not use the new paths) | | | | | |

Seeds of 20261018a: `metro` 4 -0.083 (the log's apply -> tile RAM write enable), 1 +0.057, 5 +0.142; `metrod64` 2 -0.069 (the 68000's data out -> its work RAM), 3 -0.085,
4 +0.092, 5 -0.293.  20261015b (not released): `metro` 4 +0.088; `metrod64` 1 -0.566, 2 -0.487, 3 -0.075, 4 -0.486, 5 -0.088.  20261015a (withdrawn): `metro` 4 +0.282, `metrod64` 2 +0.065.

**Hardware (the user, 2026-10-18, 20261018a): "Fixes work"** (Mouse Shooter GoGo's theatre changes, Sankokushi's sliding pictures).

## Releases 20261018b / 20261018c: the EEPROM saved, the test switch, Bang Bang Ball and Battle Bubble at 60 Hz (2026-10-18; `metro` and `metrod64`; 20261018c confirmed on the boards)

**EEPROM save.**  Mahjong Doukyuusei Special (board 16, `metro`) and Mahjong Gakuensai 1 / 2 (boards 20 / 21, `metrod64`) keep their settings in a 93C46 (`rtl/metro_eeprom.sv`); the
core loaded it at every start from the image (bytes 0x100..0x17F: MAME's `eeprom` region for Doukyuusei Special, zeros for Gakuensai) and never saved it.  Now the MRAs of the
three sets (four files) carry `<nvram index="4" size="128"/>` (`tools/make_mra.py`), and `Metro.sv` does what the PGM2 core does with its battery SRAM:

* Main_MiSTer sends the saved file after the ROMs as a download with index 4 (`nv_dl`; the machine is held in reset meanwhile).  With the fast load the file can come while
  the image is still being replayed: once it has come (`nv_loaded`, cleared by the next ROM download) the image's default bytes are not written.  No file: the image's contents
  as before.
* The core asks for an upload (`ioctl_upload_req`, index 4) when the OSD opens after the game has written the EEPROM (`o_written` of `metro_eeprom`: a write, an erase, ERAL /
  WRAL, `nv_dirty`), OSD **Autosave EEPROM** (`status[12]`, On by default), and on **Save EEPROM** (`status[13]`); both are shown only on the three boards (`status_menumask`
  bit 5).  Main_MiSTer reads the 128 bytes back (`ioctl_din` = `o_nv_rdata`, the byte at `ioctl_addr`, one clock later).
* The file is MAME's `nvram/<set>/eeprom`: 128 bytes, **little-endian words** (MAME's region is big-endian, its nvram file is not: `eeprom-dokyusp.bin` starts `00 e0`, the
  file MAME writes from it `e0 00`), so a MAME save can be copied over.
* MAME (`work/ee`): Gakuensai 1 and 2 accept neither an all-FF nor an all-zero EEPROM, initialise it in frames 2 - 44 after reset (`tap.lua`: the port's accesses per frame) and
  end with the same 128 bytes from both starts, so the core's zero default (the image) and MAME's FF default give the same settings.

**Checks** (the top-level bench `sim/emu`: `Metro.sv` with the hps_io stand-in; `tb_emu.cpp` got `NVIN` (the file sent as index 4: after the image, or with `FAST=1`
during the replay), `NVOUT` (the OSD opens, or `NVSAVE=1` Save EEPROM; an upload is answered as Main_MiSTer does), `NVEXPECT`; `OSD_STATUS` is a port of `tb_emu_top.sv`):

* Gakuensai (`metrod64`, fast load), no file: the game initialises the EEPROM, the OSD opens, 1 upload request, the 128 bytes read back are **byte for byte MAME's file**
  of a blank start (`work/ee/t1.bin`); the dirty flag clears with the upload.
* Gakuensai, MAME's file sent during the replay: the game finds it valid and writes nothing (dirty 0, no request when the OSD opens), so the file survived the replay and is
  what the game reads.  Streamed load, the file after the image, Save EEPROM: 1 request, the bytes back = the file.
* Doukyuusei Special (`metro`, fast load), MAME's file during the replay, Save: the bytes back = the file.  No file, Save: the image's region (big-endian) comes back as
  MAME's file (little-endian), byte for byte.

**60 Hz for Bang Bang Ball and Battle Bubble.**  MAME runs `bangball` / `batlbubl` at 60 Hz (`set_refresh_hz(60)`, "doesn't like 58.2 Hz"; the screen stays 392 x 263, its
scanline timer gives the line interrupts), the core ran them at the other boards' 58.23 Hz: the game ran 3 % slower than MAME's and the display at another rate.  The
video chip now takes `i_h380` (boards 25 / 26, `h380_r` in `rtl/metro_main.sv`): 380 dots a line instead of 392 at the same 6.0 MHz dot clock, 263 lines, **60.03 Hz**
(15.79 kHz; MAME's line is 63.37 us, the core's 63.33 us, the 68000 gets 1,013 of its 16 MHz cycles a line as in MAME).  The line's last dot is a register (`h_last`, static
like `h_vis`); the horizontal sync pulse is 28 dots from dot 328 (8 dots after the picture) and ends 24 dots before the next line as in the 392-dot line, so the picture
sits where the other games' does.  Every other board: `h_last` = 391 as before.

**Checks** (whole machine, `run_sys.sh` with the SDRAM path and the 64 MB D build, coin 120 / start 220 as MAME's dumps `work/gk/bb.*`, `bl.*`): Bang Bang Ball's core
frame 300 is MAME's frame 290 in every memory and register, frame 500 MAME's 490 but 2 sprite words; Battle Bubble frame 150 equal to MAME's, 300 / 500 as Bang Bang Ball.
The 10 frames are not the frame rate (the old 58.2 Hz core's frame 300 is MAME's 292): both advance the game once a frame, and they come from the boot.  The game's first
65,536-step loop (0x904: `tst.b $d00006`, the inputs, then five `move.w d2,$e78890`) takes MAME 118 cycles a step and the core 164 (the video chip's write ~40 clocks more
than MAME's zero-wait access, the input read ~76): the VDP write streams (`tools/lua/vdpwr.lua`, its path pattern's escape fixed; the bench's `+VDPWLOG`; `work/ee/bbm/wstream.py`)
are identical for the loop's 330,669 writes, which end at MAME's frame 29 and the core's 41.  So the core starts the game 0.2 s later and stays 10 - 12 frames behind MAME's
frame numbers.  The earlier note in this file that put the frame 300 differences down to 58.2 against 60 Hz was wrong; they were this offset.

**Regression** (`work/gkrp/run_reg3.sh`, whole machine, frames 100 / 250, picture + VDP memories + registers + sprite list, against the 20261018a tree's results):

```
64 MB (metrod64):  balcube, daitorida, gakusai, msgogo identical;  bangball, batlbubl: frame 100 identical, frame 250 differs (60 Hz)
32 MB (metro):     dokyusp, dharma, toride2g, pururun, daitorid, puzzli, karatour, pangpoms, skyalert, lastfort, poitto, 3kokushi, dokyusei, mouja, gunmast, ladykill identical
```

**Timing.**  The first fits (seeds 5 / 4) put `metrod64` at -0.466 ns: `pixdiv` -> `line_start` -> the enables of `r_window_q` (the line-start compare now against the
`h_last` register instead of a constant).  The compare is registered (`h_at_last`: `hcnt` holds for 16 clocks, so it is ready at the pixel enable; the same behaviour:
Bang Bang Ball, Bal Cube, Dharma, Doukyuusei Special at frame 100 byte for byte the run before it, `work/gkrp/run_eqk.sh`).  Fits (Quartus 17, build id `261018b`):

| Core file | Seed | Setup (96 MHz) | Hold | ALMs | RAM blocks |
|---|---|---|---|---|---|
| `metro_20261018b` | 5 | **+0.286 ns** (HDMI clock +0.576) | +0.120 ns | 32,709 (78 %) | 548 / 553 |
| `metrod64_20261018b` | 2 | **+0.157 ns** (HDMI clock +0.339) | +0.064 ns | 35,128 (84 %) | 549 / 553 |
| `metrof64` | (unchanged: `metrof64_20261014c.rbf`) | | | | |

`metrod64` seed 4 -0.196 ns.  Package `dist/Metro_MiSTer_20261018b.zip`, notes `dist/RELEASE_NOTES_20261018b.md` (local; sent, not tested, replaced by 20261018c).

**The test switch (20261018c).**  The owner asked whether these games should have DIP switches: they have none (metro.cpp: "Same as dokyusei, without the DSWs (these games
have an EEPROM)"), their settings are made in the game's test mode, and that is entered with the test switch (IN0 bit 3, `PORT_SERVICE_NO_TOGGLE`, MAME's F2), which the
core never drove (keyboard 9 is the service coin, bit 2): 20261018b saved an EEPROM nobody could change.  `Metro.sv`: F2 (PS/2 0x06, `key_test`) is IN0 bit 3 of the
I4300 boards with the mahjong panel (Doukyuusei, Doukyuusei Special, Gakuensai 1 / 2: `dk_in0`) and IN1 bit 7 of Mouja (`mo_in1`).  Blazing Tornado / Grand Striker 2 also
have one (IN2 bit 1) besides their Service Mode DIP: not done, `metrof64` is not rebuilt.  MAME (`work/ee/test`, `t.lua`: the "Service Mode" field held for 10 frames):
Gakuensai starts its test mode at once, in game or held at power-on ("PROGRAM ROM" ... "CG ROM", the ROM check takes ~15 s, then WORK RAM / VDP RAM / EEP ROM OK and the menu;
Ron = next page, N = previous); Doukyuusei Special goes white and shows its KEY TEST grid ~10 s later; Mouja's switch acts only after its power-on self-test (frame ~600),
then TEST MODE at once.  Top-level bench (`tb_emu.cpp` `TESTKEY=<f0>,<f1>`: F2 through the hps_io stand-in's `ps2_key`): Gakuensai with F2 at frames 60 - 70 after the load
shows "PROGRAM ROM" at frame 100 (without: the Make Software logo), Doukyuusei Special the white screen (without: the logo); Mouja's run (F2 after its self-test,
940 frames) was stopped when the board answered.  **Hardware (the owner, 2026-10-18, 20261018c): F2 works as the test switch on Mahjong Doukyuusei, Doukyuusei Special,
Mouja and Gakuensai 1 / 2; the settings are kept over a power-off; Bang Bang Ball / Battle Bubble at 60 Hz good.**

| Core file | Seed | Setup (96 MHz) | Hold | ALMs | RAM blocks |
|---|---|---|---|---|---|
| `metro_20261018c` | 5 | **+0.199 ns** (HDMI clock +0.442) | +0.024 ns | 32,904 (79 %) | 548 / 553 |
| `metrod64_20261018c` | 4 | **+0.312 ns** (HDMI clock +0.148) | +0.076 ns | 35,027 (84 %) | 549 / 553 |

`metrod64` seed 2 -0.084 ns.  Package `dist/Metro_MiSTer_20261018c.zip`, notes `dist/RELEASE_NOTES_20261018c.md` (local).

## Open points

Toolchain: WSL Ubuntu has Verilator 5.053 (`$HOME/tools/oss-cad-suite`), g++ 9.4, GNU make 4.2.1. Run WSL commands from PowerShell, or from Git Bash with `MSYS_NO_PATHCONV=1`.

* **Known issues on the board** (README "Known issues"): the plain Daitoride's torn scanlines on the rocks (the I4220 board of the `metro` core; the YMF278B version does not
  show them; the frame-synchronous tile RAM of family F was **not** ported: its cost in logic and timing margin, a frame more latency and the blitter's start held for the log
  outweigh one game's few scanlines); Mahjong Doukyuusei's bright frame / intro flashes (fixed in 20261014b / d, confirmed on the board);
  The Karate Tournament's explosion rectangles (not re-checked since 20261010);
  Mouse Shooter GoGo's quirks of video `IMG_8095` (2026-10-13: the falling cat's flashing lines and the title scrolling in are MAME's own, the owner checked them in MAME on 2026-10-14; the theatre's scene changes were fixed in 20261018a, confirmed on the board: nothing open); Sankokushi's sliding pictures (fixed in 20261018a, confirmed on the board; replays 1 of 36 pictures off).  Mahjong Gakuensai 1 / 2's glitches were the blitter's groups,
  fixed in 20261014a (confirmed on the board).
* **Not done:** the family C boards' 68000 program is read through the SDRAM cache: ROM reads wait 2 clocks on average (the "quarter slower"
  of earlier notes was bus utilisation, not speed); Puzzlet (H8/3007 CPU: MAME 0.289 does not run it either), Metabee Shot (its Z8 protection MCU has no dump) and
  Poitto! revision C (one ROM has no known good dump) cannot be done.
* **68000 speed in VDP-heavy loops:** a write to the video chip takes the core's 68000 ~40 clocks (96 MHz) more than MAME's zero-wait access, a family C input read ~76:
  Bang Bang Ball's 65,536-step boot loop ends 12 frames later than in MAME (0.2 s; section "Releases 20261018b / 20261018c").  The games' frame-locked flow is not affected.
* **Build variants:** one tree, three core files (README "Three core files"). A fit of everything in one core needed 48,811 ALMs (116 % of the device, `build_all`, 2026-10-12): the
  split is a resource limit, not a choice.
* **Hardware test switches:** the six OSD switches of the development builds are behind `VERILOG_MACRO METRO_DEBUG` (`Metro.sv`); a release build has them at the tested settings.
* **Posted writes to the 053936 plane's map RAM** (`F_POSTW` in `rtl/metro_main.sv`, written 2026-10-11 for the continue band before the frame-synchronous RAM replaced the idea):
  not in any release, not tested on a board, off by default.
