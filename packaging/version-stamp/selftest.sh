#!/bin/bash
# selftest.sh - fail-proofs for the version stampers, runnable from the dev qube (pwsh, no Windows).
#
# WHY. Repo rule: a check counts as evidence only once it has been seen to FAIL with the defect
# re-introduced. The stamper is the first link of the chain the release verifier hangs off (every
# OURS binary reads FILEVERSION == <ver>.<rev>), so a stamper that "always succeeds" would make every
# later gate pass for the wrong reason. Each case below feeds a defective input and demands the exact
# failure code; a case that passes when it should fail, or fails with a different code, fails this
# script. The last section proves the selftest ITSELF can fail: two stampers patched to re-introduce
# a defect (CI rev defaulting to 0; non-throwing INF decoder) must be caught by the case written for
# that defect, or this script fails.
#
# Every failure code the two scripts can emit has a case here (BAD_VERSION_FILE, MISSING_BUILD_REV,
# USAGE, BAD_FILEDESCRIPTION; INF_MISSING, INF_DRIVERVER_COUNT, BAD_DATE, INF_ENCODING,
# STAMPER_MISSING). The MSBuild <Error> tasks in the two .props files are NOT covered - they need a
# Windows build and are recorded as unproven in README.md.
#
# Exit 0 iff every case behaves. Exit 3 when no pwsh is available: "did not check" is not a pass and
# must never read as one (same convention as tools/ps-parse-gate.sh).
#
# Bash traps deliberately avoided (this project has paid for each): no `producer | grep -q` under
# pipefail (grep -q exits early and the producer's SIGPIPE inverts a match) - producer output is
# captured into a variable first; no `grep -q file` in a pass branch where a MISSING file (rc 2) would
# fall into the pass side - every header is asserted to exist before its content is inspected.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
STAMP="$REPO/tools/stamp-version.ps1"
INFSTAMP="$HERE/stamp-inf-driverver.ps1"

PWSH="${PWSH:-}"
if [ -z "$PWSH" ]; then
	for cand in /home/user/pwsh/pwsh /home/user/pwsh74/pwsh; do
		if [ -x "$cand" ]; then PWSH="$cand"; break; fi
	done
fi
if [ -z "$PWSH" ]; then PWSH="$(command -v pwsh 2>/dev/null || true)"; fi
if [ -z "$PWSH" ] || [ ! -x "$PWSH" ]; then
	echo "version-stamp selftest: no pwsh found (set PWSH=/path/to/pwsh) - NOT CHECKED" >&2
	exit 3
fi
for tool in iconv cmp od; do
	if ! command -v "$tool" >/dev/null 2>&1; then
		echo "version-stamp selftest: need $tool - NOT CHECKED" >&2
		exit 3
	fi
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/version-stamp-selftest.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
fails=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1: $2"; fails=$((fails + 1)); }

# probe <expect-code|OK> <name> [env K=V ...] -- <pwsh -File args...>
# Runs a stamper with a scrubbed environment (no inherited GITHUB_ACTIONS / QWTNG_BUILD_REV, so a CI
# shell running this cannot make a "local" case behave like CI). Returns 0 iff the outcome is the
# expected one; PROBE_OUT holds the combined output, PROBE_WHY the reason on mismatch. It is a
# predicate (not a reporter) so the mutation section can demand the OPPOSITE outcome from it.
PROBE_OUT=''
PROBE_WHY=''
probe() {
	local expect="$1"; shift
	shift # name: for the caller's report only
	local envs=()
	while [ "$1" != "--" ]; do envs+=("$1"); shift; done
	shift
	local out rc
	out="$(env -u GITHUB_ACTIONS -u QWTNG_BUILD_REV "${envs[@]}" "$PWSH" -NoProfile -File "$@" 2>&1)"
	rc=$?
	PROBE_OUT="$out"
	PROBE_WHY=''
	if [ "$expect" = OK ]; then
		if [ $rc -eq 0 ]; then return 0; fi
		PROBE_WHY="expected success, rc=$rc: $out"
		return 1
	fi
	if [ $rc -eq 0 ]; then
		PROBE_WHY="expected code=$expect but the stamper SUCCEEDED: $out"
		return 1
	fi
	# every Fail line is "<tool>: FAIL code=<CODE> <detail>" - the code is followed by a space
	case "$out" in
	*"FAIL code=$expect "*) return 0 ;;
	esac
	PROBE_WHY="expected code=$expect, got: $out"
	return 1
}
# run: probe + report
LAST_OUT=''
run() {
	local name="$2"
	if probe "$@"; then pass "$name"; else fail "$name" "$PROBE_WHY"; fi
	LAST_OUT="$PROBE_OUT"
}
# has <file> <fixed-string>: 0 iff the file exists AND contains the string (a missing file is 1)
has() { [ -f "$1" ] && grep -F -- "$2" "$1" >/dev/null; }
# lacks <file> <fixed-string>: 0 iff the file exists AND does NOT contain the string (missing = 1)
lacks() { [ -f "$1" ] && ! grep -F -- "$2" "$1" >/dev/null; }

