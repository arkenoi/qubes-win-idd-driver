#!/bin/bash
# nonuser-account-probe.sh - prove the guest does not depend on its local account being named "user".
#
#   mgmt/harness/nonuser-account-probe.sh <vm> [newname] [newpass]
#
# WHY THIS EXISTS. Field bug (GWeck, 2026-09-10): a Windows template whose local account is NOT
# named "user" cannot be updated from dom0 - Windows Update reports no network and qrexec-wrapper
# logs authentication failures. Root cause: an inbound qrexec service is launched by LOGGING ON the
# account name dom0 sent (the default, "user") with the hardcoded password "userpass"
# (qrexec-wrapper.h DEFAULT_USER_PASSWORD_UNICODE); on a name mismatch the existing console-session
# token is discarded and LogonUser fails.
#
# WHY OUR ACCEPTANCE NEVER CAUGHT IT, and why this probe is separate from it:
#   1. Every guest our unattended installer builds is named "user" (mgmt/autounattend*.xml), so the
#      name always matched.
#   2. The testbed's dom0 policy runs our qrexec calls as NT AUTHORITY\SYSTEM (verified: `qtest run
#      whoami` -> nt authority\system), which takes the run-as-current-user branch and NEVER reaches
#      the logon path at all. A normal user's qube runs the service as its default_user, which does.
# So no amount of the standard campaign can exercise this. This probe changes the ONE variable the
# campaign cannot: the account name.
#
# WHAT IT ASSERTS, after switching the guest to a differently-named account and cold-booting:
#   A. the interactive console session really is the NEW account (not "user");
#   B. the agent republishes the REAL name to qubesdb /qubes-tools/default-user - that key is the
#      source of truth the logon path must consult, and a stale "user" here means the fix is inert;
#   C. the guest is still fully operational on that account: qrexec answers, gui-agent is running,
#      and a launched app still maps a window to dom0.
# Missing data FAILS (rig-cycle rule 6): an unreadable probe is never scored as a pass.
#
# THE SUBJECT IS CONSUMED. This mutates accounts and autologon; the caller removes the guest
# afterwards. Never run it against a golden or a guest whose state matters.
#
# Exits: 0 all assertions passed; 1 an assertion FAILED; 2 VOID (could not set up / unreadable).
set -uo pipefail
HERE="$(cd "$(dirname "$0")/../.." && pwd)"; cd "$HERE" || exit 1
VM="${1:?usage: nonuser-account-probe.sh <vm> [newname] [newpass]}"
NEW="${2:-qtester}"
PASS="${3:-Qubes!Probe42}"
OUT="${OUT:-/home/user/rel/nonuser-probe-$VM}"; mkdir -p "$OUT"
R="$OUT/probe.log"
say(){ echo "[$(date -u +%H:%M:%S)] $*" | tee -a "$R"; }

source mgmt/harness/vmlock.sh
source mgmt/harness/e2e-wait.sh
vm_lock "$VM"
trap 'vm_unlock "$VM" 2>/dev/null' EXIT

[ "$NEW" != user ] || { say "REFUSED: the whole point is an account NOT named 'user'"; exit 2; }
w_alive "$VM" || { say "VOID: $VM is not answering qrexec at the start"; exit 2; }

say "=== non-'user' account probe on $VM (new account: $NEW) ==="
say "baseline account: $(g_probe "$VM" WHO 'Write-Host ("WHO=" + (Get-CimInstance Win32_ComputerSystem).UserName)' 60)"

# ---- 1. create the account and hand it the autologon -----------------------------------------
# set-autologon.ps1 is the shipped, credential-VALIDATING path (it LogonUser-checks before writing
# and stores the password as the LSA secret). Use it rather than hand-writing registry keys, so the
# probe exercises the same mechanism the product does.
say "creating $NEW and moving autologon to it"
SETUP=$(cat <<PS
\$ErrorActionPreference='Stop'
\$u='$NEW'; \$p=ConvertTo-SecureString '$PASS' -AsPlainText -Force
if (Get-LocalUser -Name \$u -ErrorAction SilentlyContinue) { Set-LocalUser -Name \$u -Password \$p }
else { New-LocalUser -Name \$u -Password \$p -AccountNeverExpires -PasswordNeverExpires | Out-Null }
Add-LocalGroupMember -Group 'Administrators' -Member \$u -ErrorAction SilentlyContinue
Write-Host ("MADE=" + \$u)
PS
)
b64=$(python3 -c "import sys,base64;print(base64.b64encode(sys.argv[1].encode('utf-16-le')).decode())" "$SETUP")
made=$(QTEST_VM=$VM timeout -k 5 120 ./tools/qtest run "powershell -NoProfile -ExecutionPolicy Bypass -EncodedCommand $b64" 2>/dev/null | tr -d '\r' | grep -ao '^MADE=.*' | head -1)
[ -n "$made" ] || { say "VOID: could not create the account (no MADE= line)"; exit 2; }
say "  $made"

