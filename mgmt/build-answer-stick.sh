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
#        REAL_STOCK_EXE=<exe> install GENUINE upstream QWT instead (qubes-tools-*.exe from the
#                             vendor ISO) - the starting point for the upgrade-path tests
#        OUT=<img>            output image (default ~/win-iso/answer-usb.img)
#        LOCALE=              en-GB | en-US ... MUST match the media or Setup ignores the file
#        KEYBOARD=            input locale id, defaulted per LOCALE
#        INSTALL_FLAGS=       flags for install.cmd (default /idd)
#        WITH_KEY=0           omit the generic install key (default 1: retail multi-edition
#                             media needs a key to select the edition)
#        PRIMER=1             stick installs ONLY the resident primer hook (no QWT) - used to
#                             provision pristine ST0 goldens that clones can be driven from
#        PRIME_JOB=<dir>      build a JOB stick for an already-primed guest; <dir> is staged at
#                             \qubes-prime\ and must contain onboot.cmd
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
    # SUPPRESS_XEN_REBOOT_PROMPT=1: set xenbus_monitor's AutoReboot BEFORE the installer runs.
    # Needed to test an OLD build on this rig: releases up to 4.3.1 set that key only AFTER
    # msiexec, so the "Xen PV Storage Host Adapter needs to restart the system" modal appears
    # during the install and BLOCKS it - measured 2026-08-14, 70+ minutes, qrexec never came
    # up, and the dialog was not clickable from dom0. That defect is fixed in the package
    # itself from 4.3.2 on; this switch exists so an older package can still be installed here
    # and its POST-INSTALL behaviour observed, which is the only way to reproduce a field
    # report against the exact build the reporter ran. It changes nothing inside the package.
    _prereg=""
    if [ "${SUPPRESS_XEN_REBOOT_PROMPT:-0}" = 1 ]; then
        _prereg='reg add "HKLM\SYSTEM\CurrentControlSet\Services\xenbus_monitor\Parameters" /v AutoReboot /t REG_DWORD /d 1 /f /reg:64 >> C:\qubes-win-idd-setup.log 2>&1'
        echo "payload: xenbus_monitor AutoReboot pre-set (rig affordance for pre-4.3.2 packages)"
    fi
    cat > "$WORK/payload/setup.cmd" <<EOF
@echo off
rem Found by the FirstLogonCommands drive-letter scan: <drive>:\payload\setup.cmd
echo === answer-stick payload === >> C:\qubes-win-idd-setup.log
$_prereg
call "%~dp0release\install.cmd" /auto ${INSTALL_FLAGS-/idd} >> C:\qubes-win-idd-setup.log 2>&1
echo install.cmd rc=%ERRORLEVEL% >> C:\qubes-win-idd-setup.log
EOF
    echo "payload: release package staged, install flags ${INSTALL_FLAGS-/idd}"
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

