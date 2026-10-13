# Metro for MiSTer 20261013a: first release

FPGA core for the **Metro Corp. arcade boards** (1994 - 1996, Imagetek I4100 / I4220 / I4300 video chips): 47 sets of 24 titles, written from MAME 0.289's `metro.cpp` and checked
against MAME in simulation and on a real MiSTer.

## Download

**`Metro_MiSTer_20261013a.zip`**: unpack it over the root of the SD card. It holds 47 MRAs (`_Arcade/`) and the three core files (`_Arcade/cores/`). No ROMs: put your **MAME 0.289**
romsets in `/media/fat/games/mame/` (merged sets, or split sets with their parent zip).

One source tree, three core files. The MiSTer's FPGA is too small for every board family at once (a build with all of it needs 116 % of the logic), so each core file carries what
its games need, and every MRA names the right one:

| Core file | SDRAM module | Games |
|---|---|---|
| `metro_20261013a.rbf` | 32 MB is enough | Dharma Doujou, Toride II, Gun Master, Pururun, Daitoride, Puzzli, The Karate Tournament, Lady Killer / Moeyo Gonta!!, Pang Pom's, Sky Alert, Last Fortress - Toride, Poitto!, Sankokushi, Mouja, Mahjong Doukyuusei, Mahjong Doukyuusei Special, Varia Metal (and their other sets) |
| `metrod64_20261013a.rbf` | **64 MB** | Mouse Shooter GoGo, Bal Cube, Bang Bang Ball, Battle Bubble, Daitoride (YMF278B version), Mahjong Gakuensai, Mahjong Gakuensai 2 |
| `metrof64_20261013a.rbf` | **64 MB** | Blazing Tornado, Grand Striker 2 |

Delete any older `metro*.rbf` from `_Arcade/cores/`. If you used an earlier test build, delete `/media/fat/config/inputs/Metro_input_*.map` and redefine the buttons.

## What is in it

* **Imagetek I4100 / I4220 / I4300** video chips: three tile layers, sprites, blitter, screen flip, 360-pixel games re-timed for CRT, vertical games rotated through the framebuffer.
* **Sound:** the real uPD78C10 sound CPU running the game's program (YM2413 or YM2151, OKI M6295), Varia Metal's ES8712, Blazing Tornado's / Grand Striker 2's Z80 + YM2610, and the
  **YMF278B (OPL4)** of the family C boards, which the 68000 drives itself.
* **Konami 053936** rotation / zoom plane of Blazing Tornado and Grand Striker 2, with a frame-synchronous tile RAM (no tearing on the continue screen or the title).
* **OSD:** aspect ratio, scandoubler effects, CRT Adjust (H-size, H-position, V-shift), display window (the game's CRTC or MAME's), rotate screen, volume, per-game DIP switches.
  The hardware test switches of the development builds are not in the release cores (`VERILOG_MACRO METRO_DEBUG` brings them back).
* **Controls:** joystick (Button 1, 2, 3, Start, Coin), keyboard 1 / 2 start, 5 / 6 coin, 9 service; the mahjong games use the keyboard panel with MAME's default letters.

## How well it is checked

* **In simulation** (Verilator, the games' own programs, the real SDRAM path) against MAME 0.289: the video chip's memories and registers match MAME's word for word after a coin and a
  start on every family; the uPD78C10 runs in lock-step with MAME's own code; the YMF278B's output is compared with ymfm; the Blazing Tornado / Grand Striker 2 plane was checked by
  replaying the games' own writes. The merged source tree built as the 32 MB core gives the same pictures, tile RAMs, registers and sprite lists as the previous main tree on 16 older games at two frames each (0 differences);
  for nine of them those frames were still the boot ROM / RAM test, so this is a check of the boot and of seven games' title / play screens, not of long play.
* **On a real MiSTer** (earlier builds of the same sources): the games of all three cores have been played. Blazing Tornado and Grand Striker 2 run clean with the frame-synchronous tile RAM;
  Mouse Shooter GoGo, Bal Cube, Bang Bang Ball, Battle Bubble and the YMF278B version of Daitoride play well and sound right; the older families have hardware reports for everything
  except Sankokushi and Mouja. The 20261013a binaries are rebuilt from the merged tree: if anything differs from an earlier build, please open an issue.
* Timing: all three fits meet the 96 MHz machine clock (setup +0.175 / +0.125 / +0.363 ns), 70 - 73 % of the logic, 548 / 549 / 553 of 553 RAM blocks.

## Known issues

* Daitoride (plain version): single torn scanlines on the rising rocks (the YMF278B version does not show them).
* Mahjong Doukyuusei: a bright frame in some portrait scenes. The Karate Tournament: explosion rectangles reported on an earlier build, not re-checked.
* Mahjong Gakuensai 1 / 2: a few small graphical glitches. Mouse Shooter GoGo: small quirks.
* Mahjong Gakuensai's EEPROM (settings) is not saved. Bang Bang Ball and Battle Bubble run at 58.2 Hz (MAME: 60 Hz).
* The family C boards' 68000 gets its program through the SDRAM cache; in simulation these games run up to a quarter slower than MAME (not measured on a board).

**Not supported:** Puzzlet (H8/3007 CPU, MAME 0.289 does not run it either), Metabee Shot (its protection MCU has no dump), Poitto! revision C (one ROM has no known good dump).

## Build it yourself

Quartus Prime Lite 17.0.2; one revision per core file:

```
quartus_sh --flow compile Metro      -c Metro        # metro   (32 MB)
quartus_sh --flow compile Metro      -c Metro_D64    # metrod64 (64 MB)
quartus_sh --flow compile Metro      -c Metro_F64    # metrof64 (64 MB)
```

See the README for the build switches, the simulation benches and the tools.

## Credits

MAME (the Metro driver and chip documentation), searchsolved's Arcade-HyperDuel_MiSTer (the Imagetek renderer this video chip is adapted from), Jorge Cwik (fx68k), Jose Tejada (jt51,
jt6295, jt10, jt49), Raki (IKAOPLL), Guy Hutchison (tv80), srg320 (the YMF278B engine of Arcade-PsikyoSH2_MiSTer), Aaron Giles (ymfm, the reference), rmonic79 (MiSTer-CRT-Adjust),
and the MiSTer framework (Sorgelig and contributors). Licence: GPL-3.0-or-later.

## Checksums (SHA-256)

```
e5cf3ac61ed90de7d969d763236b1e1ab7bde4005d8317b808b4babc09355bef  Metro_MiSTer_20261013a.zip
5a96aed2d11f033377ef0ef15f87b246f4816b0f50a11af7a8b2cc42dbbdbb2d  metro_20261013a.rbf
baa4d24aa72c3eeba30dc42b4f35a347e6b25dac5b0e769675e844533bb5c2c5  metrod64_20261013a.rbf
a358ed6e81ea0cd0a972cf783394fb1b1987cebe3ba6150b5cb3a7fbfe14154f  metrof64_20261013a.rbf
```
