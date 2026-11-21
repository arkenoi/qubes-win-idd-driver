#!/bin/bash
# build-tiny11sc.sh - "tiny11 serviceable core": a stripped Windows 11 install ISO, built on Linux
# from the stock Microsoft ISO, that
#   (a) is updated by our dom0-driven updater like any other Windows qube, and
#   (b) can add back from the command line everything it removed (C:\Windows\tiny11sc\tiny11sc.cmd).
#
# Usage: build-tiny11sc.sh <stock-win11.iso> [out.iso]
#   EDITION="Windows 11 Pro"   the image to keep (its name stays exact: answer files select by it)
#   WORK=<dir>                 scratch (default: next to the output); needs ~3x the source ISO
#   KEEP_WORK=1                keep the scratch tree
# Needs: 7z, wimlib-imagex, hivexregedit + hivexget (hivex), xorriso. No root, no Windows.
#
# HOW THIS DIFFERS FROM tiny11maker / tiny11Coremaker, and why. Core cuts WinSxS and Windows
# Update out of the image, so it can neither take an update nor add a component back. Here the
# offline step touches ONLY what the servicing stack does not own:
#   - one edition, so the ISO carries no other SKU;
#   - Edge, EdgeCore, the Evergreen WebView2 runtime and EdgeUpdate - not CBS components, and
#     one 870 MB payload hard-linked three times, so it is all of them or nothing (measured on
#     26300.9457); the inbox CBS WebView package is left alone;
#   - Windows\System32\Recovery\Winre.wim (791 MB, not a component; WinRE is useless in a qube);
#   - registry: Defender, Smart App Control, telemetry services and Edge's updater off; consumer
#     content, Copilot, Recall, widgets, OneDrive-at-logon off; Setup's TPM/SecureBoot checks off;
#   - SetupComplete.cmd + strip.ps1 + restore.ps1 into the image.
# Everything that IS a component - Features on Demand, optional features, provisioned apps - is
# removed at install time by strip.ps1 through DISM on the running OS (SetupComplete, as SYSTEM,
# before the first logon), and recorded in C:\Windows\tiny11sc\removed.json for restore.ps1.
# Nothing ever deletes a file that WinSxS owns, which is exactly what makes core unserviceable.
set -euo pipefail

SRC="${1:?usage: $0 <stock-win11.iso> [out.iso]}"
HERE="$(cd "$(dirname "$0")" && pwd)"
EDITION="${EDITION:-Windows 11 Pro}"
for t in 7z wimlib-imagex hivexregedit hivexget xorriso sha256sum; do
    command -v "$t" >/dev/null || { echo "need $t (Debian/Ubuntu: p7zip-full wimtools libhivex-bin libwin-hivex-perl xorriso; Fedora: p7zip-plugins wimlib-utils hivex xorriso)" >&2; exit 1; }
done
[ -f "$SRC" ] || { echo "no such ISO: $SRC" >&2; exit 1; }

# Output name carries the build number read from the image, e.g. Tiny11SC_26300.9457_English_x64.iso.
OUT="${2:-}"
WORK="${WORK:-$(dirname "${OUT:-$SRC}")/.tiny11sc-work}"
log() { printf '%s %s\n' "$(date -u +%H:%M:%S)" "$*"; }

src_bytes=$(stat -c%s "$SRC")
free_kb=$(df -Pk "$(dirname "$WORK")" | awk 'NR==2{print $4}')
need_kb=$(( src_bytes / 1024 * 3 ))
[ "$free_kb" -ge "$need_kb" ] || { echo "NOT ENOUGH DISK: need ~$(( need_kb / 1048576 )) GiB free at $(dirname "$WORK"), have $(( free_kb / 1048576 )) GiB" >&2; exit 1; }

rm -rf "$WORK"; mkdir -p "$WORK"/{iso,hives,boothive,stage}
cleanup() { [ "${KEEP_WORK:-0}" = 1 ] || rm -rf "$WORK"; }
trap cleanup EXIT

