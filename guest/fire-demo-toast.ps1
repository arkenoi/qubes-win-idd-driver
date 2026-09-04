# fire-demo-toast.ps1 — fire ONE toast of a chosen class, in the interactive user session
# (run via run-as-user.ps1). Companion to toast-bridge.ps1 demos and the DESIGN-toast-bridge
# split: -RealChoice fires the window-path class (reminder scenario + buttons), default fires
# the informational class (ToastGeneric, no actions).
param(
    [string]$Aumid = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe',
    [string]$Title = 'demo toast',
    [string]$Body = 'demo body',
    [switch]$RealChoice
)
$ErrorActionPreference = 'Stop'
[void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType=WindowsRuntime]
[void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType=WindowsRuntime]
$esc = { param($s) $s -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;' }
$t = & $esc $Title; $b = & $esc $Body
if ($RealChoice) {
    $x = "<toast scenario=""reminder""><visual><binding template=""ToastGeneric""><text>$t</text><text>$b</text></binding></visual><actions><action content=""OK"" arguments=""ok""/><action content=""Later"" arguments=""later""/></actions></toast>"
} else {
    $x = "<toast><visual><binding template=""ToastGeneric""><text>$t</text><text>$b</text></binding></visual></toast>"
}
$xml = New-Object Windows.Data.Xml.Dom.XmlDocument
$xml.LoadXml($x)
[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($Aumid).Show(
    [Windows.UI.Notifications.ToastNotification]::new($xml))
Write-Output ("FIRED class={0} aumid={1} title='{2}'" -f $(if ($RealChoice) {'realchoice'} else {'informational'}), $Aumid, $Title)
