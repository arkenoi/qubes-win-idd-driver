#!/bin/bash
# Interleaved A/B of agent 66fc670 (never re-home an owned popup onto an unrelated
# sibling), one cold boot per side.
#
# control = agent aaa8c37  (pre-fix; NOT stock QWT, which has no composite synthesis at all
#                           and so could never exhibit this defect)
# test    = agent 6b5b298  (contains 66fc670)
#
# Metric: does the agent log QGAPROTO,msg=SYNTH for the orphan popup, naming the main frame
# as its owner? The control must produce it, or the check cannot fail and proves nothing.
set -u
cd /home/user/qubes-win-idd-driver
S=/tmp/claude-1000/-home-user-qubes-win-idd-driver/af572f4c-9813-43a7-b2fc-a1299d189356/scratchpad
INC='C:\Users\user\Documents\QubesIncoming\win-idd-mgmt'
OUT=$S/ab-orphan-results.txt
ROUNDS=${ROUNDS:-3}

: "${CTL_FILE:?set CTL_FILE (name in QubesIncoming)}"
: "${CTL_HASH:?set CTL_HASH}"
: "${NEW_FILE:?set NEW_FILE}"
: "${NEW_HASH:?set NEW_HASH}"

wait_state() {
  for _ in $(seq 1 60); do
    [ "$(qvm-ls --fields NAME,STATE 2>/dev/null | grep win-idd-test | awk '{print $2}')" = "$1" ] && return 0
    sleep 5
  done
  return 1
}
wait_qrexec() {
  for _ in $(seq 1 30); do
    [ "$(timeout 25 ./tools/qtest run 'echo BOOT_OK' 2>&1 | tr -d '\r' | grep -c BOOT_OK)" -ge 2 ] && return 0
    sleep 10
  done
  return 1
}

run_side() {
  local which=$1 round=$2 tag="$1-r$2" file hash
  if [ "$which" = ctl ]; then file=$CTL_FILE; hash=$CTL_HASH; else file=$NEW_FILE; hash=$NEW_HASH; fi
  echo "=== $tag ===" >> "$OUT"

  local inst
  inst=$(timeout 90 ./tools/qtest ps "& '$INC\\install-agent2.ps1' -SrcName $file -ExpectHash $hash" 2>&1 \
         | tr -d '\r' | grep -E '^INSTALL=' | tail -1)
  echo "$tag: $inst" >> "$OUT"
  if ! printf '%s' "$inst" | grep -q "hash=$hash"; then
    echo "$tag: FAIL install (wanted hash=$hash, got '$inst')" >> "$OUT"; echo "$tag: FAIL install"; return 1
  fi

  timeout 200 ./tools/qtest shutdown >/dev/null 2>&1
  wait_state Halted  || { echo "$tag: FAIL shutdown" >> "$OUT"; return 1; }
  timeout 200 ./tools/qtest start >/dev/null 2>&1
  wait_state Running || { echo "$tag: FAIL start" >> "$OUT"; return 1; }
  wait_qrexec        || { echo "$tag: FAIL qrexec" >> "$OUT"; return 1; }
  sleep 20

  timeout 115 ./tools/qtest ps "& '$INC\\boot-measure-orphan.ps1' -Which $which -ExpectHash $hash" 2>&1 \
    | tr -d '\r' | grep -E 'ORPHAN_|MAIN|SYNTH_ALL|LOG=|RESULT' >> "$OUT"
  echo "$tag: $(grep -h "^RESULT which=$which" "$OUT" | tail -1)"
}

: > "$OUT"
for r in $(seq 1 "$ROUNDS"); do
  run_side ctl "$r"
  run_side new "$r"
done
echo "--- all results ---"
grep -E '^RESULT' "$OUT"
