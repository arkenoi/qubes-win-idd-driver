#!/bin/bash
# WHY WAS THE PREVIOUS SHUTDOWN UNCLEAN? Read the STORAGE stack, not the power events.
#
# THE DEFECT THIS INTERROGATES (findings/issues.md, "unclean shutdown under write load"): a guest
# put under ~2 GB of writes and then shut down NORMALLY - no kill, the cycle completed and the guest
# came back - reports Kernel-Power 41 / 6008 on the next boot, 3/3, in both the installer's power-off
# arm and the host ACPI arm, while an idle guest is 3/3 clean. Windows only reports 41 when the marker
# it writes late in shutdown is not there on the next boot, so under load something we ship is
# acknowledging writes that are not durable, or is not completing the shutdown flush at all.
#
# THE INSTRUMENT, and why THIS one. Every measurement so far has been made on the POWER events
# (Kernel-Power 41, 6008) plus the NTFS dirty bit. Those detect the outcome and say nothing about the
# mechanism - and the dirty bit is worse than uninformative here, having already read "NOT Dirty" on a
# provably unclean boot. The storage stack, however, logs the mechanism directly and no one here has
# ever looked:
#     Ntfs 137/140  - "failed to flush data to the transaction log" / delayed-write failure. This is
#                     the flush ITSELF failing, i.e. the lead, stated by the OS in as many words.
#     Ntfs 55/98    - structure corruption / metadata inconsistency, the consequence of the above.
#     disk 153      - an I/O was retried; disk/storahci 129 - a RESET was issued to the device
#                     because it did not answer in time. A flush that hangs looks exactly like this.
#     volmgr 46/162 - crash-dump/volume-level durability complaints.
#     xenvbd (any)  - our PV block driver's own words, if it says anything at all.
# It also reads the DEVICE-LEVEL cache policy, because Windows suppresses SYNCHRONIZE_CACHE entirely
# when a disk is marked power-protected: `Device Parameters\Disk\CacheIsPowerProtected` = 1 makes
# every flush a no-op by design, and `UserWriteCacheSetting` is the write-cache override. If either
# is set on the boot disk, the durability hole is configuration and the fix is a registry value.
#
# It is an OBSERVATION pass: it changes nothing, so it can be run on a live subject, on a specimen
# parked for forensics, or as the read-out step of an A/B. It prints one KEY=value line per fact and
# a JSON blob of the raw events, so the A/B that follows can diff two runs mechanically.
#
# THE THREE OUTCOMES, decided before the run so the result cannot be narrated afterwards:
#   Ntfs 137/140 present, clustered at the unclean shutdowns
#        -> the flush is FAILING. The lead is confirmed and it is ours (xenvbd/blkback path).
#   disk/storahci 129 or 153 present
#        -> the device is not ANSWERING in time; the flush hangs and the stack gives up on it.
#   nothing in storage, cache policy default
#        -> nothing lost a write. Windows never got to write the marker, so the domain went away
#           before the end of shutdown, and the lead is the POWER-OFF RACE, not xenvbd. That is the
#           refutation, and it must be reported as loudly as a confirmation.
#
# Usage:  VM=win10-abt mgmt/harness/xenvbd-flush-probe.sh [--out DIR]
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2

VM="${VM:?set VM to a guest answering qrexec}"
OUT="${OUT:-/home/user/rel/flush-probe-$(date -u +%Y%m%dT%H%M%SZ)}"
[ "${1:-}" = --out ] && OUT="$2"
mkdir -p "$OUT"
say(){ echo "[$(date -u +%H:%M:%S)] $*" | tee -a "$OUT/summary.log"; }

# READ-ONLY IS NOT A REASON TO SKIP THE LOCK. This probe changes nothing on the guest, but it READS
# a boot's event log, and a concurrent job rebooting the guest underneath it would have it read a
# different boot than the one being graded - the same class of fabricated result the lock exists for.
# The lock is re-entrant within a job (QWT_VMLOCK_HELD), so flush-durability-ab.sh calling this while
# holding it passes straight through.
source mgmt/harness/vmlock.sh
vm_lock "$VM"
trap 'vm_unlock "$VM"' EXIT
source mgmt/harness/e2e-wait.sh

