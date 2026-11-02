<#
  QWT-NG: let dom0's STOCK `qubes-vm-update` (and therefore the Qubes Update GUI) drive a
  Windows qube, with no dom0-side command and no dom0 changes.

  WHY THIS EXISTS
  dom0's updater does not call an agent that lives in the guest - it INJECTS one on every run
  (qubes-core-admin-linux, vmupdate/qube_connection.py):
      mkdir -p /run/qubes-update/
      cat > /run/qubes-update/agent.tar.gz      (the tarball on stdin, over qubes.VMShell)
      tar -xzf /run/qubes-update/agent.tar.gz -C /run/qubes-update/
      /usr/bin/python3 /run/qubes-update/agent/entrypoint.py <flags>
      rm -r /run/qubes-update/
      cat /var/log/qubes/qubes-update/update-agent.log
  That design is why any Linux qube is updatable with nothing preinstalled - and exactly why
  Windows can never be: no /usr/bin/python3, no dnf/apt, no Windows branch in get_os_data().
  So we answer the same command shapes ourselves and, where dom0 expects the injected agent to
  run, run OUR updater instead. The injected Python is accepted and discarded.

  The contract we must honour (verified in vmupdate/agent/source/common/exit_codes.py):
    progress = bare float lines 0..100 on STDERR, stdout = logs,
    exit 0 = success, exit 100 = no updates, anything else = error.
  wu-update.ps1 already implements it; this script only routes to it.

  SCOPE: invoked by VMExec.ps1 only for commands naming the updater workdir or entrypoint.py.
  Every other VMExec command runs through cmd.exe exactly as before.
#>
$a = @($args)
$Err = [Console]::Error
if ($a.Count -eq 0) { $Err.WriteLine('vmupdate-shim: no command'); exit 1 }

$qt = $env:QUBES_TOOLS
if (-not $qt) { $qt = 'C:\Program Files\Qubes Tools' }

# The log sink, from beside this script (docs/ADR-logging.md). Loaded BEFORE the Log below, so this
# script's own Log wins over log.ps1's. `exit`, not `throw`: VMExec runs this with `&`, where exit
# ends only this script and VMExec reads the code as $LASTEXITCODE and audits it, exactly as for
# Done; a throw would end VMExec itself before its audit line.
$qwtLogPs1 = Join-Path $PSScriptRoot 'log.ps1'
try { . $qwtLogPs1 } catch { $Err.WriteLine("vmupdate-shim.ps1: cannot load $qwtLogPs1 ($($_.Exception.Message)) - no log sink"); exit 1 }
if (-not (Get-Command Write-QwtLogLine -EA SilentlyContinue)) { $Err.WriteLine("vmupdate-shim.ps1: $qwtLogPs1 has no Write-QwtLogLine - no log sink"); exit 1 }

function Log($m) { Write-Output "vmupdate-shim: $m" }

# Audit trail. dom0 accumulates code = max(step codes) across the whole run, so ONE prep step
# returning nonzero makes a successful update report as an error - with nothing in dom0's output
# saying which step it was. Record every invocation and its exit code here instead of guessing.
# Its own file in the one log directory, vmupdate-shim.ps1-<yyyyMMdd>.log, even though it runs in
# VMExec's process (-Module names the file; without it the lines would land in VMExec's). Level I
# whatever the rc, like VMExec's own audit line: 100 is "no updates", and the updater logs its errors.
function Audit([string]$what) {
    $who = try { [Security.Principal.WindowsIdentity]::GetCurrent().Name } catch { '?' }
    $null = Write-QwtLogLine I "[$who] $what" -Module 'vmupdate-shim.ps1'
}
function Done([int]$rc, [string]$note) { Audit ("rc=$rc  $note  argv: " + ($a -join ' ')); exit $rc }
Audit ("ENTER argv: " + ($a -join ' '))

