#!/bin/bash
# CAN A DISPLAY-MODE CHANGE ALONE TRIGGER THE XEN DIRTY-VRAM WEDGE?
#
# WHERE THIS COMES FROM. A live, never-killed wedge (2026-09-10, wedge-regs.txt) caught Xen 4.19.4
# spinning in the hypervisor with:
#     flush_area_mask <- map_pages_to_xen <- virt_to_xen_l3e <- vunmap <- vfree
#                     <- hap_track_dirty_vram <- dm_op
# Read that stack for what it actually says. dm_op is a hypercall FROM THE DEVICE MODEL, so the
# spinning vCPU is QEMU's stubdomain. hap_track_dirty_vram is the emulated-VGA dirty-region tracking
# QEMU uses to know what to redraw. And it is in a FREE path - vfree/vunmap - so this is the device
# model TEARING DOWN a dirty-VRAM tracking region, not setting one up or using one.
#
# The register's surviving candidate is "early stage 2, around msiexec", inferred from the install log
# stopping two seconds into stage 2. That is a TIME, not a MECHANISM. The mechanism the stack points
# at is narrower and testable: WHAT MAKES QEMU TEAR DOWN A DIRTY-VRAM REGION? A change in the
# framebuffer it is tracking - a display-mode change, a framebuffer resize, the video device being
# reset or re-enumerated.
#
# WHY THIS IS WORTH RUNNING RATHER THAN MORE INSTALLS. 50 consecutive proven reboots of an installed
# guest produced 0 stalls, while installs stall at roughly 3 in 20. So the trigger is something an
# install does and a reboot does not do, or does far more of. A reboot changes the framebuffer about
# twice; an install changes it many times - PV driver install and device re-enumeration, IDD
# activation, the emulated-VGA disable, and the resolution changes each of those causes. If mode
# churn alone reproduces the spin, the trigger is identified and every future test costs minutes
# instead of the ~7 minutes per install that a 3-in-20 rate makes barely affordable.
#
# THE PREMISE IS CHECKED, NOT ASSUMED. This only tests anything if the EMULATED VGA is the active
# display: on a finished "ours" install the IDD is active and the emulated VGA is disabled (code 22),
# and churning modes on the IDD exercises a different code path entirely. The wedge happened while
# the emulated VGA was still live - the install log proves it, since the VGA disable happens ~65 s
# into stage 2 and the wedge hit at 2 s - so the script REFUSES to run on a guest whose emulated VGA
# is already disabled, rather than churning happily and reporting a meaningless 0.
#
# DETECTION IS CPU BURN, not a timeout. A wedged domain spins whole cores (measured on the real one:
# 181% of a core, 100% per pegged vCPU); a busy or slow guest does not. Losing qrexec alone is not a
# wedge - that is the mistake this project has made repeatedly.
#
# NOTHING IS EVER KILLED. A wedged guest is left exactly as it stands and the run STOPS, because
# every previous specimen was destroyed by being killed and the one that survived untouched is the
# only reason the stack above is known.
#
# Usage:  VM=win10-noidd CYCLES=200 mgmt/harness/vram-mode-churn.sh
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2

VM="${VM:?set VM to a guest whose EMULATED VGA is still the active display}"
CYCLES="${CYCLES:-200}"
BATCH="${BATCH:-10}"          # mode changes per guest round trip
OUT="${OUT:-/home/user/rel/vram-churn-$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$OUT"
say(){ echo "[$(date -u +%H:%M:%S)] $*" | tee -a "$OUT/summary.log"; }

source mgmt/harness/vmlock.sh
vm_lock "$VM"
trap 'vm_unlock "$VM"' EXIT
source mgmt/harness/e2e-wait.sh

b64(){ python3 -c "import sys,base64;print(base64.b64encode(sys.argv[1].encode('utf-16-le')).decode())" "$1"; }
gq(){ QTEST_VM=$VM timeout -k 5 "${2:-120}" ./tools/qtest run "$1" 2>/dev/null | tr -d '\r'; }
psp(){ local k="$1"; gq "powershell -NoProfile -ExecutionPolicy Bypass -EncodedCommand $(b64 "$2")" "${3:-180}" \
       | grep -aoE "^$k=.*" | head -1 | sed "s/^$k=//"; }