w_alive "$VM" || { say "VOID: $VM is not answering qrexec"; exit 2; }

# One probe, one round trip. Each fact is emitted as its own KEY= line; the events go out as JSON so
# the A/B can compare two runs without re-parsing prose.
# PROBE_SINCE (optional, ISO-8601 UTC): scope every query to events at or after this instant.
#
# WITHOUT IT THIS PROBE CANNOT GRADE A ROUND. The System log ACCUMULATES: once a guest has recorded
# one unclean shutdown, an unscoped read reports UNCLEAN_N>0 for the rest of that guest's life, so
# every later round "confirms" the defect whatever happened in it - and equally, storage events from
# an earlier round get attributed to this one. That is the accumulating-state trap the experimenter
# rules call out by name. Set it to the guest's clock immediately before the cycle under test.
SINCE_DECL='$Since = $null'
[ -n "${PROBE_SINCE:-}" ] && SINCE_DECL="\$Since = [datetime]::Parse('$PROBE_SINCE').ToUniversalTime()"

read -r -d '' PS <<'EOPS'
$ErrorActionPreference='SilentlyContinue'
# An EMPTY array must serialise as "[]", not as nothing. `@() | ConvertTo-Json` emits an empty
# string, so KEY= came back blank and every consumer of it broke on parse (measured on win11-nfy,
# which legitimately had zero events). A blank where a value is expected is also indistinguishable
# from a query that failed, which is the one confusion this probe must never introduce.
function J($o){ $a = @($o); if ($a.Count -eq 0) { '[]' } else { ,$a | ConvertTo-Json -Depth 4 -Compress } }
__SINCE_DECL__
Write-Host ("SINCE=" + $(if ($Since) { $Since.ToString('o') } else { 'all-history' }))
# One filter, applied to both queries, so the outcome and the mechanism are read over the SAME
# window. Reading them over different windows is how a mechanism gets attributed to the wrong round.
function Recent($evts) { if ($Since) { @($evts | Where-Object { $_.TimeCreated.ToUniversalTime() -ge $Since }) } else { @($evts) } }

# --- the outcome, kept so this probe is self-contained evidence -----------------------------------
$pw = @(Recent (Get-WinEvent -FilterHashtable @{LogName='System'; Id=41,6008} -MaxEvents 40) |
        ForEach-Object { @{ id=$_.Id; t=$_.TimeCreated.ToString('o'); msg=($_.Message -replace '\s+',' ') } })
Write-Host ("UNCLEAN_N=" + $pw.Count)
Write-Host ("UNCLEAN=" + (J $pw))

# --- the MECHANISM: what the storage stack said ---------------------------------------------------
# Filter by PROVIDER, not by id alone: id 129 exists under several providers and only the storage
# ones mean "a reset was issued to the device".
#
# ONE PROVIDER AT A TIME, and this is not a style choice. Get-WinEvent -FilterHashtable with a LIST
# of ProviderNames fails the WHOLE query if ANY single name is not registered on this guest - and
# 'xenvbd' quite possibly is not, since a driver only becomes an event provider if it registers as
# one. With -ErrorAction SilentlyContinue that failure returns NOTHING, which would print
# STORAGE_N=0 and be read as "no flush failures, nothing lost a write": a false PASS on the exact
# question this probe exists to answer. So each provider is queried separately and the ones that
# could not be queried are REPORTED, because missing data must fail rather than pass quietly.
# 'disk' and 'Disk' are the SAME provider - Windows provider names are case-insensitive - so having
# both in this list counted every disk event TWICE and doubled RESET_N. Measured on the control run:
# 6 "events" that were 3. One spelling only, and the dedupe below is the belt to that braces.
$provs = 'Ntfs','Microsoft-Windows-Ntfs','disk','storahci','stornvme','volmgr','volsnap','xenvbd','xendisk','partmgr'
$stor = @(); $pok = @(); $pmiss = @()
foreach ($pn in $provs) {
  $got = $null
  try { $got = @(Recent (Get-WinEvent -FilterHashtable @{LogName='System'; ProviderName=$pn} -MaxEvents 200 -ErrorAction Stop)) }
  catch { $pmiss += "$pn : $($_.Exception.Message -replace '\s+',' ')"; continue }
  $pok += "$pn($($got.Count))"
  $stor += @($got | Where-Object { $_.Level -le 3 } |
             ForEach-Object { @{ p=$_.ProviderName; id=$_.Id; lvl=$_.Level; t=$_.TimeCreated.ToString('o')
                                 msg=(($_.Message -replace '\s+',' ') -replace '^(.{300}).*$','$1') } })
}
$stor = @($stor | Group-Object { "$($_.t)|$($_.id)|$($_.msg)" } | ForEach-Object { $_.Group[0] })
Write-Host ("PROVIDERS_OK=" + ($pok -join ' '))
Write-Host ("PROVIDERS_MISSING=" + (J $pmiss))
Write-Host ("PROVIDERS_OK_N=" + $pok.Count)
Write-Host ("STORAGE_N=" + $stor.Count)
Write-Host ("STORAGE=" + (J $stor))

