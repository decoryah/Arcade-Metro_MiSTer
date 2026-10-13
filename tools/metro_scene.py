#!/usr/bin/env python3
"""Convert a frozen-state dump (tools/lua/vstate.lua or vfuzz.lua: <prefix>.<frame>.mem / .regs) into the scene directory the Verilator
VDP bench (mister/sim/tb_metro_vdp.sv) loads, and write the GFX ROM region as a flat binary.

  python tools/metro_scene.py <prefix> <frame> <outdir>          writes vram0/1/2.hex, tiletable.hex, palette.hex, spriteram.hex, regs.hex
  python tools/metro_scene.py --gfx <set> <file.bin>             writes the set's GFX region (after the driver's init) as bytes

regs.hex holds 22 words in the order the bench writes them through the CPU bus:
  [0] sprite count   [1] sprite priority   [2] sprite y offset   [3] sprite x offset   [4] sprite colour code   [5] layer priority
  [6] background colour   [7] screen x offset   [8] screen y offset   [9] screen control   [10:15] window y0,x0,y1,x1,y2,x2
  [16:21] scroll y0,x0,y1,x1,y2,x2
The CRTC registers are deliberately not part of the scene: without them the VDP shows chip lines 0-223, which is what MAME (and
tools/metro_ref.py) render.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import metro_ref as R  # noqa: E402


def hexfile(path, words):
    with open(path, 'w', newline='\n') as f:
        f.write('\n'.join('%04x' % w for w in words) + '\n')


def write_scene(st, out):
    """Write a State (possibly edited) as a scene directory for the bench."""
    os.makedirs(out, exist_ok=True)
    for i in range(3):
        hexfile(os.path.join(out, 'vram%d.hex' % i), st.vram[i])
    hexfile(os.path.join(out, 'tiletable.hex'), st.tt)
    hexfile(os.path.join(out, 'palette.hex'), st.pal)
    hexfile(os.path.join(out, 'spriteram.hex'), st.spr)
    r = st.reg
    regs = [r.get(0x79700, 0), r.get(0x79702, 0), r.get(0x79704, 0), r.get(0x79706, 0), r.get(0x79708, 0), r.get(0x79710, 0),
            r.get(0x79712, 0), r.get(0x78852, 0), r.get(0x78850, 0), r.get(0x788ac, 0)]
    regs += [r.get(0x78860 + 2 * i, 0) for i in range(6)] + [r.get(0x78870 + 2 * i, 0) for i in range(6)]
    hexfile(os.path.join(out, 'regs.hex'), regs)


def main(argv):
    if argv and argv[0] == '--gfx':
        open(argv[2], 'wb').write(R.load_gfx(argv[1]))
        print('wrote %s (%d bytes)' % (argv[2], os.path.getsize(argv[2])))
        return 0
    if len(argv) != 3:
        print(__doc__)
        return 2
    prefix, frame, out = argv[0], int(argv[1]), argv[2]
    write_scene(R.State(prefix, frame), out)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
