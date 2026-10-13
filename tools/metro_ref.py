#!/usr/bin/env python3
"""Reference renderer for the Imagetek I4100/I4220/I4300 video chip: the executable specification of the Metro core's video.

It re-implements MAME 0.289's imagetek_i4100.cpp screen_update (3 tilemap layers with window/scroll, tile table lookup, 4/8 bit and
8x8/16x16 tiles, zooming sprites, priorities) on a *frozen state* dumped from MAME by tools/lua/vstate.lua, and must reproduce MAME's own
frame snapshot exactly.  Pure Python, no dependencies.

  python tools/metro_ref.py render  <prefix> <frame> [--set dharma] [--out f.png]
  python tools/metro_ref.py compare <prefix> <frame> [--set dharma] [--diff d.png]     pixel diff against MAME's snapshot
  python tools/metro_ref.py all     <prefix> [--set dharma]                            every dumped frame

State files (see vstate.lua): <prefix>.<frame>.mem / .regs / .png.
"""
import glob
import os
import re
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import metro_rom  # noqa: E402
import pngio  # noqa: E402

W, H = 320, 224                 # MAME's visible area for the I4220 boards (i4220_config)
SCR_TOTAL_W, SCR_TOTAL_H = 392, 263       # bitmap size MAME's flip arithmetic uses (set_size)
BIG_N = 0x100                   # tilemap is 256 x 256 tiles

ZOOM = [0xAAC, 0x800, 0x668, 0x554, 0x494, 0x400, 0x390, 0x334, 0x2E8, 0x2AC, 0x278, 0x248, 0x224, 0x200, 0x1E0, 0x1C8,
        0x1B0, 0x198, 0x188, 0x174, 0x164, 0x154, 0x148, 0x13C, 0x130, 0x124, 0x11C, 0x110, 0x108, 0x100, 0x0F8, 0x0F0,
        0x0EC, 0x0E4, 0x0DC, 0x0D8, 0x0D4, 0x0CC, 0x0C8, 0x0C4, 0x0C0, 0x0BC, 0x0B8, 0x0B4, 0x0B0, 0x0AC, 0x0A8, 0x0A4,
        0x0A0, 0x09C, 0x098, 0x094, 0x090, 0x08C, 0x088, 0x080, 0x078, 0x070, 0x068, 0x060, 0x058, 0x050, 0x048, 0x040]


def pal5(v):
    return (v << 3) | (v >> 2)


