#!/bin/sh
# The CPU gate: rtl/tms34010.sv against MAME's own register and bus traces.
#
#   sim/run_cpu.sh [trace-dir] [-n instructions]
#   sim/run_cpu.sh -live <seconds> [-n instructions]
#
# The traces come from tools/cpu_trace.sh (default ref/cputrace).  With -live
# nothing is stored: two MAME runs write into named pipes and the bench reads
# them as they come, which is how to compare thousands of frames -- the
# register trace alone is 17 MB a frame.
set -e
here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/.." && pwd)
cd "$here"
dir="$root/ref/cputrace"
live=
if [ "$1" = "-live" ]; then live=$2; shift 2; fi
case "$1" in -*|"") ;; *) dir=$1; shift;; esac
rom="$root/.build/smashtv.rom"
[ -f "$rom" ] || { mkdir -p "$root/.build"; python3 "$root/tools/mra_build.py" \
    "$root/smashtv.mra" "$root/.mame/roms/smashtv" "$rom" >/dev/null; }
[ -n "$live" ] || [ -f "$dir/trace_bus.bin" ] || { echo "no traces in $dir; run tools/cpu_trace.sh" >&2; exit 2; }
verilator --cc --exe --build -j "${JOBS:-8}" -O2 \
    -Wall -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM \
    -Wno-PINCONNECTEMPTY -Wno-TIMESCALEMOD \
    -Wno-BLKSEQ -Wno-MULTIDRIVEN -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND \
    tb_public.vlt --top-module tb_cpu_top -Mdir obj_cpu \
    ../rtl/tms34010.sv tb_cpu_top.sv tb_cpu.cpp > obj_cpu.log 2>&1 \
    || { tail -40 obj_cpu.log; exit 1; }
if [ -z "$live" ]; then
    exec ./obj_cpu/Vtb_cpu_top "$dir" "$rom" "$@"
fi

dir=$(mktemp -d "${TMPDIR:-/tmp}/stvcpu.XXXXXX")
mkfifo "$dir/trace_bus.bin" "$dir/trace_reg.txt"
TRACE_DIR="$dir" TRACE_N=2000000000 "$root/tools/mame.sh" \
    -autoboot_script "$root/tools/bus_trace.lua" -seconds_to_run "$live" >/dev/null 2>&1 &
p1=$!
CYCLES=1 TRACE_DIR="$dir" TRACE_FRAMES=100000000 "$root/tools/mame.sh" -debug -debugger none \
    -autoboot_script "$root/tools/cpu_trace.lua" -seconds_to_run "$live" >/dev/null 2>&1 &
p2=$!
rc=0
./obj_cpu/Vtb_cpu_top "$dir" "$rom" "$@" || rc=$?
kill $p1 $p2 2>/dev/null || true
wait $p1 $p2 2>/dev/null || true
rm -rf "$dir"
exit $rc