log "extracting $(basename "$SRC")"
7z x -y -o"$WORK/iso" "$SRC" >/dev/null
SRCWIM="$WORK/iso/sources/install.wim"
[ -f "$SRCWIM" ] || { echo "no sources/install.wim in the ISO (an install.esd source is not handled)" >&2; exit 1; }
mv "$SRCWIM" "$WORK/src-install.wim"
SRCWIM="$WORK/src-install.wim"
chmod -R u+w "$WORK/iso"

# ---- the edition, by exact name -------------------------------------------------------------
IDX=$(wimlib-imagex info "$SRCWIM" | awk -v want="$EDITION" '
    /^Index:/ {i=$2} /^Name:/ {sub(/^Name:[ \t]+/,""); if ($0==want) {print i; exit}}')
[ -n "$IDX" ] || { echo "no image named '$EDITION' in install.wim:" >&2; wimlib-imagex info "$SRCWIM" | grep '^Name:' >&2; exit 1; }
BUILD=$(wimlib-imagex info "$SRCWIM" "$IDX" | awk '/^Build:/{b=$2} /^Service Pack Build:/{s=$4} END{print b"."s}')
LANGTAG=$(wimlib-imagex info "$SRCWIM" "$IDX" | awk '/^Default Language:/{print $3; exit}')
log "edition '$EDITION' is index $IDX, build $BUILD, $LANGTAG"
case "$LANGTAG" in en-US) LNAME=English ;; en-GB) LNAME=EnglishInternational ;; de-DE) LNAME=German ;; *) LNAME="$LANGTAG" ;; esac
OUT="${OUT:-$(dirname "$SRC")/Tiny11SC_${BUILD}_${LNAME}_x64.iso}"

WIM="$WORK/work.wim"
wimlib-imagex export "$SRCWIM" "$IDX" "$WIM" >/dev/null       # same compression: a copy, not a recompress

# ---- registry, offline ---------------------------------------------------------------------
log "registry: extracting hives"
wimlib-imagex extract "$WIM" 1 /Windows/System32/config/SYSTEM /Windows/System32/config/SOFTWARE \
    /Users/Default/NTUSER.DAT --dest-dir="$WORK/hives" --no-acls >/dev/null
# Record every service Start value install-SYSTEM.reg is about to change, from the hive itself,
# so restore.ps1 writes back what THIS build shipped and never a guess.
: > "$WORK/stage/services.orig"
for s in $(grep -oE 'Services\\[A-Za-z0-9_]+\]' "$HERE/reg/install-SYSTEM.reg" | sed 's/Services\\//; s/\]//' | sort -u); do
    v=$(hivexget "$WORK/hives/SYSTEM" "ControlSet001\\Services\\$s" Start 2>/dev/null || true)
    [ -n "$v" ] || continue
    case "$s" in DiagTrack|dmwappushservice) g=telemetry ;; edgeupdate*) continue ;; *) g=defender ;; esac
    printf '%s %s %s\r\n' "$g" "$s" "$v" >> "$WORK/stage/services.orig"
done
log "recorded original start values: $(wc -l < "$WORK/stage/services.orig") services"
merge() {   # merge <hive> <prefix> <regfile> - hivexregedit exits 0 on success only
    hivexregedit --merge --prefix "$2" "$1" "$3" || { echo "hivexregedit failed on $3" >&2; exit 1; }
}
cp "$WORK/hives/SYSTEM" "$WORK/hives/SYSTEM.orig"
merge "$WORK/hives/SYSTEM"     'HKEY_LOCAL_MACHINE\SYSTEM'   "$HERE/reg/install-SYSTEM.reg"
merge "$WORK/hives/SOFTWARE"   'HKEY_LOCAL_MACHINE\SOFTWARE' "$HERE/reg/install-SOFTWARE.reg"
merge "$WORK/hives/NTUSER.DAT" 'HKEY_CURRENT_USER'           "$HERE/reg/install-DEFAULT.reg"
# Read back, so a merge that "succeeded" without writing is caught here and not at first boot.
chk() { local got; got=$(hivexget "$1" "$2" "$3" 2>/dev/null || true)
        [ "$got" = "$4" ] || { echo "registry check FAILED: $2\\$3 = '$got', want '$4'" >&2; exit 1; }; }
