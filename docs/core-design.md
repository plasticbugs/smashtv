# How the board maps onto the Pocket

`docs/hardware.md` says what the board is. This says what the gateware does
about it, and what the budgets are. Every number here is either arithmetic
from `docs/hardware.md` or a measurement, marked *(measured)* with its window.

---

## 1. Clocks

The Pocket's PLL gives the core `clk_sys` at **96 MHz** and `clk_vid` at
**8 MHz, exactly `clk_sys` / 12**, which is the clock the Pocket's RGB pins
are driven from.

**Smash T.V.'s dot clock is 8.000 MHz exactly** — the TMS34010's 4 MHz pixel
clock at two pixels per clock. So the core's dot rate, the Pocket's video
clock and the board's dot clock are the same number, and the raster can be the
board's own:

| | board | core |
|---|---|---|
| dot clock | 8.000 MHz | 8.000 MHz (`clk_sys` / 12) |
| line | 506 dots, 63.25 µs | the same |
| frame | 289 lines, 18.279 ms | the same |
| refresh | 54.7069 Hz | the same |
| visible | 410 × 256 | the same |

No resampling, no invented raster totals, and nothing for the aspect-ratio
trap of METHODOLOGY §5.5 to catch — the game is `ROT0`, so `video.json` says
`4:3` the intuitive way round.

The rest of the enables, from 96 MHz:

| enable | rate | divider | exact? |
|---|---|---|---|
| dot | 8 MHz | ÷ 12 | **yes** |
| MC6809E | 2.000 MHz | ÷ 48 | **yes** |
| TMS34010 machine state | 5.000 MHz | ÷ 19.2 | no — fractional accumulator |
| YM2151 | 3.579545 MHz | ÷ 26.82 | no — fractional accumulator |
| blitter pixel | 24.39 MHz (41 ns) | ÷ 3.936 | no — fractional accumulator |

The two that matter are exact. The 6809's rate **is** the CVSD's sample rate
(`docs/hardware.md` §1), so it gets an exact divider and a memory that never
stalls it. The TMS34010's rate only affects game speed, and the game is paced
by the display interrupt, so a fractional enable with one system clock of
jitter (10.4 ns on a 200 ns period) is invisible; an 80 MHz system clock would
make it exact but would slow the SDRAM and move the capture phase the SDC is
tuned for (METHODOLOGY §5.20), which is not worth it.

`pause` freezes the divider and masks the CPU and sound enables with the same
term; the dot divider keeps running so the picture stays up behind the
Pocket's menu (METHODOLOGY §5.5). **The board's watchdog counts wall-clock
time and would expire** while the menu is open — see `docs/hardware.md` §10
item 5.

---

## 2. Where everything lives

The whole machine is 4.9 MB of state and the Pocket has 32 MB of SDRAM,
256 KB of SRAM and ~3,080 Kbit of block RAM. The interesting question is not
capacity, it is which memory each thing needs to be in.

| what | size | where | why |
|---|---|---|---|
| program ROM | 256 KB | SDRAM word 0x000000 | read by one client, cachable |
| sound ROM | 192 KB | SDRAM word 0x020000 | **behind a cache**; the 6809 must never stall |
| graphics ROM | 1.5 MB | SDRAM word 0x100000 | read sequentially, in bursts |
| frame buffer rows 0-255 | 2.0 Mbit | **block RAM** | one write per blitter pixel and one read per displayed pixel; see §3 |
| frame buffer rows 510-511 | 16 Kbit | **block RAM** | the autoerase templates, read once per line |
| frame buffer rows 256-509 | 254 KB | SDRAM word 0x400000 (bank 1) | *(measured)* only the power-up RAM test and one blit in 90 seconds touch these |
| main RAM | 128 KB | **Pocket SRAM** word 0x00000 | ≤ 5 M accesses/s against a port that does 13.7 M reads/s |
| CMOS | 32 KB | **Pocket SRAM** word 0x10000 | rarely touched; battery-backed on the board, an APF save slot here |
| palette | 4096 × 16 | block RAM | one read per displayed pixel |
| sound RAM | 2 KB | block RAM | |

Block RAM: 132,096 words of frame buffer + 4,096 of palette + 2 KB of sound
RAM. In M10K blocks at 16 bits wide (512 words each) that is **258 + 8 + 2 =
268 of the 5CEBA4's 308**, 87%. That is the design's main risk and the first
full fit is the measurement that settles it; if it does not fit, the fallback
is §3's option B, which costs bandwidth instead of blocks.

---

## 3. The frame buffer, and why it is not in SDRAM

This is the one real architectural decision, so here is the arithmetic.

The blitter's worst frame *(measured over a 90-second run through boot,
attract and a played game: frame 1827)* is **306,506 source pixels in 173
blits**. At the board's 41 ns per pixel that is 12.57 ms of an 18.279 ms
frame — **69% of the frame, with 45% headroom before the worst frame
overruns**. Per frame the core has 1,754,784 clocks of `clk_sys`.

Per blitter pixel the work is one frame-buffer write and, since one 32-bit
image word carries four pixels, half an SDRAM word of graphics read.

**Option A — frame buffer in block RAM (chosen).** Blitter writes and scanout
reads go to a true dual-port RAM, one clock each and never contending.
Autoerase is a row copy from a template row held in the same RAM.

