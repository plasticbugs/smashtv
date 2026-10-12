# Smash T.V. — Analogue Pocket core (openFPGA)

**Smash T.V.**, Williams 1990, on **Midway Y-Unit** hardware: a TMS34010
graphics processor driving a 512×512 frame buffer through a custom Williams
DMA blitter, with a Williams CVSD sound board (MC6809E, YM2151, HC-55516,
MC1408) alongside. **It runs on a Pocket**: picture, sound and controls,
checked by eye and ear on hardware at 0.1.0 — see Status.

> **ROMs are not included and never will be.** You supply your own MAME
> `smashtv` romset; the core reads one image built from it.

| board part | implementation | verified by |
|---|---|---|
| TMS34010 @ 40 MHz ÷ 8 | `rtl/tms34010.sv`, written here from MAME's | `sim/run_cpu.sh`: every register before every instruction, every bus transaction and every cycle charged, against MAME's own traces - 77 million instructions from reset through a coin, live from two MAME runs |
| Williams DMA blitter | `rtl/stv_blit.sv` | `sim/run_video.sh`: index-identical to the reference renderer on 68 frames in 8 windows, at 4.00 clocks per source pixel against the board's 3.936 |
| frame buffer, two planes | `rtl/stv_vram.sv` | the same gate; block RAM for rows 0-255 and the autoerase templates, SDRAM for rows 256-509 |
| raster, scanout, palette | `rtl/stv_video.sv` | the same gate; 410×256 at 54.7069 Hz off an 8.000 MHz dot clock, which is the board's exactly |
| the main board as a whole | `rtl/stv_main.sv` | `sim/run_machine.sh`: 2000 frames from reset on ideal memories - power-up tests, attract, coin, start, play. Before the CPU was re-timed: pixel-identical to MAME on every frame compared but one (4 pixels), and all 80 words to the sound board identical in value and frame. After: the same words, the coin sound one frame late, play frames identical or 4 pixels off (see Status) |
| MC6809E, YM2151, HC-55516, MC1408, 6821 | `rtl/stv_sound.sv` with `modules/cpu-mc6809`, `modules/sound-jt51`, `rtl/hc55516.sv`, `rtl/pia6821.sv` | `sim/run_sound.sh`: MAME's commands replayed, a whole minute including 28 s of play compared second by second and band by band - within 4% of MAME below 6 kHz |
| ROMs, RAM, CMOS | Pocket SDRAM and SRAM (`target/pocket/smashtv_mem.sv`) | `sim/run_mem.sh`: the image at the loader's real rate, every port read back, all clients at once; image byte-identical to MAME's |
| the core on the Pocket's memories | `rtl/smashtv_core.sv` on `smashtv_mem` | `sim/run_pocket.sh`: boots, passes the game's own RAM, ROM and custom-chip tests, takes a coin and plays, with the CPU at 98-100% of MAME's speed in attract and play |
| the build | Quartus 18.1, `./build-local.sh compile` | fits (62% ALMs, 301/308 block RAMs); timing closed in every corner; every constraint applied |
| all of it, on a Pocket | release 0.1.0, bitstream md5 `a15ab9fde2f7f1d82ff5104726e1b40a` | seen and heard on hardware: boot tests, attract, coin, start, play |

One row per part of the board. The right-hand column is the point of the
table: it says what checks each part, and where it says nothing, nothing does.

## Status

**0.1.0 runs on an Analogue Pocket.** The build that was released boots
through the game's own RAM, ROM and custom-chip tests, plays attract mode,
takes a coin, starts and plays, with the right picture, sound and controls,
as seen and heard by the person holding it. Everything else below is
simulation against MAME and the Quartus build (62% of the logic, 301 of the
308 block RAMs, timing closed at 96 MHz in every corner).

Hardware found two things no simulation here could, both now guarded:

- The PLL's video clock was still the template's 96/14 MHz while the core made
  a dot every 12 clocks: static, with the game playing behind it. `sim/lint.sh`
  now checks the PLL against the dot divider and `sim/run_pocket.sh` samples
  pixels the way the Pocket does.
- The picture is 410 pixels wide and **the Pocket's scaler wants a multiple of
  four**: at 410 every four-pixel group came out with its halves exchanged
  (columns 2-3-0-1), everywhere, in no simulation. `rtl/stv_pad.sv` hands it
  over 412 wide with a black column either side, and that fixed it outright.
  `docs/bringup.md` has the log and `artifacts/pocket/hardware_fault/` the
  photograph against the candidate permutations.

