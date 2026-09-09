<#
.SYNOPSIS
    Show what bind-dirs (docs/BIND-DIRS.md) did at the last boot and verify the junctions.

.DESCRIPTION
    bind-dirs.exe is a NATIVE image run from Session Manager's BootExecute; it cannot be started
    from a shell, so the instrument is its result record on the private volume plus a direct
    look at each junction. This script prints the record and, for every entry, checks that the
    C: path is a junction (reparse point) whose target is the recorded Q:\bind-dirs path and that
    the target directory exists. It also reports whether bind-dirs.exe is registered in
    BootExecute at all, so "never ran" and "ran and failed" cannot be confused.

    Exit codes: 0 = registered, record says ok, every junction verified; 1 = anything else.
    Emits an === RESULT === JSON line like the other guest scripts.

.PARAMETER Record
    Path of the result record. Default: Q:\Qubes Logs\bind-dirs-result.txt
#>
[CmdletBinding()]
param(
    [string]$Record = 'Q:\Qubes Logs\bind-dirs-result.txt'
)

$ErrorActionPreference = 'Continue'

$out = [ordered]@{
    registered   = $false
    record_found = $false
    result       = 'absent'
    reason       = ''
    entries      = @()
    verified     = 0
    broken       = 0
    pass         = $false
}

# 1. Is it registered at all? (A missing record on a registered guest = it never ran.)
$be = @()
try {
    $be = @((Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name BootExecute -ErrorAction Stop).BootExecute)
} catch {
    $be = @()
}
$out.registered = (@($be | Where-Object { $_ -match '(?i)^bind-dirs\.exe' }).Count -ge 1)
Write-Host ("BootExecute: " + ($be -join ' | '))

# 2. The record.
if (Test-Path -LiteralPath $Record) {
    $out.record_found = $true
    $lines = @(Get-Content -LiteralPath $Record -ErrorAction SilentlyContinue)
    foreach ($l in $lines) {
        Write-Host "  $l"
        if ($l -match '^result=(.*)$') { $out.result = $Matches[1].Trim() }
        if ($l -match '^reason=(.*)$') { $out.reason = $Matches[1].Trim() }
        if ($l -match '^entry=(.+?) result=(\S+) reason=(\S+) .* rw=(.+?) source=(.*)$') {
            $out.entries += [ordered]@{ path = $Matches[1]; result = $Matches[2]; reason = $Matches[3]; rw = $Matches[4]; source = $Matches[5]; junction = 'unchecked' }
        }
    }
} else {
    Write-Host "no result record at $Record"
}

# 3. Verify each entry that claims ok: the C: path must be a reparse point onto the recorded rw.
foreach ($e in $out.entries) {
    if ($e.result -ne 'ok' -or $e.reason -eq 'duplicate') { continue }
    $item = Get-Item -LiteralPath $e.path -Force -ErrorAction SilentlyContinue
    $isLink = $false
    $target = ''
    if ($item) {
        $isLink = [bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint)
        if ($item.Target) { $target = ($item.Target -join ';') }
    }
    $targetOk = ($target -replace '^\\\?\?\\', '') -ieq $e.rw
    $rwExists = Test-Path -LiteralPath $e.rw -PathType Container
    if ($isLink -and $targetOk -and $rwExists) {
        $e.junction = 'ok'
        $out.verified++
    } else {
        $e.junction = "BROKEN link=$isLink target='$target' rw_exists=$rwExists"
        $out.broken++
    }
    Write-Host ("  {0} -> {1}: {2}" -f $e.path, $e.rw, $e.junction)
}

$out.pass = ($out.registered -and $out.record_found -and $out.result -eq 'ok' -and $out.broken -eq 0)
Write-Host '=== RESULT ==='
Write-Host ($out | ConvertTo-Json -Depth 4 -Compress)
if ($out.pass) { exit 0 }
exit 1
