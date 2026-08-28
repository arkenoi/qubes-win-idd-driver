# ARM Windows autologon for this guest, durably.
#
# WHY. A Qubes Windows guest that stops at the sign-in screen is not "locked", it is GONE: with no
# interactive session qrexec service calls have nobody to run as, so dom0 cannot run apps in it,
# cannot update it, cannot read it (rc=117, measured on win11-tpl 2026-08-13 after a cumulative
# update rewrote Winlogon - recovery took a root-volume revert). And in SEAMLESS mode the sign-in
# screen is not even displayed, so the qube window is simply empty (measured 2026-08-28: autologon
# off -> 0 windows mapped in dom0). Autologon is therefore not a convenience here, it is how the
# qube stays reachable at all. Owner decision 2026-08-28: enforce it rigorously.
#
# WHERE THE PASSWORD GOES. Into the LSA private data as the secret "DefaultPassword" - the same
# place Sysinternals Autologon uses, and the place Winlogon falls back to when the registry value
# is absent. Two reasons, both load-bearing:
#   1. DURABILITY. While AutoLogonCount exists Windows CONSUMES the REGISTRY DefaultPassword and
#      deletes it; nothing can restore it afterwards because nobody kept a copy. An LSA secret is
#      not consumed, so the boot-time guard (ensure-autologon.ps1) has something to guard.
#   2. EXPOSURE. The registry value is world-readable plaintext. The guest is untrusted as a whole,
#      but a Windows password is frequently reused elsewhere, so writing the user's real password
#      where any process in the guest can read it is gratuitous. This is NOT claimed as a Qubes
#      boundary - dom0 owns the guest either way.
#
# CREDENTIALS ARE VALIDATED BEFORE ANYTHING IS WRITTEN. Arming autologon with a password Windows
# rejects produces exactly the failure this script exists to prevent, except now it is our fault.
#
# EXIT CODE IS A CONTRACT: 0 = autologon is armed and verified, 2 = it is not (reason on stdout).
[CmdletBinding()]
param(
    [string] $User,
    [string] $Password,
    [string] $Domain,
    # Last resort: if the LSA store is unavailable, write the plaintext registry value instead.
    # A reachable qube beats a tidy one, but say so loudly.
    [switch] $AllowPlaintextFallback
)
$ErrorActionPreference = 'Continue'
# An unbound [string] parameter is $null, and $null is NOT the same as an empty password when it
# reaches LogonUser - normalise before anything validates or stores it.
if ($null -eq $Password) { $Password = '' }
$WL = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
$warn = 0

Add-Type -ErrorAction Stop @'
using System;
using System.Runtime.InteropServices;
public static class QubesLsa {
    [StructLayout(LayoutKind.Sequential)]
    public struct LSA_UNICODE_STRING { public ushort Length; public ushort MaximumLength; public IntPtr Buffer; }
    [StructLayout(LayoutKind.Sequential)]
    public struct LSA_OBJECT_ATTRIBUTES { public int Length; public IntPtr RootDirectory; public IntPtr ObjectName; public int Attributes; public IntPtr SecurityDescriptor; public IntPtr SecurityQualityOfService; }

