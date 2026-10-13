#!/bin/bash
# Sound-board bench, in WSL:  mister/sim/run_sound.sh <image> <ainput log> <seconds> <out.wav>     (BUILD_DIR / NOBUILD like run_sys.sh)
set -e
cd "$(dirname "$0")"
IMAGE="$1"; EV="$2"; SECS="$3"; WAV="$4"
[ -f "$IMAGE" ] && [ -n "$WAV" ] || { echo "usage: $0 <image> <events> <seconds> <out.wav>" >&2; exit 2; }
. "$HOME/tools/oss-cad-suite/environment"
B="${BUILD_DIR:-$HOME/build_metro/sound}"; mkdir -p "$B" "$(dirname "$WAV")"
if [ -z "$NOBUILD" ]; then
verilator --cc --exe --build -j 8 -O3 --x-assign fast --x-initial fast -CFLAGS "-O3 -march=native" -MAKEFLAGS "OPT_FAST=-O3 OPT_SLOW=-O1" \
    -Wall -Wno-fatal -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNOPTFLAT -Wno-PINCONNECTEMPTY -Wno-WIDTH -Wno-CASEINCOMPLETE -Wno-TIMESCALEMOD \
    -Wno-PINMISSING -Wno-INITIALDLY -Wno-UNDRIVEN -Wno-SYNCASYNCNET -Wno-MULTIDRIVEN -Wno-LATCH -Wno-BLKSEQ -Wno-UNSIGNED -Wno-CMPCONST \
    -Wno-VARHIDDEN -Wno-BLKANDNBLK --no-assert-case -Wno-PROCASSINIT -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-UNUSEDPARAM -Wno-SELRANGE -Wno-ALWCOMBORDER \
    -Wno-IMPLICIT -Wno-UNOPT -Wno-MODDUP -Wno-PINNOCONNECT \
    --top-module tb_metro_sound_top -Mdir "$B/obj" -I../rtl -I../modules/ikaopll -I../modules/jt6295/hdl -I../modules/jt51/hdl \
    ../rtl/upd78c10.sv ../rtl/metro_sound.sv ../rtl/metro_mrom_arb.sv ../rtl/metro_sdram.sv ../rtl/metro_loader.sv sdram_model.sv \
    ../modules/ikaopll/IKAOPLL.v ../modules/ikaopll/IKAOPLL_modules/*.v ../modules/jt51/hdl/*.v \
    ../modules/jt6295/hdl/jt6295.v ../modules/jt6295/hdl/jt6295_adpcm.v ../modules/jt6295/hdl/jt6295_timing.v ../modules/jt6295/hdl/jt6295_acc.v \
    ../modules/jt6295/hdl/jt6295_ctrl.v ../modules/jt6295/hdl/jt6295_rom.v ../modules/jt6295/hdl/jt6295_serial.v ../modules/jt6295/hdl/jt6295_sh_rst.v \
    tb_metro_sound_top.sv tb_metro_sound.cpp > "$B/build.log" 2>&1 \
    || { grep -E "%Error|error:" "$B/build.log" | head -40; exit 1; }
fi
"$B/obj/Vtb_metro_sound_top" +IMAGE="$IMAGE" +EVENTS="$EV" +SECONDS="$SECS" +WAV="$WAV"