| consumer | clocks per frame | share of SDRAM |
|---|---|---|
| graphics reads, 0.5 words/pixel at 2 clocks | 306,506 | 17.5% |
| CPU program fetches (estimated, no cache) | ~312,000 | 17.8% |
| CPU graphics-window reads *(measured 479 words/frame)* | 4,311 | 0.2% |
| refresh, every 750 clocks | ~21,000 | 1.2% |
| | | **37%** |

**Option B — frame buffer in SDRAM (fallback).** The controller's burst
delivers one 16-bit word every two clocks, so a pixel costs two clocks of
frame-buffer write plus one of graphics read: three clocks, 31 ns.

| consumer | clocks per frame | share of SDRAM |
|---|---|---|
| blits, 3 clocks/pixel | 919,518 | 52.4% |
| scanout, 410 words × 256 lines at 2 clocks | 209,920 | 12.0% |
| autoerase, 512 writes × 256 lines at 2 clocks (template cached) | 262,144 | 14.9% |
| CPU program fetches (estimated) | ~312,000 | 17.8% |
| refresh | ~21,000 | 1.2% |
| | | **98.5%** |

Option B is over before the CPU's data accesses are counted, and it has no
margin for the row changes and bank conflicts the table ignores. It only
becomes comfortable if the SDRAM controller learns a true burst of one word
per clock, which is a change to a module that is proven on hardware and would
need `sim/run_mem.sh` extended to cover it. **That is the escape route if
option A does not fit, in that order: try the fit first.**

Both options need the same thing said about them: the blitter is **rate
limited to the board's 41 ns per pixel** rather than run as fast as the memory
allows. Nothing in the game should care — it polls the done bit or takes INT1
— but matching the board costs one counter and removes a whole class of "it
behaves differently from MAME and I do not know why".

The blitter never reads its destination (`docs/hardware.md` §7.3), so there is
no read-modify-write path and transparency is a write mask, not a read.

---

## 4. The shared ports, and their acks

METHODOLOGY §5.17 cost a core a released build: an untagged ack on a shared
port. Every shared port here latches its owner at grant and routes the
response by that latch, and every one gets a coincidence counter in the bench
— a checker that fires when one client's request rises on the clock another
client's ack is asserted. **Zero is not the expected answer; surviving it is.**

| port | clients |
|---|---|
| frame buffer (block RAM) | blitter write, scanout read, autoerase, CPU read/write |
| SDRAM random | download, CPU program, CPU graphics window, frame-buffer rows 256-509 |
| SDRAM burst | blitter graphics fetch |
| Pocket SRAM | CPU main RAM, CPU CMOS |

---

## 5. What the Pocket shows and reads

- **Video**: 410 × 256 at 54.7069 Hz, `ROT0`. `video.json` gets the raster
  above; the aspect ratio is `4:3` and is *not* transposed, because there is
  no rotation (METHODOLOGY §5.5).
- **Controls**: Smash T.V. is a **twin-stick** game — the left stick moves and
  the right stick fires, both 8-way (`docs/hardware.md` §3). On a Pocket the
  d-pad is the move stick and the four face buttons are the fire directions:
  Up = fire up, Down (B) = fire down, Left (Y) = fire left, Right (A) = fire
  right. Diagonal fire needs two buttons, which is what the arcade stick does
  anyway. The d-pad is **not** listed in `input.json` (METHODOLOGY §5.5) — the
  core reads it from `cont1_key` regardless, and listing it puts blank rows in
  the Pocket's controls menu.
- **Menu**: the DIP bank is *not* transcribed whole. `docs/hardware.md` §3
  says the coinage switches are read only by a full factory restore, and the
  rest of both banks is unknown. So the menu offers the test switch and
  nothing else until something is shown to do something (METHODOLOGY §5.5,
  "every menu entry is a claim that the gateware does something").
- **Audio**: one mono channel, YM2151 + DAC + CVSD mixed at MAME's weights
  (`docs/hardware.md` §6). It crosses into the Pocket's audio domain through
  the 48 kHz hold and toggle hand-over in `core_top.sv` — METHODOLOGY §5.4,
  which is the most expensive bug in this document's history.

---

## 6. Order of building, and what checks each part

| part | checked by |
|---|---|
| blitter, frame buffer, scanout | `sim/run_video.sh`: the RTL loaded with a frozen state, fed the same trace, diffed against `tools/render_model.py` — zero differing palette indices |
| TMS34010 | a bus trace against MAME, transaction by transaction, and per-instruction cycle counts (METHODOLOGY §4, the pattern `rtl/i8085.sv` was built on) |
| the whole machine, ideal memories | frames against MAME |
| the whole machine, real memory glue | `sim/run_pocket.sh` — **before the first flash** (METHODOLOGY §5.16) |
| sound | band energy per second against a MAME recording, over a whole capture in play (METHODOLOGY §5.9) |

---

## 7. What is not built, and why that is safe

From `docs/hardware.md` §9, each of these is left out because the program is
measured never to use it. Each needs re-checking before it is left out for
good:

- window checking and the window-violation interrupt (CONTROL bits 7-6 are 0);
- plane masking (PMASK is 0);
- raster ops (CONTROL bits 14-10 are 0);
- the host interface (written twice with 0 at reset, never again);
- shift-register transfers through the CPU (DPYCTL bit 11 is 0) — the
  autoerase is what uses the VRAM shift registers, and it is built;
- interlace (DPYCTL bit 14 is 1);
- the protection PLD (`init_smashtv` disables it);
- input ports IN2, UNK0 and UNK1 (never read).
