# A BARE `{ ... }` STATEMENT IS DEAD CODE, AND NO GREP CAN SEE IT.
#
# WHAT IT COST. guest/install-updater-agent.ps1 wrapped its relay compile/move in a bare brace pair.
# In PowerShell that is a ScriptBlock LITERAL: constructed, discarded, never executed. So the script
# logged "updater agent deployed", dom0 was told the agent was deployed, and the relay on disk stayed
# the one built 2026-09-16 - carrying no --parent-pid support, so every pass bound its own PID as the
# listen port (measured on win11de-tup: 8228, 6688, 8892, 2540, 5956) while WinHTTP pointed at 8082
# and nothing served it. The fix was reported READY on offline legs and Jev scores alone. Offline
# legs read source TEXT, and the text was perfectly correct - the block simply never ran. Proof in
# one line: `{ $ran = $true }` leaves $ran False.
#
# WHY THIS IS AN AST CHECK AND NOT A PATTERN. A `{` at the start of a line is also every if/foreach/
# try body, every hashtable, every -ScriptBlock argument. Only the parser knows which braces are a
# STATEMENT whose value is thrown away. The first draft of this check tested for a standalone
# ScriptBlockExpressionAst and reported every file clean while MISSING the shape that had just been
# removed - a bare block parses as a PipelineAst wrapping a CommandExpressionAst. That is why the
# control below is not optional: it is the same error one level up, and the only thing that catches
# it is requiring the check to FAIL on the real shape.
$ErrorActionPreference = 'Stop'
$pass = 0; $fail = 0
function Check([string]$what, [bool]$ok, [string]$detail = '') {
    if ($ok) { $script:pass++; "ok   $what" }
    else { $script:fail++; "FAIL $what"; if ($detail) { "       -> $detail" } }
}
$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

# Find statements whose entire value is a discarded scriptblock literal. Returns "file:line" strings.
function Find-Discarded([string]$path) {
    $t = $null; $e = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$t, [ref]$e)
    if ($null -eq $ast) { return @("${path}:0 UNPARSEABLE") }
    $hits = New-Object System.Collections.ArrayList
    # Every statement in every block, at any depth: a dead block nested inside a function or an if
    # is just as dead as one at top level.
    $stmts = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.PipelineAst] }, $true)
    foreach ($s in $stmts) {
        if ($s.PipelineElements.Count -ne 1) { continue }
        $el = $s.PipelineElements[0]
        if ($el -isnot [System.Management.Automation.Language.CommandExpressionAst]) { continue }
        if ($el.Expression -isnot [System.Management.Automation.Language.ScriptBlockExpressionAst]) { continue }
        # A pipeline that IS a lone scriptblock expression and is itself a statement in a block:
        # nothing consumes its value, so the block is built and thrown away.
        if ($s.Parent -is [System.Management.Automation.Language.StatementBlockAst] -or
            $s.Parent -is [System.Management.Automation.Language.NamedBlockAst]) {
            [void]$hits.Add("$([IO.Path]::GetFileName($path)):$($s.Extent.StartLineNumber)")
        }
    }
    return $hits.ToArray()
}

$T = Join-Path ([IO.Path]::GetTempPath()) ("deadsb-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force $T | Out-Null

# ---- SEEN TO FAIL: the exact shape that shipped must be DETECTED -------------------------------
# This is the defect reconstructed: a guard, then a bare block holding the work, then a success log.
# Every line of it is correct PowerShell and the work never runs.
$ctl = Join-Path $T 'control-dead.ps1'
@'
$exe = 'relay.exe'
if (-not (Test-Path $exe)) { Write-Output 'missing' }
{
    $out = & csc /out:$exe relay.cs
    Move-Item $out $exe -Force
    Write-Output "compiled relay -> $exe"
}
Write-Output 'agent deployed'
'@ | Set-Content -LiteralPath $ctl
$got = @(Find-Discarded $ctl)
Check 'SEEN TO FAIL: the shipped dead-block shape is DETECTED' ($got.Count -eq 1) "hits=$($got -join ',')"
Check '...and it names the line the dead block starts on' (($got -join ',') -match ':3$') "hits=$($got -join ',')"

# ---- and the shapes that are NOT defects must stay clean ---------------------------------------
# A check that flags every brace would be worse than no check: it would be turned off.
$ok = Join-Path $T 'control-legit.ps1'
@'
$sb = { Write-Output 'assigned - consumed by the assignment' }
& { Write-Output 'invoked with the call operator' }
. { Write-Output 'dot-sourced' }
1..3 | ForEach-Object { $_ * 2 }
Invoke-Command -ScriptBlock { Write-Output 'passed as an argument' }
if ($true) { Write-Output 'an if body is not a scriptblock statement' }
foreach ($i in 1..2) { Write-Output $i }
try { Write-Output 'try' } catch { Write-Output 'catch' } finally { Write-Output 'finally' }
function f { param($x) process { $x } }
$h = @{ a = 1; b = { 'a scriptblock VALUE in a hashtable' } }
trap { Write-Output 'trap body' }
while ($false) { Write-Output 'never' }
switch (1) { 1 { Write-Output 'switch body' } }
Register-ObjectEvent -InputObject $sb -EventName x -Action { Write-Output 'action' } -EA SilentlyContinue
'@ | Set-Content -LiteralPath $ok
$clean = @(Find-Discarded $ok)
Check 'every legitimate scriptblock use stays clean - this is not a brace-counter' `
    ($clean.Count -eq 0) "false positives: $($clean -join ',')"

# ---- THE SHIPPED TREE --------------------------------------------------------------------------
# The product's own PowerShell, which is where the defect lived.
$dirs = @('guest', 'packaging/setup', 'tools')
$scanned = 0
$all = New-Object System.Collections.ArrayList
foreach ($d in $dirs) {
    $p = Join-Path $repo $d
    if (-not (Test-Path -LiteralPath $p)) { continue }
    foreach ($f in @(Get-ChildItem -LiteralPath $p -Filter *.ps1 -Recurse -File)) {
        $scanned++
        foreach ($h in @(Find-Discarded $f.FullName)) { [void]$all.Add($h) }
    }
}
Check "the shipped PowerShell carries no discarded scriptblock statement ($scanned files scanned)" `
    ($all.Count -eq 0) "$($all -join ', ')"
Check 'the scan actually read a corpus - a vacuous pass is not a pass' `
    ($scanned -ge 20) "scanned=$scanned"

# install-updater-agent.ps1 is the file that shipped the defect, so it is named explicitly: a
# directory list that silently stops matching it would make this check vacuous for the one file
# whose regression this is.
$dep = Join-Path $repo 'guest/install-updater-agent.ps1'
Check 'the file that shipped the defect is in the corpus and clean' `
    ((Test-Path -LiteralPath $dep) -and (@(Find-Discarded $dep).Count -eq 0)) `
    'guest/install-updater-agent.ps1'

Remove-Item -Recurse -Force $T -EA SilentlyContinue
''
"RESULT: $pass passed, $fail failed"
if ($fail -ne 0) { exit 1 }
