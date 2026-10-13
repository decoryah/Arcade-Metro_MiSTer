#!/bin/bash
# IRQ-model test (tb_metro_vdp.cpp +IRQTEST), run inside WSL:  mister/sim/run_irq.sh [frames]
# Same sources as run_vdp.sh but its own build directory ($HOME/build_metro/irq), so it can run while a long VDP bench is using the other one.
set -e
cd "$(dirname "$0")"
FRAMES="${1:-6}"
. "$HOME/tools/oss-cad-suite/environment"
B="$HOME/build_metro/irq"; mkdir -p "$B"
if [ -z "$NOBUILD" ]; then
verilator --cc --exe --build -j 8 -O3 --x-assign fast --x-initial fast -CFLAGS "-O3 -march=native" \
    -Wall -Wno-fatal -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNOPTFLAT -Wno-PINCONNECTEMPTY -Wno-WIDTH -Wno-CASEINCOMPLETE \
    -Wno-TIMESCALEMOD -Wno-PINMISSING -Wno-INITIALDLY -Wno-UNDRIVEN -Wno-SYNCASYNCNET -Wno-MULTIDRIVEN -Wno-LATCH -Wno-BLKSEQ \
    -Wno-UNSIGNED -Wno-CMPCONST -Wno-VARHIDDEN -Wno-BLKANDNBLK --no-assert-case -Wno-PROCASSINIT -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND \
    --top-module tb_metro_vdp_top -Mdir "$B/obj" \
    ../rtl/metro_dpram.sv ../rtl/metro_tdpram.sv ../rtl/metro_blitter.sv ../rtl/metro_render.sv ../rtl/metro_vdp.sv \
    tb_metro_vdp_top.sv tb_metro_vdp.cpp > "$B/build.log" 2>&1 \
    || { grep -E "%Error|error:" "$B/build.log" | head -40; exit 1; }
fi
"$B/obj/Vtb_metro_vdp_top" +IRQTEST +FRAMES="$FRAMES"
