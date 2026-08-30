#!/bin/bash
# SG6 FAIL-PROOF — make the autologon checker go RED against the canonical measured defect.
#
# WHY IT IS OWED. H5: a check counts as evidence only once it has been seen to FAIL with the defect
# deliberately present. SG6's positive (AutoAdminLogon=1, AutoLogonCount absent, task Ready, windows
# map) has never been seen to go red, so it emits PASS-UNPROVEN. The shipped selftest cannot supply
# it: `wu-autologon-selftest.ps1` builds its negative by deleting a REGISTRY DefaultPassword that our
# installer deliberately never writes (the credential is the LSA secret), so it skips.
#
# THE DEFECT REPRODUCED HERE is the one measured on 2026-08-28: disarm BOTH `AutoAdminLogon` AND the
# re-assert task, then COLD BOOT. Expected red: the guest answers qrexec while NOBODY IS LOGGED ON -
# running, reachable, and completely invisible, with no password box anywhere in dom0. That is the
# field condition from forum posts 98/101, and it is why autologon is enforced.
#
# ============================ THREE RULES THIS FILE EXISTS TO ENCODE ==========================
#
# 1. NEVER `pushrun` ANYTHING ONCE THE DEFECT IS PLANTED.
#    `qtest push` is qubes.Filecopy, and its destination is QubesIncoming under the LOGGED-ON USER's
#    Documents folder. With autologon disarmed there is no logged-on user, GetFolderPath('MyDocuments')
#    is empty for SYSTEM, and the copy fails - silently, from the caller's point of view.
#    MEASURED 2026-08-31: the previous version used `pushrun` for BOTH the defect-state probe AND the
#    re-arm. The probe returned nothing (so the assertion it existed for was never available) and
#    THE RE-ARM NEVER RAN AT ALL - the subject was left at LogonUI with AutoAdminLogon=0 and the guard
#    task deleted, needing manual inline repair. A fail-proof that bricks its own subject is worse
#    than no fail-proof. Everything from step 2 on uses inline `qtest run`.
#
# 2. "ZERO WINDOWS" CANNOT BE THE DECISIVE EVIDENCE, IN EITHER DIRECTION.
#    `local.WinScreenshot` exits 1 with an EMPTY body both when the guest maps no windows and when
#    the service itself fails; it writes the distinction to a stderr qrexec does not forward. A count
#    of 0 is therefore genuinely ambiguous, and a gate keyed on it either passes blindly (the
#    original bug) or refuses every legitimate red (the over-correction I shipped hours later, which
#    made this cell unrunnable). The verdict is the POSITIVE assertion of the defect state - qrexec
#    alive, no Active session, no explorer - with the window count recorded as corroboration only.
#
# 3. THE SUBJECT COMES BACK, AND THAT IS VERIFIED, NOT ASSUMED.
#    Re-arm restores AutoAdminLogon, re-runs the shipped ensure-autologon.ps1 IN PLACE, and
#    re-registers the guard task from the installer's own XML. Then it cold-boots and REQUIRES a
#    logged-on session before reporting success, printing the manual repair commands if not.
#
# SG0.8: StandaloneVM only. An AppVM's volatile root reverts HKLM before the reboot that would
# exercise the change, so the arm silently does nothing there. Never a template.
#
#   mgmt/harness/sg6-failproof.sh <standalone-vm>
#
# Exit 0 = the checker went RED as required (fail-proof earned). 1 = it did NOT go red. 2 = could
# not run, or the subject did not come back (reported loudly, with the repair commands).
set -uo pipefail
cd /home/user/qubes-win-idd-driver
VM="${1:?usage: $0 <standalone-vm>}"
OUT="${2:-$HOME/qwt-accept/20260830-acceptance-4.3.16/SG6-failproof-$VM}"
mkdir -p "$OUT"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
log(){ echo "$(date -u +%H:%M:%S) sg6[$VM]: $*" | tee -a "$OUT/sg6.log"; }
# INLINE ONLY - see rule 1. Never pushrun in this script.
#
# AND IT STRIPS THE COMMAND ECHO. `qtest run` returns the guest cmd.exe banner and the PROMPT LINE
# WITH THE COMMAND ON IT, e.g. `C:\Windows\system32>cmd /c tasklist /fi "imagename eq explorer.exe"`.
# That echoed line CONTAINS the very string the counters below grep for, so every count came back
# one too high and every reg read matched the value name twice. Measured 2026-08-31: the defect was
# reproduced perfectly - sessions=0, LogonUI up, autologon 0 - and the run still reported
# `explorer=1` (the echo alone) and therefore NOT RED, plus a mangled `autologon=AutoAdminLogon\n0`.
# The instrument said no while the subject said yes.
r(){ QTEST_VM=$VM timeout -k 8 "${T:-150}" ./tools/qtest run "$1" 2>/dev/null | tr -d '\r' \
     | grep -avE '^(Microsoft Windows \[Version|\(c\) Microsoft|C:\\)'; }

