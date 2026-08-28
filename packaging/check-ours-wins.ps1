<#
.SYNOPSIS
    CI guard: every file this repo maintains a source for must ship FROM THIS REPO -
    never silently from the stock QWT 4.2.2 image, and never not at all.

.DESCRIPTION
    Data-driven from packaging/ours-wins.psd1 (the ONE list; see its header for how to
    add a file). Run by release-package.yml on every package build, after make-setup.ps1
    has assembled the qwt-improved-setup tree. Checks, in order:

      1. Mirrors  - every swept rpc source file is in the package, byte-identical.
      2. Files    - every one-off "ours wins" file is in the package, byte-identical.
      3. Orphans  - everything under the package's rpc/ and bin/ overlay dirs is
                    claimed by an entry (nothing unreviewed rides onto the guest).
      4. Binaries - fork-built binaries differ from the stock image copy (byte-equal
                    means our build did not land - the gui-agent.exe tripwire of
                    stage-qwt-repo.ps1, generalized).
      5. DeadEnds - repo copies that must stay stock-identical (they do not ship;
                    editing them silently loses the change).
      6. Sweep    - maintained trees vs the stock image by basename: a file that
                    differs from stock and is shipped by nothing FAILS the build.
                    This detects the incident class with no listing required.
      7. CompiledSources - git diff of the core-agent submodule vs its 4.2.2 base:
                    a source change whose built binary is not staged ships nowhere.
      8. KnownGaps - documented violations WARN loudly; a stale entry (gap no longer
                    manifests) FAILS so the list cannot rot.

    All failures are collected and reported together, then the script throws.
    Comparisons against the stock image are line-ending/BOM tolerant for text files
    (the repo stores LF, a Windows CI checkout materializes CRLF); repo-vs-package
    comparisons are exact bytes (both sides come from the same checkout).

.PARAMETER RepoRoot     Repository root (default: current directory).
.PARAMETER PackageRoot  The assembled qwt-improved-setup tree to verify.
.PARAMETER DataFile     The ours-wins list (default: <RepoRoot>/packaging/ours-wins.psd1).
.PARAMETER StockMsi     Stock QWT MSI to extract as the comparison baseline
                        (default: <RepoRoot>/vendor/qwt-4.2.2/installer.msi). Windows only.
.PARAMETER StockImage   Pre-extracted admin image (msiexec /a TARGETDIR). Overrides
                        StockMsi; required to run on non-Windows.
.PARAMETER MsiImage     Admin extract (msiexec /a) of the BUILT installer.msi. Entries whose
                        package path starts 'msi-image/' resolve against THIS root instead of
                        PackageRoot: they prove our bytes are inside the MSI that actually
                        installs, not merely in the payload tree beside it. Without it those
                        entries cannot be checked, so the guard REFUSES to run rather than
                        report a vacuous pass - a guard that silently skips its own data is
                        worse than no guard (measured 2026-08-28: the entries shipped without
                        this support and every one of them failed as 'NOT SHIPPED AT ALL').
#>
[CmdletBinding()]
param(
    [string]$RepoRoot = '.',
    [Parameter(Mandatory = $true)][string]$PackageRoot,
    [string]$DataFile,
    [string]$StockMsi,
    [string]$StockImage,
    [string]$MsiImage
)

$ErrorActionPreference = 'Stop'

$RepoRoot    = (Resolve-Path -LiteralPath $RepoRoot).Path
$PackageRoot = (Resolve-Path -LiteralPath $PackageRoot).Path
if (-not $DataFile) { $DataFile = Join-Path $RepoRoot 'packaging/ours-wins.psd1' }

