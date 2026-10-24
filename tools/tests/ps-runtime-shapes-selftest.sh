#!/usr/bin/env bash
# ps-runtime-shapes-selftest.sh - the two PowerShell defects that PARSE CLEANLY must be refused.
# No guest, no rig.
#
# WHY THIS EXISTS. Both were found by hand on 2026-10-24, in the same file family, and neither was
# visible to anything this repo runs:
#   1. an -f format index with no argument behind it. guest/wgcbroker-peek.ps1's CROP line
#      referenced index 10 while passing ten arguments, so every run threw "Error formatting a
#      string: Index (zero based) must be ... less than the size of the argument list" - and the ONE
#      diagnostic that tells a wrong crop from missing pixels, the thing ABI 26 exists to provide,
#      printed NOTHING from the day valid= was added to it.
#   2. a bare TYPE LITERAL as a command argument. An int cast written to the LEFT of the parentheses
#      is passed as the argument itself and the value is gone - measured under pwsh 7.4.
# The files PARSE, so tools/ps-parse-gate.sh's own pass could not see them; the variable names are
# fine, so peek-abi-assert's static leg could not; and the throw is at runtime inside one
# Write-Output. Filed as findings/issues.md PSFORMATINDEXUNCHECKED and fixed in 4fbde2c2.
#
# AND THE FIRST CUT OF CHECK 2 REPORTED NOTHING ON A FILE THAT CARRIED THE DEFECT, which is the
# reason this suite exists rather than a line in a commit message. It tested for a
# TypeExpressionAst; in ARGUMENT position PowerShell parses a bare word as a STRING, so the cast
# arrives as StringConstantExpressionAst with the cast's text. Introspected under pwsh 7.4 rather
# than assumed. A check that cannot fail is decoration, so each one is driven here on a file written
# to carry exactly that defect, and on a file written to look like it but not be one.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 2
PASS=0; FAIL=0
ok(){ echo "ok   $*"; PASS=$((PASS+1)); }
no(){ echo "FAIL $*"; FAIL=$((FAIL+1)); [ -n "${2:-}" ] && echo "     why it matters: $2"; }

PS=""
for c in "$(command -v pwsh || true)" "$HOME/pwsh74/pwsh" "$HOME/pwsh/pwsh"; do
    [ -n "$PS" ] && break; [ -x "$c" ] && PS="$c"
done
if [ -z "$PS" ]; then
    # NOT A PASS. The gate shells out to pwsh, so with no pwsh nothing was checked and saying so is
    # the only honest exit - this project's rule is that missing data fails.
    echo "SELFTEST-ERROR: no pwsh, so neither check could be driven - this is not a pass"
    exit 2
fi

T=$(mktemp -d "${TMPDIR:-/tmp}/psshapes-XXXXXX") || exit 2
# UNDER THE REPO, because the gate joins its argument to the repo root. A directory outside it would
# make the gate scan nothing and report scanned=0 failing=0, which reads exactly like a pass.
PROBE="scratchpad/psshapes-probe-$$"
mkdir -p "$PROBE" || exit 2
trap 'rm -rf "$T" "$PROBE"' EXIT

# ---- 1. the defects, each on its own line, in one file ------------------------------------------
cat > "$PROBE/bad.ps1" <<'PS1'
function T($k,$v){ Write-Output "$k=$v" }
$s = (Get-Date).AddSeconds(-5)
T 'waited_s' [int]((Get-Date) - $s).TotalSeconds
Write-Output ("a={0} b={3}" -f 1,2)
PS1
out=$(bash tools/ps-parse-gate.sh "$PROBE" 2>&1); rc=$?
printf '%s' "$out" | command grep -q 'bare type literal \[int\]' \
  && ok "1 SEEN TO FAIL: a type literal passed as an argument is refused" \
  || no "1 the type-literal check did not fire" \
        "a lost cast ships silently - the value never reaches the callee and the log line carries the word [int]"
printf '%s' "$out" | command grep -q '\-f references {3} but only 2' \
  && ok "2 SEEN TO FAIL: an -f index with no argument behind it is refused" \
  || no "2 the format-index check did not fire" \
        "that is the defect that silenced the broker's only crop diagnostic"
[ "$rc" != 0 ] \
  && ok "3 the gate EXITS NON-ZERO on them (rc=$rc), so a caller can gate on it" \
  || no "3 the gate exited 0 with findings printed" \
        "a gate whose exit code ignores its own findings cannot gate anything"

# ---- 2. the near-misses, which must NOT fire ----------------------------------------------------
# A bracketed log tag written as a bare word, and an -f whose arguments this check cannot count.
cat > "$PROBE/bad.ps1" <<'PS1'
Write-Output [WARN]
Write-Output ("a={0} b={1}" -f 1,2)
$args2 = @(1,2,3)
Write-Output ("x={0} y={1} z={2}" -f $args2)
$cast = [int]'7'
Write-Output ([int]((Get-Date) - (Get-Date).AddSeconds(-5)).TotalSeconds)
PS1
out2=$(bash tools/ps-parse-gate.sh "$PROBE" 2>&1); rc2=$?
if [ "$rc2" = 0 ]; then
    ok "4 no false positive on a bracketed log tag, a correct -f, an uncountable -f or a real cast"
else
    no "4 the checks fired on legitimate code: $(printf '%s' "$out2" | command grep -a FAIL | head -3)" \
       "a gate that refuses correct code gets switched off, and then it guards nothing"
fi

# ---- 3. and the SHIPPED tree must be clean, which is the standing claim -------------------------
out3=$(bash tools/ps-parse-gate.sh 2>&1); rc3=$?
n=$(printf '%s' "$out3" | sed -n 's/.*scanned=\([0-9]*\).*/\1/p' | tail -1)
if [ "${n:-0}" -lt 50 ]; then
    no "5 the gate scanned only ${n:-0} file(s) - the population is wrong" \
       "a sweep over nothing reports failing=0 and reads like a clean tree"
elif [ "$rc3" = 0 ]; then
    ok "5 all ${n} shipped .ps1 files are free of both shapes"
else
    no "5 shipped files carry one of these shapes: $(printf '%s' "$out3" | command grep -a FAIL | head -3)" \
       "each one is a line that throws, or a value that never arrives, on a guest"
fi

echo "--- $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ] && exit 0 || exit 1
