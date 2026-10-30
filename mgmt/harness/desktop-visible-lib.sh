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
# THE THRESHOLD IS INHERITED, NOT RE-VALIDATED. 0.004 comes from dom0-notify-witness.sh. It has
# not been measured against every locker: a lock screen carrying a wallpaper and a clock has
# edges and could score above it. So this is a one-way check - below the threshold it is
# CERTAINLY not a usable desktop; above it, the capture still needs the operator's eyes, which
# is exactly what ATTENDED-PENDING already means. Callers must therefore print the number rather
# than treat "above threshold" as proof the desktop was visible.
DESKTOP_STRUCT_MIN=${DESKTOP_STRUCT_MIN:-0.004}

desktop_struct(){ # <tar> -> "STRUCT=<fraction>" over the largest PNG, or STRUCT=-1 if unreadable
  python3 - "$1" <<'DVPY'
import sys, tarfile, io, numpy as np
from PIL import Image
try:
    with tarfile.open(sys.argv[1]) as t:
        best = None
        for m in t.getmembers():
            if m.name.lower().endswith(".png") and (best is None or m.size > best.size): best = m
        if best is None:
            print("STRUCT=-1"); raise SystemExit
        im = Image.open(io.BytesIO(t.extractfile(best).read())).convert("L")
    a = np.asarray(im, dtype=np.int16)
    print("STRUCT=%.5f" % float((np.abs(np.diff(a, axis=1)) > 12).mean()))
except Exception:
    print("STRUCT=-1")
DVPY
}

desktop_struct_value(){ desktop_struct "$1" | sed -nE 's/STRUCT=([0-9.-]+)/\1/p'; }

# rc 0 only when the capture looks like a working desktop. An unreadable capture (-1) is NOT
# visible: absence of evidence is not evidence of a desktop.
desktop_visible(){
  local v; v=$(desktop_struct_value "$1")
  awk -v x="${v:--1}" -v m="$DESKTOP_STRUCT_MIN" 'BEGIN{exit !(x >= 0 && x >= m)}'
}
