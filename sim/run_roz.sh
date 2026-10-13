#!/bin/bash
# Unit bench of rtl/metro_roz.sv against tools/metro_roz.py (run inside WSL):  sim/run_roz.sh <frame.roz> <gfx2.bin> <out.bin> [lat_map lat_blk]
set -e
cd "$(dirname "$0")"
. "$HOME/tools/oss-cad-suite/environment"
B="${BUILD_DIR:-$HOME/build_metro/roz}"
mkdir -p "$B"
if [ -z "$NOBUILD" ]; then
verilator --cc --exe --build -j 4 -O2 --x-assign fast --x-initial fast -Wno-fatal -Wno-WIDTH -Wno-UNOPTFLAT -Wno-CASEINCOMPLETE -Wno-DECLFILENAME \
    ${GGS:+-GGG_GS=$GGS} ${GGB:+-GGG_BT=$GGB} --top-module metro_roz -Mdir "$B/obj" ../rtl/metro_roz.sv tb_roz.cpp > "$B/build.log" 2>&1 \
    || { grep -E "%Error|error:" "$B/build.log" | head -40; exit 1; }
fi
"$B/obj/Vmetro_roz" "$@"
