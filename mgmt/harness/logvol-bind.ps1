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
    [switch]$Clear,
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
    # NO LETTER IS NOT NO VOLUME. Win32_LogicalDisk lists only volumes that HAVE a drive letter, so
    # a DIAG volume Windows mounted without one is invisible above and this function returned
    # $null - which the caller reports as `no_volume_labelled_DIAG_with_LOGVOL.TAG`, i.e. "the
    # volume is not there" about a volume that IS attached and readable from the host the whole
    # time. Measured 2026-10-20, run 39225775322 WIN10-clean: prime-run attached the stick at
    # 12:42:05 and read it from this qube at 12:50:05, and the binder said no volume at 12:50:16.
    # A fresh clean install is exactly where an unlettered removable volume is ordinary.
    # Get-Volume DOES see unlettered volumes. Give ours a letter - the tag can only be read through
    # a path - and re-check. A volume that still has no tag after that is not ours and is left alone.
    foreach ($uv in @(Get-Volume -ErrorAction SilentlyContinue |
                      Where-Object { $_.FileSystemLabel -eq $Label -and -not $_.DriveLetter })) {
        foreach ($want in @('Z','Y','X','W')) {
            if (Get-CimInstance Win32_Volume -Filter ("DriveLetter='" + $want + ":'") -ErrorAction SilentlyContinue) { continue }
            try {
                $uv | Get-Partition -ErrorAction Stop | Set-Partition -NewDriveLetter $want -ErrorAction Stop
            } catch { continue }
            Start-Sleep -Milliseconds 300
            $tag = Join-Path ($want + ':') 'LOGVOL.TAG'
            if (Test-Path -LiteralPath $tag) {
                Write-Output ("LOGVOL-BIND note=lettered_an_unlettered_volume label=" + $Label + " letter=" + $want + ":")
                return ($want + ':')
            }
            break   # we gave it a letter and it is not ours; do not keep consuming letters
        }
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
    # A RANGE OF HIGH LETTERS, AND A REFUSAL - NOT "KEEP THE LOW ONE".
    # This used to try Z: alone and, if Z: was occupied, RETURN THE CURRENT LETTER - which on a
    # fresh boot is whatever the emulated stick grabbed early, D: or E: (run 8 shows both:
    # `found=E:` on the clean cell, `found=D:` on the next). The bind then wrote that letter into
    # LogDir, and those are exactly the letters a Xen PV volume claims once xenvbd attaches: the log
    # stick is an EMULATED usb-storage device present from power-on, while Q: only appears when the
    # PV disk driver attaches, and Windows hands out letters as volumes arrive. So the pre-PV window
    # could leave LogDir naming a letter that later belongs to something else - and a module whose
    # LogDir is unreachable at LogInit gets NO log file and says nothing (windows-utils LogStart:
    # CreateFile fails and the process logs nowhere). Jev graded that hole 0.44 and the silent
    # no-file consequence 0.78.
    # High letters are never claimed by the PV volumes this product uses (C: system, Q: private), so
    # the pin walks DOWN from Z: and refuses if it cannot get one. A refusal is loud and the cell
    # fails on the instrument; recording a letter that may move is the failure that hides.
    $curLetter = $cur.TrimEnd(':')
    foreach ($want in @('Z','Y','X','W')) {
        if ($cur -eq ($want + ':')) { return $cur }
        # NEVER TAKE A LETTER IN USE: a volume this script knows nothing about is not ours to move.
        $taken = Get-CimInstance Win32_Volume -Filter ("DriveLetter='" + $want + ":'") -ErrorAction SilentlyContinue
        if ($taken) { continue }
        $pinned = Pin-LogVolTo $curLetter $want
        if ($pinned) { return ($want + ':') }
    }
    Fail ('logvol_letter_unpinnable: none of Z:,Y:,X:,W: could be assigned to the log volume (it is at ' + $cur + '). REFUSING rather than recording a low letter in LogDir: the stick enumerates before the PV disk driver attaches, so a low letter can later belong to a PV volume, and a module whose LogDir is unreachable at LogInit logs NOWHERE and says nothing.')
}