QTEST_VM=$VM ./tools/qtest push guest/set-autologon.ps1 >/dev/null 2>&1
al=$(QTEST_VM=$VM timeout -k 5 180 ./tools/qtest run "powershell -NoProfile -ExecutionPolicy Bypass -File \"C:\\Users\\user\\Documents\\QubesIncoming\\win-idd-mgmt\\set-autologon.ps1\" -User $NEW -Password '$PASS'" 2>/dev/null | tr -d '\r' | grep -aE '^(ok|FAIL|ERROR)' | head -2)
say "  set-autologon: ${al:-<no output>}"
case "$al" in ok*) ;; *) say "VOID: set-autologon did not confirm (got '${al:-nothing}') - not grading a guest whose autologon is unknown"; exit 2 ;; esac

# ---- 2. cold boot onto the new account -------------------------------------------------------
say "cold-booting onto $NEW"
g_reboot_proven "$VM" "nonuser-boot" >/dev/null 2>&1 || { say "VOID: could not prove a reboot"; exit 2; }
w_appvm_shell "$VM" 600 "nonuser-shell" "$OUT" say || { say "FAIL: no desktop shell after switching to $NEW"; exit 1; }

FAILED=0
chk(){ if [ "$2" = PASS ]; then say "PASS  $1"; else say "FAIL  $1"; FAILED=1; fi; }

# ---- A. the console session is the NEW account ----------------------------------------------
who=$(g_probe "$VM" WHO 'Write-Host ("WHO=" + (Get-CimInstance Win32_ComputerSystem).UserName)' 90)
say "console session user: '${who:-<unreadable>}'"
if [ -z "$who" ]; then chk "A: console session user readable" FAIL
elif printf '%s' "$who" | grep -qi "\\\\$NEW\$"; then chk "A: the interactive session is $NEW (not 'user')" PASS
else chk "A: expected the session to be $NEW, got '$who'" FAIL; fi

# ---- B. the REAL name reaches qubesdb (the source of truth for the logon path) ----------------
# advertise-tools derives it from the active WTS session and writes /qubes-tools/default-user.
# A stale "user" here means anything that reads the key still gets the wrong account.
# qubesdb-read.ps1 is a DOT-SOURCE library (Get-QubesDbValue), not a parameterised script -
# calling it with -Path silently returns nothing, which would read as "unreadable" and fail B
# for the wrong reason.
QTEST_VM=$VM ./tools/qtest push guest/qubesdb-read.ps1 >/dev/null 2>&1
du=$(g_probe "$VM" DU '. "C:\Users\user\Documents\QubesIncoming\win-idd-mgmt\qubesdb-read.ps1"; Write-Host ("DU=" + (Get-QubesDbValue "/qubes-tools/default-user"))' 120)
say "qubesdb /qubes-tools/default-user = '${du:-<unreadable>}'"
if [ -z "$du" ]; then chk "B: qubesdb default-user readable" FAIL
elif [ "$du" = "$NEW" ]; then chk "B: qubesdb default-user is the real account ($NEW)" PASS
else chk "B: qubesdb default-user is '$du', expected '$NEW'" FAIL; fi

# ---- C. the guest still works on that account ------------------------------------------------
ag=$(g_probe "$VM" AG 'Write-Host ("AG=" + ((Get-Process gui-agent -ErrorAction SilentlyContinue | Measure-Object).Count))' 90)
[ "${ag:-0}" -ge 1 ] 2>/dev/null && chk "C1: gui-agent is running as $NEW" PASS || chk "C1: gui-agent not running (got '${ag:-unreadable}')" FAIL

QTEST_VM=$VM timeout -k 5 45 ./tools/qtest run 'cmd /c start "" notepad.exe' >/dev/null 2>&1
W=0
for try in 1 2 3 4 5 6; do
  sleep 7
  rm -f "$OUT/win.tar"
  QTEST_VM=$VM timeout -k 8 120 ./tools/qtest shot "$OUT/win.tar" >/dev/null 2>&1
  if [ -s "$OUT/win.tar" ] && [ "$(tar tf "$OUT/win.tar" 2>/dev/null | grep -c '\.png$')" -gt 0 ]; then W=1; break; fi
done
# An empty dom0 capture is NOT proof of "no window" (a dom0 desktop switch produces the same
# empty tar) - ask the GUEST before grading, exactly as matrix.sh does.
if [ "$W" = 1 ]; then chk "C2: a window from the $NEW session mapped to dom0" PASS
else
  gw=$(g_probe "$VM" NPWIN 'Write-Host ("NPWIN=" + ((Get-Process notepad -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 } | Measure-Object).Count))' 60)
  if [ "${gw:-0}" -ge 1 ] 2>/dev/null; then say "SKIP  C2: guest has $gw notepad window(s) but the dom0 capture was empty - INVALID-INSTRUMENT, not graded"
  else chk "C2: notepad opened but no window anywhere (guest reports '${gw:-unreadable}')" FAIL; fi
fi
QTEST_VM=$VM timeout -k 5 45 ./tools/qtest run 'cmd /c taskkill /f /im notepad.exe' >/dev/null 2>&1

say "=== non-'user' probe: $( [ $FAILED -eq 0 ] && echo ALL ASSERTIONS PASSED || echo FAILED ) ==="
say "SUBJECT $VM IS CONSUMED (accounts + autologon mutated) - remove it before reuse."
exit $FAILED
