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
# STOCK_MSI: build the CONTROL stick for the benchmark - installs vendor QWT instead of
# ours, so both benchmark sides come from an identical clean-room path and differ only in
# the package under test. Its gui-agent is the control build (hash 3D2E6BCEC9F5BD89).
if [ -n "${STOCK_MSI:-}" ]; then
    [ -f "$STOCK_MSI" ] || { echo "STOCK_MSI not found: $STOCK_MSI" >&2; exit 1; }
    [ -n "${RELEASE_SETUP:-}" ] && { echo "ERROR: STOCK_MSI and RELEASE_SETUP are mutually exclusive" >&2; exit 1; }
    mkdir -p "$WORK/payload/stock"
    cp "$STOCK_MSI" "$WORK/payload/stock/installer.msi"
    for extra in "$HERE/../vendor/qwt-4.2.2/vc_redist.x64.exe" "$HOME/win-iso/qwt-payload/vc_redist.x64.exe"; do
        [ -f "$extra" ] && cp "$extra" "$WORK/payload/stock/" && break
    done
    cat > "$WORK/payload/setup.cmd" <<'STOCKEOF'
@echo off
echo === answer-stick payload (STOCK QWT control) === >> C:\qubes-win-idd-setup.log
if exist "%~dp0stock\vc_redist.x64.exe" "%~dp0stock\vc_redist.x64.exe" /install /quiet /norestart >> C:\qubes-win-idd-setup.log 2>&1
rem Same ADDLOCAL set stock installs by default (every feature is Level=1 in Package.wxs).
msiexec /i "%~dp0stock\installer.msi" /qn /norestart /L*v C:\qwt-stock-msi.log
echo stock msiexec rc=%ERRORLEVEL% >> C:\qubes-win-idd-setup.log
shutdown /r /t 20 /f
STOCKEOF
    echo "payload: STOCK QWT control ($(basename "$STOCK_MSI"))"
fi

cp "$HERE/../guest/firstboot-setup.ps1" "$WORK/payload/" 2>/dev/null || true

rm -f "$OUT"
truncate -s "${SIZE_MB}M" "$OUT"
mkfs.vfat -F 32 -n ANSWER "$OUT" >/dev/null
# One mount is needed because mtools is not installed here; it is the only privileged step
# and it touches nothing outside this image file.
sudo mount -o loop,uid="$(id -u)" "$OUT" "$MNT"
cp -r "$WORK"/. "$MNT"/
sync
ls "$MNT" | sed 's/^/  /'
sudo umount "$MNT"

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
