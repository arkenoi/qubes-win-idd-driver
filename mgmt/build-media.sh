#!/bin/bash
# Build unattended install media by GRAFTING onto the mounted vendor ISO.
#
# Replaces build-unattended-iso.sh's extract-everything approach, which cost ~14 GiB and
# ~15 min per build: a full 5.8 GiB 7z extraction + a ~5 GiB install.wim split + the 5.8 GiB
# output. The extraction was never necessary - this is the method
# qvm-create-windows-qube uses (windows/create-media.sh):
#
#     genisoimage -udf -b boot.bin -no-emul-boot -allow-limited-size -graft-points \
#         -o out.iso "$iso_mntpoint" "boot.bin=$boot_img" "Autounattend.xml=$answer_file"
#
# i.e. loop-MOUNT the vendor ISO read-only and overlay our files with -graft-points. The
# vendor bytes are read straight from the mount; nothing is copied to disk except the output.
#
# TWO MODES, chosen by what is installed:
#   genisoimage present -> -udf, and install.wim is used AS IS. This is the good path:
#                          UDF has no 4 GiB file limit, so no split, no wimlib, ~6 GiB total.
#   xorriso only        -> no UDF writer here ("Unsupported option '-udf'"), so a >4 GiB
#                          install.wim must still be split to .swm. Still avoids the
#                          extraction, so ~11 GiB instead of ~14.
#
# Usage: ./build-media.sh <vendor.iso> [image-name] [--with-key]
#   env: OUT=, UNATTEND=, NO_QWT=1, RELEASE_SETUP=<dir>, LOCALE=, KEYBOARD=
set -euo pipefail

SRC="${1:?usage: $0 <vendor.iso> [image-name] [--with-key]}"
IMG_NAME="${2:-Windows 10 Pro}"
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${OUT:-$HOME/win-iso/win-media.iso}"
UNATTEND="${UNATTEND:-$HERE/autounattend.xml}"
mkdir -p "$(dirname "$OUT")"
# WORK lives beside the OUTPUT, not in /tmp: /tmp here is a small tmpfs and the
# install.wim split (~5 GiB, only needed without a UDF writer) fills it instantly
# ("Failed to write WIM header: No space left on device").
WORK="$(mktemp -d "$(dirname "${OUT:-$HOME/win-iso/x}")/.media-work.XXXXXX")"
MNT=""
LOOPDEV=""

cleanup() {
    [ -n "$MNT" ] && findmnt "$MNT" >/dev/null 2>&1 && udisksctl unmount --block-device "$LOOPDEV" >/dev/null 2>&1 || true
    [ -n "$LOOPDEV" ] && udisksctl loop-delete --block-device "$LOOPDEV" >/dev/null 2>&1 || true
    rm -rf "$WORK"
}
trap cleanup EXIT

command -v xorriso >/dev/null || { echo "need xorriso" >&2; exit 1; }
UDF=0
if command -v genisoimage >/dev/null; then UDF=1; MKISO=genisoimage; else MKISO="xorriso -as mkisofs"; fi
echo "iso builder: $MKISO (udf=$UDF)"

# --- disk budget ------------------------------------------------------------------
# Output ISO (~= source), plus the .swm copy only when we cannot write UDF. No extraction
# in either mode. Refuse up front rather than dying mid-write and leaving a truncated ISO.
src_b=$(stat -c%s "$SRC")
mult=12; [ "$UDF" = 1 ] || mult=22          # 1.2x with UDF, 2.2x when a split is needed
need_kb=$(( src_b / 1024 * mult / 10 ))
free_kb=$(df -Pk "$(dirname "$OUT")" | awk 'NR==2{print $4}')
if [ "$free_kb" -lt "$need_kb" ]; then
    echo "NOT ENOUGH DISK: need ~$(( need_kb / 1048576 )) GiB, have $(( free_kb / 1048576 )) GiB" >&2
    exit 1
fi
echo "disk check ok: $(( free_kb / 1048576 )) GiB free, need ~$(( need_kb / 1048576 )) GiB"

# --- mount the vendor ISO read-only (NOT extracted) ---------------------------------
LOOPDEV=$(udisksctl loop-setup -r -f "$SRC" 2>&1 | grep -o '/dev/loop[0-9]*' | head -1)
[ -n "$LOOPDEV" ] || { echo "could not loop-setup $SRC" >&2; exit 1; }
# "Mounted /dev/loopN at /run/media/user/LABEL" - no trailing period on this udisks2.
MNT=$(udisksctl mount --block-device "$LOOPDEV" 2>&1 | sed -n 's/^Mounted .* at //p' | sed 's/\.$//')
[ -n "$MNT" ] || MNT=$(findmnt -n -o TARGET "$LOOPDEV" 2>/dev/null | head -1)
[ -n "$MNT" ] && [ -d "$MNT" ] || { echo "could not mount $LOOPDEV" >&2; exit 1; }
echo "vendor ISO mounted read-only at $MNT"

