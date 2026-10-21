#!/bin/bash
# collect-failure.sh - THE FAILURE PACKAGE THAT ALWAYS EXISTS on any non-PASS exit (PLAN-acceptance-
# optimization section 4). A harness calls it; it never decides anything about the product.
#
#   mgmt/harness/collect-failure.sh <vm> <outdir> <reason> [options]
#       <vm>        the guest (TAGGED win-idd-testbed; also QTEST_VM for every call - no default target)
#       <outdir>    where the package lands - OUTSIDE the tracked tree (scratchpad/, evidence/, $HOME/...)
#       <reason>    the harness's one-line reason for the non-PASS exit (goes into the manifest verbatim)
#       --since <utc>            the run's start (yyyy-mm-ddThh:mm:ssZ) for the log sweep; default: 3 h ago, SAID SO
#       --logvol <img>|none      the secondary log volume image (mgmt/harness/logvol-lib.sh); 'none' DECLARES
#                                the cell ran without one (recorded, not a gap); absent = a gap
#       --logvol-manifest <json> the campaign manifest logvol_attach wrote; the vm's entry names the image
#       --harness-cmd "<cmd>"    the exact harness command (default: the parent process's command line)
#       --harness-log <file>     the harness's own log; its tail travels in the package
#       --timeline <file>        'utc state source' lines the harness recorded (power-state readings)
#       --no-core                never fetch a memory image (default: fetch on a classified wedge)
# #       --no-sweep               do not run the live log sweep (the offline analysis of the volume still runs)
#       --unresponsive-secs <n>  how long one liveness probe may take before the guest counts as unresponsive (40)
#
# ORDER, AND WHY: (1) the secondary volume FIRST, read on the host with mtools while the guest is in
# whatever state it is in - nothing is asked of the guest and nothing is paused or detached, so a wedged
# specimen is read WHILE STILL WEDGED; (2) one bounded liveness probe; (3) alive -> the live log sweep
# (mgmt/harness/log-sweep.sh) and a per-window screen capture; unresponsive -> the wedge is CLASSIFIED
# (mgmt/harness/wedge-lib.sh, the dom0 forensics service) and, for SPIN/BLOCKED, the memory image is
# fetched (mgmt/harness/fetch-wedge-core.sh, which PAUSES the guest for the write and REFUSES on space -
# a refusal is recorded as the instrument-fail it is, and the specimen is left alive for it); Halted ->
# the volume's copy is analysed OFFLINE by the same analyzer (tools/log-sweep.py, corpus mode);
# (4) activity-snapshot.json (tools/activity-snapshot.py); (5) the tarball, VERIFIED, and only then
# (6) manifest.json. THE MANIFEST IS WRITTEN LAST: a run is not marked collected until it exists, so it
# must not exist before the package it describes is verified.
#
# THE SPECIMEN STAYS ALIVE. Nothing here shuts down, kills, restarts or detaches anything. Memory images
# (*.core) are referenced by the manifest and kept beside the package, never put in the tarball.
#
# EXIT CODES: 0 the package is COMPLETE; 1 the package was written WITH GAPS (each named in manifest.json
# gaps[] and in the COLLECT-RESULT line) - a gap is a missing source or a snapshot field that could not be
# filled, and it is never skipped silently; 2 nothing was written (usage, outdir refused, lock refused).
# The last line is always:  COLLECT-RESULT vm=<vm> rc=<n> complete=<0|1> manifest=<path> gaps=<n>
#
# Test overrides (tools/tests/collect-failure-selftest.sh drives every branch with stubs and the defect
# knobs): QTEST_BIN, LOGSWEEP_BIN, WEDGE_CORE_BIN, CF_JEV_CMD (the offline analyzer's judge), PATH shims for
# qrexec-client-vm (the forensics service). Each `# GUARD:<knob> DEFECT:` line is a check seen to fail.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT" || exit 2

VM="${1:-}"; OUT="${2:-}"; REASON="${3:-}"
if [ -z "$VM" ] || [ -z "$OUT" ] || [ -z "$REASON" ]; then
  sed -n '4,24p' "$0" >&2; exit 2
