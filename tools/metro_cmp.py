#!/usr/bin/env python3
"""Compare two 320x224 images (PPM P3 text as the Verilator benches write them, or PNG as MAME writes them) and report the number of
differing pixels.  Output line: "<n> of 71680 pixels differ[, bbox x0,y0-x1,y1]".  Exit status 0 when identical.

  python tools/metro_cmp.py <a.ppm|png> <b.ppm|png> [--diff diff.png]
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import pngio  # noqa: E402

W, H = 320, 224


def read_any(path):
    if path.lower().endswith('.png'):
        w, h, rgb = pngio.read(path)
        return w, h, bytes(rgb)
    toks = open(path).read().split()
    if toks[0] != 'P3':
        raise ValueError('%s: not a P3 PPM' % path)
    w, h = int(toks[1]), int(toks[2])
    return w, h, bytes(int(t) for t in toks[4:4 + w * h * 3])


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    wa, ha, a = read_any(argv[0])
    wb, hb, b = read_any(argv[1])
    if (wa, ha) != (wb, hb):
        print('size differs: %dx%d vs %dx%d' % (wa, ha, wb, hb))
        return 1
    n, x0, y0, x1, y1 = 0, wa, ha, -1, -1
    diff = bytearray(b)
    for i in range(0, wa * ha * 3, 3):
        if a[i:i + 3] != b[i:i + 3]:
            p = i // 3
            x, y = p % wa, p // wa
            n += 1
            x0, y0, x1, y1 = min(x0, x), min(y0, y), max(x1, x), max(y1, y)
            diff[i:i + 3] = b'\xff\x00\xff'
    print('%d of %d pixels differ%s' % (n, wa * ha, '' if n == 0 else ', bbox %d,%d-%d,%d' % (x0, y0, x1, y1)))
    if n and '--diff' in argv:
        pngio.write(argv[argv.index('--diff') + 1], wa, ha, bytes(diff))
    return 1 if n else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
