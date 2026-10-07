# Build the re-arm action the way guest/pvnic-selfprime.ps1 does and print what an XML parser hands
# Task Scheduler - the command line cmd.exe actually receives. Asserting the ESCAPED source text only
# proves what was typed; this proves what runs. Usage: pvnic-rearm-decode.ps1 <pvnic-selfprime.ps1>
param([Parameter(Mandatory=$true)][string]$Source)
$src = Get-Content -LiteralPath $Source -Raw
$m = [regex]::Match($src, "(?m)^\`$stampFile = .*?$")
$a = [regex]::Match($src, "(?ms)^\`$argRearm = .*?\`"$")
if (-not $m.Success -or -not $a.Success) { Write-Output "EXTRACT-FAILED stamp=$($m.Success) arg=$($a.Success)"; exit 2 }
Invoke-Expression $m.Value
Invoke-Expression $a.Value
$xml = [xml]("<Task><Actions><Exec><Command>cmd.exe</Command><Arguments>" + $argRearm + "</Arguments></Exec></Actions></Task>")
Write-Output ("DECODED>>" + $xml.Task.Actions.Exec.Arguments + "<<")
