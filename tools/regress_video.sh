#!/bin/sh
# Hold the reference renderer to MAME on every captured window.
#
#   tools/regress_video.sh [states-dir] [image.rom]
#
# Zero differing pixels is the only pass.  Run it after any change to
# tools/render_model.py, and after any change to the .mra, since the renderer
# decodes the graphics straight out of the image.
#
# Pictures and diffs land in artifacts/video/ where they can be looked at.
set -e
root=$(cd "$(dirname "$0")/.." && pwd)
dir=${1:-$root/ref/states}
rom=${2:-$root/.build/smashtv.rom}

[ -d "$dir" ] || { echo "no captures in $dir; run tools/dump_states.sh" >&2; exit 2; }
if [ ! -f "$rom" ]; then
    mkdir -p "$(dirname "$rom")"
    python3 "$root/tools/mra_build.py" "$root/smashtv.mra" "$root/.mame/roms/smashtv" "$rom" >/dev/null
fi

fail=0
for w in "$dir"/*/; do
    name=$(basename "$w")
    [ -f "$w/trace.bin" ] || continue
    echo "== $name"
    if python3 "$root/tools/render_model.py" "$w" "$rom" -o "$root/artifacts/video/$name"; then
        :
    else
        fail=$((fail + 1))
    fi
done
if [ "$fail" != 0 ]; then
    echo "FAIL  $fail window(s) differ from MAME"
    exit 1
fi
echo "PASS  the reference renderer is pixel-identical to MAME on every window"
