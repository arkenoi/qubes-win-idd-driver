#!/bin/bash
# THE GATE MUST NOT GRADE WHAT IT WAS NOT GIVEN.
#
# MEASURED 2026-10-21, both of these, before the predicates below existed:
#   an empty log file            -> SWEEP-GATE-RESULT unaccounted=0 risen=0 accounted=0   exit 0
#   a capture that failed to decode (mojibake named gui-agent-mojibake.log) -> same, exit 0
# A CLEAN verdict over nothing, and a CLEAN verdict over input nobody could read. The gate's
# classification half was already closed and finite - 13 registered emitters, 36 classified corpus
# lines, an unregistered line exits 1 - and that is why this hole survived so long: everything it
# DID say was true. It is the ancestor of the sweep reading CLEAN over a capture with no agent log,
# of the collector not searching the product's own default directory, and of the appvm cells being
# graded while logging nowhere, each patched somewhere else and never here.
#
# A LARGER CHANGE WAS WITHDRAWN RATHER THAN SHIPPED. A product patch adding one INFO birth line per
# module to the shared windows-utils logging library was written, then withdrawn: its premise - that
# at the shipped log level no module declares that it ran - rests on no measurement. The capture
# cited as proof held four harness-side logs and zero guest logs, so it graded nothing; the one
# capture with guest logs shows the banner at INFO, but from modules reporting 4.3.35.795 and
# 4.2.2.0, i.e. builds older than the package under test. Jev: product_patch_was_needed 0.15,
# premise_established 0.06. What remains here needs no product change at all.
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)" || exit 2
T=$(mktemp -d "${TMPDIR:-/tmp}/sweeplife-XXXXXX"); trap 'rm -rf "$T"' EXIT
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "ok   $1"; }
no(){ FAIL=$((FAIL+1)); echo "FAIL $1"; printf '       -> %s\n' "${2:-}"; }

birth(){ printf '[%s.001-%s:%s-I] LogInit: Log started, module name: %s\n' "$1" "$2" "$(( $2 + 4 ))" "$3"; }
warnline(){ printf '[%s.002-%s:%s-W] %s\n' "$1" "$2" "$(( $2 + 4 ))" "$3"; }

# A CAPTURE OF ANOTHER PROGRAM'S OUTPUT IS GRADEABLE. Two earlier versions of the unreadable
# predicate refused it - first per-file "no recognisable line", then whole-input "nothing parsed" -
# and both were caught by sweep-gate-selftest's T19e and four siblings. This gate's own doctrine is
# "a capture is not an emitter": msiexec's log, an installer console, the output of a command under
# test are all legitimate input with no log-shaped lines in them.
printf 'Microsoft Windows [Version 10.0.19045.2965]\nC:\\>install.cmd /auto\nInstalling...\n' > "$T/capture.log"
out=$(timeout -k 10 120 bash tools/sweep-gate.sh "$T/capture.log" 2>&1); rc=$?
if [ "$rc" = 0 ]; then ok "a plain-text capture of another program's output is GRADED, not refused"
else no "a plain-text capture was refused (rc=$rc)" "$(printf '%s' "$out" | head -2)"; fi

# ---- the gate: every ungradeable input, and every gradeable one ---------------------------------------------------
: > "$T/empty.log"
out=$(timeout -k 10 120 bash tools/sweep-gate.sh "$T/empty.log" 2>&1); rc=$?
if [ "$rc" = 2 ] && printf '%s' "$out" | command grep -qa 'INCONCLUSIVE sources=0'; then
  ok "an empty capture is INCONCLUSIVE (exit 2), not CLEAN"
else no "an empty capture returned rc=$rc" "$(printf '%s' "$out" | head -2)"; fi

out=$(timeout -k 10 120 bash tools/sweep-gate.sh "$T/does-not-exist.log" 2>&1); rc=$?
[ "$rc" = 2 ] && ok "a named source that does not exist is INCONCLUSIVE, not CLEAN" \
              || no "a missing source returned rc=$rc" "$(printf '%s' "$out" | head -2)"

# A CAPTURE NOBODY CAN READ IS NOT CLEAN. A wrong-endian UTF-16 conversion produces mojibake that
# matches no windows-utils prefix, so a content-only proof-of-life test concluded "not our logs" and
# returned CLEAN - measured at exit 0 unaccounted=0 on a file named gui-agent-mojibake.log, which is
# the blindness class coming back through the detector's own blind spot.
printf '\xe3\x89\x9b\xe3\x88\xb0\xe3\x84\xb6\xe3\x88\xb0\xe2\xb8\xb0\n' > "$T/gui-agent-mojibake.log"
out=$(timeout -k 10 120 bash tools/sweep-gate.sh "$T/gui-agent-mojibake.log" 2>&1); rc=$?
if [ "$rc" = 2 ] && printf '%s' "$out" | command grep -qa 'unreadable=1'; then
  ok "a source that decoded to nothing readable is INCONCLUSIVE, naming unreadable=1"
