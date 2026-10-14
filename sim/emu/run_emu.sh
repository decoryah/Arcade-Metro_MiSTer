#!/bin/bash
# End-to-end bench of the MiSTer top level (Metro.sv): hps_io and the PLL stubbed, everything else real.  In WSL:
#   sim/emu/run_emu.sh <image.rom> [frames after load, default 5] [out prefix]
# Environment: FAST=1 (the load as the MRA's address= attribute makes Main_MiSTer do it), STRIDE=<clocks a byte> (streamed), SCALE=0..4 (OSD Scale: Normal, V-Integer,
# HV-Integer, Narrower HV-Integer, HV-Integer+), AR=0..3 (Aspect ratio: Original, Full Screen, ARC1, ARC2), HW / HH (the scaler's size, default 1920 x 1080), NOROT=1
# (Rotate screen Off), EXPECT_ROT=1 (the game is a vertical one shown rotated: Scale must stay Normal), SDRDUMP=<file> (the SDRAM chip's first image-length bytes),
# F64=1 (the 64 MB module: Mahjong Gakuensai and family C), DVLOG=1, NOBUILD=1, JOBS
set -e
cd "$(dirname "$0")"
IMG="$1"; FR="${2:-5}"; PRE="${3:-emu}"
[ -f "$IMG" ] || { echo "usage: $0 <image> [frames] [prefix]" >&2; exit 2; }
case "$IMG" in /*) ;; *) IMG="$PWD/$IMG" ;; esac
. "$HOME/tools/oss-cad-suite/environment"
S=../../sys
OBJ=${OBJ_DIR:-$HOME/build_metro/emu${F64:+64}}
mkdir -p $OBJ
if [ -z "$NOBUILD" ]; then
# The framework's video_mixer.sv declares R_in/G_in/B_in inside an unnamed generate block and uses them outside it (Quartus accepts it; Verilator does not): a copy with the
# three wires declared at module level (arcade_video with DW=24); sys/ is untouched
python3 - $S/video_mixer.sv $OBJ/video_mixer_sim.sv <<'PY'
import re, sys
s = open(sys.argv[1]).read()
m = re.search(r'generate\s+if\(GAMMA && HALF_DEPTH\) begin.*?end else begin(.*?)end\s+endgenerate', s, re.S)
assert m, 'video_mixer.sv: the R_in generate block was not found'
open(sys.argv[2], 'w').write(s[:m.start()] + m.group(1).strip() + chr(10) + s[m.end():])
PY
# the project's own file list (files.qip), minus the Quartus-only entries
FILES=$(python3 - <<'PY'
import re
out = []
for l in open('../../files.qip'):
    m = re.match(r'set_global_assignment -name (SYSTEMVERILOG_FILE|VERILOG_FILE) (\S+)', l)
    if m and not m.group(2).startswith('['): out.append('../../' + m.group(2))
import glob
out += sorted(glob.glob('../../modules/jt10/*.v'))
print(' '.join(out))
PY
)
verilator --cc --exe --build -j ${JOBS:-8} -O2 -Wno-fatal -Wno-WIDTH -Wno-DECLFILENAME -Wno-UNOPTFLAT -Wno-PINMISSING -Wno-PINCONNECTEMPTY \
    -Wno-IMPLICIT -Wno-TIMESCALEMOD -Wno-CASEINCOMPLETE -Wno-MULTIDRIVEN -Wno-LATCH -Wno-UNSIGNED -Wno-CMPCONST -Wno-PROCASSWIRE -Wno-INITIALDLY -Wno-BLKANDNBLK \
    -Wno-UNDRIVEN -Wno-SYNCASYNCNET -Wno-VARHIDDEN -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND --no-assert-case --x-assign fast --x-initial fast \
    +1364-2005ext+v -I. -I../.. -I../../rtl -I../../modules/ikaopll -I../../modules/jt6295/hdl -I../../modules/jt51/hdl -I../../modules/jt10 \
    -DSIM -DMISTER_FB=1 -DD_BUILD -DNO_YMF ${F64:+-DF64} ${DVLOG:+-DD_VLOG} ${YMF:+-UNO_YMF} \
    --top-module tb_emu_top --prefix Vtb_emu_top -Mdir $OBJ \
    $FILES $S/arcade_video.v $OBJ/video_mixer_sim.sv $S/scandoubler.v $S/scanlines.v $S/gamma_corr.sv $S/hq2x.sv $S/video_freezer.sv $S/video_freak.sv $S/math.sv \
    hps_io_stub.sv pll_stub.sv sync_fix.sv ../sdram_model.sv ../ddr_model.sv tb_emu_top.sv tb_emu.cpp \
    > $OBJ/build.log 2>&1 || { grep -E "%Error" $OBJ/build.log | head -30; tail -5 $OBJ/build.log; exit 1; }
fi
# the core reads its microcode tables with $readmemh relative to the project directory (as Quartus does)
cd ../..
LEN=$(stat -c %s "$IMG")
FRZ=${FR}
SDRDUMP=${SDRDUMP:+"+SDRDUMP=$SDRDUMP"}
stdbuf -oL $OBJ/Vtb_emu_top "$IMG" "$FRZ" "$PRE" ${SDRDUMP} "+SDRLEN=$LEN"
