# toast-hold-fire.ps1 - the toast-hold harness's STIMULUS (mgmt/harness/toast-hold-test.sh), run in the interactive
# USER session through guest/run-as-user.ps1 (mgmt/harness/a0-lib.sh raspush): drives toastfire.exe - pushed to the
# same QubesIncoming directory - through a list of step tokens, and stamps every step with the GUEST'S OWN LOCAL CLOCK
# so the harness can join a fire to the bridge log (GetLocalTime) and, through the clock probe, to the agent log.
#
# TOKENS. Whitespace-separated; a token never contains a space, a comma, a quote, a semicolon or a dollar sign:
# the string rides run-as-user's -ArgsB64 and is then spliced UNQUOTED into a PowerShell wrapper line
# (`& powershell.exe ... -File '<script>' <tokens>`), where whitespace separates tokens and a COMMA would build an
# array (toastfire's arguments are therefore joined with '+').
#   REG:<method>[:<aumid>]     toastfire --register   --method <method> [--aumid <aumid>]
#   UNREG:<method>[:<aumid>]   toastfire --unregister --method <method> [--aumid <aumid>]
#   FIRE:<arg+arg+...>         toastfire <arg> <arg> ...   (e.g. FIRE:--fire+--method+start-shortcut+--class+informational+--title+THT-x+--tag+x)
#   XML:<arg+arg+...>          toastfire --print-xml <arg> ...   (offline payload proof: prints payload_sha256, fires nothing)
#   GAP:<ms>                   Start-Sleep between steps (the quick-succession scenarios)
#   BOGUS                      toastfire --no-such-flag     (the FIRED detector's negative control: a usage error, no FIRED)
#
# OUTPUT (toastfire's own lines verbatim in between; the harness keys on 'FIRED method=' - toastfire.cpp:565 - and
# NOT on a bare 'FIRED', which its usage text also contains):
#   THF step=<i> kind=<register|unregister|fire|xml|bogus|gap> t0=<yyyy-MM-dd HH:mm:ss.fff> args=<arg+arg+...>
#   <toastfire stdout/stderr>
#   THF step=<i> rc=<exit code> t1=<yyyy-MM-dd HH:mm:ss.fff>
#   THF done steps=<n>
# t0 is read immediately before toastfire starts, t1 immediately after it exits: the toast's Show() lies between them.
$ErrorActionPreference = 'Continue'
$exe = Join-Path $PSScriptRoot 'toastfire.exe'

function Get-ThfNow { (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff') }

if (-not (Test-Path -LiteralPath $exe)) {
    Write-Output "THF error=toastfire_not_found path=$exe"
    exit 4
}

$i = 0
foreach ($tok in $args) {
    $i++
    $tok = [string]$tok
    if ($tok -match '^GAP:(\d+)$') {
        $ms = [int]$Matches[1]
        Write-Output "THF step=$i kind=gap ms=$ms t0=$(Get-ThfNow)"
        Start-Sleep -Milliseconds $ms
        Write-Output "THF step=$i rc=0 t1=$(Get-ThfNow)"
        continue
    }
    $kind = ''
    $argv = @()
    if ($tok -match '^(REG|UNREG):([a-z-]+)(?::(.+))?$') {
        $kind = if ($Matches[1] -eq 'REG') { 'register' } else { 'unregister' }
        $method = $Matches[2]
        $aumid = $Matches[3]
        $argv = @("--$kind", '--method', $method)
        if ($aumid) { $argv += @('--aumid', $aumid) }
    } elseif ($tok -match '^FIRE:(.+)$') {
        $kind = 'fire'
        $argv = @($Matches[1] -split '\+')
    } elseif ($tok -match '^XML:(.+)$') {
        $kind = 'xml'
        $argv = @('--print-xml') + @($Matches[1] -split '\+')
    } elseif ($tok -eq 'BOGUS') {
        $kind = 'bogus'
        $argv = @('--no-such-flag')
    } else {
        Write-Output "THF step=$i kind=unknown token=$tok"
        continue
    }
    Write-Output ("THF step=$i kind=$kind t0=$(Get-ThfNow) args=" + ($argv -join '+'))
    & $exe @argv 2>&1 | ForEach-Object { "$_" }
    $rc = $LASTEXITCODE
    Write-Output "THF step=$i rc=$rc t1=$(Get-ThfNow)"
}
Write-Output "THF done steps=$i"
