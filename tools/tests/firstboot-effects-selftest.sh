#!/bin/bash
# FIRSTBOOT MUST NOT REPORT OK FOR STEPS THAT DID NOT TAKE.
#
# MEASURED 2026-10-21 by the descending audit: guest/firstboot-setup.ps1 ran with
# $ErrorActionPreference='Continue', checked nothing, and printed "OK - REBOOT REQUIRED"
# unconditionally. A failed `bcdedit /set testsigning on` or a failed policy write therefore
# produced a setup log identical to a good one. Nothing else in the tracked harness asserts
# testsigning at runtime, and the IDD driver is test-signed: with it off the driver does not load
# and the display cells fail later with a symptom pointing nowhere near here.
#
# The verdict function is extracted from the shipped script and EXECUTED in pwsh with synthetic
# readbacks - the registry and bcdedit need a guest, the decision does not.
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)" || exit 2
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "ok   $1"; }
no(){ FAIL=$((FAIL+1)); echo "FAIL $1"; printf '       -> %s\n' "${2:-}"; }
PW="$("$(dirname "$0")/pwsh-path.sh" || true)"

F=guest/firstboot-setup.ps1
blk=$(awk '/# FIRSTBOOT-VERDICT-A/,/# FIRSTBOOT-VERDICT-B/' "$F")
if [ -n "$blk" ] && printf '%s' "$blk" | command grep -qa 'Get-FirstbootFailures'; then
  ok "the verdict block was extracted from $F"
else
  echo "FATAL: could not extract the verdict block"; exit 2
fi

# the OK line must be INSIDE the failure check, not before it
if printf '%s' "$blk" | command grep -qaB2 'OK - REBOOT REQUIRED' && \
   printf '%s' "$blk" | awk '/exit 1/{seen=1} /OK - REBOOT REQUIRED/{if(seen) ok=1} END{exit !ok}'; then
  ok "the OK line comes AFTER the failure exit, so it cannot print over a failure"
else
  no "the OK line is not guarded by the failure check" "that is the defect"
fi

if [ -z "$PW" ]; then
  echo "note no pwsh on this host - the verdict function was not executed"
  echo; echo "RESULT: $PASS passed, $FAIL failed, 1 INCONCLUSIVE"
  [ "$FAIL" -eq 0 ] || exit 1
  exit 2
fi

fn=$(printf '%s' "$blk" | sed -n '/^function Get-FirstbootFailures/,/^}/p')
judge(){ # $1..$5 = TestSigning LongPaths EnableLUA TokenFilter Seamless -> the joined failures
  "$PW" -NoProfile -Command "
    $fn
    \$b = Get-FirstbootFailures -TestSigning '$1' -LongPaths $2 -EnableLUA $3 -TokenFilter $4 -Seamless $5
    if (\$b.Count -eq 0) { 'NONE' } else { \$b -join '|' }" 2>&1 | tr -d '\r' | tail -1
}

got=$(judge Yes 1 0 1 1)
[ "$got" = NONE ] && ok "the fully-correct guest reports NO failures" \
                  || no "a correct guest was reported broken" "$got"

got=$(judge No 1 0 1 1)
case "$got" in *testsigning*) ok "testsigning OFF is reported, naming the driver consequence" ;;
  *) no "testsigning off was not reported" "$got" ;; esac

got=$(judge Yes 1 1 1 1)
case "$got" in *EnableLUA*) ok "EnableLUA left at 1 is reported (qrexec would get a filtered token)" ;;
  *) no "EnableLUA=1 was accepted" "$got" ;; esac

got=$(judge Yes 1 0 1 0)
case "$got" in *SeamlessMode*) ok "SeamlessMode 0 is reported - the MSI would install fullscreen" ;;
  *) no "SeamlessMode=0 was accepted" "$got" ;; esac

got=$(judge No 0 1 0 0)
n=$(printf '%s' "$got" | awk -F'|' '{print NF}')
[ "${n:-0}" -ge 5 ] && ok "all five failures are reported together ($n named), not just the first" \
                    || no "only $n failure(s) reported when five were wrong" "$got"

