#!/usr/bin/env bash
# wu-evidence-facts.sh <vm> <facts-out> [offers|offers-only] - measure, on a RUNNING guest, the artefact versions tools/wu-exclusion-evidence.py turns into
# the INDEPENDENT evidence tools/wu-exclusion-audit.py --evidence judges against. Read by the harness, never by the updater under test.
#
# Why a script of its own (2026-10-03): it was inline in mgmt/harness/template-update-test.sh, where its first live run would have been
# a release candidate's acceptance. Standalone, it is validated on a real guest before any candidate depends on it (Jev 0.99).
#
# One PowerShell, run as SYSTEM over `qtest run` (the testbed policy runs qubes.VMShell as SYSTEM - the pattern env-assert.sh uses
# live): Get-AppxPackage -AllUsers and Get-AppxProvisionedPackage -Online need it. Prints 'EV|key=value' lines; the last is EV|end=1.
# Exit 0 = the answer is complete (the end marker arrived); 2 = it is not (guest down, qrexec refused, the probe died) - missing data
# fails, and an empty value stays empty for the builder's required-key check to refuse.
#
# `offers` (2026-11-10) adds a SECOND read, after the first is complete: what the Windows Update agent itself holds for every pending
# offer, read from its local store with no network (Online=$false; the updater's own search is the online one, and the pass owns the
# only relay - docs/ADR-updater.md 12.4). One 'EV|offer=' line per offer, then 'EV|offers=<count>' LAST - the count is that
# section's end marker. It can never change this script's exit code: the versions above are complete or not on their own, and
# tools/wu-exclusion-evidence.py refuses by itself when an item it must decide has no offer line (missing data fails there).
# WHY: an offer the updater leaves out of dom0's count as 'no route' rests on three facts (ADR-updater section 2 point 5). Its
# 'the content is not self-contained' existed only in the updater's own status, so the exclusion audit had nothing independent to
# hold it against and one permanent driver offer on the field reporter's environment ended every acceptance run INSTRUMENT.
#
# `offers-only` (2026-11-12) takes ONLY that second read and appends it to <facts-out>, which must already hold a complete first
# read (EV|end=1) and no offers section; anything else is refused with exit 2. mgmt/harness/wu-e2e.sh defers the offers read of a
# round whose pass scheduled its own restart to the next round's start, because the read raced that restart: MEASURED on build
# 4.3.41.1272's template-update round 2, the pass's `shutdown /r /t 60` (guest/wu-update.ps1) fell ~60 s after it ended, and the
# read returned at that moment with only PowerShell's "#< CLIXML" header - no offer, no count, no error line.
set -uo pipefail
cd /home/user/qubes-win-idd-driver || exit 2
VM="${1:?usage: wu-evidence-facts.sh <vm> <facts-out> [offers|offers-only]}"
OUT="${2:?usage: wu-evidence-facts.sh <vm> <facts-out> [offers|offers-only]}"
source mgmt/harness/vmlock.sh; vm_lock "$VM"
# DEFENDER LOADS LATE (measured 2026-10-03 on the rz35 subject, German 25H2): 68 s after boot WinDefend was Running but reported
# AMRunningMode 'Not running', engine 0.0.0.0 and NO signature version; at 170 s it reported Normal, engine 1.1.26080.3, signatures
# 1.459.526.0. A read in that window is not a fact, so wait for the engine - three exits, each named in EV|defender: ready; disabled
# (WinDefend's start type is Disabled - it will never load); not-ready (no engine after 300 s). Only 'ready' yields the Defender facts
# the builder requires; the others leave them empty, and the builder refuses (missing data fails).
read -r -d '' EVPS <<'PS' || true
$ErrorActionPreference = 'SilentlyContinue'
$t0 = Get-Date; $dstate = 'not-ready'
while ($true) {
  if ((Get-Service WinDefend).StartType -eq 'Disabled') { $dstate = 'disabled'; break }
  $m = Get-MpComputerStatus
  if ($m.AMServiceEnabled -and $m.AMEngineVersion -and $m.AMEngineVersion -ne '0.0.0.0' -and $m.AntivirusSignatureVersion) { $dstate = 'ready'; break }
  if (((Get-Date) - $t0).TotalSeconds -ge 300) { break }
  Start-Sleep -Seconds 5
}
'EV|defender=' + $dstate + ' after ' + [int]((Get-Date) - $t0).TotalSeconds + 's (mode ' + $m.AMRunningMode + ')'
if ($dstate -ne 'ready') { $m = $null }
'EV|platform=' + $m.AMProductVersion
'EV|engine=' + $m.AMEngineVersion
'EV|signature=' + $m.AntivirusSignatureVersion
$ax = Get-AppxPackage -AllUsers -Name Microsoft.SecHealthUI | Select-Object -First 1
'EV|sechealth=' + $ax.Version
$pv = Get-AppxProvisionedPackage -Online | Where-Object { $_.DisplayName -like '*SecHealthUI*' } | Select-Object -First 1
'EV|sechealth_prov=' + $pv.Version
# THE WINDOWS SECURITY PLATFORM (KB5007651) - the artefact its installer changes, measured 2026-10-03: Platform\CoreLocation names the
# platform folder the service runs ('\\?\C:\Windows\System32' = the INBOX platform, '...\SecurityHealth\10.0.29628.1000-0' = an installed
# update), Updates\wu is the version the installer recorded (the key is ABSENT until the first install). The two app versions above are
# NOT this item's artefact: the app follows the platform asynchronously, and an app at the offered build over an inbox platform was the
# concealed failure the rz35 subject carried. Empty when the Platform key itself cannot be read, so the builder refuses (missing data fails).
$pl = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows Security Health\Platform'
$loc = [string]$pl.CoreLocation
$leaf = $loc -replace '^.*[\\/]', ''
'EV|secplatform=' + $(if ($leaf -match '^(\d+\.\d+\.\d+\.\d+)') { $Matches[1] } elseif ($loc) { 'inbox' } else { '' })
$up = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows Security Health\Updates'
'EV|secplatform_wu=' + $(if ($up.wu) { [string]$up.wu } elseif ($loc) { 'absent' } else { '' })
$cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
'EV|build=' + $cv.CurrentBuild + '.' + $cv.UBR
'EV|hotfixes=' + ((Get-HotFix | ForEach-Object { $_.HotFixID }) -join ',')
'EV|boot=' + (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToString('s')
'EV|whoami=' + [Security.Principal.WindowsIdentity]::GetCurrent().Name
'EV|end=1'
PS
if [ "${3:-}" = offers-only ]; then
  grep -a -q '^EV|end=1$' "$OUT" 2>/dev/null || { echo "OFFERS-ONLY REFUSED: $OUT holds no complete first read (no EV|end=1) to append the offers to" >&2; exit 2; }
  if grep -a -q '^EV|offers' "$OUT"; then echo "OFFERS-ONLY REFUSED: $OUT already carries an offers section" >&2; exit 2; fi
else
  b64=$(printf '%s' "$EVPS" | iconv -f UTF-8 -t UTF-16LE | base64 -w0)
  raw="$OUT.raw"
  QTEST_VM="$VM" timeout -k 5 420 tools/qtest run "powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $b64" \
    2>&1 | tr -d '\r' > "$raw"
  grep -a '^EV|' "$raw" > "$OUT"
  grep -a -q '^EV|end=1$' "$OUT" || { echo "INCOMPLETE: no end marker from $VM (raw answer kept in $raw)" >&2; exit 2; }
  echo "facts from $VM: $(grep -a -v '^EV|end=' "$OUT" | tr '\n' ' ' | cut -c1-400)"   # -a: SYSTEM's name is localized (NT-AUTORITÄT, OEM codepage)
  [ "${3:-}" = offers ] || exit 0
fi
# THE OFFERS, AS THE AGENT HOLDS THEM. Per offer: UpdateID; nodes visited in its bundle tree; leaves (nodes that carry content);
# NEEDED leaves (neither installed nor downloaded); content items on needed leaves that are a plain download.windowsupdate.com
# file, and those that are anything else (an express or Delivery Optimization stream, a URL with a query, none at all - a leaf
# with more than 64 items is express-shaped and counted whole, never enumerated); whether the agent already holds the offer's
# content; the title as base64 of its UTF-8 (a German title does not survive the console codepage - see the whoami line above).
# COUNTS ONLY: which combination means "self-contained" is decided by the builder on the host, where it can be read and tested.
# A second call, not a longer first one: cmd.exe cuts a command line at 8191 characters and the first program already encodes
# to about 6700 (mgmt/harness/console-window-check.sh measured the cut: mid-base64, the remainder run as a command).
read -r -d '' OFPS <<'PS' || true
$ErrorActionPreference = 'Stop'
function Add-EvNode($n, $a) {
  if ($a.n -ge 256) { return }
  $a.n++
  $c = 0; try { $c = [int]$n.DownloadContents.Count } catch {}
  if ($c -gt 0) {
    $a.l++
    $i = $false; $d = $false
    try { $i = [bool]$n.IsInstalled } catch {}
    try { $d = [bool]$n.IsDownloaded } catch {}
    if (-not $i -and -not $d) {
      $a.k++
      if ($c -gt 64) { $a.o += $c }
      else {
        foreach ($f in $n.DownloadContents) {
          $u = ''; try { $u = [string]$f.DownloadUrl } catch {}
          if ($u -match '^https?://[^/]*download\.windowsupdate\.com/' -and $u -notmatch '\?|filestreamingservice|tlu\.dl\.delivery\.mp\.microsoft\.com') { $a.s++ } else { $a.o++ }
        }
      }
    }
  }
  $b = 0; try { $b = [int]$n.BundledUpdates.Count } catch {}
  if ($b -gt 0) { foreach ($x in $n.BundledUpdates) { Add-EvNode $x $a } }
}
try {
  $q = (New-Object -ComObject Microsoft.Update.Session).CreateUpdateSearcher()
  $q.ServerSelection = 2; $q.Online = $false
  $r = $q.Search('IsInstalled=0 and IsHidden=0')
  $k = 0
  foreach ($u in $r.Updates) {
    $a = @{ n = 0; l = 0; k = 0; s = 0; o = 0 }
    Add-EvNode $u $a
    $d = 0; try { if ($u.IsDownloaded) { $d = 1 } } catch {}
    'EV|offer=' + [string]$u.Identity.UpdateID + ';' + $a.n + ';' + $a.l + ';' + $a.k + ';' + $a.s + ';' + $a.o + ';' + $d + ';' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([string]$u.Title))
    $k++
  }
  'EV|offers=' + $k
} catch { 'EV|offers_error=' + ($_.Exception.Message -replace '\s+', ' ') }
PS
ocmd="powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $(printf '%s' "$OFPS" | iconv -f UTF-8 -t UTF-16LE | base64 -w0)"
if [ "${#ocmd}" -gt 8000 ]; then
  echo "OFFERS NOT READ: the encoded probe is ${#ocmd} characters, past what cmd.exe passes whole (8191) - shorten it"
  exit 0
fi
QTEST_VM="$VM" timeout -k 5 240 tools/qtest run "$ocmd" 2>&1 | tr -d '\r' > "$OUT.offers.raw"
if grep -a -q '^EV|offers=[0-9][0-9]*$' "$OUT.offers.raw"; then
  grep -a -E '^EV\|offers?=' "$OUT.offers.raw" >> "$OUT"
  echo "offers held by the Windows Update agent on $VM: $(grep -a -c '^EV|offer=' "$OUT.offers.raw") line(s), count line $(grep -a '^EV|offers=' "$OUT.offers.raw" | tail -1)"
else
  echo "OFFERS NOT READ from $VM: $(grep -a '^EV|offers_error=' "$OUT.offers.raw" | head -1 | cut -c1-200) (no count line; raw answer kept in $OUT.offers.raw)"
fi
exit 0
