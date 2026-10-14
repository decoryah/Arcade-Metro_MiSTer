# Metro for MiSTer 20261014d: fast loading, Scale option, and the 20261014b fixes

FPGA core for the Metro Corp. arcade boards (Imagetek I4100 / I4220 / I4300), 47 sets of 24 titles, written from MAME 0.289 and checked against it.

## What is new since 20261014a

(20261014d is 20261014c with more timing margin and nothing else: the 68000's read-data mux selects are registered. Use this one.)

* **Fast loading.** The ROM image (up to 36 MB) now loads in about a second or two instead of being streamed through the HPS port a byte at a time. It needs a recent
  Main_MiSTer; an older one just loads at the old speed. Use the MRAs from this zip (they carry `address="0x32000000"`; one set of cores and one set of MRAs serve both).
  The same MRAs also need the cores of this zip: all three were rebuilt.
* **Scale option in the OSD:** Normal, V-Integer, HV-Integer, Narrower HV-Integer, HV-Integer+ (integer scaling for HDMI). The 15 kHz analog output is not affected and Normal
  behaves as before. With Full Screen and an integer Scale the picture is the largest whole-number size in the screen's own proportions. Not offered for the vertical games
  (Lady Killer, Moeyo Gonta, Sky Alert) while Rotate screen is On; switch Rotate screen Off to scale them like any other game.
* CRT Adjust (rmonic79's module, already in the core) now does nothing while the scandoubler is in use (Scandoubler Fx or MiSTer.ini's forced scandoubler), as in the
  Metamorphic Force core: it is for the 15 kHz output.
* Everything of 20261014b: **Mahjong Doukyuusei's intro flashes and Gakuensai's tutorial speech bubbles are fixed** (the I4300 boards are frame-synchronous now; in simulation
  with MAME's own writes every picture of the segments tried equals MAME's; the picture is one frame later on those five boards, as MAME's is). Confirmed on the boards.

**Tested on a real MiSTer** (the owner's, 32 MB and 64 MB modules, a recent Main_MiSTer): fast loading works, the Doukyuusei intro and Gakuensai speech bubble fixes work, Scale (all five modes, Original and Full Screen, the vertical games) and CRT Adjust behave, and every game of the three cores was started and plays.

In simulation (whole top level against an SDRAM chip and a DDR3 model): the fast load puts exactly the bytes of a streamed load into the SDRAM (a 5 MB and the 38.8 MB Gakuensai image compared byte for byte), Dharma Doujou starts from it (ROM / RAM test), the vertical game's rotated frame buffer and the fast load share the DDR3 without a protocol error, and the size asked of the scaler equals the framework's integer scaling rule in 12 runs. Whole-machine regression of the registered read-mux selects: 16 D / C-board games and Grand Striker 2 byte for byte identical to the previous tree at the frames compared (the five I4300 boards differ later, by design).

## Download

**`Metro_MiSTer_20261014d.zip`**: unpack it over the root of the SD card (47 MRAs in `_Arcade/`, the three cores in `_Arcade/cores/`). No ROMs: use your MAME 0.289 romsets in
`/media/fat/games/mame/`. Delete older `metro*.rbf` files from `_Arcade/cores/`. If a game does not load with these MRAs, the 20261014b zip (MRAs without the address, cores
without fast loading) is the fallback; please say which Main_MiSTer you have.

| Core file | SDRAM module | Games |
|---|---|---|
| `metro_20261014d.rbf` | 32 MB | Dharma Doujou, Toride II, Gun Master, Pururun, Daitoride, Puzzli, The Karate Tournament, Lady Killer, Pang Pom's, Sky Alert, Last Fortress, Poitto!, Sankokushi, Mouja, Mahjong Doukyuusei (+ Special), Varia Metal |
| `metrod64_20261014d.rbf` | **64 MB** | Mouse Shooter GoGo, Bal Cube, Bang Bang Ball, Battle Bubble, Daitoride (YMF278B), Mahjong Gakuensai 1 / 2 |
| `metrof64_20261014c.rbf` | **64 MB** | Blazing Tornado, Grand Striker 2 |

Fitter: `metro` 75 % of the ALMs, timing met with +0.15 ns; `metrod64` 79 %, +0.13 ns (20261014c: +0.005 ns, which is why the read mux was pipelined); `metrof64` 72 %,
the 20261014c file (+0.30 ns; the same logic, its file keeps its date: the registered selects only buy margin).

## Known issues

* Mouse Shooter GoGo: small quirks (flashing lines in busy scenes, the title scroll); cause not found. Its whole-machine simulation equals MAME's picture at the frame checked.
* Daitoride (plain version): single torn scanlines on the rising rocks. The Karate Tournament: explosion rectangles (reported on an earlier build, not re-checked).
* Mahjong Gakuensai's settings are not saved. Bang Bang Ball and Battle Bubble run at 58.2 Hz (MAME: 60 Hz).
* Not supported: Puzzlet, Metabee Shot, Poitto! revision C (see the README).

Build instructions, simulation benches and credits are in the README. Licence: GPL-3.0-or-later. Credits for the fast load, Scale and CRT Adjust integration: the Metamorphic
Force core of this repository's owner, rmonic79's CRT Adjust, the MiSTer framework.

## Checksums (SHA-256)

```
7847ad4ec48d76bea452a444555cce16703cf9f10caf6245146c3028ab098109  Metro_MiSTer_20261014d.zip
35f05c2a489422f9196eb8eae785151992e7c667acc3a7b3cb11db0893c38994  metro_20261014d.rbf
ba9304a2a0419d0e9808039b18300016a0f3794ccebda1b0f4e33a43d8379582  metrod64_20261014d.rbf
ae9e8a0178909f335aa5a8b7c8a1e68d76665079013c388893c493fac7a5b2fa  metrof64_20261014c.rbf
```
