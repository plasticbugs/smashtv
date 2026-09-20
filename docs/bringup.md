# First flash: what to do and what to read

For the person holding the Pocket. Keep this exact — it is read from while
someone decodes squares off a screen.

## Before flashing

- `sim/lint.sh` clean; `sim/run_mem.sh` passes at `-gap 8 -hold 4`.
- The whole-machine bench on the real memory glue boots.
- `./build-local.sh compile`: no negative slack in any corner
  (`projects/output_files/*.sta.summary`), no ignored constraints. The build
  of commit 6af2cdc did this: bitstream md5 `7de5b402eae50011d0a52f243e6f6bf0`.
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
| 20-27 s | **`FAILURE IN CMOS RAM`** in red and `DEFAULT ADJUSTMENTS RESTORED.` - the game finding a blank battery-backed RAM, exactly as MAME does with no saved NVRAM. Expected on every power-on until the CMOS is saved to the card. |
| 28 s on | attract mode. **Silent** - the board makes no sound until a coin goes in. |

Select is the coin (a sound plays, `CREDITS: 1`), Start starts. The d-pad
moves; X, B, Y and A fire up, down, left and right.

The first sound the board ever makes is a short tone about two seconds after
power-up, from the sound board's own self-test. No tone and no coin sound
means the sound board; a tone but no coin sound means the latch between the
boards.

## The panel

Menu -> **Bring-up: panel**. Four rows of 32 squares along the bottom edge of
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

## Log

Date, build md5, what was seen, what it ruled out. One line each. The theories
that died belong here as much as the one that lived.
