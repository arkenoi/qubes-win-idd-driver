#!/usr/bin/env bash
# Cut a QWT-NG release with the version invariants ENFORCED in code, so the bug class that
# shipped TWO releases at one MSI ProductVersion can never recur:
#   - v4.3.0-agent09b643e and v4.3.1-agent09b643e were BOTH built from agent 09b643e
#     (agent/version 4.3.0), so both stamped MSI ProductVersion 4.3.0. A same-ProductVersion
#     MSI is neither a MajorUpgrade nor a reinstall (ProductCode="*" differs per build), so the
#     "v4.3.1" build could not upgrade a 4.3.0 guest at all - it hard-failed at the PV gate.
#   - Earlier, a build from agent 03b1674 (agent/version 4.2.2) stamped 4.2.2 == stock, which
#     forced uninstall-first and bricked a stock upgrade with 0x7B.
# The through-line: the tag moved, the payload version did not. This script makes the tag a
# FUNCTION of the payload version and refuses a non-bumped release, so the two cannot drift.
#
# Usage (run from repo root, AFTER the release-package CI build has produced artifacts):
#     tools/cut-release.sh <artifacts-dir> [--draft]
# <artifacts-dir> holds the release assets incl. MANIFEST.json and SHA256SUMS.txt.
set -euo pipefail

DIR="${1:?usage: tools/cut-release.sh <artifacts-dir> [--draft]}"
DRAFT=""
[ "${2:-}" = "--draft" ] && DRAFT="--draft"

die() { echo "ERROR: $*" >&2; exit 1; }

# --- invariant 1: agent/version is a clean 3-field version (MSI compares only 3 fields) -------
VER="$(tr -d ' \t\r\n' < agent/version)"
[[ "$VER" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "agent/version must be MAJOR.MINOR.PATCH, got '$VER'"

# --- invariant 2: strictly greater than the highest previously released version --------------
git fetch --tags --quiet origin || true
LAST="$(git tag -l 'v*-agent*' | sed -nE 's/^v([0-9]+\.[0-9]+\.[0-9]+)-agent.*/\1/p' | sort -V | tail -1)"
if [ -n "$LAST" ]; then
  # already released this exact version?
  printf '%s\n' "$LAST" | grep -qx "$VER" && die "version $VER was already released (tag exists). Bump agent/version's third field."
  HIGHEST="$(printf '%s\n%s\n' "$LAST" "$VER" | sort -V | tail -1)"
  [ "$HIGHEST" = "$VER" ] || die "agent/version ($VER) is NOT greater than the last release ($LAST). Bump it, do not ship a downgrade or a same-version."
  [ "$VER" = "$LAST" ]    && die "agent/version ($VER) equals the last release ($LAST) - a same-version MSI cannot upgrade it. Bump the third field."
fi

# --- invariant 3: the tag NAME is derived from the version + the agent sha (cannot lie) ------
AGENTSHA="$(git -C agent rev-parse --short=7 HEAD)"
TAG="v${VER}-agent${AGENTSHA}"
git rev-parse -q --verify "refs/tags/${TAG}" >/dev/null 2>&1 && die "tag ${TAG} already exists"

# --- invariant 4: the artifacts' payload version matches the label --------------------------
[ -f "$DIR/MANIFEST.json" ] || die "no MANIFEST.json in $DIR - point at the built artifacts"
PKGVER="$(python3 -c "import json,sys;print(json.load(open('$DIR/MANIFEST.json'))['package_version'].split('+')[0])")"
[ "$PKGVER" = "$VER" ] || die "artifact package_version ($PKGVER) != agent/version ($VER) - payload/label mismatch; rebuild after bumping"
[ -f "$DIR/SHA256SUMS.txt" ] || die "no SHA256SUMS.txt in $DIR"
( cd "$DIR" && sha256sum -c SHA256SUMS.txt >/dev/null ) || die "asset checksums do not verify against SHA256SUMS.txt in $DIR"

echo "All invariants pass. Releasing ${TAG} (MSI ProductVersion ${VER}, agent ${AGENTSHA})."
mapfile -t ASSETS < <(find "$DIR" -maxdepth 1 -type f \( -name '*.iso' -o -name '*.rpm' -o -name '*.tar.gz' -o -name '*.exe' -o -name 'SHA256SUMS.txt' \))
[ "${#ASSETS[@]}" -gt 0 ] || die "no release assets found in $DIR"

# --- notes: prefer the written ones -----------------------------------------------------------
# A release whose notes are a generated one-liner tells the reader nothing about what changed and
# what was actually verified. If docs/RELEASE-NOTES-<version>.md exists, that is the release text.
NOTES_FILE="docs/RELEASE-NOTES-${VER}.md"
if [ -f "$NOTES_FILE" ]; then
  echo "Using $NOTES_FILE as the release notes."
  NOTES_ARG=(--notes-file "$NOTES_FILE")
else
  NOTES_ARG=(--notes "QWT-NG ${VER}. MSI ProductVersion ${VER} — a real bump over the previous release, so an in-place MajorUpgrade lands cleanly on an existing guest (no uninstall, no PV-disk gate, no reboot). See FINDINGS.md and docs/RELEASE-NOTES for details.")
fi

gh release create "$TAG" $DRAFT \
  --title "QWT-NG ${VER} (agent ${AGENTSHA})" \
  "${NOTES_ARG[@]}" \
  "${ASSETS[@]}"
echo "Published ${TAG}."
