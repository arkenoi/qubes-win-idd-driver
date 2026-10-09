#!/bin/bash
# CROP BEFORE MAP - does a toast/menu reach dom0 already cropped, or does it appear with its
# shadow strip and snap?
#
# WHY THIS EXISTS. The agent holds a toast/menu unmapped until its shadow-crop resolves, bounded by
# CROP_BEFORE_SHOW_TIMEOUT_MS. If that bound expires first the window is mapped UNCROPPED and then
# snaps to the tight rect when the insets land - visible, and the owner reported exactly that on
# 2026-09-09. The cause was structural: the budget was a flat 400 ms while ONE UIA operation was
# allowed 500 ms (TOAST_CROP_UIA_TIMEOUT_MS), so a slow measurement could never make the budget.
#
# RETRACTED CLAIM, KEPT SO IT IS NOT RE-DERIVED. This file first said: "on 4.3.22 four held windows
# measured 188/407/484/1843 ms against a 400 ms budget - three of four over", and concluded toasts
# were being mapped uncropped. THAT CONCLUSION WAS NOT SUPPORTED BY THAT MEASUREMENT. held_ms covers
# two unrelated holds - waiting for the shadow-crop, and waiting for the window's first PAINTED frame
# (QGADIRECTWAIT / QGASLICECONTENT) - and the slow windows were console windows (CASCADIA_HOSTING_
# WINDOW_CLASS, opened by the harness's own `qtest run` probes) waiting for CONTENT, not toasts
# waiting for a crop. No class information was recorded at the time; the line that prints it is
# QGACROPLATE, added afterwards. The owner's own observation of a real violation stands - only this
# file's attribution of it was wrong.
#
# WHAT IT ASSERTS, from the agent's OWN instrument rather than from pixels:
#   QGACROPLATE          - the agent stating that it mapped a window UNCROPPED. It fires exactly on
#                          the timedOut && !cropReady arm, so it IS the defect. THE criterion.
#   TcApplyResult        - a crop measurement landing. Zero of them means nothing about cropping was
#                          exercised, so a clean QGACROPLATE count would prove nothing: that FAILS.
#   QGASLICEMAP held_ms  - reported for context ONLY. Do not grade it against the crop budget; that
#                          is the mistake above.
# NOTE this needs a build carrying QGACROPLATE (4.3.23+). On an older agent the line cannot appear,
# so its absence is not evidence and this check must not be pointed at one.
#
# NOT A PIXEL WITNESS. This proves what the agent did, not what dom0 painted. A toast bubble in
# dom0 is override-redirect and cannot be captured per-window, and this harness will NOT reach for
# a whole-desktop capture to compensate (.claude/skills/guest-capture).
#
# Usage:  VM=win11-acc BUDGET_MS=700 mgmt/harness/crop-before-map.sh
# NEEDS LogLevel >= 4 (DEBUG). The QGASLICEMAP line(s) this harness grades on are routine
# per-window detail and moved to DEBUG on 2026-10-08 (owner: "ok for debug but not for regular
# operation"), so a run at the shipped LogLevel 3 will find nothing and must not read that as a
# clean result. Raise it first with guest/set-loglevel.ps1 4 (it restarts the agent through the
# service that owns it and proves the turnover) and put it back afterwards.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2

VM="${VM:?set VM to the guest under test}"
TOASTS="${TOASTS:-3}"
# Must match CROP_BEFORE_SHOW_TIMEOUT_MS in agent/gui-agent/main.c, which is
# TOAST_CROP_UIA_TIMEOUT_MS + 200. Passed in rather than guessed so a build with a different
# budget is graded against its own.
BUDGET_MS="${BUDGET_MS:-700}"
LOG="${LOG:-/home/user/rel/crop-before-map-$VM.log}"

say(){ echo "[$(date -u +%H:%M:%S)] $*" | tee -a "$LOG"; }
pass=0; fail=0
ok(){ say "PASS  $*"; pass=$((pass+1)); }
no(){ say "FAIL  $*"; fail=$((fail+1)); }

