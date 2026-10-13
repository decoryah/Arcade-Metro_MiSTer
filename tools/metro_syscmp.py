#!/usr/bin/env python3
"""Compare the system bench's VDP state dumps (mister/sim/tb_metro_sys_top.sv: <prefix>.<frame>.hex/.regs/.ppm) with MAME's dumps of the same
frame (tools/lua/vstate.lua: <prefix>.<frame>.mem/.regs/.png), region by region, word by word.

  python tools/metro_syscmp.py <rtl prefix> <mame prefix> <frame> [<frame> ...] [--verbose] [--window N]

The image is compared with MAME's PNG (chip lines 0..223).  With --window N the RTL's image is instead compared with the reference model
(tools/metro_ref.py, driven by MAME's own state dump) rendered through a window starting at chip line N, i.e. what the VDP shows when it
follows the game's CRTC (Dharma: N = 11); use it for runs without +WINMAME=1.
"""
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import metro_cmp  # noqa: E402
import metro_ref  # noqa: E402

REGIONS = [('vram0', 65536), ('vram1', 65536), ('vram2', 65536), ('palette', 4096), ('spriteram', 2048), ('tiletable', 1024)]


def read_rtl(path):
    return [int(x, 16) for x in open(path).read().split()]


def read_mame(path):
    raw = open(path, 'rb').read()
    return list(struct.unpack('>%dH' % (len(raw) // 2), raw))


def read_regs(path):
    out = {}
    for line in open(path):
        a, v = line.split()
        out[int(a, 16)] = int(v, 16)
    return out


def main(argv):
    verbose = '--verbose' in argv
    window = int(argv[argv.index('--window') + 1]) if '--window' in argv else None
    args = [a for a in argv if not a.startswith('--') and not (window is not None and a == str(window) and argv.index(a) == argv.index('--window') + 1)]
    gfx = metro_ref.load_gfx('dharma') if window is not None else None
    if len(args) < 3:
        print(__doc__)
        return 2
    rtl, mame, frames = args[0], args[1], [int(f) for f in args[2:]]
    bad = 0
    for fr in frames:
        a = read_rtl('%s.%d.hex' % (rtl, fr))
        b = read_mame('%s.%d.mem' % (mame, fr))
        if len(a) != len(b):
            print('frame %d: size mismatch %d vs %d words' % (fr, len(a), len(b)))
            bad += 1
            continue
        o = 0
        line = []
        frame_bad = 0
        for name, n in REGIONS:
            diffs = [i for i in range(n) if a[o + i] != b[o + i]]
            line.append('%s %s' % (name, 'ok' if not diffs else '%d/%d differ' % (len(diffs), n)))
            frame_bad += len(diffs)
            if diffs and verbose:
                for i in diffs[:6]:
                    print('    %s[%#06x]: RTL %04x  MAME %04x' % (name, i, a[o + i], b[o + i]))
            o += n
        ra, rb = read_regs('%s.%d.regs' % (rtl, fr)), read_regs('%s.%d.regs' % (mame, fr))
        masks = {0x79710: 0x3f, 0x79712: 0x0fff, 0x788a4: 0x00ff}
        rd = []
        for k, v in sorted(ra.items()):
            m = masks.get(k, 0xffff)
            mv = rb.get(k, 0)
            if (v & m) != (mv & m):
                rd.append('%05x RTL %04x MAME %04x' % (k, v, mv))
        frame_bad += len(rd)
        print('frame %4d: %s | regs %s' % (fr, ', '.join(line), 'ok' if not rd else '; '.join(rd)))
        ppm, png = '%s.%d.ppm' % (rtl, fr), '%s.%d.png' % (mame, fr)
        if os.path.exists(ppm) and window is not None:
            st = metro_ref.State(mame, fr)
            r = metro_ref.Renderer(gfx)
            r.h = window + metro_ref.H
            img = bytes(r.render(st))[window * metro_ref.W * 3:]
            wa, ha, pa = metro_cmp.read_any(ppm)
            n = sum(1 for i in range(0, len(img), 3) if img[i:i + 3] != bytes(pa[i:i + 3]))
            print('            image vs model through the window at chip line %d: %d of %d pixels differ' % (window, n, wa * ha))
        elif os.path.exists(ppm) and os.path.exists(png):
            wa, ha, pa = metro_cmp.read_any(ppm)
            wb, hb, pb = metro_cmp.read_any(png)
            n = sum(1 for i in range(0, len(pa), 3) if pa[i:i + 3] != pb[i:i + 3])
            print('            image vs MAME snapshot: %d of %d pixels differ' % (n, wa * ha))
        bad += 1 if frame_bad else 0
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
