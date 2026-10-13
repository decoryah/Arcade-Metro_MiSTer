#!/bin/bash
# Frozen-state VDP bench (tb_metro_vdp_top.sv + tb_metro_vdp.cpp), run inside WSL:
#   mister/sim/run_vdp.sh <scene dir from tools/metro_scene.py> <gfx.bin> <gfx bytes> <out.ppm> [frames]
# Builds once in $HOME/build_metro/vdp (BUILD_DIR overrides it; NOBUILD=1 reuses the build), writes <out.ppm>.
set -e
cd "$(dirname "$0")"
SCENE="$1"; GFX="$2"; GFXN="$3"; OUT="$4"; FRAMES="${5:-3}"
[ -d "$SCENE" ] && [ -f "$GFX" ] && [ -n "$OUT" ] || { echo "usage: $0 <scenedir> <gfx.bin> <gfxbytes> <out.ppm> [frames]" >&2; exit 2; }
case "$SCENE" in /*) ;; *) SCENE="$PWD/$SCENE" ;; esac
case "$OUT" in /*) ;; *) OUT="$PWD/$OUT" ;; esac
. "$HOME/tools/oss-cad-suite/environment"
B="${BUILD_DIR:-$HOME/build_metro/vdp}"; mkdir -p "$B"
if [ -z "$NOBUILD" ]; then
verilator --cc --exe --build -j 8 -O3 --x-assign fast --x-initial fast ${F64:+-DF64} ${ROZ_PROBE:+-DROZ_PROBE} -CFLAGS "-O3 -march=native" \
    -Wall -Wno-fatal -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNOPTFLAT -Wno-PINCONNECTEMPTY -Wno-WIDTH -Wno-CASEINCOMPLETE \
    -Wno-TIMESCALEMOD -Wno-PINMISSING -Wno-INITIALDLY -Wno-UNDRIVEN -Wno-SYNCASYNCNET -Wno-MULTIDRIVEN -Wno-LATCH -Wno-BLKSEQ \
    -Wno-UNSIGNED -Wno-CMPCONST -Wno-VARHIDDEN -Wno-BLKANDNBLK --no-assert-case -Wno-PROCASSINIT -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND \
    ${PIXDIV:+-GPIXDIV=$PIXDIV} ${HTOT:+-GHTOT=$HTOT} ${VLAST:+-GVLAST=$VLAST} ${VLOG:+-GVLOG=1} --top-module tb_metro_vdp_top -Mdir "$B/obj" \
    ../rtl/metro_dpram.sv ../rtl/metro_tdpram.sv ../rtl/metro_blitter.sv ../rtl/metro_render.sv ../rtl/metro_vdp.sv ../rtl/metro_roz.sv \
    tb_metro_vdp_top.sv tb_metro_vdp.cpp > "$B/build.log" 2>&1 \
    || { grep -E "%Error|error:" "$B/build.log" | head -40; exit 1; }
fi
mkdir -p "$(dirname "$OUT")"
"$B/obj/Vtb_metro_vdp_top" +SCENE="$SCENE" +GFX="$GFX" +GFXSIZE="$GFXN" +OUT="$OUT" +FRAMES="$FRAMES" ${TMAPDX:+"+TMAPDX=$TMAPDX"} ${GFXLAT:+"+GFXLAT=$GFXLAT"} ${WIDE:+"+WIDE=$WIDE"} ${W384:+"+W384=$W384"} ${W304:+"+W304=$W304"} ${TALL:+"+TALL=$TALL"} ${I4100:+"+I4100=$I4100"} ${TMAPDX1:+"+TMAPDX1=$TMAPDX1"} ${BT:+"+BT=$BT"} ${CRTCV:+"+CRTCV=$CRTCV"} ${ROZ:+"+ROZ=$ROZ"} ${GFX2:+"+GFX2=$GFX2"} ${GFX2BASE:+"+GFX2BASE=$GFX2BASE"} ${WINMAME:+"+WINMAME=$WINMAME"} ${PALLATCH:+"+PALLATCH=$PALLATCH"} ${ROZPRIO:+"+ROZPRIO=$ROZPRIO"}
