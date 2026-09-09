<#
.SYNOPSIS
    Check every shipped .ps1 for syntax that Windows PowerShell 5.1 cannot parse.

.DESCRIPTION
    tools/ps-parse-check.ps1 parses with the PowerShell 7 parser available on Linux. That is a
    FALSE PASS in the direction that matters: 7.x accepts syntax 5.1 rejects, so a script using a
    ternary, ??, ??= or a && / || pipeline chain parses clean in the dev qube and is a SYNTAX ERROR
    on the guest. The guests run Windows PowerShell 5.1 - every invocation in this repo is
    `powershell` / `powershell.exe` (129 of them) and never `pwsh` - so 5.1 is the only target that
    counts.

    This closes that gap using PSScriptAnalyzer's PSUseCompatibleSyntax rule, which knows each
    version's grammar rather than guessing from the local parser.

    Run BOTH checks: parse-check catches what is broken everywhere, compat-check catches what is
    broken only where it runs. Neither subsumes the other.

    Requires PSScriptAnalyzer (no sudo):
        Install-Module PSScriptAnalyzer -Scope CurrentUser -Force -AcceptLicense
    Set TMPDIR to real disk first - /tmp here is a 1 GB tmpfs and the module's compatibility
    profiles will not fit ("No space left on device", measured 2026-09-09).

.PARAMETER Path
    Root to scan. Defaults to the repo root inferred from this script's location.

.PARAMETER TargetVersion
    PowerShell version the scripts must be parseable by. Defaults to 5.1, which is what ships in
    Windows 10 and 11. Do not raise this without changing how the guest invokes the scripts.
#>
[CmdletBinding()]
param(
    [string]$Path,
    [string]$TargetVersion = '5.1'
)

$ErrorActionPreference = 'Stop'
if (-not $Path) { $Path = Split-Path -Parent (Split-Path -Parent $PSCommandPath) }
$root = (Resolve-Path -LiteralPath $Path).Path

if (-not (Get-Module -ListAvailable -Name PSScriptAnalyzer)) {
    # Absent is NOT a pass. Say so and exit non-zero: a compatibility gate that silently skips is
    # how a 7-only construct reaches a guest.
    Write-Host 'FATAL: PSScriptAnalyzer is not installed - the 5.1 compatibility check DID NOT RUN.'
    Write-Host '  TMPDIR=/home/user/tmp pwsh -NoProfile -Command "Install-Module PSScriptAnalyzer -Scope CurrentUser -Force -AcceptLicense"'
    exit 2
}
Import-Module PSScriptAnalyzer -ErrorAction Stop

$files = @(Get-ChildItem -LiteralPath $root -Recurse -Filter *.ps1 -File -ErrorAction SilentlyContinue |
           Where-Object { $_.FullName -notmatch '[\\/](upstream|scratchpad|evidence|\.git)[\\/]' -and
                          $_.FullName -notmatch '[\\/]mgmt[\\/]prime-jobs[\\/]' })

if ($files.Count -eq 0) {
    Write-Host "FATAL: no .ps1 files found under $root - the scan is broken, not the repo clean"
    exit 2
}

$settings = @{ Rules = @{ PSUseCompatibleSyntax = @{ Enable = $true; TargetVersions = @($TargetVersion) } } }

$bad = 0
foreach ($f in $files) {
    $findings = @(Invoke-ScriptAnalyzer -Path $f.FullName -Settings $settings `
                      -IncludeRule PSUseCompatibleSyntax -ErrorAction SilentlyContinue)
    if ($findings.Count -gt 0) {
        $bad++
        $rel = $f.FullName.Substring($root.Length).TrimStart('/', '\')
        Write-Host "INCOMPATIBLE  $rel"
        foreach ($d in $findings) {
            Write-Host ("        line {0}: {1}" -f $d.Line, $d.Message)
        }
    }
}

Write-Host ("--- checked {0} file(s) against PowerShell {1}, {2} incompatible" -f $files.Count, $TargetVersion, $bad)
if ($bad -gt 0) { exit 1 }
exit 0
