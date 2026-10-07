# Dismiss the persistent test toast raised by guest/fire-toast.ps1.
#
# WHY THIS IS NEEDED. fire-toast uses `<toast scenario="reminder">`, which by design STAYS ON SCREEN
# UNTIL DISMISSED — that is the point: it gives a stable shell surface to measure. The consequence is
# that it OUTLIVES THE RUN. Measured 2026-08-31, three runs in a row: a toast from the previous run
# was on screen at baseline (`override_redirect=1` before anything was fired). It held focus, so the
# menu cell's `Alt+F` never reached Notepad and RND-3 could not open a menu at all; and it made
# RND-4's delta read `1 -> 1`, reporting FAIL for a toast that had in fact appeared.
#
# Killing ShellExperienceHost does NOT work — the notification platform re-shows a reminder toast
# when the host respawns. The toast must be removed from the NOTIFICATION HISTORY, which is per-user
# state, so this has to run in the USER session (guest/run-as-user.ps1), not from qrexec's SYSTEM.
# ShellExperienceHost is the platform's process, relaunched by the shell on demand: this script
# never ends it (owner 2026-10-07: never a bare kill of a relauncher's child - it used to
# `Get-Process ShellExperienceHost | Stop-Process` after the clear, "so anything already painted
# goes away", which the platform's respawn then undid anyway). A banner still painted is the
# caller's own window census to report, not something hidden here.
#
#   run-as-user.ps1 -Script ...\dismiss-toast.ps1 -Tag dismiss
param(
    # Must match the AppId fire-toast.ps1 notifies under, or Clear() removes nothing.
    [string]$AppId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
)
$ErrorActionPreference = 'Continue'
$cleared = @()
try {
    [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType=WindowsRuntime]
    $hist = [Windows.UI.Notifications.ToastNotificationManager]::History
    try { $hist.Clear($AppId); $cleared += 'appid' } catch { }
    # Belt and braces: the parameterless overload clears this package's own history. Harmless when
    # the AppId form already worked, and it covers a toast raised under a different AppId by hand.
    try { $hist.Clear(); $cleared += 'default' } catch { }
} catch {
    Write-Output '=== RESULT ==='
    @{ ok = $false; error = "ToastNotificationManager unavailable: $($_.Exception.Message)" } | ConvertTo-Json -Compress
    exit 2
}

# Let the Action Center settle after the clear. The shell surface host is NOT restarted from here
# (see the header): it is the platform's, and a relauncher's child is never killed to "refresh" it.
Start-Sleep -Seconds 3

Write-Output '=== RESULT ==='
@{ ok = $true; cleared = $cleared; appid = $AppId } | ConvertTo-Json -Compress
