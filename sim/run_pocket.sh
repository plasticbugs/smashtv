#!/bin/sh
# The whole core on the Pocket's real memory glue (CLAUDE.md step 7): the real
# smashtv_mem, the real SDRAM controller and SRAM port, behavioural chips, and
# the image pushed in at the loader's rate.  Run this BEFORE THE FIRST FLASH
# and after any change to target/pocket/smashtv_mem.sv or to who asks it for
# what.  Slow - a frame is 1.75 million clocks.
#
#   sim/run_pocket.sh <frames> [every] [-dlgap N]     pictures, the command log
#                                                     and rtl.wav land in artifacts/pocket/
set -e
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/.." && pwd); cd "$here"
rom="$root/.build/smashtv.rom"
[ -f "$rom" ] || { mkdir -p "$root/.build"; python3 "$root/tools/mra_build.py" "$root/smashtv.mra" "$root/.mame/roms/smashtv" "$rom" >/dev/null; }
. "$here/waivers.sh"
verilator --cc --exe --build -j "${JOBS:-8}" -O3 \
    -Wall -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-PINCONNECTEMPTY \
    -Wno-TIMESCALEMOD -Wno-BLKSEQ -Wno-MULTIDRIVEN -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND -Wno-SYNCASYNCNET \
    "$WAIVERS" --top-module tb_pocket_top -Mdir obj_pocket \
    ../rtl/smashtv_core.sv ../rtl/clk_enables.sv ../rtl/stv_main.sv ../rtl/tms34010.sv \
    ../rtl/stv_video.sv ../rtl/stv_vram.sv ../rtl/stv_blit.sv \
    ../rtl/stv_sound.sv ../rtl/pia6821.sv ../rtl/hc55516.sv \
    ../modules/cpu-mc6809/*.v ../modules/sound-jt51/*.v \
    ../target/pocket/smashtv_mem.sv ../target/pocket/rom_cache.sv ../target/pocket/sdram_ctrl.sv ../target/pocket/sram_port.sv \
    sdram_model.sv sram_model.sv tb_pocket_top.sv tb_pocket.cpp > obj_pocket.log 2>&1 \
    || { tail -40 obj_pocket.log; exit 1; }
out="$root/artifacts/pocket"; mkdir -p "$out"; rm -f "$out"/rtl_*.rgb
./obj_pocket/Vtb_pocket_top "$rom" "$out" "${1:-100}" "${2:-50}" $3 $4
python3 - "$out" <<'PY'
import sys, os, re
sys.path.insert(0, os.path.join(os.path.dirname(sys.argv[1]), '..', 'tools'))
import pngio
d = sys.argv[1]
for f in sorted(os.listdir(d)):
    m = re.match(r'rtl_(\d+)_(\d+)x(\d+)\.rgb$', f)
    if not m: continue
    w, h = int(m.group(2)), int(m.group(3))
    pngio.write(os.path.join(d, f'rtl_{m.group(1)}.png'), w, h, open(os.path.join(d, f), 'rb').read())
    os.remove(os.path.join(d, f))
PY
ls "$out" | tail -5
