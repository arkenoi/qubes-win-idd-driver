# uac-elev-trigger.ps1 - MAKE A REAL CONSENT PROMPT HAPPEN, SO THE SAMPLER CAN BE SEEN TO FIRE.
#
# uac-startup-sample.ps1's whole value is a ZERO: "no consent.exe appeared during startup". A zero
# from an instrument that has never been seen to produce a one is decoration (experimenter rule 3b,
# and this repo's standing rule that a check counts as evidence only once it has been seen to FAIL
# with the defect present). This produces the one.
#
# WHY IT CANNOT BE DONE FROM HERE DIRECTLY. This script runs as SYSTEM over qrexec. SYSTEM is already
# fully elevated, so `Start-Process -Verb RunAs` from SYSTEM raises no prompt at all - it would
# produce a zero and look like a working trigger. The request has to come from the INTERACTIVE USER's
# filtered token, so it is issued by a one-shot scheduled task registered with an Interactive
# principal at LeastPrivilege, which is the one shape that reproduces what a user's own shell does.
#
# AND IT MUST NOT BE ANSWERED. Nothing here clicks Yes: the prompt is raised, observed, and then the
# consent process is ended so the guest is left as it was found. Answering it would make the trigger
# a way of handing out administrator rights (docs/ADR-uac.md section 8).
[CmdletBinding()]
param(
    [int]    $WaitSeconds = 25,
    [string] $TaskName = 'QwtUacElevProbe',
    [switch] $KeepPrompt      # leave the prompt standing (for a window-side observation)
)

$ErrorActionPreference = 'Continue'
function Say($m) { Write-Output ("[{0:HH:mm:ss}] {1}" -f (Get-Date), $m) }

$lua = $null
try { $lua = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -ErrorAction Stop).EnableLUA } catch { }
Say ("EnableLUA=$lua - with 0 this trigger CANNOT raise a prompt, and a zero result says nothing")

$who = $null
try { $who = (Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).UserName } catch { }
if (-not $who) { Say 'NO INTERACTIVE SESSION: nothing to elevate from, refusing to report a zero'; exit 3 }
Say "console user = $who"

# The elevated target is deliberately trivial and leaves a stamp, so if the prompt IS answered by a
# human the outcome is visible rather than guessed.
$stamp = Join-Path $env:SystemDrive 'uac-elev-trigger-ran.txt'
Remove-Item -LiteralPath $stamp -Force -ErrorAction SilentlyContinue
$inner = "Start-Process cmd.exe -Verb RunAs -ArgumentList '/c echo elevated > $stamp'"
$enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($inner))

Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
try {
    $act = New-ScheduledTaskAction -Execute 'powershell.exe' `
              -Argument "-NoProfile -WindowStyle Hidden -EncodedCommand $enc"
    $prn = New-ScheduledTaskPrincipal -UserId $who -LogonType Interactive -RunLevel Limited
    $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
              -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
    Register-ScheduledTask -TaskName $TaskName -Action $act -Principal $prn -Settings $set `
              -Description 'QWT probe: raise one real UAC consent prompt (never answered)' -Force | Out-Null
} catch {
    Say "REGISTER FAILED: $($_.Exception.Message)"
    exit 4
}
Say "task registered as $who / Interactive / LeastPrivilege"

$before = @(Get-Process -Name consent -ErrorAction SilentlyContinue).Count
Say "consent.exe before = $before"
try { Start-ScheduledTask -TaskName $TaskName -ErrorAction Stop } catch { Say "START FAILED: $($_.Exception.Message)"; exit 5 }

# THREE EXITS, and it says which one fired.
$deadline = (Get-Date).AddSeconds($WaitSeconds)
$exit = 'deadline'
$seen = @()
while ((Get-Date) -lt $deadline) {
    $p = @(Get-Process -Name consent -ErrorAction SilentlyContinue)
    if ($p.Count -gt $before) { $seen = $p; $exit = 'consent-appeared'; break }
    $ti = $null
    try { $ti = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction Stop } catch { }
    if ($ti -and $ti.LastTaskResult -ne 267009 -and $ti.LastTaskResult -ne 0 -and $ti.LastRunTime) {
        $exit = "task-failed-$($ti.LastTaskResult)"; break
    }
    Start-Sleep -Milliseconds 250
}

if ($exit -eq 'consent-appeared') {
    foreach ($p in $seen) {
        $st = $null; try { $st = $p.StartTime } catch { }
        Say ("CONSENT RAISED: pid={0} start={1}" -f $p.Id, $(if ($st) { $st.ToString('o') } else { '?' }))
    }
    if (-not $KeepPrompt) {
        Start-Sleep -Seconds 3   # let a sampler running alongside take at least one sample of it
        foreach ($p in $seen) { try { Stop-Process -Id $p.Id -Force -ErrorAction Stop; Say "consent pid=$($p.Id) ended (the prompt was NOT answered)" } catch { Say "could not end consent pid=$($p.Id): $($_.Exception.Message)" } }
    } else {
        Say 'prompt LEFT STANDING (-KeepPrompt)'
    }
} else {
    Say "NO CONSENT PROMPT: exit=$exit"
}

if (Test-Path -LiteralPath $stamp) { Say 'WARNING: the elevated command RAN - something answered the prompt, or no prompt was required' }
if (-not $KeepPrompt) { Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue }
Say "TRIGGER_EXIT=$exit"
if ($exit -eq 'consent-appeared') { exit 0 } else { exit 1 }
