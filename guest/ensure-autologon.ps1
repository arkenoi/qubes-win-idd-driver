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
#
# -AtBoot is passed by the boot task (QubesAutologonGuard) only; parts 5-7 run only then, never for the
# installer or the updater, which run this script for its autologon verdict.
param([switch]$AtBoot)
$ErrorActionPreference = 'Continue'
# The log sink, from beside this script (docs/ADR-logging.md).
$qwtLogPs1 = Join-Path $PSScriptRoot 'log.ps1'
try { . $qwtLogPs1 } catch { [Console]::Error.WriteLine("ensure-autologon.ps1: cannot load $qwtLogPs1 ($($_.Exception.Message)) - no log sink"); exit 1 }
if (-not (Get-Command Write-QwtLogLine -EA SilentlyContinue)) { [Console]::Error.WriteLine("ensure-autologon.ps1: $qwtLogPs1 has no Write-QwtLogLine - no log sink"); exit 1 }
# EVERY LINE IT PRINTS ALSO GOES TO ITS LOG, ensure-autologon.ps1-<yyyyMMdd>.log in the one log directory.
# Its boot task (QubesAutologonGuard) runs it with no console, and Task Scheduler discards the
# output: until 2026-11-01 a boot-time run left no record of what it found or repaired.
# Write-Output is SHADOWED rather than every call site edited, so the printed lines, the trailer the
# callers parse and the regions the offline suites extract (they run with the real cmdlet) stay as
# they were. A FAIL line is an error, a WARN line a warning; the blank separator is not logged.
function Write-Output {
    param([Parameter(Position = 0)][string]$InputObject)
    Microsoft.PowerShell.Utility\Write-Output $InputObject
    if (-not $InputObject) { return }
    $lvl = 'I'
    if ($InputObject -like 'FAIL*') { $lvl = 'E' } elseif ($InputObject -like 'WARN*') { $lvl = 'W' }
    $null = Write-QwtLogLine $lvl $InputObject -Module 'ensure-autologon.ps1'
}
$WL = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
$changed = 0
$warn = 0

function Get-WL($n) { (Get-ItemProperty -Path $WL -Name $n -ErrorAction SilentlyContinue).$n }

# 'zero' only when all $Size bytes of disk $Number were read and every one is zero; otherwise why not.
# .NET Framework's FileStream refuses a \\.\ device path, so the handle comes from CreateFileW.
function Test-QwtDiskAllZero {
    param([Parameter(Mandatory)][int]$Number, [Parameter(Mandatory)][int64]$Size)
    try {
        if (-not ('QwtBlankDisk' -as [type])) {
            Add-Type @'
using System; using System.IO; using System.Runtime.InteropServices; using Microsoft.Win32.SafeHandles;
public static class QwtBlankDisk {
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern SafeFileHandle CreateFileW(string name, uint access, uint share, IntPtr sa, uint disposition, uint flags, IntPtr template);
    public static string Check(int number, long size) {
        if (size <= 0) return "size " + size;
        // GENERIC_READ, FILE_SHARE_READ|FILE_SHARE_WRITE, OPEN_EXISTING
        using (SafeFileHandle h = CreateFileW(@"\\.\PhysicalDrive" + number, 0x80000000u, 3u, IntPtr.Zero, 3u, 0u, IntPtr.Zero)) {
            if (h.IsInvalid) return "open failed, error " + Marshal.GetLastWin32Error();
            using (FileStream fs = new FileStream(h, FileAccess.Read, 4096, false)) {
                byte[] buf = new byte[4 << 20];
                long done = 0;
                while (done < size) {
                    int want = (int)Math.Min(buf.Length, size - done);
                    int got = fs.Read(buf, 0, want);
                    if (got <= 0) return "read ended at byte " + done + " of " + size;
                    for (int i = 0; i < got; i++) if (buf[i] != 0) return "non-zero byte at offset " + (done + i);
                    done += got;
                }
                return "zero";
            }
        }
    }
}
'@
        }
        return [QwtBlankDisk]::Check($Number, $Size)
    } catch { return "read failed: $($_.Exception.Message.Split([char]10)[0])" }
}

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