# REAL_STOCK_EXE: install GENUINE upstream Qubes Windows Tools, by running the vendor's own
# qubes-tools-<ver>.exe from its ISO. Not the same thing as STOCK_SETUP above, which installs
# the stock MSI through OUR installer to keep a benchmark control single-variable. This one
# exists for the UPGRADE path: forum 42717 post 27 reports that upgrading a working stock-QWT
# qube with a newer build drops the boot disk back to emulated IDE and the next boot crashes
# (0x7B), leaving the qube broken until the user knows the safe-mode trick. Reproducing that
# needs a guest carrying real stock QWT first, installed exactly as a user would have it.
if [ -n "${REAL_STOCK_EXE:-}" ]; then
    [ -f "$REAL_STOCK_EXE" ] || { echo "REAL_STOCK_EXE not a file: $REAL_STOCK_EXE" >&2; exit 1; }
    [ -n "${RELEASE_SETUP:-}${STOCK_SETUP:-}" ] && { echo "ERROR: REAL_STOCK_EXE is mutually exclusive with RELEASE_SETUP/STOCK_SETUP" >&2; exit 1; }
    mkdir -p "$WORK/payload/stock/certs"
    cp "$REAL_STOCK_EXE" "$WORK/payload/stock/"
    _exe=$(basename "$REAL_STOCK_EXE")

    # TRUST THE VENDOR'S OWN CA, or the install fails with 1603.
    # Stock QWT's drivers are signed by a private self-signed "Qubes Windows Tools" CA. With that CA
    # absent from TrustedPublisher, PnP raises "Would you like to install this device software?" -
    # stock's own ISO README tells a human to click it. Nobody is clicking here, and the installer
    # runs as SYSTEM in session 0 where no dialog is even visible.
    # MEASURED 2026-08-30 on win10-u10: this route staged ZERO certs and the bundle returned
    # "stock installer rc=1603", leaving a guest with testsigning on, no QWT and no qrexec. The
    # older extracted-MSI route (payload/install-qwt.cmd) always seeded these and always worked -
    # dropping the seeding is what this newer route changed.
    # Seeding is the unattended equivalent of the click a human would give: it changes WHO CONSENTS,
    # not what gets installed, so the guest still carries genuine, unmodified stock QWT.
    _ncerts=$(ls "$HERE/stock-certs"/SigningCert*.cer 2>/dev/null | wc -l)
    [ "$_ncerts" -ge 6 ] || { echo "ERROR: expected 6 stock signing certs in $HERE/stock-certs, found $_ncerts" >&2; exit 1; }
    cp "$HERE/stock-certs"/SigningCert*.cer "$WORK/payload/stock/certs/"

    # Written as REAL FILES on the stick, not generated by a stack of `echo` lines into a nested
    # batch script. That generation trick is how "%%ERRORLEVEL%%" and friends kept arriving subtly
    # wrong - the quoting has to survive two layers of cmd parsing and it silently does not.
    cat > "$WORK/payload/stock/run-stock.cmd" <<'RUNSTOCK'
@echo off
rem Runs as SYSTEM (QwtStockInstall onstart task) on the boot AFTER testsigning became active.
set LOG=C:\qubes-win-idd-setup.log
echo === stock QWT install (post-testsigning boot) %DATE% %TIME% >> %LOG%

for %%c in ("C:\stockqwt\certs\*.cer") do (
    certutil -addstore -f Root "%%~c" >> %LOG% 2>&1
    certutil -addstore -f TrustedPublisher "%%~c" >> %LOG% 2>&1
)

start /wait "" "C:\stockqwt\@EXE@" /passive /norestart /log C:\stock-burn.log >> %LOG% 2>&1
set RC=%ERRORLEVEL%
echo stock installer rc=%RC% >> %LOG%
schtasks /delete /tn QwtStockInstall /f >nul 2>&1

if "%RC%"=="0"    goto ok
if "%RC%"=="3010" goto ok

rem FAILED. This guest has no QWT, therefore no qrexec, therefore no way for a log to reach the
rem operator except THE SCREEN. Drop a self-deleting script into the all-users Startup folder and
rem reboot once: autologon fires it, Notepad shows both logs, and `qtest shot` can read them.
rem The marker keeps a failure from becoming a reboot loop.
echo FAILED rc=%RC% - see C:\stock-burn.log >> %LOG%
if exist C:\stockqwt\reported.mark goto done
echo reported > C:\stockqwt\reported.mark
copy /y C:\stockqwt\report.cmd "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp\" >> %LOG% 2>&1
shutdown /r /t 15
goto done

:ok
echo stock QWT installed rc=%RC%, rebooting to bind drivers >> %LOG%
shutdown /r /t 15
:done
exit /b %RC%
RUNSTOCK
    sed -i "s|@EXE@|$_exe|g" "$WORK/payload/stock/run-stock.cmd"

    cat > "$WORK/payload/stock/report.cmd" <<'REPORT'
