#!/bin/sh
# Capture the TMS34010's bus and register traces from MAME for sim/run_cpu.sh.
# Two runs, because the debugger's disassembler would otherwise show up in the
# bus trace (see tools/cpu_trace.lua).
#
#   tools/cpu_trace.sh [dir] [frames]
set -e
root=$(cd "$(dirname "$0")/.." && pwd)
dir=${1:-$root/ref/cputrace}
frames=${2:-40}
secs=$(( frames / 50 + 2 ))
mkdir -p "$dir"
rm -f "$dir/trace_bus.bin" "$dir/trace_reg.txt"
TRACE_DIR="$dir" TRACE_N=$(( frames * 120000 )) "$root/tools/mame.sh" \
    -autoboot_script "$root/tools/bus_trace.lua" -seconds_to_run "$secs" >/dev/null 2>&1 || true
TRACE_DIR="$dir" TRACE_FRAMES="$frames" "$root/tools/mame.sh" -debug -debugger none \
    -autoboot_script "$root/tools/cpu_trace.lua" -seconds_to_run "$secs" >/dev/null 2>&1 || true
ls -la "$dir" | tail -3