chk "$WORK/hives/SYSTEM"   'ControlSet001\Services\WinDefend' Start '4'
chk "$WORK/hives/SYSTEM"   'ControlSet001\Services\WdFilter'  Start '4'
chk "$WORK/hives/SYSTEM"   'ControlSet001\Control\CI\Policy' VerifiedAndReputablePolicyState '0'
chk "$WORK/hives/SOFTWARE" 'Microsoft\Windows\CurrentVersion\OOBE' BypassNRO '1'
chk "$WORK/hives/SOFTWARE" 'Microsoft\Windows\CurrentVersion\ReserveManager' ShippedWithReserves '0'
chk "$WORK/hives/SOFTWARE" 'Policies\Microsoft\Windows\CloudContent' DisableWindowsConsumerFeatures '1'
! hivexget "$WORK/hives/SYSTEM" 'ControlSet001\Services\edgeupdate' >/dev/null 2>&1 || { echo "registry check FAILED: edgeupdate service still present" >&2; exit 1; }
! hivexget "$WORK/hives/NTUSER.DAT" 'Software\Microsoft\Windows\CurrentVersion\Run' OneDriveSetup >/dev/null 2>&1 || { echo "registry check FAILED: OneDriveSetup still runs at logon" >&2; exit 1; }
# Windows Update must be exactly as shipped: the updater drives it, and a self-updating
# StandaloneVM turns Windows' own updating back on (ADR-updater section 17).
for s in wuauserv UsoSvc WaaSMedicSvc BITS DoSvc CryptSvc TrustedInstaller Schedule; do
    a=$(hivexget "$WORK/hives/SYSTEM.orig" "ControlSet001\\Services\\$s" Start 2>/dev/null || echo absent)
    b=$(hivexget "$WORK/hives/SYSTEM" "ControlSet001\\Services\\$s" Start 2>/dev/null || echo absent)
    [ "$a" = "$b" ] && [ "$a" != absent ] || { echo "registry check FAILED: $s Start '$a' -> '$b' - the update path must stay as shipped" >&2; exit 1; }
done
rm -f "$WORK/hives/SYSTEM.orig"

# ---- files, offline: nothing here is owned by WinSxS ----------------------------------------
log "image: deleting Edge/EdgeCore/EdgeWebView/EdgeUpdate and Winre.wim, adding tiny11sc"
for f in strip.ps1 restore.ps1; do cp "$HERE/guest/$f" "$WORK/stage/$f"; done
# cmd.exe wants CRLF; the repo stores LF.
for f in SetupComplete.cmd tiny11sc.cmd; do sed 's/\r*$/\r/' "$HERE/guest/$f" > "$WORK/stage/$f"; done
{
    echo "tiny11sc built $(date -u +%Y-%m-%dT%H:%M:%SZ) from $(basename "$SRC") (sha256 $(sha256sum "$SRC" | cut -d' ' -f1))"
    echo "edition: $EDITION, build $BUILD"
    echo "repo: $(git -C "$HERE" rev-parse --short HEAD 2>/dev/null || echo unknown)"
} | sed 's/$/\r/' > "$WORK/stage/BUILD.txt"
cat > "$WORK/update.cmds" <<EOF
delete --force --recursive '/Program Files (x86)/Microsoft/Edge'
delete --force --recursive '/Program Files (x86)/Microsoft/EdgeCore'
delete --force --recursive '/Program Files (x86)/Microsoft/EdgeWebView'
delete --force --recursive '/Program Files (x86)/Microsoft/EdgeUpdate'
delete --force '/Windows/System32/Recovery/Winre.wim'
add '$WORK/hives/SYSTEM' '/Windows/System32/config/SYSTEM'
add '$WORK/hives/SOFTWARE' '/Windows/System32/config/SOFTWARE'
add '$WORK/hives/NTUSER.DAT' '/Users/Default/NTUSER.DAT'
add '$WORK/stage/SetupComplete.cmd' '/Windows/Setup/Scripts/SetupComplete.cmd'
add '$WORK/stage/strip.ps1' '/Windows/tiny11sc/strip.ps1'
add '$WORK/stage/restore.ps1' '/Windows/tiny11sc/restore.ps1'
add '$WORK/stage/tiny11sc.cmd' '/Windows/tiny11sc/tiny11sc.cmd'
add '$WORK/stage/services.orig' '/Windows/tiny11sc/services.orig'
add '$WORK/stage/BUILD.txt' '/Windows/tiny11sc/BUILD.txt'
EOF
wimlib-imagex update "$WIM" 1 < "$WORK/update.cmds" >/dev/null
wimlib-imagex info "$WIM" 1 --image-property DISPLAYDESCRIPTION="$EDITION, tiny11 serviceable core (tiny11sc) $BUILD" >/dev/null