# The autologon account's password must not expire (owner decision 2026-10-06; set-autologon.ps1 sets it at arming).
# Re-asserted here because a policy or the user can turn expiry back on, and an expired password stops autologon exactly
# like a wrong one. A password that is ALREADY past its date and cannot be fixed means autologon will not happen (warn,
# exit 2); one that merely cannot be changed yet is reported without touching the exit contract.
$pwNoExpire = 'n/a'
if ($user) {
    $dom = Get-WL 'DefaultDomainName'
    if (-not $dom -or $dom -eq $env:COMPUTERNAME) {
        $due = $null
        try {
            $lu = Get-LocalUser -Name $user -ErrorAction Stop
            $due = $lu.PasswordExpires
            if ($null -ne $due) {
                Set-LocalUser -Name $user -PasswordNeverExpires $true -ErrorAction Stop
                $changed++
                Write-Output "ok     set the password of $user never to expire (it was due $due)"
            } else {
                Write-Output "ok     the password of $user never expires"
            }
            $pwNoExpire = 'yes'
        } catch {
            $pwNoExpire = 'error'
            if ($null -ne $due -and $due -le (Get-Date)) {
                Write-Output "WARN   the password of $user EXPIRED $due and could not be set never to expire - autologon will fail"
                $warn++
            } else {
                Write-Output "WARN   could not check or set the password expiry of ${user}: $($_.Exception.Message.Split([char]10)[0])"
            }
        }
    }
}

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
    # NAME WHO WE RAN AS. Owner, 2026-10-08: "how is it possible that it 'could not be verified'?"
    # It is possible in exactly three ways, all of them OURS, and none of them an ambiguous guest:
    #   1. Add-Type could not compile the shim (no compiler, AV, a locked temp);
    #   2. LsaOpenPolicy(POLICY_GET_PRIVATE_INFORMATION) returned non-zero - that access needs
    #      SYSTEM or an elevated admin, so a non-elevated run gets STATUS_ACCESS_DENIED;
    #   3. LsaRetrievePrivateData returned anything but success or STATUS_OBJECT_NAME_NOT_FOUND.
    # A genuinely MISSING secret is NOT this state: 0xC0000034 is treated as a definitive absence
    # and reports "absent" (exit 2). So "unverified" always means the probe itself could not run -
    # and the identity is the one fact that was never recorded, while being the likeliest cause.
    # The task is registered to run as SYSTEM (S-1-5-18); if this says otherwise, that is the bug.
    $who = '?'; $elev = '?'
    try { $who = [Security.Principal.WindowsIdentity]::GetCurrent().Name } catch { }
    try {
        $pr = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
        $elev = [string]$pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { }
    Write-Output "WARN   could not query the LSA secret ($($_.Exception.Message.Split([char]10)[0]))"
    Write-Output "WARN   the probe ran as '$who' (admin role: $elev) - reading an LSA secret needs SYSTEM"
}

