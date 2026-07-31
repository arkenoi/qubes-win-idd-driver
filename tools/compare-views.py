#!/usr/bin/env python3
"""Compare what the GUEST rendered against what DOM0 actually shows.

The guest capture (Graphics.CopyFromScreen inside Windows) is ground truth: it is what
Windows composited. The dom0 capture (local.WinScreenshot) is what the agent + gui-daemon
actually delivered. Any difference is a GUI-agent defect, and this tells us *which kind*
without needing a human to look:

  * whole window differs, dom0 image is flat/blank  -> damage never sent (blank-window bug)
  * a horizontal BAND differs                       -> stale scanlines (tearing)
  * dom0 content matches a DIFFERENT screen region  -> position/content desync (wobble)
  * dom0 content matches the region but the guest
    has another window on top there                 -> composited-framebuffer overlap

Usage:
  compare-views.py <guest.png> <dom0-dir> <windows.json>

windows.json is produced in the guest by tools/enum-windows.ps1: a list of
{hwnd, title, x, y, w, h} for the mapped top-level windows.
"""
import json
import sys

import numpy as np
from PIL import Image


def load(p):
    return np.asarray(Image.open(p).convert('RGB'), dtype=np.int16)


def diff_stats(a, b):
    """Per-row mean absolute difference plus an overall figure."""
    if a.shape != b.shape:
        return None
    d = np.abs(a - b).mean(axis=2)          # per-pixel, averaged over RGB
    return {
        'mean': float(d.mean()),
        'rows': d.mean(axis=1),             # per-row mean -> reveals bands
        'frac_differing': float((d > 8).mean()),
    }


def classify(guest, dom0img, rect):
    x, y, w, h = rect
    gh, gw, _ = guest.shape
    if x < 0 or y < 0 or x + w > gw or y + h > gh:
        return 'OFFSCREEN', {}
    crop = guest[y:y + h, x:x + w]
    if crop.shape != dom0img.shape:
        return 'SIZE-MISMATCH', {'guest': crop.shape, 'dom0': dom0img.shape}

    st = diff_stats(crop, dom0img)
    if st is None:
        return 'SIZE-MISMATCH', {}

    # flatness of the dom0 image: a blank/unpainted window has almost no variance
    flat = float(dom0img.std())

    if st['frac_differing'] < 0.02:
        return 'OK', st
    if flat < 3.0:
        return 'BLANK-IN-DOM0', dict(st, dom0_std=flat)

    # banding: contiguous rows that differ a lot while others match
    bad = st['rows'] > 8
    if bad.any() and not bad.all():
        runs, cur = [], 0
        for v in bad:
            if v:
                cur += 1
            elif cur:
                runs.append(cur)
                cur = 0
        if cur:
            runs.append(cur)
        if runs and max(runs) >= 4:
            # WHERE the band sits is diagnostic: rows only at the very top/bottom point at
            # the window-border/clipping geometry (the agent reports DWM extended frame
            # bounds, which are smaller than GetWindowRect), whereas interior bands point at
            # damage coverage.
            idx = np.where(bad)[0]
            n = len(bad)
            return 'STALE-BAND', dict(st, band_rows=int(max(runs)),
                                      differing_rows=int(bad.sum()),
                                      first_row=int(idx[0]), last_row=int(idx[-1]),
                                      height=int(n),
                                      edge_only=bool(idx[0] < 8 or idx[-1] > n - 9))
    return 'CONTENT-DIFFERS', st


def locate(guest, dom0img, expect_xy, radius=120, step=2, sub=8):
    """Find where in the guest screen dom0's content ACTUALLY came from.

    If dom0 is showing content sampled from a different position than the window's current
    rect, the best match will not be at the expected offset - that offset IS the wobble,
    measured in pixels, and its sign says whether dom0 is ahead of or behind the guest.
    Coarse grayscale search; exact enough to distinguish 0 from tens of pixels.
    """
    g = guest.mean(axis=2)
    d = dom0img.mean(axis=2)
    dh, dw = d.shape
    ex, ey = expect_xy
    best, bestscore = None, None
    for dy in range(-radius, radius + 1, step):
        for dx in range(-radius, radius + 1, step):
            x, y = ex + dx, ey + dy
            if x < 0 or y < 0 or y + dh > g.shape[0] or x + dw > g.shape[1]:
                continue
            # subsample for speed; enough to localise a whole-window shift
            sc = np.abs(g[y:y + dh:sub, x:x + dw:sub] - d[::sub, ::sub]).mean()
            if bestscore is None or sc < bestscore:
                bestscore, best = sc, (dx, dy)
    return best, bestscore