# WHICH DISK. A storage complaint only bears on this defect if it is about the disk carrying Windows.
# The control run produced 3 genuine I/O errors + retries and every one was on a NON-BOOT disk (a
# PVDISK data volume and two QEMU USB volumes), yet the verdict read "THE DEVICE IS NOT ANSWERING IN
# TIME" - a false positive on the arm that would otherwise have looked like a confirmation. So the
# counts are split boot-disk vs other. Both are reported: the other-disk ones are still real and
# still worth seeing, they just cannot explain an unclean SYSTEM shutdown.
$bootNum = (Get-CimInstance -Namespace root\Microsoft\Windows\Storage -ClassName MSFT_Disk |
            Where-Object { $_.IsBoot } | Select-Object -First 1).Number
if ($null -eq $bootNum) { $bootNum = -1 }
Write-Host ("BOOTDISK=" + $bootNum)
function OnBoot($e) {
  # "for Disk 3", "\Device\Harddisk3\DR3", "\Device\HarddiskVolume2" - the first two carry the disk
  # number. An event naming no disk is attributed to the boot disk, because guessing it away would
  # be the silent-drop failure this file already carries one scar from.
  if ($e.msg -match 'for Disk (\d+)')  { return ([int]$matches[1] -eq $bootNum) }
  if ($e.msg -match 'Harddisk(\d+)')   { return ([int]$matches[1] -eq $bootNum) }
  return $true
}
$bootEv  = @($stor | Where-Object { OnBoot $_ })
$otherEv = @($stor | Where-Object { -not (OnBoot $_) })
Write-Host ("BOOTEV_N=" + $bootEv.Count)
Write-Host ("OTHEREV_N=" + $otherEv.Count)

# The signatures the verdict turns on, boot disk only, ranked by what each actually means:
#   137/140 - the flush ITSELF failed (Ntfs says so)          -> the lead, confirmed
#   129     - a RESET was issued: the device stopped answering -> a hanging flush
#   51      - an I/O error during a PAGING operation           -> a write that did not land
#   153     - an I/O was RETRIED and then succeeded            -> the weakest signal of the four
Write-Host ("FLUSHFAIL_N=" + @($bootEv | Where-Object { $_.p -like '*Ntfs*' -and (137,140 -contains $_.id) }).Count)
Write-Host ("CORRUPT_N="   + @($bootEv | Where-Object { $_.p -like '*Ntfs*' -and (55,98 -contains $_.id) }).Count)
Write-Host ("RESET_N="     + @($bootEv | Where-Object { $_.id -eq 129 }).Count)
Write-Host ("PAGEERR_N="   + @($bootEv | Where-Object { $_.id -eq 51 }).Count)
Write-Host ("RETRY_N="     + @($bootEv | Where-Object { $_.id -eq 153 }).Count)
Write-Host ("OTHERDISK_IO_N=" + @($otherEv | Where-Object { 51,129,153 -contains $_.id }).Count)
Write-Host ("XENVBD_N="    + @($stor | Where-Object { $_.p -eq 'xenvbd' }).Count)