$failures = New-Object System.Collections.Generic.List[string]
$warnCount = 0
function Fail([string]$Msg) {
    $script:failures.Add($Msg)
    Write-Host "::error::ours-wins: $($Msg -replace '\r?\n', ' | ')"
}
function Warn([string]$Msg) {
    $script:warnCount++
    Write-Host "::warning::ours-wins: $($Msg -replace '\r?\n', ' | ')"
}
function RepoPath([string]$Rel) { Join-Path $RepoRoot ($Rel -replace '/', [IO.Path]::DirectorySeparatorChar) }
function PkgPath([string]$Rel)  {
    # Two roots. 'msi-image/...' is inside the BUILT MSI (admin extract); everything else is the
    # payload tree. Same data file describes both, because both channels ship to the guest and a
    # file can be right in one and stock in the other.
    if ($Rel -like 'msi-image/*') {
        if (-not $script:MsiImageRoot) { throw "entry '$Rel' needs -MsiImage but none was given" }
        return Join-Path $script:MsiImageRoot (($Rel -replace '^msi-image/', '') -replace '/', [IO.Path]::DirectorySeparatorChar)
    }
    Join-Path $PackageRoot ($Rel -replace '/', [IO.Path]::DirectorySeparatorChar)
}
function Sha([string]$Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash }
function IsTextName([string]$Leaf) {
    ($Leaf -match '\.(ps1|psm1|psd1|bat|cmd|txt|cs|reg|inf|ini|xml|json|config|md)$') -or ($Leaf -like 'qubes.*')
}
# Ours-vs-stock content equality, tolerant of CRLF/LF and BOM differences for text files.
function SameAsStock([string]$OursPath, [string]$StockPath) {
    if ((Sha $OursPath) -eq (Sha $StockPath)) { return $true }
    if (-not (IsTextName (Split-Path $OursPath -Leaf))) { return $false }
    $a = ([IO.File]::ReadAllText($OursPath))  -replace "`r`n", "`n" -replace "`r", "`n"
    $b = ([IO.File]::ReadAllText($StockPath)) -replace "`r`n", "`n" -replace "`r", "`n"
    return ($a -ceq $b)
}

# ------------------------------------------------------------------ load the data file
$d = Import-PowerShellDataFile -LiteralPath $DataFile
foreach ($section in 'Mirrors', 'Files', 'Binaries', 'DeadEnds', 'SweepTrees', 'CompiledSources', 'KnownGaps') {
    if ($null -eq $d[$section]) { throw "ours-wins.psd1 has no '$section' section - refusing to run a gutted guard" }
}
if (@($d.Mirrors).Count -lt 1 -or @($d.SweepTrees).Count -lt 1 -or @($d.Binaries).Count -lt 2) {
    throw 'ours-wins.psd1 lists are implausibly small - a guard whose data is empty cannot fail, so it must not pass'
}

