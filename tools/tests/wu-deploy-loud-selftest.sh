#!/usr/bin/env bash
# wu-deploy-loud-selftest.sh - the Windows Update agent deploy under a running updater pass (a scan is waited for on the real
# mutex, bounded by the scan task's limit; a full pass, an expired bound, an unknown holder refuse) and the installer's loud
# reporting of a refused deploy (ERROR, updater_agent_failed -> ok:false, result-flags.py red, the plain-words verdict, the dom0
# notification). Clean must pass; each knob must make the suite FAIL (a guard never seen to fail is decoration). Offline: pwsh 7
# runs the shipped regions of guest/install-updater-agent.ps1 and packaging/setup/Install-QwtImproved.ps1 against a second pwsh
# process that really holds the named mutex, a fake scheduled-task reader, a fake deploy script, the shipped notification route
# with its test hooks, and the real mgmt/harness/result-flags.py.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
PWSH="${PWSH:-/home/user/.local/pwsh/pwsh}"
[ -x "$PWSH" ] || PWSH=/home/user/pwsh/pwsh
[ -x "$PWSH" ] || PWSH="$(command -v pwsh || true)"
[ -n "$PWSH" ] || { echo "FAIL  no pwsh - nothing ran (missing data fails)"; exit 2; }
bad=0
out=$("$PWSH" -NoProfile -File "$HERE/wu-deploy-loud-test.ps1" 2>&1); rc=$?
if [ $rc -eq 0 ]; then echo "PASS  clean: $(printf '%s\n' "$out" | grep -c '^ok') checks"; else echo "FAIL  clean (rc=$rc): $(printf '%s\n' "$out" | grep -m1 '^FAIL')"; printf '%s\n' "$out" | grep '^FAIL' | sed 's/^/        /'; bad=1; fi
for k in scanwait waitbound fullrefuse abandonedscan abandonedfull freshrecord deployerror deployflag deployfold deployverdict deploynotify; do
  out=$("$PWSH" -NoProfile -File "$HERE/wu-deploy-loud-test.ps1" -Defect $k 2>&1); rc=$?
  if [ $rc -eq 1 ] && printf '%s\n' "$out" | grep -q '^FAIL '; then echo "PASS  defect $k: suite FAILED as required ($(printf '%s\n' "$out" | grep -m1 '^FAIL' | cut -c1-120))"
  else echo "FAIL  defect $k: the suite did not fail (rc=$rc) - that guard is decoration"; bad=1; fi
done
exit $bad