klass=$(qvm-prefs "$VM" klass 2>/dev/null)
[ "$klass" = StandaloneVM ] || { log "REFUSING: $VM is $klass. SG0.8 requires a StandaloneVM."; exit 2; }

WL='HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
ENSURE='C:\Program Files\Qubes Tools\qubes-rpc-services\ensure-autologon.ps1'
rc=0

boot_and_wait(){
  timeout -k 10 200 qvm-start "$VM" >/dev/null 2>&1 & disown
  sleep 35
  for _ in $(seq 1 40); do
    r 'cmd /c echo ALIVE' | grep -qa ALIVE && return 0
    sleep 15
  done
  return 1
}
shutdown_now(){ timeout -k 10 320 qvm-shutdown --wait --timeout 260 "$VM" >/dev/null 2>&1; sleep 5; }

# "<count>|<capture_ok>" - capture_ok annotates, it never decides (rule 2).
windows_mapped(){
  local t="$OUT/$1.tar"; rm -f "$t"
  QTEST_VM=$VM timeout -k 8 180 ./tools/qtest shot "$t" >/dev/null 2>&1
  local n=0 ok=yes
  [ -s "$t" ] || ok=no
  if [ "$ok" = yes ]; then n=$(tar tf "$t" 2>/dev/null | grep -c '\.png$'); n=${n:-0}; fi
  echo "$n|$ok"
}

# The defect state, asserted POSITIVELY and entirely inline.
session_count(){  r 'cmd /c query user'                                          | grep -acE '^[ >]*[A-Za-z0-9_.-]+ +console'; }
explorer_count(){ r 'cmd /c tasklist /fi "imagename eq explorer.exe" /nh'        | grep -ac 'explorer\.exe'; }
logonui_count(){  r 'cmd /c tasklist /fi "imagename eq LogonUI.exe" /nh'         | grep -ac 'LogonUI\.exe'; }
autologon_val(){  r "cmd /c reg query \"$WL\" /v AutoAdminLogon" | grep -a 'REG_SZ' | awk '{print $NF}' | head -1; }
guard_present(){  r 'cmd /c schtasks /query /tn QubesAutologonGuard 2>&1' | grep -qa 'QubesAutologonGuard *N/A' && echo yes || echo no; }
state_block(){ echo "    sessions=$(session_count) explorer=$(explorer_count) logonui=$(logonui_count) autologon=$(autologon_val) guard=$(guard_present)"; }

