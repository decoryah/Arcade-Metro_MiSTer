#!/bin/bash
# Unit bench of the CRT Adjust glue + rmonic79's line buffer (tb_crtadj.cpp), in WSL:  mister/sim/run_crtadj.sh
set -e
cd "$(dirname "$0")"
. "$HOME/tools/oss-cad-suite/environment"
B="${BUILD_DIR:-$HOME/build_metro/crtadj}"; mkdir -p "$B"
verilator --cc --exe --build -j 4 -O2 -Wno-fatal -Wno-lint --top-module metro_crtadj -Mdir "$B/obj" ../modules/crt_adjust/crt_adjust.sv ../rtl/metro_crtadj.sv tb_crtadj.cpp > "$B/build.log" 2>&1 || { grep -E "%Error|error:" "$B/build.log" | head -20; exit 1; }
"$B/obj/Vmetro_crtadj"