# --- answer file (same locale derivation as the old builder) ------------------------
case "${LOCALE:-}" in
    "") case "$(basename "$SRC")" in
            *EnglishInternational*|*english-international*|*en-gb*|*en_GB*) LOCALE=en-GB ;;
            *) LOCALE=en-US ;;
        esac ;;
esac
case "$LOCALE" in
    en-GB) KBD="${KEYBOARD:-0809:00000809}" ;;
    en-US) KBD="${KEYBOARD:-0409:00000409}" ;;
    *)     KBD="${KEYBOARD:?set KEYBOARD=<id> for LOCALE=$LOCALE}" ;;
esac
echo "media locale: $LOCALE (input $KBD)"
sed -e "s/@IMAGE_NAME@/$IMG_NAME/" -e "s/@UILANG@/$LOCALE/g" -e "s/@INPUTLOCALE@/$KBD/g" \
    "$UNATTEND" > "$WORK/autounattend.xml"
grep -q '@[A-Z_]*@' "$WORK/autounattend.xml" && { echo "unsubstituted placeholder in answer file" >&2; exit 1; }
if [ "${3:-}" = "--with-key" ]; then
    sed -i 's#<!--PRODUCTKEY-->#<ProductKey><Key>VK7JG-NPHTM-C97JM-9MPGT-3V66T</Key><WillShowUI>OnError</WillShowUI></ProductKey>#' \
        "$WORK/autounattend.xml"
fi
[ -f "$HERE/diskprep.cmd" ] || { echo "mgmt/diskprep.cmd missing" >&2; exit 1; }
cp "$HERE/diskprep.cmd" "$WORK/diskprep.cmd"

# --- payload ------------------------------------------------------------------------
mkdir -p "$WORK/payload"
cp "$HERE/payload-setup.cmd" "$WORK/payload/setup.cmd"
cp "$HERE/../guest/firstboot-setup.ps1" "$WORK/payload/"
if [ "${NO_QWT:-0}" = "1" ]; then
    [ -n "${RELEASE_SETUP:-}" ] || { echo "NO_QWT=1 needs RELEASE_SETUP=<dir>" >&2; exit 1; }
    [ -d "$RELEASE_SETUP" ] || { echo "RELEASE_SETUP not a directory" >&2; exit 1; }
    mkdir -p "$WORK/payload/release"
    cp -r "$RELEASE_SETUP"/. "$WORK/payload/release/"
    cat > "$WORK/payload/setup2.cmd" <<'RELEOF'
@echo off
rem MUST be first: QWTStage2 is ONSTART and our installer reboots up to three times.
schtasks /delete /tn QWTStage2 /f >nul 2>&1
echo === release install (clean path) === >> C:\qubes-win-idd-setup.log
rem /idd is opt-in: its post-reboot topology apply is unfixed on Win10 (see FINDINGS).
call C:\payload\release\install.cmd /auto >> C:\qubes-win-idd-setup.log 2>&1
echo release install.cmd rc=%ERRORLEVEL% >> C:\qubes-win-idd-setup.log
RELEOF
    for stray in installer.msi install-qwt.cmd vc_redist.x64.exe; do
        [ -e "$WORK/payload/$stray" ] && { echo "NO_QWT=1 but $stray staged" >&2; exit 1; }
    done
    echo "NO_QWT=1 verified: no stock QWT artefacts in the payload"
else
    cp "$HERE/payload-setup2.cmd" "$WORK/payload/setup2.cmd"
    cp "$HERE/../guest/install-qwt.cmd" "$WORK/payload/"
    for f in ~/win-iso/qwt-payload/installer.msi ~/win-iso/qwt-payload/vc_redist.x64.exe \
             ~/win-iso/qwt-certs/SigningCert*.cer ~/win-iso/qubesidd-test.cer; do
        [ -f "$f" ] && cp "$f" "$WORK/payload/"
    done
fi
# Setup copies sources\$OEM$\$1\payload to C:\payload while applying the image - the path
# FirstLogonCommands relies on, since a guest reboot destroys the domain and unassigns the CD.
mkdir -p "$WORK/oem/\$OEM\$/\$1"
cp -a "$WORK/payload" "$WORK/oem/\$OEM\$/\$1/payload"