class State:
    """Frozen VDP state: memories as lists of 16-bit words and the register shadow."""
    SIZES = (0x20000, 0x20000, 0x20000, 0x2000, 0x1000, 0x800)

    def __init__(self, prefix, frame):
        raw = open('%s.%d.mem' % (prefix, frame), 'rb').read()
        words = struct.unpack('>%dH' % (len(raw) // 2), raw)
        o = 0
        parts = []
        for n in self.SIZES:
            parts.append(list(words[o:o + n // 2]))
            o += n // 2
        self.vram, self.pal, self.spr, self.tt = parts[0:3], parts[3], parts[4], parts[5]
        self.reg = {}
        for line in open('%s.%d.regs' % (prefix, frame)):
            a, v = line.split()
            self.reg[int(a, 16)] = int(v, 16)
        r = self.reg
        self.sprite_count = r.get(0x79700, 0)
        self.sprite_priority = r.get(0x79702, 0)
        self.sprite_yoffset = r.get(0x79704, 0)
        self.sprite_xoffset = r.get(0x79706, 0)
        self.sprite_color_code = r.get(0x79708, 0)
        lp = r.get(0x79710, 0)
        self.layer_pri = [lp & 3, (lp >> 2) & 3, (lp >> 4) & 3]
        self.bg_color = r.get(0x79712, 0) & 0x0fff
        self.screen_yoffset = r.get(0x78850, 0)
        self.screen_xoffset = r.get(0x78852, 0)
        self.window = [r.get(0x78860 + 2 * i, 0) for i in range(6)]
        self.scroll = [r.get(0x78870 + 2 * i, 0) for i in range(6)]
        sc = r.get(0x788ac, 0)
        self.tile16 = [bool(sc >> (5 + i) & 1) for i in range(3)]
        self.blank = bool(sc >> 1 & 1)
        self.flip = bool(sc & 1)


class Renderer:
    def __init__(self, gfx, ext_tiles=True, tmap_dx=(0, 0, 0), tmap_dy=(0, 0, 0), flip_dx=None, flip_dy=None, spriteram_buffered=False):
        self.gfx = gfx
        self.ext = ext_tiles                       # I4220 / I4300: 8bpp and 16x16 tiles
        self.dx, self.dy = tmap_dx, tmap_dy
        self.fdx = flip_dx if flip_dx is not None else tuple(-x for x in tmap_dx)
        self.fdy = flip_dy if flip_dy is not None else tuple(-y for y in tmap_dy)
        self.buffered = spriteram_buffered
        self.elements = len(gfx) // 32
        self.h = H                                  # rendered lines (MAME's visible area is 224; larger values are for inspection)

    # ---- palette ---------------------------------------------------------------------------------------------------------------
    @staticmethod
    def pen(st, i):
        w = st.pal[i & 0xfff]
        return (pal5((w >> 6) & 31), pal5((w >> 11) & 31), pal5((w >> 1) & 31))        # GRBx_555

    # ---- tiles (imagetek_i4100_device::get_tile_pix) -----------------------------------------------------------------------------
    def tile_row(self, st, code, y, big):
        """-> list of tilesize entries, each a palette index (opaque) or None (transparent) for line y of the tile; None if the tile is
        unavailable.  Solid-colour tiles return ('solid', pen, opaque)."""
        if code & 0x8000:
            return ('solid', code & 0x0fff, (code & 0xf) != 0xf)
        ti = (code & 0x1ff0) >> 3
        tile = (st.tt[ti] << 16) + st.tt[ti | 1]
        size = 16 if big else 8
        color = (tile & 0x0ff00000) >> 16
        if (color & 0x00f0) == 0x00f0 and self.ext:
            color &= 0x0f00
            trans, shift, bpp8 = 0xff, (3 if big else 1), True
        else:
            trans, shift, bpp8 = 0xf, (2 if big else 0), False
        tile2 = (tile & 0xfffff) + ((code & 0xf) << shift)
        if tile2 >= self.elements:
            return None
        flipxy = (code & 0x6000) >> 13
        if flipxy & 1:
            y = size - y - 1
        base = tile2 * 32
        g = self.gfx
        row = []
        if bpp8:
            rb = base + y * size
            vals = g[rb:rb + size]
        else:
            rb = base + y * (size // 2)
            vals = []
            for b in g[rb:rb + size // 2]:
                vals.append(b & 0xf)
                vals.append(b >> 4)
        for v in vals:
            row.append(None if (v & trans) == trans else (v | color))
        if flipxy & 2:
            row.reverse()
        return row

    # ---- tilemap layers (draw_tilemap / draw_layers) ---------------------------------------------------------------------------
    def draw_layers(self, st, bm, prio, pri):
        for layer in (2, 1, 0):
            if pri != st.layer_pri[layer]:
                continue
            sy, sx = st.scroll[layer * 2], st.scroll[layer * 2 + 1]
            wy, wx = st.window[layer * 2], st.window[layer * 2 + 1]
            big = self.ext and st.tile16[layer]
            tileshift = 4 if big else 3
            tilemask = (1 << tileshift) - 1
            width, height = BIG_N << tileshift, BIG_N << tileshift
            windowwidth, windowheight = width >> 2, height >> 3
            dx = -self.fdx[layer] if st.flip else self.dx[layer]            # MAME: m_screen_flip ? -m_tilemap_flip_scrolldx : m_tilemap_scrolldx
            dy = -self.fdy[layer] if st.flip else self.dy[layer]
            sxx, syy = sx + dx, sy + dy
            cache = {}
            vram = st.vram[layer]
            for y in range(self.h):
                resy = (wy + y - syy) if st.flip else (syy + y - wy)
                scrolly = ((SCR_TOTAL_H - resy - 1) if st.flip else resy) & (windowheight - 1)
                srcline = (wy + scrolly) & (height - 1)
                row_t = srcline >> tileshift
                line = srcline & tilemask
                brow, prow = bm[y], prio[y]
                for x in range(W):
                    resx = (wx + x - sxx) if st.flip else (sxx + x - wx)
                    scrollx = ((SCR_TOTAL_W - resx - 1) if st.flip else resx) & (windowwidth - 1)
                    srccol = (wx + scrollx) & (width - 1)
                    col_t = srccol >> tileshift
                    col = srccol & tilemask
                    code = vram[col_t + row_t * BIG_N]
                    key = (code, line)
                    r = cache.get(key, 0)
                    if r == 0:
                        r = cache[key] = self.tile_row(st, code, line, big)
                    if r is None:
                        continue
                    if isinstance(r, tuple):                                  # solid-colour tile
                        if r[2]:
                            brow[x] = self.pen(st, r[1])
                            prow[x] = 3 - pri
                        continue
                    pi = r[col]
                    if pi is not None:
                        brow[x] = self.pen(st, pi)
                        prow[x] = 3 - pri

    # ---- sprites (draw_sprites / draw_spritegfx) ---------------------------------------------------------------------------------
    def draw_sprites(self, st, bm, prio):
        max_x = (st.screen_xoffset + 1) * 2
        max_y = (st.screen_yoffset + 1) * 2
        sxo = st.sprite_xoffset - (st.screen_xoffset + 1)
        syo = st.sprite_yoffset - (st.screen_yoffset + 1)
        sprites = st.sprite_count % 512
        sp = st.sprite_priority
        layerpri_disable = sp & 0x8000
        global_masknum = sp & 0x1f
        global_pri = (sp & 0x0300) >> 8
        global_masklayer = (sp & 0x0c00) >> 10
        if sprites == 0:
            return
        order = range(sprites) if layerpri_disable else range(sprites - 1, -1, -1)
        lst = []
        for j in order:
            w = st.spr[j * 4:j * 4 + 4]
            x, y, attr, code = w
            curr_pri = (x & 0xf800) >> 11
            if curr_pri == 0x1f:
                continue
            lst.append({'pri': curr_pri, 'flipx': bool(attr & 0x8000), 'flipy': bool(attr & 0x4000), 'color': (attr & 0xf0) >> 4,
                        'zoom': ZOOM[(y & 0xfc00) >> 10] << 8, 'x': x & 0x07ff, 'y': y & 0x03ff,
                        'w': (((attr >> 11) & 7) + 1) * 8, 'h': (((attr >> 8) & 7) + 1) * 8,
                        'gfxstart': 32 * (((attr & 0xf) << 16) + code), 'idx': j})
        for i in range(0x20):
            for s in lst:
                if s['pri'] != i:
                    continue
                pri = global_pri
                if not layerpri_disable and s['pri'] > global_masknum:
                    pri = global_masklayer
                x, y = s['x'] - sxo, s['y'] - syo
                adj = getattr(st, 'spr_adjust', None)          # optional per-sprite (dx, dy) subtracted in the arithmetic (flip-as-mirror experiments)
                if adj:
                    x, y = x - adj[s['idx']][0], y - adj[s['idx']][1]
                flipx, flipy = s['flipx'], s['flipy']
                if st.flip:
                    flipx, flipy = not flipx, not flipy
                    x = max_x - x - ((s['w'] * s['zoom']) >> 16)
                    y = max_y - y - ((s['h'] * s['zoom']) >> 16)
                self.draw_spritegfx(st, bm, prio, s['gfxstart'], s['w'], s['h'], s['color'], flipx, flipy, x, y, s['zoom'], 3 - pri)

    def draw_spritegfx(self, st, bm, prio, gfxstart, width, height, color, flipx, flipy, sx, sy, scale, prival):
        if not scale:
            return
        g = self.gfx
        n = len(g)
        is8 = self.ext and color == 0xf
        if is8:
            if gfxstart + width * height - 1 >= n:
                return
            trans, color = 0xff, 0
        else:
            if gfxstart + width // 2 * height - 1 >= n:
                return
            trans, color = 0xf, color << 4
        palbase = (st.sprite_color_code & 0x0f) << 8
        sw = (scale * width + 0x8000) >> 16
        sh = (scale * height + 0x8000) >> 16
        if not (sw and sh):
            return
        dx = (width << 16) // sw
        dy = (height << 16) // sh
        ex, ey = sx + sw, sy + sh
        if flipx:
            xb, dx = (sw - 1) * dx, -dx
        else:
            xb = 0
        if flipy:
            yi, dy = (sh - 1) * dy, -dy
        else:
            yi = 0
        if sx < 0:
            px = -sx
            sx += px
            xb += px * dx
        if sy < 0:
            py = -sy
            sy += py
            yi += py * dy
        if ex > W:
            ex = W
        if ey > self.h:
            ey = self.h
        if ex <= sx:
            return
        gs = gfxstart % n
        for y in range(sy, ey):
            rowbase = (yi >> 16) * width
            xi = xb
            brow, prow = bm[y], prio[y]
            for x in range(sx, ex):
                p = rowbase + (xi >> 16)
                if is8:
                    c = g[gs + p]
                else:
                    b = g[gs + (p >> 1)]
                    c = (b >> 4) if (p & 1) else (b & 0xf)
                if c != trans:
                    if prow[x] <= prival:
                        brow[x] = self.pen(st, palbase + color + c)
                    prow[x] = 0xff
                xi += dx
            yi += dy

    # ---- frame ------------------------------------------------------------------------------------------------------------------
    def render(self, st):
        bg = self.pen(st, st.bg_color)
        bm = [[bg] * W for _ in range(self.h)]
        prio = [[0] * W for _ in range(self.h)]
        if not st.blank:
            for pri in (3, 2, 1, 0):
                self.draw_layers(st, bm, prio, pri)
            self.draw_sprites(st, bm, prio)
        out = bytearray(W * self.h * 3)
        i = 0
        for row in bm:
            for (r, g, b) in row:
                out[i], out[i + 1], out[i + 2] = r, g, b
                i += 3
        return out


def load_gfx(set_name):
    roms, games = metro_rom.parse_driver()
    regs = metro_rom.build_regions(set_name, roms=roms, games=games, apply_init=True)
    tag = next(t for t in ('vdp3', 'vdp2', 'vdp') if t in regs)
    return bytes(regs[tag])


def diff(a, b):
    """-> (number of differing pixels, bounding box or None)"""
    n, x0, y0, x1, y1 = 0, W, H, -1, -1
    for i in range(0, W * H * 3, 3):
        if a[i:i + 3] != b[i:i + 3]:
            p = i // 3
            x, y = p % W, p // W
            n += 1
            x0, y0, x1, y1 = min(x0, x), min(y0, y), max(x1, x), max(y1, y)
    return n, ((x0, y0, x1, y1) if n else None)


def run(prefix, frame, gfx, args):
    st = State(prefix, frame)
    fx = fy = 0                                    # MAME's flip offsets for these boards (none set)
    if '--flipoffs' in args:                       # --flipoffs 72,39: MAME's set_tmap_flip_x/yoffsets (the layers' mirror about the visible area)
        fx, fy = (int(v) for v in args[args.index('--flipoffs') + 1].split(','))
    tdx = int(args[args.index('--tmapdx') + 1]) if '--tmapdx' in args else 0      # set_tmap_xoffsets (2 on Daitoride / Puzzli); it also sets the flip offset to -tdx
    img = Renderer(gfx, tmap_dx=(tdx,) * 3, flip_dx=(fx - tdx,) * 3, flip_dy=(fy,) * 3).render(st)
    return st, img


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    cmd, prefix = argv[0], argv[1]
    set_name = argv[argv.index('--set') + 1] if '--set' in argv else 'dharma'
    gfx = load_gfx(set_name)
    if cmd == 'all':
        frames = sorted(int(re.search(r'\.(\d+)\.mem$', p).group(1)) for p in glob.glob(prefix + '.*.mem'))
    else:
        frames = [int(argv[2])]
    bad = 0
    for fr in frames:
        st, img = run(prefix, fr, gfx, argv)
        if cmd == 'render':
            out = argv[argv.index('--out') + 1] if '--out' in argv else '%s.%d.ref.png' % (prefix, fr)
            pngio.write(out, W, H, bytes(img))
            print('wrote', out)
            continue
        w, h, ref = pngio.read('%s.%d.png' % (prefix, fr))
        if (w, h) != (W, H):
            print('frame %5d: MAME snapshot is %dx%d, expected %dx%d' % (fr, w, h, W, H))
            bad += 1
            continue
        n, box = diff(img, ref)
        print('frame %5d: %s' % (fr, 'identical' if n == 0 else '%d pixels differ, bbox %s' % (n, box)))
        bad += 1 if n else 0
        if n and '--diff' in argv:
            d = bytearray(ref)
            for i in range(0, W * H * 3, 3):
                if img[i:i + 3] != ref[i:i + 3]:
                    d[i:i + 3] = b'\xff\x00\xff'
            pngio.write(argv[argv.index('--diff') + 1], W, H, bytes(d))
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
