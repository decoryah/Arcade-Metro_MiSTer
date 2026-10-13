#!/usr/bin/env python3
# Left-edge sprite scan (see docs/status.md, known RTL deviations): python tools/metro_edgescan.py <zoom index> <comma list of screen x>
# Needs the RTL bench built once in WSL: BUILD_DIR=$HOME/build_metro/repro mister/sim/run_vdp.sh ... (or run work/repro.py once).
"""Left-edge sprite scan: many 8x8 sprites with different left overhangs / flipX / zoom over an empty background; RTL vs model per sprite."""
import subprocess, sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import paths
import metro_ref as R, metro_scene as M, metro_cmp

ZIDX = int(sys.argv[1])                        # zoom table index
XS = [int(v) for v in sys.argv[2].split(',')]  # screen x of the sprite's left edge
FLIPS = [0, 1]
gfx = R.load_gfx('dharma')
st = R.State(os.path.join(paths.BASE, 'work', 'fuzz2', 'g'), 5)                # any state: palette, tile table are reused; everything else is replaced
for l in range(3):
    st.vram[l] = [0x800F] * 65536
st.reg[0x79702] = 0x8000                       # layerpri_disable, draw order = list order, sprite priority 0
st.reg[0x78852] = 0x9f; st.reg[0x78850] = 0x6f; st.reg[0x79706] = 0x400; st.reg[0x79704] = 0x200
st.screen_xoffset, st.screen_yoffset, st.sprite_xoffset, st.sprite_yoffset = 0x9f, 0x6f, 0x400, 0x200
st.sprite_priority, st.sprite_color_code = 0x8000, 0
st.reg[0x79708] = 0; st.reg[0x79710] = 0x24; st.layer_pri = [0, 1, 2]
sxo, syo = 0x400 - 0xa0, 0x200 - 0x70
scale = R.ZOOM[ZIDX] << 8
sz = (scale * 8 + 0x8000) >> 16
rows = sz + 2
st.spr = [0xF800, 0, 0, 0] * 512
n = 0
labels = []
y = 2
for fx in FLIPS:
    for x in XS:
        if y + sz >= 224:
            break
        st.spr[n * 4 + 0] = (0 << 11) | ((x + sxo) & 0x7ff)
        st.spr[n * 4 + 1] = (ZIDX << 10) | ((y + syo) & 0x3ff)
        st.spr[n * 4 + 2] = (fx << 15) | (0 << 11) | (0 << 8) | (3 << 4) | 0       # 8x8, colour 3, high code bits 0
        st.spr[n * 4 + 3] = 0x0123 + n * 7
        labels.append((n, x, fx, y))
        n += 1
        y += rows
st.sprite_count = n
st.reg[0x79700] = n
tag = 'edge_z%d' % ZIDX
M.write_scene(st, os.path.join(paths.BASE, 'work', 'scenes', tag))
out = os.path.join(paths.BASE, 'work', 'sim', '%s.ppm' % tag)
gfxbin = os.path.join(paths.BASE, 'work', 'scenes', 'gfx_dharma.bin')
cmd = 'BUILD_DIR=$HOME/build_metro/repro NOBUILD=1 bash %s %s %s %d %s 3' % (
    paths.wsl(os.path.join(paths.REPO, 'sim', 'run_vdp.sh')), paths.wsl(os.path.join(paths.BASE, 'work', 'scenes', tag)),
    paths.wsl(gfxbin), os.path.getsize(gfxbin), paths.wsl(out))
r = subprocess.run(['wsl', '-e', 'bash', '-c', cmd], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True)
if r.returncode:
    print(r.stdout[-1500:]); sys.exit(1)
w, h, rtl = metro_cmp.read_any(out)
rtl = bytes(rtl)
model = bytes(R.Renderer(gfx).render(st))
print('zoom index %d (scale %d/256, sprite %d px wide)' % (ZIDX, scale >> 8, sz))
bad = 0
for (k, x, fx, y0) in labels:
    cols = set()
    for yy in range(y0, y0 + sz):
        for xx in range(0, 12):
            i = (yy * 320 + xx) * 3
            if rtl[i:i + 3] != model[i:i + 3]:
                cols.add(xx)
    if cols:
        bad += 1
    print('  x=%3d flipx=%d : %s' % (x, fx, 'ok' if not cols else 'MISMATCH at screen columns %s' % sorted(cols)))
print('%d of %d sprites mismatch' % (bad, len(labels)))
