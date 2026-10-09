#!/bin/bash
# deskstuck-notice-cell.sh - drive the sign-in/lock path on a guest, every arm that is SAFE to drive.
#
#   mgmt/harness/deskstuck-notice-cell.sh <vm> [outdir]
#
# WHY. dom0 was sent "The guest is waiting at the sign-in or lock screen" (QERR_SEV_ACTION, next
# steps "arm autologon in the guest") for win10-acc on a clean-install first boot whose autologon WAS
# armed and which logged in moments later - the owner caught it during an acceptance campaign. The
# gate was `now >= s_SecureNextWarn` with SECURE_DESKTOP_FIRST_WARN_MS = 30000 and nothing else: a
# clock measuring boot speed and reporting it as a fault. See findings/issues.md NOTIFYCLOCK.
#
# WHAT THE AGENT DOES NOW. It no longer asks a human to arm autologon - it removes the CAUSE where
# that needs no credential, confirms it, and says nothing; dom0 hears only what the agent cannot
# repair. The measured cause: while AutoLogonCount is present Windows CONSUMES DefaultPassword and
# then falls back to the sign-in screen, and a cumulative update rewrites Winlogon and brings the
# count back (measured 2026-08-13 on win11-tpl, recovery took a root-volume revert).
#
#   ARM A  healthy (armed, no count, password present)
#            -> dom0 gets NOTHING. Asserted on the SENT counter, not on a log line: a healthy boot
#               leaves the secure desktop in ~15-17 s and may never reach the 30 s warn at all, so
#               requiring a "dom0 NOT notified" line would fail a guest that behaved perfectly.
#               (That is what the first version of this cell got wrong.)
#   ARM B  AutoLogonCount PRESENT - the real historical condition, set by an update
#            -> the agent DELETES it, confirms it is gone, and dom0 gets nothing. Owner: "so we do
#               it silently, no need to warn user we had to re-enable."
#   ARM B2 AutoAdminLogon=0
#            -> the agent sets it to 1, confirms, and dom0 gets nothing.
#   ARM C  session LOCKED
#            -> reported AT ONCE, inside 20 s, i.e. before the 30 s warn point. "if it is locked it
#               should be detected fast."
#   ARM D  DefaultUserName cleared - nothing to log in as, which the agent cannot fix
#            -> dom0 IS notified, at once. This is the arm that proves the route was not simply
#               silenced: it is the condition the two field reports were about ("absolutely nothing
#               is visible", forum posts 98/101).
#
# WHAT IS DELIBERATELY NOT DRIVEN, AND WHY - this is coverage this cell does not have, not a pass.
# AL_PASSWORD_GONE (the consumed-password end state) would require deleting the guest's autologon
# password from BOTH stores, and by the doctrine this whole change rests on - "we do not know the
# password and will not invent one" - that is irrecoverable: the credential cannot be put back, so
# the arm would permanently break the subject rather than test it. ARM D exercises the same dom0
# route through a condition that IS restorable. The AL_PASSWORD_GONE branch therefore has no
# guest-side evidence, and that is stated here rather than left for a reader to assume.
#
# ARMS B, B2 AND D LEAVE THE GUEST UNREACHABLE IF THEY ARE NOT UNDONE: autologon is how this project
# recovers a lockout. Every value this cell touches is read FIRST, restored by an EXIT trap, and
# re-asserted and READ BACK before the cell reports anything. If the restore cannot be proven the
# cell exits 2 and says a human is needed, rather than claiming a result.
#
# INSTRUMENT: counts, never the clock. These guests boot ~3 h ahead and sync-clock-from-dom0 corrects
# ~60 s in, so a timestamp window would discard exactly the records being counted. The agent-log
# reads are scoped by the pid the RUNNING instance wrote into its own line prefix, so one arm's lines
# cannot be counted into another's verdict.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2
VM="${1:?usage: $0 <vm> [outdir] - name the subject; there is no default target}"
OUT="${2:-scratchpad/deskstuck-$VM-$(date -u +%H%M%S)}"
say(){ printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
mkdir -p "$OUT" || exit 2

. mgmt/harness/vmlock.sh
vm_lock "$VM" || { say "REFUSED: vmlock busy"; exit 3; }
. mgmt/harness/shutdown-lib.sh

ps1(){ QTEST_VM=$VM timeout "${T:-240}" tools/qtest run \
         "cmd /c powershell -NoProfile -EncodedCommand $(printf '%s' "$1" | iconv -f UTF-8 -t UTF-16LE | base64 -w0)" 2>&1 | tr -d '\r'; }

WL='HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'

# ---- the values this cell disturbs, read BEFORE anything changes --------------------------------
ORIG=$(ps1 "\$p = Get-ItemProperty -Path '$WL' -ErrorAction SilentlyContinue
Write-Host ('ORIG auto=' + \$p.AutoAdminLogon + ' user=' + \$p.DefaultUserName + ' count=' + \$(if (\$null -ne \$p.AutoLogonCount) { \$p.AutoLogonCount } else { 'absent' }))" \
  | command grep -ao 'ORIG .*' | head -1)
say "before: ${ORIG:-UNREADABLE}"
O_USER=$(printf '%s' "$ORIG" | command grep -ao 'user=[^ ]*' | head -1 | cut -d= -f2-)
[ -n "${O_USER// /}" ] || { say "REFUSING: $VM has no DefaultUserName to begin with - arm D could not be"
                            say "          told apart from the guest's own state, and the restore would"
                            say "          have nothing to put back"; exit 2; }

restore_all(){
  ps1 "Set-ItemProperty -Path '$WL' -Name AutoAdminLogon  -Value '1'        -Type String
Set-ItemProperty -Path '$WL' -Name DefaultUserName -Value '$O_USER' -Type String
Remove-ItemProperty -Path '$WL' -Name AutoLogonCount -Force -ErrorAction SilentlyContinue
\$p = Get-ItemProperty -Path '$WL'
Write-Host ('RESTORED auto=' + \$p.AutoAdminLogon + ' user=' + \$p.DefaultUserName + ' count=' + \$(if (\$null -ne \$p.AutoLogonCount) { \$p.AutoLogonCount } else { 'absent' }))" \
    | command grep -ao 'RESTORED .*' | head -1
}
trap 'say "restoring autologon"; restore_all || say "WARN restore FAILED on $VM - DO IT BY HAND"' EXIT

ready(){ local i p; p=$(mktemp); printf 'R\n' > "$p"
  for i in $(seq 1 42); do
    if QTEST_VM=$VM timeout 40 tools/qtest run 'cmd /c echo QREADY' 2>/dev/null | command grep -qa '^QREADY'; then
      if QTEST_VM=$VM timeout 90 tools/qtest push "$p" >/dev/null 2>&1; then rm -f "$p"; return 0; fi
    fi
    sleep 10
  done
  rm -f "$p"; return 1; }

# SENT is the only positive record that dom0 was TOLD something, as opposed to the log mentioning it:
# the notification route writes a marker + count per reported id under its state dir.
READ_PS='$ag = @(Get-Process -Name "gui-agent" -ErrorAction SilentlyContinue)
if ($ag.Count -eq 0) { Write-Output "R agent=0 restored=0 gone=0 unprov=0 locked=0 sent=0 auto=? count=?"; exit }
$p = $ag[0].Id
$pidRx = "-" + $p + ":[0-9]+-[A-Z]\]"
$d = ""
try { $d = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Invisible Things Lab\Qubes Tools" -ErrorAction Stop).LogDir } catch { }
$restored = 0; $gone = 0; $unprov = 0; $locked = 0
if ($d -and (Test-Path -LiteralPath $d)) {
  foreach ($f in @(Get-ChildItem -LiteralPath $d -Filter "gui-agent-*.log" -ErrorAction SilentlyContinue)) {
    foreach ($h in @(Select-String -LiteralPath $f.FullName -Pattern $pidRx -ErrorAction SilentlyContinue)) {
      $l = $h.Line
      if ($l -match "QGAAUTOLOGON autologon restored")        { $restored++ }
      if ($l -match "QGAAUTOLOGON the autologon password")     { $gone++ }
      if ($l -match "QGAAUTOLOGON autologon is NOT provisioned") { $unprov++ }
      if ($l -match "the session is LOCKED")                   { $locked++ }
    }
  }
}
$sent = 0
foreach ($base in @("$env:ProgramData\Qubes\qerr", "$env:ProgramData\Qubes Tools\qerr", "Q:\qerr")) {
  if (Test-Path -LiteralPath $base) {
    $sent += @(Get-ChildItem -LiteralPath $base -Recurse -Filter "*desktop-stuck*" -ErrorAction SilentlyContinue).Count
  }
}
$w = Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" -ErrorAction SilentlyContinue
$cnt = if ($null -ne $w.AutoLogonCount) { $w.AutoLogonCount } else { "absent" }
Write-Output ("R agent=" + $p + " restored=" + $restored + " gone=" + $gone + " unprov=" + $unprov + " locked=" + $locked + " sent=" + $sent + " auto=" + $w.AutoAdminLogon + " count=" + $cnt)'

field(){ printf '%s' "$2" | command grep -ao "$1=[0-9]*" | head -1 | cut -d= -f2; }

# SENT is cumulative per boot, so each arm is graded on a cleared counter.
clear_sent(){ ps1 'foreach ($b in @("$env:ProgramData\Qubes\qerr","$env:ProgramData\Qubes Tools\qerr","Q:\qerr")) {
  if (Test-Path -LiteralPath $b) { Get-ChildItem -LiteralPath $b -Recurse -Filter "*desktop-stuck*" -EA SilentlyContinue | Remove-Item -Force -EA SilentlyContinue }
}
Write-Host "CLEARED"' | command grep -ao 'CLEARED' | head -1; }

boot_and_read(){ # <tag>
  qwt_shutdown "$VM" 600 >/dev/null 2>&1
  timeout 300 qvm-start "$VM" >/dev/null 2>&1
  ready || { say "TERMINAL: $VM never became ready in arm $1"; return 4; }
  sleep 60                      # past the 30 s warn point, so a late report cannot be missed
  QTEST_VM=$VM timeout 120 tools/qtest synctime >/dev/null 2>&1 || true
  local r; r=$(ps1 "$READ_PS" | command grep -ao '^R .*' | head -1)
  printf '%s\n' "$r" | tee -a "$OUT/arm-$1.txt"
}

rc=0
pass(){ say "ARM $1 PASS: $2"; }
fail(){ say "ARM $1 FAIL: $2"; rc=1; }
num(){ printf '%s' "${1:-x}" | command grep -qE '^[0-9]+$'; }

# ---- ARM A: healthy - dom0 gets nothing ---------------------------------------------------------
say "--- ARM A: healthy autologon, one boot - dom0 must get NOTHING"
ps1 "Set-ItemProperty -Path '$WL' -Name AutoAdminLogon -Value '1' -Type String
Remove-ItemProperty -Path '$WL' -Name AutoLogonCount -Force -ErrorAction SilentlyContinue
Write-Host 'SET'" | command grep -ao SET | head -1
clear_sent >/dev/null
A=$(boot_and_read A) || exit 4
say "ARM A: $A"
[ "$(field sent "$A")" = 0 ] && pass A "no desktop-stuck notification was sent on a healthy boot" \
                             || fail A "dom0 was notified on a healthy boot (sent=$(field sent "$A"))"

# ---- ARM C: LOCKED - at once (before anything is disturbed) -------------------------------------
say "--- ARM C: lock the session - must be reported AT ONCE"
clear_sent >/dev/null
ps1 'rundll32.exe user32.dll,LockWorkStation; Write-Host "LOCK requested"' | command grep -ao 'LOCK .*' | head -1
sleep 20          # inside the 30 s warn point: a report that needed the warn would fail this arm
C=$(ps1 "$READ_PS" | command grep -ao '^R .*' | head -1); say "ARM C: $C"
cl=$(field locked "$C"); cs=$(field sent "$C")
{ num "$cl" && num "$cs" && [ "$cl" -ge 1 ] && [ "$cs" -ge 1 ]; } \
  && pass C "the lock was reported within 20 s, before the warn point" \
  || fail C "no lock report inside 20 s (locked=${cl:-?} sent=${cs:-?})"
qwt_shutdown "$VM" 600 >/dev/null 2>&1; timeout 300 qvm-start "$VM" >/dev/null 2>&1; ready || true

# ---- ARM B: AutoLogonCount present - silently removed -------------------------------------------
say "--- ARM B: AutoLogonCount present (what an update does) - must be removed SILENTLY"
ps1 "Set-ItemProperty -Path '$WL' -Name AutoLogonCount -Value 1 -Type DWord
Write-Host ('SET count=' + (Get-ItemProperty -Path '$WL').AutoLogonCount)" | command grep -ao 'SET .*' | head -1
clear_sent >/dev/null
B=$(boot_and_read B) || exit 4
say "ARM B: $B"
br=$(field restored "$B"); bs=$(field sent "$B")
{ num "$br" && [ "$br" -ge 1 ] && [ "$bs" = 0 ] && printf '%s' "$B" | command grep -q 'count=absent'; } \
  && pass B "the count was deleted and confirmed absent, at INFO, with dom0 told nothing" \
  || fail B "expected a QGAAUTOLOGON restored line, count=absent and sent=0 (restored=${br:-?} sent=${bs:-?})"

# ---- ARM B2: AutoAdminLogon=0 - silently set back -----------------------------------------------
say "--- ARM B2: AutoAdminLogon=0 - must be set back SILENTLY"
ps1 "Set-ItemProperty -Path '$WL' -Name AutoAdminLogon -Value '0' -Type String; Write-Host 'SET'" | command grep -ao SET | head -1
clear_sent >/dev/null
B2=$(boot_and_read B2) || exit 4
say "ARM B2: $B2"
b2r=$(field restored "$B2"); b2s=$(field sent "$B2")
{ num "$b2r" && [ "$b2r" -ge 1 ] && [ "$b2s" = 0 ] && printf '%s' "$B2" | command grep -q 'auto=1'; } \
  && pass B2 "AutoAdminLogon was set back to 1 and read back, with dom0 told nothing" \
  || fail B2 "expected a restored line, auto=1 and sent=0 (restored=${b2r:-?} sent=${b2s:-?})"

# ---- ARM D: nothing to log in as - dom0 is told, at once ----------------------------------------
say "--- ARM D: DefaultUserName cleared - the agent cannot fix it, so dom0 MUST be told"
ps1 "Set-ItemProperty -Path '$WL' -Name DefaultUserName -Value '' -Type String; Write-Host 'SET'" | command grep -ao SET | head -1
clear_sent >/dev/null
D=$(boot_and_read D) || exit 4
say "ARM D: $D"
du=$(field unprov "$D"); ds=$(field sent "$D")
{ num "$du" && num "$ds" && [ "$du" -ge 1 ] && [ "$ds" -ge 1 ]; } \
  && pass D "the unfixable case was reported to dom0 - the route is not silenced" \
  || fail D "the route did NOT fire with no DefaultUserName (unprov=${du:-?} sent=${ds:-?})"

# ---- restore, and PROVE it ----------------------------------------------------------------------
say "--- restoring autologon and proving it took"
restore_all
rb=$(ps1 "\$p = Get-ItemProperty -Path '$WL'
Write-Host ('NOW auto=' + \$p.AutoAdminLogon + ' user=' + \$p.DefaultUserName + ' count=' + \$(if (\$null -ne \$p.AutoLogonCount) { \$p.AutoLogonCount } else { 'absent' }))" \
  | command grep -ao 'NOW .*' | head -1)
say "$rb"
{ printf '%s' "$rb" | command grep -q 'auto=1' \
  && printf '%s' "$rb" | command grep -q "user=$O_USER" \
  && printf '%s' "$rb" | command grep -q 'count=absent'; } \
  || { say "FATAL: autologon is NOT restored on $VM (wanted auto=1 user=$O_USER count=absent) - a human is needed"; exit 2; }

# lint L19: arms C and D deliberately make the agent report, so the sweep needs its own CLEAN boot,
# taken after the restore is proven, with the logs archived before it.
say "--- clean boot + sweep (the log this cell leaves behind)"
bash mgmt/harness/clean-boot-sweep.sh "$VM" "$OUT/sweep" "${RELTREE:-}" >"$OUT/sweep.out" 2>&1; srv=$?
say "clean-boot-sweep rc=$srv  (evidence $OUT/sweep)"
command grep -aE 'ERROR lines attributed to the LAST boot|PROVENANCE' "$OUT/sweep.out" 2>/dev/null | head -3

say "NOT DRIVEN: AL_PASSWORD_GONE - simulating it means deleting the guest's autologon password from"
say "            both stores, which cannot be undone ('we do not know the password and will not"
say "            invent one'). That branch has no guest-side evidence."
[ "$rc" = 0 ] && say "PASS: the agent fixes what it can SILENTLY, reports only what it cannot, and waits for nothing" \
              || say "FAIL: the sign-in path does not behave as designed"
say "evidence: $OUT"
exit $rc
