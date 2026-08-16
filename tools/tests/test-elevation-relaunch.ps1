# Gate 2 regression: the UAC relaunch must name install.cmd itself, for EVERY switch.
# Runs the REAL install.cmd under the dry-run hook, then re-introduces the %~f0 defect in a copy
# and requires the SAME check to FAIL there (CLAUDE.md: a check counts only once seen to fail).
$ErrorActionPreference = "Continue"
$src = "C:\Users\user\Documents\QubesIncoming\win-idd-mgmt\install.cmd"
if (!(Test-Path $src)) { Write-Output "=== RESULT ==="; '{"error":"install.cmd not pushed"}'; exit }

$dir = "C:\elevtest"; Remove-Item $dir -Recurse -Force -EA SilentlyContinue
New-Item -ItemType Directory -Path $dir -Force | Out-Null
$good = Join-Path $dir "install.cmd"
Copy-Item $src $good -Force

# the defect, re-introduced: read %~f0 after the parse loop instead of %SELF%
$bad = Join-Path $dir "install-broken.cmd"
(Get-Content -LiteralPath $good -Raw) -replace 'ELEVATE-FILEPATH=\[%SELF%\]', 'ELEVATE-FILEPATH=[%~f0]' |
    Set-Content -LiteralPath $bad -Encoding ASCII

$switches = @('/iddoff','/idd','/noidd','/iddonly','/updatesonly','/noupdates','/nonet','/nodisk',
              '/noapptweaks','/reboot','/acceptpvdiskupgrade','/auto')
$env:QWT_ELEVATE_DRYRUN = "1"

function Probe([string]$script, [string]$sw) {
    $out = & cmd.exe /c "`"$script`" $sw" 2>&1 | Out-String
    if ($out -match 'ELEVATE-FILEPATH=\[([^\]]*)\]') { return $Matches[1] }
    return "<no-relaunch>"
}

$goodFails = @(); $badFails = @()
foreach ($sw in $switches) {
    $g = Probe $good $sw
    if ($g -ne $good) { $goodFails += "$sw -> $g" }
    # The defect must reproduce SPECIFICALLY: drive root + the switch name, e.g. C:\iddoff.
    # "anything other than the script path" would also match <no-relaunch> and make this
    # check unfailable - the exact trap that let the bug ship.
    $b = Probe $bad $sw
    $want = "{0}\{1}" -f (Split-Path -Qualifier $bad), $sw.TrimStart('/')
    if ($b -ne $want) { $badFails += "$sw expected[$want] got[$b]" }
}
# and the zero-argument form, which always worked and must keep working
$g0 = Probe $good ""
$sample = Probe $bad '/iddoff'          # capture BEFORE cleanup, else it reads <no-relaunch>
Remove-Item $dir -Recurse -Force -EA SilentlyContinue

Write-Output "=== RESULT ==="
[pscustomobject]@{
    switches_tested   = $switches.Count
    fixed_wrong       = $goodFails            # must be empty
    defect_not_reproduced = $badFails         # must be empty, else the check cannot fail
    defect_sample     = $sample
    noargs_path_ok    = ($g0 -eq $good)
    PASS              = ($goodFails.Count -eq 0 -and $badFails.Count -eq 0 -and $g0 -eq $good)
} | ConvertTo-Json -Compress
