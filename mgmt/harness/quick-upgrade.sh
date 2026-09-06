#!/bin/bash
# quick-upgrade.sh - FAST package validation via an in-place MSI MajorUpgrade, instead of a full
# clean install from a pristine base. Use for one-off "does this package work" checks; the full
# acceptance protocol still installs clean from win{10,11}-base (see prime-run.sh).
#
#   quick-upgrade.sh <package-setup-dir> [subject] [os]
#     <package-setup-dir>  a setup tree with install.cmd at its root (a dev/release package)
#     [subject]            churn guest to build (default: <os>-up)
#     [os]                 win10 | win11 (default: win11)
#
# HOW IT WORKS. It is prime-run.sh with the QWT-installed golden <os>-qwt as the base instead of the
# pristine <os>-base. prime-run clones the golden (which already has an OLDER QWT) and runs the
# package's install.cmd; because the rebuilt MSI shares stock's UpgradeCode ({14BCB82F-...}) and
# carries <MajorUpgrade/> with a per-release ProductVersion bump, install.cmd does an in-place
# MajorUpgrade with NO intermediate reboot (findings/install.md:17) - roughly half the wall-clock of
# a clean install, and it exercises the UPGRADE path (real users' path) every time.
#
# THE ORDERING RULE (why the golden is N-1). A MajorUpgrade only fires when the package's
# ProductVersion is STRICTLY GREATER than the golden's installed version. Dev builds are 4.3.N; the
# golden must be <= 4.3.(N-1). If they match, install.cmd falls to uninstall-first (slow, PV-disk
# gated) - which still WORKS but is not "quick". Refresh the golden whenever the dev line bumps:
#   mgmt/harness/prime-run.sh <os>-base <os>-qwt ours --payload <release-N-1-tree>
#   then clear its answer stick (below) so it boots clean as a clone source.
# The golden build/refresh is a rig op; see docs and the seal note at the end of this file.
set -uo pipefail
HERE="$(cd "$(dirname "$0")/../.." && pwd)"; cd "$HERE" || exit 1

PKG="${1:?usage: quick-upgrade.sh <package-setup-dir> [subject] [os]}"
OS="${3:-win11}"
SUBJECT="${2:-$OS-up}"
GOLDEN="$OS-qwt"
[ -d "$PKG" ] || { echo "FATAL: package setup dir '$PKG' not found"; exit 2; }
[ -f "$PKG/install.cmd" ] || { echo "FATAL: '$PKG' has no install.cmd at its root - not a setup tree"; exit 2; }

# The golden must exist and be Halted. If it does not, say exactly how to build it (do not guess).
gstate=$(qvm-ls --raw-data --fields NAME,STATE 2>/dev/null | awk -F'|' -v v="$GOLDEN" '$1==v{print $2}')
if [ -z "$gstate" ]; then
  echo "FATAL: quick-upgrade golden '$GOLDEN' does not exist. Build it once (N-1 release) with:"
  echo "  mgmt/harness/prime-run.sh $OS-base $GOLDEN ours --payload <release-tree>"
  echo "  then clear its stick:  qvm-device block detach $GOLDEN <holder>:<loop>; qvm-features --unset $GOLDEN qemu-extra-args"
  exit 3
fi
[ "$gstate" = Halted ] || { echo "FATAL: golden '$GOLDEN' is $gstate, must be Halted (it is a clone source, never run it directly)"; exit 3; }

# Version sanity (advisory): compare the package version to the golden's sealed version if recorded.
pkgver=$(grep -oE '"package_version"[^,]*' "$PKG/MANIFEST.json" 2>/dev/null | grep -oE '4\.[0-9.]+' | head -1)
goldver=$(grep -oE '"sealed_version"[^,]*' "mgmt/fixtures/$GOLDEN.json" 2>/dev/null | grep -oE '4\.[0-9.]+' | head -1)
if [ -n "$pkgver" ] && [ -n "$goldver" ]; then
  if [ "$(printf '%s\n%s\n' "$goldver" "$pkgver" | sort -V | tail -1)" = "$goldver" ] && [ "$goldver" != "$pkgver" ]; then
    echo "WARNING: package $pkgver <= golden $goldver - install.cmd will UNINSTALL-FIRST (slow), not a fast MajorUpgrade."
  else
    echo "quick-upgrade: package $pkgver over golden $goldver (in-place MajorUpgrade expected)"
  fi
fi

echo "quick-upgrade: $GOLDEN -> $SUBJECT via prime-run (install.cmd MajorUpgrade), package=$PKG"
exec ./mgmt/harness/prime-run.sh "$GOLDEN" "$SUBJECT" ours --payload "$PKG"
