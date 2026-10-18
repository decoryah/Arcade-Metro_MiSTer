#!/usr/bin/env python3
"""Writes the core's MRA files (mister/mra/*.mra: one a title, the other versions in mra/_alternatives/_<Title>/) from MAME's definitions: the ROM_START lists of metro.cpp (through
tools/metro_rom.py, so the MRAs and the independent image builder cannot disagree) and the DIP switches from
`mame -listxml`. No ROM file is read.   Structure follows taitol-mister/mister/tools/make_mra.py.

  python tools/make_mra.py [set ...]        (default: every supported set)

The image layout is tools/metro_rom.py's (LAYOUT).  The core's loader packs the byte stream little-endian (first byte low), so
MAME's region byte order is simply the stream order.  Interleaves use the MRA convention that tools/mra_build.py and mra-tools-c
share: each `map` digit is one byte of the output word, the RIGHTMOST digit being the word's first byte, and the digit's value the
1-based byte of that part.
DIP switches (ioctl index 254): metro.cpp has one 16-bit port `DSW0` = SW1 (bits 0-7) then SW2 (bits 8-15); byte 0 of the switch
array is bits 0-7, byte 1 bits 8-15, bit 0 first, a 1 being MAME's default.
"""
import os
import subprocess
import sys
import xml.etree.ElementTree as ET
from xml.sax.saxutils import quoteattr

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import metro_rom as T  # noqa: E402

import paths  # noqa: E402

MAME = paths.MAME                                             # MAME 0.289, the oracle (tools/paths.py says where it is looked for)
OUTDIR = os.path.join(paths.REPO, 'mra')

# sets the core runs so far (the machine must be in metro_rom.BOARDS and implemented in the RTL)
SUPPORTED = ['dharma', 'dharmag', 'dharmaj', 'dharmak', 'toride2g', 'toride2gg', 'toride2gk', 'toride2j', 'toride2ji',
             'gunmast', 'pururun', 'pururuna', 'daitorid', 'puzzli', 'puzzlia',
             'karatour', 'karatourj', 'ladykill', 'moegonta', 'pangpoms', 'pangpomsm', 'pangpomsn', 'skyalert',
             'lastfort', 'lastforte', 'lastfortea', 'lastfortk', 'lastfortg', 'lastfortj', 'poitto', '3kokushi', 'mouja', 'dokyusei', 'dokyusp', 'vmetal', 'vmetaln', 'gstrik2', 'gstrik2j', 'blzntrnd', 'gakusai', 'gakusaia', 'gakusai2', 'msgogo', 'balcube', 'daitorida', 'bangball', 'batlbubl']

ORDER = ['maincpu', 'audiocpu', 'oki', 'gfx']                  # slot order in the image (ascending offset)


def region_parts(reg, slot_size):
    """-> list of MRA lines filling exactly slot_size bytes with region `reg` (None: an absent region)."""
    out, pos = [], 0
    fill = '%02X' % (reg['fill'] if reg else 0)

    def pad(n):
        if n > 0:
            out.append('<part repeat="0x%X">%s</part>' % (n, fill))
    if reg is None:
        pad(slot_size)
        return out
    items, groups = [], {}
    for ld in reg['loads']:
        e, s = ld['elem'], ld['stride']
        if e == s:                                         # linear (ROM_LOAD, 16_WORD, 16_WORD_SWAP)
            items.append((ld['offset'], ld['size'], 'swap' if ld['swap'] else 'lin', [ld]))
        else:
            base = ld['offset'] - ld['offset'] % s
            lane = (ld['offset'] % s) // e
            groups.setdefault((base, s, e, ld['size']), {})[lane] = ld
    for (base, s, e, size), lanes in groups.items():
        n = s // e
        if sorted(lanes) != list(range(n)):
            raise ValueError('interleave at %x is missing lanes: %s' % (base, sorted(lanes)))
        items.append((base, size * n, 'ilv', [lanes[i] for i in range(n)]))
    items.sort(key=lambda t: t[0])

    def ref(ld):
        return 'name=%s crc="%08x"' % (quoteattr(ld['file']), ld['crc'])

    for base, length, kind, lds in items:
        if base < pos:
            raise ValueError('overlapping loads at %x' % base)
        pad(base - pos)
        if kind == 'lin':
            out.append('<part %s/>' % ref(lds[0]))
        elif kind == 'swap':                                # the two bytes of every word swapped: output pos0 <- byte 2, pos1 <- byte 1
            out.append('<interleave output="16">')
            out.append('    <part %s map="12"/>' % ref(lds[0]))
            out.append('</interleave>')
        else:
            n, e = len(lds), lds[0]['elem']
            s = n * e
            out.append('<interleave output="%d">' % (8 * s))
            for lane, ld in enumerate(lds):
                digits = []
                for p in range(s - 1, -1, -1):              # left to right = highest output byte first
                    k = p - lane * e
                    digits.append(str(k + 1) if 0 <= k < e else '0')
                out.append('    <part %s map="%s"/>' % (ref(ld), ''.join(digits)))
            out.append('</interleave>')
        pos = base + length
    pad(min(reg['size'], slot_size) - pos)
    pad(slot_size - max(pos, min(reg['size'], slot_size)))
    return out


