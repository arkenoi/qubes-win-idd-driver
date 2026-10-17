# guest/set-startmode.ps1 - set the Start-menu mode knobs and prove the AGENT adopted them.
# NOT SHIPPED (rig tooling, like set-prototrace.ps1 / set-shellmanaged.ps1).
#
# WHY THIS EXISTS. There are knob-setters for ProtoTrace and ShellManaged but none for the two
# knobs that decide what happens when the user presses the Windows key, so every run on this rig
# took whatever the MSI left behind. MEASURED 2026-10-17: six captures across the day, every one
# of them seamlessStart=off - i.e. the half of the target state "if we decide to show it, it
# should appear" had never once been in force, while I was reporting on the Start menu's
# behaviour. A knob with no setter is a knob that is never varied.
#
# THE TWO KNOBS, and why they belong in one script (agent/gui-agent/perf.h):
#   SeamlessStart  DWORD 0/1, default 0 - is the Start surface PRESENTED in seamless mode.
#   BlockMenuKey   DWORD 0/1, default 1 - is the Windows key dropped instead of forwarded.
# They are one decision, not two: suppressing the menu means not forwarding the key
# (BlockMenuKey=1, SeamlessStart=0), and showing it means forwarding the key AND presenting the
# surface (BlockMenuKey=0, SeamlessStart=1). The two remaining combinations are the states to stay
# out of - BlockMenuKey=0 with SeamlessStart=0 is the one that lets the menu open and then works to
# suppress it. -Mode names the two coherent settings so a caller cannot reach a mixed one by
# accident; -SeamlessStart/-BlockMenuKey remain for deliberately testing a mixed state.
#
# THE PROOF IS THE AGENT'S LINE, NOT THE REGISTRY. Reading the value back says only that this
# script can read what it just wrote; the agent samples these at PerfInit and caches them in
# globals, so the question "is the knob in force" is answerable ONLY from the running instance. So
# this restarts the agent through the service that owns it (restart-gui-agent.ps1, which proves the
# turnover by content) and then returns the QGASTARTPOLICY line that the NEW instance wrote, found
# at or after its own init line. No line -> adopted = $false and a reason, never a silent success.
param(
    [ValidateSet('show', 'suppress', 'custom')] [string] $Mode = 'custom',
    [int] $SeamlessStart = -1,
    [int] $BlockMenuKey = -1,
    [int] $ProtoTrace = -1,
    [int] $TimeoutSec = 45
)
$ErrorActionPreference = 'Continue'

switch ($Mode) {
    'show'     { $SeamlessStart = 1; $BlockMenuKey = 0 }   # key forwarded, surface presented
    'suppress' { $SeamlessStart = 0; $BlockMenuKey = 1 }   # key never forwarded: nothing to suppress later
}
if ($SeamlessStart -lt 0 -and $BlockMenuKey -lt 0 -and $ProtoTrace -lt 0) {
    Write-Output '=== RESULT ==='
    @{ ok = $false; error = 'nothing to set: pass -Mode show|suppress, or -SeamlessStart/-BlockMenuKey/-ProtoTrace' } | ConvertTo-Json -Compress
    exit 2
}

$k = 'HKLM:\SOFTWARE\Invisible Things Lab\Qubes Tools\gui-agent'
if (-not (Test-Path $k)) { New-Item $k -Force | Out-Null }
$wrote = [ordered]@{}
if ($SeamlessStart -ge 0) { Set-ItemProperty $k -Name SeamlessStart -Value $SeamlessStart -Type DWord; $wrote.SeamlessStart = $SeamlessStart }
if ($BlockMenuKey  -ge 0) { Set-ItemProperty $k -Name BlockMenuKey  -Value $BlockMenuKey  -Type DWord; $wrote.BlockMenuKey  = $BlockMenuKey }
if ($ProtoTrace    -ge 0) { Set-ItemProperty $k -Name ProtoTrace    -Value $ProtoTrace    -Type DWord; $wrote.ProtoTrace    = $ProtoTrace }

$helper = Join-Path $PSScriptRoot 'restart-gui-agent.ps1'
if (-not (Test-Path -LiteralPath $helper)) {
    Write-Output '=== RESULT ==='
    @{ ok = $false; wrote = $wrote; error = 'restart-gui-agent.ps1 not pushed next to this script (tools/qtest push guest/restart-gui-agent.ps1)' } | ConvertTo-Json -Compress
    exit 3
}
. $helper
$ra = Restart-GuiAgent -TimeoutSec $TimeoutSec
foreach ($ln in @($ra.lines)) { Write-Output $ln }

# THE ADOPTION CHECK. The new instance's own words, taken from at-or-after its init line so a
# previous instance's policy line cannot be mistaken for this one's - the same positional rule
# restart-gui-agent.ps1 applies to its serving line.
$adopted = $false; $why = 'restart failed'; $policy = ''
if ($ra.ok -and $ra.new_log) {
    $lp = Join-Path $ra.log_dir $ra.new_log
    $lines = @(Get-Content -LiteralPath $lp -ErrorAction SilentlyContinue)
    $initIdx = -1
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        if ($lines[$i] -match 'LogInit:.*process ID:\s*(\d+)' -and [int]$Matches[1] -eq [int]$ra.new_pid) { $initIdx = $i; break }
    }
    if ($initIdx -lt 0) { $why = 'no init line for the new pid in the new log' }
    else {
        for ($i = $initIdx; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match 'QGASTARTPOLICY') { $policy = $lines[$i].Trim(); break }
        }
        if (-not $policy) { $why = 'the new instance wrote no QGASTARTPOLICY line' }
        else {
            # Compare the agent's words against what was asked, so a knob that did not take is a
            # FAILURE here rather than a surprise in whatever runs next.
            $wantSS = if ($SeamlessStart -ge 0) { $SeamlessStart } else { -1 }
            $wantBK = if ($BlockMenuKey  -ge 0) { $BlockMenuKey }  else { -1 }
            $saysSS = if ($policy -match 'seamlessStart=(on|off)') { if ($Matches[1] -eq 'on') { 1 } else { 0 } } else { -1 }
            $saysBK = if ($policy -match 'blockkey=(on|off)')      { if ($Matches[1] -eq 'on') { 1 } else { 0 } } else { -1 }
            if ($saysSS -lt 0 -or $saysBK -lt 0) { $why = "could not read both knobs out of the agent's line" }
            elseif (($wantSS -ge 0 -and $saysSS -ne $wantSS) -or ($wantBK -ge 0 -and $saysBK -ne $wantBK)) {
                $why = "asked seamlessStart=$wantSS blockkey=$wantBK; the agent reports seamlessStart=$saysSS blockkey=$saysBK"
            }
            else { $adopted = $true; $why = '' }
        }
    }
}

Write-Output '=== RESULT ==='
@{ ok = ($ra.ok -and $adopted)
   mode = $Mode
   wrote = $wrote
   adopted = $adopted
   adopted_reason = $why
   agent_policy_line = $policy
   agent_pid = $(if ($ra.ok) { $ra.new_pid } else { $null })
   restart = $ra.verdict; restart_reason = $ra.reason
   log = $ra.new_log } | ConvertTo-Json
if (-not ($ra.ok -and $adopted)) { exit 1 }
