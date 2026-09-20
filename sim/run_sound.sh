#!/bin/sh
# The sound board against MAME (CLAUDE.md step 8).
#   sim/run_sound.sh [from-seconds] [to-seconds]      default 19 60
# Captures MAME's command stream and a WAV if they are not there yet
# (tools/snd_trace.lua), replays the commands into rtl/stv_sound.sv, and
# compares the two recordings second by second, band by band.  The WAV lands
# in artifacts/audio/ so it can be listened to (rtl_*.wav is what the core's
# 48 kHz hand-over makes of it, rtl_*_avg.wav the same without the aliasing).
set -e
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/.." && pwd); cd "$here"
from=${1:-19}; to=${2:-60}
rom="$root/.build/smashtv.rom"
[ -f "$rom" ] || { mkdir -p "$root/.build"; python3 "$root/tools/mra_build.py" "$root/smashtv.mra" "$root/.mame/roms/smashtv" "$rom" >/dev/null; }
ref="$root/ref/sound"
if [ ! -f "$ref/snd_cmd.txt" ] || [ ! -f "$ref/mame.wav" ]; then
    mkdir -p "$ref"
    TRACE_DIR="$ref" "$root/tools/mame.sh" -seconds_to_run 60 -wavwrite "$ref/mame.wav" \
        -autoboot_script "$root/tools/snd_trace.lua" > "$ref/mame.log" 2>&1
    grep -q '^frames 32[0-9][0-9]' "$ref/snd_trace.txt" || { echo "MAME run was cut short; run again"; exit 1; }
fi
. "$here/waivers.sh"
verilator --cc --exe --build -j "${JOBS:-8}" -O3 \
    -Wall -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-PINCONNECTEMPTY \
    -Wno-TIMESCALEMOD "$WAIVERS" \
    --top-module tb_sound_top -Mdir obj_sound \
    ../rtl/stv_sound.sv ../rtl/pia6821.sv ../rtl/hc55516.sv \
    ../modules/cpu-mc6809/*.v ../modules/sound-jt51/*.v \
    tb_sound_top.sv tb_sound.cpp > obj_sound.log 2>&1 || { tail -40 obj_sound.log; exit 1; }
out="$root/artifacts/audio"; mkdir -p "$out"
./obj_sound/Vtb_sound_top "$rom" "$ref/snd_cmd.txt" "$out/rtl_${from}_${to}.wav" "$from" "$to"
python3 "$root/tools/compare_bands.py" "$ref/mame.wav" "$out/rtl_${from}_${to}.wav" "$from"
echo; echo "and with the 2000 clocks of each sample averaged instead of point-sampled:"
python3 "$root/tools/compare_bands.py" "$ref/mame.wav" "$out/rtl_${from}_${to}_avg.wav" "$from" | tail -8