# --------------------------------------------------------------- 1. control
log "=== 1. CONTROL: an armed guest must have a SESSION and map a window ==="
[ "$(qvm-ls --raw-data --fields STATE "$VM" | tail -1)" = Halted ] || shutdown_now
boot_and_wait || { log "FATAL: $VM never answered qrexec in the control"; exit 2; }
sleep 20
r 'cmd /c start "" notepad.exe' >/dev/null 2>&1; sleep 14
cd0=$(windows_mapped control); ctrl=${cd0%%|*}; cok=${cd0#*|}
cs=$(session_count)
log "  control: sessions=$cs windows=$ctrl (capture_ok=$cok)"
r 'cmd /c taskkill /f /im notepad.exe' >/dev/null 2>&1
[ "${cs:-0}" -ge 1 ]   || { log "FATAL: no session in the control - the subject is already broken; a red would be meaningless"; exit 2; }
[ "${ctrl:-0}" -ge 1 ] || { log "FATAL: control mapped no windows (capture_ok=$cok) - fix that before claiming a red"; exit 2; }

# --------------------------------------------------------------- 2. plant
log "=== 2. PLANT THE DEFECT: AutoAdminLogon=0 AND remove the re-assert task ==="
r "cmd /c reg add \"$WL\" /v AutoAdminLogon /t REG_SZ /d 0 /f" | grep -aiE 'success|error' | sed 's/^/    /'
r 'cmd /c schtasks /delete /tn QubesAutologonGuard /f'         | grep -aiE 'success|error' | sed 's/^/    /'
log "  planted:"; state_block

# --------------------------------------------------------------- 3. cold boot
log "=== 3. COLD BOOT (SG0.7 - never an agent restart) ==="
shutdown_now
boot_and_wait || { log "the guest never answered qrexec - a DIFFERENT failure than the one under test"; rc=1; }
sleep 30
rd=$(windows_mapped defect); red=${rd%%|*}; rok=${rd#*|}
ds=$(session_count); de=$(explorer_count); dl=$(logonui_count); da=$(autologon_val)
log "  defect state: sessions=$ds explorer=$de logonui=$dl autologon=$da windows=$red (capture_ok=$rok)"
printf 'sessions=%s explorer=%s logonui=%s autologon=%s windows=%s capture_ok=%s\n' \
  "$ds" "$de" "$dl" "$da" "$red" "$rok" > "$OUT/defect-state.txt"

# --------------------------------------------------------------- 4. verdict
log "=== 4. VERDICT ==="
if [ "${ds:-1}" -eq 0 ] && [ "${de:-1}" -eq 0 ]; then
  log "RED AS REQUIRED: qrexec answers while NOBODY IS LOGGED ON (sessions=0, explorer=0,"
  log "  logonui=$dl). The invisible-guest condition, asserted positively. Windows mapped: $red."
  log "  SG6's checker is seen-to-fail; its PASS may be cited as PASS (H5), not PASS-UNPROVEN."
  rc=0
else
  log "NOT RED: sessions=$ds explorer=$de with autologon disarmed. Either the defect was not planted"
  log "  or the guest logged on anyway. SG6 stays PASS-UNPROVEN."
  rc=1
fi

# --------------------------------------------------------------- 5. re-arm, INLINE
log "=== 5. RE-ARM (inline - there is no session to push a file into) ==="
r "cmd /c reg add \"$WL\" /v AutoAdminLogon /t REG_SZ /d 1 /f" | grep -aiE 'success|error' | sed 's/^/    /'
T=300 r "cmd /c powershell -NoProfile -ExecutionPolicy Bypass -File \"$ENSURE\"" | grep -aE '^(ok|WARN|=== RESULT)' | sed 's/^/    /'
# Re-register the guard task from the installer's own XML (guest/install-updater-agent.ps1:189-209).
python3 - > "$TMP/guard.b64" <<'PY'
import base64
ps = r'''
$alPath = 'C:\Program Files\Qubes Tools\qubes-rpc-services\ensure-autologon.ps1'
$alXml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Description>QWT-NG: keep Windows autologon configured, so the qube stays reachable over qrexec after updates</Description></RegistrationInfo>
  <Triggers><BootTrigger><Enabled>true</Enabled><Delay>PT30S</Delay></BootTrigger></Triggers>
  <Principals><Principal id="Author"><UserId>S-1-5-18</UserId><RunLevel>HighestAvailable</RunLevel></Principal></Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <StartWhenAvailable>true</StartWhenAvailable>
    <ExecutionTimeLimit>PT5M</ExecutionTimeLimit>
    <AllowHardTerminate>true</AllowHardTerminate>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
  </Settings>
  <Actions Context="Author"><Exec><Command>powershell.exe</Command><Arguments>-NoProfile -ExecutionPolicy Bypass -File "$alPath"</Arguments></Exec></Actions>
</Task>
"@
$fa = Join-Path $env:TEMP 'qubes-autologon-guard.xml'
[IO.File]::WriteAllText($fa, $alXml, [Text.Encoding]::Unicode)
$o = & schtasks /create /tn QubesAutologonGuard /xml $fa /f 2>&1
Write-Output ("GUARD_REGISTER rc=$LASTEXITCODE " + ($o -join ' '))
'''
print(base64.b64encode(ps.encode('utf-16-le')).decode(), end='')
PY
r "cmd /c powershell -NoProfile -EncodedCommand $(cat "$TMP/guard.b64")" | grep -a GUARD_REGISTER | sed 's/^/    /'
log "  re-armed:"; state_block

# --------------------------------------------------------------- 6. prove it came back
log "=== 6. CONFIRM THE SUBJECT COMES BACK (never leave it at a sign-in screen) ==="
shutdown_now
if boot_and_wait; then
  sleep 25
  bs=$(session_count); bd=$(windows_mapped rearmed); bw=${bd%%|*}
  log "  after re-arm: sessions=$bs windows=$bw"
  if [ "${bs:-0}" -lt 1 ]; then
    log "  *** SUBJECT NOT REPAIRED *** no logged-on session. Repair inline (NOT pushrun):"
    log "      tools/qtest run 'cmd /c reg add \"$WL\" /v AutoAdminLogon /t REG_SZ /d 1 /f'"
    log "      tools/qtest run 'cmd /c powershell -File \"$ENSURE\"'"
    rc=2
  fi
else
  log "  *** SUBJECT DID NOT RETURN *** qrexec never answered after the re-arm boot"; rc=2
fi
exit $rc
