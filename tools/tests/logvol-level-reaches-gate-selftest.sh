#!/bin/bash
# logvol-level-reaches-gate-selftest.sh - a declared level must reach the reader, end to end.
#
# WHY. logvol-lib.sh declares [ERROR]/[WARN] at its failure sites so tools/sweep-gate.sh, which
# reads ONLY declared severity, can see them. But _lv_say writes to STDERR, and two of its three
# call sites in the campaign harness sent that stderr to /dev/null - so every level declared in
# logvol_create, logvol_attach and logvol_pull was inert, and a cell learned "log volume not
# attached" while the reason was thrown away. Declaring a severity and discarding the stream are
# the same bug as a predicate fed a constant: the code reads correct and decides nothing.
#
# So this walks the whole chain on real tools: library writes -> call site captures into a .out ->
# the campaign's file glob picks it up -> sweep-gate detects it.
set -uo pipefail
# SYNTHETIC INPUT, DECLARED. This suite writes hand-made log lines to prove the library's declared
# ERROR/WARN levels reach tools/sweep-gate.sh. The gate now refuses an input it cannot grade -
# windows-utils lines with no module birth line among them - so two legs read 0 detections instead
# of 1 until the input is declared for what it is. Same variable and meaning as the gate's own
# --verify self-invocation; the requirement stays ON by default so a real caller that forgets fails
# closed, and tools/tests/sweep-life-selftest.sh asserts no production file sets it.
export _SG_CORPUS_LINE=1
cd "$(git rev-parse --show-toplevel 2>/dev/null || echo .)" || exit 2

T=$(mktemp -d "${TMPDIR:-/tmp}/logvol-level-reaches-gate.XXXXXX") || exit 2
trap 'rm -rf "$T"' EXIT INT TERM

pass=0; fail=0
ck(){ if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "ok   $1"; else fail=$((fail+1)); echo "FAIL $1: expected '$2', got '$3'"; fi; }

M=$(ls mgmt/harness/matri*.sh | head -1)
Q=$(ls mgmt/harness/quick-up*.sh | head -1)

# 1. NO CALL SITE MAY DISCARD IT. The library's own internal archive probe is exempt: a failure
#    there is the question being asked, and its caller logs the outcome either way.
disc=$(grep -n 'logvol_create\|logvol_attach\|logvol_pull\|logvol_bind_guest' "$M" "$Q" \
       | grep -c '>/dev/null 2>&1' || true)
ck "no campaign call site discards the library's stderr" "0" "${disc:-0}"
ck "the library's archive probe may still discard"       "1" \
   "$(grep -c 'logvol_pull "\$img" "\$arch" >/dev/null 2>&1' mgmt/harness/logvol-lib.sh)"

# 2. THE CHAIN, on the real gate. A captured library error, a preserved guest log line, and the
#    harness's own graded verdict all land in a campaign-shaped directory.
mkdir -p "$T/win10-clean-guestlogs/logs/files"
printf 'logvol: [ERROR] the binder refused: LOGVOL-BIND failed access denied\n' > "$T/WIN10-clean-logvol-setup.out"
printf '[20261014.150607.123-1234-E] QgaSomething: a real guest error\n'        > "$T/win10-clean-guestlogs/logs/files/agent.log"
printf '[15:06:07] [ERROR] FAIL  WIN10-clean: a graded product check\n'         > "$T/matrix.log"
printf 'log-sweep[win10-acc]: FAIL  missing or unparseable data\n'              > "$T/win10-clean-logsweep.out"

# The campaign's own glob, copied in shape: no depth limit, and the graded reports excluded.
mapfile -t F < <(find "$T" -type f \( -name '*.out' -o -name '*.log' -o -name '*.cur' -o -name '*.tail' \) \
                   -size -8M -size +0 ! -name '*-logsweep.out' ! -path '*-guestlogs/analyze.out' \
                   ! -path '*-guestlogs/sweep.log' 2>/dev/null | sort)
ck "the glob reaches a guest log at depth 4"  "1" "$(printf '%s\n' "${F[@]}" | grep -c 'guestlogs/logs/files/agent.log')"
ck "the glob skips each cell's graded report" "0" "$(printf '%s\n' "${F[@]}" | grep -c 'logsweep.out')"

timeout 100 bash tools/sweep-gate.sh "${F[@]}" > "$T/sweep.out" 2>&1
ck "the library's declared ERROR is detected" "1" "$(grep -ac 'UNACCOUNTED.*the binder refused' "$T/sweep.out")"
ck "the guest's own E line is detected"       "1" "$(grep -ac 'UNACCOUNTED.*QgaSomething' "$T/sweep.out")"

# 3. AND IT MUST BE SEEN TO FAIL. With the stderr discarded - the shipped behaviour until today -
#    the gate has nothing to read, which is what made the bug invisible.
mkdir -p "$T/discarded"
printf '[15:05:20]   WIN10-clean: [WARN] log volume not attached - a wedge here loses the QWT logs\n' > "$T/discarded/matrix.log"
timeout 100 bash tools/sweep-gate.sh "$T/discarded/matrix.log" > "$T/discarded.out" 2>&1
ck "with stderr discarded the REASON is unreadable" "0" "$(grep -ac 'binder refused\|could not size\|mkfs' "$T/discarded.out")"

echo "logvol-level-reaches-gate-selftest: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
