#!/usr/bin/env python3
"""Metro (Imagetek) ROM images, built straight from the ROM_START definitions of MAME 0.289's metro.cpp and the user's
(merged) MAME ROM zips, then packed into the flat image the core's loader takes.  Structure follows
C:\\repos\\taitol-mister\\tools\\taitol_rom.py (same parser idea, same check against a MAME region dump).

  python tools/metro_rom.py list
  python tools/metro_rom.py survey                          region sizes of every set (to size the image layout)
  python tools/metro_rom.py build <set> [--romdir DIR] [--out FILE.rom] [--regions DIR]
  python tools/metro_rom.py check <set> <mame-region-dump-prefix>     compare with tools/lua/regions.lua's output

Regions are built the way MAME's rom loader does it:
  ROM_LOAD            linear
  ROM_LOAD16_BYTE     1 byte every 2        ROM_LOAD64_BYTE   1 byte every 8
  ROM_LOAD32_WORD     2 bytes every 4       ROM_LOAD64_WORD   2 bytes every 8       (bytes of a word ascend in memory)
  ROM_LOAD16_WORD     linear                ROM_LOAD16_WORD_SWAP   linear, the two bytes of every word swapped
Region fill is 00 unless ROMREGION_ERASEFF.  The driver inits that change ROM data (init_balcube, init_dharmak) are applied by
`build_regions(apply_init=True)` only to compare with MAME; the flat image holds the ROMs as they are and the core applies the
init (a config byte), exactly as the Taito L core does for plottinga.
"""
import os
import re
import sys
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import paths  # noqa: E402

DRIVER = os.path.join(paths.BASE, 'ref', 'mame', 'src', 'mame', 'metro', 'metro.cpp')
DEFAULT_ROMDIR = r'R:\Games\Arcade\MAME 0.289 ROMs (merged)'

# macro suffix -> (bytes per element, stride in bytes, swap bytes inside an element)
LOADS = {None: (1, 1, False), '16_BYTE': (1, 2, False), '16_WORD': (2, 2, False), '16_WORD_SWAP': (2, 2, True),
         '32_WORD': (2, 4, False), '64_WORD': (2, 8, False), '64_BYTE': (1, 8, False)}


def strip_comments(text):
    text = re.sub(r'/\*.*?\*/', '', text, flags=re.S)
    return re.sub(r'//[^\n]*', '', text)


def parse_driver(path=DRIVER):
    """-> (roms, games): roms[name] = list of regions {tag,size,fill,loads}, games[name] = {parent, machine, init, rot, ...}"""
    src = strip_comments(open(path, encoding='utf-8', errors='replace').read())
    roms = {}
    for m in re.finditer(r'ROM_START\(\s*(\w+)\s*\)(.*?)ROM_END', src, flags=re.S):
        name, body = m.group(1), m.group(2)
        regions, cur = [], None
        for line in body.split('\n'):
            line = line.strip()
            r = re.match(r'ROM_REGION(?:16_BE|16_LE|32_BE|32_LE|64_BE|64_LE)?\(\s*(0x[0-9a-fA-F]+|\d+)\s*,\s*"([^"]+)"\s*,\s*([^)]*)\)', line)
            if r:
                cur = {'tag': r.group(2), 'size': int(r.group(1), 0),
                       'fill': 0xFF if 'ERASEFF' in r.group(3) else 0x00, 'loads': []}
                regions.append(cur)
                continue
            r = re.match(r'ROM_LOAD((?:16_BYTE|16_WORD_SWAP|16_WORD|32_WORD|64_WORD|64_BYTE))?\(\s*"([^"]+)"\s*,\s*(0x[0-9a-fA-F]+|\d+)\s*,'
                         r'\s*(0x[0-9a-fA-F]+|\d+)\s*,\s*CRC\(([0-9a-fA-F]+)\)', line)
            if r and cur is not None:
                elem, stride, swap = LOADS[r.group(1)]
                cur['loads'].append({'file': r.group(2), 'offset': int(r.group(3), 0), 'size': int(r.group(4), 0),
                                     'crc': int(r.group(5), 16), 'elem': elem, 'stride': stride, 'swap': swap,
                                     'kind': r.group(1) or ''})
        roms[name] = regions
    games = {}
    for m in re.finditer(r'^\s*GAME\(\s*([^,]+),\s*(\w+)\s*,\s*(\w+)\s*,\s*(\w+)\s*,\s*(\w+)\s*,\s*\w+\s*,\s*(\w+)\s*,\s*(ROT\d+)\s*,'
                         r'\s*"([^"]*)"\s*,\s*"([^"]*)"\s*,\s*([^)]*)\)', src, flags=re.M):
        year, name, parent, machine, inp, init, rot, company, title, flags = m.groups()
        games[name] = {'year': year.strip(), 'parent': None if parent == '0' else parent, 'machine': machine, 'input': inp,
                       'init': init, 'rot': rot, 'company': company, 'title': title, 'flags': flags.strip()}
    return roms, games


