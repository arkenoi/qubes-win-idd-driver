#!/usr/bin/env python3
"""Measure how much text actually rendered in the first Notepad's client area.

The truncation regression leaves most of the window blank while stock renders every line, so
counting dark (text) pixels in the client area separates the two without a human looking.
Takes the full-desktop PNG and the window rect from geometry.txt.
"""
import sys
import numpy as np
from PIL import Image


def main():
    png, geom = sys.argv[1], sys.argv[2]
    rect = None
    for line in open(geom):
        if line.startswith('#'):
            continue
        p = line.split()
        # Match the LARGEST Notepad window by name, not by a fixed size: minimizing and
        # restoring changes the size, and a rigid size match then silently reports NOGEOM -
        # which reads as "no data" when the real answer was "the window is right there".
        if len(p) >= 7 and 'Notepad' in ' '.join(p[6:]):
            r = (int(p[1]), int(p[2]), int(p[3]), int(p[4]))
            if rect is None or r[2] * r[3] > rect[2] * rect[3]:
                rect = r
    if not rect:
        print("NOGEOM: first Notepad not in dom0 geometry")
        return 2
    x, y, w, h = rect
    im = np.asarray(Image.open(png).convert('L'))
    # client area only: skip the dom0 titlebar/border and Notepad's own chrome
    crop = im[y + 60:y + h - 20, x + 20:x + w - 20]
    dark = int((crop < 128).sum())
    total = crop.size
    print(f"rect={rect} text_pixels={dark} ({100.0*dark/total:.2f}% of client area)")
    return 0


if __name__ == '__main__':
    sys.exit(main())
