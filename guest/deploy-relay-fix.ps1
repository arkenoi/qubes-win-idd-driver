# Install the relay + updater honesty fixes on this guest, and PROVE the install rather than
# assuming it. Idempotent: safe to re-run. Emits === RESULT === JSON.
#
# Deploys:
#   qubes-updates-relay.cs  -> compiled in-box (csc) to  <QubesTools>\bin\qubes-updates-relay.exe
#   qubes-windows-update.ps1 -> copied to                <QubesTools>\bin\qubes-windows-update.ps1
# Then runs the relay's --selftest, which is the actual acceptance gate: it fails on a build that
# still truncates at MaxVerifyBytes or judges completeness from Content-Length alone.
$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$bin  = 'C:\Program Files\Qubes Tools\bin'
$res  = [ordered]@{}

$res['vm'] = $env:COMPUTERNAME
$res['elevated'] = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
                   ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not (Test-Path $bin)) { $res['error'] = "no Qubes Tools bin at $bin"; $res['ok']=$false
                             Write-Output ("=== RESULT === " + ($res | ConvertTo-Json -Compress)); exit 1 }

# --- relay ---
$src = Join-Path $here 'qubes-updates-relay.cs'
$exe = Join-Path $bin  'qubes-updates-relay.exe'
if (-not (Test-Path $src)) { $res['error'] = "source not pushed: $src"; $res['ok']=$false
                             Write-Output ("=== RESULT === " + ($res | ConvertTo-Json -Compress)); exit 1 }
$res['exe_before'] = if (Test-Path $exe) { (Get-FileHash $exe -Algorithm SHA256).Hash.Substring(0,16) } else { 'none' }
# A relay that is serving belongs to a running updater pass (started by it, relaunched by its task) -
# NOT this script's to end (owner 2026-10-07: never by name). It is reported by its PORT owner; a
# locked target exe then fails the compile loudly below instead of being "freed" by a kill.
$owner = 0
try { $l = @(Get-NetTCPConnection -LocalPort 8082 -State Listen -ErrorAction SilentlyContinue); if ($l.Count) { $owner = [int]$l[0].OwningProcess } } catch { $owner = -1 }
$res['relay_port_owner'] = $owner
if ($owner -ne 0) { $res['relay_warning'] = "port 8082 is served by pid $owner (a running pass's relay; not stopped) - end that pass (schtasks /end /tn QubesWindowsUpdateScan or QubesWindowsUpdateRun) if the exe turns out locked" }
$csc = Get-ChildItem 'C:\Windows\Microsoft.NET\Framework64\v4.0.*\csc.exe' -EA SilentlyContinue | Select-Object -First 1
if (-not $csc) { $csc = Get-ChildItem 'C:\Windows\Microsoft.NET\Framework\v4.0.*\csc.exe' -EA SilentlyContinue | Select-Object -First 1 }
if (-not $csc) { $res['error']='no in-box csc.exe'; $res['ok']=$false
                 Write-Output ("=== RESULT === " + ($res | ConvertTo-Json -Compress)); exit 1 }
$cscOut = & $csc.FullName /nologo /o /target:exe "/out:$exe" "$src" 2>&1
$res['compile_output'] = (($cscOut | Out-String).Trim() -replace '\s+',' ')
$res['exe_exists'] = Test-Path $exe
if (Test-Path $exe) {
  $h = Get-FileHash $exe -Algorithm SHA256 -EA SilentlyContinue
  $res['exe_after'] = if ($h -and $h.Hash) { $h.Hash.Substring(0,16) } else { 'UNREADABLE' }
  $res['exe_size']  = (Get-Item $exe).Length
  $res['exe_changed'] = ($res['exe_before'] -ne $res['exe_after'])
}

# --- updater ---
$upSrc = Join-Path $here 'qubes-windows-update.ps1'
$upDst = Join-Path $bin  'qubes-windows-update.ps1'
if (Test-Path $upSrc) {
  $res['ps1_before'] = if (Test-Path $upDst) { (Get-FileHash $upDst -Algorithm SHA256).Hash.Substring(0,16) } else { 'none' }
  Copy-Item -LiteralPath $upSrc -Destination $upDst -Force -EA SilentlyContinue
  $res['ps1_after'] = if (Test-Path $upDst) { (Get-FileHash $upDst -Algorithm SHA256).Hash.Substring(0,16) } else { 'FAILED' }
  $res['ps1_changed'] = ($res['ps1_before'] -ne $res['ps1_after'])
  # the guard fixes must actually be in the installed copy
  $res['ps1_has_workdir_log'] = [bool](Select-String -Path $upDst -Pattern 'Join-Path \$WorkDir .qubes-updates-relay\.log.' -Quiet -EA SilentlyContinue)
  $res['ps1_has_unknown']     = [bool](Select-String -Path $upDst -Pattern 'return -1' -Quiet -EA SilentlyContinue)
  $res['ps1_has_partial']     = [bool](Select-String -Path $upDst -Pattern 'SCAN PARTIAL' -Quiet -EA SilentlyContinue)
} else { $res['ps1_after'] = 'not pushed' }

# --- acceptance: the framing contract must hold in the binary we just installed ---
$selftest = & $exe --selftest 2>&1
$res['selftest_exit'] = $LASTEXITCODE
$res['selftest_pass'] = @($selftest | Select-String -Pattern '^PASS ' -EA SilentlyContinue).Count
$res['selftest_fail'] = @($selftest | Select-String -Pattern '^FAIL ' -EA SilentlyContinue).Count

$res['ok'] = ($res['exe_exists'] -and $res['selftest_exit'] -eq 0 -and $res['selftest_fail'] -eq 0)
$line = "=== RESULT === " + ($res | ConvertTo-Json -Compress)
Write-Output $line
# ALSO to a file. On a guest busy with servicing, qrexec gets starved and a live pushrun dies
# mid-run taking its output with it - which is exactly how win11-fresh reported an EMPTY result
# on 2026-08-20 while the deploy may or may not have happened. A file survives the connection, so
# the deploy can be run detached (scheduled task) and the outcome collected afterwards.
try {
    New-Item -ItemType Directory -Force -Path 'C:\ProgramData\Qubes' | Out-Null
    $line | Set-Content -LiteralPath 'C:\ProgramData\Qubes\deploy-relay-fix.txt' -Encoding ASCII
} catch { }
