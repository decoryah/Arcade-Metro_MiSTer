# Metro hardware notes — Dharma Doujou first

Everything here is read from **MAME 0.289** (`ref/mame/src/mame/metro/metro.cpp`, `ref/mame/src/devices/video/imagetek_i4100.cpp`)
unless marked **UNVERIFIED** (MAME does not know it, or I have not checked it) or **QUESTION** (to be settled with a MAME Lua
script, per the method). Line numbers are 0.289. Do not use `master`: its `metro.cpp` is a different, shorter file.

Video chip internals (register map, tile/sprite formats, priorities, blitter) are **not** repeated here: they are in
`ref/Arcade-HyperDuel_MiSTer/docs/i4220_spec.md`, which traces them to the same `imagetek_i4100.cpp`. This file only records what
is specific to the Metro boards and to Dharma.

## 1. Dharma Doujou sets (0.289)

| MAME name | Region | GFX scrambled (`init_dharmak`) | Notes |
|---|---|---|---|
| `dharma` | World (wa) | yes | parent; ROM names `dd__wea5/6.u39/u42`, `dd__wa-*` |
| `dharmag` | Germany | yes | same GFX/sound ROMs as `dharma`, different 68000 ROMs |
| `dharmaj` | Japan | **no** | `dd_jc-5/6`, GFX `dd_jb-1..4` (different CRCs from the scrambled set) |
| `dharmak` | Korea (MTR527 PCB) | yes | different sound ROM (`8.bin`) and samples (`7.bin`) too |

All four: `metro_upd7810_state`, machine `dharma` (line 2994), input `dharma` (line 1751), 1994, Metro. `MACHINE_SUPPORTS_SAVE` only,
i.e. MAME does not flag the graphics or sound as imperfect.

## 2. Board and clocks (PCB notes above `ROM_START(dharma)`, lines 3943-3948, and the machine config)

| Part | Value | Source |
|---|---|---|
| Crystals | 24 MHz (near the 68000), **26.666 MHz (next to the I4220 and YM3012)**, 3.579545 MHz (YM2413) | PCB drawing above `ROM_START(dharma)`, lines 3921-3939 |
| 68000 / D78C10 / OKI derive from | the 24 MHz crystal | both CPUs "24/2", OKI "24/20" |
| 68000 | 12.000 MHz | `M68000(config, m_maincpu, 24_MHz_XTAL/2)` |
| NEC D78C10 (sound CPU) | 12.000 MHz | `UPD78C10(config, m_audiocpu, 24_MHz_XTAL/2)` (`metro_upd7810_sound`, line 2927; the Daitoride group uses a plain 12 MHz XTAL, line 2938). How the 78C10 divides it internally: **UNVERIFIED**, settle when writing the core. |
| YM2413 | 3.579545 MHz | `XTAL` |
| OKI M6295 | 1.200 MHz (24/20), pin 7 high => sample rate 1.2 MHz / 132 = 9090.9 Hz | `OKIM6295(... 24_MHz_XTAL/20, PIN7_HIGH)` |
| Imagetek I4220 | 26.666 MHz crystal on the PCB beside the chip; MAME's device clock is the same value | `I4220(config, m_vdp2, 26.666_MHz_XTAL)`; MAME defines the screen independently of it (next paragraph) |
| Sound mix in MAME | OKI 0.10, YM2413 0.90 (mono) | machine config |

