#!/usr/bin/env bash
# hive-guard-selftest.sh - offline proof matrix for the self-guarding offline-hive path of
# guest/disable-hw-accel.ps1 and guest/disable-session-lock.ps1 (installer audit 2026-09-16, items
# 2 and 15: a SYSTEM reg-load of a user's NTUSER.DAT while that user's autologon is in flight, and an
# unread second reg-unload result - both reported as failed=0).
#
# Runs on this dev qube with the Linux pwsh alone (no rig, no guest, no registry):
#   static   the two HIVE-GUARD blocks are byte-identical twins (the scripts ship as separate files,
#            so drift is the failure mode), and EVERY `reg.exe load` in each script sits inside its
#            OFFLINE-HIVE block - i.e. behind the guard. A load added anywhere else fails here.
#   clean    tools/tests/hive-guard-test.ps1 MUST pass
#   knobs    HIVEGUARD_DEFECT=<name> MUST make the suite fail, on EXACTLY the intended cases -
#            a guard never seen to fail is decoration:
#              hivewait    the load fires whatever the guard decided        -> hw-4 hw-5 sl-4 sl-5
#              unloadread  the second unload's exit code is discarded       -> hw-7 sl-7
# Exit 0 only if every leg came out as required.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PWSH="${PWSH:-/home/user/bin/pwsh7/pwsh}"
OUT="${HIVEGUARD_OUT:-$(mktemp -d /tmp/hive-guard-selftest-XXXXXX)}"
mkdir -p "$OUT"
bad=0
say() { printf '%s\n' "$*"; }
HW="$ROOT/guest/disable-hw-accel.ps1"
SL="$ROOT/guest/disable-session-lock.ps1"

# ---- static ------------------------------------------------------------------------------------
block() { awk -v n="$2" '$0 ~ "^# ---- " n "-BEGIN" {f=1} f {print} $0 ~ "^# ---- " n "-END" {f=0}' "$1"; }
block "$HW" HIVE-GUARD >"$OUT/guard-hw.txt"
block "$SL" HIVE-GUARD >"$OUT/guard-sl.txt"
gl=$(wc -l <"$OUT/guard-hw.txt")
if [ "$gl" -gt 20 ] && cmp -s "$OUT/guard-hw.txt" "$OUT/guard-sl.txt"; then
    say "PASS  static: HIVE-GUARD blocks are byte-identical twins ($gl lines)"
else
    say "FAIL  static: HIVE-GUARD blocks differ or are missing (hw=$gl lines) - the twins have drifted"; diff "$OUT/guard-hw.txt" "$OUT/guard-sl.txt" | head -5; bad=1
fi
# invocations only (`& reg.exe load`), so a comment that merely mentions the command counts nowhere
for f in "$HW" "$SL"; do
    total=$(grep -c '& reg\.exe load' "$f")
    inside=$(block "$f" OFFLINE-HIVE | grep -c '& reg\.exe load')
    if [ "$total" -ge 1 ] && [ "$total" -eq "$inside" ]; then
        say "PASS  static: $(basename "$f") - all $total reg.exe load(s) inside the guarded OFFLINE-HIVE block"
    else
        say "FAIL  static: $(basename "$f") - $total reg.exe load(s), only $inside inside the guarded block"; bad=1
    fi
done

# ---- pwsh suite ----------------------------------------------------------------------------------
if [ ! -x "$PWSH" ]; then say "FAIL  pwsh not found at $PWSH - the PowerShell half DID NOT RUN"; bad=1
else
    "$PWSH" -NoProfile -File "$ROOT/tools/tests/hive-guard-test.ps1" >"$OUT/clean.out" 2>&1; rc=$?
    n=$(grep -c '^ok' "$OUT/clean.out"); f=$(grep -c '^FAIL' "$OUT/clean.out")
    if [ $rc -eq 0 ] && [ "$f" -eq 0 ] && [ "$n" -ge 20 ]; then say "PASS  clean: rc=0 ok=$n fail=0"
    else say "FAIL  clean: rc=$rc ok=$n fail=$f ($(grep -m1 -E '^FAIL|FATAL' "$OUT/clean.out" | cut -c1-140))"; bad=1; fi

    knob_expect() { case "$1" in hivewait) echo "hw-4 hw-5 sl-4 sl-5";; unloadread) echo "hw-7 sl-7";; esac; }
    for k in hivewait unloadread; do
        HIVEGUARD_DEFECT="$k" "$PWSH" -NoProfile -File "$ROOT/tools/tests/hive-guard-test.ps1" >"$OUT/defect-$k.out" 2>&1; rc=$?
        got=$(grep '^FAIL' "$OUT/defect-$k.out" | awk '{print $2}' | sort -u | tr '\n' ' ' | sed 's/ $//')
        want=$(knob_expect "$k")
        if [ $rc -eq 1 ] && [ "$got" = "$want" ]; then
            say "PASS  defect $k: suite FAILED as required on exactly [$want] (rc=$rc; $(grep -c '^FAIL' "$OUT/defect-$k.out") failing checks)"
        else
            say "FAIL  defect $k: rc=$rc failing cases [$got] expected [$want] - that guard is decoration or the knob leaked"; bad=1
        fi
    done
fi

say "--- outputs in $OUT"
exit $bad
