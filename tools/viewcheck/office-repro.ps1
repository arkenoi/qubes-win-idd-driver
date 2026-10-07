# Controlled Office repro. The daemon-kill we captured may belong to Word's FIRST-RUN
# splash/licensing window rather than steady-state chrome - and every careless launch destroys
# that distinction. This script makes the state explicit and repeatable.
#
#   -Mode Reset    : force Word back to a first-run state (and clear the safe-mode/Resiliency
#                    prompt that repeated hard kills leave behind), then STOP. Reboot after this.
#   -Mode FirstRun : launch Word expecting the first-run experience, hold, report.
#   -Mode Steady   : launch Word expecting NO first-run UI (run after a successful FirstRun),
#                    hold, report.
#
# Word is always closed GRACEFULLY (WM_CLOSE) - Stop-Process is what produced the safe-mode
# prompt in the first place and it poisons the next run - and ONLY the instance THIS run started,
# by the handle Start-Process -PassThru returned. A WINWORD this run did not start is not its to
# end (owner 2026-10-07: nothing is killed by name); it is reported so the next run knows it
# starts dirty.
param([ValidateSet('Reset','FirstRun','Steady')][string]$Mode = 'Steady', [int]$HoldSeconds = 60)
$ErrorActionPreference = 'SilentlyContinue'

$script:Word = $null
function Close-WordGracefully {
    $others = @(Get-Process WINWORD -EA SilentlyContinue | Where-Object { -not $script:Word -or $_.Id -ne $script:Word.Id })
    if ($others.Count) { "WARN WINWORD not started by this run is open (pid " + (($others | ForEach-Object Id) -join ',') + ") - not stopped; close it by hand or the next run starts dirty" }
    $p = $script:Word
    if (-not $p) { return }
    try { if ($p.HasExited) { return } } catch { return }
    [void]$p.CloseMainWindow()
    if (-not $p.WaitForExit(8000)) {
        # only if it refused - and say so, because it means the next run starts dirty
        "WARN word did not close gracefully; next run will start dirty"
        try { $p.Kill(); [void]$p.WaitForExit(5000) } catch { }
    }
}

if ($Mode -eq 'Reset') {
    Close-WordGracefully
    # Resiliency = the "start in safe mode?" prompt after crashes
    Remove-Item 'HKCU:\Software\Microsoft\Office\16.0\Word\Resiliency' -Recurse -Force
    Remove-Item 'HKCU:\Software\Microsoft\Office\16.0\Common\Resiliency' -Recurse -Force
    # first-run markers
    Remove-Item 'HKCU:\Software\Microsoft\Office\16.0\Common\General' -Recurse -Force
    Remove-Item 'HKCU:\Software\Microsoft\Office\16.0\Common\FirstRun' -Recurse -Force
    Remove-Item 'HKCU:\Software\Microsoft\Office\16.0\Word\Options' -Recurse -Force
    "RESET_DONE - reboot the guest before the FirstRun run"
    "RESULT=OFFICE_REPRO_RESET"
    exit 0
}

$log = Get-ChildItem 'C:\Program Files\Qubes Tools\log' -Filter 'gui-agent-*.log' | Sort LastWriteTime | Select -Last 1
"AGENT_LOG_BEFORE=$($log.Name)"
"AGENT_PID_BEFORE=" + (Get-Process gui-agent -EA SilentlyContinue).Id
"MODE=$Mode"
"LAUNCH_AT=" + (Get-Date -Format o)
$script:Word = Start-Process 'C:\Program Files\Microsoft Office\root\Office16\WINWORD.EXE' -ArgumentList '/w' -PassThru
Start-Sleep -Seconds $HoldSeconds
"HELD_AT=" + (Get-Date -Format o)
"AGENT_PID_AFTER=" + (Get-Process gui-agent -EA SilentlyContinue).Id
$log2 = Get-ChildItem 'C:\Program Files\Qubes Tools\log' -Filter 'gui-agent-*.log' | Sort LastWriteTime | Select -Last 1
"AGENT_LOG_AFTER=$($log2.Name)"
"AGENT_RESPAWNED=" + ($log2.Name -ne $log.Name)
$c = Get-Content $log2.FullName
"SYNTH_COUNT=" + @($c | Select-String 'msg=SYNTH,').Count
"OUTSIDE_OWNER=" + @($c | Select-String 'outside owner').Count
"MATERIALIZING=" + @($c | Select-String 'materializing child').Count
"VCHAN_DISC=" + @($c | Select-String 'vchan disconnected').Count
$c | Select-String 'msg=SYNTH,|outside owner|materializing child' | Select-Object -Last 12 |
  ForEach-Object { "L $($_.Line.Trim())" }
Close-WordGracefully
"RESULT=OFFICE_REPRO_DONE"
