#!/bin/bash
# stall-hunt.sh - run GATED reproduction passes until one stalls, then stop and preserve everything.
#
# Every pass goes through the SAME entry point the failure used (notify-errors-guest-test.sh ->
# quick-upgrade), and the stall-repro gate refuses any pass that differs from the reference on a
# recorded dimension, so a null result means something. A pass that stalls ends the hunt: the guest
# is left running, dom0 forensics are captured, and the module-base table taken host-side at arm
# time (arm-module-bases.sh) makes the RIPs resolvable even though qrexec is dead.
#
#   mgmt/harness/stall-hunt.sh [max-passes]
#
# It does not kill the subject on a stall and it does not "try again" past one: a preserved
# specimen is worth more than another sample.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2
MAX="${1:-12}"
PKG="${PKG:-/home/user/qwt-accept/rel-35650754623/dl/qwt-improved-setup}"
# NO DEFAULT TARGET. A harness that picks a guest for you is how a run lands on the wrong subject
# and is graded anyway (lint L10, and tools/qtest has refused a default since 2026-09-21).
VM="${VM:?set VM to the subject this hunt may create and destroy}"
OUT="scratchpad/stall-hunt-$(date -u +%Y%m%dT%H%M%SZ)"; mkdir -p "$OUT"
say(){ echo "$(date -u +%H:%M:%SZ) stall-hunt: $*" | tee -a "$OUT/hunt.log"; }

# JEV REFUSED THIS HUNT BEFORE IT EVER RAN (2026-09-22): faithful_without_shortcuts 0.18,
# detection_is_sound 0.12, worth_running=add-a-variable-first 0.67 with run-it at 0.01; and asked
# what the substitution was: gate-lets-unfaithful-passes-run 0.72 - admitting passes at
# is_one_to_one ~0.13 IS the shortcut, because the reference's unrecorded dimensions cannot be
# matched at all. A hunt that cannot be faithful cannot produce an informative null.
# So this refuses by default. It becomes runnable when a reference exists that was captured WITH
# today's instruments (entry snapshot, host-side module bases), i.e. after a natural recurrence -
# at which point set STALL_HUNT_I_HAVE_A_FAITHFUL_REFERENCE=1 and say why in the commit.
if [ "${STALL_HUNT_I_HAVE_A_FAITHFUL_REFERENCE:-0}" != 1 ]; then
  say "REFUSING: no faithful reference exists. The 2026-09-22 reference predates the entry snapshot"
  say "  and the host-side module-base copy, so no pass can be 1:1 with it (is_one_to_one ~0.13) and"
  say "  a null result would prove nothing. Jev: run-it 0.01. Wait for a recurrence captured with the"
  say "  instruments now armed, build a reference from it, and this hunt becomes worth running."
  exit 2
fi

say "hunting the stall: up to $MAX gated passes through notify-errors-guest-test.sh on $VM"
for i in $(seq 1 "$MAX"); do
  L="$OUT/pass$i.log"
  # Self-clean up front: a leftover subject is the documented way a pass reports someone else's state.
  if qvm-check "$VM" >/dev/null 2>&1; then
    timeout 120 qvm-kill "$VM" >/dev/null 2>&1; timeout 300 qvm-remove -f "$VM" >/dev/null 2>&1
  fi
  say "pass $i/$MAX starting"
  VM="$VM" PKG="$PKG" STALL_REPRO=1 LOG="$PWD/$L" \
    timeout 5400 bash mgmt/harness/notify-errors-guest-test.sh > "$OUT/pass$i.out" 2>&1
  rc=$?
  # THE REFERENCE FAILURE, not any stall. Jev: detection_must_check=zero-installer-output 0.97 -
  # its distinguishing property is that it produced no installer output beyond the harness's own
  # marker and never recovered. A STALLED verdict alone can be a different failure.
  stalled=0; grep -qE "TERMINAL: install STALLED|STALLED \(SPINNING\)|STALLED \(FROZEN\)" "$L" 2>/dev/null && stalled=1
  run=$(ls -td /home/user/qwt-quick-upgrade/$VM-* 2>/dev/null | head -1)
  olines=$(wc -l < "$run/install.tail" 2>/dev/null || echo -1)
  if [ "$stalled" = 1 ] && [ "${olines:-99}" -le 1 ]; then
    say "pass $i IS THE REFERENCE FAILURE: STALLED with $olines installer output line(s) - preserving; the hunt stops"
    D="$OUT/specimen-pass$i"; mkdir -p "$D"
    timeout 300 qrexec-client-vm dom0 "local.WinWedgeForensics+$VM" </dev/null > "$D/forensics.tar" 2>"$D/forensics.err"
    a=$(ls -t ~/QubesIncoming/dom0/wedge-*.tar.gz 2>/dev/null | head -1); [ -n "$a" ] && cp "$a" "$D/"
    timeout 120 bash tools/loopback-health.sh > "$D/loopback.txt" 2>&1
    run=$(ls -td /home/user/qwt-quick-upgrade/$VM-* 2>/dev/null | head -1)
    [ -n "$run" ] && cp -r "$run" "$D/run-dir" 2>/dev/null
    mb="$D/run-dir/modbases/module-bases.txt"
    if [ -s "$mb" ]; then
      say "  module bases present host-side ($(grep -ac MODBASE "$mb") records) - RIPs are resolvable"
      for f in "$D"/wedge-*/rip-d*.txt "$D"/rip-d*.txt; do
        [ -f "$f" ] || continue
        for rip in $(grep -ho '0010:\[<[0-9a-f]*>\]' "$f" | grep -o '[0-9a-f]\{8,\}'); do
          say "  RIP 0x$rip -> $(timeout 60 python3 tools/resolve-guest-rip.py "$mb" "0x$rip" 2>&1 | tail -1)"
        done
      done
    else
      say "  WARNING: no host-side module-base copy in the run dir - the RIPs will not resolve"
    fi
    say "specimen preserved in $D; the guest is LEFT RUNNING - do not kill it"
    exit 0
  fi
  if [ "$stalled" = 1 ]; then
    say "pass $i stalled but produced $olines installer output line(s) - that is a DIFFERENT failure from the reference; preserving it separately and continuing"
    mkdir -p "$OUT/other-stall-pass$i"
    timeout 300 qrexec-client-vm dom0 "local.WinWedgeForensics+$VM" </dev/null > "$OUT/other-stall-pass$i/forensics.tar" 2>/dev/null
  else
    say "pass $i completed without a stall (rc=$rc)"
  fi
done
say "no stall in $MAX passes - that bounds the rate under gated conditions, it does not clear the defect"
exit 1
