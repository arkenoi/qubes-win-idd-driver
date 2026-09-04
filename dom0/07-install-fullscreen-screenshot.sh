#!/bin/bash
# Install a dom0 qrexec service returning a FULL DESKTOP screenshot to win-idd-mgmt,
# then SELF-TEST it so failures surface here rather than as an opaque error in the dev qube.
#
# SECURITY NOTE - read before installing.
# local.WinScreenshot deliberately captures ONLY win-idd-test's windows, so the management VM
# never sees other qubes' content. This service does NOT have that property: it photographs
# the whole dom0 display, every other qube's windows included.
#
# It exists because defects in the dom0 *rendering* - window borders, the rectangle drawn over
# menus, desktop artifacts - are invisible to the per-window service by construction: menus are
# override-redirect (absent from _NET_CLIENT_LIST) and decorations are drawn on the frame, not
# on the client window that `import -window` captures.
#
# Remove when finished:   sudo rm /etc/qubes-rpc/local.WinFullScreen
set -uo pipefail

SVC=/etc/qubes-rpc/local.WinFullScreen
POLICY=/etc/qubes/policy.d/30-win-idd-fullscreen.policy
CALLER=win-idd-mgmt

[ "$(id -u)" -eq 0 ] || { echo "Run with sudo." >&2; exit 1; }

