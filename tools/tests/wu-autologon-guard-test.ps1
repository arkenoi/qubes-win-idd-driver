<#
.SYNOPSIS
    Offline suite for Protect-Autologon in guest/qubes-windows-update.ps1 - the re-assert of
    Windows autologon before every reboot the updater causes on its task-driven path
    (QubesWindowsUpdateRun, the boot and 6-hourly scans). Runs under pwsh on Linux or Windows
    PowerShell 5.1; no rig, no guest.

.DESCRIPTION
    THE DEFECT (measured 2026-09-17 on win11de-gwt - German Windows 11 25H2, QWT-NG 4.3.29 build
    537; evidence scratchpad/gweck25h2/verify/FINDING-ensure-autologon-wrong-path.txt): the guard
    read ensure-autologon.ps1 from `C:\Program Files\Qubes Tools\vmupdate-shim\`, a directory the
    installer never creates, while the helper is deployed at `<Qubes Tools>\qubes-rpc-services\`
    (guest/install-updater-agent.ps1 copies it there and hard-fails the deploy if it is absent;
    guest/wu-update.ps1 reads that path). So the guard was skipped on EVERY reboot-pending pass and
    logged "reboot staged but ensure-autologon.ps1 is not deployed" for a file that was deployed -
    on all four reboot-pending passes of the Test and Verify stages. A servicing reboot that
    rewrites Winlogon lands the qube on a sign-in screen with no session for qrexec: the lockout
    class AUTOLOGON-IS-ENFORCED exists for.

    The suite extracts the marked WU-AUTOLOGON-GUARD region (the whole function) by its marker
    lines, dot-sources it, and drives it with Log and powershell shadowed, against a real temporary
    <Qubes Tools> layout whose helper sits exactly where the installer puts it:
      deployed-path   reboot pending + helper deployed -> the guard invokes it, once, with -File
                      <the deployed path>; a stage without the reboot flag -> invoked too; with
                      QUBES_TOOLS unset the path is the default root + qubes-rpc-services (named by
                      the WARN, since that file cannot exist on this machine); an absent helper is
                      reported at the deployed location it looked at
      absent          helper absent -> exactly one WARN, the helper is not invoked, the guard returns
      gate            neither a reboot pending nor a stage -> nothing invoked, nothing logged
      shipped         the pre-fix `vmupdate-shim\` path is gone from the code; wu-update.ps1 and
                      the installer name the same qubes-rpc-services location
    Exit 0 = every check matched; 1 = at least one FAIL.

.PARAMETER Defect
    1   the `# GUARD:alpath` line becomes the pre-2026-09-17 literal
        `C:\Program Files\Qubes Tools\vmupdate-shim\ensure-autologon.ps1` in the extracted copy
        (the shipped file is never modified) - the deployed-path checks must FAIL.
    tools/tests/wu-autologon-guard-selftest.sh runs the clean leg and the knob and requires each outcome.
#>
[CmdletBinding()]
param([string]$ScriptPath, [string]$InstallerPath, [string]$HandlerPath, [string]$Defect = '')

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSCommandPath))   # tools/tests/x.ps1 -> repo
if (-not $ScriptPath)    { $ScriptPath    = Join-Path $repoRoot 'guest/qubes-windows-update.ps1' }
if (-not $InstallerPath) { $InstallerPath = Join-Path $repoRoot 'guest/install-updater-agent.ps1' }
if (-not $HandlerPath)   { $HandlerPath   = Join-Path $repoRoot 'guest/wu-update.ps1' }
$ScriptPath    = (Resolve-Path -LiteralPath $ScriptPath).Path
$InstallerPath = (Resolve-Path -LiteralPath $InstallerPath).Path
$HandlerPath   = (Resolve-Path -LiteralPath $HandlerPath).Path

$script:run = 0; $script:fail = 0
function Check([string]$name, [bool]$ok) {
    $script:run++
    if (-not $ok) { $script:fail++ }
    $tag = 'FAIL'
    if ($ok) { $tag = 'ok  ' }
    Write-Host "$tag $name"
}
function CheckEq([string]$name, $got, $want) {
    $script:run++
    $ok = ("$got" -eq "$want")
    if (-not $ok) { $script:fail++ }
    $tag = 'FAIL'
    if ($ok) { $tag = 'ok  ' }
    Write-Host ("{0} {1}" -f $tag, $name)
    if (-not $ok) { Write-Host ("       want [{0}]" -f $want); Write-Host ("       got  [{0}]" -f $got) }
}