else no "the mojibake capture returned rc=$rc" "$(printf '%s' "$out" | head -2)"; fi

# a UTF-16 guest log as the collector actually writes it must not read clean either
printf '[20261021.101500.001-1234:1238-W] QGAVCHANFAIL: request dropped\n' | iconv -f UTF-8 -t UTF-16LE > "$T/gui-agent-utf16.log"
out=$(timeout -k 10 120 bash tools/sweep-gate.sh "$T/gui-agent-utf16.log" 2>&1); rc=$?
[ "$rc" = 2 ] && ok "a BOM-less UTF-16 guest log is INCONCLUSIVE, not clean" \
              || no "the UTF-16 capture returned rc=$rc" "$(printf '%s' "$out" | head -2)"

# and a HARNESS-shaped log must still be judged, or this predicate would refuse every caller
printf '[11:13:08] [ERROR] FAIL  win10-clean: something our code declared\n' > "$T/matrix.log"
out=$(timeout -k 10 120 bash tools/sweep-gate.sh "$T/matrix.log" 2>&1); rc=$?
[ "$rc" = 1 ] && ok "a harness-shaped log is still judged (and its error still fails)" \
              || no "the harness log returned rc=$rc" "$(printf '%s' "$out" | head -2)"

{ warnline 20261021.101500 1234 'QGAVCHANFAIL: something our code declared'; } > "$T/nobirth.log"
out=$(timeout -k 10 120 bash tools/sweep-gate.sh "$T/nobirth.log" 2>&1); rc=$?
if [ "$rc" = 2 ] && printf '%s' "$out" | command grep -qa 'birth_lines=0'; then
  ok "windows-utils lines with NO module birth are INCONCLUSIVE, naming birth_lines=0"
else no "a birthless capture returned rc=$rc" "$(printf '%s' "$out" | head -2)"; fi

{ birth 20261021.101500 1234 gui-agent; } > "$T/clean.log"
out=$(timeout -k 10 120 bash tools/sweep-gate.sh "$T/clean.log" 2>&1); rc=$?
if [ "$rc" = 0 ] && printf '%s' "$out" | command grep -qa 'unaccounted=0'; then
  ok "a capture with a birth line and no errors is judged, and clean"
else no "a clean birth capture returned rc=$rc" "$(printf '%s' "$out" | head -3)"; fi

{ birth 20261021.101500 1234 gui-agent
  warnline 20261021.101502 1234 'NOBODYREGISTEREDTHIS: an error our code declared'; } > "$T/dirty.log"
out=$(timeout -k 10 120 bash tools/sweep-gate.sh "$T/dirty.log" 2>&1); rc=$?
if [ "$rc" = 1 ] && printf '%s' "$out" | command grep -qa 'unaccounted=1'; then
  ok "with proof of life present, an unregistered error still FAILS (the closed world holds)"
else no "the dirty birth capture returned rc=$rc" "$(printf '%s' "$out" | head -3)"; fi

# SEEN TO FAIL: with the detector removed, the empty capture reads CLEAN again.
sed '/# SG-LIFE-BEGIN/,/# SG-LIFE-END/d' tools/sweep-gate.sh > "$T/gate-nodetect.sh"
out=$(timeout -k 10 120 bash "$T/gate-nodetect.sh" "$T/empty.log" 2>&1); rc=$?
[ "$rc" = 0 ] && ok "SEEN TO FAIL: without the detector the empty capture is CLEAN again (rc=0)" \
              || no "the regressed gate did not go back to CLEAN (rc=$rc)" "the check cannot be driven"


# ---- THE SYNTHETIC-INPUT DECLARATION MUST NOT EXIST IN PRODUCTION -------------------------------
# _SG_CORPUS_LINE means "this input is synthetic classifier material, not a guest capture". The gate
# sets it on ITSELF for the one-line re-invocation inside --verify, and sweep-gate-selftest.sh sets
# it because every fixture there is a hand-made line. If any harness ever set it, the proof-of-life
# refusals would be off for a real campaign and the gate would be back to grading captures it cannot
# read. The requirement is ON by default precisely so a caller that forgets fails CLOSED.
setters=$(command grep -rln '_SG_CORPUS_LINE' --include='*.sh' --include='*.py' --include='*.ps1' . 2>/dev/null \
          | command grep -av '^./scratchpad' \
          | command grep -av '^./tools/tests/' \
          | command grep -av '^./tools/sweep-gate.sh$' || true)