printf '4.3.21\n' >"$WORK/version"          # trailing newline on purpose: the real file has one
printf '4.3.21.0\n' >"$WORK/version4"
printf '4.3\n' >"$WORK/version2"
printf '4.3.70000\n' >"$WORK/versionbig"
printf '' >"$WORK/versionempty"

# --- the happy path, asserted line by line (the mapping MAJOR,MINOR,PATCH,BUILD_REV) -------------
H1="$WORK/h1/qwtng_version.h"
run OK "stamp: 4.3.21 + rev 517" QWTNG_BUILD_REV=517 -- "$STAMP" "$WORK/version" "$H1" "Selftest binary"
if [ -f "$H1" ]; then pass "header written"; else fail "header written" "$H1 does not exist after a successful run"; fi
for want in \
	'#define QWT_FILEVERSION 4,3,21,517' \
	'#define QWT_FILEVERSION_STR "4.3.21.517"' \
	'#define QWT_PRODUCTVERSION QWT_FILEVERSION' \
	'#define QWT_PRODUCTVERSION_STR QWT_FILEVERSION_STR' \
	'#define QWTNG_RELEASE_STR "4.3.21"' \
	'#define QWTNG_BUILD_REV 517' \
	'#define QIDD_VER_MAJOR 4' \
	'#define QIDD_VER_MINOR 3' \
	'#define QIDD_VER_BUILD 21' \
	'#define QIDD_VER_REV   517' \
	'#define QIDD_VER_STR   "4.3.21.517"' \
	'#define QWT_FILEDESCRIPTION_STR "Selftest binary"'; do
	if has "$H1" "$want"; then pass "header has: $want"; else fail "header line" "missing: $want"; fi
done
# CRLF + ASCII, because rc.exe consumes it. Both tests require the file to exist.
if [ -f "$H1" ]; then
	crlf="$(grep -c $'\r$' "$H1")"; total="$(wc -l <"$H1")"
	if [ -n "$crlf" ] && [ "$crlf" = "$total" ] && [ "$total" -gt 0 ]; then pass "header is CRLF ($total lines)"; else fail "header CRLF" "crlf=$crlf total=$total"; fi
	if LC_ALL=C grep '[^ -~[:space:]]' "$H1" >/dev/null; then fail "header ASCII" "non-ASCII byte present"; else pass "header is ASCII"; fi
else
	fail "header CRLF" "no header"; fail "header ASCII" "no header"
fi
# the header must be a pure function of its inputs: no source/timestamp/path in it
if [ -f "$H1" ] && ! grep -E 'env QWTNG_BUILD_REV|parameter -BuildRev|local default' "$H1" >/dev/null; then pass "header names no rev source"; else fail "header purity" "rev source leaked into the header (breaks the unchanged-content rule)"; fi
# no per-project description -> no QWT_FILEDESCRIPTION_STR (the project's own version.rc defines it)
H2="$WORK/h2/qwt_version.h"
run OK "stamp: without description" QWTNG_BUILD_REV=517 -- "$STAMP" "$WORK/version" "$H2"
if lacks "$H2" QWT_FILEDESCRIPTION_STR; then pass "no-description header exists and omits QWT_FILEDESCRIPTION_STR"; else fail "no-description header" "missing, or defines QWT_FILEDESCRIPTION_STR"; fi

