#!/bin/bash
# Sound-board bench of family F, in WSL:  sim/run_sndf.sh <image> <fsnd.lua log> <seconds> <out.wav>     (BUILD_DIR / NOBUILD like run_sys.sh)
set -e
cd "$(dirname "$0")"
IMAGE="$1"; EV="$2"; SECS="$3"; WAV="$4"
[ -f "$IMAGE" ] && [ -n "$WAV" ] || { echo "usage: $0 <image> <events> <seconds> <out.wav>" >&2; exit 2; }
. "$HOME/tools/oss-cad-suite/environment"
B="${BUILD_DIR:-$HOME/build_metro/sndf}"; mkdir -p "$B" "$(dirname "$WAV")"
if [ -z "$NOBUILD" ]; then
verilator --cc --exe --build -j 8 -O3 --x-assign fast --x-initial fast ${F64:+-DF64} ${STEREO0:+-DSTEREO0} ${SNDF_YMLOG:+-DSNDF_YMLOG} -CFLAGS "-O3 -march=native" -MAKEFLAGS "OPT_FAST=-O3 OPT_SLOW=-O1" \
    -Wall -Wno-fatal -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNOPTFLAT -Wno-PINCONNECTEMPTY -Wno-WIDTH -Wno-CASEINCOMPLETE -Wno-TIMESCALEMOD \
    -Wno-PINMISSING -Wno-INITIALDLY -Wno-UNDRIVEN -Wno-SYNCASYNCNET -Wno-MULTIDRIVEN -Wno-LATCH -Wno-BLKSEQ -Wno-UNSIGNED -Wno-CMPCONST \
    -Wno-VARHIDDEN -Wno-BLKANDNBLK --no-assert-case -Wno-PROCASSINIT -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-UNUSEDPARAM -Wno-SELRANGE -Wno-ALWCOMBORDER \
    -Wno-IMPLICIT -Wno-UNOPT -Wno-MODDUP -Wno-PINNOCONNECT \
    --top-module tb_sndf_top -Mdir "$B/obj" -I../rtl -I../modules/jt10 \
    ../rtl/metro_sndf.sv ${YMPCM:-../rtl/metro_ympcm.sv} ../rtl/metro_mrom_arb.sv ../rtl/metro_sdram.sv ../rtl/metro_loader.sv sdram_model.sv \
    ../modules/jt10/*.v ../modules/jt49/*.v ../modules/cpu-tv80/*.v \
    tb_sndf_top.sv tb_sndf.cpp > "$B/build.log" 2>&1 \
    || { grep -E "%Error|error:" "$B/build.log" | head -40; exit 1; }
fi
"$B/obj/Vtb_sndf_top" +IMAGE="$IMAGE" +EVENTS="$EV" +SECONDS="$SECS" +WAV="$WAV" ${YMFILE:+"+YMFILE=$YMFILE"} ${SDRCHK:+"+SDRCHK=$SDRCHK"}
