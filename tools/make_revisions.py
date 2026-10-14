#!/usr/bin/env python3
"""Derives the Quartus revisions of the three core files from Metro.qsf (the 32 MB core `metro`).

  python tools/make_revisions.py            writes Metro_D64.qsf and Metro_F64.qsf next to Metro.qsf
  python tools/make_revisions.py --seed D64=3 --seed F64=1 --seed metro=4 --id 261013a

Metro.qsf holds every setting; its VARIANT-BEGIN / VARIANT-END block is the variant's own macros.  The revisions repeat the file with their own block and fitter seed:

  metro      Metro.qsf       D_BUILD D_VLOG NO_YMF               32 MB SDRAM module: every game except family F
  metrod64   Metro_D64.qsf   D_BUILD D_VLOG F64                  64 MB module: + family C (YMF278B) and Mahjong Gakuensai
  metrof64   Metro_F64.qsf   F_BUILD F64 F_VLOG NO_YMF           64 MB module: Blazing Tornado, Grand Striker 2

Build one:  quartus_sh --flow compile Metro -c Metro_D64        (output_files/Metro_D64.rbf; the id shown in the OSD is build_id.v)
--id writes build_id.v (`define BUILD_DATE "<id>"); sys/build_id.tcl keeps it.  The fitter seed matters: the design has a few tenths of a ns of placement noise at 96 MHz,
the seeds that met timing for each release are in docs/status.md.
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)

VARIANTS = {
    'D64': ['D_BUILD', 'D_VLOG', 'F64'],
    'F64': ['F_BUILD', 'F64', 'F_VLOG', 'NO_YMF'],
}
COMMENT = {
    'D64': '# the 64 MB core metrod64: every game except family F, + family C (YMF278B: Mouse Shooter GoGo, Bal Cube, Daitoride YMF278B version, Bang Bang Ball, Battle Bubble) and\n'
           '# Mahjong Gakuensai 1 / 2 (32 MB of graphics)',
    'F64': '# the 64 MB core metrof64: family F (Blazing Tornado, Grand Striker 2: 053936 plane, Z80 + YM2610), frame-synchronous tile RAM; the older sound boards and the YMF278B are not built',
}


def main(argv):
    seeds = {}
    ident = None
    it = iter(argv)
    for a in it:
        if a == '--seed':
            k, v = next(it).split('=')
            seeds[k] = int(v)
        elif a == '--id':
            ident = next(it)
    base = open(os.path.join(REPO, 'Metro.qsf'), newline='').read()
    crlf = '\r\n' in base
    t = base.replace('\r\n', '\n')
    m = re.search(r'# VARIANT-BEGIN\n.*?# VARIANT-END\n', t, re.S)
    if not m:
        print('Metro.qsf has no VARIANT block')
        return 1
    if 'metro' in seeds:
        t = re.sub(r'(set_global_assignment -name SEED )\d+', r'\g<1>%d' % seeds['metro'], t)
        open(os.path.join(REPO, 'Metro.qsf'), 'w', newline='').write(t.replace('\n', '\r\n') if crlf else t)
        m = re.search(r'# VARIANT-BEGIN\n.*?# VARIANT-END\n', t, re.S)
    for v, macros in VARIANTS.items():
        block = '# VARIANT-BEGIN\n' + COMMENT[v] + '\n' + ''.join('set_global_assignment -name VERILOG_MACRO "%s"\n' % x for x in macros) + '# VARIANT-END\n'
        s = t[:m.start()] + block + t[m.end():]
        if v in seeds:
            s = re.sub(r'(set_global_assignment -name SEED )\d+', r'\g<1>%d' % seeds[v], s)
        out = os.path.join(REPO, 'Metro_%s.qsf' % v)
        open(out, 'w', newline='').write(s.replace('\n', '\r\n') if crlf else s)
        print('wrote', out)
    if ident:
        open(os.path.join(REPO, 'build_id.v'), 'w', newline='').write('`define BUILD_DATE "%s"' % ident)
        print('build_id.v:', ident)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
