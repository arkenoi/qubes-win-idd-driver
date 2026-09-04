# toast-bridge.ps1 — Proposal C phase 1 of docs/DESIGN-toast-bridge.md, running code.
#
# Forward-only, per-app toast bridge: toasts from ALLOWLISTED apps (AUMIDs) are read via
# UserNotificationListener in the interactive user session and forwarded to the dom0-native
# notification service through tools/notify-proxy's NotifyClient (`--send-file`). For each
# allowlisted AUMID the Windows banner is suppressed (ShowBanner=0) so the toast does NOT map
# as an override-redirect window in dom0 — the dom0-native rendering replaces it; the
# notification still lands in the guest's Notification Center (the user's record is intact).
# Apps NOT on the allowlist are untouched: today's seamless window path, full fidelity.
# Fail-open by construction (DESIGN-toast-bridge.md §2.3): unknown app => window path.
#
# MUST run as the INTERACTIVE USER (run-as-user.ps1 -NoWait -Tag bridge). SYSTEM has no
# listener, no HKCU, no toasts.
#
#   toast-bridge.ps1 [-AllowAumids <a,b,...>] [-PollSec 2] [-ClientExe <path>]
#   toast-bridge.ps1 -Stop     # ask a running bridge to exit (stop file)
#
# State/log under C:\ProgramData\qubes-toast-bridge\ (bridge.log, stop, seen baseline is
# in-memory only: toasts existing BEFORE start are never forwarded — no replay storms).
# Politeness (notify-proxy README): sends are sequential, ack-waited, coalesced (>3 new
# toasts in one poll become ONE summary notification), so the dom0 side is never flooded.
param(
    [string]$AllowAumids = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe',
    [int]$PollSec = 2,
    [string]$ClientExe = '',
    [switch]$Stop
)
$ErrorActionPreference = 'Continue'
$base = 'C:\ProgramData\qubes-toast-bridge'
New-Item -ItemType Directory -Force -Path $base | Out-Null
$logf = Join-Path $base 'bridge.log'
$stopf = Join-Path $base 'stop'
function Log([string]$m) { ('{0:HH:mm:ss} {1}' -f (Get-Date), $m) | Add-Content -Path $logf -Encoding ASCII }

if ($Stop) { Set-Content -Path $stopf -Value 'stop'; Write-Output 'BRIDGE stop requested'; exit 0 }
Remove-Item $stopf -Force -EA SilentlyContinue

# -- locate NotifyClient.exe (compiled by send-notification.ps1; look next to this script too)
if (-not $ClientExe) {
    $here = Split-Path -Parent $MyInvocation.MyCommand.Path
    foreach ($cand in @((Join-Path $here 'NotifyClient.exe'),
                        'C:\Users\user\Documents\QubesIncoming\win-idd-mgmt\NotifyClient.exe')) {
        if (Test-Path $cand) { $ClientExe = $cand; break }
    }
}
if (-not $ClientExe -or -not (Test-Path $ClientExe)) { Log 'FATAL no NotifyClient.exe'; Write-Output 'BRIDGE FATAL no NotifyClient.exe'; exit 2 }

$allow = @($AllowAumids -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })

# -- consent (own HKCU; same value the Settings toggle writes)
$ck = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\userNotificationListener'
if (-not (Test-Path $ck)) { New-Item -Path $ck -Force | Out-Null }
if ((Get-ItemProperty -Path $ck -Name Value -EA SilentlyContinue).Value -ne 'Allow') {
    Set-ItemProperty -Path $ck -Name Value -Value 'Allow'; Log 'consent seeded Allow'
}

# -- banner suppression for allowlisted apps (notification still reaches the Notification
#    Center and the listener; only the popup — the o-r window dom0 would show — is gone)
foreach ($a in $allow) {
    $nk = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\$a"
    if (-not (Test-Path $nk)) { New-Item -Path $nk -Force | Out-Null }
    Set-ItemProperty -Path $nk -Name ShowBanner -Value 0 -Type DWord
    Log "ShowBanner=0 for $a"
}

