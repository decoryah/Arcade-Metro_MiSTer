# mkreplay.py <vdpwr log> <dump frame> <last frame> <out events>
# Events (rel_clk addr data mask): MAME's CPU writes after the state dump (frame_done of <dump frame> = the beam at line 224), time in core clocks (frame = 263*6272 clocks, drift-free: each MAME frame is
# stretched to exactly one core frame between its frame_done times).
import sys
FRAME = 263 * 6272
log, D, L, outp = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
def num(s): return float(s.replace(',', '.'))
F = {}; W = []
for line in open(log):
    p = line.split()
    if not p: continue
    if p[0] == 'F': F[int(p[2])] = num(p[1])
    elif p[0] == 'W': W.append((num(p[1]), p[2], p[3], p[4]))
fr = sorted(k for k in F if D <= k <= L)
ev = []
for t, a, d, m in W:
    if t < F[D] or t >= F[fr[-1]]: continue
    # frame index k with F[k] <= t < F[k+1]
    k = D
    for kk in fr[:-1]:
        if F[kk] <= t: k = kk
    pos = (k - D) + (t - F[k]) / (F[k + 1] - F[k])
    ev.append((round(pos * FRAME), a, d, m))
ev.sort(key=lambda e: e[0])
with open(outp, 'w') as f:
    for e in ev: f.write("%d %s %s %s\n" % e)
print("%d events from frame %d to %d" % (len(ev), D, fr[-1]))
