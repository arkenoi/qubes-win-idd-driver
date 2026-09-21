<#
.SYNOPSIS
  Qubes Windows Update agent (QWT-NG). Windows Update over the Qubes UpdatesProxy with ZERO guest
  networking.

.DESCRIPTION
  Windows' online update engine (DO -> BITS) gates on IsNetworkAlive and refuses to run on a
  routeless guest (error 0x80200010) - and no loopback/NCSI trick satisfies it (proven). So this
  agent uses "Path B", the offline-servicing route, which has no such gate:

     scan (WU COM search, proxy-aware)  ->  resolve the standalone .msu from the Microsoft Update
     Catalog (over the proxy)  ->  fetch it over the proxy (resumable)  ->  install offline (DISM).

  Everything rides the qubes-updates-relay (127.0.0.1:8082 -> qrexec qubes.UpdatesProxy), so the
  guest needs no IP networking. Throughout, it writes a structured status JSON (availability +
  progress) for dom0 to poll - the north-star: report availability + progress to dom0, non-blocking.

.NOTES
  Consolidates the proven prototype scripts (wu-enumerate / wu-catalog-get / wu-full-install).
  dom0 reporting (qubes.NotifyUpdates + a progress channel) is a thin layer on top of the status
  file - added once the dom0 policy is placed.

.PARAMETER Action  scan | download | install | full
#>
[CmdletBinding()]
param(
  [ValidateSet('scan','resolve','download','install','full','wuinstall')][string]$Action = 'scan',
  [string]$Proxy      = 'http://127.0.0.1:8082',
  [string]$RelayExe   = 'C:\Program Files\Qubes Tools\bin\qubes-updates-relay.exe',
  [string]$WorkDir    = 'C:\ProgramData\Qubes\wu',
  [string]$StatusFile = 'C:\ProgramData\Qubes\update-status.json',
  # Restrict a pass to specific KBs (e.g. -OnlyKb KB5120710). Diagnostic control, not a policy
  # knob: a normal dom0-driven pass passes nothing and takes everything offered. It exists so a
  # multi-gigabyte cumulative and a small package can be tested one at a time rather than as an
  # all-or-nothing batch - the batch is precisely what made the 24H2 failure unattributable.
  [string[]]$OnlyKb   = @(),
  # Force the catalog to answer in a given language, e.g. -AcceptLanguage de-DE. Diagnostic.
  # Exists because the catalog's response language is NOT under our control and has been measured
  # varying by itself (same KB, same guest, German at 09:54 and English at 10:21 on 2026-08-14),
  # while the row-picking logic matches on title text. A real user runs a German edition, so
  # "does resolution still pick the same FILE when the titles are German" has to be answerable on
  # an English guest - this is what makes it answerable.
  [string]$AcceptLanguage = '',
  # Set ONLY by the scheduled scan task. It marks this pass as the automatic background refresh,
  # which is the one pass that may be skipped when another has just finished (see the debounce
  # below). A pass dom0 asked for is never skipped, whatever it costs - so this switch must never
  # be added to the Run/Download tasks or to the rpc handlers.
  [switch]$Scheduled
)
$ErrorActionPreference = 'Continue'
New-Item -ItemType Directory -Force (Split-Path $StatusFile) | Out-Null

# ---- WU-PREVSTATUS-BEGIN
# GUARD:prevstatus - snapshot the PREVIOUS pass's status BEFORE anything in this run can Save over
# it. Save() rewrites $StatusFile from $script:St, which this run resets, and it is called early
# and often - so a guard that reads the file later reads THIS run's freshly blanked state and
# concludes there is no prior knowledge at all. Measured 2026-09-20: GUARD:scanactioned read
# `action=scan, rows=0` - its own output - and therefore excluded nothing, and dom0 went from empty
# back to 1 on the very next scan. Read it once, here, where it is still the previous pass's.
$script:PrevStatus = $null
try {
  if (Test-Path $StatusFile) { $script:PrevStatus = Get-Content -LiteralPath $StatusFile -Raw | ConvertFrom-Json }
} catch { $script:PrevStatus = $null }
# ---- WU-PREVSTATUS-END

# CONNECT-tunnel keep-alive (2026-08-20): one tunnel through the relay = one backend qrexec channel, so
# every tunnel .NET drops early is a vchan channel churned (each open/close = a grant permit/revoke, the
# suspected relay-wedge trigger). .NET already reuses one tunnel per host within this process (Fetch-Msu
# drains + Close()s each response, KeepAlive default true); the only thing forcing a fresh tunnel across
# catalog think-gaps is the 100 s default idle drop - raise it so sequential catalog/CDN requests ride one
# tunnel. (WU's own fe2cr/fe3cr SOAP churn is not ours; it falls only via the relay-side pool changes.)
try {
  [System.Net.ServicePointManager]::MaxServicePointIdleTime = 300000
  [System.Net.ServicePointManager]::SetTcpKeepAlive($true, 30000, 5000)
} catch {}

