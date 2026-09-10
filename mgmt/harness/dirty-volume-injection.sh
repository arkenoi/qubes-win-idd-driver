#!/bin/bash
# CAN WE PRODUCE A DIRTY VOLUME ON PURPOSE, AND DOES THE DETECTOR SEE IT?
#
# THE QUESTION, asked by the owner 2026-09-10: "so do we have dirty volumes on some shutdown cases
# or we dont?" The honest answer at the time rested on RECOLLECTION - a specimen photographed in
# Startup Repair, a volume that refused a normal mount and had to be read with ntfscat - all of it
# on guests that had been qvm-kill'ed, and none of it measured with an instrument that had been
# shown to work. Meanwhile 12 completed shutdown cycles produced 131/131 "volume is healthy"
# verdicts. That is a clean answer for the completed-shutdown path and NO answer at all for the
# hard-stop path, because nobody had ever produced a dirty volume deliberately and then looked.
#
# So produce one deliberately, and look with the detector that is supposed to catch it.
#
# WHY IT IS ALSO AN INSTRUMENT VALIDATION, which is the more important half. health-check.ps1's
# prev_shutdown_orderly gained a third signal on 2026-09-10: NTFS event 98, the per-mount volume
# health verdict, plus any repair that actually ran (Wininit 1001 autochk, Ntfs 130/131 "repaired").
# It was added because the NTFS DIRTY BIT IS A CHECK THAT CANNOT FAIL - fsutil read "NOT Dirty" on a
# provably unclean boot - and event 98 is the only one of the three that positively asserts a clean
# volume while remaining able to say otherwise. But "able to say otherwise" is a claim about it, and
# under this project's rules a check counts as evidence only once it has been SEEN TO FAIL with the
# defect deliberately re-introduced. This is that injection.
#
# THREE OUTCOMES, pre-committed:
#   repair evidence present (1001, or a non-healthy 98, or 130/131)
#        -> dirty volumes are real on the hard-stop path, DEMONSTRATED not recalled, and the new
#           detector arm is validated. Both halves of the owner's question are then answered.
#   41/6008 fire but NO repair evidence
#        -> the shutdown was unclean and yet nothing repaired the volume. Then event 98 is NOT a
#           dirty-volume detector either, the third signal must be described as unproven, and the
#           honest answer to the question becomes "unclean shutdown yes, dirty volume unproven".
#           This outcome must be reported as loudly as the first - it invalidates work done today.
#   the guest does not come back at all
#        -> Startup Repair or worse, which is ITSELF the dirty-volume evidence and the operational
#           failure this whole thread has been about. Screenshot it and stop; do not restart it.
#
# THIS CONTAMINATES THE SUBJECT PERMANENTLY. A killed guest is dirty BECAUSE of the kill, so it can
# never again serve as a subject for a clean measurement (memory: "never reuse a killed subject").
# Run it LAST on any guest, and redeploy from the golden before measuring anything else on it. The
# script refuses to run without ACK_CONTAMINATES=1 so this cannot happen by accident.
#
# Usage:  VM=win10-abt ACK_CONTAMINATES=1 mgmt/harness/dirty-volume-injection.sh
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2

VM="${VM:?set VM to an EXPENDABLE guest - this destroys its value as a measurement subject}"
[ "${ACK_CONTAMINATES:-}" = 1 ] || {
  echo "REFUSED: this hard-kills $VM mid-write and permanently contaminates it as a subject."
  echo "         Re-run with ACK_CONTAMINATES=1 if that is what you intend."; exit 2; }
OUT="${OUT:-/home/user/rel/dirty-inject-$(date -u +%Y%m%dT%H%M%SZ)}"
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

w_alive "$VM" || { say "VOID: $VM is not answering qrexec"; exit 2; }
T0=$(psp NOW 'Write-Host ("NOW=" + [datetime]::UtcNow.ToString("o"))' 60)
[ -n "$T0" ] || { say "VOID: could not read the guest clock; the read-out could not be scoped"; exit 2; }
say "=== dirty-volume injection on $VM (scope from $T0) ==="

