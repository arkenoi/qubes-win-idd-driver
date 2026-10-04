#!/usr/bin/env bash
# wix-serialstart-patch-selftest.sh - prove packaging/patch-installer-serialize-services.ps1 BEFORE it runs in
# qwt-full.yml against the freshly cloned installer source (docs/ADR-boot.md 1: the MSI's StartServices action is
# conditioned on QWTNG_SERIALSTART so Install-QwtImproved.ps1 can start QWT's services one at a time).
#
# The fixture is the pinned Package.wxs (QubesOS/qubes-installer-qubes-os-windows-tools 14c189e4, vs2022/installer/
# Package.wxs) reduced to the elements the patch anchors on and the neighbours it must leave alone, with the stock
# UTF-8 BOM and CRLF line endings. Runs on this dev qube with the linux pwsh; no rig, no guest, no WiX.
#
#   no env                 full matrix: the clean application must PASS (exactly the two insertions, in place, BOM and
#                          CRLF kept, a second application refused), and every defect knob must make this test FAIL.
#   WIXPATCH_DEFECT=<knob> run ONLY that knob and exit non-zero (the required outcome). Knobs, each a `# GUARD:<name>`
#                          line of the SCRIPT replaced in a temporary copy (the shipped script is never modified):
#       wixcond    the inserted StartServices element carries NO condition -> the MSI would start the services anyway;
#                  the script's own post-check must throw
#       wixsecure  the property is declared without Secure="yes" -> the command-line value would not reach the execute
#                  sequence of a per-machine install; the post-check must throw
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PWSH="${PWSH:-/home/user/pwsh/pwsh}"
[ -x "$PWSH" ] || PWSH=/home/user/bin/pwsh7/pwsh
SCRIPT="$ROOT/packaging/patch-installer-serialize-services.ps1"
T=$(mktemp -d "${TMPDIR:-/tmp}/wixpatch-selftest-XXXXXX"); trap 'rm -rf "$T"' EXIT
say() { printf '%s\n' "$*"; }
if [ ! -x "$PWSH" ]; then say "FAIL  pwsh not found at $PWSH - nothing ran"; exit 2; fi
[ -f "$SCRIPT" ] || { say "FAIL  $SCRIPT missing"; exit 2; }

# --- the fixture: the pinned Package.wxs, reduced; BOM + CRLF like the real file --------------------------------------
write_fixture() {
    printf '\xef\xbb\xbf' > "$1"
    sed 's/$/\r/' >> "$1" <<'WXS'
<Wix xmlns="http://wixtoolset.org/schemas/v4/wxs"
  xmlns:ui="http://wixtoolset.org/schemas/v4/wxs/ui"
  xmlns:bal="http://wixtoolset.org/schemas/v4/wxs/bal"
  xmlns:util="http://wixtoolset.org/schemas/v4/wxs/util">
  <?include version.wxi ?>

  <Package
    Name="Qubes Windows Tools v$(QWTVersion)"
    Manufacturer="Invisible Things Lab"
    Version="$(QWTVersion)"
    ProductCode="*"
    UpgradeCode="{14BCB82F-3C4B-4C77-8E00-20BAEBC61354}"
    Scope="perMachine">
    <MajorUpgrade DowngradeErrorMessage="!(loc.DowngradeError)" />
    <MediaTemplate EmbedCab="yes" />

    <Icon Id="icon.ico" SourceFile="..\..\qubes.ico" />
    <Property Id="DISABLEADVTSHORTCUTS" Value="1" />
    <Property Id="ARPPRODUCTICON" Value="icon.ico" />

    <Binary Id="InstallHelper" SourceFile="..\x64\$(var.Configuration)\install-helper\install-helper.exe" />

    <CustomAction
      Id="RunInstallHelper"
      BinaryRef="InstallHelper"
      ExeCommand=""
      Execute="deferred"
      Impersonate="no"
      Return="asyncNoWait" />

    <SetProperty
      Id="PrepareAutologon"
      Value='"[BIN_DIR]autologon.exe"'
      Sequence="execute"
      Before="PrepareAutologon" />

    <CustomAction
      Id="PrepareAutologon"
      BinaryRef="Wix4UtilCA_X64"
      DllEntry="WixQuietExec"
      Execute="deferred"
      Impersonate="no"
      Return="ignore" />

    <InstallExecuteSequence>
      <Custom Action="RunInstallHelper" Before="InstallFiles" />
      <!-- Run only if Autologon feature is being installed and not being uninstalled -->
      <Custom Action="PrepareAutologon" After="InstallFiles" Condition="(&amp;Autologon=3) AND NOT (!Autologon=3)" />
      <ScheduleReboot After="InstallFinalize" />
    </InstallExecuteSequence>

    <Feature
      Id="Core"
      AllowAbsent="yes"
      AllowAdvertise="no"
      Title="!(loc.FeatureCoreTitle)"
      Description="!(loc.FeatureCoreDescription)">
      <ComponentGroupRef Id="CoreComponents" />
    </Feature>
  </Package>
</Wix>
WXS
}

