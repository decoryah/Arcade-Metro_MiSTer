#!/usr/bin/env python3
"""Compare the sound-board bench's WAV (mister/sim/run_sound.sh) with MAME's own (-wavwrite) of the same session: levels per window, the time offset
between them, and the gain that best maps one onto the other.  Pure Python (no numpy).

  python tools/audio_cmp.py <rtl.wav> <mame.wav> [--window 0.5] [--lag 0.4]
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
    if ch == 2:
        a = array.array('h', [(a[i] + a[i + 1]) // 2 for i in range(0, len(a), 2)])
    return a, rate


def mean(x):
    return sum(x) / len(x) if len(x) else 0.0


def rms(x):
    """RMS around the mean (the chips' DC offsets are not sound)"""
    if not len(x):
        return 0.0
    m = mean(x)
    return math.sqrt(sum((v - m) * (v - m) for v in x) / len(x))


def envelope(x, step):
    return [sum(abs(v) for v in x[i:i + step]) / step for i in range(0, len(x) - step + 1, step)]


def main(argv):
    args = [a for a in argv if not a.startswith('--')]
    win = float(argv[argv.index('--window') + 1]) if '--window' in argv else 0.5
    maxlag = float(argv[argv.index('--lag') + 1]) if '--lag' in argv else 0.4
    args = [a for a in args if a not in (str(win), str(maxlag))]
    ra, rate_a = load(args[0])
    rb, rate_b = load(args[1])
    assert rate_a == rate_b, (rate_a, rate_b)
    rate = rate_a
    n = min(len(ra), len(rb))
    ra, rb = ra[:n], rb[:n]
    print('%d samples (%.2f s) each at %d Hz;  overall RMS: rtl %.1f, mame %.1f, ratio mame/rtl %.3f' % (n, n / rate, rate, rms(ra), rms(rb), rms(rb) / max(rms(ra), 1e-9)))
    # alignment by the 10 ms envelope
    st = rate // 100
    ea, eb = envelope(ra, st), envelope(rb, st)
    best = None
    for lag in range(-int(maxlag * 100), int(maxlag * 100) + 1):
        s = 0.0
        cnt = 0
        for i in range(len(ea)):
            j = i + lag
            if 0 <= j < len(eb):
                s += ea[i] * eb[j]; cnt += 1
        if cnt and (best is None or s / cnt > best[0]):
            best = (s / cnt, lag)
    lag = best[1]
    print('best envelope alignment: mame is %+d ms later than rtl' % (lag * 10))
    # level per window and the best gain after alignment
    w = int(win * rate)
    shift = lag * st
    print('%6s %10s %10s %8s   %9s %9s' % ('t[s]', 'rtl rms', 'mame rms', 'ratio', 'rtl mean', 'mame mean'))
    num = den = 0.0
    for t0 in range(0, n - w, w):
        a = ra[t0:t0 + w]
        b0 = t0 + shift
        if b0 < 0 or b0 + w > n:
            continue
        b = rb[b0:b0 + w]
        pa, pb = rms(a), rms(b)
        print('%6.2f %10.1f %10.1f %8.3f   %9.1f %9.1f' % (t0 / rate, pa, pb, pb / pa if pa > 1 else float('nan'), mean(a), mean(b)))
        ma_, mb_ = mean(a), mean(b)
        num += sum((x - ma_) * (y - mb_) for x, y in zip(a, b)); den += sum((x - ma_) * (x - ma_) for x in a)
    g = num / den if den else 0.0
    # correlation coefficient
    sa = sb = sab = 0.0
    cnt = 0
    for i in range(max(0, -shift), min(n, n - shift)):
        x, y = ra[i], rb[i + shift]
        sa += x * x; sb += y * y; sab += x * y; cnt += 1
    corr = sab / math.sqrt(sa * sb) if sa > 0 and sb > 0 else 0.0
    print('least-squares gain mame = g * rtl: g = %.3f;  correlation coefficient %.3f' % (g, corr))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
