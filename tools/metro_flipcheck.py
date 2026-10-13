#!/usr/bin/env python3
"""Verify that screen flip == the UNFLIPPED scene (adjusted) mirrored in X and Y, against MAME's flipped frames (tools/lua/vfuzz.lua scenes).

  python tools/metro_flipcheck.py <prefix>        e.g. work/fuzz/f

MAME flip arithmetic (imagetek_i4100.cpp draw_tilemap / draw_sprites), screen bitmap 392 x 263, visible 320 x 224:
  tilemap, per pixel:   scrollx = (392 - (wx + x - sx) - 1) & (ww-1)    ==  ((sx + 72) - wx + (319 - x)) & (ww-1)
                        scrolly = (263 - (wy + y - sy) - 1) & (wh-1)    ==  ((sy + 39) - wy + (223 - y)) & (wh-1)
     => unflipped algorithm at the mirrored pixel (319-x, 223-y) with scroll (sx+72, sy+39).
  sprites: x_f = max_x - x_nf - floor(w*zoom/65536), flipx toggled; unflipped-and-mirrored position is
           x' = 319 - (x_f + sw - 1) = x_nf + (320 - max_x) - (sw - floor(w*zoom/65536)), flip bits unchanged (double flip cancels).
     => unflipped sprite with screen offset eff = 318 - scrx (x) / 222 - scry (y) and the per-sprite rounding delta subtracted.
"""
import sys, glob, re
sys.path.insert(0, __import__('os').path.dirname(__import__('os').path.abspath(__file__)))
import metro_ref as R, pngio

W, H = R.W, R.H


def mirror_state(st):
    import copy
    s = copy.copy(st)
    s.flip = False
    s.scroll = [(st.scroll[i] + (72 if i % 2 else 39)) & 0xffff for i in range(6)]   # [y0,x0,y1,x1,y2,x2]: odd = x
    s.screen_xoffset = 318 - st.screen_xoffset            # unbounded signed, as MAME (wrapping to 16 bits would shift sprites by 65536)
    s.screen_yoffset = 222 - st.screen_yoffset
    s.spr_adjust = []
    for j in range(512):
        x, y, attr, code = st.spr[j * 4:j * 4 + 4]
        wd = (((attr >> 11) & 7) + 1) * 8
        ht = (((attr >> 8) & 7) + 1) * 8
        scale = R.ZOOM[(y & 0xfc00) >> 10] << 8
        s.spr_adjust.append((((scale * wd + 0x8000) >> 16) - ((scale * wd) >> 16), ((scale * ht + 0x8000) >> 16) - ((scale * ht) >> 16)))
    return s


def mirrored_render(st, gfx):
    img = R.Renderer(gfx).render(mirror_state(st))
    out = bytearray(len(img))
    for y in range(H):
        for x in range(W):
            s = ((H - 1 - y) * W + (W - 1 - x)) * 3
            d = (y * W + x) * 3
            out[d:d + 3] = img[s:s + 3]
    return out


if __name__ == '__main__':
    prefix = sys.argv[1]
    gfx = R.load_gfx('dharma')
    frames = sorted(int(re.search(r'\.(\d+)\.mem$', p).group(1)) for p in glob.glob(prefix + '.*.mem'))
    tested = bad = 0
    for fr in frames:
        st = R.State(prefix, fr)
        if not st.flip or st.blank:
            continue
        w, h, ref = pngio.read('%s.%d.png' % (prefix, fr))
        n, box = R.diff(mirrored_render(st, gfx), bytearray(ref))
        tested += 1
        bad += 1 if n else 0
        print('frame %3d: %s' % (fr, 'mirror == MAME flip' if n == 0 else '%d px differ, bbox %s' % (n, box)))
    print('%d flipped scenes tested, %d differ' % (tested, bad))
