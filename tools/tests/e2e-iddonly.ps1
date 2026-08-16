$ErrorActionPreference = "Continue"
$out = & cmd.exe /c "C:\QWT-NG\install.cmd /iddonly" 2>&1 | Out-String
Write-Output "=== RESULT ==="
[pscustomobject]@{
    banner      = $(if ($out -match "QWT-NG installer:\s*(.+)") { $Matches[1].Trim() } else { "<none>" })
    filepath_bug= ($out -match "C:\\iddonly")
    needfile_err= ($out -match "is not on this medium")
    tail        = (($out -split "`r?`n") | Where-Object { $_.Trim() } | Select-Object -Last 8) -join " | "
} | ConvertTo-Json -Compress
