#!/bin/bash
# Build a small FAT32 "answer stick": autounattend.xml + the QWT payload, to be presented to
# Windows Setup as an EMULATED USB MASS STORAGE DEVICE. The vendor ISO is booted UNTOUCHED
# and is never rebuilt.
#
# WHY THIS EXISTS. The grafted-ISO builder (build-media.sh) bakes the payload INTO a 5.8 GB
# image, so every package or install-flag change forces a full 5.8 GB rebuild. Nothing about
# the payload actually needs to be on the boot media: Windows Setup needs only the answer
# file, and QWT is applied afterwards at first logon. Splitting them means the vendor ISO is
# constant and only this ~96 MB image is rebuilt, in seconds.
#
# WHY USB AND NOT A SECOND CD. `qvm-device block assign --option devtype=cdrom` creates a Xen
# PV device. WinPE carries no Xen PV drivers, so Setup never sees it - measured twice on
# 2026-08-07 and written up as "the two-disc route is impossible". That verdict is correct
# ONLY for the CD variant. WinPE does have USBSTOR/USBXHCI inbox, and Windows Setup's
# documented implicit search order includes the root of removable media, so a usb-storage
# device works where an assigned CD cannot.
#
# THE PLACEHOLDER TRAP - the reason this is a script and not three ad-hoc commands.
# mgmt/autounattend.xml is a TEMPLATE. It carries @UILANG@ (x8), @IMAGE_NAME@ (x2),
# @INPUTLOCALE@ and a <!--PRODUCTKEY--> marker. Copying it verbatim produces a file that
# Setup PARSES BUT REJECTS, and on a language mismatch it falls back to the interactive
# locale picker SILENTLY - indistinguishable from "the answer file was never found".
# That cost a full debugging cycle on 2026-08-07. This script substitutes every placeholder
# and then ASSERTS none remain.
#
# Usage: ./build-answer-stick.sh [image-name]
#   env: RELEASE_SETUP=<dir>  QWT package to stage under \payload\release (installed at logon)
#        OUT=<img>            output image (default ~/win-iso/answer-usb.img)
#        LOCALE=              en-GB | en-US ... MUST match the media or Setup ignores the file
#        KEYBOARD=            input locale id, defaulted per LOCALE
#        INSTALL_FLAGS=       flags for install.cmd (default /idd)
#        WITH_KEY=0           omit the generic install key (default 1: retail multi-edition
#                             media needs a key to select the edition)
#        SIZE_MB=             image size (default 96)
set -euo pipefail

IMG_NAME="${1:-Windows 10 Pro}"
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${OUT:-$HOME/win-iso/answer-usb.img}"
UNATTEND="${UNATTEND:-$HERE/autounattend.xml}"
SIZE_MB="${SIZE_MB:-96}"
# /tmp here is a 1 GiB tmpfs and the staged payload is ~30 MB; a session that has been
# running a while fills it and `cp` dies with "No space left on device" mid-build, leaving a
# half-written stick (measured 2026-08-07). Prefer a disk-backed scratch dir, and CHECK the
# space before doing any work rather than discovering it halfway through.
: "${TMPDIR:=/home/user/tmp}"
mkdir -p "$TMPDIR" 2>/dev/null || true
export TMPDIR
avail_kb=$(df -Pk "$TMPDIR" | awk 'NR==2{print $4}')
if [ "${avail_kb:-0}" -lt 262144 ]; then
    echo "ERROR: only ${avail_kb}KB free in TMPDIR=$TMPDIR - need >=256MB to stage the payload" >&2
    exit 1
fi
MNT=$(mktemp -d)
cleanup(){ mountpoint -q "$MNT" && sudo umount "$MNT" 2>/dev/null || true; rmdir "$MNT" 2>/dev/null || true; }
trap cleanup EXIT

command -v mkfs.vfat >/dev/null || { echo "need dosfstools (mkfs.vfat)" >&2; exit 1; }
[ -f "$UNATTEND" ] || { echo "no answer template at $UNATTEND" >&2; exit 1; }

# Locale MUST match the media. An answer file whose language differs is silently ignored.
LOCALE="${LOCALE:-en-US}"
case "$LOCALE" in
    en-GB) KBD="${KEYBOARD:-0809:00000809}" ;;
    en-US) KBD="${KEYBOARD:-0409:00000409}" ;;
    *)     KBD="${KEYBOARD:?set KEYBOARD=<id> for LOCALE=$LOCALE}" ;;
esac
echo "locale: $LOCALE (input $KBD), image: $IMG_NAME"