# an ABSENT value (the registry write never happened) must not read as correct
got=$(judge Yes '$null' 0 1 1)
case "$got" in *LongPathsEnabled*) ok "an ABSENT value is a failure, not a pass-by-default" ;;
  *) no "a missing registry value was accepted" "$got" ;; esac

# SEEN TO FAIL: the pre-fix script printed OK regardless
got=$("$PW" -NoProfile -Command "'OK - REBOOT REQUIRED for testsigning to take effect.'" 2>&1 | tr -d '\r')
case "$got" in *"OK - REBOOT"*) ok "SEEN TO FAIL: the unconditional line prints OK with nothing checked" ;;
  *) no "could not reproduce the pre-fix line" "$got" ;; esac

# ---- AND THE CALLER MUST READ THE VERDICT ------------------------------------------------------
# The exit code above was added in the morning and the re-grade found it swallowed the same day:
# mgmt/payload-setup.cmd ran the script and scheduled stage 2 unconditionally, so a guest whose UAC
# or testsigning writes failed went on into the QWT install and the test cells.
# THE BOUND, STATED: this is a Windows .cmd file and nothing here can execute it, so these legs
# assert its CONTROL FLOW - that the errorlevel check sits between the call and the two actions that
# carry a bad guest forward - rather than its behaviour. The negative control is the pre-fix text
# out of git, which must fail them.
C=mgmt/payload-setup.cmd
[ -r "$C" ] || { echo "FATAL: $C missing"; exit 2; }

flow_ok(){ # $1=file -> 0 when the errorlevel check gates stage 2 and the reboot
  local f="$1" n_call n_chk n_task n_boot
  n_call=$(command grep -an 'firstboot-setup\.ps1' "$f" | head -1 | cut -d: -f1)
  n_chk=$(command grep -an 'if errorlevel 1' "$f" | head -1 | cut -d: -f1)
  n_task=$(command grep -an 'schtasks /create /tn QWTStage2' "$f" | head -1 | cut -d: -f1)
  n_boot=$(command grep -an '^shutdown /r' "$f" | head -1 | cut -d: -f1)
  [ -n "$n_call" ] && [ -n "$n_chk" ] && [ -n "$n_task" ] && [ -n "$n_boot" ] || return 1
  [ "$n_chk" -gt "$n_call" ] && [ "$n_chk" -lt "$n_task" ] && [ "$n_chk" -lt "$n_boot" ]
}

flow_ok "$C" \
  && ok "the caller checks errorlevel between the script and both stage-2 scheduling and the reboot" \
  || no "the caller does not gate stage 2 on the script's exit code" "the verdict is swallowed again"
# The failure branch must STOP, not merely log: a logged failure that still reboots is the old
# behaviour with a louder log.
awk '/if errorlevel 1 \(/,/^\)/' "$C" | command grep -qa 'exit /b 1' \
  && ok "and the failure branch exits instead of carrying on" \
  || no "the failure branch does not exit" "logging it and continuing is the same guest, carried forward"
# Nothing on the dom0 side parses this log, so the reason has to reach the screen the harness
# photographs - otherwise it is a verdict nobody reads, which is the defect being fixed.
awk '/if errorlevel 1 \(/,/^\)/' "$C" | command grep -qa 'notepad' \
  && ok "and it puts the reason where the harness's screen capture can read it" \
  || no "the failure is only written to a log nothing parses" "grep the repo: no dom0-side reader exists"

# SEEN TO FAIL: the pre-fix caller out of git must not satisfy the flow check
# Its own temp file: this suite has no $T, and reaching for one it does not define is how the two
# legs below first died with "T: unbound variable" after everything above them had passed.
HEADCMD=$(mktemp "${TMPDIR:-/tmp}/fbhead-XXXXXX") || exit 2
git show HEAD:mgmt/payload-setup.cmd > "$HEADCMD" 2>/dev/null || cp "$C" "$HEADCMD"
if command grep -qa 'if errorlevel 1' "$HEADCMD"; then
  ok "negative control: HEAD already carries the check (nothing to reproduce)"
elif flow_ok "$HEADCMD"; then
  no "the pre-fix caller satisfied the flow check" "then the check is not what this leg measures"
else
  ok "SEEN TO FAIL: the pre-fix caller scheduled stage 2 with the exit code unread"
fi
rm -f "$HEADCMD"

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
