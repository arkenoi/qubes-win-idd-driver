# Did the plain-HTTP verify+retry path actually engage, and what did it see?
# Answers the question the full-pass failure raises: the CTL fetch either never reached the relay
# (so the retry could not help) or it did and still failed. Quoting this through qtest/cmd fails on
# the pipes and quotes, hence a script.
$ErrorActionPreference = 'Continue'
$log = 'C:\ProgramData\Qubes\wu\qubes-updates-relay.log'
Write-Output '=== RESULT ==='
if (-not (Test-Path $log)) { Write-Output 'no relay log'; exit 1 }
$lines = @(Get-Content $log -EA SilentlyContinue)
Write-Output ("total lines      = {0}" -f $lines.Count)
$plain = @($lines | Where-Object { $_ -match 'PLAIN' })
$ctldl = @($lines | Where-Object { $_ -match 'ctldl' })
$deny  = @($lines | Where-Object { $_ -match 'DENY' })
Write-Output ("PLAIN lines      = {0}   (verify/retry path engaged)" -f $plain.Count)
Write-Output ("ctldl requests   = {0}" -f $ctldl.Count)
Write-Output ("DENY lines       = {0}" -f $deny.Count)
Write-Output '--- first PLAIN lines ---'
foreach ($l in ($plain | Select-Object -First 10)) { Write-Output ("  " + $l) }
Write-Output '--- any ctldl activity ---'
foreach ($l in ($ctldl | Select-Object -First 6)) { Write-Output ("  " + $l.Substring(0, [Math]::Min(150, $l.Length))) }
Write-Output '--- denied hosts (allowlist) ---'
foreach ($l in ($deny | Select-Object -First 6)) { Write-Output ("  " + $l.Substring(0, [Math]::Min(120, $l.Length))) }
