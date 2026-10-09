#!/bin/bash
# vchan-collapse-debug-cell.sh - grade the ONE-LINE vchan report at LogLevel 4, where the DEBUG
# replay lists every held record and the line can be checked against it.
#
#   mgmt/harness/vchan-collapse-debug-cell.sh <subject>
#
# Capture a FAILED connect at LogLevel 4, where the DEBUG replay lists every held record. That is
# the only way to check the one line against the hold - the guest's line says "8 library record(s)"
# and prints 3 distinct summing to 4.
#   HYPOTHESIS the early-boot departed-peer condition recurs on a cold boot (it fired twice in the
#              first 60 s of this guest's upgrade boots), and at LogLevel 4 the replay is complete.
#   BASELINE   the same guest, same binary, two QGAVCHANFAIL lines at LogLevel 3 with no replay.
#   VARIABLE   LogLevel 4 across the boot.
#   INSTRUMENT the guest's wrapper logs; LogLevel restored at exit; missing data FAILS.
#   BUDGET     shutdown 600 s, boot+qrexec <=420 s, read 120 s.
set -uo pipefail
cd /home/user/qubes-win-idd-driver || exit 2
VM="${1:?usage: $0 <subject> - name the subject; there is no default target}"
say(){ printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
. mgmt/harness/vmlock.sh
vm_lock "$VM" || { say "REFUSED: vmlock busy"; exit 3; }
. mgmt/harness/shutdown-lib.sh
ps1(){ QTEST_VM=$VM timeout 180 tools/qtest run "powershell -NoProfile -EncodedCommand $(printf '%s' "$1" | iconv -f UTF-8 -t UTF-16LE | base64 -w0)" 2>&1; }
K='HKLM:\SOFTWARE\Invisible Things Lab\Qubes Tools'
before=$(ps1 "\$p=Get-ItemProperty '$K' -Name LogLevel -EA SilentlyContinue; if(\$p){Write-Host ('LL='+[int]\$p.LogLevel)}else{Write-Host 'LL=-'}" | command grep -ao 'LL=[-0-9]*' | head -1)
say "LogLevel before: ${before:-unknown}"
[ -n "$before" ] || { say "FAIL could not read LogLevel"; exit 2; }
ps1 "Set-ItemProperty '$K' -Name LogLevel -Value 4 -Type DWord; Write-Host ('NOW='+[int](Get-ItemProperty '$K' -Name LogLevel).LogLevel)" | command grep -ao 'NOW=[0-9]*'
restore(){ if [ "$before" = "LL=-" ]; then ps1 "Remove-ItemProperty '$K' -Name LogLevel -EA SilentlyContinue; Write-Host RESTORED-ABSENT" | command grep -ao 'RESTORED[A-Z-]*'
           else ps1 "Set-ItemProperty '$K' -Name LogLevel -Value ${before#LL=} -Type DWord; Write-Host RESTORED" | command grep -ao 'RESTORED'; fi; }
trap 'say "restoring LogLevel"; restore || say "WARN LogLevel not restored - it is ${before}"' EXIT

say "--- cold boot at LogLevel 4"
qwt_shutdown "$VM" 600 >/dev/null 2>&1
timeout 300 qvm-start "$VM" >/dev/null 2>&1
up=0
for i in $(seq 1 42); do
  if QTEST_VM=$VM timeout 40 tools/qtest run 'cmd /c echo QREADY' 2>/dev/null | command grep -qa '^QREADY'; then up=1; break; fi
  sleep 10
done
[ "$up" = 1 ] || { say "FAIL qrexec never answered"; exit 4; }
say "qrexec up; hammering 40 short calls too, then reading"
for i in $(seq 1 40); do QTEST_VM=$VM timeout 0.3 tools/qtest run 'cmd /c ver' >/dev/null 2>&1 || true; done
sleep 5
cat > /tmp/claude-1000/faildbg.ps1 <<'PS1'
$d='Q:\Qubes Logs'
$fs=@(Get-ChildItem -LiteralPath $d -Filter 'qrexec-wrapper*.log' -EA SilentlyContinue)
$hit=@(); $drop=0
foreach ($f in $fs) {
  $L=@(Get-Content -LiteralPath $f.FullName -EA SilentlyContinue)
  if (@($L | Where-Object { $_ -match 'QGAVCHANFAIL' }).Count -gt 0) { $hit += $f.FullName }
  $drop += @($L | Where-Object { $_ -match 'past the \d+ held were dropped' }).Count
}
$cont=0
foreach ($f in $fs) {
  $cont += @(Get-Content -LiteralPath $f.FullName -EA SilentlyContinue | Where-Object { $_ -match '^\s*\|' }).Count
}
Write-Output ("FD-HITFILES=" + $hit.Count + " DROPWARNS=" + $drop + " CONTINUATIONS=" + $cont)
foreach ($p in ($hit | Select-Object -Last 1)) {
  Write-Output ("FD-FILE " + $p)
  $L=@(Get-Content -LiteralPath $p)
  # the collapsed line, then EVERY line of that instance so the replay is visible in order
  foreach ($l in $L) { Write-Output ("FD| " + $l) }
}
PS1
QTEST_VM=$VM timeout 300 tools/qtest pushrun /tmp/claude-1000/faildbg.ps1 > scratchpad/faildbg.txt 2>&1
command grep -aE '^FD-' scratchpad/faildbg.txt | head -3
echo "--- lines in that instance: $(command grep -ac '^FD|' scratchpad/faildbg.txt)"
command grep -aE '^FD\|.*(QGAVCHANFAIL|dropped|XifHold)' scratchpad/faildbg.txt | cut -c1-300
say "evidence: scratchpad/faildbg.txt"

# lint L19: this cell boots a guest, so it reports on the error log it leaves behind. The boot above
# runs at LogLevel 4 with induced failures, so the sweep needs its own clean boot - which is what
# clean-boot-sweep.sh does, with the guest's logs archived first.
say "--- clean boot + sweep"
bash mgmt/harness/clean-boot-sweep.sh "$VM" "scratchpad/sweep-$VM-after-debug-cell"; srv=$?
say "clean-boot-sweep rc=$srv"
