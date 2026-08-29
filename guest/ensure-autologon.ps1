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

# The password may live in the LSA secret instead of the registry - that is where
# set-autologon.ps1 puts it, because an LSA secret is not consumed by AutoLogonCount and is not
# world-readable plaintext. Winlogon reads it when the registry value is absent, so a guest with
# only the secret is correctly armed and must NOT be reported as broken.
$lsa = $null
# Default FALSE, not $null: if the Add-Type or the LSA query throws, the catch leaves this
# untouched, and an unset value must mean "not proven valid" rather than silently passing the
# -and test. A validity flag that defaults to permissive would reintroduce the exact hole this
# closes.
$lsaValid = $false
try {
    Add-Type -ErrorAction Stop @'
using System;
using System.Runtime.InteropServices;
public static class QubesLsaRead {
    [StructLayout(LayoutKind.Sequential)]
    public struct LSA_UNICODE_STRING { public ushort Length; public ushort MaximumLength; public IntPtr Buffer; }
    [StructLayout(LayoutKind.Sequential)]
    public struct LSA_OBJECT_ATTRIBUTES { public int Length; public IntPtr RootDirectory; public IntPtr ObjectName; public int Attributes; public IntPtr SecurityDescriptor; public IntPtr SecurityQualityOfService; }
    [DllImport("advapi32.dll", SetLastError=true)]
    static extern uint LsaOpenPolicy(IntPtr system, ref LSA_OBJECT_ATTRIBUTES attrs, uint access, out IntPtr handle);
    [DllImport("advapi32.dll", SetLastError=true)]
    static extern uint LsaRetrievePrivateData(IntPtr policy, ref LSA_UNICODE_STRING key, out IntPtr data);
    [DllImport("advapi32.dll")] static extern uint LsaClose(IntPtr policy);
    [DllImport("advapi32.dll")] static extern uint LsaFreeMemory(IntPtr p);
    [DllImport("advapi32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    static extern bool LogonUser(string user, string domain, string pass, int type, int provider, out IntPtr token);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool CloseHandle(IntPtr h);

    // VALIDATE, do not merely detect. Present() below answers "is a secret stored", which is a
    // strictly weaker question than "will Winlogon be able to log in with it" - and the weaker
    // answer is the one that shipped a broken guest. Retrieve the secret and actually try it.
    // LOGON32_LOGON_INTERACTIVE(2) is the type Winlogon itself uses, so a pass here means the
    // same credential Winlogon will present is accepted.
    public static bool Validates(string key, string user, string domain) {
        LSA_OBJECT_ATTRIBUTES a = new LSA_OBJECT_ATTRIBUTES();
        a.Length = Marshal.SizeOf(typeof(LSA_OBJECT_ATTRIBUTES));
        IntPtr pol, data = IntPtr.Zero;
        if (LsaOpenPolicy(IntPtr.Zero, ref a, 0x00000004, out pol) != 0) return false;
        LSA_UNICODE_STRING k = new LSA_UNICODE_STRING();
        k.Buffer = Marshal.StringToHGlobalUni(key);
        k.Length = (ushort)(key.Length * 2); k.MaximumLength = (ushort)(k.Length + 2);
        try {
            if (LsaRetrievePrivateData(pol, ref k, out data) != 0 || data == IntPtr.Zero) return false;
            LSA_UNICODE_STRING v = (LSA_UNICODE_STRING)Marshal.PtrToStructure(data, typeof(LSA_UNICODE_STRING));
            string secret = (v.Buffer == IntPtr.Zero) ? "" : Marshal.PtrToStringUni(v.Buffer, v.Length / 2);
            IntPtr tok;
            if (!LogonUser(user, domain, secret, 2, 0, out tok)) return false;
            CloseHandle(tok);
            return true;
        } finally {
            if (data != IntPtr.Zero) LsaFreeMemory(data);
            LsaClose(pol); Marshal.FreeHGlobal(k.Buffer);
        }
    }
    public static bool Present(string key) {
        LSA_OBJECT_ATTRIBUTES a = new LSA_OBJECT_ATTRIBUTES();
        a.Length = Marshal.SizeOf(typeof(LSA_OBJECT_ATTRIBUTES));
        IntPtr pol, data = IntPtr.Zero;
        if (LsaOpenPolicy(IntPtr.Zero, ref a, 0x00000004 /* GET_PRIVATE_INFORMATION */, out pol) != 0) return false;
        LSA_UNICODE_STRING k = new LSA_UNICODE_STRING();
        k.Buffer = Marshal.StringToHGlobalUni(key);
        k.Length = (ushort)(key.Length * 2); k.MaximumLength = (ushort)(k.Length + 2);
        try {
            if (LsaRetrievePrivateData(pol, ref k, out data) != 0 || data == IntPtr.Zero) return false;
            LSA_UNICODE_STRING v = (LSA_UNICODE_STRING)Marshal.PtrToStructure(data, typeof(LSA_UNICODE_STRING));
            return v.Length > 0 && v.Buffer != IntPtr.Zero;
        } finally {
            if (data != IntPtr.Zero) LsaFreeMemory(data);
            LsaClose(pol); Marshal.FreeHGlobal(k.Buffer);
        }
    }
}
'@
    $lsa = [QubesLsaRead]::Present('DefaultPassword')
    # The credential must WORK, not merely exist - presence is a strictly weaker question than
    # validity, and "armed" should mean Winlogon can actually log in.
    #
    # HONEST PROVENANCE (corrected 2026-08-30). This was originally written up as a fix for a
    # measured defect: stage 1 refusing with "bad-credentials" while this script reported the
    # secret present and the installer logged "autologon verified", on a guest found parked at the
    # sign-in screen with zero windows mapped. That attribution was WRONG and is retracted. The
    # stored secret VALIDATES - this very check passes on that guest - and the three 0xC000006D
    # failures came from qrexec-wrapper.exe, not from autologon. Stage 1 rejected a password that
    # was not yet in place at 19:44; stage 2 armed a working one at 19:49. They do not contradict.
    #
    # So NO case of a bad credential passing the presence check has ever been observed. This is a
    # strengthening on principle, not a demonstrated bug fix, and per this project's own rule it
    # counts as UNPROVEN until seen to fail on a deliberately broken credential.
    #
    # It is not free: LogonUser with LOGON32_LOGON_INTERACTIVE creates a real logon session, so
    # every run emits Security audit events, and against a wrong password it would feed
    # account-lockout counters. Kept because present-but-rejected is a real reachable state and
    # stranding a qube at a sign-in screen is expensive; drop it if that cost ever bites.
    $lsaUser = (Get-ItemProperty $WL -Name DefaultUserName -EA SilentlyContinue).DefaultUserName
    if (-not $lsaUser) { $lsaUser = $env:USERNAME }
    $lsaDomain = (Get-ItemProperty $WL -Name DefaultDomainName -EA SilentlyContinue).DefaultDomainName
    if (-not $lsaDomain) { $lsaDomain = $env:COMPUTERNAME }
    if ($lsa) { $lsaValid = [QubesLsaRead]::Validates('DefaultPassword', $lsaUser, $lsaDomain) }
} catch {
    Write-Output "note   could not query the LSA secret ($($_.Exception.Message.Split([char]10)[0]))"
}

if ($lsa -and $lsaValid) {
    Write-Output 'ok     password present as the LSA secret AND accepted by LogonUser'
    if ($pass) {
        Write-Output 'note   a plaintext registry DefaultPassword also exists and is redundant'
    }
} elseif ($lsa -and -not $lsaValid) {
    # Present but WRONG. This is the worst state: the guard looks armed to every check that only
    # asks "is something stored", so it silently defeats itself. Fail loudly - a stored credential
    # that Winlogon will reject strands the qube exactly as if none were stored at all.
    Write-Output ("WARN   LSA secret DefaultPassword is present but REJECTED for " +
                  "$lsaDomain\$lsaUser - Winlogon will NOT be able to log in.")
    Write-Output 'WARN   The qube will come back at the sign-in screen with NO windows mapped:'
    Write-Output 'WARN   reachable over qrexec, invisible in dom0. Re-arm with guest\set-autologon.ps1.'
    $warn++
} elseif ($pass) {
    Write-Output 'ok     DefaultPassword present (plaintext registry value - consumable)'
} else {
    Write-Output 'WARN   NO autologon password is set: neither the LSA secret nor DefaultPassword.'
    Write-Output 'WARN   Autologon will NOT happen, this qube will come back at the sign-in screen,'
    Write-Output 'WARN   qrexec will have no session to run in, and in seamless mode dom0 will be'
    Write-Output 'WARN   shown nothing at all. Re-arm with guest\set-autologon.ps1.'
    $warn++
}

Write-Output ''
Write-Output ("=== RESULT === changed=$changed warnings=$warn")
# EXIT CODE IS A CONTRACT: 0 = autologon will happen on the next boot, 2 = it will NOT and the
# qube would come back unreachable. The updater refuses to reboot on 2 rather than knowingly
# stranding the qube - see wu-update.ps1.
if ($warn -gt 0) { exit 2 }
exit 0
