#!/bin/bash
# logvolume-measure.sh - does the one-log-per-module change actually reduce the log volume on a
# guest? The claim in docs/ADR-logging.md is a PREDICTION until this runs.
#
#   mgmt/harness/logvolume-measure.sh <release-iso-or-setup-tree> <subject> <golden> [calls]
#
# The subject and the golden are BOTH named, never defaulted (lint L10): this script runs
# `qvm-remove -f` on the subject, so a defaulted name is the exact hazard that rule exists for.
#
# PRE-REGISTERED, before the run (.claude/skills/experimenter):
#   HYPOTHESIS  after the fix, qrexec-wrapper holds AT MOST 2 log files (one per day, 2 allows a
#               midnight rollover) however many calls are made, and the "output pump is still
#               running at exit" warning appears 0 times at W/E level. Refuted by 3+ wrapper files,
#               or by any pump warning.
#   BASELINE    win11r-gz, 2026-10-07, pre-fix, after one install and three boots: 386 files in
#               LogDir, 368 of them qrexec-wrapper-*.log, 229 pump warnings. Recorded in
#               findings/misc.md and docs/ADR-logging.md.
#   VARIABLE    the package only - the same golden, the same call count.
#   INSTRUMENT  the LSW INVENTORY / INVMODULE lines (independent of the collector's file cap) plus
#               the sweep's own error_lines_undeclared. Validated offline by
#               tools/tests/log-sweep-selftest.sh (59 checks), which drives BOTH the present and the
#               ABSENT inventory path - an absent inventory reads as NOT KNOWN, never as zero.
#   BUDGET      quick-upgrade ~15-25 min; the calls ~2 min; the sweep ~2 min. Terminal states and
#               stall detection come from quick-upgrade.sh and e2e-lib.sh, not from a sleep here.
#
# WHY FILES-PER-MODULE AND NOT TOTAL FILES: the total depends on how many boots and calls a run
# makes, so it cannot be compared against a baseline taken with a different history. Files per
# module is the thing the fix changes - one per PROCESS became one per DAY - so with a call count
# asserted in the same run it is a claim that stands on its own.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PKG="${1:-}"
SUBJ="${2:-}"
GOLDEN="${3:-}"
CALLS="${4:-25}"
OUT="${LOGVOL_OUT:-$HOME/qwt-logvolume}/$(date -u +%Y%m%dT%H%M%SZ)-${SUBJ:-unnamed}"

[ -n "$PKG" ] && [ -n "$SUBJ" ] && [ -n "$GOLDEN" ] \
    || { echo "usage: $0 <release-iso-or-setup-tree> <subject> <golden> [calls]"; exit 2; }
[ -e "$PKG" ] || { echo "FATAL: $PKG does not exist"; exit 2; }
# The subject is REMOVED and recreated below, so refuse anything that is not a testbed subject.
case "$SUBJ" in
    dom0|win-idd-mgmt) echo "FATAL: $SUBJ is not a testbed subject"; exit 2 ;;
esac
qvm-ls --raw-data --fields NAME 2>/dev/null | command grep -qx "$GOLDEN" \
    || { echo "FATAL: the golden $GOLDEN does not exist"; exit 2; }
mkdir -p "$OUT"
log(){ echo "[$(date -u +%H:%M:%S)] $*" | tee -a "$OUT/run.log"; }

# ONE VM-MUTATING JOB AT A TIME (mgmt/harness/vmlock.sh): concurrent jobs reboot the guest
# underneath each other and destroy each other's results.
# shellcheck source=/dev/null
. "$ROOT/mgmt/harness/vmlock.sh"
vm_lock "$SUBJ" || { echo "FATAL: another VM-mutating job holds the lock"; exit 2; }

SINCE="$(date -u +%Y-%m-%dT%H:%M:%S)"
log "subject=$SUBJ golden=$GOLDEN package=$PKG calls=$CALLS out=$OUT"

# ---- 1. a fresh subject from the golden ---------------------------------------------------------
# Never reuse a killed or previously-measured guest: its LogDir already holds another run's files,
# and this measurement is a file COUNT.
if qvm-ls --raw-data --fields NAME 2>/dev/null | command grep -qx "$SUBJ"; then
    log "removing the previous $SUBJ (its LogDir would carry the last run's files)"
    qvm-kill "$SUBJ" >/dev/null 2>&1
    qvm-remove -f "$SUBJ" >/dev/null 2>&1 || { log "FATAL: could not remove $SUBJ"; exit 2; }
fi
log "cloning $GOLDEN -> $SUBJ (clone-guest.sh: create, tag, THEN copy - policy here is tag-based)"
"$ROOT/mgmt/clone-guest.sh" "$GOLDEN" "$SUBJ" >>"$OUT/clone.log" 2>&1 \
    || { log "FATAL: clone failed, see $OUT/clone.log"; tail -5 "$OUT/clone.log"; exit 2; }

# ---- 2. the package, delivered the way the field gets it ---------------------------------------
log "quick-upgrade over the golden (an MSI MajorUpgrade from a disc, as the field gets it)"
QU_OUT="$OUT/quick-upgrade" "$ROOT/mgmt/harness/quick-upgrade.sh" "$PKG" "$SUBJ" win11 \
    >>"$OUT/upgrade.log" 2>&1
rc=$?
log "quick-upgrade rc=$rc"
if [ "$rc" != 0 ]; then
    log "FATAL: the package did not install - nothing downstream of this is a measurement"
    tail -15 "$OUT/upgrade.log" | sed 's/^/  /'
    exit 1
fi

