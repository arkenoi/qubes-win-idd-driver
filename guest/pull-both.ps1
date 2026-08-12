# Pull BOTH directions of the configure exchange, interleaved by timestamp: incoming daemon
# moves ("Updating position", Verbose) and outgoing agent announces (SendWindowConfigure).
param([int]$Tail = 60)
$ErrorActionPreference = 'Continue'
$log = Get-ChildItem 'Q:\Qubes Logs' -Filter 'gui-agent-*.log' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
Write-Output "=== LOG $($log.Name) ==="
Get-Content $log.FullName | Select-String 'Updating position of|SendWindowConfigure: QGAPROTO,msg=CONFIGURE|HandleConfigure' |
    Select-Object -Last $Tail | ForEach-Object {
        $l = $_.Line
        if ($l -match 'Updating position') { "IN   $l" }
        elseif ($l -match 'SendWindowConfigure') { "OUT  $l" }
        else { "     $l" }
    }
Write-Output '=== END ==='
