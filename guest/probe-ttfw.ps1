# Per-instance timings for the CURRENT gui-agent: its QWTBIRTH, the shell it saw, the broker's
# launch, and the broker becoming ready. All four come from ONE log, so the deltas are valid even
# though this guest's clock is offset from the host's.
$ErrorActionPreference = 'Continue'
$d = (Get-ItemProperty 'HKLM:\SOFTWARE\Invisible Things Lab\Qubes Tools').LogDir
$f = Get-ChildItem $d -Filter gui-agent-*.log -EA SilentlyContinue | Sort-Object LastWriteTime -Desc | Select-Object -First 1
if (-not $f) { 'TTFW err=no_gui_agent_log'; exit 0 }
$lines = Get-Content -LiteralPath $f.FullName -EA SilentlyContinue
# the LAST QWTBIRTH is this instance; everything after it belongs to it and nothing before does
$bi = -1
for ($i = $lines.Count - 1; $i -ge 0; $i--) { if ($lines[$i] -match 'QWTBIRTH module=gui-agent .*\bpid=(\d+)') { $bi = $i; $apid = $Matches[1]; break } }
if ($bi -lt 0) { 'TTFW err=no_qwtbirth'; exit 0 }
$mine = $lines[$bi..($lines.Count - 1)]
function Stamp($pattern) {
  foreach ($ln in $mine) { if ($ln -match $pattern) { if ($ln -match '^\[(\d{8})\.(\d{6})\.(\d{3})') { return ($Matches[1] + $Matches[2] + $Matches[3]) } } }
  return ''
}
$birth  = Stamp 'QWTBIRTH module=gui-agent'
$shell  = Stamp 'QGASHELLSEEN'
$launch = Stamp 'WgcLaunch: WGCBROKER launched'
$ready  = Stamp 'WGCBROKER ready'
$sup    = @($mine | Select-String -Pattern 'QGADIRECTSUPPRESS' -EA SilentlyContinue).Count
$noti   = @($mine | Select-String -Pattern 'QGABROKERLAUNCHNOTISSUED' -EA SilentlyContinue).Count
"TTFW pid=$apid"
"TTFW birth=$birth"
"TTFW shell=$shell"
"TTFW launch=$launch"
"TTFW ready=$ready"
"TTFW suppress=$sup"
"TTFW notissued=$noti"
