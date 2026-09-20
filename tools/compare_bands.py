#!/usr/bin/env python3
"""Second by second, band by band: the core's audio against MAME's.

    tools/compare_bands.py <mame.wav> <core.wav> [offset-seconds] [--selftest]

`offset-seconds` is where in MAME's recording the core's begins (the sound
bench can start part-way through).  For every whole second both recordings
cover it prints the RMS of each and, for five bands, the ratio of band
energies core/MAME; then the mean |log2 ratio| per band over the seconds in
which MAME is not silent, so that 0 means the same spectrum at the same level
(METHODOLOGY 5.9).

Every second is covered by all of its 4096-sample frames (Hann, half
overlapped) - METHODOLOGY 5.9 is about a band-energy function that looked at
one frame of each window.  `--selftest` checks the instrument on signals whose
answer is known before it is believed on anything else.

This compares spectra, not waveforms: two correct recordings of the same FM
voice differ in phase, and waveform correlation says nothing useful then.
"""
import cmath
import math
import struct
import sys

N = 4096
BANDS = [(40, 200), (200, 800), (800, 2500), (2500, 6000), (6000, 16000)]


def read_wav(path):
    d = open(path, 'rb').read()
    if d[:4] != b'RIFF' or d[8:12] != b'WAVE':
        sys.exit(f'{path}: not a WAV')
    i, fmt = 12, None
    while i + 8 <= len(d):
        cid = d[i:i + 4]
        n = struct.unpack('<I', d[i + 4:i + 8])[0]
        if cid == b'fmt ':
            fmt = struct.unpack('<HHIIHH', d[i + 8:i + 24])
        elif cid == b'data':
            body = d[i + 8:i + 8 + n]
            k = len(body) // 2
            s = struct.unpack(f'<{k}h', body[:2 * k])
            return list(s[::fmt[1]]), fmt[2]
        i += 8 + n + (n & 1)
    sys.exit(f'{path}: no data chunk')


_rev = None
_hann = [0.5 - 0.5 * math.cos(2 * math.pi * i / N) for i in range(N)]


def fft(x):
    global _rev
    n = len(x)
    if _rev is None:
        bits = n.bit_length() - 1
        _rev = [int(f'{i:0{bits}b}'[::-1], 2) for i in range(n)]
    a = [x[_rev[i]] for i in range(n)]
    size = 2
    while size <= n:
        half = size // 2
        w = [cmath.exp(-2j * math.pi * k / size) for k in range(half)]
        for s in range(0, n, size):
            for k in range(half):
                u, v = a[s + k], a[s + k + half] * w[k]
                a[s + k], a[s + k + half] = u + v, u - v
        size *= 2
    return a


