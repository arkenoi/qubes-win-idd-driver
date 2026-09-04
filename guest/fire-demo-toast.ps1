# fire-demo-toast.ps1 — fire ONE toast of a chosen class, in the interactive user session
# (run via run-as-user.ps1). Fixture for the toast-bridge A0 acceptance (mgmt/harness/
# a0-toast-bridge.sh) and the DESIGN-toast-bridge split: -RealChoice fires the window-path
# class (reminder scenario + buttons), default fires the informational class (ToastGeneric,
# no actions). The bridge itself is notifhost.exe --bridge (the retired PS spike was
# guest/toast-bridge.ps1).
param(
    [string]$Aumid = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe',
    [string]$Title = 'demo toast',
    [string]$Body = 'demo body',
    [switch]$RealChoice,
    # -Persistent: use scenario=reminder so the toast STAYS on screen until dismissed. A default
    # toast lives ~5s, but the rig's whole-desktop window capture (local.WinFullScreen) takes ~59s
    # per call, so a transient toast is gone before any snapshot aligns and its o-r window is never
    # caught (the 2026-09-04 false P2/P6/P8 window-path failures). Persistence lets a slow capture
    # catch it. Routing is unaffected: A0 classifies per-APP (by AUMID), NOT by scenario/content, so
    # a persistent informational toast from an allowlisted AUMID still bridges. (A future per-TOAST
    # Phase 3 WOULD read scenario=reminder as a window-path signal - a persistent-toast harness would
    # need content-pure toasts then; noted so it is not a silent trap later.)
    [switch]$Persistent
)
$ErrorActionPreference = 'Stop'
[void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType=WindowsRuntime]
[void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType=WindowsRuntime]
$esc = { param($s) $s -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;' }
$t = & $esc $Title; $b = & $esc $Body
if ($RealChoice) {
    # real-choice class: reminder + buttons (inherently persistent; the window-path control)
    $x = "<toast scenario=""reminder""><visual><binding template=""ToastGeneric""><text>$t</text><text>$b</text></binding></visual><actions><action content=""OK"" arguments=""ok""/><action content=""Later"" arguments=""later""/></actions></toast>"
} elseif ($Persistent) {
    # informational content, made persistent for detection (reminder needs one action to stay up)
    $x = "<toast scenario=""reminder""><visual><binding template=""ToastGeneric""><text>$t</text><text>$b</text></binding></visual><actions><action content=""OK"" arguments=""ok""/></actions></toast>"
} else {
    # transient informational (the true buttonless class; used where detection is via bridge.log)
    $x = "<toast><visual><binding template=""ToastGeneric""><text>$t</text><text>$b</text></binding></visual></toast>"
}
$xml = New-Object Windows.Data.Xml.Dom.XmlDocument
$xml.LoadXml($x)
$notif = [Windows.UI.Notifications.ToastNotification]::new($xml)
# Unique per-fire Tag+Group so Windows never coalesces two same-AUMID test toasts into one
# notification slot. A same-tag toast REPLACES the prior one and is not re-raised to
# UserNotificationListener as a NEW id, which would make a genuine forward read as sent=no (the
# P4a suspect: warmup + check toast, same AUMID, no tag). Tag/Group cap at 64 chars.
$uniq = [guid]::NewGuid().ToString('N').Substring(0, 16)
$notif.Tag = $uniq
$notif.Group = 'a0tb'
[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($Aumid).Show($notif)
Write-Output ("FIRED class={0} aumid={1} title='{2}' tag={3}" -f $(if ($RealChoice) {'realchoice'} else {'informational'}), $Aumid, $Title, $uniq)