@echo off
rem Copied into the all-users Startup folder only when the stock install FAILED. Shows the logs on
rem screen (the only channel a QWT-less guest has) and removes itself so it shows exactly once.
start "" notepad C:\qubes-win-idd-setup.log
if exist C:\stock-burn.log start "" notepad C:\stock-burn.log
del "%~f0"
REPORT

    # STOCK NEEDS TESTSIGNING FIRST, and it will not tell you politely: measured 2026-08-15,
    # qubes-tools-4.2.2.exe /passive still puts up its wizard with a modal - "Test signing must
    # be enabled, run the following as an administrator: bcdedit /set testsigning on" - and
    # waits forever. Its own drivers are signed by a private "Qubes Windows Tools" CA, so this
    # is inherent to stock, not something we introduced. Enable testsigning, stage the installer
    # on C:, reboot, and run it from a SYSTEM onstart task on the next boot.
    cat > "$WORK/payload/setup.cmd" <<'SETUPEOF'
@echo off
rem Found by the FirstLogonCommands drive-letter scan: <drive>:\payload\setup.cmd
echo === answer-stick payload (GENUINE upstream QWT) === >> C:\qubes-win-idd-setup.log
mkdir C:\stockqwt 2>nul
rem xcopy, not copy: the exe, its certs\ and both helper scripts all have to land on C: because the
rem stick's drive letter is not stable across boots and the stick may not be attached at all later.
xcopy /e /i /y "%~dp0stock\*" C:\stockqwt\ >> C:\qubes-win-idd-setup.log 2>&1
bcdedit /set testsigning on >> C:\qubes-win-idd-setup.log 2>&1
schtasks /create /tn QwtStockInstall /sc onstart /delay 0000:30 /ru SYSTEM /rl highest /f /tr "cmd /c C:\stockqwt\run-stock.cmd" >> C:\qubes-win-idd-setup.log 2>&1
echo rebooting for testsigning >> C:\qubes-win-idd-setup.log
shutdown /r /t 5
SETUPEOF
    echo "payload: GENUINE stock QWT staged ($_exe) + $_ncerts vendor certs, /passive with burn log"
fi

# PRIMER=1: build a stick that installs ONLY the resident primer hook and no QWT at all. Used to
# provision the pristine ST0 goldens so that CLONES of them can be driven later without a Windows
# reinstall. See mgmt/primer/qubes-prime.cmd for the contamination rules this obeys.
if [ "${PRIMER:-0}" = 1 ]; then
    [ -n "${RELEASE_SETUP:-}${STOCK_SETUP:-}${REAL_STOCK_EXE:-}" ] && { echo "ERROR: PRIMER=1 is mutually exclusive with RELEASE_SETUP/STOCK_SETUP/REAL_STOCK_EXE" >&2; exit 1; }
    mkdir -p "$WORK/payload/prime"
    cp "$HERE/primer/qubes-prime.cmd"   "$WORK/payload/prime/" || exit 1
    cp "$HERE/primer/install-primer.cmd" "$WORK/payload/setup.cmd" || exit 1
    echo "payload: PRIMER only - resident hook, no QWT, testsigning left OFF"
fi

# PRIME_JOB=<dir>: build a JOB stick for an already-provisioned, primed guest. The directory's
# contents are staged at \qubes-prime\ on the stick, and it must contain onboot.cmd - that is the
# entry point the resident hook calls, exactly once, as SYSTEM.
#
# This is the OTHER half of the primer: PRIMER=1 bakes the channel into a golden, PRIME_JOB drives a
# clone of it. Attach the stick with the same qemu-extra-args line reprovision-usb.sh uses, boot,
# and the job runs - no Windows install, no QWT, no qrexec needed.
if [ -n "${PRIME_JOB:-}" ]; then
    [ -d "$PRIME_JOB" ] || { echo "PRIME_JOB not a directory: $PRIME_JOB" >&2; exit 1; }
    [ -f "$PRIME_JOB/onboot.cmd" ] || { echo "ERROR: $PRIME_JOB/onboot.cmd missing - the hook calls that exact name" >&2; exit 1; }
    [ "${PRIMER:-0}" = 1 ] && { echo "ERROR: PRIMER=1 builds the golden, PRIME_JOB drives a clone - not the same stick" >&2; exit 1; }
    mkdir -p "$WORK/qubes-prime"
    cp -r "$PRIME_JOB"/. "$WORK/qubes-prime/" || exit 1
    # A job stick carries NO \payload\setup.cmd on purpose: it is attached to a guest that is
    # already installed, where FirstLogonCommands will never fire again anyway.
    echo "payload: PRIME_JOB staged at \\qubes-prime\\ ($(find "$PRIME_JOB" -type f | wc -l) files)"
