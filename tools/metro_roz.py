#!/usr/bin/env python3
"""Reference model of the Konami 053936 plane of Blazing Tornado / Grand Striker 2 (MAME 0.289 metro.cpp family F, `blzntrnd_state::screen_update`):
the tilemap (RAM at 0x400000, 8x8 tiles 256 x 512 for Blazing Tornado, 16x16 tiles 128 x 256 with `tilemap_scan_gstrik2` for Grand Striker 2, colour 0xE of the 8bpp
`gfx2` ROM) is drawn with k053936_device::zoom_draw (simple or "super" per-line mode) through tilemap_t::draw_roz without wrap-around, over the I4220's background pen;
the I4220's layers and sprites (metro_ref.py) are drawn on top.

  python tools/metro_roz.py <set> <prefix> <frame> [--out file.png] [--diff file.png]    (prefix.frame.mem/.regs/.png/.roz from tools/lua/vstate.lua with VS_ROZ=1)
"""
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import metro_ref  # noqa: E402
import metro_rom  # noqa: E402
import pngio  # noqa: E402

W, H = 304, 224
M32 = 0xFFFFFFFF


def s16(v):
    v &= 0xFFFF
    return v - 0x10000 if v & 0x8000 else v


class RozState:
    def __init__(self, prefix, frame):
        d = open('%s.%d.roz' % (prefix, frame), 'rb').read()
        self.ctrl = list(struct.unpack('>16H', d[:32]))
        self.line = list(struct.unpack('>2048H', d[32:32 + 4096]))
        self.ram = list(struct.unpack('>131072H', d[32 + 4096:32 + 4096 + 262144]))


class Plane:
    """the tilemap's pixmap, evaluated pixel by pixel: palette index (0xE00 + the ROM's pen)"""
    def __init__(self, kind, gfx2):
        self.kind = kind
        self.g = gfx2
        if kind == 'gstrik2':
            self.width, self.height = 128 * 16, 256 * 16
        else:
            self.width, self.height = 256 * 8, 512 * 8

    def pix(self, ram, x, y):
        g = self.g
        if self.kind == 'gstrik2':
            col, row = x >> 4, y >> 4
            off = ((row & 0x40) >> 6) | (col << 1) | ((row & 0x80) << 1) | ((row & 0x3F) << 9)
            code = (ram[off] & 0x7FFF) >> 2
            qx, qy = (x >> 3) & 1, (y >> 3) & 1
            a = code * 256 + (qy * 2 + qx) * 64 + (y & 7) * 8 + (x & 7)
        else:
            col, row = x >> 3, y >> 3
            code = ram[row * 256 + col] & 0x7FFF
            a = code * 64 + (y & 7) * 8 + (x & 7)
        return 0xE00 + g[a % len(g)]


def draw_roz_row(plane, ram, out, y, startx, starty, incxx, incxy, incyx, incyy, x0, x1):
    """tilemap_t::draw_roz_core, non-wrap-around case, for the single row y of the clip (the caller has applied the clip's top / left pre-advance)"""
    cx, cy = startx & M32, starty & M32
    ws, hs = plane.width << 16, plane.height << 16
    row = out[y]
    for x in range(x0, x1 + 1):
        if cx < ws and cy < hs:
            row[x] = plane.pix(ram, cx >> 16, cy >> 16)
        cx = (cx + incxx) & M32
        cy = (cy + incxy) & M32


