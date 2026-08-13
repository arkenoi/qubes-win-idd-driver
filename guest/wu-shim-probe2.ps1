# What tooling does the guest already have for the vmupdate shim?
$ErrorActionPreference = 'Continue'
$qt = $env:QUBES_TOOLS
$r = [ordered]@{}
$r.qubes_tools = $qt
$r.exes = @(Get-ChildItem -Path $qt -Recurse -Include *.exe -EA SilentlyContinue |
            Select-Object -ExpandProperty Name | Sort-Object -Unique)
$r.qubesdb_any = @(Get-ChildItem -Path $qt -Recurse -EA SilentlyContinue |
            Where-Object { $_.Name -match 'qubesdb' } | Select-Object -ExpandProperty FullName)
$r.rpc_services = @(Get-ChildItem -Path (Join-Path $qt 'qubes-rpc') -EA SilentlyContinue |
            Select-Object -ExpandProperty Name)
$r.rpc_handlers = @(Get-ChildItem -Path (Join-Path $qt 'qubes-rpc-services') -EA SilentlyContinue |
            Select-Object -ExpandProperty Name)
$r.vmexec_ps1 = (Get-Content (Join-Path $qt 'qubes-rpc-services\VMExec.ps1') -Raw -EA SilentlyContinue)
$r.csc = (Test-Path (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'))
$r.machine_path = [Environment]::GetEnvironmentVariable('Path','Machine')
Write-Output '=== RESULT ==='
$r | ConvertTo-Json -Depth 4 -Compress
