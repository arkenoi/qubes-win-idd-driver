#!/bin/bash
# FAIL-PROOF for tools/check-install-log.py — two-sided, entirely offline.
#
# These three invariants used to be graded by HAND-RUN GREPS straight into the ledger, so there was
# no instrument to prove. This plants each defect into a copy of a REAL campaign log and requires
# the checker to name that specific invariant; a checker that stays green on a planted defect cannot
# be evidence for the runs it graded.
set -uo pipefail
cd "$(dirname "$0")/../.."
SRC="${1:-$HOME/qwt-accept/20260830-acceptance-4.3.16/C4-win10/WIN10-1stage-final.log}"
[ -f "$SRC" ] || { echo "no source log at $SRC"; exit 2; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
rc=0

expect_red(){  # <name> <file> <invariant>
  local out; out=$(tools/check-install-log.py "$2" 2>&1); local r=$?
  if [ $r -ne 0 ] && echo "$out" | grep -q "$3"; then
    echo "  -> RED AS REQUIRED ($3)"
  else
    echo "  -> NOT RED: the checker stayed green (rc=$r) on a planted $1"; echo "$out" | sed 's/^/       /'; rc=1
  fi
}

echo "=== POSITIVE: the untouched log must PASS ==="
tools/check-install-log.py "$SRC" >/dev/null 2>&1 && echo "  -> OK" || { echo "  -> the source log already fails; pick a clean one"; exit 2; }

echo "=== NEGATIVE 1: the SAME run_id emits a second PRECONDITION (installer restarted mid-run) ==="
RID=$(grep -ao '"run_id":"[0-9a-f]*"' "$SRC" | head -1 | cut -d'"' -f4)
{ cat "$SRC"; echo "2026-08-30 99:99:99 [INFO] === PRECONDITION === {\"run_id\":\"$RID\",\"t\":\"replayed\"}"; } > "$TMP/dupe.log"
expect_red duplicate-run_id "$TMP/dupe.log" one_precondition_per_run

echo "=== NEGATIVE 2: a REFUSING line appears ==="
{ cat "$SRC"; echo "2026-08-30 99:99:99 [ERROR] REFUSING to install: PV drivers gate not satisfied"; } > "$TMP/refuse.log"
expect_red refusing-line "$TMP/refuse.log" no_refusing

echo "=== NEGATIVE 3: the monitor is never disarmed before msiexec (the 81d2b79 brick) ==="
grep -vi 'xenbus_monitor disabled' "$SRC" > "$TMP/nomon.log"
expect_red missing-monitor-disarm "$TMP/nomon.log" monitor_disabled_before_msiexec



# ---------------------------------------------------------------- the stage/msiexec invariants
# Different invariants need different source branches: stage1/stage2 RESULTs only exist in the
# two-stage logs (C1), REINSTALL=ALL only in the same-version reinstall path (C6).
C1=$(ls "$HOME"/qwt-accept/20260830-acceptance-4.3.16/C1-win10/[A-Z]*.log 2>/dev/null | head -1)
C6=$(ls "$HOME"/qwt-accept/20260830-acceptance-4.3.16/C6-win10/[A-Z]*.log 2>/dev/null | head -1)

if [ -f "$C1" ]; then
  echo "=== NEGATIVE 4: a stage1-prepare RESULT reports ok:false ==="
  sed 's/"stage":"stage1-prepare","ok":true/"stage":"stage1-prepare","ok":false/' "$C1" > "$TMP/s1.log"
  expect_red stage1-not-ok "$TMP/s1.log" stage1_prepare_ok

  echo "=== NEGATIVE 5: a stage2-install RESULT reports ok:false ==="
  sed 's/"stage":"stage2-install","ok":true/"stage":"stage2-install","ok":false/' "$C1" > "$TMP/s2.log"
  expect_red stage2-not-ok "$TMP/s2.log" stage2_install_ok

  echo "=== NEGATIVE 6: the resume fires TWICE (two stage2-install RESULTs) ==="
  { cat "$C1"; grep -a '"stage":"stage2-install"' "$C1" | head -1; } > "$TMP/twice.log"
  expect_red resume-fired-twice "$TMP/twice.log" resume_fires_once
fi

if [ -f "$C6" ]; then
  echo "=== NEGATIVE 7: msiexec drops PvDriversDisk from ADDLOCAL ==="
  sed 's/,PvDriversDisk//' "$C6" > "$TMP/noaddlocal.log"
  expect_red missing-PvDriversDisk "$TMP/noaddlocal.log" reinstall_all_on_msiexec
fi

echo "=== NEGATIVE 8: pnputil reports a failure ==="
{ cat "$SRC"; echo "2026-08-30 99:99:99 [ERROR] pnputil: adding driver package failed with error 0x800f0217"; } > "$TMP/pnp.log"
expect_red pnputil-failure "$TMP/pnp.log" pnputil_259_accepted

# (early exit removed - the negatives below must run too)

echo "=== NEGATIVE 9a: a CLEAN-install log (empty installed_qwt) loses its clean-install marker ==="
if [ -f "$C1" ]; then
  grep -v 'clean install path' "$C1" > "$TMP/nomarker.log"
  expect_red missing-clean-marker "$TMP/nomarker.log" branch_clean_install
fi

echo "=== NEGATIVE 9b: an UPGRADE log (prior QWT present) gains a clean-install marker ==="
C4=$(ls "$HOME"/qwt-accept/20260830-acceptance-4.3.16/C4-win10/[A-Z]*.log 2>/dev/null | head -1)
if [ -f "$C4" ]; then
  { cat "$C4"; echo "2026-08-30 99:99:99 [INFO] no installed Qubes Windows Tools found - clean install path"; } > "$TMP/falsemarker.log"
  expect_red false-clean-marker "$TMP/falsemarker.log" branch_clean_install
fi

echo "=== NEGATIVE 10: two runs share a run_id (ids not distinct) ==="
if [ -f "$C1" ]; then
  RID2=$(grep -ao '"run_id":"[0-9a-f]*"' "$C1" | head -1 | cut -d'"' -f4)
  { cat "$C1"; echo "2026-08-30 99:99:99 [INFO] === PRECONDITION === {\"run_id\":\"$RID2\",\"installed_qwt\":[]}"; } > "$TMP/dup2.log"
  expect_red duplicate-run-id "$TMP/dup2.log" distinct_run_ids
fi

echo "=== NEGATIVE 11: the inbox disk re-arm did not complete ==="
sed 's/"inbox_disk_rearm":"done"/"inbox_disk_rearm":"skipped"/' "$SRC" > "$TMP/rearm.log"
expect_red rearm-not-done "$TMP/rearm.log" inbox_disk_rearm_done

echo "=== NEGATIVE 12: an Event-1074 restart lands during the install ==="
{ cat "$SRC"; echo "2026-08-30 16:28:10 [WARN] Event 1074: the process msiexec.exe has initiated the restart of computer"; } > "$TMP/e1074.log"
expect_red restart-during-msiexec "$TMP/e1074.log" no_restart_during_msiexec

exit $rc
