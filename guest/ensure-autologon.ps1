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
#
# The query outcome is tracked SEPARATELY from the answer: "could not ask LSA" is not "no
# password". set-autologon.ps1 stores ONLY the secret, so on every correctly armed guest the
# verdict rests on this query alone - and a probe fault (Add-Type failing, LsaOpenPolicy denied)
# used to print 'NO autologon password' and exit 2, which made the updater withhold every reboot
# of a fully armed guest until a human intervened (audit 2026-09-08).
$lsa = $null
$lsaKnown = $false
try {
    # A long-lived host that already compiled this type (the installer dot-runs us in-process)
    # must not fail the whole probe on "type name already exists".
    if (-not ('QubesLsaRead' -as [type])) {
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
    // true/false ONLY for a definitive answer. A failed LsaOpenPolicy or an unexpected
    // LsaRetrievePrivateData status THROWS, so the caller records "unknown" - it used to return
    // false and be reported as "no password set" (exit 2, reboot withheld) on an armed guest.
    public static bool Present(string key) {
        LSA_OBJECT_ATTRIBUTES a = new LSA_OBJECT_ATTRIBUTES();
        a.Length = Marshal.SizeOf(typeof(LSA_OBJECT_ATTRIBUTES));
        IntPtr pol, data = IntPtr.Zero;
        uint st = LsaOpenPolicy(IntPtr.Zero, ref a, 0x00000004 /* GET_PRIVATE_INFORMATION */, out pol);
        if (st != 0) throw new InvalidOperationException("LsaOpenPolicy failed, NTSTATUS 0x" + st.ToString("X8"));
        LSA_UNICODE_STRING k = new LSA_UNICODE_STRING();
        k.Buffer = Marshal.StringToHGlobalUni(key);
        k.Length = (ushort)(key.Length * 2); k.MaximumLength = (ushort)(k.Length + 2);
        try {
            st = LsaRetrievePrivateData(pol, ref k, out data);
            if (st == 0xC0000034) return false; /* STATUS_OBJECT_NAME_NOT_FOUND: definitively absent */
            if (st != 0) throw new InvalidOperationException("LsaRetrievePrivateData failed, NTSTATUS 0x" + st.ToString("X8"));
            if (data == IntPtr.Zero) return false;
            LSA_UNICODE_STRING v = (LSA_UNICODE_STRING)Marshal.PtrToStructure(data, typeof(LSA_UNICODE_STRING));
            return v.Length > 0 && v.Buffer != IntPtr.Zero;
        } finally {
            if (data != IntPtr.Zero) LsaFreeMemory(data);
            LsaClose(pol); Marshal.FreeHGlobal(k.Buffer);
        }
    }
}
'@
    }
    $lsa = [QubesLsaRead]::Present('DefaultPassword')
    $lsaKnown = $true
} catch {
    Write-Output "WARN   could not query the LSA secret ($($_.Exception.Message.Split([char]10)[0]))"
}

$unknown = 0
if ($lsa) {
    Write-Output 'ok     password present as the LSA secret (not consumable, not plaintext)'
    if ($pass) {
        Write-Output 'note   a plaintext registry DefaultPassword also exists and is redundant'
    }
} elseif ($pass) {
    Write-Output 'ok     DefaultPassword present (plaintext registry value - consumable)'
} elseif (-not $lsaKnown) {
    # Probe fault, not a verdict: the secret may well be there. Loud (a probe that fails on an
    # eligible guest is a defect to diagnose), but NOT the "password consumed" finding - that one
    # withholds reboots, and a transient LSA/Add-Type error must not do that to an armed guest.
    Write-Output 'WARN   cannot tell whether an autologon password is set: the LSA secret could not be'
    Write-Output 'WARN   queried and there is no registry DefaultPassword. Autologon is UNVERIFIED, not'
    Write-Output 'WARN   known-broken - diagnose the LSA query failure above.'
    $unknown++
} else {
    Write-Output 'WARN   NO autologon password is set: neither the LSA secret nor DefaultPassword.'
    Write-Output 'WARN   Autologon will NOT happen, this qube will come back at the sign-in screen,'
    Write-Output 'WARN   qrexec will have no session to run in, and in seamless mode dom0 will be'
    Write-Output 'WARN   shown nothing at all. Re-arm with guest\set-autologon.ps1.'
    $warn++
}

$lsaState = if (-not $lsaKnown) { 'unknown' } elseif ($lsa) { 'present' } else { 'absent' }
Write-Output ''
# warnings= counts the unverified case too, so a caller that only reads the trailer (the
# installer's stage-2 verify) does not log "armed" for a state it could not check; lsa= says which
# case it was.
Write-Output ("=== RESULT === changed=$changed warnings=$($warn + $unknown) lsa=$lsaState")
# EXIT CODE IS A CONTRACT: 0 = autologon will happen on the next boot, 2 = it will NOT and the
# qube would come back unreachable, 3 = it could not be VERIFIED (the LSA probe itself failed; no
# positive finding either way). The updater refuses to reboot on 2 rather than knowingly stranding
# the qube - see wu-update.ps1; 3 is deliberately not 2, so a probe fault cannot block every
# dom0-driven update of an armed guest.
if ($warn -gt 0) { exit 2 }
if ($unknown -gt 0) { exit 3 }
exit 0