def find_zips(name, games, romdir):
    out, n = [], name
    while n:
        p = os.path.join(romdir, n + '.zip')
        if os.path.exists(p):
            out.append(p)
        n = games.get(n, {}).get('parent')
    return out


def crc_index(zips):
    idx = {}
    for zp in zips:
        with zipfile.ZipFile(zp) as z:
            for i in z.infolist():
                idx.setdefault(i.CRC, (zp, i.filename))
    return idx


def place(buf, ld, data):
    """Write `data` into `buf` the way MAME's loader does for this ROM_LOAD flavour."""
    e, s, swap = ld['elem'], ld['stride'], ld['swap']
    off = ld['offset']
    if e == 1 and s == 1:                                    # plain ROM_LOAD: contiguous
        buf[off:off + len(data)] = data
        return
    if e == s:                                               # 16_WORD / 16_WORD_SWAP: contiguous words
        if swap:
            data = bytearray(data)
            data[0::2], data[1::2] = data[1::2], data[0::2]
        buf[off:off + len(data)] = data
        return
    n = len(data) // e
    for sub in range(e):
        b = (e - 1 - sub) if swap else sub
        buf[off + b: off + b + n * s: s] = data[sub::e]


def init_balcube(r):          # metro.cpp init_balcube: every even byte of vdp2 bit-reversed
    reg = r['vdp2']
    for i in range(0, len(reg), 2):
        reg[i] = int('{:08b}'.format(reg[i])[::-1], 2)


def bitswap8(v, b7, b6, b5, b4, b3, b2, b1, b0):          # MAME bitswap<8>: argument k is the SOURCE bit for output bit 7-k
    return (((v >> b7) & 1) << 7 | ((v >> b6) & 1) << 6 | ((v >> b5) & 1) << 5 | ((v >> b4) & 1) << 4 |
            ((v >> b3) & 1) << 3 | ((v >> b2) & 1) << 2 | ((v >> b1) & 1) << 1 | ((v >> b0) & 1))


def init_dharmak(r):          # metro.cpp init_dharmak, over 0x200000 bytes of vdp2
    reg = r['vdp2']
    for i in range(0, 0x200000, 4):
        reg[i + 1] = bitswap8(reg[i + 1], 7, 3, 2, 4, 5, 6, 1, 0)
        reg[i + 3] = bitswap8(reg[i + 3], 7, 2, 5, 4, 3, 6, 1, 0)


INITS = {'init_balcube': init_balcube, 'init_dharmak': init_dharmak}
SCRAMBLE = {'init_dharmak': 1, 'init_balcube': 2}          # config byte 2: which init the core must apply to GFX reads

