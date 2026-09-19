#!/usr/bin/env python3
"""Check the .rom image the .mra builds against what MAME hands the chips.

MAME is the oracle for the ROM path too.  tools/dump_regions.lua writes out
three files -- the TMS34010's view of its program ROM, the decoded graphics
ROM as the blitter addresses it, and the three sound EPROMs -- and this undoes
the .mra's interleaving and compares byte for byte.  A mismatch here means the
core would be fed different bytes than the game expects, which is the cheapest
possible bug to find and the most expensive to find later.

The graphics check is the one worth having: the .mra packs three plane-pairs
into a 32-bit word and the core unpacks two bits at a time, and that
arithmetic is where a bit-plane order goes wrong (METHODOLOGY section 3,
"expect to get bit-plane order wrong once").  Here it is checked against
MAME's own `init_gfxrom(6)` output for all 1,572,864 pixels rather than
reasoned about.

Usage:
    tools/verify_rom.py <image.rom> <region_dir>

    REGION_DIR=/tmp/r tools/mame.sh -seconds_to_run 2 \\
        -autoboot_script tools/dump_regions.lua
"""
import sys

# The image layout.  Must match target/pocket/smashtv_mem.sv and sim/tb_mem.cpp.
PROG_BASE, PROG_LEN = 0x000000, 0x040000       # 131072 big-endian CPU words
SND_BASE,  SND_LEN  = 0x040000, 0x030000       # U4, U19, U20, 64 KB each
GFX_BASE,  GFX_LEN  = 0x070000, 0x180000       # 393216 words of four pixels
IMG_LEN             = GFX_BASE + GFX_LEN       # 2,031,616

GFX_PIXELS = GFX_LEN // 4 * 4                  # one pixel per plane-pair field


def fail(msg):
    print(f'FAIL: {msg}')
    sys.exit(1)


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    image = open(sys.argv[1], 'rb').read()
    d = sys.argv[2].rstrip('/')
    prog = open(f'{d}/prog.bin', 'rb').read()
    snd = open(f'{d}/snd.bin', 'rb').read()
    gfx = open(f'{d}/gfx.bin', 'rb').read()

    if len(image) != IMG_LEN:
        fail(f'image is {len(image)} bytes, expected {IMG_LEN}')

    # --- program.  dump_regions.lua read it a word at a time through the
    # CPU's own address space and wrote each word big-endian, which is the
    # order the image stores them in, so this is a straight compare.
    if len(prog) != PROG_LEN:
        fail(f'prog.bin is {len(prog)} bytes, expected {PROG_LEN}')
    if image[PROG_BASE:PROG_BASE + PROG_LEN] != prog:
        i = next(k for k in range(PROG_LEN) if image[PROG_BASE + k] != prog[k])
        fail(f'program differs at image 0x{PROG_BASE + i:06x} (CPU word '
             f'0x{0xffe00000 + (i // 2) * 16:08x}): image {image[PROG_BASE + i]:02x}, '
             f'MAME {prog[i]:02x}')
    print(f'  program   {PROG_LEN:8d} bytes  identical to the TMS34010\'s view')

    # --- sound.  Three 64 KB EPROMs end to end; the core turns a bank
    # register into {sel[1:0], half, a[14:0]} over exactly this.
    if len(snd) != SND_LEN:
        fail(f'snd.bin is {len(snd)} bytes, expected {SND_LEN}')
    if image[SND_BASE:SND_BASE + SND_LEN] != snd:
        i = next(k for k in range(SND_LEN) if image[SND_BASE + k] != snd[k])
        fail(f'sound differs at image 0x{SND_BASE + i:06x} '
             f'(U{[4, 19, 20][i // 0x10000]} offset 0x{i % 0x10000:04x})')
    print(f'  sound     {SND_LEN:8d} bytes  identical to MAME\'s cvsd:cpu region')

    # --- graphics.  Image word k carries four pixels, 4k..4k+3, as three
    # plane-pair bytes:  byte0 = bits 1-0, byte1 = bits 3-2, byte2 = bits 5-4,
    # each holding pixel 4k+j in its field 2j.  Rebuild every pixel and
    # compare with MAME's decoded array.
    if len(gfx) != GFX_PIXELS:
        fail(f'gfx.bin is {len(gfx)} bytes, expected {GFX_PIXELS}')
    img = image[GFX_BASE:GFX_BASE + GFX_LEN]
    for k in range(GFX_PIXELS // 4):
        c0, c1, c2 = img[4 * k], img[4 * k + 1], img[4 * k + 2]
        if img[4 * k + 3] != 0:
            fail(f'graphics word {k} (image 0x{GFX_BASE + 4 * k:06x}) has a '
                 f'non-zero fourth byte {img[4 * k + 3]:02x}; it is unused padding')
        for j in range(4):
            s = 2 * j
            px = ((c0 >> s) & 3) | (((c1 >> s) & 3) << 2) | (((c2 >> s) & 3) << 4)
            if px != gfx[4 * k + j]:
                fail(f'graphics differ at pixel {4 * k + j} '
                     f'(image 0x{GFX_BASE + 4 * k:06x} field {j}): '
                     f'image gives {px:02x}, MAME {gfx[4 * k + j]:02x}')
    print(f'  graphics  {GFX_PIXELS:8d} pixels identical to MAME\'s decoded gfx_rom')

    print('OK: the image carries exactly the bytes MAME feeds the chips')


if __name__ == '__main__':
    main()
