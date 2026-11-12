# What this guest SENT to dom0, per boot. Read-only: it greps our own senders' log lines, which each
# record the route they sent and when. No toast is raised by this script.
$ErrorActionPreference = 'SilentlyContinue'
# READ IN THIS ORDER: the registry LogDir (where every module writes - docs/ADR-logging.md), <SystemDrive>\Qubes Logs
# (log.c's directory when LogDir is unset or unreadable - a guest cloned from a parked golden writes there), then the
# two folders this read was born with. It read only those two, and a harness that binds the log volume moves LogDir
# onto it: measured 2026-11-12 on win11de-os20 (quick-upgrade, 4.3.41), both post-install pulls returned the same
# five PRE-bind lines from Q:\Qubes Logs while the 4.3.41 agent wrote its daily file on the volume.
$ld = (Get-ItemProperty 'HKLM:\SOFTWARE\Invisible Things Lab\Qubes Tools' -ErrorAction SilentlyContinue).LogDir
# No path is rewritten: a TrimEnd('\') would turn a drive-root LogDir into "Z:", the CURRENT directory of Z:, not
# its root. Select-Object -Unique keeps the first of each and the order above (Sort-Object would reorder it). Two
# spellings of one folder only list its files twice - the $seen key below reports each line once.
$dirs = @(@($ld, (Join-Path $env:SystemDrive 'Qubes Logs'), 'Q:\Qubes Logs', 'C:\Program Files\Qubes Tools\log') |
          Where-Object { $_ } | ForEach-Object { [string]$_ } | Select-Object -Unique)
$files = foreach ($d in $dirs) { Get-ChildItem -LiteralPath $d -Filter '*.log' -ErrorAction SilentlyContinue }
# The bind COPIES the old folder onto the volume, so one file can be read from two folders: each (file, line, text)
# is reported once, and the lines only the longer copy holds still count.
$seen = @{}
if (-not $files) { Write-Output 'SENDS UNREAD: no log files found'; exit 0 }
Write-Output ("FILES " + ($files | ForEach-Object { $_.Name + ':' + $_.Length } ) -join ' ')
# every emitter that reaches dom0: the agent's report route, the bridge, the updater, the death reporter
# TWO MECHANISMS REACH dom0, and the first version of this capture knew only one. QerrReport logs
# 'NOTIFYERR <component>.<id> sent to dom0'; the notifhost one-shots (DirectSuppressNotifyUser,
# StartDismissNotifyUser, DeafNotifyUser) log '<TAG>: user notification sent' and no NOTIFYERR at
# all - which is how a QGASTARTDISMISS toast reached the owner's screen and never reached my ledger.
# So the net is the ACT, not a list of tags: anything that says it notified the user.
$pat = 'user notification sent|NotifyUser|notify-file|NOTIFYERR|QGANOTIFYERR|QGAERRBOX|QerrReport|QerrText|QGANOTIF|QGABROKERMISSING|QGAWGCDEAF|QGAWGCRECREATE|QGAWGCITEMCLOSED|QGADESKSTUCK|QGAUACPENDING|QGASTARTDISMISS|' +
       'qubes\.Notifications|qubes\.NotifyUpdates|qubes\.NotifyTools|reported .* update|' +
       'notify-error|listener-init|listener-denied|deslice-down|broker-died|broker-missing|session-changed'
foreach ($f in $files) {
  $hits = Select-String -LiteralPath $f.FullName -Pattern $pat -AllMatches -Encoding Default
  foreach ($h in $hits) {
    $k = 'S|' + $f.Name + ':' + $h.LineNumber + '|' + $h.Line.Trim(); if ($seen.ContainsKey($k)) { continue }; $seen[$k] = 1
    Write-Output ("SEND [" + $f.Name + ":" + $h.LineNumber + "] " + $h.Line.Trim())
  }
}
# and the boots, so each send can be attributed to one
foreach ($f in $files) {
  # the lifecycle context a deaf report must be judged against: was the window still there?
  $hits = Select-String -LiteralPath $f.FullName -Pattern 'uptime|BOOT|Init: .*version|CTLSTOP|window destroyed|WM_DESTROY|unmapped|BrokerRegister|BrokerRetire' -Encoding Default | Select-Object -First 40
  foreach ($h in $hits) {
    $k = 'B|' + $f.Name + ':' + $h.LineNumber + '|' + $h.Line.Trim(); if ($seen.ContainsKey($k)) { continue }; $seen[$k] = 1
    Write-Output ("BOOT [" + $f.Name + ":" + $h.LineNumber + "] " + $h.Line.Trim())
  }
}
Write-Output 'SENDS DONE'
