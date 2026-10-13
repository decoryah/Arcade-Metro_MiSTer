#!/usr/bin/env python3
"""Fit MAME's recording of a session as a * YM2413 + b * OKI from the sound-board bench's unmixed stems (mister/sim/run_sound.sh writes <out>.stems.wav:
left = the YM2413 accumulator, right = the OKI output).  DC is removed from all signals with a 0.1 s moving-average high-pass first (the chips and MAME's
mixer carry offsets that are not sound).  Prints the two gains in the units of the stems, per-window levels and the residual.

  python tools/audio_fit.py <stems.wav> <mame.wav> [--lag-ms N]
"""
import array
import math
import sys
import wave


def load(path):
    w = wave.open(path, 'rb')
    ch, rate, n = w.getnchannels(), w.getframerate(), w.getnframes()
    a = array.array('h')
    a.frombytes(w.readframes(n))
    if ch == 1:
        return [list(a)], rate
    return [list(a[i::ch]) for i in range(ch)], rate


def highpass(x, win):
    n = len(x)
    pre = [0.0] * (n + 1)
    for i, v in enumerate(x):
        pre[i + 1] = pre[i] + v
    out = []
    h = win // 2
    for i in range(n):
        lo, hi = max(0, i - h), min(n, i + h + 1)
        out.append(x[i] - (pre[hi] - pre[lo]) / (hi - lo))
    return out


def rms(x):
    return math.sqrt(sum(v * v for v in x) / len(x)) if x else 0.0


def main(argv):
    args = [a for a in argv if not a.startswith('--')]
    lag_ms = int(argv[argv.index('--lag-ms') + 1]) if '--lag-ms' in argv else 0
    args = [a for a in args if a != str(lag_ms)]
    (ym, oki), rate = load(args[0])
    (mame,), rate2 = load(args[1])
    assert rate == rate2
    shift = int(lag_ms * rate / 1000)
    n = min(len(ym), len(mame) - shift) if shift >= 0 else min(len(ym) + shift, len(mame))
    if shift >= 0:
        ym, oki, mame = ym[:n], oki[:n], mame[shift:shift + n]
    else:
        ym, oki, mame = ym[-shift:-shift + n], oki[-shift:-shift + n], mame[:n]
    win = rate // 10
    ym, oki, mame = highpass(ym, win), highpass(oki, win), highpass(mame, win)
    # the two synthesisers' waveforms are not sample-correlated (different implementations, small timing offsets): fit the ENERGY per window,
    # E_mame ~ A * E_ym + B * E_oki with A = a^2, B = b^2 (the two chips play different things, so their powers add)
    w = rate // 2
    rows = []
    for t0 in range(0, n - w, w):
        seg = slice(t0, t0 + w)
        rows.append((t0 / rate, rms(mame[seg]) ** 2, rms(ym[seg]) ** 2, rms(oki[seg]) ** 2))
    use = [r for r in rows if r[1] > 4.0 or r[2] > 4.0 or r[3] > 4.0]
    syy = sum(r[2] * r[2] for r in use); soo = sum(r[3] * r[3] for r in use); syo = sum(r[2] * r[3] for r in use)
    sym = sum(r[2] * r[1] for r in use); som = sum(r[3] * r[1] for r in use)
    det = syy * soo - syo * syo
    A = (sym * soo - som * syo) / det
    B = (som * syy - sym * syo) / det
    if A < 0 or B < 0:
        A, B = (max(sym / syy, 0.0), 0.0) if A < 0 else (0.0, max(som / soo, 0.0))
    a, b = math.sqrt(A), math.sqrt(B)
    print('%d samples (%.1f s);  window energies  E_mame ~ a^2 E_ym + b^2 E_oki:   a = %.4f (YM2413)   b = %.4f (OKI)' % (n, n / rate, a, b))
    print('%6s %9s %9s %9s %9s   (RMS per half second, DC removed)' % ('t[s]', 'mame', 'a*ym', 'b*oki', 'model'))
    for t, em, ey, eo in rows:
        print('%6.2f %9.1f %9.1f %9.1f %9.1f' % (t, math.sqrt(em), a * math.sqrt(ey), b * math.sqrt(eo), math.sqrt(A * ey + B * eo)))
    # also the fit restricted to YM-only windows (OKI silent) and OKI-dominated ones
    ymonly = [r for r in rows if r[2] > 4.0 and r[3] < 1.0]
    if ymonly:
        g = math.sqrt(sum(r[1] for r in ymonly) / sum(r[2] for r in ymonly))
        print('YM-only windows (%d): a = %.4f' % (len(ymonly), g))
    okionly = [r for r in rows if r[3] > 100.0 and r[2] < 4.0]
    if okionly:
        g = math.sqrt(sum(r[1] for r in okionly) / sum(r[3] for r in okionly))
        print('OKI-only windows (%d): b = %.4f' % (len(okionly), g))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
