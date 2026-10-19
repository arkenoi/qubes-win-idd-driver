# logvol-bind.ps1 - GUEST SIDE of the secondary log volume (mgmt/harness/logvol-lib.sh). Lives under
# mgmt/harness/, NOT guest/: guest/*.ps1 may be staged into the shipped package, and this is rig
# instrumentation for TEST cells only.
#
# Runs as SYSTEM over qubes.VMShell:
#   tools/qtest pushrun mgmt/harness/logvol-bind.ps1 -Id <cell-id> [-Mode registry|junction] [-NoCopy]
#   tools/qtest pushrun mgmt/harness/logvol-bind.ps1 -Restore
#
# WHAT IT DOES (registry mode, the default - the Jev-chosen mechanism, see the library header):
#   1. finds the volume BY LABEL (LOGVOL) and by its LOGVOL.TAG - never by letter, letters are not stable;
#   2. reads the root LogDir (HKLM\SOFTWARE\Invisible Things Lab\Qubes Tools), saves it as LogDirPreLogvol
#      (only the first time - a re-run must not overwrite the saved original with the volume path);
#   3. COPIES the current log directory onto the volume (robocopy /E; the writers hold their files with
#      FILE_SHARE_READ, so open logs copy) - the install-boot logs would otherwise stay behind;
#   4. sets LogDir=<vol>:\qwt-logs\<id> and LogSafeFlush=1 at the ROOT key. Every windows-utils module
#      reads both at its next LogInit (CfgReadDword/CfgReadString fall back from the module key to the
#      root), so the effect is complete from the NEXT BOOT; modules started before this call keep their
#      current file and their current flush mode until then.
# junction mode (opt-in, UNMEASURED): an NTFS junction at "<LogDir>.logvol" -> the volume path, and two
#   PendingFileRenameOperations queued for smss to swap it into <LogDir> at the next boot, before any
#   service opens a log. LogSafeFlush=1 is set in this mode too. The registry LogDir is NOT changed.
# -Restore: registry mode puts LogDir and LogSafeFlush back from their saved copies; junction mode
#   queues the reverse renames. Nothing is deleted from the volume, ever.
#
# OUTPUT: exactly one line starting with 'LOGVOL-BIND ' (a marker that never appears in the command
# qtest echoes back - the a0-lib self-match lesson):
#   LOGVOL-BIND ok mode=<m> id=<id> drive=<L:> old=<b64> new=<b64> copied=<n> safeflush=1 [pending=1]
#   LOGVOL-BIND restored mode=<m> logdir=<b64>
#   LOGVOL-BIND fail reason=<why>
# Paths travel base64-encoded (they contain spaces); the caller decodes what it needs.
param(
    [string]$Id = '',
    [ValidateSet('registry', 'junction')][string]$Mode = 'registry',
    [switch]$Restore,
    [switch]$NoCopy
)
$ErrorActionPreference = 'Stop'
$RegKey = 'HKLM:\SOFTWARE\Invisible Things Lab\Qubes Tools'
$Label = 'DIAG'   # one stick, and this is the label the install's own cmd resolves

function B64([string]$s) { if ($null -eq $s) { $s = '' }; return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($s)) }
function Fail([string]$why) { Write-Output ("LOGVOL-BIND fail reason=" + $why); exit 1 }

function Find-LogVol {
    # BY LABEL AND TAG. Win32_LogicalDisk lists every mounted volume with a letter; the removable
    # usb-storage FAT shows DriveType 2. The tag file is what distinguishes OUR volume from any other
    # FAT that happens to carry the label.
    $disks = @(Get-CimInstance Win32_LogicalDisk -ErrorAction SilentlyContinue | Where-Object { $_.VolumeName -eq $Label })
    foreach ($d in $disks) {
        $tag = Join-Path $d.DeviceID 'LOGVOL.TAG'
        if (Test-Path -LiteralPath $tag) { return $d.DeviceID }
    }
    return $null
}

