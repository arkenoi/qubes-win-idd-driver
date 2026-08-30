#!/bin/bash
# P4 RUNNER — BENCH-2, BENCH-1 and the automatable RND cells, with the update scan PROVABLY disarmed.
#
# WHY THIS EXISTS. P3's standing rules already said "never concurrent with a benchmark/rendering
# part ... a mid-benchmark scan raises the proxy and churns qrexec (wedge trigger)". On 2026-08-30
# that rule was read into the session and then broken: a guest was cold-booted at ~17:52 with the
# scheduled scan due at ~17:54 (boot + PT2M) and BENCH-2 was started at ~17:53. The guest wedged
# mid-benchmark and every number from that session was void. The rule existed; an executable step
# did not. This is the step.
#
#   mgmt/harness/p4-run.sh <vm> [outdir]
#
# Exit 0 = the part ran with the scan disarmed throughout. 1 = a cell failed. 2 = could not
# establish the precondition (in which case NOTHING is run - an unmeasured cell beats a bad number).
set -uo pipefail
cd /home/user/qubes-win-idd-driver
VM="${1:?usage: $0 <vm> [outdir]}"
OUT="${2:-$HOME/qwt-accept/20260830-acceptance-4.3.16/P4-$VM}"
mkdir -p "$OUT"
q(){ QTEST_VM=$VM timeout -k 8 "${T:-120}" ./tools/qtest "$@" 2>/dev/null; }
log(){ echo "$(date -u +%H:%M:%S) p4[$VM]: $*" | tee -a "$OUT/p4.log"; }

# ---------------------------------------------------------------- precondition
log "=== G-0c: disarm QubesWindowsUpdateScan BEFORE anything runs ==="
cat > /home/user/.claude/jobs/c2a0f57b/tmp/p4-disarm.ps1 <<'PS'
$ErrorActionPreference='Continue'
$t = Get-ScheduledTask -TaskName QubesWindowsUpdateScan -EA SilentlyContinue
if (-not $t) { Write-Output 'SCAN_TASK ABSENT'; Write-Output 'DISARMED true'; exit 0 }
$i = Get-ScheduledTaskInfo -TaskName QubesWindowsUpdateScan -EA SilentlyContinue
Write-Output ('SCAN_BEFORE state=' + $t.State + ' nextrun=' + $i.NextRunTime)
& schtasks /change /tn QubesWindowsUpdateScan /disable *>$null
# Kill a pass that is ALREADY running - disabling the task does not stop a live one, and a live
# one is exactly the condition the rule exists to prevent.
$p = Get-Process qubes-updates-relay -EA SilentlyContinue
if ($p) { Write-Output ('RELAY_RUNNING ' + $p.Count + ' - stopping'); $p | Stop-Process -Force -EA SilentlyContinue }
Start-Sleep -Seconds 2
$t2 = Get-ScheduledTask -TaskName QubesWindowsUpdateScan -EA SilentlyContinue
Write-Output ('SCAN_AFTER state=' + $t2.State)
Write-Output ('RELAY_AFTER ' + @(Get-Process qubes-updates-relay -EA SilentlyContinue).Count)
Write-Output ('DISARMED ' + ($t2.State -eq 'Disabled'))
PS
dis=$(T=300 q pushrun /home/user/.claude/jobs/c2a0f57b/tmp/p4-disarm.ps1 | tr -d '\r')
echo "$dis" | grep -aE '^(SCAN_BEFORE|SCAN_AFTER|RELAY_|DISARMED)' | sed 's/^/  /' | tee "$OUT/disarm.txt"
echo "$dis" | grep -qa 'DISARMED True' || { log "FATAL: could not disarm the scan - refusing to run. An unmeasured cell beats a bad number."; exit 2; }
log "scan disarmed and verified"

restore(){
  log "=== re-enabling QubesWindowsUpdateScan ==="
  q run 'cmd /c schtasks /change /tn QubesWindowsUpdateScan /enable & echo REENABLED' | tr -d '\r' | grep -a REENABLED | sed 's/^/  /'
}
trap restore EXIT

rc=0
# ---------------------------------------------------------------- BENCH-2
log "=== BENCH-2: idle CPU, 3 x 120 s ==="
for r in 1 2 3; do
  v=$(T=600 q pushrun guest/cpu-bench.ps1 -IdleSec 120 | tr -d '\r' | grep -aoE 'BENCH .*' | head -1)
  log "  run $r: ${v:-NO RESULT}"
  echo "$v" >> "$OUT/bench2.txt"
done

# ---------------------------------------------------------------- BENCH-1
log "=== BENCH-1: 3 runs, scroll p50 is the metric that can carry a verdict ==="
for n in 1 2 3; do
  QTEST_VM=$VM bash tools/bench-agent.sh "$(basename "$OUT")-r$n" >/dev/null 2>&1
  s=$(bash instrumentation/bench-phases.sh "$(basename "$OUT")-r$n" 2>/dev/null | grep -aE '^scroll' | tr -s ' ')
  log "  run $n: ${s:-NO RESULT (agent alive?)}"
  echo "$s" >> "$OUT/bench1.txt"
  [ -z "$s" ] && { log "  BENCH-1 run $n produced nothing - stopping the part and preserving the guest (G-0)"; rc=1; break; }
done

# ---------------------------------------------------------------- RND-7
if [ "$rc" = 0 ]; then
  log "=== RND-7: compound chrome - 5 HWNDs guest-side, exactly 1 mapped ==="
  q push artifacts/chromerepro.exe >/dev/null 2>&1
  q run 'cmd /c start "" C:\Users\user\Documents\QubesIncoming\win-idd-mgmt\chromerepro.exe' >/dev/null 2>&1
  sleep 20
  hw=$(T=300 q pushrun /home/user/.claude/jobs/c2a0f57b/tmp/enumwin.ps1 | tr -d '\r' | grep -aoE 'CHROMEREPRO_HWNDS [0-9]+' | awk '{print $2}')
  rm -f "$OUT/rnd7.tar"; q shot "$OUT/rnd7.tar" >/dev/null 2>&1
  mapped=$(tar tf "$OUT/rnd7.tar" 2>/dev/null | grep -c '\.png$'); mapped=${mapped:-0}
  log "  guest-side HWNDs=${hw:-?}  dom0 mapped=${mapped:-?}   (accept: 5 and 1)"
  echo "RND7 hwnds=${hw:-?} mapped=${mapped:-?}" >> "$OUT/rnd.txt"
  q run 'cmd /c taskkill /f /im chromerepro.exe' >/dev/null 2>&1
fi

# ---------------------------------------------------------------- RND-5
if [ "$rc" = 0 ]; then
  log "=== RND-5: Start must NOT be presented in seamless ==="
  T=400 q pushrun guest/open-start.ps1 >/dev/null 2>&1
  sleep 12
  rm -f "$OUT/rnd5.tar"; q shot "$OUT/rnd5.tar" >/dev/null 2>&1
  m5=$(tar tf "$OUT/rnd5.tar" 2>/dev/null | grep -c '\.png$'); m5=${m5:-0}
  d5=$(T=300 q pushrun /home/user/.claude/jobs/c2a0f57b/tmp/startproof.ps1 | tr -d '\r' | grep -aoE 'DISCRIM_HITS [0-9]+' | awk '{print $2}')
  log "  dom0 mapped=${m5:-?}  agent deny lines=${d5:-?}   (accept: 0 mapped AND >0 deny = stimulus existed)"
  echo "RND5 mapped=${m5:-?} deny=${d5:-?}" >> "$OUT/rnd.txt"
fi

log "=== P4 part finished rc=$rc ==="
exit $rc
