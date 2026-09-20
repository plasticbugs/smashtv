#!/usr/bin/env python3
"""Hold a CPU to MAME one bus transaction at a time.

    tools/diff_bus.py <mame.bin> <rtl.bin> [-n N] [-skip N]
    tools/diff_bus.py --selftest <mame.bin>

Both files are what tools/bus_trace.lua writes: 16 bytes per transaction,
`u32 index, u32 addr, u16 data, u16 mask, u8 write, u8 region, u16 pad`.
The comparison stops at the first transaction that differs and prints the ten
before it, because the instruction that caused a divergence is almost never
the one that shows it (METHODOLOGY section 4).

Two things to know before believing a mismatch, both from METHODOLOGY:

  * MAME does not perform the operand reads of a conditional jump it does not
    take, so a CPU that does will diverge on a fetch that is not a fault.
  * anything the program *polls* -- a vblank bit, the blitter's busy bit, an
    input -- will eventually sample differently, and from there the two
    traces are incomparable.  `--selftest` and the region report are there so
    that is visible rather than argued about.

The trace starts a few transactions after reset: MAME reads the reset vector
inside device_reset(), before an autoboot script can install a tap.  So the
first address in the file is wherever the program had got to, and an RTL trace
has to be aligned to it -- `-skip` does that.
"""
import struct
import sys
from collections import Counter

REC = struct.Struct('<IIHHBBH')
NAMES = {0: 'framebuffer', 1: 'mainram', 2: 'cmos', 3: 'palette',
         4: 'blitter', 5: 'inputs', 6: 'sound', 7: 'control',
         8: 'gfxrom', 9: 'progrom', 10: 'ioregs', 11: 'other'}


def load(path, limit=None):
    d = open(path, 'rb').read()
    n = len(d) // REC.size
    if limit:
        n = min(n, limit)
    return [REC.unpack_from(d, i * REC.size) for i in range(n)]


def fmt(t):
    _, addr, data, mask, write, region, _pad = t
    return (f'{"W" if write else "R"} {addr:#010x} {data:#06x} '
            f'mask {mask:#06x}  {NAMES.get(region, "?")}')


def same(a, b):
    # index and pad are bookkeeping; the transaction is the rest
    return a[1:6] == b[1:6]


def report(mame, rtl, skip=0):
    rtl = rtl[skip:]
    n = min(len(mame), len(rtl))
    for i in range(n):
        if not same(mame[i], rtl[i]):
            print(f'diverges at transaction {i} '
                  f'(RTL index {rtl[i][0]}, MAME index {mame[i][0]})')
            lo = max(0, i - 10)
            for k in range(lo, i):
                print(f'  {k:8d}  {fmt(mame[k])}')
            print(f'  {i:8d}  MAME {fmt(mame[i])}')
            print(f'  {i:8d}  RTL  {fmt(rtl[i])}')
            return 1
    print(f'{n} transactions identical')
    if len(mame) != len(rtl):
        print(f'  (MAME has {len(mame)}, the RTL {len(rtl)}; '
              f'compared the shorter)')
    c = Counter(NAMES.get(t[5], '?') for t in mame[:n])
    print('  by region: ' + ', '.join(f'{k} {v}' for k, v in c.most_common()))
    return 0


def selftest(path):
    """The differ has to be able to fail.  Compare a trace with itself, then
    with copies perturbed one field at a time."""
    t = load(path, 20000)
    if len(t) < 100:
        sys.exit(f'{path}: only {len(t)} transactions, need at least 100')
    ok = True

    print('identical:')
    if report(t, list(t)) != 0:
        ok = False

    cases = [
        ('one data word changed', 2, lambda v: v ^ 1),
        ('one address changed', 1, lambda v: v ^ 0x10),
        ('one mask changed', 3, lambda v: v ^ 0x00ff),
        ('read turned into a write', 4, lambda v: 1 - v),
    ]
    for label, field, f in cases:
        bad = list(t)
        k = len(bad) // 2
        r = list(bad[k])
        r[field] = f(r[field])
        bad[k] = tuple(r)
        print(f'{label} at {k}:')
        if report(t, bad) == 0:
            print('  MISSED')
            ok = False

    print('one transaction dropped:')
    bad = t[:len(t) // 2] + t[len(t) // 2 + 1:]
    if report(t, bad) == 0:
        print('  MISSED')
        ok = False

    print('OK: the differ catches every perturbation' if ok
          else 'FAIL: the differ missed something')
    return 0 if ok else 1


def main():
    args = sys.argv[1:]
    if args and args[0] == '--selftest':
        if len(args) != 2:
            sys.exit(__doc__)
        return selftest(args[1])
    limit = skip = 0
    if '-n' in args:
        i = args.index('-n'); limit = int(args[i + 1], 0); del args[i:i + 2]
    if '-skip' in args:
        i = args.index('-skip'); skip = int(args[i + 1], 0); del args[i:i + 2]
    if len(args) != 2:
        sys.exit(__doc__)
    return report(load(args[0], limit or None), load(args[1], None), skip)


if __name__ == '__main__':
    sys.exit(main())