# THE RULE IS BY LOCATION, not a list of filenames: any suite under tools/tests/ may declare its
# input synthetic - that is what a classifier fixture is - and nothing outside tools/tests/ may,
# apart from the gate setting it on itself for --verify. A filename allowlist went stale the moment
# a third suite needed it.
if [ -z "$setters" ]; then
  ok "no production file sets _SG_CORPUS_LINE - the declaration is confined to the gate and its suites"
else
  no "a production file sets _SG_CORPUS_LINE" "$(printf '%s' "$setters" | tr '\n' ' ') - the proof-of-life refusals would be off for a real campaign"
fi
# and it must really be what suppresses them, not something incidental
: > "$T/declared.log"
# THE EXEMPTION IS THE BIRTH-LINE RULE ONLY. An empty or unreadable input stays refused even when
# declared synthetic, because a suite that hands the gate nothing has a broken fixture, not a
# classifier case. Suppressing all three would have been broader than the reason for any.
out=$(_SG_CORPUS_LINE=1 timeout -k 10 120 bash tools/sweep-gate.sh "$T/empty.log" 2>&1); rc=$?
if [ "$rc" = 2 ] && printf '%s' "$out" | command grep -qa 'sources=0'; then
  ok "an EMPTY input is still refused even when declared synthetic"
else no "the declaration suppressed the empty-input refusal too (rc=$rc)" "$(printf '%s' "$out" | head -1)"; fi
out=$(_SG_CORPUS_LINE=1 timeout -k 10 120 bash tools/sweep-gate.sh "$T/gui-agent-mojibake.log" 2>&1); rc=$?
if [ "$rc" = 2 ] && printf '%s' "$out" | command grep -qa 'unreadable=1'; then
  ok "an UNREADABLE input is still refused even when declared synthetic"
else no "the declaration suppressed the unreadable refusal too (rc=$rc)" "$(printf '%s' "$out" | head -1)"; fi
# and the birth-line rule IS what it exempts
printf '[20261021.101500.001-1234-W] something our code declared\n' > "$T/declared.log"
out=$(_SG_CORPUS_LINE=1 timeout -k 10 120 bash tools/sweep-gate.sh "$T/declared.log" 2>&1); rc=$?
[ "$rc" != 2 ] && ok "a windows-utils line with no birth line IS graded when declared synthetic (rc=$rc)" \
               || no "the declaration did not exempt the birth-line rule" "$(printf '%s' "$out" | head -1)"
out=$(timeout -k 10 120 bash tools/sweep-gate.sh "$T/declared.log" 2>&1); rc=$?
[ "$rc" = 2 ] && ok "and WITHOUT the declaration the same line is INCONCLUSIVE - the default refuses" \
              || no "the undeclared case stopped being refused (rc=$rc)" "$(printf '%s' "$out" | head -1)"

# ---- ONE BIRTH PER MODULE, NOT ONE FOR THE SET -------------------------------------------------
# The requirement was a TOTAL, so a capture where ONE module declared itself and the rest did not
# passed - and the silence of those others is exactly what the birth line exists to make readable.
# windows-utils writes one file per module, so the rule is per file.
printf '[20261021.120000.000-100:100-I] WinMain: QWTBIRTH module=gui-agent ver=4.3.36\n[20261021.120001.000-100:100-I] WinMain: up\n' > "$T/mod-a.log"
printf '[20261021.120002.000-200:200-I] WaWatchThread: polling\n[20261021.120003.000-200:200-W] WaWatchThread: something\n' > "$T/mod-b.log"
out=$(timeout -k 10 120 bash tools/sweep-gate.sh "$T/mod-a.log" "$T/mod-b.log" 2>&1); rc=$?
if [ "$rc" = 2 ] && printf '%s' "$out" | command grep -qa 'nobirth=.*mod-b.log'; then
  ok "a module with records and NO birth of its own is refused BY NAME, though another module declared"
else
  no "the undeclared module was accepted (rc=$rc)" "$(printf '%s' "$out" | head -2 | tr '\n' ' ')"
fi
# and the positive control: both modules declaring is graded, not refused
printf '[20261021.120002.000-200:200-I] WaWatchThread: Log started, module name: qrexec-agent\n[20261021.120003.000-200:200-W] WaWatchThread: something\n' > "$T/mod-b2.log"
out=$(timeout -k 10 120 bash tools/sweep-gate.sh "$T/mod-a.log" "$T/mod-b2.log" 2>&1); rc=$?
[ "$rc" != 2 ] && ok "with BOTH modules declaring, the capture is graded (rc=$rc), not refused" \
               || no "a fully-declared capture was refused" "$(printf '%s' "$out" | head -2 | tr '\n' ' ')"
