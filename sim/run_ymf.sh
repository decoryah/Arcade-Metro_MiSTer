#!/bin/bash
# YMF278B wrapper bench (WSL): run_ymf.sh <rom.bin> <ymflog.txt> <samples.txt> [seconds] [latency]
set -e
cd "$(dirname "$0")"
ROM="$1"; LOG="$2"; OUT="$3"; SECS="${4:-30}"; LAT="${5:-12}"
. "$HOME/tools/oss-cad-suite/environment"
B="${BUILD_DIR:-$HOME/build_metro/ymf}"; mkdir -p "$B"
if [ -z "$NOBUILD" ]; then
verilator --cc --exe --build -j 8 -O3 --x-assign fast --x-initial fast -CFLAGS "-O3 -march=native" \
    -Wall -Wno-fatal -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNOPTFLAT -Wno-PINCONNECTEMPTY -Wno-WIDTH -Wno-CASEINCOMPLETE \
    -Wno-TIMESCALEMOD -Wno-PINMISSING -Wno-INITIALDLY -Wno-UNDRIVEN -Wno-SYNCASYNCNET -Wno-MULTIDRIVEN -Wno-LATCH -Wno-BLKSEQ \
    -Wno-UNSIGNED -Wno-CMPCONST -Wno-VARHIDDEN -Wno-BLKANDNBLK --no-assert-case -Wno-PROCASSINIT -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND \
    -DSIM -DYMF_DBGSLOT=${DBGSLOT:-7} ${DBG:+-DYMF_DBG} --top-module tb_ymf_top -Mdir "$B/obj" -I../rtl ../rtl/ymf278b_pkg.sv ../rtl/ymf278b.sv ../rtl/metro_ymf.sv tb_ymf_top.sv tb_ymf.cpp > "$B/build.log" 2>&1 \
    || { grep -E "%Error|error:" -A3 "$B/build.log" | head -60; exit 1; }
fi
"$B/obj/Vtb_ymf_top" +ROM="$ROM" +LOG="$LOG" +OUT="$OUT" +SECONDS="$SECS" +LAT="$LAT"