**Video timing: MAME's number looks borrowed from a different clock.** `i4220_config` (line 2792): 392 x 263 total, 58.2328 Hz,
"HSync 15.32 kHz", visible 320 x 224. That is a 6.0 MHz dot clock (6.0 MHz / 392 = 15.31 kHz, within 0.1%), i.e. **24 MHz / 4**, which is
what the `i4100_config` device clock is (line 2780). The I4220 PCB has a **26.666 MHz** crystal next to the chip (above), and Hyper Duel's
author measured their I4220 board (also 26.666 MHz) at 26.666 / 4 = 6.6665 MHz, 424 x 261 = 60.24 Hz, with the CRTC programming the visible
window (their MAME report, mamedev/mame#15732, still open when I looked). The PCB note here says "VSync 60 Hz, HSync 15.55 kHz", which is
loose but is closer to that than to 58.23 Hz.
**UNVERIFIED hypothesis, to test, not assume:** Dharma runs the same 6.6665 MHz dot clock and 424 x 261 raster as Hyper Duel. Dharma does
**not** program the horizontal CRTC parameters (see section 4 / status.md), so its horizontal total cannot be read from the trace; it can
only come from a measurement, or from the shared-chip prior. Expose the choice as Hyper Duel does (native vs 60 Hz compat) rather than
hard-coding one.

## 3. 68000 memory map (`dharma_map`, line 587)

| Address | Size | Device |
|---|---|---|
| 0x000000-0x03FFFF | 256 KB | Program ROM (2 x 128 KB, byte-interleaved) |
| 0x400000-0x40FFFF | 64 KB | Work RAM, mirrored every 0x10000 up to 0x4FFFFF |
| 0x800000-0x87FFFF | 512 KB | Imagetek I4220, `v2_map` (see i4220_spec.md section 2; offsets are relative to 0x800000, so the sound-latch address 0x8788A9 is VDP offset 0x788A9) |
| 0x8788A9 (byte) | | **Sound command** write (see section 5) |
| 0xC00000 (word) | | `IN0`: coins/start/service/sound-busy |
| 0xC00001 (byte write) | | `soundstatus_w` — stores bit 0; **nothing in MAME reads it** (line 271; only saved) |
| 0xC00002 (word) | | `IN1`: P1 in low byte, P2 in high byte |
| 0xC00004 (word) | | `DSW0` (SW1 low byte, SW2 high byte) |
| 0xC00006 (word) | | `IN2` — all bits unknown, active low (reads 0xFFFF) |
| 0xC00002-0xC00009 (word writes) | | Coin counter: `coin_counter_w((offset>>1)&1, offset&1)`; value written is otherwise ignored |

IRQ wiring: the VDP's IRQ output goes to the 68000 **level 2** (autovector): `m_vdp2->irq_cb().set_inputline(m_maincpu, M68K_IRQ_2)`.

## 4. Imagetek I4220 as wired on Dharma

- Layout: `v2_map` at 0x800000. GFX region `vdp2` = 2 MB; the VDP's CPU-visible GFX window is at VDP offset 0x60000: word read
  `rom[offset*2 + 0x10000*rombank]`, `0xFFFF` past the end (`gfxrom_r`, line 738; bank register at VDP 0x788AA).
- Tilemap X offsets: default (0,0,0). (The Daitoride/Pururun/Puzzli/Gun Master group sets 2,2,2 — lines 2872/2961.)
- Sprite RAM is **not** buffered for Dharma (`set_spriteram_buffered(true)` appears only once in the file, line 3414, in another machine).
  Hyper Duel buffers it, so the RTL's `P_SPR_BUFFERED` must be 0 here. Re-check with a MAME run before relying on it. **QUESTION**
- IRQ controller (`imagetek_i4100.cpp:448-514`), 8-bit cause register, **1 = interrupt requested; enable register 1 = masked**,
  enable resets to 0xFF, VDP IRQ line = `|(cause & ~enable)`:
  - bit 0 — vblank: set at vblank start (`screen_eof`, vblank level 0)
  - bit 2 — blitter done: set 500 us after a blit (`blit_irq_level(2)`)
  - bit 4 — set by the 68000's periodic interrupt at **8 x 60 = 480 Hz** (`set_periodic_int(..., from_hz(8*60)); // ?`). The question
    mark is MAME's: the real source is unknown. On Hyper Duel the author's RTL (`i4220_vdp.sv` header) models cause bits 1 and 4
    being set on **every line except line 0**, and their README says that game requests an IRQ on every line (MAME misses ~14%). That is a
    different board and game, so it is a lead for what bit 4 might really be, not evidence for Dharma.
  - cause read at VDP 0x788A3, acknowledge = write 1s there (clears bits 4:0 only; bits 5-7 not controllable), enable at VDP 0x788A5 (byte write).
- **Measured in MAME 0.289 (`tools/lua/mtrace.lua`, 2620 frames, coin at 300; numbers in `docs/status.md`):**
  - the enable register is written **once**, `0x0A` (at frame 56): bits 1 and 3 masked, so **bits 0, 2 and 4 are live** (vblank, blitter,
    and the 480 Hz source). The game does rely on bit 4.
  - cause acknowledges: bit 0 about once per frame, bit 2 once per blit (7264 acks for 7264 blits), **bit 4 about 8 per frame** (21136 in
    2620 frames), i.e. the handler really runs at MAME's guessed 480 Hz and Dharma's logic can depend on that rate.
  - **What the bit-4 handler does (disassembled, section 4a): it only clears a RAM flag (`$40E04D`)** that the main loop arms once per frame
    and spins on. The real source of bit 4 is still unknown (MAME's 480 Hz is a guess, `// ?`; Hyper Duel's author models the bit as per-line
    on their board), **but for Dharma the rate barely matters: it only needs at least one bit-4 interrupt between the re-arm and the next
    vblank.** Eight per frame (MAME) satisfies that. By my own count of 68000 instruction timings (not measured) one handler entry is about
    430 cycles (~36 us at 12 MHz: save/restore 15 registers, three `btst`, ack, `clr.b`, `rte`), i.e. ~2% of a frame at 8 per frame, but
    over half of it if the source fired every line, which the game's pacing would not tolerate. So per-line is unlikely for Dharma.
    Keep the source a parameter of the VDP model and start with 8 per frame.
- **CRTC, decoded with the Hyper Duel author's scheme** (`{param[15:8], value[7:0]}` writes to 0x78880 inside an unlock bracket at 0x788A0):
  Dharma writes one bracket at frame 37: `0x00DF, 0x02F1, 0x04F9, 0x070B` = param 0 = 223 (active span 224), param 2 = 241 (vsync start),
  param 4 = 249 (vsync end), param 7 = **11 (first visible line)**. Hyper Duel's were 223 / 233 / 240 / 2. So the visible window is a
  per-game CRTC setting, MAME's single hard-coded 0..223 visarea cannot be right for both, and Dharma's picture is chip lines 11-234
  by this decode. The reference renderer (`docs/status.md`) shows the game's artwork continues to about chip line 234, matching that window's
  last line, so the hardware probably shows lines 11-234 and MAME's 0-223 view crops 11 lines of art off the bottom. **UNVERIFIED**; it needs a
  real-board capture to settle, so the displayed window will be an option in the core.
  The horizontal register (0x78890) only ever receives a boot-time counting sweep (0x017F, 0x0180, ... 327685 writes) while unlocked; there
  are no horizontal programming writes to decode.

## 4a. Dharma 68000 software structure (disassembled from `dharma.zip`, MAME's `unidasm`; addresses are ROM addresses)

Reset: SP 0x410000, PC 0x400. Autovectors: **levels 2-6 all go to 0x768** (level *n* vector is at `0x60 + 4n`); only level 2 is wired to the VDP.

Interrupt handler 0x768 (saves D0-D7/A0-A6, then tests the VDP cause byte at 0x8788A3 in this order, handling one source per entry):
- bit 0, vblank: calls a routine, acknowledges (`move.w #1,$8788A2`), copies six scroll values from RAM shadows (`$40E26E`, `$40E278`, `$40E282`,
  `$40E28C`, `$40E296`, `$40E2A0`, each `& 0x7FF`) to the scroll registers `$878870-$87887A`, increments the frame counter `$40E001`, and sets
  **bit 7 of `$40E000`** (the "vblank happened" flag).
- bit 2, blitter done: acknowledges, then pops the next entry of a blit queue (write index `$40E050`, read index `$40E052`, 6-byte entries at
  `$40E054`, wraps at 0x1E0) into the blitter registers `$878840`, `$878844`, `$878848` and starts it by writing 0xFFFF to `$87884C`; sets
  `$40E04F = 1` while a blit is in flight, clears it when the queue is empty. So the blitter-done interrupt is what chains queued blits.
- bit 4: acknowledges and does `clr.b $40E04D`. Nothing else.

Main loop (0x634-0x6BC): wait `$40E000` bit 7 (vblank) -> wait `$40E04D == 0` (bit-4 tick) -> run the frame's logic (several `jsr`s) -> wait
`$40E04F == 0` (blit queue drained) -> disable interrupts, write `$8788AC` (screen control) with bits 0x700 set, drop those bits from the shadow
-> `$40E04D = 1` (arm the tick) -> enable interrupts -> clear `$40E000` bit 7 -> loop. The tick is armed at the end of a frame and normally
fires several times before the next vblank, so the tick wait is a no-op in steady state.

Initialisation (0x628-0x630): writes 0x0A to the IRQ enable register `$8788A4`, then `move #$2100,SR` (interrupt mask 1, so level 2 is accepted).
The title screen idles in the vblank-wait loop until a coin arrives.

## 5. Sound CPU interface (the part with no FPGA reference)

Main CPU -> sound CPU (lines 235-256):
1. 68000 writes a byte to 0x8788A9. MAME latches it (`m_sound_data`, scheduler-synchronised), sets `m_busy_sndcpu = true`, and pulses the
   D78C10's **NMI**.
2. The D78C10 reads the byte through its serial input **RXD**, LSB first; MAME shifts the latch right on every RXD read
   (`TODO: shift on SCK falling edges` in the source — the real part is clocked by the 78C10's serial clock). **UNVERIFIED** how many
   RXD reads/bits a command takes; trace it from MAME before writing hardware for it.
3. The 78C10 drives port B bit 7 high->low to clear busy ("clock latch for message to main CPU"). Port A is the shared 8-bit data bus.

Sound CPU -> main CPU: `IN0` bit 7 (`COINS_SOUND`, line 1153) reads **1 while busy** (`custom_soundstatus_r`). The game polls this.

D78C10 program space (`upd7810_map`, line 437): `0x0000-0x3FFF` ROM; `0x4000-0x7FFF` banked ROM; `0x8000-0x87FF` 2 KB RAM.
`audiocpu` region is 128 KB (`dd__wa-8.u9`, 0x20000); the bank number is `(portC >> 4) & 0x03` for this config
(`upd7810_rombank_w<0x03>`, line 2935; the Daitoride group uses `<0x07>`, line 2946), so only the first 64 KB of the ROM is reachable on Dharma. (`machine_start` configures 8 entries.)
The ROM note says 11xxxxxxxxxxxxxxx reads as 0xFF, i.e. the top quarter of the 128 KB image is blank.

Port B (`upd7810_portb_w`, line 291), edges are **1 -> 0 on a strobe**:

| Bit | Function |
|---|---|
| 7 | !clock latch for message to main CPU: falling edge clears the busy flag |
| 5 | !clock YM2413 I/O: on falling edge, if bit 2 is low, write port A to the YM2413 (register/data select = bit 1) |
| 4 | !clock M6295 I/O (chip select for the next two) |
| 3 | !enable read from 6295: falling edge with bit 4 low latches `oki.read()` into port A |
| 2 | !enable write: falling edge with bit 4 low writes port A to the M6295 (also gates the YM2413 write above) |
| 1 | YM2413 register (0) / data (1) select |

Port C bits 5:4 select the ROM bank. No sound-chip IRQ is wired to the 78C10 in the Dharma config (the Daitoride-style configs wire the YM2151 IRQ to its INTF2, lines 2969 and 3275).

## 6. ROM layout (what the ROM tool and MRA must produce)

| Region | Size | Content |
|---|---|---|
| `maincpu` | 256 KB | `ROM_LOAD16_BYTE` x2: `u39` at even bytes, `u42` at odd (128 KB each) |
| `audiocpu` | 128 KB | one ROM |
| `vdp2` | 2 MB | `ROM_LOAD64_WORD` x4, 512 KB each: `u4` -> bytes 0-1, `u5` -> 2-3, `u10` -> 4-5, `u11` -> 6-7 of each 8-byte group |
| `oki` | 256 KB | one ROM, no banking on Dharma |

**GFX descramble (`init_dharmak`, line 5411), applies to `dharma`, `dharmag`, `dharmak` but not `dharmaj`.** For each 4-byte group at
index i (i multiple of 4) over the whole 2 MB: `b[i+1] = bitswap8(b[i+1], 7,3,2,4,5,6,1,0)` and
`b[i+3] = bitswap8(b[i+3], 7,2,5,4,3,6,1,0)` (MAME `bitswap<8>` lists source-bit indices from output bit 7 down to bit 0).
An MRA cannot do this, so it is either done by the ROM builder (separate images per set) or by a per-game byte permute on the SDRAM
read path selected by an MRA byte. Decide when the ROM path is built.

## 7. Inputs and DIPs (`INPUT_PORTS_START(dharma)`, line 1751)

`IN0` (0xC00000), active low unless noted: bit0 Service1, bit1 Tilt, bit2 Coin1, bit3 Coin2, bit4 Start1, bit5 Start2, bit6 unknown (active
high), bit7 sound busy (active high, from the sound CPU).
`IN1` (0xC00002): P1 low byte, P2 high byte, each: up, down, left, right (bits 0-3), button1 (bit 4); bits 5-7 unknown. A second and third
button exist only in test mode.
`DSW0` (0xC00004) — SW1 (low byte): coin A bits 0-2, coin B bits 3-5 (eight settings each, 0 = Free Play), flip screen bit 6, service
bit 7. SW2 (high byte): difficulty bits 8-9 (Easy 2 / Normal 3 / Hard 1 / Hardest 0), timer ("crab" speed) bits 10-11, two-player game
cost bit 12, allow continue bit 13, demo sounds bit 14, freeze (cheat) bit 15. Full coinage tables: `COINAGE_SERVICE_LOC`, line 1164.

## 8. FPGA resource notes

- VDP memories (from `i4220_vdp.sv`): three layer VRAMs of 64K x 16 = 128 KB each (384 KB), 8 KB palette, 8 KB scratch RAM, 4 KB sprite RAM (x2 if
  buffered; Dharma does not need the second), 2 KB tile table, plus renderer line buffers.
- Cyclone V on the DE10-Nano: **553 M10K blocks** (Hyper Duel's fitter error 170048). One 128 KB VRAM is ~103 blocks if packed at 10,240
  bits per block and 128 if only 8,192 bits are usable (16-bit-wide modes), so the three VRAMs alone cost **308-384 of 553**. Hyper Duel
  hit this wall and moved a shared RAM to SDRAM (`docs/plan_m10k_fit_shared3_sdram.md`). Dharma adds 64 KB work RAM (~52 blocks)
  and 2 KB for the 78C10, with no second 68000 and no shared RAM, so it should fit, but it is a constraint to budget, not an afterthought.
- GFX data is 2 MB (`GFX_AW = 22` in Hyper Duel is enough); program 256 KB, 78C10 ROM 128 KB, samples 256 KB all go in SDRAM.

## 9. Questions to settle with MAME Lua before RTL

1. ~~VDP IRQ enable mask and cause bits~~ **answered** (section 4): enable 0x0A, bits 0/2/4 live and acknowledged.
2. ~~Whether Dharma relies on blitter-done~~ **answered**: yes, the handler chains queued blits (section 4a). Still open: how sensitive the game
   is to the 500 us blit-done delay.
   ~~What the bit-4 handler does~~ **answered**: clears one RAM flag; only "at least one per frame" matters (section 4).
3. How many RXD reads/bits one sound command consumes, and whether anything else on the 78C10 port C/INT lines matters (section 5).
4. Sprite RAM buffering as seen in actual frames (section 4).
5. Real frame timing vs MAME (section 2): only a PCB measurement can settle it.

## 10. Toride II (`toride2g`, machine `toride2g`, 0.289): the second board of family B

Same board family as Dharma (MTR5260-A: I4220 + uPD78C10 + YM2413 + M6295), machine config identical to `dharma` in every respect that matters
(`M68000` 24/2 MHz, periodic interrupt 8 x 60 Hz, I4220 `irq` -> level 2, `vblank_irq`, `metro_upd7810_sound`, `i4220_config` 392 x 263 / 320 x 224) except two things:

| | Dharma | Toride II |
|---|---|---|
| Program ROM | 0x000000-0x03FFFF (256 KB) | 0x000000-0x07FFFF (512 KB) |
| I/O ports (IN0, IN1, DSW0, IN2 at +0, +2, +4, +6) | 0xC00000 | **0x800000** (`soundstatus_w` at 0x800001, coin lockout writes 0x800002-0x800009) |
| Imagetek I4220 `v2_map` | 0x800000 | **0xC00000** |
| Sound command (byte write) | 0x8788A9 | **0xC788A9** |
| OKI M6295 pin 7 | high (rate = clock / 132) | same, high: `OKIM6295(... PIN7_HIGH)` ("clock frequency & pin 7 not verified"). *Corrected 2026-10-07: this row used to say low, /165, which is Sky Alert's line in the file; build 20261007b ran Toride II's OKI 20 % slow* |
| GFX | 0x200000 in `vdp2`, scrambled by `init_dharmak` | 0x200000, plain (`empty_init`) |
| Work RAM | 0x400000-0x40FFFF mirrored to 0x4FFFFF | same |

Everything else (sound board, interrupts, the I4220's internals) is Dharma's. Five sets: `toride2g` (Japan, parent), `toride2gg` (German), `toride2gk` (Korea), `toride2j`
(Japan, revision K), `toride2ji` (Japan, revision I). The driver flags `MACHINE_IMPERFECT_GRAPHICS` (graphics MAME does not get quite right; the oracle is MAME all the same).
DIP switches (SW2): Timer Speed, Tile Arrangement, Retry Level On Continue, 2 Players Game, Allow Continue, Demo Sounds; SW1 is the same coinage / flip / service block.
Buttons: IN1 as Dharma (button 1 only; buttons 2/3 in test mode). The core takes the map from the image's configuration byte 0 (board 2).

Sankokushi (`3kokushi`, also family B) is **not** the same machine: `i4220_config_320x240`, `kokushi_map`, and the Karate Tournament style external IRQ 5 enable
(`ext_irq5_enable_w`, `karatour_vblank_irq`). It waits for its own IRQ model.


## 11. Family B2 (YM2151): Gun Master, Pururun (2 sets), Daitoride, Puzzli (2 sets) -- machines `pururun`, `daitorid`, `puzzli`, `puzzlia` (0.289)

The same I4220 board family with the YM2413 replaced by a **YM2151** (3.579545 MHz, `ymsnd.irq_handler() -> UPD7810_INTF2`, mono route 0.80) and the OKI routed at 0.40
(`OKIM6295(... 24_MHz_XTAL/20 or 1200000, PIN7_HIGH)`: /132 as Dharma). Everything is horizontal (ROT0): 320 x 224 in 392 x 263 as before (`i4220_config`).
The sound board is `daitorid_upd7810_sound`: uPD78C10 at 12 MHz as before, `upd7810_porta_r/w`, **`daitorid_portb_w`** (below), and `upd7810_rombank_w<0x07>`
(port C bits 6:4 pick one of 8 banks of 16 KB: all 128 KB of the sound program; Dharma's mask is 3).

`daitorid_portb_w` (the difference from `upd7810_portb_w`): bit 7 clocks the latch to the main CPU (1 -> 0 clears busy); **bit 6 is the YM2151 strobe** (on 1 -> 0: bit 2 low writes
port A to the register / data port selected by bit 1; bit 3 low reads port A from the YM2151: `read(bit 1)`, i.e. the status on odd offsets); bit 5 is unused; bits 4 / 3 / 2
are the OKI select / read / write exactly as on the YM2413 boards. The YM2151's IRQ line is the CPU's INTF2 (`upd7810_device::execute_set_input`: the request bit 0x10
is set when the logical line goes 0 -> 1, `m_int2 = !state` is what a read of port C bit 3 returns).

| machine (sets) | 68000 | map | tilemap X offset | interrupts |
|---|---|---|---|---|
| `pururun` (gunmast, pururun, pururuna) | 24 MHz / 2 = 12 MHz | **C**: ROM 0-0x7FFFF, I/O 0x400000, RAM 0x800000 (mirrored to 0x8FFFFF), I4220 0xC00000, sound command 0xC788A9 | 0 | periodic 8 x 60 Hz (bit 4) + vblank (bit 0), I4220 -> level 2 |
| `daitorid` (daitorid) | **32 MHz / 2 = 16 MHz** | **D**: ROM 0-0x3FFFF, I4220 0x400000 (sound command 0x4788A9), RAM 0x800000, I/O 0xC00000 | **2** (`set_tmap_xoffsets(2,2,2)`; it also sets the flip offsets to -2) | as above |
| `puzzli` (puzzli = revision B) | 16 MHz | D | 2 | **`bangball_scanline`** instead of the periodic one (below) |
| `puzzlia` (puzzlia = revision A) | 16 MHz | **C** (`pururun_map`) | 2 | as puzzli |

`bangball_scanline` (a timer on every scanline of the screen): at scanline 224 `set_irq(4)` and `screen_eof` (the vblank bit 0); on every scanline below 224, while bit 1 of the
chip's IRQ-enable register is clear, `set_irq(1)` ("hblank"; Puzzli uses it for the water effect during play, `VIDEO_UPDATE_SCANLINE` is set on its screen). The 12-vs-16 MHz CPU does
not change the 58.2328 Hz frame (the I4220 has its own crystal).

Inputs: IN0 as Dharma (service, tilt, coin 1/2, start 1/2, bit 7 sound busy) at the I/O base; IN1 joysticks with up/down/left/right, **Gun Master: buttons 1, 2, 3** (the others: 1 and 2, with 3
in test mode only); DSW0 (SW1 coinage / flip / service, SW2 per game); IN2 unused. ROM sizes: the 68000 program 2 x 128 KB (Daitoride, Pururun, Puzzli) or 2 x 256 KB (Gun Master); sound
program 128 KB; graphics 4 x 512 KB `ROM_LOAD64_WORD` into the 2 MB `vdp2` region, plain (`empty_init`); OKI samples 256 KB. The image builder and the MRAs needed no layout change
(`tools/metro_rom.py` BOARDS, config byte 0: 3 = pururun, 4 = daitorid, 5 = puzzli, 6 = puzzlia).


## 12. Family A (Imagetek I4100): Karate Tournament, Pang Pom's, Sky Alert, Lady Killer / Moeyo Gonta, Last Fortress, Poitto! -- machines `karatour`, `pangpoms`, `skyalert`, `lastfort`, `lastforg`, `poitto` (0.289)

Same sound board as Dharma (uPD78C10 + YM2413 + M6295, 12 MHz 68000, 480 Hz periodic interrupt). The video chip is the **I4100** (24 MHz crystal): the I4220's address map with the video registers at 0x788xx (the I4220
also answers there, "Puzzlet compatibility mode", except the sprite priority at 0x78802 which is the I4100's own), **no 8bpp and no 16x16 tiles** (`has_ext_tiles` false: `m_support_8bpp`, `m_support_16x16`), and a picture
size that comes from its CRTC but that MAME sets per machine: **360 x 224** (`i4100_config_360x224`: Last Fortress, Pang Pom's, Poitto, Sky Alert) or **320 x 240** (`i4100_config`: Karate Tournament, Lady Killer, Moeyo Gonta);
the raster is 392 x 263 as always. The vblank interrupt comes at the end of the picture (line 224 or 240). `video`: `rtl/metro_vdp.sv` `i_i4100`, `i_wide`, `i_tall`, `rtl/metro_render.sv` `i_width`, `i_height`, `i_ext_tiles`
(the flip mirror constants are width - 2 / height - 2); 49 + 7 real frames of the six boards (attract, coin, play with random joystick) equal MAME's picture pixel for pixel (`tools/vtest.sh` with `WIDE=1`/`TALL=1`, `I4100=1`).

| machine | sets | 68000 map | I/O layout | picture | OKI pin 7 | external vblank irq (cause bit 5) | rotation |
|---|---|---|---|---|---|---|---|
| `karatour` (board 7) | karatour, karatourj, ladykill, moegonta | ROM 512 K, **I/O 0x400000**, I4100 0x800000, RAM 0xF00000 (mirrored to 0xFFFFFF) | 2 | 320 x 240 | high (/132) | yes | karate ROT0, **lady killer ROT90** |
| `pangpoms` (8) | pangpoms, pangpomsm, pangpomsn | ROM 256 K, I4100 0x400000, I/O 0x800000, RAM 0xC00000 | 1 | 360 x 224 | high | no | ROT0 |
| `skyalert` (9) | skyalert | ROM 256 K, I/O 0x400000, I4100 0x800000, RAM 0xC00000 | 1 | 360 x 224 | **low (/165)** | no | **ROT270** |
| `lastfort` (10) | lastfort, lastforte, lastfortea, lastfortk | ROM 256 K, RAM 0x400000, I4100 0x800000, I/O 0xC00000 | 1 | 360 x 224 | **low** | no | ROT0 |
| `lastforg` (11) | lastfortj, lastfortg (VG460 board) | ROM 512 K, I/O 0x400000, **I4100 0x880000** (sound command 0x8F88A9), RAM 0xC00000 | 2 | 360 x 224 | high | yes | ROT0 |
| `poitto` (12) | poitto (poittoc does not work in MAME: a program ROM is missing) | **Toride II's map**: RAM 0x400000, I/O 0x800000, I4100 0xC00000 | 0 | 360 x 224 | high | no | ROT0 |

I/O layouts (word index = address bits 3..1 of the 16-byte block):
* **0** (Dharma, Toride II, the YM2151 boards): IN0 = coins/start/service with **bit 7 = sound CPU busy**, IN1 = P1 joystick low byte + P2 high byte, DSW0 (16 bit), IN2 unused.
* **1** (Pang Pom's, Sky Alert, Last Fortress VG420): word 0 odd byte `soundstatus_r` (1 = the sound CPU is idle), 2 = IN0 coins, 3 = IN1 P1 joystick (low byte), 4 = IN2 P2 joystick, 5 = DSW0 (SW1: coinage, flip, service), 6 = DSW1
  (SW2: game options), 7 = IN3 (0xFFFF).
* **2** (Karate Tournament, Lady Killer, Last Fortress VG460): word 0 `soundstatus`, 1 = IN0 = **P2** joystick, 2 = IN1 coins, 3 = DSW0 (SW2 game options), 5 = DSW1 (SW1 coinage, **flip**, service), 6 = IN2 = P1 joystick.
Unspecified bits read 0 (MAME). The flip DIP is bit 6 of DSW0 (layouts 0, 1) or of DSW1 (layout 2). The MRAs carry both DIP ports: `<switches default="..">` has 4 bytes, DSW1 as bits 16-31 (`Metro.sv` `sw[0..3]`).

Karate Tournament, Lady Killer and Last Fortress VG460 (and Sankokushi, I4220) use `karatour_vblank_irq`: at the start of the vblank the chip's vblank interrupt (cause bit 0) **and, if the game has set bit 8 of the screen
control register (`ext_ctrl_0`), cause bit 5** are raised; bit 5 is taken back when the vblank ends, 1500 us later (the screen's `set_vblank_time`), and the CPU's acknowledge cannot clear it (the chip controls only bits 4:0; the games
write 0xFFEA to the cause register); the games need it "for updating scroll registers" (MAME comment). `rtl/metro_vdp.sv` `i_ext5`.
`init_karatour` only saves `m_ext_irq_enable`: no ROM data changes. Region sizes: maincpu 0x40000 or 0x80000, audiocpu 0x20000, vdp (the I4100's graphics region) 1 / 2 / 4 MB, oki 0x40000; **all 16 sets build to regions identical
to MAME's** (`tools/metro_rom.py check`), the flat image layout is unchanged (board ids 7-12).

**Sankokushi (`sankokushi`, board 13, set `3kokushi`)** is the same board with an **I4220** (so 8bpp and 16x16 tiles exist), 320 x 240 and the `karatour_vblank_irq` external interrupt: ROM 512 K, RAM 0x700000 (mirrored to 0x7FFFFF),
video chip 0x800000, I/O 0xC00000 in layout 0 (like Dharma: flip is DSW0 bit 6), OKI pin 7 high. Seven frozen MAME frames (attract and play) are pixel-identical in the VDP bench (`TALL=1`).

**Whole-machine checks against MAME (frames 100 and 250 after a coin at 300 and a start at 400; `sim/run_sys.sh` with `SDR=1`, `tools/metro_syscmp.py`):** at frame 100 the VRAM, palette, sprite RAM, tile table and registers of Poitto, Pang Pom's,
Last Fortress (both boards), Sky Alert, Lady Killer and Sankokushi equal MAME's word for word (and the pictures of the first five, pixel for pixel); Karate Tournament shows the same intro explosion a few animation frames apart, Lady Killer's raster-scrolled picture
differs in some lines, Sankokushi in 3023 pixels. At frame 250 the memories still agree except for fade steps and animation phase (Last Fortress: every palette entry is one fade step (2 of 31) off MAME's; Karate Tournament's ranking
screen equals MAME's except for the background animation), i.e. the game runs MAME's code path in step to within a few frames of start-up phase. The sound hardware is Dharma's, with the uPD78C10 handlers generated from MAME's own source (`docs/status.md`,
"Sound CPU"), so the family A sound programs need no new CPU work; the OKI sample-rate pin (`i_oki_ss`) is low on Sky Alert and Last Fortress VG420.

**Rotated games (Sky Alert ROT270, Lady Killer and Moeyo Gonta ROT90):** the framework's `screen_rotate` (`sys/arcade_video.v`) copies the scaled picture into a DDR3 framebuffer rotated by 90 degrees and the scaler shows that; it needs `MISTER_FB` (`Metro.qsf`) so that
the `FB_*` ports exist and `DDRAM_*` are driven by it. `Metro.sv`: `no_rotate = status[2] | direct_video | (cfg_rot is 0 or 2)`, `rotate_ccw = (cfg_rot == 3)` (ROT90 = clockwise = `rotate_ccw` 0), OSD `Rotate screen` (On / Off, hidden for horizontal games),
and the aspect ratio of `video_freak` is 3:4 when rotating. Not yet tried on hardware.

## 13. Family D (Imagetek I4300, no sound CPU): Mouja, Mahjong Doukyuusei, Doukyuusei Special, Gakuensai 1 / 2 -- machines `mouja`, `dokyusei`, `dokyusp`, `gakusai`, `gakusai2` (0.289)

A 68000 (16 MHz: Mouja, Doukyuusei, Doukyuusei Special at 32 MHz / 2; 13.333 MHz: Gakuensai) **drives the YM2413 and the OKI M6295 itself** (no uPD78C10), the video chip is the **I4300** (`imagetek_i4300_device`, 26.666 MHz or 32 MHz), 392 x 263 raster at 58.2328 Hz as
every Metro board; pictures 320 x 224 (Mouja, Doukyuusei), 384 x 224 (Doukyuusei Special), 320 x 240 (Gakuensai).

**The I4300's register map** (`v3_map`; the memories, sprite / layer registers at 0x797xx, blitter at 0x78840, window at 0x78860 are as the I4220's): crtc unlock 0x78800, horizontal 0x78802, vertical 0x78804; screen x offset 0x78808, y offset 0x7880A (reversed against the I4220);
screen control 0x7880E; **interrupt level of each cause bit 0x78810..0x7881F (byte, one a word), interrupt vector of each level 0x78820..0x7882F**, enable 0x78831, cause 0x78833; scroll 0x78850 (six words), window 0x78860, rom bank 0x78870.
`rtl/metro_vdp.sv` folds this onto the I4220 layout (`v3map`) and adds the levels / vectors. The vblank sets cause bit 1 (`set_vblank_irq_level(1)`), the blitter's end bit 2 (Mouja) or 3 (the others), there is **no 480 Hz periodic interrupt**; the chip's
output is the **highest level among the pending, unmasked causes** (`update_irq_state`), the 68000 takes it as that interrupt level (`ipl_w`: only that IPL line high) and gets the **vector from the chip at the interrupt acknowledge** (`cpu_space_map`: 0xFFFFF0 + 2 x level, the vector of that level).
Mouja has a programmable timer interrupt too (cause bit 0, `irq_timer_ctrl_w` at VDP + 0x78834: 58 + (0xFF - data) / 2.2 Hz, the first one at once).

| machine | 68000 map | ports (inside the VDP window) | sound | EEPROM |
|---|---|---|---|---|
| `dokyusei` (board 14) | ROM 256 K, I4300 0x400000, RAM 0xF00000 (mirrored) | VDP + 0x78880 mahjong matrix, +82 IN0 (bit 1 coin 1), +84 DSW0, +86 DSW1, +88 matrix select (write) | YM2413 0xC00001 / 3, OKI 0xD00001, OKI bank high 0x800001 (bit 0), low 0xA00001 (bits 2:0): 256 KB banks of the 1 MB region; OKI 1.056 MHz (8 kHz) | none |
| `mouja` (15) | ROM 512 K, I4300 0x400000, RAM 0xF00000 | +0 IN0 (joysticks, buttons), +2 IN1 (starts, coins, service), +4 DSW0, +6 IN2, +0x78834 timer | YM2413 0xC00001 / 3, OKI 0xD00000 / 1 (the first 128 KB fixed, the upper 128 KB of its 256 KB window banked by 0x800001 bits 5:3: 8 banks of 128 KB of the 1 MB); OKI 2.0625 MHz (15.6 kHz) | none |
| `dokyusp` | ROM 256 K, I4300 0x200000 | as Doukyuusei, at 0x278880 | YM2413 0x600001 / 3, OKI 0x700001, bank low 0x500001; OKI 2.112 MHz | 93C46 (`metro_eeprom.sv`; reset 0xC00001, data 0xD00001; defaults from the image at 0x100, not saved) |
| `gakusai` / `gakusai2` | ROM 512 K, I4300 0x200000 / 0x600000 | as Doukyuusei (no DIPs) | YM2413, OKI, banks hi / lo | 93C46 (not done) |

The mahjong panel (`gakusai_state::input_r`): a 5-row matrix, the 68000 writes a row-select word (bit n low = row n selected) and reads `((AND of the selected rows, six bits) << 1) | 0xFF81`, 0 = pressed. Row 0: A E I M Kan Start; row 1: B F J N Reach;
row 2: C G K Chi Ron; row 3: D H L Pon; row 4: unused (one player). The core maps MAME's default keys: letters A-N, Left Ctrl = Kan, Left Shift = Reach, Space = Chi, Left Alt = Pon, Z = Ron, 1 = Start, 5 = Coin (`Metro.sv`).
**Memory needs**: the GFX regions are 4 MB (Mouja), 8 MB (Doukyuusei), 16 MB (Doukyuusei Special), 32 MB (Gakuensai x2) and the OKI samples 1 / 2 / 4 MB: the image is `maincpu` (0x10000), GFX (0x100000, its size), OKI (after the GFX) -- 6 MB / 10 MB / 18 MB / 36.5 MB;
a 32 MB SDRAM module holds the first three, **Gakuensai needs a 64 MB module** (and a controller that addresses it: not done). `tools/metro_rom.py` `layout_for`, `Metro.sv` `oki_wbase`, `rtl/metro_sdram.sv` (`i_gfx_addr` 24 bits, `i_oki_addr` 22 bits, `i_oki_wbase`), `GFX_AW` 24, image bytes 3:6 = the GFX size.
**Done in 20261009a**: `dokyusp` (384-pixel picture, 93C46 EEPROM kept while the core runs, not saved). **Not done**: `gakusai`, `gakusai2` (memory, EEPROM). Dokyusei's self-test (DIP "Self Test", default off) reads the whole GFX ROM through the 64 KB window (about 5 s at 68000 speed, the first 5 s of the run): with MAME's DIP defaults it is skipped.

## 14. Varia Metal (Imagetek I4220, ES8712 + MSM6585 + OKI): machines `vmetal`, `vmetaln` (0.289)

Excellent System's board (ES-9309B-B). 68000 at 16 MHz, 1 MB program ROM (2 x 512 KB), **304 x 224, ROT90**, no sound CPU: the 68000 drives an OKI M6295 (1 MHz, pin 7 high, routed at 0.5) and an **ES8712** address counter that feeds a **MSM6585** (640 kHz, prescaler 40: VCK = 16 kHz, 12-bit output, routed at 1.0).
Map (`vmetal_state::main_map`): ROM 0..FFFFF; video chip 0x100000; IN0 (word) 0x200000, SYSTEM 0x200002; control register = the byte 0x200001 (bit 4 = ES8712 sample ROM bank, bit 6 = the gate of the ES8712's interrupt, bits 0-3 coin counters / lockouts); DIPs 0x300000..0x31FFFF read **one bit per read**
(`balcube_dsw_r`: every address bit b that is 0 puts bit b of DSW0 on data bit 6 and bit b of the second bank "IN2" on data bit 7); OKI 0x400001 (r/w) and 0x400003 (w); ES8712 0x500000..D (odd bytes: start low / mid / high, end low / mid / high, go = register 6; a write of the even byte 0x500000 resets it); RAM 0xF00000 (mirrored).
Interrupts: the video chip is level 1 (vblank + the blitter), the ES8712's end-of-sample line is level 3 (only while the control register's bit 6 is set).
**ES8712 / MSM6585** (`rtl/metro_es8712.sv`, MAME `es8712.cpp` + `msm5205.cpp`): start / end are 20-bit byte addresses in a 1 MB bank (two banks, 2 MB); a play starts at start (only if start < end and not already playing), each VCK first hands the MSM the next nibble - **the HIGH nibble of a byte first, then the low** (found by correlating the decoded ROM with MAME's recording; the source's select line is not in the reference tree) - then the MSM decodes: signal += diff(step, nibble) (clamped to -2048..2047), step += {-1,-1,-1,-1,2,4,6,8}[nibble & 7] (clamped 0..48); when the address passes the end (or 0x100000) the MSM is reset (signal 0) and the interrupt is raised until the next play / reset; a play with start >= end while playing stops without a reset (the MSM keeps decoding its last nibble). MAME's wav = signal x 8.
The sample bytes come through the OKI's SDRAM client (`metro_okimux.sv`: one byte every 6000 clocks steals the port). Image (`tools/metro_rom.py`): gfx at 0x100000 (8 MB), program after it, OKI 512 KB, ES8712 2 MB (12.5 MB); `Metro.sv` `mrom_wbase` / `oki_wbase`. The second DIP bank is MAME's port "IN2" (MRA bytes 2 and 3).
Checked in simulation: frozen video 7 of 7, whole machine identical at frames 100-600, 41 of 41 sound writes equal MAME's, ES8712 output equal to a Python decoder (1.000) and 0.94 correlated with MAME's recording (`docs/status.md`, "Varia Metal").

## 15. Family F (Imagetek I4220 + Konami 053936, Z80 + YM2610): Blazing Tornado, Grand Striker 2 (2 sets) -- machines `blzntrnd`, `gstrik2` (0.289)

Human Amusement's HUM-002 / HUM-003 boards. 68000 at 16 MHz with **2 MB of program ROM** (4 x 512 KB, ROM_LOAD16_BYTE), an Imagetek I4220 (26.666 MHz, **304 x 224**, vblank cause 0 / blitter cause 3 / one interrupt line = 68000 level 1, ext. interrupt 5 on vblank enabled by screen control bit 8 like Karate Tournament, **buffered sprite RAM**, Grand Striker 2 also `set_tmap_xoffsets(0, 8, 0)`: layer 1 is 8 dots to the right), a **Konami 053936 "PSAC2"** rotate / zoom plane behind the I4220's layers, and a sound board of a Z80 at 8 MHz with a **YM2610** at 8 MHz.

Map (`blzntrnd_state::main_map`): ROM 0..1FFFFF; video chip 0x200000 (the I4220's v2 map); 053936 tile map RAM 0x400000..43FFFF (256 KB, write also marks the tile dirty), line RAM 0x500000..500FFF (write only), control 0x600000..60001F (write only); DSW0 0xE00000, DSW1 0xE00002 (a write: the sound command, upper byte), IN0 0xE00004 (P1 in the low byte, P2 in the high: up, down, left, right, buttons 1-3), IN1 0xE00006 (unused), IN2 0xE00008 (bit 0 service 1, 1 service, 2 coin 1, 3 coin 2, 4 start 1, 5 start 2); RAM 0xF00000..F0FFFF mirrored to 0xFFFFFF.

**The plane** (`metro_v.cpp`: `blzntrnd_state::screen_update`: fill with the I4220's background pen, `k053936->zoom_draw(...)` of the tilemap, then `vdp2->draw_foreground`): a tilemap of the RAM words (code & 0x7FFF, colour 0xE of the 8bpp `gfx2` ROM = palette 0xE00 + pen, no transparency): Blazing Tornado 8 x 8 tiles 256 x 512 scanned linearly, **Grand Striker 2 16 x 16 tiles 128 x 256 with `tilemap_scan_gstrik2`** (word offset = (row & 0x40) >> 6 | col << 1 | (row & 0x80) << 1 | (row & 0x3F) << 9, tile = code >> 2; the ROM tile is four 8 x 8 quadrants TL TR BL BR of 64 bytes). `k053936_device::zoom_draw` -> `tilemap_t::draw_roz` **without wrap-around**: ctrl[7] bit 6 clear = simple mode (start ctrl 0 / 1, per row step 2 / 3, per dot step 4 / 5, ctrl[6] bits 14 / 6 multiply the steps by 256), set = "super" mode: a start (words 0 / 1 + ctrl 0 / 1) and a dot step (words 2 / 3, ctrl[6] bits 15 / 7 x256) per row from the line RAM at ((row - yoff) & 0x1FF) * 4; 32-bit modular, `<< 5`, offsets (-77, -19) Grand Striker 2 / (-77, -21) Blazing Tornado; a dot outside the 2048 x 4096 plane is not drawn. Grand Striker 2's game runs in super mode (the pitch's perspective) and its title / how-to-play screens in simple mode.

**RTL.** `rtl/metro_roz.sv` (**v3, 20261011e**; v1 of 20261010: a dot at a time, a whole 256-byte tile at every tile change, one request outstanding; v2 of 20261011a - d: a walker, 32 slots of tile rows, a dot queue, a painter).  v2 missed on nearly every dot of a TURNED plane: Grand Striker 2's camera that turns the pitch (the line RAM's per-dot step is in y, `lw2 = 0, lw3 != 0`; goal replay / the new-play screen after a goal, and the whole 'y' mode of the 4,570 sampled frames of `work/gs2r`) has ~130 different {tile code, row} lines in a picture row, and 32 slots held 32: ~300 fetches of ~33 clocks, 10,000 clocks a row against a line's 6,272 (unit bench frames 9524 / 10000 / 12120 of `work/gs2r/st`: 9,976 / 7,467 / 9,153).  The video chip then showed the background pen from the second row on (hardware overlay of 20261011d: 217 of 224 lines, 37 plane rows a frame), and because the plane's pace was a COUNT of the rows the renderer had started, a kick FIFO that overflowed left the plane waiting for rows whose kicks had been dropped until the frame's end (the fix is in the video chip: `o_roz_used` is the row of the kick at the head of the FIFO).  v3: the **walker** takes one dot at a time (4 clocks, 7 at a tile change): position -> tile code from the **map cache** (64 windows of 32 words, direct mapped, invalidated by the 68000's writes to the map: `i_inval`) -> row of the tile from the **line cache** (a group of 2 rows (Grand Striker 2, 16-byte rows) / 4 rows (Blazing Tornado, 8-byte rows) of the tile, 32 bytes, per miss; 256 groups, direct mapped on {code, row group}) -> the pen into the row's line buffer.  No slots, no queues, no painter.  Turned pitch: ~1,970 clocks a row (v2 ~9,000), normal pitch ~1,700 - 1,900, Blazing Tornado ~1,900 (zoomed far out ~3,600); **0 of 68,096 dots differ from `tools/metro_roz.py` on 12 + 4 Grand Striker 2 frames (normal and turned) and 8 Blazing Tornado frames**.  `rtl/metro_vdp.sv`'s pace of the plane is the head of the kick FIFO (see above).  Grand Striker 2's tile ROM is stored by `metro_loader.sv` with its tile rows in raster order (offset bits 6 and 5:3 swapped inside each 256-byte tile: one 16-byte request per tile row instead of two 8-byte pieces 64 bytes apart). The tile map RAM stays in the SDRAM (`metro_sdram`'s shared-RAM client, word 0xE00000 = byte 28 MB, the F64 build 60 MB; the 68000 reads and writes it through that client in `metro_main.sv`) and the engine reads it through the graphics stream at its byte address (stream space = SDRAM byte - 1 MB: `rz_map_base` 0x1B00000 / 0x3B00000), which needs the stream's address 26 bits wide in the F64 build (`GAW`, `metro_sdram` `i_gfx_addr`). `metro_vdp.sv` lets the engine run ahead of its renderer: a row is kicked to the renderer once the plane has drawn it (`roz_ok`; the renderer's rows_used + 6 bound the 8 line buffers), the renderer's resolve pass takes the plane's pen where nothing else was drawn (`bgp` in `metro_render.sv`), the engine's requests ride the graphics stream (`GR_ROZ`, lowest priority). A line the engine did not finish in time is blanked by the scan-out to the BACKGROUND PEN (`so_stale`, `r_bg`: beige on Grand Striker 2's pitch, black on Blazing Tornado) -- the symptom of an engine that is too slow. **Cost (unit bench `sim/run_roz.sh` + `tools/roz_bin_cmp.py`, 25 clocks of stream latency):** 850 - 1,000 clocks a row on Grand Striker 2's frames (v1: 4,000 - 8,000 under the same latency), 2,400 on Blazing Tornado's zoomed-out ring (76 distinct lines a row; 6,272 clocks are a line); the whole machine measures 12 clocks mean / 21 max from the request to the first word. Sprite RAM: MAME's `set_spriteram_buffered(true)` (a frame is drawn from the list as it was at line 224) is the video chip's copy (`spr_copy_line`); on these boards 68000 writes to the sprite RAM are held while the 2,050-clock copy runs (`spr_wr_hold`), so the copy is a snapshot like MAME's (a word written ahead of the copy pointer reached the copy: one sprite mixed two frames).
**Sound** (`rtl/metro_sndf.sv`, after the user's mcatadv-mister board; jt10 + jt49 + tv80 vendored): Z80 0000-7FFF ROM, 8000-BFFF a 16 KB bank of the 128 KB (I/O 0x00 write: bank = data & 7), E000-FFFF RAM 8 KB; I/O 0x40 read = the 68000's command latch (reading clears the pending flag; a pending byte holds the Z80's NMI), 0x80-0x83 the YM2610 whose IRQ is the Z80's INT. The program is read through the 68000's ROM client (word reads at +2 MB, a one-word cache, WAIT while a word is fetched), ADPCM-A / ADPCM-B bytes through the OKI-style client (`metro_ympcm.sv`: the two ports take it in turn, 23-bit byte address; the region of B at the client's base, A 2 MB above). Mix: MAME's routes of `gstrik2` (SSG 0.75, FM + ADPCM L / R 0.25 each into one speaker).
**Image** (`tools/metro_rom.py` `F_MACHINES`): gfx 0x100000 (16 MB), the program 2 MB after it, the Z80's 128 KB, `gfx2` 2 MB, ADPCM-B 2 MB slot, ADPCM-A 4 MB slot (Grand Striker 2: 28.4 MB, fits a 32 MB module).  **Blazing Tornado (`blzntrnd`, board 18): 24 MB of graphics, the image is 36.1 MB: it needs the `F64` build** (`VERILOG_MACRO F64`, core file `metrof64`): the SDRAM controller addresses 64 MB (10 column bits, A9, which every 64 MB / 128 MB module has; the tile map RAM sits at byte 60 MB), the loader's address is 26 bits, the video chip's graphics address 25 bits (`GAW`). Its plane differs from Grand Striker 2's (`metro_roz.sv`, `i_bt`): 8 x 8 tiles, 256 x 512, `TILEMAP_SCAN_ROWS` (word = row * 256 + col), code = word & 0x7FFF (a 64-byte tile: one segment of the graphics stream, `i_roz_t8`), offsets (-77, -21), no `set_tmap_xoffsets(0, 8, 0)`; its tile row is 8 contiguous bytes (one 8-byte request, 4 words). **Evidence (simulation):** `tools/metro_roz.py` reference: MAME frames 100 / 250 / 420 / 600 / 800 / 1000 / 1200 / 1500 / 1800 / 2100 of `blzntrnd` 0 of 68,096 pixels off; the RTL video chip + plane at hardware timing (`sim/run_vdp.sh` with `F64=1 BT=1 GFX2BASE=27394048`, `work/bt/run_vf.sh`): the same 10 frames 0 pixels off; whole machine (`F64=1` `SDR=1`, the 36.8 MB image through the loader and the SDRAM model) frame 100: 0 pixels off.. State dumps: `tools/lua/vstate.lua` with `VS_ROZ=1` (the 053936's control block, line RAM and tile map RAM go to `<prefix>.<frame>.roz`), reference: `tools/metro_roz.py` (**MAME's frames 100 / 250 / 420 / 600 / 800 / 1000 / 1200 / 1500 reproduced pixel for pixel**), RTL against it: `sim/run_roz.sh` (`tb_roz.cpp`, `tools/roz_bin_cmp.py`), the video chip + plane at hardware timing against MAME's snapshots: `sim/run_vdp.sh` with `ROZ=` `GFX2=` `GFX2BASE=` `TMAPDX1=` `PIXDIV=16 HTOT=392 VLAST=262 W304=1` (0 of 68,096 px on the same 8 frames).


**Sound mix (20261011).** MAME's routes differ between the two boards: Blazing Tornado (HUM-002) is **stereo**, `ymsnd.add_route(0, 0.75 to both sides)` for the SSG, route 1 (FM + ADPCM left) 1.0 to the left and route 2 1.0 to the right; Grand Striker 2 (HUM-003) is mono, SSG 0.75, FM + ADPCM 0.25 + 0.25 (`gstrik2` machine config). `metro_sndf.sv` had Grand Striker 2's weights for both: Blazing Tornado's FM and ADPCM were 12 dB too low against the SSG's square waves ("music ok, loud noises and buzzing in between" of the hardware test of 20261010). `i_stereo` (board 18) selects L = 0.75 SSG + 1.0 FM left, R = 0.75 SSG + 1.0 FM right; `Metro.sv` box-filters and outputs the two sides. Bench (`sim/run_sndf.sh`, `work/bt/snd`): the first 24 s of a Blazing Tornado session (937 sound commands logged from MAME) against MAME's own `-wavwrite`: per-second RMS within 1 % on both sides (0.93 in the first loud tone), waveform correlation 0.91 - 0.97 where the content is tonal and 0.8 - 0.97 on the noise-like parts once aligned (an offset growing from 0.3 ms to 14 ms over 24 s: the Z80 / YM clock ratio, not audible).

**Debug overlay (20261011c, hardware test).**  The OSD's "Debug overlay" (Off / Small / Large) draws 15 rows of hexadecimal text over the picture with the measurements of the last frame, `rtl/metro_hud.sv` (observation only; "Small" = 8 x 8 characters over 15 rows, "Large" = 16 x 16 over rows 1 - 6; the maxima restart whenever the overlay is switched off).  Each row is `id:AAAA BBBB CCCC`; L = last frame, M = largest since the overlay was switched on:

| id | A | B | C |
|----|---|---|---|
| 1 | lines shown from the background pen (L) | M of A | frames with such a line |
| 2 | first such line (screen line) | last such line | frames counted |
| 3 | renderer: longest line (clocks) | M of A | renderer busy clocks / 64 |
| 4 | kick waited for the plane (clocks / 64) | deepest kick FIFO | kicks dropped (total) |
| 5 | plane rows done at the frame end (240) | smallest of A after 64 frames | `vfirst, v_vis` (e.g. 0BE0 = 11, 224); from 20261012a (the layer RAM log): four nibbles, running totals since reset, F = 15 or more: reads that forced the log out early, writes that found it full, frames applied at the deadline, largest occupancy in 256-slot steps (the log holds 4,096 slots) |
| 6 | plane request to first word, longest (clocks) | M of A | the same summed / 64 |
| 7 | line cache misses (group fetches) | M of A | map window fetches |
| 8 | most line misses in one row | M of A | longest walker row (clocks) |
| 9 | walker clocks in a frame / 64 | clocks waiting for a line fetch / 64 | clocks waiting for a map window / 64 |
| A | clocks the plane waited for the renderer (it was ahead) / 64 | M of the longest walker row | renderer lines |
| B | graphics stream: renderer / 64 | plane / 64 | CPU window + blitter / 64 |
| C | zoom word 2 of line RAM row 0 | word 3 row 0 | sprites in the list |
| D | word 2, row 120 | word 3, row 120 | word 2, row 220 |
| E | SDRAM controller, per 21.8 ms: program ROM accesses (68000 + Z80) | YM2610 sample accesses | tile map RAM accesses (68000 writes) |
| F | frame length in clocks / 32 (0C95C = 1,649,536) | graphics accesses (bursts), per 21.8 ms | controller busy clocks / 64 of 32,768 (7FFF = busy all the time) |

Four OSD switches belong with it: "Tile RAM frame sync" (20261012a: On = the 68000's writes to the three tile layers and the tile table are applied at the instant the sprite list is copied, Off = live as before), "Plane fetch priority" (High = the plane's tile ROM reads go first in the video chip's graphics arbiter instead of last), "CPU sprite write hold" (Off = the 68000's sprite RAM writes no longer wait for the list copy: 20261010's change), and "Sound board" (Off = the Z80 + YM2610 held in reset).

## 16. Family C (Imagetek I4220 + Yamaha YMF278B, no sound CPU): Mouse Shooter GoGo, Bal Cube, Daitoride (YMF278B version), Bang Bang Ball, Battle Bubble -- machines `msgogo`, `balcube`, `daitorida`, `bangball`, `batlbubl` (0.289)

Metro's 1995-96 boards: a 68000 at **16 MHz** (512 KB of program), an **I4220** (320 x 224 here: `set_tmap_xoffsets(2,2,2)`, vblank + blitter = 68000 level 1 through the chip's IRQ line) and a **YMF278B (OPL4)** at 33.8688 MHz that the 68000 drives itself (no
uPD78C10, no Z80); the chip's interrupt (its two FM timers) is **level 2**. A 68000 *periodic interrupt* (`set_periodic_int`: 60 Hz in `msgogo`, 8 x 60 Hz in `balcube` / `daitorida`) is the video chip's cause bit 4, as on the other boards.

| machine | 68000 map | inputs | sound |
|---|---|---|---|
| `msgogo` (board 22) | ROM 0, I4220 0x100000, RAM 0xF00000 (mirrored, 64 KB) | 0x200000 COINS, +2 JOYS, DIP matrix 0x300000 | YMF278B 0x400000 (ports at the word offsets 0 .. 5 of the low byte), status read 0x400001 |
| `balcube` (23) | ROM 0, YMF278B 0x300000, DIP matrix 0x400000, inputs 0x500000, I4220 0x600000, RAM 0xF00000 | IN0 = COINS, IN1 = JOYS | as above |
| `daitorida` (24) | ROM 0, I4220 0x100000, inputs 0x200000, DIP matrix 0x300000, YMF278B 0x400000 | as `msgogo` | as above |
| `bangball` (25) | ROM 0, YMF278B 0xB00000, DIP matrix 0xC00000, inputs 0xD00000, I4220 0xE00000, RAM 0xF00000 | IN0 = COINS, IN1 = JOYS | as above; **no periodic interrupt**: the scanline model of Puzzli (cause 1 on every visible line while the chip's mask bit 1 is clear, causes 4 + 0 at line 224: `i_scan_irq`) |
| `batlbubl` (26) | ROM 0 .. 0xFFFFF (1 MB), I4220 0x100000, IN1 (joysticks) 0x200000, DSW0 (a word) +2, IN0 (coins) +4, IN2 +6, DIP matrix 0x300000 (read, ignored by the game), YMF278B 0x400000 | its own order | as above; the scanline model of `bangball`; 8 MB of graphics |

`bangball` / `batlbubl` run at 60 Hz in MAME (`set_refresh_hz(60)`, "doesn't like 58.2 Hz"); the core's raster is 58.2 Hz as on every board, so the game's timing is 3 % slow here.
Battle Bubble's image (`tools/metro_rom.py` `BL_MACHINES`): gfx at 0x100000 (8 MB), the 1 MB program after it, the wave ROM after that (`Metro.sv` `mrom_wbase` / `oki_wbase`, as Varia Metal).

The DIP matrix is Varia Metal's `balcube_dsw_r` (one DIP bit a read), `init_balcube` (even bytes of the GFX ROM bit-reversed) is the GFX scramble 2 of the image header.  Image (`tools/metro_rom.py`): `maincpu` (0x10000), GFX (0x100000, 2 or 4 MB),
the wave ROM in the `oki` slot (the set's `ymf` region: Yamaha's 2 MB YRW801 at 0 and the game's 512 KB at 0x200000).

**The chip** (`rtl/ymf278b.sv` + `ymf278b_pkg.sv` = srg320's PCM engine from Arcade-PsikyoSH2_MiSTer, itself derived from MAME's `ymf278b`; `rtl/metro_ymf.sv` the wrapper).  What the games use: the 24 wavetable voices (12 / 16 / 8-bit samples,
envelope, pan, total level with its fade, key on / off, header load) and the FM side's registers only as the **bring-up and the two timers** (NEW / NEW2 at 0x105, timer A / B, the control register 0x04, the status byte with the chip ID the first status
read after NEW2 returns); **no FM synthesis** (the games play no FM).  Changes against the original engine, all found by comparing with ymfm (MAME 0.289's code) on the games' own register writes:
the full 22-bit wave address; the wave header of a number from 384 up in the bank register 0x02 bits 4:2 (`bank * 512 KB + (n - 384) * 12`: the games' own samples at 0x200000); the total-level fade runs towards its target (it ran away from it, wrapping the
7 bits, whenever a game does not set the level-direct bit: Bal Cube never does); the header's LFO / rate / AM bytes no longer overwrite what the game wrote after the wave number (MAME loads the header at the write: the game's own writes win); the
register write waits while a header load owns the register ports (it was dropped); the 12-bit sample's low nibble order and the pan table (0xA .. 0xF) as ymfm; output level 0.248 of the wave (ymfm: `volume 8168 / 32768`; was 1.0).  The wave ROM is read through the SDRAM's
OKI-style client (one byte per request; the engine's clock enable is held for the one byte that has not arrived, the FM timers are not).  The mono mix is MAME's (every output on one speaker, gain 1.0: DO0 + DO1 + DO2).

**Checked in simulation** (all against ymfm driven by the writes MAME's Bal Cube made in 30 s, `work/gk/ymflog_balcube.txt`; 10x time-compressed for the HDL bench): with one voice at a time the envelope, the gain and the waveform agree (RMS within 1-3 % until the
game re-keys the voice: it writes key-off, three registers and key-on 15 us apart, which MAME's 22.7 us sample grid sometimes merges into nothing and the chip's slot visit sometimes sees as a re-trigger); the whole mix within 5-20 % per 100 ms (before: 3 x too loud, garbage after the first fade).
