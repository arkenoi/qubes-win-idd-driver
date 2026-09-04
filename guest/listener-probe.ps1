# listener-probe.ps1 — prove/refute: an UNPACKAGED PowerShell in the interactive user session
# can read other apps' toasts via Windows.UI.Notifications.Management.UserNotificationListener,
# and remove one (RemoveNotification). This is the load-bearing unknown of the toast-bridge
# design (docs/DESIGN-toast-bridge.md §2.1): the documented API exposes TEXT ONLY, and its use
# from unpackaged callers is disputed in the field — measure, don't argue.
#
# MUST run as the INTERACTIVE USER (via run-as-user.ps1), not SYSTEM: the listener and the
# consent store are per-user state.
#
# Steps (each reported; a throw reports the step it died in):
#   1. seed HKCU CapabilityAccessManager consent userNotificationListener=Allow (own hive)
#   2. GetAccessStatus
#   3. fire a marker toast (ToastGeneric, no buttons — informational class)
#   4. GetNotificationsAsync(Toast) — count + AUMID/title/body of every current toast
#   5. find the marker; RemoveNotification(marker); re-read; report the delta
# Output: one JSON object after === RESULT ===.
$ErrorActionPreference = 'Stop'
$r = [ordered]@{ step = 'init'; consent_before = ''; consent_seeded = $false; access_status = '';
                 fired = $false; count = -1; toasts = @(); marker_seen = $false;
                 removed_ok = $false; count_after_remove = -1; error = '' }
$marker = 'QWTBRIDGEPROBE ' + (Get-Random)
try {
    # -- 1. consent seed (HKCU, our own hive; the Settings UI writes the same value)
    $r.step = 'consent'
    $ck = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\userNotificationListener'
    if (-not (Test-Path $ck)) { New-Item -Path $ck -Force | Out-Null }
    $r.consent_before = (Get-ItemProperty -Path $ck -Name Value -EA SilentlyContinue).Value
    if ($r.consent_before -ne 'Allow') {
        Set-ItemProperty -Path $ck -Name Value -Value 'Allow'
        $r.consent_seeded = $true
    }

    # -- WinRT projections
    $r.step = 'winrt-load'
    [void][Windows.UI.Notifications.Management.UserNotificationListener, Windows.UI.Notifications, ContentType=WindowsRuntime]
    [void][Windows.UI.Notifications.NotificationKinds, Windows.UI.Notifications, ContentType=WindowsRuntime]
    [void][Windows.UI.Notifications.KnownNotificationBindings, Windows.UI.Notifications, ContentType=WindowsRuntime]
    [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType=WindowsRuntime]
    [void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType=WindowsRuntime]
    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    $asTask = ([System.WindowsRuntimeSystemExtensions].GetMethods() |
        Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
                       $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
    function Await($op, [Type]$t) {
        $task = $asTask.MakeGenericMethod($t).Invoke($null, @($op))
        if (-not $task.Wait(10000)) { throw 'await timeout 10s' }
        return $task.Result
    }

    $listener = [Windows.UI.Notifications.Management.UserNotificationListener]::Current

    # -- 2. access status (sync; known to throw on some unpackaged callers — that IS a result)
    $r.step = 'access-status'
    try { $r.access_status = $listener.GetAccessStatus().ToString() }
    catch { $r.access_status = 'THREW: ' + $_.Exception.Message.Trim() }

    # -- 3. marker toast: informational class (no actions, default scenario)
    $r.step = 'fire'
    $aumid = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
    $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
    $xml.LoadXml("<toast><visual><binding template=""ToastGeneric""><text>$marker</text><text>listener probe body</text></binding></visual></toast>")
    [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($aumid).Show(
        [Windows.UI.Notifications.ToastNotification]::new($xml))
    $r.fired = $true
    Start-Sleep -Seconds 2

    # -- 4. read back
    $r.step = 'read'
    $nl = [System.Collections.Generic.IReadOnlyList[Windows.UI.Notifications.UserNotification]]
    $notifs = Await ($listener.GetNotificationsAsync([Windows.UI.Notifications.NotificationKinds]::Toast)) $nl
    $r.count = $notifs.Count
    $markerId = 0
    foreach ($n in $notifs) {
        $row = [ordered]@{ id = $n.Id; aumid = ''; app = ''; title = ''; body = '' }
        try { $row.aumid = $n.AppInfo.AppUserModelId; $row.app = $n.AppInfo.DisplayInfo.DisplayName } catch {}
        try {
            $b = $n.Notification.Visual.GetBinding([Windows.UI.Notifications.KnownNotificationBindings]::ToastGeneric)
            if ($b) {
                $te = $b.GetTextElements()
                if ($te.Count -ge 1) { $row.title = $te[0].Text }
                if ($te.Count -ge 2) { $row.body = ($te | Select-Object -Skip 1 | ForEach-Object { $_.Text }) -join ' / ' }
            }
        } catch { $row.title = 'TEXTREAD THREW: ' + $_.Exception.Message.Trim() }
        if ($row.title -eq $marker) { $r.marker_seen = $true; $markerId = $n.Id }
        $r.toasts += $row
    }

    # -- 5. remove the marker (the dismiss-sync verb), verify the count drops
    $r.step = 'remove'
    if ($r.marker_seen) {
        $listener.RemoveNotification($markerId)
        Start-Sleep -Seconds 1
        $after = Await ($listener.GetNotificationsAsync([Windows.UI.Notifications.NotificationKinds]::Toast)) $nl
        $r.count_after_remove = $after.Count
        $r.removed_ok = -not ($after | Where-Object { $_.Id -eq $markerId })
    }
    $r.step = 'done'
} catch {
    $r.error = $_.Exception.Message.Trim()
}
Write-Output '=== RESULT ==='
$r | ConvertTo-Json -Depth 4 -Compress
