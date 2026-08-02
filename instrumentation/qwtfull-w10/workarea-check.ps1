<#
    Work-area / maximized-window check (handoff step 5.4).
    Launches Notepad, maximizes it (ShowWindow SW_MAXIMIZE), reports:
      - guest screen size (SM_CXSCREEN/SM_CYSCREEN)
      - guest SPI_GETWORKAREA before launch and after maximize
      - the maximized window rect (GetWindowRect) + IsZoomed
      - which work-area source could have engaged: registry WorkArea value,
        qubesdb /qubes-workarea, or inference (visible in agent log)
      - all 'work area' lines from the NEWEST gui-agent log (incl.
        WorkAreaCreateListener errors - 0x5 was a Win11 defect)
    Emits RESULT_* / WALINE| markers; leaves Notepad OPEN for the dom0 fullshot.
    Run: tools/qtest pushrun instrumentation/qwtfull-w10/workarea-check.ps1
#>
$ErrorActionPreference = 'Continue'
Add-Type -Namespace Q -Name WA -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)] public struct RECT { public int left, top, right, bottom; }
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
[DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
[DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr h);
[DllImport("user32.dll", SetLastError=true)] public static extern bool SystemParametersInfo(uint action, uint p, out RECT r, uint f);
[DllImport("user32.dll")] public static extern int GetSystemMetrics(int i);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
'@

$r = New-Object 'Q.WA+RECT'
[void][Q.WA]::SystemParametersInfo(0x30, 0, [ref]$r, 0)   # SPI_GETWORKAREA
Write-Output "RESULT_GUEST_WORKAREA_BEFORE=$($r.left),$($r.top),$($r.right),$($r.bottom)"
Write-Output "RESULT_GUEST_SCREEN=$([Q.WA]::GetSystemMetrics(0))x$([Q.WA]::GetSystemMetrics(1))"

# --- work-area source evidence -------------------------------------------
foreach ($k in 'HKLM:\SOFTWARE\Invisible Things Lab\Qubes Tools',
               'HKLM:\SOFTWARE\Invisible Things Lab\Qubes Tools\gui-agent') {
    $p = Get-ItemProperty -Path $k -EA SilentlyContinue
    $tag = $k -replace '.*Qubes Tools\\?', 'base'
    if ($p -and $p.PSObject.Properties['WorkArea']) {
        Write-Output "RESULT_REG_WORKAREA[$tag]=$($p.WorkArea)"
    } else {
        Write-Output "RESULT_REG_WORKAREA[$tag]=absent"
    }
}
$qdbread = 'C:\Program Files\Qubes Tools\bin\qubesdb-read.exe'
if (Test-Path $qdbread) {
    $qv = & $qdbread /qubes-workarea 2>&1
    Write-Output "RESULT_QDB_WORKAREA=rc$LASTEXITCODE val=[$qv]"
} else {
    Write-Output "RESULT_QDB_WORKAREA=no-qubesdb-read.exe"
}

# --- launch + maximize Notepad -------------------------------------------
$np = Start-Process notepad -PassThru
[void]$np.WaitForInputIdle(10000)
for ($i = 0; $i -lt 50 -and $np.MainWindowHandle -eq 0; $i++) {
    Start-Sleep -Milliseconds 100; $np.Refresh()
}
if ($np.MainWindowHandle -eq 0) { Write-Output 'RESULT_ERROR=no_main_window'; exit 1 }
Write-Output "RESULT_NOTEPAD_PID=$($np.Id)"
[void][Q.WA]::SetForegroundWindow($np.MainWindowHandle)
Start-Sleep -Milliseconds 300
[void][Q.WA]::ShowWindow($np.MainWindowHandle, 3)   # SW_MAXIMIZE
Start-Sleep -Seconds 2

$w = New-Object 'Q.WA+RECT'
[void][Q.WA]::GetWindowRect($np.MainWindowHandle, [ref]$w)
Write-Output "RESULT_GUEST_WINRECT=$($w.left),$($w.top),$($w.right),$($w.bottom)"
Write-Output "RESULT_ZOOMED=$([Q.WA]::IsZoomed($np.MainWindowHandle))"

[void][Q.WA]::SystemParametersInfo(0x30, 0, [ref]$r, 0)
Write-Output "RESULT_GUEST_WORKAREA_AFTER=$($r.left),$($r.top),$($r.right),$($r.bottom)"

# --- newest agent log: work-area lines -----------------------------------
$log = Get-ChildItem 'C:\Program Files\Qubes Tools\log\gui-agent-*.log' |
       Sort-Object LastWriteTime -Descending | Select-Object -First 1
Write-Output "RESULT_LOG=$($log.Name)"
Select-String -Path $log.FullName -Pattern 'work.?area' |
    ForEach-Object { Write-Output "WALINE|$($_.Line)" }
$cnt = (Select-String -Path $log.FullName -Pattern 'work.?area' -EA SilentlyContinue | Measure-Object).Count
Write-Output "RESULT_WALINE_COUNT=$cnt"
Write-Output 'RESULT_DONE=1'