# dom0 speaks POSIX paths; a leading / means the root of the system drive here.
function ToWin([string]$p) {
    if ([string]::IsNullOrEmpty($p)) { return $p }
    $q = $p -replace '/', '\'
    if ($q.StartsWith('\')) { $q = $env:SystemDrive + $q }
    if ($q.Length -gt 3) { $q = $q.TrimEnd('\') }
    return $q
}
function Operands([string[]]$argv) {
    # NOTE the guard: in PowerShell `1..0` counts DOWNWARDS, so a single-element argv would
    # return $argv[1] (null) and $argv[0] - handing the command name back as an operand, i.e.
    # `rm` with no arguments would try to delete a file called "rm".
    if ($argv.Count -lt 2) { return @() }
    @($argv[1..($argv.Count - 1)] | Where-Object { $_ -notmatch '^-' })
}

# `fakeroot <cmd>` is how dom0 runs download-only passes; there is no such thing here.
if ([IO.Path]::GetFileName($a[0]) -eq 'fakeroot' -and $a.Count -gt 1) { $a = @($a[1..($a.Count-1)]) }

$verb = [IO.Path]::GetFileName($a[0]) -replace '\.exe$', ''

switch -Regex ($verb) {

    '^(mkdir|md)$' {
        foreach ($o in (Operands $a)) { New-Item -ItemType Directory -Force -Path (ToWin $o) -EA SilentlyContinue | Out-Null }
        Log "mkdir ok"
        Done 0 "mkdir"
    }

    '^rm$' {
        # The workdir itself is EMPTIED, not removed. When dom0 has no `vmexec` feature for this
        # qube it sends the tarball over VMShell as `cat > <workdir>/agent.tar.gz`, and cmd's
        # redirection needs the directory to already exist - otherwise cmd exits at once and
        # dom0 is left writing a megabyte into a closed pipe. See install-updater-agent.ps1 §8.
        foreach ($o in (Operands $a)) {
            $p = ToWin $o
            if ($p -match '\\run\\qubes-update\\?$') {
                Get-ChildItem -LiteralPath $p -Force -EA SilentlyContinue |
                    Remove-Item -Recurse -Force -EA SilentlyContinue
            } else {
                Remove-Item -LiteralPath $p -Recurse -Force -EA SilentlyContinue
            }
        }
        Log "rm ok"
        Done 0 "rm"
    }

    '^tar$' {
        # The archive holds dom0's Python agent, which cannot run here. Accept and discard:
        # reporting success is honest, because nothing downstream ever reads the extracted tree.
        Log 'accepted dom0 update agent archive (not used on Windows)'
        Done 0 "tar"
    }

    '^cat$' {
        # dom0 reads the agent log after a run. Emit ours if present; an absent log is not an error.
        foreach ($o in (Operands $a)) {
            $p = ToWin $o
            if (Test-Path -LiteralPath $p) { Get-Content -LiteralPath $p -EA SilentlyContinue }
        }
        $ours = 'C:\ProgramData\Qubes\update-status.json'
        if (Test-Path $ours) { Write-Output '--- qubes-windows-update status ---'; Get-Content $ours }
        Done 0 "cat"
    }

    '^python3?(\.exe)?$' {
        # THE point of all this: dom0 thinks it is running its injected agent; run ours.
        # --download-only must NOT install (dom0 owns that decision), so it gets its own task.
        $downloadOnly = ($a -contains '--download-only')
        $task = if ($downloadOnly) { 'QubesWindowsUpdateDownload' } else { 'QubesWindowsUpdateRun' }
        $wu = Join-Path $qt 'qubes-rpc-services\wu-update.ps1'
        if (-not (Test-Path $wu)) { $Err.WriteLine('vmupdate-shim: wu-update.ps1 missing - updater agent not installed'); Done 1 "entrypoint(missing handler)" }
        Log "running the Windows updater (task=$task)"
        & $wu -Task $task
        $rc = $LASTEXITCODE
        if ($null -eq $rc) { $rc = 0 }
        Done $rc "entrypoint"
    }

    default {
        # Anything else dom0 does to its injected agent is scaffolding that means nothing on
        # Windows, and must NOT be passed to cmd.exe: cmd fails on it, and dom0 keeps
        # code = max(all step codes), so one failing prep step makes a SUCCESSFUL update report
        # as an error. Measured 2026-08-13: `chmod u+x .../entrypoint.py` (a step not present in
        # the upstream master we read - the injection sequence differs between dom0 versions)
        # returned 1 through cmd and turned a completed update into an ERROR verdict.
        #
        # Only commands naming the updater workdir or entrypoint.py reach this script at all
        # (VMExec.ps1 scopes it), so a no-op is the correct answer for every unrecognised verb -
        # and it is future-proof against dom0 adding more of them. The audit log records each
        # one, so a step that turns out to MATTER is diagnosable rather than silent.
        Log "ignoring '$verb' (no-op on Windows; dom0's injected agent is never run here)"
        Done 0 "no-op:$verb"
    }
}
