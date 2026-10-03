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

# A FUNCTION NAMED LIKE A WINDOWS POWERSHELL 5.1 ALIAS IS NEVER CALLED: an alias wins over a function of the same name, so the
# call runs the aliased cmdlet instead. It bit twice on guests (2026-10-02): a helper named H ran Get-History and its output line
# vanished; one named Diff ran Compare-Object, which prompted for input and hung the probe. The guests run 5.1 and this parser runs
# pwsh 7, whose Linux build lacks most of those aliases - so the 5.1 default set is fixed here, not read from this session.
# Run it on a scratchpad script by hand before it goes to a guest: pwsh -File tools/ps-parse-check.ps1 <file>
$aliases51 = @('%','?','ac','asnp','cat','cd','CFS','chdir','clc','clear','clhy','cli','clp','cls','clv','cnsn','compare','copy','cp',
    'cpi','cpp','curl','cvpa','dbp','del','diff','dir','dnsn','ebp','echo','epal','epcsv','epsn','erase','etsn','exsn','fc','fhx','fl',
    'foreach','ft','fw','gal','gbp','gc','gcb','gci','gcm','gcs','gdr','ghy','gi','gin','gjb','gl','gm','gmo','gp','gps','gpv','group',
    'gsn','gsnp','gsv','gtz','gu','gv','gwmi','h','history','icm','iex','ihy','ii','ipal','ipcsv','ipmo','ipsn','irm','ise','iwmi','iwr',
    'kill','lp','ls','man','md','measure','mi','mount','move','mp','mv','nal','ndr','ni','nmo','npssc','nsn','nv','ogv','oh','popd','ps',
    'pushd','pwd','r','rbp','rcjb','rcsn','rd','rdr','ren','ri','rjb','rm','rmdir','rmo','rni','rnp','rp','rsn','rsnp','rujb','rv','rvpa',
    'rwmi','sajb','sal','saps','sasv','sbp','sc','scb','select','set','shcm','si','sl','sleep','sls','sort','sp','spjb','spps','spsv',
    'start','stz','sujb','sv','swmi','tee','trcm','type','wget','where','wjb','write')

$bad = 0
$shadowed = 0
foreach ($f in $files) {
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errors)
    $rel = $f.FullName.Substring($root.Length).TrimStart('/', '\')
    if (-not $rel) { $rel = $f.Name }
    if ($errors -and $errors.Count -gt 0) {
        $bad++
        Write-Host "FAIL  $rel"
        foreach ($e in ($errors | Select-Object -First 5)) {
            Write-Host ("        line {0}: {1}" -f $e.Extent.StartLineNumber, $e.Message)
        }
    }
    foreach ($fd in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
        if ($aliases51 -contains $fd.Name) {   # -contains is case-insensitive, as PowerShell's command lookup is
            $shadowed++
            Write-Host ("FAIL  {0}: line {1}: function '{2}' is a Windows PowerShell 5.1 alias - every call runs the aliased cmdlet, never this function; rename it" -f $rel, $fd.Extent.StartLineNumber, $fd.Name)
        }
    }
}

Write-Host ("--- parsed {0} file(s), {1} with syntax errors, {2} function(s) named like a 5.1 alias" -f $files.Count, $bad, $shadowed)
if ($bad -gt 0 -or $shadowed -gt 0) { exit 1 }
exit 0
