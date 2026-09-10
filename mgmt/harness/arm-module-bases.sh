#!/bin/bash
# CLASS B DIAGNOSIS: record the guest's kernel module bases EVERY BOOT, so a wedge becomes readable.
#
# THE PROBLEM THIS SOLVES. Class B (findings/issues.md, guest-stability P1) is a Windows MP spin: on
# specimen 2, three vCPUs sat at guest RIP fffff800038bfcfe / fffff800038bfd00 with per-vCPU RSP
# IDENTICAL across three dumps spanning nine minutes, exiting on EXIT_REASON_PAUSE_INSTRUCTION. The
# defect is therefore in Windows kernel code - and we cannot say WHICH code, because:
#   * Xen prints no guest code bytes and no guest stack for an HVM domain, so the dump gives a raw
#     RIP and nothing else;
#   * Windows KASLR randomises the module bases every boot, so an offset resolved against ANOTHER
#     boot's ntoskrnl is meaningless;
#   * and the guest is wedged, so nothing can be run inside it to ask after the fact.
# The information needed to resolve that RIP exists only DURING the boot that later wedges, and
# nobody was recording it. That is the whole reason specimen 2's function is unknown.
#
# So record it up front. This arms a guest so that every boot appends its kernel module table -
# module name, base address, size - to a file on the PERSISTENT volume, before anything can wedge.
# Any later capture then resolves: module + RVA, and the RVA can be matched against that build's
# symbols offline (tools/resolve-guest-rip.py does the arithmetic).
#
# WHY psapi AND NOT WMI. Win32_SystemDriver and driverquery give paths and states but NOT base
# addresses, which is the one field that matters here. EnumDeviceDrivers + GetDeviceDriverBaseNameA
# (psapi) return exactly the base/name pairs for every loaded kernel module, from user mode, and are
# documented API rather than an undocumented NtQuerySystemInformation class.
#
# WHERE IT WRITES, and why not C:. The Q: volume is the guest's PRIVATE volume and PERSISTS across
# the reboots and re-primes that wipe C: on these testbeds; a record of the boot that wedges is
# worthless if it dies with that boot. (Same reason the install-reboot audit writes there.)
#
# THIS IS RIG DIAGNOSTIC ARMING, NOT A PRODUCT CHANGE. It is pushed and scheduled by the harness on
# a testbed guest; nothing here is added to the MSI or to the shipped guest scripts, because users
# do not need it and shipping a diagnostic to make a diagnosis on our own rig would be a behaviour
# change nobody asked for.
#
# Usage:  VM=win10-xyz mgmt/harness/arm-module-bases.sh          # arm it (idempotent)
#         VM=win10-xyz mgmt/harness/arm-module-bases.sh --dump   # pull what has been recorded
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2

VM="${VM:?set VM}"
MODE="${1:-arm}"
OUT="${OUT:-/home/user/rel/modbases-$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$OUT"
say(){ echo "[$(date -u +%H:%M:%S)] $*" | tee -a "$OUT/summary.log"; }

source mgmt/harness/vmlock.sh
vm_lock "$VM"
trap 'vm_unlock "$VM"' EXIT
source mgmt/harness/e2e-wait.sh
w_alive "$VM" || { say "VOID: $VM is not answering qrexec"; exit 2; }

INC="${QTEST_INCOMING:-C:\\Users\\user\\Documents\\QubesIncoming\\$(hostname)}"

if [ "$MODE" = --dump ]; then
  # Pull the record. Printed as-is; resolution is done here, not in the guest.
  gq(){ QTEST_VM=$VM timeout -k 5 "${2:-180}" ./tools/qtest run "$1" 2>/dev/null | tr -d '\r'; }
  gq 'cmd /c type "Q:\Qubes Logs\module-bases.txt" 2>nul || type "C:\module-bases.txt" 2>nul' 300 > "$OUT/module-bases.txt"
  n=$(grep -ac 'MODBASE' "$OUT/module-bases.txt" 2>/dev/null || echo 0)
  say "pulled $n module records -> $OUT/module-bases.txt"
  [ "$n" = 0 ] && { say "NOTHING RECORDED. Either the guest was never armed, or it has not rebooted"
                    say "since arming. Missing data fails: do not resolve a RIP against this file."; exit 1; }
  say "resolve a captured RIP with:  tools/resolve-guest-rip.py $OUT/module-bases.txt 0xfffff800038bfcfe"
  exit 0
fi

