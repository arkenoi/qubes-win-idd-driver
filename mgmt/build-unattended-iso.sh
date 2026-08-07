#!/bin/bash
# Run IN win-idd-mgmt. Repacks a Windows install ISO into a zero-click installer:
# adds autounattend.xml + \payload (firstboot script, build cert, optional QWT installer).
# Output boots BIOS (Qubes HVM default) and UEFI.
# Usage: ./build-unattended-iso.sh <source.iso> [image-name] [--with-key]
#   image-name: exact WIM image name, e.g. "Windows 10 Pro" or
#               "Windows 10 Enterprise Evaluation" (list with: 7z x -so src.iso sources/install.wim | true;
#               easier: wiminfo if wimlib installed, or let Windows Setup error tell you)
#   --with-key: inject the well-known GENERIC Pro install key (installs only, never activates) -
#               needed on retail multi-edition ISOs so Setup doesn't stop at edition choice.
set -euo pipefail

SRC="${1:?usage: $0 <source.iso> [image-name] [--with-key]}"
IMG_NAME="${2:-Windows 10 Pro}"
HERE="$(cd "$(dirname "$0")" && pwd)"
# Env overrides (Win11 flow): UNATTEND=<answer file>  OUT=<output iso>
OUT="${OUT:-$HOME/win-iso/win-idd-unattended.iso}"
UNATTEND="${UNATTEND:-$HERE/autounattend.xml}"
WORK=~/win-iso/.unattend-work

command -v 7z >/dev/null      || { echo "need p7zip(-plugins): 7z" >&2; exit 1; }
command -v xorriso >/dev/null || { echo "need xorriso" >&2; exit 1; }

# REUSE_EXTRACT=1 keeps the previously extracted source tree (saves ~2 min of 7z per
# answer-file iteration). The payload and autounattend.xml are re-staged either way.
if [ "${REUSE_EXTRACT:-0}" = "1" ] && [ -d "$WORK/sources" ]; then
    echo "Reusing extracted tree at $WORK"
    rm -rf "$WORK/payload" "$WORK/sources/\$OEM\$"
else
    rm -rf "$WORK"; mkdir -p "$WORK"
    echo "Extracting $SRC ..."
    7z x -o"$WORK" "$SRC" >/dev/null
fi

# Answer-file LANGUAGE must match the media, or Windows Setup silently ignores the whole
# unattend file and sits on the locale picker - a failure that looks exactly like "the
# answer file was not picked up" and costs a full install cycle to notice. This bit us
# twice: once on the retail English-International media (fixed by hand, in a working copy
# that was never committed) and again today, from the committed en-US file.
# So the locale is DERIVED from the media rather than hardcoded, and can be overridden.
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
echo "media locale: $LOCALE (input $KBD) - from $(basename "$SRC")"

# answer file (+ optional generic install key)
sed -e "s/@IMAGE_NAME@/$IMG_NAME/" -e "s/@UILANG@/$LOCALE/g" -e "s/@INPUTLOCALE@/$KBD/g" \
    "$UNATTEND" > "$WORK/autounattend.xml"
# A leftover placeholder means the answer file is not the parameterised one; an unsubstituted
# @UILANG@ would be rejected by Setup with the same silent ignore. Fail here instead.
if grep -q '@[A-Z_]*@' "$WORK/autounattend.xml"; then
    echo "unsubstituted placeholder left in the answer file:" >&2
    grep -o '@[A-Z_]*@' "$WORK/autounattend.xml" | sort -u >&2
    exit 1
fi
# diskprep.cmd sits at the MEDIA ROOT: the answer file's windowsPE RunSynchronous scans
# drive letters for it (the CD's letter is not fixed in WinPE). Without it the answer file
# has no DiskConfiguration at all and Setup would stop with nowhere to install - so a
# missing file is fatal here, not a warning.
[ -f "$HERE/diskprep.cmd" ] || { echo "mgmt/diskprep.cmd missing - the answer file requires it" >&2; exit 1; }
cp "$HERE/diskprep.cmd" "$WORK/diskprep.cmd"
echo "media += diskprep.cmd (size-based disk selection)"