# --- extract the function by its marker lines --------------------------------------------------------
$lines = @(Get-Content -LiteralPath $ScriptPath)
function Get-Region([string]$name) {
    $begins = @(0..($lines.Count - 1) | Where-Object { $lines[$_].Trim() -like "# ---- $name-BEGIN*" })
    $ends   = @(0..($lines.Count - 1) | Where-Object { $lines[$_].Trim() -like "# ---- $name-END*" })
    if ($begins.Count -ne 1 -or $ends.Count -ne 1 -or $begins[0] -ge $ends[0]) {
        Write-Host "FAIL marker extraction ${name}: expected exactly one BEGIN before one END, got $($begins.Count)/$($ends.Count)"
        exit 1
    }
    return ,@($lines[($begins[0] + 1)..($ends[0] - 1)])
}
$region = Get-Region 'WU-AUTOLOGON-GUARD'
$guardLines = @($region | Where-Object { $_ -match '# GUARD:alpath$' })
if ($guardLines.Count -ne 1) { Write-Host "FAIL extract: expected exactly 1 '# GUARD:alpath' line in the region, found $($guardLines.Count)"; exit 1 }

switch ($Defect) {
    '' { }
    '1' {
        $region = @($region | ForEach-Object {
            if ($_ -match '# GUARD:alpath$') { "  `$ea = 'C:\Program Files\Qubes Tools\vmupdate-shim\ensure-autologon.ps1'   # DEFECT: the pre-2026-09-17 path" }
            else { $_ } })
    }
    default { Write-Host "FAIL unknown -Defect '$Defect' (1)"; exit 1 }
}