def second_bands(s, rate, sec):
    """Mean power per band over every half-overlapped frame of one second."""
    lo = sec * rate
    acc = [0.0] * len(BANDS)
    frames = 0
    for start in range(lo, lo + rate - N + 1, N // 2):
        seg = s[start:start + N]
        mean = sum(seg) / N
        spec = fft([(seg[i] - mean) * _hann[i] for i in range(N)])
        for b, (f0, f1) in enumerate(BANDS):
            k0, k1 = int(f0 * N / rate), int(f1 * N / rate)
            acc[b] += sum((spec[k].real ** 2 + spec[k].imag ** 2) for k in range(k0, k1))
        frames += 1
    return [a / frames / N / N for a in acc], frames


def rms(s):
    m = sum(s) / len(s)
    return math.sqrt(sum((v - m) ** 2 for v in s) / len(s))


def compare(a, b, rate, offset, quiet=False):
    secs = min((len(a) - offset * rate) // rate, len(b) // rate)
    logs = [[] for _ in BANDS]
    rlog = []
    if not quiet:
        print(f'{"sec":>4}{"MAME rms":>10}{"core rms":>10}{"ratio":>7}   '
              + ''.join(f'{f"{lo}-{hi}":>12}' for lo, hi in BANDS))
    for sec in range(secs):
        sa = a[(offset + sec) * rate:(offset + sec + 1) * rate]
        sb = b[sec * rate:(sec + 1) * rate]
        ra, rb = rms(sa), rms(sb)
        ea, fa = second_bands(a, rate, offset + sec)
        eb, _ = second_bands(b, rate, sec)
        cells = []
        for k in range(len(BANDS)):
            # a band counts where MAME has something in it
            if ea[k] > 1.0 and ra > 20:
                r = math.sqrt(eb[k] / ea[k]) if eb[k] > 0 else 0.0
                cells.append(f'{r:12.3f}')
                logs[k].append(abs(math.log2(max(r, 1e-6))))
            else:
                cells.append(f'{"-":>12}')
        if ra > 20:
            rlog.append(abs(math.log2(max(rb / ra, 1e-6))))
        if not quiet:
            print(f'{offset + sec:4d}{ra:10.1f}{rb:10.1f}{(rb / ra if ra > 1 else 0):7.3f}   ' + ''.join(cells))
    res = [sum(l) / len(l) if l else None for l in logs]
    if not quiet:
        print(f'\nframes per second analysed: {fa}; seconds compared: {secs}, '
              f'of which MAME is audible in {len(rlog)}')
        print('mean |log2(core/MAME)| amplitude, 0 = identical, 1 = a factor of two:')
        print(f'  rms         {sum(rlog) / len(rlog) if rlog else float("nan"):.3f}')
        for (lo, hi), v in zip(BANDS, res):
            print(f'  {f"{lo}-{hi} Hz":12}' + (f'{v:.3f}  ({len(logs[BANDS.index((lo, hi))])} s)' if v is not None else 'never audible in MAME'))
    return res, (sum(rlog) / len(rlog) if rlog else None)


def selftest():
    rate = 48000
    def tone(f, amp, secs=2, start=0.0):
        return [int(amp * math.sin(2 * math.pi * f * (i / rate) + start)) for i in range(rate * secs)]
    ok = True
    a = [x + y for x, y in zip(tone(440, 8000), tone(3000, 4000))]
    # identical but out of phase: must read as the same
    b = [x + y for x, y in zip(tone(440, 8000, start=1.0), tone(3000, 4000, start=2.0))]
    res, r = compare(a, b, rate, 0, quiet=True)
    print('same spectrum, other phase:', [None if v is None else round(v, 3) for v in res])
    ok &= all(v is None or v < 0.02 for v in res)
    # 3 kHz component halved: only its band may move, and by one octave
    b = [x + y for x, y in zip(tone(440, 8000), tone(3000, 2000))]
    res, r = compare(a, b, rate, 0, quiet=True)
    print('3 kHz halved:              ', [None if v is None else round(v, 3) for v in res])
    ok &= res[1] < 0.02 and abs(res[3] - 1.0) < 0.05
    # the sound only in the LAST half of each second: a first-frame-only
    # instrument would call these silent or identical whatever b held
    gate = [1 if (i % rate) > rate // 2 else 0 for i in range(rate * 2)]
    a2 = [x * g for x, g in zip(tone(440, 8000), gate)]
    b2 = [x * g for x, g in zip(tone(440, 2000), gate)]
    res, r = compare(a2, b2, rate, 0, quiet=True)
    print('late in the second, quartered:', [None if v is None else round(v, 3) for v in res])
    ok &= res[1] is not None and abs(res[1] - 2.0) < 0.05
    print('OK: the instrument reads what is there' if ok else 'FAIL')
    return 0 if ok else 1


def main():
    args = sys.argv[1:]
    if '--selftest' in args:
        return selftest()
    if len(args) < 2:
        sys.exit(__doc__)
    a, ra = read_wav(args[0])
    b, rb = read_wav(args[1])
    if ra != rb:
        sys.exit(f'{ra} Hz against {rb} Hz')
    compare(a, b, ra, int(float(args[2])) if len(args) > 2 else 0)
    return 0


if __name__ == '__main__':
    sys.exit(main())
