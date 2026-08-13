# Parse-check PowerShell files without executing them. A parse error in the updater would break
# updating entirely and only show up at the worst moment, so this runs before every deploy.
# Usage: ps-syntax-check.ps1 [-Dir <folder>]  (defaults to this script's folder)
param([string]$Dir = $PSScriptRoot)
$ErrorActionPreference = 'Continue'
$bad = 0
foreach ($f in Get-ChildItem -LiteralPath $Dir -Filter *.ps1 | Sort-Object Name) {
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$errors)
    if ($errors -and $errors.Count) {
        $bad++
        Write-Output "FAIL $($f.Name)"
        foreach ($e in ($errors | Select-Object -First 3)) {
            Write-Output ("   line $($e.Extent.StartLineNumber): $($e.Message)")
        }
    } else {
        Write-Output "ok   $($f.Name)"
    }
}
Write-Output '=== RESULT ==='
Write-Output "files_with_errors=$bad"
