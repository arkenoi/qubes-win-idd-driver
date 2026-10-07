#!/usr/bin/env bash
# wu-cumulative-order-selftest.sh - the order of the .msu route and the cumulative's registration check (qubes-windows-update.ps1
# WU-MSU-KIND, WU-PASS-ORDER, WU-INSTALL-MSUS, WU-CUMULATIVE-REGISTERED, WU-MSU-VERDICT): the clean leg must pass, and each -Defect knob
# must fail EXACTLY the cases its guard protects - a guard never seen to fail is decoration. Exit 0 only if every leg comes out as
# required. The agent route and the drivers stay inline in the offer loop; wu-notactionable-selftest.sh covers that region.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PWSH="${PWSH:-/home/user/bin/pwsh7/pwsh}"
[ -x "$PWSH" ] || { echo "FAIL  pwsh not found at $PWSH - nothing ran"; exit 2; }
T="$ROOT/tools/tests/wu-cumulative-order-test.ps1"
out=$("$PWSH" -NoProfile -File "$T" 2>&1); rc=$?
printf '%s\n' "$out" | tail -1
fails_of() { printf '%s\n' "$1" | grep -oE '^  FAIL [a-z0-9 -]+:' | sed 's/^  FAIL //; s/:$//' | LC_ALL=C sort | tr '\n' ','; }
bad=0
expect() {   # knob, expected failing cases
  local kout krc kf
  kout=$("$PWSH" -NoProfile -File "$T" -Defect "$1" 2>&1); krc=$?; kf=$(fails_of "$kout")
  if [ "$krc" = 1 ] && [ "$kf" = "$2" ]; then echo "OK    $1 fails exactly {$kf}"; else echo "FAIL  $1 rc=$krc fails={$kf} (want $2)"; bad=1; fi
}
[ "$rc" = 0 ] || { echo "FAIL  clean rc=$rc"; printf '%s\n' "$out" | grep FAIL; bad=1; }
# offerorder is 4.3.33's order: .NET stages first and the cumulative is deferred behind it by the one-package rule - so it never
# reaches DISM (no package-list reads, no before-read ahead of it) and both-land fails with the order.
expect offerorder    "both-land,cumulative-first,list-brackets-dism,rp-unreadable-proceeds,"
# nodefer hands the cumulative to DISM behind a pending restart; the registration check (the backstop) then fails that row, so what
# moves is the deferral itself - in the full plan and in the cumulative-only plan.
expect nodefer       "cumulative-deferred,deferral-requests-restart,"
# norequest: only the cumulative-only plan can see it - in the full plan .NET's own stage sets reboot_needed as well.
expect norequest     "deferral-requests-restart,"
expect assumepending "rp-unreadable-proceeds,"
# norelax is the pre-rz40 rule: .NET is deferred behind the registered cumulative, in the plan too - so only one package reaches DISM.
expect norelax       "both-land,cumulative-first,others-after-registered,"
expect relaxall      "no-cumulative-old-rule,second-cumulative-deferred,"
# nobefore: with an empty baseline the stale pending rollup passes as newly registered, an unreadable before-list can no longer be
# noticed, and the list is no longer read ahead of DISM (list-brackets-dism, and the call sequence rp-unreadable-proceeds asserts).
expect nobefore      "list-brackets-dism,rp-unreadable-proceeds,stale-pending-not-new,unreadable-not-staged,"
# notnew: the stale rollup counts - in Install-Msus and in the pure-function check alike.
expect notnew        "registered-check,stale-pending-not-new,"
# trust3010: every row the check fails reads as staged again.
expect trust3010     "stale-pending-not-new,unreadable-not-staged,unregistered-fails,"
expect unknownok     "unreadable-not-staged,"
# norelaxflag: the cumulative registers but never relaxes the rule, so .NET is deferred in the plan (one DISM call) and the flag stays unset.
expect norelaxflag   "both-land,cumulative-first,registered,"
# kindnone: nothing is the cumulative, so the order is the offer order, nothing is deferred for a pending restart, and no check runs.
expect kindnone      "both-land,cumulative-deferred,cumulative-first,deferral-requests-restart,kind,list-brackets-dism,registered,rp-unreadable-proceeds,second-cumulative-deferred,stale-pending-not-new,unreadable-not-staged,unregistered-fails,"
[ "$bad" = 0 ] && { echo "PASS  clean passes; every knob fails exactly its cases"; exit 0; }
exit 1