# --- idempotence: an unchanged version must not rewrite the header (incremental builds) ----------
touch -d '2020-01-01 00:00:00' "$H1"
before="$(stat -c %Y "$H1")"
run OK "stamp: rerun same inputs" QWTNG_BUILD_REV=517 -- "$STAMP" "$WORK/version" "$H1" "Selftest binary"
after="$(stat -c %Y "$H1")"
if [ "$before" = "$after" ]; then pass "unchanged header left untouched"; else fail "idempotence" "header rewritten with identical content"; fi
# ...even when the same rev arrives from a different source (-BuildRev vs env): identical bytes
run OK "stamp: rerun same rev via -BuildRev" -- "$STAMP" "$WORK/version" "$H1" "Selftest binary" -BuildRev 517
after2="$(stat -c %Y "$H1")"
if [ "$before" = "$after2" ]; then pass "same rev from another source leaves the header untouched"; else fail "idempotence across rev sources" "header rewritten when only the rev SOURCE changed"; fi
run OK "stamp: rerun new rev" QWTNG_BUILD_REV=518 -- "$STAMP" "$WORK/version" "$H1" "Selftest binary"
if has "$H1" '#define QWT_FILEVERSION 4,3,21,518'; then pass "new rev rewrites header"; else fail "rev change" "header not updated to 518"; fi

# --- relative paths: PowerShell $PWD and the process cwd differ inside a Set-Location caller ------
# Test-Path/Get-Content follow $PWD; System.IO.File follows the PROCESS cwd. The stamper resolves
# every path once against $PWD, so this must write $WORK/sub/rel/h.h and nothing under $WORK/other.
mkdir -p "$WORK/sub" "$WORK/other"
cp "$WORK/version" "$WORK/sub/version"
printf '9.9.9\n' >"$WORK/other/version"       # a decoy: reading from the process cwd would find THIS
relout="$(cd "$WORK/other" && env -u GITHUB_ACTIONS QWTNG_BUILD_REV=7 "$PWSH" -NoProfile -Command "Set-Location -LiteralPath '$WORK/sub'; & '$STAMP' version rel/h.h 'Relative caller'" 2>&1)"
relrc=$?
if [ $relrc -eq 0 ] && has "$WORK/sub/rel/h.h" '#define QWT_FILEVERSION 4,3,21,7' && [ ! -e "$WORK/other/rel" ]; then
	pass "relative paths resolve against the caller's \$PWD, not the process cwd"
else
	fail "relative paths" "rc=$relrc sub/rel/h.h=$([ -f "$WORK/sub/rel/h.h" ] && echo present || echo absent) other/rel=$([ -e "$WORK/other/rel" ] && echo CREATED || echo absent): $relout"
fi

# --- -Print: the single resolver the INF stamper and workflows use --------------------------------
run OK "print" QWTNG_BUILD_REV=517 -- "$STAMP" "$WORK/version" -Print
if [ "$(tail -n1 <<<"$LAST_OUT")" = "4.3.21.517" ]; then pass "-Print resolves 4.3.21.517"; else fail "-Print" "got '$LAST_OUT'"; fi

# --- version file defects: BAD_VERSION_FILE ------------------------------------------------------
run BAD_VERSION_FILE "4-field version file"        QWTNG_BUILD_REV=1 -- "$STAMP" "$WORK/version4"     "$WORK/x/h"
run BAD_VERSION_FILE "2-field version file"        QWTNG_BUILD_REV=1 -- "$STAMP" "$WORK/version2"     "$WORK/x/h"
run BAD_VERSION_FILE "field over 65535"            QWTNG_BUILD_REV=1 -- "$STAMP" "$WORK/versionbig"   "$WORK/x/h"
run BAD_VERSION_FILE "empty version file"          QWTNG_BUILD_REV=1 -- "$STAMP" "$WORK/versionempty" "$WORK/x/h"
run BAD_VERSION_FILE "missing version file"        QWTNG_BUILD_REV=1 -- "$STAMP" "$WORK/nonexistent"  "$WORK/x/h"
if [ -e "$WORK/x/h" ]; then fail "no header on failure" "a header was written despite BAD_VERSION_FILE"; else pass "no header written on BAD_VERSION_FILE"; fi

