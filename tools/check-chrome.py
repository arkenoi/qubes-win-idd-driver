#!/usr/bin/env python3
"""Assert a captured guest window actually contains its own chrome.

WHY THIS EXISTS: on 2026-08-07 a geometry "fix" clamped the reported window rect to
the work area. Because perwindow.c derives the capture crop from that same rect, it
silently cut 64 px off the top of every maximized window - the title bar and the menu
bar. Every numeric check passed (the reported geometry matched the work area exactly,
which is what made it look like a success); the defect was found by a human looking at
the screen. This turns "the window still has its chrome" into something a machine can
fail on.

Measured on the DEFECTIVE build (agent 74CF4B7385FFA9DD, maximized Notepad):
    top 0-40 rows   : 1 distinct colour     <- chrome gone
    rows 40-70      : 1 distinct colour
    bottom 40 rows  : 7 distinct colours    <- status bar still there
A healthy capture shows a title bar and a menu bar in that top band.

Usage: tools/check-chrome.py <window.png> [--min-colours N] [--band PX]
Exit 0 = chrome present, 1 = chrome missing, 2 = could not evaluate (never silently pass).
"""
import sys

def main(argv):
    args = [a for a in argv[1:] if not a.startswith('--')]
    if not args:
        print("usage: check-chrome.py <window.png> [--min-colours N] [--band PX]", file=sys.stderr)
        return 2
    path = args[0]
    min_colours = 3
    band = 40
    for i, a in enumerate(argv):
        if a == '--min-colours' and i + 1 < len(argv):
            min_colours = int(argv[i + 1])
        if a == '--band' and i + 1 < len(argv):
            band = int(argv[i + 1])

    try:
        from PIL import Image
    except ImportError:
        print("CHROME=UNKNOWN reason=PIL_missing", file=sys.stderr)
        return 2
    try:
        im = Image.open(path).convert('RGB')
    except Exception as e:
        print(f"CHROME=UNKNOWN reason=unreadable:{e}", file=sys.stderr)
        return 2

    w, h = im.size
    if h < band * 2 or w < 40:
        # A window too small to have chrome cannot be judged - and "cannot judge" must
        # never read as a pass.
        print(f"CHROME=UNKNOWN reason=too_small {w}x{h}", file=sys.stderr)
        return 2

    def distinct(y0, y1):
        return len({im.getpixel((x, y))
                    for y in range(y0, min(y1, h), 2)
                    for x in range(0, w, 20)})

    top = distinct(0, band)
    bottom = distinct(h - band, h)
    ok = top >= min_colours
    print(f"CHROME={'OK' if ok else 'MISSING'} top_band_colours={top} "
          f"bottom_band_colours={bottom} min={min_colours} size={w}x{h}")
    if not ok:
        print("  the window's top band is featureless - title bar / menu bar were cropped "
              "out of the captured content (see tools/check-chrome.py header)", file=sys.stderr)
    return 0 if ok else 1

if __name__ == '__main__':
    sys.exit(main(sys.argv))
