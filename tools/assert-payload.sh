#!/bin/bash
# MANDATORY GATE: prove a payload is the build you intend BEFORE it touches a guest.
#
# WHY THIS EXISTS. On 2026-08-29 I ran a whole acceptance cell against a payload built from
# `f777bec` — the commit BEFORE the fix under test — and graded the result as if it meant something.
# The guest's own log named the package in its first line and I did not read it. That is not a slip,
# it is an acceptance-protocol breach: the artefact under test was never verified, so every number
# the cell produced was about a different build. It cost a 29-minute reprovision and a void cell.
#
# The rule already existed ("verify the artefact under test is actually installed"). What was missing
# was something that makes ignoring it impossible. This is that thing: it FAILS CLOSED, and it is
# cheap enough (a few seconds, no guest) that there is no excuse to skip it.
#
# Usage:
#   tools/assert-payload.sh <payload-dir-or-tar> [expected-commit-ish]
#
# With no expected commit it asserts against the CURRENT HEAD, which is what you almost always want:
# you are testing what you just built. Pass an explicit sha to test an older build deliberately.
#
# Checks, in order, all fail-closed:
#   1. the payload exists and carries MANIFEST.json + SHA256SUMS.txt
#   2. every file matches SHA256SUMS.txt (a truncated push is caught here, not on the guest)
#   3. MANIFEST.json's driver_repo_commit matches the expected commit
#   4. the staged Install-QwtImproved.ps1 is byte-identical to the repo's at that commit
set -uo pipefail

SRC="${1:?usage: $0 <payload-dir-or-tar> [expected-commit-ish]}"
WANT_REF="${2:-HEAD}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WANT=$(cd "$REPO" && git rev-parse "$WANT_REF" 2>/dev/null) || { echo "FAIL: cannot resolve '$WANT_REF'"; exit 2; }

TMP=""
cleanup(){ [ -n "$TMP" ] && rm -rf "$TMP"; }
trap cleanup EXIT

DIR="$SRC"
if [ -f "$SRC" ]; then
	TMP=$(mktemp -d); DIR="$TMP/x"; mkdir -p "$DIR"
	tar -xzf "$SRC" -C "$DIR" 2>/dev/null || { echo "FAIL: cannot extract $SRC"; exit 2; }
fi
[ -d "$DIR" ] || { echo "FAIL: $SRC is not a directory or tarball"; exit 2; }

for f in MANIFEST.json SHA256SUMS.txt Install-QwtImproved.ps1; do
	[ -f "$DIR/$f" ] || { echo "FAIL: payload has no $f"; exit 1; }
done

# 2. content integrity. CRLF in the manifest is normal (it is generated on Windows).
bad=0; n=0
while read -r h f; do
	n=$((n+1))
	if [ ! -f "$DIR/$f" ]; then echo "  MISSING $f"; bad=$((bad+1)); continue; fi
	a=$(sha256sum "$DIR/$f" | cut -d' ' -f1)
	[ "$a" = "$h" ] || { echo "  MISMATCH $f"; bad=$((bad+1)); }
done < <(tr -d '\r' < "$DIR/SHA256SUMS.txt")
[ "$bad" -eq 0 ] || { echo "FAIL: $bad of $n payload files do not match SHA256SUMS.txt"; exit 1; }
# ZERO FILES VERIFIED IS NOT AN INTEGRITY PASS. With an empty or unparseable SHA256SUMS.txt this
# loop ran zero iterations, bad=0 and n=0, and the script fell through to
# "PASS: payload verified - 0 files", which all three consumers (matrix.sh, quick-upgrade.sh,
# verify-release-package.sh) read as a clean exit 0. A campaign then proceeded against a payload
# whose content nothing had hashed, with a log line identical to a real pass.
# The floor is 3 because the three files asserted present above are themselves in SHA256SUMS.txt;
# a manifest listing fewer than that is malformed, not minimal.
if [ "$n" -lt 3 ]; then
	echo "FAIL: SHA256SUMS.txt yielded only $n file(s) - nothing was verified"
	echo "      An empty or unparseable manifest is a packaging defect, and a payload whose"
	echo "      content was never hashed must not read the same as one that was."
	exit 1
fi

# 3. provenance
GOT=$(python3 -c "
import json,sys
d=json.load(open('$DIR/MANIFEST.json'))
print((d.get('source') or {}).get('driver_repo_commit') or '')" 2>/dev/null)
[ -n "$GOT" ] || { echo "FAIL: MANIFEST.json has no source.driver_repo_commit"; exit 1; }
if [ "${GOT:0:12}" != "${WANT:0:12}" ]; then
	echo "FAIL: payload was built from ${GOT:0:12}, expected ${WANT:0:12} ($WANT_REF)"
	echo "      This is the breach that voided a cell on 2026-08-29. Rebuild or pass the sha you mean."
	exit 1
fi

# 4. the installer actually shipped is the one in the repo at that commit (CRLF-normalised: the
#    packaging step converts line endings, so compare content, not bytes-on-disk).
# A CHECK THAT DID NOT RUN IS NOT A CHECK THAT PASSED. This `if` had no else, and the PASS line
# below - which says "installer matches repo" in so many words - printed either way. So a WANT_REF
# resolving to a commit where that path does not exist (an older sha, a tag cut before the file was
# added, a truncated fetch) skipped the comparison and produced the exact text of a real match,
# which is all four call sites read: quick-upgrade.sh, matrix.sh twice, and
# tools/verify-release-package.sh. Scored 0.69 as a campaign-stopper by the tier re-check,
# 2026-10-21 - from the same file whose zero-files floor was fixed that morning, nine lines away.
# Missing data fails, as it does in check 1 and check 3 above.
if ! (cd "$REPO" && git cat-file -e "$WANT:packaging/setup/Install-QwtImproved.ps1" 2>/dev/null); then
	echo "FAIL: packaging/setup/Install-QwtImproved.ps1 does not exist at ${WANT:0:12} ($WANT_REF),"
	echo "      so the staged installer could not be compared against the repo. This is the check"
	echo "      that would catch a hand-edited installer - it cannot be skipped into a PASS."
	exit 1
fi
rs=$(cd "$REPO" && git show "$WANT:packaging/setup/Install-QwtImproved.ps1" | tr -d '\r' | sha256sum | cut -d' ' -f1)
ps=$(tr -d '\r' < "$DIR/Install-QwtImproved.ps1" | sha256sum | cut -d' ' -f1)
[ "$rs" = "$ps" ] || { echo "FAIL: staged Install-QwtImproved.ps1 differs from the repo at ${WANT:0:12}"; exit 1; }

echo "PASS: payload verified — $n files, built from ${GOT:0:12} ($WANT_REF), installer matches repo"
exit 0
