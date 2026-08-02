$f=(Get-ChildItem 'C:\Program Files\Qubes Tools\log' -Filter 'gui-agent*.log'|Sort LastWriteTime -Desc|Select -First 1)
Write-Output "LOG $($f.Name)  modified $($f.LastWriteTime)"
$t=Get-Content $f.FullName
Write-Output "--- connection / protocol lines:"
$t | Select-String 'vchan|Vchan|connect|Connect|protocol|version|daemon' | Select-Object -First 12 | ForEach-Object { "  $_" }
Write-Output "--- errors:"
$t | Select-String -Pattern '\-E\]' | Select-Object -Last 8 | ForEach-Object { "  $_" }
Write-Output "--- recent maps:"
$t | Select-String 'SendWindowMap' | Select-Object -Last 6 | ForEach-Object { "  $_" }
