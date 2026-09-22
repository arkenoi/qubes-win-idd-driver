#!/bin/bash
# classifier-route-probe.sh - does the classifier's verdict actually decide the route, on a guest?
#
# The change under test (929cc81) lets a per-toast verdict route a toast from an app NOBODY
# allowlisted. Until now such a toast was skipped outright. The three cases that matter:
#
#   informational (no buttons) from a non-allowlisted AUMID -> BRIDGED, and dom0 RENDERS it
#   realchoice    (buttons)    from a non-allowlisted AUMID -> stays on the guest-window path
#   the bridge's own log states which verdict drove each decision
#
# DONE = PIXELS, NOT ACKS: the informational case is only a pass if dom0 actually rendered it,
# which is what mgmt/harness/dom0-notify-witness.sh is for. A bridge.log line saying "route ...
# bridge" proves the decision, not the delivery.
#
#   VM=<guest> mgmt/harness/classifier-route-probe.sh
#
# Read-only against the product: it fires toasts and reads logs. It does not edit the allowlist -
# the whole point is an app that is NOT on it.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2
VM="${VM:?set VM to the guest carrying the build under test}"
# One mutating job per guest: this fires toasts into it, so it takes the lock like any other
# harness. vm_lock returns at once if an ancestor already holds it.
. mgmt/harness/vmlock.sh
vm_lock "$VM"
OUT="scratchpad/classroute-$(date -u +%Y%m%dT%H%M%SZ)"; mkdir -p "$OUT"
say(){ echo "$(date -u +%H:%M:%SZ) classroute: $*" | tee -a "$OUT/probe.log"; }
gq(){ QTEST_VM=$VM timeout -k 5 "${2:-90}" ./tools/qtest run "$1" 2>/dev/null | tr -d '\r'; }
pass=0; fail=0
ok(){ say "PASS  $*"; pass=$((pass+1)); }
no(){ say "FAIL  $*"; fail=$((fail+1)); }

AUMID="QwtClassRouteProbe.$(date -u +%H%M%S)"     # an app that is on NOBODY's allowlist
BLOG='C:\ProgramData\qubes-toast-bridge\bridge.log'

say "subject $VM, probe AUMID $AUMID (deliberately not allowlisted)"

# The bridge must be up, or every verdict below is vacuous.
if ! gq 'powershell -NoProfile -Command "(Get-Process notifhost -EA SilentlyContinue | Measure-Object).Count"' 60 | grep -qE '^[1-9]'; then
  say "TERMINAL: notifhost is not running on $VM - nothing to probe"; exit 2
fi

# Offset FIRST: only lines written after this point are this probe's evidence (harness rule 8).
OFF=$(gq "cmd /c for %I in ($BLOG) do @echo %~zI" 60 | grep -aoE '^[0-9]+$' | tail -1)
say "bridge.log offset before firing: ${OFF:-0} bytes"
gq "cmd /c \"C:\\Qubes Tools\\bin\\toastfire.exe\" --register --method bare --aumid $AUMID" 120 >/dev/null

fire(){ # $1=class -> prints the toast id the bridge logged, if any
  gq "cmd /c \"C:\\Qubes Tools\\bin\\toastfire.exe\" --fire --method bare --aumid $AUMID --class $1" 120 >/dev/null
  sleep 12    # >= 3 poll passes at the 2 s cadence, plus acquisition
}
tail_new(){ gq "powershell -NoProfile -Command \"\$f='$BLOG'; if(Test-Path \$f){ \$s=New-Object IO.FileStream(\$f,'Open','Read','ReadWrite'); \$s.Seek(${OFF:-0},'Begin')|Out-Null; \$r=New-Object IO.StreamReader(\$s); \$r.ReadToEnd() }\"" 120; }

say "case 1: informational (no buttons) from a non-allowlisted app"
fire informational
T=$(tail_new); printf '%s\n' "$T" > "$OUT/after-informational.log"
if printf '%s' "$T" | grep -qE "route id=[0-9]+ aumid=$AUMID .*bridge; classifier verdict"; then
  ok "the classifier's verdict routed it to the bridge (app is not allowlisted)"
elif printf '%s' "$T" | grep -qE "skip id=[0-9]+ aumid=$AUMID"; then
  no "it took the window path - the verdict did not drive the route: $(printf '%s' "$T" | grep -aE "aumid=$AUMID" | tail -2 | tr '\n' ' ')"
else
  no "the bridge logged NOTHING for $AUMID - missing data, not a verdict"
fi

say "case 2: realchoice (buttons) from the same non-allowlisted app"
fire realchoice
T2=$(tail_new); printf '%s\n' "$T2" > "$OUT/after-realchoice.log"
if printf '%s' "$T2" | grep -qE "skip id=[0-9]+ aumid=$AUMID .*window path; classifier verdict"; then
  ok "a buttoned toast stayed on the window path, by verdict - the user keeps its buttons"
elif printf '%s' "$T2" | grep -qE "route id=[0-9]+ aumid=$AUMID .*bridge"; then
  no "a BUTTONED toast was bridged - the user cannot act on it, which is the direction that must never fail"
else
  no "no decision logged for the realchoice toast - missing data"
fi

say "case 3: nothing was deferred for ever"
printf '%s\n%s\n' "$T" "$T2" | grep -aE "await id=[0-9]+ aumid=$AUMID" > "$OUT/awaits.txt" || true
AW=$(wc -l < "$OUT/awaits.txt")
if [ "${AW:-0}" -le 6 ]; then ok "deferrals bounded ($AW await lines, cap is 3 passes per toast)"
else no "$AW await lines - a toast is being deferred past its cap"; fi

gq "cmd /c \"C:\\Qubes Tools\\bin\\toastfire.exe\" --unregister --method bare --aumid $AUMID" 120 >/dev/null
say "RESULT: $pass passed, $fail failed; evidence in $OUT"
[ "$fail" = 0 ]
