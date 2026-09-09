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
vm_lock "$VM"
trap 'vm_unlock "$VM"' EXIT

CUR=$(ps_probe LG 'Write-Host ("LG=" + (Get-ChildItem "Q:\Qubes Logs\gui-agent-*.log" | Sort-Object LastWriteTime | Select-Object -Last 1).FullName)')
[ -n "$CUR" ] || { no "no gui-agent log on the guest - nothing to grade"; exit 1; }
say "current boot log: $CUR"

# BASELINE THE ACCUMULATING LOG. These lines persist across runs; without an offset a previous
# run's over-budget hold is read as this run's result.
BASE=$(ps_probe LN "Write-Host ('LN=' + @(Get-Content '$CUR').Count)")
[ -n "$BASE" ] || { no "could not read the log length - cannot baseline"; exit 1; }
say "baseline: $BASE lines already in the log; only what follows is graded"

QTEST_VM=$VM timeout -k 5 120 ./tools/qtest push guest/fire-toast.ps1 >/dev/null 2>&1
INC='C:\Users\user\Documents\QubesIncoming\'$(hostname)
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
  no "no QGASLICEMAP/TcApplyResult lines appeared - the toasts did not reach the agent, so nothing was measured (this is a harness failure, not a pass)"
  say "=== crop-before-map: $pass passed, $fail failed ==="; exit 1
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
late=$(printf '%s\n' "$EV" | grep -c 'QGACROPLATE')
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

# A run in which no crop measurement ever landed graded nothing about cropping, however green the
# line above looks - missing data fails.
if [ "$crops" -eq 0 ]; then
  no "no TcApplyResult at all: no crop was ever measured, so 'no QGACROPLATE' proves nothing here"
else
  ok "$crops crop measurement(s) landed - the crop path really ran"
fi

say "=== crop-before-map: $pass passed, $fail failed ==="
[ "$fail" -eq 0 ] || exit 1
