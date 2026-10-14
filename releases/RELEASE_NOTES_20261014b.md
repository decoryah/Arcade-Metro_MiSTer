# Metro for MiSTer 20261014b: Doukyuusei intro flashes and Gakuensai speech bubbles

FPGA core for the Metro Corp. arcade boards (Imagetek I4100 / I4220 / I4300), 47 sets of 24 titles, written from MAME 0.289 and checked against it.

## What is new since 20261014a

* **Mahjong Doukyuusei: the flashes in the intro are gone** (the black frame at the title / credits changes, the silhouette arriving a picture early). On the I4300 boards
  (Mahjong Doukyuusei, Doukyuusei Special, Mouja, Mahjong Gakuensai 1 / 2) a frame is now built the way MAME builds it: the game's tile writes are held until the frame is drawn,
  and the sprite list and the video registers are taken at the line MAME draws the frame at. In simulation, driven with MAME's own writes, Doukyuusei's intro (400 pictures,
  two of the changes) is identical to MAME in every picture; before, three were off.
* **Mahjong Gakuensai: the tutorial's speech bubbles no longer flash** (the sprite list was copied while the game was rewriting it): 0 of 200 pictures differ from MAME, was
  20 of 200; the play segment 0 of 200, was 11.
* Mahjong Doukyuusei Special's portraits, Mouja's blinking text and Gakuensai 1 / 2 also match MAME in every picture of the segments tried.
* The price: these five boards show the game's picture one frame (16.7 ms) later than before, which is where MAME shows it too. Nothing else is changed; the other 19 titles run
  as in 20261014a. Only `metro` and `metrod64` changed; `metrof64` is the 20261013a file.
* Cost in the FPGA: +1,500 ALMs (`metro` 75 %, `metrod64` 77 %), timing met with +0.10 ns of margin on both.

**Not tested on a real MiSTer yet** (simulation and replays of MAME's CPU writes only).

## Download

**`Metro_MiSTer_20261014b.zip`**: unpack it over the root of the SD card (47 MRAs in `_Arcade/`, the three cores in `_Arcade/cores/`). No ROMs: use your MAME 0.289 romsets in
`/media/fat/games/mame/`. Delete older `metro*.rbf` files from `_Arcade/cores/`.

| Core file | SDRAM module | Games |
|---|---|---|
| `metro_20261014b.rbf` | 32 MB | Dharma Doujou, Toride II, Gun Master, Pururun, Daitoride, Puzzli, The Karate Tournament, Lady Killer, Pang Pom's, Sky Alert, Last Fortress, Poitto!, Sankokushi, Mouja, Mahjong Doukyuusei (+ Special), Varia Metal |
| `metrod64_20261014b.rbf` | **64 MB** | Mouse Shooter GoGo, Bal Cube, Bang Bang Ball, Battle Bubble, Daitoride (YMF278B), Mahjong Gakuensai 1 / 2 |
| `metrof64_20261013a.rbf` | **64 MB** | Blazing Tornado, Grand Striker 2 |

## Known issues

* Mouse Shooter GoGo: small quirks (flashing lines in busy scenes, the title scroll); cause not found. Its whole-machine simulation equals MAME's picture at the frame checked.
* Daitoride (plain version): single torn scanlines on the rising rocks. The Karate Tournament: explosion rectangles (reported on an earlier build, not re-checked).
* Mahjong Gakuensai's settings are not saved. Bang Bang Ball and Battle Bubble run at 58.2 Hz (MAME: 60 Hz).
* Not supported: Puzzlet, Metabee Shot, Poitto! revision C (see the README).

Build instructions, simulation benches and credits are in the README. Licence: GPL-3.0-or-later.

## Checksums (SHA-256)

```
f82329c8bb065d709f6902db1a66717e409ad50a4feb3745d8c4433dc0b36388  Metro_MiSTer_20261014b.zip
05f404015ded43b5bd864334efc45417f4f7687d27cfece91f188fb768d2cd15  metro_20261014b.rbf
68b13abd960fe796db8d68a702f777f354a6366ccc74fb069626dec1b17a655b  metrod64_20261014b.rbf
a358ed6e81ea0cd0a972cf783394fb1b1987cebe3ba6150b5cb3a7fbfe14154f  metrof64_20261013a.rbf
```
