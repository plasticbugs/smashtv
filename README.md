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
| Williams DMA blitter | *not written* | — |
| frame buffer + scanout | *not written* | — |
| MC6809E @ 2 MHz | *not vendored yet* | — |
| YM2151 @ 3.579545 MHz | *not vendored yet* | — |
| HC-55516 CVSD | *not written* | — |
| 6821 PIA | *not written* | — |
| ROM | Pocket SDRAM (`target/pocket/smashtv_mem.sv`) | *layout not set yet* |

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

Not proven:

- Everything else. There is no CPU, no blitter, no video and no sound in the
  gateware yet.

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
sim/lint.sh          # every module on its own
sim/run_mem.sh       # the Pocket's memory path, at the loader's real rate
```

Add the core's own gates here as they come to exist: the reference renderer
against MAME, the RTL against the renderer, the whole machine, the sound.

## Credits

MAME, for the driver and devices this was written against (`ref/mame/`). The
vendored cores and their authors (`modules/VENDOR.md`). The
openFPGA/opengateware framework in `platform/pocket/`. Anyone whose board
photographs, schematics or measurements are in `docs/hardware.md`.