state(){ qvm-ls --raw-data --fields NAME,STATE 2>/dev/null | awk -F'|' -v v="$VM" '$1==v{print $2}'; }
cput(){ printf '' | qrexec-client-vm "$VM" admin.vm.CurrentState 2>/dev/null | tr -d '\000' | grep -oE 'cputime=[0-9]+' | cut -d= -f2; }

w_alive "$VM" || { say "VOID: $VM is not answering qrexec"; exit 2; }

# --- premise check: is the emulated VGA actually the active display? ------------------------------
# PCI\VEN_1234&DEV_1111 is QEMU's stdvga. ConfigManagerErrorCode 22 means DISABLED, which is what our
# installer does once the IDD is up - and on such a guest this whole test is meaningless.
vga=$(psp VGA '
$d = @(Get-CimInstance Win32_PnPEntity -EA SilentlyContinue | Where-Object { $_.PNPDeviceID -like "PCI\VEN_1234&DEV_1111*" })
if ($d.Count -eq 0) { Write-Host "VGA=absent" }
else { Write-Host ("VGA=" + (($d | ForEach-Object { "err" + $_.ConfigManagerErrorCode }) -join ",")) }' 120)
say "emulated VGA (PCI\\VEN_1234&DEV_1111): ${vga:-<unreadable>}"
case "${vga:-}" in
  VGA\=err0*|err0*) say "premise OK: the emulated VGA is present and ENABLED - mode churn exercises it" ;;
  *absent*) say "REFUSED: no emulated VGA on this guest at all. Churning modes here cannot exercise"
            say "         hap_track_dirty_vram, and a 0 result would mean nothing."; exit 2 ;;
  *) say "REFUSED: the emulated VGA is present but NOT enabled (${vga}). On a finished 'ours' install"
     say "         the IDD is active and the VGA is disabled (code 22); churning modes then exercises"
     say "         a different code path and would report a meaningless 0. Use a /noidd guest, or one"
     say "         captured before the VGA disable."; exit 2 ;;
esac

# --- the churn ------------------------------------------------------------------------------------
# Name the device EXPLICITLY. A NULL device name fails and EnumDisplayDevices enumerates nothing on
# these guests - the desktop is not on \\.\DISPLAY1 - and that misreads as "mode change unsupported".
cat > "$OUT/churn.ps1" <<'GEN'
$ErrorActionPreference='SilentlyContinue'
Add-Type -Language CSharp @'
using System; using System.Runtime.InteropServices;
public static class Disp {
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
  public struct DEVMODE {
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string dmDeviceName;
    public short dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra;
    public int dmFields; public int dmPositionX, dmPositionY;
    public int dmDisplayOrientation, dmDisplayFixedOutput;
    public short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string dmFormName;
    public short dmLogPixels; public int dmBitsPerPel, dmPelsWidth, dmPelsHeight;
    public int dmDisplayFlags, dmDisplayFrequency;
    public int dmICMMethod, dmICMIntent, dmMediaType, dmDitherType, dmReserved1, dmReserved2, dmPanningWidth, dmPanningHeight;
  }
  [DllImport("user32.dll", CharSet=CharSet.Unicode)]
  public static extern int ChangeDisplaySettingsExW(string dev, ref DEVMODE dm, IntPtr hwnd, int flags, IntPtr p);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)]
  public static extern bool EnumDisplaySettingsW(string dev, int mode, ref DEVMODE dm);
}
'@
$dev = $env:QWT_DEV
$modes = @(@(1024,768), @(1280,800), @(1152,864), @(1280,1024), @(800,600))
$n = [int]$env:QWT_N
$ok = 0; $fail = 0
for ($i = 0; $i -lt $n; $i++) {
  $m = $modes[$i % $modes.Length]
  $dm = New-Object Disp+DEVMODE
  $dm.dmDeviceName = $dev
  $dm.dmSize = [short][Runtime.InteropServices.Marshal]::SizeOf($dm)
  [void][Disp]::EnumDisplaySettingsW($dev, -1, [ref]$dm)   # ENUM_CURRENT_SETTINGS
  $dm.dmPelsWidth = $m[0]; $dm.dmPelsHeight = $m[1]
  $dm.dmFields = 0x80000 -bor 0x100000                      # DM_PELSWIDTH | DM_PELSHEIGHT
  $r = [Disp]::ChangeDisplaySettingsExW($dev, [ref]$dm, [IntPtr]::Zero, 0, [IntPtr]::Zero)
  if ($r -eq 0) { $ok++ } else { $fail++ }
  Start-Sleep -Milliseconds 250
}
Write-Host ("CHURN=ok:" + $ok + "|fail:" + $fail)
GEN
QTEST_VM=$VM timeout -k 5 90 ./tools/qtest push "$OUT/churn.ps1" >/dev/null 2>&1 || { say "FAIL: push"; exit 2; }
INC="${QTEST_INCOMING:-C:\\Users\\user\\Documents\\QubesIncoming\\$(hostname)}"

