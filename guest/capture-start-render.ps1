# Self-contained Start render probe: an interactive, WINDOWLESS scheduled task opens Start
# (Ctrl+Esc), waits, screenshots the guest screen to a PNG, and records the shell window
# geometry - all with no qrexec activity in flight, because ANY console flash dismisses the
# menu. Retrieval happens later (read-start-render.ps1), by which time the sampling is done.
$ErrorActionPreference = 'Continue'
$work = 'C:\toastprobe'
New-Item -ItemType Directory -Force $work | Out-Null
Remove-Item "$work\start-render.png","$work\start-render.txt" -ErrorAction SilentlyContinue

@'
$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Start-Sleep -Milliseconds 1500
[System.Windows.Forms.SendKeys]::SendWait("^{ESC}")      # open Start
Start-Sleep -Milliseconds 2500                            # let it animate in
$b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
$bmp = New-Object System.Drawing.Bitmap($b.Width, $b.Height)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($b.X, $b.Y, 0, 0, $bmp.Size)
$small = New-Object System.Drawing.Bitmap($bmp, [int]($b.Width/3), [int]($b.Height/3))
$small.Save('C:\toastprobe\start-render.png', [System.Drawing.Imaging.ImageFormat]::Png)
# what the shell says about its own windows, sampled while Start is still open
$rows = @()
foreach ($n in 'StartMenuExperienceHost','ShellExperienceHost','SearchHost') {
    foreach ($p in Get-Process $n -ErrorAction SilentlyContinue) {
        $rows += ("{0} pid={1} main=0x{2:X}" -f $n, $p.Id, $p.MainWindowHandle.ToInt64())
    }
}
$rows | Set-Content 'C:\toastprobe\start-render.txt'
Add-Content 'C:\toastprobe\start-render.txt' ("captured " + (Get-Date).ToString('HH:mm:ss.fff'))
'@ | Set-Content "$work\render-inner.ps1" -Encoding ASCII

@'
CreateObject("WScript.Shell").Run "powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File ""C:\toastprobe\render-inner.ps1""", 0, False
'@ | Set-Content "$work\render-inner.vbs" -Encoding ASCII

& schtasks /create /tn QwtStartRender /tr "wscript.exe //B //Nologo $work\render-inner.vbs" /sc once /st 00:00 /ru user /it /f *>&1 | Out-Null
& schtasks /run /tn QwtStartRender *>&1 | Out-Null
Write-Output '=== RESULT ==='
@{ armed = $true } | ConvertTo-Json
