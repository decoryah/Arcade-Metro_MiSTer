#!/bin/bash
# Unit bench of the ES8712 + MSM6585 against a transcription of MAME's code, in WSL:  mister/sim/run_es8712.sh
set -e
cd "$(dirname "$0")"
. "$HOME/tools/oss-cad-suite/environment"
B="${BUILD_DIR:-$HOME/build_metro/es8712}"; mkdir -p "$B"
verilator --cc --exe --build -j 4 -O2 -Wno-fatal -Wno-lint --top-module metro_es8712 -Mdir "$B/obj" ../rtl/metro_es8712.sv tb_es8712.cpp > "$B/build.log" 2>&1 || { grep -E "%Error|error:" "$B/build.log" | head; exit 1; }
"$B/obj/Vmetro_es8712"
