# My Core — Analogue Pocket core (openFPGA)

> **This is the template.** Run `tools/init_core.py <shortname> "<Title>"`,
> then replace this block with two sentences: the game, the maker, the year,
> the board, and what is in the gateware. `CLAUDE.md` says what to do next.

> **ROMs are not included and never will be.** You supply your own MAME
> `mycore` romset; the core reads one image built from it.

| board part | implementation | verified by |
|---|---|---|
| *main CPU @ MHz* | *vendored core* | *which bench* |
| *sound CPU* | | |
| *sound chip* | | *band energy against MAME's recording, over what window* |
| *video chip* | `rtl/…` | *pixel-identical to MAME on N frozen states* |
| *ROM* | Pocket SDRAM (`target/pocket/mycore_mem.sv`) | `sim/run_mem.sh`; image byte-identical to MAME's regions |
| *tilemap RAM* | Pocket SRAM | self-test at reset |

One row per part of the board. The right-hand column is the point of the
table: write **"—"** where nothing verifies it, not nothing.

## Status

State plainly whether it has run on a Pocket. Then, as a list: what is proven
and by what; what the hardware found that no bench had; what is not
implemented. Keep the three apart. A reader deciding whether to trust the core
needs the second and third more than the first.

## Building the ROM image

```sh
python3 mra_build.py mycore.mra mycore.zip
```

The builder needs only Python 3. It reads the MAME zip (or a directory of loose
files), checks every ROM's CRC32, and verifies the finished image against a
known md5. Copy the result to `Assets/mycore/common/mycore.rom` on the SD card.

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
