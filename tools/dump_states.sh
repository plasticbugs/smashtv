#!/bin/sh
# Capture the reference video states and traces from MAME.
#
#   tools/dump_states.sh [dir]        default ref/states
#
# One MAME run per window.  Each writes a frozen frame buffer, a trace of
# every write that can change the picture for the frames that follow, and
# MAME's own picture for each of them; tools/render_model.py replays the trace
# and must match MAME on every pixel of every frame.
#
# MAME has been seen to end a headless run early and silently, so each window
# is retried until its run.txt says "complete".  The runs are deterministic
# given the romset, so the captures are reproducible and are not committed.
set -e
root=$(cd "$(dirname "$0")/.." && pwd)
dir=${1:-$root/ref/states}

# name:from:count:seconds -- the windows, chosen to span what the machine does.
# The frames were picked from a measurement, not guessed: the power-up RAM
# test sweeps the whole frame buffer in bursts of nine frames with gaps
# between them (3-11, 24-32, 45-53, ... 338-342), so `ramtest` sits on one
# burst and is the only window that exercises the CPU's own frame-buffer
# writes at volume; `cputext` and `clear` catch the two smaller bursts the
# CPU does later.
WINDOWS="
ramtest:106:12:5
cputext:360:8:9
romcheck:600:8:14
clear:1045:8:21
title:1150:8:25
attract:1500:8:32
play:1900:8:39
playbusy:2300:8:47
"

mkdir -p "$dir"
for w in $WINDOWS; do
    name=$(echo "$w" | cut -d: -f1)
    from=$(echo "$w" | cut -d: -f2)
    count=$(echo "$w" | cut -d: -f3)
    secs=$(echo "$w" | cut -d: -f4)
    out="$dir/$name"
    ok=0
    for try in 1 2 3 4 5; do
        rm -rf "$out"; mkdir -p "$out"
        FROM="$from" COUNT="$count" DUMP_DIR="$out" \
            "$root/tools/mame.sh" -seconds_to_run "$secs" \
            -autoboot_script "$root/tools/dump_state.lua" >/dev/null 2>&1 || true
        if [ -f "$out/run.txt" ] && grep -q '^complete' "$out/run.txt"; then
            ok=1; break
        fi
        echo "  $name: attempt $try incomplete, retrying" >&2
    done
    [ "$ok" = 1 ] || { echo "error: MAME would not complete the $name window" >&2; exit 1; }
    echo "$name: frames $from..$((from + count)), $(wc -c < "$out/trace.bin") bytes of trace"
done
echo "captures in $dir"