def dips(name):
    """DIP switches of the 16-bit DSW0 port (and DSW1, the second port of the I4100 boards, as bits 16-31) from MAME's -listxml
       -> (default bytes [DSW0 lo, DSW0 hi(, DSW1 lo, DSW1 hi)], [<dip .../> lines])"""
    work = os.path.join(paths.BASE, 'work', 'mame')
    os.makedirs(work, exist_ok=True)
    xml = subprocess.run([MAME, name, '-rompath', T.DEFAULT_ROMDIR, '-listxml'], capture_output=True, text=True, cwd=work).stdout
    root = ET.fromstring(xml)
    machine = [m for m in root.iter('machine') if m.get('name') == name][0]
    default, lines, has1 = 0, [], False
    for d in machine.iter('dipswitch'):
        if d.get('tag') not in ('DSW0', 'DSW1') and not (name in ('vmetal', 'vmetaln') and d.get('tag') == 'IN2'):       # Varia Metal's second DIP bank is the port "IN2"
            continue
        off = 16 if d.get('tag') in ('DSW1', 'IN2') else 0
        has1 = has1 or off != 0
        mask = int(d.get('mask'))
        shift = (mask & -mask).bit_length() - 1
        top = mask.bit_length() - 1
        nbits = top - shift + 1
        for v in d.iter('dipvalue'):
            if v.get('default') == 'yes':
                default |= (int(v.get('value')) & mask) << off
        # MiSTer's bits="first,last" is a RANGE of bits (a single number for one bit), not a list: "0,1,2" was read as bits 0..1 and the OSD offered the first four of
        # eight settings (a player's report, 2026-10-19).  A field whose bits are not contiguous gets the range around them and values= (the setting's value in it).
        if mask >> shift == (1 << nbits) - 1:
            vals = {}
            for v in d.iter('dipvalue'):
                vals.setdefault((int(v.get('value')) & mask) >> shift, v.get('name'))
            ids = [vals.get(i, 'Unused') for i in range(1 << nbits)]
            extra = ''
        else:
            print('note: %s %s: bits not contiguous (mask %#x): values=' % (name, d.get('name'), mask))
            ids, values = [], []
            for v in d.iter('dipvalue'):
                ids.append(v.get('name'))
                values.append(str((int(v.get('value')) & mask) >> shift))
            extra = ' values="%s"' % ','.join(values)
        bits = str(off + shift) if nbits == 1 else '%d,%d' % (off + shift, off + top)
        ids = [i.replace(', ', ' / ').replace(',', ' / ') for i in ids]        # ids is a comma list: MAME's "200K, every 400K" would be two settings
        lines.append('        <dip bits="%s" name=%s ids=%s%s/>' % (bits, quoteattr(d.get('name')), quoteattr(','.join(ids)), extra))
    if has1:
        return (default & 255, (default >> 8) & 255, (default >> 16) & 255, (default >> 24) & 255), lines
    return (default & 255, default >> 8), lines