b64(){ python3 -c "import sys,base64;print(base64.b64encode(sys.argv[1].encode('utf-16-le')).decode())" "$1"; }
gq(){ QTEST_VM=$VM timeout -k 5 "${2:-120}" ./tools/qtest run "$1" 2>/dev/null | tr -d '\r'; }
# Every probe emits KEY=value and only a line matching ^KEY= is read: `qtest run` output carries the
# cmd.exe banner and prompt, and a probe that greps the raw capture grades on that noise.
ps_probe(){ local k="$1"; gq "powershell -NoProfile -ExecutionPolicy Bypass -EncodedCommand $(b64 "$2")" "${3:-120}" \
            | grep -aoE "^$k=.*" | head -1 | sed "s/^$k=//"; }

say "=== crop-before-map on $VM (budget ${BUDGET_MS} ms, $TOASTS toasts) ==="

# This run fires toasts and reads the guest's log; a campaign cell rebooting the same guest
# underneath it would produce holds from a different boot. Serialise like every other VM-mutating
# job here.
source mgmt/harness/vmlock.sh
source mgmt/harness/shutdown-lib.sh
vm_lock "$VM"
LL_RESTORE=""
cleanup(){
  # Put the level back even when the run failed, or the next boot of this guest logs DEBUG for ever
  # and every later harness reads a noisier log than the product ships.
  if [ -n "$LL_RESTORE" ]; then
    # EACH KEY BACK TO WHAT IT WAS, ABSENCE INCLUDED. log.c reads the MODULE key first, so writing
    # an explicit module value where there was none would override the global level on this guest
    # for ever and silently suppress Debug lines in every later run. Measured on win11-acc: global
    # 3, module ABSENT ('-').
    say "restoring LogLevel to global=$LL_G module=$LL_M (takes effect at the agent's next start)"
    restore_loglevel "$LL_G" "$LL_M" >/dev/null 2>&1 \
      || say "WARN  could not restore LogLevel (wanted global=$LL_G module=$LL_M) - put it back by hand"
  fi
  vm_unlock "$VM"
}
trap cleanup EXIT

