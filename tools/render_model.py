#!/usr/bin/env python3
"""The reference renderer: the Y-unit's video semantics, in Python.

This is the executable specification the video RTL is written against and
checked against (METHODOLOGY section 1).  It carries four things:

  blit        the blitter's sixteen commands, clipping, flips and source
              addressing, from `dma_w` and `dma_draw` in
              ref/mame/mame/midway/midyunit_v.cpp.
  scanout     frame-buffer row -> 410 palette indices -> RGB, through the
              6-bit pen map.
  autoerase   row r overwritten from template row 510 + (r & 1), one line
              behind the beam.
  replay      all of the above interleaved with a trace of register writes
              taken from MAME, line by line, which is the only way to
              reproduce this game: it races the beam, so no single instant
              holds a whole picture.  Measured: a frame-done freeze matches
              MAME exactly on rows 0-133 and 252-255 and differs on every
              pixel of rows 134-251.

Usage:
    tools/render_model.py <dir> <image.rom> [-o outdir] [-v]

        `dir` holds what tools/dump_state.lua wrote: state_NNNNN.bin,
        trace.bin and pic_NNNNN.bin.  Replays the trace from the state and
        compares every frame with MAME's own picture.  Exit status is the
        number of frames that differ.

    tools/render_model.py <state.bin> [-o out.png]

        render that one frozen state, with no replay.
"""
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pngio

# --- the machine's shapes, from docs/hardware.md -----------------------------
FB_ROWS, FB_COLS = 512, 512          # frame buffer, pixels
VIS_W, VIS_H = 410, 256              # visible picture
PAL_ENTRIES = 4096                   # 6 bits of pixel, 6 of palette
FIRST_VIS_LINE = 20                  # VEBLNK
LAST_VIS_LINE = 275                  # VSBLNK - 1
ERASE_LAG = 21                       # row r is erased at line r + 21
LINE_ORDER = list(range(LAST_VIS_LINE + 1, 289)) + list(range(0, LAST_VIS_LINE + 1))
GFX_BASE_IN_IMAGE = 0x070000         # see smashtv.mra

# The blitter register file, by index (docs/hardware.md 7.3)
COMMAND, ROWBYTES, OFFSETLO, OFFSETHI, XSTART, YSTART, WIDTH, HEIGHT, \
    PALETTE, COLOR = range(10)


def pen6(entry):
    """Frame-buffer entry -> palette index, 6 bpp.

    midyunit_v.cpp: pen_map[i] = ((i & 0xc000) >> 8) | (i & 0x0f3f), i.e.
    { palette[3:0], palette[7:6], pixel[5:0] } out of { palette, pixel }.
    """
    return ((entry & 0xC000) >> 8) | (entry & 0x0F3F)


PEN = [pen6(i) for i in range(65536)]


def pal5(v):
    """MAME's pal5bit: 5 bits to 8 by bit replication."""
    v &= 0x1F
    return (v << 3) | (v >> 2)


def rgb_of(word):
    """Palette word xRRRRRGGGGGBBBBB -> (r, g, b)."""
    return pal5(word >> 10), pal5(word >> 5), pal5(word)


def s16(v):
    return v - 0x10000 if v & 0x8000 else v


# --- the graphics ROM --------------------------------------------------------
def load_gfx(image_path):
    """The .rom image's graphics region -> one byte per pixel, 6 bits used.

    Image word k holds pixels 4k..4k+3 as three plane-pair bytes; pixel 4k+j
    takes field 2j of each.  smashtv.mra's comment has the packing and
    tools/verify_rom.py proves it against MAME.
    """
    d = open(image_path, 'rb').read()
    g = d[GFX_BASE_IN_IMAGE:]
    n = len(g) // 4
    out = bytearray(4 * n)
    for k in range(n):
        c0, c1, c2 = g[4 * k], g[4 * k + 1], g[4 * k + 2]
        o = 4 * k
        out[o] = (c0 & 3) | ((c1 & 3) << 2) | ((c2 & 3) << 4)
        out[o + 1] = ((c0 >> 2) & 3) | (((c1 >> 2) & 3) << 2) | (((c2 >> 2) & 3) << 4)
        out[o + 2] = ((c0 >> 4) & 3) | (((c1 >> 4) & 3) << 2) | (((c2 >> 4) & 3) << 4)
        out[o + 3] = ((c0 >> 6) & 3) | (((c1 >> 6) & 3) << 2) | (((c2 >> 6) & 3) << 4)
    return bytes(out)