WORK=$(mktemp -d); trap 'cleanup; rm -rf "$WORK"' EXIT
sed -e "s/@IMAGE_NAME@/$IMG_NAME/g" -e "s/@UILANG@/$LOCALE/g" -e "s/@INPUTLOCALE@/$KBD/g" \
    "$UNATTEND" > "$WORK/Autounattend.xml"

if [ "${WITH_KEY:-1}" = 1 ]; then
    sed -i 's#<!--PRODUCTKEY-->#<ProductKey><Key>VK7JG-NPHTM-C97JM-9MPGT-3V66T</Key><WillShowUI>OnError</WillShowUI></ProductKey>#' \
        "$WORK/Autounattend.xml"
fi

# ASSERT the template is fully resolved. A leftover placeholder does not fail loudly at
# install time - Setup just drops to the interactive picker - so it must fail loudly HERE.
if grep -qE '@[A-Z_]+@|<!--PRODUCTKEY-->' "$WORK/Autounattend.xml"; then
    echo "ERROR: unsubstituted placeholders remain in the answer file:" >&2
    grep -oE '@[A-Z_]+@|<!--PRODUCTKEY-->' "$WORK/Autounattend.xml" | sort -u | sed 's/^/  /' >&2
    exit 1
fi
python3 -c "import xml.dom.minidom,sys; xml.dom.minidom.parse('$WORK/Autounattend.xml')" \
    || { echo "ERROR: answer file is not well-formed XML" >&2; exit 1; }
echo "answer file: all placeholders substituted, XML well-formed"

cp "$HERE/diskprep.cmd" "$WORK/" 2>/dev/null || true

mkdir -p "$WORK/payload"
if [ -n "${RELEASE_SETUP:-}" ]; then
    [ -d "$RELEASE_SETUP" ] || { echo "RELEASE_SETUP not a directory: $RELEASE_SETUP" >&2; exit 1; }
    mkdir -p "$WORK/payload/release"
    cp -r "$RELEASE_SETUP"/. "$WORK/payload/release/"
    [ -f "$WORK/payload/release/install.cmd" ] || { echo "ERROR: no install.cmd in $RELEASE_SETUP" >&2; exit 1; }
    cat > "$WORK/payload/setup.cmd" <<EOF
@echo off
rem Found by the FirstLogonCommands drive-letter scan: <drive>:\payload\setup.cmd
echo === answer-stick payload === >> C:\qubes-win-idd-setup.log
call "%~dp0release\install.cmd" /auto ${INSTALL_FLAGS:-/idd} >> C:\qubes-win-idd-setup.log 2>&1
echo install.cmd rc=%ERRORLEVEL% >> C:\qubes-win-idd-setup.log
EOF
    echo "payload: release package staged, install flags ${INSTALL_FLAGS:-/idd}"
fi
# STOCK_SETUP: stage a full package directory and install it with OUR OWN installer, the
# same way the ours-side is installed. This replaced a hand-rolled `msiexec /qn` control
# payload that left the guest with NO qrexec: our installer is the only path proven to
# install this MSI, and using it for both sides means the ONLY difference between the two
# benchmark guests is the MSI itself. A control installed by a different route is not a
# control. The package's MANIFEST.json must have reference_binaries REMOVED - the installer
# fails when the installed gui-agent does not match it, and on the control it is stock's.
if [ -n "${STOCK_SETUP:-}" ]; then
    [ -d "$STOCK_SETUP" ] || { echo "STOCK_SETUP not a directory: $STOCK_SETUP" >&2; exit 1; }
    [ -n "${RELEASE_SETUP:-}" ] && { echo "ERROR: STOCK_SETUP and RELEASE_SETUP are mutually exclusive" >&2; exit 1; }
    if python3 -c "
import json,sys
m=json.load(open('$STOCK_SETUP/MANIFEST.json'))
sys.exit(0 if 'reference_binaries' in m else 1)" 2>/dev/null; then
        echo "ERROR: $STOCK_SETUP/MANIFEST.json still has reference_binaries - the installer will reject the stock agent" >&2
        exit 1
    fi
    mkdir -p "$WORK/payload/release"
    cp -r "$STOCK_SETUP"/. "$WORK/payload/release/"
    [ -f "$WORK/payload/release/install.cmd" ] || { echo "ERROR: no install.cmd in $STOCK_SETUP" >&2; exit 1; }
    cat > "$WORK/payload/setup.cmd" <<'STOCKEOF'
