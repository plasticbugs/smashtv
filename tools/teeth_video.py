#!/usr/bin/env python3
"""Measure what the video gate can and cannot catch.

A gate that passes proves nothing until you know it can fail.  This breaks the
reference renderer in one specific way at a time and reports how many pixels
each break costs across every captured window.  A row reading 0 is a statement
about the captures, not about the renderer: it means nothing in them exercises
that piece of the machine, and it has to be written down as unverified
(METHODOLOGY section 5.10).

Usage:
    tools/teeth_video.py [states-dir] [image.rom]
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import render_model as R


def total(windows, gfx, nframes=16):
    """Sum of differing pixels over every frame of every window."""
    out = 0
    for name, d in windows:
        states = sorted(f for f in os.listdir(d) if f.startswith('state_'))
        st = R.State(os.path.join(d, states[0]))
        tr = R.read_trace(os.path.join(d, 'trace.bin'))
        for frame, rows, pen in R.replay(st, tr, gfx, nframes):
            p = os.path.join(d, f'mame_{frame:05d}.png')
            if not os.path.exists(p):
                continue
            bad, _ = R.compare(R.to_rgb(rows, pen), R.mame_rgb(p))
            out += bad
    return out


def main():
    args = sys.argv[1:]
    sdir = args[0] if args else 'ref/states'
    image = args[1] if len(args) > 1 else '.build/smashtv.rom'
    windows = sorted((n, os.path.join(sdir, n)) for n in os.listdir(sdir)
                     if os.path.isfile(os.path.join(sdir, n, 'trace.bin')))
    if not windows:
        sys.exit(f'no captures in {sdir}; run tools/dump_states.sh')
    gfx = R.load_gfx(image)
    print(f'{len(windows)} windows: ' + ', '.join(n for n, _ in windows))

    rows = []

    def measure(label, setup, teardown, use=None):
        setup()
        try:
            rows.append((label, total(windows, use if use is not None else gfx)))
        finally:
            teardown()

    measure('unmodified', lambda: None, lambda: None)

    pen = R.PEN[:]

    def bad_pen():
        R.PEN = [i & 0x0F3F for i in range(65536)]

    measure('pen map drops palette bits 7-6', bad_pen,
            lambda: setattr(R, 'PEN', pen))

    def pen_pixel_only():
        R.PEN = [i & 0x003F for i in range(65536)]

    measure('pen map drops the palette entirely', pen_pixel_only,
            lambda: setattr(R, 'PEN', pen))

    for lag in (20, 22):
        measure(f'autoerase lag {lag} instead of 21',
                (lambda l=lag: setattr(R, 'ERASE_LAG', l)),
                lambda: setattr(R, 'ERASE_LAG', 21))

    ae = R.autoerase_row
    measure('autoerase removed',
            lambda: setattr(R, 'autoerase_row', lambda fb, row: None),
            lambda: setattr(R, 'autoerase_row', ae))

    def flip_parity():
        def f(fb, row):
            if 0 <= row < 510:
                s = (510 + ((row + 1) & 1)) * R.FB_COLS
                fb[row * R.FB_COLS:row * R.FB_COLS + R.FB_COLS] = fb[s:s + R.FB_COLS]
        R.autoerase_row = f

    measure('autoerase template rows swapped', flip_parity,
            lambda: setattr(R, 'autoerase_row', ae))

    blit = R.blit

    def flipy():
        def f(fb, g, reg):
            if (reg[R.COMMAND] & 0x8020) == 0x8020:
                r = list(reg)
                r[R.YSTART] = (R.s16(reg[R.YSTART]) + reg[R.HEIGHT] - 1) & 0xFFFF
                return blit(fb, g, r)
            return blit(fb, g, reg)
        R.blit = f

    measure('command bit 5 taken as a real flip-y', flipy,
            lambda: setattr(R, 'blit', blit))

    def noflipx():
        def f(fb, g, reg):
            r = list(reg)
            r[R.COMMAND] = reg[R.COMMAND] & ~0x10
            return blit(fb, g, r)
        R.blit = f

    measure('flip-x ignored', noflipx, lambda: setattr(R, 'blit', blit))

    scan = R.scan_row
    measure('scanout one row off',
            lambda: setattr(R, 'scan_row', lambda fb, row: scan(fb, (row + 1) & 0x1FF)),
            lambda: setattr(R, 'scan_row', scan))

    cpu = R.cpu_fb_write
    measure('CPU frame-buffer writes use the wrong plane',
            lambda: setattr(R, 'cpu_fb_write',
                            lambda fb, o, d, m, vb, p: cpu(fb, o, d, m, 1 - vb, p)),
            lambda: setattr(R, 'cpu_fb_write', cpu))

    # the graphics themselves, not a function to be patched: the swap has to
    # be handed to the replay, or the row reads 0 and says nothing
    swapped = bytes(((b & 0x03) << 4) | (b & 0x0C) | ((b >> 4) & 0x03) for b in gfx)
    measure('graphics planes 0 and 2 swapped',
            lambda: None, lambda: None, use=swapped)
    shifted = bytes(((b << 1) | (b >> 5)) & 0x3F for b in gfx)
    measure('graphics pixel bits rotated by one',
            lambda: None, lambda: None, use=shifted)

    width = max(len(r[0]) for r in rows)
    blind = []
    for label, n in rows:
        note = ''
        if label != 'unmodified' and n == 0:
            note = '   <-- the captures do not exercise this'
            blind.append(label)
        print(f'  {label:<{width}}  {n:9d} pixels{note}')
    if rows[0][1] != 0:
        print('FAIL  the unmodified renderer does not match MAME')
        return 1
    if blind:
        print(f'{len(blind)} break(s) the captures cannot see; '
              f'they are unverified, not correct')
    return 0


if __name__ == '__main__':
    sys.exit(main())