run_script() { # $1 script, $2 wxs -> rc; output in $T/out.txt
    "$PWSH" -NoProfile -File "$1" -WxsPath "$2" > "$T/out.txt" 2>&1
}

# --- one defect knob: patch a COPY of the script at its GUARD line, apply it, require a failure -----------------------
if [ -n "${WIXPATCH_DEFECT:-}" ]; then
    case "$WIXPATCH_DEFECT" in
        wixcond)   repl='$startServicesLine = '"'"'      <StartServices />'"'"'   # DEFECT: no condition - the MSI starts the services anyway' ;;
        wixsecure) repl='    '"'"'    <Property Id="QWTNG_SERIALSTART" />'"'"'   # DEFECT: not secure - the value does not reach the execute sequence' ;;
        *) say "FAIL  unknown WIXPATCH_DEFECT='$WIXPATCH_DEFECT' (wixcond|wixsecure)"; exit 2 ;;
    esac
    hits=$(grep -c "# GUARD:$WIXPATCH_DEFECT\$" "$SCRIPT")
    if [ "$hits" -ne 1 ]; then say "FAIL  knob $WIXPATCH_DEFECT: expected exactly 1 '# GUARD:$WIXPATCH_DEFECT' line in the script, found $hits"; exit 2; fi
    python3 - "$SCRIPT" "$T/script.ps1" "$WIXPATCH_DEFECT" "$repl" <<'PY'
import sys
src, dst, knob, repl = sys.argv[1:5]
out = [repl if line.endswith('# GUARD:' + knob) else line for line in open(src, encoding='utf-8').read().split('\n')]
open(dst, 'w', encoding='utf-8').write('\n'.join(out))
PY
    write_fixture "$T/Package.wxs"
    if run_script "$T/script.ps1" "$T/Package.wxs"; then
        say "PASS? NO: defect $WIXPATCH_DEFECT: the patched script succeeded - the post-check did not catch it"
        say "--- defect knob $WIXPATCH_DEFECT: rc=0 (a non-zero rc is the required outcome) -> this test FAILS"
        exit 0   # rc 0 here = the knob was NOT caught = the matrix leg below records a FAIL
    fi
    say "defect $WIXPATCH_DEFECT: the script's post-check refused the defective edit: $(grep -m1 -E 'post-check FAILED' "$T/out.txt" | sed 's/.*post-check/post-check/' | cut -c1-140)"
    say "--- defect knob $WIXPATCH_DEFECT: rc=1 (non-zero is the required outcome)"
    exit 1
fi

# --- the clean matrix ------------------------------------------------------------------------------------------------
bad=0
write_fixture "$T/Package.wxs"; cp "$T/Package.wxs" "$T/original.wxs"
if run_script "$SCRIPT" "$T/Package.wxs"; then say "PASS  apply: the script exits 0 on the pinned shape"
else say "FAIL  apply: rc=$? [$(head -c 300 "$T/out.txt" | tr '\n' ' ')]"; bad=1; fi

n_prop=$(grep -c '<Property Id="QWTNG_SERIALSTART" Secure="yes" />' "$T/Package.wxs")
n_cond=$(grep -c '<StartServices Condition="VersionNT AND NOT QWTNG_SERIALSTART" />' "$T/Package.wxs")
n_any=$(grep -c '<StartServices' "$T/Package.wxs")
if [ "$n_prop" -eq 1 ] && [ "$n_cond" -eq 1 ] && [ "$n_any" -eq 1 ]; then say "PASS  content: exactly one secure QWTNG_SERIALSTART property and one conditioned StartServices (and no other StartServices)"
else say "FAIL  content: property=$n_prop conditioned=$n_cond any-StartServices=$n_any"; bad=1; fi

