# First flash: what to do and what to read

For the person holding the Pocket. Keep this exact — it is read from while
someone decodes squares off a screen.

## Before flashing

- `sim/lint.sh` clean; `sim/run_mem.sh` passes at `-gap 8 -hold 4`.
- The whole-machine bench on the real memory glue boots.
- `./build-local.sh compile`: no negative slack in any corner
  (`projects/output_files/*.sta.summary`), no ignored constraints. The build
  The current build does: bitstream md5 `a15ab9fde2f7f1d82ff5104726e1b40a`.
- The ROM image's md5 matches the MRA's.

## On the card

`release/pocket/` onto the card root, with `cp -X` from macOS. The ROM image
goes in `Assets/smashtv/common/smashtv.rom`. Verify the bitstream's md5 on the
card.

## What a healthy first boot looks like

Timed from the end of the download, at 54.7 frames a second:

| when | what is on the screen |
|---|---|
| 0-2 s | the power-up RAM test: the whole picture flashes through solid colours and fine patterns. **This is the frame buffer being tested, not a fault.** |
| 2-20 s | white text on black: `SMASH TV REVISION 8.00`, then the CPU, RAM and ROM checks reporting in turn (`CHECKING ROMS` with a list of chip numbers) |
| 20-27 s | **`FAILURE IN CMOS RAM`** in red and `DEFAULT ADJUSTMENTS RESTORED.` - the game finding a blank battery-backed RAM, exactly as MAME does with no saved NVRAM. Expected when the SRAM is blank; on hardware the SRAM keeps the CMOS between restarts, and then this screen does not appear. |
| 28 s on | attract mode. **Silent** - the board makes no sound until a coin goes in. |

Select is the coin (a sound plays, `CREDITS: 1`), Start starts. The d-pad
moves; X, B, Y and A fire up, down, left and right.

The first sound the board ever makes is a short tone about two seconds after
power-up, from the sound board's own self-test. No tone and no coin sound
means the sound board; a tone but no coin sound means the latch between the
boards.

## The panel

Menu -> **Bring-up: panel** (not on the release's menu: add the entry back to
`interact.json`, address `0xF2000000`, value `0x00000008`, mask `0xFFFFFFF7`).
Four rows of 32 squares along the bottom edge of
the picture. Green is 1. Read each row from the end where row 0 shows
`1010 1010`.

