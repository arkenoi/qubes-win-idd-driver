#!/bin/bash
# DID xenvbd TELL WINDOWS THE BOOT DISK HAS A VOLATILE WRITE CACHE?
#
# WHY THIS ONE FACT MATTERS. In the xenvbd we ship (upstream 054c2e5, out of the QWT MSI) the whole
# durability contract hangs off a single boolean:
#   src/xenvbd/target.c ~362   Caching->WriteCacheEnable = FrontendGetFlushCache(Frontend)
#   src/xenvbd/target.c ~277   TargetSyncCache(): if NEITHER feature-flush-cache NOR feature-barrier
#                              is advertised by the backend, complete SCSIOP_SYNCHRONIZE_CACHE with
#                              SRB_STATUS_SUCCESS *without sending anything* ("just succceed the SRB")
# So there are two very different worlds and they need different fixes:
#   WriteCacheEnabled = TRUE  -> the backend advertised feature-flush-cache. Windows relies on
#      SYNCHRONIZE_CACHE for durability, and those flushes really do reach the backend. The only
#      remaining hole is the RUNTIME DOWNGRADE: FrontendRemoveFeature() permanently clears the
#      feature on a backend error, Windows never re-reads MODE SENSE, and every later flush then
#      silently no-ops while Windows still believes the disk is write-back.
#   WriteCacheEnabled = FALSE -> the backend advertised no flush support. Windows treats the disk as
#      write-through and stops relying on flushes, so the no-op flush is CONSISTENT rather than a
#      lie - and durability instead rests entirely on the backend not acknowledging a write before
#      it is durable, which is a question about dom0's storage path, not about Windows.
# Either way this cannot be guessed. It is a boolean the OS will hand over if asked.
#
# HOW. IOCTL_DISK_GET_CACHE_INFORMATION (0x000740D4) on \\.\PhysicalDriveN returns
# DISK_CACHE_INFORMATION, whose third byte is WriteCacheEnabled - the same value Device Manager's
# "Enable write caching on the device" checkbox shows. It is the DEVICE's answer, obtained by the
# disk class driver from the MODE SENSE caching page, i.e. exactly what xenvbd reported.
#
# WHY NOT THE REGISTRY. Device Parameters\Disk\UserWriteCacheSetting is only the USER OVERRIDE and is
# absent on a default guest (measured: absent on win10-abt), so reading it answers a different
# question and reads as "no cache" when nothing was overridden. The flush probe reports that key too;
# this reports what the device itself claims.
#
# The IOCTL failing is a RESULT, not a hiccup: a driver that does not implement it is telling us
# something, so the error is printed rather than folded into a false FALSE.
#
# Usage:  VM=win10-abt mgmt/harness/disk-cache-probe.sh
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2

VM="${VM:?set VM to a guest answering qrexec}"
OUT="${OUT:-/home/user/rel/cache-probe-$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$OUT"
say(){ echo "[$(date -u +%H:%M:%S)] $*" | tee -a "$OUT/summary.log"; }

source mgmt/harness/vmlock.sh
vm_lock "$VM"
trap 'vm_unlock "$VM"' EXIT
source mgmt/harness/e2e-wait.sh
w_alive "$VM" || { say "VOID: $VM is not answering qrexec"; exit 2; }

