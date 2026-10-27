#!/usr/bin/env bash
# qrexec-agent maps SYSTEM/root to the wrapper's own-token spelling on EVERY path, in ONE place.
# run: tools/tests/qrexec-user-normalise-selftest.sh
# pass: exit 0
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/core-agent/src/qrexec-agent/qrexec-agent.c"
SRC_REL="src/qrexec-agent/qrexec-agent.c"
STUB="$ROOT/tools/tests/win32stub"
MIRROR="${WINDOWS_UTILS_SRC:-$ROOT/upstream/ro/qubes-windows-utils}"
TEST="$ROOT/tools/tests/qrexec-user-normalise-test.c"
OUT="${QUN_OUT:-$(mktemp -d "${TMPDIR:-/tmp}/qrexec-user-normalise-XXXXXX")}"
mkdir -p "$OUT"
pass=0; fail=0
ok(){ pass=$((pass+1)); echo "PASS  $*"; }
bad(){ fail=$((fail+1)); echo "FAIL  $*"; }

[ -f "$SRC" ] || { echo "FAIL  $SRC is missing - nothing ran (missing data fails)"; exit 2; }
[ -f "$TEST" ] || { echo "FAIL  $TEST is missing - nothing ran"; exit 2; }
command -v gcc >/dev/null || { echo "FAIL  no gcc - nothing ran"; exit 2; }
if [ ! -d "$MIRROR/.git" ] && [ ! -f "$MIRROR/include/log.h" ]; then
    echo "FAIL  windows-utils mirror not at $MIRROR (set WINDOWS_UTILS_SRC) - nothing ran (missing data fails)"; exit 2
fi

# ---- the headers CI compiles against ----------------------------------------------------------------------
REF=$(grep -m1 -oE 'WINDOWS_UTILS_REF:\s*\S+' "$ROOT/.github/workflows/build.yml" | awk '{print $2}')
[ -n "$REF" ] || { echo "FAIL  WINDOWS_UTILS_REF not found in .github/workflows/build.yml"; exit 2; }
rm -rf "$OUT/tree" && mkdir -p "$OUT/tree"
if git -C "$MIRROR" archive "$REF" include/log.h include/exec.h include/qubes-io.h 2>/dev/null | tar -x -C "$OUT/tree"; then
    ok "headers: log.h, exec.h and qubes-io.h extracted from windows-utils $REF (the ref CI clones)"
else
    echo "FAIL  cannot extract the headers at $REF from the mirror at $MIRROR"; exit 2
fi
# the two constants the test file defines for itself must be what the shipped headers say
if grep -qF "#define QUBES_ARGUMENT_SEPARATOR L'|'" "$OUT/tree/include/exec.h"; then
    ok "separator: exec.h at $REF splits wrapper arguments on '|', as the test assumes"
else
    bad "separator: exec.h at $REF does not define QUBES_ARGUMENT_SEPARATOR as L'|' - the test's field split is wrong"
fi
if grep -qE "#define MAX_PATH_LONG\s+32768" "$OUT/tree/include/qubes-io.h"; then
    ok "max_path_long: qubes-io.h at $REF says 32768, as the test assumes"
else
    bad "max_path_long: qubes-io.h at $REF does not say 32768"
fi

# ---- shape: one normaliser, in the chokepoint, reached by every caller -----------------------------------
python3 - "$SRC" <<'PY' > "$OUT/shape.out" 2>&1
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()

def body(name):
    """the definition 'static <type> name(' to the first line that is a lone '}', or None; must be unique"""
    hits = [m.start() for m in re.finditer(r'^static \w+ ' + re.escape(name) + r'\(', src, re.M)]
    if len(hits) != 1:
        return None
    end = src.find("\n}\n", hits[0])
    return src[hits[0]:end + 3] if end >= 0 else None

sc = body("StartChild")
nu = body("NormalizeUserName")
if sc is None:
    print("BAD producer_is_one: StartChild is not defined exactly once"); sys.exit(0)
n_prod = src.count('L"qrexec-wrapper.exe')
print(("OK" if n_prod == 1 and 'L"qrexec-wrapper.exe' in sc else "BAD")
      + " producer_is_one: %d producer(s) of the wrapper command line, %sin StartChild" % (n_prod, "" if 'L"qrexec-wrapper.exe' in sc else "NOT "))

if nu is None:
    print("BAD normaliser_exists: NormalizeUserName is not defined exactly once"); sys.exit(0)
print("OK normaliser_exists: NormalizeUserName is defined once")

routed = "childUser = NormalizeUserName(userName);" in sc and "childUser, QUBES_ARGUMENT_SEPARATOR," in sc \
    and "userName, QUBES_ARGUMENT_SEPARATOR," not in sc \
    and sc.find("NormalizeUserName(userName)") < sc.find("StringCchPrintf(")
