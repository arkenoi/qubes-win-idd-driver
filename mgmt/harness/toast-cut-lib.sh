#!/bin/bash
# cut_toast: the guest toast cut out of a dom0 desktop capture, and the desktop capture DELETED in the same call.
# A toast is override-redirect, absent from _NET_CLIENT_LIST, so only the whole-desktop capture sees it; geometry.txt
# locates it by its override_redirect flag. The desktop image photographs the owner's entire screen and never outlives
# the cut. Callers: toast-black-witness.sh, toast-hold-test.sh (allowlisted in tools/check-capture-callers.sh).

# Cut the toast out of a desktop capture and report its non-black fraction, then DELETE the
# desktop image. Prints "<w>x<h>@<x>,<y> nonblack=<f>" or "NOTOAST".
cut_toast(){ # $1=tar $2=label
  python3 - "$1" "$OUT" "$2" <<'PY'
import sys, tarfile, io, os
import numpy as np
from PIL import Image
tar, out, label = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    with tarfile.open(tar) as t:
        geo = t.extractfile("./geometry.txt").read().decode("utf-8", "replace")
        toast = None
        for line in geo.splitlines():
            if line.startswith("#") or not line.strip():
                continue
            # split(None, 7), NOT 6. The name is the only field that may contain spaces
            # ("New notification"), so splitting at 6 folds `mapped` INTO the name and the
            # mapped=="1" test can never be true - every toast was silently rejected and the
            # witness reported NOTOAST for four straight rounds while the agent's own log
            # proved toasts were on screen. A parser that cannot match is a check that cannot
            # fail, which is the exact defect this file was rewritten to remove.
            f = line.split(None, 7)
            if len(f) < 8:
                continue
            x, y, w, h, orr, mapped, name = int(f[1]), int(f[2]), int(f[3]), int(f[4]), f[5], f[6], f[7]
            # A toast: override-redirect, mapped, and named by the shell as a notification.
            if orr == "1" and mapped == "1" and "notification" in name.lower():
                toast = (x, y, w, h, name)
                break
        if toast is None:
            print("NOTOAST"); sys.exit(0)
        x, y, w, h, name = toast
        im = Image.open(io.BytesIO(t.extractfile("./screen.png").read())).convert("RGB")
        card = im.crop((x, y, x + w, y + h))
        a = np.asarray(card, dtype=np.int16)
        nonblack = float((a.max(axis=2) > 24).mean())
        card.save(os.path.join(out, f"{label}-toast.png"))   # the TOAST only, never the desktop
        print(f"{w}x{h}@{x},{y} nonblack={nonblack:.3f}")
except Exception as e:
    print(f"UNREADABLE ({e})")
PY
  rm -f "$1"          # the desktop capture never outlives the cut
}
