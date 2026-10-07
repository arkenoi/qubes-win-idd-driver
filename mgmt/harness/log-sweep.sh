#!/bin/bash
# log-sweep.sh - the PROACTIVE LOG SWEEP as a post-step any harness can call after a run.
#
#   mgmt/harness/log-sweep.sh <vm> <since-utc> <outdir> [--fault-injection] [--marker FILE]...
#       <vm>         the guest (TAGGED win-idd-testbed; this is also QTEST_VM for every call - no default target)
#       <since-utc>  logs modified / events recorded since this instant, as 2026-10-07T08:00:00Z (a harness passes
#                    the time it started the run)
#       <outdir>     where pull.txt, logs/, report.json and summary.txt land (created)
#       --fault-injection   DECLARES the run a fault-injection one (logs/context.json). The analyzer then applies the
#                    M8 rule set (an injected hang the agent did not detect is a breach) - but a declaration excuses
#                    nothing: a broker hang/death is excused only by evidence (QGAFAULT-INIT in its agent log, or an
#                    M8 record joining it by pid and time), and a declared run with no such evidence is itself a
#                    breach (fi_context_unproven: the test build / injection was not running).
#       --marker FILE       a harness-captured file carrying injection records (the `M8|name=...|pid=...|suspend=...|t=...`
#                    lines m8-suspend.ps1 prints); copied into logs/markers/ so the analyzer can join them.
#
# WHY. Owner, 2026-10-07: "could you look for such abnormalities in logs IN ADVANCE, not waiting for crashes they
# cause?" For days the GUI watchdog logged an agent death (0x40010004) and a relaunch into the ending session on
# EVERY shutdown, and a requested stop ended with a stale ERROR code, and nothing read it. This step reads the
# guest's logs after a run, normalizes them against the tracked baseline (mgmt/harness/log-sweep-baseline.json),
# computes the structural metrics (instances per shutdown, deaths at shutdown, errors during a requested stop, ...),
# and sends every NEW signature / count rise / metric breach to Jev in one call. tools/log-sweep.py is the analyzer;
# mgmt/harness/log-sweep-collect.ps1 the guest-side collector.
#
# RULES IT KEEPS (the harness conventions):
#   * the per-guest lock (mgmt/harness/vmlock.sh) - re-entrant, so a harness already holding it passes straight
#     through; a sweep must never run under another job's reboot;
#   * run-lib.sh job lifecycle (teardown of the process tree, lock release on any exit);
#   * every guest call is BOUNDED (_q from the e2e lib: timeout, rc in QRC, stderr in QERR);
#   * MISSING DATA FAILS: a guest that is not running, a pull that never verifies (counts/sha), a log the collector
#     could not read, an unparseable log - all exit non-zero with a line that says which; nothing is skipped silently;
#   * read-only on the guest: the collector reads logs and event records, it changes nothing.
#
# EXIT CODES (the analyzer's, passed through): 0 CLEAN, 1 FINDINGS (a breach or a Jev-classified defect),
# 3 DATA (missing/empty/partial/unparseable log, pull never verified, guest not running), 4 INCOMPLETE (the judge
# did not run - jev.py exit 2). 2 = usage. The last line is always LOGSWEEP-RESULT vm=... rc=... status=... report=...
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2

VM="${1:-}"; SINCE="${2:-}"; OUT="${3:-}"
if [ -z "$VM" ] || [ -z "$SINCE" ] || [ -z "$OUT" ]; then
  echo "usage: $0 <vm> <since-utc e.g. 2026-10-07T08:00:00Z> <outdir> [--fault-injection] [--marker FILE]..." >&2; exit 2
fi
shift 3
FI_DECLARED=""; MARKERS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --fault-injection) FI_DECLARED=1 ;;
    --marker) [ -n "${2:-}" ] && [ -f "$2" ] || { echo "FAIL  --marker needs an existing file (got '${2:-}')" >&2; exit 2; }; MARKERS+=("$2"); shift ;;
    *) echo "FAIL  unknown option '$1'" >&2; exit 2 ;;
  esac
  shift
done
if ! printf '%s' "$SINCE" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'; then
  echo "FAIL  since-utc must be yyyy-mm-ddThh:mm:ssZ (got '$SINCE') - it travels as a single qrexec argument" >&2; exit 2
fi
date -u -d "$SINCE" +%s >/dev/null 2>&1 || { echo "FAIL  since-utc '$SINCE' is not a valid instant" >&2; exit 2; }
mkdir -p "$OUT" || exit 2
R="$OUT/sweep.log"; : > "$R"
log(){ echo "[$(date -u +%H:%M:%S)] log-sweep[$VM]: $*" | tee -a "$R"; }
result(){ # $1=rc $2=status $3...=message; the one line every caller greps
  local rc=$1 st=$2; shift 2
  log "$*"
  echo "LOGSWEEP-RESULT vm=$VM rc=$rc status=$st report=$OUT/report.json summary=$OUT/summary.txt" | tee -a "$R"
  exit "$rc"
}

