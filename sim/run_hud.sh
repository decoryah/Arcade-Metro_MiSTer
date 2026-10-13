#!/bin/bash
# Unit bench of the debug overlay: sim/run_hud.sh <out.ppm> [mode 1|2]   (inside WSL)
set -e
cd "$(dirname "$0")"
. "$HOME/tools/oss-cad-suite/environment"
B="${BUILD_DIR:-$HOME/build_metro/hud}"; mkdir -p "$B"
verilator --cc --exe --build -j 4 -O2 --x-assign fast --x-initial fast -Wall -Wno-fatal -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-WIDTH -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND \
    --top-module metro_hud -Mdir "$B/obj" ../rtl/metro_hud.sv tb_hud.cpp > "$B/build.log" 2>&1 || { grep -E "%Error|error:" "$B/build.log" | head -20; exit 1; }
"$B/obj/Vmetro_hud" "$1" "${2:-1}"
