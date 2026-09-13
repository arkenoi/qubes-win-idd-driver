#!/bin/bash
# TOAST BLACK WITNESS - is a toast BLACK when it appears, and only then filled with content?
#
# THE PREVIOUS VERSION OF THIS FILE COULD NOT SEE A TOAST AT ALL, and said the opposite in its own
# header: "a Windows toast is a GUEST window mapped into dom0, so `qtest shot` sees it". It does
# not. A toast is caption-less, so the agent classifies it as a popup (main.c IsPopup) and maps it
# OVERRIDE-REDIRECT; dom0's per-window service enumerates `_NET_CLIENT_LIST`, which by definition
# excludes override-redirect windows - the service's own source says so
# (dom0/15-install-window-screenshot-service.sh:36). Proven, not inferred: across all three runs
# that version ever produced, not one capture contained a toast-sized window. It was a check that
# could not fail, which this project's own rules call worthless.
#
# So this uses the DOM0 RENDER WITNESS, the same unavoidable reason as a0-toast-bridge.sh and
# dom0-notify-witness.sh: `fullshot` returns geometry.txt listing EVERY window with its
# override_redirect flag, which is the only way to locate the toast, plus the desktop image to cut
# it from. THE DESKTOP CAPTURE IS DELETED THE MOMENT THE TOAST RECT IS CUT OUT - it photographs the
# owner's entire screen and three such captures once reached a public repo.
#
# THE TRAPS THIS AVOIDS (they produced false PASSes before):
#   * per-capture rect, never a remembered one - the toast MOVES and RESIZES as the stack grows;
#   * a baseline asserted to be toast-free, so "no toast present" can never read as "not black";
#   * the toast is located by override_redirect + name, not by guessing a size.
#
# Usage:  VM=win11-up mgmt/harness/toast-black-witness.sh [rounds]
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2

VM="${VM:?set VM}"
ROUNDS="${1:-3}"
SHOTS="${SHOTS:-6}"           # captures per round, starting the instant the toast is fired
OUT="${TBW_OUT:-scratchpad/toast-black/$VM-$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$OUT"
say(){ echo "[$(date -u +%H:%M:%S)] $*"; }

source mgmt/harness/vmlock.sh
vm_lock "$VM"
trap 'vm_unlock "$VM"' EXIT

b64(){ python3 -c "import sys,base64;print(base64.b64encode(sys.argv[1].encode('utf-16-le')).decode())" "$1"; }

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
            f = line.split(None, 6)
            if len(f) < 7:
                continue
            x, y, w, h, orr, mapped, name = int(f[1]), int(f[2]), int(f[3]), int(f[4]), f[5], f[6], f[6]
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

INC='C:\Users\user\Documents\QubesIncoming\'$(hostname)
QTEST_VM=$VM timeout -k 5 120 ./tools/qtest push guest/fire-toast.ps1 >/dev/null 2>&1 \
  || { say "FAIL: could not push the toast trigger"; exit 2; }

fails=0
for r in $(seq 1 "$ROUNDS"); do
  say "--- round $r/$ROUNDS"

  # BASELINE, ASSERTED. Without this a round where no toast ever appears reads as "never black".
  QTEST_VM=$VM timeout -k 5 90 ./tools/qtest fullshot "$OUT/r$r-base.tar" >/dev/null 2>&1
  base=$(cut_toast "$OUT/r$r-base.tar" "r$r-base")
  if [ "$base" != "NOTOAST" ]; then
    say "  round $r SKIPPED: a toast is already on screen ($base) - baseline is not toast-free"
    sleep 12
    continue
  fi
  say "  baseline: toast-free (asserted)"

  QTEST_VM=$VM timeout -k 5 120 ./tools/qtest run \
    "powershell -NoProfile -ExecutionPolicy Bypass -File $INC\\fire-toast.ps1 -Title BLINK$r -Body witness" \
    >"$OUT/r$r-fire.out" 2>&1 &
  fire=$!

  seen=0; black=0
  for i in $(seq 1 "$SHOTS"); do
    QTEST_VM=$VM timeout -k 5 90 ./tools/qtest fullshot "$OUT/r$r-s$i.tar" >/dev/null 2>&1
    v=$(cut_toast "$OUT/r$r-s$i.tar" "r$r-s$i")
    say "  s$i: $v"
    case "$v" in
      NOTOAST|UNREADABLE*) ;;
      *) seen=$((seen+1))
         nb=$(printf '%s' "$v" | sed 's/.*nonblack=//')
         awk -v n="$nb" 'BEGIN{exit !(n < 0.10)}' && black=$((black+1)) ;;
    esac
  done
  wait $fire 2>/dev/null

  if [ "$seen" -eq 0 ]; then
    say "  round $r: NO TOAST EVER CAPTURED - missing data FAILS, this round proves nothing"
    fails=$((fails+1))
  elif [ "$black" -gt 0 ]; then
    say "  round $r: FAIL - $black of $seen toast captures were BLACK (<10% non-black)"
    fails=$((fails+1))
  else
    say "  round $r: PASS - $seen toast captures, none black"
  fi
  sleep 10
done

say "--- toast PNGs (toast only, no desktop) in $OUT"
say "summary: $((ROUNDS-fails)) round(s) clean, $fails failed/void"
exit $([ "$fails" -eq 0 ] && echo 0 || echo 1)