cat > "$OUT/record-module-bases.ps1" <<'PS1'
# Append this boot's kernel module table to the persistent volume. Runs as SYSTEM at boot.
$ErrorActionPreference = 'SilentlyContinue'
Add-Type -Language CSharp @'
using System; using System.Text; using System.Runtime.InteropServices;
public static class Drv {
  [DllImport("psapi.dll", SetLastError=true)]
  public static extern bool EnumDeviceDrivers(IntPtr[] image, uint cb, out uint needed);
  [DllImport("psapi.dll", SetLastError=true, CharSet=CharSet.Ansi)]
  public static extern int GetDeviceDriverBaseNameA(IntPtr image, StringBuilder name, int size);
}
'@
# Two-call pattern: ask for the size, then fill. A fixed-size guess would silently TRUNCATE the
# table, and a truncated table is worse than none - it would resolve a RIP to the wrong module.
[uint32]$need = 0
[void][Drv]::EnumDeviceDrivers(@(), 0, [ref]$need)
$count = [int]($need / [IntPtr]::Size)
if ($count -le 0) { return }
$arr = New-Object IntPtr[] $count
if (-not [Drv]::EnumDeviceDrivers($arr, $need, [ref]$need)) { return }

$dir = 'Q:\Qubes Logs'
if (-not (Test-Path $dir)) { $dir = $env:SystemDrive + '\' }
$path = Join-Path $dir 'module-bases.txt'

$boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o')
$lines = New-Object System.Collections.Generic.List[string]
$lines.Add("=== BOOT $boot host=$env:COMPUTERNAME recorded=$([datetime]::UtcNow.ToString('o')) modules=$count")
foreach ($p in $arr) {
  $sb = New-Object System.Text.StringBuilder 260
  if ([Drv]::GetDeviceDriverBaseNameA($p, $sb, $sb.Capacity) -gt 0) {
    $lines.Add(("MODBASE boot={0} base=0x{1} name={2}" -f $boot, $p.ToString('x16'), $sb.ToString()))
  }
}
# APPEND, never overwrite: the record of an earlier boot is exactly what is needed if a LATER boot
# is the one that wedges and cannot be asked anything.
Add-Content -LiteralPath $path -Value $lines -Encoding ASCII
PS1

QTEST_VM=$VM timeout -k 5 90 ./tools/qtest push "$OUT/record-module-bases.ps1" >/dev/null 2>&1 \
  || { say "FAIL: could not push the recorder"; exit 2; }

# Park it somewhere that survives, then arm a boot task. QubesIncoming is under the user profile and
# is not a durable home for something that must run before a session exists.
QTEST_VM=$VM timeout -k 5 240 ./tools/qtest run \
  "cmd /c md \"C:\\Qubes Tools\\diag\" 2>nul & copy /y \"$INC\\record-module-bases.ps1\" \"C:\\Qubes Tools\\diag\\record-module-bases.ps1\"" >/dev/null 2>&1

armed=$(QTEST_VM=$VM timeout -k 5 240 ./tools/qtest run \
  "schtasks /create /tn QwtModuleBases /ru SYSTEM /sc onstart /rl HIGHEST /f /tr \"powershell -NoProfile -ExecutionPolicy Bypass -File \\\"C:\\Qubes Tools\\diag\\record-module-bases.ps1\\\"\"" 2>/dev/null | tr -d '\r')
say "schtasks: ${armed:-<no output>}"

# RUN IT NOW TOO, so this boot is recorded rather than only future ones - and so the arming is
# PROVEN to work rather than assumed. A task that was created but silently cannot run is exactly the
# kind of "armed" that turns out to be absent when it is finally needed.
QTEST_VM=$VM timeout -k 5 300 ./tools/qtest run \
  "powershell -NoProfile -ExecutionPolicy Bypass -File \"C:\\Qubes Tools\\diag\\record-module-bases.ps1\"" >/dev/null 2>&1

check=$(QTEST_VM=$VM timeout -k 5 240 ./tools/qtest run \
  'cmd /c find /c "MODBASE" "Q:\Qubes Logs\module-bases.txt" 2>nul || find /c "MODBASE" "C:\module-bases.txt" 2>nul' 2>/dev/null | tr -d '\r' | grep -aoE '[0-9]+$' | tail -1)
if [ -n "${check:-}" ] && [ "$check" -gt 0 ] 2>/dev/null; then
  say "ARMED AND PROVEN: $check module records written on this boot."
  say "  A later wedge on this guest is now resolvable: capture the RIP with debug-keys d/v, then"
  say "  VM=$VM mgmt/harness/arm-module-bases.sh --dump  and  tools/resolve-guest-rip.py"
else
  say "FAIL: the recorder wrote NOTHING on this boot (found=${check:-none})."
  say "  Do not treat this guest as armed. An 'armed' guest whose recorder does not run is the exact"
  say "  failure that left specimen 2 unresolvable - the whole point is that the data must exist"
  say "  BEFORE the wedge, and it does not."
  exit 1
fi
