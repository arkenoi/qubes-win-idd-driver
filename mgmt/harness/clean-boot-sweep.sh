#!/bin/bash
# clean-boot-sweep.sh - the error-line capture of a NORMAL boot on a build that carries the fixes.
#
#   mgmt/harness/clean-boot-sweep.sh <vm> <outdir> [installed-setup-tree]
#
# This is the measurement Jev named as the gap between this project and the standing condition's
# first clause (no-capture-from-a-current-build 0.65, then archived-clean-boot 0.98). It archives
# the guest's logs first, so the capture is THAT boot's by construction - the guest writes a PER-DAY
# log per module, and without this a capture carries every earlier boot and every induced failure of
# the same day (measured 2026-10-09: 30 induced lines from three earlier cells).
#   HYPOTHESIS a normal boot of the current build writes ZERO error-level lines, and none of the 13
#              families in findings/issues.md ERRORINV appears.
#   BASELINE   the same families on the OLD builds: win11-acc 35 lines, win10-acc 11 lines, both
#              captured today (scratchpad/sweep-win11-acc, scratchpad/sweep-win10-acc).
#   VARIABLE   the build: the subject was upgraded from the release package minutes earlier.
#   INSTRUMENT mgmt/harness/log-sweep.sh (missing data FAILS, counts verified by sha) + a per-family
#              count taken from the capture by tools/errfam.py, which is the comparison that matters.
#   BUDGET     shutdown 600 s, boot+settle <=420 s, sweep <=900 s; every wait names its exit.
set -uo pipefail
cd /home/user/qubes-win-idd-driver || exit 2
VM="${1:?usage: $0 <vm> <outdir> [installed-setup-tree] - name the subject; there is no default target}"
OUT="${2:-scratchpad/sweep-$VM-current}"
say(){ printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
. mgmt/harness/vmlock.sh
vm_lock "$VM" || { say "REFUSED: vmlock busy"; exit 3; }
. mgmt/harness/shutdown-lib.sh
ps1(){ QTEST_VM=$VM timeout 180 tools/qtest run "powershell -NoProfile -EncodedCommand $(printf '%s' "$1" | iconv -f UTF-8 -t UTF-16LE | base64 -w0)" 2>&1; }

# PROVENANCE FIRST: the running agent must be the package's, or this measures the golden's build.
# The tree is NAMED by the cell that installed it (scratchpad/last-setup.txt) - a glob over
# /home/user/qwt-accept/* took the alphabetically last package and failed this check against a build
# the guest never had (measured 2026-10-09: 7722a5ca vs e086b214, both real packages).
SETUP="${3:-$(cat scratchpad/last-setup.txt 2>/dev/null)}"
[ -n "$SETUP" ] && [ -s "$SETUP/reference/gui-agent.exe" ] \
  || { say "FAIL no installed package tree named - pass it as \$3 or let the install cell write scratchpad/last-setup.txt"; exit 2; }
ref=$(sha256sum "$SETUP/reference/gui-agent.exe" | awk '{print $1}')
say "reference from $SETUP: ${ref:0:12}"

# BASELINE THE ACCUMULATING STATE (experimenter rule 14). The guest writes a PER-DAY log per
# module, so a capture of "this boot" otherwise carries every earlier boot and every induced
# failure of the same day - measured 2026-10-09, where a clean-boot capture reported 30 induced
# QGAVCHANFAIL lines from three earlier cells. Archiving to a SIBLING directory (not a subdirectory
# of the log dir, which the collector walks) makes the capture this boot's by construction, with no
# clock and no per-line filtering involved.
say "--- archiving the guest's existing logs so the capture is THIS boot's"
arch=$(ps1 "\$d='Q:\Qubes Logs'; \$a='Q:\Qubes Logs Archive\' + (Get-Date -Format yyyyMMdd-HHmmss)
if (-not (Test-Path \$d)) { Write-Host 'ARCH=nologdir'; exit }
New-Item -ItemType Directory -Force -Path \$a | Out-Null
\$f=@(Get-ChildItem -LiteralPath \$d -File -EA SilentlyContinue)
\$moved=0
foreach (\$x in \$f) { try { Move-Item -LiteralPath \$x.FullName -Destination \$a -Force -EA Stop; \$moved++ } catch { } }
Write-Host ('ARCH=' + \$moved + '/' + \$f.Count)" | command grep -ao 'ARCH=[0-9a-z/]*' | head -1)
say "archived: ${arch:-UNKNOWN}"
case "${arch:-}" in
  ARCH=0/0|ARCH=nologdir) say "FAIL nothing archived and no log dir - the guest is not in the state this cell measures"; exit 2 ;;
  ARCH=*) ;;
  *) say "FAIL could not archive the existing logs; a capture now would carry earlier boots"; exit 2 ;;
esac

say "--- clean cold boot (no induction, no hammering)"
qwt_shutdown "$VM" 600 >/dev/null 2>&1
SINCE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
timeout 300 qvm-start "$VM" >/dev/null 2>&1
up=0
for i in $(seq 1 42); do
  if QTEST_VM=$VM timeout 40 tools/qtest run 'cmd /c echo QREADY' 2>/dev/null | command grep -qa '^QREADY'; then up=1; break; fi
  sleep 10
done
[ "$up" = 1 ] || { say "FAIL qrexec never answered after the clean boot"; exit 4; }
say "qrexec up; letting the boot settle 120 s so late starters are in the capture"
sleep 120

got=$(ps1 "(Get-FileHash -Algorithm SHA256 'C:\Program Files\Qubes Tools\bin\gui-agent.exe').Hash" | tr -d '\r' | command grep -aoE '[0-9A-Fa-f]{64}' | head -1)
if [ "${got,,}" = "${ref,,}" ]; then say "PROVENANCE OK running gui-agent == package reference"
else say "FAIL running gui-agent ${got:0:12} != package reference ${ref:0:12} - this would measure the wrong build"; exit 2; fi

say "--- sweep since $SINCE"
rm -rf "$OUT"
timeout 900 mgmt/harness/log-sweep.sh "$VM" "$SINCE" "$OUT" > "$OUT.log" 2>&1; src=$?
say "log-sweep rc=$src"
[ -d "$OUT/logs" ] || { say "FAIL no logs/ in the capture - nothing measured"; tail -8 "$OUT.log"; exit 2; }
say "--- per-family error-line counts, this capture vs the two old ones"
python3 tools/errfam.py "$OUT/logs" scratchpad/sweep-win11-acc/logs scratchpad/sweep-win10-acc/logs
say "evidence: $OUT  (sweep log $OUT.log)"