function Pin-LogVol([string]$cur) {
    # THE LETTER MUST NOT MOVE, because LogDir records one and every module reads it once at init.
    # The volume is found BY LABEL above, which is correct and letter-independent; the defect was
    # writing whatever letter it happened to have. That letter depends on which OTHER removable
    # volumes are attached, and the priming sticks are still present in the RUNNING guest when this
    # binds (unassigning a claim only takes effect at the next domain creation) - so the stick binds
    # as E: or F: and comes back as D: on the next boot, which is exactly how four acceptance runs
    # failed on a healthy guest.
    #
    # CHANGING a letter is Set-Partition's job, not mountvol's. mountvol ADDS a mount point and
    # leaves the existing letter in place: measured 2026-10-15, the receipt came back
    # "drive=E: found=E: letter=same" with the volume still on E:, so nothing was pinned and the
    # next boot would have moved it again. Set-Partition rewrites the assignment, which Windows
    # persists under MountedDevices keyed by the volume's own GUID, so it survives reboots and any
    # change in the device set. diskpart is the fallback for a guest whose Storage module is absent.
    $want = 'Z'
    if ($cur -eq ($want + ':')) { return $cur }
    $curLetter = $cur.TrimEnd(':')

    # NEVER TAKE A LETTER IN USE: keep the current one rather than displacing a volume this script
    # knows nothing about.
    $taken = Get-CimInstance Win32_Volume -Filter ("DriveLetter='" + $want + ":'") -ErrorAction SilentlyContinue
    if ($taken) { return $cur }

    try {
        $p = Get-Partition -DriveLetter $curLetter -ErrorAction Stop
        $p | Set-Partition -NewDriveLetter $want -ErrorAction Stop
    } catch {
        # No Storage module, or it refused: fall back to diskpart, which every Windows has.
        $vol = Get-CimInstance Win32_Volume -Filter ("DriveLetter='" + $cur + "'") -ErrorAction SilentlyContinue
        if (-not $vol) { return $cur }
        $script = Join-Path $env:TEMP 'logvol-pin.txt'
        @("select volume $curLetter", "assign letter=$want", 'exit') | Set-Content -LiteralPath $script -Encoding ASCII
        & diskpart /s $script 2>&1 | Out-Null
        Remove-Item -LiteralPath $script -Force -ErrorAction SilentlyContinue
    }

    # VERIFY, never assume: re-resolve by label and report what actually happened.
    Start-Sleep -Milliseconds 900
    $after = Find-LogVol
    if ($after -eq ($want + ':')) { return $after }
    if ($after) { return $after }
    return $cur
}

function Get-RegValue([string]$name) {
    $p = Get-ItemProperty -Path $RegKey -Name $name -ErrorAction SilentlyContinue
    if ($null -eq $p) { return $null }
    return $p.$name
}

if (-not (Test-Path -Path $RegKey)) { Fail 'no_qubes_tools_key' }

