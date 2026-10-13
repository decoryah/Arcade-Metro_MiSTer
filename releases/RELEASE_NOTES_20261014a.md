# Metro for MiSTer 20261014a: Mahjong Gakuensai fixed

FPGA core for the Metro Corp. arcade boards (Imagetek I4100 / I4220 / I4300), 47 sets of 24 titles, written from MAME 0.289 and checked against it.

## What is new since 20261013a

* **Mahjong Gakuensai 1 / 2: the flashing blocks and garbled mouth patches on the girls are gone** (confirmed on a real MiSTer). The games start groups of blits a few lines apart and
  never wait for the blitter; the old core showed half a group for a frame or dropped a blit. Every blit is now queued (8 deep) and applied together with the palette, as MAME does.
* The same blitter queue is in Mahjong Doukyuusei, Doukyuusei Special and Mouja (checked in simulation only: Doukyuusei Special's portraits differed from MAME in 82 of 200 pictures
  before, 1 now).
* Only `metro` and `metrod64` changed. `metrof64` (Blazing Tornado, Grand Striker 2) is the 20261013a file, unchanged.

## Download

**`Metro_MiSTer_20261014a.zip`**: unpack it over the root of the SD card (47 MRAs in `_Arcade/`, the three cores in `_Arcade/cores/`). No ROMs: use your MAME 0.289 romsets in
`/media/fat/games/mame/`. Delete older `metro*.rbf` files from `_Arcade/cores/`.

| Core file | SDRAM module | Games |
|---|---|---|
| `metro_20261014a.rbf` | 32 MB | Dharma Doujou, Toride II, Gun Master, Pururun, Daitoride, Puzzli, The Karate Tournament, Lady Killer, Pang Pom's, Sky Alert, Last Fortress, Poitto!, Sankokushi, Mouja, Mahjong Doukyuusei (+ Special), Varia Metal |
| `metrod64_20261014a.rbf` | **64 MB** | Mouse Shooter GoGo, Bal Cube, Bang Bang Ball, Battle Bubble, Daitoride (YMF278B), Mahjong Gakuensai 1 / 2 |
| `metrof64_20261013a.rbf` | **64 MB** | Blazing Tornado, Grand Striker 2 |

## Known issues

* Mouse Shooter GoGo: small quirks (flashing lines in busy scenes, the title scroll); cause not found.
* Daitoride (plain version): single torn scanlines on the rising rocks. Mahjong Doukyuusei: a bright frame in some portrait scenes. The Karate Tournament: explosion rectangles
  (reported on an earlier build, not re-checked).
* Mahjong Gakuensai's settings are not saved. Bang Bang Ball and Battle Bubble run at 58.2 Hz (MAME: 60 Hz).
* Not supported: Puzzlet, Metabee Shot, Poitto! revision C (see the README).

Build instructions, simulation benches and credits are in the README. Licence: GPL-3.0-or-later.

## Checksums (SHA-256)

```
e28573c4b0d7688fd2b9c952751e726cbe51d98847a7cb219efd48e141be4b6a  Metro_MiSTer_20261014a.zip
c5dc40ba7be094c9b18d1a3b0e57d7232f0418b92598160638f9e9bd49cfec82  metro_20261014a.rbf
81a736e67810c68ec9da6df52822cf76dc7d742d9fecfa25dfb40ebc40957f20  metrod64_20261014a.rbf
a358ed6e81ea0cd0a972cf783394fb1b1987cebe3ba6150b5cb3a7fbfe14154f  metrof64_20261013a.rbf
```
