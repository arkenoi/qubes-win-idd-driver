#!/usr/bin/env bash
# grade-noise-selftest.sh - drive every arm of tools/grade-noise.py, each one SEEN TO FAIL.
#
# WHY. The owner's acceptance criterion is "absense of notification noise" (2026-10-11). The previous
# receipt was graded BY EYE: BROKERHOLD had become INFO, the eye stopped there, and BROKERLATEREG was
# still W on all three boots - the fix had not taken and the receipt read as a pass. The grader exists
# so that cannot happen again, which only holds if each of its arms has been seen to fire.
#
# TWO KINDS OF INPUT, kept apart on purpose:
#   REAL      scratchpad/receipt-control-prevbuild.txt - the actual guest excerpt from the build
#             before the fix. It is what proves the BROKERLATEREG arm catches the real defect.
#   SYNTHETIC the fixtures below. They test the GRADER'S MECHANICS - that an arm fires on the shape
#             of line it is looking for - and are never evidence about a guest. A fixture written
#             here can only ever show the instrument works; the product receipt comes from the rig.
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
hold_warning [20261011.102247.645-4448:4452-W] ProcessNewFrame: BROKERHOLD hwnd 0x30228 holding last content brokerActive=0 sourced=0 slot=-1
latereg_warning [20261011.102258.001-4448:4452-W] UpdateWindowData: BROKERLATEREG hwnd 0x30228 registered with the broker LATE at 3828x1017
CASES

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
rc=$(G "$T/quiet.txt" --pixels "$T/nonexistent.txt")
[ "$rc" = 2 ] && ok "pixels_unreadable_is_rc2: the instrument did not run, which is not a pass" \
  || bad "pixels_unreadable_is_rc2: rc=$rc"

echo "--- $pass passed, $fail failed, $skip not driven here"
[ "$fail" = 0 ]
