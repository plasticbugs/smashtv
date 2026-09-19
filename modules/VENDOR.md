# Vendored modules

Third-party HDL cores copied into the tree — no submodules, so the build is
self-contained and reproducible. Each keeps its own LICENSE alongside.
`tools/vendor.sh <sibling> <module>` copies one from a sibling core;
`tools/gen_qip.sh` then lists everything under `modules/` for Quartus.

| module | upstream | via | licence |
|---|---|---|---|
| *(none yet)* | | | |

For each module record: what it is, the upstream repository and commit, which
sibling it came through, its licence, and anything it needs that is not
obvious (jt12's `hdl/` must be copied whole, for instance, because `jt12_top`
instantiates its ADPCM files outside a generate guard).

Written here rather than vendored: list the custom chips reimplemented from
MAME's device models, and where their behaviour is documented.

To update one: re-copy from upstream at the new commit and record it here.