export QTEST_VM="$VM"
source mgmt/harness/vmlock.sh; vm_lock "$VM"
source mgmt/harness/run-lib.sh; job_init log-sweep
source .claude/skills/win-guest-e2e/e2e-lib.sh      # _q: bounded call, rc in QRC, stderr in QERR

BASELINE="${LOGSWEEP_BASELINE:-mgmt/harness/log-sweep-baseline.json}"
[ -f "$BASELINE" ] || result 3 DATA "FAIL  baseline $BASELINE is missing - nothing to compare against"
log "=== log sweep: vm=$VM since=$SINCE out=$OUT baseline=$BASELINE ==="

# 1. the guest must be up - a sweep of a halted guest has nothing to read, and saying "clean" would be a lie
st=$(_q 25 ./tools/qtest state | grep -aoE 'power_state=[A-Za-z]+' | head -1)
[ "$st" = "power_state=Running" ] || result 3 DATA "FAIL  guest $VM is not Running (state '${st:-no answer}', rc=$QRC) - nothing collected"

# 2. pull (two attempts: a transfer that does not verify is retried once, then FAILS)
verified=""
for attempt in 1 2; do
  _q 600 ./tools/qtest pushrun mgmt/harness/log-sweep-collect.ps1 -SinceUtc "$SINCE" > "$OUT/pull.txt"
  rc=$QRC
  if ! grep -aq '^LSW END ' "$OUT/pull.txt"; then
    log "pull attempt $attempt: no END line (qtest rc=$rc, $(grep -ac '^LSW ' "$OUT/pull.txt") LSW lines; stderr: $(tr '\n' ' ' < "$QERR" | cut -c1-200))"
    continue
  fi
  rm -rf "$OUT/logs"; mkdir -p "$OUT/logs"
  if python3 tools/log-sweep.py decode "$OUT/pull.txt" --out "$OUT/logs" > "$OUT/decode.txt" 2>&1; then verified=1; break; fi
  log "pull attempt $attempt did not verify: $(grep -a 'DECODE' "$OUT/decode.txt" | grep -av ': OK' | head -3 | tr '\n' ';' | cut -c1-300)"
done
[ -n "$verified" ] || result 3 DATA "FAIL  the log pull never verified (counts/sha) - no evidence to sweep ($OUT/decode.txt)"
log "pulled: $(grep -ac ': OK' "$OUT/decode.txt") blocks verified; $(grep -a '^DECODE FILEERR' "$OUT/decode.txt" | wc -l) read errors"

# 2b. the context the caller declares, and the injection records it captured (evidence lives in the files, never in names)
if [ -n "$FI_DECLARED" ]; then
  printf '{"fault_injection_declared": true, "source": "log-sweep.sh --fault-injection (caller: %s)"}\n' "${0##*/}" > "$OUT/logs/context.json"
  log "context: declared fault-injection (excuses nothing by itself; evidence decides)"
fi
if [ ${#MARKERS[@]} -gt 0 ]; then
  mkdir -p "$OUT/logs/markers"
  for mf in "${MARKERS[@]}"; do cp -- "$mf" "$OUT/logs/markers/$(basename "$mf")"; done
  log "markers: ${#MARKERS[@]} file(s) copied into logs/markers ($(cat -- "${MARKERS[@]}" | grep -ac '^M8|') M8 record lines)"
fi

# 3. analyze (the analyzer calls Jev once per run; its rc is the verdict)
python3 tools/log-sweep.py analyze "$OUT/logs" --baseline "$BASELINE" --out "$OUT/report.json" --summary "$OUT/summary.txt" \
  --since "$SINCE" --label "$VM" > "$OUT/analyze.out" 2>&1
arc=$?
cat "$OUT/summary.txt" 2>/dev/null | tee -a "$R"
case $arc in
  0) result 0 CLEAN "PASS  no breach, no new defect, no missing data" ;;
  1) result 1 FINDINGS "FAIL  findings: $(grep -aE '^(BREACHES|NEW SIGNATURES)' "$OUT/summary.txt" | tr '\n' ' ' | cut -c1-200)" ;;
  3) result 3 DATA "FAIL  missing or unparseable data - the sweep is not complete: $(grep -aA1 '^DATA' "$OUT/summary.txt" | tail -1 | cut -c1-200)" ;;
  4) result 4 INCOMPLETE "FAIL  the judge did not run - items left unjudged: $(grep -a '^JEV' "$OUT/summary.txt" | cut -c1-200)" ;;
  *) result 3 DATA "FAIL  analyzer exited $arc: $(tail -3 "$OUT/analyze.out" | tr '\n' ' ' | cut -c1-300)" ;;
esac