print(("OK" if routed else "BAD") + " startchild_routes: StartChild resolves the account through NormalizeUserName before it builds the wrapper line, and the line carries the result")

lits = [i + 1 for i, l in enumerate(src.splitlines()) if 'L"SYSTEM"' in l or 'L"root"' in l]
nu_start = src[:src.find(nu)].count("\n") + 1
nu_end = nu_start + nu.count("\n")
outside = [n for n in lits if not (nu_start <= n <= nu_end)]
copy_gone = 'wcscmp(*userName, L"SYSTEM")' not in src
print(("OK" if lits and not outside and copy_gone else "BAD")
      + " one_place: SYSTEM/root literals on lines %s, %s; the dom0-only copy in ParseUtf8Command is %s"
      % (lits, "all inside NormalizeUserName" if not outside else "OUTSIDE the normaliser at %s" % outside, "gone" if copy_gone else "STILL THERE"))

guarded = "requested &&" in nu and '_wcsicmp(requested, L"SYSTEM")' in nu and '_wcsicmp(requested, L"root")' in nu \
    and "return NULL;" in nu and "return requested;" in nu
print(("OK" if guarded else "BAD") + " case_insensitive_null_guarded: the match is _wcsicmp on both names behind a NULL guard, NULL for the own token, the name itself otherwise")

# EITHER LEVEL. This read the literal LogInfo( and went red when the product demoted the line
# to LogDebug on 2026-10-20 for log volume (qrexec-agent.c:858-862, the owner's reason in the
# comment). The level is the owner's call; the property is that the line names the account that
# was requested AND the consequence, so the predicate asks for that and not for a level.
logged = any(('%s("user \'%%s\' is' % w) in nu for w in ("LogDebug", "LogInfo")) and "token" in nu
print(("OK" if logged else "BAD") + " logs_requested_and_consequence: the normaliser logs a line naming the requested account and the token used instead (either level)")

# every StartChild call expression in the file (not the definition, not the comment that names it)
calls = [i + 1 for i, l in enumerate(src.splitlines()) if re.match(r'^\s*(status = )?StartChild\(', l)]
print(("OK" if len(calls) == 3 else "BAD") + " three_call_sites: StartChild is called at lines %s (HandleServiceConnect, HandleExec x2) - none of them resolves the account itself" % calls)
PY
while IFS= read -r line; do
    case "$line" in
        OK\ *)  ok "shape ${line#OK }" ;;
        BAD\ *) bad "shape ${line#BAD }" ;;
        *)      bad "shape: unexpected output: $line" ;;
    esac
done < "$OUT/shape.out"

# ---- probe: what the stub printf models ----------------------------------------------------------------------
# MSVC's wide %s prints "(null)" for a NULL argument; the wrapper's own wcscmp(userName, L"(null)") is the
# other end. The stub rewrites %s to %ls for glibc, so glibc's %ls must do the same on THIS machine.
cat > "$OUT/nullprobe.c" <<'EOF'
#include <stdio.h>
#include <wchar.h>
int main(void) { wchar_t b[32]; const wchar_t *p = NULL; swprintf(b, 32, L"%ls", p); printf("%ls\n", b); return 0; }
EOF
if gcc -std=c99 -Wall -o "$OUT/nullprobe" "$OUT/nullprobe.c" 2>"$OUT/nullprobe.err" && [ "$("$OUT/nullprobe")" = "(null)" ]; then
    ok "probe: glibc's wide printf prints \"(null)\" for a NULL string argument, as MSVC's does"
else
    bad "probe: glibc's wide printf did not print \"(null)\" for NULL - the stub does not model the wrapper's contract here"
fi

