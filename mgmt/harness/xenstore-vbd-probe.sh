#!/bin/bash
# WHAT DOES THE BLOCK BACKEND ACTUALLY ADVERTISE? Read xenstore FROM INSIDE THE GUEST.
#
# THE QUESTION THIS ANSWERS, AND WHY IT IS THE ONE THAT MATTERS. In the xenvbd we ship, whether a
# Windows flush reaches dom0 at all is decided by two xenstore keys the BACKEND writes:
#     <backend>/feature-flush-cache
#     <backend>/feature-barrier
# With neither present, TargetSyncCache() (src/xenvbd/target.c ~277) completes every
# SCSIOP_SYNCHRONIZE_CACHE with SRB_STATUS_SUCCESS *without sending anything* - its own comment says
# "just succceed the SRB" - and the MODE SENSE caching page reports WriteCacheEnable from
# feature-flush-cache alone (~362). Every other measurement here can only INFER what those keys say.
# This reads them.
#
# WHY IT IS POSSIBLE AT ALL, given there is no dom0 shell and no xenstore CLI in this qube: a PV
# frontend is granted read access to its own backend node, and QWT ships xeniface, whose WMI
# interface (root\wmi, XenProjectXenStore* - older builds: CitrixXenStore*) exposes xenstore
# GetValue/GetChildren to the guest. So the guest can be asked what its backend told it. Nothing in
# this repo had ever used that surface; it was written off as "no xenstore access from here", which
# was true of THIS qube and never true of the guest.
#
# THE CLASS NAMES ARE DISCOVERED, NOT ASSUMED. The provider was renamed from Citrix* to XenProject*
# upstream and Qubes could ship either, so the probe enumerates *XenStore* in root\wmi and uses what
# it finds. If the surface is absent that is a REPORTED RESULT - it means this route to the answer is
# closed and the remaining route is dom0, i.e. the owner - not something to retry or work around.
#
# READ-ONLY: GetValue and GetChildren only. It never writes a xenstore key, and it must not - the
# backend node is dom0's.
#
# Usage:  VM=win10-abt mgmt/harness/xenstore-vbd-probe.sh
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2

VM="${VM:?set VM to a guest answering qrexec}"
OUT="${OUT:-/home/user/rel/xs-vbd-$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$OUT"
say(){ echo "[$(date -u +%H:%M:%S)] $*" | tee -a "$OUT/summary.log"; }

source mgmt/harness/vmlock.sh
vm_lock "$VM"
trap 'vm_unlock "$VM"' EXIT
source mgmt/harness/e2e-wait.sh
w_alive "$VM" || { say "VOID: $VM is not answering qrexec"; exit 2; }

read -r -d '' PS <<'EOPS'
$ErrorActionPreference='SilentlyContinue'

# --- find the provider ---------------------------------------------------------------------------
$cls = @(Get-CimClass -Namespace root\wmi -ErrorAction SilentlyContinue |
         Where-Object { $_.CimClassName -like '*XenStore*' } | ForEach-Object { $_.CimClassName })
Write-Host ("XSCLASSES=" + ($cls -join ','))
$base = @($cls | Where-Object { $_ -like '*XenStoreBase' } | Select-Object -First 1)
$sesc = @($cls | Where-Object { $_ -like '*XenStoreSession' } | Select-Object -First 1)
if ($base.Count -ne 1 -or $sesc.Count -ne 1) {
  Write-Host "XSAVAIL=0"
  Write-Host "PROBE_END=1"
  exit 0
}
Write-Host "XSAVAIL=1"
Write-Host ("XSBASE=" + $base[0] + "|XSSESSION=" + $sesc[0])

$b = Get-CimInstance -Namespace root\wmi -ClassName $base[0] -ErrorAction Stop
$r = Invoke-CimMethod -InputObject $b -MethodName AddSession -Arguments @{ Id = 'qwtflushprobe' } -ErrorAction Stop
$sid = $r.SessionId
Write-Host ("XSSID=" + $sid)
$s = Get-CimInstance -Namespace root\wmi -ClassName $sesc[0] -ErrorAction Stop |
     Where-Object { $_.SessionId -eq $sid } | Select-Object -First 1
if (-not $s) { Write-Host "XSAVAIL=0-nosession"; Write-Host "PROBE_END=1"; exit 0 }

function XGet($p) { try { (Invoke-CimMethod -InputObject $s -MethodName GetValue -Arguments @{ PathName = $p } -ErrorAction Stop).value } catch { $null } }
function XKids($p) { try { (Invoke-CimMethod -InputObject $s -MethodName GetChildren -Arguments @{ PathName = $p } -ErrorAction Stop).children.ChildNodes } catch { $null } }

