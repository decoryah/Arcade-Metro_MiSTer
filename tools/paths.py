#!/usr/bin/env python3
"""Where things are, for every tool in this folder (same scheme as taitol-mister/mister/tools/paths.py).

  REPO  the repository root (the Quartus project: Metro.qpf, mra/, sim/, tools/, docs/ ...).
  BASE  the scratch area with `work/` (MAME's dumps and snapshots, ROM images, simulation output) and `ref/` (`ref/mame`: a MAME 0.289
        source tree, `ref/Arcade-HyperDuel_MiSTer`: the VDP's origin). NOT part of the repository (both are in .gitignore). It is
          * $METRO_BASE if that is set,
          * else the folder above the repository when that has a `ref` or `work` folder (the owner's layout: <BASE>/mister is the
            repository),
          * else the repository itself (a plain clone: make `work/` and `ref/` in it).
  MAME  MAME 0.289's mame.exe (not in the repository): $METRO_MAME if set, else tools/mame/mame.exe, else the owner's other checkout
        <BASE>/../taitol-mister/mister/tools/mame/mame.exe.

  python tools/paths.py repo|base|wslrepo|wslbase|mame     prints one of them (for the shell scripts)
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)


def _base():
    b = os.environ.get('METRO_BASE')
    if b:
        return os.path.abspath(b)
    up = os.path.dirname(REPO)
    if os.path.isdir(os.path.join(up, 'ref')) or os.path.isdir(os.path.join(up, 'work')):
        return up
    return REPO


BASE = _base()


def _mame():
    cands = [os.environ.get('METRO_MAME'), os.path.join(HERE, 'mame', 'mame.exe'),
             os.path.join(os.path.dirname(BASE), 'taitol-mister', 'mister', 'tools', 'mame', 'mame.exe')]
    for c in cands:
        if c and os.path.exists(c):
            return c
    return cands[1]


MAME = _mame()


def wsl(path):
    """A Windows path as the WSL sees it (C:\\x\\y -> /mnt/c/x/y); other paths are returned unchanged."""
    p = os.path.abspath(path).replace('\\', '/')
    if len(p) > 1 and p[1] == ':':
        return '/mnt/' + p[0].lower() + p[2:]
    return p


if __name__ == '__main__':
    what = sys.argv[1] if len(sys.argv) > 1 else 'repo'
    print({'repo': REPO, 'base': BASE, 'wslrepo': wsl(REPO), 'wslbase': wsl(BASE), 'mame': MAME}[what])
