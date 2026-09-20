#!/bin/sh
# The CPU gate: rtl/tms34010.sv against MAME's own register and bus traces.
#
#   sim/run_cpu.sh [trace-dir] [-n instructions]
#
# The traces come from tools/cpu_trace.sh (default ref/cputrace).
set -e
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
cd "$here"
dir="$root/ref/cputrace"
case "$1" in -*|"") ;; *) dir=$1; shift;; esac
rom="$root/.build/smashtv.rom"
[ -f "$rom" ] || { mkdir -p "$root/.build"; python3 "$root/tools/mra_build.py" \
    "$root/smashtv.mra" "$root/.mame/roms/smashtv" "$rom" >/dev/null; }
[ -f "$dir/trace_bus.bin" ] || { echo "no traces in $dir; run tools/cpu_trace.sh" >&2; exit 2; }
verilator --cc --exe --build -j "${JOBS:-8}" -O2 \
    -Wall -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM \
    -Wno-PINCONNECTEMPTY -Wno-TIMESCALEMOD \
    -Wno-BLKSEQ -Wno-MULTIDRIVEN -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND \
    --top-module tb_cpu_top -Mdir obj_cpu \
    ../rtl/tms34010.sv tb_cpu_top.sv tb_cpu.cpp > obj_cpu.log 2>&1 \
    || { tail -40 obj_cpu.log; exit 1; }
exec ./obj_cpu/Vtb_cpu_top "$dir" "$rom" "$@"
