# Vendored modules

Third-party HDL cores copied into the tree -- no submodules, so the build is self-contained and reproducible.
Each keeps its own LICENSE alongside.

| module | upstream | via | licence |
|---|---|---|---|
| cpu-fx68k (+ `../microrom.mem`, `../nanorom.mem`) | https://github.com/ijor/fx68k (Jorge Cwik) | copied unchanged from `C:\repos\mcatadv-mister\mister\modules\cpu-fx68k` (the copy that core builds with Quartus 17 and runs in Verilator with `--no-assert-case -Wno-BLKANDNBLK`) on 2026-10-05; the same files exist in searchsolved/Arcade-HyperDuel_MiSTer `rtl/vendor/fx68k` with different Verilator/Quartus patches (`ref/Arcade-HyperDuel_MiSTer/rtl/vendor/PATCHES.md`), 56 and 36 differing lines in `fx68k.sv` / `fx68kAlu.sv` | GPL-3.0 |
| ikaopll (YM2413 / OPLL) | https://github.com/ika-musume/IKAOPLL (Raki / Sehyeon Kim) | copied unchanged from searchsolved/Arcade-HyperDuel_MiSTer `rtl/vendor/ikaopll` (`ref/Arcade-HyperDuel_MiSTer`, commit 7f154f1) on 2026-10-07 | BSD-2-Clause |
| jt51 (YM2151) | https://github.com/jotego/jt51 (Jose Tejada) | the 22 files listed in `hdl/jt51.qip`, copied unchanged from searchsolved/Arcade-HyperDuel_MiSTer `rtl/vendor/jt51` (commit 7f154f1) on 2026-10-07; used with a write hold until `cen_p1`, as that core does | GPL-3.0 |
| jt6295 (OKI M6295) | https://github.com/jotego/jt6295 (Jose Tejada) | the 8 files `hdl/jt6295*.v` (INTERPOL=0 needs no others) copied unchanged from searchsolved/Arcade-HyperDuel_MiSTer `rtl/vendor/jt6295` (which carries a patched copy, see its PROVENANCE.md) on 2026-10-07 | GPL-3.0 |
| crt_adjust (CRT Adjust: H-Size, H-Position, V-Shift) | https://github.com/rmonic79/MiSTer-CRT-Adjust (Umberto Parisi, rmonic79) | `rtl/crt_adjust.sv` of the upstream (here `modules/crt_adjust/crt_adjust.sv`) copied from commit c682de9 (2026-08-06) on 2026-10-09, suggested by the user, with **two changes marked `METRO` in the file** (the sign extension of a negative H-Position in the content-shift mode, and the picture / vertical-blank gating with the vertical blank of the line being emitted: both found by `sim/tb_crtadj.cpp`, to be reported upstream); the glue is `rtl/metro_crtadj.sv` (after the upstream's `docs/core-side-integration.md` and `examples/core_side_snippet.v`); `HPOS_MODE` = content shift | GPL-3.0-or-later |
| jt10 (YM2610 / jt12 family) | https://github.com/jotego/jt12 (Jose Tejada) at dc9be7c | copied unchanged from `C:\repos\mcatadv-mister\mister\modules\jt10` (the copy that core builds; one local change there: `jt10.v` has an extra output `adpcmA_l_dbg`) on 2026-10-10 for family F's YM2610; run on the 48 MHz clock of the PLL (see its UPSTREAM.txt) | GPL-3.0 |
| jt49 (AY-3-8910 SSG of the YM2610) | https://github.com/jotego/jt49 (Jose Tejada) | copied unchanged from `C:\repos\mcatadv-mister\mister\modules\jt49` on 2026-10-10 | GPL-3.0 |
| cpu-tv80 (Z80) | https://github.com/hutch31/tv80 (Guy Hutchison); `tv80s_cen.v` is the user's clock-enable variant of tv80s (written for the Time Pilot core) | copied unchanged from `C:\repos\mcatadv-mister\mister\modules\cpu-tv80` on 2026-10-10 for family F's sound CPU | MIT-style permissive licence (cpu-tv80/LICENSE) |
| ymf278b (YMF278B / OPL4 PCM engine) | https://github.com/srg320/Arcade-PsikyoSH2_MiSTer (srg320), `rtl/PSH2/YMF278B.sv`, derived from MAME's `ymf278b` | `rtl/ymf278b.sv` + `rtl/ymf278b_pkg.sv` (not under `modules/`: the file has the Metro changes, listed in its header) | BSD-3-Clause |

The fx68k microcode ROM files are read with `$readmemb("microrom.mem")` / `"nanorom.mem"`, i.e. relative to the directory the simulator
or Quartus runs in: simulations copy them next to the binary (as `mcatadv-mister/mister/sim/run_main.sh` does), Quartus finds them in the project directory.

To update one: re-copy from upstream at the new commit and record it here.
