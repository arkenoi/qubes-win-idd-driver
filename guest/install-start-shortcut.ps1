# Install the Start-menu opener + all-users .lnk (mirrors the Install-QwtImproved.ps1
# stage-2 block). Everything is WINDOWLESS: wscript has no console, so nothing flashes a
# a powershell launcher, even -WindowStyle Hidden, flashes a conhost window and kills Start).
# The keypress is VK_LWIN injected GUEST-side, so it is unaffected by the agent's
# BlockMenuKey filter (which drops the dom0-forwarded Super key).
#
# -Remove deletes the shortcut (and the opener), which is how the "Start Menu" entry disappears
# from the qube's application shortcuts in dom0. A guest running a THIRD-PARTY SHELL - OpenShell
# and friends - should not advertise an opener for the stock Windows Start menu it does not use.
# That case is detected automatically from the same dom0 knob that frees the Super key:
#
#     qvm-features <vm> service.enableWinKey 1
#
# so a qube configured for OpenShell installs no stock-Start entry, and an existing one is removed
# on the next run. Pass -Force to install it regardless.
#
# NOTE for the operator: dom0 caches the app list. After this runs, the entry only disappears once
# dom0 re-reads it - `qvm-sync-appmenus <vm>` (or the Qube Settings "Applications" refresh).
param([switch]$Remove, [switch]$Force)
$ErrorActionPreference = 'Continue'
$qtBin = 'C:\Program Files\Qubes Tools\bin'

# Is this guest running its own shell? The dom0 feature is exported to the guest's qubesdb as
# /qubes-service/enableWinKey. Read it via the qubesdb client DLL (qdb_open/qdb_read) - the
# qubesdb-cmd CLI returns EMPTY for reads on this build (the optind bug), so the previous CLI
# read here ALWAYS saw "unset" and never suppressed the shortcut for a third-party-shell guest.
# Mirrors the canonical guest/qubesdb-read.ps1.
$thirdPartyShell = $false
try {
    if (-not ('QdbShell' -as [type])) {
        Add-Type @'
using System; using System.Runtime.InteropServices;
public static class QdbShell {
    [DllImport("qubesdb-client.dll", CallingConvention=CallingConvention.Cdecl)]
    public static extern IntPtr qdb_open(IntPtr vmname);
    [DllImport("qubesdb-client.dll", CallingConvention=CallingConvention.Cdecl, CharSet=CharSet.Ansi)]
    public static extern IntPtr qdb_read(IntPtr h, string path, out uint value_len);
    [DllImport("qubesdb-client.dll", CallingConvention=CallingConvention.Cdecl)]
    public static extern void qdb_close(IntPtr h);
}
'@
    }
    $h = [QdbShell]::qdb_open([IntPtr]::Zero)
    if ($h -ne [IntPtr]::Zero) {
        $len = [uint32]0
        $p = [QdbShell]::qdb_read($h, '/qubes-service/enableWinKey', [ref]$len)
        if ($p -ne [IntPtr]::Zero) {
            $v = [Runtime.InteropServices.Marshal]::PtrToStringAnsi($p, [int]$len)
            if ($v -and "$v".Trim() -ne '0') { $thirdPartyShell = $true }
        }
        [QdbShell]::qdb_close($h)
    }
} catch { }

$lnkDirEarly = 'C:\ProgramData\Microsoft\Windows\Start Menu\Programs'
$lnkPathEarly = Join-Path $lnkDirEarly 'Start Menu.lnk'
if ($Remove -or ($thirdPartyShell -and -not $Force)) {
    $had = Test-Path $lnkPathEarly
    Remove-Item -LiteralPath $lnkPathEarly -Force -EA SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $qtBin 'open-start-menu.vbs') -Force -EA SilentlyContinue
    $why = if ($Remove) { 'requested' } else { 'enableWinKey set - guest runs its own shell' }
    @{ removed = $had; reason = $why; lnk = (Test-Path $lnkPathEarly) } | ConvertTo-Json -Compress
    return
}
$vbsPath = Join-Path $qtBin 'open-start-menu.vbs'
@'
' Open the Windows Start menu (dom0 qube-app shortcut target).
' wscript.exe is windowless and Run(...,0) hides the powershell console, so nothing ever
' flashes a window - a console flash steals focus and dismisses the very menu we open
' (measured 2026-08-12). VK_LWIN is injected GUEST-side, so the agent's BlockMenuKey
' filter (which drops the dom0-forwarded Super key) does not apply.
Dim sh, fso, ps
Set sh = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
ps = fso.GetSpecialFolder(2) & "\qwt-winkey.ps1"
Dim f
Set f = fso.CreateTextFile(ps, True)
f.WriteLine "Add-Type -Namespace W -Name K -MemberDefinition '[DllImport(\"user32.dll\")] public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);'"
f.WriteLine "Start-Sleep -Milliseconds 400"
f.WriteLine "[W.K]::keybd_event(0x5B,0,0,[UIntPtr]::Zero)"
f.WriteLine "Start-Sleep -Milliseconds 80"
f.WriteLine "[W.K]::keybd_event(0x5B,0,2,[UIntPtr]::Zero)"
f.Close
sh.Run "powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File """ & ps & """", 0, False
'@ | Set-Content -LiteralPath $vbsPath -Encoding ASCII

$lnkDir = 'C:\ProgramData\Microsoft\Windows\Start Menu\Programs'
$lnkPath = Join-Path $lnkDir 'Start Menu.lnk'
$wsh = New-Object -ComObject WScript.Shell
$lnk = $wsh.CreateShortcut($lnkPath)
$lnk.TargetPath = 'C:\Windows\System32\wscript.exe'
$lnk.Arguments = "//B //Nologo `"$vbsPath`""
$lnk.WorkingDirectory = $qtBin
$lnk.Description = 'Open the Windows Start menu'
$lnk.Save()
Write-Output '=== RESULT ==='
@{ vbs = (Test-Path $vbsPath); lnk = (Test-Path $lnkPath) } | ConvertTo-Json -Compress
