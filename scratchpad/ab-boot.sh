#!/bin/bash
# Interleaved A/B of the MSO_BORDEREFFECT class rule, one cold boot per side.
#
# In-place gui-agent restarts are unusable: a single one kills gui-daemon, which never
# comes back, and the agent then announces nothing (FINDINGS 2026-08-04). So each side
# installs its binary, reboots the qube, and measures against the agent instance the
# fresh daemon connected to at boot. That also makes every measurement a boot-path test.
set -u
cd /home/user/qubes-win-idd-driver
S=/tmp/claude-1000/-home-user-qubes-win-idd-driver/af572f4c-9813-43a7-b2fc-a1299d189356/scratchpad
INC='C:\Users\user\Documents\QubesIncoming\win-idd-mgmt'
OUT=$S/ab-boot-results.txt
ROUNDS=${ROUNDS:-3}

wait_state() {  # $1 = desired state
  for _ in $(seq 1 60); do
    [ "$(qvm-ls --fields NAME,STATE 2>/dev/null | grep win-idd-test | awk '{print $2}')" = "$1" ] && return 0
    sleep 5
  done
  return 1
}

wait_qrexec() {
  for _ in $(seq 1 30); do
    [ "$(timeout 25 ./tools/qtest run 'echo BOOT_OK' 2>&1 | grep -c BOOT_OK)" -ge 2 ] && return 0
    sleep 10
  done
  return 1
}

run_side() {
  local which=$1 round=$2 tag="$1-r$2"
  echo "=== $tag ===" >> "$OUT"

  # Install the binary for this side. The agent must be stopped first: Windows locks a
  # running image, so copying over it fails and - with -Force and no error check - leaves
  # the PREVIOUS build in place while the harness happily reports success. That is the
  # "verify the artefact under test is actually installed" rule, learned the hard way here.
  # Stopping the watchdog costs the gui-daemon, but the reboot below restores it anyway.
  # Multi-line PowerShell does not survive the `qtest ps` wrapper - it arrives as literal
  # text and every side "fails" without installing anything. Keep it in a pushed script.
  local expect
  if [ "$which" = orig ]; then expect=4B4CE2B1C5441C88; else expect=4DA9FE967A8A1012; fi
  # NB: do not filter with [^\r] - in a POSIX bracket expression that reads as "not
  # backslash, not r", which silently truncates INSTALL=OK at the first letter r.
  local inst
  inst=$(timeout 90 ./tools/qtest ps "& '$INC\\install-agent.ps1' -Which $which" 2>&1 \
         | tr -d '\r' | grep -E '^INSTALL=' | tail -1)
  echo "$tag: $inst" >> "$OUT"
  if ! printf '%s' "$inst" | grep -q "hash=$expect"; then
    echo "$tag: FAIL install (wanted hash=$expect, got '$inst')" >> "$OUT"
    echo "$tag: FAIL install"
    return 1
  fi

  timeout 200 ./tools/qtest shutdown >/dev/null 2>&1
  wait_state Halted || { echo "$tag: FAIL shutdown" >> "$OUT"; return 1; }
  timeout 200 ./tools/qtest start >/dev/null 2>&1
  wait_state Running || { echo "$tag: FAIL start" >> "$OUT"; return 1; }
  wait_qrexec       || { echo "$tag: FAIL qrexec" >> "$OUT"; return 1; }
  sleep 20   # let the shell/agent settle before creating the scene

  timeout 115 ./tools/qtest ps "& '$INC\\boot-measure.ps1' -Which $which" 2>&1 \
    | tr -d "\r" | grep -E "STRIPS_|MAIN_MAPPED|LOG=|RESULT" >> "$OUT"
  echo "$tag: $(grep -h "^RESULT which=$which" "$OUT" | tail -1)"
}

: > "$OUT"
for r in $(seq 1 "$ROUNDS"); do
  run_side orig "$r"
  run_side new  "$r"
done
echo "--- all results ---"
grep -E '^RESULT' "$OUT"
