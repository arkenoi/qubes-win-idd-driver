# Dump the newest gui-agent log in full (LogLevel=4), base64'd so no console mangling.
# The agent holds the file open, so it must be opened with FileShare.ReadWrite -
# [IO.File]::ReadAllBytes uses FileShare.Read and fails silently against a live writer.
$ErrorActionPreference='SilentlyContinue'
$f=(Get-ChildItem 'C:\Program Files\Qubes Tools\log' -Filter 'gui-agent*.log'|Sort LastWriteTime -Desc|Select -First 1)
Write-Output ("RESULT=LOGFILE {0} bytes={1}" -f $f.Name,$f.Length)
$fs=New-Object System.IO.FileStream($f.FullName,[System.IO.FileMode]::Open,[System.IO.FileAccess]::Read,[System.IO.FileShare]::ReadWrite)
$ms=New-Object System.IO.MemoryStream
$fs.CopyTo($ms); $fs.Close()
$b=$ms.ToArray()
Write-Output ("RESULT=READBYTES {0}" -f $b.Length)
$s=[Convert]::ToBase64String($b)
Write-Output 'B64START'
for($i=0;$i -lt $s.Length;$i+=200){ Write-Output $s.Substring($i,[Math]::Min(200,$s.Length-$i)) }
Write-Output 'B64END'
