# Vendored modules

Third-party HDL cores copied into the tree — no submodules, so the build is
self-contained and reproducible. Each keeps its own LICENSE alongside.
`tools/vendor.sh <sibling> <module>` copies one from a sibling core;
`tools/gen_qip.sh` then lists everything under `modules/` for Quartus.

| module | upstream | via | licence |
|---|---|---|---|
| cpu-mc6809 | https://github.com/cavnex/mc6809 (Greg Miller's cycle-accurate MC6809/E) | the Xenophobe core, at its commit ce86a8d | BSD-style, `LICENSE.md` |
| sound-jt51 | https://github.com/jotego/jt51 `hdl/` | the Cadash core (which has it from Xenophobe) | GPL-3.0 |

For each module record: what it is, the upstream repository and commit, which
sibling it came through, its licence, and anything it needs that is not
obvious (jt12's `hdl/` must be copied whole, for instance, because `jt12_top`
instantiates its ADPCM files outside a generate guard).

**cpu-mc6809 is not upstream's file.** Upstream clocks the core on the falling
edges of E and Q themselves; on an FPGA those are counter outputs used as
clocks, outside timing analysis. The Xenophobe core changed it to run on the
system clock with two enables, `cen_e` and `cen_q`, pulsed where E and Q would
fall (that commit's message has the reasoning), and that version is what is
here. `rtl/stv_sound.sv` makes the enables: E is `clk_sys` / 48 exactly. Its
`ADDR` output is combinational from the next-address logic, which in a few
states looks at `D` - a loop on paper with any read mux that selects on
`ADDR`; `rtl/stv_sound.sv` carries the one narrow lint waiver for it.

**sound-jt51** wants `cen` at 3.579545 MHz and `cen_p1` at half that, and
samples a write only on `cen_p1`, so a write strobe has to be held until one
has passed (`rtl/stv_sound.sv`, "YM2151").

`rtl/pia6821.sv` and `rtl/hc55516.sv` are from the Xenophobe core's own RTL
(same author as this repository's template), where they run the same Williams
sound-board design on hardware; each says so at its top.

Written here rather than vendored, from MAME's device models: the TMS34010
(`rtl/tms34010.sv`, held to MAME's bus and register traces by
`sim/run_cpu.sh`), the Williams DMA blitter (`rtl/stv_blit.sv`), the frame
buffer with its autoerase (`rtl/stv_vram.sv`) and the TMS34010's video timing
(`rtl/stv_video.sv`), all checked against `tools/render_model.py` by
`sim/run_video.sh`. `docs/hardware.md` is the behaviour they were written
against.

To update one: re-copy from upstream at the new commit and record it here.
