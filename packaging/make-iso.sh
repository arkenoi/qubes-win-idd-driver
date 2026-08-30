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

# --- autorun.inf ------------------------------------------------------------------------------
# The ISO carried NO autorun.inf, which is confusing next to the thing it replaces: dom0's
# `qvm-start <vm> --install-windows-tools` attaches the tools CDROM precisely so it can start
# itself, and stock's media does. Ours presented an installer and then sat there.
#
# It is staged into a COPY, never into $SETUP_DIR: that tree ships as its own artifact with a
# SHA256SUMS.txt covering every file, and the verification below re-checks it from inside the ISO.
# Writing an extra file into the source would make those sums fail - correctly - so the ISO gets
# the file and the setup tree stays exactly what it was built as.
#
# It points at qubes-tools-<ver>.exe, the stock-shape entry point already at the root, falling back
# to install.cmd. NOTE what autorun can and cannot do here: AutoRun only launches the target, it
# does NOT elevate. Our installer needs elevation, so the user still gets a UAC prompt - that is
# inherent, not a defect. (Stock has the same shape and worse: its own installer stops with a modal
# telling the user to run `bcdedit /set testsigning on` by hand, because its drivers are signed by a
# private CA. Ours enables testsigning itself in stage 1.)
STAGE="$(mktemp -d)"
trap 'chmod -R u+w "$STAGE" 2>/dev/null; rm -rf "$STAGE"' EXIT
cp -a "$SETUP_DIR/." "$STAGE/"
ENTRY="$(cd "$STAGE" && ls qubes-tools-*.exe 2>/dev/null | head -1)"
[ -n "$ENTRY" ] || ENTRY=install.cmd
# CRLF and plain ASCII: autorun.inf is parsed by the shell's INI reader, which is unforgiving.
printf '[autorun]\r\nopen=%s\r\nicon=%s,0\r\nlabel=Qubes Windows Tools NG\r\n' \
    "$ENTRY" "$ENTRY" > "$STAGE/autorun.inf"
echo "== autorun.inf -> $ENTRY"

echo "== building $OUT_ISO from $SETUP_DIR (volume id $VOLID)"
xorriso -as mkisofs \
    -V "$VOLID" \
    -J -joliet-long \
    -r \
    -o "$OUT_ISO" \
    "$STAGE"

WORK=$(mktemp -d)
trap 'chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

echo "== verifying content (Rock Ridge view)"
xorriso -osirrox on -indev "$OUT_ISO" -extract / "$WORK/rr" >/dev/null 2>&1
chmod -R u+w "$WORK/rr"
# autorun.inf is added by this script and is deliberately NOT in SHA256SUMS.txt (that file
# describes the setup tree artifact). Everything the sums DO cover must still match exactly.
( cd "$WORK/rr" && sha256sum -c SHA256SUMS.txt --quiet )
[ -f "$WORK/rr/autorun.inf" ] || { echo "FATAL: autorun.inf missing from the ISO" >&2; exit 1; }
echo "== all files in the ISO match SHA256SUMS.txt"

echo "== verifying names (Joliet view - this is what Windows sees)"
# Windows mounts the Joliet tree, not Rock Ridge. Checking only the Rock Ridge names would
# not notice a Joliet truncation, and the user is told to run "install.cmd" by name.
xorriso -osirrox on -indev "$OUT_ISO" -joliet on -extract / "$WORK/joliet" >/dev/null 2>&1
chmod -R u+w "$WORK/joliet"
for f in autorun.inf install.cmd Install-QwtImproved.ps1 README.txt MANIFEST.json SHA256SUMS.txt \
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
