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
source mgmt/harness/desktop-visible-lib.sh   # a round graded against a lock screen is not a round
source mgmt/harness/toast-cut-lib.sh        # cut_toast - the toast cut out, the desktop capture deleted
vm_lock "$VM"
trap 'vm_unlock "$VM"' EXIT

b64(){ python3 -c "import sys,base64;print(base64.b64encode(sys.argv[1].encode('utf-16-le')).decode())" "$1"; }


INC='C:\Users\user\Documents\QubesIncoming\'$(hostname)
QTEST_VM=$VM timeout -k 5 120 ./tools/qtest push guest/fire-toast.ps1 guest/dismiss-toast.ps1 \
  guest/run-as-user.ps1 >/dev/null 2>&1 \
  || { say "FAIL: could not push the toast trigger"; exit 2; }

# fire-toast raises a `scenario="reminder"` toast, which BY DESIGN stays on screen until dismissed
# - that is what makes it a stable surface to measure, and it is also why it outlives a round. The
# per-user notification HISTORY is what has to be cleared, so this runs in the user session; killing
# ShellExperienceHost does not work, because the platform re-shows a reminder toast when the host
# respawns (guest/dismiss-toast.ps1 documents both, measured 2026-08-31).
clear_toasts(){
  QTEST_VM=$VM timeout -k 5 300 ./tools/qtest pushrun guest/run-as-user.ps1 \
    -Tag dismiss -Script "$INC\\dismiss-toast.ps1" >/dev/null 2>&1
  sleep 6
}

fails=0
for r in $(seq 1 "$ROUNDS"); do
  say "--- round $r/$ROUNDS"

  clear_toasts
  # BASELINE, ASSERTED. Without this a round where no toast ever appears reads as "never black".
  QTEST_VM=$VM timeout -k 5 90 ./tools/qtest fullshot "$OUT/r$r-base.tar" >/dev/null 2>&1
  # A locked or blanked desktop makes the whole round meaningless: the locker is mapped
  # fullscreen and override-redirect, which is exactly what cut_toast selects on, so grading
  # would proceed against the lock screen instead of a toast. Checked on the baseline capture,
  # before anything is cut out of it.
  if ! desktop_visible "$OUT/r$r-base.tar"; then
    say "  round $r VOID: dom0 desktop blank or locked (structure=$(desktop_struct_value "$OUT/r$r-base.tar") < $DESKTOP_STRUCT_MIN) - a toast cannot be"
    say "                photographed over a screen lock, and the locker is itself a fullscreen"
    say "                override-redirect window, so cut_toast would grade IT. Refusing to grade."
    fails=$((fails+1))
    sleep 12
    continue
  fi
  base=$(cut_toast "$OUT/r$r-base.tar" "r$r-base")
  if [ "$base" != "NOTOAST" ]; then
    say "  round $r VOID: a toast is STILL on screen after the dismiss ($base) - refusing to grade"
    say "                against a dirty scene rather than reporting a delta that cannot mean anything"
    fails=$((fails+1))
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
