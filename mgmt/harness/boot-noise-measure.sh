#!/bin/bash
# boot-noise-measure.sh - how many error lines does a NORMAL BOOT write, with nothing driving it?
#
#   mgmt/harness/boot-noise-measure.sh <subject> [settle-seconds]
#
# WHY THIS AND NOT THE OTHER RUNS. Every error-line count this project has is from a run where the
# harness was driving the guest: an install, 25 qrexec calls, calls abandoned under a timeout. The
# departed-peer class in particular is OUR stimulus - the lines name domain 10858, this management
# qube, and they appear because a client left before the wrapper could connect. So "error noise
# during the normal boot" has never actually been measured. This measures it: boot, touch nothing,
# then sweep.
#
# PRE-REGISTERED, before the run (.claude/skills/experimenter):
#   HYPOTHESIS  a boot with nothing driving it writes ZERO undeclared error lines. Refuted by any.
#   BASELINE    the same guest under load, 2026-10-08: 171 undeclared error lines, of which 148 were
#               the MSI rollback plan (since fixed) and 8 were the departed-peer class from the
#               harness's own abandoned calls. No quiet-boot number exists.
#   VARIABLE    the stimulus: none. Same guest, same package.
#   INSTRUMENT  mgmt/harness/log-sweep.sh with --since at the boot instant, so only this boot counts;
#               validated offline by tools/tests/log-sweep-selftest.sh (64 checks).
#   BUDGET      shutdown + boot ~4 min, settle as given (default 240 s), sweep ~2 min. The qrexec
#               wait is this script's own and has three exits - it answered, the guest reached a
#               terminal state (Halted), or the 300 s deadline - and nothing else sleeps on a timer
#               except the deliberate settle, which IS the measurement window.
#
# THE SWEEP IS ITSELF A STIMULUS and that is accounted for, not ignored: collecting the logs needs
# qrexec calls, so the wrapper will log for them. They are ORDINARY completed calls, not abandoned
# ones, which is exactly the distinction this run exists to make. Their lines are attributed by pid
# in the report, and the verdict below names any error line whose pid belongs to the sweep's own
# calls separately from the rest.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SUBJ="${1:-}"
SETTLE="${2:-240}"
[ -n "$SUBJ" ] || { echo "usage: $0 <subject> [settle-seconds]"; exit 2; }
case "$SUBJ" in dom0|win-idd-mgmt) echo "FATAL: $SUBJ is not a testbed subject"; exit 2 ;; esac
OUT="${BOOTNOISE_OUT:-$HOME/qwt-bootnoise}/$(date -u +%Y%m%dT%H%M%SZ)-$SUBJ"
mkdir -p "$OUT"
log(){ echo "[$(date -u +%H:%M:%S)] $*" | tee -a "$OUT/run.log"; }

# shellcheck source=/dev/null
. "$ROOT/mgmt/harness/vmlock.sh"
# ONE way to power a guest down, and it never kills (mgmt/harness/shutdown-lib.sh): `qvm-shutdown
# --wait` is a KILL ON A TIMER - the --timeout it takes is when it kills, not how long it waits -
# and a killed guest would make the next boot explain the kill, which is the measurement.
# shellcheck source=/dev/null
. "$ROOT/mgmt/harness/shutdown-lib.sh"
vm_lock "$SUBJ" || { echo "FATAL: another VM-mutating job holds the lock"; exit 2; }
# e2e-lib.sh is deliberately NOT sourced: its line 11 refuses to load without QTEST_VM set ("there
# is deliberately no default target") by calling exit, which a `|| true` on the source cannot catch -
# it killed this script silently right after the lock, on the first run. Nothing from it is used; the
# one wait below is this script's own, with the three exits rule 6 requires.

log "subject=$SUBJ settle=${SETTLE}s out=$OUT"

# ---- 1. down, cleanly: a kill would contaminate the very thing being measured -------------------
log "shutting $SUBJ down cleanly (a kill would leave the next boot explaining the kill)"
qwt_shutdown "$SUBJ" 900 >>"$OUT/shutdown.log" 2>&1
state=$(qvm-ls --raw-data --fields NAME,STATE 2>/dev/null | awk -F'|' -v v="$SUBJ" '$1==v{print $2}')
[ "$state" = Halted ] || { log "FATAL: $SUBJ is '$state', not Halted after a clean shutdown - not booting on top of that"; exit 1; }