# --- build revision defects: MISSING_BUILD_REV ---------------------------------------------------
run MISSING_BUILD_REV "CI with QWTNG_BUILD_REV unset"   GITHUB_ACTIONS=true                      -- "$STAMP" "$WORK/version" "$WORK/y/h"
run MISSING_BUILD_REV "CI with QWTNG_BUILD_REV empty"   GITHUB_ACTIONS=true QWTNG_BUILD_REV=     -- "$STAMP" "$WORK/version" "$WORK/y/h"
run MISSING_BUILD_REV "rev over 65535"                  GITHUB_ACTIONS=true QWTNG_BUILD_REV=70000 -- "$STAMP" "$WORK/version" "$WORK/y/h"
run MISSING_BUILD_REV "rev non-integer"                 GITHUB_ACTIONS=true QWTNG_BUILD_REV=abc   -- "$STAMP" "$WORK/version" "$WORK/y/h"
run MISSING_BUILD_REV "rev negative"                    GITHUB_ACTIONS=true QWTNG_BUILD_REV=-1    -- "$STAMP" "$WORK/version" "$WORK/y/h"
# a set-but-bad value is refused OUTSIDE CI too (broken plumbing is never the local default)
run MISSING_BUILD_REV "local with garbage rev"          QWTNG_BUILD_REV=abc                       -- "$STAMP" "$WORK/version" "$WORK/y/h"
if [ -e "$WORK/y/h" ]; then fail "no header on failure" "a header was written despite MISSING_BUILD_REV"; else pass "no header written on MISSING_BUILD_REV"; fi
# local default: rev 0 WITH a warning, and the header says so
run OK "local build, no rev -> 0 + warning" -- "$STAMP" "$WORK/version" "$WORK/z/h"
if grep -i 'WARNING' <<<"$LAST_OUT" >/dev/null && has "$WORK/z/h" '#define QWT_FILEVERSION 4,3,21,0'; then pass "local default is 0 and warns"; else fail "local default" "$LAST_OUT"; fi
# the dev-overlay contract: build.yml sets 0 EXPLICITLY in CI - accepted, stamps .0, no warning
run OK "CI with explicit rev 0 (dev overlay)" GITHUB_ACTIONS=true QWTNG_BUILD_REV=0 -- "$STAMP" "$WORK/version" "$WORK/z0/h"
if has "$WORK/z0/h" '#define QWT_FILEVERSION 4,3,21,0' && ! grep -i 'WARNING' <<<"$LAST_OUT" >/dev/null; then pass "explicit 0 in CI stamps .0 without a warning"; else fail "explicit 0 in CI" "$LAST_OUT"; fi
# explicit -BuildRev beats the environment
run OK "-BuildRev beats env" QWTNG_BUILD_REV=1 -- "$STAMP" "$WORK/version" "$WORK/w/h" -BuildRev 42
if has "$WORK/w/h" '#define QWT_FILEVERSION 4,3,21,42'; then pass "-BuildRev wins"; else fail "-BuildRev" "env value stamped instead"; fi

# --- caller defects ------------------------------------------------------------------------------
run USAGE "no arguments"                       -- "$STAMP"
run USAGE "no header"      QWTNG_BUILD_REV=1   -- "$STAMP" "$WORK/version"
run BAD_FILEDESCRIPTION "description with a quote"     QWTNG_BUILD_REV=1 -- "$STAMP" "$WORK/version" "$WORK/v/h" 'bad "quoted" name'
run BAD_FILEDESCRIPTION "description with a backslash" QWTNG_BUILD_REV=1 -- "$STAMP" "$WORK/version" "$WORK/v/h" 'bad\name'
desc120="$(head -c 120 </dev/zero | tr '\0' a)"
run BAD_FILEDESCRIPTION "description of 121 chars"     QWTNG_BUILD_REV=1 -- "$STAMP" "$WORK/version" "$WORK/v/h" "${desc120}a"
if [ -e "$WORK/v/h" ]; then fail "no header on failure" "a header was written despite BAD_FILEDESCRIPTION"; else pass "no header written on BAD_FILEDESCRIPTION"; fi
run OK "description of exactly 120 chars"              QWTNG_BUILD_REV=1 -- "$STAMP" "$WORK/version" "$WORK/v120/h" "$desc120"
if has "$WORK/v120/h" "#define QWT_FILEDESCRIPTION_STR \"$desc120\""; then pass "120-char description accepted verbatim"; else fail "120-char description" "not stamped"; fi

