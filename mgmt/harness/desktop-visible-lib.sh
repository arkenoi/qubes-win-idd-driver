# Can the dom0 desktop show anything at all?
#
# Every DOM0 RENDER WITNESS in this tree photographs the owner's whole desktop and then asks an
# operator to find a bubble in it. A LOCKED OR BLANKED DESKTOP DEFEATS THAT IN THE WORST
# DIRECTION: the capture succeeds, the tar contains a PNG, and the row reports "captured - READ
# IT" over a photograph of the lock screen. The operator then either wastes a read or, worse,
# records "no bubble" - blaming the PRODUCT for the operator's screen lock.
#
# dom0-notify-witness.sh has carried this check since 2026-09-14 and states the reasoning:
# "a window may be mapped internally, you just wont see it on actual dom0" (owner) - mapped is
# not visible, and only a witness speaks for visible. The other three fullshot callers never
# had it. This lifts it out of that one file so all four share it (the allowlist of callers is
# tools/check-capture-callers.sh).
#
# The tell: a lock or blank screen is nearly uniform, a working desktop is not. The threshold
# only has to separate "a desktop" from "no desktop", not grade anything.
#
# THE EDGE-DENSITY THRESHOLD ALONE IS NOT SUFFICIENT, MEASURED 2026-10-30 ON THE LIVE CONDITION.
# 0.004 came from dom0-notify-witness.sh and had never been checked against a real locked screen.
# It was, the day this library was written, and it FAILED: the operator's screen was running an
# ANIMATED screensaver (xscreensaver, a pyramid on black), and across six consecutive captures the
# edge density read
#     0.00477  0.00283  0.00281  0.00265  0.00351  0.00531
# so TWO OF SIX crossed the floor and would have been handed to the operator as a desktop. An
# animated saver does not have one structure value; it has a distribution that straddles any floor
# tuned to a static one. dom0-notify-witness.sh's own comment assumed the opposite - "a screensaver
# is STATIC" - and that assumption is what this measurement retires.
#
# DARKNESS IS THE STABLE SIGNAL. The same seven captures:
#     edge density  0.00265 .. 0.00531   (spans the floor - unusable alone)
#     mean grey     1.16    .. 1.87
#     fraction dark 97.10%  .. 98.30%    (tight, and nowhere near any working desktop)
# A desktop showing a taskbar, windows and text is not 97% near-black across 5120x1440. So the
# check now refuses on EITHER signal: too flat, or too dark. Both thresholds err toward refusing,
# and that direction is safe by construction - a false refusal costs a re-run, while a false
# acceptance sends a human to look for a notification bubble in a screensaver and lets "no bubble"
# be recorded against the product.
#
# It is still a ONE-WAY check. Below either threshold the desktop is certainly not usable; above
# both, nothing is established - a locker drawing a bright wallpaper would pass both and still be a
# locker. Callers print the numbers and the operator confirms the capture is a desktop.
DESKTOP_STRUCT_MIN=${DESKTOP_STRUCT_MIN:-0.004}
DESKTOP_DARK_MAX=${DESKTOP_DARK_MAX:-0.90}

desktop_struct(){ # <tar> -> "STRUCT=<edge density> DARK=<fraction near-black>", or STRUCT=-1 DARK=-1
  python3 - "$1" <<'DVPY'
import sys, tarfile, io, numpy as np
from PIL import Image
try:
    with tarfile.open(sys.argv[1]) as t:
        best = None
        for m in t.getmembers():
            if m.name.lower().endswith(".png") and (best is None or m.size > best.size): best = m
        if best is None:
            print("STRUCT=-1 DARK=-1"); raise SystemExit
        im = Image.open(io.BytesIO(t.extractfile(best).read())).convert("L")
    a = np.asarray(im, dtype=np.int16)
    print("STRUCT=%.5f DARK=%.4f" % (float((np.abs(np.diff(a, axis=1)) > 12).mean()),
                                     float((a < 16).mean())))
except Exception:
    print("STRUCT=-1 DARK=-1")
DVPY
}

desktop_struct_value(){ desktop_struct "$1" | sed -nE 's/.*STRUCT=([0-9.-]+).*/\1/p'; }
desktop_dark_value(){   desktop_struct "$1" | sed -nE 's/.*DARK=([0-9.-]+).*/\1/p'; }

# rc 0 only when the capture is BOTH structured enough and not overwhelmingly dark. One call,
# one decode - the two values come from the same frame, which matters because the screensaver that
# forced this moves between frames.
desktop_visible(){
  local out st dk
  out=$(desktop_struct "$1")
  st=$(printf '%s' "$out" | sed -nE 's/.*STRUCT=([0-9.-]+).*/\1/p')
  dk=$(printf '%s' "$out" | sed -nE 's/.*DARK=([0-9.-]+).*/\1/p')
  awk -v x="${st:--1}" -v d="${dk:--1}" -v m="$DESKTOP_STRUCT_MIN" -v n="$DESKTOP_DARK_MAX" \
      'BEGIN{exit !(x >= 0 && x >= m && d >= 0 && d < n)}'
}
