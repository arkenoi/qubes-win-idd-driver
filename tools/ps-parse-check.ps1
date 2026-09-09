<#
.SYNOPSIS
    Parse every PowerShell file we ship and FAIL on a syntax error.

.DESCRIPTION
    Until 2026-09-09 nothing in this repo had ever parsed a .ps1. The scripts are authored in a
    Linux dev qube and only ever executed on a Windows guest, so a syntax error was discovered by
    an acceptance cell failing - minutes of guest time per attempt - or, worse, by a stage that
    swallowed the error. Microsoft ships a self-contained PowerShell for linux-x64, so the parser
    is available here and this costs about a second.

    It is a SYNTAX check, not a semantic one: it uses the same parser PowerShell itself uses, so a
    file that parses clean can still be wrong at runtime. It catches exactly the class it claims -
    unbalanced braces, a malformed hashtable literal, an if/else used as an expression where the
    parser will not take one - which is the class that costs a whole acceptance cell to find.

    Excludes upstream/ (not ours), scratchpad/ and evidence/ (gitignored working files) and
    mgmt/prime-jobs/ (staging leftovers copied out of a built package, not source).

.PARAMETER Path
    Root to scan. Defaults to the repo root inferred from this script's location.
#>
[CmdletBinding()]
param([string]$Path)

$ErrorActionPreference = 'Stop'
if (-not $Path) { $Path = Split-Path -Parent (Split-Path -Parent $PSCommandPath) }
$root = (Resolve-Path -LiteralPath $Path).Path

$files = @(Get-ChildItem -LiteralPath $root -Recurse -Filter *.ps1 -File -ErrorAction SilentlyContinue |
           Where-Object { $_.FullName -notmatch '[\\/](upstream|scratchpad|evidence|\.git)[\\/]' -and
                          $_.FullName -notmatch '[\\/]mgmt[\\/]prime-jobs[\\/]' })

# MISSING DATA FAILS. Finding no files means the scan is broken (wrong root, bad filter), not that
# the repo is clean - and a checker that reports success when it examined nothing is the exact
# failure this repo keeps paying for.
if ($files.Count -eq 0) {
    Write-Host "FATAL: no .ps1 files found under $root - the scan is broken, not the repo clean"
    exit 2
}

$bad = 0
foreach ($f in $files) {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errors)
    if ($errors -and $errors.Count -gt 0) {
        $bad++
        $rel = $f.FullName.Substring($root.Length).TrimStart('/', '\')
        Write-Host "FAIL  $rel"
        foreach ($e in ($errors | Select-Object -First 5)) {
            Write-Host ("        line {0}: {1}" -f $e.Extent.StartLineNumber, $e.Message)
        }
    }
}

Write-Host ("--- parsed {0} file(s), {1} with syntax errors" -f $files.Count, $bad)
if ($bad -gt 0) { exit 1 }
exit 0
