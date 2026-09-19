#!/bin/sh
# Copy a vendored module from a sibling core into modules/, with its licence.
#
#   tools/vendor.sh <sibling-repo> <module>
#   tools/vendor.sh ../masterw cpu-fx68k
#
# Siblings that are known-good on hardware, and what they carry:
#   ../masterw    cpu-fx68k (68000)  cpu-tv80 (Z80)  sound-jt03 (YM2203)  sound-jt49 (AY/SSG)
#   ../cadash     cpu-fx68k  cpu-tv80  jt51 (YM2151)
# Record the module, its upstream, where it came via and its licence in
# modules/VENDOR.md, then run tools/gen_qip.sh.  A block proven in another
# core is proven on that core's signal: METHODOLOGY section 5.14.
set -e
[ -d "$1/modules/$2" ] || { echo "usage: $0 <sibling-repo> <module>   (no $1/modules/$2)" >&2; exit 2; }
cd "$(dirname "$0")/.."
mkdir -p modules
cp -R "$1/modules/$2" modules/
echo "copied modules/$2 -- now add it to modules/VENDOR.md and run tools/gen_qip.sh"
grep -n "$2" "$1/modules/VENDOR.md" 2>/dev/null || true
