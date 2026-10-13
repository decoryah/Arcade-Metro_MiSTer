"""Compare the unit bench's rows (sim/tb_roz.cpp: 224 x 304 uint16, 0xFFFF = not drawn) with tools/metro_roz.py's plane.
   python tools/roz_bin_cmp.py <set> <prefix> <frame> <out.bin>"""
import os, struct, sys
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import metro_roz, metro_rom
set_name, prefix, frame, binp = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
roms, games = metro_rom.parse_driver()
regs = metro_rom.build_regions(set_name, roms=roms, games=games, apply_init=True)
kind = 'gstrik2' if set_name.startswith('gstrik2') else 'blzntrnd'
rz = metro_roz.RozState(prefix, frame)
plane = metro_roz.Plane(kind, bytes(regs['gfx2']))
xoff, yoff = (-77, -19) if kind == 'gstrik2' else (-77, -21)
ref = metro_roz.render_roz(plane, rz, xoff, yoff)
d = open(binp, 'rb').read()
got = struct.unpack('<%dH' % (224 * 304), d)
bad = 0
first = None
for y in range(224):
    for x in range(304):
        g = got[y * 304 + x]
        r = ref[y][x]
        r = 0xFFFF if r is None else r
        if g != r:
            bad += 1
            if first is None:
                first = (x, y, g, r)
print('frame %d: %d of %d dots differ%s' % (frame, bad, 224 * 304, '' if first is None else ', first at x=%d y=%d: got %04x want %04x' % first))
sys.exit(1 if bad else 0)