# A detached writer, then the kill lands ON it. The write is verified GROWING before the kill,
# because a kill that lands after the writer died is just a kill of an idle guest - a different
# experiment wearing this one's label.
cat > "$OUT/gen.ps1" <<'GEN'
$ErrorActionPreference='SilentlyContinue'
$dir = Join-Path $env:SystemDrive 'dirtyload'
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
$buf = New-Object byte[] (1MB)
(New-Object Random 3).NextBytes($buf)
$i = 0
while ($true) {
  $fs = [IO.File]::Create((Join-Path $dir "d$i.bin"))
  for ($j = 0; $j -lt 32; $j++) { $fs.Write($buf, 0, $buf.Length) }
  $fs.Close(); $i++; if ($i -gt 400) { $i = 0 }
}
GEN
QTEST_VM=$VM timeout -k 5 90 ./tools/qtest push "$OUT/gen.ps1" >/dev/null 2>&1 || { say "FAIL: push"; exit 2; }
INC="${QTEST_INCOMING:-C:\\Users\\user\\Documents\\QubesIncoming\\$(hostname)}"
gq "cmd /c start /b powershell -NoProfile -ExecutionPolicy Bypass -File \"$INC\\gen.ps1\"" 40 >/dev/null 2>&1 || true

sz(){ psp SZ '
$d = Join-Path $env:SystemDrive "dirtyload"
$s = 0; if (Test-Path $d) { $s = (Get-ChildItem $d -File | Measure-Object -Sum Length).Sum }
Write-Host ("SZ=" + [int64]$s)' 90; }
sleep 20; a=$(sz); sleep 10; b=$(sz)
if [ -z "${a:-}" ] || [ -z "${b:-}" ] || [ "${b:-0}" -le "${a:-0}" ]; then
  say "VOID: writer not growing ($a -> $b) - a kill now would be a kill of an IDLE guest, which is"
  say "      a different experiment. Not proceeding."; exit 1
fi
say "writer verified in flight: $a -> $b bytes ($(( (b-a)/1048576 )) MB in 10s)"

say "HARD KILL mid-write - THIS IS THE INJECTED DEFECT"
qvm-kill "$VM" >/dev/null 2>&1
for i in $(seq 1 30); do [ "$(state)" = Halted ] && break; sleep 4; done
say "state after kill: $(state)"

qvm-start "$VM" >/dev/null 2>&1
for i in $(seq 1 60); do w_alive "$VM" && break; sleep 10; done
if ! w_alive "$VM"; then
  say "THE GUEST DID NOT COME BACK within 10 min of start."
  say "  That is outcome 3 and it is itself the dirty-volume evidence: Startup Repair has no qrexec."
  say "  Reading the SCREEN, which is the only instrument left, and then STOPPING - not restarting it."
  QTEST_VM=$VM timeout -k 5 90 ./tools/qtest shot "$OUT/screen.tar" >/dev/null 2>&1
  if [ -s "$OUT/screen.tar" ]; then
    say "  screen captured: $OUT/screen.tar ($(wc -c <"$OUT/screen.tar") bytes) - READ IT"
  else
    say "  screen capture EMPTY - which on a guest with no session is expected and proves nothing"
    say "  by itself; do not read it as 'no windows'."
  fi
  exit 1
fi

# The read-out, scoped to this cycle. Both the outcome (41/6008) and the volume verdicts.
cat > "$OUT/read.ps1" <<'EOPS'
$ErrorActionPreference='SilentlyContinue'
$since = [datetime]::Parse($env:QWT_SINCE).ToUniversalTime()
function R($e){ @($e | Where-Object { $_.TimeCreated.ToUniversalTime() -ge $since }) }
$u = R (Get-WinEvent -FilterHashtable @{LogName='System';Id=41,6008} -MaxEvents 40)
Write-Host ("UNCLEAN_N=" + $u.Count)
foreach ($x in $u) { Write-Host ("UNCLEAN=" + $x.TimeCreated.ToString('o') + "|id" + $x.Id) }
$n = R (Get-WinEvent -FilterHashtable @{LogName='System';ProviderName='Microsoft-Windows-Ntfs'} -MaxEvents 100)
$healthy = @($n | Where-Object { $_.Id -eq 98 -and $_.Message -match 'is healthy' })
$bad     = @($n | Where-Object { ($_.Id -eq 98 -and $_.Message -notmatch 'is healthy') -or ((130,131) -contains $_.Id -and $_.Message -match 'repaired') })
Write-Host ("HEALTHY_N=" + $healthy.Count)
Write-Host ("BAD_N=" + $bad.Count)
foreach ($x in $bad) { Write-Host ("BAD=" + $x.TimeCreated.ToString('o') + "|id" + $x.Id + "|" + (($x.Message -replace '\s+',' '))) }
$chk = R (Get-WinEvent -FilterHashtable @{LogName='Application';ProviderName='Microsoft-Windows-Wininit';Id=1001} -MaxEvents 10)
Write-Host ("AUTOCHK_N=" + $chk.Count)
foreach ($x in $chk) { Write-Host ("AUTOCHK=" + $x.TimeCreated.ToString('o') + "|" + (($x.Message -replace '\s+',' ') -replace '^(.{200}).*$','$1')) }
Write-Host ("DIRTYBIT=" + ((& fsutil.exe dirty query $env:SystemDrive 2>&1 | Out-String).Trim()))
Write-Host "END=1"
EOPS
QTEST_VM=$VM timeout -k 5 90 ./tools/qtest push "$OUT/read.ps1" >/dev/null 2>&1
gq "cmd /c set QWT_SINCE=$T0 && powershell -NoProfile -ExecutionPolicy Bypass -File \"$INC\\read.ps1\"" 300 > "$OUT/read.out"
grep -aq '^END=1' "$OUT/read.out" || { say "FAIL: the read-out did not complete - nothing may be graded"; exit 2; }
grep -aE '^(UNCLEAN_N|UNCLEAN|HEALTHY_N|BAD_N|BAD|AUTOCHK_N|AUTOCHK|DIRTYBIT)=' "$OUT/read.out" | tee -a "$OUT/summary.log"

g(){ grep -aoE "^$1=.*" "$OUT/read.out" | head -1 | sed "s/^$1=//"; }
un=$(g UNCLEAN_N); bad=$(g BAD_N); chk=$(g AUTOCHK_N)
say "---"
if [ "${bad:-0}" -gt 0 ] || [ "${chk:-0}" -gt 0 ]; then
  say "OUTCOME 1: A DIRTY VOLUME WAS PRODUCED AND DETECTED (repairs=$bad autochk=$chk, unclean=$un)."
  say "  Dirty volumes on the hard-stop path are DEMONSTRATED, not recalled, and the event-98/1001"
  say "  arm of prev_shutdown_orderly is validated - it has now been seen to FAIL on a defect."
elif [ "${un:-0}" -gt 0 ]; then
  say "OUTCOME 2: THE SHUTDOWN WAS UNCLEAN ($un events) BUT NOTHING REPAIRED THE VOLUME."
  say "  So NTFS event 98 is NOT a dirty-volume detector, the third signal added to"
  say "  prev_shutdown_orderly today is UNPROVEN and must be described that way, and the honest"
  say "  answer to 'do we get dirty volumes' becomes: unclean shutdowns yes, dirty volumes UNPROVEN."
  say "  This invalidates part of today's work and is being reported as loudly as a confirmation."
else
  say "OUTCOME 0: NEITHER FIRED. A hard kill mid-write left no unclean-shutdown record at all, which"
  say "  contradicts the 2026-09-09 injection. Then the INSTRUMENT is broken, not the guest - do not"
  say "  read this as 'the kill was harmless'. Fix the read-out before concluding anything."
fi
say "=== done: $OUT (SUBJECT IS NOW CONTAMINATED - redeploy before measuring anything else) ==="
