#!/bin/bash
# matrix-runmarker-selftest.sh - the run-marker read must take the GUEST's answer, not the echo.
#
# THE DEFECT THIS PINS. `qtest run` returns the cmd banner and the prompt line WITH THE COMMAND ON
# IT, and that command text contains both PRESENT and ABSENT. matrix.sh read it with
# `grep -ao 'PRESENT\|ABSENT' | head -1`, which takes whichever token appears first IN THE ECHOED
# COMMAND - always PRESENT - so the check could not fail while the guest answered, and returned
# empty when it did not. quick-upgrade.sh had already fixed this; matrix.sh had not.
#
# The fixture is the real output shape, taken from the 2026-10-14 campaign log (win10-acc,
# 10.0.19045.2965), not a shape I imagined.
set -uo pipefail
cd "$(git rev-parse --show-toplevel 2>/dev/null || echo .)" || exit 2

T=$(mktemp -d "${TMPDIR:-/tmp}/matrix-runmarker-selftest.XXXXXX") || exit 2
trap 'rm -rf "$T"' EXIT INT TERM

pass=0; fail=0
ck(){ # <name> <expected> <got>
  if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "ok   $1"
  else fail=$((fail+1)); echo "FAIL $1: expected '$2', got '$3'"; fi
}

# The guest's real reply shape: banner, blank, prompt+command, the guest's own word, trailing prompt.
MARK='E2EMARK-20261014120600-1234'
cat > "$T/answer-absent.txt" <<EOF
Microsoft Windows [Version 10.0.19045.2965]
(c) Microsoft Corporation. All rights reserved.

C:\\Windows\\system32>cmd /c findstr /c:"$MARK" C:\\qwt-improved-install.log >nul 2>&1 && echo PRESENT || echo ABSENT
ABSENT

C:\\Windows\\system32>
EOF
sed 's/^ABSENT$/PRESENT/' "$T/answer-absent.txt" > "$T/answer-present.txt"
: > "$T/answer-silent.txt"

# matrix.sh's reader as it stood, and as it stands now. Both read the same bytes.
old(){ tr -d '\r' | grep -ao 'PRESENT\|ABSENT' | head -1; }
_shell_echo_strip(){ grep -avE '^(Microsoft Windows \[Version|\(c\) Microsoft|C:\\)'; }
new(){ tr -d '\r' | _shell_echo_strip | grep -ao 'PRESENT\|ABSENT' | tail -1; }

# THE CHECK MUST BE SEEN TO FAIL: the old reader calls an ABSENT guest PRESENT.
ck "old reader reads PRESENT off its own echo (the defect)" "PRESENT" "$(old < "$T/answer-absent.txt")"
ck "new reader takes the guest's own ABSENT"                "ABSENT"  "$(new < "$T/answer-absent.txt")"
ck "new reader still reads a true PRESENT"                  "PRESENT" "$(new < "$T/answer-present.txt")"
ck "new reader reports nothing when the guest is silent"    ""        "$(new < "$T/answer-silent.txt")"

# And the shipped file must actually use it: one reader, no head -1, and the retry present.
m=mgmt/harness/matrix.sh
ck "matrix.sh defines one marker reader"       "1" "$(grep -c '^_mark_seen()' "$m")"
ck "matrix.sh no longer head -1's the marker"  "0" "$(grep -c "grep -ao 'PRESENT\\\\|ABSENT' | head -1" "$m")"
ck "matrix.sh retries while cpu_time moves"    "1" "$(grep -c 'run marker no answer yet, but the guest IS EXECUTING' "$m")"
ck "both marker reads go through the reader"   "2" "$(grep -c 'seen=$(_mark_seen' "$m")"

# THE DISC CHECK HAD THE SAME TWO FAULTS, in the step just before this one. It read the release
# disc's MANIFEST once and, on an empty answer, reported "built from 'unreadable'" - conflating an
# instrument failure with a provenance failure, in a message that said so in plain sight. On
# 2026-10-14 that hard-FAILED a cell on a medium Gate-0 had already verified from this side.
# Reading CODE, not the comments that describe it.
mcode(){ grep -vE '^[[:space:]]*#' "$m"; }
ck "the MANIFEST read retries while the guest executes" "1" \
   "$(mcode | grep -c 'MANIFEST read came back empty while the guest IS EXECUTING')"
ck "and stops when cpu_time is flat"                    "1" \
   "$(mcode | grep -c 'MANIFEST read came back empty and cpu_time is FLAT')"
ck "an unreadable MANIFEST is INVALID-INSTRUMENT"       "1" \
   "$(mcode | grep -c 'INVALID-INSTRUMENT - could not read \$RELDISC')"
ck "a wrong commit is still a provenance FAIL"          "1" \
   "$(mcode | grep -c 'was built from \${got:0:12}')"
ck "no 'unreadable' is passed off as a commit"          "0" \
   "$(mcode | grep -c "built from '\${got:-unreadable}'")"

echo "matrix-runmarker-selftest: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
