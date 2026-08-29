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
    # The service has emitted TWO header formats over time:
    #   7 columns: id x y w h override_redirect name
    #   8 columns: id x y w h override_redirect mapped name      (mapped added 2026-08-07)
    # Decide from the header, never from the field count of a data line - a title is free text
    # and may hold any number of spaces, or none.
    #
    # This function used to do `f = line.split(None, 7)` and `if len(f) < 8: continue`, which
    # silently DISCARDED every window whose name was a single token - including the bare VM name
    # ("win10-tpl") and the "?" the service writes when a window has no WM_NAME. On the 7-column
    # format it also ate the first word of every remaining title as if it were the mapped column.
    # The result was a tool that reported "no window matching 'win10-tpl'" about a normal, mapped,
    # full-size window that was sitting right there in the capture - which is what sent this
    # project down the whole-desktop capture path in the first place. Do not reintroduce it.
    has_mapped = None
    for line in (geom or "").splitlines():
        if line.startswith("#") and "override_redirect" in line:
            has_mapped = "mapped" in line
            break

    def num(tok):
        """int, or None for the '?' the service writes when xwininfo could not read it."""
        try:
            return int(tok)
        except ValueError:
            return None

    windows = []
    for line in (geom or "").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        f = line.split(None, 6)          # id x y w h ovr <rest>
        if len(f) < 6:
            continue
        rest = f[6] if len(f) > 6 else ""
        if has_mapped is None:
            # No usable header. Infer, and be explicit that it is an inference: a leading 0/1
            # token followed by more text is the mapped column.
            parts = rest.split(None, 1)
            mapped_here = len(parts) == 2 and parts[0] in ("0", "1")
        else:
            mapped_here = has_mapped
        if mapped_here:
            parts = rest.split(None, 1)
            mapped = parts[0] if parts else "?"
            name = parts[1] if len(parts) > 1 else ""
        else:
            mapped, name = "?", rest
        windows.append((f[0], num(f[1]), num(f[2]), num(f[3]), num(f[4]), f[5],
                        mapped, name or "?"))
    return Image.open(io.BytesIO(png)), windows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("tar", nargs="?")
    ap.add_argument("name", nargs="?", help="window name to crop (substring, case-insensitive)")
    ap.add_argument("-o", "--out", default="window.png")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--classify", action="store_true",
                    help="also print a one-word verdict for what is on that window")
    # Classify a bare PNG - specifically, one window from `qtest shot`, which is the PER-WINDOW
    # capture path. Without this, the only way to get a verdict was to classify a crop out of a
    # `qtest fullshot`, i.e. to photograph the whole dom0 desktop (every other qube included) in
    # order to decide whether one guest is at a recovery screen. That is what put three
    # whole-desktop captures into a public repo. A per-window PNG needs no cropping and no
    # geometry, so classify it directly.
    ap.add_argument("--png", help="classify a single PNG (e.g. one window from `qtest shot`)")
    a = ap.parse_args()

    if a.png:
        try:
            img = Image.open(a.png)
        except Exception as e:
            print(f"cannot read {a.png}: {e}", file=sys.stderr)
            return 3
        print(f"VERDICT={classify(img)}")
        return 0
    if not a.tar:
        ap.error("give a capture tar, or --png FILE")

    screen, windows = load(a.tar)
    if a.list or not a.name:
        print(f"# capture is {screen.width}x{screen.height}")
        for w in windows:
            geo = ("?x?+?+?" if None in w[1:5]
                   else f"{w[3]}x{w[4]}+{w[1]}+{w[2]}")
            print(f"{w[0]}  {geo}  mapped={w[6]} override={w[5]}  {w[7]}")
        return 0

    want = a.name.lower()
    hits = [w for w in windows if want in w[7].lower()]
    if not hits:
        print(f"no window matching '{a.name}' in this capture; it holds: "
              + ", ".join(sorted({w[7] for w in windows})), file=sys.stderr)
        return 2
    # A window with unreadable geometry cannot be cropped - but say so, rather than dropping it
    # and reporting "no match" for a window we can plainly see.
    croppable = [w for w in hits if None not in w[1:5]]
    if not croppable:
        print(f"'{a.name}' matches {len(hits)} window(s), but the service could not read their "
              "geometry (xwininfo missing in dom0?), so no crop is possible: "
              + ", ".join(f"{w[0]} '{w[7]}'" for w in hits), file=sys.stderr)
        return 3
    # Largest match: a qube usually owns one framebuffer window plus small decorations.
    wid, x, y, w, h, _ovr, mapped, name = max(croppable, key=lambda t: t[3] * t[4])
    # Clamp to the screen: a window partly off-screen would otherwise raise or pad.
    left, top = max(0, x), max(0, y)
    right, bottom = min(screen.width, x + w), min(screen.height, y + h)
    if right <= left or bottom <= top:
        print(f"window '{name}' ({w}x{h}+{x}+{y}) lies outside the {screen.width}x{screen.height} "
              "capture - nothing to crop", file=sys.stderr)
        return 2
    crop = screen.crop((left, top, right, bottom))
    crop.save(a.out)
    clipped = " (clipped to the screen)" if (right - left, bottom - top) != (w, h) else ""
    print(f"{a.out}: {right-left}x{bottom-top} from window {wid} '{name}' mapped={mapped}{clipped}")
    if a.classify:
        print(f"VERDICT={classify(crop)}")
    return 0


# Measured signatures, not guesses (2026-08-28, from captures of this testbed):
#   Windows recovery / boot-error screens ("Automatic Repair couldn't repair your PC") are 93% of
#   ONE colour, RGB(32,103,178) - the Windows recovery blue.
#   A live guest desktop with an app open is ~87% white and otherwise varied.
# The point of this is to give a wait loop a TERMINAL state to stop on. A harness that only times
# out will sit for its full deadline on a guest that is never coming back, and - worse - restart
# it, which is how this project burned hours on a VM that was in Automatic Repair the whole time.
RECOVERY_BLUE = (32, 103, 178)


def classify(img, tol=12, dominance=0.60):
    """RECOVERY | BLACK | DESKTOP | UNKNOWN for a cropped window image."""
    small = img.convert("RGB").resize((160, 120))
    total = small.width * small.height
    colours = small.getcolors(maxcolors=total)
    if not colours:
        return "UNKNOWN"
    n, col = max(colours)
    frac = n / total
    if frac >= dominance:
        if all(abs(c - r) <= tol for c, r in zip(col, RECOVERY_BLUE)):
            return "RECOVERY"          # boot failed: recovery/repair screen, not a desktop
        if max(col) <= 24:
            return "BLACK"             # no output at all - pre-video, or a hung guest
    if frac >= 0.98:
        return "UNKNOWN"               # one flat colour we have no signature for
    return "DESKTOP"                   # varied content: something is actually rendering


if __name__ == "__main__":
    sys.exit(main())