if ($Restore) {
    $saved = Get-RegValue 'LogDirPreLogvol'
    $savedFlush = Get-RegValue 'LogSafeFlushPreLogvol'
    $cur = Get-RegValue 'LogDir'
    if ($null -ne $saved) {
        Set-ItemProperty -Path $RegKey -Name 'LogDir' -Value ([string]$saved)
        Remove-ItemProperty -Path $RegKey -Name 'LogDirPreLogvol' -ErrorAction SilentlyContinue
    }
    # UNDO EXACTLY WHAT THE BIND WROTE, no more: the bind records the module list it touched in
    # LogDirModulesPreLogvol, so the restore removes the LogDir value from those module keys and
    # leaves any key, and any other value, that was already there. A module key is only REMOVED
    # when it is left with no values at all, which means the bind is what created it.
    $savedMods = Get-RegValue 'LogDirModulesPreLogvol'
    if ($null -ne $savedMods) {
        foreach ($m in ([string]$savedMods -split ';' | Where-Object { $_ })) {
            $mk = Join-Path $RegKey $m
            if (Test-Path -Path $mk) {
                Remove-ItemProperty -Path $mk -Name 'LogDir' -ErrorAction SilentlyContinue
                $left = @((Get-Item -Path $mk -ErrorAction SilentlyContinue).Property)
                if ($left.Count -eq 0) { Remove-Item -Path $mk -Force -ErrorAction SilentlyContinue }
            }
        }
        Remove-ItemProperty -Path $RegKey -Name 'LogDirModulesPreLogvol' -ErrorAction SilentlyContinue
    }
    if ($null -ne $savedFlush) {
        if ([int]$savedFlush -lt 0) { Remove-ItemProperty -Path $RegKey -Name 'LogSafeFlush' -ErrorAction SilentlyContinue }
        else { Set-ItemProperty -Path $RegKey -Name 'LogSafeFlush' -Value ([int]$savedFlush) -Type DWord }
        Remove-ItemProperty -Path $RegKey -Name 'LogSafeFlushPreLogvol' -ErrorAction SilentlyContinue
    }
    $mode = 'registry'
    # junction mode leaves a '<LogDir>.pre-logvol' behind; queue the swap back for the next boot
    if ($cur -and (Test-Path -LiteralPath ($cur + '.pre-logvol'))) {
        $mode = 'junction'
        $sm = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'
        $pend = @((Get-ItemProperty -Path $sm -Name PendingFileRenameOperations -ErrorAction SilentlyContinue).PendingFileRenameOperations)
        $pend += @(('\??\' + $cur), '', ('\??\' + $cur + '.pre-logvol'), ('\??\' + $cur))
        Set-ItemProperty -Path $sm -Name PendingFileRenameOperations -Value ([string[]]$pend) -Type MultiString
    }
    Write-Output ("LOGVOL-BIND restored mode=" + $mode + " logdir=" + (B64 ([string](Get-RegValue 'LogDir'))))
    exit 0
}

if (-not $Id) { Fail 'no_id' }
if ($Id -notmatch '^[A-Za-z0-9._-]+$') { Fail 'bad_id' }
$drive = Find-LogVol
if (-not $drive) { Fail ('no_volume_labelled_' + $Label + '_with_LOGVOL.TAG') }
# Found by label; now make that label resolve to a letter that does not move, and redirect THERE.
$found = $drive
$drive = Pin-LogVol $drive
$pinned = if ($drive -eq $found) { 'same' } else { 'pinned' }
$old = [string](Get-RegValue 'LogDir')
if (-not $old) { $old = 'Q:\Qubes Logs' }
$new = Join-Path $drive ('qwt-logs\' + $Id)
New-Item -ItemType Directory -Path $new -Force | Out-Null

# SAFE FLUSH AT THE ROOT - durability layer L1 (the library header). Saved once; -1 means "was unset".
if ($null -eq (Get-RegValue 'LogSafeFlushPreLogvol')) {
    $prevFlush = Get-RegValue 'LogSafeFlush'
    if ($null -eq $prevFlush) { $prevFlush = -1 }
    Set-ItemProperty -Path $RegKey -Name 'LogSafeFlushPreLogvol' -Value ([int]$prevFlush) -Type DWord
}
Set-ItemProperty -Path $RegKey -Name 'LogSafeFlush' -Value 1 -Type DWord

$copied = 0
if (-not $NoCopy -and (Test-Path -LiteralPath $old)) {
    # robocopy: /E every subdir, /R:0 /W:0 never retry (an open-for-write file that refuses still
    # returns), /NP /NFL /NDL /NJH quiet; its exit code is a bitmask (<8 = no failure) - not $?.
    & robocopy.exe $old $new /E /R:0 /W:0 /NP /NFL /NDL /NJH /NJS | Out-Null
    $copied = @(Get-ChildItem -LiteralPath $new -Recurse -File -ErrorAction SilentlyContinue).Count
}

# THE PER-MODULE KEY IS THE DETERMINISTIC OVERRIDE, AND THE ROOT VALUE IS A RACE WE LOSE.
# MEASURED 2026-10-19 on win11de-tup, one guest, one boot, guest-local stamps:
#   05:00:56  this script binds the ROOT LogDir to Z:\qwt-logs\win11de-tup (copied=83)
#   05:00:58  28 qrexec-wrapper logs land ON THE STICK - the volume is mounted and writable
#   05:01:48  last stick write
#   05:02:00  the INSTALLER logs 'seeded gui-agent registry defaults (... LogDir)'
#   05:02:05  wrapper logs land in Q:\Qubes Logs again, and never on the stick after that
# A direct read taken 2026-10-19 confirmed it: LogDir = 'Q:\Qubes Logs', no per-module key, and
# Z:\qwt-logs\win11de-tup holds no wrapper logs at all. Jev: logdir_was_rewritten established
# 0.96, the volume itself exonerated 0.76, and the mechanism this harness used to blame - a
# removable volume enumerating too late - refuted 0.96.
#
# WHY NOT "BIND AFTER THE INSTALLER'S LAST SEED": that is an ORDERING RACE, and the owner's rule is
# no races and deterministic paths. `Set-GuiAgentRegistryDefaults` writes the ROOT LogDir with
# `reg add /f` once per stage, twice per install, and it must keep doing so: the MSI has two
# components racing to write LogDir under one condition, so a deterministic pre-seed is what stops
# the winner being arbitrary, and it is also what migrates a legacy root-volume path onto Q:. That
# product behaviour is CORRECT and is not touched here.
#
# WHAT IS DETERMINISTIC INSTEAD: windows-utils reads LogDir MODULE-KEY-FIRST, in code, not by
# timing - log.c:358 `CfgReadString(logName, LOG_CONFIG_PATH_VALUE, ...)` with logName the module
# name, and CfgOpenKey (config.c) opens `Qubes Tools\<module>` and only FALLS BACK to the root.
# The installer writes ONLY the root (grep for a per-module LogDir write in packaging/ and guest/:
# zero hits). So two disjoint keys with one writer each, and a precedence fixed in C. The installer
# can re-seed the root as often as it likes and the modules still read the stick.
# A NORMAL INSTALL IS UNAFFECTED, by construction: no module key exists on a user's guest, so the
# root value governs exactly as it does today. This file is harness-only and never shipped.
#
# NOT COVERED, stated rather than implied: notifhost, etwproxy and the toast bridge do not use
# windows-utils' config - they read the ROOT value through QwtLogDir() (tools/notifhost/qtb_shared.h)
# - so their logs follow the root and return to Q: after the installer's seed. The modules that
# matter for reading a WEDGED guest (gui-agent, gui-watchdog, qrexec-agent, qrexec-wrapper,
# qubesdb-*) are windows-utils modules and are covered.
function Set-ModuleLogDir([string]$mod, [string]$value) {
    $k = Join-Path $RegKey $mod
    if (-not (Test-Path -Path $k)) { New-Item -Path $k -Force | Out-Null }
    Set-ItemProperty -Path $k -Name 'LogDir' -Value $value
}
# THE MODULE LIST COMES FROM WHAT HAS ACTUALLY LOGGED, plus a floor of the core modules so a
# guest that has not written one yet is still covered. Derived from the OLD LogDir's own file
# names, which is the only place that records which modules exist on this guest.
$ModFloor = @('gui-agent','gui-watchdog','qrexec-agent','qrexec-wrapper','qubesdb-daemon','qubesdb-cmd','file-receiver','file-sender','network-setup','advertise-tools','bind-dirs')
$mods = New-Object System.Collections.Generic.HashSet[string]
foreach ($m in $ModFloor) { [void]$mods.Add($m) }
if (Test-Path -LiteralPath $old) {
    foreach ($f in @(Get-ChildItem -LiteralPath $old -File -Filter '*.log' -ErrorAction SilentlyContinue)) {
        $n = $f.Name
        if ($n -match '^(?<mod>.+?)-\d{8}(-\d{6}-\d+)?\.log$') { [void]$mods.Add($Matches['mod']) }
    }
}

if ($Mode -eq 'registry') {
    if ($null -eq (Get-RegValue 'LogDirPreLogvol')) {
        Set-ItemProperty -Path $RegKey -Name 'LogDirPreLogvol' -Value $old
    }
    Set-ItemProperty -Path $RegKey -Name 'LogDir' -Value $new
    # and the deterministic layer: every module that reads module-first
    $modList = @($mods) | Sort-Object
    foreach ($m in $modList) { Set-ModuleLogDir $m $new }
    # record EXACTLY which module keys we touched, so -Restore removes those and nothing else
    Set-ItemProperty -Path $RegKey -Name 'LogDirModulesPreLogvol' -Value ($modList -join ';')
    Write-Output ("LOGVOL-BIND ok mode=registry id=" + $Id + " drive=" + $drive + " found=" + $found + " letter=" + $pinned + " old=" + (B64 $old) + " new=" + (B64 $new) + " copied=" + $copied + " safeflush=1" + " modules=" + $modList.Count)
    exit 0
}

# junction mode: the junction at a sibling name NOW, the swap at the next boot (smss, before services).
$side = $old + '.logvol'
if (Test-Path -LiteralPath $side) { Remove-Item -LiteralPath $side -Force -Recurse:$false -ErrorAction SilentlyContinue }
& cmd.exe /c mklink /J "$side" "$new" | Out-Null
if (-not (Test-Path -LiteralPath $side)) { Fail 'junction_not_created' }
$sm = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager'
$pend = @((Get-ItemProperty -Path $sm -Name PendingFileRenameOperations -ErrorAction SilentlyContinue).PendingFileRenameOperations)
$pend += @(('\??\' + $old), ('\??\' + $old + '.pre-logvol'), ('\??\' + $side), ('\??\' + $old))
Set-ItemProperty -Path $sm -Name PendingFileRenameOperations -Value ([string[]]$pend) -Type MultiString
Write-Output ("LOGVOL-BIND ok mode=junction id=" + $Id + " drive=" + $drive + " old=" + (B64 $old) + " new=" + (B64 $new) + " copied=" + $copied + " safeflush=1 pending=1")
exit 0
