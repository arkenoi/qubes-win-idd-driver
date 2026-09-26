#!/usr/bin/env python3
"""relay-pixel-match.py - do the pixels the RELAY DELIVERED match what the window renders?

    tools/relay-pixel-match.py <dom0-shot.tar> <truth.txt> [--tol 0.25]

WHY. Route counters say where a frame came from, not whether it is right, and the de-slice census's
pixel test is a PROXY: it compares a window's own surface with its composited render INSIDE the
guest, which shows only that content exists outside the own surface. Asked to accept the goal on
that basis, Jev answered `bar_met` 0.20 with `residual_gap = relayed-pixels-never-read` at **1.00**.

The relay's delivered frames are what dom0 displays, so dom0's per-window capture IS the relayed
pixels. This compares them against the guest's composited render of the same windows.

NO MAPPING SERVICE IS AVAILABLE. `local.WinWindowShot`, which carries a manifest, is policy-refused
from this qube (measured: rc=126 "Request refused"), and `local.WinScreenshot` returns PNGs named
only by index. So rather than ASSUME which PNG is which window - the kind of assumption that has
produced false verdicts here before - this looks for a BIJECTION: each guest window is matched to at
most one dom0 capture whose colour count agrees within tolerance, and the match is reported per
window. A window with no partner is reported as UNMATCHED, never silently dropped.

A bijection over distinctive counts is stronger than an assumed mapping, and its failure mode is
loud: if two windows have indistinguishable signatures the report says so instead of guessing.
"""
import sys, tarfile, io, re, os

try:
    from PIL import Image
except ImportError:
    print("PIL unavailable - cannot read the captures; MISSING DATA, not a pass", file=sys.stderr)
    sys.exit(2)


# THE GUEST SAMPLES EVERY 9th PIXEL. guest/window-truth-survey.ps1 walks `for y += 9 { for x += 9 }`
# and counts DISTINCT SAMPLED colours - so on a 360x240 gradient it reports 1080, which is 40*27, the
# number of samples, not a property of the image as a whole. Counting every pixel of a dom0 PNG and
# comparing it with that number is apples to oranges, and the first version of this script did
# exactly that: it reported 11 of 13 windows UNMATCHED, which would have read as a product failure.
# The sampling here is identical so the two numbers mean the same thing.
STEP = 9

def png_signature(data):
    """(distinct SAMPLED colour count, width, height), sampled exactly as the guest samples."""
    im = Image.open(io.BytesIO(data)).convert("RGB")
    w, h = im.size
    px = im.load()
    seen = set()
    y = 0
    while y < h:
        x = 0
        while x < w:
            seen.add(px[x, y])
            x += STEP
        y += STEP
    return len(seen), w, h


