#!/usr/bin/env bash
# upd-task-prestop-selftest.sh - the installer ends OUR update tasks before msiexec, OFFLINE.
#
# WHY IT EXISTS. Campaign 3 cell win11-reinstall, 2026-10-22: the MSI's Restart Manager reaped
# \QubesWindowsUpdateScan's running powershell (0xC000013A inside a 666 ms session), the death
# reporter read that as an unexplained stop, and the USER was told "The Windows Update scan task
# failed" about a scan our own install had stopped. dom0_loud_failures=2 against a max of 0, P1.
# Owner: "it is our installer and our receiver. we may tell it to die politely in any way we
# please." A task WE end reports 267014/0x41306, which guest/qwt-report-death.ps1 already ignores -
# so the fix is a declaration in the installer and NO change in the reporter.
#
# The suite EXTRACTS the UPDTASKPRESTOP region from the shipped installer and RUNS it with schtasks
# replaced by a recorder, so /end-before-/disable is observed rather than grepped. It also checks
# the premise against the shipped reporter: if 267014 stopped being benign there, ending the task
# politely would only trade one notification for another, and this suite goes red.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SUITE="$ROOT/tools/tests/upd-task-prestop-test.ps1"
# pwsh FROM THE PATH FIRST, dev-qube paths as fallbacks - the same resolution
# tools/tests/death-reporter-selftest.sh uses, so this behaves identically on a CI runner (where
# the workflow already uses `shell: pwsh`) and on this qube.
PWSH="$("$(dirname "$0")/pwsh-path.sh" || true)"
say() { printf '%s\n' "$*"; }
[ -x "$PWSH" ] || { say "FAIL  pwsh not found at $PWSH - nothing ran"; exit 2; }
[ -f "$SUITE" ] || { say "FAIL  $SUITE is missing - nothing ran"; exit 2; }

out=$("$PWSH" -NoProfile -File "$SUITE" 2>&1); rc=$?
printf '%s\n' "$out"
n=$(printf '%s\n' "$out" | command grep -c '^ok  ')
f=$(printf '%s\n' "$out" | command grep -c '^FAIL')
if [ "$rc" -eq 0 ] && [ "$f" -eq 0 ] && [ "$n" -ge 9 ]; then
  say "PASS  clean: rc=0 ok=$n fail=0"
else
  say "FAIL  clean: rc=$rc ok=$n fail=$f"
  exit 1
fi
