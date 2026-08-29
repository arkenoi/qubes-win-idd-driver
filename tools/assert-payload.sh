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
if (cd "$REPO" && git cat-file -e "$WANT:packaging/setup/Install-QwtImproved.ps1" 2>/dev/null); then
	rs=$(cd "$REPO" && git show "$WANT:packaging/setup/Install-QwtImproved.ps1" | tr -d '\r' | sha256sum | cut -d' ' -f1)
	ps=$(tr -d '\r' < "$DIR/Install-QwtImproved.ps1" | sha256sum | cut -d' ' -f1)
	[ "$rs" = "$ps" ] || { echo "FAIL: staged Install-QwtImproved.ps1 differs from the repo at ${WANT:0:12}"; exit 1; }
fi

echo "PASS: payload verified — $n files, built from ${GOT:0:12} ($WANT_REF), installer matches repo"
exit 0
