#!/usr/bin/env python3
"""Verify by PIXELS that the benchmarked scene was actually rendering, and stamp the verdict
into the run's JSON.

WHY THIS EXISTS. On 2026-08-12 a single wedged Notepad — title strip delivered, client area
white, typing registered but invisible — faked TWO regressions here. It survived agent restarts
AND binary swaps, so it lives guest/window-side and NOTHING in the agent's own output can detect
it. Benchmarking against it produced "4-5 fps frame delivery collapse" while a fresh Notepad in
the same environment measured 19.7 ms. The recorded rule is: never benchmark against a window
whose content is not verified rendering. This is that check, as code rather than as a habit.

Test: the largest captured window must have real structure in its interior — measured as the
standard deviation of luminance over the client area with the outer frame cropped away. A blank
or uniformly white client area has a stddev near zero whatever its title bar does.
"""
import json
import sys
import tarfile

import numpy as np
from PIL import Image

MIN_STD = 6.0      # luminance stddev; a blank client area sits under 1
MIN_PIXELS = 10000  # smaller than this is furniture, not the scene


def check(tar_path):
    try:
        with tarfile.open(tar_path) as t:
            best = None
            for m in t.getmembers():
                if not m.name.lower().endswith(".png"):
                    continue
                f = t.extractfile(m)
                if f is None:
                    continue
                img = Image.open(f).convert("L")
                if best is None or img.width * img.height > best[1].width * best[1].height:
                    best = (m.name, img.copy())
            if best is None:
                return False, "no window captured", {}
            name, img = best
            w, h = img.size
            if w * h < MIN_PIXELS:
                return False, f"largest window {w}x{h} is too small to be the scene", {}
            # Crop the frame and the title bar: a wedged window still paints those.
            a = np.asarray(img, dtype=np.float32)
            inner = a[int(h * 0.15):int(h * 0.97), int(w * 0.03):int(w * 0.97)]
            std = float(inner.std())
            ok = std >= MIN_STD
            return ok, ("rendering" if ok else f"client area is blank (luma stddev {std:.2f})"), {
                "window": name, "size": f"{w}x{h}", "luma_std": round(std, 2)}
    except Exception as e:                    # noqa: BLE001 - any failure is a failed check
        return False, f"scene check failed: {e}", {}


def main(tar_path, json_path):
    ok, why, detail = check(tar_path)
    try:
        o = json.load(open(json_path))
    except Exception:
        o = {"valid": False, "why": ["the phase parser produced no JSON"]}
    o["scene"] = why
    o["scene_detail"] = detail
    if not ok:
        o["valid"] = False
        o.setdefault("why", []).append(f"scene not verified rendering: {why}")
    json.dump(o, open(json_path, "w"), indent=2)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1], sys.argv[2]))
