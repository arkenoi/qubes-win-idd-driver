<#
.SYNOPSIS
  Qubes Windows Update agent (QWT-NG). Windows Update over the Qubes UpdatesProxy with ZERO guest
  networking.

.DESCRIPTION
  Windows' online update engine (DO -> BITS) gates on IsNetworkAlive and refuses to run on a
  routeless guest (error 0x80200010) - and no loopback/NCSI trick satisfies it (proven). So this
  agent uses "Path B", the offline-servicing route, which has no such gate:

     scan (WU COM search, proxy-aware)  ->  resolve the standalone .msu from the Microsoft Update
     Catalog (over the proxy)  ->  fetch it over the proxy (resumable)  ->  install offline (DISM).

  Everything rides the qubes-updates-relay (127.0.0.1:8082 -> qrexec qubes.UpdatesProxy), so the
  guest needs no IP networking. Throughout, it writes a structured status JSON (availability +
  progress) for dom0 to poll - the north-star: report availability + progress to dom0, non-blocking.

.NOTES
  Consolidates the proven prototype scripts (wu-enumerate / wu-catalog-get / wu-full-install).
  dom0 reporting (qubes.NotifyUpdates + a progress channel) is a thin layer on top of the status
  file - added once the dom0 policy is placed.

.PARAMETER Action  scan | download | install | full
#>
[CmdletBinding()]
param(
  [ValidateSet('scan','resolve','download','install','full','wuinstall')][string]$Action = 'scan',
  [string]$Proxy      = 'http://127.0.0.1:8082',
  [string]$RelayExe   = 'C:\Program Files\Qubes Tools\bin\qubes-updates-relay.exe',
  [string]$WorkDir    = 'C:\ProgramData\Qubes\wu',
  [string]$StatusFile = 'C:\ProgramData\Qubes\update-status.json',
  # Restrict a pass to specific KBs (e.g. -OnlyKb KB5120710). Diagnostic control, not a policy
  # knob: a normal dom0-driven pass passes nothing and takes everything offered. It exists so a
  # multi-gigabyte cumulative and a small package can be tested one at a time rather than as an
  # all-or-nothing batch - the batch is precisely what made the 24H2 failure unattributable.
  [string[]]$OnlyKb   = @(),
  # Restrict a pass to specific offers BY IDENTITY (the UpdateID the offer itself carries, with or
  # without ":rev"). Diagnostic control, same family as -OnlyKb, and the only way to name an offer
  # that HAS NO KB - a vendor driver, for instance. Added 2026-09-21 because the KB-less
  # AudioProcessingObject driver could not be exercised on a guest at all: -OnlyKb cannot select it,
  # so its resolve-by-title path was verified off-guest only. Identity, never title text (ADR 6).
  [string[]]$OnlyUid  = @(),
  # Force the catalog to answer in a given language, e.g. -AcceptLanguage de-DE. Diagnostic.
  # Exists because the catalog's response language is NOT under our control and has been measured
  # varying by itself (same KB, same guest, German at 09:54 and English at 10:21 on 2026-08-14),
  # while the row-picking logic matches on title text. A real user runs a German edition, so
  # "does resolution still pick the same FILE when the titles are German" has to be answerable on
  # an English guest - this is what makes it answerable.
  [string]$AcceptLanguage = '',
  # Set ONLY by the scheduled scan task. It marks this pass as the automatic background refresh,
  # which is the one pass that may be skipped when another has just finished (see the debounce
  # below). A pass dom0 asked for is never skipped, whatever it costs - so this switch must never
  # be added to the Run/Download tasks or to the rpc handlers.
  [switch]$Scheduled
)
$ErrorActionPreference = 'Continue'
# THE LOG SINK IS log.ps1, beside this script in bin (docs/ADR-logging.md, Decision 2026-11-01): the pass writes
# qubes-windows-update.ps1-<yyyyMMdd>.log in the one log directory. Without it every line would be lost in silence, so a
# pass that cannot load it says so and does not run. log.ps1 defines a Log(level,msg) of its own; the Log below replaces it.
$qwtLogPs1 = Join-Path $PSScriptRoot 'log.ps1'
try { . $qwtLogPs1 } catch { [Console]::Error.WriteLine("qubes-windows-update.ps1: cannot load $qwtLogPs1 ($($_.Exception.Message)) - no log sink"); exit 1 }
if (-not (Get-Command Write-QwtLogLine -EA SilentlyContinue)) { [Console]::Error.WriteLine("qubes-windows-update.ps1: $qwtLogPs1 has no Write-QwtLogLine - no log sink"); exit 1 }
# THE SILENT STARTUP WINDOW, CLOSED. The sink above is loaded and proven callable FROM HERE, before this
# script's own Log wrapper exists, and a terminating error that reaches no log goes only to STDERR - which
# Task Scheduler DISCARDS. 0x80070001 is HRESULT_FROM_WIN32(1), what powershell.exe returns for an
# unhandled terminating error, and no Task Scheduler event export can hold the statement that raised it.
# The six field occurrences of WUSCANTASKFAILSANDLOGSNOTHING (reporter builds 4.3.37/.38) carried that
# code and no cause; their bundles held no updater log at all - those builds wrote C:\ProgramData\Qubes\wu\agent.log.
# `break` ENDS THE PASS on every terminating error the script does not catch itself, a statement-terminating
# one included - and that one, without a trap, prints to stderr and carries on. Reproduced 2026-11-12 under
# pwsh 7.6: a parameter-binding error in a function called from script level continued with exit 0 without
# the trap and ended the script with exit 1 with it. So an uncaught error stops the pass, on the record.
# The wording is deliberately NOT "startup" - a trap is script-wide and must be truthful wherever it fires.
# The body cannot fail its host: a sink that throws must not become the error it was reporting.
trap {
  try {
    $qwtLn = "$($_.InvocationInfo.Line)".Trim()
    $null = Write-QwtLogLine E ("UNHANDLED TERMINATING ERROR, this pass ends here: $($_.Exception.GetType().Name): $($_.Exception.Message) at line $($_.InvocationInfo.ScriptLineNumber): $qwtLn") -Module 'qubes-windows-update.ps1'
  } catch { }
  try { [Console]::Error.WriteLine("qubes-windows-update.ps1: UNHANDLED TERMINATING ERROR: $($_.Exception.Message)") } catch { }
  break
}
# ---- WU-PROXY-SANE-BEGIN
# GUARD:proxysane - the proxy must be an ABSOLUTE URI, checked before anything uses it.
# Measured 2026-09-21: `-Action full -OnlyKb KB2267602 KB5007651` bound the first KB to -OnlyKb and
# the SECOND to the first free positional parameter, which is -Proxy. The pass then ran with
# Proxy='KB5007651' and died deep inside the catalog search with "This operation is not supported
# for a relative URI" - a message that names neither the parameter nor the value, and cost a guest
# run and a code read to place. A positional mis-bind is a caller error, and it is cheap to catch
# here where the value is still recognisable.
if ($Proxy -and -not ([Uri]::IsWellFormedUriString($Proxy, [UriKind]::Absolute))) {
    Write-Host "FATAL: -Proxy '$Proxy' is not an absolute URI (expected e.g. http://127.0.0.1:8082)."
    Write-Host "       If you passed several KBs, -OnlyKb takes a COMMA-separated list: -OnlyKb KB1,KB2"
    Write-Host "       A bare second value binds to -Proxy, which is how this usually happens."
    exit 2
}
# ---- WU-PROXY-SANE-END
New-Item -ItemType Directory -Force (Split-Path $StatusFile) | Out-Null

# ---- WU-PREVSTATUS-BEGIN
# GUARD:prevstatus - snapshot the PREVIOUS pass's status BEFORE anything in this run can Save over
# it. Save() rewrites $StatusFile from $script:St, which this run resets, and it is called early
# and often - so a guard that reads the file later reads THIS run's freshly blanked state and
# concludes there is no prior knowledge at all. Measured 2026-09-20: GUARD:scanactioned read
# `action=scan, rows=0` - its own output - and therefore excluded nothing, and dom0 went from empty
# back to 1 on the very next scan. Read it once, here, where it is still the previous pass's.
$script:PrevStatus = $null
try {
  if (Test-Path $StatusFile) { $script:PrevStatus = Get-Content -LiteralPath $StatusFile -Raw | ConvertFrom-Json }
} catch { $script:PrevStatus = $null }
# ---- WU-PREVSTATUS-END

# CONNECT-tunnel keep-alive (2026-08-20): one tunnel through the relay = one backend qrexec channel, so
# every tunnel .NET drops early is a vchan channel churned (each open/close = a grant permit/revoke, the
# suspected relay-wedge trigger). .NET already reuses one tunnel per host within this process (Fetch-Msu
# drains + Close()s each response, KeepAlive default true); the only thing forcing a fresh tunnel across
# catalog think-gaps is the 100 s default idle drop - raise it so sequential catalog/CDN requests ride one
# tunnel. (WU's own fe2cr/fe3cr SOAP churn is not ours; it falls only via the relay-side pool changes.)
try {
  [System.Net.ServicePointManager]::MaxServicePointIdleTime = 300000
  [System.Net.ServicePointManager]::SetTcpKeepAlive($true, 30000, 5000)
} catch {}

# ONE update operation at a time. The scheduled scan, the dom0-driven run and the download task
# are separate tasks writing ONE status file and sharing ONE proxy, and they collided for real
# (2026-08-13): the 6-hourly scan fired 6 minutes into a dom0-driven install, rewrote the status
# file with its own `done`, and the rpc handler tailing that file reported the update finished -
# with an empty result - while DISM was still installing. The scan's Remove-Proxy also tears down
# the proxy the other pass is downloading through.

# THE STATUS OBJECT AND Save COME BEFORE THE MUTEX. The ownership record below the mutex writes $script:St and calls Save;
# until 2026-10-02 both were defined AFTER it, so owner_pid was never recorded (PropertyNotFound + CommandNotFound, swallowed
# under ErrorActionPreference Continue, seen in a pass's own stderr on GWeck's environment) and the interrupted-pass gate could
# not tell a running owner from a dead one. Nothing here does work: the previous status is already snapshotted (GUARD:prevstatus).
# not_actionable is declared here so it always exists and always serialises: it is the DURABLE
# record of what a previous pass proved the guest cannot action, and it has to survive a scan,
# which writes an empty result. (GUARD:scanactioned / GUARD:prevstatus.)
# A DROPPED LOG LINE IS A LOST ERROR, so the drops are COUNTED and reported (log_dropped in the
# status). Log used to swallow a failed append entirely - see the function below.
$script:LogDropped = 0
$script:LogDropFirst = ''
$script:LogLossReported = $false
# Log IS DEFINED HERE, before Save and the mutex block, because Save calls it. Until 2026-11-12 it was defined after
# them, so in the first Save (line "Save" under the mutex block) both of Save's Log calls bound to log.ps1's
# Log(level,msg), whose [int] level refuses a string. Reproduced in a ten-line script under pwsh 7.6: the clock-jump
# warning raised an argument-transformation error and the trap above ended the pass with exit 1 - a scan task
# "failure" whose only cause was a wall-clock correction of 30 s or more early in the pass.
# Write-Host alone is lost under the scheduled task, which is why every download failure so far
# had to be reconstructed from DISM's log instead of ours. Tee to a file.
function Log($m, $lvl){
  # THE LEVEL WAS SILENTLY THROWN AWAY. This took one parameter while EIGHT call sites passed a
  # level positionally - `Log "..." 'WARN'` - and PowerShell puts the extra argument in $args and
  # drops it. MEASURED, not reasoned: `function Log($m){...}; Log "x" "WARN"` prints the message
  # and `args: [WARN]`.
  # IT BLINDED THE JUDGE. tools/wu-pass-judge.py reads the writer's declared level and nothing
  # else - `^(?:\[ERROR\]|ERROR:)` - so `Log "Windows Update fallback failed" 'ERROR'` and
  # `Log "Sync-Revocation: FAILED ..." 'ERROR'` wrote lines that cannot match, and two real
  # failures could never be counted as errors. tools/log-sweep.py recorded all eight as undeclared
  # for the same reason. This is the 2026-10-14 blindness from the other end: that time the writer
  # changed its prefix and the reader stopped matching; here the writer never emitted one at all.
  # THE LEVEL IS THE LINE'S PREFIX LETTER NOW, not a "[$lvl] " in its text (docs/ADR-logging.md, Decision 2026-11-01):
  # E for ERROR/FAILED, W for WARN/WARNING, D for DEBUG, I otherwise - from the level a call site PASSES. The twelve
  # sites that write "[ERROR] "/"[WARN] " INTO the text with no $lvl keep that text (its declaration lives there on
  # purpose - QWTUPDDEFCLASSNEW below says why) and take the letter that text declares, by the rule tools/log-sweep.py
  # applied to this log before the move (BLOG_DECLARED_RE, leading blanks allowed). At I they would vanish from the
  # sweep, which reads the letter and treats I as not a failure - the pass's own final "[ERROR] " line among them.
  $L = 'I'
  if ($lvl -in 'ERROR', 'FAILED') { $L = 'E' } elseif ($lvl -in 'WARN', 'WARNING') { $L = 'W' } elseif ($lvl -eq 'DEBUG') { $L = 'D' }
  elseif (-not $lvl -and "$m" -match '^\s*\[(ERROR|FATAL|WARN|WARNING)\]\s') { if ($Matches[1] -in 'ERROR', 'FATAL') { $L = 'E' } else { $L = 'W' } }
  # The console keeps its old shape: whoever runs a pass by hand reads the level in the text.
  $shown = $m
  if ($lvl) { $shown = "[$lvl] $m" }
  Write-Host ((Get-Date -Format 'HH:mm:ss') + ' ' + $shown)
  # A DROPPED LOG LINE IS A LOST ERROR, AND THIS USED TO DROP THEM IN SILENCE. The old body was
  #     try { Add-Content ... -EA SilentlyContinue } catch {}
  # - a suppressed error inside an empty catch, so a failed append left no trace in the file, on the
  # console, or in the status. MEASURED 2026-10-08 with an unwritable WorkDir: the call does not
  # throw, writes nothing, and reports nothing.
  # IT HAPPENED FOR REAL. On WIN11-upgrade and win11de-tup the pass's agent.log was missing
  # "relay started: pid ..." and "proxy up: ..." although it plainly reached Sync-Revocation, which
  # runs immediately AFTER Ensure-Proxy and only if Ensure-Proxy returned - and Ensure-Proxy's
  # success path emits both. Add-Content takes a write lock, and the updater deploy was writing in
  # that same second. Those two absences then became evidence for a defect that was never there.
  # Write-Host alone is not a record: under Task Scheduler there is no console to keep it.
  # THE RETRY IS log.ps1's NOW: Write-QwtLogLine retries a sharing collision 20 x 15 ms and gives up at
  # once on a missing directory or a refusal, so the five tries and the after-three-drops shortcut that
  # lived here are gone - a log that is plainly gone already costs one attempt. What stays is the
  # ACCOUNTING, keyed on its answer.
  $mod = 'qubes-windows-update.ps1'
  # THE LOG REPORTS ITS OWN GAPS. A status field can go unread; a line in the log is seen by
  # whoever reads the log, including tools/log-sweep.py. So the first write that SUCCEEDS after
  # any loss states how many lines went missing and why - otherwise the only trace of a gap is
  # the gap, and an absent line would again be mistaken for an event that did not happen.
  if ($script:LogDropped -gt 0 -and -not $script:LogLossReported) {
    $notice = "QWTUPDLOGLOST $script:LogDropped line(s) could not be written to this log and are GONE (first reason: $script:LogDropFirst). Anything inferred from a MISSING line in this file is unsafe."
    # MARKED REPORTED ONLY ONCE IT IS ON DISK. Setting the flag first meant a notice that was
    # ITSELF dropped counted as delivered, so the gap was never announced - caught by
    # tools/tests/wu-log-loss-selftest.sh the first time it ran.
    if (Write-QwtLogLine W $notice -Module $mod) { $script:LogLossReported = $true }
    else {
      # The gap is still unannounced, so this line must not land after it as if nothing were missing: it is lost too,
      # and said on stderr like every other lost line (log.ps1 has only said so for the notice).
      [Console]::Error.WriteLine("qwt log: line LOST (the QWTUPDLOGLOST notice before it was not written): $m")
      $script:LogDropped++
      return
    }
  }
  if (Write-QwtLogLine $L "$m" -Module $mod) { return }
  # The primitive has already said why on stderr; it returns no reason, so the status names where to look.
  if (-not $script:LogDropFirst) { $script:LogDropFirst = 'Write-QwtLogLine could not write the line - log.ps1 named the cause on stderr' }
  # COUNT it. Save reports the count, so an incomplete log is a stated fact rather than a gap someone
  # has to notice.
  $script:LogDropped++
}
$script:St = [ordered]@{ action=$Action; phase='init'; ts=$null; owner_pid=0; owner_pid_start=''; count=0; available=@();
                         downloading=$null; installing=$null; result=@(); reboot_needed=$false; error=$null; recovered='';
                         not_actionable=@(); satisfied=@(); satisfied_rule='installed'; unroutable=@(); route_unknown=@(); esu=$null; notice=$null }