# ---- the functions under test, extracted VERBATIM -----------------------------------------------------------
# $1 = source file, $2 = output startchild.c, $3 = mode: fixed (both functions), prefix (StartChild alone; the
# normaliser must be absent), knob (both, with the one normaliser call replaced by the verbatim pass-through)
extract() {
    python3 - "$1" "$2" "$3" <<'PY'
import re, sys
src, out, mode = open(sys.argv[1], encoding="utf-8").read(), sys.argv[2], sys.argv[3]
def body(name):
    hits = [m.start() for m in re.finditer(r'^static \w+ ' + re.escape(name) + r'\(', src, re.M)]
    if len(hits) != 1:
        sys.exit("%s: %d definition(s) of %s, need exactly 1" % (mode, len(hits), name))
    end = src.find("\n}\n", hits[0])
    if end < 0:
        sys.exit("%s: no end for %s" % (mode, name))
    return src[hits[0]:end + 3]
sc = body("StartChild")
if mode == "prefix":
    if "NormalizeUserName" in src:
        sys.exit("prefix: this source carries NormalizeUserName - it is not the pre-fix revision")
    text = sc
elif mode == "knob":
    # the guarded line cut out of the FIXED StartChild; the normaliser is then unreferenced and left out
    call = "childUser = NormalizeUserName(userName);"
    if sc.count(call) != 1:
        sys.exit("knob: %d occurrence(s) of the normaliser call, need exactly 1" % sc.count(call))
    text = sc.replace(call, "childUser = userName;")
else:
    text = body("NormalizeUserName") + "\n" + sc
open(out, "w", encoding="utf-8").write(text + "\n")
PY
}
build() { # $1 label, $2 startchild.c
    mkdir -p "$OUT/$1" && cp "$2" "$OUT/$1/startchild.c" &&
    gcc -std=c99 -Wall -Wextra -Werror -D_DEFAULT_SOURCE -I"$OUT/$1" -I"$STUB" -I"$OUT/tree/include" "$TEST" -o "$OUT/$1/run" 2>"$OUT/$1/build.err"
}
# a defect build must fail, and ONLY on the cases the defect breaks: anything else failing is a broken harness
defect_run() { # $1 label
    "$OUT/$1/run" >"$OUT/$1.out" 2>&1; local rc=$?
    local f; f=$(grep -c '^FAIL' "$OUT/$1.out")
    local other; other=$(grep '^FAIL' "$OUT/$1.out" | grep -vc '^FAIL pseudo:')
    if [ "$rc" -ne 0 ] && [ "$f" -ge 5 ] && [ "$other" -eq 0 ]; then
        ok "$1: the suite FAILED as required - $f pseudo-account checks ($(grep -m1 '^FAIL' "$OUT/$1.out" | cut -c6-80)), every real-account check still passing"
    else
        bad "$1: rc=$rc, $f failing checks, $other of them outside the pseudo-account cases - the suite cannot see the defect, or the harness is broken"
    fi
}

# clean: the working tree
if extract "$SRC" "$OUT/fixed.c" fixed 2>"$OUT/extract-fixed.err"; then
    if build clean "$OUT/fixed.c"; then
        "$OUT/clean/run" >"$OUT/clean.out" 2>&1; rc=$?
        n=$(grep -c '^ok' "$OUT/clean.out"); f=$(grep -c '^FAIL' "$OUT/clean.out")
        if [ "$rc" -eq 0 ] && [ "$f" -eq 0 ] && [ "$n" -ge 20 ]; then
            ok "clean: the working-tree StartChild hands the wrapper (null) for SYSTEM/system/root and the name itself for everything else (rc=0 ok=$n fail=0)"
        else
            bad "clean: rc=$rc ok=$n fail=$f"; grep '^FAIL' "$OUT/clean.out" | head -5
        fi
    else bad "clean build: $(head -3 "$OUT/clean/build.err")"; fi
else bad "clean extract: $(cat "$OUT/extract-fixed.err")"; fi

# prefix: the revision before the fix, found by content so this keeps pointing at the defect after the commit
fixcommit=$(git -C "$ROOT/core-agent" log --format=%H -S'NormalizeUserName' -- "$SRC_REL" | tail -1)
if [ -n "$fixcommit" ]; then pre="${fixcommit}^"; else pre="HEAD"; fi   # uncommitted fix: HEAD is still the defect
if git -C "$ROOT/core-agent" show "$pre:$SRC_REL" > "$OUT/prefix-src.c" 2>/dev/null && [ -s "$OUT/prefix-src.c" ]; then
    if grep -qF 'wcscmp(*userName, L"SYSTEM")' "$OUT/prefix-src.c" && ! grep -q NormalizeUserName "$OUT/prefix-src.c"; then
        ok "prefix revision: $(git -C "$ROOT/core-agent" rev-parse --short "$pre") carries the dom0-only copy and no normaliser"
        if extract "$OUT/prefix-src.c" "$OUT/prefix.c" prefix 2>"$OUT/extract-prefix.err" && build prefix "$OUT/prefix.c"; then
            defect_run prefix
        else bad "prefix build: $(head -3 "$OUT/extract-prefix.err" "$OUT/prefix/build.err" 2>/dev/null | tr '\n' ' ')"; fi
    else
        bad "prefix revision: $pre does not look like the pre-fix source - nothing was seen to fail (missing data fails)"
    fi
else
    bad "prefix revision: cannot read $pre:$SRC_REL - nothing was seen to fail (missing data fails)"
fi

# knob: the fixed source with the one guarded line cut out
if extract "$SRC" "$OUT/knob.c" knob 2>"$OUT/extract-knob.err" && build knob "$OUT/knob.c"; then
    defect_run knob
else bad "knob build: $(head -3 "$OUT/extract-knob.err" "$OUT/knob/build.err" 2>/dev/null | tr '\n' ' ')"; fi

echo
echo "qrexec-user-normalise-selftest: $pass passed, $fail failed (outputs in $OUT)"
[ "$fail" = 0 ] || exit 1