# The buttons each game uses, by MAME's input ports (GAME()'s input column; a set's own entry first), buttons 1, 2, 3 (family F: 4): None = not used, '-' in the MRA, which
# MiSTer's button definition skips.  MAME declares buttons the games never read ("BUTTON2 and BUTTON3 in test mode only"); the counts here are what the games use in play,
# checked in MAME 0.289 where MAME and a player's report disagreed (work/btn): Gun Master's button 3 and Mouja's do nothing in play, Varia Metal's changes the ship's form,
# Blazing Tornado's own HOW TO PLAY shows three buttons (A quick attacks, B strong attacks, C + direction quick movement).  The names are the games' own words where they
# show them, else a player's report (October 2026), else Button n.
BUTTONS = {
    'dharma':     ('Attack', None, None),
    'toride2g':   ('Button 1', None, None),
    'gunmast':    ('Shoot', 'Jump', None),
    'pururun':    ('Button 1', 'Button 2', None),
    'daitorid':   ('Button 1', 'Button 2', None),
    'daitoa':     ('Button 1', 'Button 2', None),
    'puzzli':     ('Button 1', 'Button 2', None),
    'karatour':   ('Attack', 'Jump', None),
    'ladykill':   ('Dive', 'Dive 2', None),
    'moegonta':   ('Dive', 'Dive 2', None),
    'pangpoms':   ('Attack', 'Jump', None),
    'skyalert':   ('Fire', 'Bomb', None),
    'lastfort':   ('Button 1', None, None),
    'lastfero':   ('Button 1', None, None),
    'lastfortg':  ('Button 1', None, None),         # Last Fortress on the VG460 board: MAME gives it Lady Killer's ports, the game uses one button
    'lastfortj':  ('Button 1', None, None),
    'poitto':     ('Button 1', None, None),
    'sankokushi': ('Button 1', 'Button 2', None),
    'mouja':      ('Rotate Left', 'Rotate Right', None),
    'dokyusei':   (None, None, None),                # the mahjong panel (keyboard); the joystick's Start and Coin still work
    'gakusai':    (None, None, None),
    'vmetal':     ('Shoot', 'Bomb', 'Change'),
    'gstrik2':    ('Shoot', 'Long Pass', 'Short Pass', None),
    'blzntrnd':   ('Light Attack', 'Strong Attack', 'Dash', None),
    'msgogo':     ('Shoot', 'Rotate', None),
    'balcube':    ('Action', None, None),
    'bangball':   ('Attack', None, None),
    'batlbubl':   ('Attack', None, None),
}


def buttons(name, g):
    """the MRA's <buttons>: names in the joystick's bit order (button 1, button 2, start, coin, button 3[, button 4]: Metro.sv) and MiSTer's default keys"""
    b = BUTTONS.get(name) or BUTTONS[g['input']]
    n = ['-' if x is None else x for x in b]
    names = [n[0], n[1], 'Start', 'Coin'] + n[2:]
    keys = ['A', 'B', 'Start', 'Select', 'X', 'Y'][:len(names)]
    return '    <buttons names="%s" default="%s"/>' % (','.join(names), ','.join(keys))


