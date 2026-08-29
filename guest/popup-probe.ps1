# Open Explorer and deliberately raise its INLINE POPUPS, so they can be checked both by eye in
# dom0 and by attribute in the dialog-catch log.
#
# WHY: the IsPopup() change (2026-08-30) promotes a caption-less window carrying WS_EX_APPWINDOW
# from override-redirect to a normal, dom0-bordered window - the fix for the Windows Update system
# dialog arriving with no trust border. The owner's standing constraint on that change: "make sure
# we won't break regular app inline pop-ups", and "they ARE override redirect if we fail to
# synthesize them, but standalone stuff should not be granted this capability".
#
# Explorer is the sharpest test available without installing anything: its address-bar dropdown,
# context menus and search suggestions are all caption-less popups. If the change were too broad,
# these would acquire dom0 title bars and frames - immediately visible, and immediately wrong.
#
# ACCEPTANCE, by eye in dom0:
#   Explorer's own window  -> ONE bordered window (it has WS_CAPTION; unchanged by the fix)
#   address-bar dropdown   -> borderless, floating, no title bar
#   context menu           -> borderless, no title bar
# and in C:\dialog-catch.log every popup raised here must still read AGENT_OR=True.
#
# Run guest/dialog-catch.ps1 FIRST so the popups are recorded as they appear.
[CmdletBinding()]
param([int]$HoldSeconds = 8)
$ErrorActionPreference = 'Continue'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -Namespace P -Name N -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
// FindWindowW is NOT used to locate Explorer. Measured 2026-08-30, in one process and one
// breath: FindWindowW("CabinetWClass", null) returned 0 while EnumWindows found FOUR visible
// CabinetWClass windows. Adding CharSet.Unicode did not help, so it is not a marshaling fault -
// CabinetWClass is registered per-process by Explorer, and the class-name-to-atom lookup does not
// resolve across the process boundary. This probe reported "EXPLORER_WINDOW=absent" twice while
// Explorer was plainly on screen. Enumerate instead.
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc cb, IntPtr p);
public delegate bool EnumWindowsProc(IntPtr h, IntPtr p);
[DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, System.Text.StringBuilder s, int n);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
'@

Write-Output '=== RESULT ==='

# A real Explorer window (not the desktop): open This PC.
Start-Process explorer.exe 'shell:MyComputerFolder'
Start-Sleep -Seconds 6

# CabinetWClass is Explorer's browser frame. If it never appears, say so - a probe that silently
# raised nothing would let a "no misbehaviour" verdict rest on nothing having been tested.
$found = New-Object System.Collections.ArrayList
$cb = [P.N+EnumWindowsProc]{
    param($h, $p)
    if ([P.N]::IsWindowVisible($h)) {
        $sb = New-Object System.Text.StringBuilder 256
        [void][P.N]::GetClassNameW($h, $sb, 256)
        if ($sb.ToString() -eq 'CabinetWClass') { [void]$found.Add($h) }
    }
    return $true
}
[void][P.N]::EnumWindows($cb, [IntPtr]::Zero)
$hwnd = if ($found.Count -gt 0) { $found[0] } else { [IntPtr]::Zero }
Write-Output ("EXPLORER_WINDOWS_FOUND=" + $found.Count)
if ($hwnd -eq [IntPtr]::Zero) {
    Write-Output 'EXPLORER_WINDOW=absent  (probe raised nothing - do NOT read this run as a pass)'
    exit 1
}
Write-Output ("EXPLORER_WINDOW=0x{0:X}" -f [int64]$hwnd)
[void][P.N]::ShowWindow($hwnd, 9)      # SW_RESTORE
[void][P.N]::SetForegroundWindow($hwnd)
Start-Sleep -Seconds 2

# 1. Address-bar dropdown: F4 drops the combo list - a classic owned, caption-less popup.
Write-Output 'POPUP=address-bar-dropdown (F4)'
[System.Windows.Forms.SendKeys]::SendWait('{F4}')
Start-Sleep -Seconds $HoldSeconds
[System.Windows.Forms.SendKeys]::SendWait('{ESC}')
Start-Sleep -Seconds 2

# 2. Context menu: Shift+F10 on the file list - an owned menu, must stay override-redirect.
Write-Output 'POPUP=context-menu (Shift+F10)'
[System.Windows.Forms.SendKeys]::SendWait('+{F10}')
Start-Sleep -Seconds $HoldSeconds
[System.Windows.Forms.SendKeys]::SendWait('{ESC}')
Start-Sleep -Seconds 2

Write-Output 'PROBE_DONE (Explorer left open for visual inspection in dom0)'
