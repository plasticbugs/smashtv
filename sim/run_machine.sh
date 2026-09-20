#!/bin/sh
# The whole main board from reset on ideal memories (CLAUDE.md step 6).
#   sim/run_machine.sh <frames> [every]      pictures land in artifacts/machine/ (or $OUT)
#   DSW=0x7fff ... the test switch on;  SVC=1500 ... the service button at that frame
set -e
here=$(cd "$(dirname "$0")" && pwd); root=$(cd "$here/.." && pwd); cd "$here"
rom="$root/.build/smashtv.rom"
[ -f "$rom" ] || { mkdir -p "$root/.build"; python3 "$root/tools/mra_build.py" "$root/smashtv.mra" "$root/.mame/roms/smashtv" "$rom" >/dev/null; }
verilator --cc --exe --build -j "${JOBS:-8}" -O3 \
    -Wall -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-PINCONNECTEMPTY \
    -Wno-TIMESCALEMOD -Wno-BLKSEQ -Wno-MULTIDRIVEN -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND \
    tb_public.vlt --top-module tb_machine_top -Mdir obj_machine \
    ../rtl/stv_main.sv ../rtl/tms34010.sv ../rtl/stv_video.sv ../rtl/stv_vram.sv ../rtl/stv_blit.sv \
    tb_machine_top.sv tb_machine.cpp > obj_machine.log 2>&1 || { tail -40 obj_machine.log; exit 1; }
out="${OUT:-$root/artifacts/machine}"; mkdir -p "$out"; rm -f "$out"/rtl_*.rgb
./obj_machine/Vtb_machine_top "$rom" "$out" "${1:-100}" "${2:-50}"
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
ls "$out"