# Only `import` and `xprop` are required - both are already used by the existing
# local.WinScreenshot service, so they are known to be present. `xwininfo` is NOT required:
# it only adds the per-window geometry listing, and installing extra packages into dom0 to get
# a debugging nicety is a bad trade. Without it the full-desktop PNG is still produced.
# `scrot` is PREFERRED for the capture (a full-desktop `import` grab is ~59s here vs ~1-2s for
# scrot) but OPTIONAL - the service falls back to import if scrot is absent.
missing=()
for tool in import xprop; do command -v "$tool" >/dev/null || missing+=("$tool"); done
if [ ${#missing[@]} -gt 0 ]; then
    echo "Missing in dom0: ${missing[*]}" >&2
    echo "  sudo qubes-dom0-update ImageMagick" >&2
    exit 1
fi
if command -v scrot >/dev/null; then
    echo "scrot present: fast full-desktop capture enabled"
else
    echo "scrot absent: falling back to ImageMagick import (slow full-desktop grab; sudo qubes-dom0-update scrot to speed it up)"
fi
if command -v xwininfo >/dev/null; then
    echo "xwininfo present: geometry listing enabled"
else
    echo "xwininfo absent: screenshot only, no geometry listing (this is fine)"
fi

cat > "$SVC" <<'EOF'
#!/bin/bash
# Full-desktop screenshot. Returns a tar with screen.png and geometry.txt (every win-idd-test
# window INCLUDING override-redirect ones and frames, so the caller can crop without guessing).
set -uo pipefail
# Target selection is TAG-based: any qube carrying win-idd-testbed is served, which is the
# same gate the qrexec policy uses. A hardcoded name meant every qube created later got an
# EMPTY tar with no error - win11-fresh's visual acceptance was lost to exactly that
# (2026-08-07), and an empty tar is indistinguishable from "the guest has no windows".
# Robust under `set -u`: default $1 to empty before the ##*+ strip, or a direct argless call
# (the installer self-test) crashes with "1: unbound variable" instead of the clean "no target".
VM="${QREXEC_SERVICE_ARGUMENT:-${1:-}}"; VM="${VM##*+}"
[ -n "$VM" ] || { echo "no target: call as local.WinFullScreen+<vm>" >&2; exit 1; }
if ! qvm-tags "$VM" list 2>/dev/null | grep -qx win-idd-testbed; then
    echo "refused: '$VM' lacks the win-idd-testbed tag" >&2; exit 1
fi

DOMUSER=$(getent passwd 1000 | cut -d: -f1)
DISP="${DISPLAY:-:0}"
XA=""
for c in "/run/lightdm/$DOMUSER/xauthority" "/home/$DOMUSER/.Xauthority" \
         /run/user/$(id -u "$DOMUSER" 2>/dev/null)/xauth_* ; do
    [ -r "$c" ] || continue
    if sudo -u "$DOMUSER" env DISPLAY="$DISP" XAUTHORITY="$c" \
           xprop -root -notype _NET_SUPPORTED >/dev/null 2>&1; then XA="$c"; break; fi
done
[ -n "$XA" ] || { echo "ERROR: no usable X session for $DOMUSER on $DISP" >&2; exit 2; }
X=(sudo -u "$DOMUSER" env DISPLAY="$DISP" XAUTHORITY="$XA")

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
# The service runs as root, so mktemp -d gives a 0700 root-owned directory - but the capture
# runs as the desktop user through `sudo -u`, which then cannot write into it. This is what
# made every method fail with "Permission denied ... WriteBlob Failed".
chown "$DOMUSER" "$TMP" 2>/dev/null || chmod 0777 "$TMP"

# `import -window root` alone is unreliable: without -screen it grabs the root window's own
# contents rather than the composited screen, and on some setups it fails outright. Try the
# variants in order of fidelity and REPORT the real error instead of swallowing it - the first
# version of this script hid the reason and just said "capture failed".
CAP_ERR="$TMP/cap.err"
captured=""
# scrot FIRST: ImageMagick `import -screen -window root` of the full 5120x1440 dom0 desktop is
# ~59s per call here (measured 2026-09-04); scrot (imlib2/XGetImage) does the same whole-screen
# grab in a second or two. Kept behind a presence check with import as the fallback, so a dom0
# without scrot still works. (Detection that only needs the window LIST should use local.WinGeom,
# which captures nothing at all.)
if command -v scrot >/dev/null &&
   "${X[@]}" scrot -o "$TMP/screen.png" 2>>"$CAP_ERR" && [ -s "$TMP/screen.png" ]; then
    captured="scrot"
elif "${X[@]}" import -screen -window root "$TMP/screen.png" 2>>"$CAP_ERR" && [ -s "$TMP/screen.png" ]; then
    captured="import -screen -window root"
elif "${X[@]}" import -window root "$TMP/screen.png" 2>>"$CAP_ERR" && [ -s "$TMP/screen.png" ]; then
    captured="import -window root"
elif command -v xwd >/dev/null &&
     "${X[@]}" xwd -root -silent > "$TMP/screen.xwd" 2>>"$CAP_ERR" && [ -s "$TMP/screen.xwd" ] &&
     convert "$TMP/screen.xwd" "$TMP/screen.png" 2>>"$CAP_ERR" && [ -s "$TMP/screen.png" ]; then
    captured="xwd -root | convert"
    rm -f "$TMP/screen.xwd"
elif command -v gnome-screenshot >/dev/null &&
     "${X[@]}" gnome-screenshot -f "$TMP/screen.png" 2>>"$CAP_ERR" && [ -s "$TMP/screen.png" ]; then
    captured="gnome-screenshot"
fi

if [ -z "$captured" ]; then
    echo "ERROR: every root-window capture method failed. Tool output:" >&2
    sed 's/^/  /' "$CAP_ERR" >&2
    echo "  tried: scrot | import -screen -window root | import -window root | xwd+convert | gnome-screenshot" >&2
    exit 3
fi
echo "capture method: $captured" >&2

# Geometry is best effort and must never abort the capture: the PNG is the point. It also
# requires xwininfo, which dom0 may not have - absence is not an error.
{
    # The 'mapped' column exists because this list comes from xwininfo -root -tree,
    # which enumerates EXISTING X windows - a withdrawn (unmapped) window still
    # appears. Reading geometry without map state misled a whole investigation
    # (2026-08-07: the seamless desktop window was reported as "mapped full-screen"
    # when it was actually withdrawn).
    echo "# id x y w h override_redirect mapped name"
    command -v xwininfo >/dev/null || echo "# xwininfo not installed in dom0 - geometry omitted"
    "${X[@]}" xwininfo -root -tree 2>/dev/null |
      grep -oE '0x[0-9a-f]+' | sort -u | while read -r id; do
        owner=$("${X[@]}" xprop -id "$id" _QUBES_VMNAME 2>/dev/null |
                sed -n 's/^_QUBES_VMNAME(STRING) = "\(.*\)"$/\1/p')
        [ "$owner" = "$VM" ] || continue
        info=$("${X[@]}" xwininfo -id "$id" -stats 2>/dev/null) || continue
        x=$(printf '%s' "$info" | sed -n 's/.*Absolute upper-left X: *\([0-9-]*\).*/\1/p' | head -1)
        y=$(printf '%s' "$info" | sed -n 's/.*Absolute upper-left Y: *\([0-9-]*\).*/\1/p' | head -1)
        w=$(printf '%s' "$info" | sed -n 's/.*Width: *\([0-9]*\).*/\1/p' | head -1)
        h=$(printf '%s' "$info" | sed -n 's/.*Height: *\([0-9]*\).*/\1/p' | head -1)
        ovr=$(printf '%s' "$info" | grep -c 'Override Redirect State: yes')
        name=$("${X[@]}" xprop -id "$id" WM_NAME 2>/dev/null |
               sed -n 's/^WM_NAME(\(STRING\|UTF8_STRING\)) = "\(.*\)"$/\2/p' | head -1)
        ms=$(printf '%s' "$info" | grep -c 'Map State: IsViewable')
        echo "$id ${x:-?} ${y:-?} ${w:-?} ${h:-?} $ovr $ms ${name:-?}"
    done
} > "$TMP/geometry.txt" 2>/dev/null || true

tar -C "$TMP" -cf - .
EOF
chmod 755 "$SVC"

# The existing local.WinScreenshot policy was configured by hand, so do not assume a file -
# write our own, which is evaluated alongside the others.
if [ ! -f "$POLICY" ] || ! grep -q 'local.WinFullScreen' "$POLICY" 2>/dev/null; then
    printf 'local.WinFullScreen * %s dom0 allow\n' "$CALLER" >> "$POLICY"
    chmod 664 "$POLICY"
    echo "policy: added 'local.WinFullScreen * $CALLER dom0 allow' to $POLICY"
else
    echo "policy: already present in $POLICY"
fi

echo
echo "== self-test =="
OUT=$(mktemp -d)
cleanup() { rm -rf "$OUT"; }
trap cleanup EXIT

# The service is tag-gated and REQUIRES a target, so the old no-arg `"$SVC" </dev/null` call
# crashed at the arg parse. Self-test the capture against a RUNNING win-idd-testbed guest; if
# none is up, SKIP the live check - installing must not require a running guest (the service +
# policy are already written above, and the arg-parse guard is exercised by real qrexec calls).
tv=""
for v in $(qvm-ls --raw-data --fields NAME,STATE 2>/dev/null | awk -F'|' '$2=="Running"{print $1}'); do
    qvm-tags "$v" list 2>/dev/null | grep -qx win-idd-testbed && { tv="$v"; break; }
done
if [ -z "$tv" ]; then
    echo "  --  no running win-idd-testbed guest; skipping the live capture self-test (service installed)"
    echo
    echo "Installed $SVC (self-test skipped: no running testbed guest to capture against)."
    exit 0
fi
echo "  self-testing capture against running testbed guest: $tv"
QREXEC_SERVICE_ARGUMENT="$tv" "$SVC" < /dev/null > "$OUT/t.tar" 2>"$OUT/t.err"
rc=$?
if [ $rc -ne 0 ]; then
    echo "  FAIL: service exited $rc"
    sed 's/^/    /' "$OUT/t.err"
    exit 4
fi

tar -xf "$OUT/t.tar" -C "$OUT" 2>/dev/null

if [ ! -s "$OUT/screen.png" ]; then
    echo "  FAIL: tar produced no screen.png"
    sed 's/^/    /' "$OUT/t.err"
    exit 4
fi

dims=$(identify -format '%wx%h' "$OUT/screen.png" 2>/dev/null || echo '?')
bytes=$(stat -c%s "$OUT/screen.png")
echo "  OK  screen.png $dims ($bytes bytes)"
grep -h 'capture method' "$OUT/t.err" 2>/dev/null | sed 's/^/  /'

if command -v xwininfo >/dev/null 2>&1; then
    gcount=$(grep -vc '^#' "$OUT/geometry.txt" 2>/dev/null || true)
    echo "  OK  geometry.txt: ${gcount:-0} window(s) listed"
else
    echo "  --  geometry omitted (no xwininfo); the screenshot is what matters"
fi

echo
echo "Installed $SVC and self-tested."
echo "It captures the WHOLE screen, other qubes included. Remove with:"
echo "  sudo rm $SVC $POLICY"