# --- a frozen state ----------------------------------------------------------
class State:
    MAGIC = b'STVS'
    VERSION = 3

    def __init__(self, path):
        d = open(path, 'rb').read()
        if d[:4] != self.MAGIC:
            raise ValueError(f'{path}: not a state dump')
        ver, self.frame = struct.unpack_from('<II', d, 4)
        if ver != self.VERSION:
            raise ValueError(f'{path}: version {ver}, expected {self.VERSION}')
        o = 12
        self.ctrl, = struct.unpack_from('<H', d, o); o += 2
        self.dma = list(struct.unpack_from('<16H', d, o)); o += 32
        n = FB_ROWS * FB_COLS
        self.fb = list(struct.unpack_from(f'<{n}H', d, o)); o += 2 * n
        self.pen = list(struct.unpack_from(f'<{PAL_ENTRIES}H', d, o))


# --- the blitter -------------------------------------------------------------
def blit(fb, gfx, reg):
    """Run one blit into `fb`.  Returns the source pixels it covers unclipped,
    which is what MAME charges 41 ns each for.  dma_w then dma_draw."""
    command = reg[COMMAND]
    if not (command & 0x8000):
        return 0

    rowbytes = s16(reg[ROWBYTES])
    xpos = s16(reg[XSTART])
    ypos = s16(reg[YSTART])
    width = reg[WIDTH]
    height = reg[HEIGHT]
    palette = (reg[PALETTE] << 8) & 0xFFFF
    color = palette | (reg[COLOR] & 0xFF)
    cost = width * height

    gfxoffset = reg[OFFSETLO] | (reg[OFFSETHI] << 16)
    dx = -1 if (command & 0x10) else 1
    if command & 0x10:
        gfxoffset = (gfxoffset - (width - 1) * 8) & 0xFFFFFFFF
        rowbytes = (rowbytes - width + 3) & ~3
        xpos += width - 1
    else:
        rowbytes = (rowbytes + width + 3) & ~3

    offset = 0                       # extra bit offset from clipping
    if ypos < 0:
        height -= -ypos
        offset += (-ypos * rowbytes) << 3
        ypos = 0
    if ypos + height > FB_ROWS:
        height = FB_ROWS - ypos

    if not (command & 0x10):
        if xpos < 0:
            width -= -xpos
            offset += -xpos << 3
            xpos = 0
        if xpos + width > FB_COLS:
            width = FB_COLS - xpos
    else:
        if xpos >= FB_COLS:
            width -= xpos - (FB_COLS - 1)
            offset += (xpos - (FB_COLS - 1)) << 3
            xpos = FB_COLS - 1
        if xpos - width < 0:
            width = xpos

    if gfxoffset < 0x02000000:
        gfxoffset += 0x02000000
    src = ((gfxoffset - 0x02000000) + offset) >> 3       # in pixels

    op = command & 0x0F
    if op == 0 or width <= 0 or height <= 0:
        return cost
    ngfx = len(gfx)

    for y in range(height):
        o = src
        ty = (ypos + y) & 0x1FF
        src += rowbytes
        row = ty * FB_COLS
        tx = row + xpos                                  # absolute, steps by dx
        end = o + width
        if op == 0x02:                                   # the common case
            while o < end:
                p = gfx[o] if o < ngfx else 0
                if p:
                    fb[tx] = palette | p
                o += 1
                tx += dx
        elif op == 0x03:
            while o < end:
                fb[tx] = palette | (gfx[o] if o < ngfx else 0)
                o += 1
                tx += dx
        elif op in (0x0C, 0x0D, 0x0E, 0x0F):
            while o < end:
                fb[tx] = color
                o += 1
                tx += dx
        elif op in (0x08, 0x0A):
            while o < end:
                if (gfx[o] if o < ngfx else 0):
                    fb[tx] = color
                o += 1
                tx += dx
        elif op == 0x01:
            while o < end:
                if not (gfx[o] if o < ngfx else 0):
                    fb[tx] = palette
                o += 1
                tx += dx
        elif op in (0x04, 0x05):
            while o < end:
                if not (gfx[o] if o < ngfx else 0):
                    fb[tx] = color
                o += 1
                tx += dx
        elif op in (0x06, 0x07):
            while o < end:
                p = gfx[o] if o < ngfx else 0
                fb[tx] = color if p == 0 else (palette | p)
                o += 1
                tx += dx
        else:                                            # 0x09, 0x0B
            while o < end:
                p = gfx[o] if o < ngfx else 0
                fb[tx] = color if p else (palette | p)
                o += 1
                tx += dx
    return cost


