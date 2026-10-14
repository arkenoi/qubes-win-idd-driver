#!/bin/bash
# sweep-gate-selftest.sh - does the error gate actually gate?
#
# Every case here was seen to FAIL before it was seen to pass. The two that matter most:
#   T2  the gate must LOSE recall when deliberately broken. A check that cannot fail is decoration,
#       and this tool's first --verify mode compared its own regex against itself and printed
#       EXHAUSTIVE while missing `WARNING log-volume bind failed` - the very incident it was built
#       for, which carries no bracketed level.
#   T7  the corpus must still match what the emitters EMIT. Rewording a harness message without
#       re-running the regenerator would leave the gate measured against text nothing prints.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok(){ pass=$((pass+1)); printf '  PASS  %s\n' "$1"; }
no(){ fail=$((fail+1)); printf '  FAIL  %s\n     -> %s\n' "$1" "$2"; }

# T0 - THE CORPUS MUST NOT SHRINK. Every recall ratio gets easier as the ground truth gets smaller,
# and this suite once printed 7/7 green after a broken regenerator silently cut the corpus to four
# MUST lines. The floor is asserted before any ratio is believed.
FLOOR_MUST=21; FLOOR_BENIGN=13
nm=$(grep -ac '^MUST' mgmt/harness/error-corpus.txt || echo 0)
nb=$(grep -ac '^BENIGN' mgmt/harness/error-corpus.txt || echo 0)
if [ "${nm:-0}" -ge "$FLOOR_MUST" ] && [ "${nb:-0}" -ge "$FLOOR_BENIGN" ]; then
  ok "T0 corpus holds $nm MUST / $nb BENIGN (floor $FLOOR_MUST/$FLOOR_BENIGN)"
else no "T0 the corpus SHRANK to $nm MUST / $nb BENIGN - a smaller corpus is an easier gate" "raise it back or lower the floor deliberately"; fi

# T1 - recall and precision against the committed corpus of real, filed defects
out=$(bash tools/sweep-gate.sh --verify 2>&1); rc=$?
if [ $rc -eq 0 ] && printf '%s' "$out" | grep -qa 'recall=\([0-9]*\)/\1 '; then
  ok "T1 every filed defect's own line is surfaced ($(printf '%s' "$out" | grep -ao 'recall=[^ ]*'))"
else no "T1 corpus recall is not 100%" "$(printf '%s' "$out" | head -3)"; fi

# T2 - THE GATE MUST BE ABLE TO FAIL. Dropping the W class must lose the gui-agent crash loop and
# the two log-volume warnings, which are W/WARNING lines.
out=$(SWEEP_GATE_DEFECT=1 bash tools/sweep-gate.sh --verify 2>&1); rc=$?
if [ $rc -ne 0 ] && printf '%s' "$out" | grep -qa 'MISSED'; then
  ok "T2 a deliberately broken gate loses recall ($(printf '%s' "$out" | grep -ao 'recall=[^ ]*'))"
else no "T2 breaking the gate did not fail the check" "$out"; fi

# T3 - an empty or unreadable corpus is INCONCLUSIVE, never a pass. Two empty counts compared equal
# and printed EXHAUSTIVE when this was first checked by hand with a missing `bc`.
printf '# nothing\n' > "$T/empty-corpus.txt"
out=$(SWEEP_GATE_CORPUS="$T/empty-corpus.txt" bash tools/sweep-gate.sh --verify 2>&1); rc=$?
if [ $rc -eq 2 ] && printf '%s' "$out" | grep -qa INCONCLUSIVE; then ok "T3 an empty corpus is inconclusive, not a pass"
else no "T3 empty corpus did not report INCONCLUSIVE (rc=$rc)" "$out"; fi