    [DllImport("advapi32.dll", SetLastError=true)]
    static extern uint LsaOpenPolicy(IntPtr system, ref LSA_OBJECT_ATTRIBUTES attrs, uint access, out IntPtr handle);
    [DllImport("advapi32.dll", SetLastError=true)]
    static extern uint LsaStorePrivateData(IntPtr policy, ref LSA_UNICODE_STRING key, ref LSA_UNICODE_STRING data);
    [DllImport("advapi32.dll", SetLastError=true)]
    static extern uint LsaRetrievePrivateData(IntPtr policy, ref LSA_UNICODE_STRING key, out IntPtr data);
    [DllImport("advapi32.dll")] static extern uint LsaClose(IntPtr policy);
    [DllImport("advapi32.dll")] static extern uint LsaFreeMemory(IntPtr p);
    [DllImport("advapi32.dll")] static extern int LsaNtStatusToWinError(uint status);
    [DllImport("advapi32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    static extern bool LogonUser(string user, string domain, string pass, int type, int provider, out IntPtr token);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool CloseHandle(IntPtr h);

    const uint POLICY_CREATE_SECRET = 0x00000020;
    const uint POLICY_GET_PRIVATE_INFORMATION = 0x00000004;

    static LSA_UNICODE_STRING Str(string s) {
        LSA_UNICODE_STRING u = new LSA_UNICODE_STRING();
        u.Buffer = Marshal.StringToHGlobalUni(s);
        u.Length = (ushort)(s.Length * 2);
        u.MaximumLength = (ushort)(u.Length + 2);
        return u;
    }
    static IntPtr Open(uint access) {
        LSA_OBJECT_ATTRIBUTES a = new LSA_OBJECT_ATTRIBUTES();
        a.Length = Marshal.SizeOf(typeof(LSA_OBJECT_ATTRIBUTES));
        IntPtr h;
        uint st = LsaOpenPolicy(IntPtr.Zero, ref a, access, out h);
        if (st != 0) throw new System.ComponentModel.Win32Exception(LsaNtStatusToWinError(st));
        return h;
    }

    // Store the secret. Returns 0 on success, else a Win32 error code.
    public static int Store(string key, string value) {
        IntPtr pol = IntPtr.Zero;
        LSA_UNICODE_STRING k = Str(key), v = Str(value);
        try {
            pol = Open(POLICY_CREATE_SECRET);
            uint st = LsaStorePrivateData(pol, ref k, ref v);
            return LsaNtStatusToWinError(st);
        } catch (System.ComponentModel.Win32Exception e) {
            return e.NativeErrorCode;
        } finally {
            if (pol != IntPtr.Zero) LsaClose(pol);
            Marshal.FreeHGlobal(k.Buffer); Marshal.FreeHGlobal(v.Buffer);
        }
    }

    // Read the secret back; null when absent or unreadable.
    public static string Retrieve(string key) {
        IntPtr pol = IntPtr.Zero, data = IntPtr.Zero;
        LSA_UNICODE_STRING k = Str(key);
        try {
            pol = Open(POLICY_GET_PRIVATE_INFORMATION);
            uint st = LsaRetrievePrivateData(pol, ref k, out data);
            if (st != 0 || data == IntPtr.Zero) return null;
            LSA_UNICODE_STRING v = (LSA_UNICODE_STRING)Marshal.PtrToStructure(data, typeof(LSA_UNICODE_STRING));
            return v.Buffer == IntPtr.Zero ? null : Marshal.PtrToStringUni(v.Buffer, v.Length / 2);
        } catch (System.ComponentModel.Win32Exception) {
            return null;
        } finally {
            if (data != IntPtr.Zero) LsaFreeMemory(data);
            if (pol != IntPtr.Zero) LsaClose(pol);
            Marshal.FreeHGlobal(k.Buffer);
        }
    }

    // LOGON32_LOGON_INTERACTIVE = 2, LOGON32_PROVIDER_DEFAULT = 0
    public static bool ValidateCredentials(string user, string domain, string pass) {
        IntPtr token;
        if (!LogonUser(user, domain, pass, 2, 0, out token)) return false;
        CloseHandle(token);
        return true;
    }
}
'@

function Get-WL($n) { (Get-ItemProperty -Path $WL -Name $n -ErrorAction SilentlyContinue).$n }

# ---- 1. who ----------------------------------------------------------------
if (-not $User) {
    # The console session's user, not ours: this script is normally run elevated or as SYSTEM.
    $cs = (Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).UserName
    if ($cs) { $User = $cs.Split('\')[-1] }
    elseif ($env:USERNAME -and $env:USERNAME -ne 'SYSTEM') { $User = $env:USERNAME }
}
if (-not $User) {
    Write-Output 'FAIL   no user to arm autologon for (pass -User)'
    Write-Output '=== RESULT === armed=0 reason=no-user'
    exit 2
}
if (-not $Domain) { $Domain = $env:COMPUTERNAME }
Write-Output "info   arming autologon for $Domain\$User"

# ---- 2. validate BEFORE writing anything -----------------------------------
# A blank password is legitimate (a local account with none): Windows autologs in with an empty
# DefaultPassword, and LogonUser accepts "" for such an account, so the same check covers it.
if (-not [QubesLsa]::ValidateCredentials($User, $Domain, $Password)) {
    Write-Output "FAIL   Windows rejected those credentials for $Domain\$User - refusing to arm"
    Write-Output '       (arming with a wrong password strands the qube at the sign-in screen,'
    Write-Output '        which is the exact failure this is meant to prevent)'
    Write-Output '=== RESULT === armed=0 reason=bad-credentials'
    exit 2
}
Write-Output 'ok     credentials accepted by Windows'

# ---- 3. store the password where Windows will find it and nothing eats it ----
$stored = 'lsa'
$rc = [QubesLsa]::Store('DefaultPassword', $Password)
if ($rc -ne 0) {
    Write-Output "WARN   LSA secret store failed (win32 $rc)"
    $warn++
    if ($AllowPlaintextFallback) {
        New-ItemProperty -Path $WL -Name 'DefaultPassword' -Value $Password -PropertyType String -Force | Out-Null
        $stored = 'registry-plaintext'
        Write-Output 'WARN   fell back to the PLAINTEXT registry DefaultPassword - readable by any'
        Write-Output '       process in this guest, and Windows will consume it if AutoLogonCount returns'
    } else {
        Write-Output '=== RESULT === armed=0 reason=lsa-store-failed'
        exit 2
    }
} else {
    $back = [QubesLsa]::Retrieve('DefaultPassword')
    if ($back -ne $Password) {
        Write-Output 'FAIL   LSA secret did not read back identical - not trusting it'
        Write-Output '=== RESULT === armed=0 reason=lsa-verify-failed'
        exit 2
    }
    Write-Output 'ok     password stored in the LSA secret and verified'
    # Do not leave a plaintext copy behind if one was there from an earlier arming.
    if ($null -ne (Get-WL 'DefaultPassword')) {
        Remove-ItemProperty -Path $WL -Name 'DefaultPassword' -Force -ErrorAction SilentlyContinue
        Write-Output 'ok     removed the plaintext registry DefaultPassword (LSA secret supersedes it)'
    }
}

# ---- 4. the rest of the Winlogon values ------------------------------------
New-ItemProperty -Path $WL -Name 'AutoAdminLogon' -Value '1' -PropertyType String -Force | Out-Null
New-ItemProperty -Path $WL -Name 'DefaultUserName' -Value $User -PropertyType String -Force | Out-Null
New-ItemProperty -Path $WL -Name 'DefaultDomainName' -Value $Domain -PropertyType String -Force | Out-Null
# Its presence is what makes Windows consume the password. Unlimited autologon has no count.
if ($null -ne (Get-WL 'AutoLogonCount')) {
    Remove-ItemProperty -Path $WL -Name 'AutoLogonCount' -Force -ErrorAction SilentlyContinue
    Write-Output 'ok     removed AutoLogonCount (its presence consumes the password)'
}
# (Lock-screen prevention lives in disable-session-lock.ps1 - DisableLockWorkstation is a
# Policies\System value, not a Winlogon one, and writing it here would do nothing.)

Write-Output "ok     AutoAdminLogon=1 DefaultUserName=$User DefaultDomainName=$Domain"
Write-Output "=== RESULT === armed=1 user=$User stored=$stored warnings=$warn"
exit 0
