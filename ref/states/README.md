# Captured reference states

Not committed: 18 MB, and exactly reproducible. Rebuild them with

```sh
tools/dump_states.sh
```

which runs MAME once per window against the shadow romset
(`tools/shadow_romset.sh`) and writes, per window:

| file | what |
|---|---|
| `state_NNNNN.bin` | the frame buffer, the pens, the control and blitter registers, frozen at MAME's frame boundary |
| `trace.bin` | every write that can change the picture for the frames that follow, timestamped by raster line |
| `mame_NNNNN.png` | MAME's own picture for each frame — the thing to match |

A second `state_*.bin` at the far end of each window lets the replay's frame
buffer be compared with MAME's directly, which separates a wrong blit from
wrong timing.

Then

```sh
tools/regress_video.sh      # zero differing pixels is the only pass
tools/teeth_video.py        # what the gate can and cannot catch
```

The windows are chosen from a measurement, not guessed — see the comment in
`tools/dump_states.sh`. `ramtest`, `cputext` and `clear` are the only ones
that exercise the CPU's own frame-buffer writes; the rest is the blitter.

**Use `screen:snapshot()`, never `screen:pixels()`.** Measured at the same
instant on the same frame, `pixels()` returns a bitmap one frame older.
Comparing against it made a correct renderer look exactly one frame ahead
wherever something moved, and exactly right on every still screen.