def main():
    if len(sys.argv) != 4:
        print(__doc__)
        return 2
    guest = load(sys.argv[1])
    dom0dir, meta = sys.argv[2], json.load(open(sys.argv[3]))

    import glob
    import os
    # dom0 images are keyed by size, but the sizes do NOT match GetWindowRect exactly: the
    # guest rect includes the invisible resize border while the agent reports DWM extended
    # frame bounds (e.g. 2580x1029 vs 2566x1022). Match with tolerance.
    pool = []
    for p in sorted(glob.glob(os.path.join(dom0dir, '*.png'))):
        im = load(p)
        pool.append([os.path.basename(p), im, False])

    TOL = 24

    def take(w, h):
        best, bestd = None, None
        for e in pool:
            if e[2]:
                continue
            dw, dh = e[1].shape[1], e[1].shape[0]
            if abs(dw - w) <= TOL and abs(dh - h) <= TOL:
                d = abs(dw - w) + abs(dh - h)
                if bestd is None or d < bestd:
                    best, bestd = e, d
        if best:
            best[2] = True
            return best[0], best[1]
        return None

    # Windows are matched to dom0 images BY SIZE, which is ambiguous the moment two windows
    # share dimensions - and then the comparison silently judges the wrong pair and reports a
    # defect. Refuse to judge instead of guessing.
    from collections import Counter
    sizes = Counter((w['w'], w['h']) for w in meta)
    ambiguous = {sz for sz, n in sizes.items() if n > 1}

    print(f"{'window':28s} {'size':>11s}  {'verdict':16s} detail")
    worst = 'OK'
    for wdef in meta:
        if (wdef['w'], wdef['h']) in ambiguous:
            title = (wdef.get('title') or wdef.get('cls') or '?')[:26]
            print(f"{title:28s} {wdef['w']}x{wdef['h']:<6}  {'AMBIGUOUS':16s} "
                  f"{sizes[(wdef['w'], wdef['h'])]} windows share this size; size-based matching "
                  f"cannot tell them apart, so no verdict is given")
            if worst == 'OK':
                worst = 'AMBIGUOUS'
            continue
        w, h = wdef['w'], wdef['h']
        got = take(w, h)
        title = (wdef.get('title') or wdef.get('cls') or '?')[:26]
        if not got:
            print(f"{title:28s} {w}x{h:<6}  {'NOT-IN-DOM0':16s} agent never mapped it / import failed")
            continue
        name, im = got
        # crop the guest at the dom0 image's actual size, centred on the guest rect, so the
        # border discrepancy above does not masquerade as a content difference
        dh, dw = im.shape[0], im.shape[1]
        ox = wdef['x'] + (w - dw) // 2
        oy = wdef['y'] + (h - dh) // 2
        # CRITICAL: do not assume the dom0 image is centred on the guest rect. The agent
        # reports DWM extended frame bounds and the border discrepancy is not symmetric, so a
        # centred crop can be several rows off - which makes EVERY row of text mismatch and
        # masquerades as tearing. Find the true alignment first, then judge content there.
        # Alignment is only identifiable if the content has features to align ON. A blank or
        # near-uniform window (an empty Notepad is a white field) matches equally well at many
        # offsets, so the search returns an arbitrary minimum and any verdict derived from it
        # is noise. Refuse rather than report.
        probe = guest[max(0, oy):oy + dh, max(0, ox):ox + dw]
        if probe.size and float(probe.std()) < 12.0:
            print(f"{title:28s} {w}x{h:<6}  {'UNALIGNABLE':16s} guest content is near-uniform "
                  f"(std={float(probe.std()):.1f}); alignment has no unique minimum, so no "
                  f"verdict is given")
            if worst == 'OK':
                worst = 'UNALIGNABLE'
            continue

        RADIUS = 40
        off, _ = locate(guest, im, (ox, oy), radius=RADIUS, step=1, sub=2)
        # A best match sitting ON the search boundary means the true optimum is outside the
        # window searched - the number returned is the radius, not the offset. Reporting a
        # verdict from it is how "(12,-8), about one frame of lag" and a nonexistent tearing
        # defect were both manufactured.
        if off and (abs(off[0]) >= RADIUS or abs(off[1]) >= RADIUS):
            print(f"{title:28s} {w}x{h:<6}  {'UNRELIABLE':16s} best alignment {off} is at the "
                  f"+/-{RADIUS}px search boundary, so it is the limit rather than a measurement")
            if worst == 'OK':
                worst = 'UNRELIABLE'
            continue
        if off:
            ox, oy = ox + off[0], oy + off[1]
        verdict, st = classify(guest, im, (ox, oy, dw, dh))
        if off and off != (0, 0):
            st = dict(st or {}, align=off)
        extra = ''
        if st:
            if 'frac_differing' in st:
                extra = f"differing={st['frac_differing']*100:.1f}% mean={st['mean']:.1f}"
            if 'band_rows' in st:
                extra += f" band={st['band_rows']}rows"
            if 'dom0_std' in st:
                extra += f" dom0_std={st['dom0_std']:.1f}"
            if st.get('align'):
                extra += f" align={st['align']}"
            if 'first_row' in st:
                extra += (f" rows[{st['first_row']}..{st['last_row']}]/{st['height']}"
                          f"{' EDGE' if st['edge_only'] else ' INTERIOR'}")
        print(f"{title:28s} {w}x{h:<6}  {verdict:16s} {extra}  [{name}]")
        if verdict != 'OK':
            worst = verdict
    print(f"\nWORST: {worst}")
    if worst in ('AMBIGUOUS', 'UNALIGNABLE', 'UNRELIABLE'):
        print(f"{worst} means this run proved nothing about those windows - not that they are ok.")
    return 0 if worst == 'OK' else 1


if __name__ == '__main__':
    sys.exit(main())