fi
shift 3
SINCE=""; SINCE_SOURCE=""; LOGVOL_IMG="${LOGVOL_IMG:-}"; LOGVOL_MF=""; HARNESS_CMD_ARG=""; HARNESS_LOG=""; TIMELINE_IN=""
NO_CORE=0; NO_SWEEP=0; NO_QREXEC=0; UNRESP="${CF_UNRESPONSIVE_SECS:-40}"
while [ $# -gt 0 ]; do
  case "$1" in
    --since) SINCE="${2:?--since needs <utc>}"; SINCE_SOURCE="argument"; shift ;;
    --logvol) LOGVOL_IMG="${2:?--logvol needs <img>|none}"; shift ;;
    --logvol-manifest) LOGVOL_MF="${2:?--logvol-manifest needs <json>}"; shift ;;
    --harness-cmd) HARNESS_CMD_ARG="${2:?--harness-cmd needs a string}"; shift ;;
    --harness-log) HARNESS_LOG="${2:?--harness-log needs <file>}"; shift ;;
    --timeline) TIMELINE_IN="${2:?--timeline needs <file>}"; shift ;;
    --no-core) NO_CORE=1 ;;
    --no-qrexec) NO_QREXEC=1 ;;
    --no-sweep) NO_SWEEP=1 ;;
    --unresponsive-secs) UNRESP="${2:?--unresponsive-secs needs <n>}"; shift ;;
    *) echo "collect-failure: unknown option '$1'" >&2; exit 2 ;;
  esac
  shift