# --- scanout and autoerase ---------------------------------------------------
def scan_row(fb, row):
    """Frame-buffer row -> VIS_W palette indices.

    Visible line n shows row n-20, columns 0..409: DPYADR counts down from
    DPYSTRT by DUDATE and get_display_params inverts it because ORG is 0,
    which comes out as row = line - VEBLNK; and coladdr works out to 0 on
    this game.  docs/hardware.md 7.4.
    """
    base = row * FB_COLS
    return [PEN[e] for e in fb[base:base + VIS_W]]


def autoerase_row(fb, row):
    """Copy template row 510 + (row & 1) over `row`.  docs/hardware.md 7.4."""
    if 0 <= row < 510:
        s = (510 + (row & 1)) * FB_COLS
        fb[row * FB_COLS:row * FB_COLS + FB_COLS] = fb[s:s + FB_COLS]


def cpu_fb_write(fb, word_offset, data, mask, videobank, dma_palette):
    """A CPU write through the VRAM window.  docs/hardware.md 7.2."""
    o = 2 * word_offset
    if videobank:
        if mask & 0x00FF:
            fb[o] = ((dma_palette & 0xFF) << 8) | (data & 0xFF)
        if mask & 0xFF00:
            fb[o + 1] = (dma_palette & 0xFF00) | ((data >> 8) & 0xFF)
    else:
        if mask & 0x00FF:
            fb[o] = (fb[o] & 0x00FF) | ((data & 0xFF) << 8)
        if mask & 0xFF00:
            fb[o + 1] = (fb[o + 1] & 0x00FF) | (data & 0xFF00)


# --- the trace ---------------------------------------------------------------
EVENT = struct.Struct('<IHHBBIHH')
K_DMA, K_FB, K_PAL, K_CTRL = 0, 1, 2, 3


def read_trace(path):
    """-> {frame: [ (vpos, seq, kind, reg, addr, data, mask), ... ]} in order."""
    d = open(path, 'rb').read()
    by = {}
    for f, v, s, k, r, a, dt, m in EVENT.iter_unpack(d):
        by.setdefault(f, []).append((v, s, k, r, a, dt, m))
    return by


def replay(state, trace, gfx, nframes):
    """Replay `nframes` pictures after state.frame.  Yields (frame, indices,
    pens) where `indices` is VIS_H lists of VIS_W palette indices."""
    fb = state.fb
    reg = list(state.dma)
    pen = list(state.pen)
    ctrl = state.ctrl

    for i in range(nframes):
        f = state.frame + i                  # events tagged f compose picture f+1
        events = trace.get(f, [])
        ei = 0
        rows = []
        # A frame's worth of lines as MAME orders them.  Measured: the frame
        # notifier fires with VCOUNT == 275 on every frame of a 329-frame run,
        # i.e. at the start of vertical blank -- so the window that composes
        # picture f+1 runs from line 276 round to line 275.
        for line in LINE_ORDER:
            # what the scanline callback does for this line, in its order
            if FIRST_VIS_LINE <= line <= LAST_VIS_LINE:
                rows.append(scan_row(fb, line - FIRST_VIS_LINE))
            # autoerase runs one line behind the beam, from inside the same
            # scanline update, and once more from a timer at VSBLNK for the
            # last row -- so only over lines 20..276, never in the rest of
            # vertical blank.
            if (not (ctrl & 0x10)) and FIRST_VIS_LINE <= line <= LAST_VIS_LINE + 1:
                autoerase_row(fb, line - ERASE_LAG)
            # then the CPU runs until the next line
            while ei < len(events) and events[ei][0] == line:
                _, _, kind, r, addr, data, mask = events[ei]
                ei += 1
                if kind == K_DMA:
                    reg[r] = (reg[r] & ~mask) | (data & mask)
                    if r == COMMAND:
                        blit(fb, gfx, reg)
                elif kind == K_FB:
                    cpu_fb_write(fb, addr, data, mask,
                                 (ctrl >> 5) & 1, reg[PALETTE])
                elif kind == K_PAL:
                    pen[addr] = (pen[addr] & ~mask) | (data & mask)
                elif kind == K_CTRL:
                    ctrl = (ctrl & ~mask) | (data & mask)
        # events that landed outside 0..288 (there should be none)
        while ei < len(events):
            ei += 1
        yield f + 1, rows, list(pen)
    replay.fb = fb          # the frame buffer the replay ended with


# --- comparing with MAME -----------------------------------------------------
def to_rgb(rows, pen):
    lut = bytearray(PAL_ENTRIES * 3)
    for i in range(PAL_ENTRIES):
        r, g, b = rgb_of(pen[i])
        lut[3 * i] = r; lut[3 * i + 1] = g; lut[3 * i + 2] = b
    out = bytearray(VIS_W * VIS_H * 3)
    k = 0
    for row in rows:
        for p in row:
            p *= 3
            out[k] = lut[p]; out[k + 1] = lut[p + 1]; out[k + 2] = lut[p + 2]
            k += 3
    return bytes(out)


