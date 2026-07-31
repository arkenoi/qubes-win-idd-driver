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
            return 'STALE-BAND', dict(st, band_rows=int(max(runs)),
                                      differing_rows=int(bad.sum()))
    return 'CONTENT-DIFFERS', st


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

    print(f"{'window':28s} {'size':>11s}  {'verdict':16s} detail")
    worst = 'OK'
    for wdef in meta:
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
        verdict, st = classify(guest, im, (ox, oy, dw, dh))
        extra = ''
        if st:
            if 'frac_differing' in st:
                extra = f"differing={st['frac_differing']*100:.1f}% mean={st['mean']:.1f}"
            if 'band_rows' in st:
                extra += f" band={st['band_rows']}rows"
            if 'dom0_std' in st:
                extra += f" dom0_std={st['dom0_std']:.1f}"
        print(f"{title:28s} {w}x{h:<6}  {verdict:16s} {extra}  [{name}]")
        if verdict != 'OK':
            worst = verdict
    print(f"\nWORST: {worst}")
    return 0 if worst == 'OK' else 1


if __name__ == '__main__':
    sys.exit(main())