# ------------------------------------------------------- stock admin image (baseline)
if (-not $StockImage) {
    if ($env:OS -ne 'Windows_NT') { throw 'no -StockImage given and msiexec is unavailable off Windows - pass a pre-extracted admin image' }
    if (-not $StockMsi) { $StockMsi = Join-Path $RepoRoot 'vendor/qwt-4.2.2/installer.msi' }
    if (-not (Test-Path -LiteralPath $StockMsi)) { throw "stock MSI not found: $StockMsi" }
    $StockImage = Join-Path ([IO.Path]::GetTempPath()) ('qwt-stock-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    Write-Host "extracting stock admin image: $StockMsi -> $StockImage"
    $p = Start-Process msiexec.exe -ArgumentList "/a `"$((Resolve-Path -LiteralPath $StockMsi).Path)`" /qn TARGETDIR=`"$StockImage`"" -Wait -PassThru
    if ($p.ExitCode -ne 0) { throw "msiexec /a failed: $($p.ExitCode)" }
}
$StockImage = (Resolve-Path -LiteralPath $StockImage).Path
$stockFiles = @(Get-ChildItem -LiteralPath $StockImage -Recurse -File)
if ($stockFiles.Count -lt 60) { throw "stock image implausibly small ($($stockFiles.Count) files) - a guard without its baseline is worthless" }
$stockIndex = @{}   # basename -> [string[]] full paths (hashtable keys: case-insensitive)
foreach ($f in $stockFiles) {
    if (-not $stockIndex.ContainsKey($f.Name)) { $stockIndex[$f.Name] = @() }
    $stockIndex[$f.Name] += $f.FullName
}
Write-Host "stock baseline: $($stockFiles.Count) files, $($stockIndex.Count) distinct basenames"

# ---------------------------------------------------- built-MSI admin image (second root)
# Only required if the data file actually uses it. If it does and we have no image, STOP: those
# entries would otherwise all "fail" for the wrong reason, or - worse, if anyone made them
# non-fatal - pass without being checked.
$script:MsiImageRoot = $null
$needsImage = @()
foreach ($sec in 'Mirrors', 'Files', 'Binaries') {
    foreach ($e in @($d[$sec])) {
        foreach ($v in @($e.PackageDir, $e.Package)) { if ($v -like 'msi-image/*') { $needsImage += $v } }
    }
}
if ($needsImage.Count) {
    if (-not $MsiImage) {
        throw ("ours-wins.psd1 has $($needsImage.Count) 'msi-image/' entries but -MsiImage was not given. " +
               "Extract the BUILT installer.msi with 'msiexec /a <msi> /qn TARGETDIR=<dir>' and pass it, " +
               "or remove those entries - they cannot be checked against the payload tree.")
    }
    if (-not (Test-Path -LiteralPath $MsiImage)) { throw "-MsiImage path does not exist: $MsiImage" }
    $script:MsiImageRoot = (Resolve-Path -LiteralPath $MsiImage).Path
    $imgFiles = @(Get-ChildItem -LiteralPath $script:MsiImageRoot -Recurse -File)
    if ($imgFiles.Count -lt 60) {
        throw "built-MSI image implausibly small ($($imgFiles.Count) files) at $script:MsiImageRoot - extraction failed, and a guard without its image cannot fail"
    }
    Write-Host "built-MSI image: $($imgFiles.Count) files at $script:MsiImageRoot"
}

# Repo-relative source paths ('/'-separated) that SHIP - covered, so exempt from the
# stock-shadow sweep. Package-relative paths claimed by an entry - for the orphan check.
$covered   = @{}   # source rel -> package rel (case-insensitive keys)
$claimed   = @{}   # package rel -> $true
$gapMatched = @{}  # KnownGaps 'Missing' -> $true once the gap actually manifested

# --------------------------------------------------------------------- 1. Mirrors
$mirrorTotal = 0
foreach ($m in @($d.Mirrors)) {
    $srcDir = RepoPath $m.SourceDir
    if (-not (Test-Path -LiteralPath $srcDir)) {
        Fail "Mirrors: source dir missing: $($m.SourceDir) (submodule not checked out?)"
        continue
    }
    $take = @(Get-ChildItem -LiteralPath $srcDir -File | Where-Object {
        $n = $_.Name
        ($n -like $m.Include) -and -not (@($m.Exclude) | Where-Object { $n -like $_ })
    })
    if ($take.Count -eq 0) {
        Fail "Mirrors: rule '$($m.SourceDir)' include='$($m.Include)' matched NO files - stale rule or stale submodule"
        continue
    }
    foreach ($f in $take) {
        $mirrorTotal++
        $srcRel = "$($m.SourceDir)/$($f.Name)"
        $pkgRel = "$($m.PackageDir)/$($f.Name)"
        $covered[$srcRel] = $pkgRel
        $claimed[$pkgRel] = $true
        $pkg = PkgPath $pkgRel
        if (-not (Test-Path -LiteralPath $pkg)) {
            Fail "NOT SHIPPED AT ALL: $srcRel is maintained here but absent from the package ($pkgRel) - the guest would run the stock copy. make-setup.ps1's sweep and ours-wins.psd1 disagree."
        } elseif ((Sha $f.FullName) -ne (Sha $pkg)) {
            Fail "STALE COPY SHIPPED: package $pkgRel differs from repo $srcRel - the package was staged from something other than this checkout"
        }
    }
}
if ($mirrorTotal -lt 15) {
    Fail "Mirrors verified only $mirrorTotal files (expected >= 15: ~6 handler scripts + ~13 service definitions) - sweep or rules broken"
}
Write-Host "1. Mirrors: $mirrorTotal files verified"

# ----------------------------------------------------------------------- 2. Files
foreach ($e in @($d.Files)) {
    $src = RepoPath $e.Source
    $covered[$e.Source] = $e.Package
    $claimed[$e.Package] = $true
    if (-not (Test-Path -LiteralPath $src)) {
        Fail "Files: listed source vanished from the repo: $($e.Source) - remove or fix the ours-wins.psd1 entry"
        continue
    }
    $pkg = PkgPath $e.Package
    if (-not (Test-Path -LiteralPath $pkg)) {
        Fail "NOT SHIPPED AT ALL: $($e.Source) must be staged at $($e.Package) but is absent - the guest would run the stock copy"
    } elseif ((Sha $src) -ne (Sha $pkg)) {
        Fail "STALE COPY SHIPPED: package $($e.Package) differs from repo $($e.Source)"
    }
}
Write-Host "2. Files: $(@($d.Files).Count) entries verified"

# --------------------------------------------------------------------- 3. Orphans
# Everything under the guest-bound overlay dirs must be claimed by an entry; an
# unclaimed file would land on the guest with no repo source answering for it.
# Binaries entries claim their package paths too - claim them BEFORE scanning, or a
# legitimately staged bin\qrexec-wrapper.exe would be flagged the day it starts shipping.
foreach ($b in @($d.Binaries)) { $claimed[$b.Package] = $true }
foreach ($overlayDir in 'rpc', 'bin') {
    $od = PkgPath $overlayDir
    if (-not (Test-Path -LiteralPath $od)) { continue }
    foreach ($f in @(Get-ChildItem -LiteralPath $od -Recurse -File)) {
        $rel = $f.FullName.Substring($PackageRoot.Length).TrimStart('\', '/') -replace '\\', '/'
        if (-not $claimed.ContainsKey($rel)) {
            Fail "ORPHAN IN THE OVERLAY: package $rel would be placed onto the guest but no ours-wins.psd1 entry claims it - add a Mirrors/Files/Binaries entry or stop staging it"
        }
    }
}
Write-Host '3. Orphans: overlay dirs (rpc/, bin/) fully claimed'

# -------------------------------------------------------------------- 4. Binaries
foreach ($b in @($d.Binaries)) {
    $claimed[$b.Package] = $true
    $pkg = PkgPath $b.Package
    if (-not (Test-Path -LiteralPath $pkg)) {
        if ($b.Required) {
            Fail "REQUIRED BINARY MISSING from the package: $($b.Package)"
        } else {
            $gap = @($d.KnownGaps) | Where-Object { $_.Missing -eq $b.Package } | Select-Object -First 1
            if ($gap) {
                $gapMatched[$gap.Missing] = $true
                Warn "KNOWN GAP: $($b.Package) absent from the package - $($gap.Reason)"
            } else {
                Fail "optional binary $($b.Package) is absent and no KnownGaps entry documents why - document it or stage it"
            }
        }
        continue
    }
    $stockHits = @($stockIndex[$b.Stock] | Where-Object { $_ })
    if ($stockHits.Count -eq 0) {
        Fail "Binaries: stock counterpart '$($b.Stock)' not in the admin image - bad entry for $($b.Package)?"
        continue
    }
    $ours = Sha $pkg
    $same = @($stockHits | Where-Object { (Sha $_) -eq $ours })
    if ($same.Count -gt 0) {
        Fail "OUR BUILD DID NOT LAND: package $($b.Package) is byte-identical to the stock image's $($b.Stock) - the fork binary was not staged (gui-agent-tripwire class)"
    }
}
Write-Host "4. Binaries: $(@($d.Binaries).Count) differ-from-stock entries checked"

# -------------------------------------------------------------------- 5. DeadEnds
$deadEndSources = @{}
foreach ($e in @($d.DeadEnds)) {
    $deadEndSources[$e.Source] = $true
    $src = RepoPath $e.Source
    if (-not (Test-Path -LiteralPath $src)) {
        Fail "DeadEnds: listed source vanished: $($e.Source) - remove or fix the entry"
        continue
    }
    $leaf = Split-Path $src -Leaf
    $stockHits = @($stockIndex[$leaf] | Where-Object { $_ })
    if ($stockHits.Count -eq 0) {
        Fail "DeadEnds: no stock counterpart for $($e.Source) ('$leaf' not in the admin image) - the entry makes no sense"
        continue
    }
    $identical = @($stockHits | Where-Object { SameAsStock $src $_ })
    if ($identical.Count -eq 0) {
        Fail "DEAD-END COPY EDITED: $($e.Source) diverged from the stock image but ships NOWHERE - the change is silently lost. $($e.Reason)"
    }
}
Write-Host "5. DeadEnds: $(@($d.DeadEnds).Count) stock-identical pins checked"

# ----------------------------------------------------------------------- 6. Sweep
$sweepScanned = 0
$sweepExclude = @{}
foreach ($x in @($d.SweepExclude)) { $sweepExclude[$x] = $true }
foreach ($tree in @($d.SweepTrees)) {
    $dir = RepoPath $tree
    if (-not (Test-Path -LiteralPath $dir)) {
        Fail "SweepTrees: tree missing: $tree"
        continue
    }
    foreach ($f in @(Get-ChildItem -LiteralPath $dir -Recurse -File)) {
        $rel = $f.FullName.Substring($RepoRoot.Length).TrimStart('\', '/') -replace '\\', '/'
        $sweepScanned++
        if ($covered.ContainsKey($rel) -or $deadEndSources.ContainsKey($rel) -or $sweepExclude.ContainsKey($rel)) { continue }
        $stockHits = @($stockIndex[$f.Name] | Where-Object { $_ })
        if ($stockHits.Count -eq 0) { continue }   # no stock counterpart: nothing to shadow
        $identical = @($stockHits | Where-Object { SameAsStock $f.FullName $_ })
        if ($identical.Count -gt 0) { continue }   # same content as stock: an edit later will trip this
        $hint = ''
        $twin = $covered.Keys | Where-Object { (Split-Path $_ -Leaf) -ieq $f.Name } | Select-Object -First 1
        if ($twin) { $hint = " NOTE: $twin already ships (-> $($covered[$twin])) - if that is the maintained copy, apply your change THERE." }
        Fail ("MAINTAINED COPY SHADOWED BY STOCK: $rel differs from the stock image's $($f.Name) but nothing ships it - " +
              "every installed guest keeps the STOCK version (the 2026-08-25 incident class). " +
              "Ship it (Mirrors/Files in packaging/ours-wins.psd1 + make-setup staging), or revert the edit.$hint")
    }
}
if ($sweepScanned -eq 0) { Fail 'Sweep scanned 0 files - trees empty or misconfigured; a sweep that sees nothing proves nothing' }
Write-Host "6. Sweep: $sweepScanned files compared against the stock baseline"

# ------------------------------------------------------------ 7. CompiledSources
$cs = $d.CompiledSources
$sub = RepoPath $cs.Submodule
& git -C $sub cat-file -e "$($cs.UpstreamBase)^{commit}" 2>$null
if ($LASTEXITCODE -ne 0) {
    Fail "CompiledSources: upstream base $($cs.UpstreamBase) not present in the $($cs.Submodule) clone (shallow checkout? dubious-ownership?) - cannot verify; missing data FAILS"
} else {
    $diff = @(& git -C $sub diff --name-only "$($cs.UpstreamBase)" HEAD -- $cs.Root)
    if ($LASTEXITCODE -ne 0) {
        Fail "CompiledSources: git diff failed in $($cs.Submodule)"
    } else {
        foreach ($path in $diff) {
            $srcRel = "$($cs.Submodule)/$path"
            # Top-level files of MirrorDir ship via Mirrors (verified in check 1);
            # dead ends have their own targeted check (5).
            if ($path -match ('^' + [regex]::Escape($cs.MirrorDir) + '/[^/]+$')) {
                if ($covered.ContainsKey($srcRel) -or $deadEndSources.ContainsKey($srcRel)) { continue }
                Fail "CompiledSources: $srcRel changed vs the 4.2.2 base but is neither shipped (Mirrors/Files) nor a documented DeadEnd"
                continue
            }
            $mapped = $false
            foreach ($dirKey in @($cs.DirBinaries.Keys)) {
                if (($path -eq $dirKey) -or ($path -like "$dirKey/*")) {
                    $mapped = $true
                    $bin = $cs.DirBinaries[$dirKey]
                    if (Test-Path -LiteralPath (PkgPath $bin)) {
                        if (-not (@($d.Binaries) | Where-Object { $_.Package -eq $bin })) {
                            Fail "CompiledSources: $bin is staged but has no Binaries entry - add one so the differ-from-stock tripwire covers it"
                        }
                        # present + listed: check 4 already proved it differs from stock
                    } else {
                        $gap = @($d.KnownGaps) | Where-Object { $_.Missing -eq $bin } | Select-Object -First 1
                        if ($gap) {
                            $gapMatched[$gap.Missing] = $true
                            Warn "KNOWN GAP: $srcRel carries changes vs the 4.2.2 base but $bin is not in the package - the change ships NOWHERE. $($gap.Reason)"
                        } else {
                            Fail "COMPILED FIX SHIPS NOWHERE: $srcRel changed vs the 4.2.2 base but the package has no $bin (the guest keeps the stock binary, CI green - the qrexec-wrapper incident class). Stage the built binary or add a KnownGaps entry."
                        }
                    }
                    break
                }
            }
            if (-not $mapped) {
                Fail "COMPILED FIX SHIPS NOWHERE: $srcRel changed vs the 4.2.2 base but no DirBinaries mapping covers it - the binary it compiles into ships from the stock image. Add a build+staging channel and a DirBinaries mapping, or revert."
            }
        }
        Write-Host "7. CompiledSources: $($diff.Count) changed path(s) vs $($cs.UpstreamBase.Substring(0,12)) classified"
    }
}

# ------------------------------------------------------------------ 8. KnownGaps
foreach ($gap in @($d.KnownGaps)) {
    if (-not $gapMatched.ContainsKey($gap.Missing)) {
        Fail "STALE KnownGaps entry '$($gap.Missing)': the gap no longer manifests - delete the entry (and set Required=`$true on the matching Binaries entry) so the guard enforces it from now on"
    }
}
Write-Host "8. KnownGaps: $(@($d.KnownGaps).Count) entries, all current"

# ---------------------------------------------------------------------- verdict
Write-Host ''
if ($failures.Count) {
    Write-Host "ours-wins guard: $($failures.Count) FAILURE(S), $warnCount warning(s):"
    $failures | ForEach-Object { Write-Host "  FAIL: $_" }
    throw "ours-wins guard failed with $($failures.Count) violation(s) - a file this repo maintains would ship from the stock image or not at all"
}
Write-Host "ours-wins guard: PASS ($warnCount known-gap warning(s))"