def render_roz(plane, rz, xoff, yoff, w=W, h=H):
    """-> rows of palette indices (None where the plane is not drawn)"""
    out = [[None] * w for _ in range(h)]
    c = rz.ctrl
    if c[7] & 0x0040:                                       # "super" mode: a start and an x step per line from the line RAM
        for y in range(h):
            la = 4 * ((y - yoff) & 0x1FF)
            startx = (256 * s16(rz.line[la] + c[0])) & M32
            starty = (256 * s16(rz.line[la + 1] + c[1])) & M32
            incxx = s16(rz.line[la + 2])
            incxy = s16(rz.line[la + 3])
            if c[6] & 0x8000:
                incxx *= 256
            if c[6] & 0x0080:
                incxy *= 256
            startx = (startx - xoff * incxx) & M32
            starty = (starty - xoff * incxy) & M32
            # draw_roz(clip = row y, startx << 5 ...): the pre-advance is clip.left * incxx + clip.top * incyx with incyx = incyy = 0
            draw_roz_row(plane, rz.ram, out, y, (startx << 5) & M32, (starty << 5) & M32, incxx << 5, incxy << 5, 0, 0, 0, w - 1)
    else:                                                    # "simple" mode: one affine transform
        startx = (256 * s16(c[0])) & M32
        starty = (256 * s16(c[1])) & M32
        incyx, incyy = s16(c[2]), s16(c[3])
        incxx, incxy = s16(c[4]), s16(c[5])
        if c[6] & 0x4000:
            incyx *= 256
            incyy *= 256
        if c[6] & 0x0040:
            incxx *= 256
            incxy *= 256
        startx = (startx - yoff * incyx - xoff * incxx) & M32
        starty = (starty - yoff * incyy - xoff * incxy) & M32
        sx, sy = (startx << 5) & M32, (starty << 5) & M32
        ix, iy, jx, jy = incxx << 5, incxy << 5, incyx << 5, incyy << 5          # per pixel (x, y), per row (x, y)
        for y in range(h):
            draw_roz_row(plane, rz.ram, out, y, sx, sy, ix, iy, jx, jy, 0, w - 1)
            sx = (sx + jx) & M32
            sy = (sy + jy) & M32
    return out


def composite(vdp, st, roz_rows, bgpen):
    """vdp: the I4220 renderer's rows with None where nothing was drawn; roz_rows from render_roz"""
    pen = metro_ref.Renderer.pen
    out = bytearray(W * H * 3)
    i = 0
    bg = pen(st, st.bg_color)
    for y in range(H):
        vr, rr = vdp[y], roz_rows[y]
        for x in range(W):
            v = vr[x]
            if v is None:
                p = rr[x]
                v = pen(st, p) if p is not None else bg
            out[i], out[i + 1], out[i + 2] = v
            i += 3
    return out


def render_frame(set_name, prefix, frame, kind=None, vdp_gfx=None, gfx2=None):
    roms, games = metro_rom.parse_driver()
    regs = metro_rom.build_regions(set_name, roms=roms, games=games, apply_init=True)
    if vdp_gfx is None:
        vdp_gfx = bytes(regs['vdp2'])
    if gfx2 is None:
        gfx2 = bytes(regs['gfx2'])
    kind = kind or ('gstrik2' if set_name.startswith('gstrik2') else 'blzntrnd')
    st = metro_ref.State(prefix, frame)
    rz = RozState(prefix, frame)
    r = metro_ref.Renderer(vdp_gfx, tmap_dx=(0, 8 if kind == 'gstrik2' else 0, 0), flip_dx=(0, 0, 0), flip_dy=(0, 0, 0))
    # the VDP's own picture with None where nothing is drawn (the renderer pre-fills with the background pen, which is drawn under the plane here)
    class Probe(metro_ref.Renderer):
        pass
    bg_sentinel = None
    bm = [[bg_sentinel] * metro_ref.W for _ in range(r.h)]          # the I4220 renders a 320-pixel wide bitmap, the board shows its left 304
    prio = [[0] * metro_ref.W for _ in range(r.h)]
    if not st.blank:
        for pri in (3, 2, 1, 0):
            r.draw_layers(st, bm, prio, pri)
        r.draw_sprites(st, bm, prio)
    plane = Plane(kind, gfx2)
    xoff, yoff = (-77, -19) if kind == 'gstrik2' else (-77, -21)
    roz = render_roz(plane, rz, xoff, yoff)
    return composite(bm, st, roz, None), st


def main(argv):
    if len(argv) < 3:
        print(__doc__)
        return 2
    set_name, prefix, frame = argv[0], argv[1], int(argv[2])
    img, st = render_frame(set_name, prefix, frame)
    w, h, ref = pngio.read('%s.%d.png' % (prefix, frame))
    if (w, h) != (W, H):
        print('MAME snapshot is %dx%d, expected %dx%d' % (w, h, W, H))
        return 2
    n = sum(1 for i in range(0, W * H * 3, 3) if img[i:i + 3] != ref[i:i + 3])
    print('frame %d: %d of %d pixels differ' % (frame, n, W * H))
    if '--out' in argv:
        pngio.write(argv[argv.index('--out') + 1], W, H, bytes(img))
    if n and '--diff' in argv:
        d = bytearray(ref)
        for i in range(0, W * H * 3, 3):
            if img[i:i + 3] != ref[i:i + 3]:
                d[i:i + 3] = bytes((255, 0, 255))
        pngio.write(argv[argv.index('--diff') + 1], W, H, bytes(d))
    return 0 if n == 0 else 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
