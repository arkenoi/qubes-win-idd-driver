#!/bin/bash
# deskstuck-notice-cell.sh - drive the sign-in/lock notification's THREE arms on a guest.
#
#   mgmt/harness/deskstuck-notice-cell.sh <vm>
#
# WHY. dom0 was sent "The guest is waiting at the sign-in or lock screen" (QERR_SEV_ACTION, next
# steps "arm autologon in the guest") for win10-acc on a clean-install first boot whose autologon
# WAS armed and which logged in moments later - the owner caught it during an acceptance campaign.
# The gate was `now >= s_SecureNextWarn` with SECURE_DESKTOP_FIRST_WARN_MS = 30000 and nothing else:
# a clock measuring boot speed and reporting it as a fault. See findings/issues.md NOTIFYCLOCK.
#
# A FIX NOBODY HAS SEEN FAIL IS NOT EVIDENCE (.claude/skills/experimenter rule 3), and this one has
# three distinct outcomes, so all three are driven:
#   ARM A  autologon ARMED, boot      -> the guest crosses the secure desktop on its way in and dom0
#                                        must be told NOTHING. The log must carry
#                                        "QGADESKSTUCK dom0 NOT notified".
#   ARM B  autologon DISARMED, boot   -> the guest stops at the sign-in screen and dom0 MUST be told;
#                                        this is the case the route exists for (the two field reports
#                                        where no log named the state). With the OLD code this arm
#                                        also passed - it is arm A that it got wrong - so B is the
#                                        control that proves the fix did not simply silence the route.
#   ARM C  session LOCKED             -> reported AT ONCE, not at the 30 s warn point. Owner:
#                                        "no one will wait for 10 minutes at locked machine."
#
# ARM B IS THE DANGEROUS ONE TO LEAVE BEHIND: it disarms autologon, which is how this project
# handles lockouts. The restore is an EXIT trap AND is re-asserted and verified before the cell
# reports anything, because a guest left with autologon off needs a human at a screen this harness
# cannot reach.
#
# INSTRUMENT: counts, never the clock. These guests boot ~3 h ahead and sync-clock-from-dom0
# corrects ~60 s in, so a timestamp window here would discard exactly the records being counted.
# The watermark is the line count of the agent log plus the notification state dir's own counters.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2
VM="${1:?usage: $0 <vm> - name the subject; there is no default target}"
OUT="${2:-scratchpad/deskstuck-$VM-$(date -u +%H%M%S)}"
say(){ printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
mkdir -p "$OUT" || exit 2

. mgmt/harness/vmlock.sh
vm_lock "$VM" || { say "REFUSED: vmlock busy"; exit 3; }
. mgmt/harness/shutdown-lib.sh

ps1(){ QTEST_VM=$VM timeout "${T:-240}" tools/qtest run \
         "cmd /c powershell -NoProfile -EncodedCommand $(printf '%s' "$1" | iconv -f UTF-8 -t UTF-16LE | base64 -w0)" 2>&1 | tr -d '\r'; }

WL='HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'

# RESTORE IS NOT OPTIONAL AND NOT BEST-EFFORT. Autologon is how this project handles lockouts
# (CLAUDE.md), so a guest left without it is a guest nobody can reach.
restore_autologon(){
  ps1 "Set-ItemProperty -Path '$WL' -Name AutoAdminLogon -Value '1' -Type String
Write-Host ('RESTORED AutoAdminLogon=' + (Get-ItemProperty -Path '$WL').AutoAdminLogon)" \
    | command grep -ao 'RESTORED .*' | head -1
}
trap 'say "restoring autologon"; restore_autologon || say "WARN could not restore autologon on $VM - DO IT BY HAND"' EXIT

ready(){ local i p; p=$(mktemp); printf 'R\n' > "$p"
  for i in $(seq 1 42); do
    if QTEST_VM=$VM timeout 40 tools/qtest run 'cmd /c echo QREADY' 2>/dev/null | command grep -qa '^QREADY'; then
      if QTEST_VM=$VM timeout 90 tools/qtest push "$p" >/dev/null 2>&1; then rm -f "$p"; return 0; fi
    fi
    sleep 10
  done
  rm -f "$p"; return 1; }

# What the agent and the notification route recorded. SCOPED BY the agent's own pid in the line
# prefix, so two arms on the same day cannot inherit each other's lines (the logs are per day).
READ_PS='$ag = @(Get-Process -Name "gui-agent" -ErrorAction SilentlyContinue)
if ($ag.Count -eq 0) { Write-Output "R agent=0 stuck=0 notnotified=0 locked=0 sent=0"; exit }
$p = $ag[0].Id
$pidRx = "-" + $p + ":[0-9]+-[A-Z]\]"
$d = ""
try { $d = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Invisible Things Lab\Qubes Tools" -ErrorAction Stop).LogDir } catch { }
$stuck = 0; $notnot = 0; $locked = 0
if ($d -and (Test-Path -LiteralPath $d)) {
  foreach ($f in @(Get-ChildItem -LiteralPath $d -Filter "gui-agent-*.log" -ErrorAction SilentlyContinue)) {
    foreach ($h in @(Select-String -LiteralPath $f.FullName -Pattern $pidRx -ErrorAction SilentlyContinue)) {
      $l = $h.Line
      if ($l -match "QGADESKSTUCK") { $stuck++ }
      if ($l -match "QGADESKSTUCK dom0 NOT notified") { $notnot++ }
      if ($l -match "the session is LOCKED") { $locked++ }
    }
  }
}
# The notification route writes a marker + count per reported id under its state dir; that is the
# only positive record that something was SENT, as opposed to logged.
$sent = 0
foreach ($base in @("$env:ProgramData\Qubes\qerr", "$env:ProgramData\Qubes Tools\qerr", "Q:\qerr")) {
  if (Test-Path -LiteralPath $base) {
    $sent += @(Get-ChildItem -LiteralPath $base -Recurse -Filter "*desktop-stuck*" -ErrorAction SilentlyContinue).Count
  }
}
Write-Output ("R agent=" + $p + " stuck=" + $stuck + " notnotified=" + $notnot + " locked=" + $locked + " sent=" + $sent)'

field(){ printf '%s' "$2" | command grep -ao "$1=[0-9]*" | head -1 | cut -d= -f2; }

boot_and_read(){ # <tag>
  qwt_shutdown "$VM" 600 >/dev/null 2>&1
  timeout 300 qvm-start "$VM" >/dev/null 2>&1
  ready || { say "TERMINAL: $VM never became ready in arm $1"; return 4; }
  # The notification fires at 30 s of secure desktop; give the boot past that before reading.
  sleep 60
  QTEST_VM=$VM timeout 120 tools/qtest synctime >/dev/null 2>&1 || true
  local r; r=$(ps1 "$READ_PS" | command grep -ao '^R .*' | head -1)
  printf '%s\n' "$r" | tee -a "$OUT/arm-$1.txt"
}

# ---- ARM A: autologon ARMED (the defect's condition) -------------------------------------------
say "--- ARM A: autologon ARMED, one boot - dom0 must be told NOTHING"
ps1 "Set-ItemProperty -Path '$WL' -Name AutoAdminLogon -Value '1' -Type String
Write-Host ('SET AutoAdminLogon=' + (Get-ItemProperty -Path '$WL').AutoAdminLogon)" | command grep -ao 'SET .*' | head -1
A=$(boot_and_read A) || exit 4
say "ARM A: $A"
a_not=$(field notnotified "$A"); a_sent=$(field sent "$A")

# ---- ARM C: LOCKED, before disarming anything --------------------------------------------------
say "--- ARM C: lock the session - must be reported AT ONCE"
ps1 'rundll32.exe user32.dll,LockWorkStation; Write-Host "LOCK requested"' | command grep -ao 'LOCK .*' | head -1
sleep 20          # well inside the 30 s warn point: a late report would fail this arm
C=$(ps1 "$READ_PS" | command grep -ao '^R .*' | head -1); say "ARM C: $C"
c_locked=$(field locked "$C")
# Unlock by logging the console session back in the only way available here: a reboot.
qwt_shutdown "$VM" 600 >/dev/null 2>&1; timeout 300 qvm-start "$VM" >/dev/null 2>&1; ready || true

# ---- ARM B: autologon DISARMED (the control - the route must still fire) -----------------------
say "--- ARM B: autologon DISARMED, one boot - dom0 MUST be told"
ps1 "Set-ItemProperty -Path '$WL' -Name AutoAdminLogon -Value '0' -Type String
Write-Host ('SET AutoAdminLogon=' + (Get-ItemProperty -Path '$WL').AutoAdminLogon)" | command grep -ao 'SET .*' | head -1
B=$(boot_and_read B) || exit 4
say "ARM B: $B"
b_stuck=$(field stuck "$B"); b_not=$(field notnotified "$B")

say "--- restoring autologon and proving it took"
restore_autologon
rb=$(ps1 "Write-Host ('NOW AutoAdminLogon=' + (Get-ItemProperty -Path '$WL').AutoAdminLogon)" | command grep -ao 'NOW .*' | head -1)
say "$rb"
printf '%s' "$rb" | command grep -q 'AutoAdminLogon=1' \
  || { say "FATAL: autologon is NOT restored on $VM - a human is needed at that guest"; exit 2; }

# lint L19: a cell that boots a guest reports on the error log it leaves behind. ARM B deliberately
# makes the agent write QGADESKSTUCK and send the notification, so the sweep needs its own CLEAN
# boot - taken after autologon is restored and proven, with the logs archived before it so the
# capture belongs to that boot by construction.
say "--- clean boot + sweep (the log this cell leaves behind)"
bash mgmt/harness/clean-boot-sweep.sh "$VM" "$OUT/sweep" "${RELTREE:-}" >"$OUT/sweep.out" 2>&1; srv=$?
say "clean-boot-sweep rc=$srv  (evidence $OUT/sweep)"
command grep -aE 'ERROR lines attributed to the LAST boot|PROVENANCE' "$OUT/sweep.out" 2>/dev/null | head -3

# ---- the verdict --------------------------------------------------------------------------------
rc=0
[ "${a_not:-0}" -ge 1 ] && say "ARM A PASS: armed autologon -> 'dom0 NOT notified' present" \
                        || { say "ARM A FAIL: expected a 'dom0 NOT notified' line with autologon armed"; rc=1; }
[ "${c_locked:-0}" -ge 1 ] && say "ARM C PASS: the lock was reported inside 20 s (before the 30 s warn point)" \
                           || { say "ARM C FAIL: no 'session is LOCKED' line within 20 s of locking"; rc=1; }
[ "${b_stuck:-0}" -ge 1 ] && [ "${b_not:-0}" = 0 ] \
  && say "ARM B PASS: disarmed autologon -> QGADESKSTUCK reported, and NOT suppressed" \
  || { say "ARM B FAIL: the route must still fire with autologon off (stuck=${b_stuck:-?} notnotified=${b_not:-?})"; rc=1; }

[ "$rc" = 0 ] && say "PASS: all three arms behave - the notification follows the fault, not a clock" \
              || say "FAIL: the notification does not behave as designed"
say "evidence: $OUT"
exit $rc
