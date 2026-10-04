#!/usr/bin/env python3
"""Frame age per slot, from a saved census: now - captick, both guest GetTickCount64.

WHY: the original cold-boot staleness cell re-read the section 6 s after the source advanced and found
the delivered frame unchanged. That reading cannot distinguish "this channel never delivers again" from
"its next frame took longer than 6 s" - and the two call for completely different work. captick is when
the broker last captured a frame for that slot and `now` is the peek's own GetTickCount64 at the moment of
the reading (ABI 19; the broker has no heartbeat any more - older readings fall back to brokerHB, which was
the broker's heartbeat then), both on the guest's own clock, so their difference is the frame's age with
none of my polling latency in it. Run it on any saved routes.txt.
"""
import re, sys
if len(sys.argv) < 2:
    sys.exit("usage: frame-age.py <routes.txt> [...]   (a census's saved section reading)")
for path in sys.argv[1:]:
    # A missing file is named, not crashed on: these paths are census evidence dirs that a later run
    # deliberately clears, and a traceback in the middle of a multi-file analysis hides the files that
    # ARE there.
    try:
        txt = open(path, encoding='utf-8', errors='replace').read()
    except OSError as e:
        print("== %s\n   MISSING: %s" % (path, e.strerror))
        continue
    cls = {}
    import os
    cf = os.path.join(os.path.dirname(path), 'classes.txt')
    if os.path.exists(cf):
        for m in re.finditer(r'hwnd=(0x[0-9a-f]+) class=(\S+)', open(cf, errors='replace').read()):
            cls[int(m.group(1), 16)] = m.group(2)
    print(f"== {path}")
    for sample in re.split(r'(?=^S\d+ HDR )', txt, flags=re.M):
        hb = re.search(r' now=(\d+)', sample) or re.search(r'brokerHB=(\d+)', sample)
        if not hb: continue
        hb = int(hb.group(1))
        rows = []
        for m in re.finditer(r'slot(\d+) hwnd=(0x[0-9a-f]+).*?captick=(\d+)', sample):
            slot, hwnd, ct = int(m.group(1)), int(m.group(2), 16), int(m.group(3))
            if hwnd == 0: continue
            gf = re.search(r'slot%d SESSION .*?genFrames=(\d+)' % slot, sample)
            rt = re.search(r'slot%d ROUTE (\d+)' % slot, sample)
            rows.append((slot, hwnd, (hb - ct) / 1000.0, gf.group(1) if gf else '?', rt.group(1) if rt else '?'))
        for slot, hwnd, age, gf, rt in rows:
            print("   slot%-2d %-10s route=%s genFrames=%-3s last frame %8.1fs before the reading  %s"
                  % (slot, hex(hwnd), rt, gf, age, cls.get(hwnd, '')))
