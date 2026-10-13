#!/bin/bash
# System bench (tb_metro_sys_top.sv + tb_metro_sys.cpp), run inside WSL:
#   mister/sim/run_sys.sh <maincpu.bin> <gfx.bin> <gfx bytes> <frames> <dump frames, comma list> <out prefix> [coin frame] [start frame]
# Writes <out prefix>.<frame>.hex/.regs/.ppm.  Builds once in $HOME/build_metro/sys (BUILD_DIR overrides it; NOBUILD=1 reuses the build).
# Env:  WINMAME=1  show chip lines 0..223 like MAME instead of the CRTC window
#       DSW0=FFBF  the DIP word (hex; default FFFF = MAME's defaults, FFBF = Flip Screen on)
#       FLIPFORCE=1  the OSD's forced flip (flip_force input)
#       CRTON=1 CRTH=n CRTP=n CRTV=n  CRT Adjust of the final stream (with VOUT=1 the line / sync / dot figures of the adjusted stream are printed)
#       PPMONLY=1  write only the frame images (.ppm), not the VDP memory/register dumps (long frame-by-frame runs)
#       SDR=1      the real memory path: the MRA image in $IMAGE (tools/metro_rom.py build --out) is streamed through metro_loader into
#                  metro_sdram + a behavioural SDRAM model; <maincpu.bin> and <gfx.bin> are not used then (pass any existing file twice)
#                  RDLATE=1  with SDR: capture SDRAM read data one cycle later (the OSD option of the core)
set -e
cd "$(dirname "$0")"
PROG="$1"; GFX="$2"; GFXN="$3"; FRAMES="$4"; DUMPS="$5"; OUT="$6"; COIN="${7:--1}"; START="${8:--1}"
[ -f "$PROG" ] && [ -f "$GFX" ] && [ -n "$OUT" ] || { echo "usage: $0 <maincpu.bin> <gfx.bin> <gfxbytes> <frames> <dumps> <out-prefix> [coin] [start]" >&2; exit 2; }
[ -z "$SDR" ] || [ -f "$IMAGE" ] || { echo "SDR=1 needs IMAGE=<the MRA image>" >&2; exit 2; }
. "$HOME/tools/oss-cad-suite/environment"
B="${BUILD_DIR:-$HOME/build_metro/${SDR:+sdr}${SDR:-sys}}"; mkdir -p "$B"
EXTRA=""
[ -z "$SDR" ] || EXTRA="-DSDR ../rtl/metro_sdram.sv ../rtl/metro_loader.sv ../rtl/metro_romif.sv sdram_model.sv"
# SOUND=1 (with SDR): the real sound module (YM2413 + OKI) in family D's direct mode, its output written to +AUDFILE
[ -z "$SOUNDF" ] || EXTRA="$EXTRA -DTB_SOUND_F -I../rtl ../rtl/metro_sndf.sv ../rtl/metro_ympcm.sv ../rtl/metro_mrom_arb.sv ../modules/jt10/*.v ../modules/jt49/*.v ../modules/cpu-tv80/*.v"
[ -z "$SOUND" ] || EXTRA="$EXTRA -DTB_SOUND -I../rtl -I../modules/ikaopll -I../modules/jt6295/hdl -I../modules/jt51/hdl ../rtl/upd78c10.sv ../rtl/metro_sound.sv ../modules/ikaopll/IKAOPLL.v ../modules/ikaopll/IKAOPLL_modules/*.v ../modules/jt51/hdl/*.v ../modules/jt6295/hdl/jt6295.v ../modules/jt6295/hdl/jt6295_adpcm.v ../modules/jt6295/hdl/jt6295_timing.v ../modules/jt6295/hdl/jt6295_acc.v ../modules/jt6295/hdl/jt6295_ctrl.v ../modules/jt6295/hdl/jt6295_rom.v ../modules/jt6295/hdl/jt6295_serial.v ../modules/jt6295/hdl/jt6295_sh_rst.v"
if [ -z "$NOBUILD" ]; then
verilator --cc --exe --build -j 8 -O3 --x-assign fast --x-initial fast -DSIM ${F64:+-DF64} ${DBUILD:+-DD_BUILD} ${VLOG:+-DF_VLOG} ${VLOG_CHECK:+-DVLOG_CHECK} ${ROZ_PROBE:+-DROZ_PROBE} ${NO_SPR_HOLD:+-DNO_SPR_HOLD} -CFLAGS "-O3 -march=native" -MAKEFLAGS "OPT_FAST=-O3 OPT_SLOW=-O1" \
    -Wall -Wno-fatal -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNOPTFLAT -Wno-PINCONNECTEMPTY -Wno-WIDTH -Wno-CASEINCOMPLETE \
    -Wno-TIMESCALEMOD -Wno-PINMISSING -Wno-INITIALDLY -Wno-UNDRIVEN -Wno-SYNCASYNCNET -Wno-MULTIDRIVEN -Wno-LATCH -Wno-BLKSEQ \
    -Wno-UNSIGNED -Wno-CMPCONST -Wno-VARHIDDEN -Wno-BLKANDNBLK --no-assert-case -Wno-PROCASSINIT -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND \
    --top-module tb_metro_sys_top -Mdir "$B/obj" $EXTRA \
    ../modules/cpu-fx68k/fx68kAlu.sv ../modules/cpu-fx68k/uaddrPla.sv ../modules/cpu-fx68k/fx68k.sv \
    ../rtl/metro_dpram.sv ../rtl/metro_tdpram.sv ../rtl/metro_blitter.sv ../rtl/metro_render.sv ../rtl/metro_vdp.sv ../rtl/metro_roz.sv \
    ../rtl/ymf278b_pkg.sv ../rtl/ymf278b.sv ../rtl/metro_ymf.sv ../rtl/metro_cen.sv ../rtl/metro_vout.sv ../rtl/metro_crtadj.sv ../modules/crt_adjust/crt_adjust.sv ../rtl/metro_eeprom.sv ../rtl/metro_es8712.sv ../rtl/metro_okimux.sv ../rtl/metro_main.sv tb_metro_sys_top.sv tb_metro_sys.cpp > "$B/build.log" 2>&1 \
    || { grep -E "%Error|error:" "$B/build.log" | head -40; exit 1; }