# ---- flat image for the uPD7810 families (I4100 / I4220 + D78C10): the sets in metro.cpp need at most
#      maincpu 0x80000, audiocpu 0x20000, oki 0x40000, gfx 0x400000 (see `survey`).  The YMF278B and I4300 families
#      (gfx up to 32 MB, other sound chips) will get their own layout.
# The configuration block comes FIRST in the image: the loader needs the GFX scramble mode (config byte 2) before the graphics arrive,
# because it applies the driver's init (a per-byte permutation) while writing them to SDRAM, which costs nothing at run time.
LAYOUT = {            # image slot -> (image offset, image size)
    'maincpu':  (0x010000, 0x080000),
    'audiocpu': (0x090000, 0x020000),
    'oki':      (0x0B0000, 0x040000),
    'gfx':      (0x100000, 0x400000),      # the set's `vdp` (I4100) or `vdp2` (I4220) region
}
CFG_OFF = 0x000000
CFG_SIZE = 0x20
EEPROM_OFF = 0x000100          # family D sets with an EEPROM region (dokyusp): the 128 bytes of the default contents
IMAGE_SIZE = 0x500000
GFX_TAGS = ('vdp', 'vdp2', 'vdp3')
# family D (the I4300 boards: Mouja, Mahjong Doukyuusei / Gakuensai ...): no sound CPU, the GFX ROM is 4..32 MB and the OKI samples (1..4 MB, banked) follow it:
# maincpu 0x10000 (0x80000), gfx 0x100000 (its size), oki after it (the RTL finds it at 0x100000 + the GFX size of config bytes 3:6, Metro.sv `oki_wbase`)
D_MACHINES = ('dokyusei', 'dokyusp', 'gakusai', 'gakusai2', 'mouja',
              'msgogo', 'balcube', 'daitoa', 'bangball')     # family C (I4220 + YMF278B, no sound CPU): the wave ROM (the `ymf` region, 2.5 MB) is the image's `oki` slot


F_MACHINES = ('blzntrnd', 'gstrik2')           # family F (Blazing Tornado, Grand Striker 2): 2 MB 68000 program, Z80 + YM2610, Konami 053936 ROZ plane; the image is the GFX, then the 2 MB program, the Z80's 128 KB, the 053936's
                                               # tile ROM (2 MB), the YM2610's ADPCM-B ROM (2 MB slot) and its ADPCM-A ROM (4 MB slot): Metro.sv `mrom_wbase`, `f_*` bases
BL_MACHINES = ('batlbubl',)                    # Battle Bubble (family C with a 1 MB program): the program sits after the 8 MB of graphics, then the wave ROM (the `ymf` region, 2.5 MB: the `oki` slot)
VM_MACHINES = ('vmetal',)                      # Varia Metal: the 1 MB program sits after the 8 MB of graphics, then the OKI's 512 KB and the ES8712's 2 MB (Metro.sv mrom_wbase / oki_wbase)