# ---- THE INSTRUMENT'S PRECONDITION, ENFORCED RATHER THAN DOCUMENTED --------------------------
# This file has said "NEEDS LogLevel >= 4, raise it first" since the lines moved to DEBUG on
# 2026-10-08. Nothing enforced it, so the 4.3.36 release gate ran it at the shipped LogLevel 3,
# found no QGASLICEMAP at all, and recorded "FAIL crop-before-map (rc=1)" against the PRODUCT - a
# suite that could not pass, whose failure was counted as a defect. The level is now read, raised
# if short, and restored; and a run that measured nothing exits 2 (INVALID INSTRUMENT), never 1.
# THE GUEST IS REBOOTED, NOT THE AGENT: guest/set-loglevel.ps1 restarts the agent through its
# service, and an agent restart is not normal operation here (Jev restart_is_acceptable 0.22) - a
# restarted agent remaps every window, which is precisely the state this test measures.
set_loglevel(){   # $1 = level; writes BOTH keys, because log.c reads the module key FIRST
  ps_probe RL "\$k='HKLM:\\SOFTWARE\\Invisible Things Lab\\Qubes Tools'
Set-ItemProperty \$k -Name LogLevel -Value $1 -Type DWord
if (-not (Test-Path \"\$k\\gui-agent\")) { New-Item \"\$k\\gui-agent\" -Force | Out-Null }
Set-ItemProperty \"\$k\\gui-agent\" -Name LogLevel -Value $1 -Type DWord
\$g=0; \$m=0
\$p=Get-ItemProperty \$k -Name LogLevel -ErrorAction SilentlyContinue; if (\$p) { \$g=[int]\$p.LogLevel }
\$q=Get-ItemProperty \"\$k\\gui-agent\" -Name LogLevel -ErrorAction SilentlyContinue; if (\$q) { \$m=[int]\$q.LogLevel }
Write-Host (\"RL=\" + \$g + '/' + \$m)" 120
}
restore_loglevel(){   # $1 = global ('-' = remove), $2 = module ('-' = remove)
  ps_probe RS "\$k='HKLM:\\SOFTWARE\\Invisible Things Lab\\Qubes Tools'
\$km=\"\$k\\gui-agent\"
if ('$1' -eq '-') { Remove-ItemProperty \$k -Name LogLevel -ErrorAction SilentlyContinue }
else { Set-ItemProperty \$k -Name LogLevel -Value $([ "$1" = "-" ] && echo 0 || echo "$1") -Type DWord }
if ('$2' -eq '-') { Remove-ItemProperty \$km -Name LogLevel -ErrorAction SilentlyContinue }
else { Set-ItemProperty \$km -Name LogLevel -Value $([ "$2" = "-" ] && echo 0 || echo "$2") -Type DWord }
\$p=Get-ItemProperty \$k -Name LogLevel -ErrorAction SilentlyContinue
\$q=Get-ItemProperty \$km -Name LogLevel -ErrorAction SilentlyContinue
\$g='-'; if (\$p) { \$g=[string][int]\$p.LogLevel }
\$m='-'; if (\$q) { \$m=[string][int]\$q.LogLevel }
Write-Host (\"RS=\" + \$g + '/' + \$m)" 120
}
read_loglevel(){
  ps_probe LL "\$k='HKLM:\\SOFTWARE\\Invisible Things Lab\\Qubes Tools'
\$p=Get-ItemProperty \$k -Name LogLevel -ErrorAction SilentlyContinue
\$q=Get-ItemProperty \"\$k\\gui-agent\" -Name LogLevel -ErrorAction SilentlyContinue
\$m='-'; if (\$q) { \$m=[string][int]\$q.LogLevel }
\$g='-'; if (\$p) { \$g=[string][int]\$p.LogLevel }
Write-Host (\"LL=\" + \$g + '/' + \$m)" 120
}
LL=$(read_loglevel)
[ -n "$LL" ] || { no "could not read LogLevel from the guest - the precondition cannot be established"; exit 2; }
LL_G=${LL%%/*}; LL_M=${LL##*/}
say "LogLevel on the guest: global=$LL_G module=$LL_M (this test needs >= 4 in BOTH)"
llnum(){ case "$1" in ""|-) echo 0 ;; *) echo "$1" ;; esac; }
if [ "$(llnum "$LL_G")" -lt 4 ] || [ "$(llnum "$LL_M")" -lt 4 ]; then
  LL_RESTORE=1
  say "raising LogLevel to 4 and REBOOTING $VM (an agent restart would remap every window)"
  RL=$(set_loglevel 4)
  [ "$RL" = "4/4" ] || { no "LogLevel did not read back as 4/4 (got '${RL:-<no answer>}') - refusing to grade"; exit 2; }
  qwt_shutdown "$VM" 600 || { no "$VM would not halt for the LogLevel change"; exit 2; }
  timeout 300 qvm-start "$VM" >/dev/null 2>&1
  up=0
  for i in $(seq 1 30); do
    if gq 'cmd /c echo QREADY' 40 | grep -qa '^QREADY'; then up=1; say "qrexec back at t+$((i*10))s"; break; fi
    sleep 10
  done
  [ "$up" = 1 ] || { no "$VM did not come back after the LogLevel reboot"; exit 2; }
  # The toasts are fired into a logged-on session, so wait for one rather than racing it.
  sess=0
  for i in $(seq 1 30); do
    if gq 'cmd /c query session' 40 | grep -aqE 'Aktiv|Active'; then sess=1; say "session active at t+$((i*10))s"; break; fi
    sleep 10
  done
  [ "$sess" = 1 ] || { no "no logged-on session after the LogLevel reboot - toasts would go nowhere"; exit 2; }
fi

# THE RUNNING AGENT'S LOG IS FOUND BY ITS PID, NOT BY MTIME. This read used to take the newest
# gui-agent log by LastWriteTime, which on this rig selects the WRONG FILE: the live log is per-day
# and appended, NTFS updates its mtime lazily while the handle is open, and the clock jumps back ~3 h
# ~60 s into every boot - so a per-instance file from the PREVIOUS boot carries a LATER stamp than
# the file being written right now (measured 2026-10-09: 05:00:17 against 02:55:04). Baselining the
# wrong file is one way this suite reports "no QGASLICEMAP" on a healthy guest. The agent stamps its
# own pid into every line as '-<pid>:<tid>-', which no clock can forge. Same fix as
# guest/health-check.ps1's agent_log_healthy.
CUR=$(ps_probe LG '$a=@(Get-Process gui-agent -ErrorAction SilentlyContinue)
if ($a.Count -eq 0) { Write-Host "LG="; exit }
$hit=$null
foreach ($f in @(Get-ChildItem "Q:\Qubes Logs\gui-agent-*.log" -ErrorAction SilentlyContinue)) {
  foreach ($pr in $a) {
    if (Select-String -LiteralPath $f.FullName -Pattern ("-" + $pr.Id + ":[0-9]+-[A-Z]\]") -Quiet -ErrorAction SilentlyContinue) { $hit=$f; break }
  }
  if ($hit) { break }
}
if ($hit) { Write-Host ("LG=" + $hit.FullName) } else { Write-Host "LG=" }')
[ -n "$CUR" ] || { no "no gui-agent log on the guest carries a RUNNING agent's pid - either no agent is running or it has written nothing, so there is nothing to grade. INVALID INSTRUMENT, not a product verdict"; exit 2; }
say "current boot log: $CUR"

# BASELINE THE ACCUMULATING LOG. These lines persist across runs; without an offset a previous
# run's over-budget hold is read as this run's result.
BASE=$(ps_probe LN "Write-Host ('LN=' + @(Get-Content '$CUR').Count)")
[ -n "$BASE" ] || { no "could not read the log length - cannot baseline"; exit 1; }
say "baseline: $BASE lines already in the log; only what follows is graded"

QTEST_VM=$VM timeout -k 5 120 ./tools/qtest push guest/fire-toast.ps1 >/dev/null 2>&1
# DISCOVERED, never assumed: a hardcoded C:\Users\user addresses a profile that does not exist on
# any guest whose account is not `user`, and tools/qtest already works it out per guest.
INC=$(QTEST_VM=$VM ./tools/qtest incoming)
[ -n "$INC" ] || { no "could not discover the guest's QubesIncoming directory"; exit 2; }
for n in $(seq 1 "$TOASTS"); do
  say "firing toast $n"
  gq "powershell -NoProfile -ExecutionPolicy Bypass -File $INC\\fire-toast.ps1 -Title CROPTEST$n -Body ordinal-$n" 180 >/dev/null
  sleep 15
done
sleep 5

# Grade ONLY the lines appended after the baseline.
EV=$(gq "powershell -NoProfile -ExecutionPolicy Bypass -EncodedCommand $(b64 "Get-Content '$CUR' | Select-Object -Skip $BASE | Where-Object { \$_ -match 'QGASLICEMAP|QGACROPLATE|TcApplyResult' } | ForEach-Object { 'L|' + \$_ }")" 180 \
     | grep -a '^L|' | sed 's/^L|//')

if [ -z "$EV" ]; then
  no "no QGASLICEMAP/TcApplyResult lines appeared - the toasts did not reach the agent, so nothing"
  say "      was measured. LogLevel read $LL_G/$LL_M at entry. This is an INVALID INSTRUMENT (exit 2),"
  say "      never a product verdict: a suite that measured nothing has not found a defect."
  say "=== crop-before-map: $pass passed, $fail failed ==="; exit 2
fi
printf '%s\n' "$EV" | sed 's/^/    /' | tee -a "$LOG" >/dev/null

# GRADE THE CROP PATH, NOT held_ms. This is the correction to how this check first worked, and it
# had already produced a wrong conclusion: held_ms covers TWO different holds - waiting for the
# shadow-crop, and waiting for the window's first PAINTED frame (QGADIRECTWAIT / QGASLICECONTENT) -
# and only the first is this test's subject. Grading held_ms called a run a crop failure when four
# windows were merely waiting for pixels, and earlier it supported a claim that toasts were mapped
# uncropped when the slow windows were console windows waiting for content.
#
# QGACROPLATE is the agent saying, itself, "I mapped this window uncropped" - it fires exactly on
# the timedOut && !cropReady arm. That is the defect, so that is the criterion.
# SCOPE THE VERDICT TO THIS TEST'S SUBJECT. QGACROPLATE fires for ANY held window that timed out
# without a crop, and `qtest run` opens a console window (CASCADIA_HOSTING_WINDOW_CLASS) for every
# probe - so grading every occurrence failed the 4.3.25 run on windows THIS HARNESS created, while
# the actual toasts cropped correctly (measurements landed 15 ms and 203 ms before their maps).
# That is the same confusion that produced a retracted claim on 2026-09-09: console windows counted
# as toasts.
#
# The console occurrences are NOT filtered away silently - they are a real finding of their own (the
# agent defers a console window 700 ms for a shadow-crop that can never resolve, then maps it
# uncropped: latency and log noise in the defer predicate) and are reported separately below.
late=$(printf '%s\n' "$EV" | grep 'QGACROPLATE' | grep -vc 'CASCADIA_HOSTING_WINDOW_CLASS')
console_late=$(printf '%s\n' "$EV" | grep 'QGACROPLATE' | grep -c 'CASCADIA_HOSTING_WINDOW_CLASS')
held=$(printf '%s\n' "$EV" | grep -ao 'held_ms=[0-9-]*' | sed 's/held_ms=//')
n_held=$(printf '%s\n' "$held" | grep -c '[0-9]')
crops=$(printf '%s\n' "$EV" | grep -c 'TcApplyResult')

say "held windows: $n_held; holds (crop AND content, not comparable to the budget): $(printf '%s' "$held" | tr '\n' ' ')"
say "crop measurements that landed: $crops; uncropped maps reported: $late"

if [ "$n_held" -eq 0 ]; then
  no "no held windows at all - the crop-before-show path did not engage, so this run graded nothing"
elif [ "$late" -eq 0 ]; then
  ok "no QGACROPLATE: the agent mapped nothing uncropped"
else
  no "QGACROPLATE fired $late time(s) - the agent itself reports mapping a window uncropped"
  printf '%s\n' "$EV" | grep -a 'QGACROPLATE' | sed 's/^/    /' | tee -a "$LOG" >/dev/null
fi

# Reported, never hidden: a console window held for a crop it cannot have is the agent deferring
# something it should not. It does not fail THIS test - cropping toasts is what this grades - but it
# must be visible, or filtering it out becomes the bug.
if [ "${console_late:-0}" -gt 0 ]; then
  say "NOTE  $console_late QGACROPLATE on console windows (CASCADIA_HOSTING_WINDOW_CLASS) - not this"
  say "      test's subject, but the agent held them ~700 ms for a shadow-crop that cannot resolve."
fi

# A run in which no crop measurement ever landed graded nothing about cropping, however green the
# line above looks - missing data fails.
if [ "$crops" -eq 0 ]; then
  no "no TcApplyResult at all: no crop was ever measured, so 'no QGACROPLATE' proves nothing here"
else
  ok "$crops crop measurement(s) landed - the crop path really ran"
fi

say "=== crop-before-map: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ] || exit 1
