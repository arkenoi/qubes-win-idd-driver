#!/usr/bin/env bash
# notifyerr-selftest.sh - the offline proof matrix for the secondary error-delivery route.
#
# Runs on this dev qube (gcc + the linux pwsh at /home/user/pwsh/pwsh), no rig, no guest:
#   C   agent/gui-agent/notifyerr.c + notifyerr_test.c: clean build must PASS, and each
#       NOTIFYERR_DEFECT_* build must FAIL (a guard never seen to fail is decoration).
#   PS  guest/qwt-notify-error.ps1 via tools/tests/notifyerr-test.ps1: clean must PASS, and a
#       copy with each `# GUARD:<name>` line deleted must FAIL.
# Exit 0 only if every leg came out as required. Output is the evidence; keep it in scratchpad.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PWSH="${PWSH:-/home/user/pwsh/pwsh}"
OUT="${NOTIFYERR_OUT:-$(mktemp -d /tmp/notifyerr-selftest-XXXXXX)}"
mkdir -p "$OUT"
bad=0
say() { printf '%s\n' "$*"; }

# ---- C ----------------------------------------------------------------------------------------
cd "$ROOT/agent/gui-agent" || exit 2
cbuild() { gcc -std=c99 -Wall -Wextra -Werror -D_DEFAULT_SOURCE -D_POSIX_C_SOURCE=200809L $2 -I. notifyerr.c notifyerr_test.c -o "$OUT/$1" 2>"$OUT/$1.build.err"; }
if cbuild c-clean ""; then
    NOTIFYERR_TEST_DIR="$OUT" "$OUT/c-clean" >"$OUT/c-clean.out" 2>&1; rc=$?
    n=$(grep -c '^ok' "$OUT/c-clean.out"); f=$(grep -c '^FAIL' "$OUT/c-clean.out")
    if [ $rc -eq 0 ] && [ "$f" -eq 0 ] && [ "$n" -gt 40 ]; then say "PASS  C clean: rc=0 ok=$n fail=0"; else say "FAIL  C clean: rc=$rc ok=$n fail=$f"; bad=1; fi
else say "FAIL  C clean build: $(head -3 "$OUT/c-clean.build.err")"; bad=1; fi
for d in SEVERITY RATELIMIT CAP REDACT FAILOPEN; do
    if cbuild "c-defect-$d" "-DNOTIFYERR_DEFECT_$d"; then
        NOTIFYERR_TEST_DIR="$OUT" "$OUT/c-defect-$d" >"$OUT/c-defect-$d.out" 2>&1; rc=$?
        f=$(grep -c '^FAIL' "$OUT/c-defect-$d.out")
        if [ $rc -ne 0 ] && [ "$f" -gt 0 ]; then say "PASS  C defect $d: suite FAILED as required (rc=$rc, $f failing checks: $(grep '^FAIL' "$OUT/c-defect-$d.out" | head -1 | cut -c6-70))"
        else say "FAIL  C defect $d: suite did NOT fail (rc=$rc) - that guard is decoration"; bad=1; fi
    else say "FAIL  C defect $d build: $(head -3 "$OUT/c-defect-$d.build.err")"; bad=1; fi
done

# ---- PowerShell -------------------------------------------------------------------------------
if [ ! -x "$PWSH" ]; then say "FAIL  pwsh not found at $PWSH - the PowerShell half DID NOT RUN"; bad=1
else
    HELPER="$ROOT/guest/qwt-notify-error.ps1"
    "$PWSH" -NoProfile -File "$ROOT/tools/tests/notifyerr-test.ps1" >"$OUT/ps-clean.out" 2>&1; rc=$?
    n=$(grep -c '^ok' "$OUT/ps-clean.out"); f=$(grep -c '^FAIL' "$OUT/ps-clean.out")
    if [ $rc -eq 0 ] && [ "$f" -eq 0 ] && [ "$n" -gt 40 ]; then say "PASS  PS clean: rc=0 ok=$n fail=0"; else say "FAIL  PS clean: rc=$rc ok=$n fail=$f ($(grep -m1 -E '^FAIL' "$OUT/ps-clean.out" || grep -m1 -iE 'exception|error' "$OUT/ps-clean.out" | cut -c1-120))"; bad=1; fi
    for g in severity ratelimit cap redact failopen; do
        m="$OUT/helper-defect-$g.ps1"
        hits=$(grep -c "# GUARD:$g\$" "$HELPER")
        if [ "$hits" -ne 1 ]; then say "FAIL  PS defect $g: expected exactly 1 '# GUARD:$g' line in the helper, found $hits"; bad=1; continue; fi
        grep -v "# GUARD:$g\$" "$HELPER" >"$m"
        "$PWSH" -NoProfile -File "$ROOT/tools/tests/notifyerr-test.ps1" -HelperPath "$m" >"$OUT/ps-defect-$g.out" 2>&1; rc=$?
        f=$(grep -c '^FAIL' "$OUT/ps-defect-$g.out")
        if [ $rc -ne 0 ] && [ "$f" -gt 0 ]; then say "PASS  PS defect $g: suite FAILED as required (rc=$rc, $f failing checks: $(grep '^FAIL' "$OUT/ps-defect-$g.out" | head -1 | cut -c6-70))"
        else say "FAIL  PS defect $g: suite did NOT fail (rc=$rc) - that guard is decoration"; bad=1; fi
    done
fi

say "--- outputs in $OUT"
exit $bad
