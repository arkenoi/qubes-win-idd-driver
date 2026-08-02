#!/usr/bin/env python3
"""Split a qtest scenario transcript into the two files check-protocol.py needs.

Usage: parse-raw.py <raw> <out-trace.log> <out-guest.json> [GEO-tag]

Guest output is untrusted data: this only parses, never executes.
"""
import json, sys

raw = open(sys.argv[1], errors='replace').read()
tag = sys.argv[4] if len(sys.argv) > 4 else 'GEO'


def block(t):
    i = raw.find(t + 'START')
    j = raw.find(t + 'END')
    if i < 0 or j < 0:
        return []
    return raw[i + len(t) + 5:j].strip().splitlines()


rows = []
for r in block(tag):
    p = r.rstrip('\n').split('\t')
    if len(p) >= 12:
        try:
            rows.append(dict(hwnd=int(p[0]), x=int(p[1]), y=int(p[2]), w=int(p[3]), h=int(p[4]),
                             ex=int(p[5]), title=p[6], cls=p[7],
                             ex_x=int(p[8]), ex_y=int(p[9]), ex_w=int(p[10]), ex_h=int(p[11])))
        except ValueError:
            pass
json.dump(rows, open(sys.argv[3], 'w'), indent=1)

trace = block('TRACE')
open(sys.argv[2], 'w').write('\n'.join(trace) + '\n')
print(f"guest_windows={len(rows)} trace_lines={len(trace)}")