# --- the device-level cache policy ---------------------------------------------------------------
# CacheIsPowerProtected=1 makes Windows SKIP the flush by design; UserWriteCacheSetting overrides the
# device's own write-cache state. Either one set on the boot disk turns the defect into configuration.
$pol = @()
foreach ($enum in 'SCSI','IDE','SCM','STORAGE') {
  $root = "HKLM:\SYSTEM\CurrentControlSet\Enum\$enum"
  foreach ($k in @(Get-ChildItem -Path $root -Recurse -Depth 2 | Where-Object { $_.PSChildName -eq 'Disk' })) {
    $pol += @{ path=($k.Name -replace '^HKEY_LOCAL_MACHINE\\','')
               UserWriteCacheSetting=(Get-ItemProperty $k.PSPath).UserWriteCacheSetting
               CacheIsPowerProtected=(Get-ItemProperty $k.PSPath).CacheIsPowerProtected }
  }
}
Write-Host ("CACHEPOLICY=" + (J $pol))
Write-Host ("CACHEPOL_SET_N=" + @($pol | Where-Object { $null -ne $_.CacheIsPowerProtected -or $null -ne $_.UserWriteCacheSetting }).Count)

# --- which path is actually serving the disk ------------------------------------------------------
# The mechanism differs by path: on the PV path the writes go to a kernel blkback in dom0, on the
# emulated path through QEMU in the stubdomain - whose cache dies with the domain. A verdict that
# does not say which path was under test is not a verdict.
$d = @(Get-CimInstance -Namespace root\Microsoft\Windows\Storage -ClassName MSFT_Disk |
       ForEach-Object { @{ n=$_.Number; bus=$_.BusType; boot=$_.IsBoot; model=$_.Model } })
