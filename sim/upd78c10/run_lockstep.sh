#!/bin/bash
# RTL vs golden model, in WSL:  [YM2151=1] run_lockstep.sh <audiocpu.bin> <events or -> <max states> <out prefix>   (YM2151=1: the daitorid_portb_w board; events may hold "<state> irq2 <0|1>")
#   builds the Verilator bench once ($HOME/build_metro/upd78c10_rtl, NOBUILD=1 reuses it), runs the model and the RTL on the same ROM and events, and diffs the traces.
set -e
cd "$(dirname "$0")"
ROM="$1"; EV="$2"; MAXS="$3"; OUT="$4"
[ -f "$ROM" ] && [ -n "$OUT" ] || { echo "usage: $0 <audiocpu.bin> <events|-> <max states> <out prefix>" >&2; exit 2; }
. "$HOME/tools/oss-cad-suite/environment"
B="${BUILD_DIR:-$HOME/build_metro/upd78c10_rtl}"; mkdir -p "$B" "$(dirname "$OUT")"
if [ -z "$NOBUILD" ]; then
    verilator --cc --exe --build -j 8 -O3 --x-assign fast --x-initial fast -CFLAGS "-O3 -march=native" -MAKEFLAGS "OPT_FAST=-O3 OPT_SLOW=-O1" \
        -Wall -Wno-fatal -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNOPTFLAT -Wno-PINCONNECTEMPTY -Wno-WIDTH -Wno-CASEINCOMPLETE -Wno-TIMESCALEMOD \
        -Wno-PINMISSING -Wno-INITIALDLY -Wno-UNDRIVEN -Wno-SYNCASYNCNET -Wno-MULTIDRIVEN -Wno-LATCH -Wno-BLKSEQ -Wno-UNSIGNED -Wno-CMPCONST \
        -Wno-VARHIDDEN -Wno-BLKANDNBLK --no-assert-case -Wno-PROCASSINIT -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-UNUSEDPARAM -Wno-SELRANGE -Wno-ALWCOMBORDER \
        --top-module tb_upd78c10_top -Mdir "$B/obj" -I../../rtl ../../rtl/upd78c10.sv tb_upd78c10_top.sv tb_upd78c10.cpp > "$B/build.log" 2>&1 \
        || { grep -E "%Error|error:" "$B/build.log" | head -40; exit 1; }
fi
python3 - "$ROM" "$OUT.rom.hex" <<'PY'
import sys
d = open(sys.argv[1], 'rb').read()
open(sys.argv[2], 'w').write('\n'.join('%02x' % b for b in d + bytes(131072 - len(d))) + '\n')
PY
M="$HOME/build_metro/upd78c10/model"
[ -x "$M" ] || bash ./build_model.sh
"$M" "$ROM" "$EV" "$MAXS" "$OUT.model.tr" ${YM2151:+--ym2151} 2>&1 | tail -2
"$B/obj/Vtb_upd78c10_top" +ROM="$OUT.rom.hex" +TRACE="$OUT.rtl.tr" +EVENTS="$EV" +MAXSTATES="$MAXS" ${YM2151:++YM2151} 2>&1 | tail -3
python3 compare_traces.py "$OUT.model.tr" "$OUT.rtl.tr"