# SEEN TO FAIL: with the per-file list emptied, the undeclared module passes again on the total
sed 's/\[ "${w:-0}" -gt 0 \] \&\& \[ "${n:-0}" = 0 \] \&\& nobirth=/[ 1 = 0 ] \&\& nobirth=/' tools/sweep-gate.sh > "$T/gate-totalonly.sh"
if command grep -qa '\[ 1 = 0 \] && nobirth=' "$T/gate-totalonly.sh"; then
  out=$(timeout -k 10 120 bash "$T/gate-totalonly.sh" "$T/mod-a.log" "$T/mod-b.log" 2>&1); rc=$?
  [ "$rc" != 2 ] && ok "SEEN TO FAIL: on the total alone the undeclared module passes again (rc=$rc)" \
                 || no "the total-only copy still refused (rc=$rc)" "the leg does not measure the per-file rule"
else
  no "could not build the total-only control" "the substitution did not apply"
fi

# ---- A TRUNCATED PULL IS NOT A COMPLETE LOG ----------------------------------------------------
# log-sweep-collect.ps1 caps the bytes per file and sends partial=1 when it hits the cap: head +
# W/E/suspicious + tail, nothing else. log-sweep.py turns that into a DATA problem; the gate never
# looked, so matrix.sh:2957 - which sweeps decoded guest logs without running analyze - graded a
# truncated capture as whole. The fixture is a decode-shaped dir: meta.json beside files/.
mkdir -p "$T/cap/files"
printf '[20261021.120000.000-100:100-I] WinMain: QWTBIRTH module=gui-agent ver=4.3.36\n[20261021.120001.000-100:100-I] WinMain: up\n' > "$T/cap/files/gui-agent-20261021.log"
python3 - "$T/cap/meta.json" <<'TRUNCPY'
import json,sys
json.dump({"files":[{"local":"files/gui-agent-20261021.log","partial":"1","total_lines":"91234"}]},
          open(sys.argv[1],"w"), indent=1)
TRUNCPY
out=$(timeout -k 10 120 bash tools/sweep-gate.sh "$T/cap/files/gui-agent-20261021.log" 2>&1); rc=$?
if [ "$rc" = 2 ] && printf '%s' "$out" | command grep -qa 'truncated=.*gui-agent-20261021.log'; then
  ok "a file the collector marked partial=1 is REFUSED by name, not graded as complete"
else
  no "a truncated capture was graded (rc=$rc)" "$(printf '%s' "$out" | head -2 | tr '\n' ' ')"
fi
# the same file with partial=0 must still be graded, or the check refuses every decoded capture
python3 - "$T/cap/meta.json" <<'TRUNCPY'
import json,sys
json.dump({"files":[{"local":"files/gui-agent-20261021.log","partial":"0","total_lines":"2"}]},
          open(sys.argv[1],"w"), indent=1)
TRUNCPY
out=$(timeout -k 10 120 bash tools/sweep-gate.sh "$T/cap/files/gui-agent-20261021.log" 2>&1); rc=$?
[ "$rc" != 2 ] && ok "and with partial=0 the same capture is graded (rc=$rc) - not a blanket refusal" \
               || no "partial=0 was refused too" "$(printf '%s' "$out" | head -2 | tr '\n' ' ')"
# a log with NO meta.json beside it - a harness log - is unaffected
out=$(timeout -k 10 120 bash tools/sweep-gate.sh "$T/clean.log" 2>&1); rc=$?
[ "$rc" != 2 ] && ok "a log with no decode meta.json is unaffected by the truncation check (rc=$rc)" \
               || no "a plain log became INCONCLUSIVE" "$(printf '%s' "$out" | head -2 | tr '\n' ' ')"
# SEEN TO FAIL: with the refusal removed, the truncated capture is graded again
python3 - "$T/cap/meta.json" <<'TRUNCPY'
import json,sys
json.dump({"files":[{"local":"files/gui-agent-20261021.log","partial":"1","total_lines":"91234"}]},
          open(sys.argv[1],"w"), indent=1)
TRUNCPY
sed '/# SG-PARTIAL-A/,/# SG-PARTIAL-B/d' tools/sweep-gate.sh > "$T/gate-nopartial.sh"
if command grep -qa 'SG-PARTIAL' "$T/gate-nopartial.sh"; then
  no "the control still contains the partial block" "the marker range did not cut it"
else
  out=$(timeout -k 10 120 bash "$T/gate-nopartial.sh" "$T/cap/files/gui-agent-20261021.log" 2>&1); rc=$?
  [ "$rc" != 2 ] && ok "SEEN TO FAIL: without the check the truncated capture is graded again (rc=$rc)" \
                 || no "the stripped copy still refused (rc=$rc)" "the leg does not measure the check"
fi

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
