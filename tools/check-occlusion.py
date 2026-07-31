#!/usr/bin/env python3
"""Assert damage clipping in BOTH directions from an occlusion-test trace.

Reads the output of tools/viewcheck/occlusion-test.ps1 (phase markers + QGAPROTO records).

  phase 'visible': COVER is on top over BASE-relative x >= 300.
                   BASE must receive NO damage past x=300  (under-clip => corrupted overlaps)
  phase 'hidden' : COVER is hidden and occludes nothing.
                   BASE MUST receive damage past x=300     (over-clip  => blank windows)

Exits non-zero if either fails. A run that cannot establish both is a FAILURE, not a pass:
the whole point is that the previous suite reported green while a real regression was present.
"""
import re
import sys

OVERLAP_X = 300   # BASE-relative x where COVER starts


def main():
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    raw = open(sys.argv[1], errors='replace').read()

    m = re.search(r'BASEHWND (\d+)', raw)
    c = re.search(r'COVERHWND (\d+)', raw)
    if not m or not c:
        print("FAIL: test app did not report its window handles; nothing was verified")
        return 1
    base, cover = int(m.group(1)), int(c.group(1))
    print(f"base=0x{base:x} cover=0x{cover:x}")

    # Attribute records to phases by TIMESTAMP, not by position: the trace is dumped after
    # both phases have run, so every record appears after every phase marker in the output and
    # position-based attribution silently puts them all in the last phase.
    marks = dict((n, t) for n, t in re.findall(r'PHASE ([\w-]+) ([0-9.]+)', raw))
    for need in ('visible', 'visible-end', 'hidden', 'hidden-end'):
        if need not in marks:
            print(f"FAIL: phase marker '{need}' missing; records cannot be attributed")
            return 1
    # Bound each phase by its own repaint window. Between phases the z-order can legitimately
    # change (another window taking focus), and damage that is correct under the new stacking
    # would otherwise be scored as a clipping leak.
    bounds = {'visible': (marks['visible'], marks['visible-end']),
              'hidden': (marks['hidden'], marks['hidden-end'])}

    dmg = {'visible': [], 'hidden': []}
    dmg_pat = re.compile(
        r'\[(\d{8}\.\d{6}\.\d{3})-[^\]]*\].*'
        r'QGAPROTO,msg=DAMAGE,hwnd=0x([0-9a-f]+),rx=(-?\d+),ry=(-?\d+),w=(\d+),h=(\d+)')
    for line in raw.splitlines():
        d = dmg_pat.search(line)
        if not d:
            continue
        ts, hwnd = d.group(1), int(d.group(2), 16)
        if hwnd != base:
            continue
        rx, ry, w, h = map(int, d.group(3, 4, 5, 6))
        for ph, (lo, hi) in bounds.items():
            if lo <= ts < hi:
                dmg[ph].append((rx, ry, w, h))
                break

    failures = []
    for ph in ('visible', 'hidden'):
        if not dmg[ph]:
            failures.append(
                f"phase '{ph}': BASE received NO damage at all, so this phase verified "
                f"nothing (the repaint did not reach the agent)")
    if failures:
        for f in failures:
            print(f"FAIL: {f}")
        return 1

    past_visible = [d for d in dmg['visible'] if d[0] + d[2] > OVERLAP_X]
    past_hidden = [d for d in dmg['hidden'] if d[0] + d[2] > OVERLAP_X]

    print(f"  phase visible: {len(dmg['visible'])} damage rect(s), "
          f"{len(past_visible)} reaching past x={OVERLAP_X}")
    print(f"  phase hidden : {len(dmg['hidden'])} damage rect(s), "
          f"{len(past_hidden)} reaching past x={OVERLAP_X}")

    ok = True
    if past_visible:
        w = past_visible[0]
        print(f"FAIL [under-clip] BASE was sent damage at rx={w[0]} w={w[2]} (reaches "
              f"{w[0]+w[2]}) while COVER is on top of x>={OVERLAP_X}: the daemon will paint "
              f"COVER's pixels into BASE - corrupted menus / overlap debris")
        ok = False
    if not past_hidden:
        print(f"FAIL [over-clip] BASE received no damage past x={OVERLAP_X} while COVER is "
              f"HIDDEN and occludes nothing: that region will never repaint - the window goes "
              f"partially blank")
        ok = False

    print("\nboth clipping directions correct" if ok else "\nocclusion clipping is WRONG")
    return 0 if ok else 1


if __name__ == '__main__':
    sys.exit(main())
