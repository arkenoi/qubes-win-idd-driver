#!/bin/bash
# SG6 FAIL-PROOF — make the autologon checker go RED against the canonical measured defect.
#
# WHY IT IS OWED. H5: a check counts as evidence only once it has been seen to FAIL with the defect
# deliberately present. SG6's positive (AutoAdminLogon=1, AutoLogonCount absent, task Ready, windows
# map) has never been seen to go red, so it emits PASS-UNPROVEN. And the shipped selftest cannot
# supply it: `wu-autologon-selftest.ps1` builds its negative by deleting a REGISTRY DefaultPassword
# that our installer deliberately never writes (the credential is the LSA secret), so it skips and
# reports INCONCLUSIVE.
#
# THE DEFECT REPRODUCED HERE is the one actually measured on 2026-08-28: disarm BOTH
# `AutoAdminLogon` AND the re-assert task, then COLD BOOT. Expected red: the guest answers qrexec
# while mapping ZERO windows - running, reachable, and completely invisible, with no password box
# anywhere. That is the field condition from forum posts 98/101, and it is why autologon is enforced.
#
# SG0.8: StandaloneVM only. An AppVM's volatile root reverts HKLM before the reboot that would
# exercise the change, so the arm silently does nothing there. Never a template.
#
#   mgmt/harness/sg6-failproof.sh <standalone-vm>
#
# Exit 0 = the checker went RED as required (fail-proof earned). 1 = it did NOT go red (the checker
# is not a checker). 2 = could not run.
set -uo pipefail
cd /home/user/qubes-win-idd-driver
VM="${1:?usage: $0 <standalone-vm>}"
OUT="${2:-$HOME/qwt-accept/20260830-acceptance-4.3.16/SG6-failproof-$VM}"
mkdir -p "$OUT"
q(){ QTEST_VM=$VM timeout -k 8 "${T:-120}" ./tools/qtest "$@" 2>/dev/null; }

klass=$(qvm-prefs "$VM" klass 2>/dev/null)
[ "$klass" = StandaloneVM ] || { echo "REFUSING: $VM is $klass. SG0.8 requires a StandaloneVM - an AppVM reverts HKLM before the reboot."; exit 2; }

boot_and_wait(){
  timeout -k 10 150 qvm-start "$VM" >/dev/null 2>&1 & disown
  sleep 30
  for i in $(seq 1 40); do
    q run 'cmd /c echo ALIVE' | grep -qa ALIVE && return 0
    sleep 15
  done
  return 1
}
windows_mapped(){
  local t="$OUT/$1.tar"; rm -f "$t"
  q shot "$t" >/dev/null 2>&1
  [ -s "$t" ] && tar tf "$t" 2>/dev/null | grep -c '\.png$' || echo 0
}

echo "=== 1. CONTROL: with autologon armed, windows MUST map (else the later red proves nothing) ==="
[ "$(qvm-ls --raw-data --fields STATE "$VM" | tail -1)" = Halted ] || qvm-shutdown --wait --timeout 300 "$VM" >/dev/null 2>&1
boot_and_wait || { echo "FATAL: $VM never answered qrexec in the control"; exit 2; }
q run 'cmd /c start "" notepad.exe' >/dev/null; sleep 10
ctrl=$(windows_mapped control)
echo "  control: $ctrl window(s) mapped, qrexec alive"
q run 'cmd /c taskkill /f /im notepad.exe' >/dev/null 2>&1
[ "${ctrl:-0}" -ge 1 ] || { echo "FATAL: control mapped no windows - the subject is already broken, a red would be meaningless"; exit 2; }

echo "=== 2. PLANT THE DEFECT: disarm AutoAdminLogon AND the re-assert task ==="
cat > /home/user/.claude/jobs/c2a0f57b/tmp/sg6-disarm.ps1 <<'PS'
$ErrorActionPreference='Continue'
$WL='HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
Set-ItemProperty $WL -Name AutoAdminLogon -Value '0' -Type String
& schtasks /change /tn QubesAutologonGuard /disable *>$null
& schtasks /delete /tn QubesAutologonGuard /f *>$null
Write-Output ('AutoAdminLogon ' + (Get-ItemProperty $WL -Name AutoAdminLogon).AutoAdminLogon)
Write-Output ('GuardTask ' + $(if (Get-ScheduledTask -TaskName QubesAutologonGuard -EA SilentlyContinue) {'STILL PRESENT'} else {'REMOVED'}))
PS
T=300 q pushrun /home/user/.claude/jobs/c2a0f57b/tmp/sg6-disarm.ps1 | tr -d '\r' | grep -aE '^(AutoAdminLogon|GuardTask)' | sed 's/^/  /' | tee "$OUT/disarm.txt"

echo "=== 3. COLD BOOT (SG0.7 - never an agent restart) ==="
qvm-shutdown --wait --timeout 300 "$VM" >/dev/null 2>&1
boot_and_wait || { echo "the guest did not answer qrexec at all - that is a DIFFERENT failure than the one under test"; exit 1; }
echo "  qrexec answers"
sleep 45
red=$(windows_mapped defect)
echo "  with autologon disarmed: $red window(s) mapped, qrexec alive"

echo "=== 4. VERDICT ==="
if [ "${red:-0}" -eq 0 ]; then
  echo "RED AS REQUIRED: qrexec answers while ZERO windows map - the invisible-guest condition."
  echo "SG6's checker is now seen-to-fail; its PASS may be cited as PASS (H5), not PASS-UNPROVEN."
  rc=0
else
  echo "NOT RED: $red window(s) still mapped with autologon disarmed."
  echo "Either the defect was not planted, or the checker cannot detect it. SG6 stays PASS-UNPROVEN."
  rc=1
fi

echo "=== 5. RE-ARM and confirm the guest comes back (never leave a subject locked out) ==="
cat > /home/user/.claude/jobs/c2a0f57b/tmp/sg6-rearm.ps1 <<'PS'
$ErrorActionPreference='Continue'
$WL='HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
Set-ItemProperty $WL -Name AutoAdminLogon -Value '1' -Type String
& powershell -NoProfile -ExecutionPolicy Bypass -File 'C:\Program Files\Qubes Tools\qubes-rpc-services\ensure-autologon.ps1' *>&1 | Out-Null
Write-Output ('AutoAdminLogon ' + (Get-ItemProperty $WL -Name AutoAdminLogon).AutoAdminLogon)
Write-Output ('GuardTask ' + $(if (Get-ScheduledTask -TaskName QubesAutologonGuard -EA SilentlyContinue) {'present'} else {'ABSENT'}))
PS
T=300 q pushrun /home/user/.claude/jobs/c2a0f57b/tmp/sg6-rearm.ps1 | tr -d '\r' | grep -aE '^(AutoAdminLogon|GuardTask)' | sed 's/^/  /'
qvm-shutdown --wait --timeout 300 "$VM" >/dev/null 2>&1
boot_and_wait && { back=$(windows_mapped rearmed); echo "  after re-arm: $back window(s) mapped"; } || echo "  WARNING: guest did not return after re-arm"
exit $rc
