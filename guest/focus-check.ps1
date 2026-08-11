# Record the current foreground window (handle + title + process) - used before/after
# firing a toast to prove the WM-managed toast does not steal guest focus.
$ErrorActionPreference = 'Continue'
Add-Type -Namespace F -Name W -MemberDefinition @'
[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr h, System.Text.StringBuilder s, int m);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
'@
$h = [F.W]::GetForegroundWindow()
$t = New-Object Text.StringBuilder 256
[void][F.W]::GetWindowTextW($h, $t, 256)
$p = 0; [void][F.W]::GetWindowThreadProcessId($h, [ref]$p)
$pn = (Get-Process -Id $p -ErrorAction SilentlyContinue).Name
Write-Output '=== RESULT ==='
@{ fg = ('0x{0:X}' -f $h.ToInt64()); title = $t.ToString(); process = $pn } | ConvertTo-Json -Compress
