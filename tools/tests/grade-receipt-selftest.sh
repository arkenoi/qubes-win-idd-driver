#!/usr/bin/env bash
# tools/grade-receipt.sh passes a receipt only when BOTH the named conditions and the SWEEP are clean
# run: tools/tests/grade-receipt-selftest.sh
# pass: exit 0
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; cd "$ROOT" || exit 2
T=$(mktemp -d "${TMPDIR:-/tmp}/grade-receipt-selftest.XXXXXX"); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok(){ pass=$((pass+1)); echo "PASS  $*"; }
bad(){ fail=$((fail+1)); echo "FAIL  $*"; }

mkdir -p "$T/good" "$T/bad"
printf '%s\n' \
 "[20261011.102247.645-4448:4452-I] ProcessNewFrame: BROKERHOLD hwnd 0x30228 brokerActive=0 - the broker has not started yet" \
 "[20261011.102258.001-4448:4452-I] UpdateWindowData: BROKERLATEREG hwnd 0x30228 registered with the broker at 3828x1017" \
 > "$T/good/agent-excerpt.txt"
echo "[07:27:20] t+15 dom0: windows=1 win-0.png=3828x1053 mean=0.993941" > "$T/good/pixel-lines.txt"
cp "$T/good/pixel-lines.txt" "$T/bad/"
echo "[20261011.102258.001-4448:4452-W] UpdateWindowData: BROKERLATEREG hwnd 0x30228 LATE" > "$T/bad/agent-excerpt.txt"
python3 -c 'import json;print(json.dumps({"pulled_at":"2026-10-11T09:00:00Z","vm":"win11-app","file":"f","line":1,"route":"qubes.NotifyTools","decision":None,"text":"tools"}))' > "$T/led.jsonl"

printf '#!/bin/bash\nmkdir -p "$3"\necho "breaches: 0" > "$3/summary.txt"\necho sweep ok\n' > "$T/sweep-ok"
printf '#!/bin/bash\nmkdir -p "$3"\nprintf "breaches: 0\\nRESULT: INCOMPLETE (12 files dropped)\\n" > "$3/summary.txt"\necho sweep ran\n' > "$T/sweep-incomplete"
printf '#!/bin/bash\nexit 3\n' > "$T/sweep-dead"
printf '#!/bin/bash\nmkdir -p "$3"\necho sweep ran but wrote nothing\n' > "$T/sweep-nosummary"
chmod +x "$T"/sweep-*

# EACH ARM GETS A FRESH COPY OF THE DIR. Sharing one made an arm grade the previous arm's sweep
# summary - the same staleness the tool now refuses, found here first.
run(){ d="$T/run-$RANDOM"; [ -d "$1" ] && cp -r "$1" "$d" || d="$1"
       LEDGER="$T/led.jsonl" SWEEP_BIN="$2" bash tools/grade-receipt.sh "$d" 2026-10-11T08:00:00Z win11-app >"$T/o" 2>&1; echo $?; }

rc=$(run "$T/good" "$T/sweep-ok")
[ "$rc" = 0 ] && grep -q "RECEIPT 0 PASS" "$T/o" && ok "both_clean_passes" \
  || bad "both_clean_passes: rc=$rc $(tail -1 "$T/o")"
rc=$(run "$T/bad" "$T/sweep-ok")
[ "$rc" = 1 ] && grep -q "grade-noise rc=1" "$T/o" && ok "named_condition_fails: a loud BROKERLATEREG fails the receipt even with a clean sweep" \
  || bad "named_condition_fails: rc=$rc $(tail -1 "$T/o")"
rc=$(run "$T/good" "$T/sweep-incomplete")
[ "$rc" = 1 ] && grep -q "INCOMPLETE" "$T/o" && ok "sweep_incomplete_fails: a sweep that cannot grade what it collected is not a pass" \
  || bad "sweep_incomplete_fails: rc=$rc $(tail -1 "$T/o")"
rc=$(run "$T/good" "$T/sweep-dead")
[ "$rc" = 1 ] && ok "sweep_dead_fails: a sweep that dies is not a pass" \
  || bad "sweep_dead_fails: rc=$rc $(tail -1 "$T/o")"
rc=$(run "$T/good" "$T/sweep-nosummary")
[ "$rc" = 1 ] && grep -q "no summary" "$T/o" && ok "sweep_no_summary_fails: no summary is missing data, which fails" \
  || bad "sweep_no_summary_fails: rc=$rc $(tail -1 "$T/o")"
rc=$(run "$T/nonexistent" "$T/sweep-ok")
[ "$rc" = 2 ] && ok "missing_outdir_is_rc2: nothing to grade is not a verdict" \
  || bad "missing_outdir_is_rc2: rc=$rc"

echo "--- $pass passed, $fail failed"
[ "$fail" = 0 ]