# LZX, NOT LZMS/solid. Measured 2026-11-21 on 26300.9457: Pro alone is 4.68 GB even solid, over
# ISO9660's 4 GiB file limit; a solid WIM cannot be split, and the rig's xorriso writes no UDF.
# So the layout build-unattended-iso.sh already proved on the rig: LZX, split into .swm, which
# Setup reads natively and still selects by image name. The export drops the deleted payload.
log "image: writing the final WIM"
FINAL="$WORK/final.wim"
wimlib-imagex export "$WIM" 1 "$FINAL" >/dev/null
rm -f "$WIM"

# ---- read the result back -------------------------------------------------------------------
log "image: verifying the result"
wimlib-imagex dir "$FINAL" 1 > "$WORK/final.lst"
wimlib-imagex dir "$SRCWIM" "$IDX" > "$WORK/src.lst"
for p in '/Program Files (x86)/Microsoft/Edge' '/Program Files (x86)/Microsoft/EdgeCore' \
         '/Program Files (x86)/Microsoft/EdgeWebView' '/Program Files (x86)/Microsoft/EdgeUpdate' \
         '/Windows/System32/Recovery/Winre.wim'; do
    ! grep -qxF "$p" "$WORK/final.lst" || { echo "check FAILED: $p is still in the image" >&2; exit 1; }
done
for p in /Windows/Setup/Scripts/SetupComplete.cmd /Windows/tiny11sc/strip.ps1 /Windows/tiny11sc/restore.ps1 \
         /Windows/tiny11sc/tiny11sc.cmd /Windows/tiny11sc/services.orig \
         /Windows/System32/wuaueng.dll /Windows/System32/wuapi.dll /Windows/System32/Dism.exe /Windows/System32/expand.exe \
         /Windows/System32/WindowsPowerShell/v1.0/powershell.exe /Windows/Microsoft.NET/Framework64/v4.0.30319/csc.exe; do
    grep -qixF "$p" "$WORK/final.lst" || { echo "check FAILED: $p missing from the image" >&2; exit 1; }
done
# The component store is the shipped one: the same entry list under WinSxS and servicing.
for d in /Windows/WinSxS/ /Windows/servicing/; do
    a=$(grep -c "^${d}" "$WORK/src.lst"); b=$(grep -c "^${d}" "$WORK/final.lst")
    cmp -s <(grep "^${d}" "$WORK/src.lst") <(grep "^${d}" "$WORK/final.lst") \
        || { echo "check FAILED: $d differs from the source image ($a -> $b entries)" >&2; exit 1; }
    log "  $d unchanged ($b entries)"
done
rm -f "$SRCWIM"

WSZ=$(stat -c%s "$FINAL")
if [ "$WSZ" -lt 4294967296 ]; then
    mv "$FINAL" "$WORK/iso/sources/install.wim"
