#!/bin/bash
# GATE REMAINDER - the six suites tools/release-acceptance.sh does not cover, and the receipt merge
# that makes a FULL gate reachable at all.
#
# WHY THIS EXISTS, MEASURED 2026-10-08. `tools/release-acceptance.sh` writes
# scratchpad/gate-coverage-<head>.json naming package-verify, its cells, and the three feature tests
# - twelve suites. `tools/gate-scope.py required` asks for EIGHTEEN whenever the diff touches an
# unmapped path, which is most releases. A twelve-suite receipt was fed to `gate-scope.py check` and
# refused, correctly, naming the six with no producer:
#     failproof-gates  failproof-faultinject  gate-preflight  p3a-etw-gate  toast-hold-test  log-sweep
# So the sanctioned path could not produce a receipt that satisfies its own floor. This runs those
# six and MERGES the ones that PASSED into the same receipt.
#
# IT DOES NOT CUT THE RELEASE and it never writes a suite it did not see pass: a receipt is a record,
# not an intention (docs/ADR-acceptance.md section 4).
#
# Usage:
#   tools/gate-remainder.sh --run <release-package-run-id> --vm10 <win10 subject>
#                           --vm11 <win11 subject> --os11 <label, golden is <label>-qwt>
#                           [--fi-run <qwt-full-fault-injection-run>] [--dry]
#
# The three targets are REQUIRED - there are no default targets here (lint L10).
#
# --dry resolves every variable and prints every command without touching a guest. Run it first.
. "$(dirname "$0")/../mgmt/harness/shutdown-lib.sh" 2>/dev/null || true
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2

RUN=""; FIRUN=""; DRY=0
# NO DEFAULT TARGETS (tools/lint-harness.py L10, and the rule that made matrix.sh refuse an unset
# B10): a default target is wrong in almost every run, and a harness that guesses one churns a
# guest the caller did not mean. Name them with --vm10/--vm11/--os11 or be refused below.
VM10=""; VM11=""; OS11=""
while [ $# -gt 0 ]; do
  case "$1" in
    --run)    RUN="${2:-}"; shift 2 ;;
    --fi-run) FIRUN="${2:-}"; shift 2 ;;
    --vm10)   VM10="${2:-}"; shift 2 ;;
    --vm11)   VM11="${2:-}"; shift 2 ;;
    --os11)   OS11="${2:-}"; shift 2 ;;
    --dry)    DRY=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$RUN" ]  || { echo "ERROR: --run <release-package-run-id> is required" >&2; exit 2; }
[ -n "$VM10" ] || { echo "ERROR: --vm10 <win10 subject> is required - there is no default target" >&2; exit 2; }
[ -n "$VM11" ] || { echo "ERROR: --vm11 <win11 subject> is required - there is no default target" >&2; exit 2; }
[ -n "$OS11" ] || { echo "ERROR: --os11 <label, the golden is <label>-qwt> is required - there is no default target" >&2; exit 2; }

HEAD=$(git rev-parse HEAD) || exit 2
HEAD12=$(printf '%s' "$HEAD" | cut -c1-12)
COVFILE="scratchpad/gate-coverage-$HEAD12.json"
OUTDIR="$HOME/qwt-accept/remainder-$HEAD12"
WORK="$OUTDIR/work"
DL="$OUTDIR/dl"
SETUP="$DL/qwt-improved-setup"
LOG="$OUTDIR/remainder.log"
# /tmp IS RAM ON THIS QUBE (1 GB tmpfs) - a full one gets a long run OOM-killed mid-suite.
export TMPDIR="${TMPDIR:-$HOME/tmp}"

say() { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*" | tee -a "$LOG"; }
run_it() {           # run_it <label> <cmd...>  - never `cmd | tee`, which reports TEE's status
  local label="$1"; shift
  if [ "$DRY" = 1 ]; then echo "INTEND[dry] $label: $*" | tee -a "$LOG"; return 0; fi
  say "--- $label"
  "$@" >>"$WORK/$label.out" 2>&1
  local rc=$?
  if [ "$rc" = 0 ]; then say "PASS  $label"; else say "FAIL  $label (exit $rc) - see $WORK/$label.out"; fi
  return $rc
}

mkdir -p "$OUTDIR" "$WORK" "$DL" || exit 2
say "=== gate remainder for run $RUN at HEAD $HEAD12 (dry=$DRY) ==="

# ---- what the diff actually requires, and which of it is still missing -------------------------
BASE=$(git describe --tags --abbrev=0 --match 'v4.3.*' 2>/dev/null || echo "")
[ -n "$BASE" ] || { say "ERROR: no v4.3.* tag to diff against"; exit 2; }
say "range: $BASE..$HEAD12"
REQ=$(python3 tools/gate-scope.py required "$BASE..$HEAD" 2>/dev/null \
        | sed -n 's/^    \([a-z0-9][a-z0-9-]*\) .*/\1/p' | sort -u)
[ -n "$REQ" ] || { say "ERROR: gate-scope named no suites - refusing to guess"; exit 2; }
say "gate-scope requires: $(echo $REQ | tr '\n' ' ')"

# ---- the artifacts the suites consume ----------------------------------------------------------
if [ "$DRY" = 1 ]; then
  say "INTEND[dry] download: gh run download $RUN -n qwt-improved-setup -D $SETUP"
else
  if [ ! -s "$SETUP/install.cmd" ]; then
    rm -rf "$SETUP"
    say "downloading qwt-improved-setup from run $RUN"
    gh run download "$RUN" -n qwt-improved-setup -D "$SETUP" >>"$LOG" 2>&1 \
      || { say "ERROR: could not download the setup tree"; exit 2; }
  fi
  [ -s "$SETUP/install.cmd" ] || { say "ERROR: $SETUP/install.cmd missing"; exit 2; }
fi

# ---- the suites, each named exactly as gate-scope names it --------------------------------------
# Only a suite that RAN and PASSED is recorded. A suite gate-scope does not require is skipped and
# is never recorded either.
PASSED=""; FAILED=""; SKIPPED=""
need() { echo "$REQ" | tr ' ' '\n' | grep -qx "$1"; }
note() { if [ "$1" = 0 ]; then PASSED="$PASSED $2"; else FAILED="$FAILED $2"; fi; }

# THE SWEEP'S WINDOW IS THIS RUN, NOT TWELVE HOURS OF HISTORY. This said '12 hours ago', which on a
# rig whose guests are reinstalled all day means a window covering OTHER RUNS, OLDER BUILDS and the
# install-era boots - and the sweep would report their lines as this run's findings. Measured
# 2026-10-09: an install-era boot writes early-boot vchan transients (XcStoreRead 0x5,
# libxenvchan_client_init ... ring-ref 0x5, at ~21 s uptime, upstream code, resolved on retry) that a
# normal boot of a provisioned guest does NOT write - zero error lines on two swept guests - so a
# window that reaches back into an install carries them and a window over this run does not. The
# suites below all run after this point, and log-sweep runs last on purpose, so this is the right
# start for it.
SINCE=$(date -u +%Y-%m-%dT%H:%M:%SZ)

if need gate-preflight; then
  # <vm> <hex-bits>: the preflight bit-mask the suite documents; 0 exercises the no-fault path.
  run_it gate-preflight bash mgmt/harness/gate-preflight.sh "$VM11" 0; note $? gate-preflight
else SKIPPED="$SKIPPED gate-preflight"; fi

if need failproof-gates; then
  run_it failproof-gates bash mgmt/harness/failproof-gates.sh "$VM11" "$WORK/failproof-gates"
  note $? failproof-gates
else SKIPPED="$SKIPPED failproof-gates"; fi

if need failproof-faultinject; then
  # THE FAULT-INJECTION SUITE NEEDS A FAULT-INJECTION BUILD. qwt-full only compiles the injector
  # when dispatched with -f fault_injection=true; against an ordinary package the suite cannot fire
  # a fault and reports a vacuous pass (memory: a "regression" on rz24 was exactly this).
  if [ -z "$FIRUN" ]; then
    say "SKIP  failproof-faultinject: no --fi-run given, and an ordinary package cannot inject a"
    say "      fault - recording it would be a vacuous pass. Dispatch qwt-full with"
    say "      -f fault_injection=true and pass its run id."
    SKIPPED="$SKIPPED failproof-faultinject"
  else
    FIDIR="$DL/qwt-fault-package"
    if [ "$DRY" = 1 ]; then
      say "INTEND[dry] download: gh run download $FIRUN -D $FIDIR"
    elif [ ! -d "$FIDIR" ]; then
      gh run download "$FIRUN" -D "$FIDIR" >>"$LOG" 2>&1 \
        || { say "ERROR: could not download the fault-injection package"; exit 2; }
    fi
    FI_DIR="$FIDIR" run_it failproof-faultinject \
      bash mgmt/harness/failproof-faultinject.sh "$VM11" "$WORK/failproof-faultinject"
    note $? failproof-faultinject
  fi
else SKIPPED="$SKIPPED failproof-faultinject"; fi

if need p3a-etw-gate; then
  run_it p3a-etw-gate bash mgmt/harness/p3a-etw-gate.sh "$SETUP" "${OS11}-p3a" "${OS11}-qwt"
  note $? p3a-etw-gate
else SKIPPED="$SKIPPED p3a-etw-gate"; fi

if need toast-hold-test; then
  run_it toast-hold-test bash mgmt/harness/toast-hold-test.sh --run "$RUN" --os "$OS11"
  note $? toast-hold-test
else SKIPPED="$SKIPPED toast-hold-test"; fi

if need log-sweep; then
  # LAST, deliberately: it reads what every suite above wrote into the guest's logs.
  run_it log-sweep bash mgmt/harness/log-sweep.sh "$VM11" "$SINCE" "$WORK/log-sweep"
  note $? log-sweep
else SKIPPED="$SKIPPED log-sweep"; fi

say "passed:$PASSED"
say "failed:$FAILED"
say "skipped:$SKIPPED"

# ---- merge into the receipt the release-cut gate reads -----------------------------------------
# Only PASSED suites are added, and an existing receipt is never shrunk: this is a merge, so the
# cells recorded by release-acceptance.sh survive.
if [ "$DRY" = 1 ]; then
  say "INTEND[dry] merge into $COVFILE:$PASSED"
else
  python3 - "$COVFILE" "$RUN" "$HEAD12" "$PASSED" <<'PYMERGE'
import json, os, sys
out, run, head, passed = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4].split()
rec = {}
if os.path.exists(out):
    try:
        rec = json.load(open(out, encoding="utf-8"))
    except ValueError:
        rec = {}
suites = sorted(set(rec.get("suites") or []) | set(passed))
rec["suites"] = suites
rec.setdefault("package_run", run)
rec.setdefault("built_from", head)
rec["note"] = ("merged by tools/gate-remainder.sh; names only suites seen to pass. "
               + (rec.get("note") or ""))[:400]
json.dump(rec, open(out, "w"), indent=1)
print("receipt now names %d suite(s): %s" % (len(suites), " ".join(suites)))
PYMERGE
  say "--- does the receipt now satisfy the gate?"
  python3 tools/gate-scope.py check "$COVFILE" "$BASE..$HEAD" 2>&1 | tee -a "$LOG"
  CHK=${PIPESTATUS[0]}
  if [ "$CHK" = 0 ]; then say "GATE SATISFIED for $HEAD12"; else say "GATE NOT YET SATISFIED (exit $CHK)"; fi
fi

[ -z "$FAILED" ] || exit 1
exit 0
