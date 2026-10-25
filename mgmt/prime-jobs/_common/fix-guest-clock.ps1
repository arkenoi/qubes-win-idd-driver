# fix-guest-clock.ps1 - correct a guest clock that boots BEHIND, before the installer's preflight.
#
# WHY THIS EXISTS, MEASURED 2026-10-25 (campaign 40225365779, cell WIN10-clean). The installer
# refused stage 1 and nothing installed:
#     REFUSING to install pv-drivers\xencons-signer.cer - THIS GUEST'S CLOCK IS BEHIND.
#       guest UTC now     : 2026-10-25T18:39:33.7901290Z
#       signer valid from : 2026-10-25T19:10:04.0000000Z  (31 min in this guest's future)
# True UTC at that instant was 19:39:33Z: the guest was exactly 3600 s behind. The refusal is
# CORRECT product behaviour - Windows validates driver catalogs against the system clock and the
# install would HANG on 0x800B0101 rather than fail - so the clock is what has to be fixed.
#
# THE MECHANISM (ETWCLOCKDST in findings/issues.md, measured on a win11r-qwt clk-probe clone).
# `timezone=localtime` puts dom0's LOCAL time on the emulated RTC. At boot Windows converts that
# RTC with the ActiveTimeBias ALREADY STORED in its registry, and only THEN refreshes the bias for
# today - without moving the clock it just set. A base sealed in summer carries bias -180; booted
# after the autumn transition it reads winter local time (UTC+2) as though it were UTC+3, lands an
# hour behind, and STAYS behind, because a guest an hour short of its own 04:00 transition never
# reaches it. Every entry image on this rig was sealed 2026-10-15, i.e. in summer.
#
# WHY A STAMP AND NOT THE RTC. The obvious fix - re-read the hardware clock and re-derive UTC with
# the now-correct bias - does not survive inspection twice over: user mode has no raw CMOS read,
# and Windows WRITES system time back to the RTC, so once the clock is wrong the RTC stops being an
# independent reference. An external true-UTC stamp is the only source that is not already
# contaminated by the defect. prime-run.sh writes it when it stages the job, so it is always newer
# than the package it is staging - which is the invariant that matters: the stamp cannot be older
# than the signer NotBefore of the package it accompanies.
#
# DIRECTION IS LOAD-BEARING: this only ever moves the clock FORWARD. A guest that is AHEAD is left
# alone and said so. Moving a clock backwards invalidates nothing and breaks log ordering, and the
# defect this exists for has exactly one sign.
#
# GUARD:clockstamp DEFECT: a guest booted an hour behind installs nothing, and the reason is a
# refusal 30+ minutes wide that no amount of retrying resolves.
#
# NEVER FATAL. The prime job's verdict belongs to the installer, which states the clock problem
# clearly on its own. If this cannot help, it says so LOUDLY and gets out of the way.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string] $Stamp,       # file holding the host's true UTC, ISO-8601
    [string] $DiagLog = '',                              # optional: a path on the DIAG volume
    [int]    $ToleranceSeconds = 120
)