def layout_for(name, roms, games):
    """-> ({slot: (image offset, image size)}, image size) of a set"""
    if games[name]['machine'] in F_MACHINES:
        size = {slot_of(r['tag']): r['size'] for r in roms[name] if slot_of(r['tag'])}
        gfx = size['gfx']
        if gfx % 0x10000:
            raise ValueError('%s: the GFX region is not a multiple of 64 KB' % name)
        main = 0x100000 + gfx
        lay = {'gfx': (0x100000, gfx), 'maincpu': (main, 0x200000), 'audiocpu': (main + 0x200000, 0x20000),
               'gfx2': (main + 0x220000, 0x200000), 'adpcmb': (main + 0x420000, 0x200000), 'adpcma': (main + 0x620000, 0x400000)}
        return lay, main + 0xA20000
    if games[name]['machine'] in BL_MACHINES:
        size = {slot_of(r['tag']): r['size'] for r in roms[name] if slot_of(r['tag'])}
        gfx = size['gfx']
        if gfx % 0x10000:
            raise ValueError('%s: the GFX region is not a multiple of 64 KB' % name)
        main = 0x100000 + gfx
        lay = {'gfx': (0x100000, gfx), 'maincpu': (main, 0x100000), 'oki': (main + 0x100000, 0x280000)}
        return lay, main + 0x380000
    if games[name]['machine'] in VM_MACHINES:
        size = {slot_of(r['tag']): r['size'] for r in roms[name] if slot_of(r['tag'])}
        gfx = size['gfx']
        if gfx % 0x10000:
            raise ValueError('%s: the GFX region is not a multiple of 64 KB' % name)
        main = 0x100000 + gfx
        lay = {'gfx': (0x100000, gfx), 'maincpu': (main, 0x100000), 'oki': (main + 0x100000, 0x80000), 'es': (main + 0x180000, 0x200000)}
        return lay, main + 0x380000
    if games[name]['machine'] not in D_MACHINES:
        return LAYOUT, IMAGE_SIZE
    size = {slot_of(r['tag']): r['size'] for r in roms[name] if slot_of(r['tag'])}
    gfx = size['gfx']
    if gfx % 0x10000:
        raise ValueError('%s: the GFX region is not a multiple of 64 KB' % name)
    oki = size.get('oki', 0)
    lay = {'maincpu': (0x010000, 0x080000), 'gfx': (0x100000, gfx), 'oki': (0x100000 + gfx, oki)}
    if size.get('eeprom'):                       # the 93C46's contents at power-up (Doukyuusei Special): 128 bytes, big endian words, the loader sends them to the EEPROM (metro_loader.sv)
        lay['eeprom'] = (EEPROM_OFF, size['eeprom'])
    return lay, 0x100000 + gfx + oki

# machine config name (the 4th field of GAME()) -> board id in CFG[0]; add a machine when the core implements it
# MAME machine name -> board id (image config byte 0; the RTL decodes the memory map, CPU clock, sound chip and interrupt model from it):
#   1 dharma    map A (RAM 4, VDP 8, I/O C), YM2413, 12 MHz        2 toride2g  map B (RAM 4, I/O 8, VDP C), YM2413, 12 MHz
#   3 pururun   map C (I/O 4, RAM 8, VDP C), YM2151, 12 MHz        4 daitorid  map D (VDP 4, RAM 8, I/O C), YM2151, 16 MHz, tilemap x offset 2
#   5 puzzli    as 4 with a scanline interrupt                     6 puzzlia   map C (as 3) but 16 MHz, tilemap x offset 2, scanline interrupt
# (gunmast and pururuna use the pururun machine)
#   7 karatour  (+ ladykill, moegonta) map K (I/O 4, VDP 8, RAM F), I4100, 320 x 240, 12 MHz        8 pangpoms  map P (VDP 4, I/O 8, RAM C), I4100, 360 x 224
#   9 skyalert  map S (I/O 4, VDP 8, RAM C), I4100, 360 x 224, OKI pin 7 low                       10 lastfort map L (RAM 4, VDP 8, I/O C), I4100, 360 x 224, OKI pin 7 low
#  11 lastforg  map G (I/O 4, VDP 0x880000, RAM C), I4100, 360 x 224                               12 poitto   Toride II's map B, I4100, 360 x 224
#  13 sankokushi  map (RAM 7, VDP 8, I/O C), I4220, 320 x 240, vblank irq 5 like karatour (Metro.sv: flip is DSW0 bit 6)
#  17 vmetal    I4220, 16 MHz, 304 x 224, ROT90, no sound CPU: OKI M6295 + ES8712 / MSM6585 on the 68000 bus (Varia Metal)
#  16 dokyusp   I4300, 16 MHz, 384 x 224, no sound CPU, mahjong panel, 93C46 EEPROM (Mahjong Doukyuusei Special)
#  14 dokyusei  I4300, 16 MHz, no sound CPU (YM2413 + OKI on the 68000 bus), mahjong panel      15 mouja  I4300, 16 MHz, no sound CPU, joysticks, programmable timer interrupt
# (the RTL decodes all of it from the id: rtl/metro_main.sv, Metro.sv)
#  18 blzntrnd / 19 gstrik2   I4220 + Konami 053936, 16 MHz 68000, 304 x 224, Z80 + YM2610 (Blazing Tornado / Grand Striker 2)
#  22 msgogo / 23 balcube / 24 daitoa / 25 bangball / 26 batlbubl   family C: I4220, 68000 (16 MHz) + YMF278B (OPL4: PCM wavetable from the 2 MB YRW801 + the game's 512 KB), no sound CPU
#  20 gakusai / 21 gakusai2   I4300, 13.333 MHz, 320 x 240, no sound CPU (YM2413 + OKI), mahjong panel, 93C46 EEPROM, 32 MB of graphics (Mahjong Gakuensai 1 / 2; the 64 MB build)
BOARDS = {'blzntrnd': 18, 'gstrik2': 19, 'dharma': 1, 'toride2g': 2, 'pururun': 3, 'daitorid': 4, 'puzzli': 5, 'puzzlia': 6,
          'karatour': 7, 'pangpoms': 8, 'skyalert': 9, 'lastfort': 10, 'lastforg': 11, 'poitto': 12, 'sankokushi': 13,
          'dokyusei': 14, 'mouja': 15, 'dokyusp': 16, 'vmetal': 17, 'gakusai': 20, 'gakusai2': 21,
          'msgogo': 22, 'balcube': 23, 'daitoa': 24, 'bangball': 25, 'batlbubl': 26}