def mra(name, roms, games):
    g = games[name]
    zips = [name + '.zip'] + ([g['parent'] + '.zip'] if g['parent'] else [])
    cfg = T.config_for(name, roms, games)
    by_slot = {T.slot_of(r['tag']): r for r in roms[name] if T.slot_of(r['tag'])}
    default, diplines = dips(name)
    L = []
    L.append('<misterromdescription>')
    L.append('    <rotation>%s</rotation>' % ('vertical' if g['rot'] in ('ROT90', 'ROT270') else 'horizontal'))
    L.append('    <name>%s</name>' % g['title'].replace('&', '&amp;'))
    L.append('    <setname>%s</setname>' % name)
    L.append('    <mameversion>0289</mameversion>')
    L.append('    <year>%s</year>' % g['year'])
    L.append('    <manufacturer>%s</manufacturer>' % g['company'].replace('&', '&amp;'))
    L.append('    <players>2</players>')
    L.append('    <joystick>8</joystick>')
    # three core files (see README: one source tree, three builds, the device is too small for all of it at once):
    #   metrod64  family C (YMF278B) and Mahjong Gakuensai 1 / 2: 64 MB SDRAM module
    #   metrof64  family F (Blazing Tornado, Grand Striker 2: the 053936 plane + Z80 / YM2610 sound board): 64 MB SDRAM module
    #   metro     every other game: 32 MB SDRAM module is enough
    L.append('    <rbf>%s</rbf>' % ('metrod64' if g['machine'] in ('gakusai', 'gakusai2', 'msgogo', 'balcube', 'daitoa', 'bangball', 'batlbubl') else 'metrof64' if g['machine'] in T.F_MACHINES else 'metro'))
    L.append('    <platform>Metro</platform>')
    L.append('')
    L.append('    <!--')
    L.append('      Flat image for the Metro core (uPD7810 families), the same layout for every set (tools/metro_rom.py):')
    lay, total = T.layout_for(name, roms, games)
    order = sorted(lay, key=lambda t: lay[t][0])
    L.append('        0x%06X  0x%06X  configuration: [0] board [1] rotation [2] GFX scramble (0 none, 1 init_dharmak, 2 init_balcube) [3:6] GFX size' % (T.CFG_OFF, T.CFG_SIZE))
    for tag in order:
        off, size = lay[tag]
        L.append('        0x%06X  0x%06X  %s' % (off, size, tag if tag != 'gfx' else 'gfx (the set\'s vdp / vdp2 region)'))
    L.append('')
    L.append('      Expects the MAME 0.289 merged romset or the split sets: parts are found by name and CRC.')
    L.append('      The ROMs are stored as dumped; the core applies the driver\'s GFX descramble (configuration byte 2).')
    L.append('      DIP switches (ioctl index 254): byte 0 is MAME\'s DSW0 bits 0-7, byte 1 bits 8-15; the boards with a second port (DSW1) have it in bytes 2 and 3; a 1 is MAME\'s default setting.')
    L.append('    -->')
    L.append('    <switches default="%s" base="16">' % ','.join('%02X' % b for b in default))
    L.extend(diplines)
    L.append('    </switches>')
    L.append('')
    # the names fix the joystick bit layout MiSTer sends (bit 4 first): the core reads button 1/2 = bits 4/5, start = 6, coin = 7, button 3 = 8 (Metro.sv)
    L.append(buttons(name, g))                              # family F has a fourth position (IN0 bits 7 / 15), unused by its two games
    L.append('')
    L.append('    <rom index="0" zip="%s" md5="None" address="0x32000000">' % '|'.join(zips))
    # the configuration block is first: the loader needs it before the graphics arrive (tools/metro_rom.py)
    L.append('')
    L.append('        <!-- configuration -->')
    L.append('        <part>%s</part>' % ' '.join('%02X' % b for b in cfg))
    pos = T.CFG_OFF + T.CFG_SIZE
    for tag in order:
        off, size = lay[tag]
        if off > pos:
            L.append('')
            L.append('        <!-- unused -->')
            L.append('        <part repeat="0x%X">00</part>' % (off - pos))
        L.append('')
        L.append('        <!-- %s -->' % tag)
        for line in region_parts(by_slot.get(tag), size):
            L.append('        ' + line)
        pos = off + size
    if pos < total:
        L.append('        <part repeat="0x%X">00</part>' % (total - pos))
    L.append('    </rom>')
    if g['machine'] in ('dokyusp', 'gakusai', 'gakusai2'):    # the 93C46 (the settings): Main_MiSTer keeps it on the SD card, Metro.sv NV_INDEX (MAME's nvram file: 128 bytes)
        L.append('    <nvram index="4" size="128"/>')
    L.append('</misterromdescription>')
    return '\n'.join(L) + '\n'


def base_title(title):
    """'Dharma Doujou (Germany)' -> 'Dharma Doujou': MiSTer ties an _alternatives/_<Title> folder to the MRAs that start with <Title>"""
    return title.split(' (')[0].strip().replace('/', '-')


def mra_path(n, games):
    """one MRA a title in mra/, the other versions of a title in mra/_alternatives/_<Title>/ (where MiSTer's menu keeps them)"""
    fname = '%s.mra' % games[n]['title'].replace('/', '-').replace(': ', ' - ').replace(':', '-')       # no colon: it is not valid in a Windows / FAT file name
    p = games[n]['parent']
    if p:
        return os.path.join(OUTDIR, '_alternatives', '_' + base_title(games[p]['title']), fname)
    return os.path.join(OUTDIR, fname)


def main(argv):
    roms, games = T.parse_driver()
    names = argv or SUPPORTED
    if not argv:                                                   # a full run: no stale files from an older layout
        for d, _, fs in os.walk(OUTDIR):
            for f in fs:
                if f.endswith('.mra'):
                    os.remove(os.path.join(d, f))
    for n in names:
        path = mra_path(n, games)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        open(path, 'w', newline='\n').write(mra(n, roms, games))
        print('wrote', os.path.normpath(path))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
