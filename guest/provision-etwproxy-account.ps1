# PROVISION the least-privilege account for `notifhost --etw-proxy` (P3 toast classifier,
# docs/DESIGN-p3-classifier-impl.md sec 10.14, REVISED by the 2026-09-05 capability-grant split;
# as-implemented proxy record sec 10.18, agent-side launch sec 10.19 / agent/gui-agent/etwproxy.c).
#
# WHY. All real-time ETW consumption + TDH parsing of attacker-influenceable event bytes for the
# notification bridge runs in `notifhost.exe --etw-proxy` (notifhost.cpp EtwProxyMain), a process
# the SYSTEM gui-agent launches under a DEDICATED account so a parser bug hands an attacker that
# token - not SYSTEM, not admin, not the interactive user. This script creates and locks down
# that account.
#
# THE CAPABILITY-GRANT SPLIT (supersedes the PLU design this script previously implemented):
# the SYSTEM agent is the ETW session CONTROLLER (StartTraceW + EnableTraceEx2 +
# EventAccessControl granting TRACELOG_ACCESS_REALTIME on the ONE session GUID to this account);
# the proxy is a pure CONSUMER (OpenTraceW + ProcessTrace), authorized solely by that per-session
# DACL grant. Therefore this account gets **NO group memberships at all** - in particular it is
# NEVER put in BUILTIN\Performance Log Users. PLU was sec 10.17.2's named residual: it let a
# subverted proxy start/consume real-time sessions for ARBITRARY machine-wide providers, and
# group SIDs are SE_GROUP_MANDATORY - they cannot be shed in-process, so the only token that
# cannot use PLU is one that never held it. On upgrade from the PLU-era provisioning this script
# REMOVES the membership. SeBatchLogonRight, which PLU used to carry in implicitly, is now
# granted explicitly (the agent's LogonUserW(LOGON32_LOGON_BATCH) depends on it).
#
# CREDENTIALS ARE IN-MEMORY - NO SECRET AT REST (the sec 10.14.1 LSA-secret design is RETIRED):
#   * this script creates the account with 32 CSPRNG bytes of password, VALIDATES it once with
#     LogonUser(LOGON32_LOGON_BATCH) - the set-autologon.ps1 discipline: prove the credential
#     AND the batch-logon right before relying on either - and then DISCARDS it. It is stored
#     NOWHERE: no LSA secret, no file, no registry. The account is thereafter unusable by
#     anyone (batch is its only allowed logon type and nobody knows the password).
#   * the SYSTEM agent (agent/gui-agent/etwproxy.c) generates a FRESH password in memory at
#     every proxy launch, sets it via NetUserSetInfo(1003), proves it with the same batch
#     LogonUserW, uses the token, and zeroes the buffer - the single credential actor.
#   * consequently the former LSA secret (L$QubesEtwProxyCred), the boot-time rotation task
#     (QubesEtwProxyGuard) and its rotation-vs-retrieve TOCTOU race are all REMOVED here,
#     including on upgrade from an install that had them.
#
# LOCKDOWN applied here (sec 10.14.2/10.14.4, split-adjusted):
#   * logon rights: grant SeBatchLogonRight (now load-bearing, see above); DENY
#     SeDenyInteractiveLogonRight, SeDenyRemoteInteractiveLogonRight, SeDenyNetworkLogonRight.
#   * groups: NONE. New-LocalUser (like NetUserAdd level 1) joins no groups implicitly; known
#     privileged groups AND Performance Log Users are actively stripped on every run, then the
#     actual membership census is verified empty.
#   * one outbound-Block Windows Firewall rule scoped to this account's SID.
#   * LOG: the proxy logs to the STANDARD QWT log directory (HKLM ...\Qubes Tools:LogDir, else
#     %SystemDrive%\Qubes Logs - notifhost.cpp QwtLogDir), file etw-proxy.log, rotated to
#     etw-proxy.log.old at ~1MB. The ACE is scoped to the proxy's OWN log only:
#       - Modify on the two pre-created files etw-proxy.log / etw-proxy.log.old (append, and
#         the rotation rename needs DELETE on both);
#       - folder-only FILE_ADD_FILE (WD) on the log dir, because the rotation re-creates
#         etw-proxy.log (existing files stay untouchable - no inheritance);
#       - CREATOR OWNER inherit-only Modify on the log dir, so the file the proxy re-creates
#         after rotation stays writable by it (and ONLY files it creates itself - the standard
#         %ProgramData% semantics; other components' logs keep their own creators).
#     The proxy gets ZERO write access to the bridge's state/control surfaces: an explicit
#     inheritable DENY-write ACE for its SID goes on %ProgramData%\qubes-toast-bridge (stop
#     file, heartbeat, banner markers live there), and the PLU-era Modify grant on that
#     directory is removed. Even the permissive default ProgramData inheritance cannot let a
#     subverted proxy stop or spoof the bridge.
#   * hidden from the logon UI (SpecialAccounts\UserList = 0; cosmetic, the deny-interactive
#     right is the enforcement).
#
# GRACEFUL DEGRADE IS THE CONTRACT. On a managed/domain/hardened image any of these steps may be
# refused (account creation blocked by policy, firewall service off). This script NEVER fails
# the install: every failure is logged, counted, reflected in the trailer - and the exit code is
# ALWAYS 0. Without the account the agent parks its proxy supervisor after ONE log line
# (etwproxy.c), the bridge's ETW tier reads down, and the classifier serves from the
# listener/DB rungs (fail-open). Idempotent: safe to re-run on install, upgrade, reinstall;
# an existing account is adopted (password re-randomized), never duplicated.
#
# EXIT CODE: ALWAYS 0 (see above). The machine-readable result is the trailer:
#   === RESULT === provisioned=<0|1> account=<name> sid=<sid|none> validated=<0|1>
#                  nogroups=<0|1> rights=<0|1> firewall=<0|1> logdir=<0|1> statedeny=<0|1>
#                  hidden=<0|1> legacy=<0|1> warnings=<n> reason=<why-not-provisioned|ok>
# provisioned=1 means the CORE chain holds: account exists + logon rights set + batch logon
# validated with the throwaway password. The ancillary flags (nogroups/firewall/logdir/
# statedeny/hidden/legacy) can be 0 with provisioned=1; each 0 is also a logged WARN.
# (Install-QwtImproved.ps1 parses only provisioned=<d> and reason=<token> - both kept stable.)
[CmdletBinding()]
param(
    [string] $AccountName = 'qubes-etwproxy'
)
$ErrorActionPreference = 'Continue'