# in place: the property right after ARPPRODUCTICON (comment lines between are ours), the action inside the sequence, first
prop_at=$(grep -n '<Property Id="QWTNG_SERIALSTART"' "$T/Package.wxs" | cut -d: -f1); arp_at=$(grep -n 'ARPPRODUCTICON' "$T/Package.wxs" | cut -d: -f1)
seq_open=$(grep -n '<InstallExecuteSequence>' "$T/Package.wxs" | cut -d: -f1); seq_close=$(grep -n '</InstallExecuteSequence>' "$T/Package.wxs" | cut -d: -f1)
cond_at=$(grep -n '<StartServices Condition' "$T/Package.wxs" | cut -d: -f1); helper_at=$(grep -n '<Custom Action="RunInstallHelper"' "$T/Package.wxs" | cut -d: -f1)
if [ "$prop_at" -gt "$arp_at" ] && [ $((prop_at - arp_at)) -le 4 ] && [ "$cond_at" -gt "$seq_open" ] && [ "$cond_at" -lt "$seq_close" ] && [ "$cond_at" -lt "$helper_at" ]; then
    say "PASS  placement: property $((prop_at - arp_at)) line(s) after ARPPRODUCTICON; StartServices inside InstallExecuteSequence, before the first Custom action"
else say "FAIL  placement: prop=$prop_at arp=$arp_at cond=$cond_at seq=$seq_open..$seq_close helper=$helper_at"; bad=1; fi

# nothing else changed: the diff is exactly 8 added lines (2 x (3 comment lines + 1 element)) and no removed line
added=$(diff "$T/original.wxs" "$T/Package.wxs" | grep -c '^>'); removed=$(diff "$T/original.wxs" "$T/Package.wxs" | grep -c '^<')
if [ "$added" -eq 8 ] && [ "$removed" -eq 0 ]; then say "PASS  minimal: 8 lines added, 0 removed - nothing else in Package.wxs changed"
else say "FAIL  minimal: added=$added removed=$removed"; bad=1; fi

# bytes: BOM kept, CRLF kept on every line (a mixed-ending file is what a careless insertion produces)
bom=$(head -c 3 "$T/Package.wxs" | xxd -p); crlf=$(grep -c $'\r$' "$T/Package.wxs"); lines=$(wc -l < "$T/Package.wxs")
if [ "$bom" = "efbbbf" ] && [ "$crlf" -eq "$lines" ]; then say "PASS  bytes: UTF-8 BOM kept, all $lines lines CRLF"
else say "FAIL  bytes: bom=$bom crlf=$crlf of $lines lines"; bad=1; fi

# idempotency: a second application is refused, and the file is untouched by the refusal
cp "$T/Package.wxs" "$T/once.wxs"
if run_script "$SCRIPT" "$T/Package.wxs"; then say "FAIL  twice: the script applied a second time (rc=0)"; bad=1
elif grep -q 'refusing to patch twice' "$T/out.txt" && cmp -s "$T/once.wxs" "$T/Package.wxs"; then say "PASS  twice: a second application is refused ('refusing to patch twice') and the file is unchanged"
else say "FAIL  twice: refused for another reason or the file changed [$(head -c 200 "$T/out.txt" | tr '\n' ' ')]"; bad=1; fi

# wrong shape: an anchor missing must throw, not silently skip
write_fixture "$T/noseq.wxs"; sed -i 's/<InstallExecuteSequence>/<InstallExecuteSequenceX>/' "$T/noseq.wxs"
if run_script "$SCRIPT" "$T/noseq.wxs"; then say "FAIL  shape: no <InstallExecuteSequence> and the script exited 0"; bad=1
elif grep -q 'patch 2 did not apply' "$T/out.txt"; then say "PASS  shape: a Package.wxs without <InstallExecuteSequence> is refused ('patch 2 did not apply')"
else say "FAIL  shape: refused for the wrong reason [$(head -c 200 "$T/out.txt" | tr '\n' ' ')]"; bad=1; fi

# every knob must make this test fail (a guard never seen to fail is decoration)
for knob in wixcond wixsecure; do
    if WIXPATCH_DEFECT=$knob bash "$0" > "$T/knob-$knob.out" 2>&1; then
        say "FAIL  defect $knob: the knob leg exited 0 - the defective edit was NOT caught [$(grep -m1 'PASS? NO' "$T/knob-$knob.out" | cut -c1-120)]"; bad=1
    else say "PASS  defect $knob: $(grep -m1 '^defect' "$T/knob-$knob.out" | cut -c1-200)"; fi
done

say "--- wix-serialstart-patch-selftest: $([ $bad -eq 0 ] && echo ALL PASS || echo FAILURES)"
exit $bad