# T4 - with no ledger the gate refuses rather than passing everything
printf 'x\n' > "$T/a.log"
out=$(SWEEP_GATE_LEDGER="$T/nope.txt" bash tools/sweep-gate.sh "$T/a.log" 2>&1); rc=$?
if [ $rc -eq 2 ] && printf '%s' "$out" | grep -qa REFUSING; then ok "T4 no ledger -> refuses"
else no "T4 ran without a ledger (rc=$rc)" "$out"; fi

# T5 - THE PIPEFAIL TRAP. A match-free file LAST must not swallow earlier findings: `grep` returns 1
# on no-match and under `set -o pipefail` that made the whole tool exit 2 silently, so 20 logs
# reported findings and 130 reported nothing depending on the last file. Measured 2026-10-14.
printf '[ERROR] something real broke\n' > "$T/has.log"; printf 'nothing to see\n' > "$T/none.log"
printf '# empty\n' > "$T/el.txt"
out=$(SWEEP_GATE_LEDGER="$T/el.txt" bash tools/sweep-gate.sh "$T/has.log" "$T/none.log" 2>&1)
if printf '%s' "$out" | grep -qa 'something real broke'; then ok "T5 a match-free file last does not swallow findings"
else no "T5 findings lost when the last file has no match" "$out"; fi

# T6 - a ledger entry accounts for a message, and only that message
# seed, then write a real reason over the seeder's TODO - a seeded row deliberately does not account
bash tools/sweep-gate.sh --write-ledger "$T/led.txt" "$T/has.log" >/dev/null
sed -i 's/# TODO.*/# reviewed: the probe writes this on every pass; harmless/' "$T/led.txt"
out=$(SWEEP_GATE_LEDGER="$T/led.txt" bash tools/sweep-gate.sh "$T/has.log" 2>&1); rc=$?
printf '[ERROR] a different thing broke\n' > "$T/other.log"
out2=$(SWEEP_GATE_LEDGER="$T/led.txt" bash tools/sweep-gate.sh "$T/other.log" 2>&1); rc2=$?
if [ $rc -eq 0 ] && [ $rc2 -ne 0 ]; then ok "T6 a ledger entry accounts for ONE message, not a class"
else no "T6 ledger entry behaved as a class silencer (rc=$rc rc2=$rc2)" "$out2"; fi

# T7 - DRIFT. The corpus must still be what the emitters emit: reword a harness message without
# re-running the regenerator and the gate would be measured against text nothing prints any more.
cp mgmt/harness/error-corpus.txt "$T/corpus-before.txt"
bash tools/regen-error-corpus.sh --write >/dev/null 2>"$T/regen.err"; rgrc=$?
if [ "${rgrc:-1}" -ne 0 ]; then
  no "T7 the regenerator could not rebuild every site" "$(head -2 "$T/regen.err")"
elif diff -q "$T/corpus-before.txt" mgmt/harness/error-corpus.txt >/dev/null; then
  ok "T7 corpus matches what the emitters actually emit"
else
  no "T7 corpus has drifted - tools/regen-error-corpus.sh --write updated it" "$(diff "$T/corpus-before.txt" mgmt/harness/error-corpus.txt | head -4)"
fi

# T8 - A SEEDED TODO IS NOT A REASON. --write-ledger stamps every row it creates with a TODO note.
# If that counted as an account, seeding a ledger from a run would silence every error in that run -
# the silencing this redesign removed, coming back through the seeder.
printf '[ERROR] seeded thing\n' > "$T/td.log"
printf '1 [ERROR] seeded thing   # TODO: why is this not a defect?\n' > "$T/td-todo.txt"
printf '1 [ERROR] seeded thing   # the ISO is already detached by the previous cell; harmless\n' > "$T/td-real.txt"
o1=$(SWEEP_GATE_LEDGER="$T/td-todo.txt" bash tools/sweep-gate.sh "$T/td.log" 2>&1); r1=$?
o2=$(SWEEP_GATE_LEDGER="$T/td-real.txt" bash tools/sweep-gate.sh "$T/td.log" 2>&1); r2=$?
if [ $r1 -ne 0 ] && [ $r2 -eq 0 ]; then ok "T8 a TODO does not account for an error; a written reason does"
else no "T8 ledger note handling wrong (todo rc=$r1 expect non-zero, real rc=$r2 expect 0)" "$o1"; fi