if [ "${3:-}" = "--with-key" ]; then
    sed -i 's#<!--PRODUCTKEY-->#<ProductKey><Key>VK7JG-NPHTM-C97JM-9MPGT-3V66T</Key><WillShowUI>OnError</WillShowUI></ProductKey>#' \
        "$WORK/autounattend.xml"
fi

# payload — staged twice on purpose:
#   \payload                    : readable from WinPE (RunSynchronous fallback copy)
#   \sources\$OEM$\$1\payload   : Windows Setup copies this to C:\payload while applying
#                                 the image. This is the path FirstLogonCommands relies on:
#                                 a guest reboot destroys the Qubes domain (libvirt
#                                 on_reboot=destroy) and qvm-start unassigns the cdrom,
#                                 so the CD is GONE by first logon.
mkdir -p "$WORK/payload" "$WORK/sources/\$OEM\$/\$1"
cp "$HERE/payload-setup.cmd" "$WORK/payload/setup.cmd"
# NO_QWT=1 builds a TRULY CLEAN image: Windows + qrexec only, no Qubes Tools at all.
# Required for the release acceptance - "clean install" must mean no prior QWT, not
# "our package over the QWT this ISO installed" (user, 2026-08-06). setup2.cmd is what
# invokes install-qwt.cmd, so omitting it is enough; firstboot still runs.
if [ "${NO_QWT:-0}" = "1" ]; then
    echo "NO_QWT=1: payload will NOT install stock Qubes Tools"
    # RELEASE_SETUP=<dir>: stage OUR release package on the media and have firstboot run
    # it. This is the honest clean-path acceptance: a guest that has never seen QWT, where
    # qrexec only appears BECAUSE our package delivered it - so "qrexec answers" is itself
    # the pass condition. Without this the guest would be unreachable (qrexec ships with
    # QWT), which is why NO_QWT alone is not a usable test image.
    if [ -n "${RELEASE_SETUP:-}" ]; then
        [ -d "$RELEASE_SETUP" ] || { echo "RELEASE_SETUP not a directory: $RELEASE_SETUP" >&2; exit 1; }
        mkdir -p "$WORK/payload/release"
        cp -r "$RELEASE_SETUP"/. "$WORK/payload/release/"
        cat > "$WORK/payload/setup2.cmd" <<'RELEOF'
@echo off
rem Clean-path acceptance: install OUR release package on a guest with no prior QWT.
rem MUST be the first action: QWTStage2 is an ONSTART task, and our installer reboots up
rem to three times. Without this delete the task re-fires on every one of those boots and
rem launches a SECOND concurrent install.cmd - which is exactly what happened on
rem win10-clean (two stacked Qubes Windows Tools setup dialogs, guest wedged, 2026-08-06).
rem The stock payload-setup2.cmd has always done this; the release variant omitted it.
schtasks /delete /tn QWTStage2 /f >nul 2>&1
echo === release install (clean path) === >> C:\qubes-win-idd-setup.log
rem /idd is DELIBERATELY NOT passed (2026-08-07). It was added here that morning, and the
rem first clean-path acceptance that could actually see display health showed why it must
rem not be a default yet: the installer's activation sequence runs correctly (device
rem created, adapter present, VGA disabled and the disable PERSISTS at ConfigFlags=1), but
rem after the reboot Windows drives the desktop through the ROOT\BASICDISPLAY fallback and
rem the IDD stays OFFLINE (Availability=8). Disabling the VGA is not sufficient - an IddCx
rem monitor arrives inactive and still needs a topology apply that we do not perform. The
rem guest also wedged minutes later (zero active grants; causation unproven).
rem /idd remains supported and documented as an opt-in flag for manual use.
call C:\payload\release\install.cmd /auto >> C:\qubes-win-idd-setup.log 2>&1
echo release install.cmd rc=%ERRORLEVEL% >> C:\qubes-win-idd-setup.log
RELEOF
        echo "payload += release/ (our package, installed at firstboot)"
    fi
else
    cp "$HERE/payload-setup2.cmd" "$WORK/payload/setup2.cmd"
