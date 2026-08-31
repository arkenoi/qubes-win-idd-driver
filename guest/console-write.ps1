# console-write.ps1 - write a line from the guest into the XEN PV CONSOLE RING.
#
# WHY THIS IS THE INTERESTING DIRECTION. A Linux guest fills
# /var/log/xen/console/guest-<vm>.log with its kernel console; a Windows guest writes nothing,
# so that file has always been empty here apart from firmware output. But xenconsoled captures
# that ring CONTINUOUSLY in dom0, whether or not anyone is attached - which makes it the only
# RETROACTIVE channel this project has. Anything written here survives the failure that takes
# qrexec, window capture and the event log out together, and is readable afterwards with no
# guest cooperation at all.
#
# PROVEN 2026-09-01 on win10-app: a second handle on the console device, written from an
# ordinary user-mode process, was received in the dev qube over admin.vm.Console - including
# bytes written while NO reader was attached.
#
# HOW IT WORKS. xencons.sys keeps a per-FileObject handle list and xencons_monitor opens the
# device with FILE_SHARE_READ|FILE_SHARE_WRITE, so opening a SECOND handle is legitimate and
# does not disturb the interactive xencons_tty session sharing the same ring.
#
# THE TRAP THAT COST A ROUND HERE: calling WriteFile through Add-Type -MemberDefinition with an
# `out uint` parameter returned wrote=0 err=0 - a silent no-op, not an error. The whole call has
# to live in a real C# type. Same failure class as the qubesdb P/Invoke bug this repo already
# recorded ("unreadable in a Windows guest" was marshalling, not a missing capability).
#
# CAUTIONS.
#  - Contents cross an isolation boundary into a dom0-readable file. dom0 must treat them as
#    DATA: sanitise before display (a guest can emit ANSI escapes and newlines), never eval.
#  - Volume is not bounded by anything here. A chatty caller can grow a dom0 log file. Keep
#    lines short and rate-limit; this is for phase markers and failures, not a debug firehose.
#  - It interleaves with the interactive console session, so anyone attached sees these lines
#    scroll past their prompt. Prefix every line so they are filterable.
#  - It is user-mode and needs xencons loaded: nothing before PnP starts it, and nothing while
#    the guest is wedged at high IRQL (which is the measured wedge here).
#
# Usage:  .\console-write.ps1 "AGENT: seamless mode entered"
#         .\console-write.ps1 -Tag IDD "mode list updated to 2560x1080"
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)] [string] $Message,
    [string] $Tag = 'QWT'
)

$ErrorActionPreference = 'Stop'

$guid = '{0d3edd21-8ef9-4dff-856c-8c68bf4fdca3}'   # GUID_XENCONS_DEVICE
$base = "HKLM:\SYSTEM\CurrentControlSet\Control\DeviceClasses\$guid"

# The interface KEY NAME is the symbolic link with its leading separators escaped as '#'.
# Do NOT look for a '#' subkey holding SymbolicLink - that layout is not present on 19045,
# and assuming it was is why the first attempt reported "no interface" on a bound driver.
$key = (Get-ChildItem $base -ErrorAction SilentlyContinue | Select-Object -First 1).PSChildName
if (-not $key) {
    Write-Error "no XENCONS device interface - is xencons bound? (XENBUS\VEN_XP0001&DEV_CONS)"
    exit 1
}
$path = '\\?\' + $key.Substring(4)

if (-not ('QubesConsoleWriter' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class QubesConsoleWriter {
  [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
  static extern IntPtr CreateFileW(string p, uint acc, uint share, IntPtr sa, uint disp, uint fl, IntPtr t);
  [DllImport("kernel32.dll", SetLastError=true)]
  static extern bool WriteFile(IntPtr h, byte[] b, uint n, out uint w, IntPtr o);
  [DllImport("kernel32.dll", SetLastError=true)]
  static extern bool CloseHandle(IntPtr h);
  // GENERIC_WRITE, FILE_SHARE_READ|WRITE, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL
  public static string Send(string path, string msg) {
    IntPtr h = CreateFileW(path, 0x40000000u, 3u, IntPtr.Zero, 3u, 0x80u, IntPtr.Zero);
    if (h == new IntPtr(-1)) return "OPEN_FAILED err=" + Marshal.GetLastWin32Error();
    byte[] b = System.Text.Encoding.ASCII.GetBytes(msg);
    uint w = 0;
    bool ok = WriteFile(h, b, (uint)b.Length, out w, IntPtr.Zero);
    int err = Marshal.GetLastWin32Error();
    CloseHandle(h);
    return ok && w == b.Length ? "OK" : ("WRITE_FAILED wrote=" + w + "/" + b.Length + " err=" + err);
  }
}
'@
}

# Strip control characters: this line ends up in a dom0 log, and a guest emitting escape
# sequences into someone's terminal is a real (if minor) injection surface. Sanitise at the
# source as well as on read.
$clean = ($Message -replace '[\x00-\x1f\x7f]', ' ')
$line = "[{0}] {1} {2}`r`n" -f $Tag, (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss.fffK'), $clean

$result = [QubesConsoleWriter]::Send($path, $line)
if ($result -ne 'OK') { Write-Error "console write failed: $result"; exit 1 }
Write-Output "OK $($line.TrimEnd())"
