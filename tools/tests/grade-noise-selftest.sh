#!/usr/bin/env bash
# Every arm of the noise grader FIRES, and an excerpt that never met the condition is not quiet.
# run: tools/tests/grade-noise-selftest.sh
# pass: exit 0
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; cd "$ROOT" || exit 2
T=$(mktemp -d "${TMPDIR:-/tmp}/grade-noise-selftest.XXXXXX"); trap 'rm -rf "$T"' EXIT
pass=0; fail=0; skip=0
ok(){ pass=$((pass+1)); echo "PASS  $*"; }
bad(){ fail=$((fail+1)); echo "FAIL  $*"; }
G(){ python3 tools/grade-noise.py "$@" >"$T/out" 2>&1; echo $?; }

# a boot with nothing wrong: both tags present, both INFO (SYNTHETIC)
quiet(){ cat > "$1" <<'F'
[20261011.102247.645-4448:4452-I] ProcessNewFrame: BROKERHOLD hwnd 0x30228 holding last content brokerActive=0 sourced=0 slot=-1 - the broker has not started yet
[20261011.102258.001-4448:4452-I] UpdateWindowData: BROKERLATEREG hwnd 0x30228 registered with the broker at 3828x1017 - it was added before the broker had started and was withheld until now
F
}

# ---- 1. REAL control: the build before the fix must FAIL on its BROKERLATEREG level -------------
if [ -s scratchpad/receipt-control-prevbuild.txt ]; then
  rc=$(G scratchpad/receipt-control-prevbuild.txt)
  if [ "$rc" = 1 ] && grep -q "BROKERLATEREG: 3 of 3" "$T/out"; then
    ok "real_control_fails: the previous build's own guest excerpt grades NOISE PRESENT (3 of 3 at W)"
  else
    bad "real_control_fails: rc=$rc - $(tail -2 "$T/out" | tr '\n' ' ')"
  fi
else
  # NOT A PASS. The fixture is a guest excerpt, i.e. per-run evidence, and this repo is public, so it
  # lives in scratchpad/ and cannot be tracked. On a clone that lacks it this arm is not driven; the
  # run that DID drive it is recorded in findings/issues.md under DIRECTSUPPRESSEARLY.
  skip=1; echo "SKIP  real_control_fails: scratchpad/receipt-control-prevbuild.txt absent (untracked"
  echo "      per-run evidence); the synthetic arms below still prove every arm fires"
fi

# ---- 2. the clean shape passes (SYNTHETIC) ------------------------------------------------------
quiet "$T/quiet.txt"
rc=$(G "$T/quiet.txt")
[ "$rc" = 0 ] && ok "quiet_passes: both tags present and INFO grades clean" \
  || bad "quiet_passes: rc=$rc - $(tail -2 "$T/out" | tr '\n' ' ')"

# ---- 3. every noise arm fires (SYNTHETIC) ------------------------------------------------------
while read -r label line; do
  quiet "$T/one.txt"; printf '%s\n' "$line" >> "$T/one.txt"
  rc=$(G "$T/one.txt")
  [ "$rc" = 1 ] && ok "arm_fires_$label" || bad "arm_fires_$label: rc=$rc (the arm did not fire)"
