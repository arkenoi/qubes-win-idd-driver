# Deterministic tests for the scheduled-scan debounce. No network and no real Windows Update pass:
# the test HOLDS the global pass mutex, so any run that is NOT debounced falls through to the mutex
# and exits with a different, recognisable message. Debounced vs not is therefore readable from the
# output alone, and neither outcome does any work.
#
# What must hold:
#   A  -Scheduled + a pass that completed just now  -> SKIPPED
#   B  no -Scheduled (dom0-driven), same state      -> NOT skipped   (explicit passes always run)
#   C  -Scheduled + last pass long ago              -> NOT skipped
#   D  -Scheduled + debounce disabled (=0)          -> NOT skipped
#   E  -Scheduled + a completion stamp in the FUTURE-> NOT skipped   (clock moved; do not trust it)
# Emits === RESULT === JSON.
$ErrorActionPreference = 'Continue'
$here   = Split-Path -Parent $MyInvocation.MyCommand.Path
$agent  = Join-Path $here 'qubes-windows-update.ps1'
$tmp    = 'C:\Users\Public\wudebounce'
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$status = Join-Path $tmp 'status.json'
if (-not (Test-Path $agent)) { Write-Output '=== RESULT === {"ok":false,"error":"agent not pushed"}'; exit 1 }

$mx = New-Object System.Threading.Mutex($false, 'Global\QubesWindowsUpdate')
[void]$mx.WaitOne(0)     # hold it: every non-debounced run stops at the mutex, instantly

function Invoke-Case {
    param([bool]$Scheduled, [string]$DoneTs, [string]$DebounceMin)
    ([ordered]@{ phase='done'; done_ts=$DoneTs; action='full' } | ConvertTo-Json) |
        Set-Content -LiteralPath $status -Encoding UTF8
    if ($DebounceMin -ne $null -and $DebounceMin -ne '') { $env:QUBES_UPDATES_DEBOUNCE_MIN = $DebounceMin }
    else { Remove-Item Env:\QUBES_UPDATES_DEBOUNCE_MIN -EA SilentlyContinue }
    $a = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$agent,'-Action','scan',
           '-StatusFile',$status,'-WorkDir',(Join-Path $tmp 'wu'))
    if ($Scheduled) { $a += '-Scheduled' }
    $out = (& powershell.exe @a 2>&1 | Out-String)
    return $out
}
function Was-Debounced([string]$o) { return [bool]($o -match 'skipping this scheduled scan') }
function Hit-Mutex([string]$o)     { return [bool]($o -match 'another Qubes update operation is in progress') }

$now  = (Get-Date).ToString('s')
$old  = (Get-Date).AddHours(-3).ToString('s')
$soon = (Get-Date).AddHours(2).ToString('s')
$r = [ordered]@{}

$a = Invoke-Case -Scheduled $true  -DoneTs $now  -DebounceMin ''
$r['A_scheduled_recent_skipped']      = (Was-Debounced $a)

$b = Invoke-Case -Scheduled $false -DoneTs $now  -DebounceMin ''
$r['B_explicit_not_skipped']          = ((-not (Was-Debounced $b)) -and (Hit-Mutex $b))

$c = Invoke-Case -Scheduled $true  -DoneTs $old  -DebounceMin ''
$r['C_stale_not_skipped']             = ((-not (Was-Debounced $c)) -and (Hit-Mutex $c))

$d = Invoke-Case -Scheduled $true  -DoneTs $now  -DebounceMin '0'
$r['D_disabled_not_skipped']          = ((-not (Was-Debounced $d)) -and (Hit-Mutex $d))

$e = Invoke-Case -Scheduled $true  -DoneTs $soon -DebounceMin ''
$r['E_future_stamp_not_skipped']      = ((-not (Was-Debounced $e)) -and (Hit-Mutex $e))

Remove-Item Env:\QUBES_UPDATES_DEBOUNCE_MIN -EA SilentlyContinue
try { $mx.ReleaseMutex() } catch { }
$r['ok'] = [bool]($r.Values -notcontains $false)
Write-Output ("=== RESULT === " + (($r | ConvertTo-Json -Compress)))