| row | squares | meaning | healthy |
|---|---|---|---|
| 0 | 1-8 | alignment marker | `1010 1010` - if not, stop: the reading is misaligned |
| 0 | 9-16 | frame counter | changing |
| 0 | 17 | PLL locked | 1 |
| 0 | 18 | memory ready | 1 |
| 0 | 19 | downloading | 0 |
| 0 | 20 | all slots complete | 1 |
| 0 | 21 | loaded | 1 |
| 0 | 22 | core in reset | 0 |
| 0 | 23 | TMS34010 stopped at an instruction the gateware does not build | 0 |
| 0 | 24 | the sound ROM has made the 6809 wait at least once | 0 - a 1 is audible as wavering speech, not a crash |
| 0 | 25-32 | IN1 bits 7-0, active low: bill, service credit, start 2, service, tilt, start 1, coin 2, coin 1 | `1111 1111` with nothing pressed; Select clears square 32, Start square 30 |
| 1 | 1-32 | the TMS34010's program counter | changing; the first three squares `111` (the program ROM is at `FFExxxxx`-`FFFxxxxx`) |
| 2 | 1-16 | first program ROM word fetched (the reset vector's low half) | `1111 0101 1100 0000` (F5C0) |
| 2 | 17-24 | first sound ROM byte fetched (0xFFFF of U4, read in the 6809's reset sequence) | `1100 1000` (C8) |
| 2 | 25-32 | top byte of the first graphics word fetched (word 0, during the ROM check, about 9 s in) | `0000 0000` - so this one proves nothing; the ROM check's green chips do |
| 3 | 1-16, 17-32 | SRAM self-test, one word either side of address line 16 | `1010 0101 0101 1010`, `0101 1010 1010 0101` |

Row 2 proves the path, not the image; `sim/run_mem.sh` proves the image. All
three values are what `sim/run_pocket.sh` prints for the same latches.
Row 3's two words are written to SRAM addresses 0x00000 and 0x10000. **This
is the first core to use the SRAM's seventeenth address line**; if the two
halves of row 3 read the same (`5AA5 5AA5`), that line is not reaching the
chip, and main RAM and the CMOS are landing on top of each other.

## If it is wrong

| symptom | look at |
|---|---|
| black, frame counter running, row 1 standing still, square 23 lit | an instruction the CPU does not build: row 1 is its address. `sim/run_cpu.sh` on a trace through that address |
| black, row 1 moving, row 2 right | the program is running and the video is not: the frame buffer or the TMS34010's video registers. Ask what the first two seconds looked like |
| `CUSTOM CHIP U99 BAD` | the blitter's write into frame-buffer rows 256-509, which live in SDRAM (it was this in simulation once) |
| a RAM or ROM chip reported bad on the text screens | that memory's path: row 3 for RAM (SRAM), row 2 and `sim/run_mem.sh` for ROM |
| row 3 not the pattern | **Bring-up: SRAM** switches; then the SRAM port. `5AA5 5AA5`: address line 16 |
| row 2 wrong | **Bring-up: SDRAM** switches; then the PLL phase (SDC, METHODOLOGY section 5.20) |
| sprites torn or missing, text fine | the graphics read-ahead in `smashtv_mem.sv`, or the blitter outrunning it |
| objects flicker or are cut off along a horizontal line | the game races the beam: the CPU or the blitter is slower than the board's. Say which rows |
| garbled picture | ask for the game's own patterns first: Menu -> **Service Button** on, then off, during attract -> DIAGNOSTIC TESTS -> MONITOR PATTERNS (d-pad to move, a fire button to choose); METHODOLOGY section 5.18 |
| glitches only while playing, gone in the menu | something the CPU shares with the video; METHODOLOGY section 5.17 |
| speech wavers in pitch | square 24: the sound ROM is making the 6809 wait |
| menu restarts the game | `pause` has reached a reset; METHODOLOGY section 5.5 |
| picture goes to background colour while the menu is open | the autoerase is not being held by `pause` |

## With an Analogizer

Not yet run on hardware with this core (docs/analogizer.md says what the
bench proved; the same wrapper has had one run in Moo Mesa).  In this
order -- each step's reading tells the next one where to look:

1. **Menu "Analogizer: Off"** (the default).  The core must play exactly as
   without the adapter, Pocket screen and controls.  This build also moved
   a few short shift registers out of block RAM to make room for it
   (docs/analogizer.md, *Block RAM*), so a fault here with the Analogizer
   off is that, not the adapter.  If it does not play as before, stop there.
2. **Menu: Analogizer On, Video RGBS, SNAC Adapter None.**  Expected: the
   same picture on the Pocket and on the CRT, 15.81 kHz / 54.71 Hz (a PVM's
   info screen shows it; some consumer sets will not hold 54.7 Hz).  The
   bring-up panel shows on the CRT too.  No picture at all: say whether the
   CRT reports a signal (sync but no colour points at the DAC clock; nothing
   at all points at sync).
3. **Each other video mode in turn** (RGsB and YPbPr need the SOG switch on).
4. **SNAC**: one pad, assignment "SNAC P1 -> P1": the d-pad moves, the face
   buttons fire; the Pocket's own controls are then player 2.
5. **The menu's memory**: change Video, quit the core and load it again.
   The setting, and Analogizer On, should still be there.  Then change one
   entry and check the others did not move.
6. **Position**: "Analogizer V Position" + should move the picture down by
   that many lines, + on "H Position" to the right (only 5 dots: the board
   leaves little blanking there), and both should be kept across a reload.
   Try a negative value early: that the firmware writes a signed slider as
   the core reads it is not proven.

## Log

- 2026-09-20, build `7de5b402...`: **game audio, game starts and plays, picture
  is pink static throughout.**  Ruled in at once: CPU, sound board, SDRAM,
  SRAM (so its 17th address line), download, controls.  Cause: the PLL's video
  clock was still the template's 96/14 MHz while the core makes a dot every 12
  clocks - my error; I had written "8 MHz" into the comments and never into
  the PLL.  `VID_DIV=14 sim/run_pocket.sh` reproduces the static
  (`artifacts/pocket/hardware_fault/`).  Fixed in build `c4d30248...`.
- 2026-09-20, build `c4d30248...`: **boots and runs; every picture has its
  columns scrambled, the same everywhere, standing still** - the boot text,
  the ROM-check board map, attract, play, the test menu.  Rows and colours
  right.  Measured from the photograph of the DIAGNOSTIC TESTS banner against
  the bench's render of the same banner under five candidate permutations
  (`artifacts/pocket/hardware_fault/banner_under_candidate_permutations.png`,
  rows: original, reverse-8, reverse-4, halves 2-3-0-1, pairs 1-0-3-2,
  reverse-16): it is **2-3-0-1, the halves of every four-dot group exchanged,
  aligned to the screen**.  Not in any simulation, including the bench that
  samples as the Pocket does; the RAMs are built as written.  THEORY, with one
  line of evidence: the Pocket's scaler wants a width that is a multiple of
  four - this picture is 410 and all sixteen other cores checked are multiples
  of four.  Build `a15ab9fd...` hands it over 412 wide (`rtl/stv_pad.sv`, one
  black dot each side; video.json 412).  Predicted: text reads correctly, with
  a black column at each edge.  If it is unchanged the theory is dead; next
  would be the line's TOTAL length, 506 dots, which is also 2 more than a
  multiple of four.
- 2026-09-20, build `a15ab9fd...` (412 wide): **"It's perfect."**  The theory
  is confirmed by its prediction: the Pocket's scaler needs a picture width
  that is a multiple of four.  This is the build released as 0.1.0.  The
  bring-up entries came off the menu for the release; they are still wired in
  `core_top.sv` (modifier word bits 3, 4, 5, 7 and 15), and putting the five
  entries back in `interact.json` needs no rebuild.
- 2026-09-20, 0.1.0: **settings persist between restarts** - against what I had
  written in the release notes (that they were lost every power-on).  The CMOS
  is in the SRAM and the SRAM keeps its contents.  Which showed a defect of
  mine: the power-on self-test wrote 5AA5 over SRAM 0x10000, the first CMOS
  word (0x0022 in a MAME NVRAM: the head of the high-score table), at every
  start.  The test now puts back both words (`sram_selftest.sv`; `sim/run_mem.sh`
  checks the patterns read back AND that BEEF/0022 are left as found).  Not yet
  on hardware.

- 2026-10-08, bitstream be9d819d0c599d6a3cc7712fe2559dba (Analogizer, branch
  `analogizer`): not yet run.  With "Analogizer: Off" it should play exactly
  as 0.1.0 did; the first reading is that, then the menu's six new entries
  under the game's own.  This build also moved short shift registers out of
  block RAM to make room (docs/analogizer.md, *Block RAM*).

Date, build md5, what was seen, what it ruled out. One line each. The theories
that died belong here as much as the one that lived.
