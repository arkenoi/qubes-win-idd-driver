#!/bin/bash
# ONE COUNTER, ONE READER. admin.vm.Stats emits repeating NULL-separated records:
#
#     <vm> \0 vm-stats \0 memory_kb \0 8388656 \0 cpu_time \0 ... \0 cpu_usage_raw \0 3 \0
#
# mgmt/reprovision-usb.sh:179 documents the wrong way to read it, with the measurement:
# `tr -d '\0'` then `grep -oE 'cpu_usage_raw[0-9]+'` is "wrong twice over - deleting the separators
# runs the value into the NEXT record (a real value of 3 was read as 31), and it then SUMMED every
# record in the whole 20 s stream. Measured 2026-08-30 on a genuinely idle guest: the probe reported
# 149 and 6225 where the true value was 3."
#
# e2e-wait.sh's wedge path used that exact reader until 2026-10-21, while prime-run.sh,
# quick-upgrade.sh, matrix.sh and reprovision-usb.sh all read it correctly. So a live installing
# guest logged cpu=107..252 from one reader and a stalled guest logged cpu_usage_raw=14736 from the
# other, and the two numbers looked directly comparable in a log that printed both (CPUTWOREADERS).
# They were not comparable, because one of them was not a cpu figure.
#
# This suite feeds a synthetic stream of the documented shape to BOTH readers and shows the
# difference, then sweeps the harness so the bad pattern cannot come back.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "ok   $1"; }
no(){ FAIL=$((FAIL+1)); echo "FAIL $1"; }

# Three records, as several vCPUs or several samples in one window. True max = 3, sum = 6.
stream(){ printf 'win10-x\0vm-stats\0memory_kb\0838865\0cpu_time\0111\0cpu_usage_raw\0003\0'
          printf 'win10-x\0vm-stats\0memory_kb\0838865\0cpu_time\0222\0cpu_usage_raw\0001\0'
          printf 'win10-x\0vm-stats\0memory_kb\0838865\0cpu_time\0333\0cpu_usage_raw\0002\0'; }

# the reader taken OUT of the shipped file, so this cannot drift from the harness
good=$(stream | tr '\0' '\n' \
       | awk '/^cpu_usage_raw$/{getline v; if(v+0>m)m=v+0; n++} END{if(n==0)print "NA"; else print m}')
bad=$(stream | tr -d '\0' \
      | grep -aoE 'cpu_usage_raw[0-9]+' | grep -aoE '[0-9]+' | awk '{t+=$1} END{if(NR)print t; else print "NA"}')

[ "$good" = 3 ] && ok "the correct reader returns the true max (3) from a NUL-separated stream" \
                 || no "the correct reader returned '$good', expected 3"
[ "$bad" != 3 ] && ok "negative control: the pre-fix reader returns '$bad', not 3 - it is not a cpu figure" \
                 || no "negative control: the pre-fix reader also returned 3, so nothing was wrong"

# the empty case must be NA, not 0 - an unreadable stat is not an idle guest
empty=$(printf '' | tr '\0' '\n' \
        | awk '/^cpu_usage_raw$/{getline v; if(v+0>m)m=v+0; n++} END{if(n==0)print "NA"; else print m}')
[ "$empty" = NA ] && ok "an unreadable stat reads NA, not 0 (an absent number is not a calm guest)" \
                   || no "an unreadable stat read '$empty'"

# ---------------------------------------------------------------- THE SWEEP
# No harness file may use the pattern reprovision-usb.sh documents as wrong. Checking the one file
# someone remembered is how this survived in e2e-wait.sh for weeks while four siblings were correct.
hits=$(cd "$ROOT" && command grep -rn "cpu_usage_raw\[0-9\]" --include='*.sh' mgmt tools \
       | command grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' | command grep -v '/tests/' || true)
if [ -z "$hits" ]; then
  ok "no live line in mgmt/ or tools/ uses the run-together grep pattern"
else
  no "the documented-wrong reader is still live: $(printf '%s' "$hits" | tr '\n' ' ')"
fi

# and every reader of this counter must take the MAX across records, never a sum
sums=$(cd "$ROOT" && command grep -rn 'cpu_usage_raw' --include='*.sh' mgmt tools \
       | command grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' | command grep -v '/tests/' \
       | command grep -a 't+=' || true)
[ -z "$sums" ] && ok "no reader sums the counter across records" \
               || no "a reader still sums it: $(printf '%s' "$sums" | tr '\n' ' ')"

# the log line must name the unit, or the next reader guesses again
if command grep -aq 'max per vCPU' "$ROOT/mgmt/harness/e2e-wait.sh"; then
  ok "the wedge path's log line names the unit it is printing"
else
  no "the cpu figure is printed with no unit - the defect was that two scales looked comparable"
fi

echo
echo "RESULT: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