# --- INF DriverVer stamper -----------------------------------------------------------------------
# mkinf <path> <encoding> <driverver-line-count> [<driverver-line>] [<extra-raw-bytes-line>]
# Builds an INF from parts so an EXPECTED post-stamp file can be constructed independently of the
# stamper (same parts, the stamped DriverVer line) and byte-compared with cmp - the proof that no
# byte outside the DriverVer line changed, BOM and line endings included.
mkinf() {
	local path="$1" enc="$2" count="$3" line="${4:-DriverVer = 01/01/2000,1.0.0.0}" extra="${5:-}"
	local body=$'[Version]\r\nSignature="$WINDOWS NT$"\r\nClass=Display\r\n'
	local i
	for ((i = 0; i < count; i++)); do body+="$line"$'\r\n'; done
	body+=$'Provider=%ManufacturerName%\r\n'
	if [ -n "$extra" ]; then body+="$extra"$'\r\n'; fi
	case "$enc" in
	utf16)
		{ printf '\xff\xfe'; printf '%s' "$body" | iconv -f UTF-8 -t UTF-16LE; } >"$path" ;;
	utf8bom) printf '\xef\xbb\xbf%s' "$body" >"$path" ;;
	utf8) printf '%s' "$body" >"$path" ;;
	esac
}
NEWLINE='DriverVer = 09/09/2026,4.3.21.517'
# infcase <name> <encoding> [<extra-line>]: stamp, then byte-compare with the independent expectation
infcase() {
	local name="$1" enc="$2" extra="${3:-}"
	local f="$WORK/inf-$name.inf" want="$WORK/inf-$name.want"
	mkinf "$f" "$enc" 1 'DriverVer = 01/01/2000,1.0.0.0' "$extra"
	mkinf "$want" "$enc" 1 "$NEWLINE" "$extra"
	run OK "inf: $name stamp" QWTNG_BUILD_REV=517 -- "$INFSTAMP" -Inf "$f" -VersionFile "$WORK/version" -Date 09/09/2026
	if cmp -s "$f" "$want"; then
		pass "inf: $name byte-identical to expectation (only the DriverVer line changed; BOM/CRLF/encoding kept)"
	else
		fail "inf: $name bytes" "stamped file differs from expectation outside the DriverVer line: $(cmp "$f" "$want" 2>&1 | head -1)"
	fi
}
infcase utf16 utf16
infcase utf8bom utf8bom
infcase ascii utf8
infcase utf8-multibyte utf8 $'LegalCopyright="\xc2\xa9 2026 valid UTF-8"'
# default date: today's, in mm/dd/yyyy
mkinf "$WORK/today.inf" utf8 1
run OK "inf: default date" QWTNG_BUILD_REV=517 -- "$INFSTAMP" -Inf "$WORK/today.inf" -VersionFile "$WORK/version"
todaypat=$'^DriverVer = [0-9]{2}/[0-9]{2}/[0-9]{4},4[.]3[.]21[.]517\r$'   # literal CR: grep -E has no \r
todayline="$(grep -E "$todaypat" "$WORK/today.inf")"
if [ -n "$todayline" ]; then pass "inf: default date is mm/dd/yyyy + version"; else fail "inf: default date" "$(grep DriverVer "$WORK/today.inf")"; fi

# INF_ENCODING: a BOM-less INF with a Latin-1 byte (0xA9) is refused and left byte-for-byte alone.
# (Before this code existed the decoder substituted U+FFFD and wrote EF BF BD back while the
# DriverVer line passed every check - a silently re-encoded .cat input.)
mkinf "$WORK/latin1.inf" utf8 1 'DriverVer = 01/01/2000,1.0.0.0' $'LegalCopyright="\xa9 2026 Latin-1"'
cp "$WORK/latin1.inf" "$WORK/latin1.orig"
run INF_ENCODING "inf: BOM-less INF with a Latin-1 byte" QWTNG_BUILD_REV=517 -- "$INFSTAMP" -Inf "$WORK/latin1.inf" -VersionFile "$WORK/version" -Date 09/09/2026
if cmp -s "$WORK/latin1.inf" "$WORK/latin1.orig"; then pass "inf: refused INF left byte-identical"; else fail "inf: refused INF" "bytes changed despite INF_ENCODING"; fi
# the same bytes inside a UTF-16 file are fine: U+00A9 is a valid code unit there
infcase utf16-copyright utf16 $'LegalCopyright="\xc2\xa9 2026"'

