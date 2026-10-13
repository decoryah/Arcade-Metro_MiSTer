#!/usr/bin/env python3
"""Compare every dumped state under <prefix> with MAME's snapshot and tally which hardware features the states exercise.
(Used on the real-play dumps from tools/lua/vstate.lua and on the randomised scenes from tools/lua/vfuzz.lua.)

  python tools/metro_cov.py <prefix> [--set dharma]
"""
import sys, glob, re, collections, time
sys.path.insert(0, __import__('os').path.dirname(__import__('os').path.abspath(__file__)))
import metro_ref as R, pngio
SET = sys.argv[sys.argv.index('--set') + 1] if '--set' in sys.argv else 'dharma'
gfx = R.load_gfx(SET); P = sys.argv[1]
frames = sorted(int(re.search(r'\.(\d+)\.mem$', p).group(1)) for p in glob.glob(P + '.*.mem'))
tot = collections.Counter(); zooms = collections.Counter(); spri = collections.Counter(); curpri = collections.Counter()
bad = []; t0 = time.time()
for FR in frames:
    st = R.State(P, FR); r = R.Renderer(gfx); f = collections.Counter()
    o = r.tile_row
    def tr(st_, code, y, big, f=f, o=o):
        res = o(st_, code, y, big)
        if isinstance(res, tuple): f['solid_tile'] += 1
        elif res is None: f['tile_unavailable'] += 1
        else:
            ti = (code & 0x1ff0) >> 3; tile = (st_.tt[ti] << 16) + st_.tt[ti | 1]
            f['tile8bpp' if ((tile >> 16) & 0x0ff0) & 0xf0 == 0xf0 else 'tile4bpp'] += 1
            if code & 0x2000: f['tile_flipy'] += 1
            if code & 0x4000: f['tile_flipx'] += 1
            if big: f['tile16x16'] += 1
        return res
    r.tile_row = tr
    os_ = r.draw_spritegfx
    def sp(st_, bm, prio, gs, w, h, color, fx, fy, sx, sy, scale, prival, f=f, os_=os_):
        f['sprites_drawn'] += 1
        if color == 0xf: f['sprite8bpp'] += 1
        if fx: f['sprite_flipx'] += 1
        if fy: f['sprite_flipy'] += 1
        if sx < 0 or sy < 0 or sx + w > 320 or sy + h > 224: f['sprite_clipped'] += 1
        zooms[scale >> 8] += 1; spri[3 - prival] += 1
        return os_(st_, bm, prio, gs, w, h, color, fx, fy, sx, sy, scale, prival)
    r.draw_spritegfx = sp
    img = r.render(st)
    w, h, ref = pngio.read('%s.%d.png' % (P, FR))
    n, box = R.diff(img, ref)
    if n: bad.append((FR, n, box))
    tot.update(f)
    if any(st.scroll): tot['frames_with_scroll'] += 1
    if any(st.window): tot['frames_with_window'] += 1
    if any(st.tile16): tot['frames_with_16x16_layer'] += 1
    if st.blank: tot['frames_blank'] += 1
    if st.flip: tot['frames_flip'] += 1
    tot['frames'] += 1
    tot['layerpri_' + ''.join(map(str, st.layer_pri))] += 1
    tot['sprpri_%04x' % st.sprite_priority] += 1
print('frames %d, mismatching %d, %.0f s' % (len(frames), len(bad), time.time() - t0))
for b in bad[:20]: print('  MISMATCH frame %d: %d px, bbox %s' % b)
print('coverage:')
for k, v in sorted(tot.items()): print('  %-26s %d' % (k, v))
print('sprite zoom values (scale>>8):', sorted(zooms.items()))
print('sprite global pri:', sorted(spri.items()))
