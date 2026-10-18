#!/bin/bash
# Timed-write replay bench (tb_metro_vdp_top.sv + tb_metro_vdp.cpp +REPLAY), run inside WSL:
#   sim/run_replay.sh <scene dir> <gfx.bin> <gfx bytes> <events.txt> <out prefix> <pictures>
# The scene (tools/metro_scene.py of a vstate dump) is loaded, the raster is aligned to line 224 and MAME's CPU writes (work/b2/vdpwr.lua + mkreplay.py) are played at their times;
# every completed picture is written as <out prefix>.<n>.ppm.  Hardware timing (16 clocks a dot, 392 x 263).  Env: PALLATCH (default 1), SPREARLY (default 0), WINMAME (default 0),
# GFXLAT (extra clocks per ROM request, default 0), W384, I4300 (family D: the chip's native register map), TMAPDX, NOBUILD=1, BUILD_DIR, RTLDIR (another copy of the rtl folder),
# VLOG=1 (the frame-synchronous tile RAM log), LGAW (its size, 2 ** LGAW slots, default 12), FSYNC=1 (the frame-synchronous picture on an I4220 board: Sankokushi, Mouse Shooter GoGo).
set -e
cd "$(dirname "$0")"
SCENE="$1"; GFX="$2"; GFXN="$3"; EV="$4"; OUT="$5"; N="${6:-10}"
. "$HOME/tools/oss-cad-suite/environment"
RTL="${RTLDIR:-../rtl}"; B="${BUILD_DIR:-$HOME/build_metro/vdp_rp}"; mkdir -p "$B"
if [ -z "$NOBUILD" ]; then
verilator --cc --exe --build -j 8 -O3 --x-assign fast --x-initial fast ${F64:+-DF64} ${VLOG_CHECK:+-DVLOG_CHECK} ${F_COPY224:+-DF_COPY224} -CFLAGS "-O3 -march=native" \
    -Wall -Wno-fatal -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNOPTFLAT -Wno-PINCONNECTEMPTY -Wno-WIDTH -Wno-CASEINCOMPLETE \
    -Wno-TIMESCALEMOD -Wno-PINMISSING -Wno-INITIALDLY -Wno-UNDRIVEN -Wno-SYNCASYNCNET -Wno-MULTIDRIVEN -Wno-LATCH -Wno-BLKSEQ \
    -Wno-UNSIGNED -Wno-CMPCONST -Wno-VARHIDDEN -Wno-BLKANDNBLK --no-assert-case -Wno-PROCASSINIT -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND \
    -GPIXDIV=16 -GHTOT=392 -GVLAST=262 ${VLOG:+-GVLOG=1} ${LGAW:+-GLGAW=$LGAW} --top-module tb_metro_vdp_top -Mdir "$B/obj" \
    $RTL/metro_dpram.sv $RTL/metro_tdpram.sv $RTL/metro_blitter.sv $RTL/metro_render.sv $RTL/metro_vdp.sv $RTL/metro_roz.sv \
    tb_metro_vdp_top.sv tb_metro_vdp.cpp > "$B/build.log" 2>&1 \
    || { grep -E "%Error|error:" "$B/build.log" | head -40; exit 1; }
fi
mkdir -p "$(dirname "$OUT")"
[ -z "$RUNBIN" ] || cp "$B/obj/Vtb_metro_vdp_top" "$B/obj/$RUNBIN"
"$B/obj/${RUNBIN:-Vtb_metro_vdp_top}" +SCENE="$SCENE" +GFX="$GFX" +GFXSIZE="$GFXN" +OUT=/dev/null +FRAMES=1 +REPLAY="$EV" +REPLAYPFX="$OUT" +REPLAYN="$N" \
    +PALLATCH="${PALLATCH:-1}" +SPREARLY="${SPREARLY:-0}" +WINMAME="${WINMAME:-0}" +WIDE="${WIDE:-0}" +TALL="${TALL:-0}" +I4100="${I4100:-0}" ${W384:+"+W384=$W384"} ${I4300:+"+I4300=$I4300"} ${TMAPDX:+"+TMAPDX=$TMAPDX"} ${GFXLAT:+"+GFXLAT=$GFXLAT"} ${W304:+"+W304=$W304"} ${TMAPDX1:+"+TMAPDX1=$TMAPDX1"} ${ROZ:+"+ROZ=$ROZ"} ${GFX2:+"+GFX2=$GFX2"} ${GFX2BASE:+"+GFX2BASE=$GFX2BASE"} ${BT:+"+BT=$BT"} ${CRTCV:+"+CRTCV=$CRTCV"} ${PLANEDBG:+"+PLANEDBG"} ${NOPLANE:+"+NOPLANE"} ${BLITLOG:+"+BLITLOG"} ${VRAMDUMP:+"+VRAMDUMP=$VRAMDUMP"} ${FSYNC:+"+FSYNC=$FSYNC"}