$inv    = [Globalization.CultureInfo]::InvariantCulture
$styles = [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal

function Say([string]$msg, [string]$level = 'INFO') {
    $line = "[{0}] [{1}] CLOCKSTAMP {2}" -f ([datetime]::UtcNow.ToString('o')), $level, $msg
    Write-Output $line
    if ($DiagLog) { try { Add-Content -LiteralPath $DiagLog -Value $line -ErrorAction Stop } catch { } }
}

if (-not (Test-Path -LiteralPath $Stamp)) {
    # Loud, because a missing stamp means this guest is unprotected against the defect above.
    Say "no stamp at $Stamp - the clock is UNCHECKED on this guest (older stick?)" 'ERROR'
    exit 0
}

$raw = (Get-Content -LiteralPath $Stamp -Raw -ErrorAction SilentlyContinue)
if ($raw) { $raw = $raw.Trim() }
if (-not $raw) { Say "stamp at $Stamp is EMPTY - the clock is UNCHECKED" 'ERROR'; exit 0 }

# Invariant parse. Set-Date and [datetime] both parse with the CURRENT CULTURE, and this product
# ships German goldens (win11de-*) - an ISO-8601 string is not guaranteed to parse under every
# culture. Same reason, same spelling, as core-agent set-time.ps1.
$formats = @(
    "yyyy-MM-ddTHH:mm:ss.fffffffK", "yyyy-MM-ddTHH:mm:ssK", "yyyy-MM-ddTHH:mm:ss.fffK",
    "yyyy-MM-ddTHH:mm:ssZ", "yyyy-MM-ddTHH:mm:ss", "yyyy-MM-dd HH:mm:ss"
)
[datetime]$utc = [datetime]::MinValue
if (-not [datetime]::TryParseExact($raw, $formats, $inv, $styles, [ref]$utc)) {
    if (-not [datetime]::TryParse($raw, $inv, $styles, [ref]$utc)) {
        Say "could not parse '$raw' as a time under the invariant culture - the clock is UNCHANGED" 'ERROR'
        exit 0
    }
}
$utc = [datetime]::SpecifyKind($utc, [DateTimeKind]::Utc)

# THE STAMP IS A PAST INSTANT, AND UPTIME IS THE ONLY HONEST WAY TO CARRY IT FORWARD. It was
# written on the host when the job was staged; the guest then had a stick built, a volume cloned and
# a domain started before this line ran, so setting the clock to the raw stamp would leave the guest
# short by all of that. TickCount64 is a monotonic tick count since boot - it is NOT derived from
# the wall clock, so it is the one quantity on this guest the defect cannot have corrupted. It
# recovers everything after boot; what remains unrecovered is only the host-side gap between
# writing the stamp and the guest starting, which is the smallest residual available without a
# channel. Residual skew is NOT this script's problem to close: once QWT installs, qrexec exists
# and `qtest synctime` sets the clock properly. This exists to clear the signer gate, nothing more.
$uptimeMs = [Environment]::TickCount64
$target   = $utc.AddMilliseconds($uptimeMs)
$before   = (Get-Date).ToUniversalTime()
$skew     = [math]::Round(($target - $before).TotalSeconds, 1)

if ($skew -le $ToleranceSeconds) {
    Say ("clock is sound: guest UTC {0}, stamp {1} + {2} s uptime = {3}, guest is {4} s behind it (tolerance {5} s) - UNCHANGED" -f `
         $before.ToString('o'), $utc.ToString('o'), [math]::Round($uptimeMs/1000), $target.ToString('o'), $skew, $ToleranceSeconds)
    exit 0
}

Say ("guest UTC {0} is {1} s BEHIND host stamp {2} carried forward by {3} s of uptime ({4}) - correcting FORWARD before the installer runs" -f `
     $before.ToString('o'), $skew, $utc.ToString('o'), [math]::Round($uptimeMs/1000), $target.ToString('o')) 'WARN'

try {
    # Set-Date sets the LOCAL clock from the value's components (it ends in Win32 SetLocalTime) and
    # does NOT consult DateTimeKind - handing it a Utc value sets local time to those digits and
    # leaves the guest off by its whole zone offset. Measured and corrected 2026-10-08 in
    # core-agent set-time.ps1; this is that line, not a second spelling of it.
    Set-Date -Date $target.ToLocalTime() -ErrorAction Stop | Out-Null
} catch {
    Say ("Set-Date to {0} FAILED: {1} - the clock is UNCHANGED and the installer will refuse" -f `
         $target.ToString('o'), $_.Exception.Message) 'ERROR'
    exit 0
}

# VERIFY IN UTC. "It ran" and "the clock is right" must not be indistinguishable - a zone this got
# wrong would otherwise pass silently, which is the exact defect set-time.ps1 was corrected for.
$after = (Get-Date).ToUniversalTime()
$rest  = [math]::Round(($target - $after).TotalSeconds, 1)
if ([math]::Abs($rest) -le $ToleranceSeconds) {
    Say ("clock corrected: now {0} UTC (was {1} s out, now {2} s)" -f $after.ToString('o'), $skew, $rest)
} else {
    Say ("the clock did not take: asked for {0}, it reads {1} - still {2} s out (was {3} s out before)" -f `
         $target.ToString('o'), $after.ToString('o'), $rest, $skew) 'ERROR'
}
exit 0
