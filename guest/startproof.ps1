# RND-5 / SG9 VACUITY PROOF — two independent witnesses that the Start STIMULUS existed, so that
# "no Start window in dom0" is a filter RESULT and not an absence of anything to filter.
#   1. the agent's own discriminator line ("Start surface not presented in seamless mode")
#   2. a Start/shell surface actually present guest-side
#
# WAS IN JOB SCRATCH UNTIL 2026-08-31. mgmt/harness/p4-run.sh referenced it at a
# /home/user/.claude/jobs/<id>/tmp path, so on any other session the file would be absent, the
# harness would print `deny=?` and the cell would silently lose the half that makes it evidence.
#
# SESSION-CONTEXT FIX (2026-09-03). This script is delivered by `qtest pushrun`, which runs as
# NT AUTHORITY\SYSTEM. Get-Process (STARTPROC) and reading the agent log (DISCRIM) are cross-session
# and answer correctly from SYSTEM. But EnumWindows is desktop/session-scoped: a SYSTEM enumeration
# does NOT see the logged-on USER's per-user shell surfaces (StartMenuExperienceHost's
# Windows.UI.Core.CoreWindow), so it reported SHELL_SURFACES 0 in the SAME run where DISCRIM_HITS>=1
# and STARTPROC 1 both proved Start was up - a FALSE zero that made a real PASS read as
# STIMULUS_ABSENT -> INVALID. So the EnumWindows half now runs in the INTERACTIVE USER session via
# `schtasks /ru user /it` (the pattern used by run-as-user.ps1 and open-start.ps1, and by
# surface-watch.ps1 - the self-validated shell detector), and its result file is read back here. The
# emitted tokens (SHELL_SURFACES <n> and the `  S ...` lines, plus STARTPROC) are byte-identical to
# the old SYSTEM-side form, so the RND-5 collector, its grep filter, and the verdict are unchanged.
# A genuine zero (Start never opened) still returns 0 -> STIMULUS_ABSENT -> INVALID: the fix removes
# only the FALSE zero from cross-session blindness, never the ability to report a TRUE zero.
$ErrorActionPreference='SilentlyContinue'

# --- WITNESS 1 (SYSTEM-side, cross-session): the agent's own discriminator line. -------------------
$d=(Get-ItemProperty 'HKLM:\SOFTWARE\Invisible Things Lab\Qubes Tools').LogDir
$f=(Get-ChildItem $d -Filter 'gui-agent-*.log' -EA SilentlyContinue | Sort-Object LastWriteTime -Desc | Select-Object -First 1)
Write-Output ('AGENTLOG ' + $f.FullName)
if ($f) {
  $hits = Select-String -Path $f.FullName -Pattern 'Start surface|SeamlessStart|not presented in seamless|cardless' -EA SilentlyContinue | Select-Object -Last 6
  Write-Output ('DISCRIM_HITS ' + @($hits).Count)
  $hits | ForEach-Object { Write-Output ('  D ' + $_.Line.Trim()) }
}

# --- WITNESS 2 (INTERACTIVE-USER session): shell surfaces present guest-side. ----------------------
# The EnumWindows body is written to an inner script and scheduled as the user; the same body used
# to run here (SYSTEM) and could not see the user's Start CoreWindow. $pid remains untouched - it is a
# PowerShell automatic variable (this process id); assigning it makes every window report the
# sampler's process. Use $wpid instead (same bug was fixed in surface-watch.ps1).
$work = 'C:\ProgramData\Qubes\startproof'
New-Item -ItemType Directory -Force -Path $work | Out-Null
$enum = Join-Path $work 'enum.ps1'
$res  = Join-Path $work 'shell-surfaces.txt'
Remove-Item $res -Force -EA SilentlyContinue

@'
$ErrorActionPreference='SilentlyContinue'
Add-Type -TypeDefinition @"
using System; using System.Text; using System.Runtime.InteropServices;
public class SW { public delegate bool EnumProc(IntPtr h, IntPtr l);
 [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
 [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
 [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
 [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
 [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid); }
"@
$rows=New-Object System.Collections.ArrayList
$cb=[SW+EnumProc]{ param($h,$l)
  if([SW]::IsWindowVisible($h)){
    $c=New-Object Text.StringBuilder 256;[void][SW]::GetClassNameW($h,$c,256)
    $t=New-Object Text.StringBuilder 256;[void][SW]::GetWindowTextW($h,$t,256)
    $wpid=0;[void][SW]::GetWindowThreadProcessId($h,[ref]$wpid)
    $pn=(Get-Process -Id $wpid -EA SilentlyContinue).ProcessName
    if($pn -match 'StartMenuExperienceHost|SearchHost|ShellExperienceHost' -or $c.ToString() -match 'Windows.UI.Core.CoreWindow'){
      [void]$rows.Add(('  S class={0} proc={1} title="{2}"' -f $c.ToString(),$pn,$t.ToString())) } }
  return $true }
[void][SW]::EnumWindows($cb,[IntPtr]::Zero)
$o=New-Object System.Collections.ArrayList
[void]$o.Add('SHELL_SURFACES ' + $rows.Count)
$rows | ForEach-Object { [void]$o.Add($_) }
$o | Out-File -FilePath 'C:\ProgramData\Qubes\startproof\shell-surfaces.txt' -Encoding ASCII
'@ | Set-Content -Path $enum -Encoding ASCII

# Is anyone actually logged on? Without an interactive session `/it` attaches to nothing and the
# task reports success while running nothing - a silent no-op. Report a TRUE zero in that case
# (there is no user desktop to enumerate), which routes to STIMULUS_ABSENT -> INVALID.
$sess = @(query user 2>&1 | Select-String -Pattern '\s(Active)\s')
if ($sess.Count -eq 0) {
  Write-Output 'SHELL_SURFACES 0'
  Write-Output '  (no active interactive session - shell-surface enum could not run as the user)'
} else {
  & schtasks /delete /tn QwtStartProofEnum /f *>$null
  & schtasks /create /tn QwtStartProofEnum /tr "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$enum`"" /sc once /st 00:00 /ru user /it /f *>$null
  & schtasks /run /tn QwtStartProofEnum *>$null
  $deadline=(Get-Date).AddSeconds(30)
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 700
    if (Test-Path $res) { Start-Sleep -Milliseconds 300; break }
  }
  & schtasks /delete /tn QwtStartProofEnum /f *>$null
  if (Test-Path $res) {
    Get-Content $res | ForEach-Object { Write-Output $_ }
  } else {
    # The task never produced a result file: an instrument fault, not a proven zero. Emit a distinct
    # marker (filtered out by the collector) plus a 0 so the vacuity guard still refuses the run.
    Write-Output 'SHELL_SURFACES 0'
    Write-Output '  (enum task produced no result file - could not measure shell surfaces as the user)'
  }
}

# --- STARTPROC (SYSTEM-side, cross-session): Get-Process answers regardless of session. -----------
Write-Output ('STARTPROC ' + @(Get-Process StartMenuExperienceHost -EA SilentlyContinue).Count)
