# QWT-NG: silence the consumer nags a Windows guest shows in a qube.
#
# Why this belongs in the installer: a qube is a tool, not a consumer desktop. OneDrive's
# "set up OneDrive" reminder in particular pops up over the seamless desktop, steals focus, and
# on an OFFLINE qube it can never succeed at anything - it is pure noise. The same goes for the
# Spotlight/"suggested content" family.
#
# Everything here is a standard MACHINE policy value under HKLM\SOFTWARE\Policies. Nothing is
# enforced beyond normal policy precedence and an admin can change or delete any of it later.
# No user data is touched and OneDrive is not uninstalled - only prevented from starting.
#
# Emits the same trailer as disable-hw-accel.ps1 so the installer can parse it:
#   === RESULT === changed=N failed=N
$ErrorActionPreference = 'Continue'
$script:changed = 0
$script:failed = 0

function Set-Reg {
    param([string]$Path, [string]$Name, $Value, [string]$Type = 'DWord', [string]$What)
    try {
        if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
        $cur = (Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue).$Name
        if ($null -ne $cur -and "$cur" -eq "$Value") {
            Write-Output "ok     $What (already set)"
            return
        }
        New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
        $script:changed++
        Write-Output "SET    $What"
    } catch {
        $script:failed++
        Write-Output "FAIL   $What : $($_.Exception.Message)"
    }
}

# --- OneDrive -------------------------------------------------------------------------------
# DisableFileSyncNGSC is the supported way to stop OneDrive entirely: the client does not start,
# so the reminder cannot appear. (The older DisableFileSync only hides the sync UI.)
$od = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive'
Set-Reg $od 'DisableFileSyncNGSC' 1 'DWord' 'OneDrive: prevent the sync client from starting'
Set-Reg $od 'DisableFileSync'     1 'DWord' 'OneDrive: disable file sync UI'

# Stop the one that is already nagging, so the popup goes away without waiting for a logon.
$run = @(Get-Process OneDrive -ErrorAction SilentlyContinue)
if ($run.Count) {
    $run | Stop-Process -Force -ErrorAction SilentlyContinue
    $script:changed++
    Write-Output "SET    OneDrive: stopped $($run.Count) running instance(s)"
}

# --- the rest of the consumer-content family ------------------------------------------------
# Spotlight/"suggested content"/soft-landing tips: same class of popup, same argument.
$cc = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent'
Set-Reg $cc 'DisableWindowsConsumerFeatures' 1 'DWord' 'no consumer feature suggestions'
Set-Reg $cc 'DisableSoftLanding'             1 'DWord' 'no "tips about Windows" popups'
Set-Reg $cc 'DisableWindowsSpotlightFeatures' 1 'DWord' 'no Windows Spotlight content'

# "Let''s finish setting up your device" - the OOBE nag that reappears after feature updates.
$oobe = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\UserProfileEngagement'
Set-Reg $oobe 'ScoobeSystemSettingEnabled' 0 'DWord' 'no "finish setting up your device" nag'

Write-Output ""
Write-Output ("=== RESULT === changed=$script:changed failed=$script:failed")
if ($script:failed -gt 0) { exit 1 }
