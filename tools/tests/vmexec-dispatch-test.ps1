# vmexec-dispatch-test.ps1 - does guest/VMExec.ps1 route dom0's update sequence to the shim, and
# NOTHING ELSE? Offline, no guest: the predicate is READ OUT of VMExec.ps1 so the test cannot drift
# away from the code it checks.
#
# WHY THIS EXISTS. dom0 finishes an update pass with
# `cat /var/log/qubes/qubes-update/update-agent.log` and reads that output as the operator-facing
# log. The predicate matched only the updater workdir and entrypoint.py, so that step fell through
# to cmd.exe - which has no `cat` - and the shim's own `cat` branch, written to answer exactly this
# step, never ran once. Measured on a guest 2026-10-14 from the shim's own audit: mkdir, tar,
# entrypoint, rm, and no cat entry at all.
#
# The other half matters just as much: the shim's default branch is a NO-OP, so anything routed
# there that it does not recognise is silently swallowed. A predicate that is too wide is worse
# than one that is too narrow, which is why the cases below include near-misses that MUST go to cmd.
#
#   -Defect   use the pre-fix predicate; the agent-log case must then FAIL, or this test proves
#             nothing about the fix.
param([switch]$Defect)
$ErrorActionPreference = 'Stop'
$src = Join-Path $PSScriptRoot '..\..\guest\VMExec.ps1'
if (-not (Test-Path $src)) { Write-Output "FAIL  $src not found - nothing ran"; exit 2 }

$line = Select-String -Path $src -Pattern '\$cmd -match' | Select-Object -First 1
if (-not $line) { Write-Output 'FAIL  no "$cmd -match" line in VMExec.ps1 - the predicate moved'; exit 2 }
if ($line.Line -notmatch "-match\s+'([^']+)'") { Write-Output "FAIL  could not read the pattern out of: $($line.Line)"; exit 2 }
$pattern = $matches[1]
if ($Defect) { $pattern = '/run/qubes-update|\\run\\qubes-update|entrypoint\.py' }
Write-Output "predicate: $pattern"

# dom0's own sequence (qubes-core-admin-linux vmupdate/qube_connection.py) -> must reach the shim,
# plus near-misses that must NOT.
$cases = @(
  @{ cmd = 'mkdir -p /run/qubes-update/';                                      shim = $true;  why = 'dom0 step 1' },
  @{ cmd = 'tar -xzf /run/qubes-update/agent.tar.gz -C /run/qubes-update/';     shim = $true;  why = 'dom0 step 3' },
  @{ cmd = '/usr/bin/python3 /run/qubes-update/agent/entrypoint.py --log INFO'; shim = $true;  why = 'dom0 step 4, the agent run' },
  @{ cmd = 'rm -r /run/qubes-update/';                                          shim = $true;  why = 'dom0 step 5' },
  @{ cmd = 'cat /var/log/qubes/qubes-update/update-agent.log';                  shim = $true;  why = 'dom0 step 6, THE AGENT LOG' },
  @{ cmd = 'cmd /c echo hello';                                                 shim = $false; why = 'an ordinary qvm-run' },
  @{ cmd = 'powershell -Command Get-Date';                                      shim = $false; why = 'an ordinary qvm-run' },
  @{ cmd = 'type C:\logs\update-agent.log';                                     shim = $false; why = 'a log of the same NAME elsewhere' },
  @{ cmd = 'cat C:\notes\qubes-update-plan.txt';                                shim = $false; why = 'the words, not the path' }
)

$pass = 0; $fail = 0
foreach ($c in $cases) {
    $routed = [bool]($c.cmd -match $pattern)
    if ($routed -eq $c.shim) {
        $pass++; Write-Output ("  PASS  {0,-5} {1}" -f $(if ($c.shim) {'shim'} else {'cmd'}), $c.why)
    } else {
        $fail++; Write-Output ("  FAIL  want {0,-5} got {1,-5} : {2}" -f $(if ($c.shim) {'shim'} else {'cmd'}), $(if ($routed) {'shim'} else {'cmd'}), $c.cmd)
    }
}
Write-Output "RESULT: $pass passed, $fail failed"
exit $(if ($fail -gt 0) { 1 } else { 0 })