def mame_rgb(path):
    """MAME's own picture for a frame.

    A PNG written by screen:snapshot(), not screen:pixels().  Measured, at the
    same instant on the same frame: pixels() gives a bitmap one frame older,
    because MAME double-buffers the screen and pixels() reads the buffer that
    is not being drawn into.  Compared against pixels(), a correct renderer
    looks exactly one frame ahead wherever something moves and exactly right
    on every still screen -- which is the shape of an instrument fault
    (METHODOLOGY 5.1), and was one.
    """
    w, h, rgb = pngio.read(path)
    if (w, h) != (VIS_W, VIS_H):
        raise ValueError(f'{path}: {w}x{h}, expected {VIS_W}x{VIS_H}')
    return rgb


def compare(mine, theirs):
    """-> (differing pixels, first differing row)"""
    bad, first = 0, None
    for y in range(VIS_H):
        o = y * VIS_W * 3
        for x in range(VIS_W):
            i = o + 3 * x
            if mine[i:i + 3] != theirs[i:i + 3]:
                bad += 1
                if first is None:
                    first = y
    return bad, first


def main():
    args = list(sys.argv[1:])
    outdir = None
    verbose = False
    if '-o' in args:
        i = args.index('-o'); outdir = args[i + 1]; del args[i:i + 2]
    if '-v' in args:
        args.remove('-v'); verbose = True

    if len(args) == 1 and args[0].endswith('.bin'):
        st = State(args[0])
        rows = [scan_row(st.fb, y) for y in range(VIS_H)]
        rgb = to_rgb(rows, st.pen)
        print(f'frame {st.frame}: ctrl {st.ctrl:04x}')
        if outdir:
            pngio.write(outdir, VIS_W, VIS_H, rgb)
            print(f'  wrote {outdir}')
        return 0

    if len(args) != 2:
        sys.exit(__doc__)
    d, image = args[0].rstrip('/'), args[1]

    states = sorted(f for f in os.listdir(d) if f.startswith('state_'))
    if not states:
        sys.exit(f'no state_*.bin in {d}')
    st = State(os.path.join(d, states[0]))
    trace = read_trace(os.path.join(d, 'trace.bin'))
    gfx = load_gfx(image)
    pics = sorted(f for f in os.listdir(d) if f.startswith('mame_'))
    nframes = len(pics) - 1
    print(f'replaying {nframes} frames from {st.frame}, '
          f'{sum(len(v) for v in trace.values())} events, '
          f'{len(gfx)} graphics pixels')

    worst = 0
    failed = 0
    end_state = None
    ends = [f for f in states if f != states[0]]
    if ends:
        end_state = State(os.path.join(d, ends[-1]))
    for frame, rows, pen in replay(st, trace, gfx, nframes):
        pic = os.path.join(d, f'mame_{frame:05d}.png')
        if not os.path.exists(pic):
            continue
        mine = to_rgb(rows, pen)
        theirs = mame_rgb(pic)
        bad, first = compare(mine, theirs)
        worst = max(worst, bad)
        if bad:
            failed += 1
        print(f'  frame {frame}: {bad:6d} of {VIS_W*VIS_H} pixels differ'
              + (f', first at row {first}' if bad else ''))
        if outdir:
            os.makedirs(outdir, exist_ok=True)
            pngio.write(os.path.join(outdir, f'model_{frame:05d}.png'),
                        VIS_W, VIS_H, mine)
            if bad:
                dif = bytearray(len(mine))
                for i in range(0, len(mine), 3):
                    if mine[i:i + 3] != theirs[i:i + 3]:
                        dif[i] = 255; dif[i + 2] = 255
                pngio.write(os.path.join(outdir, f'diff_{frame:05d}.png'),
                            VIS_W, VIS_H, bytes(dif))
    if end_state is not None:
        mine, theirs = replay.fb, end_state.fb
        bad = sum(1 for i in range(len(mine)) if mine[i] != theirs[i])
        if bad:
            first = next(i for i in range(len(mine)) if mine[i] != theirs[i])
            print(f'  frame buffer at {end_state.frame}: {bad} of {len(mine)} '
                  f'entries differ, first at row {first // FB_COLS} '
                  f'col {first % FB_COLS} (model {mine[first]:04x}, '
                  f'MAME {theirs[first]:04x})')
        else:
            print(f'  frame buffer at {end_state.frame}: identical '
                  f'({len(mine)} entries)')
    print(f'{failed} of {nframes} frames differ; worst {worst} pixels')
    return failed


if __name__ == '__main__':
    sys.exit(main())
