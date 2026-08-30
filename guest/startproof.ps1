# RND-5 / SG9 VACUITY PROOF — two independent witnesses that the Start STIMULUS existed, so that
# "no Start window in dom0" is a filter RESULT and not an absence of anything to filter.
#   1. the agent's own discriminator line ("Start surface not presented in seamless mode")
#   2. a Start/shell surface actually present guest-side
#
# WAS IN JOB SCRATCH UNTIL 2026-08-31. mgmt/harness/p4-run.sh referenced it at a
# /home/user/.claude/jobs/<id>/tmp path, so on any other session the file would be absent, the
# harness would print `deny=?` and the cell would silently lose the half that makes it evidence.
$ErrorActionPreference='SilentlyContinue'
# Two independent witnesses that the STIMULUS existed, so "no window in dom0" is a filter result:
#  1. the agent's own discriminator line
#  2. a Start surface actually present guest-side
$d=(Get-ItemProperty 'HKLM:\SOFTWARE\Invisible Things Lab\Qubes Tools').LogDir
$f=(Get-ChildItem $d -Filter 'gui-agent-*.log' -EA SilentlyContinue | Sort-Object LastWriteTime -Desc | Select-Object -First 1)
Write-Output ('AGENTLOG ' + $f.FullName)
if ($f) {
  $hits = Select-String -Path $f.FullName -Pattern 'Start surface|SeamlessStart|not presented in seamless|cardless' -EA SilentlyContinue | Select-Object -Last 6
  Write-Output ('DISCRIM_HITS ' + @($hits).Count)
  $hits | ForEach-Object { Write-Output ('  D ' + $_.Line.Trim()) }
}
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
    # $pid is a POWERSHELL AUTOMATIC VARIABLE (this process id). Assigning it does not fail loudly;
      # it just makes every window report the SAMPLER's process, so the proc-name half of the filter
      # below never matches. Same bug was found and fixed in guest/surface-watch.ps1.
      $wpid=0;[void][SW]::GetWindowThreadProcessId($h,[ref]$wpid)
    $pn=(Get-Process -Id $wpid -EA SilentlyContinue).ProcessName
    if($pn -match 'StartMenuExperienceHost|SearchHost|ShellExperienceHost' -or $c.ToString() -match 'Windows.UI.Core.CoreWindow'){
      [void]$rows.Add(('  S class={0} proc={1} title="{2}"' -f $c.ToString(),$pn,$t.ToString())) } }
  return $true }
[void][SW]::EnumWindows($cb,[IntPtr]::Zero)
Write-Output ('SHELL_SURFACES ' + $rows.Count)
$rows | ForEach-Object { Write-Output $_ }
Write-Output ('STARTPROC ' + @(Get-Process StartMenuExperienceHost -EA SilentlyContinue).Count)
