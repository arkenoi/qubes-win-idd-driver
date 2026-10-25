# What this guest SENT to dom0, per boot. Read-only: it greps our own senders' log lines, which each
# record the route they sent and when. No toast is raised by this script.
$ErrorActionPreference = 'SilentlyContinue'
$dirs = @('Q:\Qubes Logs', 'C:\Program Files\Qubes Tools\log')
$files = foreach ($d in $dirs) { Get-ChildItem -LiteralPath $d -Filter '*.log' -ErrorAction SilentlyContinue }
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
  foreach ($h in $hits) { Write-Output ("SEND [" + $f.Name + ":" + $h.LineNumber + "] " + $h.Line.Trim()) }
}
# and the boots, so each send can be attributed to one
foreach ($f in $files) {
  # the lifecycle context a deaf report must be judged against: was the window still there?
  $hits = Select-String -LiteralPath $f.FullName -Pattern 'uptime|BOOT|Init: .*version|CTLSTOP|window destroyed|WM_DESTROY|unmapped|BrokerRegister|BrokerRetire' -Encoding Default | Select-Object -First 40
  foreach ($h in $hits) { Write-Output ("BOOT [" + $f.Name + ":" + $h.LineNumber + "] " + $h.Line.Trim()) }
}
Write-Output 'SENDS DONE'
