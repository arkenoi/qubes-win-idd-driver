#!/usr/bin/env bash
# wu-deploy-prevpass-selftest.sh - the deploy step's cut-off-pass gate: clean must pass, each knob must FAIL (a guard never seen to
# fail is decoration). Offline; pwsh 7 runs guest/install-updater-agent.ps1's DEPLOY-PREVPASS region against fakes.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
PWSH="${PWSH:-/home/user/pwsh/pwsh}"
[ -x "$PWSH" ] || PWSH="$(command -v pwsh || true)"
[ -n "$PWSH" ] || { echo "FAIL  no pwsh - nothing ran (missing data fails)"; exit 2; }
bad=0
out=$("$PWSH" -NoProfile -File "$HERE/wu-deploy-prevpass-test.ps1" 2>&1); rc=$?
if [ $rc -eq 0 ]; then echo "PASS  clean: $(printf '%s\n' "$out" | grep -c '^ok') checks"; else echo "FAIL  clean (rc=$rc): $(printf '%s\n' "$out" | grep -m1 '^FAIL')"; bad=1; fi
for k in deployscan deployboot deployrefused; do
  out=$("$PWSH" -NoProfile -File "$HERE/wu-deploy-prevpass-test.ps1" -Defect $k 2>&1); rc=$?
  if [ $rc -eq 1 ] && printf '%s\n' "$out" | grep -q '^FAIL '; then echo "PASS  defect $k: suite FAILED as required ($(printf '%s\n' "$out" | grep -m1 '^FAIL' | cut -c1-110))"
  else echo "FAIL  defect $k: the suite did not fail (rc=$rc) - that guard is decoration"; bad=1; fi
done
exit $bad
