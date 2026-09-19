#!/bin/sh
# Build a shadow romset in .mame/roms: symlinks to the user's real ROMs, plus
# placeholders for files MAME insists on but no emulation reads (PAL and PLD
# dumps, usually) and which a romset often does not carry.  The user's own
# files are never touched or polluted.
#
#   tools/shadow_romset.sh [romset-dir]
#
# The user's romset carries the pre-0.240 short names (la1.u95, u89-la8);
# MAME 0.288 wants the long label names.  Every pair below was matched by
# CRC32 against ROM_START(smashtv) in ref/mame/mame/midway/midyunit.cpp, not
# by guessing from the number in the name.
NAME_MAP="
sl2.u4:sl2_smash_tv_sound_rom_u4.u4
sl2.u19:sl2_smash_tv_sound_rom_u19.u19
sl2.u20:sl2_smash_tv_sound_rom_u20.u20
u105-la8:la8_smash_tv_game_rom_u105.u105
u89-la8:la8_smash_tv_game_rom_u89.u89
la1.u111:la1_smash_tv_game_rom_u111.u111
la1.u112:la1_smash_tv_game_rom_u112.u112
la1.u113:la1_smash_tv_game_rom_u113.u113
la1.u95:la1_smash_tv_game_rom_u95.u95
la1.u96:la1_smash_tv_game_rom_u96.u96
la1.u97:la1_smash_tv_game_rom_u97.u97
la1.u106:la1_smash_tv_game_rom_u106.u106
la1.u107:la1_smash_tv_game_rom_u107.u107
la1.u108:la1_smash_tv_game_rom_u108.u108
"
# The four EP600 PLDs.  Nothing in MAME reads the "plds" region; MAME only
# refuses to start if the files are absent, so a zero-filled stand-in of the
# right length is enough.  It reports a bad checksum for them, by design.
PLACEHOLDERS="a_5346_3044_1.u8:815 a_5346_3044_5.u52:815 a_5346_3044_6.u53:815 a_5346_3044_7.u65:815"
set -e
root=$(cd "$(dirname "$0")/.." && pwd)
src=${1:-$root/smashtv}
dst=$root/.mame/roms/smashtv
[ -d "$src" ] || { echo "no romset directory at $src" >&2; exit 2; }
mkdir -p "$dst" "$root/.mame/cfg" "$root/.mame/nvram"
for pair in $NAME_MAP; do
    from=${pair%%:*}; to=${pair##*:}
    [ -e "$src/$from" ] || { echo "missing $src/$from" >&2; exit 2; }
    ln -sf "$src/$from" "$dst/$to"
done
for spec in $PLACEHOLDERS; do
    p=${spec%%:*}; n=${spec##*:}
    [ -e "$src/$p" ] && ln -sf "$src/$p" "$dst/$p" \
                     || python3 -c "open('$dst/$p','wb').write(bytes($n))"
done
echo "shadow romset ready: $dst"
