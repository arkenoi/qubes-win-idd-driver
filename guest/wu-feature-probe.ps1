# Find the invocation this qubesdb-cmd build accepts for WRITE, then prove the key landed.
$ErrorActionPreference = 'Continue'
$qt  = $env:QUBES_TOOLS; if (-not $qt) { $qt = 'C:\Program Files\Qubes Tools' }
$qdb = Join-Path $qt 'bin\qubesdb-cmd.exe'
$qr  = Join-Path $qt 'bin\qrexec-client-vm.exe'

function Try-Form([string]$label, [string[]]$argv) {
    Write-Output "--- $label : qubesdb-cmd $($argv -join ' ')"
    $o = & $qdb @argv 2>&1 | Select-Object -First 3
    foreach ($l in $o) { Write-Output "    $l" }
    Write-Output "    rc=$LASTEXITCODE"
    $r = & $qdb -c read /features-request/vmexec 2>&1 | Select-Object -First 1
    Write-Output "    readback: $r (rc=$LASTEXITCODE)"
}

Try-Form 'A -c write path value'      @('-c','write','/features-request/vmexec','1')
Try-Form 'B -c write -- path value'   @('-c','write','--','/features-request/vmexec','1')
Try-Form 'C write path value'         @('write','/features-request/vmexec','1')
Try-Form 'D -c write path (stdin)'    @('-c','write','/features-request/vmexec')
Try-Form 'E -c write pathpair x2'     @('-c','write','/features-request/vmexec','1','/features-request/probe','1')

Write-Output '--- final state of /features-request/ ---'
& $qdb -c list /features-request/ 2>&1 | ForEach-Object { "    $_" }
Write-Output "    rc=$LASTEXITCODE"
