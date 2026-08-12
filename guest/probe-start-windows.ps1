# Dump every StartMenuExperienceHost / ShellExperienceHost / SearchHost top-level window
# with the attributes the acceptance predicate uses: styles, exstyles, DWM cloak state,
# owner, visible, rect. Distinguishes a genuinely-open Start from its persistent phantom.
$ErrorActionPreference = 'Continue'
Add-Type -Namespace P -Name S -MemberDefinition @'
public delegate bool EnumProc(System.IntPtr h, System.IntPtr l);
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc p, System.IntPtr l);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(System.IntPtr h);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(System.IntPtr h, out uint pid);
[DllImport("user32.dll")] public static extern int GetWindowLong(System.IntPtr h, int i);
[DllImport("user32.dll")] public static extern int GetWindowLongW(System.IntPtr h, int i);
[DllImport("user32.dll")] public static extern bool GetWindowRect(System.IntPtr h, out RECT r);
[DllImport("user32.dll")] public static extern System.IntPtr GetWindow(System.IntPtr h, uint c);
[DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(System.IntPtr h, System.Text.StringBuilder s, int n);
[DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(System.IntPtr h, int a, out int v, int s);
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int L,T,R,B; }
'@
$pids = @{}
foreach ($n in 'StartMenuExperienceHost','ShellExperienceHost','SearchHost') {
    foreach ($p in Get-Process $n -ErrorAction SilentlyContinue) { $pids[[uint32]$p.Id] = $n }
}
$rows = New-Object System.Collections.Generic.List[string]
$cb = [P.S+EnumProc]{ param($h,$l)
    $pid2=[uint32]0; [void][P.S]::GetWindowThreadProcessId($h,[ref]$pid2)
    if ($pids.ContainsKey($pid2)) {
        $cn = New-Object System.Text.StringBuilder 256; [void][P.S]::GetClassName($h,$cn,256)
        $r = New-Object P.S+RECT; [void][P.S]::GetWindowRect($h,[ref]$r)
        $style = [P.S]::GetWindowLongW($h,-16); $ex = [P.S]::GetWindowLongW($h,-20)
        $cloak=0; [void][P.S]::DwmGetWindowAttribute($h,14,[ref]$cloak,4)
        $owner = [P.S]::GetWindow($h,4)
        $vis = [P.S]::IsWindowVisible($h)
        $rows.Add(('0x{0:X} proc={1} class={2} vis={3} cloak={4} style=0x{5:X8} ex=0x{6:X8} owner=0x{7:X} rect={8},{9},{10}x{11}' -f `
            $h.ToInt64(), $pids[$pid2], $cn.ToString(), $vis, $cloak, ($style -band 0xFFFFFFFFL), ($ex -band 0xFFFFFFFFL), $owner.ToInt64(), $r.L, $r.T, ($r.R-$r.L), ($r.B-$r.T)))
    }
    $true }
[void][P.S]::EnumWindows($cb,[System.IntPtr]::Zero)
Write-Output '=== START WINDOWS ==='
$rows
Write-Output ('count=' + $rows.Count)
Write-Output '=== END ==='