# ONE update operation at a time. The scheduled scan, the dom0-driven run and the download task
# are separate tasks writing ONE status file and sharing ONE proxy, and they collided for real
# (2026-08-13): the 6-hourly scan fired 6 minutes into a dom0-driven install, rewrote the status
# file with its own `done`, and the rpc handler tailing that file reported the update finished -
# with an empty result - while DISM was still installing. The scan's Remove-Proxy also tears down
# the proxy the other pass is downloading through.
# DEBOUNCE, and only for the automatic scan. The mutex below stops two passes running AT ONCE; it
# does nothing about one starting the moment another finished. That happens routinely - dom0 drives
# an install, it completes, and the 6-hourly scan fires minutes later - and each pass costs a full
# Windows Update scan plus a proxy/relay teardown and rebuild. The relay churn is not free: the
# 2026-08-20 dump attributes the guest-wide freeze to the TLB shootdowns that qrexec bridge
# processes generate as they exit, so a pass nobody needs is a wedge risk, not just wasted minutes.
#
# Rules, deliberately narrow:
#   - ONLY -Scheduled passes are ever skipped. Anything dom0 asked for runs, always.
#   - the window counts from the last COMPLETED pass of ANY kind (that is the point of it being
#     cross-path); a pass that failed or is mid-flight does not start the clock.
#   - QUBES_UPDATES_DEBOUNCE_MIN=0 disables it; the default is 30 minutes against a 6-hourly scan.
#   - a pass that ended REBOOT-PENDING never debounces the scan that follows it (see inside).
# The marker lines delimit the region tools/tests/wu-reboot-report-test.ps1 extracts and replays.
# ---- WU-SCAN-DEBOUNCE-BEGIN
if ($Scheduled -and $Action -eq 'scan') {
    $debounceMin = 30
    $envMin = $env:QUBES_UPDATES_DEBOUNCE_MIN
    if ($envMin -and ($envMin -as [int]) -ne $null) { $debounceMin = [int]$envMin }
    if ($debounceMin -gt 0 -and (Test-Path $StatusFile)) {
        try {
            $prev = Get-Content -LiteralPath $StatusFile -Raw | ConvertFrom-Json
            # Only a pass that actually LEFT AN ANSWER may suppress the next scan. Measured on a
            # real cold boot 2026-08-20: the boot-triggered scan was skipped 9 minutes after a
            # download pass, finishing in 3 s having written nothing. That is right when the
            # previous pass reported availability - and wrong when it did not, because the boot
            # scan is exactly the recovery for a pass whose own rescan failed. Without this the
            # guest could sit up to a full scan interval with no availability answer for dom0.
            $prevAnswered = ($prev.PSObject.Properties.Name -contains 'available') -and ($prev.phase -eq 'done')
            # A pass that ended REBOOT-PENDING did not scan: it reported a count derived from its own
            # result rows and logged "boot scan will confirm". That boot scan (BootTrigger + 2 min,
            # -Scheduled) is THIS pass, and it is the only correction dom0 ever gets - so a
            # reboot-pending status never counts as an answer that may suppress it. Measured
            # 2026-09-16 on German Win11 25H2 (4.3.29): the install pass wrote done_ts 22:49:16,
            # the boot scan fired at 22:54:00 with LastTaskResult 0, exited right here having
            # written nothing, and dom0 kept "no updates" with a 4.4 GB cumulative downloaded and
            # unapplied on the guest.
            $prevGuessed = [bool]$prev.reboot_needed   # GUARD:bootconfirm
            if ($prev.done_ts -and $prevAnswered -and -not $prevGuessed) {
                $age = ((Get-Date) - [datetime]$prev.done_ts).TotalMinutes
                # A negative age means the stamp is in the future (clock moved) - do not trust it
                # to skip work; run the pass.
                if ($age -ge 0 -and $age -lt $debounceMin) {
                    Write-Host ("skipping this scheduled scan: a {0} pass completed {1:N0} min ago (debounce {2} min)" -f `
                                $prev.action, $age, $debounceMin)
                    exit 0
                }
            }
        } catch { }   # unreadable/absent status = no reason to skip; fall through and scan
    }
}
# ---- WU-SCAN-DEBOUNCE-END

$script:Mutex = New-Object System.Threading.Mutex($false, 'Global\QubesWindowsUpdate')
$waitMs = if ($Action -eq 'scan') { 0 } else { 900000 }   # a scan yields; real work waits 15 min
$script:HaveMutex = $false
try { $script:HaveMutex = $script:Mutex.WaitOne($waitMs) } catch [System.Threading.AbandonedMutexException] { $script:HaveMutex = $true }
if (-not $script:HaveMutex) {
    Write-Host "another Qubes update operation is in progress - skipping this $Action"
    exit 0
}
New-Item -ItemType Directory -Force $WorkDir | Out-Null
# Legacy flat layout: .msu directly in the work dir. They are what DISM dragged into an unrelated
# servicing session, and they belong to no known KB now, so drop them once.
foreach($stale in @(Get-ChildItem (Join-Path $WorkDir '*.msu') -EA SilentlyContinue)) {
    Remove-Item -LiteralPath $stale.FullName -Force -EA SilentlyContinue
}
# WHICH catalog package applies is a property of THIS guest, not a constant. Hardcoding
# "x64 + 24H2|26100" made KB5120708 unresolvable on 25H2, where the applicable entry is titled
# "... for Windows 11, version 25H2 for x64" - the scan offered it and nothing could install it.
$__cv    = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -EA SilentlyContinue
$OsVer   = $__cv.DisplayVersion          # e.g. 25H2
$OsBuild = $__cv.CurrentBuild            # e.g. 26200
$OsArch  = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }

$IS='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings'
$POL='HKLM:\SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\Internet Settings'

# not_actionable is declared here so it always exists and always serialises: it is the DURABLE
# record of what a previous pass proved the guest cannot action, and it has to survive a scan,
# which writes an empty result. (GUARD:scanactioned / GUARD:prevstatus.)
$script:St = [ordered]@{ action=$Action; phase='init'; ts=$null; count=0; available=@();
                         downloading=$null; installing=$null; result=@(); reboot_needed=$false; error=$null;
                         not_actionable=@(); satisfied=@() }
# ---- WU-SAVE-ATOMIC-BEGIN
# ATOMIC, AND NEVER FATAL. The Qube Manager handler TAILS this file while a pass writes it (that is
# what the mutex comment above describes), and a plain Set-Content fails outright on the sharing
# violation. Measured 2026-09-21 on win11de-fresh, round 2: the pass died with "Der Prozess kann
# nicht auf die Datei C:\ProgramData\Qubes\update-status.json zugreifen, da sie von einem anderen
# Prozess verwendet wird" AFTER it had already reported 3 to dom0 - so dom0 was left holding a
# number the pass never stood behind, which is the untruth this whole file exists to prevent,
# arriving by way of a file lock. The judge caught it as a CONTRADICTORY pass.
#
# Write a temp file and MOVE it into place: the reader then sees either the old file or the new
# one, never a half-written one. Retry briefly, and if it still cannot land, LOG and carry on - a
# status write must never be able to kill the install it is reporting on. (# GUARD:saveatomic)
function Save {
    $script:St.ts = (Get-Date).ToString('s')
    $json = ($script:St | ConvertTo-Json -Depth 6)
    $tmp  = "$StatusFile.tmp"
    $err  = $null
    for ($i = 0; $i -lt 10; $i++) {
        try {
            Set-Content -LiteralPath $tmp -Value $json -Encoding UTF8 -EA Stop
            Move-Item -LiteralPath $tmp -Destination $StatusFile -Force -EA Stop
            return
        } catch {
            $err = $_
            Start-Sleep -Milliseconds 150
        }
    }
    try { Log ("WARNING: could not update the status file after 10 attempts (" + $err.Exception.Message + ") - continuing") } catch {}
}
# ---- WU-SAVE-ATOMIC-END

# A pass FINISHED. Distinct from Save, which also runs on every progress tick - `ts` therefore
# means "last activity" and cannot answer "when did a pass last complete". The scheduled-scan
# debounce needs exactly that, and reading `ts` instead would let a long download suppress the
# scan that should follow it. Records WHICH action completed too, so the skip message can say so.
function Complete-Pass {
    $script:St.done_ts = (Get-Date).ToString('s')
    $script:St.action  = $Action
    Save
}
# Does a status/result row carry a key? The rows this pass builds are [ordered]@{...}, i.e.
# OrderedDictionary, and on a dictionary PSObject.Properties.Name lists the .NET MEMBERS (Count,
# IsReadOnly, Keys, Values, IsFixedSize, SyncRoot, IsSynchronized) - never the keys. Measured on the
# guest's own Windows PowerShell 5.1.26100 and on pwsh 7.6 alike, so a key test written through it
# is a filter that matches nothing. A row that came back through ConvertFrom-Json is a PSCustomObject,
# where the property list IS the key list; both shapes are answered here, by their own contract.
# ---- WU-ROWKEY-BEGIN
function Test-RowKey($row, [string]$key) {
  if ($row -is [System.Collections.IDictionary]) { return [bool]$row.Contains($key) }
  return (@($row.PSObject.Properties.Name) -contains $key)
}
# ---- WU-ROWKEY-END
# Write-Host alone is lost under the scheduled task, which is why every download failure so far
# had to be reconstructed from DISM's log instead of ours. Tee to a file.
function Log($m){
  $line = (Get-Date -Format 'HH:mm:ss')+' '+$m
  Write-Host $line
  try { Add-Content -LiteralPath (Join-Path $WorkDir 'agent.log') -Value $line -EA SilentlyContinue } catch {}
}
function SetV($p,$n,$v,$t){ if(-not(Test-Path $p)){New-Item -Path $p -Force|Out-Null}; New-ItemProperty -Path $p -Name $n -Value $v -PropertyType $t -Force|Out-Null }

# The proxy is up ONLY for the duration of a pass. Leaving the system-wide WinHTTP proxy set
# turns the relay into an always-on escape hatch: every Windows background HTTP client (telemetry,
# Edge/Defender update checks, NCSI, DO) discovers it and phones home, each connection spawning a
# qrexec qubes.UpdatesProxy call - measured 147 dom0 policy hits in one afternoon on an "offline"
# guest, still dripping hours after the last scan. Remove-Proxy in the finally below restores the
# routeless baseline; update traffic is the only traffic that ever gets a path out.
function Test-RelayListening {
  # Does something ACCEPT a TCP connection on 127.0.0.1:8082 within 3 s? A relay PROCESS existing
  # does not prove the port is being serviced (a hung/dead relay, or a squatter, yields
  # 0x80072EFD ERROR_INTERNET_CANNOT_CONNECT). This catches the proven-once failure the old
  # process-exists check missed.
  try {
    $c = New-Object System.Net.Sockets.TcpClient
    $iar = $c.BeginConnect('127.0.0.1', 8082, $null, $null)
    $ok = $iar.AsyncWaitHandle.WaitOne(3000)
    $res = ($ok -and $c.Connected)
    $c.Close(); return $res
  } catch { return $false }
}
function Start-Relay {
  if (-not (Test-Path -LiteralPath $RelayExe)) { throw "relay not found at $RelayExe" }
  $env:QUBES_UPDATES_MAXCONN='256'
  # --parent-pid: the relay exits on its own when THIS process is gone (measured 2026-09-17: a pass
  # ended hard by the scheduler never reached the Remove-Proxy below, and the relay served for hours)
  Start-Process -FilePath $RelayExe -ArgumentList '--listen','8082','--target','@default','--log',$WorkDir,'--parent-pid',"$PID" -WindowStyle Hidden
  Start-Sleep -Seconds 2
}
function Ensure-Proxy {
  & netsh winhttp set proxy '127.0.0.1:8082' '<local>' | Out-Null
  SetV $POL 'ProxySettingsPerUser' 0 'DWord'; SetV $IS 'ProxyEnable' 1 'DWord'
  SetV $IS 'ProxyServer' '127.0.0.1:8082' 'String'; SetV $IS 'ProxyOverride' '<local>' 'String'
  if (-not (Get-Process qubes-updates-relay -EA SilentlyContinue)) { Start-Relay }
  # Serviceability probe: if nothing is accepting connections on 8082, kill any relay-named process
  # and respawn - a relay that exists but is not listening would otherwise fail the pass 0x80072EFD.
  if (-not (Test-RelayListening)) {
    Log 'relay not accepting connections on 127.0.0.1:8082 - killing any relay process and respawning' 'WARN'
    Get-Process qubes-updates-relay -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
    Start-Sleep -Seconds 1
    Start-Relay
    if (-not (Test-RelayListening)) { throw 'relay still not accepting connections on 127.0.0.1:8082 after respawn' }
  }
}

# REVOCATION SYNC - without this, every pass on a guest whose CTL cache has expired dies at
# 0x80072F8F before its first byte of update metadata. Measured + root-caused 2026-08-19:
# schannel REQUIRES revocation on the WU endpoints, and Microsoft-rooted chains use
# AUTO-UPDATE (CTL) revocation - the chain elements carry CERT_TRUST_AUTO_UPDATE_*_REVOCATION
# and the engine wants a FRESH disallowedcertstl from ctldl.windowsupdate.com, NOT the CDP
# CRLs (store-imported, KeyID-matched, time-valid CRLs were measured to change nothing).
# CryptoAPI's own fetches go DIRECT (never through the relay; no DNS on a proxy-only guest),
# so the CTLs can only arrive if WE carry them: fetch through the relay (ctldl is on its
# domain allowlist; plain-HTTP rides the verified/retried path built for exactly these files
# on 2026-08-14), mirror them locally, point AuthRoot\AutoUpdate!RootDirURL at the mirror,
# and flush the chain cache. The cabs are Microsoft-SIGNED CTL containers - Windows validates
# them at use, so a corrupted/hostile body is inert, not a poisoning vector.
# Side effect, accepted: OS root-store auto-update now sources from the mirror, i.e. new
# Microsoft roots arrive when a pass refreshes the mirror (before this, they never arrived).
function Sync-Revocation {
  $dir = 'C:\ProgramData\QubesCTL'
  New-Item -ItemType Directory -Path $dir -Force | Out-Null
  $proxy = 'http://127.0.0.1:8082'
  $got = 0
  foreach ($f in 'disallowedcertstl.cab','authrootstl.cab','pinrulesstl.cab') {
    # 2 attempts, 3 s apart: the relay's accept loop can lag its Start-Process by a few
    # seconds (warm-channel pool), and one connect-refused was measured to cost a whole pass.
    foreach ($try in 1..2) {
      try {
        Invoke-WebRequest -Uri "http://ctldl.windowsupdate.com/msdownload/update/v3/static/trustedr/en/$f" `
          -Proxy $proxy -OutFile "$dir\$f.new" -UseBasicParsing -TimeoutSec 60
        Move-Item "$dir\$f.new" "$dir\$f" -Force
        $got++
        break
      } catch {
        Remove-Item "$dir\$f.new" -Force -EA SilentlyContinue
        if ($try -eq 2) {
          # "keeping existing copy" was said even when there was NOTHING to keep. On a pristine
          # guest that is simply false, and it hid the state that matters.
          $had = Test-Path "$dir\$f"
          $tail = if ($had) { 'keeping the existing copy' } else { 'and there is NO existing copy' }
          Log "Sync-Revocation: $f fetch failed ($($_.Exception.Message)) - $tail" 'WARN'
        }
        else { Start-Sleep -Seconds 3 }
      }
    }
  }
  # Only point the OS root-store updater at the mirror if the mirror can actually serve it.
  # Repointing it at an EMPTY directory is worse than leaving it alone: chain building then finds
  # no CTL at all and fails with 0x80072F8F, while this function's log line claimed success. The
  # two that matter are the root list and the disallowed list; pinrules missing is survivable.
  $have = @('disallowedcertstl.cab','authrootstl.cab','pinrulesstl.cab') | Where-Object { Test-Path "$dir\$_" }
  $core = @('authrootstl.cab','disallowedcertstl.cab') | Where-Object { Test-Path "$dir\$_" }
  if ($core.Count -eq 2) {
    SetV 'HKLM:\SOFTWARE\Microsoft\SystemCertificates\AuthRoot\AutoUpdate' 'RootDirURL' "file://$dir" 'String'
    if ($have.Count -lt 3) { Log "Sync-Revocation: mirror is missing $(3 - $have.Count) of 3 CTLs but has both core lists - repointed anyway" 'WARN' }
  } else {
    # Leave the OS on whatever it was using; do not hand it a mirror that cannot answer. Take OUR
    # pointer away if a previous pass set one, so a half-built mirror from an earlier run cannot
    # keep poisoning chain validation.
    Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\SystemCertificates\AuthRoot\AutoUpdate' -Name 'RootDirURL' -EA SilentlyContinue
    Log "Sync-Revocation: FAILED - the CTL mirror has no usable root list (have: $($have -join ',' )). RootDirURL left unset, so certificate chain building may fail with 0x80072F8F until a pass succeeds." 'ERROR'
    $script:St.ctl_mirror = 'unusable'
    return
  }
  foreach ($v in 'DisallowedCertLastSyncTime','LastSyncTime','PinRulesLastSyncTime') {
    Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\SystemCertificates\AuthRoot\AutoUpdate' -Name $v -EA SilentlyContinue
  }
  # quoted deliberately: bare @now is PowerShell splatting and silently drops the argument
  & certutil -setreg 'chain\ChainCacheResyncFiletime' '@now' | Out-Null
  Log "Sync-Revocation: $got/3 CTLs refreshed through the relay, chain cache flushed"
}

# TEMPORAL GATE - still required, and not superseded by the relay's positional one.
# The relay now refuses any caller that is not the update process, which closes the leak this
# comment block describes. That check lives in our code and depends on our own process-identity
# logic being right; this teardown does not. Keeping both means a mistake in either one is
# bounded by the other: a wrong allowlist is still limited to the minutes a pass runs, and a
# pass left open still serves nobody but the update. Do not remove this because the other exists.
function Remove-Proxy {
  & netsh winhttp reset proxy | Out-Null
  SetV $IS 'ProxyEnable' 0 'DWord'
  Remove-ItemProperty -Path $IS -Name 'ProxyServer' -EA SilentlyContinue
  Get-Process qubes-updates-relay -EA SilentlyContinue | ForEach-Object { $_.Kill() }
  Log 'proxy removed, relay stopped (offline baseline restored)'
}

# Report the available-update count to dom0's qubes.NotifyUpdates (target: bare dom0).
# THIS build of qrexec-client-vm.exe takes ONE pipe-delimited command line "domain|service|user|
# local program [args]" and TRIGGERS the service, running the local program whose STDOUT is the
# vchan to the service - so the count is EMITTED by the local program (cmd /c echo N), NOT piped
# to stdin (stdin never crosses). dom0's qubes-notify-updates .strip()s the line so CRLF is fine.
#
# CRITICAL quoting: qrexec-client-vm's GetArgument() splits the RAW command line on '|' and does
# NOT strip quotes. Wrapping the whole "domain|...|prog" in double quotes therefore leaks a literal
# quote into the target field -> domain parses as "dom0, a VM that does not exist, and the daemon
# REFUSES it (proven: quoted -> HandleServiceRefused; unquoted -> accepted, flag set). PowerShell
# re-quotes any single arg containing spaces, so pass SPLIT tokens: the first (no spaces) is emitted
# verbatim with literal pipes; '/c' 'echo' $count append space-separated -> field4 = "cmd /c echo N".
function Report-Availability($count){
  $qr='C:\Program Files\Qubes Tools\bin\qrexec-client-vm.exe'
  if(-not(Test-Path $qr)){ Log 'qrexec-client-vm.exe not found - cannot report to dom0'; return }
  try { & $qr 'dom0|qubes.NotifyUpdates|user|cmd' '/c' 'echo' "$count" 2>&1 | Out-Null
        Log "reported $count update(s) to dom0 qubes.NotifyUpdates (exit $LASTEXITCODE)" }
  catch { Log "qubes.NotifyUpdates report failed: $($_.Exception.Message)" }
}

# Classify an offered IUpdate by the SHAPE of its published download content, WITHOUT a network
# round-trip, so the router can decide whether it is installable NLA-free. Proven separable on live
# scan data (scratchpad/dc-probe.ps1, 2026-08-20): self-contained updates carry a static
# download.windowsupdate.com URL with no query string (Defender mpam-fe.exe, MSRT, SSU, .NET .cab);
# express/UUP cumulatives (KB5071959) carry thousands of time-signed
# tlu.dl.delivery.mp.microsoft.com/filestreamingservice delta streams that ONLY Delivery Optimization
# can assemble - and DO refuses routeless (measured 0x80D03805), so those are terminally classified,
# not chased. Static WINS if any static URL exists; the walk is bounded (a self-contained payload
# appears in the first handful) so an express update's 8496 streams are never enumerated.
function Get-WuContentClass($u){
  $static=@(); $expressSeen=$false; $total=0
  $items=@($u); try{ $items += @($u.BundledUpdates) }catch{}
  foreach($b in $items){
    $dcc=$null; try{ $dcc=$b.DownloadContents }catch{}
    if(-not $dcc){ continue }
    $n=0
    foreach($dc in $dcc){
      $n++; $total++
      $url=$null; try{ $url=$dc.DownloadUrl }catch{}
      if($url){
        if($url -match 'filestreamingservice|tlu\.dl\.delivery\.mp\.microsoft\.com'){ $expressSeen=$true }
        else{
          # A DELTA patch (Defender am_delta_patch_*.exe) is NOT self-contained: it needs the current
          # engine as its base and cannot self-apply offline (measured 0x80070002 for bare run AND /q;
          # the FULL mpam-fe is DO-only, MpCmdRun -SignatureUpdate uses DO). Exclude it so Defender is
          # classified terminally (honest) rather than fail-attempting an unapplicable patch. WU's
          # IsDeltaCompressedContent is FALSE for these, so filter on the name too.
          $isDelta=$false; try{ $isDelta=[bool]$dc.IsDeltaCompressedContent }catch{}
          if((-not $isDelta) -and $url -notmatch 'delta' -and $url -match '^https?://[^/]*download\.windowsupdate\.com/' -and $url -notmatch '\?'){ $static += $url }
        }
      }
      if($n -ge 64){ break }
    }
    if($static.Count -gt 0 -and $expressSeen){ break }
  }
  if($static.Count -gt 0){ return @{ class='self-contained'; urls=@($static | Sort-Object -Unique) } }
  if($expressSeen -or $total -gt 50){ return @{ class='express'; urls=@() } }
  return @{ class='none'; urls=@() }
}

# ---- WU-APPX-CARVE-BEGIN
# A "self-contained" vendor installer may be a CONTAINER, not an installer: securityhealthsetup.exe
# holds its .appx packages as ZIP64 members of the PE and, on a netvm-less guest invoked directly
# rather than by the Windows Update engine, it exits 0 in under a second and does nothing at all -
# with no extract switch that works either (/x, /extract, /q /x all rc=0, nothing written).
# Measured 2026-09-21: the packages carve out intact, signatures included, and install in eleven
# seconds via Add-AppxProvisionedPackage. So carve and provision, the same way this updater already
# resolves .msu content itself instead of relying on BITS/DO, which cannot work here.
function Get-EmbeddedAppx {
    param([string]$ExePath, [string]$OutDir)
    $bytes = [IO.File]::ReadAllBytes($ExePath)
    New-Item -ItemType Directory -Force $OutDir | Out-Null
    $out = @()
    # ZIP64 end-of-central-directory: 'P','K',6,6. The classic EOCD that follows carries the
    # archive's true end; the ZIP64 record carries the central directory's size and offset, and
    # the archive therefore STARTS at (record position - size - offset).
    # Walk the CLASSIC end-of-central-directory records ('P','K',5,6). Each one ends an archive
    # and carries the central directory's size and offset, so the archive STARTS at
    # (eocd - size - offset). When those fields are 0xFFFFFFFF the archive is ZIP64 and the real
    # values live in the ZIP64 EOCD ('P','K',6,6) immediately before it. Handling BOTH matters:
    # keying only on the ZIP64 record would silently skip any ordinary-sized embedded package,
    # and "found nothing" is indistinguishable from "there was nothing".
    for ($i = 0; $i -lt $bytes.Length - 22; $i++) {
        if ($bytes[$i] -ne 0x50 -or $bytes[$i+1] -ne 0x4B -or $bytes[$i+2] -ne 0x05 -or $bytes[$i+3] -ne 0x06) { continue }
        $cdsize = [BitConverter]::ToUInt32($bytes, $i + 12)
        $cdoff  = [BitConverter]::ToUInt32($bytes, $i + 16)
        $end    = $i + 22 + [BitConverter]::ToUInt16($bytes, $i + 20)
        # [uint32]::MaxValue, NOT 0xFFFFFFFF: PowerShell parses that literal as Int32 -1, so
        # `4294967295 -eq 0xFFFFFFFF` is FALSE and the ZIP64 branch never runs. Measured
        # 2026-09-21 - it silently found zero packages in a file holding three.
        if ($cdsize -eq [uint32]::MaxValue -or $cdoff -eq [uint32]::MaxValue) {
            $z64 = -1
            for ($j = $i - 4; $j -ge 0 -and $j -gt $i - 8192; $j--) {
                if ($bytes[$j] -eq 0x50 -and $bytes[$j+1] -eq 0x4B -and $bytes[$j+2] -eq 0x06 -and $bytes[$j+3] -eq 0x06) { $z64 = $j; break }
            }
            if ($z64 -lt 0 -or $z64 + 56 -gt $bytes.Length) { continue }
            $start = [int64]$z64 - [int64][BitConverter]::ToUInt64($bytes, $z64 + 40) - [int64][BitConverter]::ToUInt64($bytes, $z64 + 48)
        } else {
            $start = [int64]$i - [int64]$cdsize - [int64]$cdoff
        }
        if ($start -lt 0 -or $end -le $start -or $end -gt $bytes.Length) { continue }
        $blob = New-Object byte[] ($end - $start)
        [Array]::Copy($bytes, $start, $blob, 0, $blob.Length)
        $tmp = Join-Path $OutDir ("member-" + $start + ".appx")
        [IO.File]::WriteAllBytes($tmp, $blob)
        # Identify it by its OWN manifest - never by filename or by size order.
        $name = $null; $ver = $null
        try {
            Add-Type -AssemblyName System.IO.Compression.FileSystem -EA SilentlyContinue
            $zip = [IO.Compression.ZipFile]::OpenRead($tmp)
            $ent = $zip.Entries | Where-Object { $_.FullName -eq 'AppxManifest.xml' } | Select-Object -First 1
            if ($ent) {
                $sr = New-Object IO.StreamReader($ent.Open())
                $xml = [xml]$sr.ReadToEnd(); $sr.Close()
                $name = $xml.Package.Identity.Name; $ver = $xml.Package.Identity.Version
            }
            $zip.Dispose()
        } catch {}
        if ($name) {
            $final = Join-Path $OutDir ($name + ".appx")
            Move-Item -Force $tmp $final
            $out += [pscustomobject]@{ Path = $final; Name = $name; Version = $ver; Bytes = $blob.Length }
        } else {
            Remove-Item -Force $tmp -EA SilentlyContinue
        }
    }
    return ,$out
}
# ---- WU-APPX-CARVE-END

# Provision what the wrapper would not. Main package vs frameworks is decided STRUCTURALLY, from
# each manifest: a framework declares <Framework>true</Framework> and the main package declares
# <PackageDependency> entries naming them. No filename matching, no size ordering.
function Install-EmbeddedAppx {
    param([string]$ExePath, [string]$WorkRoot)
    $res = [ordered]@{ attempted = $false; count = 0; ok = $false; detail = ''; mainVersion = $null }
    try {
        $dir = Join-Path $WorkRoot ('appx-' + [IO.Path]::GetFileNameWithoutExtension($ExePath))
        Remove-Item $dir -Recurse -Force -EA SilentlyContinue
        # NOT @(Get-EmbeddedAppx ...): the function returns `,$out` so the array survives the
        # pipeline intact, and wrapping it again yields a one-element array CONTAINING the
        # array - so the count is always 1 and the main/framework split sees one object with
        # every Name at once. Caught by tools/tests/wu-appx-carve-selftest.sh on its first run.
        $pkgs = Get-EmbeddedAppx -ExePath $ExePath -OutDir $dir
        $pkgs = @($pkgs)
        $res.count = $pkgs.Count
        if ($pkgs.Count -eq 0) { $res.detail = 'no embedded packages'; return $res }
        $res.attempted = $true
        $main = @(); $deps = @()
        foreach ($pk in $pkgs) {
            $isFw = $false
            try {
                $zip = [IO.Compression.ZipFile]::OpenRead($pk.Path)
                $ent = $zip.Entries | Where-Object { $_.FullName -eq 'AppxManifest.xml' } | Select-Object -First 1
                if ($ent) { $sr = New-Object IO.StreamReader($ent.Open()); $x = [xml]$sr.ReadToEnd(); $sr.Close()
                            $isFw = ("$($x.Package.Properties.Framework)" -eq 'true') }
                $zip.Dispose()
            } catch {}
            if ($isFw) { $deps += $pk.Path } else { $main += $pk.Path }
        }
        if ($main.Count -ne 1) { $res.detail = "expected exactly one non-framework package, found $($main.Count)"; return $res }
        $res.mainVersion = @($pkgs | Where-Object { $_.Path -eq $main[0] } | Select-Object -First 1).Version
        if ($deps.Count -gt 0) { Add-AppxProvisionedPackage -Online -PackagePath $main[0] -DependencyPackagePath $deps -SkipLicense -EA Stop | Out-Null }
        else                   { Add-AppxProvisionedPackage -Online -PackagePath $main[0] -SkipLicense -EA Stop | Out-Null }
        $res.ok = $true; $res.detail = "provisioned $([IO.Path]::GetFileName($main[0])) with $($deps.Count) dependency package(s)"
    } catch {
        $res.detail = $_.Exception.Message -replace '\s+',' '
    }
    return $res
}

function Get-Available {
  $s=New-Object -ComObject Microsoft.Update.Session
  $se=$s.CreateUpdateSearcher(); $se.ServerSelection=2; $se.Online=$true
  $r=$se.Search("IsInstalled=0 and IsHidden=0")
  $out=@()
  foreach($u in $r.Updates){
    $kb=@($u.KBArticleIDs)|Select-Object -First 1; $kb= if($kb){"KB$kb"}else{'(no KB)'}
    $cls = Get-WuContentClass $u    # content class + any static URLs, computed while the IUpdate is live
    # THE OFFER'S OWN IDENTITY. Without it a scan cannot tell "the same offer the last pass already
    # resolved" from "a genuinely new one", and so it must count both - which is why dom0 went from
    # empty back to 1 thirty seconds after a pass installed a Defender signature AND PROVED it by
    # effect (win11de-fresh, 2026-09-20). UpdateID+RevisionNumber is structured data straight off
    # the COM object: no title parsing, no locale dependence (ADR section 6).
    $uid=$null; $rev=$null
    try { $uid=[string]$u.Identity.UpdateID; $rev=[int]$u.Identity.RevisionNumber } catch {}
    $out += [ordered]@{ kb=$kb; title="$($u.Title)"; size_mb=[math]::Round($u.MaxDownloadSize/1MB,1); downloaded=[bool]$u.IsDownloaded; content_class=$cls.class; direct_urls=@($cls.urls); uid=$uid; rev=$rev }
  }
  return ,$out
}

# WU-NATIVE INSTALL - RETAINED AS A FALLBACK ONLY. Do not restore it as the default.
#
# CORRECTED 2026-08-14. This block used to say the catalog+DISM path "cannot service every image",
# citing KB5121003 being staged (rc=3010) and then ROLLED BACK at boot with 0x80070490 /
# CBS_E_INVALID_PACKAGE, and calling kb5043080 its "checkpoint prerequisite". That diagnosis was
# WRONG and the conclusion drawn from it was backwards. kb5043080 is not a prerequisite: it is a
# SUPERSEDED 2024-09 cumulative that the catalog bundles with the download, DISM rejects as not
# applicable (rc=552), and whose rejection poisons the CBS transaction the real cumulative then
# rides into. Dropping it BEFORE download makes the same image, the same package and the same DISM
# path install cleanly: verified 26100.8875 -> 26100.9168 with KB5043080 never present.
#
# So the catalog path does decide correctly which package an image needs - it just must not hand
# CBS the ones it does not.
#
# The searcher already runs online through our proxy (Get-Available), so the same session's
# downloader and installer can too. Delivery Optimization is forced into simple mode first,
# because DO does its own peer/CDN transport and does not reliably honour the WinHTTP proxy that
# Ensure-Proxy sets - and a qube has no other way out.
# Put Delivery Optimization back exactly as it was. MUST be reachable from every exit of
# Install-ViaWU: the first version restored it just before building the result rows, and the
# "WU: nothing to install" early return skipped it - measured, DODownloadMode=99 was still set
# on the guest afterwards. A policy this code sets for its own convenience must not outlive it.
function Restore-DoPolicy {
  if (-not $script:DoRestore) { return }
  try {
    if ($script:DoRestore.Had) { SetV $script:DoRestore.Key 'DODownloadMode' $script:DoRestore.Value 'DWord' }
    else { Remove-ItemProperty -LiteralPath $script:DoRestore.Key -Name 'DODownloadMode' -Force -EA SilentlyContinue }
    Log 'Delivery Optimization: restored'
  } catch { Log "could not restore DODownloadMode: $($_.Exception.Message)" }
  $script:DoRestore = $null
}

function Install-ViaWU {
  # $OnlyKbs limits the pass to specific KBs. Used as the FALLBACK for updates the Update
  # Catalog cannot serve: Defender definitions and the Malicious Software Removal Tool are not
  # .msu packages at all, so Resolve-Catalog will never find them, and without this they are
  # reported failed on every pass forever - dom0 keeps showing updates that can never clear.
  param([string[]]$OnlyKbs = @(), [bool]$TunePolicies = $true)
  # Delivery Optimization: no peering (99 = simple), and no background throttling. A qube's only
  # path out is the updates proxy, which is up ONLY during this pass, so there is nothing to be
  # polite to - the usual reason WU downloads slowly in the background does not apply here.
  #
  # These are MACHINE-WIDE POLICY writes and they persist. That was an acceptable price when
  # this function was an opt-in path for multi-gigabyte cumulatives. It is NOT acceptable on the
  # non-catalog fallback, which fires on almost every pass - Defender definitions are published
  # several times a day - and would leave every guest's Delivery Optimization and BITS policy
  # rewritten as a side effect of routine definition updates. The fallback passes $false: a few
  # megabytes of definitions do not need the transport tuned.
  # $TunePolicies=$false was a blunt answer to "do not leave machine policy rewritten": it also
  # gave up DODownloadMode=99, and Delivery Optimization does NOT reliably honour the WinHTTP
  # proxy in its default mode - which is the whole reason this block exists. A qube has no other
  # way out, so an unset DO can simply fail to download. Set the policy for the duration of the
  # pass and PUT IT BACK afterwards: reliability without a permanent change.
  $script:DoRestore = $null
  if (-not $TunePolicies) {
    $DO = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization'
    $prev = $null
    try { $prev = (Get-ItemProperty -LiteralPath $DO -Name DODownloadMode -EA Stop).DODownloadMode } catch { }
    $script:DoRestore = @{ Key = $DO; Had = ($null -ne $prev); Value = $prev }
    SetV $DO 'DODownloadMode' 99 'DWord'
    Log 'Delivery Optimization: DODownloadMode=99 for THIS pass only (restored at the end)'
  }
  if ($TunePolicies) {
    $DO = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization'
    SetV $DO 'DODownloadMode'                      99 'DWord'
    SetV $DO 'DOPercentageMaxBackgroundBandwidth' 100 'DWord'
    SetV $DO 'DOPercentageMaxForegroundBandwidth' 100 'DWord'
    SetV $DO 'DOMaxBackgroundDownloadBandwidth'     0 'DWord'   # 0 = unlimited
    SetV 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\BITS' 'EnableBITSMaxBandwidth' 0 'DWord'
    Log 'Delivery Optimization: simple mode, no background throttle (proxy is up only for this pass)'
  }

  try {
    $session = New-Object -ComObject Microsoft.Update.Session
    $searcher = $session.CreateUpdateSearcher(); $searcher.ServerSelection = 2; $searcher.Online = $true
    $script:St.phase='scan'; Save
    $found = $searcher.Search("IsInstalled=0 and IsHidden=0")
    if ($found.Updates.Count -eq 0) { Log 'WU: nothing to install'; return @() }

    $coll = New-Object -ComObject Microsoft.Update.UpdateColl
    foreach ($u in $found.Updates) {
      if ($OnlyKbs.Count -gt 0) {
        $kbs = @($u.KBArticleIDs) | ForEach-Object { "KB$_" }
        if (-not (@($kbs | Where-Object { $OnlyKbs -contains $_ }).Count -gt 0)) { continue }
      }
      if (-not $u.EulaAccepted) { try { $u.AcceptEula() } catch {} }
      [void]$coll.Add($u)
      Log ("WU: selected " + $u.Title)
    }
    if ($coll.Count -eq 0) { Log 'WU: nothing matched the requested KBs'; return @() }
    $script:St.count = $coll.Count; Save

    $script:St.phase='download'; Save
    $downloader = $session.CreateUpdateDownloader(); $downloader.Updates = $coll
    # dpHigh: WU downloads at background priority by default and paces itself accordingly -
    # measured bursts every ~3.5 s with idle gaps, while each connection sustained ~840 KB/s.
    try { $downloader.Priority = 3 } catch { Log '  (downloader does not accept Priority)' }
    Log "WU: downloading $($coll.Count) update(s) through the proxy"
    $dres = $downloader.Download()
    Log "WU: download ResultCode=$($dres.ResultCode) HResult=$($dres.HResult)"

    # Install only what actually downloaded; asking WU to install a missing payload just fails.
    $ready = New-Object -ComObject Microsoft.Update.UpdateColl
    foreach ($u in $coll) { if ($u.IsDownloaded) { [void]$ready.Add($u) } }
    if ($ready.Count -eq 0) { Log 'WU: nothing downloaded - not installing'; return @() }

    $script:St.phase='install'; Save
    $installer = $session.CreateUpdateInstaller(); $installer.Updates = $ready
    Log "WU: installing $($ready.Count) update(s)"
    $ires = $installer.Install()
    Log "WU: install ResultCode=$($ires.ResultCode) RebootRequired=$($ires.RebootRequired)"
    if ($ires.RebootRequired) { $script:St.reboot_needed = $true }

    # ResultCode: 2 = succeeded, 3 = succeeded with errors, 4 = failed, 5 = aborted.
    $rows = @()
    for ($i = 0; $i -lt $ready.Count; $i++) {
      $u = $ready.Item($i)
      $r = $ires.GetUpdateResult($i)
      $kb = @($u.KBArticleIDs) | Select-Object -First 1
      $rows += [ordered]@{ kb = $(if ($kb) { "KB$kb" } else { '(no KB)' })
                           ok = ($r.ResultCode -in @(2, 3))
                           files = @([ordered]@{ file = "$($u.Title)"; rc = $r.ResultCode; hr = $r.HResult }) }
      Log ("WU:   $($u.Title) -> ResultCode=$($r.ResultCode) HResult=$($r.HResult)")
    }
    return ,$rows
  } finally { Restore-DoPolicy }

}

# KB -> standalone .msu URLs from the Update Catalog (over the proxy), for THIS guest's
# architecture and Windows version.
#
# THE DECISION IS MADE ON THE FILENAME, NOT ON THE TITLE. Rewritten 2026-08-14 because the old
# version chose a row by matching ENGLISH words in its title, and the catalog's response language
# is not ours to choose: asking for fr-FR returned an ITALIAN title, and the same KB on the same
# guest came back German at 09:54 and English at 10:21. A real user runs a German edition. So the
# title is now used only to NARROW and RANK candidates by tokens nobody translates - the arch
# ("x64"/"arm64") and the build/version number - while the actual accept/reject test is run against
# the .msu filename the catalog hands back, which is language-invariant by construction.
#
# Two ambiguities the old title matching could not survive, both real:
#   * DisplayVersion alone does not identify a product: Windows 10 AND Windows 11 both shipped a
#     "22H2". CurrentBuild does (19045 vs 22621), so the BUILD is ranked above the version now.
#   * Build alone does not separate client from server: Windows Server 2025 and Windows 11 24H2
#     are BOTH build 26100.
#
# CORRECTED 2026-08-14, measured: the filename family does NOT separate client from server.
# Server packages are ALSO named windows11.0-* - "Cumulative Update for Microsoft server operating
# system version 24H2 ... (KB5120233)" ships windows11.0-kb5120233-x64_9344....msu. An earlier
# version of this comment claimed Server 2025 used windows10.0-*; that was an assumption and it was
# wrong. What the family check DOES buy is separating Windows 10 packages from Windows 11 ones.
#
# The real client/server separator is the KB NUMBER, which is product-specific: the 24H2 cumulative
# is KB5121003 for client and KB5120233 for server; the .NET one is KB5120710 client, KB5120708
# server. So a KB-specific search returns product-specific rows - measured, KB5121003 returns four
# rows, all client (24H2/25H2 x x64/arm64), no server row at all. The English `Server` keyword was
# never what kept server packages out.
#
# Dynamic Updates cannot reach us either, for two measured reasons: they ship .cab, not .msu (the
# `\.msu` filter below drops them outright), and they carry their OWN KB numbers - Safe OS Dynamic
# Update is KB5121002 and Setup Dynamic Update is KB5106084, neither of which is KB5121003.
#
# Nothing here is pinned to a Windows version: arch, build, version and product family are all read
# from the running guest. Hardcoding "x64 + 24H2|26100" once made KB5120708 unresolvable on 25H2.
# ---- WU-DRIVER-TITLE-BEGIN
# RESOLVE A KB-LESS OFFER BY ITS TITLE, AND CHOOSE BY WHAT THE PACKAGE DECLARES.
#
# Some offers carry no KB and no self-contained URL - measured on GWeck's environment:
# "Microsoft Corporation AudioProcessingObject Driver Update (1.0.4.7057)", content_class=none,
# direct_urls=[]. Resolve-Catalog is keyed on the KB, so it has no handle on them, and the row used
# to say so and stop. But the catalog DOES hold the item, under its title, and serves a real .cab.
#
# THE TRAP, and the reason this cannot be done on title text alone: that offer matches TWO catalog
# entries with byte-identical titles AND identical product strings. Title, order and size cannot
# tell them apart - one package declares `[Manufacturer] ... NTARM64` and the other `NTamd64`, and
# that is the only difference. So each candidate is DOWNLOADED and its INF read, and the choice is
# made on the architecture THE PACKAGE ITSELF DECLARES. Judge the artefact, never the label:
# the same rule as verify-by-effect, and the reason title language (nondeterministic here) is
# irrelevant to the decision.
function Get-PackageArch($cab){
  $d = Join-Path $WorkDir ('drvinsp-' + [IO.Path]::GetFileNameWithoutExtension($cab))
  Remove-Item $d -Recurse -Force -EA SilentlyContinue
  New-Item -ItemType Directory -Force $d | Out-Null
  & expand.exe "$cab" -F:*.inf "$d" 2>&1 | Out-Null
  foreach($inf in @(Get-ChildItem (Join-Path $d '*.inf') -EA SilentlyContinue)){
    $txt = Get-Content -Raw -LiteralPath $inf.FullName -EA SilentlyContinue
    if(-not $txt){ continue }
    $m = [regex]::Match($txt, '(?ms)^\[Manufacturer\](.*?)^\[')
    $blob = if($m.Success){ $m.Groups[1].Value } else { $txt }
    $a = @([regex]::Matches($blob, 'NT(amd64|arm64|x86)', 'IgnoreCase') | ForEach-Object { $_.Groups[1].Value.ToLower() } | Sort-Object -Unique)
    if($a.Count){ return ($a -join ',') }
  }
  return 'unknown'
}

function Resolve-DriverByTitle($title){
  $want = ($env:PROCESSOR_ARCHITECTURE).ToLower()          # AMD64 -> amd64, ARM64 -> arm64
  $q = [uri]::EscapeDataString(($title -replace '\s*\(Version [^)]*\)\s*$','').Trim())
  $hdr = @{}; if ($AcceptLanguage) { $hdr['Accept-Language'] = $AcceptLanguage }
  $r = Invoke-WebRequest "https://www.catalog.update.microsoft.com/Search.aspx?q=$q" -Proxy $Proxy -UseBasicParsing -TimeoutSec 60 -Headers $hdr
  $rows = [regex]::Matches($r.Content, "id='([0-9a-f-]{36})_link'[^>]*>\s*(.*?)\s*</a>", 'Singleline')
  $cands = @()
  foreach($m in $rows){
    $t = ($m.Groups[2].Value -replace '\s+',' ').Trim()
    if($t -eq $title.Trim()){ $cands += $m.Groups[1].Value }
  }
  if($cands.Count -eq 0){ Log "  title resolve: no catalog entry titled exactly '$title'"; return $null }
  Log "  title resolve: $($cands.Count) candidate(s); choosing by the architecture each PACKAGE declares (want $want)"
  foreach($uid in $cands){
    $json = '[{"size":0,"languages":"","uidInfo":"' + $uid + '","updateID":"' + $uid + '"}]'
    try { $dl = Invoke-WebRequest 'https://www.catalog.update.microsoft.com/DownloadDialog.aspx' -Method POST -Body @{updateIDs=$json} -Proxy $Proxy -UseBasicParsing -TimeoutSec 60 -Headers $hdr } catch { continue }
    $url = @([regex]::Matches($dl.Content, "https?://[^'`"]+\.cab") | ForEach-Object { $_.Value } | Sort-Object -Unique)[0]
    if(-not $url){ continue }
    $f = Join-Path $WorkDir ([IO.Path]::GetFileName(($url -split '\?')[0]))
    if(-not (Test-Path $f)){ Fetch-Msu $url $f | Out-Null }
    if(-not (Test-Path $f)){ continue }
    $arch = Get-PackageArch $f
    Log "    $uid arch=$arch"
    if($arch -split ',' -contains $want){ return @{ uid=$uid; url=$url; file=$f; arch=$arch } }
  }
  Log "  title resolve: no candidate declares $want - this offer is not installable on this architecture"
  return $null
}

# INSTALL a driver package and VERIFY BY EFFECT. pnputil's own exit code is not the answer: the
# question is whether the driver is in the store afterwards, which /enum-drivers states.
function Install-DriverCab($cab, $label){
  $d = Join-Path $WorkDir ('drv-' + [IO.Path]::GetFileNameWithoutExtension($cab))
  Remove-Item $d -Recurse -Force -EA SilentlyContinue
  New-Item -ItemType Directory -Force $d | Out-Null
  & expand.exe "$cab" -F:* "$d" 2>&1 | Out-Null
  $inf = @(Get-ChildItem (Join-Path $d '*.inf') -EA SilentlyContinue | Select-Object -First 1)
  if($inf.Count -eq 0){ return [ordered]@{ file=[IO.Path]::GetFileName($cab); ok=$false; reason='no .inf inside the package' } }
  $name = $inf[0].Name
  $before = (& pnputil.exe /enum-drivers 2>&1 | Out-String)
  $p = Start-Process pnputil.exe -ArgumentList @('/add-driver', $inf[0].FullName, '/install') -Wait -PassThru -WindowStyle Hidden
  $after = (& pnputil.exe /enum-drivers 2>&1 | Out-String)
  # EFFECT: the original INF name appears in the driver store now and did not before, or it was
  # already there (a re-offer of something installed). rc alone decides nothing.
  $was = $before -match [regex]::Escape($name)
  $now = $after  -match [regex]::Escape($name)
  $row = [ordered]@{ file=$name; rc=$p.ExitCode; ok=$now; verified_by_effect=$now
                     probe='pnputil-enum'; severity=$null; info_reason=$null }
  if($now -and -not $was){ Log "  $label : driver added to the store (pnputil rc=$($p.ExitCode), verified by /enum-drivers)" }
  elseif($now -and $was){ $row.severity=$null; Log "  $label : already present in the driver store - nothing to do" }
  else { Log "  $label : pnputil rc=$($p.ExitCode) but $name is NOT in the driver store - did NOT install" }
  return $row
}
# ---- WU-DRIVER-TITLE-END

function Resolve-Catalog($kb){
  $hdr = @{}
  if ($AcceptLanguage) { $hdr['Accept-Language'] = $AcceptLanguage }
  $r=Invoke-WebRequest "https://www.catalog.update.microsoft.com/Search.aspx?q=$kb" -Proxy $Proxy -UseBasicParsing -TimeoutSec 60 -Headers $hdr
  # ---- WU-CATALOG-VALID-BEGIN
  # GUARD:catalogvalid - ZERO RESULTS AND A BROKEN RESPONSE LOOK IDENTICAL, and they must not.
  # Everything downstream reads "0 catalog .msu" as "the catalog has no package for this KB", which
  # sends the KB to the informational ceiling dom0 excludes from its count - a class this code logs
  # as "terminally classified". But a truncated body (relay truncation on large responses is a
  # KNOWN failure mode on this path), an error or interstitial page, or a garbled encoding all
  # produce zero regex matches too, so a transient transport fault would permanently hide a real
  # installable update from dom0 - the field defect this product already shipped once.
  # Jev: is_defect 0.94, severity high-silently-hides-real-updates 1.00, self_corrects 0.21.
  # Believe a zero count ONLY from a response that is demonstrably the catalog's own results page.
  $script:CatalogUnresolved = $false
  $body = [string]$r.Content
  if ([string]::IsNullOrWhiteSpace($body) -or ($body -notmatch '(?i)catalogBody|updateMatches|catalog\.update\.microsoft\.com')) {
    $script:CatalogUnresolved = $true
    Log ("  " + $kb + " : catalog response is not a results page (" + $body.Length + " bytes) - UNRESOLVED, not 'no package'")
    return @()
  }
  # ---- WU-CATALOG-VALID-END
  $rx=[regex]"(?is)id='([0-9a-fA-F\-]{36})_link'[^>]*>(.*?)</a>"
  $digits = $kb -replace '\D',''

  # Expected filename family for THIS guest, derived - never assumed. InstallationType is 'Client'
  # or 'Server'/'Server Core' and is not localized; 22000 is the Windows 11 build boundary, a
  # number rather than a name. Used as a PREFERENCE, not a hard requirement, so an unforeseen
  # future family degrades to "still picks a correctly-named package for this arch and KB".
  $instType = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -EA SilentlyContinue).InstallationType
  $wantFamily = if ($instType -like 'Client*' -and [int]$OsBuild -ge 22000) { 'windows11.0' } else { 'windows10.0' }

  # Rank candidates on untranslated tokens only. Arch is mandatory; build outranks version; the
  # old English keywords survive ONLY as a tie-breaker nudge and can no longer reject anything.
  $ranked = @()
  $all = @()
  foreach($m in $rx.Matches($r.Content)){
    $t=($m.Groups[2].Value -replace '<[^>]+>','' -replace '\s+',' ').Trim()
    $all += $t
    if($t -notmatch [regex]::Escape($OsArch)){ continue }
    $score = 0
    if($OsBuild -and $t -match [regex]::Escape($OsBuild)){ $score += 4 }
    if($OsVer   -and $t -match [regex]::Escape($OsVer))  { $score += 2 }
    if($score -eq 0){ continue }
    # Ranking hint ONLY - this can no longer reject anything, so a locale it fails to cover costs
    # ordering, not correctness. Stems, because the shared prefix is what survives translation:
    # 'Dynami' covers Dynamic/Dynamisch/dinamico/dynamique, and -match is case-insensitive so
    # 'Server' already catches German "Serverbetriebssystem" and Italian "sistema operativo
    # server" - but NOT French "serveur" or Spanish "servidor", hence those spelled out.
    # 'server operating system' is dropped as dead weight: 'Server' already matches it.
    #
    # ASCII ONLY, deliberately. A CJK stem here was mangled to '?a??a?' in transit and broke the
    # parse (ps-syntax-check caught it) - this file crosses qrexec/qtest and is written as ASCII,
    # so a non-ASCII literal is a syntax error waiting to happen. Since this is only a ranking
    # nudge, losing a script we cannot spell costs ordering, never correctness.
    if($t -match 'Dynami|Server|Serveur|Servidor|servidore'){ $score -= 3 }
    $ranked += [pscustomobject]@{ guid=$m.Groups[1].Value; title=$t; score=$score }
  }
  $ranked = @($ranked | Sort-Object -Property @{Expression='score';Descending=$true})

  $fallback = $null
  foreach($c in $ranked){
    $json='[{"size":0,"languages":"","uidInfo":"'+$c.guid+'","updateID":"'+$c.guid+'"}]'
    try{
      $dl=Invoke-WebRequest 'https://www.catalog.update.microsoft.com/DownloadDialog.aspx' -Method POST -Body @{updateIDs=$json} -Proxy $Proxy -UseBasicParsing -TimeoutSec 60 -Headers $hdr
    }catch{ Log ("  candidate rejected (download dialog failed): " + $c.title); continue }
    $files=@([regex]::Matches($dl.Content,"url\s*=\s*'(http[^']+)'")|ForEach-Object{$_.Groups[1].Value}|Where-Object{$_ -match '\.msu(\?|$)'}|Sort-Object -Unique)
    if(-not $files.Count){ Log ("  candidate rejected (no .msu): " + $c.title); continue }

    # THE test: does this candidate actually carry a package named for this KB and this arch?
    # EXCEPTION for .NET Framework CUs: the offered ROLLUP KB (e.g. KB5066747) is delivered as
    # COMPONENT packages named for a DIFFERENT KB (windows10.0-kb5066130-ndp481, kb5066135-ndp48), so the
    # rollup digits never appear in the filenames and the digit test wrongly rejected a real, installable
    # .NET security CU (measured 2026-08-20). For .NET candidates, match on arch only and take every .msu
    # (all are correct .NET component packages; Install-Msus skips the ones this image does not apply).
    $isDotNet = $c.title -match '\.NET Framework'
    $named = @($files | Where-Object { ($isDotNet -or $_ -match $digits) -and $_ -match [regex]::Escape($OsArch) })
    if(-not $named.Count){
      Log ("  candidate rejected (no file named for $kb/$OsArch): " + $c.title)
      foreach($f in $files){ Log ("      had: " + (& { if($f -match '/([^/?]+\.msu)'){$Matches[1]} else {$f} })) }
      continue
    }
    $family = @($named | Where-Object { $_ -match [regex]::Escape($wantFamily) })
    if($family.Count){
      Log ("  catalog pick: " + $c.title)
      Log ("    matched on filename family $wantFamily + $kb + $OsArch (title language is irrelevant)")
      return $files
    }
    # Right KB and arch, wrong/unknown product family - keep as a fallback and look for better.
    if(-not $fallback){ $fallback = [pscustomobject]@{ files=$files; title=$c.title } }
    Log ("  candidate deferred (no $wantFamily file): " + $c.title)
  }

  if($fallback){
    Log ("  catalog pick (FALLBACK - no $wantFamily package found for this KB): " + $fallback.title)
    return $fallback.files
  }
  # Log every candidate: a resolution miss is otherwise invisible and looks like "no updates".
  Log "  no catalog entry matches arch=$OsArch ver=$OsVer build=$OsBuild family=$wantFamily; candidates:"
  foreach($c in $all){ Log "    - $c" }
  return @()
}

# Resumable fetch with progress into the status file, and with the two checks whose absence
# produced an unusable 5 GB file (2026-08-13, template): CBS rejected both packages with
# CBS_E_INVALID_PACKAGE, DISM logged "Failed to open ESD ... 0x8007000d" and a DPX range error
# 0xca00a005 - i.e. the bytes on disk were not a package at all.
#
# WHY IT COULD HAPPEN: the old version sent a Range header and then ALWAYS appended the response.
# A server (or the relay) that ignores the range and answers 200 with the WHOLE body appends a
# full copy onto the partial one, producing a file of plausible size and corrupt content. Nothing
# checked afterwards, so it went to DISM, "succeeded" with 3010, and was rolled back at boot.
#
# Now: a ranged request that comes back 200 restarts the file instead of appending; the expected
# total is taken from Content-Range when the server does honour the range; and the finished file
# is verified for BOTH size and the CAB magic (an .msu is a cabinet - "MSCF"), which is what
# catches an HTML error page or a truncated download. A file that fails verification is DELETED,
# never resumed - resuming corrupt bytes can only produce more corrupt bytes.
# Returns 'ok' | 'short' | 'bad'. The distinction matters more than it looks: treating a SHORT
# file as corrupt turns every dropped connection into a restart from zero, and a 4.8 GB package
# over a relay that drops around 3 GB then never completes - measured 2026-08-13, the download
# looped 3.18 GB -> deleted -> 0 bytes -> repeat.
function Test-Msu($path, $expect) {
  if (-not (Test-Path -LiteralPath $path)) { return 'bad' }
  $len = (Get-Item -LiteralPath $path).Length
  if ($len -eq 0) { return 'bad' }
  try {
    $fs = [IO.File]::OpenRead($path)
    $magic = New-Object byte[] 4
    $null = $fs.Read($magic, 0, 4)
    $fs.Close()
  } catch { return 'bad' }   # an UNREADABLE file is corrupt, not success: 'bad' (was $false, which matched no case)
  # An .msu is NOT always a cabinet. Classic packages start with 'MSCF', but recent Windows 11
  # cumulative updates ship as WIM containers starting with 'MSWIM' - measured 2026-08-13:
  # KB5121003's .msu begins 4D 53 57 49 4D. A CAB-only check rejected a perfectly good 4.8 GB
  # download and looped forever, which is worse than the problem it was added for. Accept both,
  # and keep the check only for what it is actually good at: catching an HTML error page.
  $isCab = ($magic[0] -eq 0x4D -and $magic[1] -eq 0x53 -and $magic[2] -eq 0x43 -and $magic[3] -eq 0x46)
  $isWim = ($magic[0] -eq 0x4D -and $magic[1] -eq 0x53 -and $magic[2] -eq 0x57 -and $magic[3] -eq 0x49)
  # A self-contained WU update can also be an executable (Defender mpam-fe.exe, MSRT
  # windows-kb890830-*.exe) - a valid PE starts 'MZ' (4D 5A). Accept it: an HTML error page still
  # begins '<' (0x3C), so this keeps catching garbage while letting Install-SelfContained fetch exes.
  $isExe = ($magic[0] -eq 0x4D -and $magic[1] -eq 0x5A)
  if (-not ($isCab -or $isWim -or $isExe)) {
    Log "  VERIFY: $([IO.Path]::GetFileName($path)) is not MSCF/MSWIM/MZ - discarding"
    return 'bad'          # an HTML error page or garbage: resuming it can only make it worse
  }
  if ($expect -gt 0 -and $len -lt $expect) { return 'short' }   # incomplete: RESUME, do not delete
  if ($expect -gt 0 -and $len -gt $expect) {
    Log "  VERIFY: $([IO.Path]::GetFileName($path)) is $len bytes, expected $expect - discarding"
    return 'bad'          # longer than advertised = a body appended onto a partial
  }
  return 'ok'
}

function Get-UrlSize($url){
  # Size WITHOUT fetching a body, so "what would this cost" is answerable before committing to it.
  # Two ways, because CDNs are inconsistent: HEAD first, then a one-byte ranged GET whose
  # Content-Range trailer carries the full length. Returns -1 when neither works - callers must
  # print that as unknown rather than silently reporting 0, which would read as "free".
  foreach($method in 'HEAD','GET'){
    try{
      $r=[System.Net.HttpWebRequest]::Create($url); $r.Proxy=New-Object System.Net.WebProxy($Proxy)
      $r.Timeout=30000; $r.Method=$method
      if($method -eq 'GET'){ $r.AddRange(0,0) }
      $resp=$r.GetResponse()
      $len=-1
      $cr=$resp.Headers['Content-Range']
      if($cr -and $cr -match '/(\d+)\s*$'){ $len=[int64]$Matches[1] }
      elseif($resp.ContentLength -gt 0){ $len=[int64]$resp.ContentLength }
      $resp.Close()
      if($len -ge 0){ return $len }
    }catch{ }
  }
  return -1
}

function Fetch-Msu($url,$dst,$kb){
  # Throughput is a first-class output here, not a nicety: every rate figure recorded for this
  # tunnel so far was taken while the guest was also talking to telemetry endpoints the proxy
  # allowlist now blocks, so none of them describe the shipping configuration. Log bytes and
  # wall time per attempt and let the numbers come from the real workload.
  # Measured against what was on disk when this call began, so a resumed download reports the
  # bytes IT moved rather than crediting itself with an earlier attempt's progress.
  $tStart = Get-Date
  $startLen = if (Test-Path $dst) { (Get-Item $dst).Length } else { 0 }
  # 14 attempts, not 8: the relay intermittently churns its warm channel and a fresh GetResponse can
  # time out with zero bytes (measured on the 85 MB MSRT self-contained fetch - attempts stalled, then
  # resumed 16 -> 32 MB). Since each attempt RESUMES from bytes-on-disk, a large file completes across
  # more attempts even when individual ones abort. GetResponse timeout raised 60->90s to give a slow
  # relay response more room before aborting an otherwise-good attempt.
  for($a=1;$a -le 14;$a++){
    $have=0; if(Test-Path $dst){$have=(Get-Item $dst).Length}; $o=$null; $expect=0
    try{
      $req=[System.Net.HttpWebRequest]::Create($url); $req.Proxy=New-Object System.Net.WebProxy($Proxy)
      $req.Timeout=90000; $req.ReadWriteTimeout=180000
      $asked=$false; if($have -gt 0){ $req.AddRange($have); $asked=$true }
      $resp=$req.GetResponse()

      # Did the server honour the range? 206 = yes, resume. Anything else = start over.
      $status=[int]$resp.StatusCode
      $append=$false
      if($asked -and $status -eq 206){
        $append=$true
        $cr=$resp.Headers['Content-Range']
        if($cr -and $cr -match '/(\d+)\s*$'){ $expect=[int64]$Matches[1] } else { $expect=$have+$resp.ContentLength }
      } else {
        if($asked){ Log "  server ignored the resume range (HTTP $status) - restarting the download" }
        $have=0; $expect=$resp.ContentLength
      }

      $mode = if($append){[System.IO.FileMode]::Append}else{[System.IO.FileMode]::Create}
      $in=$resp.GetResponseStream()
      $o=[System.IO.File]::Open($dst,$mode); $buf=New-Object byte[] (1048576); $last=Get-Date
      while(($n=$in.Read($buf,0,$buf.Length)) -gt 0){ $o.Write($buf,0,$n); $have+=$n
        if(((Get-Date)-$last).TotalSeconds -ge 3){ $script:St.downloading=[ordered]@{kb=$kb;file=[IO.Path]::GetFileName($dst);mb=[math]::Round($have/1MB,1);total_mb=[math]::Round($expect/1MB,1);pct=[math]::Round(100*$have/[math]::Max($expect,1),1)}; Save; $last=Get-Date } }
      $o.Close();$in.Close();$resp.Close()

      $verdict = Test-Msu $dst $expect
      if($verdict -eq 'bad'){
        Remove-Item -LiteralPath $dst -Force -EA SilentlyContinue   # never resume corrupt bytes
        Log "  attempt ${a}: file is not a package - discarded, restarting"
        Start-Sleep 5
        continue
      }
      if($verdict -eq 'short'){
        Log "  attempt ${a}: stream ended early at $([math]::Round($have/1MB,1)) of $([math]::Round($expect/1MB,1)) MB - resuming"
        Start-Sleep 5
        continue                                                    # keep the bytes, resume them
      }
      $script:St.downloading=[ordered]@{kb=$kb;file=[IO.Path]::GetFileName($dst);mb=[math]::Round($have/1MB,1);total_mb=[math]::Round($have/1MB,1);pct=100}; Save
      $bytesThisRun = $have - $startLen
      $secs = [math]::Max(((Get-Date) - $tStart).TotalSeconds, 0.001)
      Log ("  THROUGHPUT {0}: {1:N1} MB fetched in {2:N0}s = {3:N0} KB/s (file now {4:N1} MB, {5} attempt(s))" -f `
           [IO.Path]::GetFileName($dst), ($bytesThisRun/1MB), $secs, ($bytesThisRun/1KB/$secs), ($have/1MB), $a)
      return $true
    }catch{
      if($o){try{$o.Close()}catch{}}
      # A complete local copy makes the server refuse the resume range with 416. That is
      # "already downloaded", not a failure - measured 2026-08-13: a re-run after a successful
      # pass burned all 8 attempts on 416 and reported the update as unresolvable.
      # PowerShell wraps a failing method call in a MethodInvocationException, so $_.Exception is
      # NOT the WebException - it is the wrapper. Unwrap it, and keep a text fallback: this check
      # silently did nothing the first time precisely because of that wrapping.
      $code=$null; $we=$_.Exception
      if($we -isnot [System.Net.WebException] -and $we.InnerException){ $we=$we.InnerException }
      if($we -is [System.Net.WebException] -and $we.Response){ $code=[int]$we.Response.StatusCode }
      if(-not $code -and $_.Exception.Message -match '\(416\)'){ $code=416 }
      if($code -eq 416 -and $have -gt 0){
        # Complete by the server's reckoning - but PROVE it. expect=0 skipped the SIZE check, so an
        # over-long corrupt-append file with valid leading magic slipped through. Verify magic AND
        # size against the server's true total (Get-UrlSize; -1 => magic-only, best effort).
        $srvTotal = Get-UrlSize $url
        if((Test-Msu $dst $srvTotal) -eq 'ok'){
          Log "  $([IO.Path]::GetFileName($dst)) already complete ($([math]::Round($have/1MB,1)) MB; server refused resume with 416)"
          $script:St.downloading=[ordered]@{kb=$kb;file=[IO.Path]::GetFileName($dst);mb=[math]::Round($have/1MB,1);total_mb=[math]::Round($have/1MB,1);pct=100}; Save
          return $true
        }
        Log "  local copy failed verification despite 416 (magic/size) - discarding and refetching"
        Remove-Item -LiteralPath $dst -Force -EA SilentlyContinue
        continue
      }
      Log "  fetch attempt ${a}: $($we.Message)"; Start-Sleep 5 }
  }
  return $false
}

# DISM outcomes that mean "this package is now on the system": success, success-pending-reboot,
# and already-installed (0x240006). Anything else is a real failure for that FILE - though not
# necessarily for the KB, see the per-KB rule at the call site.
#
# NOTE: this definition was once deleted by a careless region replacement (the Fetch-Msu rewrite
# above), leaving $OK_RC undefined - so `$_.rc -in $OK_RC` was always false and EVERY install
# reported failure, including one that had returned 3010. Keep it adjacent to its only consumers.
$OK_RC = @(0, 3010, 2359302)
# Set the moment any package is STAGED (rc=3010). CBS applies exactly one staged session per
# boot; a second package staged behind the first is silently discarded, so the pass stops
# staging once this is true and the next pass picks up the rest after the reboot.
# Set QUBES_UPDATES_ALLOW_MULTISTAGE=1 to stage several packages anyway - Windows DOES aggregate
# packages per reboot normally, so the one-per-session rule rests on a single observation and must
# stay falsifiable. That variable is how the aggregation question gets re-tested.
# TEST HOOKS, same convention as the agent's SoloFaultInject: the multistage-defer guard only
# fires when a session has already staged a reboot-requiring package AND a non-catalog KB is
# still pending, and that combination cannot be summoned on a guest that is already up to date.
#   QUBES_UPDATES_FAKE_STAGED=1        pretend this session staged something
#   QUBES_UPDATES_FAKE_FALLBACK_KB=KB. pretend that KB needs the Windows Update fallback
# Both are dead code when unset.
$script:StagedThisSession = ($env:QUBES_UPDATES_FAKE_STAGED -eq '1')
if ($script:StagedThisSession) { Log 'QUBES_UPDATES_FAKE_STAGED=1 - pretending a reboot-requiring package is already staged' }

# ASK DISM WHETHER A PACKAGE APPLIES, BEFORE INSTALLING IT.
# Measured 2026-08-13/14 on a 24H2 image: the catalog returns SEVERAL .msu per KB, and we ran all
# of them. kb5043080 came back rc=552 and DISM's own log said "Not applicable ... Feature:
# CumulativeUpdate_KB5043080"; the real cumulative then staged (3010) and was ROLLED BACK at boot
# with 0x80070490 / CBS_E_INVALID_PACKAGE. Running an inapplicable package is not free - it can
# leave the servicing session in a state the applicable one cannot complete from.
#
# /Get-PackageInfo answers the question directly and changes nothing. Returns a hashtable:
#   applicable : Yes | No | unknown        state : Installed | Not Present | Install Pending | ...
#   identity   : the CBS package identity, which also tells us what KIND of package it is
function Get-MsuInfo($path){
  $out = & DISM /Online /Get-PackageInfo /PackagePath:"$path" /English 2>&1
  $info = @{ applicable='unknown'; state='unknown'; identity=''; rc=$LASTEXITCODE }
  foreach($l in $out){
    if($l -match '^\s*Applicable\s*:\s*(\S+)')       { $info.applicable = $Matches[1] }
    elseif($l -match '^\s*State\s*:\s*(.+?)\s*$')     { $info.state      = $Matches[1] }
    elseif($l -match '^\s*Package Identity\s*:\s*(\S+)'){ $info.identity  = $Matches[1] }
  }
  return $info
}

# Servicing order matters: a servicing-stack update must be installed BEFORE the cumulative that
# requires it, and the file size we used to sort by is only a proxy for that. The CBS identity
# names the kind, so order by it and fall back to size.
function Order-Msus($files){
  $ranked = @()
  foreach($f in $files){
    $id = ''
    try { $id = (Get-MsuInfo $f).identity } catch { $id = '' }
    $rank = 2                                             # default: everything else
    if($id -match 'ServicingStack|SSU')   { $rank = 0 }   # servicing stack first
    elseif($id -match 'Checkpoint')       { $rank = 1 }   # then any checkpoint package
    elseif($id -match 'RollupFix|LCU')    { $rank = 3 }   # cumulative last
    $ranked += [pscustomobject]@{ path=$f; rank=$rank; size=(Get-Item $f).Length; id=$id }
  }
  return ,@($ranked | Sort-Object rank, size | ForEach-Object { $_.path })
}

# DISM cannot ingest .msu on Win10 (measured 2026-08-19: rc=50 'request is not supported' on
# 19045 for both the LCU and the .NET package; the same call works on Win11 26100, where the
# whole catalog+DISM path was built and proven). And the WU-native path cannot replace it on
# a netvm-less guest: BITS/DO refuse jobs outright with no network interface present
# (0x80200010 BG_E_NETWORK_DISCONNECTED / 0x80D03805 - NLM sees no NIC; the loopback proxy
# does not count). So on rc=50 the .msu is EXPANDED (an .msu is a cab archive) and the inner
# .cab payloads go to DISM directly - the classic Win10 servicing shape. WSUSSCAN.cab is
# metadata, not a package; SSU-named cabs rank first (combined LCUs usually carry the SSU
# inside the main cab, where CBS orders it itself). rc reduction across cabs: any real
# failure wins, else 3010 if anything staged, else 0.
function Add-PackageCompat($f){
  & DISM /Online /Add-Package /PackagePath:"$f" /NoRestart /Quiet /LogPath:"$WorkDir\dism.log" | Out-Null
  $rc=$LASTEXITCODE
  if($rc -ne 50){ return $rc }
  $name=[IO.Path]::GetFileName($f)
  Log "  $name : DISM rc=50 (.msu unsupported on this OS) - expanding to cabs"
  $tmp = Join-Path $WorkDir ('msux-' + [IO.Path]::GetFileNameWithoutExtension($f).Substring(0, [Math]::Min(40, [IO.Path]::GetFileNameWithoutExtension($f).Length)))
  Remove-Item $tmp -Recurse -Force -EA SilentlyContinue
  New-Item -ItemType Directory -Path $tmp -Force | Out-Null
  & expand.exe -F:* "$f" "$tmp" | Out-Null
  $cabs = @(Get-ChildItem $tmp -Filter '*.cab' | Where-Object { $_.Name -ine 'WSUSSCAN.cab' } |
            Sort-Object @{e={ if($_.Name -match 'SSU'){0}else{1} }}, Length)
  if($cabs.Count -eq 0){ Log "  $name : expand produced no cabs"; Remove-Item $tmp -Recurse -Force -EA SilentlyContinue; return 50 }
  $worst=0; $staged=$false
  foreach($c in $cabs){
    & DISM /Online /Add-Package /PackagePath:"$($c.FullName)" /NoRestart /Quiet /LogPath:"$WorkDir\dism.log" | Out-Null
    $crc=$LASTEXITCODE
    Log ("  cab " + $c.Name + " rc=" + $crc)
    if($crc -eq 3010 -or $crc -eq 2359302){ $staged=$true }
    elseif($crc -ne 0){ $worst=$crc }
  }
  Remove-Item $tmp -Recurse -Force -EA SilentlyContinue
  if($worst -ne 0){ return $worst }
  if($staged){ return 3010 }
  return 0
}

# Does this guest have a REAL default route (i.e. a netvm)? Loopback/blackhole adapters do not count.
# Templates have none by design; only netvm-attached standalones do. Used to gate the DO/BITS-based
# Install-ViaWU rung, which fails routeless (measured DO 0x80D03805 / BITS 0x80200010) and must never
# run on a netvm-free guest where it only produces phantom failures.
function Test-HasDefaultRoute {
  try {
    return @(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -EA SilentlyContinue |
             Where-Object { $_.InterfaceAlias -notmatch 'Loopback' }).Count -gt 0
  } catch { return $false }
}

# Best-effort ESU (Extended Security Updates) entitlement status, for the honesty gate on post-EOS
# Win10 (19045). Not load-bearing - purely informational for dom0 - so it never throws.
function Get-EsuStatus {
  try {
    $esu = @(Get-CimInstance -ClassName SoftwareLicensingProduct -EA SilentlyContinue |
             Where-Object { $_.Name -match 'ESU|Extended Security' -and $_.LicenseStatus -eq 1 })
    if ($esu.Count -gt 0) { return 'entitled' }
    return 'not-enrolled'
  } catch { return 'unknown' }
}

# Build a human-readable INFORMATIONAL diagnosis for the post-end-of-support / ESU-gated state, so dom0
# sees WHY the newest security cumulative is not being installed - a licensing ceiling, not a transport
# failure. Returns $null when there is nothing to report (ESU-entitled, or not the post-EOS Win10 case).
# Keyed off the OS build + entitlement, NOT a live-clock comparison, so it is deterministic. $avail rows
# carry content_class/title from Get-Available; used only to name the phantom OOB if one is offered.
function Get-ServicingNotice($avail, $esu) {
  if ("$OsBuild" -ne '19045') { return $null }   # only Windows 10 22H2 is post-end-of-support in this fleet
  if ($esu -eq 'entitled')    { return $null }   # entitled -> the catalog CU installs; nothing to report
  $exprCU = @($avail | Where-Object { $_.content_class -eq 'express' -and "$($_.title)" -match 'Cumulative Update' })
  $offer = if ($exprCU.Count -gt 0) {
    ' Windows Update currently offers only the ESU-enrollment out-of-band (' +
    (($exprCU | ForEach-Object { $_.kb }) -join ',') + '), which carries no new security content.'
  } else { '' }
  return ('Windows 10 22H2 (build 19045) reached end-of-support on 2025-10-14 and this guest is NOT ' +
    'enrolled in Extended Security Updates (ESU=' + $esu + '). Post-end-of-support security updates ' +
    'therefore cannot be INSTALLED: the current monthly security cumulative update IS published in the ' +
    'Microsoft Update Catalog and the updater can fetch it through the proxy, but Windows (CBS) refuses ' +
    'to apply it without ESU entitlement.' + $offer + ' To resume security servicing, enroll this guest ' +
    'in ESU with a volume Multiple Activation Key (MAK, offline-activatable). INFORMATIONAL, not an error.')
}

# Defender SIGNATURE updates: resolve the current full package URL.
#
# Measured 2026-08-21, correcting a claim recorded here earlier: the FULL signature package is NOT
# Delivery-Optimization-only. It is an ordinary HTTPS GET of ~203 MB:
#     https://go.microsoft.com/fwlink/?linkid=121721&arch=x64
#       -> 302 -> https://definitionupdates.microsoft.com/packages/content/mpam-fe.exe
#                   ?packageType=Signatures&packageVersion=...&arch=amd64&engineVersion=...
# The version parameters are MANDATORY - the bare URL 404s - so the redirect has to be followed
# rather than a URL constructed. HTTPS only (plain http answers 503), so it rides the relay's
# CONNECT tunnel. Both hosts are in the relay allowlist for exactly this.
#
# Returns the resolved URL, or $null if it could not be resolved - in which case the caller keeps
# the old INFORMATIONAL behaviour rather than inventing a URL.
function Get-DefenderFullPackageUrl {
  # The fwlink is a CHAIN, not one hop. Measured 2026-08-21:
  #   go.microsoft.com/fwlink/?linkid=121721  -302->  definitionupdates.microsoft.com/packages?arch=x64
  #                                           -302->  .../packages/content/mpam-fe.exe?packageType=...
  # Only the LAST url names the file. Stopping at the first hop would hand Install-SelfContained a
  # URL with no .exe in it, which it correctly refuses as an unrecognised artifact - so follow the
  # chain until the target names a file, and cap the hops so a redirect loop cannot spin.
  $url = 'https://go.microsoft.com/fwlink/?linkid=121721&arch=x64'
  for ($hop = 0; $hop -lt 5; $hop++) {
    $next = Get-RedirectTarget $url
    if (-not $next) { break }
    # A Location header may be RELATIVE, and the second hop of this chain is: it answers
    # "/packages/content/mpam-fe.exe?packageType=..." with no scheme or host. Handing that to
    # Fetch-Msu produced 14 identical failures reading
    #   "Invalid URI: The format of the URI could not be determined."
    # Resolve every hop against the URL it came from, which is a no-op for absolute targets.
    try { $url = ([Uri]::new([Uri]$url, $next)).AbsoluteUri }
    catch { Log "Defender: unusable redirect target '$next' from $url" 'WARN'; return $null }
    if ($url -match '/[^/?]+\.(exe|msu|cab)(\?|$)') { return $url }
  }
  if ($url -match '/[^/?]+\.(exe|msu|cab)(\?|$)') { return $url }
  Log "Defender: the fwlink chain did not end at a downloadable file (last: $url)" 'WARN'
  return $null
}

# One redirect hop: return the Location of $Url, or $null when it is not a redirect.
function Get-RedirectTarget($Url) {
  foreach ($try in 1..2) {
    $resp = $null
    try {
      # HttpWebRequest with AllowAutoRedirect=$false, NOT Invoke-WebRequest -MaximumRedirection 0.
      # Measured: the Invoke-WebRequest form throws
      #   InvalidOperationException: Operation is not valid due to the current state of the object
      # in Windows PowerShell 5.1 when the reply IS a redirect, and exposes no response object to
      # read Location from - the request never even reaches the relay (its log stayed empty). This
      # is also the class Fetch-Msu already uses, so the whole updater speaks HTTP one way.
      $req = [System.Net.HttpWebRequest]::Create($Url)
      $req.Proxy = New-Object System.Net.WebProxy($Proxy)
      $req.AllowAutoRedirect = $false
      $req.Timeout = 60000
      $req.ReadWriteTimeout = 60000
      $resp = $req.GetResponse()
      $code = [int]$resp.StatusCode
      $loc  = $resp.GetResponseHeader('Location')
      $resp.Close(); $resp = $null
      if ($loc) { return $loc }
      if ($code -ge 300 -and $code -lt 400) { Log "Defender: $code with no Location header for $Url" 'WARN' }
      return $null
    } catch [System.Net.WebException] {
      # A 3xx with AllowAutoRedirect=$false is NOT an exception, but a 4xx/5xx is - and its response
      # still carries the headers, so try to read Location even here before giving up.
      $wr = $null; try { $wr = $_.Exception.Response } catch {}
      if ($wr) {
        $loc = $null; try { $loc = $wr.GetResponseHeader('Location') } catch {}
        try { $wr.Close() } catch {}
        if ($loc) { return $loc }
      }
      if ($try -eq 2) { Log "Defender: redirect hop failed for $Url ($($_.Exception.Message))" 'WARN' }
      else { Start-Sleep -Seconds 3 }
    } catch {
      if ($try -eq 2) { Log "Defender: redirect hop error for $Url ($($_.Exception.Message))" 'WARN' }
      else { Start-Sleep -Seconds 3 }
    } finally {
      if ($resp) { try { $resp.Close() } catch {} }
    }
  }
  return $null
}

# Install a KB that Windows Update offers as a self-contained STATIC file (Defender defs and MSRT ship
# as .exe; some updates as .msu), fetched through the proxy and installed with NO Delivery Optimization
# / BITS / NLA. This is the routeless-clean replacement for handing these KBs to the DO-gated
# Install-ViaWU, the class that actually failed every pass on a netvm-free guest. Proven mechanism:
# scan carries the static URL (dc-probe.ps1), Fetch-Msu pulls it through 127.0.0.1:8082 (harvest-proof.ps1).
function Install-SelfContained($kb,$urls){
  $dir = Join-Path $WorkDir ("wu-direct\" + $kb)
  New-Item -ItemType Directory -Force $dir | Out-Null
  $rows=@()
  foreach($url in @($urls)){
    $name = if($url -match '/([^/?]+\.(?:msu|exe|cab))(\?|$)'){ $Matches[1] } else { "$kb.bin" }
    $dst = Join-Path $dir $name
    if(-not (Fetch-Msu $url $dst $kb)){ $rows += [ordered]@{ kb=$kb; file=$name; rc='fetch-failed'; ok=$false }; continue }
    $ext = [IO.Path]::GetExtension($name).ToLower()
    if($ext -eq '.exe'){
      # Verify BY EFFECT, not by exit code: Defender mpam-fe advances AntivirusSignatureVersion; MSRT
      # advances HKLM\...\RemovalTools\MRT\Version. rc=0 alone has read as success on a no-op before.
      #
      # GUARD:effectprobe - and it read as success on a no-op AGAIN, measured 2026-09-20 on the
      # German 25H2 template. securityhealthsetup.exe (the "Windows Security platform" offer,
      # KB5007651, offered as 10.0.29628.1000) ran with rc=0 on EVERY pass while
      # SecurityHealthService.exe stayed at the inbox 10.0.26100.9278 - nothing moved. There was no
      # probe for that executable, so $eff was structurally false for it and `rc -eq 0` alone
      # decided ok=$true. dom0 was therefore told "offered, still pending" forever instead of
      # "this update is FAILING", which is the same untruth as the field report in a new place.
      # Now: if we KNOW how to measure an executable's effect, rc=0 without that effect is NOT
      # success. Where we have no probe, say so in the row rather than implying verification.
      $probe = $null
      if    ($name -match 'securityhealthsetup') { $probe = 'security-platform' }
      elseif($name -match 'kb890830|mrt')        { $probe = 'mrt-version' }
      elseif($name -match 'mpam|mpas|nis_full')  { $probe = 'defender-signature' }
      $sigBefore=''; $mrtBefore=''; $shBefore=''
      try{ $sigBefore=(Get-MpComputerStatus).AntivirusSignatureVersion }catch{}
      try{ $mrtBefore=(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\RemovalTools\MRT' -Name Version -EA SilentlyContinue).Version }catch{}
      # The file calls itself "Windows Security app UNDOCKED setup": what it updates is the
      # SecHealthUI APPX PACKAGE, not SecurityHealthService.exe in System32. Probing only the
      # System32 binary would report a false FAILURE for a correct install, so take both and
      # treat either moving as the effect. (Caught before shipping, 2026-09-20.)
      try{ $pkB=Get-AppxPackage -AllUsers -Name Microsoft.SecHealthUI -EA SilentlyContinue | Select-Object -First 1; if($pkB){ $shBefore=[string]$pkB.Version } }catch{}
      # ...and the PROVISIONED package, which is a THIRD artefact and the one that moves when the
      # payload is provisioned rather than installed into a user profile. Measured 2026-09-21:
      # provisioning takes the version from 1000.26100.8036.0 to 1000.29628.1000.0 while
      # Get-AppxPackage -AllUsers stays put, so a probe blind to this reports a correct install as
      # a failure - the same "probe the wrong artefact" trap, one artefact further on.
      try{ $prB=Get-AppxProvisionedPackage -Online -EA SilentlyContinue | Where-Object { $_.DisplayName -like '*SecHealthUI*' } | Select-Object -First 1; if($prB){ $shBefore="$shBefore|" + [string]$prB.Version } }catch{}
      try{ $itB=Get-Item 'C:\Windows\System32\SecurityHealthService.exe' -EA SilentlyContinue; if($itB){ $shBefore="$shBefore|" + $itB.VersionInfo.ProductVersion } }catch{}
      $p = Start-Process $dst -ArgumentList '/q' -Wait -PassThru -WindowStyle Hidden
      $eff=$false
      try{ if($sigBefore){ $eff = $eff -or ((Get-MpComputerStatus).AntivirusSignatureVersion -ne $sigBefore) } }catch{}
      try{ if($name -match 'kb890830'){ $eff = $eff -or ((Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\RemovalTools\MRT' -Name Version -EA SilentlyContinue).Version -ne $mrtBefore) } }catch{}
      $shAfter=''
      try{ $pkA=Get-AppxPackage -AllUsers -Name Microsoft.SecHealthUI -EA SilentlyContinue | Select-Object -First 1; if($pkA){ $shAfter=[string]$pkA.Version } }catch{}
      try{ $prA=Get-AppxProvisionedPackage -Online -EA SilentlyContinue | Where-Object { $_.DisplayName -like '*SecHealthUI*' } | Select-Object -First 1; if($prA){ $shAfter="$shAfter|" + [string]$prA.Version } }catch{}
      try{ $itA=Get-Item 'C:\Windows\System32\SecurityHealthService.exe' -EA SilentlyContinue; if($itA){ $shAfter="$shAfter|" + $itA.VersionInfo.ProductVersion } }catch{}
      # If neither artefact could be read at all, the probe did not RUN - that is unknown, not a
      # negative, and must not be reported as a failed install.
      $probeRan = $true
      if($probe -eq 'security-platform'){
        if(-not $shBefore -and -not $shAfter){ $probeRan = $false }
        else { $eff = $eff -or ($shAfter -ne $shBefore) }
      }
      # THE WRAPPER RAN AND CHANGED NOTHING. Before reporting an outstanding update, check whether
      # it is a CONTAINER we can service ourselves. Measured 2026-09-21 on the German 25H2
      # template: securityhealthsetup.exe exits 0 in under a second and does nothing, with no
      # extract switch that works (/x, /extract, /q /x all rc=0, nothing written), while the .appx
      # packages inside it provision cleanly in eleven seconds. That is this path's problem, not a
      # vendor bug: Windows Update normally installs this through its own engine, and we invoke the
      # wrapper standalone because the guest is routeless - the same reason .msu content is
      # resolved from the catalog here instead of through BITS/DO.
      #
      # Gated to the ONE probe whose effect we can measure. A fallback whose result cannot be
      # verified must not fire silently (fallbacks are anomalies: they are logged loudly).
      $alreadyCurrent = $false
      # DEFENDER SIGNATURES: the offer DOES state the version it carries, in its own title as
      # "(Version 1.459.317.0)", and Get-MpComputerStatus states the installed one. Comparing the
      # two turns "the probe cannot establish the offered version" - which was true, and which made
      # this item unjudgeable - into a plain answer. Digits only: the title's LANGUAGE is
      # nondeterministic here (the same KB comes back German, English or French) but a dotted quad
      # is a dotted quad, and this is an EFFECT comparison, never accept/reject, which still runs
      # on the filename. Jev rated this measurement decisive at 1.00 for this item.
      if($probe -eq 'defender-signature' -and -not $eff -and $p.ExitCode -eq 0){
        $offeredVer = $null
        try {
          $off = @($script:St.available | Where-Object { $_.kb -eq $kb } | Select-Object -First 1)
          if($off -and $off[0].title -match '(\d+\.\d+\.\d+\.\d+)'){ $offeredVer = $Matches[1] }
        } catch {}
        $sigNow = ''
        try { $sigNow = [string](Get-MpComputerStatus).AntivirusSignatureVersion } catch {}
        if($offeredVer -and $sigNow){
          try {
            if([version]$sigNow -ge [version]$offeredVer){
              $alreadyCurrent = $true
              Log ("    signature $sigNow is already at or past the offered $offeredVer - nothing to do")
            } else {
              Log ("    signature $sigNow is BEHIND the offered $offeredVer and nothing moved - this update did not install")
            }
          } catch { Log ("    could not compare signature versions ('$sigNow' vs '$offeredVer')") }
        }
      }
      if($probe -eq 'security-platform' -and $probeRan -and -not $eff -and $p.ExitCode -eq 0){
        $ax = Install-EmbeddedAppx -ExePath $dst -WorkRoot $WorkDir
        if($ax.attempted){
          Log ("  $name : wrapper exited 0 and changed nothing; carved $($ax.count) embedded package(s) -> $($ax.detail)")
          if($ax.ok){
            $shAfter=''
            try{ $pkA3=Get-AppxPackage -AllUsers -Name Microsoft.SecHealthUI -EA SilentlyContinue | Select-Object -First 1; if($pkA3){ $shAfter=[string]$pkA3.Version } }catch{}
            try{ $prA3=Get-AppxProvisionedPackage -Online -EA SilentlyContinue | Where-Object { $_.DisplayName -like '*SecHealthUI*' } | Select-Object -First 1; if($prA3){ $shAfter="$shAfter|" + [string]$prA3.Version } }catch{}
            # The re-probe must read the SAME artefacts IN THE SAME ORDER as $shBefore, or the
            # comparison below is apples-to-oranges and reports a change that did not happen.
            # Measured 2026-09-21: $shBefore was installed|provisioned|service (three fields) while
            # this re-probe built only two, so `$shAfter -ne $shBefore` was ALWAYS true and the
            # fallback would have certified itself even when nothing moved. It happened to be right
            # on the run that exposed it, which is exactly how an unsound check survives.
            try{ $itA3=Get-Item 'C:\Windows\System32\SecurityHealthService.exe' -EA SilentlyContinue; if($itA3){ $shAfter="$shAfter|" + $itA3.VersionInfo.ProductVersion } }catch{}
            # The EFFECT is still the only thing that counts - a successful call is not a result.
            if($shAfter -ne $shBefore){ $eff=$true; Log ("    security platform moved $shBefore -> $shAfter (SecHealthUI|provisioned)") }
            else {
              # NOTHING MOVED - which is success or failure depending on a fact we can check: the
              # version the PAYLOAD carries, read from its own manifest. If the image is already at
              # it there was genuinely nothing to do, which is exactly what a SECOND pass sees once
              # this fallback has provisioned it while Windows Update keeps offering the same
              # revision. Measured 2026-09-21: without this, a pass that had succeeded an hour
              # earlier reported the very same item as a failed install.
              if($ax.mainVersion -and $prA3 -and ([string]$prA3.Version) -eq [string]$ax.mainVersion){
                $alreadyCurrent = $true
                Log ("    nothing moved, and the image is ALREADY at the version this offer carries ($($ax.mainVersion))")
              } else {
                Log ("    provisioning reported success but NOTHING MOVED, and the image is not at the offered version")
              }
            }
          }
        }
      }
      # A probe we ran and that showed nothing is a NEGATIVE result, not a missing one.
      # ---- WU-EXE-EFFECT-BEGIN
      if($probe -and $probeRan){ $ok = $eff } else { $ok = ($p.ExitCode -eq 0) }
      $detail = if($probe -and $probeRan){ "probe=$probe verified_by_effect=$eff" }
                elseif($probe){ "probe=$probe DID NOT RUN (artefact unreadable) - ok from rc only" }
                else { 'probe=none (ok from rc only)' }
      # GUARD:notactionable - what the probe tells us apart.
      #   rc=0 AND the probe ran AND nothing changed -> the installer SELF-DETERMINED it has
      #     nothing to do on this image. Measured 2026-09-20: securityhealthsetup.exe, 22 MB,
      #     exits 0 in ONE SECOND, writes no log anywhere, and moves neither the SecHealthUI appx
      #     nor SecurityHealthService.exe - on four consecutive passes. Windows Update re-offers it
      #     regardless. That is an offer this guest can NEVER action, exactly the shape the
      #     express/ESU phantoms already carry, so it is INFORMATIONAL: still reported and still
      #     visible with its reason, but it must not hold dom0 at "updates available" forever.
      #   rc<>0 AND the probe ran AND nothing changed -> a real failure. Stays actionable.
      # Without the probe these two are indistinguishable, which is how one of them sat unnoticed.
      $sev=$null; $why=$null
      if($probe -and $probeRan -and -not $eff){
        if($p.ExitCode -eq 0){
          # CORRECTED 2026-09-20, SAME DAY, ON EVIDENCE. This branch used to set severity=info,
          # ok=$true, reason "nothing to do on this image" - i.e. it read its own NEGATIVE probe as
          # proof the image was already current. That inference is not supported, and for the item
          # it was written for it is FALSE. Measured: the offered securityhealthsetup.exe was
          # fetched and unpacked off-guest; it is an APPX payload declaring Microsoft.SecHealthUI
          # 1000.29628.1000.0, while this guest carries 1000.26100.8036.0 in BOTH the installed and
          # the PROVISIONED package (read directly, so "the probe watches the wrong artefact" is
          # refuted), and the payload's TargetDeviceFamily MinVersion 10.0.22000.1 is far below this
          # build, so inapplicability is refuted too. The installer carries something NEWER,
          # applicable, and lands nothing. Jev: concealed-failure 0.87.
          #
          # "rc=0 and nothing moved" is therefore a FAILED INSTALL, and it stays ACTIONABLE. The
          # temptation to keep it informational is that an item which can never install holds dom0
          # at "updates available" forever - but dom0's job is to report the TRUTH (ADR section 2),
          # and the truth is that this update is outstanding. Making dom0 look settled by calling a
          # failure benign is the field report's untruth wearing a different hat.
          # NARROWED 2026-09-21, and this matters in BOTH directions. The rule above is right only
          # where we can establish what the offer CARRIES. Where we can (the appx payload declares
          # its version), "not at it and nothing moved" is a failure and "already at it" is simply
          # done. Where we cannot - a Defender signature, say - asserting a failure turned an
          # already-current item into a permanent "updates available", which is the very defect
          # this file exists to prevent, re-introduced by me from the other side. So: assert
          # neither, report it, and keep it out of dom0's count.
          if($alreadyCurrent){
            $ok=$true
            $why='the image is already at the version this offer carries - nothing to do'
            Log ("  $name : exe rc=0 $detail -> ALREADY CURRENT ($why)")
          } elseif($probe -eq 'security-platform'){
            $ok=$false
            $why='installer exited 0 but the probe measured no change - this update did NOT install'
            Log ("  $name : exe rc=0 $detail -> FAILED ($why)")
          } else {
            $sev='info'; $ok=$true
            $why='installer exited 0 and changed nothing, and this probe cannot establish the version the offer carries - reported as informational rather than asserting an install or a failure'
            Log ("  $name : exe rc=0 $detail -> NOT ACTIONABLE ($why)")
          }
          if($probe -eq 'security-platform'){ Log ("    security platform stayed at $shBefore (SecHealthUI|SecurityHealthService)") }
        } else {
          Log ("  $name : exe rc=$($p.ExitCode) $detail -> FAILED (nonzero rc and the probe saw no effect)")
        }
      } else {
        Log ("  $name : exe rc=$($p.ExitCode) $detail")
      }
      # ---- WU-EXE-EFFECT-END
      $rows += [ordered]@{ kb=$kb; file=$name; rc=$p.ExitCode; ok=$ok; verified_by_effect=$eff; probe=$probe; severity=$sev; info_reason=$why }
    } elseif($ext -eq '.msu' -or $ext -eq '.cab'){
      # DISM decides. Three DETERMINISTIC outcomes, each classified honestly:
      #  - OK_RC (0/3010/2359302): installed/staged.
      #  - NOT-A-PACKAGE (rc 2 ERROR_FILE_NOT_FOUND, 13 ERROR_INVALID_DATA, 0x800f0805 CBS_E_INVALID_PACKAGE):
      #    the artifact is not a DISM-installable CBS package - a WU-CLIENT blob with no update.mum
      #    (measured: KB5001716's cab, and the .NET ndp481 PAYLOAD cab). Windows installs these itself;
      #    they are NOT applicable to offline servicing, so this is INFORMATIONAL, not a failure.
      #  - anything else: a genuine install failure.
      $rc = Add-PackageCompat $dst
      Log ("  $name : DISM rc=$rc")
      # ---- WU-NOTPACKAGE-BEGIN
      # GUARD:mumcheck - PROVE it is not a package; do not infer it from the return code.
      # Those three codes are NOT exclusive to WU-client blobs: a TRUNCATED OR CORRUPT DOWNLOAD
      # produces ERROR_INVALID_DATA / CBS_E_INVALID_PACKAGE too, and relay truncation on large
      # files is a known failure mode on this very path. Inferring "informational" from the code
      # alone therefore let a corrupt cumulative be filed as "nothing to worry about" and dom0 was
      # told all was well - the field defect exactly, reached from a different direction.
      # The real discriminator is the one the comment above always named: a servicing package
      # CONTAINS update.mum. Look, do not assume. If the artifact HAS update.mum it IS a package,
      # so one of these codes means something went wrong with THIS copy of it - a failure, and a
      # retryable one - never informational. If expand cannot read the file at all, that is itself
      # evidence of corruption, so it fails too.
      $notPackage = ($rc -eq 2 -or $rc -eq 13 -or $rc -eq -2146498555)   # -2146498555 = 0x800f0805
      $mum = $null
      if ($notPackage) {
        try {
          $lst = & expand.exe -D "$dst" 2>&1 | Out-String
          # EMPTY output is not "no update.mum" - it is "we could not read the artifact", which is
          # evidence of corruption and must fail. Caught by the suite: '' -match ... is $false, not
          # $null, so an unreadable file was falling through to INFORMATIONAL - the very case this
          # guard exists to stop.
          if ([string]::IsNullOrWhiteSpace($lst)) { $mum = $null }
          else { $mum = [bool]($lst -match '(?i)update\.mum') }
        } catch { $mum = $null }
        if ($mum -eq $true) {
          Log ("  $name : DISM rc=$rc BUT the artifact CONTAINS update.mum - it IS a servicing package, so this is a FAILURE (corrupt or truncated download), not informational")
          $notPackage = $false
        } elseif ($mum -eq $null) {
          Log ("  $name : DISM rc=$rc and expand could not read the artifact - treating as a FAILURE (unreadable is evidence of corruption, not of being a non-package)")
          $notPackage = $false
        }
      }
      # ---- WU-NOTPACKAGE-END
      if ($rc -in $OK_RC) {
        $rows += [ordered]@{ kb=$kb; file=$name; rc=$rc; ok=$true }
        if($rc -eq 3010){ $script:St.reboot_needed=$true; $script:StagedThisSession=$true }
      } elseif ($notPackage) {
        $rows += [ordered]@{ kb=$kb; file=$name; rc=$rc; ok=$false; severity='info'; mum_present=$false
          reason='not a DISM-installable CBS package - VERIFIED to contain no update.mum, i.e. a Windows Update client/orchestrator blob that Windows installs itself; not applicable to offline servicing. INFORMATIONAL - not a failure' }
      } else {
        $rows += [ordered]@{ kb=$kb; file=$name; rc=$rc; ok=$false }
      }
    } else {
      Log ("  $name : unrecognised self-contained artifact type - failing loudly")
      $rows += [ordered]@{ kb=$kb; file=$name; rc='unknown-artifact'; ok=$false }
    }
  }
  return ,$rows
}

function Install-Msus($files){
  $reboot=$false; $rows=@()
  foreach($f in (Order-Msus $files)){
    $name = [IO.Path]::GetFileName($f)
    $pi = Get-MsuInfo $f
    Log "  $name applicable=$($pi.applicable) state=$($pi.state) id=$($pi.identity)"
    if($pi.applicable -eq 'No'){
      # SKIPPED, not failed: this package was never meant for this image. Recording it as a
      # failure is what made a whole KB look broken when only a catalog sibling was irrelevant.
      $rows += [ordered]@{ file=$name; rc='skipped'; why="not applicable to this image" }
      continue
    }
    if($pi.state -eq 'Installed'){
      $rows += [ordered]@{ file=$name; rc='skipped'; why="already installed" }
      continue
    }
    # ONE REBOOT-REQUIRING PACKAGE PER SERVICING SESSION.
    #
    # Measured 2026-08-14 on a pristine 26100.8875 clone: the pass staged KB5120710 (rc=3010) and
    # then KB5121003 (rc=3010) without a reboot in between. After the reboot KB5120710 was
    # state=112 Installed and KB5121003 had ZERO CBS package entries - never registered, no
    # rollback logged, shutdown 77 s instead of the 6.3 min a real apply takes. CBS applied the
    # first staged package and silently discarded the second, while DISM returned 3010 for both.
    # The 11:47 success is the control: it installed the cumulative ALONE on an image where the
    # .NET update was already installed AND rebooted.
    #
    # So once something is staged, stop. The remaining packages stay on disk and the next pass -
    # after the reboot this one forces - picks them up. Slower, and the only way the second package
    # actually lands.
    if ($script:StagedThisSession -and -not $env:QUBES_UPDATES_ALLOW_MULTISTAGE) {
      $rows += [ordered]@{ file=$name; rc='deferred'
                           why='another package is already staged; installing it needs a reboot first' }
      Log "  DEFER $name - a reboot-requiring package is already staged this session"
      continue
    }
    $script:St.installing=[ordered]@{ file=$name; state='running' }; Save
    $rc = Add-PackageCompat $f
    if($rc -eq 3010){ $reboot=$true; $script:StagedThisSession = $true }
    # Re-ask DISM what the package's state is NOW. rc=3010 only means "staged"; the state tells us
    # whether CBS actually took it, which is the thing that was silently false before.
    $after = Get-MsuInfo $f
    $rows += [ordered]@{ file=$name; rc=$rc; state_after=$after.state }
    Log "  DISM $name rc=$rc state_after=$($after.state)"
  }
  # STICKY, never assigned: Install-Msus runs once per KB, so assigning would let a later KB
  # that needs no reboot erase an earlier one that does. Measured 2026-08-13 on the template:
  # KB5120710 returned 3010 (reboot required), KB5121003 then returned 0, and the pass ended
  # claiming reboot_needed=false while Windows had CBS RebootPending set.
  if ($reboot) { $script:St.reboot_needed = $true }

  # SETTLE BEFORE DECLARING ANYTHING. DISM returning 3010 does NOT mean CBS has finished
  # registering the package: TiWorker keeps working after the exit code. Measured 2026-08-14 - the
  # pass reported done, the qube shut down 22 s later, the shutdown took 77 s where a real apply
  # takes 6.3 min, and the cumulative ended with ZERO CBS entries. A staged package that has not
  # reached "reboot pending" is not staged yet, and rebooting there loses it.
  #
  # NOTE this is also the test that decides WHY it was lost. Windows aggregates many packages per
  # reboot routinely, so "CBS only applies one staged package" is a weak claim on one observation.
  # If RebootPending appears here and the package is still discarded at boot, the aggregation story
  # is real; if RebootPending never appears, the loss was this race and serialising was treating a
  # symptom.
  if ($reboot) {
    $cbsRel = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing'
    $rp = "HKLM:\$cbsRel\RebootPending"
    $deadline = (Get-Date).AddMinutes(10)
    # PUSH, not poll (audit 2026-09-08): this used to Test-Path every 5 s, adding up to 5 s of dead
    # time to every dom0-driven pass. RebootPending is a SUBKEY of the CBS key, so a
    # REG_NOTIFY_CHANGE_NAME notification on the parent wakes us the instant CBS creates it. The
    # notification only says "a subkey under CBS changed", so re-Test and re-arm until the key is
    # there or the 10 min are up. Arm BEFORE testing so a key created between the two is not missed.
    $seen = [bool](Test-Path $rp)
    if (-not $seen) {
      try {
        if (-not ('CbsRegNotify' -as [type])) {
          Add-Type @'
using System; using System.Runtime.InteropServices;
public static class CbsRegNotify {
    [DllImport("advapi32.dll")]
    public static extern int RegNotifyChangeKeyValue(IntPtr hKey, bool bWatchSubtree, uint dwNotifyFilter, IntPtr hEvent, bool fAsynchronous);
}
'@
        }
        $cbsKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($cbsRel,
                    [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadSubTree,
                    ([System.Security.AccessControl.RegistryRights]::Notify -bor [System.Security.AccessControl.RegistryRights]::ReadKey))
        if (-not $cbsKey) { throw 'CBS key not openable' }
        $ev = New-Object System.Threading.ManualResetEvent($false)
        try {
          while (-not $seen -and (Get-Date) -lt $deadline) {
            [void]$ev.Reset()
            # 0x1 = REG_NOTIFY_CHANGE_NAME (subkey add/delete); 0x10000000 = REG_NOTIFY_THREAD_AGNOSTIC
            # so the registration is not tied to the calling thread's lifetime.
            $nrc = [CbsRegNotify]::RegNotifyChangeKeyValue($cbsKey.Handle.DangerousGetHandle(), $false, 0x10000001,
                                                            $ev.SafeWaitHandle.DangerousGetHandle(), $true)
            if ($nrc -ne 0) { throw "RegNotifyChangeKeyValue rc=$nrc" }
            if (Test-Path $rp) { $seen = $true; break }
            $ms = [int][Math]::Max(0, ($deadline - (Get-Date)).TotalMilliseconds)
            [void]$ev.WaitOne($ms)
            if (Test-Path $rp) { $seen = $true }
          }
        } finally { $ev.Dispose(); $cbsKey.Dispose() }
      } catch {
        # A working registry notification is the instrument here; losing it is an anomaly, not a
        # mode. Say so, then keep the bounded poll so the settle verdict is still reached.
        Log "  WARNING: RebootPending registry notification unavailable ($($_.Exception.Message)) - polling every 5 s instead"
        while (-not $seen -and (Get-Date) -lt $deadline) {
          if (Test-Path $rp) { $seen = $true; break }
          Start-Sleep -Seconds 5
        }
      }
    }
    $ti = @(Get-Process TiWorker, TrustedInstaller -EA SilentlyContinue).Count
    Log ("  settle: CBS RebootPending={0} after staging, servicing processes still up={1}" -f $seen, $ti)
    $script:St.reboot_pending_confirmed = $seen
    if (-not $seen) {
      Log '  WARNING: staged but CBS never reported RebootPending - a reboot now would lose it'
    }
    # Let TiWorker finish its post-DISM work; rebooting mid-registration is what loses a package.
    # Wait ON the process, not for it (audit 2026-09-08): the 10 s Get-Process poll re-listed every
    # process for as long as TiWorker ran (minutes) and overshot its exit by up to 10 s. WaitForExit
    # returns the moment it is gone. The loop re-lists only when an instance actually exited, so a
    # TiWorker that TrustedInstaller respawns is still waited for, as the poll did.
    $q = (Get-Date).AddMinutes(10)
    while ((Get-Date) -lt $q) {
      $tiw = @(Get-Process TiWorker -EA SilentlyContinue)
      if ($tiw.Count -eq 0) { break }
      $ms = [int][Math]::Max(1, ($q - (Get-Date)).TotalMilliseconds)
      try { [void]$tiw[0].WaitForExit($ms) }
      catch {
        # Cannot open the process for SYNCHRONIZE - an anomaly on the SYSTEM task this runs as.
        Log "  WARNING: WaitForExit on TiWorker failed ($($_.Exception.Message)) - polling every 10 s instead"
        Start-Sleep -Seconds 10
      }
    }
    Log ("  settle: TiWorker idle={0}" -f (@(Get-Process TiWorker -EA SilentlyContinue).Count -eq 0))
  }
  return $rows
}

# AUTOLOGON PROTECTION AT EVERY PASS END (measured 2026-08-19: three HARNESS-driven reboots
# around staged servicing consumed DefaultPassword and left win10-clean at the sign-in screen
# - unreachable for qrexec, needing a manual login. ensure-autologon.ps1 was wired only to
# the vmupdate/dom0-driven REBOOT path, so any other rebooter - a harness, a human, CBS
# itself - bypassed it). Running the prevention whenever THIS pass staged reboot-requiring
# work removes the dependency on who reboots afterwards. Prevention only: if the password is
# already consumed there is nothing this can restore (see ensure-autologon.ps1's header).
# ---- WU-AUTOLOGON-GUARD-BEGIN   (tools/tests/wu-autologon-guard-test.ps1 extracts this function by these markers)
function Protect-Autologon {
  # Fire whenever a reboot is pending OR a package was staged this session (a stage can precede the
  # reboot_needed flag, and a throw between the two must not skip re-arming autologon).
  if (-not ($script:St.reboot_needed -or $script:StagedThisSession)) { return }
  # The guard is read from where install-updater-agent.ps1 deploys it - <Qubes Tools>\qubes-rpc-services,
  # the location wu-update.ps1 reads too - derived the same way (QUBES_TOOLS, else the default root).
  # Until 2026-09-17 this read a `vmupdate-shim\` directory the installer never creates, so on the
  # task-driven path (QubesWindowsUpdateRun, the boot and 6-hourly scans) the guard was skipped on
  # EVERY reboot-pending pass while logging that the helper was "not deployed" - measured on
  # win11de-gwt: the file existed at qubes-rpc-services (10040 B), the WARN appeared on all four
  # reboot-pending passes. Autologon survived those reboots by luck, not by this guard.
  $qt = $env:QUBES_TOOLS; if (-not $qt) { $qt = 'C:\Program Files\Qubes Tools' }
  $ea = Join-Path $qt 'qubes-rpc-services\ensure-autologon.ps1'   # GUARD:alpath
  if (-not (Test-Path $ea)) { Log "reboot staged but ensure-autologon.ps1 is missing at $ea - autologon may be consumed by the coming reboots" 'WARN'; return }
  try {
    & powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $ea 2>&1 |
      ForEach-Object { Log "  autologon: $_" }
  } catch { Log "ensure-autologon failed: $($_.Exception.Message)" 'WARN' }
}
# ---- WU-AUTOLOGON-GUARD-END

# ---------------------------------------------------------------------- main
# VM-CLASS CLASSIFICATION, guest-side. The qubes.UpdatesProxy updater is a TEMPLATE-ONLY
# mechanism: dom0-driven updates for a VM that is otherwise offline. It must run ONLY on a
# TemplateVM. A StandaloneVM - networked OR offline - updates ITSELF via normal Windows Update and
# must NEVER raise the proxy ("offline" does not make a standalone a template). An AppVM/DispVM has
# a volatile root and must do nothing (updates are its template's business).
#
# The class is read LIVE from qubesdb, exactly as the Linux agent does. The earlier "vm-type is
# unreadable in a Windows guest" claim was a BUG in the PowerShell glue, NOT a real limit: the C
# agent reads qubesdb fine, qubesdb-client.dll is in SYSTEM32, and the P/Invoke merely needed the
# correct Cdecl/Ansi marshaling (measured 2026-08-19). Keys are written by core-admin:
#   /type                 - the exact Python class name (StandaloneVM/TemplateVM/AppVM/DispVM).
#                           The ONLY key that separates StandaloneVM from AppVM; /qubes-vm-type
#                           collapses both to 'AppVM'.
#   /qubes-vm-type        - TemplateVM | AppVM | NetVM | ProxyVM (fallback template test).
#   /qubes-vm-updateable  - True (Template/Standalone) | False (AppVM/DispVM) (fallback splitter).
# No deploy-time stamp is needed and this works on ANY template however it was built. The old
# VmClass/RootIdentity stamp fallback is RETIRED - the read is proven reliable, so if we cannot
# classify we refuse to proxy (skipped-unknown) rather than trust a stale stamp. NOTE:
# /qubes-service/yum-proxy-setup carries dom0's updates-proxy-setup feature if
# an operator ever wants to opt a specific standalone in; we deliberately do not honour it here
# (the requirement is template-ONLY).
function Get-QubesDbValue([string]$path) {
  try {
    if (-not ('QubesDb' -as [type])) {
      Add-Type @'
using System; using System.Runtime.InteropServices;
public static class QubesDb {
    [DllImport("qubesdb-client.dll", CallingConvention=CallingConvention.Cdecl)]
    public static extern IntPtr qdb_open(IntPtr vmname);
    [DllImport("qubesdb-client.dll", CallingConvention=CallingConvention.Cdecl, CharSet=CharSet.Ansi)]
    public static extern IntPtr qdb_read(IntPtr h, string path, out uint value_len);
    [DllImport("qubesdb-client.dll", CallingConvention=CallingConvention.Cdecl)]
    public static extern void qdb_close(IntPtr h);
}
'@
    }
    $h = [QubesDb]::qdb_open([IntPtr]::Zero)
    if ($h -eq [IntPtr]::Zero) { return $null }
    try {
      $len = [uint32]0
      $p = [QubesDb]::qdb_read($h, $path, [ref]$len)
      if ($p -eq [IntPtr]::Zero) { return $null }
      # value is heap-allocated by qubesdb-client; a few bytes leak per read (no qdb_free
      # exported and calling the CRT free from PS is unsafe) - fine for a short-lived pass.
      return [Runtime.InteropServices.Marshal]::PtrToStringAnsi($p, [int]$len)
    } finally { [QubesDb]::qdb_close($h) }
  } catch { return $null }
}
function Get-QubesVmClass {
  # WAIT for the qubesdb daemon to finish starting. This is a service-startup ORDERING race, not a random
  # flake: qdb_open connects to the qubesdb-daemon service (which, at boot, syncs the database from dom0
  # over vchan). A boot-triggered pass can run before that daemon is serving its pipe, so qdb_open returns
  # NULL *deterministically* in that window and BOTH /type and /qubes-vm-type read empty. Measured
  # 2026-08-20: in steady state the read is rock solid (25/25 returned the class); only the early-boot run
  # read empty. The old code concluded "not a TemplateVM (VmClass='')" on that first empty read and SKIPPED
  # the whole pass on a real template (doing nothing for a full boot). Retry ONLY while qubesdb is
  # unreachable (both keys empty) so we wait out the daemon's startup; a populated value returns
  # immediately, so a steady-state read costs nothing.
  for ($try = 1; $try -le 8; $try++) {
    $t = Get-QubesDbValue '/type'
    if ($t) { return $t }                            # exact class name - best signal
    $vt = Get-QubesDbValue '/qubes-vm-type'
    if ($vt) {
      if ($vt -eq 'TemplateVM') { return 'TemplateVM' }
      if ((Get-QubesDbValue '/qubes-vm-updateable') -eq 'True') { return 'StandaloneVM' }
      return 'AppVM'
    }
    if ($try -lt 8) { Start-Sleep -Seconds 2 }       # qubesdb not reachable yet - wait out the boot race
  }
  return $null                                       # still unreadable after ~14s -> caller uses fallback
}
function Test-DirectInternet {
  foreach ($u in 'http://www.msftconnecttest.com/connecttest.txt','http://www.msn.com/') {
    try {
      $req = [System.Net.HttpWebRequest]::Create($u)
      $req.Proxy = $null                 # explicitly DIRECT - ignore any system/WinHTTP proxy
      $req.Timeout = 8000
      $resp = $req.GetResponse()
      $ok = ([int]$resp.StatusCode -lt 400)
      $resp.Close()
      if ($ok) { return $true }
    } catch { }
  }
  return $false
}
$vmClassLive = Get-QubesVmClass
if (-not $vmClassLive) {
  # qubesdb is the authority and is reliably readable (qubesdb-client.dll is in SYSTEM32). If we
  # genuinely cannot classify, REFUSE to proxy rather than guess - never proxy a VM we cannot
  # confirm is a template. This is an anomaly to investigate, NOT a case to paper over with a
  # deploy-time stamp (the old VmClass/RootIdentity stamp fallback is retired: the read is proven).
  Log 'CANNOT classify VM from qubesdb - refusing to proxy; nothing done. Investigate qubesdb.' 'WARN'
  $script:St.phase='skipped-unknown'; Save
  exit 0
}
Log "VM class (live from qubesdb): $vmClassLive"
if ($vmClassLive -eq 'TemplateVM') {
  # the proxy updater's home - fall through to Ensure-Proxy below
} elseif ($vmClassLive -eq 'StandaloneVM') {
  if (Test-DirectInternet) {
    Log 'StandaloneVM with direct internet - it updates ITSELF via Windows Update. The qubes proxy updater is template-only: disabled. Undoing NoAutoUpdate=1.'
    Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' -Name NoAutoUpdate -EA SilentlyContinue
  } else {
    Log 'StandaloneVM, offline - the qubes proxy updater is template-only and never runs here; this VM must update itself. Doing nothing.'
  }
  $script:St.phase='skipped-standalone'; Save
  exit 0
} else {
  Log "$vmClassLive - not a template; updates are the template's business. Exiting before any proxy activity."
  $script:St.phase='skipped-appvm'; Save
  exit 0
}
try {
  $script:St.phase='ensure-proxy'; Save; Ensure-Proxy
  $script:St.phase='sync-revocation'; Save; Sync-Revocation
  $script:St.phase='scan'; Save
  # A LOSSY PASS MUST NEVER BE REPORTED AS "NOTHING TO UPDATE".
  # Measured 2026-08-15: five consecutive scans reported 0 updates on a guest that had three.
  # Windows Update was reachable the whole time - what failed were small plain-HTTP metadata
  # fetches through the relay, which returned nothing at all. WU cannot describe an offer it
  # could not download, so it answers "no updates", and the guest then tells dom0 it is current.
  # That is the worst possible failure: silent, and it looks like success.
  # So: watch the relay's own log across the scan. If it gave up on any fetch (complete=False)
  # AND the scan found nothing, the result is UNKNOWN, not zero - retry once, then refuse to
  # report a number nobody can stand behind.
  # The relay writes its log under the SAME WorkDir it is started with (see Ensure-Proxy: --log
  # $WorkDir). This was hardcoded to the default path, so any run with a non-default -WorkDir read a
  # file that never grew, counted zero give-ups, and disarmed the guard silently.
  $relayLog = Join-Path $WorkDir 'qubes-updates-relay.log'
  # Number of fetches the relay gave up on since $fromOffset, or -1 for UNKNOWN.
  # UNKNOWN IS NOT ZERO. This used to answer 0 when the log was missing and 0 again when reading it
  # threw - a check that could not fail, and therefore was not a check. The caller now treats an
  # unknown answer as suspect instead of as a clean bill of health.
  function Get-RelayGiveUps([long]$fromOffset) {
    if (-not (Test-Path $relayLog)) { return -1 }
    try {
      $fs = [IO.File]::Open($relayLog, 'Open', 'Read', 'ReadWrite')
      try {
        if ($fromOffset -gt $fs.Length) { $fromOffset = 0 }
        [void]$fs.Seek($fromOffset, 'Begin')
        $sr = New-Object IO.StreamReader($fs)
        $text = $sr.ReadToEnd()
      } finally { $fs.Dispose() }
      # 'PLAIN REFUSED' is the unambiguous marker: the relay declined to hand over a short body.
      # A complete=False summary still counts, because a SPILLED (already-committed) response can
      # end short after the bytes are on the client's wire and cannot be refused retroactively.
      # Chunked replies no longer produce a spurious complete=False, so this no longer over-counts.
      return ([regex]::Matches($text, 'PLAIN REFUSED|complete=False')).Count
    } catch { return -1 }
  }
  $relayOffset = if (Test-Path $relayLog) { (Get-Item $relayLog).Length } else { 0 }

  $avail = Get-Available
  # TEST HOOK, same reasoning as the agent's SoloFaultInject: this guard only fires when a scan
  # finds nothing WHILE the transport was dropping fetches, and once Windows Update has cached
  # its metadata that state cannot be summoned on demand. QUBES_UPDATES_FAKE_EMPTY_SCAN=1 makes
  # the scan look empty so the guard can be SEEN to fire. Absent, this is dead code.
  if ($env:QUBES_UPDATES_FAKE_EMPTY_SCAN -eq '1') {
    Log 'QUBES_UPDATES_FAKE_EMPTY_SCAN=1 - pretending the scan found nothing' 'WARN'
    $avail = @()
  }
  $giveUps = Get-RelayGiveUps $relayOffset
  # A lost fetch makes the scan suspect whatever the COUNT is: a partial list is indistinguishable
  # from a complete one, so gating this on "found nothing" only caught the most obvious half.
  # An UNKNOWN answer (-1) is suspect too, but only when the scan also came back empty - an empty
  # scan with no evidence that the transport was working is exactly the dangerous case, while a
  # non-empty scan has already demonstrated it fetched something.
  $suspect = ($giveUps -gt 0) -or ($giveUps -lt 0 -and $avail.Count -eq 0)
  if ($suspect) {
    $gu = if ($giveUps -lt 0) { 'UNKNOWN (relay log unreadable)' } else { $giveUps }
    Log "scan is suspect - relay give-ups: $gu, found $($avail.Count) update(s) - rescanning" 'WARN'
    $relayOffset = if (Test-Path $relayLog) { (Get-Item $relayLog).Length } else { 0 }
    Start-Sleep -Seconds 5
    $avail = Get-Available
    $giveUps = Get-RelayGiveUps $relayOffset
    $suspect = ($giveUps -gt 0) -or ($giveUps -lt 0 -and $avail.Count -eq 0)
  }
  if ($suspect -and $avail.Count -eq 0) {
    $gu = if ($giveUps -lt 0) { 'an unknown number of' } else { "$giveUps" }
    $script:St.phase='scan-failed'; $script:St.error = "transport lost $gu fetch(es); update availability unknown"; Save
    Log "SCAN FAILED: the relay gave up on $gu fetch(es) and Windows Update found nothing. Not reporting 0 to dom0 - a scan that could not fetch its metadata is not the same as a guest with no updates." 'ERROR'
    exit 75
  }
  if ($suspect) {
    # Non-empty, but the transport dropped something: the list may be SHORT. Say so instead of
    # letting a partial result be read as authoritative. Not a failure - the updates that were
    # found are real and worth installing - but dom0 must not treat this count as complete.
    $script:St.scan_partial = $giveUps; Save
    Log "SCAN PARTIAL: found $($avail.Count) update(s) but the relay gave up on $giveUps fetch(es) - the list may be incomplete; treat the count as a lower bound, not the whole truth." 'WARN'
  }

  $script:St.available=$avail; $script:St.count=$avail.Count; Save
  # Post-end-of-support / ESU diagnosis: INFORMATIONAL, computed on every pass from the fresh scan so a
  # bare `scan` surfaces it too. Explains WHY the newest security cumulative is not installable here.
  if ("$OsBuild" -eq '19045') {
    $script:St.esu = Get-EsuStatus
    $script:St.notice = Get-ServicingNotice $avail $script:St.esu
  }
  # dom0's "updates available" marker should reflect ACTIONABLE updates. Under the ESU notice, the
  # express/ESU-gated offers are informational (in St.notice), not installable - do not count them, or
  # dom0 would show a permanent "updates available" for a phantom the guest can never apply.
  # ---- WU-SCAN-COUNT-BEGIN
  # GUARD:scanactioned - a SCAN must not re-inflate what an install pass already settled.
  # Measured 2026-09-20 on the German 25H2 guest: an install pass correctly drove dom0 to EMPTY,
  # and the very next boot scan reported 3 again - the no-route driver plus two offers Windows
  # Update re-presents forever. dom0 oscillated 0 -> 3 and the admin was told there was work when
  # there was none. GUARD:actioned and GUARD:infoalways only govern the post-install rescan; this
  # is the same rule for the scan path, using the DURABLE knowledge the last pass wrote down.
  # Conservative on purpose: only a KB the previous pass recorded as severity='info' (structurally
  # not actionable - no route, no package, nothing to do) is dropped here. An ok=$true row is NOT
  # dropped on a scan, because "installed last time" is not evidence that a fresh offer of the same
  # KB is already satisfied - that judgement belongs to a pass that actually tries.
  # Use the startup snapshot (GUARD:prevstatus). Re-reading the file HERE is too late: this run has
  # already Saved over it, so the read returns our own empty result and excludes nothing.
  $priorInfo = @()
  try {
    $prevStatus = $script:PrevStatus
    if ($prevStatus -and $prevStatus.result) {
      $priorInfo = @($prevStatus.result | Where-Object { $_.severity -eq 'info' } |
                     ForEach-Object { $_.kb; if($_.PSObject -and (Test-RowKey $_ 'title')){ $_.title } } |
                     Where-Object { $_ })
    }
    # DURABLE. A scan writes its own status with an EMPTY result, so knowledge taken only from
    # result rows survives exactly ONE scan - and scans run at every boot and on a timer, so the
    # steady state would re-inflate anyway. Carry the classification forward in its own field.
    if ($prevStatus -and (Test-RowKey $prevStatus 'not_actionable')) {
      $priorInfo = @(@($priorInfo) + @($prevStatus.not_actionable) | Where-Object { $_ } | Sort-Object -Unique)
    }
  } catch { $priorInfo = @() }
  $script:St.not_actionable = @($priorInfo)
  # GUARD:offeridentity, the consuming half. An offer whose OWN identity a previous pass recorded
  # as resolved is not a fresh offer, whatever its KB says. This is what lets a scan stop
  # re-raising dom0 for a package that was installed and proven installed thirty seconds earlier,
  # without touching the conservative rule above: a NEW revision carries a new identity and counts.
  $priorSat = @()
  try {
    if ($script:PrevStatus -and (Test-RowKey $script:PrevStatus 'satisfied')) {
      $priorSat = @($script:PrevStatus.satisfied | Where-Object { $_ })
    }
  } catch { $priorSat = @() }
  # DURABLE, for the same reason not_actionable is. A scan writes its OWN status, so knowledge
  # taken only from the previous file and not written back survives exactly ONE scan - and scans
  # run at every boot and on a timer, so the steady state re-inflates anyway. Measured on the
  # guest 2026-09-21: the pass wrote satisfied=[2 identities] and the scan that consumed it wrote
  # satisfied=[] straight back, so a SECOND scan would have re-counted them. Carry it forward.
  $script:St.satisfied = @($priorSat)
  $notPriorSat = { param($r)
      if (-not ($r -and (Test-RowKey $r 'uid') -and $r.uid)) { return $true }   # no identity -> count it
      return ($priorSat -notcontains "$($r.uid):$($r.rev)") }
  $notPriorInfo = { param($r) ($priorInfo -notcontains $r.kb) -and ($priorInfo -notcontains $r.title) -and (& $notPriorSat $r) }
  $reportCount = @($avail | Where-Object { (& $notPriorInfo $_) }).Count
  if ($priorInfo.Count -gt 0 -and $reportCount -ne $avail.Count) {
    Log ("scan: excluding " + ($avail.Count - $reportCount) + " offer(s) a previous pass proved not actionable: " + ($priorInfo -join ', '))
  }
  # Under the ESU notice (netvm-free, post-EOS): only SELF-CONTAINED updates are actionable - express
  # (ESU-gated phantom) and 'none' (Defender delta / DO-only) cannot install routeless and are informational.
  if ($script:St.notice) { $reportCount = @($avail | Where-Object { $_.content_class -eq 'self-contained' -and (& $notPriorInfo $_) }).Count }
  # ---- WU-SCAN-COUNT-END
  $script:St.remaining = $reportCount; Save
  Log ("scan: $($avail.Count) update(s) offered" + $(if($script:St.notice){ "; $reportCount actionable (" + ($avail.Count - $reportCount) + " ESU-gated/express informational - see notice)" }else{ '' }))
  if ($script:St.notice) { Log ("SERVICING NOTICE: " + $script:St.notice) }
  Report-Availability $reportCount    # -> dom0 Qube Manager (default-allowed for TemplateVMs)

  # Applied AFTER reporting: dom0 must always hear the true number of available updates. -OnlyKb
  # narrows what THIS pass acts on, it does not narrow what the guest admits to.
  if ($OnlyKb.Count -gt 0) {
    $before = $avail.Count
    $avail = @($avail | Where-Object { $k = $_.kb; @($OnlyKb | Where-Object { $k -match $_ }).Count -gt 0 })
    Log ("-OnlyKb " + ($OnlyKb -join ',') + ": acting on $($avail.Count) of $before offered update(s)")
    # A KB that is no longer OFFERED (because it is already installed) can still be interrogated -
    # that is how you price a package after the fact. Allowed for `resolve` ONLY: resolve reads
    # catalog metadata and sizes, it downloads and installs nothing, so this can never push an
    # update onto a guest that Windows did not offer.
    if ($avail.Count -eq 0 -and $Action -eq 'resolve') {
      foreach ($k in $OnlyKb) {
        if ($k -match '^(KB\d+)$') {
          $avail += [pscustomobject]@{ kb = $Matches[1]; title = '(forced resolve - not currently offered)' }
        }
      }
      Log ("forced resolve of " + ($avail | ForEach-Object { $_.kb }) -join ',')
    }
  }

  if ($Action -eq 'wuinstall') {
    $script:St.result = Install-ViaWU
    Protect-Autologon
    $script:St.phase='done'; Complete-Pass
    Log 'done (WU-native)'
    return
  }

  # KBs the catalog cannot serve; handed to the Windows Update installer after the loop.
  $script:WuFallbackKbs = @()
  # KBs Windows Update publishes ONLY as Delivery-Optimization express streams (KB5071959-class):
  # not installable on a netvm-free guest, terminally classified, reported honestly after the loop.
  $script:WuOnlyExpressKbs = @()
  if ($env:QUBES_UPDATES_FAKE_FALLBACK_KB) {
    $script:WuFallbackKbs += $env:QUBES_UPDATES_FAKE_FALLBACK_KB
    Log ("QUBES_UPDATES_FAKE_FALLBACK_KB=" + $env:QUBES_UPDATES_FAKE_FALLBACK_KB + " - pretending that KB needs the Windows Update fallback")
  }
  if ($Action -in 'resolve','download','full','install') {
    foreach($u in $avail){
      if($u.kb -notmatch '^KB\d+'){
        # ---- WU-NOKB-BEGIN
        # GUARD:nokbinfo - an offer with no KB (a vendor driver, e.g. "Microsoft Corporation
        # AudioProcessingObject Driver Update") cannot be resolved through the update CATALOG,
        # because the catalog search is keyed on the KB number. That much is structural.
        #
        # BUT THE CATALOG IS NOT THE ONLY ROUTE, and this is where it was wrong. Get-Available
        # computes content_class and direct_urls for EVERY offer from the live IUpdate, so a no-KB
        # offer can perfectly well be 'self-contained' WITH a working download URL - installable
        # through the proxy with no catalog involved. The old code skipped on the SHAPE of the KB
        # field before ever looking at direct_urls, and so threw away an update it was holding the
        # means to install, then told dom0 it was not actionable. Jev put 0.80 on a genuinely
        # installable update legitimately lacking a KB; this is that case, in this code.
        # So: look for a route before declaring there is none.
        $nokb = if($u.title){ [string]$u.title } else { 'untitled offer' }
        $nokbUrls = @(@($u.direct_urls) | Where-Object { $_ })
        if($nokbUrls.Count -gt 0 -and $Action -in 'install','full'){
          Log "no KB but $($nokbUrls.Count) direct URL(s) - INSTALLING self-contained: $nokb"
          $nokbRows = Install-SelfContained $nokb $nokbUrls
          $nokbOk = @($nokbRows | Where-Object { $_.ok }).Count -gt 0
          $script:St.result += [ordered]@{ kb=$nokb; ok=$nokbOk
                                           state=$(if($nokbOk){'installed'}else{'failed'}); files=$nokbRows }
          Save
          continue
        }
        # No KB and no self-contained URL - but the CATALOG may still hold it under its title.
        # Resolve-DriverByTitle downloads each identically-titled candidate and picks on the
        # architecture the package declares, because that is the only thing that differs between
        # them. Only on an install action: a resolve/download pass must not change the guest.
        if($Action -in 'install','full'){
          Log "no KB and no direct URL - trying the catalog by title: $nokb"
          $drv = Resolve-DriverByTitle $nokb
          if($drv){
            $drow = Install-DriverCab $drv.file $nokb
            $script:St.result += [ordered]@{ kb=$nokb; title=$nokb; ok=[bool]$drow.ok
                                             state=$(if($drow.ok){'installed'}else{'failed'}); files=@($drow) }
            Save
            continue
          }
        }
        # Genuinely no route from here - and now that is a MEASURED statement, not an assumption
        # about the catalog.
        Log "skip (no KB, no direct URL, no catalog match for this architecture): $nokb"
        $script:St.result += [ordered]@{ kb=$nokb; title=$nokb; ok=$true; state='not-actionable'; severity='info';
                                         info_reason='offer carries no KB and no self-contained URL, and the catalog holds no entry with this exact title whose package declares this guest architecture - so there is no route to it from here. Checked, not assumed: the title search runs and each identically-titled candidate is inspected.' }
        Save
        continue
        # ---- WU-NOKB-END
      }
      $script:St.phase='resolve'; Save
      $urls = Resolve-Catalog $u.kb
      Log "$($u.kb): $($urls.Count) catalog .msu"
      # ASK BEFORE DOWNLOADING. The catalog's DownloadDialog returns every file bundled with an
      # update, including SUPERSEDED cumulatives: for KB5121003 it returns kb5043080 (2024-09)
      # alongside the one we want. On a 26100.8875 image the older one is not applicable, DISM
      # rejects it with rc=552, and feeding it to CBS first preceded the cumulative being rolled
      # back at boot with 0x80070490. The KB is in the URL, so this costs no bytes to decide.
      # /Get-PackageInfo cannot help here - measured: it reports the superseded package as
      # "Applicable: Yes, State: Installed, identity OnePackage~~~~0.0.0.0", i.e. nothing usable.
      # Deliberately ABOVE the resolve-only branch: the decision is pure string work on URLs, so
      # `-Action resolve` is a genuine zero-byte dry run of exactly what a download would fetch.
      $digits = ($u.kb -replace '\D', '')
      $matching = @($urls | Where-Object { $_ -match $digits })
      if ($matching.Count -gt 0 -and $matching.Count -lt $urls.Count) {
        Log ("  " + $u.kb + ": " + ($urls.Count - $matching.Count) + " of " + $urls.Count +
             " catalog file(s) are for other KBs - not downloading them")
        # Size the dropped files on a resolve pass. This is the ONLY exact figure for what the
        # filter saves - the payload's internal waste is not knowable from a URL - and it costs
        # one HEAD each, no body.
        foreach ($drop in ($urls | Where-Object { $_ -notmatch $digits })) {
          $nm = if ($drop -match '/([^/?]+\.msu)') { $Matches[1] } else { $drop }
          if ($Action -eq 'resolve') {
            $sz = Get-UrlSize $drop
            Log ("    DROP " + $nm + "  " + $(if($sz -ge 0){ "{0:N1} MB avoided" -f ($sz/1MB) } else { 'size unknown' }))
          } else { Log ("    DROP " + $nm) }
        }
        $urls = $matching
      } elseif ($matching.Count -eq 0) {
        Log ("  " + $u.kb + ": no catalog file names mention the KB - keeping all " + $urls.Count)
      }
      $got=@()
      if ($Action -eq 'resolve') {
        Log "$($u.kb): resolve-only, would fetch $($urls.Count) package(s)"
        $keepTotal = 0
        foreach ($url in $urls) {
          $nm = if ($url -match '/([^/?]+\.msu)') { $Matches[1] } else { $url }
          $sz = Get-UrlSize $url
          if ($sz -ge 0) { $keepTotal += $sz }
          Log ("    KEEP " + $nm + "  " + $(if($sz -ge 0){ "{0:N1} MB" -f ($sz/1MB) } else { 'size unknown' }))
        }
        Log ("  " + $u.kb + ": would transfer {0:N1} MB" -f ($keepTotal/1MB))
        continue
      }
      if ($Action -in 'download','full') {
        $script:St.phase='download'; Save
        # ONE DIRECTORY PER KB. DISM treats the folder holding a package as a source set: with a
        # flat work dir it pulled kb5054156-25h2-ekb.msu - a 25H2 enablement package left by an
        # earlier session - into a 24H2 servicing session (dism.log "LocalSources"). Isolating
        # each KB makes that impossible and keeps resume/reuse working.
        $kbDir = Join-Path $WorkDir $u.kb
        New-Item -ItemType Directory -Force $kbDir | Out-Null
        $i=0; foreach($url in $urls){ $i++; $name="$($u.kb)_$i.msu"; if($url -match '/([^/?]+\.msu)'){$name=$Matches[1]}
          $dst=Join-Path $kbDir $name; if(Fetch-Msu $url $dst $u.kb){ $got+=$dst } }
      } else { $got = @(Get-ChildItem (Join-Path (Join-Path $WorkDir $u.kb) '*.msu') -EA SilentlyContinue | ForEach-Object FullName) }
      # An offered KB that yields NO installable file is a FAILED update, not a quiet success.
      # Measured 2026-08-13: KB5120708 (.NET Framework) resolved to zero catalog .msu on a 25H2
      # guest - Resolve-Catalog is written around the x64/24H2/26100 client build - and because
      # nothing was downloaded there was no result row, so the pass reported "count=1" and exit 0
      # while installing nothing. dom0 must hear about that.
      if ($Action -in 'install','full' -and $got.Count -eq 0) {
        $why = if ($urls.Count -eq 0) { 'no catalog entry matches this Windows version/architecture' }
               else { "resolved $($urls.Count) package(s) from the catalog but none could be downloaded" }
        # Before calling it failed: some updates have no .msu for the DISM path to install.
        # CHECKED against the Update Catalog on 2026-08-15 rather than assumed:
        #   KB890830  (Malicious Software Removal Tool) IS in the catalog - 26 rows - but ships
        #             as an .exe, and Resolve-Catalog accepts only .msu because DISM does.
        #   KB2267602 (Defender definitions) is NOT in the catalog at all ("We did not find any
        #             results"); it is delivered through Windows Update / the security
        #             intelligence mpam-fe.exe.
        # Neither is a defect - it is how those products are packaged - but both would be
        # reported failed on every pass, leaving dom0 showing updates that never clear.
        # Hand exactly those to WU's own installer after this loop.
        if ($urls.Count -eq 0) {
          # The catalog has no .msu for this KB. Route by the content class computed at scan time
          # (Get-WuContentClass) instead of blindly handing it to the DO-gated Install-ViaWU, which
          # fails routeless. Three outcomes:
          $cls = $u.content_class
          $directUrls = @($u.direct_urls)
          if ($cls -eq 'self-contained' -and $directUrls.Count -gt 0) {
            # Defender defs / MSRT / SSU published as a static file: fetch through the proxy and
            # install natively, NLA-free. This is the class that failed EVERY pass before.
            Log "$($u.kb): not in the catalog, but Windows Update offers it as a self-contained static file - installing directly through the proxy (no DO/BITS/NLA)"
            $script:St.phase='install'; Save
            $rows = Install-SelfContained $u.kb $directUrls
            $ok = @($rows | Where-Object { $_.ok }).Count -gt 0
            $staged = @($rows | Where-Object { $_.rc -eq 3010 }).Count -gt 0
            # If nothing installed AND every file was a not-a-package informational (WU-client blob,
            # e.g. KB5001716), the KB is INFORMATIONAL, not a failure - so it is excluded from the
            # failed/remaining count and does not read as broken forever.
            $allInfo = (-not $ok) -and (@($rows).Count -gt 0) -and (@($rows | Where-Object { $_.severity -ne 'info' }).Count -eq 0)
            $row = [ordered]@{ kb=$u.kb; ok=$ok; state=$(if($staged){'staged'}elseif($ok){'installed'}elseif($allInfo){'informational'}else{'failed'}); files=$rows }
            if ($allInfo) { $row.severity = 'info' }
            $script:St.result += $row
            Save
            Log "$($u.kb): self-contained $(if($allInfo){'informational (not a DISM-installable package)'}else{"install ok=$ok"})"
            continue
          }
          if ($cls -eq 'express') {
            # KB5071959-class: published ONLY as Delivery-Optimization delta streams. Not installable
            # on a netvm-free guest and it carries no content the catalog CU does not. Classify it
            # terminally - never chase it into the DO/BITS path that would fail forever.
            $script:WuOnlyExpressKbs += $u.kb
            Log "$($u.kb): published only as Delivery-Optimization express/UUP streams - terminally classified (not installable netvm-free, not chased)"
            continue
          }
          # class 'none'/unknown: only a guest that actually has a route may try the WU installer.
          $script:WuFallbackKbs += $u.kb
          Log "$($u.kb): no catalog .msu and no static WU URL - deferring to the Windows Update installer (route permitting)"
          continue
        }
        $script:St.result += [ordered]@{ kb=$u.kb; ok=$false; files=@(); reason=$why }
        Save
        Log "$($u.kb): NO installable package resolved - reporting as failed"
      }
      if ($Action -in 'install','full' -and $got.Count -gt 0) {
        $script:St.phase='install'; Save
        # One catalog KB can yield SEVERAL .msu (build/architecture variants, prerequisites), and
        # the ones that do not apply to this image fail by design - a 24H2 cumulative returns
        # rc=552 on a 25H2 guest. So a KB counts as installed when AT LEAST ONE of its files
        # succeeds, and results are grouped PER KB and APPENDED. This used to be a plain
        # assignment of a flat row list, so each KB silently erased the previous KB's outcome.
        $rows = Install-Msus $got
        $ok = @($rows | Where-Object { $_.rc -in $OK_RC }).Count -gt 0
        # STAGED IS NOT INSTALLED. rc=3010 means CBS accepted the package and will apply it during
        # the next boot - it is not proof that it landed, and on 2026-08-14 a package that returned
        # 3010 ended up with ZERO CBS entries after the reboot while this code reported
        # "installed=True". Say which it is, so a discarded package can never read as a success.
        $staged = @($rows | Where-Object { $_.rc -eq 3010 }).Count -gt 0
        $applied = @($rows | Where-Object { $_.rc -eq 0 }).Count -gt 0
        $deferred = @($rows | Where-Object { $_.rc -eq 'deferred' }).Count -gt 0
        $state = if ($staged) { 'staged' } elseif ($applied) { 'installed' }
                 elseif ($deferred) { 'deferred' } else { 'failed' }
        $script:St.result += [ordered]@{ kb=$u.kb; ok=$ok; state=$state; files=$rows }
        Save
        # Reclaim the download ONLY once the package is truly applied. A STAGED package still has
        # to survive a reboot, and if it does not, the next pass must be able to retry it without
        # re-fetching gigabytes - deleting it here is what made a failed apply expensive.
        if (-not $staged) {
          foreach($r in $rows){ if($r.rc -in $OK_RC){ Remove-Item -LiteralPath (Join-Path (Join-Path $WorkDir $u.kb) $r.file) -Force -EA SilentlyContinue } }
        }
        Log "$($u.kb): $state (ok=$ok)"
      }
    }
  }
  # Updates that are not catalog packages: install them the only way they CAN be installed.
  #
  # NOT if this session already staged something. CBS applies exactly ONE staged session per
  # boot and silently discards anything staged behind it (measured twice, 2026-08-14, with
  # RebootPending confirmed and TiWorker idle - it is not a shutdown race). The catalog path
  # already stops for that reason; letting Windows Update install into the same session
  # afterwards would walk straight back into it, and the discarded package would be reported
  # as installed. dom0 drives a second pass, which is where these belong.
  # The Windows Update installer (Install-ViaWU) downloads through Delivery Optimization / BITS, which
  # REFUSE on a guest with no route (measured DO 0x80D03805 / BITS 0x80200010) - so on a netvm-free
  # guest this rung only manufactures phantom 0x80240022 failures. canWuNative is the guest's ability to
  # ever install these: a real default route (netvm-attached standalone) or the explicit override.
  $canWuNative = (Test-HasDefaultRoute) -or ($env:QUBES_UPDATES_ALLOW_WU_NATIVE -eq '1')
  # DEFER only makes sense when the guest CAN install them next pass (canWuNative): CBS applies exactly
  # ONE staged session per boot, so a second WU-native install this pass would be silently discarded.
  # On a netvm-free guest (no route) they are never installable, so skip the deferral and let the
  # informational block below classify them honestly instead of promising a "next pass" that never installs.
  if ($Action -in 'install','full' -and $script:WuFallbackKbs.Count -gt 0 -and $canWuNative -and
      ($script:StagedThisSession -or $script:St.reboot_needed) -and -not $env:QUBES_UPDATES_ALLOW_MULTISTAGE) {
    foreach ($kb in $script:WuFallbackKbs) {
      $script:St.result += [ordered]@{ kb=$kb; ok=$false; files=@()
                                       reason='deferred: a reboot-requiring package is already staged this session; the next pass installs this' }
    }
    Save
    Log ("Windows Update fallback DEFERRED for " + ($script:WuFallbackKbs -join ',') +
         " - something is already staged this session and CBS would discard a second one")
    $script:WuFallbackKbs = @()
  }
  if ($Action -in 'install','full' -and $script:WuFallbackKbs.Count -gt 0 -and -not $canWuNative) {
    $script:WuFallbackKbs = @($script:WuFallbackKbs | Sort-Object -Unique)
    foreach ($kb in $script:WuFallbackKbs) {
      # DEFENDER SIGNATURES ARE NO LONGER A DEAD END. The full package turned out to be a plain
      # HTTPS download (see Get-DefenderFullPackageUrl), so a netvm-free guest CAN take it. Try that
      # before declaring the KB informational; Install-SelfContained already verifies Defender by
      # EFFECT (AntivirusSignatureVersion moving), not by exit code.
      $isDefender = ($kb -eq 'KB2267602') -or
                    (@($avail | Where-Object { $_.kb -eq $kb -and $_.title -match 'Defender|Antivirus|Security Intelligence' }).Count -gt 0)
      if ($isDefender) {
        $defUrl = Get-DefenderFullPackageUrl
        if ($defUrl) {
          Log "Defender $kb : resolved the full signature package, installing it directly (netvm-free)"
          $defRows = Install-SelfContained $kb @($defUrl)
          $defOk = (@($defRows | Where-Object { $_.ok }).Count -gt 0)
          $script:St.result += [ordered]@{ kb=$kb; ok=$defOk; severity=$(if($defOk){'ok'}else{'info'})
            files=@($defRows)
            reason=$(if($defOk){'full signature package installed directly (verified by effect)'}
                     else{'full signature package resolved but did not apply - INFORMATIONAL, not a failure'}) }
          Save
          continue
        }
        # fall through to the informational record below when the fwlink could not be resolved
      }
      # severity='info': on a netvm-free guest there is NO route by which these could install (no catalog
      # .msu, no static file, and DO/BITS refuse routeless), so this is a deterministic INFORMATIONAL
      # ceiling. Not a failure, and excluded from the actionable/remaining count reported to dom0.
      # GUARD:catalogvalid - but ONLY when the catalog actually answered. If the search response
      # could not be validated as a results page then "no catalog .msu" is an UNKNOWN, not a fact,
      # and an unknown must never buy a permanent exclusion from dom0's count.
      if ($script:CatalogUnresolved) {
        Log ("  " + $kb + " : NOT classified informational - the catalog search was UNRESOLVED, so 'no package' is unproven")
        $script:St.result += [ordered]@{ kb=$kb; ok=$false; files=@()
          reason='catalog search did not return a valid results page - resolution UNRESOLVED, so this KB stays outstanding rather than being excluded' }
      } else {
      $script:St.result += [ordered]@{ kb=$kb; ok=$false; severity='info'; files=@()
        reason='not installable on a netvm-free guest: no catalog .msu and no self-contained static installer (delivered only via Delivery Optimization / a delta patch). INFORMATIONAL - not a failure' }
      }
    }
    Save
    Log ("Windows Update native installer SKIPPED (informational) for " + ($script:WuFallbackKbs -join ',') +
         " - no default route; DO/BITS would fail routeless (set QUBES_UPDATES_ALLOW_WU_NATIVE=1 to force)")
    $script:WuFallbackKbs = @()
  }
  if ($Action -in 'install','full' -and $script:WuFallbackKbs.Count -gt 0) {
    $script:WuFallbackKbs = @($script:WuFallbackKbs | Sort-Object -Unique)
    Log ("Windows Update fallback for " + ($script:WuFallbackKbs -join ',') + " (no .msu for the DISM path)")
    try {
      $wuRows = Install-ViaWU -OnlyKbs $script:WuFallbackKbs -TunePolicies $false
      foreach ($row in $wuRows) { $script:St.result += $row }
      $done = @($wuRows | Where-Object { $_.ok }).Count
      Log "Windows Update fallback: $done of $($script:WuFallbackKbs.Count) installed"
      # Install-ViaWU sets St.reboot_needed when Windows asks for one. Say so here too: a
      # definition update normally needs no reboot, and if one of these ever does, that is
      # exactly the fact the next pass has to know about.
      if ($script:St.reboot_needed) { Log 'Windows Update fallback: a reboot is required to finish' }
      # Anything the fallback did not cover is still a failure, and dom0 must hear it.
      foreach ($kb in $script:WuFallbackKbs) {
        if (-not (@($wuRows | Where-Object { $_.kb -eq $kb }).Count -gt 0)) {
          $script:St.result += [ordered]@{ kb=$kb; ok=$false; files=@()
                                           reason='no .msu for the DISM path, and the Windows Update installer did not offer it either' }
        }
      }
      Save
    } catch {
      Log "Windows Update fallback failed: $($_.Exception.Message)" 'ERROR'
      foreach ($kb in $script:WuFallbackKbs) {
        $script:St.result += [ordered]@{ kb=$kb; ok=$false; files=@(); reason="Windows Update fallback failed: $($_.Exception.Message)" }
      }
      Save
    }
  }

  # Terminal honesty gate for express-only KBs (KB5071959-class). These are published only as
  # Delivery-Optimization delta streams and are not installable on a netvm-free guest by ANY path -
  # so report them once, deterministically, as a fixed ceiling, instead of failing them forever. On
  # post-EOS Win10 (19045) the underlying reason is the ESU entitlement gate at CBS install time
  # (the real Nov CU, KB5068781, IS in the catalog and installs via the existing path ONCE entitled);
  # surface that as a stable status so dom0 sees the ceiling rather than a phantom transport failure.
  if ($Action -in 'install','full' -and $script:WuOnlyExpressKbs.Count -gt 0) {
    $script:WuOnlyExpressKbs = @($script:WuOnlyExpressKbs | Sort-Object -Unique)
    foreach ($kb in $script:WuOnlyExpressKbs) {
      # severity='info' marks this as INFORMATIONAL, not a failure: it is excluded from the failed/
      # remaining count reported to dom0 (see below), so a KB the guest can never apply routeless does
      # not read as a broken update forever. The St.notice (set at scan time) carries the ESU diagnosis.
      $script:St.result += [ordered]@{ kb=$kb; ok=$false; severity='info'
        reason='wu-only-express: Windows Update offers this KB only through Delivery Optimization (express streams and/or a delta patch that needs a base); no catalog .msu and no self-contained static installer, so it is not installable on a netvm-free guest. INFORMATIONAL - not a failure.' }
    }
    if ("$OsBuild" -eq '19045' -and -not $script:St.esu) { $script:St.esu = Get-EsuStatus }
    Save
    Log ("wu-only-express (informational, terminally classified): " + ($script:WuOnlyExpressKbs -join ',') +
         $(if($script:St.esu){ " ; ESU=$($script:St.esu)" }else{ '' }))
  }

  # Re-report availability at the END of an install pass, so dom0's "updates available" marker
  # reflects reality instead of the pre-install scan. Two cases:
  #  - a reboot is pending: Windows keeps offering the KB until it boots, so any count now would
  #    be a lie. We are rebooting anyway, and the boot scan task (BootTrigger + 2 min) reports
  #    the truth - the same shape as Linux's upgrades-status-notify after an update. That boot
  #    scan is a -Scheduled pass; the debounce at the top of this file exempts it while the
  #    previous status is reboot-pending, because without the exemption it was skipped every time.
  #  - nothing pending: rescan now and report, or the flag stays set until the next 6-hourly scan.
  if ($Action -in 'install','full') {
    if ($script:St.reboot_needed) {
      # Everything offered was applied; the reboot is ours to perform and happens immediately
      # after this pass. Windows keeps listing the KB as "available" until it boots, but that is
      # a Windows artefact - from dom0's point of view the update IS applied, so clear the flag
      # now rather than leaving the qube marked for minutes. Anything that did NOT install is
      # still reported, and the boot scan re-reports the truth either way, so a wrong guess here
      # self-corrects within ~2 minutes of the restart.
      # COUNT BY KEY (Test-RowKey), never by PSObject.Properties.Name: the rows are [ordered]
      # dictionaries, and on those that property list never contains 'kb', so the old predicate
      # matched nothing and this reported 0 on EVERY reboot-pending pass. Measured 2026-09-16 on
      # German Win11 25H2 (4.3.29): result row kb=KB5129195 ok=false state=deferred (the 4.4 GB
      # September cumulative, downloaded, waiting for the .NET reboot), "remaining": 0 written,
      # dom0's updates-available cleared - Qube Manager then showed the qube as up to date.
      # ---- WU-REBOOT-PENDING-REPORT-BEGIN
      # A STAGED OR DEFERRED ROW IS NOT APPLIED. The comment above says "everything offered was
      # applied", and for a row that INSTALLED that is true - but a staged package has been written
      # to the image and needs exactly the reboot that is pending, and a deferred one has not been
      # installed at all. Both carry ok=$true or ok=$false with a `state`, and the old predicate
      # counted only `-not $_.ok`, so a staged cumulative reported ZERO.
      #
      # Measured 2026-09-21 on win11de-ctld, GWeck's environment: KB5129195 came back
      # `ok=true state=staged` with reboot_needed=true and this path reported 0 to dom0, which then
      # showed the template as up to date - the ORIGINAL field report, surviving in a THIRD code
      # path after GUARD:rowkey fixed it here and GUARD:stagedpending fixed it in the post-install
      # rescan. The oscillation check caught it independently: dom0 '<empty>' after the pass and
      # '1' after the very next scan. (# GUARD:stagedpending, reboot-pending half.)
      $doneStates = @('installed','ok','up-to-date','not-actionable')
      $pendingKbs = @($script:St.result |
                     Where-Object { (Test-RowKey $_ 'kb') -and $_.severity -ne 'info' -and ((-not $_.ok) -or ((Test-RowKey $_ 'state') -and ($doneStates -notcontains [string]$_.state))) })   # GUARD:rowkey
      # NO FLOOR. An earlier version of this fix forced at least 1 whenever a reboot was pending,
      # even with nothing staged or deferred - which would pin dom0 at "updates available" forever
      # on a guest carrying a stale CBS RebootPending and nothing to install. That is the inverse
      # defect the owner reported (a template that can never show as up to date), so the rule is
      # exactly "count what is not applied" and nothing more. Jev ruled on staged packages
      # (count-staged 0.97); the floor was mine and is withdrawn.
      $pendingCount = $pendingKbs.Count
      $script:St.remaining = $pendingCount; Save
      Log "reboot pending; reporting $pendingCount remaining to dom0 (staged and deferred work is NOT applied)"
      Report-Availability $pendingCount
      # ---- WU-REBOOT-PENDING-REPORT-END
    } else {
      # Best-effort: this is a REPORT, not the work. It needs the proxy, and if anything has
      # taken the proxy away (measured: a concurrent scan's Remove-Proxy) Get-Available throws
      # 0x80240438 - which used to propagate and mark a pass that had installed everything
      # successfully as phase=error.
      try {
        $after = Get-Available
        # Refresh the ESU diagnosis from the post-install scan, and report only ACTIONABLE updates so an
        # ESU-gated/express phantom does not leave dom0 permanently marked "updates available".
        if ("$OsBuild" -eq '19045') { $script:St.esu = Get-EsuStatus; $script:St.notice = Get-ServicingNotice $after $script:St.esu }
        # Exclude KBs this pass proved informational (a self-contained artifact DISM rejected as
        # not-a-package, e.g. KB5001716) - they are self-contained by shape but never installable, so
        # they must not leave dom0 marked "updates available" forever.
        # Key on kb AND title. A no-KB offer (GUARD:nokbinfo) is recorded under its TITLE because it
        # has no KB, so a kb-only match would silently fail to exclude exactly the rows that most
        # need excluding - the ones that can never be actioned.
        # GUARD:actioned - dom0's count is what the ADMIN still has to do, not what Windows Update
        # still feels like offering. Two kinds of row drop out of it:
        #   severity='info'  - the guest can never action it (no route, no package, nothing to do);
        #   ok=$true         - THIS PASS actioned or satisfied it (installed, staged, already
        #                      current), and Windows Update re-offering it changes nothing the
        #                      admin can act on.
        # Measured 2026-09-20 on the German 25H2 guest: after a pass that INSTALLED KB5007651 and
        # found the Defender signatures current, both were still offered and both still counted, so
        # dom0 sat at "updates available" for work already done - the same untruth as the field
        # report, one layer further in.
        # Rows with ok=$false stay counted, which is what keeps a DEFERRED cumulative visible - the
        # control that must never be excluded.
        # GUARD:infoalways - informational rows are excluded from dom0's actionable count ALWAYS,
        # not only under the post-end-of-support notice. Before 2026-09-20 the else-branch was a
        # bare $after.Count, so on a current OS every un-actionable offer still counted and dom0
        # could never reach "up to date" - measured on the German 25H2 template, three items
        # re-offered on every pass after the September cumulative was fully applied.
        # ---- WU-INFO-EXCLUDE-BEGIN
        # WHAT EARNS AN OFFER ITS SILENCE. Two things only: a row classified INFORMATIONAL, and a
        # row that is genuinely DONE. A STAGED or DEFERRED row is neither - it is work written to
        # the image that needs a reboot to become real.
        #
        # GUARD:stagedpending. Measured 2026-09-21 on the PRE-TUESDAY CONTROL, and only the control
        # could see it: KB5129195 came back ok=true state=staged with reboot_needed=true, the bare
        # `$_.ok -eq $true` swept it into the excluded set, remaining went to 0 and dom0 was told
        # the template was UP TO DATE while a cumulative sat waiting for a reboot. That is the
        # field report's own defect (ADR section 2), reintroduced through the door opened to fix
        # its opposite. On an already-updated guest this bug is invisible, which is the whole
        # argument for running both controls against one build.
        $doneStates = @('installed','ok','up-to-date','not-actionable')
        $infoKbs = @($script:St.result |
                     Where-Object {
                       ($_.severity -eq 'info') -or
                       ($_.ok -eq $true -and ((-not (Test-RowKey $_ 'state')) -or ($doneStates -contains [string]$_.state))) } |
                     ForEach-Object { $_.kb; if($_.PSObject -and (Test-RowKey $_ 'title')){ $_.title } } |
                     Where-Object { $_ })
        $notInfo = { param($r) ($infoKbs -notcontains $r.kb) -and ($infoKbs -notcontains $r.title) }
        $reportCount = if ($script:St.notice) { @($after | Where-Object { $_.content_class -eq 'self-contained' -and (& $notInfo $_) }).Count }
                       else { @($after | Where-Object { (& $notInfo $_) }).Count }
        # STAGED WORK STILL COUNTS even when Windows has stopped offering it - it is written to the
        # image and not applied until the restart. Counted from the RESULT rows, not from what the
        # rescan still offers. No blanket floor on reboot_needed: forcing >=1 with nothing staged
        # would pin dom0 at "updates available" on a stale CBS RebootPending, which is the inverse
        # defect. (Jev: count-staged 0.97; under-reporting is the worse error at 0.99.)
        $stagedN = @($script:St.result | Where-Object { (Test-RowKey $_ 'state') -and (@('staged','deferred') -contains [string]$_.state) }).Count
        if ($stagedN -gt $reportCount) { $reportCount = $stagedN }
        # GUARD:offeridentity - record WHICH OFFERS this pass resolved, by the offer's own identity.
        # A later scan may then exclude the very same offer without weakening the rule right above
        # it ("installed last time" is not evidence a FRESH offer is satisfied): a new revision has
        # a different identity and is counted again. An offer with no identity records nothing, so
        # the fallback is always "count it".
        $script:St.satisfied = @($script:St.available | Where-Object {
                                   ($infoKbs -contains $_.kb) -or ($infoKbs -contains $_.title) } |
                                 ForEach-Object {
                                   if ($_ -and (Test-RowKey $_ 'uid') -and $_.uid) { "$($_.uid):$($_.rev)" } } |
                                 Where-Object { $_ })
        # ---- WU-INFO-EXCLUDE-END
        $script:St.remaining = $reportCount; Save
        Log ("post-install rescan: $($after.Count) offered; $reportCount actionable to dom0" + $(if($script:St.notice){ ' (ESU-gated informational - see notice)' }else{ '' }))
        if ($script:St.notice) { Log ("SERVICING NOTICE: " + $script:St.notice) }
        Report-Availability $reportCount
      } catch {
        Log "post-install rescan failed (updates are installed; availability will be re-reported by the next scan): $($_.Exception.Message)"
      }
    }
  }

  Protect-Autologon
  $script:St.phase='done'; Complete-Pass
  Log 'done'
} catch {
  $script:St.phase='error'; $script:St.error="$($_.Exception.Message)"; Save
  Log "ERROR: $($script:St.error)"
} finally {
  # Re-arm autologon on ANY exit path that staged a reboot - INCLUDING a throw AFTER staging (e.g.
  # Resolve-Catalog/Fetch failing once a package was already applied rc=3010). Previously this ran
  # only on the success paths, so a staged-then-threw pass left the guest reboot-pending with
  # autologon unarmed = the sign-in lockout (qrexec rc=117, unmanageable qube). Idempotent + guarded.
  Protect-Autologon
  Remove-Proxy   # ALWAYS restore the routeless baseline - see the Ensure-Proxy comment
  if ($script:HaveMutex) { try { $script:Mutex.ReleaseMutex() } catch {} }
}
# Exit-code contract: a pass that errored must NOT exit 0. A dom0 wrapper or a scheduled task's
# LastTaskResult that trusts the exit code would otherwise misread failure as clean success.
if ($script:St.phase -eq 'error') { exit 1 }
