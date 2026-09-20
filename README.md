# Smash T.V. — Analogue Pocket core (openFPGA)

**Smash T.V.**, Williams 1990, on **Midway Y-Unit** hardware: a TMS34010
graphics processor driving a 512×512 frame buffer through a custom Williams
DMA blitter, with a Williams CVSD sound board (MC6809E, YM2151, HC-55516,
MC1408) alongside. The gateware here is **not finished** — see Status.

> **ROMs are not included and never will be.** You supply your own MAME
> `smashtv` romset; the core reads one image built from it.

| board part | implementation | verified by |
|---|---|---|
| TMS34010 @ 40 MHz ÷ 8 | *not written* | — |
| Williams DMA blitter | `rtl/stv_blit.sv` | `sim/run_video.sh`: index-identical to the reference renderer on 68 frames in 8 windows, at 4.00 clocks per source pixel against the board's 3.936 |
| frame buffer, two planes | `rtl/stv_vram.sv` | the same gate; block RAM for rows 0-255 and the autoerase templates, SDRAM for rows 256-509 |
| raster, scanout, palette | `rtl/stv_video.sv` | the same gate; 410×256 at 54.7069 Hz off an 8.000 MHz dot clock, which is the board's exactly |
| MC6809E @ 2 MHz | *not vendored yet* | — |
| YM2151 @ 3.579545 MHz | *not vendored yet* | — |
| HC-55516 CVSD | *not written* | — |
| 6821 PIA | *not written* | — |
| ROM | Pocket SDRAM (`target/pocket/smashtv_mem.sv`) | `sim/run_mem.sh`: 1,114,112 words at the loader's real rate; image byte-identical to MAME's |

One row per part of the board. The right-hand column is the point of the
table: it says **"—"** where nothing verifies it, not nothing.

## Status

**It has never run on a Pocket, and there is no game in it yet.** What is in
the tree is the template's working skeleton — a test pattern, a cursor and a
beep — plus the first two steps of the work `CLAUDE.md` lays out.

Proven, and by what:

- The board is documented in `docs/hardware.md` from MAME 0.288's sources
  (kept verbatim in `ref/mame/`) and from measurements taken off the game
  running under MAME against this romset. Every number there is cited or
  marked as measured, with the window it was measured over.
- MAME runs this romset headless and deterministically through
  `tools/mame.sh`, which is the oracle everything later is checked against.
- **The ROM image.** `tools/verify_rom.py` proves all three regions
  byte-identical to what MAME hands the chips, including all 1,572,864
  decoded graphics pixels, and it catches a flipped bit in any plane, a
  swapped plane pair and a non-zero pad byte.
- **The Pocket memory path.** `sim/run_mem.sh` pushes the real image through
  the download port at the loader's rate — a byte per 8 clocks, strobe held 4
  — and reads all 1,114,112 words back through the core's ports: none wrong.
- **The video RTL** (`rtl/stv_blit.sv`, `rtl/stv_vram.sv`, `rtl/stv_video.sv`)
  produces the same 410×256 palette indices as the reference renderer on all
  68 frames of all eight windows — the blitter, the two frame-buffer planes,
  the CPU's window into them, autoerase, the 6-bit pen map and the palette.
  `sim/run_video.sh` loads a frozen state through the CPU's own port, replays
  the same trace, and diffs indices rather than colours. It also measures:
  the blitter runs at **4.00 clocks per source pixel** against the board's
  3.936, no event ever lands on a later raster line than MAME had it, and no
  write is ever held off because the display was fetching that row.
- **The reference renderer** (`tools/render_model.py`) is pixel-identical to
  MAME on every frame of eight captured windows spanning the power-up RAM
  test, the CPU drawing text, the ROM check, a screen clear, the title, the
  attract mode and two of gameplay — and its frame buffer is byte-identical
  to MAME's at the end of each. `tools/teeth_video.py` shows the gate
  catching a wrong pen map, a wrong plane order, a one-row scanout error, a
  wrong flip and the wrong frame-buffer plane.

Not proven:

- **There is no CPU and no sound**, so there is no machine: `rtl/smashtv_core.sv`
  still draws the template's test pattern. The video RTL above is verified in
  isolation against the renderer and is **not wired into the core**, because
  without a CPU to program it the screen would be black — and the skeleton
  working on a Pocket is worth more than an unfinished machine.
- **The block-RAM budget is arithmetic, not a measurement.** The frame
  buffer's hot rows want 258 of the 5CEBA4's M10K blocks and everything else
  about 10 more, which is 87%. The first fit that includes them is the check;
  `docs/core-design.md` section 3 has the fallback if it does not fit.
- Three parts of the video model are **unverified rather than correct**: the
  autoerase lag (±1 raster line makes no difference to any captured frame),
  which of the two template rows a row is erased from (the game keeps them
  identical, so the parity is unobservable), and autoerase being present at
  all (worth only 171 pixels across the whole capture set). See
  `tools/teeth_video.py`.
- Two blitter command bits are followed rather than understood: bit 5
  ("flip y") and bit 11. MAME ignores both; so does the model, and the
  captures agree with MAME on all 76 frames — which means the game does not
  depend on them, not that they do nothing. `docs/hardware.md` section 10.

## Building the ROM image

```sh
python3 tools/mra_build.py smashtv.mra smashtv.zip
```

The builder needs only Python 3. It reads the MAME zip (or a directory of loose
files), checks every ROM's CRC32, and verifies the finished image against a
known md5. Copy the result to `Assets/smashtv/common/smashtv.rom` on the SD card.

Note that this romset is often distributed with the pre-0.240 short file names
(`la1.u95`, `u89-la8`). `tools/shadow_romset.sh` maps them to the names MAME
0.288 wants, matched by CRC32 rather than by the number in the name.

## Building the core

`./build-local.sh` compiles with Quartus 18.1 in Docker and leaves the SD-card
package in `release/pocket/`. `./build-local.sh map` runs analysis and synthesis
only — a couple of minutes, and it catches what Verilator cannot.

## Checking it

```sh
sim/lint.sh                 # every module on its own
sim/run_mem.sh              # the Pocket's memory path, at the loader's real rate
sim/run_video.sh            # the video RTL against the renderer: zero indices or fail

tools/shadow_romset.sh      # once: the romset under the names MAME 0.288 wants
REGION_DIR=/tmp/r tools/mame.sh -seconds_to_run 2 \
    -autoboot_script tools/dump_regions.lua
tools/verify_rom.py /tmp/smashtv.rom /tmp/r    # the image against MAME

tools/dump_states.sh        # capture the reference states and traces (~20 s)
tools/regress_video.sh      # the renderer against MAME: zero pixels or fail
tools/teeth_video.py        # what that gate can and cannot catch
```

Add the core's own gates here as they come to exist: the RTL against the
renderer, the whole machine, the sound.

## Credits

MAME, for the driver and devices this was written against (`ref/mame/`). The
vendored cores and their authors (`modules/VENDOR.md`). The
openFPGA/opengateware framework in `platform/pocket/`. Anyone whose board
photographs, schematics or measurements are in `docs/hardware.md`.
