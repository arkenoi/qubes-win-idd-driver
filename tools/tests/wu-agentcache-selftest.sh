#!/usr/bin/env bash
# wu-agentcache-selftest.sh - the agent-cache install path (qubes-windows-update.ps1 WU-COMOBJECT, WU-LEAF-SELECT, WU-AGENT-INSTALL,
# WU-DEFENDER-SIGNATURE, WU-AGENT-VERDICT): the clean leg must pass, and each -Defect knob must fail EXACTLY the cases its guard protects - a guard never seen to
# fail is decoration. Exit 0 only if every leg comes out as required.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PWSH="${PWSH:-/home/user/bin/pwsh7/pwsh}"
[ -x "$PWSH" ] || { echo "FAIL  pwsh not found at $PWSH - nothing ran"; exit 2; }
T="$ROOT/tools/tests/wu-agentcache-test.ps1"
out=$("$PWSH" -NoProfile -File "$T" 2>&1); rc=$?
printf '%s\n' "$out" | tail -1
fails_of() { printf '%s\n' "$1" | grep -oE '^  FAIL [a-z -]+:' | sed 's/^  FAIL //; s/:$//' | LC_ALL=C sort | tr '\n' ','; }
bad=0
expect() {   # knob, expected failing cases
  local kout krc kf
  kout=$("$PWSH" -NoProfile -File "$T" -Defect "$1" 2>&1); krc=$?; kf=$(fails_of "$kout")
  if [ "$krc" = 1 ] && [ "$kf" = "$2" ]; then echo "OK    $1 fails exactly {$kf}"; else echo "FAIL  $1 rc=$krc fails={$kf} (want $2)"; bad=1; fi
}
[ "$rc" = 0 ] || { echo "FAIL  clean rc=$rc"; printf '%s\n' "$out" | grep FAIL; bad=1; }
# onelevel also takes the two install-failure cases down: with the depth-2 engine leaf never seen, its missing fetch / missing static
# content cannot be named - the measured run-2 symptom ("not downloaded", nothing named).
# unroll: the factory hands every caller $null, so every install case dies at its first Add (the rz38b guest, 2026-10-03).
expect unroll         "comobject,install-fetchfail,install-nostatic,install-ok,"
expect onelevel       "install-fetchfail,install-nostatic,install-ok,leaf-depth,"
expect fetchinstalled "install-ok,leaf-downloaded,leaf-installed,"
expect acceptexpress  "install-nostatic,leaf-express,"
expect downloader     "install-fetchfail,install-nostatic,"
expect emptycache     "install-fetchfail,"
expect sigbehindinfo  "sig-behind,"
expect trustagent     "verdict-disagree,verdict-disagree-plat,"
expect rcignored      "verdict-failed,"
expect agentcurrent   "verdict-current,"
expect nomissing      "verdict-notdownloaded,"
[ "$bad" = 0 ] && { echo "PASS  clean passes; every knob fails exactly its cases"; exit 0; }
exit 1
