# Launch ONE ordinary application window and print its pid, so a time-to-first-window measurement
# can END IN A DEMONSTRATED WINDOW instead of in a log line. A clean log with no window ever shown
# proves nothing - the owner's point, 2026-10-23: "a measurement that does not prove end state is
# sane is futile, we may claim zero seconds immediately".
#
# The pid is printed so the caller can end it BY PID. Nothing here is ever ended by name: killing by
# name races whatever else owns that image and is prohibited (docs/ADR-supervision.md 5).
$ErrorActionPreference = 'Continue'
$p = $null
foreach ($exe in @('notepad.exe', 'explorer.exe')) {
    try {
        if ($exe -eq 'explorer.exe') { $p = Start-Process -FilePath $exe -ArgumentList 'C:\' -PassThru -EA Stop }
        else                         { $p = Start-Process -FilePath $exe -PassThru -EA Stop }
    } catch { continue }
    if ($p) { "WINPROBE exe=$exe pid=$($p.Id)"; break }
}
if (-not $p) { 'WINPROBE err=no_app_could_be_started' }