read -r -d '' PS <<'EOPS'
$ErrorActionPreference='SilentlyContinue'
Add-Type -Language CSharp @'
using System;
using System.Runtime.InteropServices;
public static class DiskCache {
  [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
  static extern IntPtr CreateFileW(string p, uint access, uint share, IntPtr sa, uint disp, uint flags, IntPtr tmpl);
  [DllImport("kernel32.dll", SetLastError=true)]
  static extern bool DeviceIoControl(IntPtr h, uint code, IntPtr inBuf, uint inSz,
                                     byte[] outBuf, uint outSz, out uint ret, IntPtr ov);
  [DllImport("kernel32.dll", SetLastError=true)] static extern bool CloseHandle(IntPtr h);
  // CTL_CODE(FILE_DEVICE_DISK=7, 0x35, METHOD_BUFFERED=0, FILE_READ_ACCESS=1)
  const uint IOCTL_DISK_GET_CACHE_INFORMATION = 0x000740D4;
  public static string Query(int n) {
    // GENERIC_READ (0x80000000), share read+write. The first version of this opened with ZERO
    // access on the reasoning that a query IOCTL needs no data access - that was wrong and every
    // disk came back "ioctl-failed:5", ERROR_ACCESS_DENIED (measured on win10-abt 2026-09-10):
    // IOCTL_DISK_GET_CACHE_INFORMATION is defined with FILE_READ_ACCESS, so the handle has to
    // carry read access or the I/O manager refuses it before the driver ever sees it. A read-only
    // handle to a disk with mounted volumes is permitted; it is a WRITE handle that would not be.
    IntPtr h = CreateFileW(@"\\.\PhysicalDrive" + n, 0x80000000, 3, IntPtr.Zero, 3, 0, IntPtr.Zero);
    if (h == (IntPtr)(-1)) return "open-failed:" + Marshal.GetLastWin32Error();
    try {
      byte[] b = new byte[64]; uint got;
      if (!DeviceIoControl(h, IOCTL_DISK_GET_CACHE_INFORMATION, IntPtr.Zero, 0, b, (uint)b.Length, out got, IntPtr.Zero))
        return "ioctl-failed:" + Marshal.GetLastWin32Error();
      // DISK_CACHE_INFORMATION: [0] ParametersSavable [1] ReadCacheEnabled [2] WriteCacheEnabled
      return "savable:" + (b[0]!=0) + "|read:" + (b[1]!=0) + "|WRITE:" + (b[2]!=0);
    } finally { CloseHandle(h); }
  }
}
'@
$disks = @(Get-CimInstance -Namespace root\Microsoft\Windows\Storage -ClassName MSFT_Disk)
foreach ($d in $disks) {
  $r = [DiskCache]::Query([int]$d.Number)
  Write-Host ("DISK" + $d.Number + "=boot:" + [bool]$d.IsBoot + "|bus:" + $d.BusType + "|model:" + ($d.Model).Trim() + "|" + $r)
}
$b = @($disks | Where-Object { $_.IsBoot } | Select-Object -First 1)
if ($b.Count -eq 1) { Write-Host ("BOOTCACHE=" + [DiskCache]::Query([int]$b[0].Number)) }
else { Write-Host ("BOOTCACHE=no-single-boot-disk:" + $b.Count) }
Write-Host "PROBE_END=1"
EOPS

PS1="$OUT/disk-cache-probe.ps1"
printf '%s\n' "$PS" > "$PS1"
QTEST_VM=$VM timeout -k 5 90 ./tools/qtest push "$PS1" >/dev/null 2>&1 || { say "FAIL: could not push"; exit 2; }
INC="${QTEST_INCOMING:-C:\\Users\\user\\Documents\\QubesIncoming\\$(hostname)}"
QTEST_VM=$VM timeout -k 5 240 ./tools/qtest run \
  "powershell -NoProfile -ExecutionPolicy Bypass -File \"$INC\\disk-cache-probe.ps1\"" 2>/dev/null | tr -d '\r' > "$OUT/probe.raw"

grep -aq '^PROBE_END=1' "$OUT/probe.raw" || {
  say "FAIL: the probe did not run to completion - nothing may be read off it"
  say "      raw: $OUT/probe.raw"; sed -n '1,20p' "$OUT/probe.raw" | tee -a "$OUT/summary.log"; exit 2; }

grep -aoE '^(DISK[0-9]+|BOOTCACHE)=.*' "$OUT/probe.raw" | tee -a "$OUT/summary.log"
bc=$(grep -aoE '^BOOTCACHE=.*' "$OUT/probe.raw" | head -1 | sed 's/^BOOTCACHE=//')
case "$bc" in
  *WRITE:True*)
    say "VERDICT: xenvbd REPORTS A VOLATILE WRITE CACHE on the boot disk, so the backend advertised"
    say "         feature-flush-cache and Windows is relying on SYNCHRONIZE_CACHE for durability."
    say "         The 'neither feature advertised' no-op branch is EXCLUDED. The variant still live is"
    say "         the RUNTIME DOWNGRADE: FrontendRemoveFeature() clearing the feature after Windows"
    say "         has already cached WriteCacheEnable=1 and will never re-read it." ;;
  *WRITE:False*)
    say "VERDICT: NO WRITE CACHE IS REPORTED on the boot disk. Windows treats it as write-through, so"
    say "         it does not depend on flushes and xenvbd's no-op SYNCHRONIZE_CACHE is consistent"
    say "         rather than a lie. Durability then rests on the backend not acknowledging a write"
    say "         before it is durable - a dom0 storage-path question, NOT a Windows-side one, and one"
    say "         this qube cannot inspect (no dom0 shell): it needs the owner." ;;
  *)
    say "VERDICT: UNDETERMINED - the boot disk's cache state could not be read ('$bc'). That is a"
    say "         result about the driver, not a hiccup to retry away: record it as such." ;;
esac
say "raw: $OUT/probe.raw"