def build_regions(name, romdir=DEFAULT_ROMDIR, roms=None, games=None, apply_init=True):
    """-> {tag: bytearray}, exactly as MAME fills them (with the driver's ROM-data init when apply_init)."""
    if roms is None:
        roms, games = parse_driver()
    if name not in roms:
        raise KeyError('no ROM_START for %s' % name)
    idx = crc_index(find_zips(name, games, romdir))
    out = {}
    for reg in roms[name]:
        buf = bytearray([reg['fill']]) * reg['size']
        for ld in reg['loads']:
            if ld['crc'] not in idx:
                raise FileNotFoundError('%s: %s (CRC %08x) not found in the zips' % (name, ld['file'], ld['crc']))
            zp, fn = idx[ld['crc']]
            with zipfile.ZipFile(zp) as z:
                data = z.read(fn)[:ld['size']]
            if len(data) != ld['size']:
                raise ValueError('%s: %s has %d bytes, the driver wants %d' % (name, ld['file'], len(data), ld['size']))
            place(buf, ld, data)
        out[reg['tag']] = buf
    init = games.get(name, {}).get('init')
    if apply_init and init in INITS:
        INITS[init](out)
    return out


def slot_of(tag):
    """region tag -> image slot name (None: not part of the flat image)"""
    if tag == 'ymsnd:adpcmb':
        return 'adpcmb'
    if tag == 'ymsnd:adpcma':
        return 'adpcma'
    if tag == 'gfx2':
        return 'gfx2'
    if tag == 'ymf':
        return 'oki'
    return 'gfx' if tag in GFX_TAGS else 'es' if tag == 'essnd' else (tag if tag in LAYOUT or tag == 'eeprom' else None)


def config_for(name, roms, games):
    """The CFG_SIZE configuration bytes at CFG_OFF, from the definitions alone (no ROM data needed):
       [0] board id   [1] rotation 0..3   [2] GFX scramble (0 none, 1 init_dharmak, 2 init_balcube)
       [3:6] GFX ROM size in bytes, 32-bit little endian"""
    size = {slot_of(r['tag']): r['size'] for r in roms[name] if slot_of(r['tag'])}
    g = games[name]
    cfg = bytearray(CFG_SIZE)
    cfg[0] = BOARDS[g['machine']]
    cfg[1] = {'ROT0': 0, 'ROT90': 1, 'ROT180': 2, 'ROT270': 3}[g['rot']]
    cfg[2] = SCRAMBLE.get(g['init'], 0)
    cfg[3:7] = size['gfx'].to_bytes(4, 'little')
    return cfg