Proven, and by what:

- The board is documented in `docs/hardware.md` from MAME 0.288's sources
  (kept verbatim in `ref/mame/`) and from measurements taken off the game
  running under MAME against this romset. Every number there is cited or
  marked as measured, with the window it was measured over.
- MAME runs this romset headless and deterministically through
  `tools/mame.sh` - from an **empty NVRAM every run**, because MAME saves the
  game's CMOS on exit and two runs were otherwise two different machines.
- **The ROM image.** `tools/verify_rom.py` proves all three regions
  byte-identical to what MAME hands the chips, including all 1,572,864
  decoded graphics pixels, and it catches a flipped bit in any plane, a
  swapped plane pair and a non-zero pad byte.
- **The CPU.** `rtl/tms34010.sv` is held to MAME one instruction and one bus
  transaction at a time, and to MAME's cycle count for every instruction
  form. The longest run is 76,962,925 instructions (reset, the power-up
  tests, attract, a coin): all identical, 180,050,603 cycles charged by MAME
  and the same by the RTL but for 16 (one form of DIVS, since corrected).
- **The video RTL** (`rtl/stv_blit.sv`, `rtl/stv_vram.sv`, `rtl/stv_video.sv`)
  produces the same 410×256 palette indices as the reference renderer on all
  68 frames of all eight windows. **The reference renderer**
  (`tools/render_model.py`) is pixel-identical to MAME on every frame of those
  windows, and `tools/teeth_video.py` shows what the gate can and cannot catch.
- **The main board.** From reset to frame 2000 on ideal memories the frames
  are MAME's - `artifacts/machine/` - and so is every command to the sound
  board, to the frame.
- **The sound board.** A minute against MAME's recording: per-second RMS
  within 0.96-1.07, mean |log2| error 0.026 overall and 0.018-0.053 in the
  bands below 6 kHz. The top band reads 27% high sampled the way the core's
  48 kHz hand-over used to sample it and 10% high averaged, so
  `target/pocket/core_top.sv` now averages.
- **The Pocket memory path.** `sim/run_mem.sh`: the real image through the
  download port at the loader's rate, every region read back through the
  core's ports, the graphics read-ahead in order, skipping and at random, all
  four SDRAM clients at once, and the SRAM across its 17th address line.
- **The core on those memories.** `sim/run_pocket.sh` boots it from the
  download: the game's own tests pass (every RAM and ROM chip green, U99 the
  blitter included), it takes a coin and plays; no ack on the shared graphics
  port ever coincided with another client's request rising.

Not proven:

- **Much of the game on hardware.** One person has played the first rooms of
  one build. Later levels, a second player, the test menu's contents and long
  sessions have not been looked at.
- **Frame-exactness with the timed CPU.** To close timing the TMS34010
  advances one clock in three. It is held to MAME instruction for
  instruction, transaction for transaction and cycle for cycle
  (`sim/run_cpu.sh`), but it runs the power-up RAM test at 93-96% of MAME's
  speed (85-91% on the Pocket's memories), so the boot ends 19 frames later
  than MAME's (51 on the Pocket's memories) and frames after it line up with
  MAME's only to within a frame or three. The frame-for-frame identity
  through 2000 frames was measured on the CPU before that change.
- **The CMOS is not saved to the SD card.** It lives in the Pocket's SRAM,
  which - as seen on hardware - keeps the game's settings and high scores
  between restarts; no save file backs it, so a long power-off may lose it, and
  a blank one shows FAILURE IN CMOS RAM for seven seconds and restores factory
  settings. (I first wrote that it was lost at every power-on: an assumption,
  corrected by the person holding the Pocket.) `docs/core-design.md` section 8.
- **0.1.0's power-on SRAM test damages one CMOS word per start** (the head of
  the high-score table): it wrote its pattern at SRAM 0x10000 and did not put
  back what was there. `target/pocket/sram_selftest.sv` now does, checked by
  `sim/run_mem.sh`; that is in the tree, not in the 0.1.0 bitstream.
- The 6809 sometimes waits for its ROM: about two stretched cycles a frame
  in play, of 36,500 (`docs/bringup.md`, square 24). Inaudible is the
  expectation, not a measurement.
- Three parts of the video model are **unverified rather than correct**: the
  autoerase lag (±1 raster line makes no difference to any captured frame),
  which of the two template rows a row is erased from, and autoerase being
  present at all (worth only 171 pixels across the capture set). See
  `tools/teeth_video.py`.
