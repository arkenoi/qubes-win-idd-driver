# Keep autologon working across Windows updates.
#
# WHY THIS EXISTS. A qube must come back by itself after a reboot: with no interactive session,
# qrexec service calls have nobody to run as, so dom0 cannot update the qube, cannot run apps in
# it, and cannot even read it - measured 2026-08-13 on win11-tpl, where a cumulative update left
# the guest at the sign-in screen and every qrexec call failed with rc=117.
#
# THE MECHANISM, documented in mgmt/autounattend*.xml since provisioning: while AutoLogonCount is
# present, Windows CONSUMES DefaultPassword - it decrements the count, and when it runs out it
# deletes the password and falls back to the sign-in screen. Provisioning deletes AutoLogonCount
# once, which makes autologon unlimited; but a Windows update rewrites Winlogon values, so the
# one-time fix does not survive servicing. Nothing re-asserted it afterwards. This does.
#
# PREVENTION, NOT REPAIR. If DefaultPassword has already been consumed there is nothing to
# restore - we do not know the password and will not invent one. So this runs BEFORE a reboot we
# trigger (and at install), where deleting AutoLogonCount is what stops the consumption.
#
# NOTE ON THE PASSWORD: DefaultPassword is plaintext in the registry, which is how the image was
# provisioned. That is not a Qubes boundary - the guest is untrusted either way, and a local
# Windows password protects nothing dom0 relies on. QWT's own Autologon component would store an
# LSA secret instead, but it randomises the account password, which is why the image omits it.
$ErrorActionPreference = 'Continue'
$WL = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
$changed = 0
$warn = 0

function Get-WL($n) { (Get-ItemProperty -Path $WL -Name $n -ErrorAction SilentlyContinue).$n }

# 1. AutoLogonCount must be ABSENT. Its presence is what makes Windows eat the password.
if ($null -ne (Get-WL 'AutoLogonCount')) {
    Remove-ItemProperty -Path $WL -Name 'AutoLogonCount' -Force -ErrorAction SilentlyContinue
    $changed++
    Write-Output 'SET    removed AutoLogonCount (its presence consumes DefaultPassword)'
} else {
    Write-Output 'ok     AutoLogonCount absent'
}

# 2. AutoAdminLogon must be "1".
if ((Get-WL 'AutoAdminLogon') -ne '1') {
    New-ItemProperty -Path $WL -Name 'AutoAdminLogon' -Value '1' -PropertyType String -Force | Out-Null
    $changed++
    Write-Output 'SET    AutoAdminLogon=1'
} else {
    Write-Output 'ok     AutoAdminLogon=1'
}

# 3. Report what we cannot fix: a consumed password. Loudly, because the qube will come back
#    unreachable and the cause must not have to be re-derived from a lock screen.
$user = Get-WL 'DefaultUserName'
$pass = Get-WL 'DefaultPassword'
if (-not $user) { Write-Output 'WARN   DefaultUserName is not set - autologon cannot work'; $warn++ }
else { Write-Output "ok     DefaultUserName=$user" }
if (-not $pass) {
    Write-Output 'WARN   DefaultPassword is MISSING (already consumed). Autologon will NOT happen and'
    Write-Output 'WARN   this qube will need an interactive logon before qrexec works again.'
    $warn++
} else {
    Write-Output 'ok     DefaultPassword present'
}

Write-Output ''
Write-Output ("=== RESULT === changed=$changed warnings=$warn")
# EXIT CODE IS A CONTRACT: 0 = autologon will happen on the next boot, 2 = it will NOT and the
# qube would come back unreachable. The updater refuses to reboot on 2 rather than knowingly
# stranding the qube - see wu-update.ps1.
if ($warn -gt 0) { exit 2 }
exit 0
