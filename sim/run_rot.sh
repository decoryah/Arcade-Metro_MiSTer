#!/bin/bash
# Geometry check of the framework's screen_rotate (sys/arcade_video.v) with the Metro raster, in WSL:  mister/sim/run_rot.sh
# A 360 x 224 frame whose pixel (x, y) = (R x, G y) goes through it; the DDRAM writes are rebuilt into the framebuffer and the four corners are reported:
# rotate_ccw 0 turns the picture 90 degrees clockwise (MAME's ROT90), 1 counter-clockwise (ROT270).
set -e
cd "$(dirname "$0")"
. "$HOME/tools/oss-cad-suite/environment"
B="${BUILD_DIR:-$HOME/build_metro/rot}"; mkdir -p "$B"
verilator --cc --exe --build -j 4 -O2 -Wno-fatal -Wno-lint --top-module screen_rotate -Mdir "$B/obj" ../sys/arcade_video.v tb_screen_rotate.cpp > "$B/build.log" 2>&1
"$B/obj/Vscreen_rotate" 0
"$B/obj/Vscreen_rotate" 1