Write-Host ("DISKS=" + (J $d))
$w = @(Get-CimInstance Win32_DiskDrive | ForEach-Object { @{ cap=$_.Caption; iface=$_.InterfaceType } })
Write-Host ("DRIVES=" + (J $w))
Write-Host ("BOOTID=" + (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToString('o'))
Write-Host ("HIBERBOOT=" + [string](Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power').HiberbootEnabled)
Write-Host ("PROBE_END=1")
EOPS

say "=== flush probe on $VM ==="

# PUSHED AS A FILE, not as -EncodedCommand. The e2e-wait.sh idiom (base64 -EncodedCommand) is right
# for one-line probes and WRONG here: cmd.exe caps a command line at 8191 characters and base64 of
# UTF-16 runs about 2.7x the source, so this script's ~5 KB became a ~13 KB argument. The guest did
# not report an error - cmd ECHOED the truncated blob back and returned a prompt, which arrives
# looking exactly like a probe that ran and printed nothing. Measured 2026-09-10.
PS1="$OUT/flush-probe.ps1"
printf '%s\n' "${PS/__SINCE_DECL__/$SINCE_DECL}" > "$PS1"
QTEST_VM=$VM timeout -k 5 90 ./tools/qtest push "$PS1" >/dev/null 2>&1 || { say "FAIL: could not push the probe"; exit 2; }
INC="${QTEST_INCOMING:-C:\\Users\\user\\Documents\\QubesIncoming\\$(hostname)}"
QTEST_VM=$VM timeout -k 5 300 ./tools/qtest run \
  "powershell -NoProfile -ExecutionPolicy Bypass -File \"$INC\\flush-probe.ps1\"" 2>/dev/null | tr -d '\r' > "$OUT/probe.raw"

grep -aq '^PROBE_END=1' "$OUT/probe.raw" || {
  say "FAIL: the probe did not run to completion - the read-out is INCOMPLETE and must not be graded."
  say "      raw output kept at $OUT/probe.raw ($(wc -c <"$OUT/probe.raw") bytes)"
  exit 2
}
grep -aoE '^[A-Z_]+=.*' "$OUT/probe.raw" > "$OUT/facts.txt"
v(){ grep -aoE "^$1=.*" "$OUT/facts.txt" | head -1 | sed "s/^$1=//"; }

say "unclean shutdowns in the log : $(v UNCLEAN_N)"
say "boot disk                    : #$(v BOOTDISK)"
say "-- on the BOOT disk (these can explain an unclean shutdown) --"
say "Ntfs flush failures (137/140): $(v FLUSHFAIL_N)"
say "Ntfs corruption    (55/98)   : $(v CORRUPT_N)"
say "device resets       (129)    : $(v RESET_N)"
say "paging I/O errors   (51)     : $(v PAGEERR_N)"
say "I/O retried         (153)    : $(v RETRY_N)"
say "-- elsewhere (real, but cannot explain it) --"
say "I/O errors on other disks    : $(v OTHERDISK_IO_N)"
say "xenvbd's own events          : $(v XENVBD_N)"
say "disks with a cache override  : $(v CACHEPOL_SET_N)"
say "bus types                    : $(v DISKS)"
say "hiberboot                    : $(v HIBERBOOT)"

say "queryable providers          : $(v PROVIDERS_OK)"
say "providers that FAILED to query: $(v PROVIDERS_MISSING)"

ff=$(v FLUSHFAIL_N); rs=$(v RESET_N); cp=$(v CACHEPOL_SET_N)

# MISSING DATA FAILS. The whole value of this probe is that a NEGATIVE result refutes the flush
# hypothesis - and a negative result is only worth that if the collection demonstrably worked. If no
# provider could be queried, or if neither Ntfs provider could, then the flush-failure arm was never
# actually checked and must be reported UNCHECKED, not clean. This is the exact shape of the false
# PASS that a single multi-provider query would have produced silently.
if [ "$(v PROVIDERS_OK_N)" = 0 ]; then
  say "VOID: no event provider could be queried at all. This probe measured NOTHING - the storage"
  say "      arms are UNCHECKED, and no verdict may be read off this run."
  exit 2
fi
case "$(v PROVIDERS_OK)" in
  *Ntfs*) ;;
  *) say "VOID: neither Ntfs provider was queryable, so 'no flush failure' was never established."
     say "      The flush-failure arm is UNCHECKED. Fix the query before grading this."
     exit 2 ;;
esac

pe=$(v PAGEERR_N)

# A GUEST WITH NOTHING TO EXPLAIN REFUTES NOTHING. On the first control run - win10-abt after 50
# idle reboots - every storage count was zero and the read-out printed "REFUTES the flush
# hypothesis". It did no such thing: that guest reported ZERO unclean shutdowns, so there was no
# lost write for the storage stack to have an opinion about. Reading a refutation off a run with no
# defect present is precisely the "check that cannot fail" this project bans, run backwards.
if [ "$(v UNCLEAN_N)" = 0 ]; then
  say "CONTROL: this guest reports NO unclean shutdown, so there is nothing here to explain. The"
  say "         run establishes the clean baseline - boot-disk storage complaints: flush=${ff:-0}"
  say "         reset=${rs:-0} paging=${pe:-0} - and REFUTES NOTHING. To decide the flush question,"
  say "         run this probe on a guest that HAS just recorded an unclean shutdown."
  say "facts: $OUT/facts.txt   raw: $OUT/probe.raw"
  exit 0
fi

if [ "${ff:-0}" -gt 0 ]; then
  say "VERDICT: THE FLUSH IS FAILING - Ntfs says so itself. The lead is confirmed."
elif [ "${rs:-0}" -gt 0 ]; then
  say "VERDICT: THE BOOT DEVICE STOPPED ANSWERING - a reset was issued to it. A hanging flush"
  say "         looks exactly like this."
elif [ "${pe:-0}" -gt 0 ]; then
  say "VERDICT: PAGING I/O FAILED ON THE BOOT DISK - a write that Windows needed did not land."
elif [ "${cp:-0}" -gt 0 ]; then
  say "VERDICT: A CACHE OVERRIDE IS SET on a disk - Windows may be skipping flushes by configuration."
else
  say "VERDICT: NOTHING LOST A WRITE. No flush failure, no reset, default cache policy. So Windows"
  say "         never reached the end of shutdown: the lead is the POWER-OFF RACE, not xenvbd."
  say "         This REFUTES the flush hypothesis and must be reported as such."
fi
say "facts: $OUT/facts.txt   raw: $OUT/probe.raw"
