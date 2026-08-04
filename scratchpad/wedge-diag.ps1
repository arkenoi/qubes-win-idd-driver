# Diagnose the Transient wedges: was the guest slow to shut down, or did it crash?
$ErrorActionPreference = 'Continue'
Write-Output "=== boot / shutdown events (last 3h) ==="
Get-WinEvent -FilterHashtable @{LogName='System'; StartTime=(Get-Date).AddHours(-3)} -ErrorAction SilentlyContinue |
  Where-Object { $_.Id -in 1074,6005,6006,6008,41,12,13 } |
  Sort-Object TimeCreated |
  ForEach-Object {
    $first = ($_.Message -split "`r?`n")[0]
    if ($first.Length -gt 90) { $first = $first.Substring(0,90) }
    Write-Output ("{0}  id={1,-5} {2}" -f $_.TimeCreated.ToString('HH:mm:ss'), $_.Id, $first)
  }

Write-Output ""
Write-Output "=== interpretation keys ==="
Write-Output "6006 = clean shutdown (event log stopped)   6005 = boot (event log started)"
Write-Output "6008 = PREVIOUS shutdown was UNEXPECTED     41   = kernel power, unclean"
Write-Output "1074 = something requested the shutdown     12/13 = OS start / OS shutdown"

Write-Output ""
Write-Output "=== how long did the last shutdowns take? (13 -> next 12) ==="
$se = Get-WinEvent -FilterHashtable @{LogName='System'; StartTime=(Get-Date).AddHours(-6); Id=12,13} -ErrorAction SilentlyContinue | Sort-Object TimeCreated
for ($i = 0; $i -lt $se.Count - 1; $i++) {
  if ($se[$i].Id -eq 13 -and $se[$i+1].Id -eq 12) {
    $gap = ($se[$i+1].TimeCreated - $se[$i].TimeCreated).TotalSeconds
    Write-Output ("shutdown {0} -> boot {1} : {2:N0}s down" -f $se[$i].TimeCreated.ToString('HH:mm:ss'), $se[$i+1].TimeCreated.ToString('HH:mm:ss'), $gap)
  }
}

Write-Output ""
Write-Output "=== services that block shutdown / pending reboot ==="
Write-Output ("PendingFileRename: " + [bool](Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue))
Write-Output ("RebootPending: " + (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'))
Write-Output ("WU RebootRequired: " + (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'))
Write-Output ("Uptime: " + [Math]::Round(((Get-Date) - (Get-CimInstance Win32_OperatingSystem).LastBootUpTime).TotalMinutes,1) + " min")
Write-Output ("LoggedOnUser: " + (Get-CimInstance Win32_ComputerSystem).UserName)
