#!/bin/bash
# Run the frozen-state VDP bench (sim/run_vdp.sh) over dumped frames and compare each with MAME's snapshot.
#   tools/vtest.sh <set> <prefix> <frame> [<frame> ...]       e.g.  tools/vtest.sh dharma work/states/dharma 420 1000 1800
# <prefix> is relative to the base folder (the one with work/ and ref/, tools/paths.py); <prefix>.<frame>.mem/.regs/.png come from
# tools/lua/vstate.lua (real play) or vfuzz.lua (random scenes).
# Builds once (first frame), reuses the build after.  Prints one line a frame; exit status = number of failures.
# Env: PY (python 3.8+), FRAMES (frames the bench lets pass after loading, default 3), NOBUILD=1 (reuse the build from the first frame on).
export MSYS_NO_PATHCONV=1
HERE="$(cd "$(dirname "$0")" && pwd -W)"                 # C:/... (Windows Python cannot open /c/... with MSYS_NO_PATHCONV=1)
PY=${PY:-/c/Python38/python.exe}
WB="$($PY "$HERE/paths.py" wslbase | tr -d '\r')"       # /mnt/c/... : what WSL sees (base: work/, ref/)
WR="$($PY "$HERE/paths.py" wslrepo | tr -d '\r')"       #               (repository: sim/, tools/, mra/)
RW="$(echo "$WR" | sed -E 's#^/mnt/([a-z])/#\U\1:/#')"  # C:/... : for Python
BW="$(echo "$WB" | sed -E 's#^/mnt/([a-z])/#\U\1:/#')"
BM="$(echo "$WB" | sed -E 's#^/mnt/#/#')"               # /c/... : for Git Bash itself
SET="$1"; PREFIX="$2"; shift 2
TAG="$(basename "$(dirname "$PREFIX")")_$(basename "$PREFIX")"
mkdir -p "$BM/work/scenes" "$BM/work/sim"
GFXBIN="$BM/work/scenes/gfx_$SET.bin"
[ -f "$GFXBIN" ] || $PY "$RW/tools/metro_scene.py" --gfx "$SET" "$BW/work/scenes/gfx_$SET.bin" > /dev/null
GFXN=$(stat -c %s "$GFXBIN")
fail=0; first=1
for f in "$@"; do
    $PY "$RW/tools/metro_scene.py" "$BW/$PREFIX" "$f" "$BW/work/scenes/$TAG.f$f" || { echo "f$f: scene prep failed"; fail=$((fail+1)); continue; }
    # WSL does not forward Git-Bash environment variables, so pass NOBUILD through env(1)
    if [ $first = 1 ] && [ -z "$NOBUILD" ]; then ENVV="env TMAPDX=${TMAPDX:-0} GFXLAT=${GFXLAT:-0} PIXDIV=${PIXDIV:-} HTOT=${HTOT:-} WIDE=${WIDE:-} W384=${W384:-} W304=${W304:-} TALL=${TALL:-} I4100=${I4100:-} BUILD_DIR=${BUILD_DIR:-}"; else ENVV="env NOBUILD=1 TMAPDX=${TMAPDX:-0} GFXLAT=${GFXLAT:-0} PIXDIV=${PIXDIV:-} HTOT=${HTOT:-} WIDE=${WIDE:-} W384=${W384:-} W304=${W304:-} TALL=${TALL:-} I4100=${I4100:-} BUILD_DIR=${BUILD_DIR:-}"; fi
    first=0
    wsl -e $ENVV bash "$WR/sim/run_vdp.sh" "$WB/work/scenes/$TAG.f$f" "$WB/work/scenes/gfx_$SET.bin" "$GFXN" "$WB/work/sim/$TAG.f$f.ppm" "${FRAMES:-3}" \
        > "$BM/work/sim/$TAG.f$f.log" 2>&1 || { echo "f$f: bench failed (see work/sim/$TAG.f$f.log)"; fail=$((fail+1)); continue; }
    res=$($PY "$RW/tools/metro_cmp.py" "$BW/work/sim/$TAG.f$f.ppm" "$BW/$PREFIX.$f.png" --diff "$BW/work/sim/$TAG.f$f.diff.png")
    ovr=$(grep -o "max line render.*" "$BM/work/sim/$TAG.f$f.log" | tail -1)
    echo "f$f: $res   [$ovr]"
    case "$res" in "0 of"*) ;; *) fail=$((fail+1)) ;; esac
done
exit $fail