# count / date / missing / generator-missing
mkinf "$WORK/none.inf" utf16 0
run INF_DRIVERVER_COUNT "inf: no DriverVer line"  QWTNG_BUILD_REV=517 -- "$INFSTAMP" -Inf "$WORK/none.inf" -VersionFile "$WORK/version"
mkinf "$WORK/two.inf" utf16 2
run INF_DRIVERVER_COUNT "inf: two DriverVer lines" QWTNG_BUILD_REV=517 -- "$INFSTAMP" -Inf "$WORK/two.inf" -VersionFile "$WORK/version"
cp "$WORK/inf-utf16.inf" "$WORK/pristine.inf"; cp "$WORK/pristine.inf" "$WORK/pristine.orig"
run BAD_DATE            "inf: bad date"            QWTNG_BUILD_REV=517 -- "$INFSTAMP" -Inf "$WORK/pristine.inf" -VersionFile "$WORK/version" -Date 2026-09-09
run INF_MISSING         "inf: missing file"        QWTNG_BUILD_REV=517 -- "$INFSTAMP" -Inf "$WORK/nope.inf" -VersionFile "$WORK/version"
# the generator's own codes propagate through the INF stamper unchanged
run MISSING_BUILD_REV   "inf: CI without rev"      GITHUB_ACTIONS=true  -- "$INFSTAMP" -Inf "$WORK/pristine.inf" -VersionFile "$WORK/version"
run BAD_VERSION_FILE    "inf: 4-field version"     QWTNG_BUILD_REV=517 -- "$INFSTAMP" -Inf "$WORK/pristine.inf" -VersionFile "$WORK/version4"
if cmp -s "$WORK/pristine.inf" "$WORK/pristine.orig"; then pass "inf: failing cases never touch the INF"; else fail "inf: failing cases" "the INF was modified by a failing run"; fi
# STAMPER_MISSING: the INF stamper resolves ../../tools/stamp-version.ps1 from its own location
mkdir -p "$WORK/isolated/a/b"
cp "$INFSTAMP" "$WORK/isolated/a/b/stamp-inf-driverver.ps1"
run STAMPER_MISSING     "inf: generator not reachable from the script's location" QWTNG_BUILD_REV=517 -- "$WORK/isolated/a/b/stamp-inf-driverver.ps1" -Inf "$WORK/pristine.inf" -VersionFile "$WORK/version"

# --- mutation proofs: the selftest must be able to FAIL --------------------------------------------
# 1. A stamper that quietly defaults the CI build rev to 0 (the defect MISSING_BUILD_REV exists for)
#    must be caught by the "CI with rev unset" case. If the patch anchor no longer matches, that is a
#    failure too: it would mean this proof silently stopped proving anything.
mkdir -p "$WORK/mut1" "$WORK/mut2"
MUT1="$WORK/mut1/stamp-version.ps1"
sed 's/if (\$inCi) {/if ($false) {/' "$STAMP" >"$MUT1"
if cmp -s "$STAMP" "$MUT1"; then
	fail "mutation 1 anchor" "'if (\$inCi) {' not found in stamp-version.ps1 - the CI-default mutation can no longer be constructed"
elif probe MISSING_BUILD_REV "mutant" GITHUB_ACTIONS=true -- "$MUT1" "$WORK/version" "$WORK/mut1/h"; then
	fail "mutation 1" "a stamper that defaults the CI build rev to 0 PASSED the 'CI with rev unset' case - the case proves nothing"
else
	pass "mutation 1: CI-default-to-0 stamper is caught by the 'CI with rev unset' case"
fi
# 2. An INF stamper whose BOM-less decoder does not throw (the U+FFFD rewrite defect) must be caught
#    by the Latin-1 case. The mutant needs a reachable generator, so it is placed two levels below a
#    dir that has tools/stamp-version.ps1.
mkdir -p "$WORK/mut2/tools" "$WORK/mut2/p/v"
cp "$STAMP" "$WORK/mut2/tools/stamp-version.ps1"
MUT2="$WORK/mut2/p/v/stamp-inf-driverver.ps1"
sed 's/System\.Text\.UTF8Encoding(\$false, \$true)/System.Text.UTF8Encoding($false, $false)/' "$INFSTAMP" >"$MUT2"
if cmp -s "$INFSTAMP" "$MUT2"; then
	fail "mutation 2 anchor" "'UTF8Encoding(\$false, \$true)' not found in stamp-inf-driverver.ps1 - the lenient-decoder mutation can no longer be constructed"
else
	cp "$WORK/latin1.orig" "$WORK/mut2/latin1.inf"
	if probe INF_ENCODING "mutant" QWTNG_BUILD_REV=517 -- "$MUT2" -Inf "$WORK/mut2/latin1.inf" -VersionFile "$WORK/version" -Date 09/09/2026; then
		fail "mutation 2" "an INF stamper with a non-throwing decoder PASSED the Latin-1 case - the case proves nothing"
	else
		pass "mutation 2: lenient-decoder INF stamper is caught by the Latin-1 case"
	fi
fi

echo
if [ $fails -eq 0 ]; then
	echo "version-stamp selftest: ALL PASS"
	exit 0
fi
echo "version-stamp selftest: $fails FAILED"
exit 1