$tmpRoot = Join-Path ([IO.Path]::GetTempPath()) ('wuautologon-ps-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null
# The default-root case computes `C:\Program Files\Qubes Tools\...`, which Join-Path refuses on a
# machine without a C: drive ("Cannot find drive"). Where there is none, map C: onto a scratch
# directory for this session so the shipped line runs unmodified and the helper can be deployed under
# the default root; on a machine with a real C: (Windows) the case reads what the guard computed.
$cRoot = Join-Path $tmpRoot 'cdrive'
New-Item -ItemType Directory -Path $cRoot -Force | Out-Null
$ownC = -not (Get-PSDrive C -EA SilentlyContinue)
if ($ownC) { New-PSDrive -Name C -PSProvider FileSystem -Root $cRoot -Scope Script | Out-Null }
$regionFile = Join-Path $tmpRoot 'guard-region.ps1'
[IO.File]::WriteAllLines($regionFile, [string[]]$region)
. $regionFile
Check 'extract: the region defines Protect-Autologon' ([bool](Get-Command Protect-Autologon -EA SilentlyContinue))

# --- the shipped files, as shipped ------------------------------------------------------------------
$installer = Get-Content -LiteralPath $InstallerPath -Raw
$handler   = Get-Content -LiteralPath $HandlerPath -Raw
$codeLines = @($lines | Where-Object { $_ -notmatch '^\s*#' })
Check 'shipped: the pre-fix `vmupdate-shim\ensure-autologon.ps1` path is gone from the updater''s code' `
      (@($codeLines | Where-Object { $_ -match 'vmupdate-shim\\ensure-autologon' }).Count -eq 0)
Check 'shipped: the guard line derives the path from QUBES_TOOLS + qubes-rpc-services (no new literal drive letter)' `
      ($guardLines[0] -match "Join-Path \`$qt 'qubes-rpc-services\\ensure-autologon\.ps1'" -and
       @($region | Where-Object { $_ -match '\$qt = \$env:QUBES_TOOLS; if \(-not \$qt\) \{ \$qt = ''C:\\Program Files\\Qubes Tools'' \}' }).Count -eq 1)
Check 'shipped: wu-update.ps1 reads the same location (Join-Path $qtRootForAl ''qubes-rpc-services\ensure-autologon.ps1'')' `
      ($handler -match "Join-Path \`$qtRootForAl 'qubes-rpc-services\\ensure-autologon\.ps1'" -and
       $handler -match '\$qtRootForAl = \$env:QUBES_TOOLS; if \(-not \$qtRootForAl\) \{ \$qtRootForAl = ''C:\\Program Files\\Qubes Tools'' \}')
Check 'shipped: the installer deploys the helper to <Qubes Tools>\qubes-rpc-services and hard-fails if it is not there' `
      ($installer -match "\`$handlerDir = Join-Path \`$qt 'qubes-rpc-services'" -and
       $installer -match "Copy-Item \(Join-Path \`$SetupRoot 'ensure-autologon\.ps1'\) \(Join-Path \`$handlerDir 'ensure-autologon\.ps1'\)" -and
       $installer -match "\`$alPath = Join-Path \`$handlerDir 'ensure-autologon\.ps1'" -and
       $installer -match 'if \(-not \(Test-Path \$alPath\)\) \{ throw "autologon guard script missing at \$alPath')
# 2026-09-17: a pass ended by the scheduler (0x41306) had no record of its requester because the
# Task Scheduler operational log is off by default. The installer must enable it - grep-level, by
# its marker: the exact wevtutil call, the before/after state logged, and failure kept a WARN.
Check 'shipped: the installer enables the Task Scheduler operational log (WU-TASKSCHED-OPLOG block: wevtutil sl .../Operational /e:true, before->after logged, failure is a WARN)' `
      ($installer -match '# ---- WU-TASKSCHED-OPLOG' -and
       $installer -match "& wevtutil sl 'Microsoft-Windows-TaskScheduler/Operational' /e:true" -and
       $installer -match 'Log "task scheduler operational log: enabled \$tsBefore -> \$tsAfter"' -and
       $installer -match 'catch \{ Log "WARN: could not enable the Task Scheduler operational log')

# --- the harness: Log and powershell shadowed, a real <Qubes Tools> layout ------------------------------
$script:LogLines = @()
function Log($m, $lvl) { $script:LogLines += [pscustomobject]@{ m = "$m"; lvl = "$lvl" } }
$script:Invocations = @()
function powershell { $script:Invocations += ,@($args); 'SET DefaultPassword (test stub)' }

$qt = Join-Path $tmpRoot 'Qubes Tools'
# The deployed location, built from the installer's own layout: $handlerDir = <root>\qubes-rpc-services,
# helper = <handlerDir>\ensure-autologon.ps1 (asserted on the shipped installer above).
$deployedDir  = Join-Path $qt 'qubes-rpc-services'
$deployedFile = Join-Path $deployedDir 'ensure-autologon.ps1'
New-Item -ItemType Directory -Path $deployedDir -Force | Out-Null
function Deploy-Helper { [IO.File]::WriteAllText($deployedFile, "# stand-in for ensure-autologon.ps1`n") }
function Remove-Helper { Remove-Item -LiteralPath $deployedFile -Force -EA SilentlyContinue }
function Invoke-Guard([bool]$reboot, [bool]$staged, [string]$qubesTools) {
    $script:LogLines = @(); $script:Invocations = @()
    $script:St = @{ reboot_needed = $reboot }
    $script:StagedThisSession = $staged
    if ($null -eq $qubesTools) { Remove-Item Env:QUBES_TOOLS -EA SilentlyContinue } else { $env:QUBES_TOOLS = $qubesTools }
    Protect-Autologon
    return [pscustomobject]@{
        invoked = @($script:Invocations)
        warns   = @($script:LogLines | Where-Object { $_.lvl -eq 'WARN' })
        log     = @($script:LogLines)
    }
}
function Get-FileArg($argv) { $i = [Array]::IndexOf([object[]]$argv, '-File'); if ($i -ge 0 -and $i + 1 -lt $argv.Count) { return "$($argv[$i + 1])" }; return '' }
# Provider paths on both sides, so a path through the C: mapping compares equal to its real location.
function Same-Path([string]$a, [string]$b) {
    if (-not $a -or -not $b) { return $false }
    $pa = try { Convert-Path -LiteralPath $a } catch { $a }
    $pb = try { Convert-Path -LiteralPath $b } catch { $b }
    return ($pa -eq $pb)
}

# --- 1. deployed path, reboot pending ---------------------------------------------------------------
Deploy-Helper
$r = Invoke-Guard $true $false $qt
CheckEq 'deployed-path: reboot pending, helper deployed - the guard invokes it exactly once' $r.invoked.Count 1
Check   'deployed-path: reboot pending, helper deployed - the guard invokes it (powershell -File <deployed path>)' `
        ($r.invoked.Count -eq 1 -and (Same-Path (Get-FileArg $r.invoked[0]) $deployedFile))
Check   'deployed-path: the invocation is non-interactive with the execution policy bypassed' `
        ($r.invoked.Count -eq 1 -and @($r.invoked[0]) -contains '-NonInteractive' -and @($r.invoked[0]) -contains '-NoProfile' -and
         ([Array]::IndexOf([object[]]$r.invoked[0], '-ExecutionPolicy') -ge 0) -and @($r.invoked[0]) -contains 'Bypass')
Check   'deployed-path: the helper''s output reaches the log as "  autologon: ..." lines' `
        (@($r.log | Where-Object { $_.m -eq '  autologon: SET DefaultPassword (test stub)' }).Count -eq 1)
CheckEq 'deployed-path: no WARN when the helper is deployed' $r.warns.Count 0

# --- 2. deployed path, a stage this session without the reboot flag ---------------------------------
$r = Invoke-Guard $false $true $qt
Check   'deployed-path: a stage this session without reboot_needed still invokes the guard' `
        ($r.invoked.Count -eq 1 -and (Same-Path (Get-FileArg $r.invoked[0]) $deployedFile))

# --- 3. helper absent -------------------------------------------------------------------------------
Remove-Helper
$r = Invoke-Guard $true $false $qt
CheckEq 'absent: helper absent - exactly one WARN' $r.warns.Count 1
CheckEq 'absent: helper absent - the helper is not invoked' $r.invoked.Count 0
Check   'absent: the WARN says the guard is missing and that autologon may be consumed' `
        ($r.warns.Count -eq 1 -and $r.warns[0].m -like 'reboot staged but ensure-autologon.ps1 is missing at * - autologon may be consumed by the coming reboots')
Check   'deployed-path: absent helper - the WARN names the deployed location it looked at' `
        ($r.warns.Count -eq 1 -and $r.warns[0].m -match [regex]::Escape($deployedFile))

# --- 4. the gate ------------------------------------------------------------------------------------
Deploy-Helper
$r = Invoke-Guard $false $false $qt
CheckEq 'gate: neither reboot pending nor a stage - nothing invoked' $r.invoked.Count 0
CheckEq 'gate: neither reboot pending nor a stage - nothing logged' $r.log.Count 0

# --- 5. QUBES_TOOLS unset: the default root, same subdirectory -----------------------------------------
if ($ownC) {
    # C: is this session's mapping: deploy the helper where the installer would under the default root
    # and require the guard to find and invoke it there.
    $defaultFile = Join-Path (Join-Path (Join-Path $cRoot 'Program Files') 'Qubes Tools') 'qubes-rpc-services'
    New-Item -ItemType Directory -Path $defaultFile -Force | Out-Null
    $defaultFile = Join-Path $defaultFile 'ensure-autologon.ps1'
    [IO.File]::WriteAllText($defaultFile, "# stand-in for ensure-autologon.ps1 (default root)`n")
    $r = Invoke-Guard $true $false $null
    Check 'deployed-path: QUBES_TOOLS unset - the guard finds and invokes the helper under the default root at qubes-rpc-services' `
          ($r.invoked.Count -eq 1 -and $r.warns.Count -eq 0 -and (Same-Path (Get-FileArg $r.invoked[0]) $defaultFile))
} else {
    # A real C: drive: whether or not a helper is installed on this machine, the path the guard
    # computed is visible in the invocation or in the WARN, and must be the deployed location.
    $r = Invoke-Guard $true $false $null
    $got = if ($r.invoked.Count -eq 1) { Get-FileArg $r.invoked[0] }
           elseif ($r.warns.Count -eq 1 -and $r.warns[0].m -match 'missing at (.+?) - autologon') { $Matches[1] }
           else { "<invoked=$($r.invoked.Count) warns=$($r.warns.Count)>" }
    CheckEq 'deployed-path: QUBES_TOOLS unset - the guard looks under the default root at qubes-rpc-services' `
            $got 'C:\Program Files\Qubes Tools\qubes-rpc-services\ensure-autologon.ps1'
}
$env:QUBES_TOOLS = $qt
if ($ownC) { Remove-PSDrive -Name C -Force -EA SilentlyContinue }

Remove-Item -LiteralPath $tmpRoot -Recurse -Force -EA SilentlyContinue
Write-Host ("--- {0} checks, {1} failed{2}" -f $script:run, $script:fail, $(if ($Defect) { " (defect knob: $Defect)" } else { '' }))
if ($script:fail -gt 0) { exit 1 }
exit 0
