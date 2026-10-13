#!/usr/bin/env python3
"""The release zip: every MRA and the three core files, in MiSTer's SD card structure (unpack it over the root of the card).

  python tools/package.py YYYYMMDD[a-z] [core=YYYYMMDD[a-z] ...]   (releases/metro_<date>.rbf, metrod64_<date>.rbf, metrof64_<date>.rbf)

A `core=<date>` argument takes that core file from an older release (a core whose sources did not change: `metrof64=20261013a`); the file keeps its own date in the zip.

Writes dist/Metro_MiSTer_<date>.zip:
  _Arcade/<title>.mra, _Arcade/_alternatives/_<Title>/<set>.mra   (mra/, as written by tools/make_mra.py)
  _Arcade/cores/metro_<date>.rbf, metrod64_<date>.rbf, metrof64_<date>.rbf

The MRAs name the cores `metro`, `metrod64` and `metrof64` (MiSTer takes the newest <name>_*.rbf).  No ROMs in it (the merged MAME sets go to /media/fat/games/mame/).
A core file that is not in releases/ is left out with a note (a zip with only some of the cores is a partial release).
"""
import os
import sys
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
CORES = ('metro', 'metrod64', 'metrof64')


def main(argv):
    if not argv:
        print(__doc__)
        return 2
    date = argv[0]
    older = dict(a.split('=', 1) for a in argv[1:] if '=' in a)
    rbfs = []
    for core in CORES:
        p = os.path.join(REPO, 'releases', '%s_%s.rbf' % (core, older.get(core, date)))
        if os.path.exists(p):
            rbfs.append(p)
        else:
            print('note: no', p)
    if not rbfs:
        return 1
    mradir = os.path.join(REPO, 'mra')
    mras = []
    for d, _, fs in os.walk(mradir):
        for f in fs:
            if f.endswith('.mra'):
                full = os.path.join(d, f)
                mras.append((full, '_Arcade/' + os.path.relpath(full, mradir).replace(os.sep, '/')))
    os.makedirs(os.path.join(REPO, 'dist'), exist_ok=True)
    out = os.path.join(REPO, 'dist', 'Metro_MiSTer_%s.zip' % date)
    with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED) as z:
        for full, arc in sorted(mras, key=lambda t: t[1]):
            z.writestr(arc, open(full, encoding='utf-8').read())
        for p in rbfs:
            z.write(p, '_Arcade/cores/' + os.path.basename(p))
    print('%s: %d MRAs + %s' % (out, len(mras), ', '.join(os.path.basename(p) for p in rbfs)))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