# T9 - THE WIRING, not just the tool. Coverage depends on matrix.sh actually CALLING the gate over
# the right files and raising a class that blocks. The block is read OUT of matrix.sh and executed
# against two fixtures, so this test cannot drift from the harness it checks. The guest log sits in
# a SUBDIRECTORY because logvol_pull puts it there and a flat glob missed it - the first version of
# the wiring would have passed a campaign whose guest log carried a gui-agent crash loop.
blk=$(python3 - <<'PYX'
s = open('mgmt/harness/matrix.sh', encoding='utf-8').read()
a = s.index('if [ -x tools/sweep-gate.sh ]; then'); b = s.index('# PRECONDITION EVIDENCE')
print(s[a:b].rstrip())
PYX
)
run_block(){ # $1 = campaign dir
  bash -c "FAIL=0; INVALID=0; R='$1/run.log'; M='$1'
say(){ echo \"\$*\"; }
no(){ FAIL=\$((FAIL+1)); case \"\$*\" in *INVALID*) INVALID=\$((INVALID+1)) ;; esac; echo \"NO \$*\"; }
$blk
echo \"RESULT FAIL=\$FAIL INVALID=\$INVALID\"" 2>&1
}
mkdir -p "$T/dirty/logvol-win11-up/qwt-logs" "$T/clean"
printf '12:00:00 matrix: campaign start\n' > "$T/dirty/run.log"
printf '12:00:00 matrix: campaign start\n' > "$T/clean/run.log"
printf '[20261014.120004.001-1234-W] gui-agent.exe died within 10000 ms of starting, 2 time(s) in a row\n'   > "$T/dirty/logvol-win11-up/qwt-logs/gui-agent-20261014.log"
od=$(run_block "$T/dirty"); oc=$(run_block "$T/clean")
if printf '%s' "$od" | grep -qa 'RESULT FAIL=1 INVALID=1' && printf '%s' "$oc" | grep -qa 'RESULT FAIL=0 INVALID=0'; then
  ok "T9 the campaign wiring blocks on a GUEST log in a subdir, and passes a clean campaign"
else
  no "T9 campaign wiring wrong" "dirty: $(printf '%s' "$od" | tail -1) | clean: $(printf '%s' "$oc" | tail -1)"
fi

# T10 - A DISPOSITIONED MESSAGE MUST RE-SURFACE WHEN IT RISES, and the threshold must scale. The
# reason written in a ledger can be WRONG, and a rising count is the only signal that contradicts it
# from outside. A flat "double it" would have let the x102 inverted-DWM-bounds message reach 205.
printf '# t\n102 GetRealWindowRect: <HEX>: inverted DWM bounds (N,N)-(N,N) and no usable GetWindowRect - rejecting   # reviewed: correct handling\n' > "$T/rose-led.txt"
mk(){ python3 -c "open('$1','w').write('[20261014.120000.001-1-E] GetRealWindowRect: 0xdead: inverted DWM bounds (1,2)-(3,4) and no usable GetWindowRect - rejecting\n'*$2)"; }
mk "$T/r130.log" 130; mk "$T/r110.log" 110
o130=$(SWEEP_GATE_LEDGER="$T/rose-led.txt" bash tools/sweep-gate.sh "$T/r130.log" 2>&1)
o110=$(SWEEP_GATE_LEDGER="$T/rose-led.txt" bash tools/sweep-gate.sh "$T/r110.log" 2>&1)
if printf '%s' "$o130" | grep -qa 'risen=1' && printf '%s' "$o110" | grep -qa 'risen=0'; then
  ok "T10 a dispositioned x102 re-surfaces at x130 and stays quiet at x110 (scaled threshold)"
else no "T10 rise threshold wrong" "130: $(printf '%s' "$o130" | grep -a RESULT) | 110: $(printf '%s' "$o110" | grep -a RESULT)"; fi

# T11 - NORMALISATION KEEPS WHAT IS DIAGNOSTIC AND MERGES WHAT IS NOT, and says how much it merged.
# Measured on a real campaign's 257 declared lines: keeping the escalation count splits exactly one
# message (a crash loop going from 1 to 2 in a row was invisible); keeping every hex would take 27
# messages to 183, because a bare hex is a window HANDLE and 82 handles hitting one condition is
# one message - that explosion is how the FIRST version of this tool failed.
printf '%s\n' \
  "[20261014.120000.001-1-W] WatchdogThread: died within 10000 ms of starting, 1 time(s) in a row" \
  "[20261014.120001.001-1-W] WatchdogThread: died within 10000 ms of starting, 2 time(s) in a row" \
  "[20261014.120002.001-1-E] QioReadBuffer: ReadFile failed with error 0x6d: pipe ended" \
  "[20261014.120003.001-1-E] QioReadBuffer: ReadFile failed with error 0x5aa: pipe ended" \
  "[20261014.120004.001-1-W] GetRealWindowRect: 0x1009a: inverted DWM bounds (0,0)-(0,0) rejecting" \
  "[20261014.120005.001-1-W] GetRealWindowRect: 0x1009c: inverted DWM bounds (0,0)-(0,0) rejecting" \
  > "$T/norm.log"
printf '# empty\n' > "$T/norm-led.txt"
nout=$(SWEEP_GATE_LEDGER="$T/norm-led.txt" bash tools/sweep-gate.sh "$T/norm.log" 2>&1)
esc=$(printf '%s' "$nout" | grep -ac 'time(s) in a row')
cod=$(printf '%s' "$nout" | grep -acE 'error (0x6d|0x5aa)')
hnd=$(printf '%s' "$nout" | grep -ac 'inverted DWM bounds')
vtag=$(printf '%s' "$nout" | grep -ac '\[2 distinct\] GetRealWindowRect')
if [ "$esc" = 2 ] && [ "$cod" = 2 ] && [ "$hnd" = 1 ] && [ "$vtag" = 1 ]; then
  ok "T11 escalation counts and error codes are kept, window handles merge, and the merge reports [2 distinct]"
else
  no "T11 normalisation wrong (escalation=$esc want 2, codes=$cod want 2, handles=$hnd want 1, variant-tag=$vtag want 1)" "$(printf '%s' "$nout" | grep -a UNACCOUNTED | head -4)"
fi

# T12 - LOCALE INDEPENDENCE. win_perror2 renders a Win32 code through FormatMessage, which uses the
# SYSTEM locale, so the same failure reads "Die Pipe wurde beendet." on a German guest and "The pipe
# has been ended." on an English one. A ledger keyed on that sentence misses on the other guest and
# orphans its disposition. The owner's rule: the harness may carry EN+DE with caveats, the product
# may not. So the key carries the CODE, which is locale-independent, and <OSMSG> for the sentence.
printf '%s\n' \
  "[20261014.120000.001-1-E] QioReadBuffer: ReadFile failed with error 0x6d: Die Pipe wurde beendet." \
  "[20261014.120001.001-1-E] QioReadBuffer: ReadFile failed with error 0x6d: The pipe has been ended." \
  "[20261014.120002.001-1-E] QioReadBuffer: ReadFile failed with error 0x5aa: Nicht genug Ressourcen." \
  > "$T/loc.log"
printf '# empty\n' > "$T/loc-led.txt"
lout=$(SWEEP_GATE_LEDGER="$T/loc-led.txt" bash tools/sweep-gate.sh "$T/loc.log" 2>&1)
same=$(printf '%s' "$lout" | grep -ac 'error 0x6d: <OSMSG>')
diff2=$(printf '%s' "$lout" | grep -ac 'error 0x5aa: <OSMSG>')
nonascii=$(printf '%s' "$lout" | grep -aE '^  (UN)?ACCOUNTED' | grep -ac '[^ -~]')
if [ "$same" = 1 ] && [ "$diff2" = 1 ] && [ "$nonascii" = 0 ]; then
  ok "T12 the same code in two languages is ONE message, a different code is another, no localised text in any key"
else
  no "T12 locale dependence (0x6d groups=$same want 1, 0x5aa=$diff2 want 1, localised keys=$nonascii want 0)" "$(printf '%s' "$lout" | grep -a UNACCOUNTED)"
fi

# T13 - GROUPING MUST NOT LOSE A LINE. Merging is right for a report (82 window handles are one
# message, and keeping every hex took 27 messages to 183 and buried the findings). But the distinct
# lines behind a message are evidence, and they were being discarded. SWEEP_GATE_DUMP writes every
# one under its message, so the aggregation is presentation rather than loss - asserted here by
# counting, not by claiming.
printf '%s\n' \
  "[20261014.120000.001-1-W] GetRealWindowRect: 0x1009a: inverted DWM bounds (0,0)-(0,0) rejecting" \
  "[20261014.120001.001-1-W] GetRealWindowRect: 0x1009c: inverted DWM bounds (0,0)-(0,0) rejecting" \
  "[20261014.120002.001-1-W] GetRealWindowRect: 0x1009c: inverted DWM bounds (0,0)-(0,0) rejecting" \
  "[20261014.120003.001-1-E] QioReadBuffer: ReadFile failed with error 0x6d: pipe ended" \
  > "$T/dmp.log"
printf '# empty\n' > "$T/dmp-led.txt"
SWEEP_GATE_LEDGER="$T/dmp-led.txt" SWEEP_GATE_DUMP="$T/dmp.out" bash tools/sweep-gate.sh "$T/dmp.log" >/dev/null 2>&1
# 4 lines in, 3 DISTINCT (one exact duplicate) -> the dump must carry all 3 and no more
indump=$(grep -ac '^    ' "$T/dmp.out" 2>/dev/null || echo 0)
hdrs=$(grep -ac '^=== x' "$T/dmp.out" 2>/dev/null || echo 0)
if [ "${indump:-0}" = 3 ] && [ "${hdrs:-0}" = 2 ]; then
  ok "T13 every distinct line is recoverable from the dump (3 distinct of 4 lines, under 2 messages)"
else
  no "T13 the dump lost or invented lines (distinct=$indump want 3, messages=$hdrs want 2)" "$(head -6 "$T/dmp.out" 2>/dev/null)"
fi

# T14 - TWO INDEPENDENT IMPLEMENTATIONS MUST AGREE ON THE POPULATION. A corpus the author curated
# can only measure the author's judgement; the FIRST version of --verify compared this tool's regex
# with itself and printed EXHAUSTIVE while missing a real incident. --census extracts the declared
# lines in AWK, from the log FORMAT (the writers' format, not anything this tool invented), and
# requires the tool's own dump to account for exactly those. On 83 real guest logs both reach 185.
printf '%s\n' \
  "[20261014.120000.001-1-E] first real error" \
  "[20261014.120001.001-1-W] a warning" \
  "[20261014.120002.001-1-I] progress, not an error" \
  "[20261014.120003.001-1-D] debug, not an error" \
  "[ERROR] a bracketed one" \
  "ordinary line with no level at all" \
  > "$T/cen.log"
cout=$(bash tools/sweep-gate.sh --census "$T/cen.log" 2>&1); crc=$?
dout=$(SWEEP_GATE_DEFECT=1 bash tools/sweep-gate.sh --census "$T/cen.log" 2>&1); drc=$?
if [ $crc -eq 0 ] && printf '%s' "$cout" | grep -qa 'AGREE' && printf '%s' "$cout" | grep -qa 'the same 3 distinct' \
   && [ $drc -ne 0 ] && printf '%s' "$dout" | grep -qa 'DISAGREE'; then
  ok "T14 an independent awk pass and the tool agree on the 3 declared lines, and DISAGREE when the tool is broken"
else
  no "T14 census wrong (clean rc=$crc, defect rc=$drc)" "clean: $(printf '%s' "$cout" | tail -2) | defect: $(printf '%s' "$dout" | tail -1)"
fi

# T15 - THE BLIND SPOT IS MEASURED, AND UNMEASURABLE IS NOT ZERO. Reading declared severity is
# structurally blind to a failure that declares NOTHING, which is the case this tool exists for, so
# its size must be a number. A verdict ledger is an independent witness: a recorded FAIL whose log
# carries no declared error is a failure this detector would have missed. The first version joined
# label to log by filename and, on a real campaign dir whose logs are named agent-etwproxysup.log,
# matched nothing and called 14 of 14 failures "silent" - a broken join reported as a result.
mkdir -p "$T/sf"
printf 'cellA|FAIL the product misbehaved\ncellB|FAIL also broke\ncellC|PASS fine\n' > "$T/sf/verdicts.txt"
printf '[20261014.120000.001-1-E] something broke here\n' > "$T/sf/cellA.log"
printf 'nothing declared at all, just progress\n' > "$T/sf/cellB.log"
m=$(bash tools/sweep-gate.sh --silent-failures "$T/sf/verdicts.txt" "$T/sf"/*.log 2>&1)
printf 'zzz|FAIL unjoinable\n' > "$T/sf/v2.txt"
u=$(bash tools/sweep-gate.sh --silent-failures "$T/sf/v2.txt" "$T/sf/cellA.log" 2>&1); urc=$?
if printf '%s' "$m" | grep -qa 'measured=2 left_a_declared_error=1 silent=1' \
   && [ $urc -eq 2 ] && printf '%s' "$u" | grep -qa 'INCONCLUSIVE'; then
  ok "T15 a failure with a silent log is counted, and a label with no log is INCONCLUSIVE not zero"
else
  no "T15 blind-spot measurement wrong (urc=$urc)" "measured: $(printf '%s' "$m" | tail -1) | unjoinable: $(printf '%s' "$u" | tail -1)"
fi

# T16 - IT MUST NOT READ ITS OWN REPORT. The report quotes the messages it found, so a bracketed
# one is still a declared line when the report is swept. matrix.sh globs "$M"/*.out and writes its
# report to "$M"/sweep-gate.out, so before this a re-run gained PHANTOM findings - in a gate that
# raises INVALID and blocks a release. Measured: one real error became two.
mkdir -p "$T/own"
printf '[ERROR] DISM rc=3010 state_after=Not Present\n' > "$T/own/cell.log"
printf '# empty\n' > "$T/own/led.txt"
SWEEP_GATE_LEDGER="$T/own/led.txt" bash tools/sweep-gate.sh "$T/own/cell.log" > "$T/own/sweep-gate.out" 2>&1
again=$(SWEEP_GATE_LEDGER="$T/own/led.txt" bash tools/sweep-gate.sh "$T/own/cell.log" "$T/own/sweep-gate.out" 2>&1)
alone=$(SWEEP_GATE_LEDGER="$T/own/led.txt" bash tools/sweep-gate.sh "$T/own/cell.log" 2>&1)
n2=$(printf '%s' "$again" | grep -aoE 'unaccounted=[0-9]+' | head -1)
n1=$(printf '%s' "$alone" | grep -aoE 'unaccounted=[0-9]+' | head -1)
if [ "$n2" = "unaccounted=1" ] && [ "$n1" = "unaccounted=1" ]; then
  ok "T16 sweeping its own report adds nothing ($n1 alone, $n2 with the report beside it)"
else
  no "T16 it re-detects its own output ($n1 alone, $n2 with its report)" "$(printf '%s' "$again" | grep -a UNACCOUNTED | head -3)"
fi

echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
