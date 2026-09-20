#!/bin/sh
# The frozen-state video gate: the real rtl/stv_video.sv, rtl/stv_vram.sv and
# rtl/stv_blit.sv loaded with a state captured from MAME, fed the same trace,
# and held to tools/render_model.py index for index.
#
#   sim/run_video.sh [window ...]        default: every window in ref/states
#
# Zero differing indices is the only pass.  Run it for every change to RTL
# that draws pixels, including pure refactors (CLAUDE.md).
set -e
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
cd "$here"
verilator --version >/dev/null 2>&1 || { echo "verilator not found" >&2; exit 2; }

rom="$root/.build/smashtv.rom"
if [ ! -f "$rom" ]; then
    mkdir -p "$root/.build"
    python3 "$root/tools/mra_build.py" "$root/smashtv.mra" \
        "$root/.mame/roms/smashtv" "$rom" >/dev/null
fi

verilator --cc --exe --build -j "${JOBS:-8}" -O2 \
    -Wall -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM \
    -Wno-PINCONNECTEMPTY -Wno-TIMESCALEMOD \
    -Wno-BLKSEQ -Wno-MULTIDRIVEN -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND \
    -Wno-SYNCASYNCNET \
    --top-module tb_video_top -Mdir obj_video \
    ../rtl/stv_video.sv ../rtl/stv_vram.sv ../rtl/stv_blit.sv \
    tb_video_top.sv tb_video.cpp > obj_video.log 2>&1 \
    || { tail -40 obj_video.log; exit 1; }

windows=$*
[ -n "$windows" ] || windows=$(cd "$root/ref/states" && ls -d */ 2>/dev/null | tr -d /)
[ -n "$windows" ] || { echo "no captures; run tools/dump_states.sh" >&2; exit 2; }

fail=0
for w in $windows; do
    d="$root/ref/states/$w"
    [ -f "$d/trace.bin" ] || { echo "== $w: no trace, skipped"; continue; }
    idx="$root/.build/idx/$w"
    python3 "$root/tools/render_model.py" "$d" "$rom" --idx "$idx" >/dev/null
    echo "== $w"
    ./obj_video/Vtb_video_top "$d" "$rom" "$idx" || fail=$((fail + 1))
done
if [ "$fail" != 0 ]; then
    echo "FAIL  $fail window(s) differ"
    exit 1
fi
echo "PASS  the video RTL matches the reference renderer on every window"
