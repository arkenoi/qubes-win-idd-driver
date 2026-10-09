#!/bin/bash
# fi-monstale-cell.sh - drive the stale-monitor-handle fix with its fault PRESENT, both arms.
#
#   mgmt/harness/fi-monstale-cell.sh <vm>
#
# WHY. A stale monitor handle is a display-change race: MonitorFromWindow hands back a monitor that
# existed a moment ago and GetMonitorInfo then answers ERROR_INVALID_MONITOR_HANDLE. Measured on
# win10-acc, ONE such failure was reported TWICE ("GetMonitorInfo failed failed with error 0x5b5",
# then "GetRealWindowRect failed" naming a function that is not where it failed) and the window went
# UNMEASURED, so dom0 kept its old geometry. The fix re-acquires the handle; if the second ask
# succeeds the race is DEMONSTRATED rather than assumed and the window is measured after all.
#
# A FIX NOBODY HAS SEEN FAIL IS NOT EVIDENCE, which is why this cell exists: FI_MON_STALE makes
# GetMonitorSettings report that status on demand, before the monitor cache so a cached hit cannot
# serve the fault away.
#   ARM A (1 shot)  the first ask fails, the re-acquire succeeds: the window must STILL be measured
#                   and QGAMONSTALE must count it, with NO "failed twice" error line.
#                   With the OLD code this arm produced two error lines and no measurement.
#   ARM B (2 shots) both asks fail: exactly ONE error line naming GetMonitorInfo, and ZERO lines
#                   from the caller - the double report is what the fix removes.
#
# REQUIREMENTS, each asserted rather than assumed:
#   * the subject runs a FAULT-INJECTION build (qwt-full -f fault_injection=true). A release binary
#     compiles the knob out, so the arms would both read "clean" and mean nothing - the rz24 trap.
#   * the QGAFAULT-INIT line must show monstale=<n>, which proves THIS knob is in THAT binary.
#   * the fault arms 60 s after the agent starts (FAULT_DEFAULT_ARM_DELAY_SEC), so the window that
#     consumes a shot has to be created AFTER that, not at boot.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2
VM="${1:?usage: $0 <vm> - name the subject; there is no default target}"
OUT="${2:-scratchpad/fi-monstale-$VM}"
say(){ printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
mkdir -p "$OUT" || exit 2

. mgmt/harness/vmlock.sh
vm_lock "$VM" || { say "REFUSED: vmlock busy"; exit 3; }
. mgmt/harness/shutdown-lib.sh
K='HKLM:\SOFTWARE\Invisible Things Lab\Qubes Tools\gui-agent'
ps1(){ QTEST_VM=$VM timeout "${T:-240}" tools/qtest run \
         "powershell -NoProfile -EncodedCommand $(printf '%s' "$1" | iconv -f UTF-8 -t UTF-16LE | base64 -w0)" 2>&1; }
wait_qrexec(){ for _i in $(seq 1 42); do
    if QTEST_VM=$VM timeout 40 tools/qtest run 'cmd /c echo QREADY' 2>/dev/null | command grep -qa '^QREADY'; then return 0; fi
    sleep 10; done; return 1; }
restore(){ ps1 "Remove-ItemProperty '$K' -Name FaultMonStale -EA SilentlyContinue; Write-Host 'KNOB=removed'" \
             | command grep -ao 'KNOB=removed' || say "WARN could not remove FaultMonStale - do it by hand"; }
trap 'say "restoring the knob"; restore' EXIT

# One arm: shots -> reboot -> window after the arming delay -> read the agent log.
run_arm(){
  local shots="$1" tag="$2"
  say "--- ARM $tag: FaultMonStale=$shots"
  ps1 "if (-not (Test-Path '$K')) { New-Item '$K' -Force | Out-Null }
Set-ItemProperty '$K' -Name FaultMonStale -Value $shots -Type DWord
Write-Host ('KNOB=' + [int](Get-ItemProperty '$K' -Name FaultMonStale).FaultMonStale)" \
    | command grep -ao 'KNOB=[0-9]*' | head -1
  qwt_shutdown "$VM" 600 >/dev/null 2>&1
  timeout 300 qvm-start "$VM" >/dev/null 2>&1
  wait_qrexec || { say "FAIL qrexec never answered in arm $tag"; return 4; }

  # The fault arms 60 s after the agent starts. Create the window AFTER that, and create it here
  # rather than poking an installed app: Notepad/Paint are absent on some of these guests
  # (recorded 2026-09-30), so a cell that depends on one measures nothing on those.
  say "    waiting out the 60 s arming delay, then creating a window for 25 s"
  sleep 75
  T=240 ps1 "Add-Type -AssemblyName System.Windows.Forms
\$f = New-Object System.Windows.Forms.Form
\$f.Text = 'x'; \$f.Width = 420; \$f.Height = 300
\$f.StartPosition = 'CenterScreen'
\$f.Show(); \$f.Refresh()
1..25 | ForEach-Object { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Seconds 1 }
\$f.Close()
Write-Host 'WINDOW=done'" | command grep -ao 'WINDOW=done' | head -1

  cat > "$OUT/read-$tag.ps1" <<'PS1'
# SCOPED TO THE RUNNING AGENT, not to the file. These logs are PER DAY, so both arms of this cell
# write into the same file on the same day - an unscoped count would carry arm A's QGAMONSTALE into
# arm B's total and could inherit an error line arm A wrote, which would invert arm B's verdict.
# The anchor is what the process itself wrote: its pid in the line prefix
# ([date.time.ms-<pid>:<tid>-LEVEL]), which needs no clock - and the guest's clock flips ~3 h about
# 60 s into every boot, so a timestamp window is not usable here. (lint L20)
$ag = @(Get-Process -Name 'gui-agent' -EA SilentlyContinue)
if ($ag.Count -eq 0) { Write-Output 'FI-INIT=0 KNOB= FIRED=0 QGAMONSTALE=0 TWICE=0 CALLER=0 NOAGENT=1'; exit }
$agentPid = $ag[0].Id
$pidRx = "-$agentPid" + ":[0-9]+-[A-Z]\]"
$d='Q:\Qubes Logs'
$init=0; $knob=''; $fired=0; $stale=0; $twice=0; $caller=0; $seen=0
foreach ($x in @(Get-ChildItem -LiteralPath $d -Filter 'gui-agent-*.log' -EA SilentlyContinue)) {
  foreach ($h in @(Select-String -LiteralPath $x.FullName -Pattern $pidRx -EA SilentlyContinue)) {
    $l = $h.Line; $seen++
    if ($l -match 'QGAFAULT-INIT build=QGA-FAULT-INJECTION:on') { $init++ }
    if ($l -match 'QGAFAULT-INIT .*monstale=(\d+)')             { $knob=$Matches[1] }
    if ($l -match 'QGAFAULT FI_MON_STALE')                      { $fired++ }
    if ($l -match 'QGAMONSTALE')                                { $stale++ }
    if ($l -match 'GetMonitorInfo failed twice')                { $twice++ }
    if ($l -match 'GetRealWindowRect failed')                   { $caller++ }
  }
}
Write-Output ("FI-INIT=$init KNOB=$knob FIRED=$fired QGAMONSTALE=$stale TWICE=$twice CALLER=$caller PIDLINES=$seen AGENTPID=$agentPid")
PS1
  QTEST_VM=$VM timeout 300 tools/qtest pushrun "$OUT/read-$tag.ps1" > "$OUT/read-$tag.out" 2>&1
  command grep -aE '^FI-INIT=' "$OUT/read-$tag.out" | head -1
}

read_field(){ command grep -ao "$1=[0-9]*" "$2" | head -1 | cut -d= -f2; }

run_arm 1 A || exit 4
A="$OUT/read-A.out"
init=$(read_field FI-INIT "$A"); knob=$(read_field KNOB "$A"); fired=$(read_field FIRED "$A")
stale=$(read_field QGAMONSTALE "$A"); twice=$(read_field TWICE "$A"); caller=$(read_field CALLER "$A")
say "ARM A: fi-build=${init:-?} knob-in-binary=${knob:-absent} fault-fired=${fired:-?} QGAMONSTALE=${stale:-?} failed-twice=${twice:-?} caller-lines=${caller:-?}"
[ "${init:-0}" -ge 1 ] || { say "INSTRUMENT: this subject is NOT running a fault-injection build - both arms would read clean and mean nothing"; exit 2; }
[ -n "${knob:-}" ]     || { say "INSTRUMENT: QGAFAULT-INIT carries no monstale= field, so this knob is not in that binary"; exit 2; }
[ "${fired:-0}" -ge 1 ] || { say "INVALID: the fault never fired, so nothing was measured (no window reached GetMonitorSettings after the arming delay)"; exit 2; }
armA=0
[ "${stale:-0}" -ge 1 ] && [ "${twice:-0}" = 0 ] && armA=1
[ "$armA" = 1 ] && say "ARM A PASS: the re-acquire measured the window (QGAMONSTALE) and no error line was written" \
                || say "ARM A FAIL: expected QGAMONSTALE>=1 and failed-twice=0"

run_arm 2 B || exit 4
B="$OUT/read-B.out"
fired2=$(read_field FIRED "$B"); twice2=$(read_field TWICE "$B"); caller2=$(read_field CALLER "$B")
say "ARM B: fault-fired=${fired2:-?} failed-twice=${twice2:-?} caller-lines=${caller2:-?}"
[ "${fired2:-0}" -ge 1 ] || { say "INVALID: the fault never fired in arm B"; exit 2; }
armB=0
[ "${twice2:-0}" -ge 1 ] && [ "${caller2:-0}" = 0 ] && armB=1
[ "$armB" = 1 ] && say "ARM B PASS: one error line naming GetMonitorInfo, and NO second line from the caller" \
                || say "ARM B FAIL: expected failed-twice>=1 and caller-lines=0 (the double report)"

if [ "$armA" = 1 ] && [ "$armB" = 1 ]; then
  say "PASS: the monitor-handle fix measured on a guest with its fault present, both arms"
  rc=0
else
  say "FAIL: the fix does not behave as designed under its own fault"
  rc=1
fi

# lint L19: a cell that boots a guest reports on the error log it leaves behind. Arm B deliberately
# writes an error line, so the sweep needs its own clean boot - with the knob removed by the trap.
say "--- clean boot + sweep"
restore >/dev/null 2>&1
bash mgmt/harness/clean-boot-sweep.sh "$VM" "scratchpad/sweep-$VM-after-fi-monstale"; srv=$?
say "clean-boot-sweep rc=$srv"
exit $rc