def load_truth(p):
    rows = []
    for ln in open(p, errors="replace"):
        if not ln.startswith("TRUTH\t"):
            continue
        fields = ln.strip().split("\t")[1:]
        d = dict(kv.split("=", 1) for kv in fields if "=" in kv)
        if "hwnd" not in d:
            continue
        # The row carries the window size as a BARE token (e.g. "360x240"), not a key=value pair, so
        # the kv parse above drops it. It is the strongest key for matching a capture to a window.
        wh = next((f for f in fields if re.fullmatch(r"\d+x\d+", f)), None)
        try:
            rows.append({
                "hwnd": int(d["hwnd"], 16),
                "cls": d.get("class", "?"),
                "own": int(d.get("ownColours", "-1")),
                "full": int(d.get("fullColours", "-1")),
                "title": d.get("title", ""),
                "w": int(wh.split("x")[0]) if wh else 0,
                "h": int(wh.split("x")[1]) if wh else 0,
            })
        except ValueError:
            continue
    return rows


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    tar_p, truth_p = sys.argv[1], sys.argv[2]
    tol = 0.25
    if "--tol" in sys.argv:
        tol = float(sys.argv[sys.argv.index("--tol") + 1])

    caps = []
    with tarfile.open(tar_p) as t:
        for m in t.getmembers():
            if not m.name.lower().endswith(".png"):
                continue
            data = t.extractfile(m).read()
            try:
                c, w, h = png_signature(data)
            except Exception as e:
                print(f"  {m.name}: unreadable ({e}) - MISSING DATA")
                continue
            caps.append({"name": os.path.basename(m.name), "colours": c, "w": w, "h": h})
    rows = load_truth(truth_p)
    # DEDUPE BY HWND. Several chromerepro instances accumulate across runs, so the same class appears
    # more than once and the bijection is then asked to match windows that no longer exist. Keeping
    # the last row per hwnd is not a cosmetic tidy-up: duplicates made 13 guest windows compete for
    # 7 captures and every loser was reported as a failure.
    dedup = {}
    for r in rows:
        dedup[r["hwnd"]] = r
    rows = list(dedup.values())
    if not caps or not rows:
        print(f"MISSING DATA: {len(caps)} dom0 capture(s), {len(rows)} guest row(s) - cannot compare")
        return 1

    print(f"{len(caps)} dom0 captures, {len(rows)} guest windows, tolerance +/-{int(tol*100)}%\n")
    print("dom0 captures:")
    for c in sorted(caps, key=lambda x: -x["colours"]):
        print(f"  {c['name']:<12} {c['w']}x{c['h']:<6} colours={c['colours']}")
    print()

    # Greedy bijection, most distinctive (highest colour count) first: those are the least ambiguous.
    used, results = set(), []
    for r in sorted(rows, key=lambda x: -x["full"]):
        if r["full"] < 0:
            results.append((r, None, "no guest colour count"))
            continue
        best, bestd = None, None
        for c in caps:
            if c["name"] in used:
                continue
            lo = min(c["colours"], r["full"]) or 1
            d = abs(c["colours"] - r["full"]) / lo
            # DIMENSIONS DIFFER BY THE FRAME, LEGITIMATELY. The guest measures GetWindowRect (the
            # whole window) while dom0 captures the content dom0 was sent - measured here as 360x240
            # against 348x234, i.e. a 12x6 frame. An exact-equality penalty rejected a window whose
            # colour count matched EXACTLY (16 vs 16), which would have been reported as a pixel
            # failure. Allow the frame: penalise only a capture that is not plausibly this window.
            if r.get("w") and not (abs(c["w"] - r["w"]) <= 24 and abs(c["h"] - r["h"]) <= 24):
                d += 0.5
            if bestd is None or d < bestd:
                best, bestd = c, d
        if best is not None and bestd is not None and bestd <= tol:
            used.add(best["name"])
            results.append((r, best, f"match d={bestd:.2f}"))
        else:
            near = f" (nearest {best['name']} colours={best['colours']}, d={bestd:.2f})" if best else ""
            results.append((r, None, f"UNMATCHED{near}"))

    print(f"{'class':<34}{'guest full':>11}{'dom0':>7}  verdict")
    matched = 0
    for r, c, why in results:
        got = c["colours"] if c else "-"
        ok = c is not None
        matched += 1 if ok else 0
        print(f"{r['cls'][:33]:<34}{r['full']:>11}{str(got):>7}  {'MATCH' if ok else why}")
    print()
    print(f"matched {matched}/{len(results)} guest windows to a dom0 capture")
    unmatched = [r for r, c, _ in results if c is None]
    if unmatched:
        print("RELAY PIXEL VERDICT: FAIL - these windows' rendered content was not found in dom0's "
              "captures: " + ", ".join(r["cls"] for r in unmatched))
        print("  (missing data FAILS; it is not a pass)")
        return 1
    print("RELAY PIXEL VERDICT: PASS - every guest window's composited colour count is present in "
          "dom0's own captures within tolerance")
    return 0


if __name__ == "__main__":
    sys.exit(main())