fi
cp "$HERE/../guest/firstboot-setup.ps1" "$WORK/payload/"
# install-qwt.cmd is version-controlled in guest/; the rest are large/derived binaries
# extracted from the QWT rpm into ~/win-iso (see PROVISION-LOG.md for how to regenerate).
cp "$HERE/../guest/install-qwt.cmd" "$WORK/payload/" && echo "payload += install-qwt.cmd (from guest/)"
for f in ~/win-iso/qubesidd-test.cer ${NO_QWT:+} $( [ "${NO_QWT:-0}" = "1" ] || echo ~/win-iso/qwt-installer.exe ~/win-iso/qwt-installer.msi ) \
         ~/win-iso/qwt-payload/installer.msi ~/win-iso/qwt-payload/vc_redist.x64.exe \
         ~/win-iso/qwt-certs/SigningCert*.cer; do
    [ -f "$f" ] && cp "$f" "$WORK/payload/" && echo "payload += $(basename "$f")"
done
# QWT_MSI: stage OUR CI-built installer.msi instead of the stock one (full-source-build
# plan step 4; artifact qwt-full-package). QWT_MSI_SHA256 (from the CI MANIFEST.json) is
# verified here at stage time and written alongside for install-qwt.cmd to re-verify.
if [ -n "${QWT_MSI:-}" ]; then
    [ -f "$QWT_MSI" ] || { echo "QWT_MSI not found: $QWT_MSI" >&2; exit 1; }
    have=$(sha256sum "$QWT_MSI" | cut -d' ' -f1)
    if [ -n "${QWT_MSI_SHA256:-}" ] && [ "$have" != "$QWT_MSI_SHA256" ]; then
        echo "QWT_MSI sha256 mismatch: $have != $QWT_MSI_SHA256" >&2; exit 1
    fi
    cp "$QWT_MSI" "$WORK/payload/installer.msi"
    echo "$have  installer.msi" > "$WORK/payload/installer.msi.sha256"
    echo "payload += installer.msi (OURS: $have)"
fi
cp -a "$WORK/payload" "$WORK/sources/\$OEM\$/\$1/payload"
rm -rf "$WORK/[BOOT]"   # 7z-extracted El Torito images; not needed in the rebuilt ISO

# bootfix.bin makes bootmgr show "Press any key to boot from CD/DVD" whenever the disk
# already has a bootable OS - on unattended media that prompt times out and the VM
# silently boots the OLD install from disk instead of Setup (bitten 2026-08-01: reinstall
# over an existing guest ran the previous Windows; qrexec answering during "Setup" was
# the tell).
#
# KEPT BY DEFAULT since 2026-08-07. Every vendor byte we leave alone is one less
# difference between this media and what a user installs from, and the prompt cannot
# actually bite the acceptance flow: reprovision.sh always destroys and recreates the
# qube, so the disk is BLANK on the CD boot (no prompt is shown at all), and every
# later restart happens WITHOUT the CD attached. Set REMOVE_BOOTFIX=1 to drop it for
# a hand-run reinstall over an existing Windows.
if [ "${REMOVE_BOOTFIX:-0}" = "1" ]; then
    rm -f "$WORK/boot/bootfix.bin" && echo "removed boot/bootfix.bin (promptless CD boot)"
else
    echo "kept boot/bootfix.bin (vendor file; safe because acceptance always boots a blank disk)"
fi

# ISO9660-without-UDF cannot carry a >4GiB file (see xorriso NOTE below). Win11 24H2
# install.wim exceeds that -> split into .swm chunks, which Windows Setup consumes
# natively (same mechanism as FAT32 USB media; autounattend InstallFrom-by-name works
# unchanged). Requires wimlib. install.wim is REMOVED after a verified split so Setup
# cannot pick the unsplit copy.
WIM="$WORK/sources/install.wim"
if [ -f "$WIM" ] && [ "$(stat -c%s "$WIM")" -gt 4294967295 ]; then
    command -v wimlib-imagex >/dev/null || {
        echo "install.wim >4GiB needs splitting but wimlib-imagex is missing" >&2
        echo "install it (e.g. dnf install wimlib-utils) and re-run" >&2; exit 1; }
    echo "install.wim is >4GiB - splitting to .swm ..."
    wimlib-imagex split "$WIM" "$WORK/sources/install.swm" 3500
    wimlib-imagex verify "$WORK/sources/install.swm" \
        --ref="$WORK/sources/install*.swm" >/dev/null
    rm -f "$WIM"
    ls -sh "$WORK/sources/"install*.swm