# --- every vbd frontend, and the backend node it points at ---------------------------------------
$ids = @(XKids 'device/vbd')
Write-Host ("VBDS=" + (($ids | ForEach-Object { $_ -replace '.*/','' }) -join ','))
$rows = @()
foreach ($k in $ids) {
  $id = ($k -replace '.*/','')
  $fe = "device/vbd/$id"
  $be = XGet "$fe/backend"
  # The FEATURE KEYS, which is the whole point. Absent is not the same as 0 and must not be
  # collapsed into it: absent means the backend never said anything, 0 means it said no.
  $row = [ordered]@{
    id      = $id
    backend = $be
    fe_state = (XGet "$fe/state")
    device_type = (XGet "$fe/device-type")
    flush   = $(if ($be) { $v = XGet "$be/feature-flush-cache"; if ($null -eq $v) { 'absent' } else { $v } } else { 'no-backend-path' })
    barrier = $(if ($be) { $v = XGet "$be/feature-barrier";     if ($null -eq $v) { 'absent' } else { $v } } else { 'no-backend-path' })
    discard = $(if ($be) { $v = XGet "$be/feature-discard";     if ($null -eq $v) { 'absent' } else { $v } } else { '' })
    be_mode = $(if ($be) { XGet "$be/mode" } else { '' })
    be_type = $(if ($be) { XGet "$be/type" } else { '' })
    be_phys = $(if ($be) { XGet "$be/physical-device" } else { '' })
    be_params = $(if ($be) { XGet "$be/params" } else { '' })
    be_state = $(if ($be) { XGet "$be/state" } else { '' })
  }
  $rows += $row
  Write-Host ("VBD=" + (($row.Keys | ForEach-Object { "$_=$($row[$_])" }) -join '|'))
}
Write-Host ("VBDJSON=" + ($rows | ConvertTo-Json -Depth 3 -Compress))

# Which frontend serves the BOOT disk. Without this the read-out is a list with no way to tell which
# row is the one that matters, and the boot disk is the only one that can explain an unclean shutdown.
$bootIdx = (Get-CimInstance -Namespace root\Microsoft\Windows\Storage -ClassName MSFT_Disk |
            Where-Object { $_.IsBoot } | Select-Object -First 1).Number
Write-Host ("BOOTDISK=" + $bootIdx)

try { Invoke-CimMethod -InputObject $b -MethodName RemoveSessionsByName -Arguments @{ Id = 'qwtflushprobe' } -ErrorAction SilentlyContinue | Out-Null } catch {}
Write-Host "PROBE_END=1"
EOPS

PS1="$OUT/xenstore-vbd-probe.ps1"
printf '%s\n' "$PS" > "$PS1"
QTEST_VM=$VM timeout -k 5 90 ./tools/qtest push "$PS1" >/dev/null 2>&1 || { say "FAIL: could not push"; exit 2; }
INC="${QTEST_INCOMING:-C:\\Users\\user\\Documents\\QubesIncoming\\$(hostname)}"
QTEST_VM=$VM timeout -k 5 300 ./tools/qtest run \
  "powershell -NoProfile -ExecutionPolicy Bypass -File \"$INC\\xenstore-vbd-probe.ps1\"" 2>/dev/null | tr -d '\r' > "$OUT/probe.raw"

grep -aq '^PROBE_END=1' "$OUT/probe.raw" || {
  say "FAIL: the probe did not run to completion - nothing may be read off it"
  sed -n '1,20p' "$OUT/probe.raw" | tee -a "$OUT/summary.log"; exit 2; }

grep -aoE '^(XSCLASSES|XSAVAIL|XSBASE|XSSID|VBDS|VBD|BOOTDISK)=.*' "$OUT/probe.raw" | tee -a "$OUT/summary.log"

case "$(grep -aoE '^XSAVAIL=.*' "$OUT/probe.raw" | head -1)" in
  XSAVAIL=1) ;;
  *) say "RESULT: the guest has NO xenstore WMI surface (classes seen: $(grep -aoE '^XSCLASSES=.*' "$OUT/probe.raw" | head -1 | cut -d= -f2-))."
     say "        This route to the backend's feature keys is CLOSED. The remaining route is dom0,"
     say "        which this qube cannot reach - it needs the owner. Recorded, not worked around."
     exit 3 ;;
esac

# The verdict is about the BOOT disk's backend only, and it distinguishes ABSENT from 0 - collapsing
# those would lose the difference between "the backend never said" and "the backend said no".
f=$(grep -aoE '^VBD=.*' "$OUT/probe.raw" | head -1)
fl=$(printf '%s' "$f" | grep -oE 'flush=[^|]*' | cut -d= -f2)
ba=$(printf '%s' "$f" | grep -oE 'barrier=[^|]*' | cut -d= -f2)
say "boot-disk backend: feature-flush-cache=${fl:-?}  feature-barrier=${ba:-?}"
if [ "${fl:-}" = 1 ]; then
  say "VERDICT: FLUSH IS ADVERTISED. Windows' SYNCHRONIZE_CACHE really does reach dom0, so the"
  say "         'no-op flush' branch of xenvbd is NOT what this guest runs. The live variant is the"
  say "         RUNTIME DOWNGRADE - FrontendRemoveFeature() clearing the feature on a backend error"
  say "         after Windows has cached WriteCacheEnable=1 and will never re-read MODE SENSE."
elif [ "${ba:-}" = 1 ]; then
  say "VERDICT: NO FLUSH, BUT BARRIER IS ADVERTISED. Flushes are sent as BLKIF_OP_WRITE_BARRIER, but"
  say "         MODE SENSE reports WriteCacheEnable from feature-flush-cache ALONE - so Windows is"
  say "         told the disk is WRITE-THROUGH while the driver still needs barriers to order writes."
  say "         That asymmetry in xenvbd is worth a hard look: it is exactly the shape of a durability"
  say "         hole that only appears under load."
else
  say "VERDICT: NEITHER IS ADVERTISED (flush=$fl barrier=$ba). Then xenvbd's SYNCHRONIZE_CACHE is a"
  say "         GUARANTEED no-op on this guest, and MODE SENSE reports no write cache - consistent,"
  say "         but it means durability rests ENTIRELY on dom0 not acknowledging a write before it is"
  say "         durable. Whether that holds for this rig's file-backed loop volumes cannot be checked"
  say "         from here: it needs the owner."
fi
say "raw: $OUT/probe.raw"