$LegacySecret  = 'L$QubesEtwProxyCred'            # RETIRED - deleted if present
$LegacyTask    = 'QubesEtwProxyGuard'             # RETIRED - deleted if present
$LegacyPersist = 'C:\Program Files\Qubes Tools\bin\provision-etwproxy-account.ps1'  # RETIRED copy
$FwRuleName    = 'QubesEtwProxy-BlockOutbound'
$PluSid        = 'S-1-5-32-559'   # BUILTIN\Performance Log Users - must NOT be a member (split)

$warn = 0
$flag = @{ validated=0; nogroups=0; rights=0; firewall=0; logdir=0; statedeny=0; hidden=0; legacy=0 }
$script:AcctSid = 'none'

function Say($m)  { Write-Output $m }
function Warned($m) { Write-Output "WARN   $m"; $script:warn++ }
function Finish([int]$provisioned, [string]$reason) {
    Say ("=== RESULT === provisioned=$provisioned account=$AccountName sid=$($script:AcctSid) " +
         "validated=$($flag.validated) nogroups=$($flag.nogroups) rights=$($flag.rights) " +
         "firewall=$($flag.firewall) logdir=$($flag.logdir) statedeny=$($flag.statedeny) " +
         "hidden=$($flag.hidden) legacy=$($flag.legacy) warnings=$($script:warn) reason=$reason")
    exit 0   # ALWAYS - a refused provisioning must never fail the install (fail-open: ETW tier
             # stays down, the bridge serves from the listener/DB rungs)
}

Say 'info   install-time run (capability-grant split: no PLU, no stored credential)'