fi

echo "Rebuilding bootable ISO ..."
# NOTE: no -udf — this xorriso (1.5.8) lacks UDF write support ("Unsupported option
# '-udf'"). Plain ISO9660 is fine as long as no payload file exceeds 4 GiB
# (Win10 LTSC 2021 eval install.wim = 3.97 GiB, OK; Win11 LTSC 2024 would NOT fit).
# LAYOUT (learned the hard way): on original MS media CDBOOT finds BOOTMGR via UDF;
# without UDF it parses the ISO9660 PVD and needs the classic UPPERCASE-mapped names —
# "-relaxed-filenames" stored lowercase 'bootmgr' and BIOS boot died with
# "CDBOOT: Couldn't find BOOTMGR". So: strict ISO9660 (uppercase-mangled PVD, satisfies
# CDBOOT/bootmgr) + Joliet with long names (-J -joliet-long, preserves case and $OEM$
# for Windows Setup, which prefers the Joliet tree). Win7-era retail media shipped
# exactly this layout, no UDF.
# -d: no trailing period on extensionless PVD names (else 'BOOTMGR.' breaks CDBOOT)
xorriso -as mkisofs -iso-level 3 -J -joliet-long -D -N -d \
    -V WIN_IDD_UNATTENDED \
    -b boot/etfsboot.com -no-emul-boot -boot-load-size 8 \
    -eltorito-alt-boot -e efi/microsoft/boot/efisys.bin -no-emul-boot \
    -o "$OUT" "$WORK"
# Auditable delta: state exactly how this media differs from the vendor ISO, next to the
# ISO itself. A repack is only defensible if what it changed is enumerable - and on Qubes
# HVM a repack is UNAVOIDABLE: an assigned second CD is a PV device that WinPE (no Xen PV
# drivers) cannot see, and SeaBIOS will not boot it either, so the answer file has to be
# on the one emulated CD (measured 2026-08-07, see FINDINGS).
DELTA="${OUT%.iso}.vendor-delta.txt"
{
    echo "media: $(basename "$OUT")"
    echo "built from vendor ISO: $(basename "$SRC")"
    echo "vendor ISO sha256: $(sha256sum "$SRC" | cut -d' ' -f1)"
    echo
    echo "ADDED (ours, none of it replaces a vendor file):"
    echo "  /autounattend.xml        unattended answer file"
    echo "  /diskprep.cmd            WinPE disk selection by size"
    echo "  /payload/**              firstboot scripts + our release package"
    echo "  /sources/\$OEM\$/\$1/payload/**   same payload, copied to C:\\payload by Setup"
    echo
    echo "CHANGED (vendor content):"
    if [ -f "$WORK/sources/install.swm" ] || ls "$WORK"/sources/install*.swm >/dev/null 2>&1; then
        echo "  /sources/install.wim -> install*.swm   SPLIT, losslessly."
        echo "    Required because Windows cannot read a >4GiB file from ISO9660 without UDF,"
        echo "    and this xorriso has no UDF writer. Verified with 'wimlib-imagex verify'"
        echo "    against the split set; image contents are unchanged."
    else
        echo "  (none - install.wim fit and was copied verbatim)"
    fi
    [ "${REMOVE_BOOTFIX:-0}" = "1" ] && echo "  /boot/bootfix.bin REMOVED (REMOVE_BOOTFIX=1)" \
                                     || echo "  /boot/bootfix.bin kept (vendor file untouched)"
    echo "  ISO structure itself is rebuilt (ISO9660+Joliet, El Torito BIOS+UEFI)."
    echo
    echo "NOT changed: every other vendor file is copied byte-for-byte."
} > "$DELTA"
[ "${REUSE_EXTRACT:-0}" = "1" ] || rm -rf "$WORK"
ls -sh "$OUT"
echo "vendor delta written to $DELTA"
echo "Attach with:  qvm-start win-idd-test --cdrom=win-idd-mgmt:${OUT/#$HOME/\/home\/user}"