- Two blitter command bits are followed rather than understood: bit 5
  ("flip y") and bit 11. `docs/hardware.md` section 10. INT2's source and the
  watchdog likewise.
- Nothing past frame 2000 and no second player. The service button is shown
  to open the game's test menu (`artifacts/machine/service_menu.png`); what is
  in that menu has not been run.

## Analogizer

The core supports RndMnkIII's [Analogizer](https://github.com/RndMnkIII/Analogizer)
adapter: the board's native 15.8 kHz, 54.7 Hz picture out of the VGA port
(RGBS, RGsB, YPbPr, Y/C, or scandoubled for a VGA monitor), and SNAC
controllers for both players.  It is set up in the core's own menu
(Analogizer, Analogizer Video, SNAC Adapter, SNAC Assignment, and H and V
Position to centre the picture on the CRT); with "Analogizer" off, the
default, the core is unchanged.  A SNAC pad plays as the Pocket does: the
d-pad moves, the four face buttons fire up, down, left and right.  Because
the core declares a cartridge adapter, the Pocket powers the slot: take any
game cartridge out first.  `docs/analogizer.md` has the modes, the
controller assignments, and what has and has not been checked. Confirmed on
a Pocket with an Analogizer and a CRT (0.2.0).

## Building the ROM image

```sh
python3 tools/mra_build.py smashtv.mra smashtv.zip
```

The builder needs only Python 3. It reads the MAME zip (or a directory of loose
files), checks every ROM's CRC32, and verifies the finished image against a
known md5. Copy the result to `Assets/smashtv/common/smashtv.rom` on the SD card.

This romset is often distributed with the pre-0.240 short file names
(`la1.u95`, `u89-la8`). The builder finds each part by its CRC32 when it is not
there under MAME 0.288's name, and says which file it used.
`tools/shadow_romset.sh` does the same renaming for MAME's sake.

## Building the core

`./build-local.sh` compiles with Quartus 18.1 in Docker and leaves the SD-card
package in `release/pocket/`. `./build-local.sh map` runs analysis and synthesis
only — a couple of minutes, and it catches what Verilator cannot.

## Checking it

```sh
sim/lint.sh                 # every module on its own
sim/run_mem.sh              # the Pocket's memory path, at the loader's real rate
sim/run_video.sh            # the video RTL against the renderer: zero indices or fail
tools/cpu_trace.sh          # MAME's bus and register traces (default: 40 frames from reset)
sim/run_cpu.sh              # the CPU against them; -live <seconds> streams from MAME instead
sim/run_machine.sh 2000 100 # the main board from reset, frames to artifacts/machine/
sim/run_sound.sh            # the sound board against MAME's recording, band by band
sim/run_pocket.sh 2000 100  # the whole core on the real memory glue, from the download
sim/run_analogizer.sh       # the Analogizer path, read at the cartridge pins

tools/shadow_romset.sh      # once: the romset under the names MAME 0.288 wants
REGION_DIR=/tmp/r tools/mame.sh -seconds_to_run 2 \
    -autoboot_script tools/dump_regions.lua
tools/verify_rom.py /tmp/smashtv.rom /tmp/r    # the image against MAME

tools/dump_states.sh        # capture the reference states and traces (~20 s)
tools/regress_video.sh      # the renderer against MAME: zero pixels or fail
tools/teeth_video.py        # what that gate can and cannot catch

TRACE_DIR=/tmp/b tools/mame.sh -seconds_to_run 1 \
    -autoboot_script tools/bus_trace.lua      # every TMS34010 bus transaction
tools/diff_bus.py --selftest /tmp/b/trace_bus.bin
```

## Credits

MAME, for the driver and devices this was written against (`ref/mame/`). The
vendored cores and their authors (`modules/VENDOR.md`). **RndMnkIII**, for
the [Analogizer](https://github.com/RndMnkIII/Analogizer) adapter and its
`openFPGA_Pocket_Analogizer` module (`target/pocket/analogizer/`), with the
parts it gathers from others: the Y/C encoder by **Mike Simone**
(MiSTerFPGA_YC_Encoder), the scandoubler and HQ2x by **Sorgelig** and
**Ludvig Strigeus** (MiSTer), the PlayStation controller interface after
**pgate1**'s psPAD, and the SNAC game-controller readers he credits to
**@MikeSimonson**, the **MiST** project, **@RandyS**, **jotego**, **Scott
Larson** (the PS/2 receiver) and **@tomasz**. The
openFPGA/opengateware framework in `platform/pocket/`. Anyone whose board
photographs, schematics or measurements are in `docs/hardware.md`.
