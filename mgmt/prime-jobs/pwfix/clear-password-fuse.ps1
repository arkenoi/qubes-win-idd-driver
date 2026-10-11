# clear-password-fuse.ps1 - remove Windows' dated password expiry from this image, and record what
# it did INSIDE the image. There is no separate verifier: the proof is written next to the change.
#
# THE DEFECT, measured 2026-10-11. Windows' default "Maximum password age" is 42 days, so every
# image carries an expiry fixed at build time. The win10 image's password was set 30/08/2026 and
# came due 11/10/2026; that boot sat on "Your password has expired", autologon could not proceed,
# and the guest was unreachable over qrexec. win11-tpl carried the same 42-day age. It costs one
# stuck boot per image, on a date nobody chose, and prime-run CLONES a base and boots it rather
# than reinstalling - so a blown fuse in a base breaks every clean-install cell entering through it.
#
# WHY NOT wmic. The obvious one-liner is `wmic useraccount ... set PasswordExpires=FALSE`, and it is
# wrong here: wmic is deprecated and absent from recent Windows 11 builds, and these guests are
# 26100/26300. It would SILENTLY do nothing on exactly the images that matter. Jev scored that
# formulation 0.00 and the wmic risk 0.87. Get-LocalUser/Set-LocalUser ship with Windows 10 and 11.
#
# WHY BOTH LEVERS AND THE LATCH. Setting the never-expires flag alone was judged a coin flip
# (clears_already_expired 0.50) for an account whose password has ALREADY expired, and the single
# most likely thing to leave a guest stuck was named as that latched "must change at next logon"
# state (0.82). So: the machine-wide age, the per-account flag, AND an explicit clear of the
# must-change latch - none of which needs the password.
$ErrorActionPreference = 'SilentlyContinue'
$log = 'C:\qubes-pwfix.log'
function Note($s) { "[{0:yyyy-MM-dd HH:mm:ss}] {1}" -f (Get-Date), $s | Add-Content -LiteralPath $log }

Note "pwfix start (as $([Security.Principal.WindowsIdentity]::GetCurrent().Name))"
Note ("BEFORE " + (((net accounts) -match 'Maximum password age') -replace '\s+',' '))
foreach ($u in @(Get-LocalUser | Where-Object { $_.Enabled })) {
    Note ("BEFORE account {0} expires={1}" -f $u.Name, $(if ($null -eq $u.PasswordExpires) { 'NEVER' } else { $u.PasswordExpires }))
}

# ORDER MATTERS, and getting it wrong is how this fails against the very wall it is for.
# "User must change password at next logon" and "password never expires" are MUTUALLY EXCLUSIVE in
# Windows: Set-LocalUser -PasswordNeverExpires throws while the must-change latch is set. Clearing
# the latch FIRST is therefore not tidiness - with the other order, an account sitting at the
# expired wall takes the throw and keeps its fuse.
#
# Two distinct states are being cleared, which is why both levers and the latch are all here:
#   * COMPUTED expiry - pwdLastSet + maxPwdAge has passed. Beaten by the unlimited machine age and
#     by the per-account never-expires flag; this is the "Your password has expired" wall.
#   * EXPLICIT must-change - an admin flag (pwdLastSet = 0), unrelated to any age. Beaten only by
#     logonpasswordchg:no.
& net accounts /maxpwage:unlimited | Out-Null
foreach ($u in @(Get-LocalUser | Where-Object { $_.Enabled })) {
    & net user $u.Name /logonpasswordchg:no | Out-Null      # clear the latch BEFORE pinning
    try { Set-LocalUser -Name $u.Name -PasswordNeverExpires $true -ErrorAction Stop }
    catch { Note ("SET FAILED {0}: {1}" -f $u.Name, $_.Exception.Message) }
}

Note ("AFTER  " + (((net accounts) -match 'Maximum password age') -replace '\s+',' '))
$bad = 0
foreach ($u in @(Get-LocalUser | Where-Object { $_.Enabled })) {
    $e = $u.PasswordExpires
    if ($null -ne $e) { $bad++ }
    Note ("AFTER  account {0} expires={1}" -f $u.Name, $(if ($null -eq $e) { 'NEVER' } else { $e }))
}
# LAST RESORT, only if an account survived all three levers. Jev put the residual risk at
# "reset-password-to-itself" (0.51) against "nothing-needed" (0.06): re-setting the password moves
# pwdLastSet, which clears a wall unambiguously, where the flags clear it only by evaluation
# (flag_cures_age_expiry 0.81 - likely, not certain).
#
# IT USES THE CREDENTIAL THE IMAGE ALREADY HOLDS, never a guessed one. set-autologon.ps1 stores the
# account password as the LSA secret "DefaultPassword"; re-setting the account to that exact value
# moves pwdLastSet AND keeps autologon consistent. Setting it to anything else would break autologon
# outright - a worse failure than the one being fixed - so if the secret cannot be read, this does
# nothing and says so. Skipped entirely when the levers already worked.
if ($bad -gt 0) {
    Note "levers left $bad account(s) expiring - trying the stored DefaultPassword to move pwdLastSet"
    $pw = $null
    try {
        $sa = Join-Path $env:QUBES_TOOLS 'qubes-rpc-services\..\set-autologon.ps1'
        $lsa = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -Name DefaultPassword -ErrorAction Stop
        $pw = $lsa.DefaultPassword
    } catch { }
    if (-not $pw) {
        Note "no readable DefaultPassword - NOT guessing a credential; those accounts stay as they are"
    } else {
        foreach ($u in @(Get-LocalUser | Where-Object { $_.Enabled -and $null -ne $_.PasswordExpires })) {
            try {
                Set-LocalUser -Name $u.Name -Password (ConvertTo-SecureString $pw -AsPlainText -Force) -ErrorAction Stop
                Set-LocalUser -Name $u.Name -PasswordNeverExpires $true -ErrorAction Stop
                Note ("re-set {0} to the stored password to move pwdLastSet" -f $u.Name)
            } catch { Note ("re-set FAILED {0}: {1}" -f $u.Name, $_.Exception.Message) }
        }
        $bad = @(Get-LocalUser | Where-Object { $_.Enabled -and $null -ne $_.PasswordExpires }).Count
    }
}
Note ("RESULT " + $(if ($bad -eq 0) { 'OK - no enabled account expires' } else { "STILL EXPIRING: $bad account(s)" }))
Note "pwfix done"
