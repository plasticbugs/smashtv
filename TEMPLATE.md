# Pocket arcade core template

A starting point for an Analogue Pocket (openFPGA) arcade core, cut from the
Master of Weapon core after it shipped and carrying what it, Cadash, Pleiads,
Time Pilot and Xenophobe learned. Delete this file once the core has a README
of its own.

## What it is

Not a blank scaffold: a **core that already works**, with no game in it.
`rtl/mycore_core.sv` draws a crosshatch and colour bars, moves a cursor with
the d-pad, beeps on button 1, and reads one word from each ROM region; around
it is the platform glue, memory subsystem, bring-up panel, benches, CI and
release tooling that the sibling cores run on hardware. The first thing a new
core does on a Pocket should be *work*, so that the PLL, SDRAM, SRAM,
download, video hand-over, controls and audio are proven before there is a
CPU to blame.

## What has been verified, and what has not

| | |
|---|---|
| `sim/lint.sh` | clean, every module on its own |
| `sim/run_mem.sh` | passes: 851,968 words through the download port at the loader's rate (a byte per 8 clocks, strobe held 4) and back through the core's ports, then the SRAM with byte enables |
| the gate has teeth | the same bench **fails** the pre-fix memory module that blacked out Master of Weapon's first hardware run (333 wrong words of 14,000 sampled, right low byte under wrong high byte) |
| Quartus 18.1 full compile | succeeds; no negative slack in any corner; no ignored constraints |
| `tools/init_core.py` | a stamped copy lints, passes the gate and synthesises |
| **on a Pocket** | **the skeleton itself has not been run.** Everything around `mycore_core.sv` is the code Master of Weapon v0.1.1 runs on hardware; the skeleton's own raster and pattern are new and unflashed. Flash it first and fix this line. |

## Start here

On GitHub, **Use this template** → a new repository, then clone it. Or with
the CLI:

```sh
gh repo create <shortname> --private --template plasticbugs/pocket-core-template
git clone https://github.com/<you>/<shortname>.git && cd <shortname>
tools/init_core.py <shortname> "<Title>"
tools/gen_qip.sh && sim/lint.sh && sim/run_mem.sh -quick
```

Locally, from the directory the template sits in (`~/work`):

```sh
git clone pocket-core-template <shortname>      # tracked files only: 1.2 MB,
cd <shortname> && rm -rf .git && git init       # not the 35 MB Quartus database
tools/init_core.py <shortname> "<Title>"        # stamps the names through the tree
tools/gen_qip.sh && sim/lint.sh && sim/run_mem.sh -quick
```

`git clone` rather than `cp -R`: the template's working tree carries a Quartus
build database and a compiled bench that a copy would drag into the new core.
`init_core.py` refuses to run twice, so a mis-typed name is recoverable by
starting the clone again.

**Fixes go back upstream.** `platform/`, `sdram_ctrl.sv`, `sram_port.sv`,
`interact.sv` and `core_top.sv`'s framework half are the same in every core
here. A bug fixed in one of them in a core is a bug still waiting in the next
one unless it is also fixed here — which is how the download corruption and
the menu reset each reached two cores.

Then read `CLAUDE.md`, then `METHODOLOGY.md`, and start `docs/hardware.md`.
The platform image is artwork the user supplies; `icon.bin` is the house icon
and is already in place.

## What is where

`CLAUDE.md` has the map. The stubs to fill in are `README.md`,
`docs/hardware.md`, `docs/core-design.md`, `docs/bringup.md`,
`modules/VENDOR.md` and `mycore.mra`. `tools/examples/` holds four
game-specific tools from Master of Weapon, kept as patterns.