# ---- 2. up, and then LEFT ALONE -----------------------------------------------------------------
SINCE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
log "since=$SINCE  (the sweep window opens here, before the boot)"
qvm-start "$SUBJ" >>"$OUT/start.log" 2>&1 || { log "FATAL: $SUBJ would not start"; tail -3 "$OUT/start.log"; exit 1; }
log "booted; waiting for qrexec, then leaving it ALONE for ${SETTLE}s"

# One bounded wait for qrexec, with three exits: it answered, it is in a terminal state, or no
# progress. This is the only thing touched before the settle.
answered=0
deadline=$(( $(date +%s) + 300 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
    if QTEST_VM="$SUBJ" timeout 30 "$ROOT/tools/qtest" run "$SUBJ" 'cmd /c echo BOOTNOISE_UP' 2>/dev/null | command grep -aq BOOTNOISE_UP; then
        answered=1; break
    fi
    st=$(qvm-ls --raw-data --fields NAME,STATE 2>/dev/null | awk -F'|' -v v="$SUBJ" '$1==v{print $2}')
    [ "$st" = Halted ] && { log "FATAL: $SUBJ halted while waiting for qrexec - terminal, not a stall"; exit 1; }
    sleep 15
done
[ "$answered" = 1 ] || { log "FATAL: no qrexec answer within 300 s - nothing to measure"; exit 1; }
log "qrexec answered; the ONE call above is the only thing driving it. Settling ${SETTLE}s."
sleep "$SETTLE"
log "settle over; sweeping"

# ---- 3. the sweep ------------------------------------------------------------------------------
# NO QWT_VMLOCK_HELD OVERRIDE HERE. vm_lock exports it already, set to the VM NAME, and the
# pass-through compares it to the vm being locked (vmlock.sh:106) - so setting it to 1 breaks the
# very pass-through it looks like it is enabling. That is what made the first run of this harness
# sweep nothing: "REFUSING TO START: another harness already holds win11r-logvol", the holder being
# this script itself.
"$ROOT/mgmt/harness/log-sweep.sh" "$SUBJ" "$SINCE" "$OUT/sweep" >>"$OUT/sweep.log" 2>&1
sweeprc=$?
log "log-sweep rc=$sweeprc ($(command grep -ao 'LOGSWEEP-RESULT.*' "$OUT/sweep.log" | tail -1))"
REP=$(command grep -ao 'report=[^ ]*' "$OUT/sweep.log" | tail -1 | cut -d= -f2)
[ -n "$REP" ] && [ -f "$REP" ] || { log "FATAL: the sweep produced no report - nothing to read"; exit 1; }

# ---- 4. the verdict ----------------------------------------------------------------------------
python3 - "$REP" "$OUT" <<'PY' | tee -a "$OUT/run.log"
import json, sys
rep, out = sys.argv[1], sys.argv[2]
r = json.load(open(rep))
m = r.get("metrics", {})
und = m.get("error_lines_undeclared")
print("BOOT NOISE  error_lines=%s  undeclared=%s  warning_lines=%s  boots=%s" % (
    m.get("error_lines"), und, m.get("warning_lines"), m.get("boots")))
sigs = [s for s in (r.get("new") or []) + (r.get("out_of_context") or []) if s.get("level") == "E"]
if sigs:
    print("\nEVERY ERROR SIGNATURE THIS BOOT WROTE (%d):" % len(sigs))
    for s in sorted(sigs, key=lambda s: -int(s.get("count", 0))):
        j = s.get("jev") or {}
        print("  x%-4s %-10s %s%s" % (s.get("count"), s.get("family"), (s.get("key") or "")[:104],
              ("   Jev: %s %.2f" % (j.get("choice"), j.get("confidence"))) if j else ""))
else:
    print("\nno error signatures at all this boot")
ok = (und == 0)
print()
print("BOOTNOISE-RESULT %s undeclared=%s" % ("PASS" if ok else "FAIL", und))
open(out + "/verdict.txt", "w").write(("PASS" if ok else "FAIL") + " undeclared=%s\n" % und)
sys.exit(0 if ok else 1)
PY
vrc=$?
log "verdict rc=$vrc"
exit "$vrc"
