#!/bin/bash
# Build a TINY second CD carrying autounattend.xml + \payload, so the Windows ISO itself
# can stay byte-for-byte STOCK.
#
# WHY THIS EXISTS (user question, 2026-08-06: "is there no way to make it a virtual
# removable drive?"): Windows Setup searches the root of every removable drive for
# autounattend.xml, and a virtual CD-ROM counts. Qubes exposes block devices as fixed
# disks by default, but `--option devtype=cdrom` makes the frontend a CD-ROM, which
# Setup does scan. So: CD 1 = untouched vendor ISO (boot device), CD 2 = this image.
#
# The repack route (build-unattended-iso.sh) stays supported and is what every result so
# far was produced with. This one buys two things: the install media is provably
# unmodified, and rebuilding the payload costs seconds instead of ~10 min of 7z+xorriso
# over a 6 GiB image.
#
# THE CATCH, and how it is handled. On the repacked image the payload reaches C:\payload
# via sources\$OEM$\$1\payload, which Setup copies while applying the image. A stock ISO
# has no $OEM$ and we may not add one, so the payload has to still be REACHABLE at first
# logon. A Qubes guest reboot destroys the domain and `qvm-start --cdrom` assignment does
# not survive it - hence the answer disc must be attached PERSISTENTLY:
#
#   qvm-device block attach --persistent --option devtype=cdrom --ro \
#       <vm> win-idd-mgmt:<loopN>
#
# With that, the disc is present at every boot including first logon, and the drive-letter
# scan already in autounattend.xml FirstLogonCommands ("for %d in (D E F ...) do if exist
# %d:\payload\setup.cmd") finds it. No answer-file change is needed.
#
# Usage: ./build-answer-disc.sh [image-name]
#   env: RELEASE_SETUP=<dir>  stage our release package and install it at firstboot
#        UNATTEND=<file>      answer file (default mgmt/autounattend.xml)
#        OUT=<iso>            output path
set -euo pipefail

IMG_NAME="${1:-Windows 10 Pro}"
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${OUT:-$HOME/win-iso/win-idd-answer.iso}"
UNATTEND="${UNATTEND:-$HERE/autounattend.xml}"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/answer-disc.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

command -v xorriso >/dev/null || { echo "need xorriso" >&2; exit 1; }

# Same media-language rule as build-unattended-iso.sh: an answer file whose language does
# not match the media is silently ignored by Setup. Here the media is not ours to inspect,
# so LOCALE must be given (defaulting to en-US would silently reproduce the bug on
# English-International media).
LOCALE="${LOCALE:-en-US}"
case "$LOCALE" in
    en-GB) KBD="${KEYBOARD:-0809:00000809}" ;;
    en-US) KBD="${KEYBOARD:-0409:00000409}" ;;
    *)     KBD="${KEYBOARD:?set KEYBOARD=<id> for LOCALE=$LOCALE}" ;;
esac
echo "answer-file locale: $LOCALE (input $KBD) - MUST match the Windows media on CD 1"
sed -e "s/@IMAGE_NAME@/$IMG_NAME/" -e "s/@UILANG@/$LOCALE/g" -e "s/@INPUTLOCALE@/$KBD/g" \
    "$UNATTEND" > "$WORK/autounattend.xml"
if grep -q '@[A-Z_]*@' "$WORK/autounattend.xml"; then
    echo "unsubstituted placeholder left in the answer file:" >&2
    grep -o '@[A-Z_]*@' "$WORK/autounattend.xml" | sort -u >&2
    exit 1
fi
if [ "${WITH_KEY:-0}" = "1" ]; then
    sed -i 's#<!--PRODUCTKEY-->#<ProductKey><Key>VK7JG-NPHTM-C97JM-9MPGT-3V66T</Key><WillShowUI>OnError</WillShowUI></ProductKey>#' \
        "$WORK/autounattend.xml"
fi

mkdir -p "$WORK/payload"
cp "$HERE/payload-setup.cmd" "$WORK/payload/setup.cmd"
cp "$HERE/../guest/firstboot-setup.ps1" "$WORK/payload/"

if [ -n "${RELEASE_SETUP:-}" ]; then
    [ -d "$RELEASE_SETUP" ] || { echo "RELEASE_SETUP not a directory: $RELEASE_SETUP" >&2; exit 1; }
    mkdir -p "$WORK/payload/release"
    cp -r "$RELEASE_SETUP"/. "$WORK/payload/release/"
    # Same clean-path contract as the repacked NO_QWT image: no stock QWT is ever
    # installed, so qrexec answering at all proves OUR package delivered it.
    cat > "$WORK/payload/setup2.cmd" <<'RELEOF'
@echo off
echo === release install (clean path, answer disc) === >> C:\qubes-win-idd-setup.log
rem The disc's letter is not fixed; %~dp0 is this script's own location.
call "%~dp0release\install.cmd" /auto >> C:\qubes-win-idd-setup.log 2>&1
echo release install.cmd rc=%ERRORLEVEL% >> C:\qubes-win-idd-setup.log
RELEOF
    echo "payload += release/ (our package, installed at firstboot)"
else
    cp "$HERE/payload-setup2.cmd" "$WORK/payload/setup2.cmd"
    for f in ~/win-iso/qubesidd-test.cer ~/win-iso/qwt-payload/installer.msi \
             ~/win-iso/qwt-payload/vc_redist.x64.exe ~/win-iso/qwt-certs/SigningCert*.cer; do
        [ -f "$f" ] && cp "$f" "$WORK/payload/" && echo "payload += $(basename "$f")"
    done
    cp "$HERE/../guest/install-qwt.cmd" "$WORK/payload/"
fi

mkdir -p "$(dirname "$OUT")"
# No boot image: this disc is never booted from, only read. Joliet keeps long names.
xorriso -as mkisofs -iso-level 3 -J -joliet-long -D -N -d \
    -V ANSWER_DISC -o "$OUT" "$WORK"
ls -sh "$OUT"
cat <<EOF

Attach both discs (boot from the STOCK ISO, answers from this one):
  losetup --show -f /path/to/stock-windows.iso        # -> loopA, in win-idd-mgmt
  losetup --show -f $OUT                              # -> loopB
  qvm-device block attach --persistent --option devtype=cdrom --ro <vm> win-idd-mgmt:loopB
  qvm-start <vm> --cdrom=win-idd-mgmt:loopA
EOF