# The guest's desktop is NOT necessarily \\.\DISPLAY1 - name it from what actually carries the
# desktop, or every ChangeDisplaySettingsEx silently returns "bad mode" and the churn does nothing.
dev=$(psp DEV '
$d = @(Get-CimInstance Win32_VideoController -EA SilentlyContinue | Where-Object { $_.CurrentHorizontalResolution -gt 0 } | Select-Object -First 1)
if ($d) { Write-Host ("DEV=" + $d.DeviceID.Replace("VideoController","\\.\DISPLAY")) } else { Write-Host "DEV=" }' 120)
[ -n "${dev:-}" ] || dev='\\.\DISPLAY1'
say "driving device: $dev  (a wrong name makes every change a silent no-op)"

say "=== $CYCLES mode changes in batches of $BATCH on $VM ==="
done_n=0
while [ "$done_n" -lt "$CYCLES" ]; do
  a=$(cput)
  out=$(gq "cmd /c set QWT_DEV=$dev&& set QWT_N=$BATCH&& powershell -NoProfile -ExecutionPolicy Bypass -File \"$INC\\churn.ps1\"" 300 | grep -aoE '^CHURN=.*' | head -1)
  rc=$?
  if [ -z "$out" ]; then
    # No answer. Distinguish a WEDGE from a merely unresponsive guest by what the domain is DOING.
    say "no answer after $done_n changes - classifying by CPU burn, not by the silence"
    x=$(cput); sleep 20; y=$(cput)
    burn=unknown
    [ -n "$x" ] && [ -n "$y" ] && burn=$(python3 -c "print(f'{(int('$y')-int('$x'))/1e9/20*100:.0f}')" 2>/dev/null || echo unknown)
    say "  state=$(state)  burn=${burn}% of a core"
    case "$burn" in
      unknown) say "  could not read cputime - UNCLASSIFIED, do not call this a wedge" ;;
      *) if [ "${burn%%.*}" -ge 60 ] 2>/dev/null; then
           say "  A SPINNING DOMAIN. THIS IS THE WEDGE, and mode churn alone reproduced it."
           say "  IT IS LEFT UNTOUCHED - capture it NOW, before anything else touches it:"
           say "    dom0:  sudo ./11-wedge-forensics.sh $VM --nmi"
           say "    dom0:  sudo xl dmesg -c >/dev/null; sudo xl debug-keys d; sudo xl dmesg > ~/wedge-regs.txt"
           say "           (the CALL TRACE is the whole point - it is what named flush_area_mask)"
           exit 1
         else
           say "  NOT spinning. The guest stopped answering for some other reason - that is a"
           say "  different failure and must not be recorded as this one."
           exit 1
         fi ;;
    esac
    exit 1
  fi
  done_n=$((done_n + BATCH))
  b=$(cput)
  d=unknown
  [ -n "$a" ] && [ -n "$b" ] && d=$(python3 -c "print(f'{(int('$b')-int('$a'))/1e9:.1f}')" 2>/dev/null || echo unknown)
  say "  $done_n/$CYCLES  $out  (guest burned ${d}s of CPU during that batch)"
done
say "=== $CYCLES mode changes, no wedge. Display-mode churn ALONE does not reproduce it ==="
say "    That removes a candidate; it does not exonerate the display path, since the wedge stack is"
say "    still inside hap_track_dirty_vram. The next difference between a churn and an install is"
say "    DEVICE RE-ENUMERATION - the PV driver install resetting/replacing the video device - which"
say "    is a teardown a mode change never performs."