def build_image(name, romdir=DEFAULT_ROMDIR, roms=None, games=None):
    if roms is None:
        roms, games = parse_driver()
    regions = build_regions(name, romdir, roms, games, apply_init=False)       # the image holds the ROMs as they are;
    lay, total = layout_for(name, roms, games)
    img = bytearray(total)                                                     # the core applies the init (CFG[2])
    for tag, buf in regions.items():
        slot = slot_of(tag)
        if slot is None:
            raise ValueError('%s: region %s has no slot in the image layout' % (name, tag))
        off, size = lay[slot]
        if len(buf) > size:
            raise ValueError('%s region %s is 0x%x bytes, the image has room for 0x%x' % (name, tag, len(buf), size))
        img[off:off + len(buf)] = buf
    cfg = config_for(name, roms, games)
    img[CFG_OFF:CFG_OFF + CFG_SIZE] = cfg
    return img, regions, cfg


def main(argv):
    roms, games = parse_driver()
    romdir = argv[argv.index('--romdir') + 1] if '--romdir' in argv else DEFAULT_ROMDIR
    if len(argv) >= 2 and argv[0] == 'build':
        name = argv[1]
        img, regions, cfg = build_image(name, romdir, roms, games)
        for tag, buf in regions.items():
            print('  %-10s -> %-9s 0x%06x bytes' % (tag, slot_of(tag), len(buf)))
        print('  config: board %d, rot %s, gfx scramble %d, gfx size 0x%x' % (cfg[0], games[name]['rot'], cfg[2], int.from_bytes(cfg[3:7], 'little')))
        if '--out' in argv:
            open(argv[argv.index('--out') + 1], 'wb').write(img)
        if '--regions' in argv:
            d = argv[argv.index('--regions') + 1]
            os.makedirs(d, exist_ok=True)
            for tag, buf in regions.items():
                open(os.path.join(d, '%s.%s.bin' % (name, tag.replace(':', '_'))), 'wb').write(buf)
        return 0
    if len(argv) >= 3 and argv[0] == 'check':                       # against tools/lua/regions.lua's dump (MAME after its init)
        name, pre = argv[1], argv[2]
        regions = build_regions(name, romdir, roms, games, apply_init=True)
        bad = 0
        for tag, buf in regions.items():
            p = '%s.%s.bin' % (pre, tag.replace(':', ''))
            if not os.path.exists(p):
                print('  %-10s no MAME dump (%s)' % (tag, p))
                continue
            ref = open(p, 'rb').read()
            same = (ref == bytes(buf))
            first = next((i for i in range(min(len(ref), len(buf))) if ref[i] != buf[i]), None)
            print('  %-10s %s (%d vs %d bytes)%s' % (tag, 'identical' if same else 'DIFFERENT', len(buf), len(ref),
                                                    '' if same or first is None else ', first difference at 0x%x' % first))
            bad += 0 if same else 1
        return bad
    if not argv or argv[0] == 'list':
        for n in sorted(roms):
            g = games.get(n, {})
            print('%-10s %-10s parent %-9s %-6s %-14s %s' % (n, g.get('machine', '?'), g.get('parent') or '-', g.get('rot', '?'), g.get('init', '?'), g.get('title', '')))
        return 0
    if argv[0] == 'survey':
        tags = {}
        for n in sorted(roms):
            for r in roms[n]:
                tags.setdefault(r['tag'], []).append((r['size'], n))
        for tag, lst in sorted(tags.items()):
            mx = max(lst)
            print('%-14s %3d sets, size min 0x%06x max 0x%06x (%s)' % (tag, len(lst), min(lst)[0], mx[0], mx[1]))
        print()
        for n in sorted(roms):
            print('%-10s %s' % (n, '  '.join('%s=0x%x' % (r['tag'], r['size']) for r in roms[n])))
        return 0
    print(__doc__)
    return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
