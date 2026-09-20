#!/usr/bin/env python3
"""Group a Quartus report_timing summary by where the paths start and end.

    tools/group_paths.py projects/output_files/failing_paths.txt

The top of a timing report is usually two hundred bits of one bus; what is
wanted is the list of distinct places that fail and the worst slack of each.
"""
import collections
import re
import sys

t = open(sys.argv[1], errors='ignore').read()
rows = re.findall(r'^; (-?[\d.]+)\s*; (\S+)\s*; (\S+)\s*;', t, re.M)


def short(n):
    n = re.sub(r'^core_top:ic\|', '', n)
    n = n.replace('smashtv_core:u_core|', '').replace('stv_main:u_main|', '')
    n = re.sub(r'\[\d+\]', '[]', n)
    n = re.sub(r'~\S*', '', n)
    n = re.sub(r'_OTERM\d+', '', n)
    parts = n.split('|')
    return '|'.join(parts[:3])[:60]


groups = collections.OrderedDict()
for s, a, b in rows:
    k = (short(a), short(b))
    g = groups.setdefault(k, [0, float(s)])
    g[0] += 1
print(f'{len(rows)} failing paths in {len(groups)} groups')
for (a, b), (n, worst) in sorted(groups.items(), key=lambda kv: kv[1][1])[:60]:
    print(f'{worst:8.3f} {n:6d}  {a}  ->  {b}')
