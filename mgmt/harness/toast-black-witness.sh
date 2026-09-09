#!/bin/bash
# TOAST BLACK WITNESS - is a toast BLACK when it first appears, and only then filled with content?
#
# WHY, AND WHY NOT FROM THE LOG. The owner reports toasts appearing black and filling in afterwards.
# The agent's own instrument says the opposite for the same run: QGASLICEMAP reported the toast's
# content arriving 438 ms BEFORE its map (lead_ms=438, nonblack=918/1250). When the log and the
# screen disagree the screen wins - "judge output, not logs" - so this looks at pixels.
#
# PER-WINDOW CAPTURE, NOT A DESKTOP ONE. A Windows toast is a GUEST window mapped into dom0, so
# `qtest shot` (local.WinScreenshot) sees it. That is the whole difference from a dom0-native
# notification bubble, which is override-redirect and needs the desktop witness. No fullshot here.
#
# METHOD: sample the guest's windows repeatedly across the toast's appearance and report the
# non-black fraction of the toast-sized window in each frame. A toast that is black-then-filled shows
# a low fraction in the first frames and a high one later; one that is correct is high throughout.
#
# Usage:  VM=win11-nfy mgmt/harness/toast-black-witness.sh
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2

VM="${VM:?set VM}"
SHOTS="${SHOTS:-14}"          # samples after the toast is fired
OUT="scratchpad/toast-black/$VM-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$OUT"
say(){ echo "[$(date -u +%H:%M:%S)] $*"; }

source mgmt/harness/vmlock.sh
vm_lock "$VM"
trap 'vm_unlock "$VM"' EXIT

b64(){ python3 -c "import sys,base64;print(base64.b64encode(sys.argv[1].encode('utf-16-le')).decode())" "$1"; }

say "baseline capture (no toast on screen)"
QTEST_VM=$VM timeout -k 5 60 ./tools/qtest shot "$OUT/base.tar" >/dev/null 2>&1

QTEST_VM=$VM timeout -k 5 120 ./tools/qtest push guest/fire-toast.ps1 >/dev/null 2>&1
INC='C:\Users\user\Documents\QubesIncoming\'$(hostname)

# Fire the toast WITHOUT waiting: the interesting window is the first few hundred ms after it
# appears, so the capture loop must already be running when it does.
QTEST_VM=$VM timeout -k 5 120 ./tools/qtest run \
  "powershell -NoProfile -ExecutionPolicy Bypass -File $INC\\fire-toast.ps1 -Title BLACKTEST -Body witness" \
  >"$OUT/fire.out" 2>&1 &
FIREPID=$!

for i in $(seq 1 "$SHOTS"); do
  QTEST_VM=$VM timeout -k 5 30 ./tools/qtest shot "$OUT/s$(printf '%02d' "$i").tar" >/dev/null 2>&1
done
wait $FIREPID 2>/dev/null

say "--- per-capture window inventory (size and non-black fraction)"
python3 - "$OUT" <<'PY'
import sys, tarfile, io, glob, os
import numpy as np
from PIL import Image
d = sys.argv[1]
for tar in sorted(glob.glob(os.path.join(d, "*.tar"))):
    rows = []
    try:
        with tarfile.open(tar) as t:
            for m in t.getmembers():
                if not m.name.lower().endswith(".png"):
                    continue
                im = Image.open(io.BytesIO(t.extractfile(m).read())).convert("RGB")
                a = np.asarray(im, dtype=np.int16)
                # "non-black" on the same footing the agent uses: any channel meaningfully above 0.
                nonblack = float((a.max(axis=2) > 24).mean())
                rows.append((im.size[0], im.size[1], nonblack, os.path.basename(m.name)))
    except Exception as e:
        print(f"{os.path.basename(tar)}: UNREADABLE ({e})")
        continue
    if not rows:
        print(f"{os.path.basename(tar)}: no windows")
        continue
    # Report every window; the toast is the small one (a few hundred px wide).
    parts = [f"{w}x{h} nonblack={nb:.2f}" for w, h, nb, _ in sorted(rows)]
    print(f"{os.path.basename(tar)}: " + " | ".join(parts))
PY
say "evidence: $OUT"