done <<'CASES'
directsuppress [20261011.063835.047-4448:4452-E] ProcessNewFrame: QGADIRECTSUPPRESS hwnd 0x10094 (class Notepad, 1428x783) NOT SHOWN: never received a frame
notifhost_send [20261011.063835.064-4448:4452-I] DirectSuppressNotifyUser: user notification sent (1 suppressed window(s))
notifyerr_send [20261011.063835.070-4448:4452-W] NOTIFYERR gui-agent.capture-deaf sent to dom0 (#1 this boot)
notifyerr_gated [20261011.063835.070-4448:4452-W] NOTIFYERR gui-agent.session-changed not sent to dom0: gated (service.notify-errors off) - shown as a window instead
hold_warning [20261011.102247.645-4448:4452-W] ProcessNewFrame: BROKERHOLD hwnd 0x30228 holding last content brokerActive=0 sourced=0 slot=-1
latereg_warning [20261011.102258.001-4448:4452-W] UpdateWindowData: BROKERLATEREG hwnd 0x30228 registered with the broker LATE at 3828x1017
CASES

# the two notifyerr lines are one word apart; each must be named as the event it IS
quiet "$T/g.txt"
printf '%s\n' "[20261011.063835.070-4448:4452-W] NOTIFYERR gui-agent.session-changed not sent to dom0: gated (service.notify-errors off) - shown as a window instead" >> "$T/g.txt"
rc=$(G "$T/g.txt")
if [ "$rc" = 1 ] && grep -q "SHOWN AS A WINDOW" "$T/out" && ! grep -q "dom0 was told by the error route" "$T/out"; then
  ok "gated_named_correctly: a gated error is failed as a window shown, NOT as a send to dom0"
else
  bad "gated_named_correctly: rc=$rc - $(grep -c FAIL "$T/out") fail line(s); the needle matched the negation"
fi

# ---- 4. MISSING DATA FAILS: an excerpt that never met the condition is not quiet ---------------
: > "$T/empty.txt"
rc=$(G "$T/empty.txt")
if [ "$rc" = 1 ] && grep -q "ABSENT" "$T/out"; then
  ok "absent_tags_fail: an excerpt with no BROKERHOLD/BROKERLATEREG cannot be graded quiet"
else
  bad "absent_tags_fail: rc=$rc - an empty excerpt reading as 'no noise' is the hole this closes"
fi
# one tag alone is still not the condition
quiet "$T/half.txt"; grep -v BROKERLATEREG "$T/half.txt" > "$T/half2.txt"; mv "$T/half2.txt" "$T/half.txt"
rc=$(G "$T/half.txt")
[ "$rc" = 1 ] && ok "half_condition_fails: BROKERHOLD without BROKERLATEREG is not a graded boot" \
  || bad "half_condition_fails: rc=$rc"

# ---- 5. the pixels arm: delivery is asserted, absence is not delivery -------------------------
quiet "$T/quiet.txt"
echo "[07:27:02] t+15 dom0: windows=1 win-0.png=3828x1053 mean=0.993941" > "$T/pix-ok.txt"
rc=$(G "$T/quiet.txt" --pixels "$T/pix-ok.txt")
[ "$rc" = 0 ] && ok "pixels_delivered_passes: windows=1 mean=0.99 counts as delivered" \
  || bad "pixels_delivered_passes: rc=$rc - $(tail -2 "$T/out" | tr '\n' ' ')"
echo "[07:27:02] t+15 dom0: windows=0" > "$T/pix-none.txt"
rc=$(G "$T/quiet.txt" --pixels "$T/pix-none.txt")
[ "$rc" = 1 ] && ok "pixels_absent_fails: a capture with no window is not a delivered window" \
  || bad "pixels_absent_fails: rc=$rc"
echo "[07:27:02] t+15 dom0: windows=1 win-0.png=3828x1053 mean=0.000000" > "$T/pix-black.txt"
rc=$(G "$T/quiet.txt" --pixels "$T/pix-black.txt")
[ "$rc" = 1 ] && ok "pixels_black_fails: a black window is noise-free and still not a result" \
  || bad "pixels_black_fails: rc=$rc"
# NOTHING WEIRD IN BETWEEN: a black capture mid-hold fails even when the last one is perfect
printf '%s\n' \
  "[07:27:02] t+3 dom0: windows=1 win-0.png=3828x1053 mean=0.000000" \
  "[07:27:20] t+15 dom0: windows=1 win-0.png=3828x1053 mean=0.993941" > "$T/pix-flash.txt"
rc=$(G "$T/quiet.txt" --pixels "$T/pix-flash.txt")
if [ "$rc" = 1 ] && grep -q "MAPPED BLACK" "$T/out"; then
  ok "pixels_black_flash_fails: a black window at t+3 fails although t+15 is perfect"
else
  bad "pixels_black_flash_fails: rc=$rc - grading only the best capture hides the flash"
fi
# and the held case - windows=0 while the broker starts - is NOT a black window
printf '%s\n' \
  "[07:27:02] t+3 dom0: windows=0" \
  "[07:27:20] t+15 dom0: windows=1 win-0.png=3828x1053 mean=0.993941" > "$T/pix-held.txt"
rc=$(G "$T/quiet.txt" --pixels "$T/pix-held.txt")
[ "$rc" = 0 ] && ok "pixels_held_then_delivered_passes: windows=0 during the hold is the designed path" \
  || bad "pixels_held_then_delivered_passes: rc=$rc - $(tail -2 "$T/out" | tr '\n' ' ')"

rc=$(G "$T/quiet.txt" --pixels "$T/nonexistent.txt")
[ "$rc" = 2 ] && ok "pixels_unreadable_is_rc2: the instrument did not run, which is not a pass" \
  || bad "pixels_unreadable_is_rc2: rc=$rc"

# ---- 6. THE LEDGER: the independent half - what was PULLED, not what the log claims -----------
quiet "$T/quiet.txt"
L="$T/led.jsonl"
mk_row(){ python3 -c 'import json,sys; print(json.dumps({"pulled_at":sys.argv[1],"vm":sys.argv[2],"file":"f","line":1,"route":sys.argv[3],"decision":sys.argv[4] or None,"text":sys.argv[5]}))' "$@"; }
: > "$L"
mk_row 2026-10-11T09:00:00Z win11-app qubes.NotifyTools "" "reported tools to dom0" >> "$L"
mk_row 2026-10-11T09:00:01Z win11-app qubes.Notifications "" "protocol traffic" >> "$L"
rc=$(G "$T/quiet.txt" --ledger "$L" --vm win11-app --since 2026-10-11T08:00:00Z)
[ "$rc" = 0 ] && ok "ledger_normal_traffic_passes: NotifyTools/Notifications carry no send decision" \
  || bad "ledger_normal_traffic_passes: rc=$rc - $(tail -2 "$T/out" | tr '\n' ' ')"
mk_row 2026-10-11T09:00:02Z win11-app capture-deaf-notepad.exe "user notification sent (1 suppressed window(s))" "DirectSuppressNotifyUser: QGADIRECTSUPPRESS user notification sent" >> "$L"
rc=$(G "$T/quiet.txt" --ledger "$L" --vm win11-app --since 2026-10-11T08:00:00Z)
if [ "$rc" = 1 ] && grep -q "record a send to dom0" "$T/out"; then
  ok "ledger_send_fails: a pulled row whose DECISION says a notification was sent fails"
else
  bad "ledger_send_fails: rc=$rc - the independent half would miss a real dom0 popup"
fi
# the NOTIFYERR route's own wording is caught too, not only the notifhost one
: > "$L"; mk_row 2026-10-11T09:00:03Z win11-app gui-agent.deslice-down "sent to dom0 (#1 this boot)" "NOTIFYERR gui-agent.deslice-down sent to dom0 (#1 this boot)" >> "$L"
rc=$(G "$T/quiet.txt" --ledger "$L" --vm win11-app --since 2026-10-11T08:00:00Z)
[ "$rc" = 1 ] && ok "ledger_notifyerr_fails: the error route's own send record fails too" \
  || bad "ledger_notifyerr_fails: rc=$rc"
# MISSING DATA FAILS: nothing pulled in the window is not a quiet guest
: > "$L"; mk_row 2026-10-10T09:00:00Z win11-app qubes.NotifyTools "" "yesterday" >> "$L"
rc=$(G "$T/quiet.txt" --ledger "$L" --vm win11-app --since 2026-10-11T08:00:00Z)
if [ "$rc" = 1 ] && grep -q "never pulled" "$T/out"; then
  ok "ledger_no_rows_fails: no rows in the window means the pull did not happen"
else
  bad "ledger_no_rows_fails: rc=$rc - a silent nothing would read as 'dom0 was told nothing'"
fi
# another guest's rows are not this guest's receipt
: > "$L"; mk_row 2026-10-11T09:00:00Z win11-acc qubes.NotifyTools "" "other guest" >> "$L"
rc=$(G "$T/quiet.txt" --ledger "$L" --vm win11-app --since 2026-10-11T08:00:00Z)
[ "$rc" = 1 ] && ok "ledger_other_vm_not_credited: another guest's rows do not count" \
  || bad "ledger_other_vm_not_credited: rc=$rc"
# an unreadable ledger is rc 2, never a pass
rc=$(G "$T/quiet.txt" --ledger "$T/nonexistent.jsonl" --vm win11-app)
[ "$rc" = 2 ] && ok "ledger_unreadable_is_rc2: the instrument did not run" \
  || bad "ledger_unreadable_is_rc2: rc=$rc"
printf 'not json\n' > "$T/bad.jsonl"
rc=$(G "$T/quiet.txt" --ledger "$T/bad.jsonl" --vm win11-app)
[ "$rc" = 2 ] && ok "ledger_malformed_is_rc2: a corrupt ledger is not a quiet guest" \
  || bad "ledger_malformed_is_rc2: rc=$rc"

echo "--- $pass passed, $fail failed, $skip not driven here"
[ "$fail" = 0 ]
