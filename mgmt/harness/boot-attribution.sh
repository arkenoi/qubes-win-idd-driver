#!/usr/bin/env bash
# BOOT-TO-QREXEC ATTRIBUTION - turn "~10 s slower on non-clean guests" into "this component costs N ms".
#
# WHY THIS EXISTS (findings/issues.md, guest-stability P2): acceptance 2026-09-08 measured cold
# boot-to-qrexec at 20,20 s on clean installs vs 28,30,30,38 s on upgrade/AppVM guests - DISJOINT
# sets, cause unknown. The register says: do not theorise, Windows already records the answer.
# Diagnostics-Performance/Operational event 100 carries BootTime/MainPathBootTime/BootPostBootTime
# per boot, and 101/102/103/106/109 NAME the slow application, driver, service, background process
# or device with a per-item duration.
#
# WHAT IT DOES NOT DO: it does not boot anything and it does not reap. Point it at a guest that
# has already cold-booted and is still alive. The acceptance cells reap their subject at cell
# START, so a boot they measured is gone by the time you could ask - that is exactly why the
# numbers existed with no attribution. Run this against a preserved subject or a dedicated boot.
#
# USAGE:  mgmt/harness/boot-attribution.sh <vm> [outdir]
# OUTPUT: <outdir>/boot-attribution-<vm>.tsv   (one row per event, newest boot first)
#         <outdir>/boot-attribution-<vm>.json  (raw guest answer, unparsed)
#
# READ THE OUTPUT AS: event 100's MainPathBootTime is the quantity boot-to-qrexec lives inside.
# A 10 s difference must show up THERE before any 101/103 line explains it - if event 100 says the
# two guests boot in the same time, the difference is AFTER the boot Windows measures (our service
# start ordering, qubesdb readiness, the qrexec agent's 1 Hz poll) and no amount of 103 lines will
# show it. Check that first; it is the fork in the road.
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1

VM="${1:?usage: boot-attribution.sh <vm> [outdir]}"
OUT="${2:-scratchpad/boot-attribution}"

# ONE HARNESS PER GUEST, even for a read. This script only reads, so the lock is not protecting
# guest state - it is protecting the ANSWER. The single most tempting way to use this is to point
# it at a subject an acceptance cell is mid-boot on, which would both contend for qrexec and read
# a boot that is still being written. The lock makes that refuse instead of returning a number.
source mgmt/harness/vmlock.sh; vm_lock "$VM"
mkdir -p "$OUT"
TSV="$OUT/boot-attribution-$VM.tsv"
RAW="$OUT/boot-attribution-$VM.json"

log(){ echo "[$(date +%H:%M:%S)] $*" >&2; }

# The guest side. Get-WinEvent on this channel needs no session, so it goes inline via `qtest run`
# (memory: pushrun-needs-a-session). ConvertTo-Json with -Compress so one line survives the pipe;
# -Depth 4 because the event properties nest. Errors are surfaced, never swallowed: an empty answer
# here previously read as "the guest is fine and there is nothing to report", which is the failure
# mode rule 4 of the autonomy block exists to stop.
read -r -d '' PS <<'PSEOF'
$ErrorActionPreference='Stop'
try {
  $ev = Get-WinEvent -LogName 'Microsoft-Windows-Diagnostics-Performance/Operational' -MaxEvents 200 -ErrorAction Stop |
        Where-Object { $_.Id -in 100,101,102,103,106,109 }
  $rows = foreach ($e in $ev) {
    $x = [xml]$e.ToXml()
    $d = @{}
    foreach ($n in $x.Event.EventData.Data) { $d[$n.Name] = $n.'#text' }
    [pscustomobject]@{
      Id       = $e.Id
      Time     = $e.TimeCreated.ToString('o')
      Boot     = $d['BootTime']
      MainPath = $d['MainPathBootTime']
      PostBoot = $d['BootPostBootTime']
      Name     = $(foreach ($k in 'Name','FileName','FriendlyName','ServiceName') { if ($d[$k]) { $d[$k]; break } })
      Cost     = $(foreach ($k in 'TotalTime','Degradation','DiskUsageMS','CpuUsageMS','StartTime') { if ($d[$k]) { $d[$k]; break } })
    }
  }
  Write-Host ('BOOTATTR=' + (ConvertTo-Json @($rows) -Depth 4 -Compress))
} catch {
  Write-Host ('BOOTATTRERR=' + $_.Exception.Message)
}
PSEOF

# Collapse to one line for the qtest command line, and escape for the nested cmd/powershell quoting
# the other harness call sites use.
PS1=$(printf '%s' "$PS" | tr '\n' ';' | sed 's/;;*/;/g; s/"/\\"/g')

log "reading Diagnostics-Performance from $VM (no boot, no reap - this only reads)"
ans=$(QTEST_VM="$VM" timeout -k 8 120 ./tools/qtest run \
      "powershell -NoProfile -Command \"$PS1\"" 2>/dev/null | tr -d '\r')

err=$(printf '%s\n' "$ans" | grep -aoE 'BOOTATTRERR=.*' | head -1)
if [ -n "$err" ]; then
  log "GUEST ERROR: ${err#BOOTATTRERR=}"
  log "the channel is disabled on some images: wevtutil sl Microsoft-Windows-Diagnostics-Performance/Operational /e:true"
  exit 2
fi

json=$(printf '%s\n' "$ans" | grep -aoE 'BOOTATTR=.*' | head -1)
json="${json#BOOTATTR=}"
if [ -z "$json" ] || [ "$json" = "[]" ]; then
  # MISSING DATA FAILS (autonomy rule 4). An empty channel is not "no slow components", it is
  # "this guest has not recorded a boot yet" - the diagnostic runs a couple of minutes after boot.
  log "NO DATA: the channel returned nothing. Either the guest has not finished writing its"
  log "post-boot diagnostic (it lands ~2 min after boot - wait and re-run), or the channel is off."
  exit 3
fi
printf '%s\n' "$json" > "$RAW"

python3 - "$RAW" "$TSV" <<'PY'
import json, sys
rows = json.load(open(sys.argv[1]))
if isinstance(rows, dict): rows = [rows]
KIND = {100:'boot-total', 101:'slow-application', 102:'slow-driver',
        103:'slow-service', 106:'slow-background', 109:'slow-device'}
rows.sort(key=lambda r: (r.get('Time') or ''), reverse=True)
with open(sys.argv[2], 'w') as f:
    f.write('time\tid\tkind\tboot_ms\tmainpath_ms\tpostboot_ms\tname\tcost_ms\n')
    for r in rows:
        f.write('\t'.join(str(r.get(k) or '') for k in
                ('Time','Id')) + '\t' + KIND.get(int(r.get('Id') or 0), '?') + '\t' +
                '\t'.join(str(r.get(k) or '') for k in
                ('Boot','MainPath','PostBoot','Name','Cost')) + '\n')
tot = [r for r in rows if int(r.get('Id') or 0) == 100]
print(f"{len(rows)} events, {len(tot)} boots recorded")
for r in tot[:5]:
    print(f"  boot {r.get('Time','?')[:19]}  total={r.get('Boot')}ms  "
          f"mainpath={r.get('MainPath')}ms  postboot={r.get('PostBoot')}ms")
slow = [r for r in rows if int(r.get('Id') or 0) != 100][:10]
if slow:
    print("  slowest named components (most recent boots):")
    for r in slow:
        print(f"    {KIND.get(int(r['Id']),'?'):17s} {str(r.get('Name'))[:44]:44s} {r.get('Cost')}")
PY

log "wrote $TSV"