# ---- 0. elevation - without it, skip cleanly --------------------------------------------
try {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $elevated = (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
} catch { $elevated = $false }
if (-not $elevated) {
    Warned 'not elevated - cannot provision the ETW proxy account (skipping, install unaffected)'
    Finish 0 'not-elevated'
}

# ---- native helpers (LSA rights, legacy-secret delete, batch-logon validation) -----------
# Same P/Invoke family as set-autologon.ps1's QubesLsa. Guarded so a re-run in the same
# PowerShell session does not trip Add-Type's duplicate-type error. (Store/Retrieve members
# from the LSA-secret era are gone - nothing may ever store this account's credential again.)
if (-not ('QubesEtwProxyNative' -as [type])) {
    try {
        Add-Type -ErrorAction Stop @'
using System;
using System.Runtime.InteropServices;
public static class QubesEtwProxyNative {
    [StructLayout(LayoutKind.Sequential)]
    public struct LSA_UNICODE_STRING { public ushort Length; public ushort MaximumLength; public IntPtr Buffer; }
    [StructLayout(LayoutKind.Sequential)]
    public struct LSA_OBJECT_ATTRIBUTES { public int Length; public IntPtr RootDirectory; public IntPtr ObjectName; public int Attributes; public IntPtr SecurityDescriptor; public IntPtr SecurityQualityOfService; }

    [DllImport("advapi32.dll")]
    static extern uint LsaOpenPolicy(IntPtr system, ref LSA_OBJECT_ATTRIBUTES attrs, uint access, out IntPtr handle);
    [DllImport("advapi32.dll")]
    static extern uint LsaAddAccountRights(IntPtr policy, IntPtr sid, LSA_UNICODE_STRING[] rights, uint count);
    [DllImport("advapi32.dll", EntryPoint="LsaStorePrivateData")]
    static extern uint LsaDeletePrivateData(IntPtr policy, ref LSA_UNICODE_STRING key, IntPtr none);
    [DllImport("advapi32.dll")] static extern uint LsaClose(IntPtr policy);
    [DllImport("advapi32.dll")] static extern int LsaNtStatusToWinError(uint status);
    [DllImport("advapi32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    static extern bool LogonUser(string user, string domain, string pass, int type, int provider, out IntPtr token);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);

    const uint POLICY_CREATE_ACCOUNT = 0x00000010;
    const uint POLICY_CREATE_SECRET = 0x00000020;
    const uint POLICY_LOOKUP_NAMES = 0x00000800;

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

    // Grant/deny the given logon-right names to the SID (binary form). 0 or a Win32 error.
    public static int AddRights(byte[] sidBytes, string[] rights) {
        IntPtr pol = IntPtr.Zero, sid = IntPtr.Zero;
        LSA_UNICODE_STRING[] arr = new LSA_UNICODE_STRING[rights.Length];
        try {
            sid = Marshal.AllocHGlobal(sidBytes.Length);
            Marshal.Copy(sidBytes, 0, sid, sidBytes.Length);
            for (int i = 0; i < rights.Length; i++) arr[i] = Str(rights[i]);
            pol = Open(POLICY_CREATE_ACCOUNT | POLICY_LOOKUP_NAMES);
            uint st = LsaAddAccountRights(pol, sid, arr, (uint)rights.Length);
            return LsaNtStatusToWinError(st);
        } catch (System.ComponentModel.Win32Exception e) {
            return e.NativeErrorCode;
        } finally {
            if (pol != IntPtr.Zero) LsaClose(pol);
            if (sid != IntPtr.Zero) Marshal.FreeHGlobal(sid);
            foreach (LSA_UNICODE_STRING u in arr) if (u.Buffer != IntPtr.Zero) Marshal.FreeHGlobal(u.Buffer);
        }
    }

    // Delete an LSA private-data secret (LsaStorePrivateData with NULL data). 0 or a Win32
    // error; 2 (FILE_NOT_FOUND) = was not there. Used ONLY to remove the retired
    // L$QubesEtwProxyCred on upgrade - this script never stores one.
    public static int Delete(string key) {
        IntPtr pol = IntPtr.Zero;
        LSA_UNICODE_STRING k = Str(key);
        try {
            pol = Open(POLICY_CREATE_SECRET);
            uint st = LsaDeletePrivateData(pol, ref k, IntPtr.Zero);
            return LsaNtStatusToWinError(st);
        } catch (System.ComponentModel.Win32Exception e) {
            return e.NativeErrorCode;
        } finally {
            if (pol != IntPtr.Zero) LsaClose(pol);
            Marshal.FreeHGlobal(k.Buffer);
        }
    }

    // LOGON32_LOGON_BATCH = 4 - the logon type the agent uses at proxy launch (sec 10.14.3),
    // so this validates BOTH the credential and the batch-logon right in one call.
    public static bool ValidateBatchLogon(string user, string domain, string pass) {
        IntPtr token;
        if (!LogonUser(user, domain, pass, 4, 0, out token)) return false;
        CloseHandle(token);
        return true;
    }
}
'@
    } catch {
        Warned "native helper compile failed: $($_.Exception.Message)"
        Finish 0 'add-type-failed'
    }
}

# ---- 1. machine-random THROWAWAY password ------------------------------------------------
# 32 CSPRNG bytes -> base64 (44 chars, upper+lower+digits: satisfies any complexity policy).
# Exists ONLY in this process's memory, ONLY long enough to create the account and prove one
# batch logon; then discarded (step 6). NEVER stored, NEVER logged, NEVER echoed. The SYSTEM
# agent replaces it with its own in-memory password at every proxy launch (etwproxy.c).
$rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
$pwBytes = New-Object byte[] 32
$rng.GetBytes($pwBytes)
$pw = [Convert]::ToBase64String($pwBytes)
$secPw = ConvertTo-SecureString -String $pw -AsPlainText -Force

# ---- 2. the account: create once, adopt + re-randomize thereafter ------------------------
# New-LocalUser (like NetUserAdd level 1, sec 10.14.1) adds the account to NO local groups -
# unlike `net user /add`, which silently puts it in Users. That property is load-bearing:
# zero-groups means EVERY membership found later is one we did not grant.
# UserMayNotChangePassword blocks a SELF change (needs the old password); the SYSTEM agent's
# NetUserSetInfo(1003) is an administrative SET and is unaffected.
try {
    $existing = Get-LocalUser -Name $AccountName -ErrorAction SilentlyContinue
    if ($null -eq $existing) {
        New-LocalUser -Name $AccountName -Password $secPw `
            -Description 'Qubes Tools least-privilege ETW proxy' `
            -PasswordNeverExpires -AccountNeverExpires -UserMayNotChangePassword -ErrorAction Stop | Out-Null
        Say "ok     created local account $AccountName (no implicit groups)"
    } else {
        # Idempotent adoption: same account, fresh throwaway password (whatever it was is dead;
        # nothing is allowed to know it anyway - the agent resets it at every launch).
        Set-LocalUser -Name $AccountName -Password $secPw -PasswordNeverExpires $true -ErrorAction Stop
        Enable-LocalUser -Name $AccountName -ErrorAction SilentlyContinue
        Say "ok     adopted existing account $AccountName (password re-randomized)"
    }
} catch {
    # Managed image / policy block / LocalAccounts module unavailable: the whole feature skips.
    Warned "cannot create/update account '$AccountName': $($_.Exception.Message)"
    Warned 'ETW proxy account unavailable - the bridge will serve from the listener/DB rungs'
    Finish 0 'account-create-refused'
}

try {
    $sidObj = (New-Object System.Security.Principal.NTAccount($AccountName)).Translate(
        [System.Security.Principal.SecurityIdentifier])
    $script:AcctSid = $sidObj.Value
    Say "ok     account SID $($script:AcctSid)"
} catch {
    Warned "cannot resolve SID for '$AccountName': $($_.Exception.Message)"
    Finish 0 'sid-resolve-failed'
}

# ---- 3. group membership: NONE - and remove the PLU-era grant on upgrade -----------------
# The capability-grant split's core property: this token never holds Performance Log Users
# (or anything else). Group SIDs are SE_GROUP_MANDATORY - they cannot be dropped at runtime -
# so membership hygiene HERE is the enforcement (the proxy's own token guard only detects
# drift; etwproxy.c logs the census). PLU removal is the expected upgrade path, not a warning.
try {
    Remove-LocalGroupMember -SID $PluSid -Member $AccountName -ErrorAction Stop
    Say 'ok     removed legacy BUILTIN\Performance Log Users membership (split: consumer must never hold PLU)'
} catch {
    # not a member (the normal case on fresh installs) or the group is absent - both fine
}
# Strip anything else something/someone may have added (Administrators, Users, RDP,
# Backup/Remote Management Operators). By SID - names are localized. Removal failures are
# warnings; absence is the normal case.
foreach ($g in 'S-1-5-32-544', 'S-1-5-32-545', 'S-1-5-32-551', 'S-1-5-32-555', 'S-1-5-32-580') {
    try {
        Remove-LocalGroupMember -SID $g -Member $AccountName -ErrorAction Stop
        Warned "removed unexpected membership in local group $g (zero-groups is the contract)"
    } catch {
        # not a member (the normal case) or the group does not exist on this SKU - fine either way
    }
}
# Verify, don't assume: census the ACTUAL local-group memberships. nogroups=1 only on a
# verified-empty census (an unavailable census leaves it 0 - honest "unverified").
try {
    $adsi = [ADSI]"WinNT://$env:COMPUTERNAME/$AccountName,user"
    $residual = @($adsi.Invoke('Groups') | ForEach-Object {
        $_.GetType().InvokeMember('Name', 'GetProperty', $null, $_, $null) })
    if ($residual.Count -eq 0) {
        Say 'ok     group census verified empty (no memberships at all)'
        $flag.nogroups = 1
    } else {
        Warned ("account still member of: " + ($residual -join ', ') + ' - could not strip; the proxy token will carry these')
    }
} catch {
    Warned "group census unavailable: $($_.Exception.Message) (memberships unverified)"
}

# ---- 4. logon rights: batch yes, everything interactive/remote/network DENIED ------------
# (sec 10.14.2). SeBatchLogonRight is now LOAD-BEARING, not belt-and-braces: without PLU
# nothing else carries it in, and the agent's LogonUserW(LOGON32_LOGON_BATCH) fails without it.
$sidBytes = New-Object byte[] ($sidObj.BinaryLength)
$sidObj.GetBinaryForm($sidBytes, 0)
$rc = [QubesEtwProxyNative]::AddRights($sidBytes, @(
    'SeBatchLogonRight',
    'SeDenyInteractiveLogonRight',
    'SeDenyRemoteInteractiveLogonRight',
    'SeDenyNetworkLogonRight'))
if ($rc -eq 0) {
    Say 'ok     logon rights set: +SeBatchLogonRight (load-bearing), deny interactive/remote-interactive/network'
    $flag.rights = 1
} else {
    Warned "LsaAddAccountRights failed (win32 $rc) - agent batch logon will fail (proxy stays parked)"
}

# ---- 5. hide from the logon UI (cosmetic; the deny-interactive right enforces) -----------
try {
    $ul = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon\SpecialAccounts\UserList'
    if (-not (Test-Path $ul)) { New-Item -Path $ul -Force | Out-Null }
    New-ItemProperty -Path $ul -Name $AccountName -Value 0 -PropertyType DWord -Force | Out-Null
    $flag.hidden = 1
    Say 'ok     hidden from the logon UI (SpecialAccounts\UserList)'
} catch {
    Warned "could not hide the account from the logon UI: $($_.Exception.Message)"
}

# ---- 6. validate the batch path, then DISCARD the password -------------------------------
# The set-autologon.ps1 discipline survives the storage step's removal: prove the credential
# AND SeBatchLogonRight with the exact logon type the agent will use, so a provisioning-time
# failure is diagnosed HERE (loud, with context) instead of as a parked proxy at first launch.
# validated=0 does not abort the remaining lockdown steps - ACLs and firewall are independent
# of the credential - but it does zero `provisioned` (the agent's launch will fail the same way).
if ([QubesEtwProxyNative]::ValidateBatchLogon($AccountName, $env:COMPUTERNAME, $pw)) {
    Say 'ok     batch logon validated (account enabled + SeBatchLogonRight proven), password now discarded'
    $flag.validated = 1
} else {
    Warned "batch logon validation FAILED for $AccountName - the agent's launch-time logon will fail identically (proxy will park)"
}
# Discard: zero the key material, drop every reference. (.NET strings are immutable, so the
# base64 copy is only unreferenced, not scrubbed - accepted: this password authorizes nothing
# beyond this point, since the agent overwrites it with its own in-memory one at every launch.)
[Array]::Clear($pwBytes, 0, $pwBytes.Length)
$pw = $null; $secPw = $null; $pwBytes = $null
Remove-Variable pw, secPw, pwBytes -ErrorAction SilentlyContinue

# ---- 7. legacy cleanup: retire the LSA secret, the guard task, the persisted copy --------
# Upgrade path from the PLU/LSA-era provisioning. All three are load-bearing REMOVALS:
#   - the secret is a credential at rest that no longer has a legitimate reader;
#   - the boot task would rotate the password UNDER the agent (the rotation race, sec 10.17.5)
#     and would re-run the retired script from the persisted copy;
#   - the persisted copy is the old logic (PLU grant + secret store) waiting to be re-run.
$legacyOk = $true
$drc = [QubesEtwProxyNative]::Delete($LegacySecret)
if ($drc -eq 0) { Say "ok     retired LSA secret $LegacySecret deleted (no credential at rest)" }
elseif ($drc -eq 2) { } # ERROR_FILE_NOT_FOUND - fresh install, nothing to clean
else { Warned "could not delete retired LSA secret $LegacySecret (win32 $drc)"; $legacyOk = $false }
$null = & schtasks /query /tn $LegacyTask 2>&1
if ($LASTEXITCODE -eq 0) {
    $tr = & schtasks /delete /tn $LegacyTask /f 2>&1
    if ($LASTEXITCODE -eq 0) { Say "ok     retired boot task $LegacyTask deleted (agent owns the password now)" }
    else { Warned ("schtasks /delete $LegacyTask rc=$LASTEXITCODE : " + ($tr -join ' ')); $legacyOk = $false }
}
try {
    if (Test-Path -LiteralPath $LegacyPersist) {
        Remove-Item -LiteralPath $LegacyPersist -Force -ErrorAction Stop
        Say 'ok     retired persisted provisioning copy deleted'
    }
} catch { Warned "could not delete retired persisted copy: $($_.Exception.Message)"; $legacyOk = $false }
if ($legacyOk) { $flag.legacy = 1 }

# ---- 8. firewall: block ALL outbound for this SID (sec 10.14.4) --------------------------
# Belt to deny-network-logon's braces: even in-guest loopback/outbound from the proxy token is
# refused. Recreate-by-name = idempotent. A guest with the firewall service disabled degrades
# with a warning (the deny-network-logon right above still holds).
try {
    Remove-NetFirewallRule -Name $FwRuleName -ErrorAction SilentlyContinue
    New-NetFirewallRule -Name $FwRuleName `
        -DisplayName 'Qubes ETW proxy: block all outbound traffic' `
        -Direction Outbound -Action Block -Enabled True -Profile Any `
        -LocalUser "D:(A;;CC;;;$($script:AcctSid))" -ErrorAction Stop | Out-Null
    Say 'ok     outbound-block firewall rule scoped to the proxy SID'
    $flag.firewall = 1
} catch {
    Warned "firewall rule failed: $($_.Exception.Message) (deny-network-logon still applies)"
}

# ---- 9. bridge state dir: ZERO write access for the proxy --------------------------------
# %ProgramData%\qubes-toast-bridge holds the bridge's CONTROL surfaces (stop file, heartbeat,
# banner markers) and bridge.log. The proxy must not be able to stop, starve or spoof the
# bridge, so: remove the PLU-era Modify grant this script used to add here, then lay an
# explicit inheritable DENY of the write class for the proxy SID. The deny out-ranks any
# permissive inherited allow (ProgramData's defaults let authenticated users create files).
try {
    $stateDir = Join-Path $env:ProgramData 'qubes-toast-bridge'
    if (-not (Test-Path -LiteralPath $stateDir)) { New-Item -ItemType Directory -Force -Path $stateDir | Out-Null }
    $ic = & icacls "$stateDir" /remove:g ("*" + $script:AcctSid) 2>&1
    if ($LASTEXITCODE -ne 0) { Warned ("icacls /remove:g legacy state-dir grant rc=$LASTEXITCODE : " + ($ic -join ' ')) }
    # Specific rights (icacls does not mix simple + specific in one list): WD write-data/
    # add-file, AD append-data/add-subdir, WEA write-EA, WA write-attrs, DE delete, DC
    # delete-child - the full write/delete class, nothing of the read class.
    $ic = & icacls "$stateDir" /deny ("*" + $script:AcctSid + ":(OI)(CI)(WD,AD,WEA,WA,DE,DC)") 2>&1
    if ($LASTEXITCODE -eq 0) {
        Say "ok     proxy DENIED write/delete on $stateDir (bridge control surfaces untouchable)"
        $flag.statedeny = 1
    } else {
        Warned ("icacls deny on $stateDir failed rc=$LASTEXITCODE : " + ($ic -join ' '))
    }
} catch {
    Warned "state-dir lockdown failed: $($_.Exception.Message)"
}

# ---- 10. standard log location: an ACE scoped to the proxy's OWN log ---------------------
# notifhost --etw-proxy logs to <QwtLogDir>\etw-proxy.log (notifhost.cpp QwtLogDir + g_logName):
# HKLM\SOFTWARE\Invisible Things Lab\Qubes Tools : LogDir if set, else %SystemDrive%\Qubes Logs
# - the STANDARD QWT log location (windows-utils LogInitDefault convention), NOT the bridge
# state dir. Resolve it the same way (this elevated 64-bit PowerShell reads the same 64-bit
# view notifhost opens with KEY_WOW64_64KEY). The grant must survive the proxy's own rotation
# (BLog: rename etw-proxy.log -> etw-proxy.log.old with REPLACE, then re-create via OPEN_ALWAYS):
#   file ACEs (Modify) on both names cover append + the renames; folder-only WD covers the
#   re-create; CREATOR OWNER (inherit-only) keeps the re-created file writable by its creator
#   - which grants the proxy access ONLY to files the proxy itself creates, never to other
#   components' logs. icacls takes the */SID form, so no localized account names are involved.
try {
    $logDir = $null
    try {
        $lv = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Invisible Things Lab\Qubes Tools' `
                               -Name LogDir -ErrorAction Stop
        if ($lv.LogDir) { $logDir = [Environment]::ExpandEnvironmentVariables([string]$lv.LogDir) }
    } catch { }
    if (-not $logDir) { $logDir = Join-Path $env:SystemDrive 'Qubes Logs' }
    if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Force -Path $logDir | Out-Null }

    $aceOk = $true
    foreach ($f in 'etw-proxy.log', 'etw-proxy.log.old') {
        $p = Join-Path $logDir $f
        if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType File -Force -Path $p | Out-Null }
        $ic = & icacls "$p" /grant ("*" + $script:AcctSid + ":(M)") 2>&1
        if ($LASTEXITCODE -ne 0) { Warned ("icacls grant on $p rc=$LASTEXITCODE : " + ($ic -join ' ')); $aceOk = $false }
    }
    # folder-only FILE_ADD_FILE (WD): lets the proxy re-create etw-proxy.log after rotation.
    # No (OI)/(CI): existing and future files created by OTHERS stay untouchable by this SID.
    $ic = & icacls "$logDir" /grant ("*" + $script:AcctSid + ":(WD)") 2>&1
    if ($LASTEXITCODE -ne 0) { Warned ("icacls folder-only WD grant on $logDir rc=$LASTEXITCODE : " + ($ic -join ' ')); $aceOk = $false }
    # CREATOR OWNER (S-1-3-0), inherit-only Modify: the standard ProgramData-style semantics -
    # every file's creator keeps Modify on its own file. For this SID that is exactly and only
    # the re-created etw-proxy.log.
    $ic = & icacls "$logDir" /grant '*S-1-3-0:(OI)(CI)(IO)(M)' 2>&1
    if ($LASTEXITCODE -ne 0) { Warned ("icacls CREATOR OWNER grant on $logDir rc=$LASTEXITCODE : " + ($ic -join ' ')); $aceOk = $false }
    if ($aceOk) {
        Say "ok     proxy log ACE scoped to its own log under $logDir (standard QWT log location)"
        $flag.logdir = 1
    }
} catch {
    Warned "log-location ACL failed: $($_.Exception.Message) (proxy will run but cannot log)"
}

# ---- verdict -----------------------------------------------------------------------------
# Core chain under the split: account exists + logon rights + batch logon proven. Credential
# custody and the ETW session grant are the AGENT's per-launch job (etwproxy.c); nothing else
# is stored or scheduled here any more.
if ($flag.rights -eq 1 -and $flag.validated -eq 1) {
    Finish 1 'ok'
} elseif ($flag.rights -ne 1) {
    Finish 0 'logon-rights-failed'
} else {
    Finish 0 'batch-logon-validate-failed'
}