done
# THE PACKAGE NEVER LANDS ON A TRACKED PATH (the repo is public; captures and raw run output stay in
# scratchpad/ or an evidence dir).
OUTABS=$(python3 -c 'import os,sys; print(os.path.abspath(sys.argv[1]))' "$OUT")
case "$OUTABS" in
  "$ROOT"/scratchpad/*|"$ROOT"/evidence/*) ;;
  "$ROOT"/*) echo "collect-failure: REFUSED - $OUT is inside the tracked tree; use scratchpad/, evidence/ or a path outside the repo" >&2; exit 2 ;;
esac
mkdir -p "$OUTABS" || exit 2
OUT="$OUTABS"
LOGF="$OUT/collect.log"; : > "$LOGF"
log(){ echo "[$(date -u +%H:%M:%S)] collect-failure[$VM]: $*" | tee -a "$LOGF"; }
GAPS=()
gap(){ GAPS+=("$1"); log "GAP  $1"; }   # GUARD:gaprecord DEFECT: gap(){ log "GAP  $1"; }
if [ -z "$SINCE" ]; then SINCE=$(date -u -d '-3 hours' +%Y-%m-%dT%H:%M:%SZ); SINCE_SOURCE="default-3h"; fi
printf '%s' "$SINCE" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' || { echo "collect-failure: --since must be yyyy-mm-ddThh:mm:ssZ (got '$SINCE')" >&2; exit 2; }

export QTEST_VM="$VM"
QTEST="${QTEST_BIN:-./tools/qtest}"
LOGSWEEP="${LOGSWEEP_BIN:-mgmt/harness/log-sweep.sh}"
WEDGE_CORE="${WEDGE_CORE_BIN:-mgmt/harness/fetch-wedge-core.sh}"
BASELINE="${LOGSWEEP_BASELINE:-mgmt/harness/log-sweep-baseline.json}"
# ONE VM-MUTATING JOB AT A TIME (re-entrant: a harness that already holds this guest's lock passes
# straight through; standalone, the collector must not read under another job's reboot).
source mgmt/harness/vmlock.sh; vm_lock "$VM" || exit 2
source mgmt/harness/run-lib.sh; job_init collect-failure
source mgmt/harness/wedge-lib.sh
source mgmt/harness/logvol-lib.sh
source mgmt/harness/e2e-wait.sh          # w_screen: the ONE sanctioned per-window capture (guest-capture skill)
q(){ local to="$1"; shift; timeout -k 8 "$to" "$QTEST" "$@" 2>>"$OUT/qtest.err"; }

log "=== failure package: vm=$VM reason='$REASON' out=$OUT since=$SINCE ($SINCE_SOURCE) ==="
T0=$(date +%s)

# ---- 0. the context: the exact harness command, its log, the power-state readings it recorded -------
HARNESS_CMD_FROM_ENV="${HARNESS_CMD:-}"            # read BEFORE the variable is reused below
HARNESS_CMD="$HARNESS_CMD_ARG"; HARNESS_CMD_SOURCE="argument"
if [ -z "$HARNESS_CMD" ] && [ -n "$HARNESS_CMD_FROM_ENV" ]; then HARNESS_CMD="$HARNESS_CMD_FROM_ENV"; HARNESS_CMD_SOURCE="environment"; fi
if [ -z "$HARNESS_CMD" ]; then
  HARNESS_CMD=$(tr '\0' ' ' < "/proc/$PPID/cmdline" 2>/dev/null | sed 's/ $//'); HARNESS_CMD_SOURCE="parent process $PPID"
fi
[ -n "$HARNESS_CMD" ] || { HARNESS_CMD_SOURCE="none"; gap "harness command unknown (no --harness-cmd, no HARNESS_CMD, parent cmdline unreadable)"; }
log "harness command ($HARNESS_CMD_SOURCE): $(printf '%s' "$HARNESS_CMD" | cut -c1-200)"
if [ -n "$HARNESS_LOG" ]; then
  if [ -f "$HARNESS_LOG" ]; then tail -n 300 "$HARNESS_LOG" > "$OUT/harness-log-tail.txt"; log "harness log tail: $(wc -l < "$OUT/harness-log-tail.txt") line(s) from $HARNESS_LOG"
  else gap "harness log $HARNESS_LOG does not exist"; fi
fi
TIMELINE="$OUT/timeline.txt"; : > "$TIMELINE"
[ -n "$TIMELINE_IN" ] && [ -f "$TIMELINE_IN" ] && cat "$TIMELINE_IN" >> "$TIMELINE"
git -C "$ROOT" rev-parse HEAD > "$OUT/repo-head.txt" 2>/dev/null || true

# ---- 1. power state - one bounded read, recorded with the instant it was taken ------------------------
STATE_RAW=$(q 25 state)
POWER=$(printf '%s' "$STATE_RAW" | grep -aoE 'power_state=[A-Za-z]+' | head -1 | cut -d= -f2)
[ -n "$POWER" ] || { POWER="unreadable"; gap "power state unreadable (qtest state answered: $(printf '%s' "$STATE_RAW" | tr -d '\0\r' | cut -c1-80))"; }
printf '%s %s qtest-state\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$POWER" >> "$TIMELINE"
log "power state: $POWER"

# ---- 2. THE SECONDARY VOLUME FIRST - host-side, nothing asked of the guest ----------------------------
LOGVOL_STATUS="absent"; LOGVOL_FILES=0; LOGVOL_SALVAGE=0; LOGVOL_DIR_COPY=""
if [ -z "$LOGVOL_IMG" ] && [ -n "$LOGVOL_MF" ]; then LOGVOL_IMG=$(logvol_manifest_lookup "$LOGVOL_MF" "$VM" image); fi
if [ "$LOGVOL_IMG" = none ]; then
  LOGVOL_STATUS="declared-none"; log "secondary volume: the caller declares this cell ran WITHOUT one"
elif [ -n "$LOGVOL_IMG" ]; then
  if logvol_pull "$LOGVOL_IMG" "$OUT/logvol" >>"$LOGF" 2>&1; then
    LOGVOL_STATUS="pulled"; LOGVOL_FILES=$(find "$OUT/logvol/files" -type f | wc -l)
    LOGVOL_DIR_COPY="$OUT/logvol/files"; [ -d "$OUT/logvol/files/qwt-logs" ] && LOGVOL_DIR_COPY="$OUT/logvol/files/qwt-logs"
    log "secondary volume: $LOGVOL_FILES file(s) read from $LOGVOL_IMG (host-side, guest untouched)"
  else
    LOGVOL_STATUS="unreadable"; gap "secondary volume $LOGVOL_IMG could not be read (see collect.log)"
  fi
  if logvol_salvage "$LOGVOL_IMG" "$OUT/logvol" >>"$LOGF" 2>&1; then
    LOGVOL_SALVAGE=$(wc -l < "$OUT/logvol/salvage.txt"); log "secondary volume: raw-image salvage found $LOGVOL_SALVAGE log-shaped line(s)"
  fi
else
  gap "secondary volume: none named (no --logvol, no manifest entry) - the plan's primary log source is absent"   # GUARD:logvolgap DEFECT: log "secondary volume: none named"
fi

# ---- 3. liveness, then the branch the state dictates ------------------------------------------------
LIVENESS="not-running"; SWEEP_RC=""; SWEEP_STATUS=""; SWEEP_DIR=""; SCREEN=""; WEDGE_CLASS=""; CORE_STATUS="not-attempted"; CORE_PATH=""
if [ "$POWER" = Running ]; then
  # A GUEST THAT NEVER HAD QREXEC IS NOT WEDGED BY BEING SILENT. A pristine base carries no QWT -
  # that is what makes it pristine - so it can never answer, and its silence says nothing about its
  # health. Measured 2026-10-13: a base build failed on a HARNESS bug (a shell function that was not
  # sourced), the guest was perfectly healthy, and this read its silence as a wedge and wrote an
  # 8.1 GB memory core of it, filling /home to 97%.
  #
  # The CALLER declares it, the way --logvol none declares a cell that ran without a log volume. The
  # caller always knows: reprovision-usb.sh knows it is building a QWT-free base, quick-upgrade.sh
  # and matrix.sh know their subject carries QWT. Inferring it from the qrexec FEATURE instead was
  # judged the wrong discriminator (Jev 0.27 vs 0.87 for a declaration): the feature is harness-set
  # state, so a genuinely wedged guest whose feature was never set would be silently skipped - a real
  # wedge going unclassified with no core is a worse failure than the one being fixed.
  #
  # The probe is skipped entirely rather than run and ignored: it can only ever fail here, and a
  # 40-second wait for an answer that cannot come is not a measurement.
  if [ "$NO_QREXEC" = 1 ]; then                                     # GUARD:declqwtfree DEFECT: if false; then
    LIVENESS="no-qrexec-by-design"
    log "liveness: not probed - the caller declares this guest carries no QWT, so silence is expected"
  else
    # CAPTURE, THEN MATCH - never `q ... | grep -q`. MEASURED 2026-10-14, 200 probes of a HEALTHY
    # producer: 86 of them read "unresponsive". `grep -q` exits the instant it matches, which SIGPIPEs
    # the still-writing left side, `timeout` reports that death as 141, and `set -o pipefail` (line 43)
    # makes 141 the status of the whole pipeline - so a guest that answered correctly is graded dead
    # about two times in five, and the collector then classifies a wedge and fetches a multi-GB memory
    # image of a healthy guest. The same command alone returns 0 every time; capture-then-match was
    # 200/200. The pipeline statuses seen were exactly {0, 141}.
    PROBE=$(q "$UNRESP" run 'cmd /c echo QREADY')
    # ANCHOR THE MARKER. qubes.VMShell returns cmd's banner AND THE ECHOED COMMAND LINE, so
    # `*QREADY*` matched the `echo QREADY` in the request it had just sent: a guest that answered
    # nothing at all was graded alive, and this is the discriminator that decides QREXECDEAD
    # vs "the subject would not halt". Only a line that IS the marker counts. Same fix as
    # tools/qtest made for QTINCOK on 2026-10-09.
    if command grep -qa '^QREADY' <<< "$PROBE"; then LIVENESS="alive"; else LIVENESS="unresponsive"; fi   # GUARD:unresponsive DEFECT: LIVENESS="alive"
    # BACKSTOP for a caller that forgot the flag. It does not silently do the right thing: it refuses
    # the expensive step AND records a gap, so the run is incomplete (rc=1) and the caller gets fixed.
    # Loud, diagnosed, never quietly recovered from.
    if [ "$LIVENESS" = unresponsive ] && [ -z "$(qvm-features "$VM" qrexec 2>/dev/null)" ]; then   # GUARD:qwtfreebackstop DEFECT: if false; then
      LIVENESS="no-qrexec-undeclared"
      gap "$VM has no qrexec feature and the caller did not pass --no-qrexec: its silence cannot be read as a wedge, so nothing was classified and no memory image was taken. Fix the caller."
    fi
    log "liveness: $LIVENESS (one probe, bound ${UNRESP}s)"
  fi
fi
printf '%s %s liveness\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$LIVENESS" >> "$TIMELINE"

if [ "$LIVENESS" = alive ]; then
  if [ "$NO_SWEEP" = 0 ]; then
    SWEEP_DIR="$OUT/sweep"
    timeout -k 30 1800 "$LOGSWEEP" "$VM" "$SINCE" "$SWEEP_DIR" >"$OUT/sweep.out" 2>&1; SWEEP_RC=$?
    SWEEP_STATUS=$(grep -ao 'LOGSWEEP-RESULT.*' "$OUT/sweep.out" | tail -1 | grep -ao 'status=[A-Z]*' | cut -d= -f2)
    log "live log sweep: rc=$SWEEP_RC status=${SWEEP_STATUS:-none} ($SWEEP_DIR)"
    case "$SWEEP_RC" in
      0|1) ;;   # CLEAN or FINDINGS: the data is complete; the verdict is the wrapper's business
      *) gap "live log sweep did not complete (rc=$SWEEP_RC status=${SWEEP_STATUS:-none}) - instrument, not product" ;;
    esac
  else
    log "live log sweep skipped by --no-sweep"
  fi
  SCREEN=$(w_screen "$VM" screen "$OUT")
  log "screen (per-window capture): $SCREEN"
elif [ "$LIVENESS" = unresponsive ]; then
  # The wedge is CLASSIFIED before anything is decided, and the classification is itself the capture.
  WEDGE_CLASS=$(wedge_classify "$VM" "$OUT/wedge" 2>>"$LOGF"); wrc=$?
  log "wedge: $WEDGE_CLASS (rc=$wrc; artefacts in $OUT/wedge)"
  case "$WEDGE_CLASS" in
    SPIN*|BLOCKED*)
      if [ "$NO_CORE" = 1 ]; then CORE_STATUS="skipped-by-caller"; log "memory image skipped (--no-core)"
      else
        CORE_PATH="$OUT/wedge/$VM.core"
        timeout -k 60 4000 "$WEDGE_CORE" "$VM" "$CORE_PATH" >"$OUT/wedge/core.out" 2>&1; crc=$?
        if [ $crc -eq 0 ] && [ -s "$CORE_PATH" ]; then CORE_STATUS="fetched"; log "memory image: $CORE_PATH ($(stat -c%s "$CORE_PATH") bytes) - kept beside the package, not in the tarball"
        elif grep -qa 'REFUSED: not enough free space' "$OUT/wedge/core.out"; then
          CORE_STATUS="refused-space"; gap "memory image REFUSED for space (instrument-fail) - $(grep -ao 'SHORT BY [0-9]* MiB' "$OUT/wedge/core.out" | head -1); THE SPECIMEN STAYS ALIVE until this is resolved (fetch-wedge-core.sh names what to free)"
        else
          CORE_STATUS="failed"; gap "memory image not taken (fetch rc=$crc: $(tail -1 "$OUT/wedge/core.out" 2>/dev/null | cut -c1-160)) - THE SPECIMEN STAYS ALIVE"
        fi
      fi ;;
    *) gap "wedge forensics UNREADABLE (the dom0 service answered nothing usable) - the guest is unresponsive and unclassified; instrument-fail" ;;
  esac
  SCREEN=$(w_screen "$VM" screen "$OUT")
  log "screen (per-window capture): $SCREEN"
elif [ "$LIVENESS" = no-qrexec-by-design ] || [ "$LIVENESS" = no-qrexec-undeclared ]; then
  # Nothing can be asked of this guest, so nothing is asked: no live sweep (it needs qrexec), no wedge
  # classification, no memory image. The per-window capture is a DOM0 service that needs nothing from
  # the guest, so it still runs - on a QWT-free guest it is the only instrument there is. On 2026-10-13
  # the answer-file dialog that stalled a base build sat on screen for 90 minutes while nothing looked.
  SCREEN=$(w_screen "$VM" screen "$OUT")                            # GUARD:qwtfreescreen DEFECT: SCREEN=""
  CORE_STATUS="skipped-no-qrexec"
  log "screen (per-window capture): $SCREEN - dom0-side, the only instrument that needs nothing from the guest"
else
  log "guest is $POWER - no live sweep, no capture; the secondary volume is the source"
fi

# ---- 3b. OFFLINE analysis of the volume's copy - the same analyzer, corpus mode, no guest needed ------
OFFLINE_RC=""; OFFLINE_STATUS=""
if [ -n "$LOGVOL_DIR_COPY" ] && [ "$LOGVOL_FILES" -gt 0 ]; then
  mkdir -p "$OUT/sweep-offline"
  jevopt=()
  [ -n "${CF_JEV_CMD:-}" ] && jevopt=(--jev-cmd "$CF_JEV_CMD")
  python3 tools/log-sweep.py analyze "$LOGVOL_DIR_COPY" --baseline "$BASELINE" --out "$OUT/sweep-offline/report.json" \
      --summary "$OUT/sweep-offline/summary.txt" --label "$VM-logvol" --workdir "$OUT/sweep-offline/work" "${jevopt[@]}" \
      > "$OUT/sweep-offline/analyze.out" 2>&1; OFFLINE_RC=$?
  if python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$OUT/sweep-offline/report.json" >/dev/null 2>&1; then
    OFFLINE_STATUS=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('status',''))" "$OUT/sweep-offline/report.json")
    log "offline analysis of the volume: rc=$OFFLINE_RC status=$OFFLINE_STATUS ($OUT/sweep-offline/report.json)"
    case "$OFFLINE_RC" in 0|1) ;; *) gap "offline analysis of the volume did not complete (rc=$OFFLINE_RC status=$OFFLINE_STATUS)" ;; esac
  else
    OFFLINE_STATUS="no-report"; gap "offline analysis produced no readable report (rc=$OFFLINE_RC): $(tail -2 "$OUT/sweep-offline/analyze.out" | tr '\n' ' ' | cut -c1-200)"
  fi
fi
if [ "$LIVENESS" != alive ] && [ "$LOGVOL_FILES" -eq 0 ]; then
  gap "no module logs at all: the guest is $POWER/$LIVENESS and the secondary volume holds nothing"
fi

# ---- 4. the activity snapshot ---------------------------------------------------------------------------
SNAPARGS=(--out "$OUT/activity-snapshot.json" --vm "$VM" --reason "$REASON" --power-state "$POWER" --timeline "$TIMELINE"
          --harness-cmd "$HARNESS_CMD" --harness-cmd-source "$HARNESS_CMD_SOURCE")
[ -d "$OUT/sweep/logs" ] && SNAPARGS+=(--logs "$OUT/sweep/logs")
[ -n "$LOGVOL_DIR_COPY" ] && SNAPARGS+=(--logvol-files "$LOGVOL_DIR_COPY")
[ -f "$OUT/sweep/clock-presync.txt" ] && SNAPARGS+=(--clock "$OUT/sweep/clock-presync.txt")
python3 tools/activity-snapshot.py "${SNAPARGS[@]}" > "$OUT/snapshot.out" 2>&1; SNAP_RC=$?
cat "$OUT/snapshot.out" | tee -a "$LOGF"
if [ ! -s "$OUT/activity-snapshot.json" ]; then gap "activity-snapshot.json was not written (rc=$SNAP_RC)"
elif [ "$SNAP_RC" -ne 0 ]; then
  while IFS= read -r m; do gap "snapshot: $m"; done < <(grep -a '^  MISSING ' "$OUT/snapshot.out" | sed 's/^  MISSING //')   # GUARD:snapshotgaps DEFECT: :
fi

# ---- 5. the tarball, VERIFIED ----------------------------------------------------------------------------
TARBALL="$OUT/package.tar.gz"
rm -f "$TARBALL"
find "$OUT" -type f ! -name 'package.tar.gz' ! -name 'manifest.json' ! -name '*.core' ! -name '*.core.partial' ! -name '*.core.err' -printf '%P\n' | sort > "$OUT/.members"
tar -czf "$TARBALL" -C "$OUT" -T "$OUT/.members" 2>>"$LOGF"; trc=$?
TAR_OK=0; TAR_SHA=""; TAR_MEMBERS=0
if [ $trc -eq 0 ] && [ -s "$TARBALL" ]; then
  TAR_MEMBERS=$(tar -tzf "$TARBALL" 2>/dev/null | grep -vc '/$')
  WANT=$(wc -l < "$OUT/.members")
  if [ "$TAR_MEMBERS" = "$WANT" ]; then TAR_OK=1; TAR_SHA=$(sha256sum "$TARBALL" | cut -d' ' -f1)
  else gap "tarball lists $TAR_MEMBERS member(s), $WANT expected - not verified"; fi
else
  gap "tarball could not be written (tar rc=$trc)"
fi
log "tarball: $( [ $TAR_OK = 1 ] && echo "VERIFIED $TAR_MEMBERS member(s) sha256 ${TAR_SHA:0:16}" || echo NOT-VERIFIED )"

# ---- 6. the manifest - LAST, and only once the package it describes is verified ----------------------
COMPLETE=1; [ "${#GAPS[@]}" -eq 0 ] || COMPLETE=0
if [ "$TAR_OK" = 1 ]; then WRITE_MANIFEST=1; else WRITE_MANIFEST=0; fi   # GUARD:manifestlast DEFECT: WRITE_MANIFEST=1
if [ "$WRITE_MANIFEST" = 1 ]; then
  python3 - "$OUT" "$VM" "$REASON" "$HARNESS_CMD" "$HARNESS_CMD_SOURCE" "$POWER" "$LIVENESS" "$LOGVOL_STATUS" "$LOGVOL_IMG" "$LOGVOL_FILES" "$LOGVOL_SALVAGE" \
      "${SWEEP_RC:-}" "${SWEEP_STATUS:-}" "${OFFLINE_RC:-}" "${OFFLINE_STATUS:-}" "$SCREEN" "$WEDGE_CLASS" "$CORE_STATUS" "$CORE_PATH" \
      "$TARBALL" "$TAR_SHA" "$TAR_MEMBERS" "$COMPLETE" "$SINCE" "$SINCE_SOURCE" "$T0" "${#GAPS[@]}" "${GAPS[@]}" <<'PY' >> "$LOGF" 2>&1
import hashlib, json, os, sys, time
(out, vm, reason, hcmd, hsrc, power, live, lvst, lvimg, lvfiles, lvsalv, swrc, swst, ofrc, ofst, screen, wedge, corest, corepath,
 tarball, tarsha, tarn, complete, since, since_src, t0, ngaps) = sys.argv[1:28]
gaps = sys.argv[28:28 + int(ngaps)]
files = []
for ln in open(os.path.join(out, ".members"), encoding="utf-8"):
    rel = ln.rstrip("\n")
    p = os.path.join(out, rel)
    try:
        h = hashlib.sha256(open(p, "rb").read()).hexdigest()
        files.append({"path": rel, "bytes": os.path.getsize(p), "sha256": h})
    except OSError as e:
        files.append({"path": rel, "error": str(e)})
snap = {}
try:
    s = json.load(open(os.path.join(out, "activity-snapshot.json"), encoding="utf-8"))
    snap = {"path": "activity-snapshot.json", "complete": s.get("complete"), "missing": s.get("missing", [])}
except (OSError, ValueError):
    snap = {"path": None}
mf = {"version": 1, "vm": vm, "reason": reason, "collected_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
      "duration_s": int(time.time()) - int(t0), "harness_cmd": hcmd, "harness_cmd_source": hsrc,
      "since": since, "since_source": since_src, "power_state": power, "liveness": live,
      "sources": {"secondary_volume": {"status": lvst, "image": lvimg or None, "files": int(lvfiles), "salvage_lines": int(lvsalv)},
                  "live_sweep": {"rc": int(swrc) if swrc else None, "status": swst or None},
                  "offline_analysis": {"rc": int(ofrc) if ofrc else None, "status": ofst or None},
                  "screen": screen or None, "wedge_class": wedge or None,
                  "core": {"status": corest, "path": corepath or None}},
      "activity_snapshot": snap, "gaps": gaps, "complete": complete == "1",
      "tarball": {"path": tarball, "sha256": tarsha, "members": int(tarn), "bytes": os.path.getsize(tarball) if os.path.exists(tarball) else 0},
      "files": files, "specimen": "left alive - nothing here stops, kills or detaches the guest"}
tmp = os.path.join(out, "manifest.json.tmp")
with open(tmp, "w", encoding="utf-8") as f:
    json.dump(mf, f, indent=1, ensure_ascii=False)
os.replace(tmp, os.path.join(out, "manifest.json"))
PY
fi
rm -f "$OUT/.members"
if [ -s "$OUT/manifest.json" ]; then
  RC=0; [ "$COMPLETE" = 1 ] || RC=1
  log "manifest: $OUT/manifest.json (complete=$COMPLETE gaps=${#GAPS[@]})"
else
  RC=2; log "NO MANIFEST: the package did not verify, so the run is NOT collected"
fi
echo "COLLECT-RESULT vm=$VM rc=$RC complete=$COMPLETE manifest=$( [ -s "$OUT/manifest.json" ] && echo "$OUT/manifest.json" || echo none ) gaps=${#GAPS[@]}" | tee -a "$LOGF"
exit $RC
