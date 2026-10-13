#!/bin/bash
# Build the golden model in WSL:  mister/sim/upd78c10/build_model.sh   (after: python gen_model.py)  ->  $HOME/build_metro/upd78c10/model
set -e
cd "$(dirname "$0")"
B="${BUILD_DIR:-$HOME/build_metro/upd78c10}"; mkdir -p "$B"
g++ -std=c++17 -O2 -w -Imodel/shim -Imodel/gen -o "$B/model" model.cpp model/gen/core_extract.cpp model/gen/upd7810_opcodes.cpp model/gen/upd7810_table.cpp
echo "built $B/model"
