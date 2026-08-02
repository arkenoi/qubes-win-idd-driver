# Acceptance for the blank-synthesized-menu fix (user-reported: a dropdown renders as a blank
# rectangle in dom0 until the cursor moves INTO it, which generates real repaint damage).
#
# The test must produce a menu on an otherwise COMPLETELY STATIC screen: no mouse motion, no
# typing, nothing that would generate a DDA frame. That is the condition the old code could
# not heal, and it is also the condition none of the existing scripted checks create - they
# all generate continuous damage, which is why the automated suite never caught this.
#
# Opens the menu by KEYBOARD (Alt+F) so the cursor never moves, then sits still.
# Run it, wait, then take a VM-scoped screenshot from the mgmt qube WITHOUT touching the guest:
#   tools/qtest shot menu.tar     # the menu is synthesized INTO the owner, so it must appear
#                                 # inside the Notepad window's own PNG
param([int]$HoldSeconds = 45)
$ErrorActionPreference = 'SilentlyContinue'

Get-Process notepad -EA SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 2
Start-Process notepad
Start-Sleep -Seconds 3

Add-Type -TypeDefinition @"
using System;using System.Runtime.InteropServices;
public class K {
  [DllImport("user32.dll")] public static extern IntPtr FindWindowW(string c,string w);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out R r);
  [StructLayout(LayoutKind.Sequential)] public struct R { public int l,t,rr,b; }
}
"@
$h = [K]::FindWindowW("Notepad", $null)
if ($h -eq [IntPtr]::Zero) { "RESULT=ERROR no notepad"; exit 1 }
[void][K]::SetForegroundWindow($h)
Start-Sleep -Seconds 1
$r = New-Object K+R; [void][K]::GetWindowRect($h, [ref]$r)
"OWNER_HWND=0x{0:x}" -f $h.ToInt64()
"OWNER_RECT=$($r.l),$($r.t),$($r.rr),$($r.b)"

# Alt+F opens the File menu with NO pointer involvement.
$w = New-Object -ComObject WScript.Shell
$w.SendKeys('%f')
"MENU_OPENED=$(Get-Date -Format o)"

# From here on the screen is static by construction: no input, no cursor motion. A correct
# build must fill the menu in from the synth re-patch path alone.
Start-Sleep -Seconds $HoldSeconds
"STILL_OPEN=$(Get-Date -Format o)"
"RESULT=MENU_STATIC_HELD"
