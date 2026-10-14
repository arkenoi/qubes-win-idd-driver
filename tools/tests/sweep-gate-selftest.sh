#!/bin/bash
# sweep-gate-selftest.sh - offline proof matrix for tools/sweep-gate.sh. No rig, no guest.
#
# Every check is also seen to FAIL with its defect present: SWEEP_GATE_DEFECT=1 narrows the shape
# list back to the pre-2026-10-14 set, which missed the stall verdict, bare rc=, German OS text,
# hex status codes and expiry - and the recall cases below must then fail.
set -u
cd "$(dirname "$0")/../.." || exit 2
T=$(mktemp -d "${TMPDIR:-/tmp}/sweepgate-XXXXXX"); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok(){ pass=$((pass+1)); echo "PASS  $*"; }
no(){ fail=$((fail+1)); echo "FAIL  $*"; }

# A baseline holding one benign shape, with a count.
printf '# fixture baseline\n4 <CELL>: could not detach the ISO (harmless: the start-time attach drops at the guest'"'"'s next shutdown)\n' > "$T/base.txt"
run(){ SWEEP_GATE_BASELINE="$T/base.txt" bash tools/sweep-gate.sh "$@" 2>&1; }

# ---- RECALL: real failure forms this rig has actually had must all be caught -------------------
cat > "$T/recall.log" <<'LOG'
[01:00:00] TRANSPORT rc=0 stdout_bytes=0 stdout_has=False stderr_bytes=0
[01:00:01] => STALL (alive=dead halt=ignored cpu=MOVING 99089 / after-deadline MOVING 93625) scan
[01:00:02] Der Befehl "drain" ist entweder falsch geschrieben oder konnte nicht gefunden werden.
[01:00:03] AUPROBE name=PS-ASUSER rc=3221225794 ran=True stdout_bytes=0
[01:00:04] net user: password expires 11/10/2026 - Your password has expired
[01:00:05] DOM0SENDSUNREAD win11de-fix: no record of what dom0 was told on this boot (rc=124)
[01:00:06] release-acceptance exit=1
LOG
out=$(run "$T/recall.log"); n=$(printf '%s' "$out" | grep -c '  NEW')
[ "$n" -ge 7 ] && ok "recall: all 7 real failure forms are reported as NEW shapes (got $n)" || no "recall: only $n of 7 reported
$out"
# ASSERT ON THE NORMALISED FORM. The gate reports SHAPES, so digits are already N: a test that
# greps the output for "rc=124" or "3221225794" fails on its own naivety, not on the gate.
for w in stdout_bytes STALL 'nicht gefunden' AUPROBE expired DOM0SENDSUNREAD 'exit=N'; do
  printf '%s' "$out" | grep -qa -- "$w" || no "recall: '$w' was not reported"
done

# ---- PRECISION: lines that merely contain the words must NOT be reported ----------------------
cat > "$T/benign.log" <<'LOG'
[02:00:00] autologon: ok     the password of gerd-test never expires
[02:00:01] t+120s 383 log lines | installing component 3 of 9
[02:00:02] PASS WIN11-clean: xenbus bound is 9.1.0.0, from the MSI - nothing of ours layered on top
[02:00:03] v4copy: r1 CONTROL in=9.1MB/s out=8.8MB/s v4_lines=12 status=OK
[02:00:04] WIN10-clean: could not detach the ISO (harmless: the start-time attach drops at the guest's next shutdown)
LOG
out=$(run "$T/benign.log")
printf '%s' "$out" | grep -qa 'new_shapes=0 risen_shapes=0' \
  && ok "precision: 'never expires', a progress line, a PASS line, status=OK and a baselined shape are all clean" \
  || no "precision: a benign line was reported
$out"

# ---- ROSE: a baselined shape whose count jumps is reported (the standing-silencer fix) --------
{ for i in 1 2 3 4 5 6 7 8 9 10 11 12; do echo "[03:00:0$i] WIN10-clean: could not detach the ISO (harmless: the start-time attach drops at the guest's next shutdown)"; done; } > "$T/rose.log"
out=$(run "$T/rose.log")
printf '%s' "$out" | grep -qa '  ROSE' && ok "ROSE: a baselined shape at 12x its baseline of 4 is reported" || no "ROSE: not reported
$out"

# ---- the gate refuses to run without a baseline rather than passing ---------------------------
out=$(SWEEP_GATE_BASELINE="$T/nope.txt" bash tools/sweep-gate.sh "$T/benign.log" 2>&1); rc=$?
[ "$rc" = 2 ] && ok "no baseline -> rc 2 (refuses), never a silent pass" || no "no baseline -> rc=$rc"

# ---- the defect knob: the OLD shape list must miss the recall cases --------------------------
if grep -q 'SWEEP_GATE_DEFECT' tools/sweep-gate.sh; then
  out=$(SWEEP_GATE_DEFECT=1 run "$T/recall.log"); n=$(printf '%s' "$out" | grep -c '  NEW')
  [ "$n" -lt 7 ] && ok "knob 'defect': the pre-widening shape list misses $((7-n)) of the 7 - the check is SEEN TO FAIL" \
                 || no "knob 'defect': the old list still caught all 7"
else
  no "knob: tools/sweep-gate.sh has no SWEEP_GATE_DEFECT knob, so no check here has been seen to fail"
fi

echo "RESULT: $pass passed, $fail failed"
exit $(( fail > 0 ? 1 : 0 ))