fi

cp "$HERE/../guest/firstboot-setup.ps1" "$WORK/payload/" 2>/dev/null || true
# Stage every helper the answer file launches from C:\payload. Missing scripts do not error
# at build time - the `for %%d ... if exist` guards in the answer file silently skip them -
# so an unstaged script is invisible until the guest wedges on the modal it was meant to
# dismiss. Copy them explicitly and FAIL if a referenced one is absent.
for _p in dismiss-restart-prompts.ps1 disable-hw-accel.ps1; do
    if grep -q "payload\\\\$_p" "$UNATTEND" 2>/dev/null; then
        cp "$HERE/../guest/$_p" "$WORK/payload/" \
            || { echo "ERROR: answer file references payload\\$_p but guest/$_p is missing" >&2; exit 1; }
    fi
done

# Rewrite the image IN PLACE. `rm -f` + truncate would give the file a NEW INODE while any
# losetup attached to it keeps the OLD one - `losetup -l` then shows the backing file as
# "(deleted)" and the guest silently reads a STALE stick. Re-pointing the loop needs root,
# which this script does not have when it runs unattended, so instead the inode is never
# changed: truncate to 0 and back to the fixed size preserves it, and because the size is
# CONSTANT the cached loop capacity stays correct too. Both hazards disappear, no sudo.
# (Measured 2026-08-07: a rebuilt stick was served stale to a guest for a full install.)
# IMAGE FORMAT: FAT32, written with mtools (mcopy) - no mount, no root.
# History: the first version needed `sudo mount` because mtools was absent, and unattended
# that BLOCKS forever on a password prompt; it hung the control build twice. An ISO built
# with xorriso avoided root but Windows Setup did not pick the answer file off it. mtools
# gives the format Setup actually reads AND needs no privileges - the right answer to both.
command -v mcopy >/dev/null || { echo "need mtools (mcopy)" >&2; exit 1; }

# Rewrite IN PLACE: rm+create would give the file a new inode while losetup keeps the old
# one ("(deleted)" in losetup -l) and the guest silently reads a STALE stick. Truncating to
# 0 and back to the FIXED size preserves the inode and keeps the cached loop capacity
# correct, so no losetup -c (i.e. no root) is ever needed.
if [ -e "$OUT" ]; then truncate -s 0 "$OUT"; else : > "$OUT"; fi
truncate -s "${SIZE_MB}M" "$OUT"
mkfs.vfat -F 32 -n ANSWER "$OUT" >/dev/null

# mcopy -s copies directories recursively; ::/ is the image root. -Q makes it stop on the
# first failure instead of silently shipping a partial stick.
( cd "$WORK" && for entry in *; do
      MTOOLS_SKIP_CHECK=1 mcopy -Q -i "$OUT" -s "$entry" ::/ \
        || { echo "ERROR: mcopy failed on $entry" >&2; exit 1; }
  done ) || exit 1

# Prove the answer file is actually on the image; a stick without it looks exactly like
# "Setup ignored the answer file" an hour later.
MTOOLS_SKIP_CHECK=1 mdir -i "$OUT" ::/ 2>/dev/null | sed 's/^/  /'
MTOOLS_SKIP_CHECK=1 mdir -i "$OUT" ::/ 2>/dev/null | grep -qi "AUTOUNA" \
    || { echo "ERROR: Autounattend.xml is not on the image" >&2; exit 1; }

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
