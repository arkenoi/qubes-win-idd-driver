# END-TO-END, the reporter's exact scenario: C:\QWT-NG\install.cmd /iddoff on a guest whose
# desktop is currently on the IDD. Asserts real OUTCOMES (device state, adapter), not log lines.
$ErrorActionPreference = "Continue"
$tgz = "C:\Users\user\Documents\QubesIncoming\win-idd-mgmt\qwtng.tgz"
$dir = "C:\QWT-NG"
Remove-Item $dir -Recurse -Force -EA SilentlyContinue
New-Item -ItemType Directory -Path $dir -Force | Out-Null
& tar.exe -xzf $tgz -C "C:\" 2>&1 | Out-Null
if (Test-Path "C:\qwtng") { Get-ChildItem "C:\qwtng" | Move-Item -Destination $dir -Force; Remove-Item "C:\qwtng" -Recurse -Force }

function Adapters {
    Get-CimInstance Win32_VideoController | ForEach-Object { "$($_.Name)=$($_.Status)" }
}
$before = @(Adapters) -join ";"
$iddBefore = [bool](Get-PnpDevice -Class Display -EA SilentlyContinue | Where-Object { $_.FriendlyName -match "IddSample" })

# the banner (Gate 0) and the run itself
$out = & cmd.exe /c "`"$dir\install.cmd`" /iddoff" 2>&1 | Out-String

Write-Output "=== RESULT ==="
[pscustomobject]@{
    banner_version = $(if ($out -match "QWT-NG installer:\s*(.+)") { $Matches[1].Trim() } else { "<none>" })
    banner_from    = $(if ($out -match "Running from:\s*(.+)")    { $Matches[1].Trim() } else { "<none>" })
    stale_warning  = ($out -match "WARNING: no MANIFEST.json")
    said_notelev   = ($out -match "Not elevated")
    filepath_bug   = ($out -match "C:\\iddoff")
    needfile_err   = ($out -match "is not on this medium")
    adapters_before= $before
    idd_before     = $iddBefore
    exit_seen      = $(if ($out -match "(?m)^FAILED with (\d+)") { $Matches[1] } else { "" })
    tail           = (($out -split "`r?`n") | Where-Object { $_.Trim() } | Select-Object -Last 12) -join " | "
} | ConvertTo-Json -Compress
