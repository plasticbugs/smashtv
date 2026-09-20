#!/bin/sh
# Run MAME on smashtv against the shadow romset, headless and deterministic.
# Always pass -seconds_to_run: a Lua script that ends the run with
# machine:exit() has proved unreliable, while -seconds_to_run plus an
# add_machine_stop_notifier that writes the results is repeatable to the frame.
#
# Nothing here may touch the display.  `-video none` stops MAME rendering to a
# window but does NOT stop it creating one, and MAME's own defaults are
# fullscreen (window 0, maximize 1) -- which on macOS makes the desktop jump
# to another Space every time a probe runs, several times a minute during a
# capture session.  Three measures, because they fail independently:
# SDL_VIDEODRIVER=dummy keeps SDL from opening the display at all (it is read
# before MAME parses anything), -videodriver dummy says the same through MAME,
# and -window -nomaximize means that if a window is created regardless it is a
# small one that steals no Space.  Snapshots are byte-identical to a normal
# run, checked on the Master of Weapon core where this was found.
root=$(cd "$(dirname "$0")/.." && pwd)
# Every run starts from the same machine: an EMPTY battery-backed RAM, in a
# directory of its own that is thrown away afterwards.  MAME writes the CMOS
# back when it exits, so with a shared nvram directory each run began where
# the last one ended - the coin audit one higher, for a start - and two
# captures that were meant to be of the same run were not (found by
# sim/run_cpu.sh: the register trace read 0x25 where the bus trace read 0x24).
# Empty is also what the benches' RAM and a Pocket's first boot are: the game
# says FAILURE IN CMOS RAM, restores its defaults and carries on.
# NVRAM=<dir> uses (and updates) a directory of your choosing instead.
if [ -n "$NVRAM" ]; then nv=$NVRAM; keep=1
else mkdir -p "$root/.mame/tmp"; nv=$(mktemp -d "$root/.mame/tmp/nv.XXXXXX"); keep=
fi
SDL_VIDEODRIVER=dummy \
mame smashtv -rompath "$root/.mame/roms" \
    -video none -videodriver dummy -window -nomaximize \
    -sound none -nothrottle -skip_gameinfo \
    -cfg_directory "$root/.mame/cfg" -nvram_directory "$nv" \
    -snapshot_directory "$root/.mame/snap" \
    "$@"
rc=$?
[ -n "$keep" ] || rm -rf "$nv"
exit $rc