fi
cp ../microrom.mem ../nanorom.mem "$B/"
mkdir -p "$(dirname "$OUT")"
cd "$B"
[ -z "$RUNBIN" ] || cp obj/Vtb_metro_sys_top obj/$RUNBIN
./obj/${RUNBIN:-Vtb_metro_sys_top} +PROG="$PROG" +GFX="$GFX" +GFXSIZE="$GFXN" +FRAMES="$FRAMES" +DUMPS="$DUMPS" +DUMPPFX="$OUT" +COIN="$COIN" +START="$START" \
    ${WINMAME:+"+WINMAME=1"} ${PPMONLY:+"+PPMONLY=1"} ${FLIPFORCE:+"+FLIPFORCE=1"} ${SDR:+"+IMAGE=$IMAGE"} ${RDLATE:+"+RDLATE=1"} ${DSW0:+"+DSW0=$DSW0"} ${DSW1:+"+DSW1=$DSW1"} ${SNDLOG:+"+SNDLOG"} ${HUDST:+"+HUDST"} ${VOUT:+"+VOUT"} ${FASTCPU:+"+FASTCPU"} ${LH0:+"+LH0=$LH0"} ${KICK0:+"+KICK0=$KICK0"} ${BLIT0:+"+BLIT0=$BLIT0"} ${BLIT1:+"+BLIT1=$BLIT1"} ${MIDF:+"+MIDF=$MIDF"} ${MIDL:+"+MIDL=$MIDL"} ${MIDN:+"+MIDN=$MIDN"} ${KICK1:+"+KICK1=$KICK1"} ${LH1:+"+LH1=$LH1"} ${VNARROW:+"+VNARROW"} ${CRTON:+"+CRTON=$CRTON"} ${CRTH:+"+CRTH=$CRTH"} ${CRTP:+"+CRTP=$CRTP"} ${CRTV:+"+CRTV=$CRTV"} ${AUDFILE:+"+AUDFILE=$AUDFILE"} ${YMFAUD:+"+YMFAUD=$YMFAUD"} ${YMFLOG:+"+YMFLOG=$YMFLOG"} ${VDPWLOG:+"+VDPWLOG=$VDPWLOG"} ${YMFROM:+"+YMFROM=$YMFROM"} ${YMFCHK:+"+YMFCHK=$YMFCHK"} ${SDRCHK:+"+SDRCHK=$SDRCHK"} ${ASTRACE:+"+ASTRACE=$ASTRACE"} ${ASFRAME:+"+ASFRAME=$ASFRAME"}