# DEBOUNCE, and only for the automatic scan. The mutex below stops two passes running AT ONCE; it
# does nothing about one starting the moment another finished. That happens routinely - dom0 drives
# an install, it completes, and the 6-hourly scan fires minutes later - and each pass costs a full
# Windows Update scan plus a proxy/relay teardown and rebuild. The relay churn is not free: the
# 2026-08-20 dump attributes the guest-wide freeze to the TLB shootdowns that qrexec bridge
# processes generate as they exit, so a pass nobody needs is a wedge risk, not just wasted minutes.
#
# Rules, deliberately narrow:
#   - ONLY -Scheduled passes are ever skipped. Anything dom0 asked for runs, always.
#   - the window counts from the last COMPLETED pass of ANY kind (that is the point of it being
#     cross-path); a pass that failed or is mid-flight does not start the clock.
#   - QUBES_UPDATES_DEBOUNCE_MIN=0 disables it; the default is 30 minutes against a 6-hourly scan.
#   - a pass that ended REBOOT-PENDING never debounces the scan that follows it (see inside).
#   - a skip is a line in the pass log. The region sits below Log for that: the scan task runs under
#     Task Scheduler, which discards Write-Host. Nothing above this point saves or takes the mutex.
# The marker lines delimit the region tools/tests/wu-reboot-report-test.ps1 extracts and replays.
# ---- WU-SCAN-DEBOUNCE-BEGIN
if ($Scheduled -and $Action -eq 'scan') {
    $debounceMin = 30
    $envMin = $env:QUBES_UPDATES_DEBOUNCE_MIN
    if ($envMin -and ($envMin -as [int]) -ne $null) { $debounceMin = [int]$envMin }
    if ($debounceMin -gt 0 -and (Test-Path $StatusFile)) {
        try {
            $prev = Get-Content -LiteralPath $StatusFile -Raw | ConvertFrom-Json
            # Only a pass that actually LEFT AN ANSWER may suppress the next scan. Measured on a
            # real cold boot 2026-08-20: the boot-triggered scan was skipped 9 minutes after a
            # download pass, finishing in 3 s having written nothing. That is right when the
            # previous pass reported availability - and wrong when it did not, because the boot
            # scan is exactly the recovery for a pass whose own rescan failed. Without this the
            # guest could sit up to a full scan interval with no availability answer for dom0.
            $prevAnswered = ($prev.PSObject.Properties.Name -contains 'available') -and ($prev.phase -eq 'done')
            # A pass that ended REBOOT-PENDING did not scan: it reported a count derived from its own
            # result rows and logged "boot scan will confirm". That boot scan (BootTrigger + 2 min,
            # -Scheduled) is THIS pass, and it is the only correction dom0 ever gets - so a
            # reboot-pending status never counts as an answer that may suppress it. Measured
            # 2026-09-16 on German Win11 25H2 (4.3.29): the install pass wrote done_ts 22:49:16,
            # the boot scan fired at 22:54:00 with LastTaskResult 0, exited right here having
            # written nothing, and dom0 kept "no updates" with a 4.4 GB cumulative downloaded and
            # unapplied on the guest.
            $prevGuessed = [bool]$prev.reboot_needed   # GUARD:bootconfirm
            if ($prev.done_ts -and $prevAnswered -and -not $prevGuessed) {
                $age = ((Get-Date) - [datetime]$prev.done_ts).TotalMinutes
                # A negative age means the stamp is in the future (clock moved) - do not trust it
                # to skip work; run the pass.
                if ($age -ge 0 -and $age -lt $debounceMin) {
                    Log ("skipping this scheduled scan: a {0} pass completed {1:N0} min ago (debounce {2} min)" -f `
                         $prev.action, $age, $debounceMin)
                    exit 0
                }
            }
        } catch { }   # unreadable/absent status = no reason to skip; fall through and scan
    }
}
# ---- WU-SCAN-DEBOUNCE-END

# ---- WU-PASS-CLOCK-BEGIN
# A PASS DURATION MUST NOT BE READ OFF A CLOCK THAT MOVES UNDER IT. `ts` above is
# (Get-Date).ToString('s') - LOCAL and with no offset - so any duration taken as the difference of
# two of them silently absorbs every correction that lands in between, and on this platform those
# corrections are an hour wide and routine.
# MEASURED 2026-10-30 on the clean cell of this very campaign:
#   CLOCKSTAMP guest UTC 2026-10-30T14:08:59.0Z is 3573.6 s BEHIND host stamp 2026-10-30T15:06:54.0Z
#   carried forward by 99 s of uptime - correcting FORWARD
# 3573.6 s is 59.56 minutes, and the boot scan starts at boot + 2 min, so a correction landing in a
# scan adds very close to one hour to anything timed by subtracting wall clocks.
# WHY THIS MATTERS HERE AND NOT ONLY IN THEORY: the scan task's ExecutionTimeLimit was raised
# PT20M -> PT2H on the strength of "a FIRST scan after servicing ran >25 min and >66 min on the
# reporter's template, 2026-09-17". That number survives only as a comment - it is in no findings
# entry, no ADR and no retained capture - and >66 min is, to the minute, a ~6 min scan plus one of
# these corrections. It is not refuted, and it is not evidence either until something times a pass
# with a clock that cannot jump.
# So: Stopwatch is monotonic (QueryPerformanceCounter) and is unaffected by any clock change. The
# pass publishes BOTH - elapsed_s, which is the truth, and the wall-clock disagreement, which names
# the artefact instead of letting it inflate the number. `ts` is untouched: dom0 and the Qube
# Manager handler read it, and this adds fields rather than changing one.
$script:PassWatch     = [System.Diagnostics.Stopwatch]::StartNew()
$script:PassWallStart = Get-Date
$script:ClockJumpLogged = $false
# A correction smaller than this is ordinary drift and says nothing; the sweep's own
# clock_boot_correction_s gate sits at 60 s, so 30 s is below anything it would pass.
$script:ClockJumpThresholdSec = 30
# ---- WU-PASS-CLOCK-END
# ---- WU-SAVE-ATOMIC-BEGIN
# ATOMIC, AND NEVER FATAL. The Qube Manager handler TAILS this file while a pass writes it (that is
# what the mutex comment above describes), and a plain Set-Content fails outright on the sharing
# violation. Measured 2026-09-21 on win11de-fresh, round 2: the pass died with "Der Prozess kann
# nicht auf die Datei C:\ProgramData\Qubes\update-status.json zugreifen, da sie von einem anderen
# Prozess verwendet wird" AFTER it had already reported 3 to dom0 - so dom0 was left holding a
# number the pass never stood behind, which is the untruth this whole file exists to prevent,
# arriving by way of a file lock. The judge caught it as a CONTRADICTORY pass.
#
# Write a temp file and MOVE it into place: the reader then sees either the old file or the new
# one, never a half-written one. Retry briefly, and if it still cannot land, LOG and carry on - a
# status write must never be able to kill the install it is reporting on. (# GUARD:saveatomic)
function Save {
    $now = Get-Date
    $script:St.ts = $now.ToString('s')
    # The monotonic truth, and the wall clock's disagreement with it - see WU-PASS-CLOCK above.
    if ($script:PassWatch) {
        $mono = $script:PassWatch.Elapsed.TotalSeconds
        $script:St.elapsed_s = [math]::Round($mono, 1)
        $wall = ($now - $script:PassWallStart).TotalSeconds
        $jump = $wall - $mono
        if ([math]::Abs($jump) -ge $script:ClockJumpThresholdSec) {
            $script:St.clock_jump_s = [math]::Round($jump, 1)
            if (-not $script:ClockJumpLogged) {
                $script:ClockJumpLogged = $true
                Log ("[WARN] QWTUPDCLOCKJUMP the wall clock moved {0:N1} s against {1:N1} s of real elapsed time during this pass - every duration taken from 'ts' is wrong by that much, 'elapsed_s' is not" -f $jump, $mono)
            }
        } elseif ($script:St.Contains('clock_jump_s')) {
            # RECOMPUTED, NEVER STICKY. The field must mean "this pass is out by this much, now".
            # Left set, a jump recorded once would be re-asserted by every later write of a state
            # object that outlives it, and dom0 would read a correction as still pending.
            $script:St.Remove('clock_jump_s')
        }
    }
    # THE LOG'S OWN LOSSES TRAVEL WITH THE STATUS. dom0 reads this file; if lines were dropped, the
    # log it would be told to consult is incomplete, and that must be visible rather than inferred
    # from a gap.
    if ($script:LogDropped -gt 0) {
        $script:St.log_dropped = $script:LogDropped
        $script:St.log_drop_reason = $script:LogDropFirst
    }
    $json = ($script:St | ConvertTo-Json -Depth 6)
    $tmp  = "$StatusFile.tmp"
    $err  = $null
    for ($i = 0; $i -lt 10; $i++) {
        try {
            Set-Content -LiteralPath $tmp -Value $json -Encoding UTF8 -EA Stop
            Move-Item -LiteralPath $tmp -Destination $StatusFile -Force -EA Stop
            return
        } catch {
            $err = $_
            Start-Sleep -Milliseconds 150
        }
    }
    try { Log ("[WARN] could not update the status file after 10 attempts (" + $err.Exception.Message + ") - continuing") } catch {}
}
# ---- WU-SAVE-ATOMIC-END

# ---- WU-MUTEX-DEFINED-BEGIN
# NO UNDEFINED PATH AROUND THIS MUTEX. Three things were undefined before, and all three are here:
#
# 1. THE WAIT. This blocked up to 15 minutes for anything but a scan, writing nothing while it
#    waited, so a guest doing exactly what it should looked wedged to every watcher (measured
#    2026-09-23: an upgrade went silent and was graded STALLED at 300 s). A timed wait is a guess
#    about someone else's progress; taking the lock or refusing is a fact. WaitOne(0) only.
# 2. THE ABANDONED BRANCH. It said "it is ours now" and ran the pass on top of whatever the dead
#    holder had been doing. Worse, it is not even the mechanism it looks like: MEASURED 3/3 on
#    win10-acc (Windows 10 19045), killing a process that owns a named mutex does NOT raise
#    AbandonedMutexException in the next waiter - WaitOne(0) simply returns $true. So this branch
#    is not the detector for a killed pass; it is only a safety net, and it refuses.
# 3. THE KILLED PASS, which is what actually happens (Task Scheduler stops a task at its
#    ExecutionTimeLimit; a guest is shut down mid-pass). The mutex keeps no trace of it, so the
#    detection is the status file this pass already writes: a NON-TERMINAL phase whose owner
#    process is gone means the last pass stopped at an unknown point. Checked BEFORE the mutex is
#    touched, refused loudly, nothing changed.
#
# Why the status file and not a new lease file: it already exists, dom0 already reads it, and it
# already distinguishes the case that would otherwise need extra machinery - a pass that ends
# intending a reboot sets phase='done' BEFORE the handler reboots, so a planned servicing reboot
# is already a terminal phase and needs no reboot flag, no boot identity, nothing.
# RESIDUAL, stated rather than hidden: a kill between WaitOne(0) returning and the save below
# leaves no record - but no work has been done in that window, so there is nothing unknown to
# inherit. A killed DEPLOY is likewise not recorded here; its work (compile-and-swap, schtasks /f)
# is redone wholesale by the next deploy.
# 'diagnosing' counts as finished HERE (and only here): it is the main catch's state between the failure and the measured reason
# (WU-MAIN-CATCH). The pass has already failed and its error is on record; what it still does - a proxy probe, the restart-request
# stamp - changes no update state, so a pass killed in it leaves nothing unknown to inherit. dom0's handler still treats it as
# NOT terminal and waits for the final error (guest/wu-update.ps1 Test-TerminalPhase). Jev review 2026-10-02: without this, a kill in
# that ~3 s window would make every later pass refuse.
$WU_TERMINAL_PHASES = @('done','error','diagnosing','skipped-unknown','skipped-standalone','skipped-appvm')

function Test-WuOwnerAlive([int]$ownerPid, [string]$ownerStart) {
    if ($ownerPid -le 0) { return $false }
    $p = Get-Process -Id $ownerPid -ErrorAction SilentlyContinue
    if (-not $p) { return $false }
    # A pid is reused; the start time is what makes it the SAME process.
    if ($ownerStart) { try { if ($p.StartTime.ToString('s') -ne $ownerStart) { return $false } } catch { return $false } }
    return $true
}

# THE GATE: an interrupted previous pass, refused before the mutex is touched.
# REFUSALS dom0 CAN READ. The three refusals below end this process before it owns the status file, so their message went to
# Write-Host only - the task's console, which nobody reads. dom0's handler (guest/wu-update.ps1) then saw its task end with no status
# of its own, reported a dead pass, and its leftover cleanup tore down the proxy of whichever pass DID own the updater (measured
# 2026-10-02, rz31 on GWeck's environment: the boot scan's relay, mid-search). Each refusal now also leaves this record next to the
# status - never IN it, the status belongs to the holder - and the handler renders it (for 'mutex-held' it waits for the holder and
# starts this pass again).
# RETURNS $true WHEN THE RECORD WAS WRITTEN, because that record is the channel dom0 reads and the
# caller's exit code now depends on it. wu-update.ps1 states the contract in its own words - "A
# REFUSAL IS NOT A DEATH (WU-HOLDER). The pass stood down before it owned anything and recorded why
# - so no DIED line" - and renders "update refused by the qube: <message>". Meanwhile the refusal
# exited 1, Task Scheduler recorded a non-zero result, and qwt-report-death.ps1 sent the user "The
# Windows Update install task failed": TWO user-facing messages for one event, contradicting each
# other, which is the no-double-notification rule broken by our own two halves disagreeing.
# So a refusal that HAS been recorded exits 0 - dom0 is told by the record - and a refusal that
# could NOT be recorded still exits non-zero, because then the exit code is the only signal left.
function Write-Refusal([string]$reason, [string]$message) {
    Write-Host $message
    try {
        $holder = $null
        try { if (Test-Path -LiteralPath $StatusFile) { $holder = Get-Content -LiteralPath $StatusFile -Raw | ConvertFrom-Json } } catch { $holder = $null }
        $hAction = ''; $hPhase = ''; $hPid = ''; $hStart = ''
        if ($holder) { $hAction = "$($holder.action)"; $hPhase = "$($holder.phase)"; $hPid = "$($holder.owner_pid)"; $hStart = "$($holder.owner_pid_start)" }
        $rec = [ordered]@{ ts = (Get-Date).ToString('s'); action = $Action; scheduled = [bool]$Scheduled; reason = $reason; message = $message;
                           holder_action = $hAction; holder_phase = $hPhase; holder_pid = $hPid; holder_start = $hStart }
        $f = Join-Path (Split-Path -Parent $StatusFile) 'update-refusal.json'
        ($rec | ConvertTo-Json -Compress) | Set-Content -LiteralPath "$f.tmp" -Encoding UTF8
        Move-Item -LiteralPath "$f.tmp" -Destination $f -Force
        return $true
    } catch { Write-Host "QWTUPDREFUSALUNRECORDED: $($_.Exception.Message)" }
    return $false
}

# ---- WU-PREVPASS-GATE-BEGIN   (tools/tests/wu-prevpass-gate-test.ps1 runs this region)
# AN EARLIER PASS THAT WAS CUT OFF (owner's decision 2026-10-02, D3). A status left at a non-terminal phase whose owner process is gone
# means a pass was cut off partway - its scheduler time limit, a shutdown or a crash mid-pass. Until 2026-10-02 every later pass
# refused that forever: only a completed pass rewrites the status, and the refusal itself prevented one. Now:
#   * a cut-off SCAN never blocks. A scan only searches; it installs nothing, so nothing is unknown. Measured: the scheduled scan's own
#     PT20M limit cuts off the first scan after a servicing apply on GWeck's template (>25 and >66 min, 2026-09-17);
#   * a pass cut off before this qube's last restart proceeds. Windows completes or rolls back pending servicing during boot, so after
#     a restart that work is settled;
#   * a pass cut off in THIS boot refuses once and requests one restart (reboot_needed, the existing channel - ADR section 8 - on the
#     cut-off pass's own record, which stays non-terminal): its servicing may still be running (TiWorker carries on after our process
#     dies), and a new pass could land on a half-applied install. A second attempt in this boot refuses the same way; the first pass
#     after the restart proceeds.
# Both proceeding cases say so - in the agent log and to dom0 (status field 'recovered', rendered by guest/wu-update.ps1).
$wuPrev = $null
try { if (Test-Path -LiteralPath $StatusFile) { $wuPrev = Get-Content -LiteralPath $StatusFile -Raw | ConvertFrom-Json } } catch { $wuPrev = $null }
if ($wuPrev -and $wuPrev.phase -and ($WU_TERMINAL_PHASES -notcontains $wuPrev.phase)) {
    $prevPid   = 0; $prevStart = ''
    if ($wuPrev.PSObject.Properties.Name -contains 'owner_pid')       { $prevPid   = [int]$wuPrev.owner_pid }
    if ($wuPrev.PSObject.Properties.Name -contains 'owner_pid_start') { $prevStart = "$($wuPrev.owner_pid_start)" }
    if (-not (Test-WuOwnerAlive $prevPid $prevStart)) {
        $prevAction = "$($wuPrev.action)"; $prevPhase = "$($wuPrev.phase)"
        $prevTs = "$($wuPrev.ts)"; if ($wuPrev.ts -is [datetime]) { $prevTs = $wuPrev.ts.ToString('s') }
        $what = "the previous update pass ('$prevAction', last written $prevTs) was cut off at phase '$prevPhase' (its process $prevPid is gone)"
        # When did it last write? Before this boot means it ended with an earlier boot - no process survives a restart.
        $bootT = $null
        try { $bootT = (Get-CimInstance Win32_OperatingSystem -EA Stop).LastBootUpTime } catch { $bootT = $null }
        if (-not $bootT) { try { $bootT = (Get-Date).AddMilliseconds(-[double]([Environment]::TickCount -band [int]::MaxValue)) } catch { } }
        $bootS = ''; if ($bootT) { $bootS = $bootT.ToString('s') }
        # The boot a refusal below was made in. A DIFFERENT boot now means the requested restart has happened - the answer even when
        # the cut-off pass's own timing cannot be read (without it that case would refuse in every boot: the dead end this removes).
        $refusedBoot = ''
        if ($wuPrev.PSObject.Properties.Name -contains 'refused_boot') {
            # pwsh 7's ConvertFrom-Json hands an ISO string back as a DateTime; Windows PowerShell 5.1 leaves it a string - compare both as 's'
            if ($wuPrev.refused_boot -is [datetime]) { $refusedBoot = $wuPrev.refused_boot.ToString('s') } else { $refusedBoot = "$($wuPrev.refused_boot)" }
        }
        $lastT = [datetime]::MinValue
        $lastKnown = [datetime]::TryParseExact($prevTs, 'yyyy-MM-ddTHH:mm:ss', [Globalization.CultureInfo]::InvariantCulture,
                                               [Globalization.DateTimeStyles]::None, [ref]$lastT)
        if ($prevAction -eq 'scan') {   # GUARD:prevscan
            $script:St.recovered = "$what - a scan installs nothing, so nothing is unknown; continuing"
        } elseif ($bootT -and $lastKnown -and $lastT -lt $bootT) {   # GUARD:prevboot
            $script:St.recovered = ("$what before this qube's last restart ($bootS) - Windows completes or rolls " +
                                    'back pending servicing during boot, so that work is settled; continuing')
        } elseif ($refusedBoot -and $bootS -and $refusedBoot -ne $bootS) {   # GUARD:refusedboot
            $script:St.recovered = ("$what; a pass refused it in an earlier boot ($refusedBoot) and requested a restart, which has " +
                                    "happened ($bootS) - Windows has settled that servicing during boot; continuing")
        } else {
            # In THIS boot - or its timing cannot be read, which is treated the same way: one restart settles it either way.
            # THE RESTART REQUEST IS RECORDED EITHER WAY, before deciding whether to refuse: an INSTALL pass must still
            # refuse until the qube has been restarted once, and that has to hold whether or not THIS caller refuses.
            $recordErr = ''
            try {
                if ($wuPrev.PSObject.Properties.Name -contains 'reboot_needed') { $wuPrev.reboot_needed = $true }
                else { $wuPrev | Add-Member -NotePropertyName reboot_needed -NotePropertyValue $true }
                if ($bootS -and -not $refusedBoot) { $wuPrev | Add-Member -NotePropertyName refused_boot -NotePropertyValue $bootS -Force }
                ($wuPrev | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath "$StatusFile.tmp" -Encoding UTF8
                Move-Item -LiteralPath "$StatusFile.tmp" -Destination $StatusFile -Force
            } catch { $recordErr = " (The restart request could not be recorded: $($_.Exception.Message) - restart it yourself.)" }

            if ($Action -eq 'scan') {   # GUARD:scanreadonly
                # A SCAN ONLY READS, so there is nothing for unfinished servicing to make unknown - which is exactly
                # what GUARD:prevscan above already says ("a scan installs nothing, so nothing is unknown"). That guard
                # tested the wrong side: whether the PREVIOUS action was a scan, rather than whether the action about to
                # run is one. The consequence was measured on a faithful reproduction of the reporter's case
                # (2026-10-07): the installer's own pass is cut off by the install's reboot, the boot+2min scheduled
                # scan lands in THIS boot, falls through to the refusal below, and exits 1. Task Scheduler records
                # 0x80070001, the death reporter correctly turns a non-zero task result into a dom0 notification, and
                # the user's first sight of a freshly installed qube is "The Windows Update scan task failed" - for a
                # read-only operation that had nothing to refuse. The restart request above still stands for an install.
                $script:St.recovered = ("$what in THIS boot, but a scan only reads - it installs nothing and cannot land on " +
                                        'top of unfinished servicing, so nothing is unknown to it; continuing. A restart has ' +
                                        "been requested and an install pass will still refuse until it has happened.$recordErr")
            } else {
                $m = ("QWTUPDSTATEUNKNOWN: $what in THIS boot - its Windows servicing may still be running; refusing to start a $Action " +
                      'on top of it, nothing was changed. Restart this qube once, then update again (a restart has been requested).' +
                      $recordErr)
                # Recorded -> dom0 renders it and the task did not fail; unrecorded -> the exit code
                # is the only signal left.
                # THE MARKER BELONGS ON THE LINE THE KNOB MUST DEFEAT, and for a while it did not.
                # tools/tests/wu-prevpass-gate-test.ps1's Knob() matches "# GUARD:<name>$" - the marker
                # must END the line - and replaces that whole line to inject the defect. 8c9782cc moved
                # this marker onto the COMMENT above, where two things broke at once: the regex stopped
                # matching (the knob reported "expected exactly 1 '# GUARD:thisboot' line, found 0"), and
                # even a match would have replaced a comment with a comment and injected nothing. The
                # 'nothisboot' leg was decoration from then on - and 8c9782cc is the commit that fixed
                # the scan refusal this guard sits next to, so the fix disabled its sibling's proof.
                if (Write-Refusal 'state-unknown' $m) { exit 0 } else { exit 1 }   # GUARD:thisboot
            }
        }
    }
    # owner alive = a pass really is running; that is ordinary contention and the mutex below says so.
}
# ---- WU-PREVPASS-GATE-END

$script:Mutex = New-Object System.Threading.Mutex($false, 'Global\QubesWindowsUpdate')
$script:HaveMutex = $false
try {
    $script:HaveMutex = $script:Mutex.WaitOne(0)   # NEVER a timed wait: take it or refuse
} catch [System.Threading.AbandonedMutexException] {
    # .NET hands us the mutex with this exception; give it back before refusing, or this process
    # exits owning it and every later run inherits the same abandonment.
    try { $script:Mutex.ReleaseMutex() } catch { }
    # A SCHEDULED SCAN DOES NOT FAIL OVER THIS, for the same reason GUARD:thisboot no longer refuses
    # one: a scan only READS - it installs nothing and cannot land on top of unfinished servicing -
    # so an abandoned mutex leaves it nothing to refuse. And the refusal has NOWHERE to go for a
    # scan: wu-update.ps1's Get-FreshRefusal discards any record whose action is 'scan' by design
    # ("never a scheduled scan's"), so the ONLY thing that reached the user was the non-zero task
    # result, which the death reporter correctly renders as "The Windows Update scan task failed" -
    # about a read-only operation that deliberately declined and changed nothing. Reachable exactly
    # as reported: the install's own reboot cuts off the installer's pass, the boot+2min scheduled
    # scan finds the mutex abandoned, and the user's first sight of a freshly installed qube is that
    # error. The sibling branch above was fixed for this in 2026-10-07 and this one was left.
    # YIELDING IS SELF-HEALING: .NET handed us the mutex with the exception and the release above
    # clears the abandonment, so the next scheduled scan takes it cleanly. Nothing is hidden - the
    # abandonment is a real anomaly and is logged as one; what is removed is a user-facing ERROR
    # about a task that did exactly the right thing.
    if ($Scheduled -and $Action -eq 'scan') {
        Log ("QWTUPDMUTEXABANDONED: a previous update operation was terminated without releasing " +
             "Global\QubesWindowsUpdate - the abandonment is cleared and this scheduled scan yields; " +
             "a scan only reads, so it has nothing to refuse. The next scheduled scan takes the mutex cleanly.") 'WARN'
        exit 0
    }
    if (Write-Refusal 'mutex-abandoned' ("QWTUPDMUTEXABANDONED: a previous update operation was terminated without releasing " +
                "Global\QubesWindowsUpdate, so what it was doing is unknown; refusing to start a $Action " +
                "on top of it, nothing was changed.")) { exit 0 } else { exit 1 }
}
if (-not $script:HaveMutex) {
    if ($Scheduled -and $Action -eq 'scan') {
        # A scheduled scan yields to a running pass - it changes nothing - but the contention is on
        # the record rather than looking like an ordinary skip.
        Log "QWTUPDMUTEXHELD: another Qubes update operation is in progress - skipping this scheduled scan"
        exit 0
    }
    if (Write-Refusal 'mutex-held' ("QWTUPDMUTEXHELD: another Qubes update operation is in progress - refusing to run this " +
                "$Action under it; nothing was changed. Let it finish (schtasks /query /tn QubesWindowsUpdateRun /v) " +
                "or end it (schtasks /end /tn <task>) and retry.")) { exit 0 } else { exit 1 }
}
# OWNERSHIP ON THE RECORD, IMMEDIATELY - before any work, so a kill from here on is detectable by
# the gate above on the next start.
$script:St.owner_pid = $PID
$script:St.owner_pid_start = ''
# Guarded, not chained: Get-Process returns $null rather than throwing under
# -ErrorAction SilentlyContinue, and a chain on $null is exactly the class the linter refuses.
$meProc = Get-Process -Id $PID -ErrorAction SilentlyContinue
if ($meProc) { try { $script:St.owner_pid_start = $meProc.StartTime.ToString('s') } catch { } }
$script:St.phase = 'init'
Save
# ---- WU-MUTEX-DEFINED-END
New-Item -ItemType Directory -Force $WorkDir | Out-Null
# Legacy flat layout: .msu directly in the work dir. They are what DISM dragged into an unrelated
# servicing session, and they belong to no known KB now, so drop them once.
foreach($stale in @(Get-ChildItem (Join-Path $WorkDir '*.msu') -EA SilentlyContinue)) {
    Remove-Item -LiteralPath $stale.FullName -Force -EA SilentlyContinue
}
# WHICH catalog package applies is a property of THIS guest, not a constant. Hardcoding
# "x64 + 24H2|26100" made KB5120708 unresolvable on 25H2, where the applicable entry is titled
# "... for Windows 11, version 25H2 for x64" - the scan offered it and nothing could install it.
$__cv    = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -EA SilentlyContinue
$OsVer   = $__cv.DisplayVersion          # e.g. 25H2
$OsBuild = $__cv.CurrentBuild            # e.g. 26200
$OsArch  = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }

$IS='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings'
$POL='HKLM:\SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\Internet Settings'


# A pass FINISHED. Distinct from Save, which also runs on every progress tick - `ts` therefore
# means "last activity" and cannot answer "when did a pass last complete". The scheduled-scan
# debounce needs exactly that, and reading `ts` instead would let a long download suppress the
# scan that should follow it. Records WHICH action completed too, so the skip message can say so.
function Complete-Pass {
    $script:St.done_ts = (Get-Date).ToString('s')
    $script:St.action  = $Action
    Save
}
# Does a status/result row carry a key? The rows this pass builds are [ordered]@{...}, i.e.
# OrderedDictionary, and on a dictionary PSObject.Properties.Name lists the .NET MEMBERS (Count,
# IsReadOnly, Keys, Values, IsFixedSize, SyncRoot, IsSynchronized) - never the keys. Measured on the
# guest's own Windows PowerShell 5.1.26100 and on pwsh 7.6 alike, so a key test written through it
# is a filter that matches nothing. A row that came back through ConvertFrom-Json is a PSCustomObject,
# where the property list IS the key list; both shapes are answered here, by their own contract.
# ---- WU-ROWKEY-BEGIN
function Test-RowKey($row, [string]$key) {
  if ($row -is [System.Collections.IDictionary]) { return [bool]$row.Contains($key) }
  return (@($row.PSObject.Properties.Name) -contains $key)
}
# INSTALLED AND PROVED INSTALLED (ADR-updater section 2 point 3) - the ONE test, read by `satisfied` (GUARD:offeridentity), the
# post-install count (WU-INFO-EXCLUDE) and the reboot-pending count (WU-REBOOT-PENDING-REPORT), so the three cannot drift apart.
# ok=true, not informational, and state 'installed' - or no state at all, the shape of a row an older writer measured installed
# (the captured direct-signature row: severity 'ok', "verified by effect"). Every shipped writer states the outcome - Install-ViaWU
# from each update's own RebootRequired since 2026-11-02 - so a STAGED row says 'staged': ok=true and NOT installed, it waits for
# the restart (GUARD:stagedpending). An informational row is never installed, whatever its ok says.
function Test-RowInstalled($row) {
  if (-not $row -or $row.ok -ne $true) { return $false }
  if ((Test-RowKey $row 'severity') -and "$($row.severity)" -eq 'info') { return $false }
  return ((-not (Test-RowKey $row 'state')) -or ([string]$row.state -eq 'installed'))
}
# What THIS pass installed, by kb and title (a no-KB row is recorded under its title), and the offer identities (uid:rev) of the
# scan's offers it names - what both ends of a pass write to `satisfied` (the post-install rescan, the reboot-pending report).
function Get-InstalledKeys {
  # '(no KB)' IS NOT A KEY, AND USED TO BE SPENT AS ONE. Get-Available labels every offer carrying no
  # KBArticleIDs '(no KB)' and Install-ViaWU labels its rows the same way, so ONE installed no-KB row
  # put that literal in here - and the post-install rescan's $notInstalled, which matches an offer on
  # kb/title, then excluded EVERY no-KB offer from the number dom0 hears. Reachable on any routed
  # guest with two such offers: the WU-by-identity path (WUNOKBMISSNOTINSTALLEDONROUTEDGUEST's fix)
  # installs one and the other vanishes from the count - the under-report the owner reported from the
  # field, by a different door. The IDENTITY path never had this hole: Get-InstalledIdentities drops a
  # stamped row's kb from the join as $spoken, so only the raw key join below ever used the label.
  # Dropping it costs nothing a reader can see. A row with no identity records nothing and its offer
  # is COUNTED AGAIN - this file's own stated rule ("the fallback is always count it") and the safer
  # error of the two (Jev: under-reporting is the worse one, 0.99).
  return @(@($script:St.result) | Where-Object { Test-RowInstalled $_ } |
           ForEach-Object { $_.kb; if (Test-RowKey $_ 'title') { $_.title } } |
           Where-Object { $_ -and "$_" -ne '(no KB)' })
}
function Get-InstalledIdentities($keys) {
  # A ROW THAT CARRIES ITS OWN IDENTITY IS TAKEN AT ITS WORD, and only a row without one is
  # joined back to the scan's offers on kb/title. The join is what hid a re-presented offer:
  # same KB, new revision, so keying on kb/title matched the OLD available row and dom0 heard
  # N-1 and then N (WURESCANKEYSBYKBSCANBYIDENTITY). Install-ViaWU stamps uid/rev on the rows
  # it returns, so the non-catalog fallback path needs no join at all.
  $own = @(@($script:St.result) |
           Where-Object { (Test-RowInstalled $_) -and (Test-RowKey $_ 'uid') -and $_.uid } |
           ForEach-Object { "$($_.uid):$($_.rev)" })
  # AND THE JOIN MUST NOT ANSWER FOR A ROW THAT ALREADY SPOKE. A stamped row's KB is dropped from
  # the join's keys, so the scan's twin of that offer - same KB, NEW revision - cannot ride in on
  # it. Without this the stamp would be inert: $own would hold uid:204 and the join would add
  # uid:205 beside it, and the re-presented offer would be subtracted from dom0's number exactly
  # as before. An unstamped installed row still joins on kb/title, which is the offer loop's
  # residual and is named as such in ADR-updater section 2.
  $spoken = @(@($script:St.result) |
           Where-Object { (Test-RowInstalled $_) -and (Test-RowKey $_ 'uid') -and $_.uid } |
           ForEach-Object { $_.kb; if (Test-RowKey $_ 'title') { $_.title } } | Where-Object { $_ })
  $joinKeys = @(@($keys) | Where-Object { $spoken -notcontains $_ })
  $joined = @(@($script:St.available) | Where-Object { $_ -and (($joinKeys -contains $_.kb) -or ($joinKeys -contains $_.title)) } |
           ForEach-Object { if ((Test-RowKey $_ 'uid') -and $_.uid) { "$($_.uid):$($_.rev)" } } | Where-Object { $_ })
  return @(@($own + $joined) | Sort-Object -Unique)
}
# The key an offer's no-route verdict is recorded and looked up under (ADR-updater section 2 point 5, extended 2026-11-06): the KB when
# the offer has one, else its exact title, used whole (section 6: never parsed). A no-KB offer's kb field is the shared placeholder
# '(no KB)', and the WU-NOKB result row carries the title in kb, so this one function serves offers and result rows alike.
function Get-OfferRouteKey($u) {
  if ($u -and (Test-RowKey $u 'kb') -and ("$($u.kb)" -match '^KB\d+$')) { return "$($u.kb)" }
  if ($u -and (Test-RowKey $u 'title') -and "$($u.title)".Trim()) { return "$($u.title)".Trim() }
  if ($u -and (Test-RowKey $u 'kb') -and "$($u.kb)" -ne '(no KB)') { return "$($u.kb)".Trim() }   # a result row written with the title in kb
  return ''
}
# ---- WU-ROWKEY-END
# What the start gate (WU-PREVPASS-GATE) decided about a cut-off earlier pass goes on the record here.
if ($script:St.recovered) { Log ("PREVPASS " + $script:St.recovered) }
function SetV($p,$n,$v,$t){ if(-not(Test-Path $p)){New-Item -Path $p -Force|Out-Null}; New-ItemProperty -Path $p -Name $n -Value $v -PropertyType $t -Force|Out-Null }

# The proxy is up ONLY for the duration of a pass. Leaving the system-wide WinHTTP proxy set
# turns the relay into an always-on escape hatch: every Windows background HTTP client (telemetry,
# Edge/Defender update checks, NCSI, DO) discovers it and phones home, each connection spawning a
# qrexec qubes.UpdatesProxy call - measured 147 dom0 policy hits in one afternoon on an "offline"
# guest, still dripping hours after the last scan. Remove-Proxy in the finally below restores the
# routeless baseline; update traffic is the only traffic that ever gets a path out.
# ---- WU-RELAY-BEGIN   (region markers)
function Test-RelayListening {
  param([int]$BoundMs = 15000)
  # Does something ACCEPT a TCP connection on 127.0.0.1:8082? A relay PROCESS existing does not prove
  # the port is being serviced (a hung/dead relay, or a squatter, yields 0x80072EFD
  # ERROR_INTERNET_CANNOT_CONNECT). This catches the proven-once failure the old process-exists check
  # missed.
  #
  # IT NOW POLLS, BECAUSE A SINGLE ATTEMPT NEVER WAITED. The old body made ONE BeginConnect and gave
  # it WaitOne(3000), and its comment said "within 3 s" - but a connect to a loopback port with NO
  # LISTENER is refused IMMEDIATELY (ECONNREFUSED); the 3 s was only a ceiling for a connect already
  # in progress, so the check sampled readiness once, right after a flat 2 s sleep, and never spent
  # the bound waiting for it. MEASURED 2026-10-19, release 4.3.37 acceptance, feature test
  # template-update on the German TemplateVM win11de-tup - it failed all three rounds and failed the
  # release:
  #   01:35:52  relay started: pid 1536 ... owned by handle
  #   01:35:56  relay pid 1536 is not accepting connections on 127.0.0.1:8082 within 3 s - ... starting another
  #   01:35:56  relay pid 1536 stopped by this pass (exit code -1)
  #   01:35:58  relay started: pid 4780 ... owned by handle
  #   01:36:02  [ERROR] relay pid 4780 still not accepting connections on 127.0.0.1:8082 after respawn
  #   01:36:02  relay pid 4780 stopped by this pass (exit code -1)
  # Stop-OwnRelay prints "had already exited" for a process that is gone and "stopped by this pass"
  # for one it had to kill - both say the latter, so the relay was ALIVE and had simply not reached
  # its listen yet. The pass then ended without reporting to dom0 at all. Jev: never_waits 0.23 (i.e.
  # it does not), poll_until_bound 1.00.
  # NOT A TIMEOUT AS A FIX: the bound is what the check always claimed to measure, and it is now
  # actually spent. The attempt count is published so the log can say how long readiness took.
  $deadline = [DateTime]::UtcNow.AddMilliseconds($BoundMs)
  $script:RelayListenAttempts = 0
  while ($true) {
    $script:RelayListenAttempts++
    try {
      $c = New-Object System.Net.Sockets.TcpClient
      $iar = $c.BeginConnect('127.0.0.1', 8082, $null, $null)
      $ok = $iar.AsyncWaitHandle.WaitOne(1000)
      $res = ($ok -and $c.Connected)
      $c.Close()
      if ($res) { return $true }
    } catch { }
    if ([DateTime]::UtcNow -ge $deadline) { return $false }
    Start-Sleep -Milliseconds 250
  }
}
# WHAT THE RELAY ITSELF SAID, for the two failure paths below. The relay writes the file Start-Relay
# named for it ($script:RelayLogPath, passed as --log-file), including "parent watchdog armed: pid N"
# and then "listen 127.0.0.1:<port> target=..." immediately before its listener.Start() - so its own
# log says how far it got. Neither failure path read it, and the harness did not collect it, so the
# one artefact that explains the failure was discarded every time. Jev: diagnosis_gap 0.81.
function Get-RelayDiagnosis {
  $alive = 'liveness unreadable'
  try {
    $p = $script:OwnRelay
    if ($p) { $alive = $(if ($p.HasExited) { "exited on its own (code {0})" -f $p.ExitCode } else { 'still running' }) }
  } catch { }
  $tail = ''
  try {
    $lp = $script:RelayLogPath
    if ($lp -and (Test-Path -LiteralPath $lp)) { $tail = ((Get-Content -LiteralPath $lp -Tail 6 -ErrorAction Stop) -join ' | ') }
    else { $tail = "no relay log at $lp - the relay never got as far as writing one" }
  } catch { $tail = "relay log unreadable: $($_.Exception.Message)" }
  return ("relay pid {0} {1} after {2} connect attempt(s); its own log: {3}" -f `
            $script:OwnRelayPid, $alive, $script:RelayListenAttempts, $tail)
}
# Who LISTENS on 127.0.0.1:8082 right now: the owning pid, 0 when nobody does, -1 when the table cannot be read (UNKNOWN IS NOT
# ZERO). The owner is found by the PORT and identified by its PID - never by a process name (docs/ADR-updater.md 12.4). When the
# port is free Get-NetTCPConnection reports "no matching objects" as an ObjectNotFound error, so that error IS the free answer and
# any other error is unknown. Mirrored in guest/wu-update.ps1 and guest/install-updater-agent.ps1 (neither can load this file: it
# IS the pass); keep the three in step.
function Get-RelayPortOwner {
  $ev = @()
  try { $l = @(Get-NetTCPConnection -LocalPort 8082 -State Listen -ErrorAction SilentlyContinue -ErrorVariable ev) } catch { return -1 }
  if ($l.Count -gt 0) { return [int]$l[0].OwningProcess }
  foreach ($e in $ev) { if ("$($e.CategoryInfo.Category)" -ne 'ObjectNotFound') { return -1 } }
  return 0
}
# The refusal, with the owner NAMED. Passes are serialized by the updater mutex, so nothing else of ours can be serving 8082 while
# this pass runs: another owner is an anomaly to investigate, never a relay to use. This pass hands its traffic to nothing it did
# not start, and it does not kill what it did not start either.
function Format-RelayRefusal([int]$owner) {
  if ($owner -lt 0) { return 'REFUSED: cannot read who listens on 127.0.0.1:8082 (Get-NetTCPConnection failed), so the port cannot be shown free - this pass never adopts a relay it did not start and never serves through an unknown one (ADR-updater 12.4); nothing was started' }
  if ($owner -eq 0) { return ("REFUSED: nothing listens on 127.0.0.1:8082 right after relay pid {0} accepted a connection - that relay is gone; nothing was adopted and nothing else is started" -f $script:OwnRelayPid) }
  $who = ''
  try { $op = Get-Process -Id $owner -ErrorAction SilentlyContinue; if ($op) { $who = " ($($op.ProcessName), started $($op.StartTime.ToString('s')))" } } catch { }
  return "REFUSED: 127.0.0.1:8082 is already served by pid $owner$who, which this pass did not start - the pass never adopts a relay (ADR-updater 12.4), and under the updater mutex another listener on its port is an ANOMALY: find out what pid $owner is before the next pass; it was NOT killed"
}
# Start-Process joins -ArgumentList with bare spaces - Windows PowerShell 5.1 quotes nothing - and the log directory is
# "<SystemDrive>\Qubes Logs" by default: unquoted, "Logs" reaches the relay as a stray argument and it refuses to start.
# Quoted by the rules its argument parser applies, a trailing backslash doubled so it cannot escape the closing quote.
function ConvertTo-RelayArg([string]$s) {
  if ($s -and $s -notmatch '\s') { return $s }
  return '"' + ($s -replace '(\\+)$', '$1$1') + '"'
}
function Start-Relay {
  if (-not (Test-Path -LiteralPath $RelayExe)) { throw "relay not found at $RelayExe" }
  $env:QUBES_UPDATES_MAXCONN='256'
  # THE RELAY'S LOG IS NAMED HERE, once per pass, in the one log directory (docs/ADR-logging.md, Decision 2026-11-01), and
  # this pass reads it back (Get-RelayGiveUps, Get-RelayDiagnosis): one variable on both sides, so the reader cannot look at
  # another day's file than the one the relay writes - it writes this one for its whole life, and a respawn writes it too.
  # --log is the directory the relay's handlers write their own per-day log into.
  $relayLogDir = Get-QwtLogDir
  if (-not $script:RelayLogPath) { $script:RelayLogPath = Join-Path $relayLogDir ('qubes-updates-relay-' + (Get-Date -Format 'yyyyMMdd') + '.log') }
  # OWNED BY HANDLE (ADR-updater 12.4): -PassThru hands back the Process object of the one relay THIS pass started; that object,
  # its pid and its start time are the only identity this pass ever stops (Stop-OwnRelay). --parent-pid: the relay exits on its
  # own when THIS process is gone (measured 2026-09-17: a pass ended hard by the scheduler never reached the Remove-Proxy below,
  # and the relay served for hours).
  $p = Start-Process -FilePath $RelayExe -ArgumentList '--listen','8082','--target','@default','--log',(ConvertTo-RelayArg $relayLogDir),'--log-file',(ConvertTo-RelayArg $script:RelayLogPath),'--parent-pid',"$PID" -WindowStyle Hidden -PassThru   # GUARD:relayhandle
  $script:OwnRelay = $p
  $script:OwnRelayPid = 0
  $script:OwnRelayStart = ''
  if ($p) {
    $script:OwnRelayPid = [int]$p.Id
    try { $script:OwnRelayStart = $p.StartTime.ToString('s') } catch { }
  }
  Log ("relay started: pid {0}, start {1}, parent {2} - owned by handle; this pass stops this one and no other" -f $script:OwnRelayPid, $(if ($script:OwnRelayStart) { $script:OwnRelayStart } else { 'unreadable' }), $PID)
  Start-Sleep -Seconds 2
}
# Stops exactly the relay THIS pass started, by the handle Start-Relay kept - never by name, never by port. A handle cannot be
# fooled by pid reuse. Every outcome is logged; a stop that does not complete is an anomaly, not a retry.
function Stop-OwnRelay {
  $p = $script:OwnRelay
  if (-not $p) { Log 'relay: this pass holds no relay handle - nothing of ours to stop (a relay this pass did not start is never touched)'; return }
  $script:OwnRelay = $null
  $id = $script:OwnRelayPid
  try {
    if ($p.HasExited) { Log ("relay pid {0} had already exited (exit code {1}) - nothing to stop" -f $id, $p.ExitCode); return }
    $p.Kill()
    if ($p.WaitForExit(10000)) { Log ("relay pid {0} stopped by this pass (exit code {1})" -f $id, $p.ExitCode) }
    else { Log ("ANOMALY: relay pid {0} did not exit within 10 s of being killed by this pass" -f $id) }
  } catch { Log ("ANOMALY: relay pid {0} NOT stopped: {1}" -f $id, $_.Exception.Message) }
}
function Ensure-Proxy {
  # NEVER ADOPT (ADR-updater 12.4). Until 2026-10-03 this started a relay only if no process NAMED qubes-updates-relay existed and
  # otherwise served through whatever answered on 8082 - measured that day: the boot scan adopted a relay another process had
  # started, and its Remove-Proxy then killed it mid-transfer. Now the port's owner is read first, and a port that is not free is
  # a refusal naming the owner, before any proxy setting is touched.
  $owner = Get-RelayPortOwner
  if ($owner -ne 0) { throw (Format-RelayRefusal $owner) }   # GUARD:relayrefuse
  & netsh winhttp set proxy '127.0.0.1:8082' '<local>' | Out-Null
  SetV $POL 'ProxySettingsPerUser' 0 'DWord'; SetV $IS 'ProxyEnable' 1 'DWord'
  SetV $IS 'ProxyServer' '127.0.0.1:8082' 'String'; SetV $IS 'ProxyOverride' '<local>' 'String'
  Start-Relay
  # Serviceability probe: a relay that exists but is not accepting would fail the pass 0x80072EFD. Stop and respawn ONLY the relay
  # this pass started, by its handle; the port is re-read before the respawn, because a listener that appeared meanwhile is not
  # ours either.
  if (-not (Test-RelayListening)) {
    # SAY WHY BEFORE KILLING IT: Stop-OwnRelay overwrites the only liveness evidence there is, because
    # its own kill supplies the exit code. Read the relay's account first.
    Log ("relay pid {0} is not accepting connections on 127.0.0.1:8082 within the readiness bound - {1}" -f $script:OwnRelayPid, (Get-RelayDiagnosis))
    Log ("relay pid {0}: stopping THAT relay (by its handle) and starting another" -f $script:OwnRelayPid)
    Stop-OwnRelay   # GUARD:relayrespawnown
    Start-Sleep -Seconds 1
    $owner = Get-RelayPortOwner
    if ($owner -ne 0) { throw (Format-RelayRefusal $owner) }
    Start-Relay
    if (-not (Test-RelayListening)) {
      $why = Get-RelayDiagnosis
      Log ("relay pid {0} did not serve the port after a respawn either - {1}" -f $script:OwnRelayPid, $why)
      throw ("relay pid {0} still not accepting connections on 127.0.0.1:8082 after respawn - {1}" -f $script:OwnRelayPid, $why)
    }
  }
  # THE LISTENER MUST BE OURS. Accepting a connection proves that something serves the port, not that it is the relay this pass
  # started: a listener that won the port between the check above and our start would be adopted by the connect test alone.
  $owner = Get-RelayPortOwner
  if ($owner -ne $script:OwnRelayPid) { Stop-OwnRelay; throw (Format-RelayRefusal $owner) }   # GUARD:relayidentity
  Log ("proxy up: 127.0.0.1:8082 is served by relay pid {0}, started by this pass" -f $script:OwnRelayPid)
}
# ---- WU-RELAY-END

# GUARD:wusession WAS HERE AND IS REMOVED, 2026-09-21. It stopped wuauserv after Ensure-Proxy set
# the proxy, on the theory that WU held a WinHTTP session created before the proxy existed. It was
# MEASURED on win11de-wus (fresh clone of the sealed German golden, env-assert gweck passed,
# artefact byte-verified, install ledger requested=0 performed=0 so never cycled) and it DOES NOT
# WORK: the reset ran and the pass still died at 0x8024402C, twice. Restarting the WHOLE update
# service set - wuauserv, UsoSvc, DoSvc, BITS, cryptsvc, WaaSMedicSvc - did not help either.
# ONE REBOOT DID: the very next pass got past the search and downloaded a 4.4 GB cumulative.
# So the first-boot requirement is NOT a service-session problem, and a change with no measured
# effect does not stay in the shipped script (owner's rule, the 30f2393 flush precedent).
# The defect itself remains OPEN in findings/issues.md - what a boot establishes that a service
# restart does not is still unknown.

# REVOCATION SYNC - without this, every pass on a guest whose CTL cache has expired dies at
# 0x80072F8F before its first byte of update metadata. Measured + root-caused 2026-08-19:
# schannel REQUIRES revocation on the WU endpoints, and Microsoft-rooted chains use
# AUTO-UPDATE (CTL) revocation - the chain elements carry CERT_TRUST_AUTO_UPDATE_*_REVOCATION
# and the engine wants a FRESH disallowedcertstl from ctldl.windowsupdate.com, NOT the CDP
# CRLs (store-imported, KeyID-matched, time-valid CRLs were measured to change nothing).
# CryptoAPI's own fetches go DIRECT (never through the relay; no DNS on a proxy-only guest),
# so the CTLs can only arrive if WE carry them: fetch through the relay (ctldl is on its
# domain allowlist; plain-HTTP rides the verified/retried path built for exactly these files
# on 2026-08-14), mirror them locally, point AuthRoot\AutoUpdate!RootDirURL at the mirror,
# and flush the chain cache. The cabs are Microsoft-SIGNED CTL containers - Windows validates
# them at use, so a corrupted/hostile body is inert, not a poisoning vector.
# Side effect, accepted: OS root-store auto-update now sources from the mirror, i.e. new
# Microsoft roots arrive when a pass refreshes the mirror (before this, they never arrived).
function Sync-Revocation {
  $dir = 'C:\ProgramData\QubesCTL'
  New-Item -ItemType Directory -Path $dir -Force | Out-Null
  $proxy = 'http://127.0.0.1:8082'
  $got = 0
  foreach ($f in 'disallowedcertstl.cab','authrootstl.cab','pinrulesstl.cab') {
    # 2 attempts, 3 s apart: the relay's accept loop can lag its Start-Process by a few
    # seconds (warm-channel pool), and one connect-refused was measured to cost a whole pass.
    foreach ($try in 1..2) {
      try {
        Invoke-WebRequest -Uri "http://ctldl.windowsupdate.com/msdownload/update/v3/static/trustedr/en/$f" `
          -Proxy $proxy -OutFile "$dir\$f.new" -UseBasicParsing -TimeoutSec 60
        Move-Item "$dir\$f.new" "$dir\$f" -Force
        $got++
        break
      } catch {
        Remove-Item "$dir\$f.new" -Force -EA SilentlyContinue
        if ($try -eq 2) {
          # "keeping existing copy" was said even when there was NOTHING to keep. On a pristine
          # guest that is simply false, and it hid the state that matters.
          $had = Test-Path "$dir\$f"
          $tail = if ($had) { 'keeping the existing copy' } else { 'and there is NO existing copy' }
          Log "Sync-Revocation: $f fetch failed ($($_.Exception.Message)) - $tail" 'WARN'
        }
        else { Start-Sleep -Seconds 3 }
      }
    }
  }
  # Only point the OS root-store updater at the mirror if the mirror can actually serve it.
  # Repointing it at an EMPTY directory is worse than leaving it alone: chain building then finds
  # no CTL at all and fails with 0x80072F8F, while this function's log line claimed success. The
  # two that matter are the root list and the disallowed list; pinrules missing is survivable.
  $have = @('disallowedcertstl.cab','authrootstl.cab','pinrulesstl.cab') | Where-Object { Test-Path "$dir\$_" }
  $core = @('authrootstl.cab','disallowedcertstl.cab') | Where-Object { Test-Path "$dir\$_" }
  if ($core.Count -eq 2) {
    SetV 'HKLM:\SOFTWARE\Microsoft\SystemCertificates\AuthRoot\AutoUpdate' 'RootDirURL' "file://$dir" 'String'
    if ($have.Count -lt 3) { Log "Sync-Revocation: mirror is missing $(3 - $have.Count) of 3 CTLs but has both core lists - repointed anyway" 'WARN' }
  } else {
    # Leave the OS on whatever it was using; do not hand it a mirror that cannot answer. Take OUR
    # pointer away if a previous pass set one, so a half-built mirror from an earlier run cannot
    # keep poisoning chain validation.
    Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\SystemCertificates\AuthRoot\AutoUpdate' -Name 'RootDirURL' -EA SilentlyContinue
    Log "Sync-Revocation: FAILED - the CTL mirror has no usable root list (have: $($have -join ',' )). RootDirURL left unset, so certificate chain building may fail with 0x80072F8F until a pass succeeds." 'ERROR'
    $script:St.ctl_mirror = 'unusable'
    return
  }
  foreach ($v in 'DisallowedCertLastSyncTime','LastSyncTime','PinRulesLastSyncTime') {
    Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\SystemCertificates\AuthRoot\AutoUpdate' -Name $v -EA SilentlyContinue
  }
  # quoted deliberately: bare @now is PowerShell splatting and silently drops the argument
  & certutil -setreg 'chain\ChainCacheResyncFiletime' '@now' | Out-Null
  Log "Sync-Revocation: $got/3 CTLs refreshed through the relay, chain cache flushed"
}

# TEMPORAL GATE - still required, and not superseded by the relay's positional one.
# The relay now refuses any caller that is not the update process, which closes the leak this
# comment block describes. That check lives in our code and depends on our own process-identity
# logic being right; this teardown does not. Keeping both means a mistake in either one is
# bounded by the other: a wrong allowlist is still limited to the minutes a pass runs, and a
# pass left open still serves nobody but the update. Do not remove this because the other exists.
# ---- WU-RELAY-TEARDOWN-BEGIN   (region markers)
function Remove-Proxy {
  & netsh winhttp reset proxy | Out-Null
  SetV $IS 'ProxyEnable' 0 'DWord'
  Remove-ItemProperty -Path $IS -Name 'ProxyServer' -EA SilentlyContinue
  # ONLY THE RELAY THIS PASS STARTED, by its handle (ADR-updater 12.4). Until 2026-10-03 this line killed every process NAMED
  # qubes-updates-relay - measured that day: a relay another process had started, TerminateProcess'ed mid-transfer with no log
  # line and no crash record. A relay this pass did not start is not its to stop; that relay's own --parent-pid watchdog ends it
  # when ITS pass is gone.
  Stop-OwnRelay   # GUARD:relayownstop
  Log 'proxy removed (offline baseline restored)'
}
# ---- WU-RELAY-TEARDOWN-END

# Report the available-update count to dom0's qubes.NotifyUpdates (target: bare dom0).
# THIS build of qrexec-client-vm.exe takes ONE pipe-delimited command line "domain|service|user|
# local program [args]" and TRIGGERS the service, running the local program whose STDOUT is the
# vchan to the service - so the count is EMITTED by the local program (cmd /c echo N), NOT piped
# to stdin (stdin never crosses). dom0's qubes-notify-updates .strip()s the line so CRLF is fine.
#
# CRITICAL quoting: qrexec-client-vm's GetArgument() splits the RAW command line on '|' and does
# NOT strip quotes. Wrapping the whole "domain|...|prog" in double quotes therefore leaks a literal
# quote into the target field -> domain parses as "dom0, a VM that does not exist, and the daemon
# REFUSES it (proven: quoted -> HandleServiceRefused; unquoted -> accepted, flag set). PowerShell
# re-quotes any single arg containing spaces, so pass SPLIT tokens: the first (no spaces) is emitted
# verbatim with literal pipes; '/c' 'echo' $count append space-separated -> field4 = "cmd /c echo N".
function Report-Availability($count){
  # St.count IS the number dom0 is told, set at the ONE place that tells dom0 - so the field the dom0-facing reader prints
  # (wu-update.ps1's summary line) can never differ from the report. From 2026-10-25 (61557095) to 2026-11-01 it did: the scan
  # narrowed St.count to the non-definition offers while this function sent every offer, and dom0 printed "found 7 update(s)"
  # over eight KBs. One writer, three callers (scan, reboot-pending, post-install rescan).
  $script:St.count = [int]$count; Save
  $qr='C:\Program Files\Qubes Tools\bin\qrexec-client-vm.exe'
  if(-not(Test-Path $qr)){ Log 'qrexec-client-vm.exe not found - cannot report to dom0'; return }
  try { & $qr 'dom0|qubes.NotifyUpdates|user|cmd' '/c' 'echo' "$count" 2>&1 | Out-Null
        Log "reported $count update(s) to dom0 qubes.NotifyUpdates (exit $LASTEXITCODE)" }
  catch { Log "qubes.NotifyUpdates report failed: $($_.Exception.Message)" }
}

# ---- WU-LEAF-SELECT-BEGIN   (tools/tests/wu-agentcache-test.ps1 runs this region)
# WHAT THE AGENT STILL NEEDS, read from the offer's OWN metadata. An IUpdate is a BUNDLE TREE: the offered update carries
# BundledUpdates, and those can carry more - measured 2026-10-03 on the German 25H2 template, KB2267602's MpSigStub helper sits at depth 2
# under a "HIDDEN" depth-1 node with no content of its own, so a one-level walk left the bundle 'not downloaded' and the install failed
# (0x80240022 / 0x80246007). Content lives on LEAVES (DownloadContents.Count > 0). A leaf is NEEDED when it is neither installed nor
# downloaded: an up-to-date guest's installed 204 MB "Bases" leaves are not fetched (fetching them cost time and preceded the relay
# refusing every later connection). A content URL is STATIC when it is a plain download.windowsupdate.com file - not an express stream
# (filestreamingservice / tlu.dl.delivery.mp.microsoft.com, which only Delivery Optimization can assemble, and DO refuses routeless,
# 0x80D03805), and no query string. The Defender delta leaf IS static and IS needed: its old exclusion rested on running it ourselves
# (0x80070002 bare and with /q), and the agent runs it through MpSigStub with the update's own command line. Bounded: 256 nodes, and 64
# content items per leaf (a self-contained leaf carries one; an express node carries thousands, which are never enumerated).
function Get-WuNeededLeaves($u){
  # bytes_needed/bytes_all: the LEAF sizes. The offered node's own MaxDownloadSize is not the content this guest fetches: 92637.7 MB against
  # a 4553.8 MB .msu for identity 43f0fc0f r1 (2026-10-31 and again 2026-11-01), 92399.7 against 4424.5 in the capture at
  # tools/tests/wu-update-render-test.ps1 (2026-09-17). Where WUA exposes leaves their sum IS the content (3 of 3 exact, 2026-11-01); where
  # it exposes none (visited=1) there is nothing to sum and Get-WuContentClass says so. Summed HERE because this walk already visits every
  # leaf for the content classification, so the honest
  # number costs no second enumeration and no HEAD per offer. leaves/maxdepth feed the WUSIZE line beside the row dom0 reads - the
  # measurement that proves the sum against the pass's own THROUGHPUT record, per UpdateID+RevisionNumber.
  $acc = [ordered]@{ needed=@(); urls=@(); missing=@(); content=0; express=$false; visited=0; bytes_needed=[long]0; bytes_all=[long]0; leaves=0; maxdepth=0 }
  Add-WuLeaves $u 0 $acc
  return $acc
}
function Add-WuLeaves($n, [int]$depth, $acc){
  if($acc.visited -ge 256){ return }
  $acc.visited++
  $nc=0; try{ $nc=[int]$n.DownloadContents.Count }catch{}
  if($nc -gt 0){
    $acc.content += $nc
    $acc.leaves++; if($depth -gt $acc.maxdepth){ $acc.maxdepth=$depth }
    # A LEAF's MaxDownloadSize IS its content: the max-over-variants ambiguity lives at bundle nodes, which this walk descends past.
    # Counted into bytes_all for every content leaf and into bytes_needed only on the needed arm, so "small because the leaves are
    # already present" can be told from "small because the bundle number was an upper bound".
    $lsz=[long]0; try{ $lsz=[long]$n.MaxDownloadSize }catch{}
    $acc.bytes_all += $lsz
    $installed=$false; $downloaded=$false
    try{ $installed=[bool]$n.IsInstalled }catch{}
    try{ $downloaded=[bool]$n.IsDownloaded }catch{}
    $title=''; try{ $title=[string]$n.Title }catch{}
    $uid=''; try{ $uid=[string]$n.Identity.UpdateID }catch{}
    if(-not $installed -and -not $downloaded){   # GUARD:leafneeded - installed or already-cached leaves are not fetched again
      $acc.bytes_needed += $lsz
      $static=@(); $bad=@()
      if($nc -gt 64){ $bad += "$nc content items (express-shaped)"; $acc.express=$true }
      else {
        foreach($dc in $n.DownloadContents){
          $url=$null; try{ $url=[string]$dc.DownloadUrl }catch{}
          if($url -match 'filestreamingservice|tlu\.dl\.delivery\.mp\.microsoft\.com'){ $acc.express=$true }
          if($url -and $url -match '^https?://[^/]*download\.windowsupdate\.com/' -and $url -notmatch '\?' -and $url -notmatch 'filestreamingservice|tlu\.dl\.delivery\.mp\.microsoft\.com'){ $static += $url }   # GUARD:leafstatic
          else { $bad += $(if($url){ $url } else { '(no url)' }) }
        }
      }
      $acc.needed += [pscustomobject]@{ Update=$n; Uid=$uid; Title=$title; Depth=$depth; Urls=@($static); Bad=@($bad) }
      $acc.urls += $static
      if($bad.Count -gt 0){ $acc.missing += [pscustomobject]@{ Uid=$uid; Title=$title; Depth=$depth; Bad=@($bad) } }
    }
  }
  $nb=0; try{ $nb=[int]$n.BundledUpdates.Count }catch{}
  if($nb -gt 0){ foreach($c in $n.BundledUpdates){ Add-WuLeaves $c ($depth+1) $acc } }   # GUARD:leafrecurse - the whole tree, not one level
}
# ---- WU-LEAF-SELECT-END

# Classify an offered IUpdate from the shape of its needed leaves, without a network round-trip: 'self-contained' when every needed leaf
# has static content (or nothing is needed because the agent's cache already holds it all) - the agent's own installer installs it from
# content we supply (Install-ViaAgentCache); 'express' when a needed leaf is an express stream (not installable routeless, classified
# terminally); 'none' otherwise. urls = the static URLs the install will fetch. No per-package code (Jev, scope 0.74, 2026-10-03).
function Get-WuContentClass($u){
  $lv = Get-WuNeededLeaves $u
  $downloaded=$false; try{ $downloaded=[bool]$u.IsDownloaded }catch{}
  # THE SIZE, AND ITS PROVENANCE. bytes = what the needed leaves add up to, and NOTHING when the walk found no content leaf. The offer's
  # own MaxDownloadSize is never the size. MEASURED 2026-11-01 on win11de-tup - the WUSIZE line at scan against the same pass's fetches:
  # where leaves exist their sum was exactly the bytes moved (83.7, 21.7, 207.9 MB); where WUA exposes the offer as ONE node with no
  # DownloadContents and no BundledUpdates (the cumulative, .NET, a driver) the bundle number was 92637.7 MB for a 4553.8 MB .msu (20.3x),
  # 184.6 for 92.3 (2.0x) and 28.6 for 28.6 (1.0x): sometimes right, never knowable from the offer. Those offers are catalog-delivered and
  # their size is first known when Fetch-Msu opens the content and reads Content-Length - which writes it into the row (size_src=content).
  # Until then the row says size_mb=null, size_src=unresolved, and the bundle number travels under its own name, bundle_max_mb.
  $bytes=$null; $src='unresolved'
  if($lv.content -gt 0){ $bytes=[long]$lv.bytes_needed; $src='leaves' }
  $bmax=[long]0; try{ $bmax=[long]$u.MaxDownloadSize }catch{}
  $sz=@{ bytes=$bytes; src=$src; bundle_max=$bmax; leaf_needed=[long]$lv.bytes_needed; leaf_all=[long]$lv.bytes_all; leaves_needed=$lv.needed.Count; leaves_all=$lv.leaves; visited=$lv.visited; depth=$lv.maxdepth }
  # WUSIZE - the measurement the size rule ships with, logged HERE and not in Get-Available: that function is run in isolation by
  # tools/tests/wu-available-test.ps1 (this one stubbed, no Log) and had no Log call until the first cut put one there - measured
  # 2026-11-01: every leg threw "The term 'Log' is not recognized". ADR-updater 12.4 forbids a standalone WU probe (the pass owns the
  # only relay), so the numbers come from the pass: one line per offer at scan, keyed by UpdateID+RevisionNumber (section 6) - no title,
  # no KB. bundle_max/bundle_min are the offer's own numbers, leaf_* the walk's; the pass's THROUGHPUT and WUSIZE-RESOLVED are the other side.
  $wuid=''; $wrev=''; try{ $wuid=[string]$u.Identity.UpdateID; $wrev=[int]$u.Identity.RevisionNumber }catch{}
  $bmin=[long]0; try{ $bmin=[long]$u.MinDownloadSize }catch{}
  Log ("WUSIZE uid=$wuid rev=$wrev bundle_max_mb=" + [math]::Round($bmax/1MB,1) + " bundle_min_mb=" + [math]::Round($bmin/1MB,1) + " leaf_needed_mb=" + [math]::Round($lv.bytes_needed/1MB,1) + " leaf_all_mb=" + [math]::Round($lv.bytes_all/1MB,1) + " leaves_needed=$($lv.needed.Count) leaves_all=$($lv.leaves) visited=$($lv.visited) depth=$($lv.maxdepth) src=$src")
  if($lv.needed.Count -gt 0 -and $lv.missing.Count -eq 0){ return @{ class='self-contained'; urls=@($lv.urls | Sort-Object -Unique); size=$sz } }
  if($lv.needed.Count -eq 0 -and $lv.content -gt 0 -and $downloaded){ return @{ class='self-contained'; urls=@(); size=$sz } }
  if($lv.express){ return @{ class='express'; urls=@(); size=$sz } }
  return @{ class='none'; urls=@(); size=$sz }
}

# ---- WU-SECPLATFORM-READ-BEGIN   (tools/tests/wu-secplatform-test.ps1 runs this region)
# THE WINDOWS SECURITY PLATFORM, as its own installer (securityhealthsetup.exe, KB5007651) records it. Measured 2026-10-03 on the German
# 25H2 template before and after a no-argument run, as SYSTEM: HKLM\SOFTWARE\Microsoft\Windows Security Health\Platform\CoreLocation
# names the platform folder the Security Health service runs - '\\?\C:\Windows\System32' is the INBOX platform, '\\?\C:\Windows\System32\
# SecurityHealth\10.0.29628.1000-0' an installed update; HKLM\...\Windows Security Health\Updates\wu is the version the installer recorded
# (the Updates key is ABSENT until the first install); SecurityHealthHost.exe in CoreLocation carries the platform's FileVersion, which is
# the only version the inbox platform has (10.0.26100.9278 there). `ver` is the folder's version, `cmp` the version an offer is compared
# with (the folder's, else the inbox host's), `text` the one-line state for the log. `readable` is false when CoreLocation cannot be
# read: the probe then did NOT run (ADR-updater section 3) and no verdict is drawn from it.
function Get-SecurityPlatformState {
  $s = [ordered]@{ readable=$false; loc=''; ver=$null; wu=$null; host=$null; cmp=$null; text='' }
  try {
    $pl = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows Security Health\Platform' -EA SilentlyContinue
    if($pl -and $pl.CoreLocation){ $s.loc = [string]$pl.CoreLocation; $s.readable = $true }
  } catch {}
  if($s.loc){
    if(($s.loc -replace '^.*[\\/]','') -match '^(\d+\.\d+\.\d+\.\d+)'){ $s.ver = $Matches[1] }
    try {
      $h = Get-Item -LiteralPath (($s.loc -replace '^\\\\\?\\','').TrimEnd('\') + '\SecurityHealthHost.exe') -EA SilentlyContinue
      if($h -and ([string]$h.VersionInfo.FileVersion) -match '(\d+\.\d+\.\d+\.\d+)'){ $s.host = $Matches[1] }
    } catch {}
  }
  try {
    $up = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows Security Health\Updates' -EA SilentlyContinue
    if($up -and $up.wu){ $s.wu = [string]$up.wu }
  } catch {}
  $s.cmp = if($s.ver){ $s.ver } else { $s.host }
  if($s.readable){
    $s.text = "$(if($s.ver){ $s.ver } else { 'inbox' }) (CoreLocation $($s.loc); host $(if($s.host){ $s.host } else { 'unreadable' }); Updates\wu $(if($s.wu){ $s.wu } else { 'absent' }))"
  } else { $s.text = 'CoreLocation unreadable' }
  return $s
}
# ---- WU-SECPLATFORM-READ-END

# ---- WU-DEFINITION-CLASS-BEGIN   (tools/tests/wu-definition-class-test.ps1 runs this region)
# DEFINITION UPDATES ARE IDENTIFIED STRUCTURALLY, NEVER BY TITLE. The field runs a German edition and
# ADR section 6 forbids title text as an identity - "Definition Update for Microsoft Defender
# Antivirus" is "Definitionsupdate fuer Microsoft Defender Antivirus" there, and a substring match
# would silently stop excluding anything the day a locale or a product name changed.
#
# WU classifies every offer, and "Definition Updates" is a FIXED classification GUID,
# e0789628-ce08-4437-be74-2495b842f43b, exposed in Categories as a category whose Type is
# 'UpdateClassification'. It is the same field WU itself groups by, it is locale-independent, and it
# is structured data straight off the COM object.
#
# IT SEPARATES THE TWO DEFENDER THINGS, which neither a KB nor a title can: the daily signature
# definitions carry this classification, while the Defender PLATFORM / antimalware engine updates are
# classified as ordinary Updates. The engine updates are real servicing work and must keep counting.
#
# UNREADABLE CATEGORIES MEAN "NOT A DEFINITION", deliberately: the failure direction is that an offer
# still counts. An exclusion that swallows an update it could not classify would hide real servicing
# work, which is the defect this project keeps paying for.
#
# THE GUID IS DISCLOSED, NOT ASSERTED. The target value above has never been read off a live
# IUpdate: the probe that proved this MECHANISM (German 25H2, as SYSTEM) ran against an offline
# metadata cache that had no definition pending, so it returned Security Updates and Drivers and
# could not answer the one question. Rather than leave the constant unfalsifiable, the extractor
# returns the classifications it SAW, every offer row carries them, and the exclusion names them in
# the log - so the next real pass that is offered KB2267602 settles it as DATA, in evidence dom0
# already collects, instead of by anyone re-reading this comment. See WUDEFINITIONGUIDUNCONFIRMED.
$script:WU_DEFINITION_CLASS = 'e0789628-ce08-4437-be74-2495b842f43b'
# THE SIGNATURE OFFERS, BY KB. Used only to WATCH the classification, never to classify: KB is an
# identifier off the COM object (KBArticleIDs), not title text, so ADR section 6 stands. The
# platform/engine update is deliberately NOT here - KB4052623 is ordinary servicing and must keep
# counting, and a watcher that fired on it would cry wolf every month until it was ignored.
$script:WU_SIGNATURE_KBS = @('KB2267602', 'KB2310138')
function Get-WuClassifications($u){
  $ids=@()
  try {
    foreach($c in $u.Categories){
      $ty=''; try { $ty=[string]$c.Type } catch {}
      if($ty -ne 'UpdateClassification'){ continue }
      $id=''; try { $id=[string]$c.CategoryID } catch {}
      $id = ($id -replace '[{}]','').Trim().ToLowerInvariant()
      if($id){ $ids += $id }
    }
  } catch {}
  # PLAIN return, and @() at EVERY call site. `return ,$ids` nests it - the comma operator wraps
  # the array in a one-element array, so @(Get-WuClassifications $u) saw a single System.Object[]
  # and an offer whose categories threw disclosed one bogus classification instead of none. Caught
  # by the two checks added for exactly this field, before it ever reached a guest.
  return $ids
}
function Test-WuDefinitionUpdate($u){
  foreach($id in @(Get-WuClassifications $u)){
    if($id -eq $script:WU_DEFINITION_CLASS){ return $true }
  }
  return $false
}
# ---- WU-DEFINITION-CLASS-END

function Get-Available {
  $s=New-Object -ComObject Microsoft.Update.Session
  $se=$s.CreateUpdateSearcher(); $se.ServerSelection=2; $se.Online=$true
  # ---- WU-AVAILABLE-INIT-BEGIN   (tools/tests/wu-available-test.ps1 runs this function)
  $r=$se.Search("IsInstalled=0 and IsHidden=0")   # GUARD:onesearch - ONE online search per scan
  # $out MUST start as an empty ARRAY: `$null += [ordered]@{...}` yields a DICTIONARY, and the next += then merges two dictionaries
  # and throws on the duplicate key "kb" - which killed every scan offering two or more updates (rz38, 2026-10-03).
  $out=@()   # GUARD:outarray
  # ---- WU-AVAILABLE-INIT-END
  # THE LIVE IUpdate OBJECTS, kept for the install phase of this pass: Install-ViaAgentCache hands the agent's installer the very object
  # the search returned (CopyToCache is a method of it). Keyed by KB and by UpdateID (no-KB offers); the session and the result stay
  # referenced with them so the COM objects remain valid. Rebuilt by every search, so a fresh search is a fresh map.
  $script:WuSession = $s; $script:WuSearchResult = $r; $script:LiveUpdates = @{}
  foreach($u in $r.Updates){
    $kb=@($u.KBArticleIDs)|Select-Object -First 1; $kb= if($kb){"KB$kb"}else{'(no KB)'}
    $cls = Get-WuContentClass $u    # content class + any static URLs, computed while the IUpdate is live
    # THE OFFER'S OWN IDENTITY. Without it a scan cannot tell "the same offer the last pass already
    # resolved" from "a genuinely new one", and so it must count both - which is why dom0 went from
    # empty back to 1 thirty seconds after a pass installed a Defender signature AND PROVED it by
    # effect (win11de-fresh, 2026-09-20). UpdateID+RevisionNumber is structured data straight off
    # the COM object: no title parsing, no locale dependence (ADR section 6).
    $uid=$null; $rev=$null
    try { $uid=[string]$u.Identity.UpdateID; $rev=[int]$u.Identity.RevisionNumber } catch {}
    if($kb -ne '(no KB)' -and -not $script:LiveUpdates.ContainsKey($kb)){ $script:LiveUpdates[$kb] = $u }
    if($uid){ $script:LiveUpdates[$uid] = $u }
    $out += [ordered]@{ kb=$kb; title="$($u.Title)"; size_mb=$(if($null -ne $cls.size.bytes){ [math]::Round($cls.size.bytes/1MB,1) }else{ $null }); size_src=$cls.size.src; bundle_max_mb=[math]::Round($cls.size.bundle_max/1MB,1); downloaded=[bool]$u.IsDownloaded; content_class=$cls.class; direct_urls=@($cls.urls); uid=$uid; rev=$rev; classifications=@(Get-WuClassifications $u); is_definition=(Test-WuDefinitionUpdate $u) }
  }
  return ,$out
}

# WU-NATIVE INSTALL - RETAINED AS A FALLBACK ONLY. Do not restore it as the default.
#
# CORRECTED 2026-08-14. This block used to say the catalog+DISM path "cannot service every image",
# citing KB5121003 being staged (rc=3010) and then ROLLED BACK at boot with 0x80070490 /
# CBS_E_INVALID_PACKAGE, and calling kb5043080 its "checkpoint prerequisite". That diagnosis was
# WRONG and the conclusion drawn from it was backwards. kb5043080 is not a prerequisite: it is a
# SUPERSEDED 2024-09 cumulative that the catalog bundles with the download, DISM rejects as not
# applicable (rc=552), and whose rejection poisons the CBS transaction the real cumulative then
# rides into. Dropping it BEFORE download makes the same image, the same package and the same DISM
# path install cleanly: verified 26100.8875 -> 26100.9168 with KB5043080 never present.
#
# So the catalog path does decide correctly which package an image needs - it just must not hand
# CBS the ones it does not.
#
# The searcher already runs online through our proxy (Get-Available), so the same session's
# downloader and installer can too. Delivery Optimization is forced into simple mode first,
# because DO does its own peer/CDN transport and does not reliably honour the WinHTTP proxy that
# Ensure-Proxy sets - and a qube has no other way out.
# Put Delivery Optimization back exactly as it was. MUST be reachable from every exit of
# Install-ViaWU: the first version restored it just before building the result rows, and the
# "WU: nothing to install" early return skipped it - measured, DODownloadMode=99 was still set
# on the guest afterwards. A policy this code sets for its own convenience must not outlive it.
function Restore-DoPolicy {
  if (-not $script:DoRestore) { return }
  try {
    if ($script:DoRestore.Had) { SetV $script:DoRestore.Key 'DODownloadMode' $script:DoRestore.Value 'DWord' }
    else { Remove-ItemProperty -LiteralPath $script:DoRestore.Key -Name 'DODownloadMode' -Force -EA SilentlyContinue }
    Log 'Delivery Optimization: restored'
  } catch { Log "could not restore DODownloadMode: $($_.Exception.Message)" }
  $script:DoRestore = $null
}

# The update's OWN identity, read off the live COM object: UpdateID plus RevisionNumber, with rev an
# [int] so a stamped result row and a scan offer carry the SAME JSON type to dom0 (ADR-updater
# section 6: structured data, never a parsed string). An object that refuses the properties yields an
# empty uid, which every caller reads as "no identity" rather than inventing one.
#
# WHY THE THREE INLINE COPIES STAY INLINE, measured 2026-11-08 rather than left as an untidied
# duplicate: they are the same READ but not the same empty value, and both differences are
# load-bearing. :1030 starts $wrev at '' and prints it in the sweep-parsed `WUSIZE uid= rev=`
# line, so routing it here turns a failed read from `rev=` into `rev=0` and moves text a parser
# keys on. :1152 starts uid/rev at $null and serialises them into $script:St.available, i.e. into
# JSON dom0 reads, where '' and 0 are not the same as null and a rev of 0 could collide with a
# genuine revision 0. :984 wants the uid alone off a different object. Converting them is a
# separate change with its own measurement, not a tidy-up - do not fold them in silently.
function Get-WuIdentity($u) {
  $uid = ''; $rev = 0
  try { $uid = [string]$u.Identity.UpdateID; $rev = [int]$u.Identity.RevisionNumber } catch { }
  return @{ uid = $uid; rev = $rev }
}
function Install-ViaWU {
  # $OnlyKbs limits the pass to specific KBs. Used as the FALLBACK for updates the Update
  # Catalog cannot serve: Defender definitions and the Malicious Software Removal Tool are not
  # .msu packages at all, so Resolve-Catalog will never find them, and without this they are
  # reported failed on every pass forever - dom0 keeps showing updates that can never clear.
  # $OnlyUids names offers by the update's OWN identity (Identity.UpdateID, with or without
  # ":rev" - the two forms -OnlyUid accepts at :3141). It exists because $OnlyKbs cannot name an
  # offer that carries no KB at all - every vendor driver is one - and those are exactly the
  # offers WU-NOKB has to hand over here (ADR-updater section 2, the point-3 mechanism).
  param([string[]]$OnlyKbs = @(), [bool]$TunePolicies = $true, [string[]]$OnlyUids = @())
  # Delivery Optimization: no peering (99 = simple), and no background throttling. A qube's only
  # path out is the updates proxy, which is up ONLY during this pass, so there is nothing to be
  # polite to - the usual reason WU downloads slowly in the background does not apply here.
  #
  # These are MACHINE-WIDE POLICY writes and they persist. That was an acceptable price when
  # this function was an opt-in path for multi-gigabyte cumulatives. It is NOT acceptable on the
  # non-catalog fallback, which fires on almost every pass - Defender definitions are published
  # several times a day - and would leave every guest's Delivery Optimization and BITS policy
  # rewritten as a side effect of routine definition updates. The fallback passes $false: a few
  # megabytes of definitions do not need the transport tuned.
  # $TunePolicies=$false was a blunt answer to "do not leave machine policy rewritten": it also
  # gave up DODownloadMode=99, and Delivery Optimization does NOT reliably honour the WinHTTP
  # proxy in its default mode - which is the whole reason this block exists. A qube has no other
  # way out, so an unset DO can simply fail to download. Set the policy for the duration of the
  # pass and PUT IT BACK afterwards: reliability without a permanent change.
  $script:DoRestore = $null
  if (-not $TunePolicies) {
    $DO = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization'
    $prev = $null
    try { $prev = (Get-ItemProperty -LiteralPath $DO -Name DODownloadMode -EA Stop).DODownloadMode } catch { }
    $script:DoRestore = @{ Key = $DO; Had = ($null -ne $prev); Value = $prev }
    SetV $DO 'DODownloadMode' 99 'DWord'
    Log 'Delivery Optimization: DODownloadMode=99 for THIS pass only (restored at the end)'
  }
  if ($TunePolicies) {
    $DO = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization'
    SetV $DO 'DODownloadMode'                      99 'DWord'
    SetV $DO 'DOPercentageMaxBackgroundBandwidth' 100 'DWord'
    SetV $DO 'DOPercentageMaxForegroundBandwidth' 100 'DWord'
    SetV $DO 'DOMaxBackgroundDownloadBandwidth'     0 'DWord'   # 0 = unlimited
    SetV 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\BITS' 'EnableBITSMaxBandwidth' 0 'DWord'
    Log 'Delivery Optimization: simple mode, no background throttle (proxy is up only for this pass)'
  }

  try {
    $session = New-Object -ComObject Microsoft.Update.Session
    $searcher = $session.CreateUpdateSearcher(); $searcher.ServerSelection = 2; $searcher.Online = $true
    $script:St.phase='scan'; Save
    $found = $searcher.Search("IsInstalled=0 and IsHidden=0")
    if ($found.Updates.Count -eq 0) { Log 'WU: nothing to install'; return @() }

    $coll = New-Object -ComObject Microsoft.Update.UpdateColl
    foreach ($u in $found.Updates) {
      $wid = Get-WuIdentity $u
      if ($OnlyUids.Count -gt 0) {
        # Compared as FIELDS, never as a parsed string (ADR-updater section 6). Both narrowings
        # apply in sequence, the way -OnlyUid and -OnlyKb compose at the top of the script.
        if (-not (@($OnlyUids | Where-Object { $_ -eq $wid.uid -or $_ -eq "$($wid.uid):$($wid.rev)" }).Count -gt 0)) { continue }
      }
      if ($OnlyKbs.Count -gt 0) {
        $kbs = @($u.KBArticleIDs) | ForEach-Object { "KB$_" }
        if (-not (@($kbs | Where-Object { $OnlyKbs -contains $_ }).Count -gt 0)) { continue }
      }
      if (-not $u.EulaAccepted) { try { $u.AcceptEula() } catch {} }
      [void]$coll.Add($u)
      Log ("WU: selected " + $u.Title)
    }
    if ($coll.Count -eq 0) { Log 'WU: nothing matched the requested KBs'; return @() }
    $script:St.wu_selected = $coll.Count; Save   # the Windows Update installer's selection - not what dom0 is told (St.count is set where dom0 is told)

    $script:St.phase='download'; Save
    $downloader = $session.CreateUpdateDownloader(); $downloader.Updates = $coll
    # dpHigh: WU downloads at background priority by default and paces itself accordingly -
    # measured bursts every ~3.5 s with idle gaps, while each connection sustained ~840 KB/s.
    try { $downloader.Priority = 3 } catch { Log '  (downloader does not accept Priority)' }
    Log "WU: downloading $($coll.Count) update(s) through the proxy"
    $dres = $downloader.Download()
    Log "WU: download ResultCode=$($dres.ResultCode) HResult=$($dres.HResult)"

    # Install only what actually downloaded; asking WU to install a missing payload just fails.
    $ready = New-Object -ComObject Microsoft.Update.UpdateColl
    foreach ($u in $coll) { if ($u.IsDownloaded) { [void]$ready.Add($u) } }
    if ($ready.Count -eq 0) { Log 'WU: nothing downloaded - not installing'; return @() }

    $script:St.phase='install'; Save
    $installer = $session.CreateUpdateInstaller(); $installer.Updates = $ready
    Log "WU: installing $($ready.Count) update(s)"
    $ires = $installer.Install()
    Log "WU: install ResultCode=$($ires.ResultCode) RebootRequired=$($ires.RebootRequired)"
    if ($ires.RebootRequired) { $script:St.reboot_needed = $true }

    # ResultCode: 2 = succeeded, 3 = succeeded with errors, 4 = failed, 5 = aborted.
    $rows = @()
    for ($i = 0; $i -lt $ready.Count; $i++) {
      $u = $ready.Item($i)
      $r = $ires.GetUpdateResult($i)
      $kb = @($u.KBArticleIDs) | Select-Object -First 1
      # THE ROW STATES ITS OUTCOME (GUARD:stagedpending): a succeeded update whose own RebootRequired is set is STAGED, not installed -
      # it completes at the restart. Until 2026-11-02 these rows carried only ok, and every reader had to guess from the pass's flag.
      $ok = ($r.ResultCode -in @(2, 3))
      # THE ROW CARRIES ITS OWN IDENTITY (ADR-updater section 2, the point-3 mechanism decided
      # 2026-11-08). Every OTHER writer on this fallback path emits ok=$false, so these are the
      # only rows here that Test-RowInstalled can ever pass - which is why stamping at this one
      # place is enough to let Get-InstalledIdentities stop joining back on kb/title.
      $rid = Get-WuIdentity $u
      $row = [ordered]@{ kb = $(if ($kb) { "KB$kb" } else { '(no KB)' }); ok = $ok }
      if ($rid.uid) { $row['uid'] = $rid.uid; $row['rev'] = $rid.rev }
      if ($ok) { $row['state'] = $(if ($r.RebootRequired) { 'staged' } else { 'installed' }) }
      # THE ROW ADMITS THAT NOTHING CHECKED (ADR-updater 3 and 12.3, fourth row). This path has no
      # effect probe at all - the verdict IS the WUA installer's ResultCode - so it says probe=$null
      # and verified_by_effect=$false instead of leaving a reader to infer a measured install from
      # ok=$true. Same two field names, types and meaning as Install-ViaAgentCache's row and
      # Get-MsuKbVerdict's (61eae363); with this the exclusion audit and the evidence builder see all
      # THREE install routes instead of two, which is what made the first two fixes worth having.
      $row['verified_by_effect'] = $false
      $row['probe'] = $null
      # AND SUCCEEDED-WITH-ERRORS NOW SAYS SO. ResultCode 3 is orcSucceededWithErrors and still counts
      # as ok here (deliberately unchanged - it is Windows' own verdict and nothing of ours can second
      # it), but it is not a clean install, and `reason` is the row-level key every reader takes -
      # dom0's Get-RowWhy and tools/wu-exclusion-evidence.py. The one outcome on this route that most
      # deserves a sentence carried none, so a partly-failed install read exactly like a clean one.
      if ($r.ResultCode -eq 3) {
        $row['reason'] = ('Windows Update reported SUCCEEDED WITH ERRORS (ResultCode 3, HResult 0x{0:X8}) - counted installed on that verdict, and nothing on this route probed the effect' -f $r.HResult)
      }
      $row['files'] = @([ordered]@{ file = "$($u.Title)"; rc = $r.ResultCode; hr = $r.HResult })
      $rows += $row
      Log ("WU:   $($u.Title) -> ResultCode=$($r.ResultCode) HResult=$($r.HResult) RebootRequired=$($r.RebootRequired)")
    }
    return ,$rows
  } finally { Restore-DoPolicy }

}

# KB -> standalone .msu URLs from the Update Catalog (over the proxy), for THIS guest's
# architecture and Windows version.
#
# THE DECISION IS MADE ON THE FILENAME, NOT ON THE TITLE. Rewritten 2026-08-14 because the old
# version chose a row by matching ENGLISH words in its title, and the catalog's response language
# is not ours to choose: asking for fr-FR returned an ITALIAN title, and the same KB on the same
# guest came back German at 09:54 and English at 10:21. A real user runs a German edition. So the
# title is now used only to NARROW and RANK candidates by tokens nobody translates - the arch
# ("x64"/"arm64") and the build/version number - while the actual accept/reject test is run against
# the .msu filename the catalog hands back, which is language-invariant by construction.
#
# Two ambiguities the old title matching could not survive, both real:
#   * DisplayVersion alone does not identify a product: Windows 10 AND Windows 11 both shipped a
#     "22H2". CurrentBuild does (19045 vs 22621), so the BUILD is ranked above the version now.
#   * Build alone does not separate client from server: Windows Server 2025 and Windows 11 24H2
#     are BOTH build 26100.
#
# CORRECTED 2026-08-14, measured: the filename family does NOT separate client from server.
# Server packages are ALSO named windows11.0-* - "Cumulative Update for Microsoft server operating
# system version 24H2 ... (KB5120233)" ships windows11.0-kb5120233-x64_9344....msu. An earlier
# version of this comment claimed Server 2025 used windows10.0-*; that was an assumption and it was
# wrong. What the family check DOES buy is separating Windows 10 packages from Windows 11 ones.
#
# The real client/server separator is the KB NUMBER, which is product-specific: the 24H2 cumulative
# is KB5121003 for client and KB5120233 for server; the .NET one is KB5120710 client, KB5120708
# server. So a KB-specific search returns product-specific rows - measured, KB5121003 returns four
# rows, all client (24H2/25H2 x x64/arm64), no server row at all. The English `Server` keyword was
# never what kept server packages out.
#
# Dynamic Updates cannot reach us either, for two measured reasons: they ship .cab, not .msu (the
# `\.msu` filter below drops them outright), and they carry their OWN KB numbers - Safe OS Dynamic
# Update is KB5121002 and Setup Dynamic Update is KB5106084, neither of which is KB5121003.
#
# Nothing here is pinned to a Windows version: arch, build, version and product family are all read
# from the running guest. Hardcoding "x64 + 24H2|26100" once made KB5120708 unresolvable on 25H2.
# ---- WU-DRIVER-TITLE-BEGIN
# RESOLVE A KB-LESS OFFER BY ITS TITLE, AND CHOOSE BY WHAT THE PACKAGE DECLARES.
#
# Some offers carry no KB and no self-contained URL - measured on GWeck's environment:
# "Microsoft Corporation AudioProcessingObject Driver Update (1.0.4.7057)", content_class=none,
# direct_urls=[]. Resolve-Catalog is keyed on the KB, so it has no handle on them, and the row used
# to say so and stop. But the catalog DOES hold the item, under its title, and serves a real .cab.
#
# THE TRAP, and the reason this cannot be done on title text alone: that offer matches TWO catalog
# entries with byte-identical titles AND identical product strings. Title, order and size cannot
# tell them apart - one package declares `[Manufacturer] ... NTARM64` and the other `NTamd64`, and
# that is the only difference. So each candidate is DOWNLOADED and its INF read, and the choice is
# made on the architecture THE PACKAGE ITSELF DECLARES. Judge the artefact, never the label:
# the same rule as verify-by-effect, and the reason title language (nondeterministic here) is
# irrelevant to the decision.
function Get-PackageArch($cab){
  $d = Join-Path $WorkDir ('drvinsp-' + [IO.Path]::GetFileNameWithoutExtension($cab))
  Remove-Item $d -Recurse -Force -EA SilentlyContinue
  New-Item -ItemType Directory -Force $d | Out-Null
  & expand.exe "$cab" -F:*.inf "$d" 2>&1 | Out-Null
  foreach($inf in @(Get-ChildItem (Join-Path $d '*.inf') -EA SilentlyContinue)){
    $txt = Get-Content -Raw -LiteralPath $inf.FullName -EA SilentlyContinue
    if(-not $txt){ continue }
    $m = [regex]::Match($txt, '(?ms)^\[Manufacturer\](.*?)^\[')
    $blob = if($m.Success){ $m.Groups[1].Value } else { $txt }
    $a = @([regex]::Matches($blob, 'NT(amd64|arm64|x86)', 'IgnoreCase') | ForEach-Object { $_.Groups[1].Value.ToLower() } | Sort-Object -Unique)
    if($a.Count){ return ($a -join ',') }
  }
  return 'unknown'
}

function Resolve-DriverByTitle($title){
  # ONE ASK PER TITLE PER PASS (the Resolve-Catalog rule): the scan's route proof asks first and the install loop's WU-NOKB reuses the
  # answer. UNRESOLVED is never memoised - the next ask asks again. Within a pass only: nothing is remembered across passes.
  if (-not $script:TitleAsked) { $script:TitleAsked = @{} }
  if ($script:TitleAsked.ContainsKey($title)) { return $script:TitleAsked[$title] }
  $want = ($env:PROCESSOR_ARCHITECTURE).ToLower()          # AMD64 -> amd64, ARM64 -> arm64
  $q = [uri]::EscapeDataString(($title -replace '\s*\(Version [^)]*\)\s*$','').Trim())
  $hdr = @{}; if ($AcceptLanguage) { $hdr['Accept-Language'] = $AcceptLanguage }
  # AN UNANSWERED TITLE SEARCH IS UNRESOLVED, never "no entry" (ADR-updater section 2 point 5): a throw (run 9's refused Catalog
  # ended the whole pass here until 2026-11-02) or a body that is not the Catalog's results page - the GUARD:catalogvalid test of
  # WU-CATALOG-VALID - returns @{ unresolved }, and WU-NOKB leaves the offer outstanding.
  try { $r = Invoke-WebRequest "https://www.catalog.update.microsoft.com/Search.aspx?q=$q" -Proxy $Proxy -UseBasicParsing -TimeoutSec 60 -Headers $hdr }
  catch { Log ("  title resolve: catalog search threw (" + $_.Exception.Message + ") - UNRESOLVED, not 'no entry'"); return @{ unresolved = $true } }
  $body = [string]$r.Content
  if ([string]::IsNullOrWhiteSpace($body) -or ($body -notmatch 'ctl00_catalogBody_(updateMatches|noResult)')) {
    Log ("  title resolve: catalog response is not a results page (" + $body.Length + " bytes) - UNRESOLVED, not 'no entry'"); return @{ unresolved = $true }
  }
  $rows = [regex]::Matches($r.Content, "id='([0-9a-f-]{36})_link'[^>]*>\s*(.*?)\s*</a>", 'Singleline')
  $cands = @()
  foreach($m in $rows){
    $t = ($m.Groups[2].Value -replace '\s+',' ').Trim()
    if($t -eq $title.Trim()){ $cands += $m.Groups[1].Value }
  }
  if($cands.Count -eq 0){ Log "  title resolve: no catalog entry titled exactly '$title'"; $script:TitleAsked[$title] = $null; return $null }
  Log "  title resolve: $($cands.Count) candidate(s); choosing by the architecture each PACKAGE declares (want $want)"
  $uninspected = 0   # GUARD:dialogunanswered on this route too - a candidate whose dialog or package never arrived, or whose dialog lists no .cab package, was not inspected
  foreach($uid in $cands){
    $json = '[{"size":0,"languages":"","uidInfo":"' + $uid + '","updateID":"' + $uid + '"}]'
    try { $dl = Invoke-WebRequest 'https://www.catalog.update.microsoft.com/DownloadDialog.aspx' -Method POST -Body @{updateIDs=$json} -Proxy $Proxy -UseBasicParsing -TimeoutSec 60 -Headers $hdr }
    catch { $uninspected++; Log ("    $uid : download dialog failed (" + $_.Exception.Message + ") - not inspected"); continue }
    if ([string]::IsNullOrWhiteSpace([string]$dl.Content)) { $uninspected++; Log "    $uid : download dialog returned an empty body - not inspected"; continue }
    $url = @([regex]::Matches($dl.Content, "https?://[^'`"]+\.cab") | ForEach-Object { $_.Value } | Sort-Object -Unique)[0]
    if(-not $url){ $uninspected++; Log "    $uid : the download dialog lists no .cab package - not inspected"; continue }
    $f = Join-Path $WorkDir ([IO.Path]::GetFileName(($url -split '\?')[0]))
    if(-not (Test-Path $f)){ Fetch-Msu $url $f | Out-Null }
    if(-not (Test-Path $f)){ $uninspected++; Log "    $uid : package fetch failed - not inspected"; continue }
    $arch = Get-PackageArch $f
    Log "    $uid arch=$arch"
    if($arch -split ',' -contains $want){ $script:TitleAsked[$title] = @{ uid=$uid; url=$url; file=$f; arch=$arch }; return $script:TitleAsked[$title] }
  }
  # The skip row this would lead to tells dom0 "each identically-titled candidate is inspected" - true only if each one was.
  if($uninspected -gt 0){
    Log "  title resolve: $uninspected of $($cands.Count) candidate(s) not inspected - UNRESOLVED, not 'no candidate declares $want'"
    return @{ unresolved = $true }
  }
  Log "  title resolve: no candidate declares $want - this offer is not installable on this architecture"
  $script:TitleAsked[$title] = $null
  return $null
}

# INSTALL a driver package and VERIFY BY EFFECT. pnputil's own exit code is not the answer: the
# question is whether the driver is in the store afterwards, which /enum-drivers states.
function Install-DriverCab($cab, $label){
  $d = Join-Path $WorkDir ('drv-' + [IO.Path]::GetFileNameWithoutExtension($cab))
  Remove-Item $d -Recurse -Force -EA SilentlyContinue
  New-Item -ItemType Directory -Force $d | Out-Null
  & expand.exe "$cab" -F:* "$d" 2>&1 | Out-Null
  $inf = @(Get-ChildItem (Join-Path $d '*.inf') -EA SilentlyContinue | Select-Object -First 1)
  if($inf.Count -eq 0){ return [ordered]@{ file=[IO.Path]::GetFileName($cab); ok=$false; reason='no .inf inside the package' } }
  $name = $inf[0].Name
  $before = (& pnputil.exe /enum-drivers 2>&1 | Out-String)
  $p = Start-Process pnputil.exe -ArgumentList @('/add-driver', $inf[0].FullName, '/install') -Wait -PassThru -WindowStyle Hidden
  $after = (& pnputil.exe /enum-drivers 2>&1 | Out-String)
  # EFFECT: the original INF name appears in the driver store now and did not before, or it was
  # already there (a re-offer of something installed). rc alone decides nothing.
  $was = $before -match [regex]::Escape($name)
  $now = $after  -match [regex]::Escape($name)
  $row = [ordered]@{ file=$name; rc=$p.ExitCode; ok=$now; verified_by_effect=$now
                     probe='pnputil-enum'; severity=$null; info_reason=$null }
  if($now -and -not $was){ Log "  $label : driver added to the store (pnputil rc=$($p.ExitCode), verified by /enum-drivers)" }
  elseif($now -and $was){ $row.severity=$null; Log "  $label : already present in the driver store - nothing to do" }
  else { Log "  $label : pnputil rc=$($p.ExitCode) but $name is NOT in the driver store - did NOT install" }
  return $row
}
# ---- WU-DRIVER-TITLE-END

# ONE ASK PER KB PER PASS. The route proof (WU-ROUTE-PROOF, below) asks the Catalog at scan for every offer it might leave out
# of dom0's count, and the install loop asks again for every KB. The answer cannot change inside one pass, so the second ask
# returns the first one. $script:CatalogAsked[kb] = @{ urls; valid; rows; ranked } - valid is GUARD:catalogvalid's verdict for THAT kb, kept
# per KB because $script:CatalogUnresolved is only ever the LAST ask's. Memoised within a pass ONLY: the next pass asks again,
# which is what lets a Catalog publication, a new route or an entitlement be seen the moment it exists (nothing remembered).
# A THROW IS UNRESOLVED, caught HERE (no proxy, a refused or failed Catalog request), and it is NOT memoised - it is not an
# answer: the next ask in this pass (the install loop after the scan's route proof) asks again, so a one-off timeout at scan costs
# nothing, and an unanswered KB never proves 'no package' (Test-CatalogProvedNoPackage needs a memoised valid page). Meanwhile the
# install loop's UNRESOLVED gates leave the KB outstanding (ADR-updater section 2 point 5: "An UNRESOLVED Catalog answer is not
# verification - the offer stays counted").
# Until 2026-11-02 only the route proof caught it: run 9 on win10-tup (Catalog 403 through the proxy) ended the pass at the
# resolve step with phase=error, and dom0's user read "update failed: ... (403) Forbidden." for offers it could not have installed.
function Resolve-Catalog($kb){
  if (-not $script:CatalogAsked) { $script:CatalogAsked = @{} }
  if ($script:CatalogAsked.ContainsKey($kb)) {
    $m = $script:CatalogAsked[$kb]
    $script:CatalogUnresolved = -not $m.valid
    return @($m.urls)
  }
  try { $urls = @(Resolve-CatalogUncached $kb) }
  catch {
    $script:CatalogUnresolved = $true; $script:CatalogRows = $null; $script:CatalogRanked = $null
    Log ("  " + $kb + " : catalog search threw (" + $_.Exception.Message + ") - UNRESOLVED, not 'no package'")
    return @()
  }
  $script:CatalogAsked[$kb] = @{ urls = @($urls); valid = (-not $script:CatalogUnresolved); rows = $script:CatalogRows; ranked = $script:CatalogRanked }
  return @($urls)
}
# TRUE only when THIS pass asked the Catalog for the KB, got a valid results page, and resolved no package for this guest.
# The one fact that may turn 'no .msu' into an informational row; an unresolved page or an unasked KB never does.
function Test-CatalogProvedNoPackage($kb){
  return [bool]($script:CatalogAsked -and $script:CatalogAsked.ContainsKey($kb) -and $script:CatalogAsked[$kb].valid -and
                (@($script:CatalogAsked[$kb].urls).Count -eq 0))
}
# THE ROW NAMES THE THREE FACTS (ADR-updater section 2 point 5) in the words the dom0 user reads: wu-update.ps1 prints a row's
# reason verbatim as "informational <KB>: <reason>", so this text is what the Qube Manager update window shows. ONE writer for the
# scan's log line and both install-loop gates, so the three cannot drift apart. Called only where all three were measured this pass
# (Test-CatalogProvedNoPackage true; the content not self-contained; HasDefaultRoute false).
function Get-NoRouteReason($kb, $contentClass) {
  if (-not ("$kb" -match '^KB\d+$')) {   # an offer without a KB, verified by its exact title (point 5, extended 2026-11-06)
    return ("not installable from this guest, verified this pass: the Update Catalog answered a valid results page for the title '" + $kb +
            "' and none of the identically-titled packages declares " + $OsArch + " (each candidate inspected); the offer carries no " +
            "self-contained content (no direct URL); and the guest has no default route for Windows Update's own downloader." +
            " Informational, not a failure: left out of dom0's count until a pass measures otherwise")
  }
  $m = if ($script:CatalogAsked) { $script:CatalogAsked[$kb] } else { $null }
  $page = if ($null -eq $m.rows) { 'a valid results page' } elseif ([int]$m.rows -eq 0) { "a valid results page with no entries (the Catalog's own 'no results')" }
          elseif ([int]$m.rows -eq 1) { 'a valid results page with 1 entry' } else { "a valid results page with $($m.rows) entries" }
  if ($null -ne $m.ranked -and [int]$m.rows -gt 0) { $page += ", $($m.ranked) of them for $OsArch build $OsBuild," }
  $cls = if ("$contentClass" -ne '') { "$contentClass" } else { 'none' }
  $content = if ($cls -eq 'express') { "Windows Update serves it only as express or Delivery Optimization streams (content_class=express)" }
             else { "Windows Update supplies no static file our installer could fetch (content_class=$cls)" }
  return ("not installable from this guest, verified this pass: the Update Catalog answered " + $page + " and resolved no package for " + $kb +
          "; the content is not self-contained - " + $content + "; and the guest has no default route for Windows Update's own downloader." +
          " Informational, not a failure: left out of dom0's count until a pass measures otherwise")
}
# The content class the scan computed for an offer, by KB - the install-loop gates hold KBs, not offers.
function Get-OfferContentClass($kb) {
  $u = @($script:St.available | Where-Object { "$($_.kb)" -eq "$kb" } | Select-Object -First 1)
  if ($u.Count -gt 0 -and "$($u[0].content_class)" -ne '') { return "$($u[0].content_class)" }
  return 'none'
}
function Resolve-CatalogUncached($kb){
  $script:CatalogRows = $null; $script:CatalogRanked = $null   # the valid page's entry counts; Resolve-Catalog keeps them per KB for the reason the row names
  $hdr = @{}
  if ($AcceptLanguage) { $hdr['Accept-Language'] = $AcceptLanguage }
  $r=Invoke-WebRequest "https://www.catalog.update.microsoft.com/Search.aspx?q=$kb" -Proxy $Proxy -UseBasicParsing -TimeoutSec 60 -Headers $hdr
  # ---- WU-CATALOG-VALID-BEGIN
  # GUARD:catalogvalid - ZERO RESULTS AND A BROKEN RESPONSE LOOK IDENTICAL, and they must not.
  # Everything downstream reads "0 catalog .msu" as "the catalog has no package for this KB", which
  # sends the KB to the informational ceiling dom0 excludes from its count - a class this code logs
  # as "terminally classified". But a truncated body (relay truncation on large responses is a
  # KNOWN failure mode on this path), an error or interstitial page, or a garbled encoding all
  # produce zero regex matches too, so a transient transport fault would permanently hide a real
  # installable update from dom0 - the field defect this product already shipped once.
  # Jev: is_defect 0.94, severity high-silently-hides-real-updates 1.00, self_corrects 0.21.
  # Believe a zero count ONLY from a response that is demonstrably the catalog's own results page.
  # The Catalog's answer to a search carries its results table or its own "no results" element. Its error page, and a
  # search page it returns with an empty results container, carry neither while still carrying other catalogBody ids, so
  # "the body mentions catalogBody" is not the test. The title search in Resolve-DriverByTitle applies the same expression.
  $script:CatalogUnresolved = $false
  $body = [string]$r.Content
  if ([string]::IsNullOrWhiteSpace($body) -or ($body -notmatch 'ctl00_catalogBody_(updateMatches|noResult)')) {
    $script:CatalogUnresolved = $true
    Log ("  " + $kb + " : catalog response is not a results page (" + $body.Length + " bytes) - UNRESOLVED, not 'no package'")
    return @()
  }
  # ---- WU-CATALOG-VALID-END
  $rx=[regex]"(?is)id='([0-9a-fA-F\-]{36})_link'[^>]*>(.*?)</a>"
  $digits = $kb -replace '\D',''

  # Expected filename family for THIS guest, derived - never assumed. InstallationType is 'Client'
  # or 'Server'/'Server Core' and is not localized; 22000 is the Windows 11 build boundary, a
  # number rather than a name. Used as a PREFERENCE, not a hard requirement, so an unforeseen
  # future family degrades to "still picks a correctly-named package for this arch and KB".
  $instType = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -EA SilentlyContinue).InstallationType
  $wantFamily = if ($instType -like 'Client*' -and [int]$OsBuild -ge 22000) { 'windows11.0' } else { 'windows10.0' }

  # Rank candidates on untranslated tokens only. Arch is mandatory; build outranks version; the
  # old English keywords survive ONLY as a tie-breaker nudge and can no longer reject anything.
  $ranked = @()
  $all = @()
  foreach($m in $rx.Matches($r.Content)){
    $t=($m.Groups[2].Value -replace '<[^>]+>','' -replace '\s+',' ').Trim()
    $all += $t
    if($t -notmatch [regex]::Escape($OsArch)){ continue }
    $score = 0
    if($OsBuild -and $t -match [regex]::Escape($OsBuild)){ $score += 4 }
    if($OsVer   -and $t -match [regex]::Escape($OsVer))  { $score += 2 }
    if($score -eq 0){ continue }
    # Ranking hint ONLY - this can no longer reject anything, so a locale it fails to cover costs
    # ordering, not correctness. Stems, because the shared prefix is what survives translation:
    # 'Dynami' covers Dynamic/Dynamisch/dinamico/dynamique, and -match is case-insensitive so
    # 'Server' already catches German "Serverbetriebssystem" and Italian "sistema operativo
    # server" - but NOT French "serveur" or Spanish "servidor", hence those spelled out.
    # 'server operating system' is dropped as dead weight: 'Server' already matches it.
    #
    # ASCII ONLY, deliberately. A CJK stem here was mangled to '?a??a?' in transit and broke the
    # parse (ps-syntax-check caught it) - this file crosses qrexec/qtest and is written as ASCII,
    # so a non-ASCII literal is a syntax error waiting to happen. Since this is only a ranking
    # nudge, losing a script we cannot spell costs ordering, never correctness.
    if($t -match 'Dynami|Server|Serveur|Servidor|servidore'){ $score -= 3 }
    $ranked += [pscustomobject]@{ guid=$m.Groups[1].Value; title=$t; score=$score }
  }
  $ranked = @($ranked | Sort-Object -Property @{Expression='score';Descending=$true})
  $script:CatalogRows = $all.Count; $script:CatalogRanked = $ranked.Count   # what the valid page listed, and how many of those name this arch and build

  $fallback = $null
  $unanswered = 0   # GUARD:dialogunanswered - candidates whose download dialog never ANSWERED (the request failed, or an empty body)
  foreach($c in $ranked){
    $json='[{"size":0,"languages":"","uidInfo":"'+$c.guid+'","updateID":"'+$c.guid+'"}]'
    try{
      $dl=Invoke-WebRequest 'https://www.catalog.update.microsoft.com/DownloadDialog.aspx' -Method POST -Body @{updateIDs=$json} -Proxy $Proxy -UseBasicParsing -TimeoutSec 60 -Headers $hdr
    }catch{ $unanswered++; Log ("  candidate unanswered (download dialog failed: " + $_.Exception.Message + "): " + $c.title); continue }
    if ([string]::IsNullOrWhiteSpace([string]$dl.Content)) { $unanswered++; Log ("  candidate unanswered (download dialog returned an empty body): " + $c.title); continue }
    $files=@([regex]::Matches($dl.Content,"url\s*=\s*'(http[^']+)'")|ForEach-Object{$_.Groups[1].Value}|Where-Object{$_ -match '\.msu(\?|$)'}|Sort-Object -Unique)
    if(-not $files.Count){ Log ("  candidate rejected (no .msu): " + $c.title); continue }

    # THE test: does this candidate actually carry a package named for this KB and this arch?
    # EXCEPTION for .NET Framework CUs: the offered ROLLUP KB (e.g. KB5066747) is delivered as
    # COMPONENT packages named for a DIFFERENT KB (windows10.0-kb5066130-ndp481, kb5066135-ndp48), so the
    # rollup digits never appear in the filenames and the digit test wrongly rejected a real, installable
    # .NET security CU (measured 2026-08-20). For .NET candidates, match on arch only and take every .msu
    # (all are correct .NET component packages; Install-Msus skips the ones this image does not apply).
    $isDotNet = $c.title -match '\.NET Framework'
    $named = @($files | Where-Object { ($isDotNet -or $_ -match $digits) -and $_ -match [regex]::Escape($OsArch) })
    if(-not $named.Count){
      Log ("  candidate rejected (no file named for $kb/$OsArch): " + $c.title)
      foreach($f in $files){ Log ("      had: " + (& { if($f -match '/([^/?]+\.msu)'){$Matches[1]} else {$f} })) }
      continue
    }
    $family = @($named | Where-Object { $_ -match [regex]::Escape($wantFamily) })
    if($family.Count){
      Log ("  catalog pick: " + $c.title)
      Log ("    matched on filename family $wantFamily + $kb + $OsArch (title language is irrelevant)")
      return $files
    }
    # Right KB and arch, wrong/unknown product family - keep as a fallback and look for better.
    if(-not $fallback){ $fallback = [pscustomobject]@{ files=$files; title=$c.title } }
    Log ("  candidate deferred (no $wantFamily file): " + $c.title)
  }

  if($fallback){
    Log ("  catalog pick (FALLBACK - no $wantFamily package found for this KB): " + $fallback.title)
    return $fallback.files
  }
  # Log every candidate: a resolution miss is otherwise invisible and looks like "no updates".
  Log "  no catalog entry matches arch=$OsArch ver=$OsVer build=$OsBuild family=$wantFamily; candidates:"
  foreach($c in $all){ Log "    - $c" }
  # A candidate the dialog never answered might have been the package: 'no package' is unproven (ADR-updater section 2 point 5).
  # Until 2026-11-02 this returned a VERIFIED miss - the valid search page alone - so a refused dialog POST left the offer out of
  # dom0's count with an informational row saying the Catalog "resolved no package" (replayed with KB5127648, which it serves).
  if ($unanswered -gt 0) {
    $script:CatalogUnresolved = $true
    Log ("  " + $kb + " : " + $unanswered + " candidate(s) unanswered by the download dialog - UNRESOLVED, not 'no package'")
  }
  return @()
}

# Resumable fetch with progress into the status file, and with the two checks whose absence
# produced an unusable 5 GB file (2026-08-13, template): CBS rejected both packages with
# CBS_E_INVALID_PACKAGE, DISM logged "Failed to open ESD ... 0x8007000d" and a DPX range error
# 0xca00a005 - i.e. the bytes on disk were not a package at all.
#
# WHY IT COULD HAPPEN: the old version sent a Range header and then ALWAYS appended the response.
# A server (or the relay) that ignores the range and answers 200 with the WHOLE body appends a
# full copy onto the partial one, producing a file of plausible size and corrupt content. Nothing
# checked afterwards, so it went to DISM, "succeeded" with 3010, and was rolled back at boot.
#
# Now: a ranged request that comes back 200 restarts the file instead of appending; the expected
# total is taken from Content-Range when the server does honour the range; and the finished file
# is verified for BOTH size and the CAB magic (an .msu is a cabinet - "MSCF"), which is what
# catches an HTML error page or a truncated download. A file that fails verification is DELETED,
# never resumed - resuming corrupt bytes can only produce more corrupt bytes.
# Returns 'ok' | 'short' | 'bad'. The distinction matters more than it looks: treating a SHORT
# file as corrupt turns every dropped connection into a restart from zero, and a 4.8 GB package
# over a relay that drops around 3 GB then never completes - measured 2026-08-13, the download
# looped 3.18 GB -> deleted -> 0 bytes -> repeat.
function Test-Msu($path, $expect) {
  if (-not (Test-Path -LiteralPath $path)) { return 'bad' }
  $len = (Get-Item -LiteralPath $path).Length
  if ($len -eq 0) { return 'bad' }
  try {
    $fs = [IO.File]::OpenRead($path)
    $magic = New-Object byte[] 4
    $null = $fs.Read($magic, 0, 4)
    $fs.Close()
  } catch { return 'bad' }   # an UNREADABLE file is corrupt, not success: 'bad' (was $false, which matched no case)
  # An .msu is NOT always a cabinet. Classic packages start with 'MSCF', but recent Windows 11
  # cumulative updates ship as WIM containers starting with 'MSWIM' - measured 2026-08-13:
  # KB5121003's .msu begins 4D 53 57 49 4D. A CAB-only check rejected a perfectly good 4.8 GB
  # download and looped forever, which is worse than the problem it was added for. Accept both,
  # and keep the check only for what it is actually good at: catching an HTML error page.
  $isCab = ($magic[0] -eq 0x4D -and $magic[1] -eq 0x53 -and $magic[2] -eq 0x43 -and $magic[3] -eq 0x46)
  $isWim = ($magic[0] -eq 0x4D -and $magic[1] -eq 0x53 -and $magic[2] -eq 0x57 -and $magic[3] -eq 0x49)
  # A self-contained WU update can also be an executable (Defender mpam-fe.exe, MSRT
  # windows-kb890830-*.exe) - a valid PE starts 'MZ' (4D 5A). Accept it: an HTML error page still
  # begins '<' (0x3C), so this keeps catching garbage while letting the agent-cache path fetch exes.
  $isExe = ($magic[0] -eq 0x4D -and $magic[1] -eq 0x5A)
  if (-not ($isCab -or $isWim -or $isExe)) {
    Log "  VERIFY: $([IO.Path]::GetFileName($path)) is not MSCF/MSWIM/MZ - discarding"
    return 'bad'          # an HTML error page or garbage: resuming it can only make it worse
  }
  if ($expect -gt 0 -and $len -lt $expect) { return 'short' }   # incomplete: RESUME, do not delete
  if ($expect -gt 0 -and $len -gt $expect) {
    Log "  VERIFY: $([IO.Path]::GetFileName($path)) is $len bytes, expected $expect - discarding"
    return 'bad'          # longer than advertised = a body appended onto a partial
  }
  return 'ok'
}

function Get-UrlSize($url){
  # Size WITHOUT fetching a body, so "what would this cost" is answerable before committing to it.
  # Two ways, because CDNs are inconsistent: HEAD first, then a one-byte ranged GET whose
  # Content-Range trailer carries the full length. Returns -1 when neither works - callers must
  # print that as unknown rather than silently reporting 0, which would read as "free".
  foreach($method in 'HEAD','GET'){
    try{
      $r=[System.Net.HttpWebRequest]::Create($url); $r.Proxy=New-Object System.Net.WebProxy($Proxy)
      $r.Timeout=30000; $r.Method=$method
      if($method -eq 'GET'){ $r.AddRange(0,0) }
      $resp=$r.GetResponse()
      $len=-1
      $cr=$resp.Headers['Content-Range']
      if($cr -and $cr -match '/(\d+)\s*$'){ $len=[int64]$Matches[1] }
      elseif($resp.ContentLength -gt 0){ $len=[int64]$resp.ContentLength }
      $resp.Close()
      if($len -ge 0){ return $len }
    }catch{ }
  }
  return -1
}

# THE ROW LEARNS ITS SIZE HERE - from bytes a fetch MEASURED: Content-Length when the file is fetched, the VERIFIED local copy's
# length when the server answers the resume with 416 (MEASURED 2026-11-01, campaign at bafe660f, template-update round 2: KB5127648
# was a cache hit from round 1's deferred fetch; its row stayed size_mb=null/unresolved while a 4553.8 MB file verified by Test-Msu sat
# on disk and `downloading` already said total_mb 4553.8). Keyed by file so a retry or a resume counts a file once; looked up by KB the
# way the install path does (St.available keeps every offer); the next Save carries it to dom0. A row that cannot be updated never
# fails the fetch. ADR-updater 12.2.
function Resolve-WuRowSize($kb,$dst,$bytes,$via){
  if(-not $kb -or $kb -notmatch '^KB\d+$'){ return }
  if(-not $bytes -or [long]$bytes -le 0){ return }
  try{
    if(-not $script:ResolvedSize){ $script:ResolvedSize=@{} }
    if(-not $script:ResolvedSize.ContainsKey($kb)){ $script:ResolvedSize[$kb]=@{} }
    $script:ResolvedSize[$kb][[IO.Path]::GetFileName($dst)]=[long]$bytes
    $sum=[long]0; foreach($v in $script:ResolvedSize[$kb].Values){ $sum+=$v }
    foreach($row in @($script:St.available | Where-Object { $_.kb -eq $kb })){ $row.size_mb=[math]::Round($sum/1MB,1); $row.size_src='content' }
    Log ("WUSIZE-RESOLVED kb={0} file={1} mb={2} row_mb={3} via={4}" -f $kb, [IO.Path]::GetFileName($dst), [math]::Round([long]$bytes/1MB,1), [math]::Round($sum/1MB,1), $via)
  }catch{ Log "  row size not updated for ${kb}: $($_.Exception.Message)" }
}

function Fetch-Msu($url,$dst,$kb){
  # Throughput is a first-class output here, not a nicety: every rate figure recorded for this
  # tunnel so far was taken while the guest was also talking to telemetry endpoints the proxy
  # allowlist now blocks, so none of them describe the shipping configuration. Log bytes and
  # wall time per attempt and let the numbers come from the real workload.
  # Measured against what was on disk when this call began, so a resumed download reports the
  # bytes IT moved rather than crediting itself with an earlier attempt's progress.
  $tStart = Get-Date
  $startLen = if (Test-Path $dst) { (Get-Item $dst).Length } else { 0 }
  # 14 attempts, not 8: the relay intermittently churns its warm channel and a fresh GetResponse can
  # time out with zero bytes (measured on the 85 MB MSRT self-contained fetch - attempts stalled, then
  # resumed 16 -> 32 MB). Since each attempt RESUMES from bytes-on-disk, a large file completes across
  # more attempts even when individual ones abort. GetResponse timeout raised 60->90s to give a slow
  # relay response more room before aborting an otherwise-good attempt.
  for($a=1;$a -le 14;$a++){
    $have=0; if(Test-Path $dst){$have=(Get-Item $dst).Length}; $o=$null; $expect=0
    try{
      $req=[System.Net.HttpWebRequest]::Create($url); $req.Proxy=New-Object System.Net.WebProxy($Proxy)
      $req.Timeout=90000; $req.ReadWriteTimeout=180000
      $asked=$false; if($have -gt 0){ $req.AddRange($have); $asked=$true }
      $resp=$req.GetResponse()

      # Did the server honour the range? 206 = yes, resume. Anything else = start over.
      $status=[int]$resp.StatusCode
      $append=$false
      if($asked -and $status -eq 206){
        $append=$true
        $cr=$resp.Headers['Content-Range']
        if($cr -and $cr -match '/(\d+)\s*$'){ $expect=[int64]$Matches[1] } else { $expect=$have+$resp.ContentLength }
      } else {
        if($asked){ Log "  server ignored the resume range (HTTP $status) - restarting the download" }
        $have=0; $expect=$resp.ContentLength
      }
      # For a catalog-delivered offer this Content-Length is the first honest number there is (Get-WuContentClass said unresolved).
      Resolve-WuRowSize $kb $dst $expect 'content-length'

      $mode = if($append){[System.IO.FileMode]::Append}else{[System.IO.FileMode]::Create}
      $in=$resp.GetResponseStream()
      $o=[System.IO.File]::Open($dst,$mode); $buf=New-Object byte[] (1048576); $last=Get-Date
      while(($n=$in.Read($buf,0,$buf.Length)) -gt 0){ $o.Write($buf,0,$n); $have+=$n
        if(((Get-Date)-$last).TotalSeconds -ge 3){ $script:St.downloading=[ordered]@{kb=$kb;file=[IO.Path]::GetFileName($dst);mb=[math]::Round($have/1MB,1);total_mb=[math]::Round($expect/1MB,1);pct=[math]::Round(100*$have/[math]::Max($expect,1),1)}; Save; $last=Get-Date } }
      $o.Close();$in.Close();$resp.Close()

      $verdict = Test-Msu $dst $expect
      if($verdict -eq 'bad'){
        Remove-Item -LiteralPath $dst -Force -EA SilentlyContinue   # never resume corrupt bytes
        Log "  attempt ${a}: file is not a package - discarded, restarting"
        Start-Sleep 5
        continue
      }
      if($verdict -eq 'short'){
        Log "  attempt ${a}: stream ended early at $([math]::Round($have/1MB,1)) of $([math]::Round($expect/1MB,1)) MB - resuming"
        Start-Sleep 5
        continue                                                    # keep the bytes, resume them
      }
      $script:St.downloading=[ordered]@{kb=$kb;file=[IO.Path]::GetFileName($dst);mb=[math]::Round($have/1MB,1);total_mb=[math]::Round($have/1MB,1);pct=100}; Save
      $bytesThisRun = $have - $startLen
      $secs = [math]::Max(((Get-Date) - $tStart).TotalSeconds, 0.001)
      Log ("  THROUGHPUT {0}: {1:N1} MB fetched in {2:N0}s = {3:N0} KB/s (file now {4:N1} MB, {5} attempt(s))" -f `
           [IO.Path]::GetFileName($dst), ($bytesThisRun/1MB), $secs, ($bytesThisRun/1KB/$secs), ($have/1MB), $a)
      return $true
    }catch{
      if($o){try{$o.Close()}catch{}}
      # A complete local copy makes the server refuse the resume range with 416. That is
      # "already downloaded", not a failure - measured 2026-08-13: a re-run after a successful
      # pass burned all 8 attempts on 416 and reported the update as unresolvable.
      # PowerShell wraps a failing method call in a MethodInvocationException, so $_.Exception is
      # NOT the WebException - it is the wrapper. Unwrap it, and keep a text fallback: this check
      # silently did nothing the first time precisely because of that wrapping.
      $code=$null; $we=$_.Exception
      if($we -isnot [System.Net.WebException] -and $we.InnerException){ $we=$we.InnerException }
      if($we -is [System.Net.WebException] -and $we.Response){ $code=[int]$we.Response.StatusCode }
      if(-not $code -and $_.Exception.Message -match '\(416\)'){ $code=416 }
      if($code -eq 416 -and $have -gt 0){
        # Complete by the server's reckoning - but PROVE it. expect=0 skipped the SIZE check, so an
        # over-long corrupt-append file with valid leading magic slipped through. Verify magic AND
        # size against the server's true total (Get-UrlSize; -1 => magic-only, best effort).
        $srvTotal = Get-UrlSize $url
        if((Test-Msu $dst $srvTotal) -eq 'ok'){
          # A verified complete copy is a measured size: the row would otherwise stay unresolved on every cache hit.
          Resolve-WuRowSize $kb $dst $have 'cached'
          Log "  $([IO.Path]::GetFileName($dst)) already complete ($([math]::Round($have/1MB,1)) MB; server refused resume with 416)"
          $script:St.downloading=[ordered]@{kb=$kb;file=[IO.Path]::GetFileName($dst);mb=[math]::Round($have/1MB,1);total_mb=[math]::Round($have/1MB,1);pct=100}; Save
          return $true
        }
        Log "  local copy failed verification despite 416 (magic/size) - discarding and refetching"
        Remove-Item -LiteralPath $dst -Force -EA SilentlyContinue
        continue
      }
      Log "  fetch attempt ${a}: $($we.Message)"; Start-Sleep 5 }
  }
  return $false
}

# DISM outcomes that mean "this package is now on the system": success, success-pending-reboot,
# and already-installed (0x240006). Anything else is a real failure for that FILE - though not
# necessarily for the KB, see the per-KB rule at the call site.
#
# NOTE: this definition was once deleted by a careless region replacement (the Fetch-Msu rewrite
# above), leaving $OK_RC undefined - so `$_.rc -in $OK_RC` was always false and EVERY install
# reported failure, including one that had returned 3010. Keep it adjacent to its only consumers.
$OK_RC = @(0, 3010, 2359302)
# Set the moment any package is STAGED (rc=3010). CBS applies exactly one staged session per
# boot; a second package staged behind the first is silently discarded, so the pass stops
# staging once this is true and the next pass picks up the rest after the reboot.
# Set QUBES_UPDATES_ALLOW_MULTISTAGE=1 to stage several packages anyway - Windows DOES aggregate
# packages per reboot normally, so the one-per-session rule rests on a single observation and must
# stay falsifiable. That variable is how the aggregation question gets re-tested.
# ONE RELAXATION, AND ONLY THIS ONE (2026-10-04, docs/ADR-updater.md section 13): packages may stage in the same pass AFTER a
# cumulative that THIS pass staged and that Windows REGISTERED (WU-CUMULATIVE-REGISTERED sets $script:CumulativeRegisteredThisSession).
# Measured 2026-10-03/04 on the reporter's German 25H2 template (released 4.3.33, four fresh clones). With this rule LIFTED
# (QUBES_UPDATES_ALLOW_MULTISTAGE=1), .NET (KB5126052) staged first and the cumulative (KB5129195) second lost the cumulative silently -
# DISM 3010 for both, no RollupFix 9457 ever registered, UBR unchanged after the restart. (Shipped 4.3.33 keeps the rule: it defers the
# cumulative behind .NET and asks for a second restart; a cumulative it staged alone was verified to land, UBR 9457.) The cumulative
# FIRST and .NET second both landed at ONE restart (RollupFix 9457 Installed, UBR 9457, .NET installed).
# Mechanism, inferred: the cumulative's bundled servicing stack must install ONLINE first, and a restart already pending blocks that.
# A second cumulative behind the first is still deferred, and with no cumulative in the pass the rule above stands unchanged.
# TEST HOOKS, same convention as the agent's SoloFaultInject: the multistage-defer guard only
# fires when a session has already staged a reboot-requiring package AND a non-catalog KB is
# still pending, and that combination cannot be summoned on a guest that is already up to date.
#   QUBES_UPDATES_FAKE_STAGED=1        pretend this session staged something
#   QUBES_UPDATES_FAKE_FALLBACK_KB=KB. pretend that KB needs the Windows Update fallback
# Both are dead code when unset.
$script:StagedThisSession = ($env:QUBES_UPDATES_FAKE_STAGED -eq '1')
if ($script:StagedThisSession) { Log 'QUBES_UPDATES_FAKE_STAGED=1 - pretending a reboot-requiring package is already staged' }
# True only once a cumulative staged in THIS pass is seen REGISTERED by Windows (a RollupFix package newly InstallPending). Never
# set from an exit code, never carried across passes: the restart that follows settles it.
$script:CumulativeRegisteredThisSession = $false

# ASK DISM WHETHER A PACKAGE APPLIES, BEFORE INSTALLING IT.
# Measured 2026-08-13/14 on a 24H2 image: the catalog returns SEVERAL .msu per KB, and we ran all
# of them. kb5043080 came back rc=552 and DISM's own log said "Not applicable ... Feature:
# CumulativeUpdate_KB5043080"; the real cumulative then staged (3010) and was ROLLED BACK at boot
# with 0x80070490 / CBS_E_INVALID_PACKAGE. Running an inapplicable package is not free - it can
# leave the servicing session in a state the applicable one cannot complete from.
#
# /Get-PackageInfo answers the question directly and changes nothing. Returns a hashtable:
#   applicable : Yes | No | unknown        state : Installed | Not Present | Install Pending | ...
#   identity   : the CBS package identity, which also tells us what KIND of package it is
function Get-MsuInfo($path){
  $out = & DISM /Online /Get-PackageInfo /PackagePath:"$path" /English 2>&1
  $info = @{ applicable='unknown'; state='unknown'; identity=''; rc=$LASTEXITCODE }
  foreach($l in $out){
    if($l -match '^\s*Applicable\s*:\s*(\S+)')       { $info.applicable = $Matches[1] }
    elseif($l -match '^\s*State\s*:\s*(.+?)\s*$')     { $info.state      = $Matches[1] }
    elseif($l -match '^\s*Package Identity\s*:\s*(\S+)'){ $info.identity  = $Matches[1] }
  }
  return $info
}

# Servicing order matters: a servicing-stack update must be installed BEFORE the cumulative that
# requires it, and the file size we used to sort by is only a proxy for that. The CBS identity
# names the kind, so order by it and fall back to size.
function Order-Msus($files){
  $ranked = @()
  foreach($f in $files){
    $id = ''
    try { $id = (Get-MsuInfo $f).identity } catch { $id = '' }
    $rank = 2                                             # default: everything else
    if($id -match 'ServicingStack|SSU')   { $rank = 0 }   # servicing stack first
    elseif($id -match 'Checkpoint')       { $rank = 1 }   # then any checkpoint package
    elseif($id -match 'RollupFix|LCU')    { $rank = 3 }   # cumulative last
    $ranked += [pscustomobject]@{ path=$f; rank=$rank; size=(Get-Item $f).Length; id=$id }
  }
  return ,@($ranked | Sort-Object rank, size | ForEach-Object { $_.path })
}

# ---- WU-MSU-KIND-BEGIN   (tools/tests/wu-cumulative-order-test.ps1 runs this region)
# WHICH .msu IS THE CUMULATIVE - decided by the package identity DISM reports for the FILE (Get-MsuInfo), never by a title or a filename
# (ADR-updater section 6; Jev Q1 0.63, 2026-10-04). Measured on the reporter's German 25H2 template with 4.3.33: the combined cumulative
# (KB5129195 - servicing stack and rollup in one .msu, the new format expand.exe cannot open) reports 'OnePackage~~~~0.0.0.0'; an
# older-format rollup names its RollupFix; the .NET packages (KB5126052) report no identity at all. The kind decides the ORDER of the
# pass (WU-PASS-ORDER) and which package gets the registration check (WU-CUMULATIVE-REGISTERED). It never decides whether a package is
# installed - DISM's own applicability answer does that, as before.
function Get-MsuKindFromIdentity([string]$identity){
  if($identity -match 'OnePackage|RollupFix'){ return 'cumulative' }   # GUARD:cumulativeid
  return 'other'
}
# Memoized per path: /Get-PackageInfo opens the package, and a cumulative is gigabytes.
$script:MsuKindCache = @{}
function Get-MsuKind($path){
  $key = [string]$path
  if(-not $script:MsuKindCache.ContainsKey($key)){
    $id = ''
    try { $id = [string](Get-MsuInfo $path).identity } catch { $id = '' }
    $script:MsuKindCache[$key] = Get-MsuKindFromIdentity $id
  }
  return $script:MsuKindCache[$key]
}
# ---- WU-MSU-KIND-END

# ---- WU-CBS-READ-BEGIN
# TWO READS OF THE SERVICING STATE, both STRUCTURED, both honest about not knowing.
# CBS RebootPending (the key CBS creates when a staged operation waits for a boot): $true / $false, or $null when it cannot be read.
# UNKNOWN IS NOT FALSE: the caller announces an unreadable answer (ADR-updater section 10) rather than treating it as 'nothing pending'.
function Test-CbsRebootPending {
  try { return [bool](Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending' -EA Stop) }
  catch { return $null }
}
# The package list as PackageName -> PackageState, from the Dism module (Get-WindowsPackage -Online). The state is the module's own
# enum, whose names are English whatever the system language - `dism /get-packages /format:table` prints its state words LOCALIZED,
# and the reporter's guest is German, so that output can never be matched here (ADR-updater section 6). $null when the list cannot be
# read or comes back empty: a reading that failed is reported as such by the caller, never as 'nothing pending'.
function Get-CbsPackageStates {
  try {
    $states = @{}
    foreach($p in @(Get-WindowsPackage -Online -ErrorAction Stop)){ $states[[string]$p.PackageName] = [string]$p.PackageState }
    if($states.Count -eq 0){ Log '  package list: Get-WindowsPackage -Online returned no packages at all - treated as UNREADABLE'; return $null }
    return $states
  } catch {
    Log ('  package list: Get-WindowsPackage -Online failed (' + ($_.Exception.Message -replace '\s+',' ') + ') - UNREADABLE')
    return $null
  }
}
# ---- WU-CBS-READ-END

# ---- WU-CUMULATIVE-REGISTERED-BEGIN   (tools/tests/wu-cumulative-order-test.ps1 runs this region)
# DID WINDOWS REGISTER THE CUMULATIVE DISM ACCEPTED? DISM's rc=3010 is not the answer: measured 2026-10-03/04 on the reporter's German 25H2
# template, a cumulative staged behind a pending restart returned 3010 and was NEVER registered - no RollupFix 9457 in the package list
# in any state, UBR unchanged after the restart, the update re-offered. (That was an experiment with QUBES_UPDATES_ALLOW_MULTISTAGE=1: the
# shipped one-package rule never staged the cumulative behind .NET - it deferred it, which is why 4.3.33 asks for a second restart. And a
# cumulative 4.3.33 staged ALONE was verified to complete at its restart, UBR 9457.) The
# answer is the package list BEFORE and AFTER the DISM call: a RollupFix package must be NEWLY InstallPending (absent before, or not
# InstallPending before). Measured when it works: RollupFix 9457 'InstallPending' and 8037 'UninstallPending' after the call, 9457
# Installed and 8037 Superseded after the restart. An already-pending rollup is NOT this call's doing and does not pass it.
# Returns ok (registered), known (both lists were readable) and a why that names what was seen. Jev Q3 0.88: the check is needed.
function Test-RollupRegistered($before, $after, [string]$WantState = 'InstallPending'){
  if($null -eq $before -or $null -eq $after){
    $which = if($null -eq $before -and $null -eq $after){ 'before and after' } elseif($null -eq $before){ 'before' } else { 'after' }
    return @{ ok=$false; known=$false; why="the package list could not be read $which the DISM call, so whether a RollupFix package became $WantState is UNKNOWN" }
  }
  $newlyPending = @($after.Keys | Where-Object { $_ -match 'RollupFix' -and $after[$_] -eq $WantState -and ((-not $before.ContainsKey($_)) -or ($before[$_] -ne $WantState)) })   # GUARD:rollupregistered
  $seen = @($after.Keys | Where-Object { $_ -match 'RollupFix' } | Sort-Object | ForEach-Object {
             "$_=$($after[$_])" + $(if($before.ContainsKey($_)){ " (before: $($before[$_]))" } else { ' (absent before)' }) })
  if($newlyPending.Count -gt 0){ return @{ ok=$true; known=$true; why=("newly $WantState" + ': ' + ($newlyPending -join ', ')) } }
  return @{ ok=$false; known=$true; why=("no RollupFix package is newly $WantState" + ' - RollupFix packages after the call: ' + $(if($seen.Count){ $seen -join ', ' } else { 'none' })) }
}
# ---- WU-CUMULATIVE-REGISTERED-END

# DISM cannot ingest .msu on Win10 (measured 2026-08-19: rc=50 'request is not supported' on
# 19045 for both the LCU and the .NET package; the same call works on Win11 26100, where the
# whole catalog+DISM path was built and proven). And the WU-native path cannot replace it on
# a netvm-less guest: BITS/DO refuse jobs outright with no network interface present
# (0x80200010 BG_E_NETWORK_DISCONNECTED / 0x80D03805 - NLM sees no NIC; the loopback proxy
# does not count). So on rc=50 the .msu is EXPANDED (an .msu is a cab archive) and the inner
# .cab payloads go to DISM directly - the classic Win10 servicing shape. WSUSSCAN.cab is
# metadata, not a package; SSU-named cabs rank first (combined LCUs usually carry the SSU
# inside the main cab, where CBS orders it itself). rc reduction across cabs: any real
# failure wins, else 3010 if anything staged, else 0.
function Add-PackageCompat($f){
  # DISM's own log goes to the one log directory, in DISM's own shape: dism-<yyyyMMdd>.log, dated by the call
  # (docs/ADR-logging.md, Decision 2026-11-01, item 2).
  $dismLog = Join-Path (Get-QwtLogDir) ('dism-' + (Get-Date -Format 'yyyyMMdd') + '.log')
  & DISM /Online /Add-Package /PackagePath:"$f" /NoRestart /Quiet /LogPath:"$dismLog" | Out-Null
  $rc=$LASTEXITCODE
  if($rc -ne 50){ return $rc }
  $name=[IO.Path]::GetFileName($f)
  Log "  $name : DISM rc=50 (.msu unsupported on this OS) - expanding to cabs"
  $tmp = Join-Path $WorkDir ('msux-' + [IO.Path]::GetFileNameWithoutExtension($f).Substring(0, [Math]::Min(40, [IO.Path]::GetFileNameWithoutExtension($f).Length)))
  Remove-Item $tmp -Recurse -Force -EA SilentlyContinue
  New-Item -ItemType Directory -Path $tmp -Force | Out-Null
  & expand.exe -F:* "$f" "$tmp" | Out-Null
  $cabs = @(Get-ChildItem $tmp -Filter '*.cab' | Where-Object { $_.Name -ine 'WSUSSCAN.cab' } |
            Sort-Object @{e={ if($_.Name -match 'SSU'){0}else{1} }}, Length)
  if($cabs.Count -eq 0){ Log "  $name : expand produced no cabs"; Remove-Item $tmp -Recurse -Force -EA SilentlyContinue; return 50 }
  $worst=0; $staged=$false
  foreach($c in $cabs){
    $dismLog = Join-Path (Get-QwtLogDir) ('dism-' + (Get-Date -Format 'yyyyMMdd') + '.log')
    & DISM /Online /Add-Package /PackagePath:"$($c.FullName)" /NoRestart /Quiet /LogPath:"$dismLog" | Out-Null
    $crc=$LASTEXITCODE
    Log ("  cab " + $c.Name + " rc=" + $crc)
    if($crc -eq 3010 -or $crc -eq 2359302){ $staged=$true }
    elseif($crc -ne 0){ $worst=$crc }
  }
  Remove-Item $tmp -Recurse -Force -EA SilentlyContinue
  if($worst -ne 0){ return $worst }
  if($staged){ return 3010 }
  return 0
}

# Does this guest have a REAL default route (i.e. a netvm)? Loopback/blackhole adapters do not count.
# Templates have none by design; only netvm-attached standalones do. Used to gate the DO/BITS-based
# Install-ViaWU rung, which fails routeless (measured DO 0x80D03805 / BITS 0x80200010) and must never
# run on a netvm-free guest where it only produces phantom failures.
function Test-HasDefaultRoute {
  try {
    return @(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -EA SilentlyContinue |
             Where-Object { $_.InterfaceAlias -notmatch 'Loopback' }).Count -gt 0
  } catch { return $false }
}

# Best-effort ESU (Extended Security Updates) licence status, read LIVE on every pass and every build. INFORMATIONAL:
# it is reported beside the count and decides nothing (ADR-updater section 2, point 5) - an entitled guest is offered the
# real cumulative and the route proof below finds it in the Catalog, with no switch of ours. Never throws.
# MEASURED 2026-11-01: an unenrolled Win10 22H2 guest and a Win11 26H2 guest both carry ZERO SoftwareLicensingProduct rows
# whose Name says ESU, so 'not-enrolled' is what both read today; 'entitled' needs a licensed ESU product row.
function Get-EsuStatus {
  try {
    $esu = @(Get-CimInstance -ClassName SoftwareLicensingProduct -EA SilentlyContinue |
             Where-Object { $_.Name -match 'ESU|Extended Security' -and $_.LicenseStatus -eq 1 })
    if ($esu.Count -gt 0) { return 'entitled' }
    return 'not-enrolled'
  } catch { return 'unknown' }
}

# The INFORMATIONAL notice dom0's reader sees beside the count. Built from LIVE facts only - the offers THIS pass verified
# have no route (WU-ROUTE-PROOF) and the live ESU licence state - never from a build number, a date or a class. $null when
# nothing was left out of the count. Until 2026-11-01 this fired only on build 19045 with a hardcoded end-of-support date
# and then left every express/none-class offer out of dom0's count BY CLASS (owner: "that sucks").
function Get-ServicingNotice($unroutable, $esu) {
  $u = @($unroutable | Where-Object { $_ })
  if ($u.Count -eq 0) { return $null }
  return ("$($u.Count) offered update(s) have no route on this guest, verified this pass: " + ($u -join ', ') +
    '. For each, the Update Catalog answered a valid results page with no package for build ' + "$OsBuild/$OsArch" +
    ' (an offer without a KB: none of its identically-titled packages declares this architecture), Windows Update offers no ' +
    'self-contained content for it (express / Delivery Optimization streams only), and this guest ' +
    'has no default route for Windows Update''s own downloader. They are left out of the count reported to dom0 while this ' +
    'holds and verified again on every pass. ESU licence: ' + "$esu" + ' (read live; informational). INFORMATIONAL, not an error.')
}

# ---- WU-ROUTE-PROOF-BEGIN
# WHAT EARNS AN OFFER ITS SILENCE TO DOM0 (ADR-updater section 2, point 5; owner 2026-11-01: the decision is "we detected that
# we cannot install this update now so we legitimately verified the reason and skipped it", not "we blacklisted ESU by class").
# Test-OfferRoute returns the route THIS pass finds for an offer, or the verified absence of one:
#   static    - the content is self-contained: the agent's own installer installs it from content we fetch (Install-ViaAgentCache)
#   catalog   - the Update Catalog resolves an .msu for this KB on this build/arch (the DISM route; Resolve-Catalog, memoised)
#   wu-native - no Catalog package, content not express, but the guest has a default route (or the override): Install-ViaWU can
#   none      - VERIFIED no route: a valid Catalog results page with no package for this guest, no self-contained content, and
#               no route for Windows Update's own downloader (express content is never handed to it - the install loop's rule).
#               The ONLY verdict that leaves an offer out of dom0's count.
#   unknown   - the Catalog answer was UNRESOLVED (GUARD:catalogvalid), the search threw, or the offer has neither KB nor title: COUNTED.
#   An offer WITHOUT a KB (point 5, extended 2026-11-06) is asked by its exact TITLE instead, in this scan: a direct URL is 'static';
#   Resolve-DriverByTitle (one ask per title per pass) gives catalog | unknown | (default route ? wu-native : none). Its key at every
#   site that writes or reads the set is Get-OfferRouteKey (the KB, or the title).
# Nothing here keys on a build, a date, a class alone or a KB list - the class only says whether the agent-cache route exists.
# Asked again on every pass, so the day the Catalog publishes the package, the guest gains a route, or an entitlement makes
# Windows offer the real update, the next pass counts it and installs it. MEASURED basis: an unenrolled Win10 22H2 guest is
# offered only KB5071959, the ESU-enrollment OOB - express-only and absent from the Catalog (findings/updates.md:90); the
# 2026-11-01 run offered the Win11 cumulative KB5127648 as content_class=none and installed it from the Catalog (4553.8 MB).
function Test-OfferRoute($u) {
  if ("$($u.content_class)" -eq 'self-contained') { return 'static' }
  if (-not ("$($u.kb)" -match '^KB\d+$')) {   # no KB: the title route, verified in THIS scan (ADR-updater section 2 point 5, extended 2026-11-06)
    if (@(@($u.direct_urls) | Where-Object { $_ }).Count -gt 0) { return 'static' }   # the agent's own installer (WU-NOKB's first branch)
    $title = Get-OfferRouteKey $u
    if (-not $title) { return 'unknown' }   # neither KB nor title: nothing to ask the Catalog for
    $drv = Resolve-DriverByTitle $title
    if ($drv -and $drv.unresolved) { return 'unknown' }   # GUARD:nokbunresolved - an unanswered title search is not verification
    if ($drv) { return 'catalog' }   # an identically-titled package declaring this architecture: WU-NOKB installs it (Install-DriverCab)
    if ($script:HasDefaultRoute) { return 'wu-native' }   # a default route IS a route, whatever the offer's shape
    return 'none'   # VERIFIED: a valid results page, every candidate inspected, none for this architecture, no URL, no default route
  }
  $urls = @()
  try { $urls = @(Resolve-Catalog $u.kb) }   # Resolve-Catalog catches the Catalog's throw itself (UNRESOLVED); this catch is a guard
  catch { Log ("  " + $u.kb + " : catalog search threw (" + $_.Exception.Message + ") - route UNKNOWN, the offer stays counted"); return 'unknown' }
  if ($urls.Count -gt 0) { return 'catalog' }
  if ($script:CatalogUnresolved) { return 'unknown' }
  # ADR-updater section 2 point 5, third condition: a guest WITH a default route is never "no route" - Windows Update's
  # own downloader is a route whatever the content class, so the offer stays counted (the install loop decides what it
  # does with it). Only a routeless guest can verify 'none'.
  if ($script:HasDefaultRoute) { return 'wu-native' }   # a default route IS a route (Windows Update's own downloader), whatever the class
  return 'none'
}
# The offers THIS pass verified have no route (by Get-OfferRouteKey: the KB, or the exact title of an offer without one), and the ones it could not verify. Computed fresh on every call and
# written to the status as `unroutable` / `route_unknown`; nothing is carried from a previous pass.
function Measure-Unroutable($offers) {
  $none = @(); $unknown = @()
  foreach ($u in @($offers)) {
    if (-not $u) { continue }
    $route = Test-OfferRoute $u
    if ($route -eq 'none') { $k = Get-OfferRouteKey $u; $none += $k; Log ("  " + $k + " : " + (Get-NoRouteReason $k $u.content_class)) }
    elseif ($route -eq 'unknown') { $k = Get-OfferRouteKey $u; if ($k) { $unknown += $k } }   # a nameless offer is counted and named nowhere
  }
  return @{ none = @($none); unknown = @($unknown) }
}
# ---- WU-ROUTE-PROOF-END

# WHICH EFFECT PROBE answers for an update: by its fixed KB, else by the filename family of its content (ADR-updater section 6: keys and
# filename families, never titles). A probe measures the artefact the package actually changes; the agent's result is judged with it.
function Get-EffectProbe([string]$kb, [string[]]$names){
  $n = ($names -join ' ')
  if($kb -eq 'KB5007651' -or $n -match 'securityhealthsetup'){ return 'security-platform' }
  if($kb -eq 'KB890830'  -or $n -match 'kb890830'){ return 'mrt-version' }
  if($kb -eq 'KB4052623' -or $n -match 'updateplatform'){ return 'defender-platform' }
  if($kb -eq 'KB2267602' -or $n -match 'mpam|mpas|nis_full|am_delta|am_base|am_engine|mpsigstub'){ return 'defender-signature' }
  return $null
}

# ---- WU-COMOBJECT-BEGIN   (tools/tests/wu-agentcache-test.ps1 runs this region)
# A COM object the agent path needs - one place, so the offline tests can stand in fakes for it. A fresh Microsoft.Update.StringColl /
# UpdateColl is an EMPTY enumerable collection, and a function's return value is unrolled into the pipeline: 'return (New-Object ...)'
# handed every caller $null, and every agent-path install died at its first $coll.Add (rz38b, 2026-10-03, German 25H2 TemplateVM). The
# unary comma returns the collection itself.
function New-WuComObject([string]$progId){ return ,(New-Object -ComObject $progId) }   # GUARD:noenumerate
# ---- WU-COMOBJECT-END

# ---- WU-REGWATCH-BEGIN   (tools/tests/wu-effectsettle-test.ps1 runs this region)
# AN EFFECT CAN LAND AFTER THE AGENT'S INSTALLER RETURNS (measured 2026-10-03, w11de-tu38b): KB5007651's Install() returned ResultCode 2
# after 2 s, the platform read 1 s later was still the inbox one, and the platform had switched by the pass's rescan 10 s later. Run by
# us directly, the same installer only returned after the switch (8.4 s) - the agent returns before its worker is done. So where a row
# would otherwise FAIL, the pass waits for the artefact itself: a registry change notification on the probe's own key, armed BEFORE
# each read and re-read on every wake (the CBS settle's RegNotifyChangeKeyValue below), for at most $EffectSettleSec after the agent
# returned. An expiry never passes a row - only an observed effect does (Jev: mechanism 0.72, scope 0.92, 'never a timeout as a fix'
# complied 0.83, 60 s 0.55). MEASURED with this wait (w11de-val38c, 2026-10-03): the platform switched 2.8 s after the agent returned;
# every wait logs the latency it saw.
$EffectSettleSec = 60   # GUARD:settlebound
# The key each probe's artefact is recorded under (ADR-updater section 6: keys, never titles). $null = nothing to watch.
function Get-EffectWatchKey([string]$probe){
  switch($probe){
    'security-platform'  { return @{ rel='SOFTWARE\Microsoft\Windows Security Health'; subtree=$true } }   # Platform\CoreLocation, Updates\wu
    'defender-signature' { return @{ rel='SOFTWARE\Microsoft\Windows Defender\Signature Updates'; subtree=$false } }
    'defender-platform'  { return @{ rel='SOFTWARE\Microsoft\Windows Defender'; subtree=$false } }
    'mrt-version'        { return @{ rel='SOFTWARE\Microsoft\RemovalTools\MRT'; subtree=$false } }
  }
  return $null
}
# THE ROWS THE WAIT IS FOR: exactly the verdict's DISAGREEMENT rows (WU-AGENT-VERDICT, GUARD:agentdisagree) - the agent reports success,
# the probe ran, nothing moved, the artefact is not already current. Any other row is decided on its first read, without waiting.
function Test-EffectWouldFail([bool]$agentOk, [string]$probe, [bool]$probeRan, [bool]$eff, [bool]$alreadyCurrent, [bool]$platBehind, [bool]$sigBehind){
  return [bool]($agentOk -and $probe -and $probeRan -and -not $eff -and -not $alreadyCurrent -and
    (($probe -eq 'security-platform') -or ($probe -eq 'defender-platform' -and $platBehind) -or ($probe -eq 'defender-signature' -and $sigBehind)))   # GUARD:settlewhen
}
function Start-RegistryWatch([string]$rel, [bool]$subtree){
  $w = [pscustomobject]@{ armed=$false; why=''; key=$null; ev=$null }
  try {
    if(-not ('CbsRegNotify' -as [type])){
      Add-Type @'
using System; using System.Runtime.InteropServices;
public static class CbsRegNotify {
    [DllImport("advapi32.dll")]
    public static extern int RegNotifyChangeKeyValue(IntPtr hKey, bool bWatchSubtree, uint dwNotifyFilter, IntPtr hEvent, bool fAsynchronous);
}
'@
    }
    $w.key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($rel, [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadSubTree,
               ([System.Security.AccessControl.RegistryRights]::Notify -bor [System.Security.AccessControl.RegistryRights]::ReadKey))
    if(-not $w.key){ $w.why = "HKLM\$rel cannot be opened"; return $w }
    $w.ev = New-Object System.Threading.ManualResetEvent($false)
    # 0x1 REG_NOTIFY_CHANGE_NAME (a subkey added or removed) | 0x4 REG_NOTIFY_CHANGE_LAST_SET (a value written) | 0x10000000 THREAD_AGNOSTIC
    $rc = [CbsRegNotify]::RegNotifyChangeKeyValue($w.key.Handle.DangerousGetHandle(), $subtree, 0x10000005, $w.ev.SafeWaitHandle.DangerousGetHandle(), $true)
    if($rc -ne 0){ $w.why = "RegNotifyChangeKeyValue rc=$rc"; return $w }
    $w.armed = $true
  } catch { $w.why = ($_.Exception.Message -replace '\s+',' ') }
  return $w
}
function Wait-RegistryWatch($w, [int]$ms){ if($w -and $w.armed){ return [bool]$w.ev.WaitOne([Math]::Max(0,$ms)) }; return $false }
function Stop-RegistryWatch($w){ if($w){ try { if($w.ev){ $w.ev.Dispose() } } catch {}; try { if($w.key){ $w.key.Dispose() } } catch {} } }
# ---- WU-REGWATCH-END

# THE LIVE IUpdate FOR AN OFFER ROW: from this pass's search (Get-Available keeps them), else from a FRESH search - never guessed. The agent
# installs only what it offered; an update a fresh search no longer offers is reported as such.
function Get-LiveUpdate($u){
  foreach($try in 1,2){
    if($script:LiveUpdates){
      if($u.uid -and $script:LiveUpdates.ContainsKey([string]$u.uid)){ return $script:LiveUpdates[[string]$u.uid] }
      if(([string]$u.kb) -match '^KB\d+' -and $script:LiveUpdates.ContainsKey([string]$u.kb)){ return $script:LiveUpdates[[string]$u.kb] }
    }
    if($try -eq 1){
      Log "  $($u.kb): no live update object from this pass's search - searching again"
      try { Get-Available | Out-Null } catch { Log "  fresh search failed: $($_.Exception.Message)"; return $null }
    }
  }
  return $null
}

# INSTALLER-TYPE UPDATES ARE INSTALLED BY THE WINDOWS UPDATE AGENT'S OWN INSTALLER, FROM CONTENT WE SUPPLY. The owner's rule (2026-10-03):
# a vendor installer is never run with a switch we chose, and its payload is never carved, repacked or provisioned by us. Until 2026-10-03
# this updater ran the fetched .exe itself with '/q' (a no-op for securityhealthsetup.exe - KB5007651 silently failed every pass from
# 2026-09-20), resolved and ran the Defender full package itself, and carved KB5007651's app packages out of its installer; all of that is
# gone. Mechanism (Jev 1.00), measured 2026-10-03 on the German 25H2 template on four offered updates, all succeeding by effect: the
# needed leaves' content is fetched through the relay (Fetch-Msu), handed to the agent with IUpdate2.CopyToCache (the update then reads
# IsDownloaded), and IUpdateInstaller.Install runs it - the agent runs each package with the update's OWN command line (KB5007651: no
# switch, ResultCode 2 in 2 s, the platform moved; KB2267602: MpSigStub's /payload chain, four leaves incl. a 204 MB base, ResultCode 2
# in 26 s, signatures and engine moved; KB890830: '/Q /W', ResultCode 2 in 126 s, MRT version set; KB4052623: ResultCode 2 in 45 s).
# The agent's DOWNLOADER is never called: routeless it goes to BITS and hung for 30 minutes. CopyToCache with an EMPTY list throws
# E_INVALIDARG. The COM object's IsInstalled stays stale after Install: the verdict is the agent's result codes AND our effect probes
# (Jev 0.72), never a re-read of it. One row per update, in the shape dom0's handler and the exclusion audit read.
function Install-ViaAgentCache($u){
  $kb = [string]$u.kb
  $label = if($kb -match '^KB\d+'){ $kb } elseif($u.title){ [string]$u.title } else { 'untitled offer' }
  $dir = Join-Path $WorkDir ("wu-agent\" + ($label -replace '[^A-Za-z0-9._-]','_'))
  New-Item -ItemType Directory -Force $dir | Out-Null
  $update = Get-LiveUpdate $u
  if(-not $update){
    Log "  $label : not offered by a fresh search - nothing for the agent to install"
    return [ordered]@{ kb=$label; ok=$false; state='failed'; files=@(); reason='Windows Update no longer offers this update (a fresh search in this pass found no live object for it) - nothing was installed' }
  }
  $session = $script:WuSession
  try { if(-not $update.EulaAccepted){ $update.AcceptEula() } } catch {}
  $lv = Get-WuNeededLeaves $update
  $leafNames = @($lv.urls | ForEach-Object { if($_ -match '/([^/?]+)(\?|$)'){ $Matches[1] } })
  $probe = Get-EffectProbe $kb $leafNames
  Log ("  $label : $($lv.needed.Count) needed leaf/leaves, $($lv.urls.Count) static file(s)" + $(if($probe){ ", effect probe $probe" } else { ', no effect probe' }))
  # ---- the artefact BEFORE the install, per probe
  $sigBefore=''; $mrtBefore=''; $platBefore=''; $platDirsBefore=@(); $secBefore=$null; $appBefore=''
  if($probe -eq 'defender-signature'){ try{ $sigBefore=[string](Get-MpComputerStatus).AntivirusSignatureVersion }catch{} }
  if($probe -eq 'defender-platform'){
    try{ $platBefore=[string](Get-MpComputerStatus).AMProductVersion }catch{}
    try{ $platDirsBefore = @(Get-ChildItem -LiteralPath 'C:\ProgramData\Microsoft\Windows Defender\Platform' -Directory -EA Stop | ForEach-Object { $_.Name }) }catch{}
  }
  if($probe -eq 'mrt-version'){ try{ $mrtBefore=[string](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\RemovalTools\MRT' -Name Version -EA SilentlyContinue).Version }catch{} }
  if($probe -eq 'security-platform'){
    # THE WINDOWS SECURITY PLATFORM (KB5007651): the artefact its installer changes is the PLATFORM (Get-SecurityPlatformState). Two
    # earlier probes read the wrong artefact (ADR-updater section 3): SecurityHealthService.exe (2026-09-20; it never changes) and the
    # SecHealthUI app (2026-09-21; it follows the platform about 41 s AFTER the installer returns, and a fallback of this updater's own
    # used to provision it, which made the item read ALREADY CURRENT over an uninstalled platform - rz35, 2026-10-03). The app is read
    # for the LOG only and decides nothing.
    $secBefore = Get-SecurityPlatformState
    try{ $pkB=Get-AppxPackage -AllUsers -Name Microsoft.SecHealthUI -EA SilentlyContinue | Select-Object -First 1; if($pkB){ $appBefore=[string]$pkB.Version } }catch{}
  }
  # ---- WU-AGENT-INSTALL-BEGIN   (tools/tests/wu-agentcache-test.ps1 runs this region with fake agent objects)
  $files=@(); $missing=@()
  foreach($leaf in $lv.needed){
    if($leaf.Bad.Count -gt 0){ $missing += "$($leaf.Title): no static content ($($leaf.Bad -join ', '))"; continue }
    $coll = New-WuComObject 'Microsoft.Update.StringColl'
    foreach($url in $leaf.Urls){
      $name = if($url -match '/([^/?]+)(\?|$)'){ $Matches[1] } else { 'content.bin' }
      $dst = Join-Path $dir $name
      if(Fetch-Msu $url $dst $label){
        [void]$coll.Add($dst)
        $files += [ordered]@{ file=$name; bytes=(Get-Item -LiteralPath $dst).Length; leaf=$leaf.Title }
      } else {
        $missing += "$($leaf.Title): fetch failed ($name)"
        $files += [ordered]@{ file=$name; bytes=0; leaf=$leaf.Title; rc='fetch-failed' }
      }
    }
    if($coll.Count -eq 0){ continue }   # GUARD:emptycache - CopyToCache with no files throws E_INVALIDARG (measured 2026-10-03)
    try { $leaf.Update.CopyToCache($coll); Log ("    $($leaf.Title): $($coll.Count) file(s) handed to the agent's cache") }
    catch { $missing += "$($leaf.Title): CopyToCache failed ($($_.Exception.Message -replace '\s+',' '))" }
  }
  $downloaded=$false; try{ $downloaded=[bool]$update.IsDownloaded }catch{}
  $agentRc=$null; $agentHr=$null; $agentErr=$null; $reboot=$false
  if(-not $downloaded){   # GUARD:nodownloader - the agent's downloader is NEVER called here (routeless it goes to BITS and hangs)
    Log ("  $label : NOT downloaded after CopyToCache - not installing; missing: " + $(if($missing.Count){ $missing -join '; ' } else { 'nothing named - the agent did not accept the cached content' }))
  } else {
    $installer = $session.CreateUpdateInstaller()
    $one = New-WuComObject 'Microsoft.Update.UpdateColl'; [void]$one.Add($update); $installer.Updates = $one
    $script:St.installing = [ordered]@{ kb=$label; via='agent' }; Save
    $t0 = Get-Date
    try {
      $res = $installer.Install(); $ur = $res.GetUpdateResult(0)
      $agentRc=[int]$ur.ResultCode; $agentHr=[int]$ur.HResult; $reboot=[bool]$res.RebootRequired
      Log ("  $label : agent installer ResultCode=$agentRc HResult=0x{0:X8} RebootRequired=$reboot in {1} s" -f $agentHr, [int]((Get-Date) - $t0).TotalSeconds)
    } catch { $agentErr = ($_.Exception.Message -replace '\s+',' '); $agentRc = 4; Log ("  $label : agent installer THREW: $agentErr") }
    $script:St.installing = $null
  }
  # ---- WU-AGENT-INSTALL-END
  $agentOk = ($null -ne $agentRc) -and ($agentRc -in @(2,3))
  # ---- WU-EFFECT-SETTLE-BEGIN   (tools/tests/wu-effectsettle-test.ps1 runs this region; WU-REGWATCH says why)
  # The artefact is read; a row that would otherwise FAIL waits for it to move - armed before every read, re-read on every wake, never
  # past $EffectSettleSec after the agent returned. The reads below are the probes' own regions, unchanged, on every turn of this loop.
  $settleKey = Get-EffectWatchKey $probe
  $settleAt = Get-Date; $settleUntil = $settleAt.AddSeconds($EffectSettleSec); $settleWaited = $false
  while($true){
    $watch = $null
    if($agentOk -and $settleKey){ $watch = Start-RegistryWatch $settleKey.rel $settleKey.subtree }   # GUARD:settlearm - BEFORE the read
    try {
  # ---- WU-EFFECT-SETTLE-READ-BEGIN
  # ---- the artefact AFTER the install, per probe: $eff = it moved, $probeRan = it could be read, $alreadyCurrent / *Behind = its
  # comparison with the dotted quad in the offer's own title (digits are language-free, ADR-updater section 6)
  $eff=$false; $probeRan=$true; $alreadyCurrent=$false; $platBehind=$false; $sigBehind=$false; $secWhy=$null
  $offered = $null
  try { if(([string]$u.title) -match '(\d+\.\d+\.\d+\.\d+)'){ $offered = $Matches[1] } } catch {}
  if($probe -eq 'mrt-version'){
    $mrtAfter=''; try{ $mrtAfter=[string](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\RemovalTools\MRT' -Name Version -EA SilentlyContinue).Version }catch{}
    if(-not $mrtBefore -and -not $mrtAfter){ $probeRan=$false } else { $eff = ($mrtAfter -ne $mrtBefore); Log ("    MRT version $mrtBefore -> $mrtAfter") }
  }
  if($probe -eq 'defender-signature'){
    $sigAfter=''; try{ $sigAfter=[string](Get-MpComputerStatus).AntivirusSignatureVersion }catch{}
    if(-not $sigBefore -and -not $sigAfter){ $probeRan=$false }
    else {
      $eff = ($sigAfter -ne $sigBefore)
      # ---- WU-DEFENDER-SIGNATURE-BEGIN   (tools/tests/wu-agentcache-test.ps1 runs this region)
      # The offer states the version it carries in its own title ("(Version 1.459.317.0)"); Get-MpComputerStatus states the installed
      # one. Nothing moved and at or past the offer = ALREADY CURRENT (what a second pass sees). Nothing moved and BELOW the offer after
      # an agent success = a disagreement the verdict fails loudly. No version in the offer = nothing to compare.
      if($eff){ Log ("    signature $sigBefore -> $sigAfter") }
      elseif($offered -and $sigAfter){
        try {
          if([version]$sigAfter -ge [version]$offered){ $alreadyCurrent = $true; Log ("    signature $sigAfter is already at or past the offered $offered - nothing to do") }
          else {
            $sigBehind = $true   # GUARD:sigbehind
            Log ("    signature $sigAfter is BEHIND the offered $offered and nothing moved")
          }
        } catch { Log ("    could not compare signature versions ('$sigAfter' vs '$offered')") }
      } else { Log ("    signature stayed at $sigAfter; the offer names no version to compare") }
      # ---- WU-DEFENDER-SIGNATURE-END
    }
  }
# ---- WU-DEFENDER-PLATFORM-BEGIN   (tools/tests/wu-defplatform-test.ps1 runs this region)
      # THE DEFENDER ANTIMALWARE PLATFORM (KB4052623, updateplatform.amd64fre_*.exe) was counted from its exit code alone - "probe=none
      # (ok from rc only)" - and the exclusion audit, rightly, would not accept dom0's silence about an item nothing had verified: it
      # failed the rz35 release gate's template-update test on exactly this row (2026-10-03; Jev: product effect probe 0.92). The
      # effect IS measurable: the installer stages the new platform under ...\Windows Defender\Platform\<version>*, and Defender reports
      # the platform it runs as AMProductVersion (which may only move once its service restarts - so the staged folder counts too).
      # The offered version is the dotted quad in the offer's own title, as for the signatures below (language-independent).
      # BEHIND = the agent reported success, nothing moved, nothing new was staged and the platform is still below the offered version: a
      # FAILED install (a disagreement), decided in WU-AGENT-VERDICT. Never 'informational' - that reason says the offered version cannot
      # be established, which here it can (ADR-updater section 3: the negative of a probe that ran is a result, not a missing one).
      $platBehind = $false
      if($probe -eq 'defender-platform'){
        $platOffered = $null
        try {
          $platOff = @($script:St.available | Where-Object { $_.kb -eq $kb } | Select-Object -First 1)
          if($platOff -and $platOff[0].title -match '(\d+\.\d+\.\d+\.\d+)'){ $platOffered = $Matches[1] }
        } catch {}
        $platAfter=''; try{ $platAfter=[string](Get-MpComputerStatus).AMProductVersion }catch{}
        # STAGED = a folder for the offered version that was NOT there before this installer ran. A folder that already existed is the
        # platform already in place (handled as already-current below), never an effect of this run.
        $platStaged = $false
        if($platOffered){
          try { $platStaged = @(Get-ChildItem -LiteralPath 'C:\ProgramData\Microsoft\Windows Defender\Platform' -Directory -EA Stop |
                                Where-Object { $_.Name -like "$platOffered*" -and $platDirsBefore -notcontains $_.Name }).Count -gt 0 } catch {}
        }
        if(-not $platBefore -and -not $platAfter -and -not $platStaged -and -not $platDirsBefore.Count){ $probeRan = $false }   # nothing readable: unknown
        else {
          if(($platAfter -and $platBefore -and $platAfter -ne $platBefore) -or $platStaged){ $eff = $true }   # GUARD:defplatform
          if($eff){ Log ("    defender platform $platBefore -> $platAfter" + $(if($platStaged){ " (the offered $platOffered is staged on disk)" } else { '' })) }
          elseif($agentOk -and $platOffered -and $platAfter){
            try {
              if([version]$platAfter -ge [version]$platOffered){
                $alreadyCurrent = $true
                Log ("    defender platform $platAfter is already at or past the offered $platOffered - nothing to do")
              } else {
                # PENDING, not behind: the offered version's folder was already on disk before this installer ran AND was created in
                # THIS boot - an earlier pass of this boot staged it (and verified that) and the service has not switched yet. A folder
                # older than this boot that the service still does not run is a switch that never happened: a failed install.
                $platPending = $null
                try {
                  $bootAt = (Get-CimInstance Win32_OperatingSystem -EA Stop).LastBootUpTime
                  $platPending = @(Get-ChildItem -LiteralPath 'C:\ProgramData\Microsoft\Windows Defender\Platform' -Directory -EA Stop |
                                   Where-Object { $_.Name -like "$platOffered*" -and $_.CreationTime -ge $bootAt } | ForEach-Object { $_.Name }) |
                                   Select-Object -First 1
                } catch {}
                if($platPending){
                  $eff = $true   # GUARD:platpending
                  Log ("    defender platform ${platAfter}: the offered $platOffered is staged on disk since this boot ($platPending) and the service has not switched yet")
                } else {
                  $platBehind = $true   # GUARD:platbehind
                  Log ("    defender platform $platAfter is BEHIND the offered $platOffered, nothing moved and nothing was staged")
                }
              }
            } catch { Log ("    could not compare platform versions ('$platAfter' vs '$platOffered')") }
          }
        }
      }
# ---- WU-DEFENDER-PLATFORM-END
# ---- WU-SECURITY-PLATFORM-BEGIN   (tools/tests/wu-secplatform-test.ps1 runs this region)
      # THE WINDOWS SECURITY PLATFORM (KB5007651) is decided by the PLATFORM - Get-SecurityPlatformState before and after the run (the
      # CoreLocation folder's version, Updates\wu, the host's FileVersion) against the dotted quad in the offer's own title (digits are
      # language-free, ADR section 6), like the Defender platform above. Measured 2026-10-03 on the German 25H2 template (two fresh
      # clones and the rz35 subject): the no-argument run moves CoreLocation from System32 to ...\SecurityHealth\10.0.29628.1000-0 and
      # writes Updates\wu=10.0.29628.1000. CORRECTED 2026-10-03: this said "before the launcher returns" - true when WE ran the launcher
      # (it returned after the switch, 8.4 s), FALSE through the agent's installer, whose Install() returns after 2 s with the switch still
      # to come (rz38b validation: inbox 1 s after, switched by 10 s) - WU-EFFECT-SETTLE waits for it. Windows Update then STOPS offering
      # KB5007651; the SecHealthUI
      # app follows about 41 s later and is information only - it decided this item until 2026-10-03 and read ALREADY CURRENT over an
      # uninstalled platform. MOVED to or past the offer = installed (eff). NOT moved and at or past the offer = ALREADY CURRENT.
      # Anything else = a FAILED install, decided in WU-AGENT-VERDICT (the owner's rule, 2026-10-03). The install itself is the
      # agent's (Install-ViaAgentCache); nothing here installs, carves or provisions any part of the payload.
      $secWhy = $null
      if($probe -eq 'security-platform'){
        $secOffered = $null
        try {
          $secOff = @($script:St.available | Where-Object { $_.kb -eq $kb } | Select-Object -First 1)
          if($secOff -and $secOff[0].title -match '(\d+\.\d+\.\d+\.\d+)'){ $secOffered = $Matches[1] }
        } catch {}
        $secAfter = Get-SecurityPlatformState
        if(-not ($secBefore.readable -and $secAfter.readable)){
          $probeRan = $false   # GUARD:secunreadable
          Log ("    security platform: CoreLocation could not be read (before: $($secBefore.text); after: $($secAfter.text)) - the probe did not run")
        } else {
          $appAfter = ''; try{ $pkA=Get-AppxPackage -AllUsers -Name Microsoft.SecHealthUI -EA SilentlyContinue | Select-Object -First 1; if($pkA){ $appAfter=[string]$pkA.Version } }catch{}
          $secMoved = ($secAfter.loc -ne $secBefore.loc) -or ([string]$secAfter.wu -ne [string]$secBefore.wu) -or ([string]$secAfter.host -ne [string]$secBefore.host)
          $secAtOffer = $null   # $true / $false, or $null when the offer or the platform has no version to compare
          if($secOffered -and $secAfter.cmp){ try { $secAtOffer = ([version]$secAfter.cmp -ge [version]$secOffered) } catch {} }
          if($secMoved -and $secAtOffer -ne $false){ $eff = $true }   # GUARD:secplatform
          if(-not $secMoved -and $secAtOffer -eq $true -and $agentOk){ $alreadyCurrent = $true }   # GUARD:seccurrent
          $secState = "$($secBefore.text) -> $($secAfter.text)" + $(if($secOffered){ " (offered $secOffered)" } else { ' (the offer names no version)' })
          if($eff){ Log ("    security platform moved: $secState") }
          elseif($alreadyCurrent){ Log ("    security platform $($secAfter.cmp) is already at or past the offered $secOffered - nothing to do ($secState)") }
          else {
            $secAt = if($secAfter.ver){ $secAfter.ver } elseif($secAfter.cmp){ "the inbox platform $($secAfter.cmp)" } else { 'the inbox platform (version unreadable)' }
            $secWhy = "$(if($secMoved){ 'moved only to' } else { 'stayed at' }) $secAt" +
                      $(if($secAtOffer -eq $false){ ", below the offered $secOffered" }
                        elseif($secAtOffer -eq $true){ ", at the offered $secOffered, but the agent reported ResultCode $agentRc" }
                        elseif(-not $secOffered){ "; the offer names no version, so 'already current' cannot be established" }
                        else { "; no version to compare with the offered $secOffered" })
            Log ("    security platform $secWhy ($secState)")
          }
          Log ("    SecHealthUI app $appBefore -> $appAfter - information only: the app follows the platform asynchronously and is not this item's effect")   # GUARD:appnoteffect
        }
      }
# ---- WU-SECURITY-PLATFORM-END
  # ---- WU-EFFECT-SETTLE-READ-END
      if(-not (Test-EffectWouldFail $agentOk $probe $probeRan $eff $alreadyCurrent $platBehind $sigBehind)){
        if($settleWaited){ Log ("    $probe artefact " + $(if($eff){ 'moved' } else { 'settled' }) + (" {0:N1} s after the agent returned" -f ((Get-Date) - $settleAt).TotalSeconds)) }
        break
      }
      if(-not $settleKey){ break }   # no artefact key to watch: the read above decides
      if(-not $watch.armed){   # GUARD:settleunarmed - the instrument is missing: loud, and the read above decides (never a poll in its place)
        Log ("  [ERROR] $label : the $probe effect wait could not be armed on HKLM\$($settleKey.rel) ($($watch.why)) - the row is decided on the read above")
        break
      }
      $ms = [int][Math]::Floor(($settleUntil - (Get-Date)).TotalMilliseconds)
      if($ms -le 0){   # GUARD:settledeadline - the expiry decides nothing: the read above (taken after it) stands
        Log ("    $probe artefact did not move within $EffectSettleSec s of the agent returning - the read above decides")
        break
      }
      if(-not $settleWaited){ Log ("    the agent reports success but the $probe artefact has not moved - waiting for it (registry notification on HKLM\$($settleKey.rel), at most $EffectSettleSec s)"); $settleWaited = $true }
      [void](Wait-RegistryWatch $watch $ms)   # GUARD:settlewait - a wake or the deadline: either way the artefact is read again
    } finally { Stop-RegistryWatch $watch }
  }
  # ---- WU-EFFECT-SETTLE-END
  # ---- WU-AGENT-VERDICT-BEGIN   (tools/tests/wu-agentcache-test.ps1, wu-defplatform-test.ps1 and wu-secplatform-test.ps1 run this region)
  # THE ROW IS DECIDED BY THE AGENT'S RESULT AND OUR EFFECT PROBE TOGETHER (Jev 0.72, 2026-10-03). ResultCode 2 = succeeded, 3 = succeeded
  # with errors, 4 = failed, 5 = aborted; $null = the agent was never asked, because the update was not downloaded after CopyToCache.
  # ALREADY CURRENT is only ever the probe's own comparison with the offer (KB5007651: the PLATFORM at or past the offer, Jev 0.98). A
  # probe that ran, saw nothing move and finds the artefact BELOW the offer overrules an agent success - loudly, as a DISAGREEMENT - and
  # for KB5007651 anything but moved-or-current is a failed install (the owner's rule). No probe, or a probe whose artefact could not be
  # read: the agent's result stands and the row says probe=none / DID NOT RUN, never implying verification.
  $sev=$null; $ok=$false; $state='failed'; $reason=$null
  $hr = if($null -ne $agentHr){ ('0x{0:X8}' -f $agentHr) } else { '' }
  if($null -eq $agentRc){   # GUARD:notdownloadedfails - the row names what is missing; the downloader is not the answer
    $reason = "not downloaded after CopyToCache, so the agent was not asked to install (its downloader is never called on this path); missing: " + $(if($missing.Count){ $missing -join '; ' } else { 'nothing named - the agent did not accept the cached content' })
  } elseif(-not $agentOk){   # GUARD:agentfailed
    $reason = "the Windows Update agent's installer FAILED this update: ResultCode=$agentRc HResult=$hr" + $(if($agentErr){ " ($agentErr)" } else { '' })
  } elseif($probe -and $probeRan -and -not $eff){
    if($alreadyCurrent){   # GUARD:agentcurrent
      $ok=$true; $state='installed'
      $reason = "the agent reports ResultCode=$agentRc and the $probe artefact is already at or past the version this offer carries - nothing to do"
    } elseif(($probe -eq 'security-platform') -or ($probe -eq 'defender-platform' -and $platBehind) -or ($probe -eq 'defender-signature' -and $sigBehind)){   # GUARD:agentdisagree
      $reason = "DISAGREEMENT: the agent reports ResultCode=$agentRc but the $probe artefact " + $(if($secWhy){ $secWhy } else { 'did not move and is below the version this offer carries' }) + " - this update did NOT install"
    } else {
      $ok=$true; $state='installed'
      $reason = "the agent reports ResultCode=$agentRc; the $probe artefact did not move and there is no offered version to compare it with - the agent's result stands, the effect is NOT verified"
    }
  } else {
    $ok=$true; $state=$(if($reboot){ 'staged' } else { 'installed' })
    $reason = "installed by the Windows Update agent's own installer from content supplied with CopyToCache: ResultCode=$agentRc" +
              $(if($probe -and $probeRan){ " (verified by effect: $probe)" } elseif($probe){ " (probe=$probe DID NOT RUN - artefact unreadable; ok from the agent's result)" } else { ' (probe=none; ok from the agent''s result)' })
  }
  if($reboot){ $script:St.reboot_needed = $true }
  Log ("  $label : " + $(if($ok){ $state.ToUpper() } else { 'FAILED' }) + " - $reason")
  # ---- WU-AGENT-VERDICT-END
  # Reclaim the fetched content only once the agent has installed it (its cache holds its own copy); a failed install keeps the files so
  # the next pass resumes instead of re-fetching 200 MB.
  if($ok){ foreach($f in $files){ Remove-Item -LiteralPath (Join-Path $dir $f.file) -Force -EA SilentlyContinue } }
  # The per-file rows carry the verdict fields the exclusion audit and the evidence builder read (severity / verified_by_effect / probe /
  # already_current / info_reason), as the per-file rows of the old .exe path did; the row carries them too for a leafless install.
  $rows = @()
  foreach($f in $files){ $rows += [ordered]@{ kb=$label; file=$f.file; bytes=$f.bytes; leaf=$f.leaf; rc=$(if($f.rc){ $f.rc } else { $agentRc }); ok=$ok; verified_by_effect=[bool]$eff; probe=$probe; severity=$sev; info_reason=$reason; already_current=[bool]$alreadyCurrent } }
  return [ordered]@{ kb=$label; ok=$ok; state=$state; files=@($rows); rc=$agentRc; hresult=$(if($hr){ $hr } else { $null }); verified_by_effect=[bool]$eff; probe=$probe; already_current=[bool]$alreadyCurrent; severity=$sev; reason=$reason }
}

# ---- WU-INSTALL-MSUS-BEGIN   (tools/tests/wu-cumulative-order-test.ps1 runs this function with DISM, the settle and the package list stood in)
function Install-Msus($files){
  $reboot=$false; $rows=@(); $cumRow=$null; $cumBefore=$null; $cumFile=''; $cumRc=$null
  foreach($f in (Order-Msus $files)){
    $name = [IO.Path]::GetFileName($f)
    $pi = Get-MsuInfo $f
    $kind = Get-MsuKindFromIdentity ([string]$pi.identity)
    Log "  $name applicable=$($pi.applicable) state=$($pi.state) id=$($pi.identity) kind=$kind"
    if($pi.applicable -eq 'No'){
      # SKIPPED, not failed: this package was never meant for this image. Recording it as a
      # failure is what made a whole KB look broken when only a catalog sibling was irrelevant.
      $rows += [ordered]@{ file=$name; rc='skipped'; why="not applicable to this image" }
      continue
    }
    if($pi.state -eq 'Installed'){
      $rows += [ordered]@{ file=$name; rc='skipped'; why="already installed" }
      continue
    }
    # ONE REBOOT-REQUIRING PACKAGE PER SERVICING SESSION - WITH ONE RELAXATION.
    #
    # Measured 2026-08-14 on a pristine 26100.8875 clone: the pass staged KB5120710 (rc=3010) and
    # then KB5121003 (rc=3010) without a reboot in between. After the reboot KB5120710 was
    # state=112 Installed and KB5121003 had ZERO CBS package entries - never registered, no
    # rollback logged, shutdown 77 s instead of the 6.3 min a real apply takes. CBS applied the
    # first staged package and silently discarded the second, while DISM returned 3010 for both.
    # The 11:47 success is the control: it installed the cumulative ALONE on an image where the
    # .NET update was already installed AND rebooted.
    #
    # So once something is staged, stop. The remaining packages stay on disk and the next pass -
    # after the reboot this one forces - picks them up. Slower, and the only way the second package
    # actually lands.
    #
    # THE RELAXATION (2026-10-04, ADR-updater section 13), measured on the reporter's German 25H2 template with this rule lifted
    # (QUBES_UPDATES_ALLOW_MULTISTAGE=1): the package that gets lost behind a stage is the CUMULATIVE (its bundled servicing stack must
    # install online first), while the cumulative FIRST and .NET second both landed at one restart. So a package that is NOT itself a
    # cumulative may stage behind a cumulative THIS pass staged and Windows REGISTERED (the check below). A second cumulative is still
    # deferred; with no registered cumulative the rule stands.
    if ($script:StagedThisSession -and -not $env:QUBES_UPDATES_ALLOW_MULTISTAGE) {
      if ($kind -eq 'cumulative' -or -not $script:CumulativeRegisteredThisSession) {   # GUARD:stagebehindcumulative
        $why = if ($kind -eq 'cumulative') { 'another package is already staged this pass and this one is a cumulative (it carries a servicing stack, which must install online before anything is pending); installing it needs a reboot first' }
               else { 'another package is already staged; installing it needs a reboot first' }
        $rows += [ordered]@{ file=$name; rc='deferred'; why=$why }
        Log "  DEFER $name - $why"
        continue
      }
      Log "  $name : staging behind the cumulative this pass staged and Windows registered (measured 2026-10-04: both land at the one restart)"
    }
    # THE BASELINE FOR THE REGISTRATION CHECK, read BEFORE the DISM call - a RollupFix package already pending now is not this call's.
    if ($kind -eq 'cumulative') { $cumBefore = Get-CbsPackageStates }   # GUARD:regbefore
    $script:St.installing=[ordered]@{ file=$name; state='running' }; Save
    $rc = Add-PackageCompat $f
    if($rc -eq 3010){ $reboot=$true; $script:StagedThisSession = $true }
    # Re-ask DISM what the package's state is NOW. rc=3010 only means "staged"; the state tells us
    # whether CBS actually took it, which is the thing that was silently false before. For the combined cumulative it tells nothing
    # (measured 2026-10-04: 'Not Present' whether the rollup later lands or is dropped) - the package list after the settle decides.
    $after = Get-MsuInfo $f
    $row = [ordered]@{ file=$name; rc=$rc; state_after=$after.state; kind=$kind }
    # ARMED ON BOTH OUTCOMES, not only 3010. Until 2026-11-08 this read `-and $rc -eq 3010`, so a
    # cumulative DISM APPLIED IN PLACE (rc=0) left $cumRow null, skipped the registration check
    # entirely, and was reported installed on DISM's exit code alone - exactly what ADR-updater 3
    # forbids, and the same shape as the 2026-08-14 incident this region was built for. $cumBefore
    # was already being captured for any cumulative on the line above and then thrown away.
    # 0 and 3010 ONLY, never all of $OK_RC: its third member 2359302 is ALREADY INSTALLED (and this
    # file treats it as staged at the cab loop above), so nothing new appears in the package list for
    # it - arming the check there would look for a newly Installed RollupFix, find none, and FAIL a
    # cumulative that was already on the machine. A false red is not a better lie than the old one.
    if($kind -eq 'cumulative' -and $rc -in @(0, 3010)){ $cumRow = $row; $cumFile = $name; $cumRc = $rc }
    $rows += $row
    Log "  DISM $name rc=$rc state_after=$($after.state)"
  }
  # STICKY, never assigned: Install-Msus runs once per KB, so assigning would let a later KB
  # that needs no reboot erase an earlier one that does. Measured 2026-08-13 on the template:
  # KB5120710 returned 3010 (reboot required), KB5121003 then returned 0, and the pass ended
  # claiming reboot_needed=false while Windows had CBS RebootPending set.
  if ($reboot) { $script:St.reboot_needed = $true }
  if ($reboot -or $cumRow) { Wait-CbsSettle }   # a cumulative applied in place still has TiWorker finishing behind it
  # THE REGISTRATION CHECK, after the settle (TiWorker idle): was the cumulative DISM accepted actually registered by Windows? A row
  # that was not is NOT staged, whatever rc=3010 says - it will not complete at the restart, and dom0 is never told it will
  # (Get-MsuKbVerdict fails the KB on it). The restart is requested either way: it is what clears the state that blocked the
  # registration, and the pass after it retries the package, which stays on disk.
  if ($cumRow) {
    # WHICH STATE PROVES IT DEPENDS ON WHAT DISM DID, and that is why rc=0 could not simply be
    # added to the arming condition above. rc=3010 means CBS took the package for the next boot, so
    # the proof is a RollupFix package that is NEWLY InstallPending. rc=0 means DISM applied it in
    # place, and such a package is never InstallPending - it is Installed (measured in this region's
    # own header: 9457 'InstallPending' after the call, 'Installed' after the restart). Asking for
    # InstallPending on the rc=0 path would therefore have FAILED every cumulative that really
    # landed, which is a worse lie than the one being fixed.
    $cumWant = if ($cumRc -eq 3010) { 'InstallPending' } else { 'Installed' }
    $cumAfter = Get-CbsPackageStates
    $reg = Test-RollupRegistered $cumBefore $cumAfter $cumWant
    if ($reg.ok) {
      $script:CumulativeRegisteredThisSession = $true   # GUARD:registeredrelaxes - the only thing that lets a later package stage this pass
      $cumRow.registered = $true
      Log "  REGISTERED $cumFile - $($reg.why)"
    } elseif ($reg.known) {
      $cumRow.registered = $false
      $cumRow.why = if ($cumRc -eq 3010) {
        "DISM accepted $cumFile (rc=3010; the cumulative) but Windows did NOT register it: $($reg.why). It is NOT staged and will not complete at a restart; this pass requests the restart that clears the state which blocked it, and the pass after the restart retries this package"
      } else {
        "DISM reported $cumFile applied (rc=0; the cumulative) but no RollupFix package is newly Installed: $($reg.why). rc=0 is not proof it landed, so this is NOT reported as installed and the next pass retries this package, which stays on disk"
      }
      Log "  [ERROR] $($cumRow.why)"
    } else {
      $cumRow.registered = 'unknown'   # GUARD:unreadablefails - missing data fails: not reported as staged
      $cumRow.why = "DISM returned rc=$cumRc for $cumFile (the cumulative) but whether Windows registered it is UNKNOWN: $($reg.why). NOT reported as staged or installed; the next pass retries this package if Windows did not take it"
      Log "  [ERROR] $($cumRow.why)"
    }
  }
  return $rows
}
# ---- WU-INSTALL-MSUS-END

function Wait-CbsSettle {
  # SETTLE BEFORE DECLARING ANYTHING. DISM returning 3010 does NOT mean CBS has finished
  # registering the package: TiWorker keeps working after the exit code. Measured 2026-08-14 - the
  # pass reported done, the qube shut down 22 s later, the shutdown took 77 s where a real apply
  # takes 6.3 min, and the cumulative ended with ZERO CBS entries. A staged package that has not
  # reached "reboot pending" is not staged yet, and rebooting there loses it.
  #
  # NOTE this is also the test that decides WHY it was lost. Windows aggregates many packages per
  # reboot routinely, so "CBS only applies one staged package" is a weak claim on one observation.
  # If RebootPending appears here and the package is still discarded at boot, the aggregation story
  # is real; if RebootPending never appears, the loss was this race and serialising was treating a
  # symptom.
  # Its own function since 2026-10-04 so the offline test can stand it in; the body is unchanged. Called only after a stage (rc=3010).
    $cbsRel = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing'
    $rp = "HKLM:\$cbsRel\RebootPending"
    $deadline = (Get-Date).AddMinutes(10)
    # PUSH, not poll (audit 2026-09-08): this used to Test-Path every 5 s, adding up to 5 s of dead
    # time to every dom0-driven pass. RebootPending is a SUBKEY of the CBS key, so a
    # REG_NOTIFY_CHANGE_NAME notification on the parent wakes us the instant CBS creates it. The
    # notification only says "a subkey under CBS changed", so re-Test and re-arm until the key is
    # there or the 10 min are up. Arm BEFORE testing so a key created between the two is not missed.
    $seen = [bool](Test-Path $rp)
    if (-not $seen) {
      try {
        if (-not ('CbsRegNotify' -as [type])) {
          Add-Type @'
using System; using System.Runtime.InteropServices;
public static class CbsRegNotify {
    [DllImport("advapi32.dll")]
    public static extern int RegNotifyChangeKeyValue(IntPtr hKey, bool bWatchSubtree, uint dwNotifyFilter, IntPtr hEvent, bool fAsynchronous);
}
'@
        }
        $cbsKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($cbsRel,
                    [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadSubTree,
                    ([System.Security.AccessControl.RegistryRights]::Notify -bor [System.Security.AccessControl.RegistryRights]::ReadKey))
        if (-not $cbsKey) { throw 'CBS key not openable' }
        $ev = New-Object System.Threading.ManualResetEvent($false)
        try {
          while (-not $seen -and (Get-Date) -lt $deadline) {
            [void]$ev.Reset()
            # 0x1 = REG_NOTIFY_CHANGE_NAME (subkey add/delete); 0x10000000 = REG_NOTIFY_THREAD_AGNOSTIC
            # so the registration is not tied to the calling thread's lifetime.
            $nrc = [CbsRegNotify]::RegNotifyChangeKeyValue($cbsKey.Handle.DangerousGetHandle(), $false, 0x10000001,
                                                            $ev.SafeWaitHandle.DangerousGetHandle(), $true)
            if ($nrc -ne 0) { throw "RegNotifyChangeKeyValue rc=$nrc" }
            if (Test-Path $rp) { $seen = $true; break }
            $ms = [int][Math]::Max(0, ($deadline - (Get-Date)).TotalMilliseconds)
            [void]$ev.WaitOne($ms)
            if (Test-Path $rp) { $seen = $true }
          }
        } finally { $ev.Dispose(); $cbsKey.Dispose() }
      } catch {
        # A working registry notification is the instrument here; losing it is an anomaly, not a
        # mode. Say so, then keep the bounded poll so the settle verdict is still reached.
        Log "  [WARN] RebootPending registry notification unavailable ($($_.Exception.Message)) - polling every 5 s instead"
        while (-not $seen -and (Get-Date) -lt $deadline) {
          if (Test-Path $rp) { $seen = $true; break }
          Start-Sleep -Seconds 5
        }
      }
    }
    $ti = @(Get-Process TiWorker, TrustedInstaller -EA SilentlyContinue).Count
    Log ("  settle: CBS RebootPending={0} after staging, servicing processes still up={1}" -f $seen, $ti)
    $script:St.reboot_pending_confirmed = $seen
    if (-not $seen) {
      Log '  [WARN] staged but CBS never reported RebootPending - a reboot now would lose it'
    }
    # Let TiWorker finish its post-DISM work; rebooting mid-registration is what loses a package.
    # Wait ON the process, not for it (audit 2026-09-08): the 10 s Get-Process poll re-listed every
    # process for as long as TiWorker ran (minutes) and overshot its exit by up to 10 s. WaitForExit
    # returns the moment it is gone. The loop re-lists only when an instance actually exited, so a
    # TiWorker that TrustedInstaller respawns is still waited for, as the poll did.
    $q = (Get-Date).AddMinutes(10)
    while ((Get-Date) -lt $q) {
      $tiw = @(Get-Process TiWorker -EA SilentlyContinue)
      if ($tiw.Count -eq 0) { break }
      $ms = [int][Math]::Max(1, ($q - (Get-Date)).TotalMilliseconds)
      try { [void]$tiw[0].WaitForExit($ms) }
      catch {
        # Cannot open the process for SYNCHRONIZE - an anomaly on the SYSTEM task this runs as.
        Log "  [WARN] WaitForExit on TiWorker failed ($($_.Exception.Message)) - polling every 10 s instead"
        Start-Sleep -Seconds 10
      }
    }
    Log ("  settle: TiWorker idle={0}" -f (@(Get-Process TiWorker -EA SilentlyContinue).Count -eq 0))
}

# ---- WU-MSU-VERDICT-BEGIN   (tools/tests/wu-cumulative-order-test.ps1 runs this region)
# THE KB's ROW FROM ITS FILE ROWS. One catalog KB can yield SEVERAL .msu (build/architecture variants, prerequisites), and the ones that
# do not apply to this image fail by design - a 24H2 cumulative returns rc=552 on a 25H2 guest. So a KB counts as installed when AT
# LEAST ONE of its files succeeds. STAGED IS NOT INSTALLED: rc=3010 means CBS accepted the package and will apply it during the next
# boot - it is not proof that it landed, and on 2026-08-14 a package that returned 3010 ended up with ZERO CBS entries after the reboot
# while this code reported "installed=True". Say which it is, so a discarded package can never read as a success.
# A CUMULATIVE DISM ACCEPTED BUT WINDOWS DID NOT REGISTER (or could not be shown to have registered - WU-INSTALL-MSUS's check, rows
# carrying registered=$false / 'unknown') FAILS the KB: ok=false, state 'failed', the file row's why as the reason. dom0 then hears it
# as outstanding with a restart required - never as 'staged (completes at restart)', which DISM's 3010 alone would have claimed.
function Get-MsuKbVerdict([string]$kb, $rows){
  $ok = @($rows | Where-Object { $_.rc -in $OK_RC }).Count -gt 0
  $staged = @($rows | Where-Object { $_.rc -eq 3010 }).Count -gt 0
  $applied = @($rows | Where-Object { $_.rc -eq 0 }).Count -gt 0
  $deferred = @($rows | Where-Object { $_.rc -eq 'deferred' }).Count -gt 0
  $state = if ($staged) { 'staged' } elseif ($applied) { 'installed' }
           elseif ($deferred) { 'deferred' } else { 'failed' }
  # THE ROW NOW SAYS WHETHER IT WAS VERIFIED. ADR-updater 3 and 12.3 permit an exit-code success
  # ONLY where no probe exists and the row ADMITS it (probe=none, "never implying verification").
  # This route carried neither field, so the main install path - the cumulative and every other
  # .msu - reported `installed` with nothing to distinguish a measured install from an assumed one,
  # and the two consumers the sibling route feeds (the exclusion audit and the evidence builder,
  # which read severity / verified_by_effect / probe) saw nothing for it at all. Same field names
  # and types as Install-ViaAgentCache's row, so nothing is invented here.
  # The cumulative's probe IS the registration check in Install-Msus; no other .msu has one.
  $regRow = @($rows | Where-Object { Test-RowKey $_ 'registered' })
  $probe = if($regRow.Count -gt 0){ 'rollup-registered' } else { $null }
  $eff = ($regRow.Count -gt 0) -and ($regRow[0].registered -eq $true)
  $row = [ordered]@{ kb=$kb; ok=$ok; state=$state; files=@($rows); verified_by_effect=[bool]$eff; probe=$probe }
  $unregistered = @($rows | Where-Object { (Test-RowKey $_ 'registered') -and ($_.registered -ne $true) })
  if ($unregistered.Count -gt 0) {   # GUARD:unregisteredfails
    $row.ok = $false; $row.state = 'failed'; $row.reason = [string]$unregistered[0].why
  }
  return $row
}
# ---- WU-MSU-VERDICT-END

# ---- WU-PASS-ORDER-BEGIN   (tools/tests/wu-cumulative-order-test.ps1 runs this region with DISM, the settle and the package list stood in)
# THE ORDER OF THE .msu ROUTE (decided 2026-10-04, docs/ADR-updater.md section 13). Until then each catalog package was handed to DISM
# the moment its files arrived, i.e. in OFFER ORDER - on the reporter's German 25H2 template .NET (KB5126052) before the cumulative
# (KB5129195): .NET staged, the one-package rule deferred the cumulative, and the guest needed a second restart. Measured there with the
# rule lifted (QUBES_UPDATES_ALLOW_MULTISTAGE=1), a cumulative staged behind .NET's pending restart was never registered at all; the
# cumulative FIRST and .NET second both landed at one restart. So the resolve/download loop queues the .msu offers in a plan and this
# installs them after the loop:
#   1. the cumulative (Get-MsuKind, by DISM's identity of the file) - FIRST, and only if CBS RebootPending is false at that moment.
#      A restart already pending (left by Windows or by an earlier pass) DEFERS it with exactly that reason and requests the restart
#      through the existing channel (reboot_needed; ADR sections 8 and 10). An unreadable RebootPending is announced and the cumulative
#      proceeds (ADR section 10: an unmeasured guard is never assumed in either direction) - the registration check is the backstop;
#   2. every other .msu, in offer order (the one-package rule, relaxed only behind a registered cumulative, is Install-Msus's).
# NOT part of this: the Windows Update agent route (Install-ViaAgentCache - Defender, the Security platform, MSRT, no-KB offers with
# static content) and the title-resolved drivers (Install-DriverCab). They run inline in the offer loop, where 4.3.33 was measured
# working (Jev review 2026-10-04: moving them behind a staged cumulative was the biggest risk, 0.78; this narrow design 0.73). They are
# not CBS packages and are not expected to set CBS RebootPending (not measured); if one ever does, the gate above defers the cumulative
# truthfully, at the cost of one extra restart. Any miss of the order rule ends in a truthful deferral or a failed row that requests the
# restart (Jev Q2 unsettled at 0.49; Q3's check is the backstop at 0.88): at most one extra restart, and nothing reported staged on
# DISM's 3010 alone. Plan entries: @{ u=<offer row>; label; got=@(files) }.
function Install-MsuPlan($plan){
  foreach($e in $plan){ $e.cumulative = (@($e.got | Where-Object { (Get-MsuKind $_) -eq 'cumulative' }).Count -gt 0) }
  $ordered = @($plan | Where-Object { $_.cumulative }) + @($plan | Where-Object { -not $_.cumulative })   # GUARD:cumulativefirst
  Log ('install order (.msu): ' + (@($ordered | ForEach-Object { $_.label + $(if($_.cumulative){ ' [cumulative]' } else { '' }) }) -join ' -> '))
  foreach($e in $ordered){
    $u = $e.u
    if($e.cumulative){
      $rp = Test-CbsRebootPending
      if($rp -eq $true){   # GUARD:cumulativedefer
        $why = ('deferred: a restart is already pending (CBS RebootPending is set - left by Windows or by an earlier pass) and the ' +
                'cumulative''s bundled servicing stack must install online BEFORE anything is pending (measured 2026-10-03/04 on the ' +
                'reporter''s environment: staged behind a pending restart, DISM returned 3010 and Windows never registered the rollup); ' +
                'this pass requests that restart, and the pass after it installs the cumulative first')
        $fileRows = @($e.got | ForEach-Object { [ordered]@{ file=[IO.Path]::GetFileName($_); rc='deferred'; why=$why } })
        $script:St.result += [ordered]@{ kb=$u.kb; ok=$false; state='deferred'; files=@($fileRows); reason=$why }
        $script:St.reboot_needed = $true   # GUARD:deferrequests - the restart is REQUESTED through the counted channel, never taken
        Save
        Log "$($u.kb): DEFERRED - $why"
        continue
      }
      if($null -eq $rp){ Log "  [WARN] $($u.kb): CBS RebootPending could not be read - the cumulative proceeds (an unmeasured guard is never assumed); the registration check after the DISM call is the backstop" }   # GUARD:rpunreadable
      else { Log "  $($u.kb): CBS RebootPending=false - the cumulative goes first" }
    }
    $script:St.phase='install'; Save
    # One catalog KB can yield SEVERAL .msu (build/architecture variants, prerequisites), and the ones that do not apply to this image
    # fail by design - a 24H2 cumulative returns rc=552 on a 25H2 guest. So a KB counts as installed when AT LEAST ONE of its files
    # succeeds (Get-MsuKbVerdict), and results are grouped PER KB and APPENDED. This used to be a plain assignment of a flat row list,
    # so each KB silently erased the previous KB's outcome.
    $rows = Install-Msus $e.got
    $verdict = Get-MsuKbVerdict $u.kb $rows
    $script:St.result += $verdict
    Save
    # Reclaim the download ONLY once the package is truly applied. A STAGED package still has
    # to survive a reboot, and if it does not, the next pass must be able to retry it without
    # re-fetching gigabytes - deleting it here is what made a failed apply expensive.
    $staged = @($rows | Where-Object { $_.rc -eq 3010 }).Count -gt 0
    if (-not $staged) {
      foreach($r in $rows){ if($r.rc -in $OK_RC){ Remove-Item -LiteralPath (Join-Path (Join-Path $WorkDir $u.kb) $r.file) -Force -EA SilentlyContinue } }
    }
    Log ("$($u.kb): $($verdict.state) (ok=$($verdict.ok))" + $(if($verdict.reason){ " - $($verdict.reason)" } else { '' }))
  }
}
# ---- WU-PASS-ORDER-END

# AUTOLOGON PROTECTION AT EVERY PASS END (measured 2026-08-19: three HARNESS-driven reboots
# around staged servicing consumed DefaultPassword and left win10-clean at the sign-in screen
# - unreachable for qrexec, needing a manual login. ensure-autologon.ps1 was wired only to
# the vmupdate/dom0-driven REBOOT path, so any other rebooter - a harness, a human, CBS
# itself - bypassed it). Running the prevention whenever THIS pass staged reboot-requiring
# work removes the dependency on who reboots afterwards. Prevention only: if the password is
# already consumed there is nothing this can restore (see ensure-autologon.ps1's header).
# ---- WU-AUTOLOGON-GUARD-BEGIN   (tools/tests/wu-autologon-guard-test.ps1 extracts this function by these markers)
function Protect-Autologon {
  # Fire whenever a reboot is pending OR a package was staged this session (a stage can precede the
  # reboot_needed flag, and a throw between the two must not skip re-arming autologon).
  if (-not ($script:St.reboot_needed -or $script:StagedThisSession)) { return }
  # The guard is read from where install-updater-agent.ps1 deploys it - <Qubes Tools>\qubes-rpc-services,
  # the location wu-update.ps1 reads too - derived the same way (QUBES_TOOLS, else the default root).
  # Until 2026-09-17 this read a `vmupdate-shim\` directory the installer never creates, so on the
  # task-driven path (QubesWindowsUpdateRun, the boot and 6-hourly scans) the guard was skipped on
  # EVERY reboot-pending pass while logging that the helper was "not deployed" - measured on
  # win11de-gwt: the file existed at qubes-rpc-services (10040 B), the WARN appeared on all four
  # reboot-pending passes. Autologon survived those reboots by luck, not by this guard.
  $qt = $env:QUBES_TOOLS; if (-not $qt) { $qt = 'C:\Program Files\Qubes Tools' }
  $ea = Join-Path $qt 'qubes-rpc-services\ensure-autologon.ps1'   # GUARD:alpath
  if (-not (Test-Path $ea)) { Log "reboot staged but ensure-autologon.ps1 is missing at $ea - autologon may be consumed by the coming reboots" 'WARN'; return }
  try {
    & powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $ea 2>&1 |
      ForEach-Object { Log "  autologon: $_" }
  } catch { Log "ensure-autologon failed: $($_.Exception.Message)" 'WARN' }
}
# ---- WU-AUTOLOGON-GUARD-END

# ---- WU-PROXY-PROBE-BEGIN
# GUARD:reasonmeasured - the probe half. When a pass dies at 0x8024402C, dom0 is owed the REASON,
# and the reason has to be MEASURED IN THAT PASS rather than asserted from what a rig run once
# showed. This runs inside the pass-level catch, where the proxy and the relay are still up
# (Remove-Proxy is in the finally, after it).
#
# It uses WINHTTP - the stack Windows Update itself uses - deliberately. Measured 2026-09-21 on
# three clones of the German 25H2 golden: while WU fails 0x8024402C, WinHttpRequest.5.1 through the
# same 127.0.0.1:8082 fetches the same service-registration endpoint (HTTP 200, 36310 bytes), as
# does .NET. Re-applying the machine WinHTTP proxy and populating the service account's WinINET
# proxy both change nothing. So the failure is WU's own proxy selection, and this probe is what
# lets the pass SAY so with evidence instead of with a story.
#
# ANY HTTP status counts as reachable, including 404: the question is whether the request reached
# the endpoint through our proxy, not what the endpoint thought of it. Only a transport failure is
# 'unreachable'. Bounded timeouts, one attempt, no retry loop - this is a diagnosis on an error
# path, not a wait standing in for an answer.
function Test-ProxyServesWu {
  $target = "https://tas02.sls.update.microsoft.com/SLS/{9482F4B4-E343-43B6-B170-9A65BC822C77}/$OsArch/$OsBuild/0"
  $hostport = $Proxy -replace '^[a-zA-Z]+://',''
  try {
    $w = New-Object -ComObject 'WinHttp.WinHttpRequest.5.1'
    $w.SetProxy(2, $hostport, '<local>')
    $w.SetTimeouts(15000,15000,15000,30000)
    $w.Open('GET', $target, $false)
    $w.Send()
    return "reachable status=$($w.Status)"
  } catch {
    return "unreachable " + ($_.Exception.Message -replace "`r|`n",' ')
  }
}
# ---- WU-PROXY-PROBE-END

# ---------------------------------------------------------------------- main
# VM-CLASS CLASSIFICATION, guest-side. The qubes.UpdatesProxy updater is a TEMPLATE-ONLY
# mechanism: dom0-driven updates for a VM that is otherwise offline. It must run ONLY on a
# TemplateVM. A StandaloneVM - networked OR offline - updates ITSELF via normal Windows Update and
# must NEVER raise the proxy ("offline" does not make a standalone a template). An AppVM/DispVM has
# a volatile root and must do nothing (updates are its template's business).
#
# The class is read LIVE from qubesdb, exactly as the Linux agent does. The earlier "vm-type is
# unreadable in a Windows guest" claim was a BUG in the PowerShell glue, NOT a real limit: the C
# agent reads qubesdb fine, qubesdb-client.dll is in SYSTEM32, and the P/Invoke merely needed the
# correct Cdecl/Ansi marshaling (measured 2026-08-19). Keys are written by core-admin:
#   /type                 - the exact Python class name (StandaloneVM/TemplateVM/AppVM/DispVM).
#                           The ONLY key that separates StandaloneVM from AppVM; /qubes-vm-type
#                           collapses both to 'AppVM'.
#   /qubes-vm-type        - TemplateVM | AppVM | NetVM | ProxyVM (fallback template test).
#   /qubes-vm-updateable  - True (Template/Standalone) | False (AppVM/DispVM) (fallback splitter).
# No deploy-time stamp is needed and this works on ANY template however it was built. The old
# VmClass/RootIdentity stamp fallback is RETIRED - the read is proven reliable, so if we cannot
# classify we refuse to proxy (skipped-unknown) rather than trust a stale stamp. NOTE:
# /qubes-service/yum-proxy-setup carries dom0's updates-proxy-setup feature if
# an operator ever wants to opt a specific standalone in; we deliberately do not honour it here
# (the requirement is template-ONLY).
function Get-QubesDbValue([string]$path) {
  try {
    if (-not ('QubesDb' -as [type])) {
      Add-Type @'
using System; using System.Runtime.InteropServices;
public static class QubesDb {
    [DllImport("qubesdb-client.dll", CallingConvention=CallingConvention.Cdecl)]
    public static extern IntPtr qdb_open(IntPtr vmname);
    [DllImport("qubesdb-client.dll", CallingConvention=CallingConvention.Cdecl, CharSet=CharSet.Ansi)]
    public static extern IntPtr qdb_read(IntPtr h, string path, out uint value_len);
    [DllImport("qubesdb-client.dll", CallingConvention=CallingConvention.Cdecl)]
    public static extern void qdb_close(IntPtr h);
}
'@
    }
    $h = [QubesDb]::qdb_open([IntPtr]::Zero)
    if ($h -eq [IntPtr]::Zero) { return $null }
    try {
      $len = [uint32]0
      $p = [QubesDb]::qdb_read($h, $path, [ref]$len)
      if ($p -eq [IntPtr]::Zero) { return $null }
      # value is heap-allocated by qubesdb-client; a few bytes leak per read (no qdb_free
      # exported and calling the CRT free from PS is unsafe) - fine for a short-lived pass.
      return [Runtime.InteropServices.Marshal]::PtrToStringAnsi($p, [int]$len)
    } finally { [QubesDb]::qdb_close($h) }
  } catch { return $null }
}
function Get-QubesVmClass {
  # WAIT for the qubesdb daemon to finish starting. This is a service-startup ORDERING race, not a random
  # flake: qdb_open connects to the qubesdb-daemon service (which, at boot, syncs the database from dom0
  # over vchan). A boot-triggered pass can run before that daemon is serving its pipe, so qdb_open returns
  # NULL *deterministically* in that window and BOTH /type and /qubes-vm-type read empty. Measured
  # 2026-08-20: in steady state the read is rock solid (25/25 returned the class); only the early-boot run
  # read empty. The old code concluded "not a TemplateVM (VmClass='')" on that first empty read and SKIPPED
  # the whole pass on a real template (doing nothing for a full boot). Retry ONLY while qubesdb is
  # unreachable (both keys empty) so we wait out the daemon's startup; a populated value returns
  # immediately, so a steady-state read costs nothing.
  for ($try = 1; $try -le 8; $try++) {
    $t = Get-QubesDbValue '/type'
    if ($t) { return $t }                            # exact class name - best signal
    $vt = Get-QubesDbValue '/qubes-vm-type'
    if ($vt) {
      if ($vt -eq 'TemplateVM') { return 'TemplateVM' }
      if ((Get-QubesDbValue '/qubes-vm-updateable') -eq 'True') { return 'StandaloneVM' }
      return 'AppVM'
    }
    if ($try -lt 8) { Start-Sleep -Seconds 2 }       # qubesdb not reachable yet - wait out the boot race
  }
  return $null                                       # still unreadable after ~14s -> caller uses fallback
}
function Test-DirectInternet {
  foreach ($u in 'http://www.msftconnecttest.com/connecttest.txt','http://www.msn.com/') {
    try {
      $req = [System.Net.HttpWebRequest]::Create($u)
      $req.Proxy = $null                 # explicitly DIRECT - ignore any system/WinHTTP proxy
      $req.Timeout = 8000
      $resp = $req.GetResponse()
      $ok = ([int]$resp.StatusCode -lt 400)
      $resp.Close()
      if ($ok) { return $true }
    } catch { }
  }
  return $false
}
# ADR-updater 17: what lets Windows Update install an update and restart this guest by itself, read from what is in
# force and counted wherever it is found - Group Policy ($Au = ...\WindowsUpdate\AU, $Wu = ...\WindowsUpdate) and
# device management ($Mdm = PolicyManager\current\device\Update). Each argument is the key's Get-ItemProperty object,
# or $null when the key is absent. Updates are off where NoAutoUpdate=1 or AllowAutoUpdate=5. AUOptions 2 and 3 only
# notify, and AUOptions=4 with NoAutoRebootWithLoggedOnUsers=1 leaves the restart to the signed-in user. A deadline
# overrides all of that, so it counts wherever updates are not off. With nothing configured anywhere, Windows installs
# and restarts by default. The deadline value names are those of the Windows 11 WindowsUpdate.admx.
# Returns one @{Tag; Detail} per cause: Tag is a fixed phrase for the notice, Detail names the values for the log.
function Get-WuAutoRestartCause($Au, $Wu, $Mdm) {
  $nau = $null; $auo = $null; $narw = $null; $aau = $null
  if ($Au) { $nau = $Au.NoAutoUpdate; $auo = $Au.AUOptions; $narw = $Au.NoAutoRebootWithLoggedOnUsers }
  if ($Mdm) { $aau = $Mdm.AllowAutoUpdate }
  $c = @()
  if (($null -ne $nau -or $null -ne $auo) -and $nau -ne 1) {
    if ($auo -ne 2 -and $auo -ne 3 -and -not ($auo -eq 4 -and $narw -eq 1)) {
      $c += @{ Tag = 'group policy'; Detail = "group policy NoAutoUpdate=$(if ($null -eq $nau) { 'unset' } else { $nau }) AUOptions=$(if ($null -eq $auo) { 'unset' } else { $auo }) NoAutoRebootWithLoggedOnUsers=$(if ($null -eq $narw) { 'unset' } else { $narw })" }
    }
  } elseif ($null -eq $nau -and $null -eq $auo -and $null -eq $aau) {
    $c += @{ Tag = 'the Windows default'; Detail = 'no automatic-updates policy is set, and by default Windows installs and restarts' }
  }
  if ($aau -ge 1 -and $aau -le 4) { $c += @{ Tag = 'device management'; Detail = "device management AllowAutoUpdate=$aau" } }
  $dl = @()
  if ($Wu) { foreach ($n in 'SetComplianceDeadlineForQU', 'SetComplianceDeadlineForFU') { if ($Wu.$n -eq 1) { $dl += "group policy $n=1" } } }
  if ($Mdm) { foreach ($n in 'ConfigureDeadlineForQualityUpdates', 'ConfigureDeadlineForFeatureUpdates') { if ($null -ne $Mdm.$n) { $dl += "device management $n=$($Mdm.$n)" } } }
  if ($dl.Count -and $nau -ne 1 -and $aau -ne 5) { $c += @{ Tag = 'a deadline policy'; Detail = ($dl -join ' ') } }
  return $c
}
$vmClassLive = Get-QubesVmClass
if (-not $vmClassLive) {
  # qubesdb is the authority and is reliably readable (qubesdb-client.dll is in SYSTEM32). If we
  # genuinely cannot classify, REFUSE to proxy rather than guess - never proxy a VM we cannot
  # confirm is a template. This is an anomaly to investigate, NOT a case to paper over with a
  # deploy-time stamp (the old VmClass/RootIdentity stamp fallback is retired: the read is proven).
  Log 'CANNOT classify VM from qubesdb - refusing to proxy; nothing done. Investigate qubesdb.' 'WARN'
  $script:St.phase='skipped-unknown'; Save
  exit 0
}
Log "VM class (live from qubesdb): $vmClassLive"
# ADR-updater 17: a StandaloneVM with direct internet updates itself, and Windows Update is set never to restart it by
# itself - AUOptions=4 with NoAutoRebootWithLoggedOnUsers=1 leaves the restart to the signed-in user. The two values
# are written before NoAutoUpdate is removed; when they cannot be written, NoAutoUpdate stays.
$wuAuKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
$selfUpdating = ($vmClassLive -eq 'StandaloneVM') -and (Test-DirectInternet)
if ($selfUpdating) {
  try {
    & { $ErrorActionPreference = 'Stop'; SetV $wuAuKey 'AUOptions' 4 'DWord'; SetV $wuAuKey 'NoAutoRebootWithLoggedOnUsers' 1 'DWord' }
    Log 'StandaloneVM with direct internet - it updates ITSELF via Windows Update, and a restart waits for the signed-in user (AUOptions=4, NoAutoRebootWithLoggedOnUsers=1). The qubes proxy updater is template-only: disabled. Undoing NoAutoUpdate=1.'
    Remove-ItemProperty -Path $wuAuKey -Name NoAutoUpdate -EA SilentlyContinue
  } catch {
    Log "StandaloneVM with direct internet, but AUOptions=4 and NoAutoRebootWithLoggedOnUsers=1 could not be written ($($_.Exception.Message)) - NoAutoUpdate is left as it is." 'ERROR'
  }
}
# ADR-updater 17 decision 2, on every class: warn when what is in force lets Windows restart this guest by itself. It
# runs after the write above, so the first pass after an upgrade does not warn about the values it has just set.
$wuCauses = $null
try {
  $wuCauses = @(Get-WuAutoRestartCause -Au (Get-ItemProperty -LiteralPath $wuAuKey -EA SilentlyContinue) `
      -Wu (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' -EA SilentlyContinue) `
      -Mdm (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Update' -EA SilentlyContinue))
} catch { Log "WUAUTORESTART the policy in force could not be read: $($_.Exception.Message)" 'ERROR' }
if ($null -ne $wuCauses -and $wuCauses.Count -eq 0) { Log 'WUAUTORESTART none: no policy in force lets Windows restart this guest by itself' }
elseif ($wuCauses) {
  Log ('WUAUTORESTART possible: ' + (($wuCauses | ForEach-Object { $_.Detail }) -join '; ')) 'ERROR'
  # The notice carries fixed phrases only; the values are in the line above.
  $notifyPs1 = Join-Path $PSScriptRoot 'qwt-notify-error.ps1'
  $sent = 'unavailable:helper-absent'
  try {
    if (Test-Path -LiteralPath $notifyPs1) {
      $script:QwtNotifyLog = { param($m) Log "NOTIFYERR $m" 'WARN' }
      . $notifyPs1
      $sent = Send-QwtError -Component 'qubes-windows-update' -Id 'auto-restart-possible' -Severity ACTION `
        -Header 'Windows may restart this qube by itself' `
        -Next 'Windows Update can install an update and restart this qube without asking; unsaved work can be lost.' `
        -Cause 'Cause: the Windows Update policy in force allows it; the log names the values.' `
        -Tech (Format-QwtNotifyTechLine -Subject 'qubes-windows-update.ps1' -Code ('allowed by ' + (($wuCauses | ForEach-Object { $_.Tag } | Select-Object -Unique) -join ', ')) `
          -Count 'reported once per boot' -Evidence (Join-Path (Get-QwtLogDir) ('qubes-windows-update.ps1-' + (Get-Date -Format 'yyyyMMdd') + '.log')))
    }
  } catch { $sent = 'failed:exception'; Log "WUAUTORESTART notice could not be sent: $($_.Exception.Message)" 'WARN' }
  Log "WUAUTORESTART notice: $sent"
}
if ($vmClassLive -eq 'TemplateVM') {
  # the proxy updater's home - fall through to Ensure-Proxy below
} elseif ($vmClassLive -eq 'StandaloneVM') {
  if (-not $selfUpdating) {
    Log 'StandaloneVM, offline - the qubes proxy updater is template-only and never runs here; this VM must update itself. Doing nothing.'
  }
  $script:St.phase='skipped-standalone'; Save
  exit 0
} else {
  Log "$vmClassLive - not a template; updates are the template's business. Exiting before any proxy activity."
  $script:St.phase='skipped-appvm'; Save
  exit 0
}
try {
  $script:St.phase='ensure-proxy'; Save; Ensure-Proxy
  $script:St.phase='sync-revocation'; Save; Sync-Revocation
  $script:St.phase='scan'; Save
  # A LOSSY PASS MUST NEVER BE REPORTED AS "NOTHING TO UPDATE".
  # Measured 2026-08-15: five consecutive scans reported 0 updates on a guest that had three.
  # Windows Update was reachable the whole time - what failed were small plain-HTTP metadata
  # fetches through the relay, which returned nothing at all. WU cannot describe an offer it
  # could not download, so it answers "no updates", and the guest then tells dom0 it is current.
  # That is the worst possible failure: silent, and it looks like success.
  # So: watch the relay's own log across the scan. If it gave up on any fetch (complete=False)
  # AND the scan found nothing, the result is UNKNOWN, not zero - retry once, then refuse to
  # report a number nobody can stand behind.
  # The relay writes the file Start-Relay named for it ($script:RelayLogPath, passed as --log-file), and
  # this reads that same variable. The path was once hardcoded to the default WorkDir while the relay
  # wrote under the WorkDir it was started with, so any run with a non-default -WorkDir read a file
  # that never grew, counted zero give-ups, and disarmed the guard silently.
  # Number of fetches the relay gave up on since $fromOffset, or -1 for UNKNOWN.
  # UNKNOWN IS NOT ZERO. This used to answer 0 when the log was missing and 0 again when reading it
  # threw - a check that could not fail, and therefore was not a check. The caller now treats an
  # unknown answer as suspect instead of as a clean bill of health.
  function Get-RelayGiveUps([long]$fromOffset) {
    if (-not $script:RelayLogPath -or -not (Test-Path $script:RelayLogPath)) { return -1 }
    try {
      $fs = [IO.File]::Open($script:RelayLogPath, 'Open', 'Read', 'ReadWrite')
      try {
        if ($fromOffset -gt $fs.Length) { $fromOffset = 0 }
        [void]$fs.Seek($fromOffset, 'Begin')
        $sr = New-Object IO.StreamReader($fs)
        $text = $sr.ReadToEnd()
      } finally { $fs.Dispose() }
      # 'PLAIN REFUSED' is the unambiguous marker: the relay declined to hand over a short body.
      # A complete=False summary still counts, because a SPILLED (already-committed) response can
      # end short after the bytes are on the client's wire and cannot be refused retroactively.
      # Chunked replies no longer produce a spurious complete=False, so this no longer over-counts.
      return ([regex]::Matches($text, 'PLAIN REFUSED|complete=False')).Count
    } catch { return -1 }
  }
  $relayOffset = if ($script:RelayLogPath -and (Test-Path $script:RelayLogPath)) { (Get-Item $script:RelayLogPath).Length } else { 0 }

  $avail = Get-Available
  # TEST HOOK, same reasoning as the agent's SoloFaultInject: this guard only fires when a scan
  # finds nothing WHILE the transport was dropping fetches, and once Windows Update has cached
  # its metadata that state cannot be summoned on demand. QUBES_UPDATES_FAKE_EMPTY_SCAN=1 makes
  # the scan look empty so the guard can be SEEN to fire. Absent, this is dead code.
  if ($env:QUBES_UPDATES_FAKE_EMPTY_SCAN -eq '1') {
    Log 'QUBES_UPDATES_FAKE_EMPTY_SCAN=1 - pretending the scan found nothing' 'WARN'
    $avail = @()
  }
  $giveUps = Get-RelayGiveUps $relayOffset
  # A lost fetch makes the scan suspect whatever the COUNT is: a partial list is indistinguishable
  # from a complete one, so gating this on "found nothing" only caught the most obvious half.
  # An UNKNOWN answer (-1) is suspect too, but only when the scan also came back empty - an empty
  # scan with no evidence that the transport was working is exactly the dangerous case, while a
  # non-empty scan has already demonstrated it fetched something.
  $suspect = ($giveUps -gt 0) -or ($giveUps -lt 0 -and $avail.Count -eq 0)
  if ($suspect) {
    $gu = if ($giveUps -lt 0) { 'UNKNOWN (relay log unreadable)' } else { $giveUps }
    Log "scan is suspect - relay give-ups: $gu, found $($avail.Count) update(s) - rescanning" 'WARN'
    $relayOffset = if ($script:RelayLogPath -and (Test-Path $script:RelayLogPath)) { (Get-Item $script:RelayLogPath).Length } else { 0 }
    Start-Sleep -Seconds 5
    $avail = Get-Available
    $giveUps = Get-RelayGiveUps $relayOffset
    $suspect = ($giveUps -gt 0) -or ($giveUps -lt 0 -and $avail.Count -eq 0)
  }
  if ($suspect -and $avail.Count -eq 0) {
    $gu = if ($giveUps -lt 0) { 'an unknown number of' } else { "$giveUps" }
    $script:St.phase='scan-failed'; $script:St.error = "transport lost $gu fetch(es); update availability unknown"; Save
    Log "SCAN FAILED: the relay gave up on $gu fetch(es) and Windows Update found nothing. Not reporting 0 to dom0 - a scan that could not fetch its metadata is not the same as a guest with no updates." 'ERROR'
    exit 75
  }
  if ($suspect) {
    # Non-empty, but the transport dropped something: the list may be SHORT. Say so instead of
    # letting a partial result be read as authoritative. Not a failure - the updates that were
    # found are real and worth installing - but dom0 must not treat this count as complete.
    $script:St.scan_partial = $giveUps; Save
    Log "SCAN PARTIAL: found $($avail.Count) update(s) but the relay gave up on $giveUps fetch(es) - the list may be incomplete; treat the count as a lower bound, not the whole truth." 'WARN'
  }

  # ---- WU-DEFINITION-EXCLUDE-BEGIN   (the marker names what this region CLAIMED from 2026-10-25 to 2026-11-01; it records now)
  # DEFINITION OFFERS COUNT LIKE EVERY OFFER (ADR-updater section 2 point 2: a classification may narrow what a pass acts on, never
  # what the guest admits to). Commit 61557095 claimed otherwise - "Defender definitions stopped raising dom0's flag" - and did not:
  # it narrowed St.count to the non-definition offers while Report-Availability kept sending every offer, so dom0 heard the definition
  # and the status lied about it (measured 2026-11-01 on win10-tup: "excluded 1 of 8" beside "7 reported", the definition among
  # them; 22 campaign scans on win11de-tup: "2 of 6" beside "6 reported"). Quieting definitions is WUQUIETDEFINITIONS, the owner's
  # queued request - an ADR amendment and the owner's go, because on a netvm-free template a dom0-driven pass is the only way a
  # definition ever installs. Kept: `is_definition` on every offer (WU's own classification, WU-DEFINITION-CLASS) and
  # `definitions_offered`, how many of the offers are definitions - information for the reader, deciding nothing.
  $defs = @($avail | Where-Object { $_.is_definition })
  $script:St.available=$avail
  $script:St.definitions_offered=$defs.Count
  Save
  if ($defs.Count -gt 0) {
    Log ("{0} of {1} offer(s) are Defender definition updates [{2}] - counted to dom0 like every offer (ADR-updater section 2 point 2); WUQUIETDEFINITIONS is queued, not implemented" -f `
         $defs.Count, $avail.Count, (($defs | ForEach-Object { $_.kb + '[' + (@($_.classifications) -join ' ') + ']' }) -join ','))
  }

  # ---- WU-DEFINITION-CLASS-WATCH-BEGIN
  # A WRONG OR CHANGED GUID FAILS IN SILENCE. That is the one weakness of the fail-safe direction:
  # if Microsoft ever classifies signatures under a different GUID, or adds a second one, nothing
  # matches, is_definition is false and definitions_offered undercounts, and NOTHING IN THE LOG SAYS
  # WHY - the next reader would be debugging dom0's flag with no idea the classifier had stopped
  # matching. The constant is also still unconfirmed against a live object
  # (WUDEFINITIONGUIDUNCONFIRMED), so this watcher is what turns "wrong GUID" from an invisible
  # no-op into a named line.
  #
  # IT DOES NOT CHANGE A DECISION. It only reports; every offer counts regardless (ADR-updater section 2 point 2).
  #
  # THE [WARN] IS IN THE MESSAGE, not passed as Log's level, and that is deliberate even though
  # Log now honours a level (it silently dropped one until the commit that added this watcher).
  # This exact line is asserted verbatim in two places - the offline suite reads it out of the
  # shipped region, and tools/wu-pass-judge.py's fixture is that printed text - so its declaration
  # must not depend on a second mechanism continuing to behave. A line whose level came from
  # elsewhere is a line that can lose its level somewhere else, which is the defect this same
  # commit fixes.
  $anom = @()
  foreach ($r in $avail) {
    if ($script:WU_SIGNATURE_KBS -notcontains $r.kb) { continue }
    if ($r.is_definition) { continue }
    $seen = @($r.classifications)
    $anom += ($r.kb + '[' + ($seen -join ' ') + ']')
    if ($seen.Count -eq 0) {
      Log ("[WARN] QWTUPDDEFCLASSNEW {0} is a signature offer carrying NO readable UpdateClassification, so is_definition is false for it - its categories were absent or threw (every offer counts regardless)." -f $r.kb)
    } else {
      Log ("[WARN] QWTUPDDEFCLASSNEW {0} is a signature offer but Windows Update classifies it as [{1}], not {2} - is_definition is false for it and definitions_offered undercounts; the classification GUID has changed or there is more than one." -f $r.kb, ($seen -join ' '), $script:WU_DEFINITION_CLASS)
    }
  }
  $script:St.definition_class_anomalies = @($anom)
  if ($anom.Count -gt 0) { Save }
  # ---- WU-DEFINITION-CLASS-WATCH-END
  # ---- WU-DEFINITION-EXCLUDE-END
  # THE ROUTE PROOF, AT SCAN (ADR-updater section 2, point 5, amended 2026-11-01). The ESU licence state is read live on
  # every pass and every build and is information only. Then every offer that is not self-contained is taken to the
  # Catalog NOW, in this pass, so the only offers left out of dom0's count are the ones THIS pass verified have no route
  # on this guest - never a class, a build, a date or a remembered set. The proxy is up for the whole pass (Ensure-Proxy
  # above, Remove-Proxy in the finally), and Resolve-Catalog is memoised per KB, so the install loop pays nothing twice.
  # Definition offers are not taken to the Catalog: the definition exclusion owns them (above) and they still install.
  # The third fact of ADR-updater section 2 point 5 is MEASURED: a default route, or none. The install loop's knob
  # QUBES_UPDATES_ALLOW_WU_NATIVE is not read here - nothing in the proof keys on a switch (Jev 2026-11-01: a switch inside
  # the proof was the one deviation from the contract, 0.51); the knob stays what it was, the install loop's own.
  $script:HasDefaultRoute = [bool](Test-HasDefaultRoute)
  # ASSIGNED HERE, not 370 lines below where the fallback rungs first used it: the install loop
  # needs the same fact (WU-NOKB's routed branch), and one variable assigned once beats the loop
  # re-deriving it. Value-identical - HasDefaultRoute is assigned on this line and nowhere else,
  # and the env knob is never written by this script.
  $canWuNative = $script:HasDefaultRoute -or ($env:QUBES_UPDATES_ALLOW_WU_NATIVE -eq '1')   # the route measured above the scan count, plus the install loop's own knob
  $script:St.esu = Get-EsuStatus
  $routeProof = Measure-Unroutable @($avail | Where-Object { -not $_.is_definition })
  $script:St.unroutable = @($routeProof.none)
  $script:St.route_unknown = @($routeProof.unknown)
  $script:St.notice = Get-ServicingNotice $script:St.unroutable $script:St.esu
  if (@($routeProof.unknown).Count -gt 0) {
    Log ("scan: route UNKNOWN for " + (@($routeProof.unknown) -join ',') + " (the Catalog answer was unresolved or the search threw) - counted to dom0, never excluded on an unknown")
  }
  # ---- WU-SCAN-COUNT-BEGIN
  # GUARD:scanactioned - a SCAN must not re-inflate what an install pass already settled.
  # Measured 2026-09-20 on the German 25H2 guest: an install pass correctly drove dom0 to EMPTY,
  # and the very next boot scan reported 3 again - the no-route driver plus two offers Windows
  # Update re-presents forever. dom0 oscillated 0 -> 3 and the admin was told there was work when
  # there was none. GUARD:actioned and GUARD:infoalways only govern the post-install rescan; this
  # is the same rule for the scan path, using the DURABLE knowledge the last pass wrote down.
  # Conservative on purpose: only a KB the previous pass recorded as severity='info' (structurally
  # not actionable - no route, no package, nothing to do) is dropped here. An ok=$true row is NOT
  # dropped on a scan, because "installed last time" is not evidence that a fresh offer of the same
  # KB is already satisfied - that judgement belongs to a pass that actually tries.
  # Use the startup snapshot (GUARD:prevstatus). Re-reading the file HERE is too late: this run has
  # already Saved over it, so the read returns our own empty result and excludes nothing.
  $priorInfo = @()
  try {
    $prevSnap = $script:PrevStatus
    if ($prevSnap -and $prevSnap.result) {
      $priorInfo = @($prevSnap.result | Where-Object { $_.severity -eq 'info' } |
                     ForEach-Object { $_.kb; if($_.PSObject -and (Test-RowKey $_ 'title')){ $_.title } } |
                     Where-Object { $_ })
    }
    # DURABLE. A scan writes its own status with an EMPTY result, so knowledge taken only from
    # result rows survives exactly ONE scan - and scans run at every boot and on a timer, so the
    # steady state would re-inflate anyway. Carry the classification forward in its own field.
    if ($prevSnap -and (Test-RowKey $prevSnap 'not_actionable')) {
      $priorInfo = @(@($priorInfo) + @($prevSnap.not_actionable) | Where-Object { $_ } | Sort-Object -Unique)
    }
  } catch { $priorInfo = @() }
  $script:St.not_actionable = @($priorInfo)
  # GUARD:offeridentity, the consuming half. An offer whose OWN identity a previous pass recorded
  # as resolved is not a fresh offer, whatever its KB says. This is what lets a scan stop
  # re-raising dom0 for a package that was installed and proven installed thirty seconds earlier,
  # without touching the conservative rule above: a NEW revision carries a new identity and counts.
  # ONLY A LIST WRITTEN BY THIS RULE (satisfied_rule='installed', ADR-updater section 2 point 3). An agent before 2026-11-02 also
  # recorded INFORMATIONAL offers here, and its list survives the upgrade in the status file: carried forward, it would keep those
  # offers out of dom0's count for ever (WUINFOIDENTITYREMEMBERED). Such a list is discarded once and every offer measured again -
  # the cost is an installed offer Windows re-presents being counted until the next pass, the safe direction.
  $priorSat = @()
  try {
    if ($script:PrevStatus -and (Test-RowKey $script:PrevStatus 'satisfied')) {
      $prevList = @($script:PrevStatus.satisfied | Where-Object { $_ })
      if ((Test-RowKey $script:PrevStatus 'satisfied_rule') -and "$($script:PrevStatus.satisfied_rule)" -eq 'installed') { $priorSat = $prevList }
      elseif ($prevList.Count -gt 0) {
        Log ("scan: the previous status's satisfied list (" + $prevList.Count + " offer identities) was written by an agent that also recorded informational offers - discarded, every offer is measured again")
      }
    }
  } catch { $priorSat = @() }
  # DURABLE, for the same reason not_actionable is. A scan writes its OWN status, so knowledge
  # taken only from the previous file and not written back survives exactly ONE scan - and scans
  # run at every boot and on a timer, so the steady state re-inflates anyway. Measured on the
  # guest 2026-09-21: the pass wrote satisfied=[2 identities] and the scan that consumed it wrote
  # satisfied=[] straight back, so a SECOND scan would have re-counted them. Carry it forward.
  $script:St.satisfied = @($priorSat)
  $notPriorSat = { param($r)
      if (-not ($r -and (Test-RowKey $r 'uid') -and $r.uid)) { return $true }   # no identity -> count it
      return ($priorSat -notcontains "$($r.uid):$($r.rev)") }
  $notPriorInfo = { param($r) ($priorInfo -notcontains $r.kb) -and ($priorInfo -notcontains $r.title) -and (& $notPriorSat $r) }
  # DOM0 HEARS THE TRUE NUMBER OF OFFERS. The rule is stated fifteen lines below this, at the -OnlyKb
  # narrowing - "dom0 must always hear the true number of available updates" - and this line broke it: an
  # offer a previous pass classified 'info' was subtracted from the count, DURABLY (not_actionable is carried
  # forward on purpose), so the guest decided on its own that dom0 should be told nothing while Windows went
  # on offering the update. GWeck, forum #175 on 4.3.35, unchanged since 4.3.33: "Trying to update from the
  # Qube manager still shows (wrongly) that no updates are available", with KB5101684 - the July 2026
  # optional PREVIEW cumulative - listed in his own Windows Update window.
  # CORRECTED 2026-10-08: this line said KB5101684 "cannot install routeless". That was an assumption
  # carried in this very commit and it is FALSE, measured from the dev qube through the same dom0
  # updates proxy: the catalog publishes it as a monolithic package (four rows; 25H2 x64 is
  # windows11.0-kb5101684-x64, 5,097,279,731 bytes, with its SSU KB5043080 alongside), the SHIPPED
  # Resolve-Catalog ranking picks exactly that row for a 25H2/26200/x64 guest (score 6; the arm64 rows
  # are rejected on architecture and the 24H2 row at score 0), and a ranged GET through the relay
  # answers 206 with Accept-Ranges, which is what Fetch-Msu's resume needs. So the update was never
  # undeliverable - it was never ASKED FOR, because this count told dom0 there was nothing. Jev:
  # why_not_delivered = count-concealment-so-nobody-asked 0.98, express_premise_false 0.93.
  # STILL UNPROVEN, and not claimed: no guest has fetched 4.75 GiB through the relay or installed it
  # (Jev, on whether "fixed" may be said today: 0.09).
  # Jev: is_concealment 0.89, true-count-always 0.87, and the owner's ESU ruling is untouched (0.28) because
  # that is the notice branch below, which keeps its own rule.
  # The actionable/informational split is not lost - it is recorded in the status, where the pass's own
  # report carries it, instead of being hidden inside a single number.
  # TWO DIFFERENT EXCLUSIONS, and only one of them may touch what dom0 hears:
  #   an offer whose own IDENTITY a pass installed and proved installed is GONE, not hidden - Windows
  #     re-presents satisfied signatures under the same KB, and counting them is what drove dom0 0 -> 3 -> 0
  #     on 2026-09-20 (GUARD:offeridentity above);
  #   an offer we CANNOT INSTALL is still available, and subtracting it is the concealment this fix removes.
  # THE ONE MEASURED EXCEPTION (ADR-updater section 2, point 5): an offer THIS pass VERIFIED has no route on this guest -
  # WU-ROUTE-PROOF, minutes ago, in this very pass, written to St.unroutable - is left out of what dom0 hears. Not a class,
  # not a build, not a carried-forward set: the next pass asks the Catalog again before leaving it out again.
  $unroutable = @($script:St.unroutable | Where-Object { $_ })
  $notUnroutable = { param($r) ($unroutable -notcontains (Get-OfferRouteKey $r)) }   # the KB, or the exact title of an offer without one
  $actionableCount = @($avail | Where-Object { (& $notPriorInfo $_) -and (& $notUnroutable $_) }).Count
  $reportCount = @($avail | Where-Object { (& $notPriorSat $_) -and (& $notUnroutable $_) }).Count   # GUARD:truecount
  # Said only of the offers it is TRUE of: a previous pass's informational KB that THIS pass also verified has no route is left out
  # by point 5, so the line must not call it counted (run 4, 2026-11-01: the line said 'still COUNTED' one line above 'reported 0').
  $priorInfoCounted = @($priorInfo | Where-Object { $unroutable -notcontains "$_" })
  if ($priorInfoCounted.Count -gt 0) {
    Log ("scan: " + $priorInfoCounted.Count + " offer(s) a previous pass proved not actionable: " + ($priorInfoCounted -join ', ') +
         " - still COUNTED to dom0, because what we cannot install is not the same as nothing being available")
  }
  # (The class-keyed override that stood here - "under the ESU notice, count self-contained offers only" - is gone: the
  # verified set above is the whole exception, measured, and the notice is built from it rather than the other way round.)
  $script:St.offered = $avail.Count
  $script:St.actionable = $actionableCount
  # ---- WU-SCAN-COUNT-END
  $script:St.remaining = $actionableCount; Save
  Log ("scan: $($avail.Count) update(s) offered, $actionableCount actionable, $reportCount reported to dom0" + $(if($unroutable.Count -gt 0){ "; " + $unroutable.Count + " verified no route this pass (" + ($unroutable -join ',') + ") - see notice" }else{ '' }))
  if ($script:St.notice) { Log ("SERVICING NOTICE: " + $script:St.notice) }
  Report-Availability $reportCount    # -> dom0 Qube Manager (default-allowed for TemplateVMs)

  # Applied AFTER reporting: dom0 must always hear the true number of available updates. -OnlyKb
  # narrows what THIS pass acts on, it does not narrow what the guest admits to.
  if ($OnlyUid.Count -gt 0) {
    $before = $avail.Count
    # Match on the UpdateID, and accept either "uid" or "uid:rev" - the identity is structured, so
    # this compares fields rather than parsing a string the catalog may return in any language.
    $avail = @($avail | Where-Object {
                 $u = "$($_.uid)"; $ur = "$($_.uid):$($_.rev)"
                 @($OnlyUid | Where-Object { $_ -eq $u -or $_ -eq $ur }).Count -gt 0 })
    Log ("-OnlyUid " + ($OnlyUid -join ',') + ": acting on $($avail.Count) of $before offered update(s)")
  }
  if ($OnlyKb.Count -gt 0) {
    $before = $avail.Count
    $avail = @($avail | Where-Object { $k = $_.kb; @($OnlyKb | Where-Object { $k -match $_ }).Count -gt 0 })
    Log ("-OnlyKb " + ($OnlyKb -join ',') + ": acting on $($avail.Count) of $before offered update(s)")
    # A KB that is no longer OFFERED (because it is already installed) can still be interrogated -
    # that is how you price a package after the fact. Allowed for `resolve` ONLY: resolve reads
    # catalog metadata and sizes, it downloads and installs nothing, so this can never push an
    # update onto a guest that Windows did not offer.
    if ($avail.Count -eq 0 -and $Action -eq 'resolve') {
      foreach ($k in $OnlyKb) {
        if ($k -match '^(KB\d+)$') {
          $avail += [pscustomobject]@{ kb = $Matches[1]; title = '(forced resolve - not currently offered)' }
        }
      }
      Log ("forced resolve of " + ($avail | ForEach-Object { $_.kb }) -join ',')
    }
  }

  if ($Action -eq 'wuinstall') {
    # NO EARLY RETURN. This installed through Windows Update and then returned straight out, skipping
    # the end-of-pass availability re-report 350 lines below - so dom0 kept the number the PRE-INSTALL
    # scan computed, with everything this action had just installed still inside it. It is the sixth of
    # the six .msu-route miscounts (WUMSUROUTENEVERSAYSUNVERIFIED) and the only one left open. No caller
    # passes -Action wuinstall (measured 2026-11-08: the only occurrences in the tree are this
    # ValidateSet, this branch and the frozen prime-job copies), so it is reached by hand and the stale
    # number self-corrects at the boot scan or inside the 6-hourly interval - which is why it is a P2,
    # not a reason to leave it wrong.
    # THE RE-REPORT IS REUSED, NOT COPIED. Everything this branch used to do itself - Protect-Autologon,
    # phase=done, Complete-Pass - is the shared tail of this same try block. The four blocks in between
    # are each gated on BOTH `$Action -in 'install','full'` AND a non-empty $script:WuFallbackKbs or
    # $script:WuOnlyExpressKbs, which only the offer loop fills and a wuinstall pass never enters, and
    # the offer loop itself is gated on an $Action this is not. So falling through reaches exactly one
    # more block than before, and that block is the fix.
    $script:St.result = Install-ViaWU
    Log 'WU-native install finished; re-reporting availability below'
  }

  # KBs the catalog cannot serve; handed to the Windows Update installer after the loop.
  $script:WuFallbackKbs = @()
  # KBs Windows Update publishes ONLY as Delivery-Optimization express streams (KB5071959-class) and the Catalog has no
  # package for: not installable on a netvm-free guest, reported honestly after the loop - informational only when the
  # Catalog's answer was a valid page (Test-CatalogProvedNoPackage), outstanding when it was not.
  $script:WuOnlyExpressKbs = @()
  if ($env:QUBES_UPDATES_FAKE_FALLBACK_KB) {
    $script:WuFallbackKbs += $env:QUBES_UPDATES_FAKE_FALLBACK_KB
    Log ("QUBES_UPDATES_FAKE_FALLBACK_KB=" + $env:QUBES_UPDATES_FAKE_FALLBACK_KB + " - pretending that KB needs the Windows Update fallback")
  }
  if ($Action -in 'resolve','download','full','install') {
    # THE .msu ROUTE IS TWO-PHASE (2026-10-04, docs/ADR-updater.md section 13). This loop still resolves and fetches every offer in
    # offer order, and the agent route and the drivers still install right here, where 4.3.33 was measured working. Only the catalog
    # .msu are not installed here: they are queued in $plan, and Install-MsuPlan (WU-PASS-ORDER) runs them after the loop, the
    # cumulative first. In offer order 4.3.33 staged .NET first and its one-package rule then deferred the cumulative to a second
    # restart (reporter's environment, 2026-10-03/04).
    $plan = @()
    foreach($u in $avail){
      if($u.kb -notmatch '^KB\d+'){
        # ---- WU-NOKB-BEGIN
        # GUARD:nokbinfo - an offer with no KB (a vendor driver, e.g. "Microsoft Corporation
        # AudioProcessingObject Driver Update") cannot be resolved through the update CATALOG,
        # because the catalog search is keyed on the KB number. That much is structural.
        #
        # BUT THE CATALOG IS NOT THE ONLY ROUTE, and this is where it was wrong. Get-Available
        # computes content_class and direct_urls for EVERY offer from the live IUpdate, so a no-KB
        # offer can perfectly well be 'self-contained' WITH a working download URL - installable
        # through the proxy with no catalog involved. The old code skipped on the SHAPE of the KB
        # field before ever looking at direct_urls, and so threw away an update it was holding the
        # means to install, then told dom0 it was not actionable. Jev put 0.80 on a genuinely
        # installable update legitimately lacking a KB; this is that case, in this code.
        # So: look for a route before declaring there is none.
        $nokb = if($u.title){ [string]$u.title } else { 'untitled offer' }
        $nokbUrls = @(@($u.direct_urls) | Where-Object { $_ })
        if($nokbUrls.Count -gt 0 -and $Action -in 'install','full'){
          Log "no KB but $($nokbUrls.Count) static content URL(s) - installing through the agent's own installer: $nokb"
          $script:St.result += (Install-ViaAgentCache $u)
          Save
          continue
        }
        # No KB and no self-contained URL - but the CATALOG may still hold it under its title.
        # Resolve-DriverByTitle downloads each identically-titled candidate and picks on the
        # architecture the package declares, because that is the only thing that differs between
        # them. The scan's route proof asked first (one ask per title per pass, ADR-updater section 2 point 5 extended 2026-11-06), so
        # this reuses its answer; only on an install action is anything installed.
        if($Action -in 'install','full'){
          Log "no KB and no direct URL - trying the catalog by title: $nokb"
          $drv = Resolve-DriverByTitle $nokb
          if($drv -and $drv.unresolved){   # GUARD:nokbunresolved - the title search was not answered: outstanding, never the skip below
            $script:St.result += [ordered]@{ kb=$nokb; title=$nokb; ok=$false; files=@()
                                             reason='catalog title search did not return a valid results page - resolution UNRESOLVED, so this offer stays outstanding rather than being skipped' }
            Save
            continue
          }
          if($drv){
            $drow = Install-DriverCab $drv.file $nokb
            # The row carries WHAT WAS MEASURED, the same rule the Defender row was corrected under
            # on 2026-09-21: this install is verified by `pnputil /enum-drivers` seeing the package
            # in the store afterwards, so the row says so instead of leaving dom0 to infer it from
            # ok=True. Verified on a guest the same day: store matches 0 before, 2 after.
            $script:St.result += [ordered]@{ kb=$nokb; title=$nokb; ok=[bool]$drow.ok
                                             state=$(if($drow.ok){'installed'}else{'failed'})
                                             verified_by_effect=[bool]$drow.verified_by_effect
                                             reason=$(if($drow.ok){'driver resolved from the catalog by title, architecture chosen from the package''s own INF, and seen in the driver store afterwards (pnputil /enum-drivers)'}
                                                      else{'driver resolved from the catalog but pnputil did not put it in the driver store - did NOT install'})
                                             files=@($drow) }
            Save
            continue
          }
          # ROUTED GUEST, ONE ROUTE LEFT: Windows Update's own downloader. A no-KB offer the
          # catalog cannot serve by title is still installable where the guest HAS a default route,
          # and until 2026-11-08 this fell straight through to the not-actionable row below - so
          # dom0 was told N with the offer inside the number on every pass and nothing ever
          # installed it (WUNOKBMISSNOTINSTALLEDONROUTEDGUEST). Handed over BY IDENTITY: -OnlyKbs
          # selects on a KB this offer does not have, and a parsed title is forbidden (section 6).
          if($canWuNative -and $u.uid){
            Log "no KB and no catalog match, but this guest has a route - Windows Update by identity: $($u.uid):$($u.rev)"
            $nokbWuRows = @(Install-ViaWU -OnlyUids @("$($u.uid):$($u.rev)") -TunePolicies $false)
            if($nokbWuRows.Count -gt 0){
              foreach($row in $nokbWuRows){ $script:St.result += $row }
              Save
              continue
            }
            # Windows Update selected nothing for this identity. That is NOT a route proof, so the
            # offer takes the not-actionable row below and stays COUNTED (point 2).
            Log "  Windows Update selected nothing for $($u.uid):$($u.rev) - not-actionable, still counted"
          }
        }
        # Genuinely no route from here - and now that is a MEASURED statement, not an assumption
        # about the catalog.
        Log "skip (no KB, no direct URL, no catalog match for this architecture): $nokb"
        # `reason`, the row-level key every reader takes (dom0's Get-RowWhy, tools/wu-exclusion-evidence.py). Until 2026-11-02 this
        # row alone wrote `info_reason`, and dom0 printed "informational <title>: no reason recorded" (measured with the shipped reader).
        $script:St.result += [ordered]@{ kb=$nokb; title=$nokb; ok=$false; state='not-actionable'; severity='info';
                                         reason='offer carries no KB and no self-contained URL, and the catalog holds no entry with this exact title whose package declares this guest architecture - so there is no route to it from here. Checked, not assumed: the title search runs and each identically-titled candidate is inspected.' }
        Save
        continue
        # ---- WU-NOKB-END
      }
      $script:St.phase='resolve'; Save
      $urls = Resolve-Catalog $u.kb
      Log "$($u.kb): $($urls.Count) catalog .msu"
      # ASK BEFORE DOWNLOADING. The catalog's DownloadDialog returns every file bundled with an
      # update, including SUPERSEDED cumulatives: for KB5121003 it returns kb5043080 (2024-09)
      # alongside the one we want. On a 26100.8875 image the older one is not applicable, DISM
      # rejects it with rc=552, and feeding it to CBS first preceded the cumulative being rolled
      # back at boot with 0x80070490. The KB is in the URL, so this costs no bytes to decide.
      # /Get-PackageInfo cannot help here - measured: it reports the superseded package as
      # "Applicable: Yes, State: Installed, identity OnePackage~~~~0.0.0.0", i.e. nothing usable.
      # Deliberately ABOVE the resolve-only branch: the decision is pure string work on URLs, so
      # `-Action resolve` is a genuine zero-byte dry run of exactly what a download would fetch.
      $digits = ($u.kb -replace '\D', '')
      $matching = @($urls | Where-Object { $_ -match $digits })
      if ($matching.Count -gt 0 -and $matching.Count -lt $urls.Count) {
        Log ("  " + $u.kb + ": " + ($urls.Count - $matching.Count) + " of " + $urls.Count +
             " catalog file(s) are for other KBs - not downloading them")
        # Size the dropped files on a resolve pass. This is the ONLY exact figure for what the
        # filter saves - the payload's internal waste is not knowable from a URL - and it costs
        # one HEAD each, no body.
        foreach ($drop in ($urls | Where-Object { $_ -notmatch $digits })) {
          $nm = if ($drop -match '/([^/?]+\.msu)') { $Matches[1] } else { $drop }
          if ($Action -eq 'resolve') {
            $sz = Get-UrlSize $drop
            Log ("    DROP " + $nm + "  " + $(if($sz -ge 0){ "{0:N1} MB avoided" -f ($sz/1MB) } else { 'size unknown' }))
          } else { Log ("    DROP " + $nm) }
        }
        $urls = $matching
      } elseif ($matching.Count -eq 0) {
        Log ("  " + $u.kb + ": no catalog file names mention the KB - keeping all " + $urls.Count)
      }
      $got=@()
      if ($Action -eq 'resolve') {
        Log "$($u.kb): resolve-only, would fetch $($urls.Count) package(s)"
        $keepTotal = 0
        foreach ($url in $urls) {
          $nm = if ($url -match '/([^/?]+\.msu)') { $Matches[1] } else { $url }
          $sz = Get-UrlSize $url
          if ($sz -ge 0) { $keepTotal += $sz }
          Log ("    KEEP " + $nm + "  " + $(if($sz -ge 0){ "{0:N1} MB" -f ($sz/1MB) } else { 'size unknown' }))
        }
        Log ("  " + $u.kb + ": would transfer {0:N1} MB" -f ($keepTotal/1MB))
        continue
      }
      if ($Action -in 'download','full') {
        $script:St.phase='download'; Save
        # ONE DIRECTORY PER KB. DISM treats the folder holding a package as a source set: with a
        # flat work dir it pulled kb5054156-25h2-ekb.msu - a 25H2 enablement package left by an
        # earlier session - into a 24H2 servicing session (dism.log "LocalSources"). Isolating
        # each KB makes that impossible and keeps resume/reuse working.
        $kbDir = Join-Path $WorkDir $u.kb
        New-Item -ItemType Directory -Force $kbDir | Out-Null
        $i=0; foreach($url in $urls){ $i++; $name="$($u.kb)_$i.msu"; if($url -match '/([^/?]+\.msu)'){$name=$Matches[1]}
          $dst=Join-Path $kbDir $name; if(Fetch-Msu $url $dst $u.kb){ $got+=$dst } }
      } else { $got = @(Get-ChildItem (Join-Path (Join-Path $WorkDir $u.kb) '*.msu') -EA SilentlyContinue | ForEach-Object FullName) }
      # An offered KB that yields NO installable file is a FAILED update, not a quiet success.
      # Measured 2026-08-13: KB5120708 (.NET Framework) resolved to zero catalog .msu on a 25H2
      # guest - Resolve-Catalog is written around the x64/24H2/26100 client build - and because
      # nothing was downloaded there was no result row, so the pass reported "count=1" and exit 0
      # while installing nothing. dom0 must hear about that.
      if ($Action -in 'install','full' -and $got.Count -eq 0) {
        $why = if ($urls.Count -eq 0) { 'no catalog entry matches this Windows version/architecture' }
               else { "resolved $($urls.Count) package(s) from the catalog but none could be downloaded" }
        # Before calling it failed: some updates have no .msu for the DISM path to install.
        # CHECKED against the Update Catalog on 2026-08-15 rather than assumed:
        #   KB890830  (Malicious Software Removal Tool) IS in the catalog - 26 rows - but ships
        #             as an .exe, and Resolve-Catalog accepts only .msu because DISM does.
        #   KB2267602 (Defender definitions) is NOT in the catalog at all ("We did not find any
        #             results"); it is delivered through Windows Update / the security
        #             intelligence mpam-fe.exe.
        # Neither is a defect - it is how those products are packaged - but both would be
        # reported failed on every pass, leaving dom0 showing updates that never clear.
        # Hand exactly those to WU's own installer after this loop.
        if ($urls.Count -eq 0) {
          # The catalog has no .msu for this KB. Route by the content class computed at scan time (Get-WuContentClass):
          $cls = $u.content_class
          if ($cls -eq 'self-contained') {
            # Every leaf Windows Update offers for it is a static file (Defender signatures and platform, MSRT, the Windows Security
            # platform, SSU / .NET cabs): the agent's OWN installer installs it from content fetched through the proxy - no DO/BITS/NLA,
            # and no switch of ours. This is the class that failed every pass before 2026-08-20, and whose .exe files this updater then
            # ran itself, with '/q', until 2026-10-03.
            Log "$($u.kb): not in the catalog; Windows Update offers it as static content - the agent's installer installs it from content supplied through the proxy (no DO/BITS/NLA)"
            $script:St.phase='install'; Save
            $arow = Install-ViaAgentCache $u
            $script:St.result += $arow
            Save
            Log "$($u.kb): agent-cache install ok=$($arow.ok) state=$($arow.state)"
            continue
          }
          if ($cls -eq 'express') {
            # KB5071959-class: published ONLY as Delivery-Optimization delta streams. Not installable
            # on a netvm-free guest and it carries no content the catalog CU does not. Classify it
            # terminally - never chase it into the DO/BITS path that would fail forever.
            #
            # READ THE CONDITION ABOVE BEFORE BELIEVING THAT SENTENCE (corrected 2026-10-08). This
            # branch is reached ONLY when Resolve-Catalog already returned zero rows, so it does not
            # and cannot refuse an express-offered update that the catalog does publish - the catalog
            # is tried first, for every KB. The sentence is nonetheless FALSE AS A GENERAL RULE
            # (Jev 0.93): KB5101684, an express-offered preview cumulative, is catalog-published as a
            # monolithic package and the shipped resolver picks it. It holds for KB5071959, which is
            # the ESU phantom OOB the owner parked, and that is the class this branch was written
            # around. What actually hid KB5101684 from the reporter was the scan COUNT, not this
            # branch (GUARD:truecount, above).
            $script:WuOnlyExpressKbs += $u.kb
            Log "$($u.kb): published only as Delivery-Optimization express/UUP streams and absent from the Catalog - the route gate after the loop decides (the Windows Update installer on a routed guest, an informational row on a routeless one)"
            continue
          }
          # class 'none'/unknown: only a guest that actually has a route may try the WU installer.
          $script:WuFallbackKbs += $u.kb
          Log "$($u.kb): no catalog .msu and no static WU URL - deferring to the Windows Update installer (route permitting)"
          continue
        }
        $script:St.result += [ordered]@{ kb=$u.kb; ok=$false; files=@(); reason=$why }
        Save
        Log "$($u.kb): NO installable package resolved - reporting as failed"
      }
      if ($Action -in 'install','full' -and $got.Count -gt 0) {
        # Not installed here: queued for Install-MsuPlan (WU-PASS-ORDER), which runs the .msu after this loop, the cumulative first,
        # and builds the per-KB row (Get-MsuKbVerdict).
        Log "$($u.kb): $($got.Count) package file(s) on disk - queued for DISM (WU-PASS-ORDER decides the order)"
        $plan += [ordered]@{ u=$u; label=$u.kb; got=@($got) }
      }
    }
    if ($Action -in 'install','full' -and $plan.Count -gt 0) { Install-MsuPlan $plan }
  }
  # Updates that are not catalog packages: install them the only way they CAN be installed.
  #
  # NOT if this session already staged something. CBS applies exactly ONE staged session per
  # boot and silently discards anything staged behind it (measured twice, 2026-08-14, with
  # RebootPending confirmed and TiWorker idle - it is not a shutdown race). The catalog path
  # already stops for that reason; letting Windows Update install into the same session
  # afterwards would walk straight back into it, and the discarded package would be reported
  # as installed. dom0 drives a second pass, which is where these belong.
  # The Windows Update installer (Install-ViaWU) downloads through Delivery Optimization / BITS, which
  # REFUSE on a guest with no route (measured DO 0x80D03805 / BITS 0x80200010) - so on a netvm-free
  # guest this rung only manufactures phantom 0x80240022 failures. canWuNative is the guest's ability to
  # ever install these: a real default route (netvm-attached standalone) or the explicit override.
  # ADR-updater section 2 point 5, third fact: a guest WITH a default route has a route for express-only content too - Windows Update's
  # own downloader - so on it those offers are work for the Windows Update installer with the rest of the fallback set, not a ceiling to
  # report. Only a routeless guest reaches the express gate below, where all three facts hold and the row may say so.
  if ($canWuNative -and $script:WuOnlyExpressKbs.Count -gt 0) {
    $why = if ($script:HasDefaultRoute) { 'this guest has a default route' } else { 'QUBES_UPDATES_ALLOW_WU_NATIVE=1 forces the Windows Update installer' }
    Log ("express-only offer(s) " + ($script:WuOnlyExpressKbs -join ',') + ": " + $why + ", so the Windows Update installer takes them instead of an informational row")
    $script:WuFallbackKbs += $script:WuOnlyExpressKbs
    $script:WuOnlyExpressKbs = @()
  }
  # DEFER only makes sense when the guest CAN install them next pass (canWuNative): CBS applies exactly
  # ONE staged session per boot, so a second WU-native install this pass would be silently discarded.
  # On a netvm-free guest (no route) they are never installable, so skip the deferral and let the
  # informational block below classify them honestly instead of promising a "next pass" that never installs.
  if ($Action -in 'install','full' -and $script:WuFallbackKbs.Count -gt 0 -and $canWuNative -and
      ($script:StagedThisSession -or $script:St.reboot_needed) -and -not $env:QUBES_UPDATES_ALLOW_MULTISTAGE) {
    foreach ($kb in $script:WuFallbackKbs) {
      $script:St.result += [ordered]@{ kb=$kb; ok=$false; files=@()
                                       reason='deferred: a reboot-requiring package is already staged this session; the next pass installs this' }
    }
    Save
    Log ("Windows Update fallback DEFERRED for " + ($script:WuFallbackKbs -join ',') +
         " - something is already staged this session and CBS would discard a second one")
    $script:WuFallbackKbs = @()
  }
  if ($Action -in 'install','full' -and $script:WuFallbackKbs.Count -gt 0 -and -not $canWuNative) {
    $script:WuFallbackKbs = @($script:WuFallbackKbs | Sort-Object -Unique)
    foreach ($kb in $script:WuFallbackKbs) {
      # severity='info': the three facts of ADR-updater section 2 point 5 hold for these - the Catalog's valid page resolved no
      # package (checked below), the content is not self-contained (that is how they got here), and the guest has no default
      # route (-not canWuNative, above) - so the row names them (Get-NoRouteReason) and is left out of the count dom0 hears.
      # GUARD:catalogvalid - but ONLY when the catalog actually answered. If the search response
      # could not be validated as a results page then "no catalog .msu" is an UNKNOWN, not a fact,
      # and an unknown must never buy a permanent exclusion from dom0's count.
      if (-not (Test-CatalogProvedNoPackage $kb)) {
        Log ("  " + $kb + " : NOT classified informational - the catalog search for it was UNRESOLVED, so 'no package' is unproven")
        $script:St.result += [ordered]@{ kb=$kb; ok=$false; files=@()
          reason='catalog search did not return a valid results page - resolution UNRESOLVED, so this KB stays outstanding rather than being excluded' }
      } else {
      $script:St.result += [ordered]@{ kb=$kb; ok=$false; severity='info'; files=@()
        reason=(Get-NoRouteReason $kb (Get-OfferContentClass $kb)) }
      }
    }
    Save
    Log ("Windows Update native installer SKIPPED (informational) for " + ($script:WuFallbackKbs -join ',') +
         " - no default route; DO/BITS would fail routeless (set QUBES_UPDATES_ALLOW_WU_NATIVE=1 to force)")
    $script:WuFallbackKbs = @()
  }
  if ($Action -in 'install','full' -and $script:WuFallbackKbs.Count -gt 0) {
    $script:WuFallbackKbs = @($script:WuFallbackKbs | Sort-Object -Unique)
    Log ("Windows Update fallback for " + ($script:WuFallbackKbs -join ',') + " (no .msu for the DISM path)")
    try {
      $wuRows = Install-ViaWU -OnlyKbs $script:WuFallbackKbs -TunePolicies $false
      foreach ($row in $wuRows) { $script:St.result += $row }
      $done = @($wuRows | Where-Object { $_.ok }).Count
      Log "Windows Update fallback: $done of $($script:WuFallbackKbs.Count) installed"
      # Install-ViaWU sets St.reboot_needed when Windows asks for one. Say so here too: a
      # definition update normally needs no reboot, and if one of these ever does, that is
      # exactly the fact the next pass has to know about.
      if ($script:St.reboot_needed) { Log 'Windows Update fallback: a reboot is required to finish' }
      # Anything the fallback did not cover is still a failure, and dom0 must hear it.
      foreach ($kb in $script:WuFallbackKbs) {
        if (-not (@($wuRows | Where-Object { $_.kb -eq $kb }).Count -gt 0)) {
          $script:St.result += [ordered]@{ kb=$kb; ok=$false; files=@()
                                           reason='no .msu for the DISM path, and the Windows Update installer did not offer it either' }
        }
      }
      Save
    } catch {
      Log "Windows Update fallback failed: $($_.Exception.Message)" 'ERROR'
      foreach ($kb in $script:WuFallbackKbs) {
        $script:St.result += [ordered]@{ kb=$kb; ok=$false; files=@(); reason="Windows Update fallback failed: $($_.Exception.Message)" }
      }
      Save
    }
  }

  # The express gate (KB5071959-class, on a routeless guest). Windows Update publishes them only as Delivery-Optimization
  # streams and the Catalog has no package for them, so no path of ours can install them on a guest with no default route: report
  # that, as a ceiling VERIFIED this pass, instead of failing them forever. Verified means the Catalog answered a valid results page
  # for THIS kb (Test-CatalogProvedNoPackage) - an UNRESOLVED answer leaves the KB outstanding, exactly as the fallback gate
  # above does, because an unknown must never buy an informational row (GUARD:catalogvalid). Whatever the licensing story
  # behind such an offer (the ESU enrollment OOB on an unenrolled Win10 22H2 guest is the measured instance), the row says
  # what was measured; the ESU licence state travels beside it as information (St.esu, read at scan).
  if ($Action -in 'install','full' -and $script:WuOnlyExpressKbs.Count -gt 0) {
    $script:WuOnlyExpressKbs = @($script:WuOnlyExpressKbs | Sort-Object -Unique)
    foreach ($kb in $script:WuOnlyExpressKbs) {
      if (-not (Test-CatalogProvedNoPackage $kb)) {
        Log ("  " + $kb + " : NOT classified informational - the catalog search for it was UNRESOLVED, so 'express-only with no package' is unproven")
        $script:St.result += [ordered]@{ kb=$kb; ok=$false; files=@()
          reason='catalog search did not return a valid results page - resolution UNRESOLVED, so this KB stays outstanding rather than being excluded' }
        continue
      }
      # severity='info' marks this as INFORMATIONAL, not a failure: it is excluded from the failed/remaining count reported
      # to dom0 (see below), so a KB the guest can never apply routeless does not read as a broken update forever.
      $script:St.result += [ordered]@{ kb=$kb; ok=$false; severity='info'
        reason=(Get-NoRouteReason $kb 'express') }
    }
    Save
    Log ("express-only offers with no route on this guest (informational, verified this pass): " + ($script:WuOnlyExpressKbs -join ',') +
         $(if($script:St.esu){ " ; ESU=$($script:St.esu)" }else{ '' }))
  }

  # Re-report availability at the END of an install pass, so dom0's "updates available" marker
  # reflects reality instead of the pre-install scan. Two cases:
  #  - a reboot is pending: Windows keeps offering the KB until it boots, so any count now would
  #    be a lie. We are rebooting anyway, and the boot scan task (BootTrigger + 2 min) reports
  #    the truth - the same shape as Linux's upgrades-status-notify after an update. That boot
  #    scan is a -Scheduled pass; the debounce at the top of this file exempts it while the
  #    previous status is reboot-pending, because without the exemption it was skipped every time.
  #  - nothing pending: rescan now and report, or the flag stays set until the next 6-hourly scan.
  # 'wuinstall' IS HERE for the same reason the other three gates exclude it: this is the only block a
  # WU-native pass must still run, and it ran none of it until 2026-11-08.
  if ($Action -in 'install','full','wuinstall') {
    if ($script:St.reboot_needed) {
      # Everything offered was applied; the reboot is ours to perform and happens immediately
      # after this pass. Windows keeps listing the KB as "available" until it boots, but that is
      # a Windows artefact - from dom0's point of view the update IS applied, so clear the flag
      # now rather than leaving the qube marked for minutes. Anything that did NOT install is
      # still reported, and the boot scan re-reports the truth either way, so a wrong guess here
      # self-corrects within ~2 minutes of the restart.
      # COUNT BY KEY (Test-RowKey), never by PSObject.Properties.Name: the rows are [ordered]
      # dictionaries, and on those that property list never contains 'kb', so the old predicate
      # matched nothing and this reported 0 on EVERY reboot-pending pass. Measured 2026-09-16 on
      # German Win11 25H2 (4.3.29): result row kb=KB5129195 ok=false state=deferred (the 4.4 GB
      # September cumulative, downloaded, waiting for the .NET reboot), "remaining": 0 written,
      # dom0's updates-available cleared - Qube Manager then showed the qube as up to date.
      # ---- WU-REBOOT-PENDING-REPORT-BEGIN
      # A STAGED OR DEFERRED ROW IS NOT APPLIED. The comment above says "everything offered was
      # applied", and for a row that INSTALLED that is true - but a staged package has been written
      # to the image and needs exactly the reboot that is pending, and a deferred one has not been
      # installed at all. Both carry ok=$true or ok=$false with a `state`, and the old predicate
      # counted only `-not $_.ok`, so a staged cumulative reported ZERO.
      #
      # Measured 2026-09-21 on win11de-ctld, GWeck's environment: KB5129195 came back
      # `ok=true state=staged` with reboot_needed=true and this path reported 0 to dom0, which then
      # showed the template as up to date - the ORIGINAL field report, surviving in a THIRD code
      # path after GUARD:rowkey fixed it here and GUARD:stagedpending fixed it in the post-install
      # rescan. The oscillation check caught it independently: dom0 '<empty>' after the pass and
      # '1' after the very next scan. (# GUARD:stagedpending, reboot-pending half.)
      # AN INFORMATIONAL ROW STILL COUNTS (ADR-updater section 2 point 2) unless this pass's route proof verified its offer has
      # no route (point 5, St.unroutable, written by this pass's scan): the WU-NOKB skip measures no route, and until 2026-11-02
      # it was left out here while the next scan counted it.
      $unroutablePass = @($script:St.unroutable | Where-Object { $_ })
      $pendingKbs = @($script:St.result |
                     Where-Object { (Test-RowKey $_ 'kb') -and -not (Test-RowInstalled $_) -and -not ("$($_.severity)" -eq 'info' -and $unroutablePass -contains (Get-OfferRouteKey $_)) })   # GUARD:rowkey
      # NO FLOOR. An earlier version of this fix forced at least 1 whenever a reboot was pending,
      # even with nothing staged or deferred - which would pin dom0 at "updates available" forever
      # on a guest carrying a stale CBS RebootPending and nothing to install. That is the inverse
      # defect the owner reported (a template that can never show as up to date), so the rule is
      # exactly "count what is not applied" and nothing more. Jev ruled on staged packages
      # (count-staged 0.97); the floor was mine and is withdrawn.
      $pendingCount = $pendingKbs.Count
      # GUARD:offeridentity at this end of a pass too: what THIS pass installed and proved installed (the Defender signatures
      # beside a staged cumulative) is recorded, so the boot scan does not count it again if Windows re-presents it.
      $script:St.satisfied = @(Get-InstalledIdentities (Get-InstalledKeys))
      $script:St.remaining = $pendingCount; Save
      Log "reboot pending; reporting $pendingCount remaining to dom0 (staged and deferred work is NOT applied)"
      Report-Availability $pendingCount
      # ---- WU-REBOOT-PENDING-REPORT-END
    } else {
      # Best-effort: this is a REPORT, not the work. It needs the proxy, and if anything has
      # taken the proxy away (measured: a concurrent scan's Remove-Proxy) Get-Available throws
      # 0x80240438 - which used to propagate and mark a pass that had installed everything
      # successfully as phase=error.
      try {
        $after = Get-Available
        # The route proof again, over the RESCAN's offers (WU-ROUTE-PROOF): memoised KBs cost nothing, a newly offered KB is
        # asked now. What this pass verified has no route is left out below; the ESU state is re-read as information.
        $script:St.esu = Get-EsuStatus
        $afterProof = Measure-Unroutable @($after | Where-Object { -not $_.is_definition })
        $script:St.unroutable = @($afterProof.none)
        $script:St.route_unknown = @($afterProof.unknown)
        $script:St.notice = Get-ServicingNotice $script:St.unroutable $script:St.esu
        # GUARD:actioned - dom0's count is what the ADMIN still has to do. An offer THIS PASS installed and proved installed
        # (ADR-updater section 2 point 3) drops out of it: measured 2026-09-20 on the German 25H2 guest, after a pass that
        # INSTALLED KB5007651 and found the Defender signatures current, both were still offered and both still counted, so dom0
        # sat at "updates available" for work already done. Key on kb AND title: a no-KB row is recorded under its TITLE.
        # Rows with ok=$false stay counted, which is what keeps a DEFERRED cumulative visible - the control that must never be
        # excluded.
        # ---- WU-INFO-EXCLUDE-BEGIN
        # WHAT EARNS AN OFFER ITS SILENCE (ADR-updater section 2). Two things only: an offer this pass INSTALLED and proved
        # installed (point 3, Test-RowInstalled), and an offer the rescan's own route proof just VERIFIED has no route (point 5,
        # unroutableAfter below). An INFORMATIONAL row is still COUNTED (point 2): until 2026-11-02 every severity='info' row
        # dropped out here and its offer identity went into `satisfied`, so a no-KB offer the scan counts (WU-NOKB measures no
        # route) made dom0 hear N-1 after the pass and N at the next scan, or nothing for ever once `satisfied` remembered it
        # (WUINFOIDENTITYREMEMBERED: run 9 on win10-tup reported 0 where the scan's own line said 2). A STAGED or DEFERRED row
        # is not installed either - it is work written to the image that needs a reboot to become real.
        #
        # GUARD:stagedpending. Measured 2026-09-21 on the PRE-TUESDAY CONTROL, and only the control
        # could see it: KB5129195 came back ok=true state=staged with reboot_needed=true, the bare
        # `$_.ok -eq $true` swept it into the excluded set, remaining went to 0 and dom0 was told
        # the template was UP TO DATE while a cumulative sat waiting for a reboot. That is the
        # field report's own defect (ADR section 2), reintroduced through the door opened to fix
        # its opposite. On an already-updated guest this bug is invisible, which is the whole
        # argument for running both controls against one build.
        $installedKeys = @(Get-InstalledKeys)
        # AND THE OFFER'S OWN IDENTITY DECIDES FIRST, where it has one (GUARD:offeridentity, this end).
        # The kb/title join alone cannot answer for a no-KB offer: every one of them is labelled
        # '(no KB)' by Get-Available and by Install-ViaWU's rows alike, so the join either matched ALL
        # of them off one install (measured: two offered, one installed, dom0 told ZERO - the guest
        # read as up to date with a driver update outstanding) or, once that label stops being a key,
        # matches NONE and counts the installed one again (told 2 where 1 is true). Neither is the
        # number. Install-ViaWU stamps uid/rev on the rows it returns and Get-Available carries uid/rev
        # on the offers, so the identity is already on both sides - the same set this block computes a
        # few lines below for St.satisfied, hoisted so the count can use it instead of guessing.
        $installedIds = @(Get-InstalledIdentities $installedKeys)
        $notInstalled = { param($r)
          $rid = $(if ((Test-RowKey $r 'uid') -and $r.uid) { "$($r.uid):$($r.rev)" } else { $null })
          (-not ($rid -and $installedIds -contains $rid)) -and
          ($installedKeys -notcontains $r.kb) -and ($installedKeys -notcontains $r.title) }
        # ...and the offers THIS pass verified have no route (St.unroutable, WU-ROUTE-PROOF) - the one measured exception
        # (ADR-updater section 2, point 5); the class-keyed notice branch that stood here is gone.
        $unroutableAfter = @($script:St.unroutable | Where-Object { $_ })
        $reportCount = @($after | Where-Object { (& $notInstalled $_) -and ($unroutableAfter -notcontains (Get-OfferRouteKey $_)) }).Count
        # STAGED WORK STILL COUNTS even when Windows has stopped offering it - it is written to the
        # image and not applied until the restart. Counted from the RESULT rows, not from what the
        # rescan still offers. No blanket floor on reboot_needed: forcing >=1 with nothing staged
        # would pin dom0 at "updates available" on a stale CBS RebootPending, which is the inverse
        # defect. (Jev: count-staged 0.97; under-reporting is the worse error at 0.99.)
        $stagedN = @($script:St.result | Where-Object { (Test-RowKey $_ 'state') -and (@('staged','deferred') -contains [string]$_.state) }).Count
        if ($stagedN -gt $reportCount) { $reportCount = $stagedN }
        # GUARD:offeridentity - record WHICH OFFERS this pass resolved, by the offer's own identity.
        # A later scan may then exclude the very same offer without weakening the rule right above
        # it ("installed last time" is not evidence a FRESH offer is satisfied): a new revision has
        # a different identity and is counted again. An offer with no identity records nothing, so
        # the fallback is always "count it".
        # INSTALLED identities only (point 3): an informational offer is measured again by the next scan's route proof (point 5),
        # never remembered here.
        $script:St.satisfied = $installedIds
        # ---- WU-INFO-EXCLUDE-END
        $script:St.remaining = $reportCount; Save
        Log ("post-install rescan: $($after.Count) offered; $reportCount actionable to dom0" + $(if($unroutableAfter.Count -gt 0){ ' (' + $unroutableAfter.Count + ' verified no route this pass - see notice)' }else{ '' }))
        if ($script:St.notice) { Log ("SERVICING NOTICE: " + $script:St.notice) }
        Report-Availability $reportCount
      } catch {
        Log "post-install rescan failed (updates are installed; availability will be re-reported by the next scan): $($_.Exception.Message)"
      }
    }
  }

  Protect-Autologon
  $script:St.phase='done'; Complete-Pass
  Log 'done'
} catch {
# ---- WU-MAIN-CATCH-BEGIN   (tools/tests/wu-catch-scope-test.ps1 runs this region at SCRIPT scope)
  # NOT 'error' YET. guest/wu-update.ps1 - dom0's view of this pass - polls this status every 3 s and renders the FIRST terminal
  # phase it reads. Publishing phase=error here with the bare exception, and the measured reason ~3 s later (after the proxy probe
  # below), let dom0 print the bare text: measured 2026-10-02 on GWeck's environment (rz31), dom0 got "update failed: Ausnahme von
  # HRESULT: 0x8024402C" while this status ended with the reason and the restart request. 'diagnosing' is not terminal, so the handler
  # keeps waiting; a pass that dies in it is still caught by the handler's dead-pass guard. The raw message is saved now so that a
  # failure inside the diagnosis cannot lose it; the terminal phase is published once, at the end of this region.
  # THE MESSAGE IS READ ONCE AND REUSED. This read demonstrably works: on the 2026-10-08 failure the
  # status carried the correct "Ausnahme von HRESULT: 0x8024402C", so $_ was intact here. The
  # diagnosis below then read $_.Exception.Message AGAIN and its 0x8024402C branch did not run - the
  # saved status kept this raw message instead of the measured reason, and no restart was requested.
  # Five candidate mechanisms for that second read failing were refuted by measurement (on the
  # guest's own Windows PowerShell 5.1.26100.7920 with a real COMException: $_ survives a function
  # call, a nested try/catch, a failing Add-Content inside Log's empty catch, and ScriptStackTrace
  # and InvocationInfo stay populated; Test-ProxyServesWu cannot throw - it returns "unreachable").
  # The mechanism is still unknown, so the DEPENDENCY is removed rather than explained: one read,
  # into a script-scope variable, and everything downstream uses that. tools/tests/
  # wu-catch-scope-test.ps1 asserts the region reads it exactly once.
  $script:ErrMsg = "$($_.Exception.Message)"
  $script:St.phase='diagnosing'; $script:St.error=$script:ErrMsg; Save
  try {   # ...finally below: the terminal phase is published exactly once, whatever the diagnosis (or its logging) does
  Log "[ERROR] $($script:St.error)"
  # WHERE it threw, not just what it said. Measured 2026-09-21: an install pass died with
  # "Dieser Vorgang wird fuer einen relativen URI nicht unterstuetzt" and the log named no line,
  # no function and no call path - so locating a one-line defect needed a second guest run and a
  # code read. The message alone is not a diagnosis; the site is free to record and the exception
  # already carries it.
  try {
    $ii = $_.InvocationInfo
    if ($ii) { Log ("ERROR-SITE line $($ii.ScriptLineNumber): " + (("$($ii.Line)" -replace '\s+',' ').Trim())) }
    # NOT $st: PowerShell names are case-insensitive, and at script scope $st IS $script:St, the status object. Measured 2026-10-02
    # on GWeck's environment: this line (e6037f5d, 09-21 23:11) turned the status into a string, so the 0x8024402C remedy one hour
    # older (f81aae77) died on its first $script:St.error assignment - no restart requested, no reason given to dom0, in every
    # release since. tools/tests/wu-catch-scope-selftest.sh runs this catch at script scope and fails if it comes back.
    $stackText = "$($_.ScriptStackTrace)"
    if ($stackText) { foreach($l in ($stackText -split "`n" | Select-Object -First 4)) { Log ("ERROR-STACK " + $l.Trim()) } }
  } catch { }
  $msg = $script:ErrMsg
  $probeResult = if ($msg -match '8024402C') { Test-ProxyServesWu } else { '' }
# ---- WU-DIAGNOSE-REASON-BEGIN
  # GUARD:reasonmeasured - the decision half. 0x8024402C is WU_E_PT_WINHTTP_NAME_NOT_RESOLVED, and
  # on a routeless guest it has TWO very different causes that dom0 must not be left to guess
  # between: our proxy was genuinely not usable, or Windows Update did not use it. The probe above
  # separates them, and each branch reports only what was measured.
  #
  # NO DURATION IS CLAIMED. Three subjects cleared this state at uptimes that only bracket a
  # quarter of an hour; Jev graded a fixed-delay claim at 0.25, so the text says it clears by
  # itself and stops there. And no retry happens here: the next pass searches normally, which is
  # the reporting model, not a loop that hides the state from dom0.
  if ($msg -match '8024402C') {
    if ($probeResult -match '^reachable status=(\d+)') {
      $httpStatus = $matches[1]
      # ---- WU-PROXYSTATE-REMEDY-BEGIN
      # GUARD:proxystateremedy - REPORTING THE REASON IS NOT HANDLING IT. The admin asked for an
      # update and got none, and "it clears by itself" gives them nothing to do. One remedy IS
      # measured: a RESTART clears this immediately - two subjects searched normally at 62 s and
      # ~150 s of uptime after a reboot, while the same guests failed for a quarter of an hour
      # before it. So this asks for the restart through the channel that already exists and is
      # already accounted (reboot_needed; ADR section 8 counts performed against requested), and
      # section 10 governs the rest: the guest REQUESTS, it never takes.
      #
      # ONCE PER BOOT, and the stamp is what makes that true rather than hoped. If a restart has
      # already been requested for this reason in THIS boot and the state is still here, asking
      # again would be a reboot loop dressed as a remedy - so the second time it reports and stops.
      # That is also the honest answer if the remedy ever stops working.
      $bootNow = $null
      try { $bootNow = (Get-CimInstance Win32_OperatingSystem -EA Stop).LastBootUpTime.ToUniversalTime().ToString('o') } catch { }
      $askedFor = $null
      try { $askedFor = (Get-ItemProperty 'HKLM:\SOFTWARE\Qubes\Updates' -EA Stop).ProxyStateRestartAskedBoot } catch { }
      $remedy = ''
      if (-not $bootNow) {
        $remedy = ' A restart clears this state, but this pass could not read the boot time, so it is NOT requesting one.'
      } elseif ($askedFor -eq $bootNow) {
        # WHAT THE MATCHING STAMP ACTUALLY PROVES: the restart has NOT HAPPENED. A restart moves the
        # boot time, and the stamp carries the boot it was asked in - so a match means the request
        # is still outstanding, NOT that restarting failed to help. Saying "the remedy stopped
        # working" here would be false in precisely the case that triggers it. (Measured on a guest
        # 2026-09-21: two passes back to back, no restart between them, and the first wording
        # claimed the remedy had failed when nothing had been tried.)
        $remedy = (' A restart was already requested for this in the current boot and has NOT been performed yet, so this pass ' +
                   'is not asking again - the request stands and the pass after the restart searches normally')
      } else {
        try {
          if (-not (Test-Path 'HKLM:\SOFTWARE\Qubes\Updates')) { New-Item -Path 'HKLM:\SOFTWARE\Qubes\Updates' -Force | Out-Null }
          Set-ItemProperty -Path 'HKLM:\SOFTWARE\Qubes\Updates' -Name ProxyStateRestartAskedBoot -Value $bootNow -Type String
          $script:St.reboot_needed = $true
          $remedy = ' A RESTART CLEARS THIS IMMEDIATELY (measured), so this pass requests one; the pass after the restart searches normally'
        } catch {
          $remedy = ' A restart clears this state, but the request could not be recorded (' + ($_.Exception.Message -replace "`r|`n",' ') + '), so none is being made'
        }
      }
      # ---- WU-PROXYSTATE-REMEDY-END
      $script:St.error = ("Windows Update failed with 0x8024402C - it could not resolve its service-registration host - " +
        "while this pass PROVED the update proxy usable at that same moment: WinHTTP through $Proxy reached the same " +
        "endpoint and returned HTTP $httpStatus. So Windows Update did not use the configured proxy for that call. " +
        "Nothing was searched and no update state was reported to dom0." + $remedy)
    } elseif ($probeResult -match '^unreachable') {
      $script:St.error = ("Windows Update failed with 0x8024402C AND the update proxy was not usable from this guest " +
        "either - WinHTTP through ${Proxy}: " + ($probeResult -replace '^unreachable ','') + ". That is a transport " +
        "failure in this pass, not the Windows Update proxy-selection state. Nothing was searched and no update state " +
        "was reported to dom0")
    } else {
      $script:St.error = ("Windows Update failed with 0x8024402C and the proxy-reachability probe did not run, so the " +
        "cause is UNMEASURED in this pass. Nothing was searched and no update state was reported to dom0")
    }
    Save
    Log $script:St.error
  }
# ---- WU-DIAGNOSE-REASON-END
  } finally {
    # The ONE terminal publication: the error is final now (the raw message, or the measured reason that replaced it).
    $script:St.phase='error'; Save
  }
# ---- WU-MAIN-CATCH-END
} finally {
  # Re-arm autologon on ANY exit path that staged a reboot - INCLUDING a throw AFTER staging (e.g.
  # Resolve-Catalog/Fetch failing once a package was already applied rc=3010). Previously this ran
  # only on the success paths, so a staged-then-threw pass left the guest reboot-pending with
  # autologon unarmed = the sign-in lockout (qrexec rc=117, unmanageable qube). Idempotent + guarded.
  Protect-Autologon
  Remove-Proxy   # ALWAYS restore the routeless baseline - see the Ensure-Proxy comment
  if ($script:HaveMutex) { try { $script:Mutex.ReleaseMutex() } catch {} }
}
# Exit-code contract: a pass that errored must NOT exit 0. A dom0 wrapper or a scheduled task's
# LastTaskResult that trusts the exit code would otherwise misread failure as clean success.
if ($script:St.phase -eq 'error') { exit 1 }