# VERIFIED BY EFFECT, which needs no privileged read at all. If autologon is configured for a user
# and that user IS logged on at the console, then autologon demonstrably happened on THIS boot -
# this script runs from a boot task, so had it not happened the guest would be sitting at the
# sign-in screen with no console user. That is a positive finding about the mechanism, from
# something observable, and it is what makes "unverified" rare rather than routine.
$effect = $false
# RE-READ, not a variable that does not exist: my first version tested $auto, which this script
# never defines (line 39 reads AutoAdminLogon inline and sets it to 1 when absent), so the whole
# effect check would have been a silent no-op - a fix that does nothing is worse than none.
if ((Get-WL 'AutoAdminLogon') -eq '1' -and $user) {
    $consoleUser = ''
    try { $consoleUser = "$((Get-CimInstance Win32_ComputerSystem -EA Stop).UserName)" } catch { }
    if ($consoleUser) {
        $leaf = $consoleUser.Split('\')[-1]
        if ($leaf -and $leaf -ieq $user) {
            $effect = $true
            Write-Output "ok     autologon VERIFIED BY EFFECT: '$consoleUser' is logged on at the console and AutoAdminLogon=1, so it happened on this boot"
        }
    }
}

$unknown = 0
if ($lsa) {
    Write-Output 'ok     password present as the LSA secret (not consumable, not plaintext)'
    if ($pass) {
        Write-Output 'note   a plaintext registry DefaultPassword also exists and is redundant'
    }
} elseif ($pass) {
    Write-Output 'ok     DefaultPassword present (plaintext registry value - consumable)'
} elseif ((-not $lsaKnown) -and $effect) {
    # The probe could not run, but the mechanism was observed working this boot - so this is not an
    # unknown, and it must not exit 3 and tell the user the guard failed.
    Write-Output 'ok     the LSA secret could not be queried, but autologon was verified by effect above'
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

# The profile repair below signs out a temporary-profile session with ForceAutoLogon=1 set, which is what
# makes Winlogon log the user on again (docs/ADR-windows.md decision 4). It marks that it set the value,
# and the next boot removes both, so a later manual sign-out behaves as it did before the repair.
$qtKey = 'HKLM:\SOFTWARE\Invisible Things Lab\Qubes Tools'
$forceMark = 'ProfileRepairForceAutoLogon'
if ($AtBoot -and (Get-ItemProperty -Path $qtKey -Name $forceMark -ErrorAction SilentlyContinue)) {
    try {
        Remove-ItemProperty -Path $WL -Name 'ForceAutoLogon' -Force -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path $qtKey -Name $forceMark -Force -ErrorAction Stop
        Write-Output 'SET    ForceAutoLogon removed: the profile repair set it on the previous boot'
    } catch {
        Write-Output "WARN   ForceAutoLogon set by the profile repair could not be removed: $($_.Exception.Message.Split([char]10)[0])"
    }
}

# 4. A profile store that was never filled. MoveUsers keeps every profile on the private volume
#    (C:\Users is a link to Q:\Users), and `qvm-create --class StandaloneVM --template T` gives the new
#    qube a copy of T's root with a NEW, EMPTY private volume: the link dangles, the autologon user
#    gets a temporary profile (User Profile Service 1505) and the shell never starts. Nothing in the
#    guest can bring T's profiles back. When the installer left a profile seed on the root volume, the
#    guard gives the qube a fresh profile store as a Linux qube gets a fresh home from /etc/skel
#    (docs/ADR-windows.md section 14): Q: on the blank disk with the installer's two calls, Q:\Users
#    seeded with Default and Public, every S-1-5-21 ProfileList entry whose folder is gone removed so
#    Windows builds new profiles, and the boot goes on. Without a seed, or when a step fails, the user is
#    told the remedy once per boot (qvm-clone copies the private volume) and autologon still happens. The private disk is told apart by serial, the installer's rule
#    (Classify-PrivateDiskState, packaging/setup/Install-QwtImproved.ps1).
try {
    $cu = Get-Item -LiteralPath 'C:\Users' -Force -ErrorAction Stop
    $cuTarget = if (($cu.Attributes -band [IO.FileAttributes]::ReparsePoint) -and $cu.Target) { [string]@($cu.Target)[0] } else { '' }
    if (-not $cuTarget) {
        Write-Output 'ok     profile store C:\Users is a plain directory'
    } elseif ($cuTarget -notmatch '^[A-Za-z]:\\' -or (Test-Path -LiteralPath $cuTarget.Substring(0, 3))) {
        Write-Output "ok     profile store C:\Users links to $cuTarget"
    } else {
        $priv = @(Get-Disk -ErrorAction Stop | Where-Object { ([string]$_.SerialNumber).Trim() -in @('QM00002', '0001') })
        $privState = if ($priv.Count -eq 1) { [string]$priv[0].PartitionStyle } else { "matched by $($priv.Count) disks" }
        # MoveUsers always relocates to Q:, the private volume's letter; a link to any other missing drive
        # was not made by us, so the notice's cause would be a guess.
        if ($cuTarget -notmatch '^[Qq]:\\' -or $privState -ne 'RAW') {
            Write-Output "WARN   NO USER PROFILE can load: C:\Users links to $cuTarget, whose drive does not exist; private disk: $privState"
        } else {
            Write-Output "WARN   NO USER PROFILE can load: C:\Users links to $cuTarget, whose drive does not exist, and the private disk is blank -"
            Write-Output 'WARN   this qube was made from a template without its private volume'
            $seed = Join-Path $env:ProgramData 'Qubes\profile-seed'
            $repaired = $false
            $why = 'no profile seed on the root volume (the template was installed before it was kept)'
            if (Test-Path -LiteralPath (Join-Path $seed 'Default\NTUSER.DAT')) {
                $p = $priv[0]; $pSn = ([string]$p.SerialNumber).Trim(); $touched = $false; $seeded = $false
                try {
                    # The installer's prepare: the identity is read again at the instant of the write.
                    $now = Get-Disk -Number $p.Number -ErrorAction Stop
                    if (([string]$now.SerialNumber).Trim() -ne $pSn -or [string]$now.PartitionStyle -ne 'RAW') {
                        throw "disk #$($p.Number) changed: now sn '$(([string]$now.SerialNumber).Trim())' style $($now.PartitionStyle) - not writing"
                    }
                    # RAW says only that Windows found no partition table; a damaged table or a disk that reads
                    # badly at boot looks the same while holding data. Blank means every byte is zero, as
                    # core-agent-linux setup-rwdev.sh requires before it formats a private volume.
                    $blank = Test-QwtDiskAllZero -Number $p.Number -Size ([int64]$now.Size)
                    if ($blank -ne 'zero') { throw "disk #$($p.Number) is not blank ($blank) - not writing" }
                    if ($now.IsOffline)  { Set-Disk -Number $p.Number -IsOffline $false -ErrorAction Stop }
                    if ($now.IsReadOnly) { Set-Disk -Number $p.Number -IsReadOnly $false -ErrorAction Stop }
                    $touched = $true
                    Initialize-Disk -Number $p.Number -PartitionStyle GPT -PassThru -ErrorAction Stop | Out-Null
                    $null = New-Volume -DiskNumber $p.Number -DriveLetter Q -FriendlyName 'Qubes Private Image' -FileSystem NTFS -ErrorAction Stop
                    $onDisk = $null
                    for ($vtry = 0; $vtry -lt 4; $vtry++) {
                        $onDisk = try { [int](Get-Partition -DriveLetter Q -ErrorAction Stop).DiskNumber } catch { $null }
                        if ((Test-Path -LiteralPath 'Q:\') -and $onDisk -eq [int]$p.Number) { break }
                        Start-Sleep -Seconds 2
                    }
                    if (-not (Test-Path -LiteralPath 'Q:\') -or $onDisk -ne [int]$p.Number) { throw "Q: is not on disk #$($p.Number) after New-Volume" }
                    Write-Output "SET    Q: created on the private disk #$($p.Number) (sn $pSn)"
                    foreach ($sp in 'Default', 'Public') {
                        $null = & robocopy.exe (Join-Path $seed $sp) (Join-Path 'Q:\Users' $sp) /E /COPY:DAT /DCOPY:DAT /R:0 /W:0 /NP /NFL /NDL /NJH /NJS 2>&1
                        if ($LASTEXITCODE -ge 8) { throw "seeding Q:\Users\$sp failed (robocopy rc=$LASTEXITCODE)" }
                    }
                    $seeded = $true
                    Write-Output 'SET    Q:\Users seeded with Default and Public from the root volume'
                    $pl = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
                    foreach ($k in @(Get-ChildItem -LiteralPath $pl -ErrorAction Stop | Where-Object { $_.PSChildName -like 'S-1-5-21-*' })) {
                        $img = [Environment]::ExpandEnvironmentVariables([string](Get-ItemProperty -LiteralPath $k.PSPath -Name ProfileImagePath -ErrorAction SilentlyContinue).ProfileImagePath)
                        if ($img -and (Test-Path -LiteralPath $img)) { continue }
                        Remove-Item -LiteralPath $k.PSPath -Recurse -Force -ErrorAction Stop
                        Write-Output "SET    removed ProfileList $($k.PSChildName) (its folder $img does not exist)"
                    }
                    $repaired = $true
                } catch {
                    $why = $_.Exception.Message.Split([char]10)[0]
                    Write-Output "WARN   the repair failed: $why"
                    if ($touched -and -not $seeded) {
                        # Back to RAW, so the next boot finds the same state and tries again.
                        try { Clear-Disk -Number $p.Number -RemoveData -RemoveOEM -Confirm:$false -ErrorAction Stop; Write-Output "SET    disk #$($p.Number) cleared back to RAW" }
                        catch { Write-Output "WARN   could not clear disk #$($p.Number): $($_.Exception.Message.Split([char]10)[0])" }
                    }
                }
            }
            if ($repaired) {
                # As on Linux, the boot goes on and nothing is sent to dom0. An autologon that already ran got a
                # temporary profile. A sign-out alone leaves the guest at the sign-in screen; with ForceAutoLogon=1
                # Winlogon logs the user on again, now from the fresh store.
                $sids = @(Get-Process -IncludeUserName -ErrorAction SilentlyContinue |
                          Where-Object { $_.SessionId -gt 0 -and $user -and ([string]$_.UserName).EndsWith("\$user", [StringComparison]::OrdinalIgnoreCase) } |
                          Select-Object -ExpandProperty SessionId -Unique)
                if ($sids.Count -and [string](Get-WL 'ForceAutoLogon') -ne '1') {
                    try {
                        # The marker first: if the second write fails, the next boot still removes what was set.
                        if (-not (Test-Path -LiteralPath $qtKey)) { New-Item -Path $qtKey -Force -ErrorAction Stop | Out-Null }
                        New-ItemProperty -Path $qtKey -Name $forceMark -Value 1 -PropertyType DWord -Force -ErrorAction Stop | Out-Null
                        New-ItemProperty -Path $WL -Name 'ForceAutoLogon' -Value '1' -PropertyType String -Force -ErrorAction Stop | Out-Null
                        Write-Output 'SET    ForceAutoLogon=1 for the sign-out below; the next boot removes it'
                    } catch {
                        Write-Output "WARN   could not set ForceAutoLogon, so the session is not signed out - the new profile is used from the next restart: $($_.Exception.Message.Split([char]10)[0])"
                        $sids = $null
                    }
                }
                foreach ($sid in $sids) {
                    & logoff.exe $sid 2>&1 | Out-Null
                    Write-Output "SET    signed out session $sid of $user (rc=$LASTEXITCODE) - autologon logs on again with the new profile"
                }
                if ($null -ne $sids -and -not $sids.Count) { Write-Output "ok     no session of $user yet - its first logon builds the new profile" }
            } else {
                $sent = 'unavailable:helper-absent'
                $nh = @((Join-Path $PSScriptRoot 'qwt-notify-error.ps1'), (Join-Path (Split-Path -Parent $PSScriptRoot) 'bin\qwt-notify-error.ps1')) |
                      Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
                if ($nh) {
                    # The helper's own lines go to this script's log, never to the pipeline: a line written there
                    # inside Send-QwtError would become part of its return value.
                    $script:QwtNotifyLog = { param($m) $null = Write-QwtLogLine 'W' "NOTIFYERR $m" -Module 'ensure-autologon.ps1'; Write-Host "note   NOTIFYERR $m" }
                    . $nh
                    $sent = Send-QwtError -Component 'autologon' -Id 'private-volume-empty' -Severity ACTION `
                        -Header 'User profiles missing, private volume empty' `
                        -Next 'Windows shows no desktop. Recreate the qube in dom0: qvm-clone --class StandaloneVM TEMPLATE NAME' `
                        -Cause "Not repaired: $why" `
                        -Tech (Format-QwtNotifyTechLine -Subject 'ensure-autologon.ps1' -Code "C:\Users links to the missing $cuTarget" `
                                 -Evidence 'Application log, User Profile Service event 1505')
                }
                Write-Output "WARN   dom0 notice: $sent"
            }
        }
    }
} catch {
    Write-Output "WARN   could not check where the user profiles live: $($_.Exception.Message.Split([char]10)[0])"
}

# 5. Volumes extended in dom0 while the qube was halted grow now, as Linux grows /rw at every boot.
#    resize-disk.ps1 is also the qubes.ResizeDisk handler that dom0 calls on a running qube. It runs in its
#    own process: its output goes to the console, which this script captures and logs. Its outcome never
#    counts as an autologon warning - the exit code below is about autologon only.
$rz = Join-Path $PSScriptRoot 'resize-disk.ps1'
if (-not $AtBoot) {
    # not the boot task
} elseif (Test-Path -LiteralPath $rz) {
    foreach ($v in 'private', 'root') {
        $rzOut = @(& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $rz -Disk $v 2>&1)
        $rzRc = $LASTEXITCODE
        foreach ($l in $rzOut) { if ("$l") { Write-Output ("{0} resize {1}: {2}" -f $(if ($rzRc) { 'WARN  ' } else { 'note  ' }), $v, "$l") } }
        if (-not $rzOut.Count) { Write-Output "WARN   resize ${v}: no output (rc=$rzRc)" }
    }
} else {
    Write-Output 'WARN   resize-disk.ps1 is not beside this script - volumes extended in dom0 do not grow at boot'
}

# 6. The profile seed follows the live Default and Public, as /etc/skel on a template's root is always
#    current: updates and machine-wide installs change both on Q:, and a standalone made from this qube's
#    root would otherwise be seeded from the install-time copy. Same copy as the installer's (data,
#    attributes, timestamps, junctions excluded), at boot only, and only where C:\Users is Q:\Users.
#    Templates only: `qvm-create --template` takes a TemplateVM, so no other qube's seed is ever read, and an
#    AppVM's root writes are discarded at shutdown. A class QubesDB cannot answer keeps the refresh.
if ($AtBoot) {
    $seedRoot = Join-Path $env:ProgramData 'Qubes\profile-seed'
    # Inline mirror of guest/qubesdb-read.ps1's Get-QubesDbValue: this file runs installed and alone.
    $vmClass = $null
    try {
        if (-not ('QwtGuardQdb' -as [type])) {
            Add-Type @'
using System; using System.Runtime.InteropServices;
public static class QwtGuardQdb {
    [DllImport("qubesdb-client.dll", CallingConvention=CallingConvention.Cdecl)]
    public static extern IntPtr qdb_open(IntPtr vmname);
    [DllImport("qubesdb-client.dll", CallingConvention=CallingConvention.Cdecl, CharSet=CharSet.Ansi)]
    public static extern IntPtr qdb_read(IntPtr h, string path, out uint value_len);
    [DllImport("qubesdb-client.dll", CallingConvention=CallingConvention.Cdecl)]
    public static extern void qdb_close(IntPtr h);
}
'@
        }
        $qh = [QwtGuardQdb]::qdb_open([IntPtr]::Zero)
        if ($qh -ne [IntPtr]::Zero) {
            try {
                $qlen = [uint32]0
                $qp = [QwtGuardQdb]::qdb_read($qh, '/type', [ref]$qlen)
                if ($qp -ne [IntPtr]::Zero) { $vmClass = [Runtime.InteropServices.Marshal]::PtrToStringAnsi($qp, [int]$qlen).Trim() }
            } finally { [QwtGuardQdb]::qdb_close($qh) }
        }
    } catch { $vmClass = $null }
    if ($vmClass -and $vmClass -ne 'TemplateVM') {
        Write-Output "ok     profile seed: not kept on this $vmClass - only a template's seed is read"
    } elseif ($cuTarget -match '^[Qq]:\\Users\\?$' -and (Test-Path -LiteralPath 'Q:\Users\Default\NTUSER.DAT')) {
        if (-not $vmClass) { Write-Output "note   profile seed: the qube class is unreadable from QubesDB - refreshing as on a template" }
        foreach ($sp in 'Default', 'Public') {
            $src = Join-Path 'Q:\Users' $sp
            if (-not (Test-Path -LiteralPath $src)) { Write-Output "WARN   profile seed: $src is absent"; continue }
            $null = & robocopy.exe $src (Join-Path $seedRoot $sp) /MIR /COPY:DAT /DCOPY:DAT /XJ /R:0 /W:0 /NP /NFL /NDL /NJH /NJS 2>&1
            $rc = $LASTEXITCODE
            if ($rc -ge 8) { Write-Output "WARN   profile seed: copying $src failed (robocopy rc=$rc)" }
            elseif ($rc -gt 0) { Write-Output "SET    profile seed: $sp refreshed (robocopy rc=$rc)" }
            else { Write-Output "ok     profile seed: $sp current" }
        }
    } else {
        Write-Output "note   profile seed not refreshed: C:\Users links to '$cuTarget' or Q:\Users\Default has no NTUSER.DAT"
    }
    # 7. The updates proxy belongs to the template (ADR-updater §18 point 4). Its pass keeps the proxy configured on
    #    the template's root, and every qube made from that root boots with it - where nothing serves 127.0.0.1:8082.
    #    Not a template: remove what OUR pass wrote, and only that - a WinHTTP or WinINET proxy that is not ours, and
    #    the policy value when the machine proxy is someone else's, are left as they are. An unreadable class changes
    #    nothing (a template must keep its proxy).
    if ($vmClass -and $vmClass -ne 'TemplateVM') {
        $ours = '127.0.0.1:8082'
        $isK = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings'
        $polK = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\Internet Settings'
        $done = @()
        $wh = (& netsh winhttp show proxy 2>&1 | Out-String)
        if ($wh -match [regex]::Escape($ours)) { & netsh winhttp reset proxy | Out-Null; $done += 'WinHTTP proxy' }
        $ps = (Get-ItemProperty -LiteralPath $isK -Name ProxyServer -ErrorAction SilentlyContinue).ProxyServer
        if ($ps -eq $ours) {
            Set-ItemProperty -LiteralPath $isK -Name ProxyEnable -Value 0 -Type DWord -ErrorAction SilentlyContinue
            Remove-ItemProperty -LiteralPath $isK -Name ProxyServer, ProxyOverride -ErrorAction SilentlyContinue
            $done += 'machine WinINET proxy'
        }
        if ((-not $ps -or $ps -eq $ours) -and $null -ne (Get-ItemProperty -LiteralPath $polK -Name ProxySettingsPerUser -ErrorAction SilentlyContinue).ProxySettingsPerUser) {
            Remove-ItemProperty -LiteralPath $polK -Name ProxySettingsPerUser -ErrorAction SilentlyContinue
            $done += 'per-machine proxy policy'
        }
        # Revocation checking off goes whoever wrote it: on a qube with a network it weakens every WinINet connection.
        if ((Get-ItemProperty -LiteralPath $polK -Name CertificateRevocation -ErrorAction SilentlyContinue).CertificateRevocation -eq 0) {
            Remove-ItemProperty -LiteralPath $polK -Name CertificateRevocation -ErrorAction SilentlyContinue
            $done += 'revocation-check-off policy'
        }
        $aiK = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppInstaller'
        if ((Get-ItemProperty -LiteralPath $aiK -Name DefaultProxy -ErrorAction SilentlyContinue).DefaultProxy -eq "http://$ours") {
            Remove-ItemProperty -LiteralPath $aiK -Name DefaultProxy -ErrorAction SilentlyContinue
            $done += 'winget proxy policy'
        }
        if ($null -ne (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Qubes\UpdatesProxy' -Name UpdaterPids -ErrorAction SilentlyContinue).UpdaterPids) {
            Remove-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Qubes\UpdatesProxy' -Name UpdaterPids -ErrorAction SilentlyContinue
            $done += 'relay registration'
        }
        if ($done.Count) { Write-Output ("SET    updates proxy: removed on this $vmClass - " + ($done -join ', ')) }
        else { Write-Output "ok     updates proxy: none of ours on this $vmClass" }
    } elseif (-not $vmClass) {
        Write-Output "note   updates proxy: the qube class is unreadable from QubesDB - left as it is"
    }
}

$lsaState = if (-not $lsaKnown) { 'unknown' } elseif ($lsa) { 'present' } else { 'absent' }
# reason= names the ONE thing to repair, in the same token form set-autologon.ps1 uses, so a caller
# reading only the trailer can record it instead of guessing. Before this token every warning was
# reported by the installer as 'not-armed:no-password' - including a guest whose Winlogon
# DefaultUserName had been wiped by servicing while its LSA secret was intact, which sent the user
# to supply a password that was not the problem (audit 2026-09-08 #16). Precedence: a missing user
# name first (nothing logs on without it, whatever the password state - lsa= still carries that),
# then a positively absent password, then the unverified probe; 'none' when autologon will happen.
$reason = if (-not $user) { 'no-user' }
          elseif ($warn -gt 0) { 'no-password' }
          elseif ($unknown -gt 0) { 'lsa-unverified' }
          else { 'none' }
Write-Output ''
# warnings= counts the unverified case too, so a caller that only reads the trailer (the
# installer's stage-2 verify) does not log "armed" for a state it could not check; lsa= says which
# case it was, reason= which repair applies.
Write-Output ("=== RESULT === changed=$changed warnings=$($warn + $unknown) lsa=$lsaState reason=$reason pwnoexpire=$pwNoExpire")
# EXIT CODE IS A CONTRACT: 0 = autologon will happen on the next boot, 2 = it will NOT and the
# qube would come back unreachable, 3 = it could not be VERIFIED (the LSA probe itself failed; no
# positive finding either way). The updater refuses to reboot on 2 rather than knowingly stranding
# the qube - see wu-update.ps1; 3 is deliberately not 2, so a probe fault cannot block every
# dom0-driven update of an armed guest.
if ($warn -gt 0) { exit 2 }
if ($unknown -gt 0) { exit 3 }
exit 0
