#!/bin/bash
# make-iso.sh - wrap a staged qwt-improved-setup directory into an ISO 9660 image that a
# Windows qube can mount as a CD with no networking involved.
#
#   usage: make-iso.sh <setup-dir> <out.iso> [volume-id]
#
# Joliet (-J) so Windows sees the real filenames, Rock Ridge (-r) so a Linux host does
# too. Deliberately NOT bootable: this is a data disc you attach to a running guest.
#
# The image is verified by extracting it back out and re-checking every file against the
# SHA256SUMS.txt the installer itself will verify at install time. An ISO step that only
# checks its own exit code cannot fail in the way that matters (silently mangled or
# truncated payload), and the failure would then surface on the user's machine.
set -euo pipefail

SETUP_DIR=${1:?usage: make-iso.sh <setup-dir> <out.iso> [volume-id]}
OUT_ISO=${2:?usage: make-iso.sh <setup-dir> <out.iso> [volume-id]}
VOLID=${3:-QWT_IMPROVED}

[ -d "$SETUP_DIR" ] || { echo "FATAL: $SETUP_DIR is not a directory" >&2; exit 1; }
[ -f "$SETUP_DIR/SHA256SUMS.txt" ] || { echo "FATAL: $SETUP_DIR/SHA256SUMS.txt missing" >&2; exit 1; }
[ -f "$SETUP_DIR/install.cmd" ] || { echo "FATAL: $SETUP_DIR/install.cmd missing" >&2; exit 1; }
[ -f "$SETUP_DIR/msi/installer.msi" ] || { echo "FATAL: $SETUP_DIR/msi/installer.msi missing" >&2; exit 1; }

command -v xorriso >/dev/null || { echo "FATAL: xorriso not installed" >&2; exit 1; }

echo "== building $OUT_ISO from $SETUP_DIR (volume id $VOLID)"
xorriso -as mkisofs \
    -V "$VOLID" \
    -J -joliet-long \
    -r \
    -o "$OUT_ISO" \
    "$SETUP_DIR"

WORK=$(mktemp -d)
trap 'chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

echo "== verifying content (Rock Ridge view)"
xorriso -osirrox on -indev "$OUT_ISO" -extract / "$WORK/rr" >/dev/null 2>&1
chmod -R u+w "$WORK/rr"
( cd "$WORK/rr" && sha256sum -c SHA256SUMS.txt --quiet )
echo "== all files in the ISO match SHA256SUMS.txt"

echo "== verifying names (Joliet view - this is what Windows sees)"
# Windows mounts the Joliet tree, not Rock Ridge. Checking only the Rock Ridge names would
# not notice a Joliet truncation, and the user is told to run "install.cmd" by name.
xorriso -osirrox on -indev "$OUT_ISO" -joliet on -extract / "$WORK/joliet" >/dev/null 2>&1
chmod -R u+w "$WORK/joliet"
for f in install.cmd Install-QwtImproved.ps1 README.txt MANIFEST.json SHA256SUMS.txt \
         msi/installer.msi msi/vc_redist.x64.exe; do
    [ -f "$WORK/joliet/$f" ] || {
        echo "FATAL: '$f' is not present in the ISO's Joliet tree under that exact name" >&2
        echo "Joliet tree was:" >&2
        ( cd "$WORK/joliet" && find . -type f | sort ) >&2
        exit 1
    }
done
# The Joliet copy must also be byte-identical, not merely present.
( cd "$WORK/joliet" && sha256sum -c SHA256SUMS.txt --quiet )
echo "== entry points present and intact under their Joliet names"

ls -l "$OUT_ISO"
sha256sum "$OUT_ISO"
