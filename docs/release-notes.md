## Smash T.V. for Analogue Pocket 0.1.0

The first release. Williams' Smash T.V. (1990, Midway Y-unit): the TMS34010
graphics processor, the Williams DMA blitter and its 512x512 frame buffer, and
the CVSD sound board (6809, YM2151, DAC and CVSD speech), all in gateware
written against MAME and checked against it - the CPU instruction by
instruction over 77 million instructions, the video pixel by pixel, the sound
band by band over a minute of play.

**Tested on hardware**: this exact bitstream
(md5 `a15ab9fde2f7f1d82ff5104726e1b40a`) boots, plays attract mode, takes a
coin and plays, with correct picture, sound and controls.

### Installing

1. Unzip onto the root of the SD card (it adds to `Cores/`, `Platforms/` and
   `Assets/`).
2. **ROMs are not included.** Build the image from your own MAME `smashtv`
   romset (any MAME version's file names; parts are found by CRC):

       python3 mra_build.py smashtv.mra smashtv.zip smashtv.rom

   and copy `smashtv.rom` to `Assets/smashtv/common/`. It should be 2,031,616
   bytes, md5 `faac921545f4ea871a236abfdde31dd6`.

### Playing

- D-pad moves. **X, B, Y, A fire up, down, left, right** - the four face
  buttons are the second stick, so a diagonal is two buttons.
- Select is the coin, Start starts. A second controller is player two.
- Menu -> Service Button (on, then off) during attract mode opens the game's
  own DIAGNOSTIC TESTS.

### Known

- **Settings and high scores are kept in the Pocket's SRAM, not in a save
  file.** As seen on hardware they persist between restarts; nothing is
  written to the SD card, so do not count on them across a long power-off.
  The first start on a blank memory shows FAILURE IN CMOS RAM / DEFAULT
  ADJUSTMENTS RESTORED for about seven seconds, as a cabinet with a flat
  battery would, and carries on. *(These notes first said settings were lost
  at every power-on. That was an assumption, and it was wrong.)*
- **0.1.0's power-on memory test overwrites one word of that memory at every
  start** - the first word of the game's high-score table - without putting
  it back. Fixed in the source after 0.1.0; it will be in the next release.
- The power-up self-test takes about a second longer than the arcade board's.
- Tested by one person on the first rooms of the game. Reports welcome.