# ---- 3. THE RUNNING BINARY MUST BE THE ONE UNDER TEST ------------------------------------------
# A measurement of a package that did not install is worse than no measurement. The marker is in
# the patched logger itself: the line prefix carries pid:tid, which only the patched build writes.
log "asserting the installed build is the patched one"
"$ROOT/tools/qtest" run "$SUBJ" 'powershell -NoProfile -Command "
$d=(Get-ItemProperty \"HKLM:\SOFTWARE\Invisible Things Lab\Qubes Tools\" -EA SilentlyContinue).LogDir
$f=Get-ChildItem $d -Filter *.log -EA SilentlyContinue | Sort-Object LastWriteTime -Desc | Select-Object -First 1
if ($f) { Write-Output (\"PREFIXSAMPLE \" + ((Get-Content $f.FullName -TotalCount 40) -match \"^﻿?\[\d{8}\.\d{6}\.\d{3}-\d+:\d+-\" | Measure-Object).Count + \" \" + $f.Name) }
else { Write-Output \"PREFIXSAMPLE none\" }"' > "$OUT/prefix.txt" 2>&1
pfx=$(command grep -ao 'PREFIXSAMPLE [0-9a-zA-Z.-]*' "$OUT/prefix.txt" | head -1 | awk '{print $2}')
log "pid:tid-prefixed lines in the newest log: ${pfx:-<none>}"
case "${pfx:-none}" in
    none|0) log "FATAL: no pid:tid line prefix in the guest's newest log - the patched logger is NOT running, so a file count here measures the OLD build"; exit 1 ;;
esac

# ---- 4. drive the wrapper: the module the explosion came from -----------------------------------
# 368 of the 386 files were qrexec-wrapper, one per CALL. Make calls, then count files.
log "making $CALLS qrexec calls (each one used to leave its own log file)"
made=0
for i in $(seq 1 "$CALLS"); do
    "$ROOT/tools/qtest" run "$SUBJ" 'cmd /c echo logvol-'"$i" >/dev/null 2>&1 && made=$((made+1))
done
log "calls that returned: $made of $CALLS"
# Missing data FAILS: too few calls and the file count proves nothing either way.
if [ "$made" -lt 10 ]; then
    log "FATAL: only $made calls landed - with fewer than 10 the per-module file count cannot refute anything"
    exit 1
fi

# ---- 5. the sweep, which is also the gate -------------------------------------------------------
log "log sweep (this is the instrument AND the gate: every rig run sweeps and acts)"
"$ROOT/mgmt/harness/log-sweep.sh" "$SUBJ" "$SINCE" "$OUT/sweep" >>"$OUT/sweep.log" 2>&1
sweeprc=$?
log "log-sweep rc=$sweeprc ($(command grep -ao 'LOGSWEEP-RESULT.*' "$OUT/sweep.log" | tail -1))"

REP=$(command grep -ao 'report=[^ ]*' "$OUT/sweep.log" | tail -1 | cut -d= -f2)
[ -n "$REP" ] && [ -f "$REP" ] || { log "FATAL: the sweep produced no report - nothing to read"; exit 1; }

# ---- 6. the verdict, against the bars written above --------------------------------------------
python3 - "$REP" "$made" "$OUT" <<'PY' | tee -a "$OUT/run.log"
import json, sys, base64
rep, made, out = sys.argv[1], int(sys.argv[2]), sys.argv[3]
r = json.load(open(rep))
h = r.get("header", {})
inv = h.get("inventory")
mods = h.get("invmodules") or []
fails = []
if not inv:
    print("FAIL  inventory: ABSENT - the volume for this run is NOT KNOWN (missing data, not zero)")
    fails.append("inventory-absent")
else:
    print("INVENTORY  %s file(s), %s line(s), %s module(s)" % (inv.get("files"), inv.get("lines"), inv.get("modules")))
    def name(m):
        try: return base64.b64decode(m.get("nameb64", "")).decode("utf-8", "replace")
        except Exception: return "?"
    for m in sorted(mods, key=lambda m: -int(m.get("files", 0)))[:8]:
        print("   %-26s %4s file(s) %9s line(s)" % (name(m)[:26], m.get("files"), m.get("lines")))
    wrap = [m for m in mods if name(m) == "qrexec-wrapper"]
    if not wrap:
        print("FAIL  qrexec-wrapper: no module row at all after %d calls - the calls did not log, so this refutes nothing" % made)
        fails.append("no-wrapper-row")
    else:
        nf = int(wrap[0].get("files", 0))
        if nf <= 2:
            print("PASS  qrexec-wrapper: %d file(s) for %d calls (bar: <= 2; it was 368 for a comparable run)" % (nf, made))
        else:
            print("FAIL  qrexec-wrapper: %d file(s) for %d calls - the bar was <= 2" % (nf, made))
            fails.append("wrapper-files-%d" % nf)
# the 229-line class must be gone at W/E level
pump = 0
for s in (r.get("new") or []) + (r.get("out_of_context") or []):
    if "output pump is still running" in (s.get("key") or ""):
        pump += int(s.get("count", 0))
if pump:
    print("FAIL  pump warnings: %d at W/E level - the classification did not take" % pump)
    fails.append("pump-%d" % pump)
else:
    print("PASS  pump warnings: none at W/E level (it was 229 on the pre-fix run)")
und = (r.get("metrics") or {}).get("error_lines_undeclared")
print("GATE  error_lines_undeclared=%s  status=%s" % (und, r.get("status")))
print()
print("LOGVOLUME-RESULT %s fails=%s" % ("PASS" if not fails else "FAIL", ",".join(fails) or "none"))
open(out + "/verdict.txt", "w").write("PASS" if not fails else "FAIL " + ",".join(fails))
sys.exit(0 if not fails else 1)
PY
vrc=$?
log "verdict rc=$vrc"
exit "$vrc"