else
    wimlib-imagex split "$FINAL" "$WORK/iso/sources/install.swm" 3500 >/dev/null 2>"$WORK/split.log" \
        || { cat "$WORK/split.log" >&2; exit 1; }
    # verify's stderr is only "no integrity information" warnings when it passes; kept for a failure.
    wimlib-imagex verify "$WORK/iso/sources/install.swm" --ref="$WORK/iso/sources/install*.swm" >/dev/null 2>"$WORK/verify.log" \
        || { cat "$WORK/verify.log" >&2; exit 1; }
    rm -f "$FINAL"
fi
log "install image: $(( WSZ / 1048576 )) MiB as $(cd "$WORK/iso/sources" && ls install* | tr '\n' ' ')"

# ---- boot.wim: Setup (index 2) takes Qubes HVMs without a TPM or Secure Boot ----------------
log "boot.wim: LabConfig bypass in Setup's SYSTEM hive"
wimlib-imagex extract "$WORK/iso/sources/boot.wim" 2 /Windows/System32/config/SYSTEM --dest-dir="$WORK/boothive" --no-acls >/dev/null
merge "$WORK/boothive/SYSTEM" 'HKEY_LOCAL_MACHINE\SYSTEM' "$HERE/reg/boot-SYSTEM.reg"
chk "$WORK/boothive/SYSTEM" 'Setup\LabConfig' BypassTPMCheck '1'
echo "add '$WORK/boothive/SYSTEM' '/Windows/System32/config/SYSTEM'" | wimlib-imagex update "$WORK/iso/sources/boot.wim" 2 --rebuild >/dev/null

# ---- the ISO: the layout build-unattended-iso.sh proved on the rig --------------------------
# strict ISO9660 (uppercase PVD names - CDBOOT finds BOOTMGR there) + Joliet long names (Setup
# reads that tree), El Torito BIOS + UEFI, -d for extensionless names. Read that script's NOTE.
log "writing $OUT"
VOL="TINY11SC_${BUILD%%.*}"
xorriso -as mkisofs -iso-level 3 -J -joliet-long -D -N -d \
    -V "$VOL" \
    -b boot/etfsboot.com -no-emul-boot -boot-load-size 8 \
    -eltorito-alt-boot -e efi/microsoft/boot/efisys.bin -no-emul-boot \
    -o "$OUT" "$WORK/iso" 2>"$WORK/xorriso.log" || { cat "$WORK/xorriso.log" >&2; exit 1; }
DELTA="${OUT%.iso}.vendor-delta.txt"
{
    echo "media: $(basename "$OUT")   sha256 $(sha256sum "$OUT" | cut -d' ' -f1)"
    echo "built from: $(basename "$SRC")   sha256 $(sha256sum "$SRC" | cut -d' ' -f1)"
    echo "edition kept: $EDITION (source index $IDX), build $BUILD; repo $(git -C "$HERE" rev-parse --short HEAD 2>/dev/null || echo unknown)"
    echo
    echo "install image: one edition (LZX, split into .swm when over 4 GiB). Inside it:"
    sed -n 's/^delete --force \(--recursive \)\{0,1\}/  DELETED /p' "$WORK/update.cmds"
    echo "  ADDED   /Windows/Setup/Scripts/SetupComplete.cmd, /Windows/tiny11sc/* (strip, restore, services.orig, BUILD.txt)"
    echo "  REGISTRY merged: mgmt/tiny11sc/reg/install-{SYSTEM,SOFTWARE,DEFAULT}.reg"
    echo "boot.wim index 2: mgmt/tiny11sc/reg/boot-SYSTEM.reg (LabConfig)"
    echo "At install time strip.ps1 removes capabilities, features and provisioned apps through DISM;"
    echo "C:\\Windows\\tiny11sc\\removed.json lists them and tiny11sc.cmd adds any back."
} > "$DELTA"
log "done: $OUT ($(( $(stat -c%s "$OUT") / 1048576 )) MiB); delta in $DELTA"
