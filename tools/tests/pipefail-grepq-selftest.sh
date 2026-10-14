#!/bin/bash
# pipefail-grepq-selftest.sh - a file read piped into `grep -q` loses the match it found.
#
# THE MECHANISM, demonstrated rather than described: `grep -q` exits on its FIRST match and closes
# the pipe; the reader upstream still has data to write, dies of SIGPIPE, and `pipefail` makes 141
# the status of the whole pipeline. The caller then reads "no match" on a file that matched.
#
# It only fires when the upstream has more to write than the pipe buffer holds AND the match comes
# early, which is why it hides: on 2026-10-14 it reported 0 of 3047 lines in tools/sweep-gate.sh and
# disabled that tool's own-report skipping, on a 1.5 MB log, while every fixture was small enough to
# pass. L23 forbids the shape for a GUEST PROBE (where it graded a live guest dead 86 times in 200);
# the six sites below were the same shape on ordinary files, including run-lib.sh's job-start
# confirmation, which every harness inherits - there a growing log plus an early marker made a job
# that HAD started report as never having started.
set -uo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || echo .)" || exit 2

T=$(mktemp -d "${TMPDIR:-/tmp}/pipefail-grepq.XXXXXX") || exit 2
trap 'rm -rf "$T"' EXIT INT TERM

pass=0; fail=0
ck(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "ok   $1"; else fail=$((fail+1)); echo "FAIL $1: expected '$2', got '$3'"; fi; }

# A file far past the 64 KiB pipe buffer, with the match on line 1.
{ echo "MARKER-ON-LINE-ONE"; for i in $(seq 1 60000); do echo "filler line $i ................................"; done; } > "$T/big.log"
sz=$(wc -c < "$T/big.log")
ck "the fixture is past the pipe buffer" "yes" "$([ "$sz" -gt 200000 ] && echo yes || echo "no ($sz bytes)")"

# THE TRAP. Run in a subshell so this script's own status is unaffected.
( set -o pipefail; cat "$T/big.log" | grep -qa 'MARKER-ON-LINE-ONE' ) 2>/dev/null; rc_q=$?
ck "grep -q on a big file returns 141, not 0" "141" "$rc_q"
ck "so the match it FOUND reads as absent"    "no"  "$([ "$rc_q" -eq 0 ] && echo yes || echo no)"

# THE FORM THE HARNESS USES NOW: grep -c reads to EOF, so nothing closes the pipe.
( set -o pipefail; [ "$(cat "$T/big.log" | grep -ac 'MARKER-ON-LINE-ONE')" -gt 0 ] ) 2>/dev/null; rc_c=$?
ck "counting returns the right answer"        "0"   "$rc_c"
# and still says no when there is nothing to find
( set -o pipefail; [ "$(cat "$T/big.log" | grep -ac 'NOT-IN-THIS-FILE')" -gt 0 ] ) 2>/dev/null; rc_n=$?
ck "counting still reports a real absence"    "1"   "$rc_n"

# AND THE SITES MUST BE GONE. Each was read and confirmed before being changed.
left=0
for f in p3a-etw-gate.sh quick-upgrade.sh run-lib.sh; do
  # Comments stripped first: three checks today matched the comment EXPLAINING the shape they
  # forbid, which is the same trap as a scripted edit landing inside its own explanation.
  n=$(grep -vE '^[[:space:]]*#' "mgmt/harness/$f" | grep -cE '(cat|tail|head|sed -n|grep -a)[^|]*\|[^|]*grep[[:space:]]+-[a-zA-Z]*q')
  [ "${n:-0}" -eq 0 ] || { echo "   $f still has ${n} file-read-into-grep-q line(s)"; left=$((left+n)); }
done
ck "no file read is piped into grep -q in the three fixed files" "0" "$left"

# run-lib.sh's start confirmation is the one every harness inherits, so it is named explicitly.
ck "run_verified counts instead of grep -q" "1" \
   "$(grep -c 'grep -ac "\$re")" -gt 0 \]' mgmt/harness/run-lib.sh)"

echo "pipefail-grepq-selftest: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
