# guest/qubesdb-read.ps1 - the RELIABLE qubesdb value read for the Windows guest.
#
# History worth remembering: for weeks this project believed qubesdb was "unreadable in a Windows
# guest" and built workarounds around that belief - deploy-time registry stamps for the VM class,
# a network-setup.exe exit-code oracle, log scraping. That belief was FALSE. It was a P/Invoke
# marshaling bug, not a real limit. The C gui-agent reads qubesdb natively (qdb_open/qdb_read
# against qubesdb-client.dll, which ships in C:\Windows\System32); PowerShell reads it identically
# once the DllImport uses the Cdecl calling convention + Ansi marshaling and passes the NULL
# vmname as IntPtr.Zero. Measured working in plain user context (WIN-IDD-TEST\user) 2026-08-19,
# reading /name, /type, /qubes-vm-type, /qubes-vm-updateable off both a StandaloneVM and a
# TemplateVM. WRITE is a separate story and DOES remain broken through the qubesdb-cmd CLI (the
# optind bug); this helper is READ-only, which is all the guest ever needs - dom0 owns the writes.
#
# Usage:  . <path>\qubesdb-read.ps1 ; $cls = Get-QubesVmClass ; $ip = Get-QubesDbValue '/qubes-ip'
# Run directly for a self-test.
#
# NOTE: the updater (guest/qubes-windows-update.ps1) and the installer (Install-QwtImproved.ps1)
# carry INLINE mirrors of Get-QubesDbValue rather than dot-sourcing this file - they must stay
# self-contained on the deployed medium. Keep the three in sync.

function Get-QubesDbValue {
    param([Parameter(Mandatory)][string]$Path)
    try {
        if (-not ('QubesDbClient' -as [type])) {
            Add-Type @'
using System; using System.Runtime.InteropServices;
public static class QubesDbClient {
    [DllImport("qubesdb-client.dll", CallingConvention=CallingConvention.Cdecl)]
    public static extern IntPtr qdb_open(IntPtr vmname);
    [DllImport("qubesdb-client.dll", CallingConvention=CallingConvention.Cdecl, CharSet=CharSet.Ansi)]
    public static extern IntPtr qdb_read(IntPtr h, string path, out uint value_len);
    [DllImport("qubesdb-client.dll", CallingConvention=CallingConvention.Cdecl)]
    public static extern void qdb_close(IntPtr h);
}
'@
        }
        $h = [QubesDbClient]::qdb_open([IntPtr]::Zero)
        if ($h -eq [IntPtr]::Zero) { return $null }
        try {
            $len = [uint32]0
            $p = [QubesDbClient]::qdb_read($h, $Path, [ref]$len)
            if ($p -eq [IntPtr]::Zero) { return $null }   # key absent
            # The returned buffer is heap-allocated by qubesdb-client and leaks (no qdb_free is
            # exported and calling the CRT free from PS is unsafe) - a few bytes per read, fine.
            return [Runtime.InteropServices.Marshal]::PtrToStringAnsi($p, [int]$len)
        } finally { [QubesDbClient]::qdb_close($h) }
    } catch { return $null }
}

# The qube's class - the single most-asked question. /type is the exact Python class name
# (StandaloneVM/TemplateVM/AppVM/DispVM). If /type is somehow absent, fall back to the pair
# /qubes-vm-type (collapses Standalone+App to 'AppVM') + /qubes-vm-updateable (True splits
# Standalone from App). Returns $null only if qubesdb is genuinely unreadable.
function Get-QubesVmClass {
    $t = Get-QubesDbValue '/type'
    if ($t) { return $t }
    $vt = Get-QubesDbValue '/qubes-vm-type'
    if (-not $vt) { return $null }
    if ($vt -eq 'TemplateVM') { return 'TemplateVM' }
    if ((Get-QubesDbValue '/qubes-vm-updateable') -eq 'True') { return 'StandaloneVM' }
    return 'AppVM'
}

# Boolean Qubes service feature (/qubes-service/<name>): '1'/'true' -> $true, absent/'0' -> $false.
function Test-QubesService {
    param([Parameter(Mandatory)][string]$Name)
    $v = Get-QubesDbValue "/qubes-service/$Name"
    return ($v -and "$v".Trim() -ne '0')
}

# Run directly (not dot-sourced) -> self-test.
if ($MyInvocation.InvocationName -ne '.') {
    foreach ($k in '/name','/type','/qubes-vm-type','/qubes-vm-updateable',
                   '/qubes-service/enableWinKey','/qubes-ip','/qubes-gateway') {
        $v = Get-QubesDbValue $k
        Write-Output ("QDB $k = " + $(if ($null -eq $v) { '<absent>' } else { "[$v]" }))
    }
    Write-Output ("QDB class          = " + (Get-QubesVmClass))
    Write-Output ("QDB svc enableWinKey = " + (Test-QubesService 'enableWinKey'))
}
