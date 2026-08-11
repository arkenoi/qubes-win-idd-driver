# Fire a PERSISTENT (reminder-scenario) toast in the interactive session via scheduled task.
# The reminder scenario keeps the banner on screen until dismissed, giving a stable shell
# surface for drag-under-toast measurements. Prints === RESULT === JSON.
param([string]$Title = 'QWT DRAG TEST', [string]$Body = 'persistent reminder toast')
$ErrorActionPreference = 'Continue'
$work = 'C:\toastprobe'
New-Item -ItemType Directory -Force $work | Out-Null

@"
`$AppId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
[void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType=WindowsRuntime]
[void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType=WindowsRuntime]
`$xmlText = @'
<toast scenario="reminder">
  <visual><binding template="ToastGeneric">
    <text>$Title</text>
    <text>$Body</text>
  </binding></visual>
  <actions>
    <action content="OK" arguments="ok"/>
    <action content="Later" arguments="later"/>
  </actions>
</toast>
'@
`$xml = New-Object Windows.Data.Xml.Dom.XmlDocument
`$xml.LoadXml(`$xmlText)
[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier(`$AppId).Show([Windows.UI.Notifications.ToastNotification]::new(`$xml))
Set-Content '$work\fired.txt' 'fired'
"@ | Set-Content "$work\fire-persist.ps1" -Encoding ASCII

Remove-Item "$work\fired.txt" -ErrorAction SilentlyContinue
& schtasks /create /tn QwtToastFire /tr "powershell -NoProfile -ExecutionPolicy Bypass -File $work\fire-persist.ps1" /sc once /st 00:00 /ru user /it /f *>&1 | Out-Null
& schtasks /run /tn QwtToastFire *>&1 | Out-Null
$fired = $false
for ($i = 0; $i -lt 20; $i++) { Start-Sleep 1; if (Test-Path "$work\fired.txt") { $fired = $true; break } }
& schtasks /delete /tn QwtToastFire /f *>&1 | Out-Null
Write-Output '=== RESULT ==='
@{ fired = $fired } | ConvertTo-Json