@echo off
echo === answer-stick payload (STOCK QWT control, our installer) === >> C:\qubes-win-idd-setup.log
rem No /idd: stock QWT has no indirect display driver.
call "%~dp0release\install.cmd" /auto >> C:\qubes-win-idd-setup.log 2>&1
echo install.cmd rc=%ERRORLEVEL% >> C:\qubes-win-idd-setup.log
STOCKEOF
    echo "payload: STOCK control staged, installed via our own installer (no /idd)"
fi

cp "$HERE/../guest/firstboot-setup.ps1" "$WORK/payload/" 2>/dev/null || true

# Rewrite the image IN PLACE. `rm -f` + truncate would give the file a NEW INODE while any
# losetup attached to it keeps the OLD one - `losetup -l` then shows the backing file as
# "(deleted)" and the guest silently reads a STALE stick. Re-pointing the loop needs root,
# which this script does not have when it runs unattended, so instead the inode is never
# changed: truncate to 0 and back to the fixed size preserves it, and because the size is
# CONSTANT the cached loop capacity stays correct too. Both hazards disappear, no sudo.
# (Measured 2026-08-07: a rebuilt stick was served stale to a guest for a full install.)
# IMAGE FORMAT. The FAT path needed one `sudo mount` (mtools is not installed here), and
# that is the single fragile step: run unattended it BLOCKS forever on a password prompt,
# and sudo is not reliably available in this qube. xorriso needs no privileges at all, and
# QEMU's usb-storage can present the result as a USB CD-ROM, which Windows reads via CDFS -
# Setup scans removable media roots either way. So build an ISO instead and drop the
# privileged step entirely. Set STICK_FAT=1 to force the old FAT path.
if [ "${STICK_FAT:-0}" = 1 ]; then
    if [ -e "$OUT" ]; then truncate -s 0 "$OUT"; else : > "$OUT"; fi
    truncate -s "${SIZE_MB}M" "$OUT"
    mkfs.vfat -F 32 -n ANSWER "$OUT" >/dev/null
    sudo mount -o loop,uid="$(id -u)" "$OUT" "$MNT"
    cp -r "$WORK"/. "$MNT"/
    sync
    ls "$MNT" | sed 's/^/  /'
    sudo umount "$MNT"
else
    command -v xorriso >/dev/null || { echo "need xorriso" >&2; exit 1; }
    # -R -J: long names both ways. No boot image: this is never booted from, only read.
    xorriso -as mkisofs -iso-level 3 -R -J -joliet-long -V ANSWER -o "$OUT" "$WORK" 2>/dev/null \
        || { echo "ERROR: xorriso failed" >&2; exit 1; }
    # PAD to the FIXED size, exactly as the FAT path did. A loop device caches its capacity
    # at setup: if the image shrinks the loop keeps advertising the old size and reads run
    # past EOF; if it grows the guest sees a truncated image. Re-pointing the loop needs
    # root, which is the dependency this whole path exists to avoid - so the size is held
    # CONSTANT instead. Trailing zeros sit outside the ISO9660 volume and readers ignore them.
    iso_bytes=$(stat -c%s "$OUT")
    pad_to=$((SIZE_MB * 1024 * 1024))
    if [ "$iso_bytes" -gt "$pad_to" ]; then
        echo "ERROR: ISO is $iso_bytes bytes, exceeds the fixed ${pad_to}-byte slot" >&2
        exit 1
    fi
    truncate -s "$pad_to" "$OUT"
    echo "iso $iso_bytes bytes, padded to $pad_to (loop capacity stays constant)"
    ls "$WORK" | sed 's/^/  /'
fi

echo "built $OUT ($(du -h "$OUT" | cut -f1))"
echo
echo "Present it to the guest as an emulated USB stick (vendor ISO stays untouched):"
echo "  sudo losetup --show -f $OUT                 # -> /dev/loopN"
echo "  qvm-device block assign --required -o frontend-dev=xvdi -o devtype=disk <vm> win-idd-mgmt:loopN"
echo "  qvm-features <vm> qemu-extra-args -- '-drive file=/dev/xvdi,format=host_device,if=none,readonly=on,id=ansdrv -device nec-usb-xhci,id=ansusb -device usb-storage,bus=ansusb.0,drive=ansdrv,removable=on,bootindex=99'"
echo "  qvm-start <vm> --cdrom=win-idd-mgmt:<vendor-iso-loop>"
echo
echo "The guest disk must be EMPTY: a leftover partition table makes SeaBIOS prompt"
echo "'Press any key to boot from CD' and then fall through to a diskless boot."