# -- WinRT
[void][Windows.UI.Notifications.Management.UserNotificationListener, Windows.UI.Notifications, ContentType=WindowsRuntime]
[void][Windows.UI.Notifications.NotificationKinds, Windows.UI.Notifications, ContentType=WindowsRuntime]
[void][Windows.UI.Notifications.KnownNotificationBindings, Windows.UI.Notifications, ContentType=WindowsRuntime]
Add-Type -AssemblyName System.Runtime.WindowsRuntime
$asTask = ([System.WindowsRuntimeSystemExtensions].GetMethods() |
    Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
                   $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
$nlType = [System.Collections.Generic.IReadOnlyList[Windows.UI.Notifications.UserNotification]]
function ReadToasts($listener) {
    $task = $asTask.MakeGenericMethod($nlType).Invoke($null,
        @($listener.GetNotificationsAsync([Windows.UI.Notifications.NotificationKinds]::Toast)))
    if (-not $task.Wait(10000)) { throw 'listener read timeout 10s' }
    return $task.Result
}
function ToastText($n) {
    $title = ''; $body = ''
    try {
        $b = $n.Notification.Visual.GetBinding([Windows.UI.Notifications.KnownNotificationBindings]::ToastGeneric)
        if ($b) {
            $te = @($b.GetTextElements())
            if ($te.Count -ge 1) { $title = $te[0].Text }
            if ($te.Count -ge 2) { $body = (@($te | Select-Object -Skip 1) | ForEach-Object { $_.Text }) -join ' — ' }
        }
    } catch { }
    return @($title, $body)
}
function SendDom0([string]$summary, [string]$body) {
    # --send-file: UTF-8, first line = summary, rest = body (survives quotes/unicode/newlines)
    $tmp = Join-Path $base ('msg-' + [Guid]::NewGuid().ToString('N') + '.txt')
    [IO.File]::WriteAllText($tmp, "$summary`n$body", (New-Object Text.UTF8Encoding $false))
    $out = & $ClientExe --send-file $tmp --timeout 15 2>&1 | Out-String
    Remove-Item $tmp -Force -EA SilentlyContinue
    return $out.Trim()
}

$listener = [Windows.UI.Notifications.Management.UserNotificationListener]::Current
$status = $listener.GetAccessStatus().ToString()
if ($status -ne 'Allowed') { Log "FATAL access=$status"; Write-Output "BRIDGE FATAL access=$status"; exit 2 }

# -- baseline: everything already in the center predates us — never forwarded
$seen = @{}
try { foreach ($n in (ReadToasts $listener)) { $seen[[string]$n.Id] = 1 } } catch { Log "baseline read failed: $_" }
Log ("BRIDGE armed allow=[{0}] baseline={1} client={2}" -f ($allow -join ';'), $seen.Count, $ClientExe)
Write-Output 'BRIDGE armed'

$failStreak = 0
while (-not (Test-Path $stopf)) {
    Start-Sleep -Seconds $PollSec
    try {
        $cur = ReadToasts $listener
        $failStreak = 0
        $new = @()
        foreach ($n in $cur) {
            $id = [string]$n.Id
            if ($seen.ContainsKey($id)) { continue }
            $seen[$id] = 1
            $aumid = ''; try { $aumid = $n.AppInfo.AppUserModelId } catch {}
            if ($allow -notcontains $aumid) { Log "skip id=$id aumid=$aumid (window path)"; continue }
            $app = ''; try { $app = $n.AppInfo.DisplayInfo.DisplayName } catch {}
            $t = ToastText $n
            $new += ,@($id, $app, $t[0], $t[1])
        }
        if ($new.Count -gt 3) {
            # coalesce a burst into one dom0 notification (politeness rule)
            $lines = ($new | ForEach-Object { '{0}: {1}' -f $_[2], $_[3] }) -join "`n"
            $v = SendDom0 ("{0} notifications ({1})" -f $new.Count, $new[0][1]) $lines
            Log "SENT coalesced x$($new.Count): $v"
        } else {
            foreach ($e in $new) {
                $body = if ($e[3]) { $e[3] } else { $e[1] }
                $v = SendDom0 $e[2] $body
                Log ("SENT id={0} app='{1}' title='{2}': {3}" -f $e[0], $e[1], $e[2], $v)
            }
        }
        # bound the seen-set (ids are monotonic per session; keep it simple and small)
        if ($seen.Count -gt 500) {
            $keep = @{}; foreach ($n in $cur) { $keep[[string]$n.Id] = 1 }; $seen = $keep
        }
    } catch {
        $failStreak++
        Log "poll error ($failStreak): $($_.Exception.Message.Trim())"
        if ($failStreak -ge 30) { Log 'FATAL 30 consecutive poll errors, exiting'; break }
    }
}
Remove-Item $stopf -Force -EA SilentlyContinue
Log 'BRIDGE stopped'
