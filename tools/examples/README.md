# Worked examples, from the Master of Weapon core

These are not generic, and they will not run here as they stand: they name that
board's regions, chips and state format. They are kept because each is the
pattern for a tool every core needs, and adapting one is quicker and safer
than starting blank. The full set, with the reference renderer they belong to
(`vcu_model.py`, `render_model.py`, `regress_render.sh`), is in `../masterw/tools/`.

| file | what to make of it |
|---|---|
| `verify_rom.py` | de-interleaves the built ROM image and compares every region with the bytes MAME hands the chips (`dump_regions.lua`). Do this before trusting any `map=` attribute. |
| `dump_state.lua` | dumps one frame's machine state from MAME — VRAM, sprite RAM, scroll, control registers, palette, and MAME's own pixels — as the frozen state the video bench loads. Note the alignment it documents: the pixels in dump N were drawn from tilemaps of N-1 and sprites of N-2. Yours will differ; measure it. |
| `idx2png.py`, `diff_index.py` | the RTL bench writes palette *indices*, not colours, so a diff against the renderer cannot be hidden by two indices sharing a colour. |
