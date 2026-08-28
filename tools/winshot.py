#!/usr/bin/env python3
"""Crop a `qtest fullshot` capture down to one dom0 window, by name.

Why this exists: `qtest shot` (local.WinScreenshot) returns an EMPTY tar for a guest with no
gui-agent session - a Windows guest sitting in Automatic Repair, at the boot screen, or wedged
before the agent starts is invisible to it. Those are exactly the states worth looking at, and
"I cannot see it" has repeatedly turned into a wrong diagnosis here.

`qtest fullshot` does capture such a guest, because dom0 draws the qube's framebuffer as an
ordinary window: the capture carries the whole dom0 desktop plus a geometry table naming every
window. So the per-window view is a crop away - no dom0-side change, no new service.

Usage:
    tools/qtest fullshot out.tar && tools/winshot.py out.tar win10-tpl [-o shot.png]
    tools/winshot.py out.tar --list          # what windows the capture contains

Exit codes: 0 cropped, 2 no window of that name, 3 unusable capture.
"""
import argparse
import io
import sys
import tarfile

from PIL import Image


def load(tar_path):
    """Return (screen Image, [(id, x, y, w, h, override_redirect, mapped, name)])."""
    try:
        tf = tarfile.open(tar_path)
    except Exception as e:
        sys.exit(f"cannot read {tar_path}: {e}")
    png = geom = None
    for m in tf.getmembers():
        base = m.name.rsplit("/", 1)[-1]
        if base == "screen.png":
            png = tf.extractfile(m).read()
        elif base == "geometry.txt":
            geom = tf.extractfile(m).read().decode("utf-8", "replace")
    if not png:
        sys.exit(3)
    windows = []
    for line in (geom or "").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        f = line.split(None, 7)
        if len(f) < 8:
            continue
        try:
            windows.append((f[0], int(f[1]), int(f[2]), int(f[3]), int(f[4]), f[5], f[6], f[7]))
        except ValueError:
            continue
    return Image.open(io.BytesIO(png)), windows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("tar")
    ap.add_argument("name", nargs="?", help="window name to crop (substring, case-insensitive)")
    ap.add_argument("-o", "--out", default="window.png")
    ap.add_argument("--list", action="store_true")
    a = ap.parse_args()

    screen, windows = load(a.tar)
    if a.list or not a.name:
        print(f"# capture is {screen.width}x{screen.height}")
        for w in windows:
            print(f"{w[0]}  {w[3]}x{w[4]}+{w[1]}+{w[2]}  mapped={w[6]} override={w[5]}  {w[7]}")
        return 0

    want = a.name.lower()
    hits = [w for w in windows if want in w[7].lower()]
    if not hits:
        print(f"no window matching '{a.name}' in this capture; it holds: "
              + ", ".join(sorted({w[7] for w in windows})), file=sys.stderr)
        return 2
    # Largest match: a qube usually owns one framebuffer window plus small decorations.
    wid, x, y, w, h, _ovr, mapped, name = max(hits, key=lambda t: t[3] * t[4])
    # Clamp to the screen: a window partly off-screen would otherwise raise or pad.
    left, top = max(0, x), max(0, y)
    right, bottom = min(screen.width, x + w), min(screen.height, y + h)
    if right <= left or bottom <= top:
        print(f"window '{name}' ({w}x{h}+{x}+{y}) lies outside the {screen.width}x{screen.height} "
              "capture - nothing to crop", file=sys.stderr)
        return 2
    screen.crop((left, top, right, bottom)).save(a.out)
    clipped = " (clipped to the screen)" if (right - left, bottom - top) != (w, h) else ""
    print(f"{a.out}: {right-left}x{bottom-top} from window {wid} '{name}' mapped={mapped}{clipped}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
