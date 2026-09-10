#!/bin/bash
# CATCH ONE RESOLVABLE SPECIMEN, as cheaply as possible. Prime -> arm -> cycle, GATED at every step.
#
# WHY A CATCHER AND NOT A RATE (owner, 2026-09-10: "i do not think stall count is THAT useful to be
# precisely measured"). A rate only earns its cost when something is being compared before and after
# a change, and there is no such change to test: dom0-side knobs are ruled out by the owner, the
# "install PV storage in stage 1" idea is withdrawn on the installer's own contract, and every
# remaining candidate is untested. What is missing is the MECHANISM - the name of the Windows
# primitive that spins, and what the device model's main loop is blocked on. That needs ONE specimen
# whose RIPs can be RESOLVED, which no specimen so far has been.
#
# WHY THIS ROUTE. The loaded-ACPI cycle produced specimen 2 on its FIRST round: ~3 minutes an
# attempt against ~11 for a clean install. That hit rate is n=1 and may have been luck, so this is
# cheap attempts at an unknown rate rather than a good rate - which is the right shape when the goal
# is one specimen and not a denominator.
#
# WHY IT IS GATED, and this is the part that cost a run. The previous attempt was an inline chain:
# remove the old subject, prime, cycle. The remove FAILED (the guest had been restarted by queued
# qrexec calls from a harness I had killed) and I had discarded its stderr with 2>/dev/null; prime-run
# then correctly refused, and the chain RAN THE CYCLER ANYWAY against a subject that did not exist,
# voiding fifteen rounds in three minutes. CLAUDE.md names that exact failure - "a harness that
# proceeds on a failed install reports results for a build that was never running". So: every step
# here is gated on the previous one, no error output is discarded, and the preconditions are asserted
# rather than assumed.
#
# NOTHING IS EVER KILLED once cycling starts: a wedged guest is the product, and the cycler leaves it
# exactly as it stands.
#
# Usage:  W=<work dir with dl/qwt-improved-setup> SUBJ=win10-cyc ROUNDS=15 mgmt/harness/catch-specimen.sh
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2

W="${W:?set W to the work dir holding dl/qwt-improved-setup}"
SUBJ="${SUBJ:-win10-cyc}"
BASE="${BASE:-win10-base}"
JOB="${JOB:-ours}"
ROUNDS="${ROUNDS:-15}"
OUT="${OUT:-/home/user/rel/catch-$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$OUT"
say(){ echo "[$(date -u +%H:%M:%S)] $*" | tee -a "$OUT/summary.log"; }
die(){ say "STOP: $*"; exit 1; }

[ -d "$W/dl/qwt-improved-setup" ] || die "no payload at $W/dl/qwt-improved-setup"
ver=$(python3 -c "import json;print(json.load(open('$W/dl/qwt-improved-setup/MANIFEST.json'))['release_version'])" 2>/dev/null)
say "=== catch-specimen: subject $SUBJ, job $JOB, package ${ver:-UNKNOWN}, $ROUNDS cycles ==="

# GATE 1: the subject must not exist, and removing it must SUCCEED VISIBLY. A guest left Running by
# queued qrexec calls is the normal case here, not an anomaly, so drain it rather than assume.
if qvm-ls --raw-data --fields NAME 2>/dev/null | grep -qx "$SUBJ"; then
  say "subject $SUBJ exists - removing it (its state is unknown, and an unknown baseline measures the mess)"
  qvm-prefs "$SUBJ" qrexec_timeout 5 2>&1 | tee -a "$OUT/summary.log"
  qvm-kill "$SUBJ" 2>&1 | tee -a "$OUT/summary.log"
  for i in $(seq 1 20); do
    [ "$(qvm-ls --raw-data --fields NAME,STATE | awk -F'|' -v v="$SUBJ" '$1==v{print $2}')" = Halted ] && break
    sleep 2
  done
  qvm-remove -f "$SUBJ" 2>&1 | tee -a "$OUT/summary.log"
  qvm-ls --raw-data --fields NAME 2>/dev/null | grep -qx "$SUBJ" \
    && die "$SUBJ still exists after remove - not proceeding on a subject of unknown provenance"
fi

# GATE 2: prime-run refuses while any other win1x guest is up, and it is right to. Report WHICH,
# because "not Halted" with no name sent me hunting the wrong guest once already.
up=$(qvm-ls --raw-data --fields NAME,STATE 2>/dev/null \
     | awk -F'|' -v v="$SUBJ" '$2!="Halted" && $1!=v && $1 ~ /^(win(10|11)|prime-)/{print $1}' | tr '\n' ' ')
[ -z "${up// /}" ] || die "these guests are not Halted and prime-run will refuse: $up"

# GATE 3: prime, and STOP on failure. The whole point.
say "priming $SUBJ from $BASE (job $JOB)"
if ! ./mgmt/harness/prime-run.sh "$BASE" "$SUBJ" "$JOB" --payload "$W/dl/qwt-improved-setup" >"$OUT/prime.log" 2>&1; then
  say "prime FAILED - last lines:"; tail -5 "$OUT/prime.log" | tee -a "$OUT/summary.log"
  die "no subject to cycle. NOT proceeding: a cycler run against a guest that does not exist voids
       every round and reports nothing, which is what happened on the previous attempt."
fi
say "prime OK"

# GATE 4: the subject must actually answer before anything is armed or cycled.
source mgmt/harness/e2e-wait.sh
w_alive "$SUBJ" || die "$SUBJ primed but does not answer qrexec"

# The cycler arms module bases itself (once, up front - the onstart task then covers every reboot it
# performs, including the one that wedges) and stops on a hit with the guest untouched.
say "cycling: ACPI shutdown under verified in-flight load, $ROUNDS rounds"
VM="$SUBJ" ROUNDS="$ROUNDS" ROUTE=acpi LOAD_MODE=concurrent OUT="$OUT/ab" \
  ./mgmt/harness/flush-durability-ab.sh 2>&1 | tee -a "$OUT/cycle.log"
rc=${PIPESTATUS[0]}
say "cycler rc=$rc"
if [ "$rc" = 1 ]; then
  say "A SPECIMEN MAY BE STANDING. Check $OUT/ab/summary.log for the classification, and capture it"
  say "in dom0 BEFORE anything touches it. Then, and this is what no specimen has managed yet:"
  say "  VM=$SUBJ mgmt/harness/arm-module-bases.sh --dump"
  say "  tools/resolve-guest-rip.py <that dump> <the spinning RIP from debug-keys v>"
fi
say "=== done: $OUT ==="