# The actual assignment, split out so the loop above reads as the policy it is.
function Pin-LogVolTo([string]$curLetter, [string]$want) {

    try {
        $p = Get-Partition -DriveLetter $curLetter -ErrorAction Stop
        $p | Set-Partition -NewDriveLetter $want -ErrorAction Stop
    } catch {
        # No Storage module, or it refused: fall back to diskpart, which every Windows has.
        $vol = Get-CimInstance Win32_Volume -Filter ("DriveLetter='" + $curLetter + ":'") -ErrorAction SilentlyContinue
        if (-not $vol) { return $false }
        $script = Join-Path $env:TEMP 'logvol-pin.txt'
        @("select volume $curLetter", "assign letter=$want", 'exit') | Set-Content -LiteralPath $script -Encoding ASCII
        & diskpart /s $script 2>&1 | Out-Null
        Remove-Item -LiteralPath $script -Force -ErrorAction SilentlyContinue
    }

    # VERIFY, never assume: re-resolve by label and report what actually happened.
    Start-Sleep -Milliseconds 900
    $after = Find-LogVol
    return ($after -eq ($want + ':'))
}

function Get-RegValue([string]$name) {
    $p = Get-ItemProperty -Path $RegKey -Name $name -ErrorAction SilentlyContinue
    if ($null -eq $p) { return $null }
    return $p.$name
}

if (-not (Test-Path -Path $RegKey)) { Fail 'no_qubes_tools_key' }

# -Clear: REMOVE the LogDir value entirely, so the product falls to its OWN default.
#
# THE MEASURED REASON THIS EXISTS. An AppVM inherits its registry from the template, whose root is
# the churn subject's 'installed' park, so it boots believing LogDir=Z:\qwt-logs\<churn>. The
# receipts of run 39476792836 say `found=D: letter=pinned` on all six appvm boots: at boot Windows
# letters the volume D:, and the bind pins it to Z: AFTERWARDS. So when the agent family starts, the
# inherited value names a letter that does not exist yet, log.c:256 CreateDirectory fails,
# :258-264 calls LogStart(NULL) and jumps to the fallback at :289 - stderr only, NO FILE ANYWHERE.
# Both appvm cells of that run produced zero agent-family logs on all three boots.
#
# No registry path naming a LETTER can be valid at an AppVM's agent start, and a volume GUID path
# (probed working on a guest 2026-10-21) cannot help either, because the INHERITED value would name
# the churn volume's GUID. The one path that is valid is the product's own default:
# log.c:236-253 with log.h:59 build "<system drive>\Qubes Logs" and CREATE it when LogInit is given
# nothing - no letter, no inheritance. It is reached only when CfgReadString FAILS, i.e. when there
# is NO value. Hence: remove it, do not rewrite it.
#
# RESTORING instead was tried and disproved: the restored value is Q:\Qubes Logs, on the PRIVATE
# volume, which checkpoint.sh clones into the template and an AppVM's private is seeded from - and
# it is NOT empty at park time (WIN10-clean's receipt: copied=21 modules=15), so the AppVM would
# inherit a log directory pre-filled with another guest's logs. C:\Qubes Logs is unused on these
# guests: the string appears in none of that run's eight captures.
if ($Clear) {
    $cur = Get-RegValue 'LogDir'
    $mods = Get-RegValue 'LogDirModulesPreLogvol'
    $removed = @()
    # the per-module keys FIRST: CfgReadString reads the module key before the root, so a value
    # left there would still win and the root removal would look like it had worked.
    foreach ($m in @((Get-ChildItem -Path $RegKey -ErrorAction SilentlyContinue) | ForEach-Object { $_.PSChildName })) {
        $mk = Join-Path $RegKey $m
        if ($null -ne (Get-ItemProperty -Path $mk -Name 'LogDir' -ErrorAction SilentlyContinue)) {
            Remove-ItemProperty -Path $mk -Name 'LogDir' -ErrorAction SilentlyContinue
            $removed += $m
        }
    }
    Remove-ItemProperty -Path $RegKey -Name 'LogDir' -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path $RegKey -Name 'LogDirPreLogvol' -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path $RegKey -Name 'LogDirModulesPreLogvol' -ErrorAction SilentlyContinue
    # ASSERT THE ABSENCE, do not report the attempt. A Remove-ItemProperty that silently did nothing
    # would otherwise be reported as success - the defect class this whole area has been full of.
    $still = @()
    if ($null -ne (Get-ItemProperty -Path $RegKey -Name 'LogDir' -ErrorAction SilentlyContinue)) { $still += '(root)' }
    foreach ($m in @((Get-ChildItem -Path $RegKey -ErrorAction SilentlyContinue) | ForEach-Object { $_.PSChildName })) {
        if ($null -ne (Get-ItemProperty -Path (Join-Path $RegKey $m) -Name 'LogDir' -ErrorAction SilentlyContinue)) { $still += $m }
    }
    if ($still.Count -gt 0) {
        Fail ('logdir_still_set_after_clear keys=' + ($still -join ','))
    }
    Write-Output ('LOGVOL-BIND cleared was=' + (B64 ([string]$cur)) + ' modules=' + (($removed -join ',')) + ' remaining=0')
    exit 0
}

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
