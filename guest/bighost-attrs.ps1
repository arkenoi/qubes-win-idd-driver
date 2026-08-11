# Find the CREATE line for the workarea-sized shell window in the newest agent log, then
# dump that HWND's class/styles/owner/cloak - the attributes IsShellToastWindow gates on.
$ErrorActionPreference = 'Continue'
$logdir = (Get-ItemProperty 'HKLM:\SOFTWARE\Invisible Things Lab\Qubes Tools' -ErrorAction SilentlyContinue).LogDir
if (-not $logdir) { $logdir = 'Q:\Qubes Logs' }
$log = Get-ChildItem $logdir -Filter 'gui-agent-*.log' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
$line = Get-Content $log.FullName | Select-String 'msg=CREATE,hwnd=(0x[0-9a-f]+).*w=5120,h=1384' | Select-Object -Last 1
Write-Output "=== RESULT ==="
if (-not $line) { Write-Output '{"error":"no 5120x1384 CREATE line"}'; exit }
$h = [IntPtr][Convert]::ToInt64($line.Matches[0].Groups[1].Value, 16)
Add-Type -Namespace B -Name W -MemberDefinition @'
[DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, System.Text.StringBuilder s, int m);
[DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int i);
[DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr h, uint c);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
[DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int a, out int v, int s);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
'@
$cls = New-Object Text.StringBuilder 256; [void][B.W]::GetClassName($h, $cls, 256)
$style = [B.W]::GetWindowLong($h, -16); $ex = [B.W]::GetWindowLong($h, -20)
$cloak = 0; [void][B.W]::DwmGetWindowAttribute($h, 14, [ref]$cloak, 4)
$procId = 0; [void][B.W]::GetWindowThreadProcessId($h, [ref]$procId)
$pn = (Get-Process -Id $procId -ErrorAction SilentlyContinue).Name
@{ hwnd = ('0x{0:X}' -f $h.ToInt64()); cls = $cls.ToString(); proc = $pn;
   style = ('0x{0:X8}' -f $style); ex = ('0x{0:X8}' -f $ex);
   topmost = [bool]($ex -band 0x8); noredir = [bool]($ex -band 0x200000);
   transparent = [bool]($ex -band 0x20); toolwin = [bool]($ex -band 0x80);
   owner = ('0x{0:X}' -f [B.W]::GetWindow($h,4).ToInt64()); cloak = $cloak;
   visible = [B.W]::IsWindowVisible($h) } | ConvertTo-Json
