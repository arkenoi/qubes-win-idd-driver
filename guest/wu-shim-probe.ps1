# Probe whether a Windows guest can answer dom0's stock qubes-vm-update command sequence.
# Read-only except for a throwaway C:\usr\bin\python3.bat and C:\run test dirs (removed at the end).
# Prints one JSON blob after === RESULT ===.
$ErrorActionPreference = 'Continue'
$r = [ordered]@{}

function RunCmd([string]$line) {
    # Route through cmd.exe exactly like VMExec.ps1 does (& cmd.exe /c $cmd).
    $o = & cmd.exe /c $line 2>&1 | Out-String
    return @{ rc = $LASTEXITCODE; out = ($o.Trim() -replace '\s+', ' ') }
}

# 1. tar: Windows ships bsdtar since 1803 - does dom0's `tar -xzf` have a chance?
$t = RunCmd 'tar --version'
$r.tar = $t

# 2. mkdir -p /run/qubes-update/  (dom0 step 2, forward slashes, POSIX -p flag)
$t = RunCmd 'mkdir -p /run/qubes-update/'
$r.mkdir = $t
$r.mkdir_made_workdir = (Test-Path 'C:\run\qubes-update')
$r.mkdir_made_junk_p  = (Test-Path 'C:\-p')

# 3. leading-slash program resolution: can cmd find C:\usr\bin\python3.* from "/usr/bin/python3"?
New-Item -ItemType Directory -Force -Path 'C:\usr\bin' | Out-Null
Set-Content -Path 'C:\usr\bin\python3.bat' -Value @'
@echo off
echo SHIM-OK args=%*
exit /b 100
'@ -Encoding ASCII
$t = RunCmd '/usr/bin/python3 /run/qubes-update/agent/entrypoint.py --no-progress'
$r.slashpath_bat = $t
# same thing with backslashes, as a control
$t = RunCmd 'C:\usr\bin\python3.bat --control'
$r.backslash_control = $t

# 4. cat: absent on stock Windows? (dom0 pipes the agent tarball through `cat > file`)
$t = RunCmd 'where cat'
$r.cat_present = $t
$t = RunCmd 'where rm'
$r.rm_present = $t

# 5. what QWT exposes
$r.qubes_tools = $env:QUBES_TOOLS
$r.vmexec_svc  = (Test-Path (Join-Path $env:QUBES_TOOLS 'qubes-rpc\qubes.VMExec'))
$r.vmshell_svc = (Test-Path (Join-Path $env:QUBES_TOOLS 'qubes-rpc\qubes.VMShell'))
$r.updater_svc = (Test-Path (Join-Path $env:QUBES_TOOLS 'qubes-rpc\qubes.WindowsUpdate'))
$r.pathext     = $env:PATHEXT

# 6. current auto-update policy state (should end up NoAutoUpdate=1 when we ship)
$au = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
$r.au_policy_key = (Test-Path $au)
if (Test-Path $au) { $r.au_noautoupdate = (Get-ItemProperty $au).NoAutoUpdate } else { $r.au_noautoupdate = $null }

# cleanup of probe leftovers (keep nothing behind; the real shim lands via the installer)
Remove-Item 'C:\usr\bin\python3.bat' -Force -EA SilentlyContinue
Remove-Item 'C:\usr' -Recurse -Force -EA SilentlyContinue
Remove-Item 'C:\run' -Recurse -Force -EA SilentlyContinue
Remove-Item 'C:\-p'  -Recurse -Force -EA SilentlyContinue

Write-Output '=== RESULT ==='
$r | ConvertTo-Json -Depth 4 -Compress