# --- boot image, taken from the vendor ISO ------------------------------------------
# geteltorito is what qvm-create-windows-qube uses; xorriso can do the same extraction, so
# we do not depend on an extra package.
xorriso -indev "$SRC" -osirrox on -extract_boot_images "$WORK/boot" >/dev/null 2>&1 || true
# BIOS boot image, NOT the UEFI one: Qubes HVMs boot SeaBIOS, which needs
# boot/etfsboot.com. A `find *.img | head -1` picked eltorito_img2_uefi.img and would
# have produced media that does not boot here (caught 2026-08-07 before use).
BOOTIMG=""
[ -f "$MNT/boot/etfsboot.com" ] && BOOTIMG="$MNT/boot/etfsboot.com"
[ -n "$BOOTIMG" ] || BOOTIMG="$(find "$WORK/boot" -type f -name '*img1*' 2>/dev/null | head -1)"
[ -n "$BOOTIMG" ] || { echo "could not obtain a boot image from $SRC" >&2; exit 1; }
echo "boot image: $BOOTIMG"

# --- WIM: split ONLY when we cannot write UDF ----------------------------------------
GRAFT_WIM=""
if [ "$UDF" = 0 ]; then
    WIM="$MNT/sources/install.wim"
    if [ -f "$WIM" ] && [ "$(stat -c%s "$WIM")" -gt 4294967295 ]; then
        command -v wimlib-imagex >/dev/null || { echo "install.wim >4GiB and no UDF writer: need wimlib-imagex or genisoimage" >&2; exit 1; }
        echo "no UDF writer: splitting install.wim (install genisoimage to skip this entirely)"
        mkdir -p "$WORK/swm"
        wimlib-imagex split "$WIM" "$WORK/swm/install.swm" 3500
        wimlib-imagex verify "$WORK/swm/install.swm" --ref="$WORK/swm/install*.swm" >/dev/null
        # graft the .swm set in and HIDE the oversized original
        GRAFT_WIM=""
        for f in "$WORK"/swm/install*.swm; do GRAFT_WIM="$GRAFT_WIM sources/$(basename "$f")=$f"; done
    fi
fi

# --- build ---------------------------------------------------------------------------
# -graft-points: overlay our files onto the mounted vendor tree. Vendor bytes stream from
# the mount; only the output is written.
GRAFT_ARGS=(
    "autounattend.xml=$WORK/autounattend.xml"
    "diskprep.cmd=$WORK/diskprep.cmd"
    "payload=$WORK/payload"
    "sources/\$OEM\$=$WORK/oem/\$OEM\$"
)
# shellcheck disable=SC2206
[ -n "$GRAFT_WIM" ] && GRAFT_ARGS+=( $GRAFT_WIM )

echo "building $OUT ..."
if [ "$UDF" = 1 ]; then
    # Graft the mount AT ROOT (/=$MNT), do not also pass it as a plain path: doing both
    # made genisoimage emit the tree twice (12 GiB from a 5.8 GiB source, 2026-08-07).
    # The boot image is referenced by its path INSIDE the mounted tree, so it is not
    # grafted separately either.
    genisoimage -udf -allow-limited-size -graft-points -quiet \
        -b boot/etfsboot.com -no-emul-boot -boot-load-size 8 \
        -V WIN_IDD_MEDIA -o "$OUT" \
        "/=$MNT" "${GRAFT_ARGS[@]}"
else
    # Strict ISO9660 + Joliet, the layout CDBOOT needs without UDF (see the old builder).
    xorriso -as mkisofs -iso-level 3 -J -joliet-long -D -N -d -graft-points \
        -V WIN_IDD_MEDIA \
        -b boot/etfsboot.com -no-emul-boot -boot-load-size 8 \
        -o "$OUT" \
        "/=$MNT" "${GRAFT_ARGS[@]}"
fi

{
    echo "media: $(basename "$OUT")"
    echo "built from vendor ISO: $(basename "$SRC")  sha256 $(sha256sum "$SRC" | cut -d' ' -f1)"
    echo "method: loop-mounted vendor ISO + -graft-points (NO extraction)"
    echo "udf: $UDF  (1 = install.wim used as-is; 0 = split to .swm, the only vendor change)"
    echo "ADDED: /autounattend.xml /diskprep.cmd /payload/** /sources/\$OEM\$/\$1/payload/**"
} > "${OUT%.iso}.vendor-delta.txt"

ls -sh "$OUT"
echo "vendor delta: ${OUT%.iso}.vendor-delta.txt"
